-- =============================================================================
-- walkthrough.sql — a guided tour of the catalog data store.
--
--   ./demo.sh up && ./demo.sh walkthrough
--
-- Each step prints what it is about to show, then the SQL, then the result.
-- The steps change the data, so run the file once against a fresh database
-- (./demo.sh up again resets it). docs/data-store/tutorial.md walks through
-- the same steps with commentary.
-- =============================================================================

\pset footer off
\pset null '∅'
\set ECHO queries
\set QUIET on

\echo
\echo '════ 1. The map ═══════════════════════════════════════════════════════════'
\echo 'Every resource is one row in catalog.resource, whatever its kind. Kinds are'
\echo 'rows too (catalog.kind + catalog.link_type), so a new kind is an insert.'
\echo
select kind, count(*) as resources,
       count(*) filter (where effective_owners = '{}') as unowned
  from catalog.resource
 where deleted_at is null and kind not in ('kind', 'source')
 group by kind order by kind;

select kind_id as kind, name as link, target_kinds, many, ownership
  from catalog.link_type
 where kind_id in ('component', 'system', 'team', 'aws_rds_instance')
 order by kind_id, name;

\echo
\echo '════ 2. One resource, four sources ════════════════════════════════════════'
\echo 'GitHub, PagerDuty, FinOps and a manual (git) fact all describe checkout-service.'
\echo 'Each source keeps its own observation; properties is the merge, and'
\echo 'property_provenance says which source won each value.'
\echo
select source_id, observed, last_seen_at::time(0) as last_seen
  from catalog.resource_source
 where resource_id = (select id from catalog.resource where ref = 'component:checkout-service')
 order by source_id;

select jsonb_pretty(property_provenance) as provenance
  from catalog.resource where ref = 'component:checkout-service';

\echo
\echo '════ 3. Ownership is computed, never typed in ═════════════════════════════'
\echo 'The RDS instance has no owner field. It is tagged with its component, the'
\echo 'component names its team, and the resolver follows that path.'
\echo
set catalog.viewer = 'user:frank';
select * from api.who_owns('aws_rds_instance:prod-4711/checkout-db');
select * from api.who_owns('component:cart-service');

\echo 'And a queue with no tag resolves to nobody: unowned is a state, not a gap.'
select ref, effective_owners from catalog.resource
 where deleted_at is null and effective_owners = '{}'
   and kind not in ('kind', 'source', 'user', 'identity_group', 'team');

\echo
\echo '════ 4. Permissions are part of the map ═══════════════════════════════════'
\set line 'The catalog service acts as the API role (' :api_role ') and sets catalog.viewer per'
\echo :line
\echo 'request. What each person can see is derived from ownership + membership.'
\echo
set role :"api_role";

set catalog.viewer = 'user:alice';
select 'alice' as viewer, count(*) as visible, count(*) filter (where redacted <> '{}') as redacted from api.resource where kind not in ('kind', 'source');
set catalog.viewer = 'user:carol';
select 'carol' as viewer, count(*) as visible, count(*) filter (where redacted <> '{}') as redacted from api.resource where kind not in ('kind', 'source');
set catalog.viewer = 'user:frank';
select 'frank' as viewer, count(*) as visible, count(*) filter (where redacted <> '{}') as redacted from api.resource where kind not in ('kind', 'source');

\echo 'Carol (Search) sees that checkout-service exists and who owns it, but not'
\echo 'its rota or cost, and not Payments'' infrastructure at all.'
set catalog.viewer = 'user:carol';
select ref, effective_owners, properties ->> 'tier' as tier, redacted
  from api.resource where ref like 'component:%' order by ref;
select count(*) as carol_sees_checkout_db from api.get('aws_rds_instance:prod-4711/checkout-db');

\echo 'The service role cannot bypass that by reading tables:'
\set ON_ERROR_STOP off
select count(*) from catalog.resource;
\set ON_ERROR_STOP on

reset role;
\echo 'The same answers, per user, for one resource (admin diagnostic):'
select * from authz.access_matrix('component:checkout-service');

