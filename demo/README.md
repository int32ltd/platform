# Platform abstraction demo

A tiny, runnable simulation of the architecture described in
[`../docs/platform-abstraction/`](../docs/platform-abstraction/). It doesn't
install any real infrastructure — no Kubernetes, no Kafka, no vendor
accounts. Each layer is a plain Python module and a small YAML file; vendor
calls are printed, not made. The point is to make the *boundaries between
layers* visible and testable, not to be production-ready.

One capability is modeled end-to-end: **observability** (`emit-metric`,
`define-alert`), with two interchangeable fake providers: Datadog and
Dynatrace.

## Setup

```
pip install pyyaml   # the only dependency
```

## What maps to what

| File in this demo | Layer (see `../docs/platform-abstraction/reference.md`) | Stands in for |
|---|---|---|
| `platform.py` | 1. Developer Interface | CLI / API / MCP server |
| `contracts/observability.yaml` | 2. Capability Contract | KubeVela `ComponentDefinition` (KCL schema) |
| `catalog/components.yaml`, `catalog/teams.yaml` | 3. Policy & Ownership Graph | DataHub (entities/aspects) + OpenFGA (access decisions) |
| `bindings/observability.yaml` | 4. Binding Policy | the one git file allowed to name a vendor |
| `layers/adapters.py` | 4/6. Provider Adapter + Concrete Vendor | Crossplane Composition Function / vendor SDK call |

## Run it

```
cd demo
python3 platform.py apply requests/checkout-latency.yaml \
  --component checkout-service --team team-payments \
  --tenant team-growth --environment production
```

This prints all six steps in order: read the request, validate it against
the contract, check `team-payments` actually owns `checkout-service` and is
granted `observability`, resolve a provider from the binding policy, then
print the (simulated) Datadog calls the adapter would make.

### Try the two failure paths

```
# contract rejects an undeclared field, before any later layer runs
python3 - <<'EOF' > /tmp/bad.yaml
import yaml
r = yaml.safe_load(open("requests/checkout-latency.yaml"))
r["emit-metric"]["vendor_tag"] = "datadog-specific"
yaml.safe_dump(r, open("/tmp/bad.yaml", "w"))
EOF
python3 platform.py apply /tmp/bad.yaml --component checkout-service \
  --team team-payments --tenant team-growth --environment production

# ownership graph denies a team that doesn't own the component
python3 platform.py apply requests/checkout-latency.yaml \
  --component checkout-service --team team-checkout \
  --tenant team-growth --environment production
```

## Prove claim 1: swapping vendors never touches the request

Run the `apply` command above once — note it resolves to `datadog`. Now edit
*only* the first rule in `bindings/observability.yaml`:

```yaml
  - match: { tenant: "*", environment: production }
    provider: dynatrace   # was: datadog
```

Re-run the **exact same** `apply` command with the **exact same**
`requests/checkout-latency.yaml`. Only steps 4–6 change (provider +
vendor-shaped payload) — the request, the contract, and the ownership check
are untouched. Revert the rule back to `datadog` when done.

## Prove claim 2: moving ownership is one edit, and access recalculates from it

```
python3 platform.py explain --component checkout-service --team team-payments
# -> ALLOWED

python3 platform.py transfer-ownership --component checkout-service --new-team team-checkout

python3 platform.py explain --component checkout-service --team team-payments
# -> DENIED (no longer the owner)

python3 platform.py explain --component checkout-service --team team-checkout
# -> ALLOWED (ownership moved with one field edit, no other file touched)
```

`transfer-ownership` rewrites `catalog/components.yaml` back to
`owner: team-checkout` afterward — restore it with:

```yaml
components:
  checkout-service:
    owner: team-payments
    capability-bindings: [observability]
```

## What's intentionally not modeled

Everything real infra (Kubernetes reconciliation, Kafka, gRPC, OpenFGA,
Crossplane) does asynchronously here just happens as a synchronous function
call — the demo keeps the *data flow and boundaries* from the docs, not the
runtime mechanics. See `../docs/platform-abstraction/explanation.md` for why
those boundaries exist and what they cost in the real design.
