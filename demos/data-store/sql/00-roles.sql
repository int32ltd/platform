-- =============================================================================
-- 00-roles.sql — database roles. Runs as the bootstrap superuser; every later
-- script switches to catalog_owner so no object is owned by a superuser.
--
--   catalog_owner    owns every object; never logs in
--   catalog_api      the catalog service's request path: api.* only (granted to its login role)
--   catalog_ingest   connectors: catalog.ingest / retract / runs
--   catalog_consumer outbox consumers: poll and ack the change log
--   catalog_auditor  read-only access to the facts, for audit and the
--                    nightly OpenFGA consistency check
-- =============================================================================

do $$
declare r text;
begin
  foreach r in array array['catalog_owner', 'catalog_ingest', 'catalog_consumer', 'catalog_auditor'] loop
    if not exists (select 1 from pg_roles where rolname = r) then
      execute format('create role %I nologin', r);
    end if;
  end loop;
  if not exists (select 1 from pg_roles where rolname = 'catalog_api') then
    create role catalog_api nologin;   -- grant it to the catalog service's login role
  end if;
  execute format('grant create on database %I to catalog_owner', current_database());
end $$;
