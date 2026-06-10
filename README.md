# Do It List

Task trees with real progress.

Do It List is a small web app for breaking work into nested tasks and watching
parent and root progress roll up automatically from the leaves. Optional
weighting lets you say "this subtask is worth 30% of its parent" without forcing
the user to set weights for everything.

Do It List grows milestone by milestone. The execution dashboard lives in
[`docs/PLAN.md`](docs/PLAN.md); the canonical product spec lives in
[`docs/ProductSpec.md`](docs/ProductSpec.md). The first shipped milestone
is **M01-BaseApp** ([`docs/milestones/m01-baseapp/m01-baseapp.md`](docs/milestones/m01-baseapp/m01-baseapp.md)).

## Stack

- Phoenix LiveView 1.1 (Elixir 1.18)
- PostgreSQL 16
- Tailwind + DaisyUI for styling
- Bcrypt for password hashing

The whole development environment is containerised. The only host-level
requirements are Docker and Docker Compose.

## Run it

```bash
docker compose up --build
```

Then open <http://localhost:4000>. Register an account, create an Initiative, and
start adding lists and nested tasks.

The first boot is slow — Elixir, Hex, and the JS asset toolchain are all
pulled into the image. Subsequent runs use the cached `_build`, `deps`, and
`node_modules` named volumes.

### Environment

`compose.yaml` ships with sensible defaults that need no configuration. To
override them, copy `.env.example` to `.env` and edit:

| Variable      | Default      | Purpose                                    |
| ------------- | ------------ | ------------------------------------------ |
| `WEB_PORT`    | `4000`       | Port mapped from the host to the web app.  |
| `DB_USERNAME` | `postgres`   | PostgreSQL user.                           |
| `DB_PASSWORD` | `postgres`   | PostgreSQL password.                       |
| `DB_DATABASE` | `doit_dev`   | PostgreSQL database name.                  |

Database data lives in the named Docker volume `doit_pgdata`, so it survives
`docker compose down`. `docker compose down -v` wipes everything.

## Run the tests

The test suite (notably the progress roll-up unit tests) runs inside the
container too:

```bash
docker compose run --rm \
  -e MIX_ENV=test \
  -e DB_DATABASE=doit \
  web mix test
```

This creates a `doit_test` database alongside `doit_dev`. The pure-Elixir
progress tests in `test/doit/tasks/progress_test.exs` do not touch the database
at all and are the fastest signal that the roll-up math is correct.

### Browser (e2e) tests

Tests tagged `:e2e` (in `test/e2e/`) drive a real headless Chromium through
[Playwright](https://playwright.dev/). The browser runs in its own compose
service (the web image stays Alpine; tests connect to it over websocket), so
start that once, then use the `test.e2e` alias:

```bash
docker compose --profile test up -d playwright

docker compose run --rm \
  -e MIX_ENV=test \
  -e DB_DATABASE=doit \
  web mix test.e2e
```

Plain `mix test` excludes the `:e2e` tag and never needs the playwright
service. `mix test.e2e` runs the whole suite including it; append a path
(e.g. `mix test.e2e test/e2e`) to run just the browser tests.

## Terminology

Canonical definitions live in [`docs/ProductSpec.md`](docs/ProductSpec.md). Quick reference:

- **Initiative** — the top-level container, has members and many Lists.
- **Task** — any node in the tree.
- **List** — informal name for a *root* task (a task whose `parent_id` is
  `null`). An Initiative usually has multiple Lists, each with its own tree.
- **Roll-up progress** — `computed_progress` on a task: the weighted average of
  its children's rolled-up progress.
- **Weight** — how much a child contributes to its parent's roll-up. Default
  is `1`; users only have to touch it when they want non-equal contributions.
- **Initiative member** — a `(user, initiative, role)` triple. Roles are `owner`,
  `editor`, `viewer`.

## How progress works

The principle and formula live in [`docs/ProductSpec.md`](docs/ProductSpec.md);
detailed edge cases live in [`docs/milestones/m01-baseapp/m01-baseapp.md`](docs/milestones/m01-baseapp/m01-baseapp.md).
Pure implementation lives in `DoIt.Tasks.Progress` and is exercised by
`test/doit/tasks/progress_test.exs`.

```
leaf task                    → manual_progress (clamped 0..100)
status == "done"             → 100
branch task                  → sum(child_progress * child_weight) / sum(child_weight)
```

Children with non-positive weight are ignored. Marking a task `done` snaps its
progress to 100; reopening lets the user move it back down. Whenever a task
changes, `DoIt.Tasks` recomputes its ancestors recursively.

## Architecture, briefly

- `lib/doit/accounts/` — user registration / login / password hashing.
- `lib/doit/initiatives/` — initiatives and initiative membership.
- `lib/doit/tasks/` — tasks, comments, activity events, and the
  pure-Elixir `Progress` module.
- `lib/doit_web/live/` — `InitiativeIndexLive` and `InitiativeShowLive`. The latter
  subscribes to `initiative:<id>` PubSub topics so other browsers see updates
  promptly. Last writer wins; no conflict resolution.
- `lib/doit_web/user_auth.ex` — session-based auth plug + LiveView mount hooks.

Activity events are recorded on task creation, deletion, comment, and field
changes (title, status, progress, weight, assignee, parent, priority) and are
shown in the task editor sidebar.

## Known limitations (intentional, see Non-Goals in the milestone)

- No drag-and-drop reordering. `sort_order` is set on creation and editable
  only via the JSON form field.
- No conflict resolution: simultaneous edits to the same field follow
  last-writer-wins.
- No notifications, attachments, kanban, calendar, or AI features.
- No password reset / email confirmation flow yet — registration logs you
  straight in.
- `mix release` / production Dockerfile are out of scope for M01-BaseApp; the
  shipped image runs `mix phx.server` in `dev` mode.
