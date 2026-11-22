-- =============================================================================
-- 05-seed.sql — platform configuration and the worked example.
--
-- The graph is the one in demos/service-catalog-ownership: five people, five
-- identity groups, three teams, two systems, three components and six pieces
-- of infrastructure. Nothing is inserted into tables directly: every fact
-- arrives through catalog.ingest from the source that owns it, in the order
-- real connectors would deliver it.
-- =============================================================================

set role catalog_owner;

-- -----------------------------------------------------------------------------
-- Bootstrap: the `manual` source has to exist before the first kind can be
-- defined, because a kind is itself a resource written by `manual`.
-- -----------------------------------------------------------------------------
insert into catalog.source (id, connector, writes_kinds)
values ('manual', 'manual', array['kind', 'source']);

select catalog.define_kind('{"identifier": "kind", "title": "Kind", "builtIn": true, "visibility": "org",
  "description": "A kind definition",
  "links": {"editors": {"target": ["team", "identity_group"], "many": true, "privileged": true}}}');
select catalog.define_kind('{"identifier": "source", "title": "Source", "builtIn": true,
  "description": "An ingestion source and its mapping"}');
select catalog.define_kind('{"identifier": "scorecard", "title": "Scorecard", "builtIn": true, "visibility": "org"}');
select catalog.define_kind('{"identifier": "action", "title": "Action", "builtIn": true, "visibility": "org"}');

-- The platform itself is a resource. Who administers or audits it is a link,
-- like any other relationship in the graph.
select catalog.define_kind('{"identifier": "platform", "title": "Platform", "builtIn": true, "visibility": "org",
  "description": "The platform; its admins and auditors",
  "links": {"admins":   {"target": ["user", "identity_group"], "many": true, "privileged": true},
            "auditors": {"target": ["user", "identity_group"], "many": true, "privileged": true}}}');

select catalog.define_kind('{
  "identifier": "user", "title": "User", "builtIn": true, "visibility": "org",
  "description": "A person or service principal",
  "schema": {"properties": {"email": {"type": "string"}, "jobTitle": {"type": "string"}}},
  "identity": {"keys": ["email"]}, "staleAfter": "1 day"}');

select catalog.define_kind('{
  "identifier": "identity_group", "title": "Identity group", "builtIn": true, "visibility": "org",
  "schema": {"properties": {"provider": {"type": "string"}, "objectId": {"type": "string"}}},
  "links": {"members": {"target": ["user", "identity_group"], "many": true, "privileged": true}},
  "staleAfter": "1 day"}');

select catalog.define_kind('{
  "identifier": "team", "title": "Team", "builtIn": true, "visibility": "org",
  "description": "The organisational unit that owns things",
  "schema": {"properties": {"orgUnitId": {"type": "string"}, "costCentre": {"type": "string"},
             "manager": {"type": "string"}, "slack": {"type": "string"}, "oncallRota": {"type": "string"}}},
  "sensitive": ["costCentre"],
  "links": {"backedBy": {"target": "identity_group", "many": true, "privileged": true}},
  "identity": {"keys": ["orgUnitId"]}}');

select catalog.define_kind('{
  "identifier": "system", "title": "System", "visibility": "org", "materialiseOnReference": true,
  "description": "An architecture grouping of components",
  "schema": {"properties": {"domain": {"type": "string"}, "productOwner": {"type": "string"}}},
  "links": {"owner": {"target": "team", "ownership": "grants"}}}');

select catalog.define_kind('{
  "identifier": "component", "title": "Component", "visibility": "org",
  "description": "A deployable unit of software (service, job, library)",
  "schema": {"properties": {
      "lifecycle": {"type": "string", "enum": ["experimental", "production", "deprecated"]},
      "tier": {"type": "string", "enum": ["tier-1", "tier-2", "tier-3"]},
      "language": {"type": "string"}, "repoUrl": {"type": "string", "format": "uri"},
      "oncallRota": {"type": "string"}, "monthlyCost": {"type": "number"}},
    "required": ["lifecycle"]},
  "sensitive": ["oncallRota", "monthlyCost"],
  "links": {
    "owner":     {"target": "team", "ownership": "grants"},
    "system":    {"target": "system", "ownership": "inherits"},
    "dependsOn": {"target": "component", "many": true},
    "repo":      {"target": "repository"}},
  "identity": {"keys": ["repoUrl"]}}');

select catalog.define_kind('{
  "identifier": "repository", "title": "Repository",
  "links": {"component": {"target": "component", "ownership": "inherits"}}}');
