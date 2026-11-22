-- =============================================================================
-- test.sql — invariant checks for the catalog data store.
--
--   ./demo.sh up && ./demo.sh test
--
-- Runs in one transaction and rolls back, so it leaves the seed untouched.
-- Some checks assume the seed state, so run it on a fresh database (before
-- the walkthrough, or after ./demo.sh up). Stops at the first failure.
-- =============================================================================

\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null
begin;

-- ---------------------------------------------------------------------------
\echo 'materialised ownership matches the resolver for every live resource'
do $$ begin
  assert not exists (
    select 1 from catalog.resource
     where deleted_at is null and effective_owners is distinct from catalog.resolve_owners(id)),
    'effective_owners drifted from resolve_owners';
end $$;

-- ---------------------------------------------------------------------------
\echo 'flattened membership matches a fresh rebuild'
create temporary table ut_before as select * from authz.user_team;
select authz.refresh_memberships();
do $$ begin
  assert not exists ((table ut_before except table authz.user_team)
                     union all (table authz.user_team except table ut_before)),
    'authz.user_team is stale';
end $$;

-- (The comparison with OpenFGA lives in fga/drift.py, run by ./demo.sh test:
-- it asks a real OpenFGA, rather than re-implementing the model here.)

-- ---------------------------------------------------------------------------
\echo 'owner-only kinds are invisible to non-owners; org kinds are redacted'
set local role catalog_api;
set local catalog.viewer = 'user:carol';
do $$ begin
  assert not exists (select 1 from api.resource where ref = 'aws_rds_instance:prod-4711/checkout-db'),
    'carol can see payments infrastructure';
  assert (select redacted from api.resource where ref = 'component:checkout-service') = '{oncallRota,monthlyCost}',
    'checkout-service not redacted for carol';
  assert not exists (select 1 from api.resource r, jsonb_object_keys(r.provenance) k
                      where r.ref = 'component:checkout-service' and k in ('oncallRota', 'monthlyCost')),
    'provenance leaks redacted property names';
  assert not exists (select 1 from api.link where from_ref like 'aws_%' or to_ref like 'aws_%'),
    'links leak hidden resources';
end $$;
set local catalog.viewer = '';
do $$ begin
  assert not exists (select 1 from api.resource), 'anonymous viewer sees resources';
end $$;
set local catalog.viewer = 'user:nobody';
do $$ begin
  assert not exists (select 1 from api.resource), 'unknown viewer sees resources';
end $$;
reset role;

-- ---------------------------------------------------------------------------
\echo 'unowned resources are visible to platform admins only'
set local role catalog_api;
set local catalog.viewer = 'user:alice';
do $$ begin
  assert not exists (select 1 from api.resource where ref = 'aws_sqs_queue:prod-4711/legacy-orders-dlq'), 'alice sees unowned queue';
end $$;
set local catalog.viewer = 'user:frank';
do $$ begin
  assert exists (select 1 from api.resource where ref = 'aws_sqs_queue:prod-4711/legacy-orders-dlq'), 'admin cannot see unowned queue';
end $$;
reset role;

-- ---------------------------------------------------------------------------
\echo 'the service role has no direct table access'
set local role catalog_api;
do $$ begin
  begin
    perform 1 from catalog.resource limit 1;
    assert false, 'catalog_api read catalog.resource';
  exception when insufficient_privilege then null;
  end;
  begin
    perform catalog.ingest('manual', 'component', 'x');
    assert false, 'catalog_api called catalog.ingest';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- ---------------------------------------------------------------------------
\echo 'the change log is append-only'
do $$ begin
  begin
    update catalog.change_log set reason = 'tampered' where id = 1;
    assert false, 'change_log row updated';
  exception when raise_exception then null;
  end;
end $$;

