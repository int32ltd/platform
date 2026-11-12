# Explanation

Why the platform is layered this way, and what it costs.

## The problem being solved

A platform that exposes vendor APIs directly to developers (Datadog SDK calls
in app code, Jenkinsfiles checked into every repo, Terraform that names
`aws_instance` in golden-path templates) accumulates two kinds of lock-in:

1. **Vendor lock-in** — swapping Datadog for Dynatrace means touching every
   service that called Datadog directly.
2. **Ownership lock-in** — moving a service from Team A to Team B means
   manually re-granting access in GitHub, AWS IAM, Datadog, Okta, and
   whatever else that service touches, with no single place that confirms
   it's actually done.

Both are the same underlying mistake: something that should be platform
policy (which vendor, who owns what) got hard-coded into developer-facing
surfaces (app code, templates, IAM consoles).

## Why three layers, specifically

**Contract vs. provider adapter** is the standard "stable interface, swappable
implementation" split — the same idea as a CSI driver in Kubernetes, a
Terraform provider, or a Crossplane Composition. The contract is deliberately
*thin*: just enough verbs for every current and plausible provider to
implement. A thin contract is what makes a genuinely new adapter possible
later; a contract shaped around today's incumbent vendor's quirks (e.g.
exposing Datadog-specific tag syntax) just relocates the lock-in one layer
down instead of removing it.

**Binding policy as its own layer**, separate from the contract, is what lets
vendor choice vary *per tenant/environment/region* without that variability
leaking into developer-facing templates. It's also the one file platform
engineers are allowed to put a vendor name in — concentrating that knowledge
in one git-reviewable place is what makes "we're migrating off Datadog" a
single, auditable change instead of a grep-and-replace across every service.

**Ownership as a graph, not as IAM state**, is the part that specifically
answers "can ownership move between entities." If ownership *is* a GitHub
team membership and an AWS IAM group and a Datadog role, moving it is N
manual operations with no transactional guarantee and no single audit event.
If ownership is one edge in a graph (`Component --owned-by--> Team`) and every
vendor's native IAM is a *projection* of that graph, moving ownership is one
graph mutation, and "did it actually move everywhere" is one reconciliation
check instead of N consoles.

This is the same principle Backstage's software catalog and Kubernetes'
controller/reconciliation model both rely on: a declared desired state, and
controllers that continuously push reality toward it. Treating vendor IAM as
generated-and-reconciled (rather than hand-edited) is what keeps it from
drifting out of sync with the graph.

## Trade-offs — what this costs

- **Latency to support a new vendor feature.** If a vendor ships a feature
  the contract doesn't expose a verb for, developers can't use it until the
  contract is extended and an adapter implements it. This is deliberate: the
  alternative is vendor-specific escape hatches that quietly recreate
  lock-in. Where teams genuinely need bleeding-edge vendor-specific features
  faster than the contract can evolve, that's a signal to widen the contract,
  not to bypass it.
- **Upfront cost before any abstraction pays off.** Writing a contract, one
  adapter, and the binding/ownership plumbing for a capability that only ever
  has one provider is pure overhead. Abstract the capabilities where
  multi-vendor reality already exists or is clearly coming (observability,
  CI, cloud), not everything in the capability map on day one — see the
  rollout note in the original design discussion.
- **The graph becomes a single point of failure/trust.** If the ownership
  graph or policy engine is wrong or down, every provider's access reflects
  that. This is the correct trade for having one coherent audit trail instead
  of N inconsistent ones, but it means the graph/policy engine itself needs
  the reliability and review rigor of anything else access-control-critical.

## Relationship to existing OSS patterns

| Pattern used here | Comparable OSS building block |
|---|---|
| Capability contract + provider adapter | Crossplane Composition/Claim, Terraform provider interface, Kubernetes CSI/CNI |
| Flexible entity/relationship graph (the actual ownership-graph store) | DataHub |
| Policy engine over a graph | Open Policy Agent, Cedar, OpenFGA |
| Vendor-neutral telemetry wire format | OpenTelemetry |
| Vendor-neutral ingress/routing contract | Kubernetes Gateway API |
| Sync controller reconciling generated state | Kubernetes operator/controller pattern, External Secrets Operator |

None of this requires inventing new tooling from scratch — it requires
deciding, deliberately, which file is allowed to name a vendor, and making
sure ownership lives in exactly one place.

## Why DataHub, not Backstage — and why no Backstage at all

