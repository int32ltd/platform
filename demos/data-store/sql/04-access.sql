-- =============================================================================
-- 04-access.sql — the read path and its permission rule.
--
-- The catalog service connects as catalog_api and sets, per request,
--   set local catalog.viewer = 'user:alice';
-- catalog_api has no privilege on catalog.* or authz.*. Everything it reads
-- goes through api.* views owned by catalog_owner, and every one of them is
-- built on api.resource, so the visibility rule exists in exactly one place.
-- =============================================================================

set role catalog_owner;

-- -----------------------------------------------------------------------------
-- Who is asking, and what that gives them. Each is evaluated once per query
-- (the views call them in a materialised CTE), not once per row.
-- -----------------------------------------------------------------------------
create function authz.viewer() returns text
language sql stable security definer set search_path = pg_catalog as $$
  select r.ref
    from catalog.resource r
   where r.ref = nullif(current_setting('catalog.viewer', true), '')
     and r.kind = 'user' and r.deleted_at is null;   -- a tombstoned user is nobody
$$;

create function authz.viewer_teams() returns text[]
language sql stable security definer set search_path = pg_catalog as $$
  select coalesce(array_agg(team_ref), '{}') from authz.user_team where user_ref = authz.viewer();
$$;

create function authz.viewer_is(p_role text) returns boolean
language sql stable security definer set search_path = pg_catalog as $$
  select exists (select 1 from authz.user_role where user_ref = authz.viewer() and role = p_role);
$$;

-- Kinds whose resources the viewer may list regardless of ownership.
create function authz.viewer_readable_kinds() returns text[]
language sql stable security definer set search_path = pg_catalog as $$
  select coalesce(array_agg(k.id), '{}')
    from catalog.kind k
   where authz.viewer() is not null
     and (k.visibility = 'org'
          or authz.viewer_is('admin') or authz.viewer_is('auditor')
          or exists (select 1 from authz.user_kind_grant g
                      where g.user_ref = authz.viewer() and g.kind_id = k.id));
$$;

-- Kinds whose resources the viewer sees in full (sensitive properties too)
-- regardless of ownership: kind editors, platform admins and auditors.
create function authz.viewer_privileged_kinds() returns text[]
language sql stable security definer set search_path = pg_catalog as $$
  select coalesce(array_agg(k.id), '{}')
    from catalog.kind k
   where authz.viewer_is('admin') or authz.viewer_is('auditor')
      or exists (select 1 from authz.user_kind_grant g
                  where g.user_ref = authz.viewer() and g.kind_id = k.id);
$$;

create function authz.viewer_can_edit(p_kind text, p_owners text[]) returns boolean
language sql stable security definer set search_path = pg_catalog as $$
  select p_owners && authz.viewer_teams()
      or authz.viewer_is('admin')
      or exists (select 1 from authz.user_kind_grant g
                  where g.user_ref = authz.viewer() and g.kind_id = p_kind and g.relation = 'editor');
$$;

create function authz.viewer_can_transfer(p_kind text) returns boolean
language sql stable security definer set search_path = pg_catalog as $$
  select authz.viewer_is('admin');
$$;

-- -----------------------------------------------------------------------------
-- api.resource — THE visibility rule:
--   row visible   : owner team member, or kind readable (org / editor / admin / auditor)
--   full properties: owner team member, or kind privileged (editor / admin / auditor)
-- Tombstoned resources are never visible through the API.
-- -----------------------------------------------------------------------------
create view api.resource with (security_barrier) as
  with v as materialized (
    select authz.viewer_teams()            as teams,
           authz.viewer_readable_kinds()   as readable,
           authz.viewer_privileged_kinds() as privileged
  )
  select r.ref,
         r.kind,
         r.identifier,
         r.title,
         case when a.full then r.properties
              else r.properties - k.sensitive_properties end                        as properties,
         case when a.full then '{}'::text[]
              else array(select p from unnest(k.sensitive_properties) p
                          where r.properties ? p) end                               as redacted,
         r.effective_owners,
         case when a.full then r.property_provenance
              else r.property_provenance - k.sensitive_properties end               as provenance,
         (select jsonb_object_agg(rs.source_id, jsonb_build_object(
                   'lastSeenAt', rs.last_seen_at, 'stale', rs.stale_since is not null)
                   order by rs.source_id)
            from catalog.resource_source rs where rs.resource_id = r.id)            as freshness,
         r.unmatched,
         r.version,
         r.created_at,
         r.updated_at,
         a.full                                                                     as sensitive_visible
    from catalog.resource r
    join catalog.kind k on k.id = r.kind
    cross join v
    cross join lateral (select r.effective_owners && v.teams or r.kind = any (v.privileged) as full) a
   where r.deleted_at is null
     and (r.effective_owners && v.teams or r.kind = any (v.readable));

