-- =============================================================================
-- 01-schema.sql — tables, types and indexes of the catalog data store.
--
-- Three schemas, one per kind of thing they hold:
--   catalog  the facts: kinds, resources, links, provenance, the change log
--   authz    access projections derived from the facts (never written by hand
--            except platform/kind grants)
--   api      the only surface the catalog service's read role can touch
--
-- Spec: docs/data-store/reference.md. Rationale: docs/data-store/explanation.md.
--
-- Changing the schema? Update demos/data-store/index.html (the schema page)
-- and docs/data-store/reference.md in the same change. ./demo.sh test fails
-- while the page and the database disagree.
-- =============================================================================


create schema catalog;
create schema authz;
create schema api;

create type catalog.visibility     as enum ('owner', 'org');
create type catalog.link_ownership as enum ('grants', 'inherits');
create type catalog.actor_type     as enum ('user', 'source', 'system');
create type catalog.run_status     as enum ('running', 'completed', 'held', 'failed');

-- -----------------------------------------------------------------------------
-- Kinds: schema as data. A kind is also a resource of kind `kind` (created by
-- catalog.define_kind), so schema changes share the audit and API path. These
-- two tables are its typed projection, which the write path validates against.
-- -----------------------------------------------------------------------------
create table catalog.kind (
  id                       text primary key check (id ~ '^[a-z][a-z0-9_]*$'),
  major_version            int  not null default 1,
  title                    text not null,
  description              text,
  property_schema          jsonb not null default '{}',   -- JSON Schema, validated by the API layer
  sensitive_properties     text[] not null default '{}',  -- redacted unless the viewer passes can_view
  visibility               catalog.visibility not null default 'owner',
  identity_keys            text[] not null default '{}',  -- identity resolution rule 2
  materialise_on_reference boolean not null default false, -- create a placeholder when a link points at a missing resource
  stale_after              interval not null default '7 days',
  built_in                 boolean not null default false,
  updated_at               timestamptz not null default now()
);

create table catalog.link_type (
  kind_id      text not null references catalog.kind on delete cascade,
  name         text not null check (name ~ '^[a-z][a-zA-Z0-9]*$'),
  target_kinds text[] not null check (cardinality(target_kinds) > 0),
  many         boolean not null default false,
  required     boolean not null default false,
  ownership    catalog.link_ownership,          -- null: the link plays no part in ownership
  privileged   boolean not null default false,  -- changing it changes who can access what
  primary key (kind_id, name)
);
-- At most one link per kind may define the owner.
create unique index link_type_one_grant on catalog.link_type (kind_id) where ownership = 'grants';

-- -----------------------------------------------------------------------------
-- Sources: an ingestion connector plus its mapping, and what it may write.
-- -----------------------------------------------------------------------------
create table catalog.source (
  id                       text primary key check (id ~ '^[a-z][a-z0-9-]*$'),
  connector                text not null,
  config                   jsonb not null default '{}',
  mapping                  jsonb not null default '[]',  -- executed by the connector, stored here so it is data
  writes_kinds             text[] not null default '{}',
  full_sync_drop_threshold numeric not null default 0.20 check (full_sync_drop_threshold between 0 and 1),
  freshness_slo            interval                     -- e.g. the identity provider's membership SLO
);

-- Which source owns which property of which kind. Lower priority wins when two
-- sources claim the same property; the loser's value stays in
-- resource_source.observed but is not applied. The `manual` source owns any
-- property nobody claims.
create table catalog.property_claim (
  source_id text not null references catalog.source on delete cascade,
  kind_id   text not null references catalog.kind on delete cascade,
  property  text not null,
  priority  int  not null default 100,
  primary key (source_id, kind_id, property)
);

create table catalog.ingestion_run (
  id             bigint generated always as identity primary key,
  source_id      text not null references catalog.source,
  mode           text not null check (mode in ('full', 'delta')),
  status         catalog.run_status not null default 'running',
  started_at     timestamptz not null default now(),
  finished_at    timestamptz,
  resources_seen int not null default 0,
  baseline       int,           -- resources_seen of the last completed full run
  note           text
);
create index ingestion_run_source on catalog.ingestion_run (source_id, started_at desc);

-- -----------------------------------------------------------------------------
-- Resources. `properties` is the merged view (one winning value per property);
-- the raw per-source input is resource_source.observed.
-- -----------------------------------------------------------------------------
create table catalog.resource (
  id                  bigint generated always as identity primary key,
  kind                text not null references catalog.kind,
  identifier          text not null check (identifier <> ''),
  ref                 text generated always as (kind || ':' || identifier) stored,
  title               text not null,
  properties          jsonb not null default '{}',
  property_provenance jsonb not null default '{}',     -- property -> source whose value was applied
  effective_owners    text[] not null default '{}',    -- team refs; written only by the ownership resolver
  version             bigint not null default 1,
  unmatched           boolean not null default false,  -- placeholder nobody has claimed yet
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,                     -- tombstone: hidden, restorable
  search              tsvector generated always as (
                        to_tsvector('simple', translate(identifier || ' ' || title, '/@.', '   '))) stored,
  unique (kind, identifier),
  unique (ref)
);
create index resource_kind_live   on catalog.resource (kind) where deleted_at is null;
create index resource_properties  on catalog.resource using gin (properties jsonb_path_ops);
create index resource_owners      on catalog.resource using gin (effective_owners);
create index resource_search      on catalog.resource using gin (search);
create index resource_updated     on catalog.resource (updated_at);
create index resource_unowned     on catalog.resource (kind)
  where deleted_at is null and effective_owners = '{}';

