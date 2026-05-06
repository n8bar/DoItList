# syntax=docker/dockerfile:1.6
#
# Single-stage development image. Production releases are out of scope for the
# MVP — the goal is `docker compose up --build` boots the app cleanly.

FROM elixir:1.18-alpine

ENV LANG=C.UTF-8 \
    MIX_ENV=dev \
    PHX_SERVER=true \
    PORT=4000

# Build deps for native NIFs (bcrypt) and dev tooling.
RUN apk add --no-cache \
      build-base \
      git \
      inotify-tools \
      openssl \
      ncurses-libs \
      bash \
      postgresql-client

WORKDIR /app

# Hex/Rebar are needed before fetching deps.
RUN mix local.hex --force && mix local.rebar --force

# Cache mix deps separately so source changes don't bust dep compile.
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get && mix deps.compile

# Tailwind/esbuild binaries.
RUN mix assets.setup

# Copy the rest of the source tree.
COPY . .

EXPOSE 4000

CMD ["sh", "/app/bin/start.sh"]
