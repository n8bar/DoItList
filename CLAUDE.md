# CLAUDE

Claude Code instructions for **Do It List** — a web app for nested task trees with real, rolled-up progress. Domain: DoItList.app.

`@.agents/phoenix.md` below auto-loads the Phoenix/Elixir framework rules. Treat any `mix ...` command in those rules as running *inside the container* — wrap with `docker compose run --rm web ...` (or `docker compose exec web ...` if the stack is already up).

The `.agents/` folder holds files and guardrails that help agents (currently just Claude) use this project's frameworks, APIs, libraries, and interfaces correctly. See `.agents/README.md`.

For doc-structure conventions (hierarchy, numbering, doc layout, deadlines), see [`docs/README.md`](docs/README.md). Consult when adding any doc or making a structural decision.

@.agents/phoenix.md

## Product (primer — see [`docs/ProductSpec.md`](docs/ProductSpec.md) for canonical detail)
- **Core idea:** Task trees with real progress. Nest tasks, update leaves, parents roll up automatically. Importance is expressed by decomposition — no weight attribute.
- **Vocabulary** (use consistently): Initiative, Task, Progress, Roll-up progress, Initiative member. Not a generic todo app.
- **Inspiration:** AbstractSpoon's ToDo List, with three deliberate departures — web-based, real-time collaborative, deliberately simpler.

## Durable Principles
- Nested work is first-class.
- Progress is useful by default; importance is expressed by decomposition, not configuration.
- No file check-in/check-out collaboration.
- Grow milestone by milestone — resist becoming bloated PM software.

## Engineering Style
- Boring, understandable code; small, reviewable changes.
- Business logic in domain/service modules with tests, not views. Progress math stays in pure modules with unit tests.
- State lives where its lifetime is: ephemeral UI state (selection, expand/collapse, focus) stays client-side; the server owns durable data. Writes get optimistic feedback (UX_GUARDRAILS §6); renders and broadcasts update incrementally — cost proportional to the change, not the tree.

## Dev Environment
- Everything runs through Docker — `docker compose up --build`. No host installs beyond Docker + Compose.
- Required infra: `Dockerfile`, `compose.yaml`, `.env.example`, persistent DB volume, README setup commands.
- Must stay runnable on a clean Linux box with just Docker.

## Working Style
- Specs first: align on milestone scope in `docs/milestones/m##-<slug>/m##-<slug>.md` before writing code. If asked to code before a spec exists, pause and recommend writing it first.
- Keep docs in sync as scope shifts. Same commit is fine, separate commits are fine — what matters is they don't drift.
- When the user asks for input/feedback ("what do you think?", "should we…?"), answer first; don't change files until they confirm.
- Use the system date for any dated docs.
- Bug fixes are fair game on any branch if they're documented first.

## Branch & Repo
- Milestone-scoped work: `M##-<slug>` (uppercase M, no padding). Example: `M02-keyboard-nav`.
- Non-milestone work: semantic prefixes — `fix/<slug>`, `chore/<slug>`, `docs/<slug>`, `spike/<slug>`.
- `main` is canonical on GitHub.
- Don't merge with a dirty tree or unpushed commits without explicit confirmation.

## Terminal Ownership
Claude drives Docker, git, and `mix` (via the container) — assume the user has no shell open unless they say otherwise.

## Subagents
Use only for independent, path-scoped tasks that materially shorten cycle time. The primary agent owns integration and the user-facing summary.