-- An edge is visible when both ends are (a dangling edge only needs its source).
create view api.link with (security_barrier) as
  select f.ref                                 as from_ref,
         l.name,
         l.to_ref,
         l.to_id is null                       as dangling,
         array_agg(l.source_id order by l.source_id) filter (where l.applied)     as sources,
         array_agg(l.source_id order by l.source_id) filter (where not l.applied) as overridden,
         max(l.last_seen_at)                   as last_seen_at
    from catalog.link l
    join catalog.resource fr  on fr.id = l.from_id
    join api.resource f       on f.ref = fr.ref
    left join catalog.resource tr on tr.id = l.to_id
    left join api.resource t      on t.ref = tr.ref
   where l.to_id is null or t.ref is not null
   group by f.ref, l.name, l.to_ref, l.to_id
  having bool_or(l.applied);

-- Change history of resources the viewer can see now. In diffs the viewer may
-- not read in full, sensitive values are replaced by "(redacted)": the viewer
-- learns that the property changed, not what it changed to.
create view api.change with (security_barrier) as
  select c.occurred_at,
         c.resource_ref,
         c.version,
         c.op,
         c.actor_type,
         c.actor,
         case when r.sensitive_visible or not c.diff ? 'properties' then c.diff
              else jsonb_set(c.diff, '{properties}',
                     ((c.diff -> 'properties') - k.sensitive_properties)
                     || coalesce((select jsonb_object_agg(p, '(redacted)')
                                    from unnest(k.sensitive_properties) p
                                   where c.diff -> 'properties' ? p), '{}'))
         end as diff,
         c.reason
    from catalog.change_log c
    join api.resource r on r.ref = c.resource_ref
    join catalog.kind k on k.id = r.kind;

create view api.kind with (security_barrier) as
  select k.id, k.title, k.description, k.visibility, k.sensitive_properties, k.identity_keys,
         (select jsonb_object_agg(lt.name, jsonb_strip_nulls(jsonb_build_object(
                   'target', lt.target_kinds, 'many', lt.many, 'ownership', lt.ownership)))
            from catalog.link_type lt where lt.kind_id = k.id) as links
    from catalog.kind k
   where authz.viewer() is not null;

-- -----------------------------------------------------------------------------
-- api functions: the query surface the REST/GraphQL/MCP layer calls.
-- -----------------------------------------------------------------------------
create function api.get(p_ref text) returns setof api.resource
language sql stable as $$
  select * from api.resource where ref = p_ref;
$$;

-- Full-text search: the index finds candidates, api.resource decides visibility.
create function api.search(p_query text, p_kind text default null, p_limit int default 20)
returns setof api.resource
language sql stable security definer set search_path = pg_catalog as $$
  select v.*
    from catalog.resource r
    join api.resource v on v.ref = r.ref
   where r.search @@ websearch_to_tsquery('simple', p_query)
     and (p_kind is null or r.kind = p_kind)
   order by ts_rank(r.search, websearch_to_tsquery('simple', p_query)) desc, r.ref
   limit p_limit;
$$;

-- Ownership with its evidence. Path steps the viewer cannot see are masked.
create function api.who_owns(p_ref text)
returns table (owner text, path text)
language sql stable security definer set search_path = pg_catalog as $$
  select p.owner_ref,
         (select string_agg(
                   case when i = 1 then step
                        else format('--%s--> %s', p.links[i - 1], step) end, ' ' order by i)
            from unnest(p.refs) with ordinality as u(ref, i)
            cross join lateral (
              select case when exists (select 1 from api.resource v where v.ref = u.ref)
                          then u.ref else '(hidden)' end as step) s)
    from catalog.resource r
    cross join lateral catalog.owner_paths(r.id) p
   where r.ref = p_ref
     and exists (select 1 from api.resource v where v.ref = p_ref)
   order by 1, 2;
$$;

