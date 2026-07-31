#!/bin/sh
set -eu

: "${APP_DB_USER:?APP_DB_USER must be set}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app_user="$APP_DB_USER" <<-'EOSQL'
    SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'app_user')
    UNION ALL
    SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'app_user')
    UNION ALL
    SELECT format('GRANT SELECT, INSERT, DELETE ON TABLE items TO %I', :'app_user')
    UNION ALL
    SELECT format('GRANT USAGE ON SEQUENCE items_id_seq TO %I', :'app_user')
    \gexec
EOSQL