-- ---------------------------------------------------------------------------
\echo 'write-path validation: kinds, link targets, cardinality, claimed properties'
do $$ begin
  begin
    perform catalog.ingest('github', 'user', 'mallory');
    assert false, 'github wrote a user';
  exception when insufficient_privilege then null;
  end;
  begin
    perform catalog.ingest('github', 'component', 'checkout-service', null, '{}', '{"owner": "system:commerce"}');
    assert false, 'owner link accepted a system';
  exception when check_violation then null;
  end;
  begin
    perform catalog.ingest('github', 'component', 'checkout-service', null, '{}', '{"owner": ["team:payments", "team:search"]}');
    assert false, 'single-valued link accepted two targets';
  exception when check_violation then null;
  end;
  begin
    perform catalog.ingest('github', 'component', 'checkout-service', null, '{}', '{"pager": "team:payments"}');
    assert false, 'undeclared link accepted';
  exception when check_violation then null;
  end;
end $$;
set local role catalog_api;
set local catalog.viewer = 'user:alice';
do $$ begin
  begin
    perform api.update('component:checkout-service', '{"tier": "tier-3"}');
    assert false, 'manual edit overwrote a github-owned property';
  exception when insufficient_privilege then null;
  end;
  begin
    perform api.update('aws_rds_instance:prod-4711/checkout-db', p_links => '{"component": "component:search-indexer"}');
    -- alice owns it, and component is an inherits link, not grants: allowed.
  end;
end $$;
reset role;

-- ---------------------------------------------------------------------------
\echo 'a manual override wins a single-valued link; removing it restores the source value'
set local role catalog_api;
set local catalog.viewer = 'user:frank';
select 1 from api.update('component:checkout-service', p_links => '{"owner": "team:search"}');
reset role;
do $$ begin
  assert (select effective_owners from catalog.resource where ref = 'component:checkout-service') = '{team:search}',
    'manual override did not win';
  assert (select effective_owners from catalog.resource where ref = 'aws_rds_instance:prod-4711/checkout-db') = '{team:search}',
    'override did not propagate down the inheritance path';
  assert (select count(*) from catalog.link l join catalog.resource r on r.id = l.from_id
           where r.ref = 'component:checkout-service' and l.name = 'owner' and not l.applied and l.source_id = 'github') = 1,
    'github assertion not retained as overridden';
end $$;
set local role catalog_api;
set local catalog.viewer = 'user:frank';
select 1 from api.update('component:checkout-service', p_links => '{"owner": null}');
reset role;
do $$ begin
  assert (select effective_owners from catalog.resource where ref = 'component:checkout-service') = '{team:payments}',
    'removing the override did not restore github''s owner';
end $$;

-- ---------------------------------------------------------------------------
\echo 'retract tombstones, re-ingest restores and reattaches'
do $$ begin
  perform catalog.retract('github', 'component:search-indexer');
  assert (select deleted_at is null from catalog.resource where ref = 'component:search-indexer'),
    'resource still seen by manual/pagerduty/finops should not be tombstoned';
  perform catalog.retract('manual', 'component:search-indexer');
  perform catalog.retract('pagerduty', 'component:search-indexer');
  perform catalog.retract('finops', 'component:search-indexer');
  assert (select deleted_at is not null from catalog.resource where ref = 'component:search-indexer'), 'not tombstoned';
  assert (select effective_owners from catalog.resource where ref = 'k8s_workload:prod-eu/search/indexer') = '{}',
    'workload kept an owner through a tombstoned component';
  perform catalog.ingest('github', 'component', 'search-indexer', null, '{}', '{"owner": "team:search"}');
  assert (select effective_owners from catalog.resource where ref = 'k8s_workload:prod-eu/search/indexer') = '{team:search}',
    'workload did not regain its owner after restore';
end $$;

-- ---------------------------------------------------------------------------
\echo 'resolver: cycles terminate, depth limit is 6'
select catalog.define_kind('{"identifier": "test_node", "title": "Test node",
  "links": {"parent": {"target": "test_node", "ownership": "inherits"},
            "owner":  {"target": "team", "ownership": "grants"}}}');
update catalog.source set writes_kinds = writes_kinds || '{test_node}' where id = 'manual';
select catalog.ingest('manual', 'test_node', 'a', null, '{}', '{"parent": "test_node:b"}');
select catalog.ingest('manual', 'test_node', 'b', null, '{}', '{"parent": "test_node:a"}');
select catalog.ingest('manual', 'test_node', 'n' || i, null, '{}',
                      case when i = 7 then '{"owner": "team:payments"}'::jsonb
                           else jsonb_build_object('parent', 'test_node:n' || (i + 1)) end)
  from generate_series(7, 0, -1) i;
