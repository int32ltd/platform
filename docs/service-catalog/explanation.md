# Service Catalog explanation

Why the catalog is built the way it is. For the exact schemas, authorization
model and API, see [reference.md](./reference.md).

The catalog is the platform's **resource map**: a continuously refreshed store of
everything the organisation runs (services, repos, workloads, cloud resources,
teams, people, incidents, ...) and how those things relate. It is populated by
ingestion from many sources and is the thing agents, reports, scorecards and
self-service actions query — instead of hitting the live systems themselves.

It is the concrete implementation of Layer 3 ("Policy & Ownership Graph") in
[`../platform-abstraction/`](../platform-abstraction/README.md), one level
deeper.

The one requirement that shapes everything else: **permissions are part of the
map.** An identity group (from Entra ID, Okta, Zitadel, or any other identity
provider) is a resource like any other. Ownership is a link. Who
may see or act on a resource is *inferred from the graph* (resource → owning team
→ backing identity group → members), never configured per resource by hand.

Contents:

- [Goals and non-goals](#goals-and-non-goals)
- [Kinds, resources and links](#kinds-resources-and-links)
- [Why `team` and `identity_group` are separate](#why-team-and-identity_group-are-separate)
- [Where `team` and `system` come from](#where-team-and-system-come-from)
- [Why ownership is inferred, not configured](#why-ownership-is-inferred-not-configured)
- [Permissions are part of the map](#permissions-are-part-of-the-map)
- [Owner-only visibility and what it costs](#owner-only-visibility-and-what-it-costs)
- [Agents are not special](#agents-are-not-special)
- [Why query the catalog instead of live systems](#why-query-the-catalog-instead-of-live-systems)
- [Why Postgres and not DataHub](#why-postgres-and-not-datahub)
- [Decisions and open questions](#decisions-and-open-questions)

---

## Goals and non-goals

**Goals**

- One queryable map of resources and links, refreshed from many sources,
  with provenance and freshness on every fact.
- Schema defined as data ("kinds"), so a new resource type or link is a
  config change, not a deploy.
- Ownership inferred from links, and access derived from ownership plus
  identity-group membership. No per-resource ACLs.
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

## Kinds, resources and links

Three concepts: **kind** (a type), **resource** (an instance of a kind), and
**link** (a typed, directed edge declared on a kind). Everything else —
ownership, permissions, scorecards — is expressed in terms of these.

In this document "resource" always means a catalog resource. Things in the
source systems are called by their own names: cloud resources, workloads,
repositories, groups.

Kinds are themselves data, so a new resource type or link is a config change,
not a deploy. The exact shapes are in
[reference.md](./reference.md#kinds).

## Why `team` and `identity_group` are separate

`team` is kept distinct from `identity_group` on purpose. Groups are an identity
provider artefact: there are usually several per team (`eng-payments`,
`eng-payments-oncall`, `payments-prod-deployers`), they get renamed, and
ownership should not churn when IT reorganises the group tree. A team is the
stable thing resources point at; which groups back it is one link that can
change.

## Where `team` and `system` come from

A source is authoritative when someone else already maintains it for their own
reasons and it costs *them* when it is wrong. Git passes that test for platform
configuration — kinds, actions, scorecards, source mappings — which is code:
reviewed, versioned, deployed, and broken loudly when wrong. It fails that test
for organisational facts. A `teams.yaml` is a copy of the org chart that nobody's
workflow depends on, so nobody notices when it rots — and the catalog would then
be inferring ownership, and therefore access, from the stalest file in the
repository.

So `team` is not one source's record. It is assembled from three, each owning
the facts it is genuinely responsible for:

| Fact | Source | Why that one |
|---|---|---|
| existence, name, parent unit, cost centre, manager | HR system (Workday, Personio, HiBob, ...) | the organisation's own record of its units, with a stable `orgUnitId` to key on |
| membership | identity provider ([Group membership freshness](./reference.md#group-membership-freshness)) | already the source for `identity_group`; joined to the team by an org-unit attribute carried on the group, not by a name pattern |
| who is accountable for production right now | on-call / incident tool (PagerDuty, Opsgenie, ...) | the one place where being wrong hurts within the hour, so it is the freshest thing in the organisation |

`identity.keys: [orgUnitId]`, so the team survives a rename in any of the three.
The catalog merges them with the ordinary provenance rules ([Merging and provenance](./reference.md#merging-and-provenance)): HR owns the
descriptive properties, the identity provider owns membership, the on-call tool
owns the rota.

The known weakness is that HR org units and engineering squads frequently do not
match — HR models reporting lines, engineering works in squads that re-form
faster than HR records them. Where the organisation models squads somewhere else
(the on-call tool, a team directory), *that* tool is the spine and the HR system
enriches it with hierarchy and cost centre. Which one is the spine is an
organisation-specific choice ([open question 2](#decisions-and-open-questions)); the rule that does not vary is that the
spine is a system somebody else maintains for their own reasons.

Git keeps at most the join between spine and groups, and only where neither side
carries a usable cross-reference. That residue is measured, reported, and driven
to zero rather than treated as the design. The reports that keep it honest
([Reports](./reference.md#reports)): org units with no backing group, teams owning a tier-1 component with no
rotation, on-call teams matching no catalog team, groups matching the org-unit
pattern that no team references.

**`system`** has no HR or identity equivalent — it is an architecture grouping,
not an organisational one — so it is sourced differently again. Its membership is
declared by the components themselves: the catalog file in each repository names
the system it belongs to, exactly as a Kubernetes label names a component ([Identity resolution](./reference.md#identity-resolution)).
GitHub is therefore the source, and the `system` resource is materialised from
the union of those declarations, created on first reference by dangling-edge
resolution ([Link integrity](./reference.md#link-integrity)) and flagged `meta.unmatched` until something claims it. Its
descriptive properties — business name, domain, product owner — and its `owner`
link come from the portfolio or product tool where the organisation runs one
(Jira product hierarchy, ServiceNow business services, an architecture
repository).

Where no such tool exists, a system's `owner` is a catalog-owned override. That
is legitimate: it is a fact with no other home, which [Goals and non-goals](#goals-and-non-goals) already reserves
to the catalog. The distinction worth holding onto is that **git holds overrides
and platform configuration, never records** — and ownership-coverage reports
should show what share of the map currently rests on overrides, because that
share is the design's technical debt.

## Why ownership is inferred, not configured

Ownership is never a free-text field. It is computed from links: a link marked
`ownership: grants` names the owner directly, and links marked
`ownership: inherits` let a resource take its owner from what it belongs to (a
workload from its component, a component from its system). Anything that
resolves to nobody is *unowned*, which is a first-class, reportable state rather
than a silent gap. The algorithm is in
[reference.md](./reference.md#ownership-resolution).

The result is written to `meta.effectiveOwners` and recomputed whenever the
resource, or anything on its inheritance path, changes. This single resolver is
the only place ownership logic lives. OpenFGA ([Authorization model](./reference.md#authorization-model)) receives
`effectiveOwners` as plain tuples and does not re-derive it. The query layer
filters on the same column. One implementation, three consumers.

## Permissions are part of the map

Access is a function of the graph: a user can act on a resource when there is a
path `resource → effectiveOwner team → backing identity group → (nested groups) →
user`, or when a kind-level or platform-level grant says so. There are no
resource-level ACLs. Changing who can see or edit a service means changing a
link (move the service to another team, add a group behind the team),
which is itself an audited catalog write.

The catalog stores the facts. Two evaluators make decisions from them, with
one model and split authority. The catalog database evaluates the rule
itself for the catalog's own queries, because search, lists and graph
traversal have to be filtered inside the query: calling OpenFGA per row, or
intersecting a full `ListObjects` result with a filtered, paged search, does
not scale. **OpenFGA** is the decision service for every other component of
the platform, which should never query the catalog database to ask "may this
user do that?".

Two evaluators of one model can drift apart, so the design treats agreement as
something to prove. The catalog is the only writer of tuples, ownership is
resolved once and consumed by both, the model lives in one file that the
docs copy verbatim, and a drift check compares both evaluators over the same
tuples for every user and resource in CI
([reference](./reference.md#authorization-model)).

## Owner-only visibility and what it costs

The requirement is: only members of the owning group can view or work on an
resource. That is the default: `visibility: owner`.

This has a real cost for a catalog: dependency maps, "who do I call about
service X", and cross-team reports all need other teams' resources to be at
least discoverable. The design therefore supports, per kind:

Per-kind `org` visibility combined with property-level redaction covers that
without per-resource rules: everyone can see that checkout-service exists and
payments owns it; only payments sees its on-call rota and cost (see
[reference.md](./reference.md#visibility)).

The recommendation is to run the built-in `team`, `system` and `component`
kinds as `org` with sensitive properties redacted, and everything else as
`owner`. This is a policy choice for the platform owners; the mechanism
supports either.

## Agents are not special

Agents are not special. An MCP server acts **on behalf of** the calling user
(token exchange / on-behalf-of flow against the identity provider) and every catalog call
carries that user's identity. An agent running unattended runs as a service
principal that is itself a `user` resource in one or more identity groups, so the same
rules apply and its reach is visible in the graph like anyone else's.

## Why query the catalog instead of live systems

Live systems are the source of truth, and agents could call them. The catalog
wins on three axes: one credential model and one permission check instead of
N; cross-source joins (which pods run the service whose repo had this commit,
and who is on call) that no single source can answer; and cost — one indexed
query instead of fan-out API calls with rate limits. The price is staleness,
which is why freshness is on every fact and `catalog_changes_since` exists.

## Why Postgres and not DataHub

The store is a Postgres-backed catalog service (schema in
[reference.md](./reference.md#storage)).

Why not DataHub as the store, given the earlier platform-abstraction decision
chose it for Layer 3? Two things in this design strain it:

1. **Dynamic kinds.** DataHub's entity types and relationship names (its
   own terms) are compiled in (PDL schemas, entity registry) and need a
   redeploy. Structured properties are dynamic, but new types and new
   relationships are not.
   "A kind is a config change" does not fit.
2. **Permission inference.** DataHub has its own policy engine and ownership
   aspect, and it would have to be bypassed or kept in sync with the
   group-derived model in [Authorization model](./reference.md#authorization-model). Running two authorization opinions over
   the same data is exactly what the design is trying to avoid.

What DataHub provided — aspect model, change-log stream, timeline/audit — is
reproduced here by the change log table and bus. OpenFGA stays exactly as the
earlier design specified. If DataHub is already running for data-catalogue
purposes, it becomes an ingestion *source* (datasets, pipelines) rather than
the store. The platform-abstraction docs should be updated to reflect this
once the decision is confirmed (see [Decisions and open questions](#decisions-and-open-questions)).

## Decisions and open questions

Decided in this document:

- Kinds are data; a single generic OpenFGA `resource` type keeps the
  authorization model stable as kinds are added.
- `team` is distinct from `identity_group`; teams own, groups grant membership.
- Ownership is inferred by one resolver and materialised; OpenFGA and the
  query filter both consume the result rather than re-deriving it.
- Default visibility is owner-only, with per-kind `org` visibility and
  property-level redaction as the escape hatch.
- Agents act on behalf of users; no catalog-wide service identity for agents.
- Two evaluators, one model: the SQL rule is authoritative for the catalog's
  own queries, OpenFGA for every other service; a drift check in CI proves
  they agree.
- Postgres-backed catalog service rather than DataHub as the store.

Open, needing a decision from the platform owners:

1. **Which built-in kinds default to `org` visibility** ([Visibility](./reference.md#visibility)). The
   recommendation is `team`, `system`, `component` with sensitive properties
   redacted. Pure owner-only on everything makes dependency maps and
   cross-team reports mostly empty for ordinary users.
2. **Which system of record is the team spine** ([Where team and system come from](#where-team-and-system-come-from)). HR org units give
   coverage and stable ids but lag reorganisations and often do not match
   engineering squads; the on-call tool is the freshest and the most meaningful
   for ownership but covers only teams carrying production load. Recommendation:
   HR system as the spine, joined to identity groups by an org-unit attribute on
   the group, with drift reports against the on-call tool. This needs confirming
   against the systems the organisation actually runs, and against whether its
   groups carry an org-unit attribute at all — if they do not, the join table
   lives in git as a measured, temporary residue rather than as the design.
3. **Expression language** for mappings and scorecards: CEL or JQ. CEL is
   recommended for its type checking and sandboxing; JQ is more widely
   known.
4. **Message bus.** Kafka if already operated; otherwise the Postgres outbox
   pattern is sufficient at the stated scale.
5. **Confirm the DataHub change** and update
   [`../platform-abstraction/explanation.md`](../platform-abstraction/explanation.md)
   and `reference.md` accordingly. Until then the two documents disagree on
   the Layer 3 store, and this one is the newer position.
