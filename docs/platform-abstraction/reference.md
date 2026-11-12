# Reference

Precise specs. No rationale here — see [explanation.md](./explanation.md) for
why things are shaped this way, including why each tool below was picked over
its alternatives.

## Which tool implements each layer

None of the schemas below are a bespoke format invented for this platform —
each layer maps onto an existing OSS project and DSL:

| Layer | Concrete tool | Schema / DSL | Wire protocol it exposes |
|---|---|---|---|
| 1. Developer Interface | CLI / API / MCP servers (primary) — no portal UI required | — | HTTPS (API/MCP) + Kubernetes API (`kubectl`-compatible) |
| 2. Capability Contract — provisioning-time | KubeVela (OAM): `ComponentDefinition` / `TraitDefinition` / `WorkflowStepDefinition` | KCL (or CUE) | Kubernetes CRD, served by the API server |
| 2. Capability Contract — runtime-callable | wasmCloud capabilities | WIT (WebAssembly Interface Types) | wRPC (over NATS, TCP, or QUIC) |
| 3. Policy & Ownership Graph | DataHub (graph) + OpenFGA (access decisions) | DataHub aspects (Pegasus PDL schemas) / OpenFGA authorization model (`.fga`) | DataHub: REST + GraphQL (GMS) + Kafka (MCL events) · OpenFGA: gRPC (`Check`/`Write`), REST proxy available |
| 4. Provider Adapter — infra/data/secrets/network | Crossplane Providers + Composition Functions | KCL or CUE (composition function body) | Kubernetes controller reconcile loop (watch/apply against the API server) |
| 4. Provider Adapter — CI/CD pipeline logic | Dagger | Go / Python / TypeScript / CUE / shell (Dagger SDKs) | Dagger Engine GraphQL API (session-local), triggered by each CI runner's native webhook |
| 4. Provider Adapter — runtime-callable capabilities | wasmCloud capability providers | any language, implementing a WIT world | wRPC |
| 5. Concrete Vendor | AWS/GCP/Datadog/GitHub/Okta/etc. | — | each vendor's own REST/gRPC API — deliberately not abstracted at this layer |

The point of this table: nothing above required us to invent a format. The
work is wiring these together and writing the `KCL`/`WIT` definitions
specific to our capability map — not building a contract engine from zero.

## Layer schemas

### Capability Contract — provisioning-time (OAM `ComponentDefinition`)

Written as a KCL schema that KubeVela compiles against incoming `Application`
manifests:

```python
# contracts/observability.k
schema Observability:
    name: str
    metricType: "counter" | "gauge" | "histogram"
    alertCondition?: str
    severity?: "page" | "ticket" | "info"

# the CUE/KCL template below is what KubeVela actually renders per binding —
# see Provider Adapter, this is the half that stays vendor-neutral
```

The OAM `ComponentDefinition` wraps this schema as a Kubernetes CRD, so
`kubectl apply -f` (or the developer portal calling the same API) is the
submission path from Layer 1. Rules: a `ComponentDefinition`'s schema fields
are additive-only within a version; a `TraitDefinition` composes onto it
(e.g. a `scaler` trait) without the component needing to know which trait is
attached. No vendor name or vendor-specific field is permitted in the schema
— that knowledge lives only in the render template, selected by the Binding
Policy.

### Capability Contract — runtime-callable (WIT)

For capabilities an application calls at runtime rather than provisions
once (secrets access, metric emission):

```wit
// contracts/secrets.wit
package platform:secrets@1.0.0;

interface store {
  record secret { key: string, value: string }
  get: func(key: string) -> result<secret, string>;
  rotate: func(key: string) -> result<_, string>;
}

world secrets-capability {
  export store;
}
```

Any wasmCloud capability provider implementing the `secrets-capability`
world can back this — Vault, AWS Secrets Manager, GCP Secret Manager — and
the application component calls `store.get` over wRPC without knowing which
one is wired up. This is the one place in the whole design where "the
contract" is a literal callable interface rather than a provisioning
schema; use it only for capabilities invoked from running app code, not for
things that are provisioned once and then left alone.

### Binding Policy

Still a plain git file — none of the DSLs above are a good fit for "which
provider, per tenant/environment/region," so this stays custom:

```yaml
# bindings/observability.yaml
kind: BindingPolicy
capability: observability
rules:
  - match: { tenant: "*", environment: production }
    provider: datadog
  - match: { tenant: team-payments, environment: "*" }
    provider: dynatrace
  - match: { tenant: "*", environment: "*" }
    provider: datadog
```

Rules: evaluated top-to-bottom, first match wins. Must end in a `"*"/"*"/"*"`
default rule. This file is the only place a vendor name may appear outside
the Provider Adapter layer itself. **Protocol:** read by the KubeVela
application controller's reconcile loop (a Kubernetes API server watch on
this file once it's applied as a ConfigMap/CRD) — not polled, and not
read directly by developer-facing tooling.

