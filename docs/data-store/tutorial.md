# Data store tutorial

In this tutorial you load the catalog's PostgreSQL store into the local environment's shared
PostgreSQL, load
the worked example from the
[ownership demo](../../demos/service-catalog-ownership/), and use plain SQL to
watch ownership, access and history follow the graph. It takes about twenty
minutes. You need `kubectl`, `python3` and the local kind environment (`localenv`), whose
shared PostgreSQL holds the demo database.

You will:

1. start the store and look at the map;
2. see one resource assembled from four sources;
3. ask who owns something, and why;
4. see the same data through four people's eyes;
5. move ownership, tag an orphan and offboard a contractor, and watch access
   follow;
6. let infrastructure arrive before its component;
7. stop a broken sync from deleting the map;
8. read the change log the way a consumer, a user and an agent do.

If you'd rather see it all at once, `./demo.sh walkthrough` runs every step
below in one go.

## 1. Start the store

```
cd demos/data-store
./demo.sh up
./demo.sh psql
```

`up` runs `localenv apps apply` on `.localenv.yaml`, which gives the demo database
`catalog_data_store` on the local environment's shared PostgreSQL, plus the four roles it
separates privileges with (`catalog_data_store_api` and others). It then deploys a `psql` client
pod and OpenFGA (`k8s.yaml`), drops and recreates the demo's schemas, and runs
`sql/00-roles.sql` to `sql/05-seed.sql` as the database owner. The seed does not insert rows directly: every fact arrives
through `catalog.ingest`, from the source that owns it, in the order real
connectors would deliver it. `./demo.sh up` again always gives you a fresh copy.

No local environment? `CATALOG_PG=standalone ./demo.sh up` runs on any Kubernetes cluster
with its own Postgres, creating the same database, roles and Secret. CI uses it.

Count what is there:

```sql
select kind, count(*) as resources,
       count(*) filter (where effective_owners = '{}') as unowned
  from catalog.resource
 where deleted_at is null and kind not in ('kind', 'source')
 group by kind order by kind;
```

```
       kind       | resources | unowned
------------------+-----------+---------
 aws_rds_instance |         1 |       0
 aws_sqs_queue    |         2 |       1
 component        |         3 |       0
 identity_group   |         5 |       5
 ...
 user             |         5 |       5
```

Every resource of every kind is a row in one table. The kinds themselves are
rows too:

```sql
select kind_id, name, target_kinds, many, ownership
  from catalog.link_type where kind_id = 'component';
```

```
  kind_id  |   name    | target_kinds | many | ownership
-----------+-----------+--------------+------+-----------
 component | dependsOn | {component}  | t    |
 component | owner     | {team}       | f    | grants
 component | repo      | {repository} | f    |
 component | system    | {system}     | f    | inherits
```

`grants` names an owner; `inherits` lets a resource take its owner from what
it points at. That is all the resolver needs to know.

## 2. One resource, four sources

```sql
select source_id, observed
  from catalog.resource_source
 where resource_id = (select id from catalog.resource where ref = 'component:checkout-service');
```

```
 source_id |                       observed
-----------+------------------------------------------------------
 finops    | {"monthlyCost": 4210}
 github    | {"tier": "tier-1", "repoUrl": "https://…", "language": "go"}
 manual    | {"lifecycle": "production"}
 pagerduty | {"oncallRota": "payments-primary"}
```

Each source's last report is kept as it said it. `catalog.resource.properties`
is the merge, and `property_provenance` says who won each value:

```sql
select property_provenance from catalog.resource where ref = 'component:checkout-service';
```

`lifecycle` comes from `manual` because no source claims it. Facts with no
other home belong to the catalog. Try `select * from catalog.property_claim`
to see which source claims what.

## 3. Who owns this, and why

The API functions read `catalog.viewer`, the user a request is made for. Be
Frank, the platform admin, for now:

```sql
set catalog.viewer = 'user:frank';
select * from api.who_owns('aws_rds_instance:prod-4711/checkout-db');
```

```
     owner     |                                   path
---------------+---------------------------------------------------------------------------
 team:payments | aws_rds_instance:prod-4711/checkout-db --component--> component:checkout-service --owner--> team:payments
```

The database has no owner field. Its `platform:component` tag became a
`component` link, the component's catalog file names its team, and
`catalog.owner_paths` followed the path. The result is stored in
`effective_owners`, so reads never have to walk it again.

Now `api.who_owns('component:cart-service')`: cart-service names no owner, so
it inherits from `system:commerce`. And `legacy-orders-dlq` has no tag at all:

```sql
select ref, effective_owners from catalog.resource
 where ref = 'aws_sqs_queue:prod-4711/legacy-orders-dlq';
```