\echo
\echo '════ 5. Moving ownership ══════════════════════════════════════════════════'
\echo 'cart-service inherits Payments through system:commerce. Search is taking it'
\echo 'over. Changing ownership needs can_transfer, which only platform admins have.'
\echo
create temporary table tuples_before as select * from authz.fga_tuples;
grant select on tuples_before to :"api_role";
set role :"api_role";

set catalog.viewer = 'user:carol';
\set ON_ERROR_STOP off
select ref from api.update('component:cart-service', p_links => '{"owner": "team:search"}');
\set ON_ERROR_STOP on

set catalog.viewer = 'user:frank';
select ref, effective_owners, version
  from api.update('component:cart-service', p_links => '{"owner": "team:search"}',
                  p_reason => 'CHG-1182: cart moves to Search');
select * from api.who_owns('component:cart-service');

reset role;
\echo 'The write and the ownership change are both in the change log:'
select version, op, actor_type, actor, diff, reason
  from catalog.change_log where resource_ref = 'component:cart-service' and version > 5 order by id;

\echo 'And the OpenFGA tuples the sync consumer will now write and delete:'
(select '+' as op, * from authz.fga_tuples except select '+', * from tuples_before)
union all
(select '-', * from tuples_before except select '-', * from authz.fga_tuples)
order by 1, 2;

\echo
\echo '════ 6. Tag the orphan queue ══════════════════════════════════════════════'
\echo 'Someone adds platform:component=checkout-service to the DLQ in AWS. The next'
\echo 'AWS event carries the tag; the queue inherits Payments with no catalog edit.'
\echo
select catalog.ingest('aws-prod-4711', 'aws_sqs_queue', 'prod-4711/legacy-orders-dlq', null,
                      '{"tags": {"platform:component": "checkout-service"}}',
                      '{"component": "component:checkout-service"}') is not null as ingested;
set role :"api_role";
set catalog.viewer = 'user:alice';
select ref, effective_owners, properties -> 'messagesVisible' as messages
  from api.get('aws_sqs_queue:prod-4711/legacy-orders-dlq');
reset role;

\echo
\echo '════ 7. Offboard a contractor ═════════════════════════════════════════════'
\echo 'Dave is removed from eng-search in Entra ID. The next delta sync rewrites the'
\echo 'group''s members; the flattened membership and Dave''s view follow at once.'
\echo
set role :"api_role";
set catalog.viewer = 'user:dave';
select 'before' as dave, count(*) filter (where sensitive_visible) as full_access,
       count(*) filter (where kind like 'k8s%' or kind like 'aws%' or kind = 'repository') as infrastructure
  from api.resource;
reset role;

select catalog.ingest('entra-id', 'identity_group', 'eng-search', null, '{}',
                      '{"members": ["user:carol"]}') is not null as ingested;
select * from authz.user_team where user_ref = 'user:dave';

set role :"api_role";
set catalog.viewer = 'user:dave';
select 'after' as dave, count(*) filter (where sensitive_visible) as full_access,
       count(*) filter (where kind like 'k8s%' or kind like 'aws%' or kind = 'repository') as infrastructure
  from api.resource;
reset role;

\echo
\echo '════ 8. Infrastructure that arrives before its component ═════════════════'
\echo 'Kubernetes reports a workload labelled with a component GitHub has not'
\echo 'ingested yet. The link is stored dangling and contributes no owner.'
\echo
select catalog.ingest('kubernetes-prod-eu', 'k8s_workload', 'prod-eu/fraud/fraud-scorer', 'fraud-scorer',
                      '{"cluster": "prod-eu", "namespace": "fraud", "replicas": 2}',
                      '{"component": "component:fraud-scorer"}') is not null as ingested;
select l.name, l.to_ref, l.to_id is null as dangling, r.effective_owners
  from catalog.link l join catalog.resource r on r.id = l.from_id
 where r.ref = 'k8s_workload:prod-eu/fraud/fraud-scorer';

