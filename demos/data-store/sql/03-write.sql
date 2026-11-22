-- =============================================================================
-- 03-write.sql — the write path. Every fact enters through these functions,
-- so validation, merging, ownership recompute and the change log happen in
-- the same transaction as the write.
--
-- Changing the schema? Update demos/data-store/index.html (the schema page)
-- and docs/data-store/reference.md in the same change. ./demo.sh test fails
-- while the page and the database disagree.
-- =============================================================================

set role catalog_owner;

create function catalog.log_change(
  p_resource_id bigint, p_ref text, p_version bigint, p_op text,
  p_actor_type catalog.actor_type, p_actor text, p_diff jsonb, p_reason text)
returns void
language plpgsql as $$
begin
  insert into catalog.change_log (resource_id, resource_ref, version, op, actor_type, actor, diff, reason)
  values (p_resource_id, p_ref, p_version, p_op, p_actor_type, p_actor, p_diff, p_reason);
  perform pg_notify('catalog_changes', p_ref);   -- wakes consumers; they still read via poll_changes
end $$;

-- -----------------------------------------------------------------------------
-- ingest: the one upsert used by every source, including `manual` (API edits
-- on behalf of a user) and the git reconciler.
--
--   p_properties  patch: keys present replace this source's observation,
--                 null values remove it
--   p_links       { linkName: ref | [ref, ...] | null } — for each name given,
--                 this source's assertions become exactly that set; names not
--                 given are left alone
-- -----------------------------------------------------------------------------
create function catalog.ingest(
  p_source      text,
  p_kind        text,
  p_identifier  text,
  p_title       text    default null,
  p_properties  jsonb   default '{}',
  p_links       jsonb   default '{}',
  p_external_id text    default null,
  p_run_id      bigint  default null,
  p_actor_type  catalog.actor_type default 'source',
  p_actor       text    default null,
  p_reason      text    default null)
returns bigint
language plpgsql as $$
declare
  v_src        catalog.source;
  v_kind       catalog.kind;
  v_res        catalog.resource;
  v_lt         catalog.link_type;
  v_actor      text := coalesce(p_actor, p_source);
  v_op         text;
  v_key        text;
  v_name       text;
  v_val        jsonb;
  v_targets    text[];
  v_old        text[];
  v_prev_run   bigint;
  v_merged     jsonb;
  v_prov       jsonb;
  v_diff       jsonb := '{}';
  v_links_diff jsonb := '{}';
  v_owners_dirty     boolean := false;
  v_membership_dirty boolean := false;
  v_ph         record;
  v_ph_id      bigint;
