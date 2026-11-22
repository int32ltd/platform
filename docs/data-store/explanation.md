# Data store explanation

Why the catalog's PostgreSQL schema is shaped the way it is. For the exact
tables, functions and roles, see [reference.md](./reference.md). For the
catalog design this implements, see
[`../service-catalog/explanation.md`](../service-catalog/explanation.md), which
already decided on "a Postgres-backed catalog service rather than DataHub"
and sketched the storage in one paragraph. This document is that paragraph
worked out.

Contents:

- [What the store has to do](#what-the-store-has-to-do)
- [One generic resource table, not a table per kind](#one-generic-resource-table-not-a-table-per-kind)
- [Observations and the merge are stored separately](#observations-and-the-merge-are-stored-separately)
- [Links: one row per edge per source](#links-one-row-per-edge-per-source)
- [Two identifiers: `id` inside, `ref` outside](#two-identifiers-id-inside-ref-outside)
- [Ownership is materialised, synchronously](#ownership-is-materialised-synchronously)
- [People and grants are resources and links](#people-and-grants-are-resources-and-links)
- [Membership is flattened, but only as a projection](#membership-is-flattened-but-only-as-a-projection)
- [Visibility lives in one view, not in row-level security](#visibility-lives-in-one-view-not-in-row-level-security)
- [The viewer is a session setting](#the-viewer-is-a-session-setting)
- [Writes go through functions](#writes-go-through-functions)
- [The change log is the outbox](#the-change-log-is-the-outbox)
- [Deletion is slow on purpose](#deletion-is-slow-on-purpose)
- [What the store does not do](#what-the-store-does-not-do)
- [Decisions and open questions](#decisions-and-open-questions)

---

## What the store has to do

The catalog design asks five things of its store:

1. **Kinds are data.** A new resource type or link is a config change, not a
   deploy, and certainly not a migration.
2. **Many sources, one resource.** HR, the identity provider, PagerDuty and
   git all describe the same team. Each owns some properties, and the store has
   to remember who said what.
3. **Ownership is inferred and access follows it.** The resolver is the only
   place ownership logic lives. OpenFGA and the query filter consume its output.
4. **Cheap, permission-filtered reads.** Agents and dashboards hit the catalog
   instead of the source systems, so every read is filtered and none of them
   fan out.
5. **Everything is auditable and streamable.** Every change is logged with
   actor, diff and reason, and consumers (OpenFGA sync, scorecards, search)
   react to it without polling.

At ~500k resources, ~5M links and ~10k changes per minute at peak, one Postgres
primary does all of this. Each section below covers one choice and what it
costs.

## One generic resource table, not a table per kind

Every resource, of every kind, is a row in `catalog.resource`, with its
properties in a `jsonb` column. Kinds are rows in `catalog.kind` and
`catalog.link_type`.

The alternative is a table per kind (`component`, `aws_rds_instance`, ...)
with typed columns. It gives real column types, `not null`, check constraints
and smaller indexes. It also makes every new kind a `create table` and every
new property an `alter table`, deployed through migrations. That contradicts
requirement 1, and it puts schema changes on a different path from the audited
catalog write that the design wants for them. The service catalog explanation
rejected DataHub for exactly this reason ("entity types are compiled in"), and
a table per kind would bring the same problem back in a different form.

What the generic table costs, and how each cost is paid:

| Cost | Mitigation |
|---|---|
| No column types or constraints on properties | The kind's JSON Schema is validated by the API layer on write. `pg_jsonschema` could move this into the database if a second write path ever appears. |
| One GIN index over every kind's properties | `jsonb_path_ops` handles containment (`@>`) queries well at this size. A hot property on a big kind gets a partial expression index: `create index on catalog.resource ((properties->>'tier')) where kind = 'component'`. That is a data-driven, additive change. |
| Queries are less self-describing | The GraphQL layer generates a typed schema per kind from `catalog.kind`, so typing comes back at the API. |

## Observations and the merge are stored separately

`catalog.resource_source.observed` holds what each source last reported,
whether or not it won. `catalog.resource.properties` is the merge, recomputed by
`catalog.merge_properties` on every write, and `property_provenance` records
the winner of each property.

Storing only the merged value would be smaller, but it loses information the
design needs. The catalog reference says the loser's value is "retained in
provenance but not applied". Without the raw observations, changing a claim
priority, or retracting a source, can only re-merge forward from what happens
to be stored. With them, the merged view can always be rebuilt from first
principles, and a "these two sources disagree" report is a plain query.

Each write is a patch of the writing source's observation (keys given are
replaced, `null` removes a key). The same call therefore works for a full
snapshot from a connector and for a single-field manual edit.

## Links: one row per edge per source

`catalog.link` has a row for every (edge, asserting source). The edge exists
while any source asserts it, which is the catalog's rule that "links are
unioned across sources". Retracting a source removes only that source's rows.

Two columns carry the harder rules:

- **`to_id` is nullable.** A link stores `to_ref` (the target reference) and
  `to_id` (the target row) once it exists. Ingestion order is not
  controllable, so a Kubernetes workload can name `component:fraud-scorer`
  before GitHub has delivered it. The row is stored dangling, contributes no
  owner, and a trigger attaches it when the component appears. The same
  column provides tombstones: a hard delete sets `to_id` back to null
  (`on delete set null`), so a re-created resource reattaches by `to_ref`. For
  kinds marked `materialise_on_reference` (`system`), a dangling link creates
  an `unmatched` placeholder instead, as the catalog design specifies.
- **`applied` resolves single-valued conflicts.** GitHub's catalog file says
  checkout-service is owned by Payments. A platform admin transfers it to
  Search. Both assertions are facts worth keeping. Exactly one is applied: a
  `manual` override wins, otherwise the earliest assertion does. The resolver,
  the membership projection and the API only follow applied rows. Removing the
  override restores the source's value with no extra bookkeeping. This is the
  link equivalent of property claims.

Graph traversals (ownership, dependents, agent context) are recursive CTEs
over this table, using the forward and reverse indexes. The depths involved
are 2 to 6 hops, which Postgres handles comfortably. The catalog reference
already said a graph database is "not justified until traversal patterns prove
otherwise", and nothing here changes that.

## Two identifiers: `id` inside, `ref` outside

Every resource has a `bigint` surrogate `id`, used by foreign keys and joins,
and a generated, unique `ref` (`component:checkout-service`), used by
everything outside the database: the API, OpenFGA tuples, `effective_owners`,
the change log, and links' `to_ref`.

`ref` is stable because the catalog makes `identifier` immutable. A rename in
the source system is a new identifier only if the mapping says so; otherwise
identity resolution matches it by `identity_keys`. `id` never leaves the
database, so internal renumbering (a restore from backup, a future sharding
scheme) cannot break a consumer.

## Ownership is materialised, synchronously

`effective_owners` is a `text[]` of team refs on every resource, with a GIN
index. It is written only by `catalog.recompute_owners`, which calls
`catalog.resolve_owners` (itself a thin layer over `catalog.owner_paths`, the
one implementation of the algorithm). The resolver runs **inside the write
transaction**: when a link that matters to ownership changes, the resource and
everything that inherits through it are recomputed before commit.

Why materialise: the visibility predicate runs on every read, against every
candidate row. `effective_owners && viewer_teams` against a GIN index is cheap.
Resolving ownership on the fly with a recursive walk per row is not.

Why synchronous rather than as a change-log consumer: the window in which
`effective_owners` is stale is a window in which access is wrong. A
transferred service would stay visible to its old team, and a newly tagged
queue would stay invisible to its new one. Doing it in the transaction makes
the window zero, and makes the log show the write and its ownership effect
together (`op = update` followed by `op = owners`).

The cost is write amplification. Changing a system's owner rewrites every
component in it and every workload, queue and database under those
components. At the stated scale that is thousands of rows at worst, in a rare,
privileged write, and fine in one transaction. If a deeper hierarchy ever
makes it slow, the same function moves behind the outbox as a consumer, and
`effective_owners` becomes eventually consistent with a measured lag. That
trade can be made later without changing the schema.

A team owns itself. Without that rule, a team's members would see their own
team's sensitive properties redacted, because a team has no `owner` link.

## People and grants are resources and links

The catalog's founding rule is that permissions are part of the map. So
there is no `users`, `groups`, `teams` or `grants` table. People and access
use the same two tables as everything else:

| Fact | Stored as |
|---|---|
| a person or service principal | resource of kind `user` |
| an identity provider group | resource of kind `identity_group` |
| a team | resource of kind `team` |
| group membership (nested) | `identity_group --members--> user \| identity_group` |
| which groups back a team | `team --backedBy--> identity_group` |
| platform admins and auditors | `platform:default --admins/auditors--> user \| identity_group` |
| kind-wide editors | `kind:<id> --editors--> team \| identity_group` |

That buys the same things for access that every other fact gets. A grant is
ingested from its source (or written through git as `manual`), shows up in
the change log with actor and reason, appears on the group's or team's
neighbourhood in `api.link` and `api.context`, and reaches OpenFGA through the
same tuple projection. "Who can administer the platform?" and "who can edit
RDS instances?" are graph queries, not lookups in a side table.

The `authz` schema holds no facts at all. Its tables are a cache derived from
these links (next section), and its views (`group_user`, `access_grant`,
`fga_tuples`) are read-only lenses over them.

These links are marked **privileged** on their link type. That has two
effects. A change to one rebuilds the access projections in the same
transaction. And changing one through the API needs `can_transfer`, exactly
like changing an owner. Without that rule, a team owns itself, so any member
could put another group behind their team (`backedBy`), and a kind editor of
`kind` could make themselves an editor of every kind.

## Membership is flattened, but only as a projection

The catalog keeps groups nested exactly as the identity provider asserts them,
as `members` links between `identity_group` and `user` resources. The catalog
reference says "flattening happens in the policy engine, not here", and as
far as the facts go, that holds.

The query path still needs "which teams is this user in" on every request.
Walking nested groups per request is exactly the cost the catalog exists to
avoid. So `authz.user_team` (and `user_role`, `user_kind_grant`) are projections,
rebuilt by `authz.refresh_memberships()` in the same transaction as any change
to a privileged link (`members`, `backedBy`, `admins`, `auditors`, `editors`).
They are the database's copy of what OpenFGA computes from the same tuples. They are never written by hand, and the nightly
consistency check, which evaluates the OpenFGA model over `authz.fga_tuples` and
compares it with `api.resource` for every user, catches any drift between the
two.

Doing this in-transaction means a removal in the identity provider stops
granting access as soon as the next delta sync commits. That keeps the
membership-freshness SLO a property of the connector's cadence, not of a
second asynchronous hop.

## Visibility lives in one view, not in row-level security

Postgres row-level security is the obvious tool. It was considered and not
used, for three reasons:

1. **The rule is not only about rows.** `org` kinds are listed to everyone
   with sensitive properties redacted. RLS can hide rows; it cannot redact a
   key inside a `jsonb` column. Redaction would need a view anyway, so the
   rule would live in two places: the RLS policy and the view.
2. **Superusers and table owners bypass RLS.** Making it hold for the write
   functions, the owner and maintenance jobs means `force row level security`
   and per-role exceptions. That is more mechanism to get right than the
   problem needs.
3. **Hidden things leak through joins.** Links, history, search hits and
   ownership paths must all respect the same rule. With RLS on every table,
   each policy must re-derive visibility of the rows it references.

Instead, the service role `catalog_api` has no privilege on any `catalog`
table. Everything it can read is an `api.*` view owned by `catalog_owner`,
and every view is built on `api.resource`, which holds the only copy of the
predicate:

```sql
where r.deleted_at is null
  and (r.effective_owners && viewer_teams or r.kind = any (readable_kinds))
```

`api.link` joins `api.resource` on both ends, `api.change` joins it and
redacts diffs, and `api.who_owns` masks path steps that fail it. The views are
`security_barrier`, so a caller's own `where` clause cannot run a leaky
function over rows the predicate would have removed. The viewer-derived sets
are computed once per query in a materialised CTE, not once per row.

## The viewer is a session setting

The catalog service connects as `catalog_api` and, per request, runs
`set local catalog.viewer = 'user:alice'`. Every `api` view reads it.

The alternative, a database role per end user, would mean ~100k roles synced
from the identity provider, plus connection pooling per role. The catalog
explanation already establishes that the catalog API is the single
enforcement point and the only caller of OpenFGA. End users and agents never
get a database connection. The setting carries the identity the API has
already authenticated, the same way it carries it to OpenFGA `Check`.

The trust boundary is therefore the `catalog_api` credential, not the setting.
Anything holding that credential can act as any user, exactly as anything
holding the API's OpenFGA credential can. A viewer that is not a live `user`
resource (unset, unknown, or offboarded and tombstoned) is nobody, and sees
nothing.

## Writes go through functions

No role but the owner can `insert` into a `catalog` table. Sources call
`catalog.ingest` and `catalog.retract`. Users write through `api.update`,
which checks `can_edit`, and `can_transfer` for ownership and access-granting
changes, then calls
`catalog.ingest` as the `manual` source with the user as actor. Platform
configuration arrives through `catalog.define_kind` and
`catalog.define_source`, from the git reconciler.

That is what makes the derived state trustworthy. Merging, link validation,
single-valued precedence, placeholder creation, ownership recompute,
membership refresh and the change log all happen in one transaction, on one
code path, whatever the writer. The few rules that must hold even against a
future second path are triggers: link validation, dangling attachment, and an
append-only change log.

A kind and a source are each also a resource (`kind:component`,
`source:aws-prod-4711`), written by `manual` as actor `git`. Schema and mapping
changes therefore appear in the same change log, with the same diff format, as
any other fact.

## The change log is the outbox

`catalog.change_log` is append-only, partitioned by month, and is at once:

- the **audit trail**: actor, diff, reason, version, per change;
- the **outbox**: consumers poll it through `catalog.poll_changes`, with
  offsets in `catalog.consumer`;
- the **history** users see through `api.change`, filtered and redacted.

This settles the catalog's open question 4 (Kafka or outbox) in favour of
not needing to decide now. The outbox is enough at the stated scale. If Kafka
is already run, a `kafka-relay` consumer publishes the log to the
`catalog.changes` topic, and nothing else changes.

The subtle part is reading an outbox by sequence number. Ids are assigned when
a row is inserted, not when its transaction commits. A consumer that reads
"everything after id 100" can miss id 99 if that transaction commits a moment
later. So each row records its `tx_id` (`pg_current_xact_id()`), consumers read
in `(tx_id, id)` order, and they read only rows with `tx_id` below the oldest
transaction still running (`pg_snapshot_xmin(pg_current_snapshot())`). Below
that line no new row can ever appear, so an offset never skips one. A
`pg_notify` on every insert lets consumers block on `LISTEN` instead of
polling on a timer.

Monthly partitions keep the active partition small and make retention a
`drop table`. Rows are never updated, so there is no bloat to vacuum.

## Deletion is slow on purpose

Nothing disappears in one step:

1. A source **retracts** a resource (an event-driven delete) or, for full-sync
   sources, a completed full run marks every resource it did not see as
   **stale**.
2. Only when **every** source considers a resource stale for longer than the
   kind's `stale_after` does the **sweep** tombstone it. A resource that
   GitHub stopped reporting but PagerDuty still pages on stays.
3. A tombstone is hidden from the API, keeps its history and links, and is
   **restored** by any source that sees it again. Hard deletion is a separate
   retention job.

A full run that sees far fewer resources than the last completed one (more
than 20% fewer, by default) is **held**: nothing is marked stale until a human
releases it. A revoked IAM permission or an expired token looks, to a naive
full sync, exactly like everything having been deleted. This guard turns
that into a held run and an alert instead of an empty catalog.

## What the store does not do

- **Evaluate expressions.** Mappings run in connectors; scorecard rules run in
  the scorecard consumer. The store holds their definitions (as resources) and
  their results (`scorecard_result`, `scorecard_history`). Whether the
  language is CEL or JQ (catalog open question 3) does not affect the schema.
- **Validate JSON Schema.** The API does, on write. See the table in
  [One generic resource table](#one-generic-resource-table-not-a-table-per-kind).
- **Talk to OpenFGA.** `authz.fga_tuples` says what the tuple set should be;
  the `openfga-sync` consumer writes the difference.
- **Execute actions.** An `action_run` is a resource, written through the
  ingestion API by the runner as a source, and it inherits ownership from its
  target.

## Decisions and open questions

Decided here:

- One `catalog.resource` table with `jsonb` properties for every kind; kinds
  and link types as rows.
- Per-source observations stored, merged view derived, provenance per property.
- Links stored per asserting source; dangling links kept and attached by
  trigger; single-valued conflicts resolved by `manual` first, then earliest.
- `effective_owners` and flattened membership materialised synchronously,
  inside the write transaction.
- Users, groups, teams and the platform are resources; membership and grants
  (admins, auditors, kind editors) are privileged links. `authz` holds only
  derived data.
- Visibility as one `security_barrier` view over tables the service role
  cannot read, not row-level security; viewer passed as a session setting.
- All writes through `security definer` functions; integrity rules that must
  survive a second write path as triggers.
- The change log doubles as the outbox, read by `(tx_id, id)` behind the
  snapshot horizon; Kafka is an optional relay.

Open, needing a decision:

1. **Source authentication at the database.** Today any role granted
   `catalog_ingest` may name any source. Binding each connector's login role to
   its source (a `db_role` column on `catalog.source`, checked against
   `session_user` in `catalog.ingest`) closes that gap. Recommended before more
   than one team operates connectors.
2. **Single-valued precedence beyond `manual`.** "Earliest assertion wins"
   is deterministic but arbitrary when two automated sources disagree (for
   example, CODEOWNERS and a portfolio tool both naming a component owner).
   Options: a per-kind link priority mirroring `property_claim.priority`, or
   treating the disagreement as a report and keeping earliest-wins.
   Recommendation: start with the report, and add priority only if a real
   conflict needs it.
3. **Incremental membership refresh.** `authz.refresh_memberships()` rebuilds
   the projections in full. That is fine for the demo and for thousands of
   users, but at 100k users with frequent delta syncs it should recompute only
   the teams reachable from the changed group.
4. **Synchronous ownership recompute limits.** As above: measure the largest
   subtree under a system. Move recompute behind the outbox only if a
   real transfer exceeds an agreed transaction budget.
5. **Users and groups have no owner.** `user` and `identity_group` resolve to
   unowned, which is correct (the identity provider owns them, and they are
   `org`-visible), but ownership-coverage reports must exclude them rather than
   count them as debt.
