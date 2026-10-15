-- zitadel-backup-setup.sql — one-time DB setup for the passwordless Zitadel
-- users dump (server/zitadel-scrubbed-dump.sh). Run as the postgres superuser
-- against the Zitadel database. Idempotent.
--
-- Design: a dedicated backup schema holds shape-copied tables of NAMED
-- COLUMNS ONLY (no password hashes, no secret columns). SECURITY DEFINER
-- procs copy the named columns in. The nightly export runs as a
-- least-privilege role that may only truncate + call + read that schema.
--
-- VERIFY FIRST (projection table names carry version suffixes that differ
-- per Zitadel release — adjust the source names/columns below to match):
--   SELECT table_name, column_name FROM information_schema.columns
--   WHERE table_schema='projections' ORDER BY table_name;
-- Also confirm the password hash lives only in the event stream on your
-- version: SELECT count(*) FROM eventstore.events2 WHERE payload ? 'encodedHash';

BEGIN;
CREATE SCHEMA IF NOT EXISTS zitadel_backup;
CREATE ROLE zitadel_export NOLOGIN;

CREATE TABLE IF NOT EXISTS zitadel_backup.orgs AS SELECT id, creation_date, resource_owner, instance_id, name, primary_domain, org_state FROM projections.orgs1 WITH NO DATA;
CREATE TABLE IF NOT EXISTS zitadel_backup.users AS SELECT id, creation_date, change_date, state, resource_owner, instance_id, username, type FROM projections.users14 WITH NO DATA;
CREATE TABLE IF NOT EXISTS zitadel_backup.users_humans AS SELECT user_id, instance_id, first_name, last_name, display_name, preferred_language, email, is_email_verified, phone, is_phone_verified FROM projections.users14_humans WITH NO DATA;
CREATE TABLE IF NOT EXISTS zitadel_backup.org_members AS SELECT creation_date, user_id, user_resource_owner, roles, resource_owner, instance_id, org_id FROM projections.org_members4 WITH NO DATA;
CREATE TABLE IF NOT EXISTS zitadel_backup.user_grants AS SELECT id, state, resource_owner, instance_id, user_id, project_id, granted_org, roles FROM projections.user_grants5 WITH NO DATA;

CREATE OR REPLACE PROCEDURE zitadel_backup.copy_orgs() LANGUAGE sql SECURITY DEFINER AS $$
  TRUNCATE zitadel_backup.orgs; INSERT INTO zitadel_backup.orgs SELECT id, creation_date, resource_owner, instance_id, name, primary_domain, org_state FROM projections.orgs1; $$;
CREATE OR REPLACE PROCEDURE zitadel_backup.copy_users() LANGUAGE sql SECURITY DEFINER AS $$
  TRUNCATE zitadel_backup.users; INSERT INTO zitadel_backup.users SELECT id, creation_date, change_date, state, resource_owner, instance_id, username, type FROM projections.users14; $$;
CREATE OR REPLACE PROCEDURE zitadel_backup.copy_users_humans() LANGUAGE sql SECURITY DEFINER AS $$
  TRUNCATE zitadel_backup.users_humans; INSERT INTO zitadel_backup.users_humans SELECT user_id, instance_id, first_name, last_name, display_name, preferred_language, email, is_email_verified, phone, is_phone_verified FROM projections.users14_humans; $$;
CREATE OR REPLACE PROCEDURE zitadel_backup.copy_org_members() LANGUAGE sql SECURITY DEFINER AS $$
  TRUNCATE zitadel_backup.org_members; INSERT INTO zitadel_backup.org_members SELECT creation_date, user_id, user_resource_owner, roles, resource_owner, instance_id, org_id FROM projections.org_members4; $$;
CREATE OR REPLACE PROCEDURE zitadel_backup.copy_user_grants() LANGUAGE sql SECURITY DEFINER AS $$
  TRUNCATE zitadel_backup.user_grants; INSERT INTO zitadel_backup.user_grants SELECT id, state, resource_owner, instance_id, user_id, project_id, granted_org, roles FROM projections.user_grants5; $$;

GRANT USAGE ON SCHEMA zitadel_backup TO zitadel_export;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA zitadel_backup TO zitadel_export;
GRANT SELECT, TRUNCATE ON ALL TABLES IN SCHEMA zitadel_backup TO zitadel_export;
ALTER DEFAULT PRIVILEGES IN SCHEMA zitadel_backup GRANT SELECT, TRUNCATE ON TABLES TO zitadel_export;
COMMIT;