begin
  select * into v_src from catalog.source where id = p_source;
  if not found then
    raise exception 'unknown source %', p_source;
  end if;
  if not (p_kind = any (v_src.writes_kinds) or '*' = any (v_src.writes_kinds)) then
    raise exception 'source % may not write kind %', p_source, p_kind using errcode = '42501';
  end if;
  select * into v_kind from catalog.kind where id = p_kind;
  if not found then
    raise exception 'unknown kind %', p_kind;
  end if;

  -- Identity resolution: 1. exact identifier, 2. the kind's identity keys,
  -- 3. a new resource.
  select * into v_res from catalog.resource
   where kind = p_kind and identifier = p_identifier for update;
  if v_res.id is null then
    foreach v_key in array v_kind.identity_keys loop
      continue when p_properties -> v_key is null;
      select * into v_res from catalog.resource
       where kind = p_kind and deleted_at is null
         and properties @> jsonb_build_object(v_key, p_properties -> v_key)
       limit 1 for update;
      exit when v_res.id is not null;
    end loop;
  end if;

  if v_res.id is null then
    insert into catalog.resource (kind, identifier, title)
    values (p_kind, p_identifier, coalesce(p_title, p_identifier))
    returning * into v_res;
    v_op := 'create';
  elsif v_res.deleted_at is not null then
    update catalog.resource set deleted_at = null where id = v_res.id returning * into v_res;
    v_op := 'restore';
  else
    v_op := 'update';
  end if;

  -- Provenance: this source has seen the resource now.
  select last_run_id into v_prev_run
    from catalog.resource_source where resource_id = v_res.id and source_id = p_source;
  insert into catalog.resource_source as rs (resource_id, source_id, external_id, observed, last_run_id)
  values (v_res.id, p_source, p_external_id, jsonb_strip_nulls(coalesce(p_properties, '{}')), p_run_id)
  on conflict (resource_id, source_id) do update
     set observed     = jsonb_strip_nulls(rs.observed || coalesce(p_properties, '{}')),
         external_id  = coalesce(excluded.external_id, rs.external_id),
         last_seen_at = now(),
         last_run_id  = coalesce(excluded.last_run_id, rs.last_run_id),
         stale_since  = null;
  if p_run_id is not null and v_prev_run is distinct from p_run_id then
    update catalog.ingestion_run set resources_seen = resources_seen + 1
     where id = p_run_id and status = 'running';
  end if;

  -- Merge properties across sources.
  select m.properties, m.provenance into v_merged, v_prov from catalog.merge_properties(v_res.id) m;
  if v_merged is distinct from v_res.properties then
    v_diff := v_diff || jsonb_build_object('properties', catalog.jsonb_diff(v_res.properties, v_merged));
  end if;
  if p_title is not null and p_title <> v_res.title then
    v_diff := v_diff || jsonb_build_object('title', jsonb_build_object('from', v_res.title, 'to', p_title));
  end if;
  if v_res.unmatched then
    v_diff := v_diff || jsonb_build_object('unmatched', jsonb_build_object('from', true, 'to', false));
  end if;

  -- Links: replace this source's assertions for each link name given.
  for v_name, v_val in select key, value from jsonb_each(coalesce(p_links, '{}')) loop
    select * into v_lt from catalog.link_type where kind_id = p_kind and name = v_name;
    if not found then
      raise exception 'kind % declares no link %', p_kind, v_name using errcode = '23514';
    end if;
    v_targets := case jsonb_typeof(v_val)
                   when 'array'  then array(select distinct jsonb_array_elements_text(v_val))
                   when 'string' then array[v_val #>> '{}']
                   else '{}' end;
    if not v_lt.many and cardinality(v_targets) > 1 then
      raise exception 'link %.% is single-valued, got %', p_kind, v_name, v_targets using errcode = '23514';
    end if;

    select coalesce(array_agg(to_ref order by to_ref), '{}') into v_old
      from catalog.link where from_id = v_res.id and name = v_name and source_id = p_source;
    delete from catalog.link
     where from_id = v_res.id and name = v_name and source_id = p_source
       and not to_ref = any (v_targets);
    insert into catalog.link (from_id, name, to_ref, source_id)
    select v_res.id, v_name, t, p_source from unnest(v_targets) t
    on conflict (from_id, name, to_ref, source_id) do update set last_seen_at = now();
    if not v_lt.many then
      perform catalog.apply_single_link(v_res.id, v_name);
    end if;

    if not (v_old @> v_targets and v_targets @> v_old) then
      v_links_diff := v_links_diff || jsonb_build_object(v_name, jsonb_build_object(
        'added',   to_jsonb(array(select unnest(v_targets) except select unnest(v_old))),
        'removed', to_jsonb(array(select unnest(v_old) except select unnest(v_targets)))));
      v_owners_dirty := v_owners_dirty or v_lt.ownership is not null;
      v_membership_dirty := v_membership_dirty
        or (p_kind, v_name) in (('identity_group', 'members'), ('team', 'backedBy'));
    end if;
  end loop;
  if v_links_diff <> '{}' then
    v_diff := v_diff || jsonb_build_object('links', v_links_diff);
  end if;

  -- Placeholders: a link to a missing resource of a materialise_on_reference
  -- kind (e.g. system) creates it, flagged unmatched until a source claims it.
  for v_ph in
    select distinct l.to_ref, split_part(l.to_ref, ':', 1) as kind,
           substr(l.to_ref, strpos(l.to_ref, ':') + 1) as identifier
      from catalog.link l
      join catalog.kind k on k.id = split_part(l.to_ref, ':', 1) and k.materialise_on_reference
     where l.from_id = v_res.id and l.to_id is null
  loop
    insert into catalog.resource (kind, identifier, title, unmatched)
    values (v_ph.kind, v_ph.identifier, v_ph.identifier, true)
    returning id into v_ph_id;
    perform catalog.log_change(v_ph_id, v_ph.to_ref, 1, 'create', 'system', 'dangling-edge-resolution',
              jsonb_build_object('unmatched', jsonb_build_object('from', null, 'to', true)),
              format('first referenced by %s', v_res.ref));
  end loop;

  if v_op <> 'update' or v_diff <> '{}' then
    update catalog.resource
       set title               = coalesce(p_title, title),
           properties          = v_merged,
           property_provenance = v_prov,
           unmatched           = false,
           version             = case when v_op = 'create' then 1 else version + 1 end,
           updated_at          = now()
     where id = v_res.id
    returning * into v_res;
    perform catalog.log_change(v_res.id, v_res.ref, v_res.version, v_op,
              p_actor_type, v_actor, v_diff, p_reason);
  end if;

  if v_owners_dirty or v_op <> 'update' then
    perform catalog.recompute_owners(v_res.id, p_actor_type, v_actor, coalesce(p_reason, 'ownership path changed'));
  end if;
  if v_membership_dirty or (v_op = 'restore' and p_kind in ('user', 'identity_group', 'team')) then
    perform authz.refresh_memberships();
  end if;

  return v_res.id;
end $$;

-- -----------------------------------------------------------------------------
-- retract: a source says it no longer sees a resource (event-driven deletion,
-- or the sweep on its behalf). The source's observation and link assertions go;
-- when no source has the resource any more it is tombstoned.
-- -----------------------------------------------------------------------------
create function catalog.retract(
  p_source text, p_ref text,
  p_actor_type catalog.actor_type default 'source', p_actor text default null, p_reason text default null)
returns boolean
language plpgsql as $$
declare
  v_res    catalog.resource;
  v_actor  text := coalesce(p_actor, p_source);
  v_merged jsonb;
  v_prov   jsonb;
  v_link   record;
begin
  select * into v_res from catalog.resource where ref = p_ref and deleted_at is null for update;
  if not found then
    return false;
  end if;

  delete from catalog.resource_source where resource_id = v_res.id and source_id = p_source;
  for v_link in
    delete from catalog.link where from_id = v_res.id and source_id = p_source returning name
  loop
    perform catalog.apply_single_link(v_res.id, v_link.name);
  end loop;

  if exists (select 1 from catalog.resource_source where resource_id = v_res.id) then
    select m.properties, m.provenance into v_merged, v_prov from catalog.merge_properties(v_res.id) m;
    update catalog.resource
       set properties = v_merged, property_provenance = v_prov, version = version + 1, updated_at = now()
     where id = v_res.id;
    perform catalog.log_change(v_res.id, v_res.ref, v_res.version + 1, 'update', p_actor_type, v_actor,
      jsonb_build_object('properties', catalog.jsonb_diff(v_res.properties, v_merged),
                         'retractedBy', p_source), p_reason);
  else
    update catalog.resource
       set deleted_at = now(), effective_owners = '{}', version = version + 1, updated_at = now()
     where id = v_res.id;
    perform catalog.log_change(v_res.id, v_res.ref, v_res.version + 1, 'delete', p_actor_type, v_actor,
      jsonb_build_object('tombstoned', true), p_reason);
  end if;

  perform catalog.recompute_owners(v_res.id, p_actor_type, v_actor, coalesce(p_reason, format('%s retracted', p_ref)));
  if v_res.kind in ('user', 'identity_group', 'team') then
    perform authz.refresh_memberships();
  end if;
  return true;
end $$;

-- -----------------------------------------------------------------------------
-- Full-sync runs: mark-and-sweep with a guard against mass deletion.
-- -----------------------------------------------------------------------------
create function catalog.start_run(p_source text, p_mode text default 'full') returns bigint
language sql as $$
  insert into catalog.ingestion_run (source_id, mode, baseline)
  values (p_source, p_mode,
          (select resources_seen from catalog.ingestion_run
            where source_id = p_source and mode = 'full' and status = 'completed'
            order by started_at desc, id desc limit 1))
  returning id;
$$;

create function catalog.mark_stale(p_run catalog.ingestion_run) returns int
language sql as $$
  with marked as (
    update catalog.resource_source
       set stale_since = now()
     where source_id = p_run.source_id
       and stale_since is null
       and last_run_id is distinct from p_run.id
    returning 1)
  select count(*)::int from marked;
$$;

create function catalog.finish_run(p_run_id bigint) returns catalog.run_status
language plpgsql as $$
declare
  v_run catalog.ingestion_run;
  v_src catalog.source;
  v_marked int;
begin
  select * into v_run from catalog.ingestion_run where id = p_run_id and status = 'running' for update;
  if not found then
    raise exception 'run % is not running', p_run_id;
  end if;
  select * into v_src from catalog.source where id = v_run.source_id;

  if v_run.mode = 'full' and v_run.baseline > 0
     and v_run.resources_seen < v_run.baseline * (1 - v_src.full_sync_drop_threshold) then
    update catalog.ingestion_run
       set status = 'held', finished_at = now(),
           note = format('saw %s of the %s resources the last completed full run saw (drop over %s%%): held for review, nothing marked stale',
                         v_run.resources_seen, v_run.baseline, round(v_src.full_sync_drop_threshold * 100))
     where id = p_run_id;
    return 'held';
  end if;

  v_marked := case when v_run.mode = 'full' then catalog.mark_stale(v_run) else 0 end;
  update catalog.ingestion_run
     set status = 'completed', finished_at = now(),
         note = case when v_run.mode = 'full' then format('%s resources marked stale', v_marked) end
   where id = p_run_id;
  return 'completed';
end $$;

-- A held run that a human has confirmed is genuine.
create function catalog.release_run(p_run_id bigint, p_actor text) returns int
language plpgsql as $$
declare
  v_run catalog.ingestion_run;
  v_marked int;
begin
  select * into v_run from catalog.ingestion_run where id = p_run_id and status = 'held' for update;
  if not found then
    raise exception 'run % is not held', p_run_id;
  end if;
  v_marked := catalog.mark_stale(v_run);
  update catalog.ingestion_run
     set status = 'completed',
         note = note || format('; released by %s, %s resources marked stale', p_actor, v_marked)
   where id = p_run_id;
  return v_marked;
end $$;

-- Tombstone resources that every source has considered stale for longer than
-- the kind's stale_after window. p_as_of lets the demo fast-forward time.
create function catalog.sweep(p_as_of timestamptz default now()) returns int
language plpgsql as $$
declare
  r record;
  n int := 0;
begin
  for r in
    select res.ref, array_agg(rs.source_id) as sources
      from catalog.resource res
      join catalog.kind k on k.id = res.kind
      join catalog.resource_source rs on rs.resource_id = res.id
     where res.deleted_at is null
     group by res.ref, k.stale_after
    having bool_and(rs.stale_since is not null)
       and max(rs.stale_since) < p_as_of - k.stale_after
  loop
    perform catalog.retract(s, r.ref, 'system', 'sweep', 'not seen by any source within stale_after')
       from unnest(r.sources) s;
    n := n + 1;
  end loop;
  return n;
end $$;

-- -----------------------------------------------------------------------------
-- Outbox consumers. A row is handed out only once every transaction that
-- could still commit a lower tx_id has finished, so a slow writer can never
-- slip a change in behind a consumer's offset.
-- -----------------------------------------------------------------------------
create function catalog.poll_changes(p_consumer text, p_limit int default 100)
returns setof catalog.change_log
language sql stable as $$
  select c.*
    from catalog.change_log c
    join catalog.consumer k on k.name = p_consumer
   where (c.tx_id, c.id) > (k.last_tx, k.last_id)
     and c.tx_id < pg_snapshot_xmin(pg_current_snapshot())
   order by c.tx_id, c.id
   limit p_limit;
$$;

create function catalog.ack_changes(p_consumer text, p_tx xid8, p_id bigint) returns void
language sql as $$
  update catalog.consumer set last_tx = p_tx, last_id = p_id
   where name = p_consumer and (last_tx, last_id) < (p_tx, p_id);
$$;

-- -----------------------------------------------------------------------------
-- Platform configuration (git-owned). A kind and a source are each also a
-- resource, so schema and mapping changes appear in the change log too.
-- -----------------------------------------------------------------------------
create function catalog.define_kind(p_doc jsonb, p_actor text default 'git') returns void
language plpgsql as $$
declare
  v_id text := p_doc ->> 'identifier';
  v_link record;
begin
  insert into catalog.kind (id, title, description, property_schema, sensitive_properties, visibility,
                            identity_keys, materialise_on_reference, stale_after, built_in)
  values (v_id, p_doc ->> 'title', p_doc ->> 'description', coalesce(p_doc -> 'schema', '{}'),
          array(select jsonb_array_elements_text(coalesce(p_doc -> 'sensitive', '[]'))),
          coalesce(p_doc ->> 'visibility', 'owner')::catalog.visibility,
          array(select jsonb_array_elements_text(coalesce(p_doc #> '{identity,keys}', '[]'))),
          coalesce((p_doc ->> 'materialiseOnReference')::boolean, false),
          coalesce((p_doc ->> 'staleAfter')::interval, '7 days'),
          coalesce((p_doc ->> 'builtIn')::boolean, false))
  on conflict (id) do update
     set title = excluded.title, description = excluded.description,
         property_schema = excluded.property_schema, sensitive_properties = excluded.sensitive_properties,
         visibility = excluded.visibility, identity_keys = excluded.identity_keys,
         materialise_on_reference = excluded.materialise_on_reference,
         stale_after = excluded.stale_after, updated_at = now();

  delete from catalog.link_type
   where kind_id = v_id and not name in (select jsonb_object_keys(coalesce(p_doc -> 'links', '{}')));
  for v_link in select key, value from jsonb_each(coalesce(p_doc -> 'links', '{}')) loop
    insert into catalog.link_type (kind_id, name, target_kinds, many, required, ownership)
    values (v_id, v_link.key,
            case jsonb_typeof(v_link.value -> 'target')
              when 'array' then array(select jsonb_array_elements_text(v_link.value -> 'target'))
              else array[v_link.value ->> 'target'] end,
            coalesce((v_link.value ->> 'many')::boolean, false),
            coalesce((v_link.value ->> 'required')::boolean, false),
            (v_link.value ->> 'ownership')::catalog.link_ownership)
    on conflict (kind_id, name) do update
       set target_kinds = excluded.target_kinds, many = excluded.many,
           required = excluded.required, ownership = excluded.ownership;
  end loop;

  perform catalog.ingest('manual', 'kind', v_id, p_doc ->> 'title', jsonb_build_object('definition', p_doc),
                         p_actor_type => 'system', p_actor => p_actor);
end $$;

create function catalog.define_source(p_doc jsonb, p_actor text default 'git') returns void
language plpgsql as $$
declare
  v_id text := p_doc ->> 'identifier';
  v_kind text;
  v_prop text;
begin
  insert into catalog.source (id, connector, config, mapping, writes_kinds, full_sync_drop_threshold, freshness_slo)
  values (v_id, p_doc ->> 'connector', coalesce(p_doc -> 'config', '{}'), coalesce(p_doc -> 'mapping', '[]'),
          array(select jsonb_array_elements_text(coalesce(p_doc #> '{writes,kinds}', '[]'))),
          coalesce((p_doc ->> 'fullSyncDropThreshold')::numeric, 0.20),
          (p_doc ->> 'freshnessSlo')::interval)
  on conflict (id) do update
     set connector = excluded.connector, config = excluded.config, mapping = excluded.mapping,
         writes_kinds = excluded.writes_kinds, full_sync_drop_threshold = excluded.full_sync_drop_threshold,
         freshness_slo = excluded.freshness_slo;

  delete from catalog.property_claim where source_id = v_id;
  for v_kind in select jsonb_object_keys(coalesce(p_doc #> '{writes,ownsProperties}', '{}')) loop
    for v_prop in select jsonb_array_elements_text(p_doc #> array['writes', 'ownsProperties', v_kind]) loop
      insert into catalog.property_claim (source_id, kind_id, property, priority)
      values (v_id, v_kind, v_prop, coalesce((p_doc #>> array['writes', 'priority', v_kind])::int, 100));
    end loop;
  end loop;

  if exists (select 1 from catalog.kind where id = 'source') then
    perform catalog.ingest('manual', 'source', v_id, v_id, jsonb_build_object('definition', p_doc),
                           p_actor_type => 'system', p_actor => p_actor);
  end if;
end $$;

reset role;
