-- =============================================================================
-- 02-graph.sql — what the store derives from the facts: link validation,
-- dangling-edge attachment, single-valued link precedence, property merging,
-- ownership resolution and flattened membership.
--
-- Changing the schema? Update demos/data-store/index.html (the schema page)
-- and docs/data-store/reference.md in the same change. ./demo.sh test fails
-- while the page and the database disagree.
-- =============================================================================

set role catalog_owner;

-- -----------------------------------------------------------------------------
-- Link validation. Runs on every insert, whatever the write path: the link must
-- be declared on the source resource's kind and point at an allowed kind.
-- -----------------------------------------------------------------------------
create function catalog.link_validate() returns trigger
language plpgsql as $$
declare
  v_kind   text;
  v_lt     catalog.link_type;
  v_target text := split_part(new.to_ref, ':', 1);
begin
  select kind into v_kind from catalog.resource where id = new.from_id;
  select * into v_lt from catalog.link_type where kind_id = v_kind and name = new.name;
  if not found then
    raise exception 'kind % declares no link %', v_kind, new.name using errcode = '23514';
  end if;
  if not v_target = any (v_lt.target_kinds) then
    raise exception 'link %.% may point at % but got %', v_kind, new.name, v_lt.target_kinds, new.to_ref
      using errcode = '23514';
  end if;
  if new.to_id is null then
    select id into new.to_id from catalog.resource where ref = new.to_ref;
  end if;
  return new;
end $$;
create trigger link_validate before insert on catalog.link
  for each row execute function catalog.link_validate();

-- Dangling-edge attachment: when a resource appears, every link already
-- pointing at its ref attaches to it. A hard delete sets to_id back to null
-- (on delete set null), which is the tombstone that lets a re-created
-- resource reattach cleanly.
create function catalog.attach_dangling() returns trigger
language plpgsql as $$
begin
  update catalog.link set to_id = new.id where to_id is null and to_ref = new.ref;
  return null;
end $$;
create trigger resource_attach_dangling after insert on catalog.resource
  for each row execute function catalog.attach_dangling();

-- -----------------------------------------------------------------------------
-- Single-valued links (many: false) can be asserted by more than one source
-- with different targets. Every assertion is kept (provenance); exactly one is
-- applied: a `manual` override wins, otherwise the earliest assertion. Links
-- with many: true are a union, so every assertion is applied.
-- -----------------------------------------------------------------------------
alter table catalog.link add column applied boolean not null default true;
create index link_applied_forward on catalog.link (from_id, name) where applied;

create function catalog.apply_single_link(p_from bigint, p_name text) returns void
language sql as $$
  update catalog.link l
     set applied = (l.id = w.id)
    from (select id from catalog.link
           where from_id = p_from and name = p_name
           order by (source_id = 'manual') desc, created_at, id
           limit 1) w
   where l.from_id = p_from and l.name = p_name
     and l.applied is distinct from (l.id = w.id);
$$;

-- -----------------------------------------------------------------------------
-- Property merging: resource.properties is computed from what each source
-- observed. A source's value is applied only for properties it claims; the
-- `manual` source supplies properties nobody claims. Lower priority wins.
-- -----------------------------------------------------------------------------
create function catalog.merge_properties(p_id bigint, out properties jsonb, out provenance jsonb)
language sql stable as $$
  with r as (select kind from catalog.resource where id = p_id),
  obs as (
    select rs.source_id, e.key, e.value
      from catalog.resource_source rs, jsonb_each(rs.observed) e
     where rs.resource_id = p_id
  ),
  ranked as (
    select o.key, o.value, o.source_id,
           coalesce(pc.priority,
                    case when o.source_id = 'manual'
                          and not exists (select 1 from catalog.property_claim c
                                           where c.kind_id = r.kind and c.property = o.key)
                         then 1000 end) as priority
      from obs o
      cross join r
      left join catalog.property_claim pc
             on pc.source_id = o.source_id and pc.kind_id = r.kind and pc.property = o.key
  ),
  winners as (
    select distinct on (key) key, value, source_id
      from ranked where priority is not null
     order by key, priority, source_id
  )
  select coalesce(jsonb_object_agg(key, value), '{}'),
         coalesce(jsonb_object_agg(key, source_id), '{}')
    from winners;