-- Agent context: a token-bounded neighbourhood. Permission filtering happens
-- before the budget, because both views it walks are already filtered.
create function api.context(p_focus text[], p_depth int default 2, p_max_resources int default 60)
returns jsonb
language sql stable as $$
  with recursive hood (ref, depth) as (
    select ref, 0 from api.resource where ref = any (p_focus)
    union
    select case when l.from_ref = h.ref then l.to_ref else l.from_ref end, h.depth + 1
      from hood h
      join api.link l on (l.from_ref = h.ref or l.to_ref = h.ref) and not l.dangling
     where h.depth < p_depth
  ),
  nearest as (
    select ref, min(depth) as depth from hood group by ref
  ),
  picked as (
    select n.ref, n.depth from nearest n order by n.depth, n.ref limit p_max_resources
  )
  select jsonb_build_object(
    'focus', to_jsonb(p_focus),
    'truncated', (select count(*) from nearest) > p_max_resources,
    'resources', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                     'ref', r.ref, 'title', r.title, 'depth', p.depth,
                     'owners', r.effective_owners, 'properties', r.properties,
                     'redacted', nullif(r.redacted, '{}'), 'freshness', r.freshness))
                     order by p.depth, r.ref)
                    from picked p join api.resource r on r.ref = p.ref),
    'links', (select coalesce(jsonb_agg(jsonb_build_object('from', l.from_ref, 'link', l.name, 'to', l.to_ref)
                     order by l.from_ref, l.name, l.to_ref), '[]')
                from api.link l
               where l.from_ref in (select ref from picked) and l.to_ref in (select ref from picked)));
$$;

create function api.changes_since(p_since timestamptz)
returns setof api.change
language sql stable as $$
  select * from api.change where occurred_at > p_since order by occurred_at;
$$;

-- Manual edit on behalf of the viewer: can_edit for anything, can_transfer
-- when the edit touches the owner link. Writes go through catalog.ingest as
-- the `manual` source, so they merge, resolve and log like any other write.
create function api.update(p_ref text, p_properties jsonb default '{}', p_links jsonb default '{}',
                           p_reason text default null)
returns setof api.resource
language plpgsql security definer set search_path = pg_catalog as $$
declare
  v_viewer text := authz.viewer();
  v_res    catalog.resource;
  v_claim  record;
begin
  if v_viewer is null then
    raise exception 'no viewer: set catalog.viewer to a live user ref' using errcode = '28000';
  end if;
  select * into v_res from catalog.resource where ref = p_ref and deleted_at is null;
  if not found or not exists (select 1 from api.resource where ref = p_ref) then
    raise exception 'resource % not found', p_ref using errcode = 'P0002';  -- same answer as "hidden"
  end if;
  if not authz.viewer_can_edit(v_res.kind, v_res.effective_owners) then
    raise exception '% lacks can_edit on %', v_viewer, p_ref using errcode = '42501';
  end if;
  if exists (select 1 from catalog.link_type lt
              where lt.kind_id = v_res.kind and lt.ownership = 'grants'
                and coalesce(p_links, '{}') ? lt.name)
     and not authz.viewer_can_transfer(v_res.kind) then
    raise exception '% lacks can_transfer on %: ownership changes are privileged', v_viewer, p_ref
      using errcode = '42501';
  end if;
  select pc.property, pc.source_id into v_claim
    from catalog.property_claim pc
   where pc.kind_id = v_res.kind and coalesce(p_properties, '{}') ? pc.property
   limit 1;
  if found then
    raise exception 'property % of % is owned by source %: change it there', v_claim.property, v_res.kind, v_claim.source_id
      using errcode = '42501';
  end if;

  perform catalog.ingest('manual', v_res.kind, v_res.identifier, null, p_properties, p_links,
                         p_actor_type => 'user', p_actor => v_viewer, p_reason => p_reason);
  return query select * from api.resource where ref = p_ref;
end $$;