\echo 'Then the repo''s catalog file is merged. The dangling edge attaches and the'
\echo 'owner flows down to the workload in the same transaction.'
select catalog.ingest('github', 'component', 'fraud-scorer', 'Fraud Scorer',
                      '{"tier": "tier-2", "language": "python", "repoUrl": "https://github.com/acme/fraud-scorer"}',
                      '{"owner": "team:payments", "system": "system:commerce"}') is not null as ingested;
select l.name, l.to_ref, l.to_id is null as dangling, r.effective_owners
  from catalog.link l join catalog.resource r on r.id = l.from_id
 where r.ref = 'k8s_workload:prod-eu/fraud/fraud-scorer';

\echo
\echo '════ 9. A broken credential cannot delete the map ═════════════════════════'
\echo 'An AWS full sync with a half-revoked role sees 1 resource where the last'
\echo 'completed run saw 3. The run is held and nothing is marked stale.'
\echo
select catalog.start_run('aws-prod-4711', 'full') as run \gset
select catalog.ingest('aws-prod-4711', 'aws_sqs_queue', 'prod-4711/checkout-events', p_run_id => :run) is not null as ingested;
select catalog.finish_run(:run) as status;
select id, status, resources_seen, baseline, note from catalog.ingestion_run where id = :run;

\echo 'A genuine disappearance: the search indexer Deployment is deleted. A full'
\echo 'Kubernetes run marks it stale; once stale_after (1 day) passes, the sweep'
\echo 'tombstones it. It is hidden from queries; its history stays.'
select catalog.start_run('kubernetes-prod-eu', 'full') as run \gset
select catalog.ingest('kubernetes-prod-eu', 'k8s_workload', w, p_run_id => :run) is not null as ingested
  from unnest(array['prod-eu/checkout/checkout-web', 'prod-eu/fraud/fraud-scorer']) w;
select catalog.finish_run(:run) as status;
select catalog.sweep() as swept_now, catalog.sweep(now() + interval '2 days') as swept_in_two_days;
select ref, deleted_at is not null as tombstoned from catalog.resource where ref = 'k8s_workload:prod-eu/search/indexer';

\echo
\echo '════ 10. The change log is the outbox ═════════════════════════════════════'
\echo 'Consumers read in (tx_id, id) order and only below the oldest running'
\echo 'transaction, so a slow writer can never slip in behind an offset.'
\echo
select id, tx_id, resource_ref, op, actor from catalog.poll_changes('openfga-sync', 5);
select catalog.ack_changes('openfga-sync', tx_id, id)
  from catalog.poll_changes('openfga-sync', 5) order by tx_id desc, id desc limit 1;
select name, last_tx, last_id,
       (select count(*) from catalog.poll_changes(name, 100000)) as pending
  from catalog.consumer order by name;

\echo 'Users read history through the API, filtered and redacted like everything'
\echo 'else. Bob (Payments) no longer owns cart-service, so cost changes are hidden:'
select catalog.ingest('finops', 'component', 'cart-service', null, '{"monthlyCost": 1130}') is not null as ingested;
set role :"api_role";
set catalog.viewer = 'user:bob';
select version, op, actor, diff from api.change
 where resource_ref = 'component:cart-service' order by version desc limit 3;
reset role;

\echo
\echo '════ 11. Context for an agent ═════════════════════════════════════════════'
\echo 'api.context returns a bounded neighbourhood. Permission filtering happens'
\echo 'before the budget, so truncation never reveals what the caller cannot see.'
\echo
set role :"api_role";
set catalog.viewer = 'user:alice';
select 'alice' as caller, r ->> 'ref' as ref, r ->> 'depth' as depth, r -> 'redacted' as redacted
  from jsonb_array_elements(api.context(array['component:checkout-service'], 1) -> 'resources') r;
set catalog.viewer = 'user:carol';
select 'carol' as caller, r ->> 'ref' as ref, r ->> 'depth' as depth, r -> 'redacted' as redacted
  from jsonb_array_elements(api.context(array['component:checkout-service'], 1) -> 'resources') r;
reset role;

\echo
\echo 'Done. Explore further with ./demo.sh psql, for example:'
\set line '  set role ' :api_role '; set catalog.viewer = ''user:carol''; table api.resource;'
\echo :line
