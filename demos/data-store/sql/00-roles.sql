-- =============================================================================
-- 00-roles.sql — check the roles the schema separates privileges with.
--
-- Runs as the database owner, which owns every object the later scripts
-- create. It is not a superuser and can't create roles, so the other four
-- must already exist, as NOLOGIN roles the owner may SET ROLE to:
--
--   <owner>_api       the catalog service's request path: api.* only
--   <owner>_ingest    connectors: catalog.ingest / retract / runs
--   <owner>_consumer  outbox consumers: poll and ack the change log
--   <owner>_auditor   read-only access to the facts
--
-- On localenv they come from .localenv.yaml (databaseRoles), which is exactly
-- this naming. In production, grant each one to the login role that needs it
-- (the catalog service's login gets <owner>_api, and so on).
-- =============================================================================

do $$
declare
  r       text;
  missing text[] := '{}';
  no_set  text[] := '{}';
begin
  foreach r in array array['api', 'ingest', 'consumer', 'auditor'] loop
    r := current_user || '_' || r;
    if not exists (select 1 from pg_roles where rolname = r) then
      missing := missing || r;
    elsif not pg_has_role(current_user, r, 'SET') then
      no_set := no_set || r;
    end if;
  end loop;
  if missing <> '{}' then
    raise exception 'missing roles: %', array_to_string(missing, ', ')
      using hint = 'On localenv, list them in .localenv.yaml (databaseRoles: [api, ingest, consumer, auditor]) '
                   'and run `localenv apps apply`. Elsewhere, create them NOLOGIN and grant them to '
                   || current_user || ' WITH SET TRUE.';
  end if;
  if no_set <> '{}' then
    raise exception '% cannot SET ROLE to: %', current_user, array_to_string(no_set, ', ')
      using hint = 'grant each role to ' || current_user || ' WITH SET TRUE';
  end if;
end $$;