-- -----------------------------------------------------------------------------
-- OpenFGA: the tuple set the catalog should have written. The sync consumer
-- diffs this against the store after each batch of changes; the nightly
-- consistency check compares Check() answers with api.resource.
-- -----------------------------------------------------------------------------
create view authz.fga_tuples as
  -- nested group membership, kept nested
  select g.ref as object, 'member' as relation,
         case when m.kind = 'user' then m.ref else m.ref || '#member' end as subject
    from catalog.link l
    join catalog.resource g on g.id = l.from_id and g.kind = 'identity_group' and g.deleted_at is null
    join catalog.resource m on m.id = l.to_id and m.deleted_at is null
   where l.name = 'members' and l.applied
  union
  select t.ref, 'backed_by', g.ref
    from catalog.link l
    join catalog.resource t on t.id = l.from_id and t.kind = 'team' and t.deleted_at is null
    join catalog.resource g on g.id = l.to_id and g.deleted_at is null
   where l.name = 'backedBy' and l.applied
  union
  select format('resource:%s/%s', r.kind, r.identifier), 'kind', 'kind:' || r.kind
    from catalog.resource r
   where r.deleted_at is null and r.kind not in ('user', 'identity_group', 'team')
  union
  select format('resource:%s/%s', r.kind, r.identifier), 'owner', o
    from catalog.resource r, unnest(r.effective_owners) o
   where r.deleted_at is null and r.kind not in ('user', 'identity_group', 'team')
  union
  select 'kind:' || k.id, 'platform', 'platform:default' from catalog.kind k
  union
  select 'kind:' || k.id, 'org_viewer', 'user:*' from catalog.kind k where k.visibility = 'org'
  union
  select 'kind:' || kg.kind_id, kg.relation,
         kg.principal_ref || '#member'
    from authz.kind_grant kg
  union
  select 'platform:default', pg.role,
         pg.principal_ref || case when pg.principal_ref like 'identity_group:%' then '#member' else '' end
    from authz.platform_grant pg;

-- Diagnostic for platform admins (not granted to catalog_api): what each live
-- user may do with one resource, evaluated by the same functions the API uses.
create function authz.access_matrix(p_ref text)
returns table (user_ref text, can_view boolean, sees_sensitive boolean, can_edit boolean, can_transfer boolean)
language plpgsql as $$
declare
  v_prev text := current_setting('catalog.viewer', true);
  u      record;
  v_res  catalog.resource;
begin
  select * into v_res from catalog.resource where ref = p_ref;
  for u in select ref from catalog.resource where kind = 'user' and deleted_at is null order by ref loop
    perform set_config('catalog.viewer', u.ref, true);
    user_ref := u.ref;
    select true, a.sensitive_visible into can_view, sees_sensitive from api.resource a where a.ref = p_ref;
    can_view       := coalesce(can_view, false);
    sees_sensitive := coalesce(sees_sensitive, false);
    can_edit       := can_view and authz.viewer_can_edit(v_res.kind, v_res.effective_owners);
    can_transfer   := can_view and authz.viewer_can_transfer(v_res.kind);
    return next;
    can_view := null; sees_sensitive := null;
  end loop;
  perform set_config('catalog.viewer', coalesce(v_prev, ''), true);
end $$;

-- -----------------------------------------------------------------------------
-- Privileges. Functions are executable by PUBLIC by default; take that away
-- first, then grant per role.
-- -----------------------------------------------------------------------------
-- Entry points other roles call run with the owner's rights, so callers need
-- no table privileges at all.
alter function catalog.ingest(text, text, text, text, jsonb, jsonb, text, bigint, catalog.actor_type, text, text)
  security definer set search_path = pg_catalog;
alter function catalog.retract(text, text, catalog.actor_type, text, text) security definer set search_path = pg_catalog;
alter function catalog.start_run(text, text)            security definer set search_path = pg_catalog;
alter function catalog.finish_run(bigint)               security definer set search_path = pg_catalog;
alter function catalog.poll_changes(text, int)          security definer set search_path = pg_catalog;
alter function catalog.ack_changes(text, xid8, bigint)  security definer set search_path = pg_catalog;

revoke all on schema catalog, authz, api from public;
revoke execute on all functions in schema catalog, authz, api from public;

grant usage on schema api to catalog_api;
grant select on all tables in schema api to catalog_api;
grant execute on all functions in schema api to catalog_api;
grant usage on schema authz to catalog_api;   -- views call these; definer rights do the reading
grant execute on function authz.viewer(), authz.viewer_teams(), authz.viewer_is(text),
                          authz.viewer_readable_kinds(), authz.viewer_privileged_kinds(),
                          authz.viewer_can_edit(text, text[]), authz.viewer_can_transfer(text)
  to catalog_api;

grant usage on schema catalog to catalog_ingest;
grant execute on function catalog.ingest(text, text, text, text, jsonb, jsonb, text, bigint, catalog.actor_type, text, text),
                          catalog.retract(text, text, catalog.actor_type, text, text),
                          catalog.start_run(text, text), catalog.finish_run(bigint)
  to catalog_ingest;

grant usage on schema catalog to catalog_consumer;
grant execute on function catalog.poll_changes(text, int), catalog.ack_changes(text, xid8, bigint) to catalog_consumer;

grant usage on schema catalog, authz to catalog_auditor;
grant select on all tables in schema catalog, authz to catalog_auditor;

reset role;
