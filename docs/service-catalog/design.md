# Service Catalog design

The catalog is the platform's **resource map**: a continuously refreshed store of
everything the organisation runs (services, repos, workloads, cloud resources,
teams, people, incidents, ...) and how those things relate. It is populated by
ingestion from many sources and is the thing agents, reports, scorecards and
self-service actions query — instead of hitting the live systems themselves.

It is the concrete implementation of Layer 3 ("Policy & Ownership Graph") in
[`../platform-abstraction/`](../platform-abstraction/README.md). This document
goes one level deeper: the data model, the permission model, how data gets in,
how it gets queried, and what is derived from it.

The one requirement that shapes everything else: **permissions are part of the
map.** An `ADGroup` is a resource like any other. Ownership is a link. Who
may see or act on a resource is *inferred from the graph* (resource → owning team
→ backing AD group → members), never configured per resource by hand.

Contents:

1. [Goals and non-goals](#1-goals-and-non-goals)
2. [Data model: kinds, resources, links](#2-data-model)
3. [Permission model](#3-permission-model)
4. [Ingestion](#4-ingestion)
5. [Query and agent access](#5-query-and-agent-access)
6. [Derived data: scorecards, reports, actions](#6-derived-data)
7. [Storage and components](#7-storage-and-components)
8. [Decisions and open questions](#8-decisions-and-open-questions)

---

## 1. Goals and non-goals

**Goals**

- One queryable map of resources and links, refreshed from many sources,
  with provenance and freshness on every fact.
- Schema defined as data ("kinds"), so a new resource type or link is a
  config change, not a deploy.
- Ownership inferred from links, and access derived from ownership plus
  AD group membership. No per-resource ACLs.
- Read path cheap enough that agents and dashboards hit the catalog, not the
  source systems.
- Every change auditable: who/what changed which fact, when, from which source.
- Derived views (scorecards, reports) and side effects (self-service actions)
  built on the same model and the same permission check.

**Non-goals**

- Being the source of truth for the source systems. GitHub owns repos, Entra ID
  owns groups, Kubernetes owns workloads. The catalog is a projection, with one
  exception: facts that have no other home (manual ownership overrides, tier,
  lifecycle, kind definitions themselves, action definitions).
- Real-time consistency with sources. Freshness is tracked and exposed, not
  guaranteed.
- A human portal. The API/CLI/MCP surface is primary; a UI is optional and
  sits on the same API.

---

## 2. Data model

Three concepts: **kind** (a type), **resource** (an instance of a kind), and
**link** (a typed, directed edge declared on a kind). Everything else —
ownership, permissions, scorecards — is expressed in terms of these.

In this document "resource" always means a catalog resource. Things in the
source systems are called by their own names: cloud resources, workloads,
repositories, groups.

### 2.1 Kind

A kind is a versioned document. Properties are JSON Schema; links are
first-class, not just string properties that happen to hold an id.

```yaml
kind: kind
identifier: component
title: Component
description: A deployable unit of software (service, job, library)
schema:
  properties:
    lifecycle: { type: string, enum: [experimental, production, deprecated] }
    tier:      { type: string, enum: [tier-1, tier-2, tier-3] }
    language:  { type: string }
    repoUrl:   { type: string, format: uri }
  required: [lifecycle]
links:
  owner:
    target: team
    many: false
    required: false          # may be inherited, see 2.4
    ownership: grants        # this link *defines* the owner of this resource
  system:
    target: system
    many: false
    ownership: inherits      # if no direct owner, inherit from the system
  dependsOn:
    target: component
    many: true
  repo:
    target: repository
    many: false
visibility: owner           # owner | org   (default: owner, see 3.3)
identity:
  # how ingestion resolves "which resource is this" — see 4.3
  keys: [repoUrl]
```

Rules:

- `identifier` is immutable. Properties are additive within a major version;
  removing or retyping a property is a new major version and requires a
  migration step that rewrites existing resources.
- A link declares `target` (kind id), `many`, `required`, and the
  `ownership` role (`grants`, `inherits`, or none). At most one link per
  kind may be `ownership: grants`.
- `visibility` sets the default read rule for the kind's resources.
- Every document's `kind:` field names the kind it is an instance of, the way
  `kind:` works in Kubernetes. A kind definition is itself a resource of the
  built-in kind `kind`, so the same audit, API and permission path applies to
  schema changes.

### 2.2 Resource

```yaml
kind: component
identifier: checkout-service          # unique within the kind
title: Checkout Service
properties:
  lifecycle: production
  tier: tier-1
  language: go
  repoUrl: https://github.com/acme/checkout-service
links:
  owner: team:payments
  system: system:commerce
  dependsOn: [component:cart-service, component:pricing-service]
  repo: repository:github/acme/checkout-service
# server-managed:
meta:
  createdAt: 2026-11-12T09:14:03Z
  updatedAt: 2026-11-12T10:02:11Z
  sources:                             # provenance per source, see 4.4
    - { source: github, lastSeenAt: 2026-11-12T10:02:11Z, externalId: "R_kgDOAbc" }
    - { source: manual, lastSeenAt: 2026-10-01T08:00:00Z }
  propertyProvenance:
    lifecycle: manual
    language: github
    repoUrl: github
  effectiveOwners: [team:payments]     # derived, see 2.4
```

Resource references are `<kind>:<identifier>`. That string is the stable id
used by the API, OpenFGA tuples, and every downstream consumer.

### 2.3 Built-in kinds

The platform ships these; they can be extended but not removed, because the
permission model depends on them.

| Kind | What it is | Ingested from |
|---|---|---|
| `user` | A person or service principal | Entra ID / AD |
| `ad_group` | A security group. Has `members: [user \| ad_group]` (nested groups keep their structure; flattening happens in the policy engine, not here) | Entra ID / AD |
| `team` | The organisational unit that owns things. Has `backedBy: [ad_group]` (one or more) | Manual, HR system, or derived 1:1 from a naming convention on AD groups |
| `kind` | Kind definitions themselves | Manual / git |
| `action` | Self-service action definition (6.3) | Manual / git |
| `action_run` | One invocation of an action | Action runner |
| `scorecard` | Scorecard definition (6.1) | Manual / git |
| `source` | An ingestion source and its mapping (4.2) | Manual / git |

`team` is kept distinct from `ad_group` on purpose. Groups are an identity
provider artefact: there are usually several per team (`eng-payments`,
`eng-payments-oncall`, `payments-prod-deployers`), they get renamed, and
ownership should not churn when IT reorganises the group tree. A team is the
stable thing resources point at; which groups back it is one link that can
change.

### 2.4 Ownership inference

Ownership is never a free-text field. It is computed:

1. If the resource has a link with `ownership: grants` set (e.g.
   `component.owner`), its target is the owner.
2. Otherwise, follow each link with `ownership: inherits` (e.g.
   `component.system`, `k8s_workload.component`, `aws_resource.component`) and
   take the owner(s) of the targets, recursively, with cycle detection and a
   depth limit.
3. If nothing resolves, the resource is **unowned**. Unowned is a first-class
   state: it shows up in reports, is scoreable, and by default is visible only
   to platform admins (3.3).

The result is written to `meta.effectiveOwners` and recomputed whenever the
resource, or anything on its inheritance path, changes. This single resolver is
the only place ownership logic lives. OpenFGA (section 3) receives
`effectiveOwners` as plain tuples and does not re-derive it. The query layer
filters on the same column. One implementation, three consumers.

Example path: `aws_rds_instance:prod-checkout-db --component--> component:checkout-service --owner--> team:payments --backedBy--> ad_group:eng-payments --members--> user:alice`.

### 2.5 Link integrity

- A link may point at a resource that does not exist yet (ingestion order
  is not controllable). Such edges are stored as **dangling** and resolved when
  the target appears. Dangling edges are reportable and never contribute to
  ownership.
- Deleting a resource leaves tombstones for its incoming links for a
  retention period, so a source that re-creates it (common with Kubernetes
  restarts, repo renames) reattaches cleanly.
- Cardinality (`many: false`) is validated on write.

---

## 3. Permission model

### 3.1 Principle

Access is a function of the graph: a user can act on a resource when there is a
path `resource → effectiveOwner team → backing AD group → (nested groups) →
user`, or when a kind-level or platform-level grant says so. There are no
resource-level ACLs. Changing who can see or edit a service means changing a
link (move the service to another team, add a group behind the team),
which is itself an audited catalog write.

The catalog stores the facts. **OpenFGA** evaluates the decision. The catalog
API is the only writer of tuples and the only caller of `Check`/`ListObjects`;
nothing else talks to OpenFGA directly.

### 3.2 Authorization model

```
model
  schema 1.1

type user

type ad_group
  relations
    define member: [user, ad_group#member]      # nested groups, resolved by OpenFGA

type team
  relations
    define backed_by: [ad_group]
    define member: member from backed_by

type platform
  relations
    define admin: [user, ad_group#member]
    define auditor: [user, ad_group#member]     # read everything, change nothing

type kind
  relations
    define platform: [platform]
    define org_viewer: [user:*]                 # present only when visibility: org
    define editor: [team#member, ad_group#member]   # kind-wide grants (rare)
    define admin: admin from platform

type resource
  relations
    define kind: [kind]
    define owner: [team]                        # one tuple per effectiveOwner
    define owner_member: member from owner
    define can_view: owner_member
                     or org_viewer from kind
                     or editor from kind
                     or admin from kind
                     or auditor from platform
    define can_edit: owner_member
                     or editor from kind
                     or admin from kind
    define can_run_action: owner_member or admin from kind
    define can_transfer: admin from kind   # moving ownership is a privileged write

type action
  relations
    define kind: [kind]
    define runner: [team#member, ad_group#member]   # optional narrowing, see 6.3
```

Tuples written by the catalog, from the example in 2.2:

```
ad_group:eng-payments#member@user:alice
ad_group:eng-payments#member@ad_group:eng-payments-leads#member
team:payments#backed_by@ad_group:eng-payments
resource:component/checkout-service#kind@kind:component
resource:component/checkout-service#owner@team:payments
resource:aws_rds_instance/prod-checkout-db#owner@team:payments     # inherited, written by the resolver
resource:aws_rds_instance/prod-checkout-db#kind@kind:aws_rds_instance
kind:component#platform@platform:default
platform:default#admin@ad_group:platform-engineering#member
```

Because the resource type is generic (`resource`, not one OpenFGA type per
kind), adding a kind never changes the authorization model. The
kind-level OpenFGA relations (`org_viewer`, `editor`) are how a kind's
`visibility` and any wide grants are expressed.

### 3.3 Visibility defaults and the trade-off

The requirement is: only members of the owning group can view or work on an
resource. That is the default: `visibility: owner`.

This has a real cost for a catalog: dependency maps, "who do I call about
service X", and cross-team reports all need other teams' resources to be at
least discoverable. The design therefore supports, per kind:

| `visibility` | Who can read | Typical use |
|---|---|---|
| `owner` (default) | owning team members, kind editors, platform admins/auditors | cloud resources, secrets metadata, cost data, anything with sensitive properties |
| `org` | any authenticated user | `team`, `system`, `component` *identity and ownership fields* |

`org` can be combined with **property-level sensitivity**: a kind may mark
properties `sensitivity: owner`, in which case the resource is listed to everyone
but those properties are redacted unless `can_view` passes. This is what lets
"everyone can see that checkout-service exists and payments owns it; only
payments sees its on-call rota and cost" work without per-resource rules.

The recommendation is to run the built-in `team`, `system` and `component`
kinds as `org` with sensitive properties redacted, and everything else as
`owner`. This is a policy choice for the platform owners; the mechanism
supports either.

### 3.4 Enforcement points

| Path | Check |
|---|---|
| `GET /resources/{id}` | `Check(user, can_view, resource)` |
| Search / list / graph traversal | `ListObjects(user, can_view, resource)` intersected with the query; for large tenants, the query layer instead filters on `effectiveOwners ∩ userTeams` plus kind visibility, which is the same rule precomputed. Both paths exist; a consistency test compares them nightly. |
| Write (manual edit, API) | `Check(user, can_edit, resource)`; ownership-changing writes need `can_transfer` |
| Ingestion write | Source identity, not user identity. A `source` resource declares which kinds it may write and which properties it owns (4.4). |
| Run action | `Check(user, can_run_action, resource)` and, if the action has `runner` tuples, `Check(user, runner, action)` |
| Scorecard / report read | Same as resource read; reports aggregate only over resources the caller can view |

Agents are not special. An MCP server acts **on behalf of** the calling user
(token exchange / on-behalf-of flow against Entra ID) and every catalog call
carries that user's identity. An agent running unattended runs as a service
principal that is itself a `user` resource in one or more AD groups, so the same
rules apply and its reach is visible in the graph like anyone else's.

### 3.5 Group membership freshness

Membership is the one fact where staleness is a security issue. The Entra ID
source therefore runs two cadences: a full reconciliation (hourly) and a delta
subscription (Graph change notifications, or delta queries every few minutes).
Removal from a group propagates to OpenFGA within the delta interval; this
bound is documented as an SLO and exposed on the `source:entra-id` resource.

---

## 4. Ingestion

### 4.1 Sources

A source is a connector plus a mapping. Expected first-wave sources:

| Source | Kinds produced | Mode |
|---|---|---|
| Entra ID / AD | `user`, `ad_group`, group membership | full + delta (3.5) |
| GitHub | `repository`, `component` (via a catalog file in the repo), CODEOWNERS → `owner` hint | webhook + nightly full |
| Kubernetes (per cluster) | `k8s_cluster`, `k8s_namespace`, `k8s_workload`, `k8s_workload --component-->` via a label | watch + periodic resync |
| AWS (per account) | `aws_account`, one `aws_*` kind per service, `--component-->` via tag | Config/CloudTrail events + daily full |
| Argo CD / CI | `deployment`, `pipeline_run` | webhook |
| Datadog / PagerDuty | `monitor`, `oncall_schedule`, `incident` | webhook + periodic |
| Manual / git | `team`, `system`, overrides, kinds, actions, scorecards | git push (reconciled on merge) |

### 4.2 Mapping

Each source has a declarative mapping from source payload to resources. The
mapping is data on the `source` resource, so adding a field or a new kind
from an existing source is a config change:

```yaml
kind: source
identifier: kubernetes-prod-eu
connector: kubernetes
config: { cluster: prod-eu, watch: [Deployment, StatefulSet, CronJob] }
mapping:
  - match: Deployment             # source-side object type
    kind: k8s_workload            # catalog kind it becomes
    identifier: "{{ .metadata.namespace }}/{{ .metadata.name }}@prod-eu"
    title: "{{ .metadata.name }}"
    properties:
      replicas: "{{ .spec.replicas }}"
      image: "{{ (index .spec.template.spec.containers 0).image }}"
    links:
      namespace: "k8s_namespace:prod-eu/{{ .metadata.namespace }}"
      component: '{{ with index .metadata.labels "platform.acme.io/component" }}component:{{ . }}{{ end }}'
writes:
  kinds: [k8s_cluster, k8s_namespace, k8s_workload]
  ownsProperties: { k8s_workload: [replicas, image] }
```

The template language is a sandboxed expression language (JQ or CEL; pick one
and use it everywhere, including scorecards). The connector is responsible for
fetching and change detection; the mapping is responsible for shape.

### 4.3 Identity resolution

The hard problem in multi-source ingestion is "is this the same thing". Rules,
in order:

1. The mapping produces an explicit `identifier` — exact match.
2. Otherwise, the kind's `identity.keys` (e.g. `component.repoUrl`) are
   matched against existing resources.
3. Otherwise, a new resource is created and flagged `meta.unmatched: true` for
   the source, so it shows up in a "possible duplicates" report rather than
   silently forking the graph.

Cross-source links use the same mechanism in the link direction: the
Kubernetes label `platform.acme.io/component` and the AWS tag `platform:component`
are the convention by which infrastructure declares which component it belongs
to. That label is what makes ownership inheritance (2.4) reach cloud resources.

### 4.4 Merging, provenance, conflicts

- Each source **owns** the properties it declares in `writes.ownsProperties`
  and may not overwrite others. The `manual` source owns anything not claimed
  by another source. If two sources claim the same property, kind config
  sets a priority; the loser's value is retained in provenance but not applied.
- Every applied value records `propertyProvenance[prop] = source`, and every
  source that has seen the resource records `lastSeenAt`.
- Links are unioned across sources; a link is removed only when no
  source still asserts it.

### 4.5 Deletion and reconciliation

- Event-driven sources mark deletions explicitly.
- Full-sync sources use mark-and-sweep: resources not seen in a completed full
  run are marked `stale` by that source; when no source has seen a resource for
  the kind's `staleAfter` window it is soft-deleted (tombstoned, hidden
  from queries, restorable). Hard deletion is a separate retention job.
- A full run that produces far fewer resources than the last one (configurable
  threshold, default 20% drop) is held for review instead of swept. This is
  the guard against a broken credential deleting half the map.

### 4.6 Change log

Every write (ingestion or manual) appends to an immutable change log:
`(resourceRef, version, actor{user|source}, timestamp, diff, reason)`. The log
is the audit trail, the input to OpenFGA tuple sync, and the event stream for
derived data. It is published to a message bus (Kafka topic `catalog.changes`,
or the outbox pattern on the catalog DB if Kafka is not already run) so
consumers never poll.

---

## 5. Query and agent access

### 5.1 API surface

- **REST** for CRUD and ingestion: `/kinds`, `/resources`, `/sources`,
  `/actions`, `/changes`.
- **GraphQL** for reads: typed per kind (schema generated from
  kinds), link traversal with depth and direction, filters on
  properties, full-text search, and `effectiveOwners` on every resource.
- **Search**: full-text over title/identifier/selected properties, scoped by
  kind, always permission-filtered.

Every response carries freshness: `meta.updatedAt` and per-source `lastSeenAt`
so a caller can decide whether a fact is recent enough.

### 5.2 Agent context

Agents need a small, relevant, token-bounded slice of the graph, not the whole
thing. One endpoint does that:

```
POST /context
{ "focus": ["component:checkout-service"],
  "depth": 2,
  "include": ["owner", "dependsOn", "k8s_workload", "incident", "scorecard"],
  "budget": { "maxResources": 60 } }
```

It returns the focus resources, their neighbourhood by the listed links (in
both directions), current scorecard results, open incidents, and the freshness
of each fact, in a compact JSON shape. Permission filtering happens before the
budget is applied, so an agent never learns of a resource's existence through
truncation counts.

The MCP server exposes this as tools: `catalog_search`, `catalog_get`,
`catalog_context`, `catalog_who_owns`, `catalog_changes_since`,
`catalog_run_action`. All calls carry the end user's identity (3.4).

### 5.3 Why query the catalog instead of live systems

Live systems are the source of truth, and agents could call them. The catalog
wins on three axes: one credential model and one permission check instead of
N; cross-source joins (which pods run the service whose repo had this commit,
and who is on call) that no single source can answer; and cost — one indexed
query instead of fan-out API calls with rate limits. The price is staleness,
which is why freshness is on every fact and `catalog_changes_since` exists.

---

## 6. Derived data

### 6.1 Scorecards

A scorecard is rules over a resource and its neighbourhood, evaluated on
change. `appliesTo` names the kind it scores.

```yaml
kind: scorecard
identifier: production-readiness
appliesTo: component
filter: 'resource.properties.lifecycle == "production"'
levels: [bronze, silver, gold]
rules:
  - id: has-owner
    level: bronze
    expr: 'size(resource.meta.effectiveOwners) > 0'
  - id: has-oncall
    level: silver
    expr: 'size(linked(resource, "owner").linked("oncall_schedule")) > 0'
  - id: no-critical-vulns
    level: gold
    expr: 'linked(resource, "repo").properties.criticalVulnerabilities == 0'
```

Results are stored as a derived property set on the resource
(`scorecards.production-readiness = { level: silver, rules: {...}, evaluatedAt }`)
and in a history table, so trend reports are a query, not a recomputation.
Evaluation is triggered from the change log, scoped to resources whose inputs
changed. Scorecard rules use the same expression language as mappings (4.2).

### 6.2 Reports

Reports are saved GraphQL queries plus an aggregation, run on a schedule or on
demand, permission-filtered to the viewer. Typical: ownership coverage per
kind, unowned resources per AWS account, scorecard distribution per team,
stale resources per source. No separate reporting store; the catalog's indexes
and the scorecard history table are the inputs.

### 6.3 Self-service actions

An action is a form bound to a kind and a runner:

```yaml
kind: action
identifier: scaffold-service
appliesTo: component
trigger: create               # create | day-2 (on an existing resource) | delete
inputs:
  schema:
    properties:
      name: { type: string, pattern: "^[a-z0-9-]+$" }
      team: { type: string, kind: team }       # link-typed input, filtered to teams the caller is a member of
      template: { type: string, enum: [go-service, python-job] }
runner:
  type: argo-workflows        # or github-actions
  ref: platform/scaffold-service
  payload: '{ "name": inputs.name, "team": inputs.team, "requestedBy": user.id }'
permissions:
  # defaults to can_run_action on the target resource (day-2) or kind editor (create)
```

Invoking an action creates an `action_run` resource linked to the target and the
caller, dispatches to the runner, and the runner reports status back by
updating that resource (via the ingestion API, as a `source`). The `action_run`
inherits ownership from its target, so visibility of runs follows the same
rules as everything else. Runners are existing workflow engines; the catalog
never executes anything itself.

---

## 7. Storage and components

![Service Catalog Components](./Service%20Catalog%20Components.drawio.png)

The PNG has the draw.io source embedded; open it directly in
[diagrams.net](https://app.diagrams.net) or the VS Code Draw.io extension to edit.

**Store: Postgres.** Resources as rows with a JSONB `properties` column and a
GIN index; links as a `(from_ref, link, to_ref, source)` table;
`effective_owners` as an indexed array column; change log as an append-only
table partitioned by month. Full-text search via `tsvector` initially, moving
to OpenSearch only if relevance or scale demands it. Graph traversals for the
depths the catalog needs (2–4 hops) are recursive CTEs over the links
table; a dedicated graph database is not justified until traversal patterns
prove otherwise.

Why not DataHub as the store, given the earlier platform-abstraction decision
chose it for Layer 3? Two things in this design strain it:

1. **Dynamic kinds.** DataHub's entity types and relationship names (its
   own terms) are compiled in (PDL schemas, entity registry) and need a
   redeploy. Structured properties are dynamic, but new types and new
   relationships are not.
   "A kind is a config change" does not fit.
2. **Permission inference.** DataHub has its own policy engine and ownership
   aspect, and it would have to be bypassed or kept in sync with the
   group-derived model in section 3. Running two authorization opinions over
   the same data is exactly what the design is trying to avoid.

What DataHub provided — aspect model, change-log stream, timeline/audit — is
reproduced here by the change log table and bus. OpenFGA stays exactly as the
earlier design specified. If DataHub is already running for data-catalogue
purposes, it becomes an ingestion *source* (datasets, pipelines) rather than
the store. The platform-abstraction docs should be updated to reflect this
once the decision is confirmed (see section 8).

**Sizing assumptions:** up to ~500k resources, ~5M links, ~100k
users/groups, ~10k changes/minute at ingestion peaks. Postgres handles this
comfortably on one primary with read replicas for the query path.

---

## 8. Decisions and open questions

Decided in this document:

- Kinds are data; a single generic OpenFGA `resource` type keeps the
  authorization model stable as kinds are added.
- `team` is distinct from `ad_group`; teams own, groups grant membership.
- Ownership is inferred by one resolver and materialised; OpenFGA and the
  query filter both consume the result rather than re-deriving it.
- Default visibility is owner-only, with per-kind `org` visibility and
  property-level redaction as the escape hatch.
- Agents act on behalf of users; no catalog-wide service identity for agents.
- Postgres-backed catalog service rather than DataHub as the store.

Open, needing a decision from the platform owners:

1. **Which built-in kinds default to `org` visibility** (3.3). The
   recommendation is `team`, `system`, `component` with sensitive properties
   redacted. Pure owner-only on everything makes dependency maps and
   cross-team reports mostly empty for ordinary users.
2. **Team ↔ AD group convention.** Derive teams 1:1 from a group naming
   pattern (zero manual work, brittle) or maintain `team` resources in git with
   an explicit `backedBy` list (small manual step, stable). Recommendation:
   git-maintained, with a report flagging groups matching the pattern that no
   team references.
3. **Expression language** for mappings and scorecards: CEL or JQ. CEL is
   recommended for its type checking and sandboxing; JQ is more widely
   known.
4. **Message bus.** Kafka if already operated; otherwise the Postgres outbox
   pattern is sufficient at the stated scale.
5. **Confirm the DataHub change** and update
   [`../platform-abstraction/explanation.md`](../platform-abstraction/explanation.md)
   and `reference.md` accordingly. Until then the two documents disagree on
   the Layer 3 store, and this one is the newer position.
