#!/bin/sh
# Entrypoint: wait for the database, run migrations, then start Phoenix.
set -e

cd /app

echo "Waiting for postgres at ${DB_HOSTNAME:-db}:5432..."
until pg_isready -h "${DB_HOSTNAME:-db}" -U "${DB_USERNAME:-postgres}" >/dev/null 2>&1; do
  sleep 1
done
echo "Postgres is ready."

mix ecto.create
mix ecto.migrate

exec mix phx.server