do $$ begin
  assert (select effective_owners from catalog.resource where ref = 'test_node:a') = '{}', 'cycle resolved to an owner';
  assert (select effective_owners from catalog.resource where ref = 'test_node:n1') = '{team:payments}', '6 hops should resolve';
  assert (select effective_owners from catalog.resource where ref = 'test_node:n0') = '{}', '7 hops should not resolve';
end $$;

-- ---------------------------------------------------------------------------
\echo 'access grants are links: a kind editor grant gives access, is logged, and can be revoked'
select catalog.ingest('manual', 'kind', 'aws_sqs_queue', null, '{}', '{"editors": ["team:search"]}',
                      p_actor_type => 'system', p_actor => 'git', p_reason => 'test grant');
set local role catalog_api;
set local catalog.viewer = 'user:carol';
do $$ begin
  assert exists (select 1 from api.resource where ref = 'aws_sqs_queue:prod-4711/checkout-events' and sensitive_visible),
    'kind editor grant did not give carol access';
end $$;
reset role;
do $$ begin
  assert exists (select 1 from catalog.change_log
                  where resource_ref = 'kind:aws_sqs_queue' and reason = 'test grant' and diff ? 'links'),
    'grant not in the change log';
  assert exists (select 1 from authz.fga_tuples
                  where object = 'kind:aws_sqs_queue' and relation = 'editor' and subject = 'team:search#member'),
    'grant not projected to OpenFGA';
end $$;
select catalog.ingest('manual', 'kind', 'aws_sqs_queue', null, '{}', '{"editors": null}',
                      p_actor_type => 'system', p_actor => 'git');
set local role catalog_api;
set local catalog.viewer = 'user:carol';
do $$ begin
  assert not exists (select 1 from api.resource where ref = 'aws_sqs_queue:prod-4711/checkout-events'),
    'revoked kind editor grant still gives access';
end $$;
reset role;

\echo 'platform admins come from the admins link on platform:default'
select catalog.ingest('manual', 'platform', 'default', null, '{}', '{"admins": null}');
do $$ begin
  assert not exists (select 1 from authz.user_role where user_ref = 'user:frank'), 'frank kept admin after the link was removed';
end $$;
select catalog.ingest('manual', 'platform', 'default', null, '{}', '{"admins": ["identity_group:platform-engineering"]}');
do $$ begin
  assert exists (select 1 from authz.user_role where user_ref = 'user:frank' and role = 'admin'), 'admin not restored';
end $$;

\echo 'access-granting links are privileged: team members cannot change their own team''s backing groups'
set local role catalog_api;
set local catalog.viewer = 'user:alice';
do $$ begin
  begin
    perform api.update('team:payments', p_links => '{"backedBy": ["identity_group:eng-payments", "identity_group:eng-search"]}');
    assert false, 'alice widened her own team';
  exception when insufficient_privilege then null;
  end;
end $$;
set local catalog.viewer = 'user:frank';
select 1 from api.update('team:payments', p_links => '{"backedBy": ["identity_group:eng-payments", "identity_group:eng-search"]}');
do $$ begin
  assert exists (select 1 from api.resource where ref = 'aws_rds_instance:prod-4711/checkout-db'), 'admin lost sight of resources';
end $$;
reset role;
do $$ begin
  assert exists (select 1 from authz.user_team where user_ref = 'user:carol' and team_ref = 'team:payments'),
    'admin-approved backing group did not grant membership';
end $$;

-- ---------------------------------------------------------------------------
\echo 'a full run far smaller than the baseline is held, not swept'
do $$
declare run bigint := catalog.start_run('aws-prod-4711', 'full');
begin
  perform catalog.ingest('aws-prod-4711', 'aws_sqs_queue', 'prod-4711/checkout-events', p_run_id => run);
  assert catalog.finish_run(run) = 'held', 'run not held';
  assert not exists (select 1 from catalog.resource_source where source_id = 'aws-prod-4711' and stale_since is not null),
    'held run marked resources stale';
end $$;

rollback;
\echo
\echo 'all checks passed (transaction rolled back)'
