# Tutorial: follow one request through every layer

**Goal:** see the pattern work end to end before you build any of it. You'll
send one vendor-neutral observability request through a small simulation of
the platform, watch each layer handle its part, and then make the two changes
the design promises are cheap: swapping the vendor, and moving ownership to
another team.

Everything runs locally in
[`demos/platform-abstraction/`](../../demos/platform-abstraction/). Nothing real
is installed or called. Vendor API calls are printed, not sent.

## Before you start

You need Python 3 and one package:

```
pip install pyyaml
cd demos/platform-abstraction
```

Run every command below from that directory.

## 1. Send a request through every layer

A developer asks for a latency metric and an alert. Here is everything they
write:

```yaml
# requests/checkout-latency.yaml
capability: observability
emit-metric:
  name: request_latency_ms
  type: histogram
define-alert:
  metric: request_latency_ms
  condition: "p99 > 300ms"
  severity: page
```

There's no vendor anywhere in that file. Apply it as `team-payments`, for the
`checkout-service` component, in production:

```
python3 platform.py apply requests/checkout-latency.yaml \
  --component checkout-service --team team-payments \
  --tenant team-growth --environment production
```

You'll see six numbered steps:

```
[1 Developer Interface] read request 'requests/checkout-latency.yaml'
[2 Capability Contract] validating against 'contracts/observability.yaml'
    ok — every verb/field is declared in the contract
[3 Policy & Ownership Graph] does 'team-payments' own 'checkout-service' and may it use 'observability'?
    ALLOWED — 'team-payments' owns 'checkout-service' and is granted 'observability'
[4 Binding Policy] resolving provider for tenant='team-growth' environment='production'
    -> provider: datadog
[5 Provider Adapter] translating verbs for 'datadog'
[6 Concrete Vendor] (simulated) calls:
    POST https://api.datadoghq.com/api/v1/series
    ...
```

The vendor only shows up at step 4. Everything before it is vendor-neutral.

## 2. Watch the contract reject a vendor-specific field

Open `contracts/observability.yaml`. It lists the verbs (`emit-metric`,
`define-alert`) and the fields each one accepts. Nothing else gets through.

Add a Datadog-only field to a copy of the request:

```
cp requests/checkout-latency.yaml /tmp/bad.yaml
printf '  vendor_tag: datadog-specific\n' >> /tmp/bad.yaml
```

That appends `vendor_tag` under `define-alert`. Apply it:

```
python3 platform.py apply /tmp/bad.yaml --component checkout-service \
  --team team-payments --tenant team-growth --environment production
```

The run stops at step 2 with `REJECTED`. No later layer runs. This is how
vendor details are kept out of developer config: the contract won't accept
them.

## 3. Watch the ownership graph deny a team

Open `catalog/components.yaml`. `checkout-service` is owned by
`team-payments`. Now apply the original request as a different team:

```
python3 platform.py apply requests/checkout-latency.yaml \
  --component checkout-service --team team-checkout \
  --tenant team-growth --environment production
```

Step 3 prints:

```
DENIED — 'team-checkout' does not own 'checkout-service' (owner is 'team-payments')
```

The decision comes from the catalog, not from Datadog's own user management.

## 4. Swap the vendor without touching the request

Open `bindings/observability.yaml`. It's the only file in the demo that names
a vendor. The first matching rule wins:

```yaml
rules:
  - match: { tenant: "*", environment: production }
    provider: datadog
  ...
```

Change that first rule's provider to `dynatrace`, save, and re-run the
**exact** command from step 1. Steps 1 to 3 print the same as before. Step 4
now resolves to `dynatrace`, and step 6 prints Dynatrace API calls in place of
Datadog ones.

You changed one line in one file. The request, the contract and the ownership
check didn't change.

Change the rule back to `datadog` before moving on.

## 5. Move ownership with one edit

Ask the platform why `team-payments` has access:

```
python3 platform.py explain --component checkout-service --team team-payments
```

```
[Policy & Ownership Graph] graph path:
    Component(checkout-service) --owned-by--> Team(team-payments) --grants--> ['observability']
[decision for team='team-payments'] ALLOWED — ...
```

Access is a path through the graph. Now hand the service to another team:

```
python3 platform.py transfer-ownership --component checkout-service --new-team team-checkout
```

Run `explain` again for both teams:

```
python3 platform.py explain --component checkout-service --team team-payments    # DENIED
python3 platform.py explain --component checkout-service --team team-checkout    # ALLOWED
```

Access moved because one field (`owner`) changed. Nobody edited anything in
the vendor tools.

Put the original owner back when you're done:

```
git checkout catalog/components.yaml
```

## What you've seen

- Developers write requests against a **contract**, which rejects anything
  vendor-specific.
- The **ownership graph** decides access. Vendor permission settings aren't
  involved.
- The **binding policy** is the only place a vendor is named, so changing
  vendors means editing one file.
- Moving ownership means editing one field, and access follows from it.

The demo runs every step synchronously in one process. In the real design
these are separate systems, and [explanation.md](./explanation.md) covers why
the boundaries are where they are and what they cost. To do this for real, go
to [how-to-guides.md](./how-to-guides.md), starting with
[rolling the pattern out on a first real capability](./how-to-guides.md#how-to-roll-out-the-pattern-on-a-first-real-capability).
