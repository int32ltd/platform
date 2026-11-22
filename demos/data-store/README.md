# Data store demo

The catalog's PostgreSQL store, running for real: the full schema from
[`docs/data-store/`](../../docs/data-store/), loaded with the same worked graph
as the [ownership demo](../service-catalog-ownership/) (five people, five
identity groups, three teams, two systems, three components, six pieces of
infrastructure). Every fact in the seed arrives through `catalog.ingest` from
the source that owns it.

Needs `kubectl` and a Kubernetes cluster; a local kind cluster is enough.
Everything runs in the `catalog-data-store` namespace (one `postgres:18.2-trixie`
pod, data in an `emptyDir`), and nothing outside it is touched.

```
./demo.sh up            # deploy k8s.yaml, recreate the catalog database, load sql/*.sql
./demo.sh walkthrough   # the guided tour: 11 steps, prints SQL and results
./demo.sh test          # invariant checks, in a rolled-back transaction
./demo.sh psql          # explore by hand
./demo.sh down          # delete the namespace; nothing persists
```

The walkthrough changes data, so run it on a fresh database. `./demo.sh up`
always starts from the seed. The [tutorial](../../docs/data-store/tutorial.md)
covers the same steps with commentary.

## Files

| File | What it is |
|---|---|
| [`sql/00-roles.sql`](./sql/00-roles.sql) | database roles: `catalog_owner`, `catalog_api`, `catalog_ingest`, `catalog_consumer`, `catalog_auditor` |
| [`sql/01-schema.sql`](./sql/01-schema.sql) | schemas, types, tables, indexes, change-log partitions |
| [`sql/02-graph.sql`](./sql/02-graph.sql) | link validation, dangling attachment, single-valued precedence, property merge, ownership resolver, membership projection |
| [`sql/03-write.sql`](./sql/03-write.sql) | `ingest`, `retract`, full-sync runs and sweep, outbox polling, `define_kind` / `define_source` |
| [`sql/04-access.sql`](./sql/04-access.sql) | the viewer functions, `api.*` views and functions, `authz.fga_tuples`, privileges |
| [`sql/05-seed.sql`](./sql/05-seed.sql) | kinds, sources and the worked graph |
| [`walkthrough.sql`](./walkthrough.sql) | the guided tour |
| [`test.sql`](./test.sql) | invariant checks, including the OpenFGA consistency check |
| [`k8s.yaml`](./k8s.yaml) | namespace, Postgres 18 StatefulSet (emptyDir) and Service |
| [`demo.sh`](./demo.sh) | deploy, load, run and connect, using `kubectl` |

## Trying things by hand

```sql
-- be the catalog service, acting for Carol (Search)
set role catalog_api;
set catalog.viewer = 'user:carol';
select ref, effective_owners, redacted from api.resource order by ref;
select * from api.who_owns('component:cart-service');
select jsonb_pretty(api.context(array['component:checkout-service'], 1));

-- back to the superuser to see the facts underneath
reset role;
select * from authz.access_matrix('component:checkout-service');
table authz.fga_tuples;
```

For a GUI client, forward the port:
`kubectl -n catalog-data-store port-forward svc/postgres 5433:5432`, then
connect to `postgres://postgres:postgres@127.0.0.1:5433/catalog`.