select catalog.define_kind('{
  "identifier": "k8s_workload", "title": "Kubernetes workload", "staleAfter": "1 day",
  "links": {"component": {"target": "component", "ownership": "inherits"}}}');
select catalog.define_kind('{
  "identifier": "aws_sqs_queue", "title": "SQS queue", "staleAfter": "2 days",
  "links": {"component": {"target": "component", "ownership": "inherits"}}}');
select catalog.define_kind('{
  "identifier": "aws_rds_instance", "title": "RDS instance", "staleAfter": "2 days",
  "links": {"component": {"target": "component", "ownership": "inherits"}}}');
select catalog.define_kind('{
  "identifier": "action_run", "title": "Action run", "builtIn": true,
  "links": {"target": {"target": ["component", "system", "repository", "k8s_workload", "aws_sqs_queue", "aws_rds_instance"],
                       "ownership": "inherits"},
            "action": {"target": "action"}}}');

-- -----------------------------------------------------------------------------
-- Sources. writes.kinds is what a source may create or update;
-- writes.ownsProperties is which property values it is authoritative for.
-- -----------------------------------------------------------------------------
select catalog.define_source('{"identifier": "manual", "connector": "manual",
  "writes": {"kinds": ["kind", "source", "platform", "scorecard", "action", "team", "system", "component",
                       "repository", "k8s_workload", "aws_sqs_queue", "aws_rds_instance"]}}');

select catalog.define_source('{"identifier": "entra-id", "connector": "entra-id", "freshnessSlo": "5 minutes",
  "config": {"tenant": "acme.onmicrosoft.com", "delta": "graph-change-notifications"},
  "writes": {"kinds": ["user", "identity_group", "team"],
             "ownsProperties": {"user": ["email", "jobTitle"], "identity_group": ["provider", "objectId"]}}}');

select catalog.define_source('{"identifier": "hris", "connector": "workday",
  "writes": {"kinds": ["team"], "ownsProperties": {"team": ["orgUnitId", "costCentre", "manager"]}}}');

select catalog.define_source('{"identifier": "pagerduty", "connector": "pagerduty",
  "writes": {"kinds": ["team", "component"],
             "ownsProperties": {"team": ["oncallRota"], "component": ["oncallRota"]}}}');

select catalog.define_source('{"identifier": "github", "connector": "github",
  "config": {"org": "acme", "catalogFile": ".platform/catalog.yaml"},
  "writes": {"kinds": ["component", "repository"],
             "ownsProperties": {"component": ["tier", "language", "repoUrl"],
                                "repository": ["defaultBranch", "repoVisibility", "criticalVulnerabilities", "catalogFile"]}}}');

select catalog.define_source('{"identifier": "portfolio", "connector": "jira-product-hierarchy",
  "writes": {"kinds": ["system"], "ownsProperties": {"system": ["domain", "productOwner"]}}}');

select catalog.define_source('{"identifier": "finops", "connector": "aws-cost-explorer",
  "writes": {"kinds": ["component"], "ownsProperties": {"component": ["monthlyCost"]}}}');

select catalog.define_source('{"identifier": "kubernetes-prod-eu", "connector": "kubernetes",
  "config": {"cluster": "prod-eu", "watch": ["Deployment", "StatefulSet", "CronJob"]},
  "mapping": [{"match": "Deployment", "kind": "k8s_workload",
               "identifier": "{{ .metadata.namespace }}/{{ .metadata.name }}@prod-eu",
               "links": {"component": "{{ with index .metadata.labels \"platform.acme.io/component\" }}component:{{ . }}{{ end }}"}}],
  "writes": {"kinds": ["k8s_workload"],
             "ownsProperties": {"k8s_workload": ["cluster", "namespace", "replicas", "image", "componentLabel"]}}}');

select catalog.define_source('{"identifier": "aws-prod-4711", "connector": "aws", "fullSyncDropThreshold": 0.2,
  "config": {"account": "4711", "regions": ["eu-west-1"], "componentTag": "platform:component"},
  "writes": {"kinds": ["aws_sqs_queue", "aws_rds_instance"],
             "ownsProperties": {"aws_sqs_queue": ["region", "account", "messagesVisible", "tags"],
                                "aws_rds_instance": ["region", "engine", "instanceClass", "multiAZ", "tags"]}}}');

insert into catalog.consumer (name) values ('openfga-sync'), ('scorecards'), ('search-indexer');