### Provider Adapter

Three different concrete forms, one per domain family:

**Crossplane Composition Function, in KCL** (infra/data/secrets/network):
```python
# adapters/observability/datadog/compose.k
import crossplane.function as fn

def compose(req):
    obs = req.observed.composite.spec
    return fn.Resource(
        name = "datadog-monitor",
        resource = {
            "apiVersion": "monitors.datadog.upbound.io/v1",
            "kind": "Monitor",
            "spec": {
                "forProvider": {
                    "type": obs.metricType,
                    "query": obs.alertCondition,
                }
            },
        },
    )
```
Registers as a `ProviderAdapter` by declaring which `Capability.name` and
version it implements; Crossplane's own test harness (`crossplane render`)
is the contract test suite — it must render successfully against every
example in the contract's test fixtures to be allowed to register.

**Dagger pipeline function** (CI/CD):
```python
# adapters/ci-pipeline/dagger/pipeline.py
import dagger

@dagger.function
async def build_and_test(source: dagger.Directory) -> str:
    return await (
        dagger.container().from_("golang:1.23")
        .with_mounted_directory("/src", source)
        .with_workdir("/src")
        .with_exec(["go", "test", "./..."])
        .stdout()
    )
```
The pipeline *logic* itself is vendor-neutral and runs inside the Dagger
Engine, identically on a laptop or in any CI. What's **not** abstracted, on
purpose, is CI-native plumbing: triggering, checkout, secret injection, and
status reporting stay with each tool, because that's what each one does
well and there's no benefit to hiding it. Concretely:

- **GitHub Actions**: the `dagger/dagger-for-github` Action finds/starts a
  Dagger Engine on the runner, then runs `dagger call build-and-test`. The
  workflow YAML still owns checkout, secrets, and trigger conditions.
- **Jenkins**: a `Jenkinsfile` stage just shells out — `sh 'dagger call
  build-and-test'` — no plugin required.
- **Argo Workflows**: a `WorkflowTemplate` step runs a container with the
  Dagger CLI and makes the same call; Argo's own DAG/retry features still
  apply at the workflow level around that one step.

In every case, the only vendor-specific artifact is that one-line call plus
the surrounding native trigger/checkout/secrets config — analogous to the
Binding Policy's role for every other domain, just thinner than "does
nothing but invoke the call" implies.

**wasmCloud capability provider** (runtime-callable):
implements the WIT `world` from the contract above, in any language,
deployed as its own OCI artifact and wired to a component via a wasmCloud
`link` — the link definition (`component ↔ provider`, scoped by `link_name`)
is this domain's equivalent of a Binding Policy rule.

### Ownership / policy graph entities

```yaml
kind: Component            # a service, job, or dataset
name: string
owner: string               # Team or User id — the single source of truth
capability-bindings: [string]  # which capability instances this component uses

kind: Team
name: string
roles: [string]

kind: Role
name: string
grants: [{ capability: string, verbs: [string] }]
```

Relationships: `Component --owned-by--> Team --has-role--> Role --grants-->
Permission(capability, verb)`. Vendor-native IAM objects (AWS IAM roles,
GitHub teams, Datadog RBAC roles, Okta groups) are **generated** from this
graph by sync controllers and are never a source of truth — direct edits to
them are overwritten on the next reconciliation pass.

#### Reference implementation: DataHub (graph) + OpenFGA (access decisions)

**DataHub side — entities as urns, custom fields as aspects:**

```
urn:li:component:checkout-service
  aspect ownershipV2:        { owners: ["urn:li:team:team-checkout"] }
  aspect capabilityBindings: { bindings: ["urn:li:capabilityinstance:..."] }

urn:li:team:team-checkout
  aspect roles: { roles: ["urn:li:role:service-owner"] }
```
`Component`, `Team`, `Role`, `BindingPolicy`, `Tenant`, and
`CapabilityInstance` are each registered as DataHub custom entity types; the
fields in the YAML schemas above become custom aspects on them. **Protocol:**
writes go through the GMS REST/GraphQL API — the same API an MCP server or
CLI calls directly, no portal in between; ingestion sources (GitHub,
Kubernetes, cloud providers, CI) push into the same API, and every write
emits a Metadata Change Log (MCL) event onto a Kafka topic
(`MetadataChangeLog_v1`).

**Audit log, provided by DataHub, not built separately:** every aspect
create/update/removal is that same MCL event, retained as queryable version
history via the Timeline API — including for custom entity types like
`Component`. There is no separate audit-log component to run.

**OpenFGA side — the same entities, expressed as relation tuples:**

