# Data store

The PostgreSQL database behind the [service catalog](../service-catalog/):
kinds, resources, links and per-source provenance; ownership and flattened
membership derived inside the write transaction; one permission-filtered read
surface; and a change log that doubles as the audit trail and the outbox.

This is the detailed design of the "Postgres-backed catalog service" chosen in
[`../service-catalog/explanation.md`](../service-catalog/explanation.md#why-postgres-and-not-datahub).

| Quadrant | Question it answers | Document |
|---|---|---|
| Tutorial | "Show me it working." | [tutorial.md](./tutorial.md) |
| Reference | "What exactly are the tables, functions, views and roles?" | [reference.md](./reference.md) |
| Explanation | "Why is it built this way?" | [explanation.md](./explanation.md) |

The runnable version is [`demos/data-store/`](../../demos/data-store/): the full
schema plus the ownership demo's worked graph, in a throwaway Postgres 18 pod
in its own `catalog-data-store` namespace. `./demo.sh up && ./demo.sh walkthrough` runs the whole tour.

For a visual guide, open the
[schema page](../../demos/data-store/index.html) and its companion,
[How it works](../../demos/data-store/flows.html) (worked scenarios: define a
kind, create an instance, apply permissions, move ownership), in a browser
(on the local environment, `./demo.sh pages` serves them at
https://catalog-data-store.dev.test/data-store/). The schema page shows every table, view and function, what writes each one,
and the logic behind it. Both must be kept current with the schema (see
[CONTRIBUTING](../../CONTRIBUTING.md#keep-the-data-store-schema-page-current)),
and `./demo.sh test` fails while it is out of date.

## At a glance

```
                    sources (entra-id, hris, github, kubernetes, aws, …)
                                         │
                       catalog.ingest / retract / runs
                                         ▼
 ┌─ catalog ───────────────────────────────────────────────────────────────┐
 │  kind ── link_type        source ── property_claim      ingestion_run   │
 │                                                                         │
 │  resource ◄── resource_source (observed, per source)                    │
 │    │  properties (merged)  property_provenance  effective_owners        │
 │    └── link (per edge, per source; to_id null = dangling)               │
 │                                                                         │
 │  change_log (append-only, monthly partitions, outbox) ──► consumers     │
 └─────────────────────────────────────────────────────────────────────────┘
          │ resolver + membership projection (same transaction)
          ▼
 ┌─ authz ─────────────────────┐     ┌─ api (the API role reads only this) ┐
 │ user_team  user_role        │────►│ resource  link  change  kind        │
 │ access_grant (from links)   │     │ get  search  who_owns  context      │
 │ fga_tuples (→ OpenFGA sync) │     │ changes_since  update               │
 └─────────────────────────────┘     └─────────────────────────────────────┘
```