-- -----------------------------------------------------------------------------
-- 1. Identity provider: users and groups (groups nested as Entra ID nests them).
-- -----------------------------------------------------------------------------
select catalog.ingest('entra-id', 'user', u.id, u.title,
                      jsonb_build_object('email', u.id || '@acme.io', 'jobTitle', u.job), '{}', u.oid)
  from (values ('alice', 'Alice Novak', 'Staff engineer, Payments', '0b1e…a11'),
               ('bob',   'Bob Mehta',   'Engineer, Payments',       '5c2d…b22'),
               ('carol', 'Carol Ihde',  'Engineer, Search',         '8e3f…c33'),
               ('dave',  'Dave Osei',   'Contractor, Search',       '1a4b…d44'),
               ('frank', 'Frank Lind',  'Platform engineering',     '6d5c…f55')) u(id, title, job, oid);

select catalog.ingest('entra-id', 'identity_group', g.id, g.id,
                      jsonb_build_object('provider', 'entra-id', 'objectId', g.oid),
                      jsonb_build_object('members', g.members), g.oid)
  from (values ('eng-payments-leads',   '7f1c…a09', '["user:alice"]'::jsonb),
               ('eng-payments',         '2b8e…41d', '["user:bob", "identity_group:eng-payments-leads"]'),
               ('eng-search',           '9dd0…c73', '["user:carol", "user:dave"]'),
               ('payments-contractors', '4a55…1fe', '["user:dave"]'),
               ('platform-engineering', '11ab…9c2', '["user:frank"]')) g(id, oid, members);

-- Who administers the platform: a link from platform:default to a group,
-- written through git like any other catalog-owned fact.
select catalog.ingest('manual', 'platform', 'default', 'Platform', '{}',
                      '{"admins": ["identity_group:platform-engineering"]}',
                      p_actor_type => 'system', p_actor => 'git');

-- -----------------------------------------------------------------------------
-- 2. Teams: HR owns the record, the identity provider the backing groups (by
-- the org-unit attribute on the group), PagerDuty the rota, manual the Slack
-- channel. Four sources, one resource.
-- -----------------------------------------------------------------------------
select catalog.ingest('hris', 'team', t.id, t.title,
                      jsonb_build_object('orgUnitId', t.ou, 'costCentre', t.cc, 'manager', t.mgr), '{}', t.ou)
  from (values ('payments', 'Payments', 'OU-2241', 'CC-4120', 'Nadia Berg'),
               ('search',   'Search',   'OU-2263', 'CC-4180', 'Rafael Tun'),
               ('platform', 'Platform', 'OU-2200', 'CC-4000', 'Nadia Berg')) t(id, title, ou, cc, mgr);

select catalog.ingest('entra-id', 'team', t.id, null, '{}', jsonb_build_object('backedBy', t.groups))
  from (values ('payments', '["identity_group:eng-payments"]'::jsonb),
               ('search',   '["identity_group:eng-search"]'),
               ('platform', '["identity_group:platform-engineering"]')) t(id, groups);

select catalog.ingest('pagerduty', 'team', t.id, null, jsonb_build_object('oncallRota', t.rota))
  from (values ('payments', 'payments-primary'), ('search', 'search-primary'), ('platform', 'platform-primary')) t(id, rota);

select catalog.ingest('manual', 'team', t.id, null, jsonb_build_object('slack', t.slack),
                      p_actor_type => 'system', p_actor => 'git')
  from (values ('payments', '#team-payments'), ('search', '#team-search'), ('platform', '#team-platform')) t(id, slack);

-- -----------------------------------------------------------------------------
-- 3. GitHub: each repo's catalog file declares its component, owner and
-- system. The systems do not exist yet; the first reference materialises them.
-- -----------------------------------------------------------------------------
select catalog.ingest('github', 'component', c.id, c.title,
                      jsonb_build_object('tier', c.tier, 'language', c.lang, 'repoUrl', 'https://github.com/acme/' || c.id),
                      c.links)
  from (values ('checkout-service', 'Checkout Service', 'tier-1', 'go',
                '{"owner": "team:payments", "system": "system:commerce", "dependsOn": ["component:cart-service"],
                  "repo": "repository:github/acme/checkout-service"}'::jsonb),
               ('cart-service',     'Cart Service',     'tier-2', 'go',   '{"system": "system:commerce"}'),
               ('search-indexer',   'Search Indexer',   'tier-2', 'java', '{"owner": "team:search", "system": "system:discovery"}')
       ) c(id, title, tier, lang, links);

