#!/bin/sh
# Entrypoint: wait for the database, run migrations, then start Phoenix.
set -e

cd /app

echo "Waiting for postgres at ${DB_HOSTNAME:-db}:5432..."
until pg_isready -h "${DB_HOSTNAME:-db}" -U "${DB_USERNAME:-postgres}" >/dev/null 2>&1; do
  sleep 1
done
echo "Postgres is ready."

# An unclean shutdown can leave Mix.Sync.Lock probe files with empty ports,
# which crash mix (CaseClauseError in fetch_probe_port). Nothing else runs
# mix at entrypoint time, so clearing them here is safe.
rm -rf /tmp/mix_lock_* /tmp/mix_pubsub_*

mix ecto.create
mix ecto.migrate

exec mix phx.server