```
# authorization model (simplified)
type component
  relations
    define owner: [team]
    define can_configure: owner

type team
  relations
    define member: [user]
    define has_role: [role]

type role
  relations
    define grants: [capability#verb]
```
```
# tuples (written whenever the Backstage entity above changes)
component:checkout-service#owner@team:team-checkout
team:team-checkout#has_role@role:service-owner
```
OpenFGA never stores its own copy of "what exists" — only relation tuples
keyed by the same urns/ids DataHub holds. **Protocol:** a sync job
*consumes* the `MetadataChangeLog_v1` Kafka topic and *calls* OpenFGA's
`Write` gRPC RPC to rewrite the affected tuples; access checks elsewhere in
the platform call OpenFGA's `Check` gRPC RPC (synchronous, low-latency —
this is the call an admission webhook or an MCP tool call makes, not
something that goes through Kafka).

## Protocol map between every layer boundary

This is the part worth pinning down precisely, since "vendor-neutral
contract" only holds if the boundaries themselves are well-defined:

| From → To | Protocol | Sync/async |
|---|---|---|
| Developer Interface (CLI/API/MCP) → Capability Contract | `kubectl apply`-equivalent against the Kubernetes API server (OAM `Application` CRD) | Sync (admission), async (reconcile) |
| Capability Contract → Policy & Ownership Graph | Admission webhook calls OpenFGA `Check` (gRPC) before the Application is admitted | Sync |
| Capability Contract → Provider Adapter | KubeVela/Crossplane controller reconcile loop reads the Binding Policy (Kubernetes API watch) to pick which Composition/adapter to invoke | Async (continuous reconciliation) |
| Provider Adapter → Concrete Vendor | Each adapter's own vendor SDK/API call (Crossplane Provider → vendor REST/gRPC API; Dagger → CI runner's native API; wasmCloud provider → vendor SDK over wRPC from the component) | Varies per vendor — intentionally not abstracted here |
| Any ingestion source → Policy & Ownership Graph | Push or poll into DataHub's GMS REST/GraphQL ingestion API | Async |
| Policy & Ownership Graph (DataHub) → Policy & Ownership Graph (OpenFGA) | Kafka topic `MetadataChangeLog_v1` consumed by the sync job, which calls OpenFGA `Write` (gRPC) | Async, at-least-once |
| Policy & Ownership Graph (OpenFGA) → Provider Adapter / sync controllers | IAM sync controllers call OpenFGA `Check`/`Expand` (gRPC) to decide what to reconcile into each vendor's native IAM, then call that vendor's own IAM API | Async (reconcile loop), with the OpenFGA call itself synchronous |
| CI/CD trigger (vendor-specific) → Provider Adapter (Dagger) | GitHub Actions/Jenkins/Argo Workflows native webhook invokes `dagger call <function>` against the Dagger Engine's local GraphQL API | Sync within the pipeline run |
| Application component → runtime-callable capability | wRPC call against the WIT interface, routed by wasmCloud's link definition to whichever capability provider is linked | Sync |

## Domain → abstraction mapping

| Diagram domain (capability) | Contract covers | Example interchangeable providers |
|---|---|---|
| Observability Stack | emit-metric, define-alert, dashboard, trace | Datadog, Dynatrace, Grafana/Mimir |
| CI pipelines | build, test-stage, promote, artifact — via Dagger | GitHub Actions, Jenkins, Argo Workflows |
| CD / GitOps | sync, rollout, rollback | Argo CD, Flux |
| Compute Provider / Infra provisioning (IaC) | compute instance, module apply — via Crossplane | AWS, GCP, on-prem Kubernetes |
| SQL / NoSQL / Cache / Object storage | database claim (engine, tier) — via Crossplane | RDS/Cloud SQL, DynamoDB/Firestore, self-hosted |
| Secret Store | get/set secret, rotate — via WIT/wasmCloud (runtime-callable) | Vault, AWS Secrets Manager, GCP Secret Manager |
| Ingress / DNS / Certificate Manager | route, certificate, record | NGINX/Istio Gateway API, Route53/CloudDNS |
| Identity Provider | authenticate, group membership | Okta, Entra ID, Google Workspace |
| Software catalog / ownership graph | entity + aspect CRUD, relations, search | DataHub (chosen), OpenMetadata, Backstage catalog |
| Policy engine | evaluate(principal, action, resource) | OpenFGA (chosen), OPA, Cedar |

## File layout convention

```
contracts/<capability>.k            # KCL schema backing an OAM ComponentDefinition
contracts/<capability>.wit          # WIT world, for runtime-callable capabilities only
adapters/<capability>/<provider>/   # Crossplane Composition Function (KCL/CUE) or Dagger pipeline
bindings/<capability>.yaml
catalog/components/<name>.yaml
catalog/teams/<name>.yaml
datahub/entities/<entity-type>.yaml       # custom entity type + aspect registrations
datahub/ingestion/<source>-recipe.yaml    # DataHub ingestion source configs
openfga/model.fga                          # authorization model (types/relations)
openfga/sync/                              # Kafka consumer rewriting tuples from DataHub events
dagger/                                    # Dagger SDK pipeline modules, one per CI/CD capability
```
All of the above are git-versioned; reconciliation runs on merge to main.
