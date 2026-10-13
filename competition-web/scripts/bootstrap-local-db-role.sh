#!/usr/bin/env bash
set -euo pipefail

: "${OST_WEB_DB_PASSWORD:?Set OST_WEB_DB_PASSWORD to a random 64-character hex password}"
if [[ ! "$OST_WEB_DB_PASSWORD" =~ ^[a-fA-F0-9]{64}$ ]]; then
  echo "OST_WEB_DB_PASSWORD must be exactly 64 hexadecimal characters." >&2
  exit 1
fi

docker exec -i supabase_db_ost-competition-private psql -U supabase_admin -d postgres \
  -v ON_ERROR_STOP=1 -v app_password="$OST_WEB_DB_PASSWORD" <<'SQL'
select format(
  'create role ost_web_app_login login noinherit nosuperuser nobypassrls password %L',
  :'app_password'
)
where not exists (select 1 from pg_roles where rolname='ost_web_app_login')
\gexec
select format('alter role ost_web_app_login password %L', :'app_password')
\gexec
grant ost_web_app to ost_web_app_login;
SQL