Its owners are `{}`. Unowned is a state you can query, not a gap.

## 4. Four people, four views

Switch to the role the catalog service uses, `catalog_data_store_api`. It cannot read any
table, only the `api` views:

```sql
set role catalog_data_store_api;
select count(*) from catalog.resource;
```

```
ERROR:  permission denied for schema catalog
```

Now look through Carol's eyes. She is on Search:

```sql
set catalog.viewer = 'user:carol';
select ref, effective_owners, redacted from api.resource where ref like 'component:%';
```

```
            ref             | effective_owners |         redacted
----------------------------+------------------+--------------------------
 component:cart-service     | {team:payments}  | {oncallRota,monthlyCost}
 component:checkout-service | {team:payments}  | {oncallRota,monthlyCost}
 component:search-indexer   | {team:search}    | {}
```

Components are `org`-visible, so Carol can see that checkout-service exists and
that Payments owns it, but not its rota or cost. Payments' infrastructure is
`owner`-visible, so for her it does not exist:

```sql
select count(*) from api.get('aws_rds_instance:prod-4711/checkout-db');   -- 0
```

Repeat with `user:alice` (Payments), `user:dave` (a contractor on Search) and
`user:frank` (admin), and compare `select count(*) from api.resource`. Then go
back to the database owner and ask for all of it at once:

```sql
reset role;
select * from authz.access_matrix('component:checkout-service');
```

```
  user_ref  | can_view | sees_sensitive | can_edit | can_transfer
------------+----------+----------------+----------+--------------
 user:alice | t        | t              | t        | f
 user:bob   | t        | t              | t        | f
 user:carol | t        | f              | f        | f
 user:dave  | t        | f              | f        | f
 user:frank | t        | t              | t        | t
```

None of this was configured per resource. Alice's access comes from
`user:alice` being in `eng-payments-leads`, which is nested in `eng-payments`,
which backs `team:payments`, which owns the component.

## 5. Change the graph, watch access follow

**Move ownership.** Search is taking over cart-service. Carol tries first:

```sql
set role catalog_data_store_api;
set catalog.viewer = 'user:carol';
select ref from api.update('component:cart-service', p_links => '{"owner": "team:search"}');
```

```
ERROR:  user:carol lacks can_edit on component:cart-service
```

Frank is a platform admin, so he has `can_transfer`:

```sql
set catalog.viewer = 'user:frank';
select ref, effective_owners from api.update('component:cart-service',
  p_links => '{"owner": "team:search"}', p_reason => 'CHG-1182: cart moves to Search');
```

The owner changes, and so does every query that depends on it. Look at what
was logged, as the database owner:

```sql
reset role;
select version, op, actor, diff, reason from catalog.change_log
 where resource_ref = 'component:cart-service' order by id desc limit 2;
```

```
 version |   op   |   actor    |                                  diff
---------+--------+------------+-------------------------------------------------------------------------
       7 | owners | user:frank | {"effectiveOwners": {"to": ["team:search"], "from": ["team:payments"]}}
       6 | update | user:frank | {"links": {"owner": {"added": ["team:search"], "removed": []}}}
```

One write, two log entries: the fact Frank changed, and its effect on
ownership. The OpenFGA tuples the sync consumer will apply are just a diff of
`authz.fga_tuples` before and after: one `owner` tuple removed, one added.

**Tag the orphan.** Someone tags the dead-letter queue in AWS. The AWS
connector's next event carries the tag:

```sql
select catalog.ingest('aws-prod-4711', 'aws_sqs_queue', 'prod-4711/legacy-orders-dlq', null,
  '{"tags": {"platform:component": "checkout-service"}}',
  '{"component": "component:checkout-service"}');
```

The queue now inherits Payments, and Alice can see it. Nobody edited the catalog.

**Offboard a contractor.** Dave leaves `eng-search` in Entra ID. The next delta
sync rewrites the group's members:

```sql
select catalog.ingest('entra-id', 'identity_group', 'eng-search', null, '{}',
                      '{"members": ["user:carol"]}');
select * from authz.user_team where user_ref = 'user:dave';   -- no rows
```

The flattened membership was rebuilt in the same transaction. As `user:dave`
through the API role, every Search resource that used to be fully visible is
now redacted or gone.

## 6. Infrastructure before its component

Kubernetes reports a workload labelled with a component GitHub has not
delivered yet:

