#!/bin/sh
set -eu

: "${APP_DB_USER:?APP_DB_USER must be set}"
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD must be set}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app_user="$APP_DB_USER" -v app_password="$APP_DB_PASSWORD" <<-'EOSQL'
    -- Can't use a DO $$ ... $$ block here: psql's :'var' substitution skips
    -- dollar-quoted bodies (it treats them as an opaque string literal), so
    -- neither variable would ever get interpolated. \gexec sidesteps that --
    -- the SELECT below is plain top-level SQL, builds the CREATE ROLE
    -- statement as text, and \gexec runs it only if a row came back.
    --
    -- %I (not %L) for the role name: %L quotes it as a *string literal*,
    -- which CREATE ROLE 'app_rw' rejects -- role names are identifiers, and
    -- %I is format()'s identifier-quoting placeholder (handles case, quoting,
    -- and the SQL-injection risk of gluing untrusted text into DDL).
    SELECT format('CREATE ROLE %I WITH LOGIN PASSWORD %L', :'app_user', :'app_password')
    WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user')
    \gexec
EOSQL