$$;

create function catalog.jsonb_diff(a jsonb, b jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_object_agg(k, jsonb_build_object('from', a -> k, 'to', b -> k)), '{}')
    from (select jsonb_object_keys(coalesce(a, '{}')) union select jsonb_object_keys(coalesce(b, '{}'))) keys(k)
   where a -> k is distinct from b -> k;
$$;

-- -----------------------------------------------------------------------------
-- Ownership resolution — the only place ownership logic lives.
--   1. a live applied `ownership: grants` link names the owner;
--   2. otherwise follow `ownership: inherits` links, recursively, with cycle
--      detection and a depth limit of 6;
--   3. nothing resolves: unowned (an empty array).
-- Dangling links (to_id is null) and tombstoned targets never contribute.
-- owner_paths returns the evidence; resolve_owners is just its owner column.
-- -----------------------------------------------------------------------------
create function catalog.owner_paths(p_id bigint)
returns table (owner_ref text, refs text[], links text[])
language sql stable as $$
  with recursive walk (id, refs, links, depth) as (
    select r.id, array[r.ref], array[]::text[], 0
      from catalog.resource r
     where r.id = p_id and r.deleted_at is null
    union all
    select t.id, w.refs || t.ref, w.links || l.name, w.depth + 1
      from walk w
      join catalog.resource r   on r.id = w.id
      join catalog.link l       on l.from_id = w.id and l.applied and l.to_id is not null
      join catalog.link_type lt on lt.kind_id = r.kind and lt.name = l.name and lt.ownership = 'inherits'
      join catalog.resource t   on t.id = l.to_id and t.deleted_at is null
     where w.depth < 6
       and not t.ref = any (w.refs)                      -- cycle detection
       and not exists (                                  -- rule 1 beats rule 2
             select 1
               from catalog.link g
               join catalog.link_type glt on glt.kind_id = r.kind and glt.name = g.name and glt.ownership = 'grants'
               join catalog.resource tm   on tm.id = g.to_id and tm.deleted_at is null
              where g.from_id = w.id and g.applied)
  )
  select tm.ref, w.refs || tm.ref, w.links || g.name
    from walk w
    join catalog.resource r    on r.id = w.id
    join catalog.link g        on g.from_id = w.id and g.applied
    join catalog.link_type glt on glt.kind_id = r.kind and glt.name = g.name and glt.ownership = 'grants'
    join catalog.resource tm   on tm.id = g.to_id and tm.deleted_at is null and tm.kind = 'team'
  union all
  -- A team owns itself, so its members see its sensitive properties.
  select r.ref, array[r.ref], array[]::text[]
    from catalog.resource r
   where r.id = p_id and r.kind = 'team' and r.deleted_at is null;
$$;

create function catalog.resolve_owners(p_id bigint) returns text[]
language sql stable as $$
  select coalesce(array_agg(distinct owner_ref order by owner_ref), '{}')
    from catalog.owner_paths(p_id);
$$;

-- Recompute effective_owners for a resource and everything whose ownership can
-- depend on it (reverse walk over grants/inherits links), logging each change.
create function catalog.recompute_owners(
  p_id bigint, p_actor_type catalog.actor_type, p_actor text, p_reason text)
returns int
language plpgsql as $$
declare
  r     record;
  v_new text[];
  n     int := 0;
begin
  for r in
    with recursive dependents (id) as (
      select p_id
      union
      select l.from_id
        from dependents d
        join catalog.link l       on l.to_id = d.id
        join catalog.resource f   on f.id = l.from_id
        join catalog.link_type lt on lt.kind_id = f.kind and lt.name = l.name and lt.ownership is not null
    )
    select res.id, res.ref, res.effective_owners, res.version
      from dependents d join catalog.resource res using (id)
     where res.deleted_at is null
     order by res.id
  loop
    v_new := catalog.resolve_owners(r.id);
    if v_new is distinct from r.effective_owners then
      update catalog.resource
         set effective_owners = v_new, version = version + 1, updated_at = now()
       where id = r.id;
      perform catalog.log_change(r.id, r.ref, r.version + 1, 'owners', p_actor_type, p_actor,
        jsonb_build_object('effectiveOwners',
          jsonb_build_object('from', to_jsonb(r.effective_owners), 'to', to_jsonb(v_new))),
        p_reason);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- -----------------------------------------------------------------------------