```sql
select catalog.ingest('kubernetes-prod-eu', 'k8s_workload', 'prod-eu/fraud/fraud-scorer', 'fraud-scorer',
  '{"replicas": 2}', '{"component": "component:fraud-scorer"}');

select l.to_ref, l.to_id is null as dangling, r.effective_owners
  from catalog.link l join catalog.resource r on r.id = l.from_id
 where r.ref = 'k8s_workload:prod-eu/fraud/fraud-scorer';
```

```
         to_ref         | dangling | effective_owners
------------------------+----------+------------------
 component:fraud-scorer | t        | {}
```

The link is kept but contributes nothing. Now the repo's catalog file arrives:

```sql
select catalog.ingest('github', 'component', 'fraud-scorer', 'Fraud Scorer',
  '{"tier": "tier-2", "repoUrl": "https://github.com/acme/fraud-scorer"}',
  '{"owner": "team:payments", "system": "system:commerce"}');
```

Run the link query again: `dangling` is now `f` and the workload's owner is
`{team:payments}`. A trigger attached the edge when the component row appeared,
and the resolver walked down to the workload in the same transaction.

## 7. A broken credential cannot delete the map

An AWS full sync with a half-revoked role sees one queue where the last
completed run saw three:

```sql
select catalog.start_run('aws-prod-4711', 'full') as run \gset
select catalog.ingest('aws-prod-4711', 'aws_sqs_queue', 'prod-4711/checkout-events', p_run_id => :run);
select catalog.finish_run(:run);                                         -- held
select note from catalog.ingestion_run where id = :run;
```

```
 saw 1 of the 3 resources the last completed full run saw (drop over 20%): held for review, nothing marked stale
```

Nothing is marked stale. A human either fixes the credential or confirms the
run with `catalog.release_run(:run, 'user:frank')`.

A genuine disappearance goes through the normal path. Run a Kubernetes full
sync that does not include the search indexer, then sweep:

```sql
select catalog.start_run('kubernetes-prod-eu', 'full') as run \gset
select catalog.ingest('kubernetes-prod-eu', 'k8s_workload', w, p_run_id => :run)
  from unnest(array['prod-eu/checkout/checkout-web', 'prod-eu/fraud/fraud-scorer']) w;
select catalog.finish_run(:run);
select catalog.sweep(), catalog.sweep(now() + interval '2 days');      -- 0, 1
```

Nothing is swept today, because the kind's `stale_after` is one day. With the
clock moved two days on, the workload is tombstoned: hidden from the API,
history intact, and restored if Kubernetes ever reports it again.

## 8. Read the change log three ways

**As a consumer.** The OpenFGA sync, the scorecard evaluator and the search
indexer each keep an offset:

```sql
select id, tx_id, resource_ref, op from catalog.poll_changes('openfga-sync', 5);
select * from catalog.consumer;
```

Rows come out in `(tx_id, id)` order, and only once no older transaction can
still commit. [explanation.md](./explanation.md#the-change-log-is-the-outbox)
covers why that matters.

**As a user.** Bob is on Payments, which no longer owns cart-service, so he
sees that its cost changed but not what to:

```sql
select catalog.ingest('finops', 'component', 'cart-service', null, '{"monthlyCost": 1130}');
set role catalog_data_store_api;
set catalog.viewer = 'user:bob';
select version, op, actor, diff from api.change
 where resource_ref = 'component:cart-service' order by version desc limit 1;
```

```
 version |   op   | actor  |                     diff
---------+--------+--------+-----------------------------------------------
       8 | update | finops | {"properties": {"monthlyCost": "(redacted)"}}
```

**As an agent.** `api.context` returns a bounded neighbourhood for an MCP tool
call:

```sql
set catalog.viewer = 'user:carol';
select jsonb_pretty(api.context(array['component:checkout-service'], 1));
```

Compare it with `user:alice`. Carol gets four resources and Alice nine. The
budget is applied after filtering, so Carol's `truncated` flag tells her
nothing about resources she cannot see.

## Check the invariants

```
./demo.sh test
```

This runs [`test.sql`](../../demos/data-store/test.sql) in a rolled-back
transaction, checks that the schema pages match the database, and runs the
drift check. The drift check asks OpenFGA (deployed alongside Postgres) the
same questions the SQL rule answers, for every user and resource, and fails if
they disagree. Try breaking it: give a team member access in the database
without syncing, then run `./demo.sh drift` to see the drift, and
`./demo.sh drift --apply` to repair it.

When you are done, `./demo.sh down` removes the workloads. The database stays;
`localenv apps delete catalog-data-store` removes it with the namespace and roles.

## Where next

- [reference.md](./reference.md) lists every table, function and view you just used.
- [explanation.md](./explanation.md) covers why there is one resource table,
  why visibility is a view and not row-level security, and why ownership is
  recomputed inside the write transaction.