select catalog.ingest('github', 'repository', 'github/acme/checkout-service', 'acme/checkout-service',
                      '{"defaultBranch": "main", "repoVisibility": "private", "criticalVulnerabilities": 0,
                        "catalogFile": ".platform/catalog.yaml"}',
                      '{"component": "component:checkout-service"}', 'R_kgDOAbc');

-- lifecycle is claimed by no source, so it is a manual fact (set through git).
select catalog.ingest('manual', 'component', c, null, '{"lifecycle": "production"}',
                      p_actor_type => 'system', p_actor => 'git')
  from unnest(array['checkout-service', 'cart-service', 'search-indexer']) c;

select catalog.ingest('pagerduty', 'component', c.id, null, jsonb_build_object('oncallRota', c.rota))
  from (values ('checkout-service', 'payments-primary'), ('cart-service', 'payments-primary'),
               ('search-indexer', 'search-primary')) c(id, rota);

select catalog.ingest('finops', 'component', c.id, null, jsonb_build_object('monthlyCost', c.cost))
  from (values ('checkout-service', 4210), ('cart-service', 980), ('search-indexer', 1640)) c(id, cost);

-- -----------------------------------------------------------------------------
-- 4. Portfolio tool claims the placeholder systems and names their owners.
-- -----------------------------------------------------------------------------
select catalog.ingest('portfolio', 'system', s.id, s.title,
                      jsonb_build_object('domain', s.domain, 'productOwner', s.po),
                      jsonb_build_object('owner', s.owner))
  from (values ('commerce',  'Commerce',  'revenue', 'Nadia Berg', 'team:payments'),
               ('discovery', 'Discovery', 'product', 'Rafael Tun', 'team:search')) s(id, title, domain, po, owner);

-- -----------------------------------------------------------------------------
-- 5. Infrastructure, labelled or tagged with the component it belongs to.
-- AWS arrives as a full run, which becomes the baseline for the drop guard.
-- -----------------------------------------------------------------------------
select catalog.ingest('kubernetes-prod-eu', 'k8s_workload', w.id, w.title,
                      jsonb_build_object('cluster', 'prod-eu', 'namespace', w.ns, 'replicas', w.replicas,
                                         'image', w.image, 'componentLabel', 'platform.acme.io/component=' || w.comp),
                      jsonb_build_object('component', 'component:' || w.comp))
  from (values ('prod-eu/checkout/checkout-web', 'checkout-web', 'checkout', 6, 'ghcr.io/acme/checkout-web:1.84.2', 'checkout-service'),
               ('prod-eu/search/indexer',        'search-indexer', 'search', 3, 'ghcr.io/acme/search-indexer:0.42.0', 'search-indexer')
       ) w(id, title, ns, replicas, image, comp);

do $$
declare run bigint := catalog.start_run('aws-prod-4711', 'full');
begin
  perform catalog.ingest('aws-prod-4711', 'aws_sqs_queue', 'prod-4711/checkout-events', 'prod-checkout-events',
    '{"region": "eu-west-1", "account": "4711", "messagesVisible": 128, "tags": {"platform:component": "checkout-service"}}',
    '{"component": "component:checkout-service"}', 'arn:aws:sqs:eu-west-1:4711:prod-checkout-events', run);
  perform catalog.ingest('aws-prod-4711', 'aws_rds_instance', 'prod-4711/checkout-db', 'prod-checkout-db',
    '{"region": "eu-west-1", "engine": "postgres 16.3", "instanceClass": "db.r6g.large", "multiAZ": true,
      "tags": {"platform:component": "checkout-service"}}',
    '{"component": "component:checkout-service"}', 'arn:aws:rds:eu-west-1:4711:db:prod-checkout-db', run);
  -- No component tag: nothing to inherit from, so it is unowned.
  perform catalog.ingest('aws-prod-4711', 'aws_sqs_queue', 'prod-4711/legacy-orders-dlq', 'legacy-orders-dlq',
    '{"region": "eu-west-1", "account": "4711", "messagesVisible": 1943, "tags": {}}',
    '{}', 'arn:aws:sqs:eu-west-1:4711:legacy-orders-dlq', run);
  perform catalog.finish_run(run);
end $$;

-- -----------------------------------------------------------------------------
-- 6. Derived data: one scorecard result, as the scorecard consumer would write it.
-- -----------------------------------------------------------------------------
insert into catalog.scorecard_result (resource_id, scorecard, level, rules)
select id, 'production-readiness', 'gold',
       '{"has-owner": {"pass": true}, "has-oncall": {"pass": true}, "no-critical-vulns": {"pass": true}}'
  from catalog.resource where ref = 'component:checkout-service';

reset role;
