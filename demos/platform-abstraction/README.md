# Platform abstraction demo

A tiny, runnable simulation of the design in
[`docs/platform-abstraction/`](../../docs/platform-abstraction/). It doesn't
install any real infrastructure: no Kubernetes, no Kafka, no vendor accounts.
Each layer is a plain Python module and a small YAML file, and vendor calls are
printed, not made. The point is to make the *boundaries between layers* visible
and testable, not to be production-ready.

One capability is modeled end to end: **observability** (`emit-metric`,
`define-alert`), with two interchangeable fake providers, Datadog and
Dynatrace.

**To learn the design with this demo, follow the
[tutorial](../../docs/platform-abstraction/tutorial.md).** This README is the
quick reference.

## Setup

```
pip install pyyaml   # the only dependency
cd demos/platform-abstraction
```

## Commands

```
# run a request through every layer
python3 platform.py apply requests/checkout-latency.yaml \
  --component checkout-service --team team-payments \
  --tenant team-growth --environment production

# show the graph path behind an access decision
python3 platform.py explain --component checkout-service --team team-payments

# move a component to another team (rewrites catalog/components.yaml;
# restore with `git checkout catalog/components.yaml`)
python3 platform.py transfer-ownership --component checkout-service --new-team team-checkout
```

## What maps to what

| File in this demo | Layer (see [reference.md](../../docs/platform-abstraction/reference.md)) | Stands in for |
|---|---|---|
| `platform.py` | 1. Developer Interface | CLI / API / MCP server |
| `contracts/observability.yaml` | 2. Capability Contract | KubeVela `ComponentDefinition` (KCL schema) |
| `catalog/components.yaml`, `catalog/teams.yaml` | 3. Policy & Ownership Graph | DataHub (entities/aspects) + OpenFGA (access decisions) |
| `bindings/observability.yaml` | 4. Binding Policy | the one git file allowed to name a vendor |
| `layers/adapters.py` | 4/6. Provider Adapter + Concrete Vendor | Crossplane Composition Function / vendor SDK call |
| `requests/checkout-latency.yaml` | developer input | a golden-path template's output |

## What's intentionally not modeled

Everything real infra (Kubernetes reconciliation, Kafka, gRPC, OpenFGA,
Crossplane) does asynchronously happens here as a synchronous function call.
The demo keeps the *data flow and boundaries* from the docs, not the runtime
mechanics. See
[explanation.md](../../docs/platform-abstraction/explanation.md) for why those
boundaries exist and what they cost in the real design.