-- Flattened membership. The catalog keeps groups nested exactly as the
-- identity provider asserts them; these projections are the query path's copy
-- of what OpenFGA computes, rebuilt whenever membership-bearing links change.
-- -----------------------------------------------------------------------------
create view authz.group_user as
  with recursive closure (group_id, member_id) as (
    select l.from_id, l.to_id
      from catalog.link l
      join catalog.resource g on g.id = l.from_id and g.kind = 'identity_group' and g.deleted_at is null
      join catalog.resource m on m.id = l.to_id and m.deleted_at is null
     where l.name = 'members' and l.applied
    union
    select c.group_id, l.to_id
      from closure c
      join catalog.link l     on l.from_id = c.member_id and l.name = 'members' and l.applied
      join catalog.resource m on m.id = l.to_id and m.deleted_at is null
  )
  select distinct g.ref as group_ref, u.ref as user_ref
    from closure c
    join catalog.resource g on g.id = c.group_id
    join catalog.resource u on u.id = c.member_id and u.kind = 'user';

-- Access grants are links too: platform admins and auditors, and kind-wide
-- editors. This view names them in the relation vocabulary of the OpenFGA model.
create view authz.access_grant as
  select case l.name when 'admins' then 'admin' when 'auditors' then 'auditor' else 'editor' end as relation,
         o.ref        as object_ref,
         o.kind       as object_kind,
         o.identifier as object_identifier,
         p.ref        as principal_ref,
         p.kind       as principal_kind
    from catalog.link l
    join catalog.resource o on o.id = l.from_id and o.deleted_at is null
    join catalog.resource p on p.id = l.to_id and p.deleted_at is null
   where l.applied
     and ((o.kind = 'platform' and l.name in ('admins', 'auditors'))
          or (o.kind = 'kind' and l.name = 'editors'));

-- No temporary tables: each statement materialises the group closure in a CTE.
-- (A temp table would belong to whichever role created it first in the
-- transaction, and creating one per write churns the system catalog.)
create function authz.refresh_memberships() returns void
language plpgsql as $$
begin
  delete from authz.user_team;
  insert into authz.user_team (user_ref, team_ref)
  with gu as materialized (select * from authz.group_user)
  select distinct gu.user_ref, t.ref
    from catalog.resource t
    join catalog.link l     on l.from_id = t.id and l.name = 'backedBy' and l.applied
    join catalog.resource g on g.id = l.to_id and g.deleted_at is null
    join gu                 on gu.group_ref = g.ref
   where t.kind = 'team' and t.deleted_at is null;

  -- platform --admins/auditors--> user | identity_group
  delete from authz.user_role;
  insert into authz.user_role (user_ref, role)
  with gu as materialized (select * from authz.group_user)
  select distinct u.user_ref, ag.relation
    from authz.access_grant ag
    cross join lateral (
      select ag.principal_ref as user_ref where ag.principal_kind = 'user'
      union
      select gu.user_ref from gu where gu.group_ref = ag.principal_ref
    ) u
   where ag.object_kind = 'platform';

  -- kind --editors--> team | identity_group
  delete from authz.user_kind_grant;
  insert into authz.user_kind_grant (user_ref, kind_id, relation)
  with gu as materialized (select * from authz.group_user)
  select distinct u.user_ref, ag.object_identifier, ag.relation
    from authz.access_grant ag
    cross join lateral (
      select ut.user_ref from authz.user_team ut where ut.team_ref = ag.principal_ref
      union
      select gu.user_ref from gu where gu.group_ref = ag.principal_ref
    ) u
   where ag.object_kind = 'kind';
end $$;

reset role;
