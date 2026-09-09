"""Tick one DoItList item as done, mirror the plan checkbox, then print the next open item.

Order: DoItList first, plan mirror second, changelog line third (when the workspace keeps one),
next open item last.

Usage (from inside the project):
  doitlist-tick.py --section "<plan heading>" ID [--plan-only] [--dry-run]

One ID per call. Run it the moment an item finishes; its output is how you find the next item.
Never batch ticks, never defer them to commit or review time.

Discovery (override with flags or env):
  project root   git toplevel of cwd, else cwd
  plan mirror    --plan | DOITLIST_PLAN | nearest PLAN.md or docs/PLAN.md at or above root
                 (may sit outside git)
  initiative     --initiative | DOITLIST_INITIATIVE | first "/initiatives/<N>" link in the plan
  changelog      --log | DOITLIST_LOG | nearest ancestor changelog/ClaudeITChanges-<host>.log | none
  lock           nearest ancestor tools/tocc-lock, held on the plan while mirroring | none
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

HELPER_CANDIDATES = (
    Path(__file__).parent / "doitlist_api",  # invoked through a skill's scripts/ symlink
    Path.home() / ".claude/skills/doitlist-api/scripts/doitlist_api",
    Path.home() / ".codex/skills/doitlist-api/scripts/doitlist_api",
)
HELPER = next((path for path in HELPER_CANDIDATES if path.exists()), HELPER_CANDIDATES[1])


def run(*args: str, cwd: Path | None = None) -> str:
    result = subprocess.run(list(args), capture_output=True, text=True, cwd=cwd)  # noqa: S603
    if result.returncode:
        raise SystemExit(f"{args[0]} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def squash(text: object) -> str:
    return re.sub(r"\s+", " ", str(text)).strip()


def is_true(value: object) -> bool:
    return value is True or str(value).lower() == "true"


def project_root() -> Path:
    try:
        return Path(run("git", "rev-parse", "--show-toplevel").strip())
    except SystemExit:
        return Path.cwd()


def find_up(start: Path, *relatives: str) -> Path | None:
    """Nearest existing path among relatives, checked level by level from start upward."""
    for base in (start, *start.parents):
        for relative in relatives:
            if (base / relative).exists():
                return base / relative
    return None


def resolve_initiative(flag: int | None, plan: Path) -> int:
    if flag:
        return flag
    if os.environ.get("DOITLIST_INITIATIVE"):
        return int(os.environ["DOITLIST_INITIATIVE"])
    match = re.search(r"/initiatives/(\d+)\b", plan.read_text()) if plan.exists() else None
    if match:
        return int(match.group(1))
    raise SystemExit("initiative unknown: pass --initiative, set DOITLIST_INITIATIVE, or link it in the plan")


def load_tree(initiative: int, section: str) -> object:
    out = Path(tempfile.gettempdir()) / f"doitlist-tree-{initiative}.json"
    run(str(HELPER), "tree", str(initiative), "--subtree", section, "--out", str(out))
    return json.loads(out.read_text())


def nodes(document: object):
    """Yield task dicts in tree order (children sorted by position)."""
    if isinstance(document, dict):
        if "id" in document and "title" in document:
            yield document
        for value in document.values():
            if isinstance(value, (dict, list)):
                yield from nodes(value)
    elif isinstance(document, list):
        ordered = sorted(
            document,
            key=lambda n: int(n.get("position", 0)) if isinstance(n, dict) else 0,
        )
        for item in ordered:
            yield from nodes(item)


def section_node(document: object, section: str) -> dict:
    key = squash(section).lower()
    hits = [n for n in nodes(document) if squash(n["title"]).lower().startswith(key)]
    if len(hits) != 1:
        raise SystemExit(f"section {section!r} matched {len(hits)} tasks; use the full heading")
    return hits[0]


def task_in(section: dict, task_id: int) -> dict:
    for node in nodes(section):
        if int(node["id"]) == task_id:
            return node
    raise SystemExit(f"ID {task_id} is not under section {squash(section['title'])!r}")


def next_open(section: dict, ticked: int) -> dict | None:
    """First undone leaf under the section, in tree order, excluding the item just ticked."""
    for node in nodes(section):
        if int(node["id"]) == ticked or is_true(node.get("done")):
            continue
        if is_true(node.get("leaf", "true")):
            return node
    return None


def tick_doitlist(task_id: int) -> None:
    key = "tick-" + hashlib.sha256(str(task_id).encode()).hexdigest()[:16]
    batch = {"operations": [{"op": "update", "type": "task", "id": task_id, "data": {"done": True}}]}
    path = Path(tempfile.gettempdir()) / f"{key}.json"
    path.write_text(json.dumps(batch))
    print(run(str(HELPER), "apply", "--input", str(path), "--idempotency-key", key).strip())


def tick_plan(plan: Path, section: str, title: str, write: bool) -> bool:
    lines = plan.read_text().split("\n")
    start = next((i for i, line in enumerate(lines) if line.startswith("#") and section in line), None)
    if start is None:
        raise SystemExit(f"heading containing {section!r} not found in {plan}")
    level = len(lines[start]) - len(lines[start].lstrip("#"))
    end = next(
        (
            i
            for i, line in enumerate(lines)
            if i > start and line.startswith("#") and len(line) - len(line.lstrip("#")) <= level
        ),
        len(lines),
    )
    wanted = squash(title)
    for i in range(start, end):
        line = lines[i]
        if "[ ]" not in line:
            continue
        text = re.sub(r"^\s*(?:#+\s*)?(?:-\s*)?\[ \]\s*(?:\*\*)?", "", line)
        text = squash(text.replace("**", ""))
        head = text[:60]
        if text == wanted or text.startswith(wanted) or wanted.startswith(head):
            if write:
                lines[i] = line.replace("[ ]", "[x]", 1)
                plan.write_text("\n".join(lines))
            return True
    return False


def with_lock(lock: Path | None, plan: Path, action):
    workspace = lock.parent.parent if lock else None
    if workspace is None or not plan.is_relative_to(workspace):
        return action()
    rel = str(plan.relative_to(workspace))
    run("bash", str(lock), "claim", rel, cwd=workspace)
    try:
        return action()
    finally:
        run("bash", str(lock), "release", rel, cwd=workspace)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--section", required=True, help="plan heading of the unit holding the item, e.g. 'Arc 3: Web Experience'")
    parser.add_argument("id", type=int, help="one DoItList task ID; one item per call")
    parser.add_argument("--plan", type=Path, help="plan mirror file (default: <root>/PLAN.md)")
    parser.add_argument("--initiative", type=int, help="DoItList Initiative ID (default: link in plan)")
    parser.add_argument("--log", type=Path, help="changelog to append to (default: nearest workspace changelog)")
    parser.add_argument("--plan-only", action="store_true", help="Initiative already ticked; mirror only")
    parser.add_argument("--dry-run", action="store_true", help="resolve and report; write nothing")
    args = parser.parse_args()

    root = project_root()
    plan = args.plan or (Path(os.environ["DOITLIST_PLAN"]) if os.environ.get("DOITLIST_PLAN") else None)
    plan = plan or find_up(root, "PLAN.md", "docs/PLAN.md")
    if plan is None or not plan.exists():
        raise SystemExit(f"plan not found: {plan or 'no PLAN.md or docs/PLAN.md at or above ' + str(root)}")
    initiative = resolve_initiative(args.initiative, plan)
    host = os.uname().nodename
    log = args.log or (Path(os.environ["DOITLIST_LOG"]) if os.environ.get("DOITLIST_LOG") else None)
    log = log or find_up(root, f"changelog/ClaudeITChanges-{host}.log")
    lock = find_up(root, "tools/tocc-lock")

    section = section_node(load_tree(initiative, args.section), args.section)
    title = squash(task_in(section, args.id)["title"])

    if args.dry_run:
        found = tick_plan(plan, args.section, title, write=False)
        print(f"initiative {initiative}; plan {plan}; log {log or 'none'}; lock {lock or 'none'}")
        print(f"would tick: {title} (plan line {'found' if found else 'NOT found'})")
    else:
        if not args.plan_only:
            tick_doitlist(args.id)
        mirrored = with_lock(lock, plan, lambda: tick_plan(plan, args.section, title, write=True))
        if log:
            stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            shown = plan.relative_to(log.parent.parent) if plan.is_relative_to(log.parent.parent) else plan
            with log.open("a", encoding="utf-8") as handle:
                handle.write(
                    f"{stamp} {root.name}: {args.section}: done '{title}'"
                    f"{' (already live)' if args.plan_only else ''}; plan line"
                    f" {'mirrored' if mirrored else 'NOT found'} in {shown} via doitlist-tick.py.\n"
                )
        print(f"ticked: {title} (plan line {'mirrored' if mirrored else 'NOT found'})")
        found = mirrored

    nxt = next_open(section, args.id)
    if nxt is None:
        print("next: none — no open items left in this section")
    else:
        print(f"next: {nxt.get('index', '?')} {squash(nxt['title'])} [id {nxt['id']}]")
    return 0 if found else 1


if __name__ == "__main__":
    sys.exit(main())
