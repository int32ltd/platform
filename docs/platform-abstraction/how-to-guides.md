# How-to guides

Task-oriented recipes. Each assumes the contract/adapter/binding pattern from
[tutorial.md](./tutorial.md) and the schemas in [reference.md](./reference.md).

## How to add a new provider adapter for an existing capability

1. Implement every verb in the capability contract against the new vendor.
2. Run the contract's test suite against the adapter — it must pass
   unmodified; if it doesn't, the vendor can't actually fulfill the contract
   as written (don't weaken the contract to fit one vendor).
3. Add the adapter to the provider registry.
4. Do **not** change the binding policy yet — ship the adapter dark first.
5. Add a binding policy rule scoped to one low-risk tenant/environment,
   verify, then widen the match.

## How to add a brand-new capability type

1. Draft the verb set. Keep it to the smallest set of operations every
   current and plausible-future provider can implement — this is the
   contract everyone is stuck with later, so under-specify rather than
   over-fit to today's incumbent vendor.
2. Write a reference adapter for whichever vendor is already in use.
3. Write the contract test suite before writing a second adapter — it's the
   spec, and it should fail against an adapter that leaks vendor-specific
   behavior.
4. Add the capability + its default binding policy to the catalog so it's
   discoverable from the developer portal/CLI.

## How to change which provider backs a capability

For new instances only (no live migration):

```yaml
# bindings/<capability>.yaml
rules:
  - match: { tenant: team-x, environment: production }
    provider: new-vendor
```
Commit, merge, done — the next provisioning request for that match resolves
to the new provider. Existing instances are untouched.

To migrate *existing* live instances to a new provider, that's a deliberate
reconciliation run, not a side effect of editing the binding policy — treat it
as its own change with its own rollback plan.

## How to transfer service/code ownership

1. Update the catalog entity:
   ```yaml
   kind: Component
   name: checkout-service
   owner: team-checkout   # was: team-payments
   ```
2. Merge the change — the ownership graph is git-backed, so this is a normal
   PR with normal review.
3. Confirm the sync controllers reconciled: old team's access revoked, new
   team's access granted, across every provider this service touches
   (source control, CI, observability, cloud IAM) — in one pass, from one
   edit.
4. Check the audit log entry references the graph mutation, not N separate
   per-vendor IAM events.

Never grant/revoke access directly in a vendor's console as a shortcut — it
will be overwritten on the next reconciliation pass, and it breaks the single
audit trail.

## How to onboard a new tenant/team

1. Create the tenant entity in the catalog.
2. Assign default quotas/resource limits (Tenancy & Environments domain).
3. The binding policy's wildcard (`match: { tenant: "*" }`) rules apply
   automatically — only add tenant-specific overrides if this tenant
   genuinely needs a different provider (e.g. a team standardized on a
   different observability vendor pre-acquisition).
4. New services registered under this tenant inherit ownership/RBAC from the
   graph with no extra steps.

## How to audit who can access what

Query the ownership graph and policy engine directly — never reconstruct
access by cross-referencing vendor consoles:

```
policy-cli explain --component checkout-service --principal alice@co.com
```
This returns the graph path (`Component → owner → Team → role → Permission`)
that produced the decision, which is also what the audit log records.