-- Provenance and freshness, one row per (resource, source that has seen it).
create table catalog.resource_source (
  resource_id   bigint not null references catalog.resource on delete cascade,
  source_id     text   not null references catalog.source,
  external_id   text,
  observed      jsonb  not null default '{}',   -- last properties this source reported, applied or not
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  last_run_id   bigint references catalog.ingestion_run,
  stale_since   timestamptz,                    -- set by mark-and-sweep when a full run missed it
  primary key (resource_id, source_id)
);
create index resource_source_sweep on catalog.resource_source (source_id, last_run_id);

-- -----------------------------------------------------------------------------
-- Links: typed, directed edges, one row per (edge, asserting source). An edge
-- exists while at least one source asserts it. to_id is null while the target
-- does not exist (dangling) and is filled in when it appears.
-- -----------------------------------------------------------------------------
create table catalog.link (
  id           bigint generated always as identity primary key,
  from_id      bigint not null references catalog.resource on delete cascade,
  name         text   not null,
  to_ref       text   not null check (to_ref ~ '^[a-z][a-z0-9_]*:.+$'),
  to_id        bigint references catalog.resource on delete set null,
  source_id    text   not null references catalog.source,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (from_id, name, to_ref, source_id)
);
create index link_reverse  on catalog.link (to_id, name);
create index link_dangling on catalog.link (to_ref) where to_id is null;

-- -----------------------------------------------------------------------------
-- Change log: immutable, partitioned by month, doubling as the outbox.
-- tx_id lets consumers read without missing rows from slow transactions
-- (see catalog.poll_changes).
-- -----------------------------------------------------------------------------
create table catalog.change_log (
  id           bigint generated always as identity,
  tx_id        xid8 not null default pg_current_xact_id(),
  occurred_at  timestamptz not null default now(),
  resource_id  bigint,          -- no FK: the log outlives hard deletes
  resource_ref text not null,
  version      bigint,
  op           text not null check (op in ('create', 'update', 'delete', 'restore', 'owners')),
  actor_type   catalog.actor_type not null,
  actor        text not null,
  diff         jsonb not null,
  reason       text,
  primary key (id, occurred_at)
) partition by range (occurred_at);
create index change_log_resource on catalog.change_log (resource_id, occurred_at);
create index change_log_tx       on catalog.change_log (tx_id, id);

-- One partition per month. In production pg_partman (or a cron job calling
-- this function) keeps a few months ahead; the default partition catches the rest.
create function catalog.ensure_change_log_partition(p_month date) returns text
language plpgsql as $$
declare
  lo date := date_trunc('month', p_month);
  name text := format('change_log_%s', to_char(lo, 'YYYY_MM'));
begin
  execute format(
    'create table if not exists catalog.%I partition of catalog.change_log for values from (%L) to (%L)',
    name, lo, (lo + interval '1 month')::date);
  return name;
end $$;

select catalog.ensure_change_log_partition((date_trunc('month', now()) + make_interval(months => m))::date)
from generate_series(-1, 2) m;
create table catalog.change_log_default partition of catalog.change_log default;

create function catalog.change_log_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'catalog.change_log is append-only (% refused)', tg_op;
end $$;
create trigger change_log_append_only before update or delete on catalog.change_log
  for each row execute function catalog.change_log_immutable();

-- Consumer offsets for the outbox: the OpenFGA tuple sync, scorecard
-- evaluation, the search indexer, the Kafka relay if there is one.
create table catalog.consumer (
  name    text primary key,
  last_tx xid8   not null default '0',
  last_id bigint not null default 0
);

-- -----------------------------------------------------------------------------
-- authz: access projections derived from the graph, written only by
-- authz.refresh_memberships. They hold no facts. Who belongs to what, and who
-- administers what, are links between ordinary resources:
--   identity_group --members-->  user | identity_group
--   team           --backedBy--> identity_group
--   platform       --admins / auditors--> user | identity_group
--   kind           --editors-->  team | identity_group
-- These tables are a cache of what OpenFGA computes from the same links.
-- -----------------------------------------------------------------------------

-- Derived: flattened membership, the query-path twin of OpenFGA's evaluation.
create table authz.user_team (
  user_ref text not null,
  team_ref text not null,
  primary key (user_ref, team_ref)
);
create index user_team_team on authz.user_team (team_ref);

create table authz.user_role (
  user_ref text not null,
  role     text not null,
  primary key (user_ref, role)
);

create table authz.user_kind_grant (
  user_ref text not null,
  kind_id  text not null,
  relation text not null,
  primary key (user_ref, kind_id, relation)
);

-- -----------------------------------------------------------------------------
-- Derived data: scorecard results (current + history). Rules are evaluated by
-- the scorecard consumer in the expression language; the store only keeps results.
-- -----------------------------------------------------------------------------
create table catalog.scorecard_result (
  resource_id  bigint not null references catalog.resource on delete cascade,
  scorecard    text   not null,          -- identifier of the scorecard resource
  level        text,                     -- null: no level reached
  rules        jsonb  not null,          -- { rule-id: { pass: bool, detail } }
  evaluated_at timestamptz not null default now(),
  primary key (resource_id, scorecard)
);

create table catalog.scorecard_history (
  resource_id  bigint not null,
  scorecard    text   not null,
  level        text,
  rules        jsonb  not null,
  evaluated_at timestamptz not null
) partition by range (evaluated_at);
create table catalog.scorecard_history_default partition of catalog.scorecard_history default;
create index scorecard_history_lookup on catalog.scorecard_history (scorecard, evaluated_at);

