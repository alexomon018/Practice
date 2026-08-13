-- Replaces db/init/03_grants.sh under CloudNativePG.
--
-- The trap: postInitApplicationSQLRefs files are executed by the operator as
-- the `postgres` SUPERUSER, connected to `practicedb`. So every table, index
-- and sequence created by 01_schema.sql is owned by `postgres` -- not by
-- `app_rw`, even though `app_rw` owns the database itself. Owning a database
-- grants you nothing on the objects inside it.
--
-- The backend authenticates as `app_rw`. Without this file it can connect and
-- then fail on the first SELECT.

BEGIN;

GRANT USAGE ON SCHEMA public TO app_rw;

GRANT SELECT, INSERT, DELETE ON TABLE items TO app_rw;

GRANT INSERT ON TABLE request_audit TO app_rw;

GRANT USAGE ON SEQUENCE items_id_seq, request_audit_id_seq TO app_rw;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT SELECT, INSERT, DELETE ON TABLES TO app_rw;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT USAGE ON SEQUENCES TO app_rw;

COMMIT;
