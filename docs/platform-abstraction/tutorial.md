# Tutorial: build your first abstracted capability

**Goal:** take one real capability — Observability — from "developers call
Datadog directly" to "developers declare intent, the platform resolves the
vendor." By the end you'll have a capability contract, two interchangeable
provider adapters, a binding policy, and ownership flowing through the graph
instead of through Datadog's native RBAC.

This is a learning exercise — follow it in order, on a throwaway capability
first, before touching anything real.

## 1. Write the capability contract

Create the vendor-neutral schema a service author will actually use. Keep the
verb set small — resist adding anything Datadog-specific:

```yaml
# contracts/observability.yaml
kind: Capability
name: observability
version: v1
verbs:
  - emit-metric: { name: string, type: counter|gauge|histogram, labels: map }
  - define-alert: { metric: string, condition: string, severity: string }
  - dashboard: { title: string, panels: list }
```

## 2. Write two provider adapters

Each adapter implements the same verbs against a different backend. Keep them
thin — translation only, no business logic:

```
adapters/observability/datadog/   # emit-metric -> DogStatsD, define-alert -> Datadog Monitor API
adapters/observability/dynatrace/ # emit-metric -> Dynatrace OneAgent SDK, define-alert -> Dynatrace Problem API
```

Verify both adapters pass the same contract test suite (see
[reference.md](./reference.md#provider-adapter-interface)) before wiring
anything else up.

## 3. Write the binding policy

This is the *only* file that names a vendor:

```yaml
# bindings/observability.yaml
kind: BindingPolicy
capability: observability
rules:
  - match: { tenant: "*", environment: production }
    provider: datadog
  - match: { tenant: team-payments, environment: "*" }
    provider: dynatrace   # payments already standardized on Dynatrace
  - match: { tenant: "*", environment: "*" }
    provider: datadog     # default
```

## 4. Wire a golden-path template

Your service scaffolding template references the contract, never a vendor:

```yaml
# golden-paths/web-service/observability.yaml
capability: observability
emit-metric: { name: request_latency_ms, type: histogram }
define-alert: { metric: request_latency_ms, condition: "p99 > 300ms", severity: page }
```

Scaffold a test service from this template and confirm the alert actually
shows up in Datadog (default binding) — then flip the binding policy's default
to `dynatrace` and re-provision the *same* service with *no* template change.
That round-trip is the whole point of the exercise.

## 5. Add ownership and confirm it flows

Register the test service in the catalog with an owning team:

```yaml
kind: Component
name: test-service
owner: team-payments
```

Confirm, without touching Datadog/Dynatrace directly, that:
- the policy engine grants `team-payments` access to the service's alerts,
- a sync controller has created the corresponding native role/group in
  whichever provider the binding policy selected.

Now change `owner: team-payments` to `owner: team-checkout` and re-run the
sync controller. Confirm access moved — and that you touched exactly one YAML
field to do it.

If all five steps hold, you've proven the pattern end-to-end on a disposable
capability. [how-to-guides.md](./how-to-guides.md) covers doing this for real.