An intermediate version of this design put the ownership/relationship graph
*and* the portal on Backstage, on the strength of its 1.50 catalog
**model-layer system**, which lets plugins declare custom entity kinds with
JSON Schema validation. That was reverted for two reasons, one about the
feature itself and one about what this platform's primary interface
actually is.

**The feature isn't ready to be a source of truth.** The model-layer system
is alpha, opt-in, and explicitly flagged by the Backstage team as subject to
breaking changes. Worse than "unstable" — there's an open, acknowledged bug
(backstage/backstage#36470) where adding a catalog model source swaps out
the built-in entity processor and **relations between built-in kinds and
custom kinds stop being emitted**. That's not cosmetic: it directly
threatens `Component --owned-by--> Team` the moment `Component` becomes a
custom-schema'd kind and `Team` stays built-in — exactly the relation this
whole design depends on. Putting the actual ownership graph on top of that
is the wrong trade regardless of anything else.

**Backstage's main value doesn't apply here.** Backstage's reason to exist
is the portal UI — search, entity pages, scaffolding, a human-facing
catalog. This platform's primary interface is the CLI/API/MCP surface, not
a human portal. Adopting Backstage would mean taking on its alpha catalog
internals (see above) without even using the one thing it's actually good
at and stable on. There's no version of "use Backstage" that makes sense
once the portal isn't the primary interface — so Layer 1 doesn't include it
at all; a human-facing UI, if one is wanted later, is an optional,
independently-addable thing, not a dependency of the architecture.

That leaves the earlier DataHub-based design as the right one: DataHub's
aspect model, Kafka-based ingestion, and Timeline API are stable, Apache
2.0, and — just as importantly for an API/MCP-first platform — DataHub is
itself API-first (GraphQL + REST), so an MCP server or CLI talks to it
exactly as naturally as a human-facing UI would have. See
[reference.md](./reference.md) for the concrete schemas; the short version:

- **Aspect model**: any entity carries arbitrary typed "aspects" you define
  yourself — `Tenant`, `BindingPolicy`, `CapabilityInstance` are each a
  custom entity type with custom aspects, no alpha flag attached.
- **Event-driven ingestion**: metadata change events flow through Kafka into
  a graph store + search index, consumable by any number of independent
  downstream services (OpenFGA sync, IAM sync controllers, scorecards)
  without each one polling an API.
- **Audit/version history, built in**: every aspect write emits an MCL event
  retained via the Timeline API — no custom audit table to build, unlike
  the Backstage-only path.
- OpenMetadata remains the runner-up, rejected for the same two reasons as
  before: its UI/ingestion framework sits under the source-available Collate
  Community License rather than Apache 2.0, and its model is schema-first
  rather than aspect-based.

### Architecture sketch: Layer 3 built on DataHub

```
CLI / API / MCP servers  (primary interface — no portal UI required)
        │  reads/writes via GraphQL/REST
        ▼
DataHub  (the ownership/relationship graph)
  ├─ GMS (metadata service)            — entity + aspect CRUD, GraphQL API
  ├─ Graph store + search index        — relationship queries, full-text search
  ├─ Timeline API                      — version/audit history, built in
  └─ Kafka ingestion backbone          — change events from every source below
        │
        ├─ existing ingestion connectors (GitHub, Kubernetes, cloud, CI)
        └─ custom connectors for anything DataHub doesn't cover yet
        │
        ▼
OpenFGA  (relation-based access decisions)
  — evaluates access by walking the same entity IDs DataHub holds;
    DataHub owns "what exists and how it relates," OpenFGA owns
    "who may do what to it" — kept as two systems on purpose, not merged,
    so the access-control engine stays swappable independent of the catalog
        │
        ▼
Sync controllers → vendor-native IAM (AWS IAM, GitHub Teams, Datadog RBAC, Okta groups)
  — generated projections, reconciled from OpenFGA's decisions, never hand-edited
```

What this buys, concretely: moving ownership becomes "update the `owner`
aspect on the `Component` entity in DataHub" — one write, one place — and
every downstream RBAC/IAM projection reconciles from that automatically, the
same guarantee the original design called for, with audit history included
rather than hand-built.

What still has to be built, because nothing OSS does it generically: a
**no-code blueprint/entity-type editor UI** (Port's actual product surface
— DataHub's aspects are defined via code/schema today, not a point-and-click
form; lower priority now that the portal isn't the primary interface
anyway), **self-service actions** (forms/CLI commands that trigger
workflows — wire to Argo Workflows/GitHub Actions rather than invent a
runner), and **scorecards** (OPA/Rego can express the scoring rules; the
aggregation/reporting layer is custom).
