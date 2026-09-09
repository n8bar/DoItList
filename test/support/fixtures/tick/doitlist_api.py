#!/usr/bin/env python3
"""Small, dependency-free client for DoItList v1 HTTP API."""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any, BinaryIO
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

DEFAULT_BASE_URL = "https://doitlist.dev.n8bar.online"
MAX_RESPONSE_BYTES = 10 * 1024 * 1024
MAX_BATCH_SIZE = 150


class ClientError(Exception):
    """Safe user-facing configuration, transport, or API error."""


class NoRedirectHandler(HTTPRedirectHandler):
    """Refuse redirects so bearer credentials never cross to another URL."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def validate_base_url(value: str) -> str:
    value = value.strip().rstrip("/")
    parsed = urlsplit(value)
    loopback = parsed.hostname in {"localhost", "127.0.0.1", "::1"}
    if parsed.scheme != "https" and not (parsed.scheme == "http" and loopback):
        raise ClientError("DOITLIST_API_URL must use HTTPS, except for loopback development.")
    if not parsed.hostname or parsed.username or parsed.password:
        raise ClientError("DOITLIST_API_URL must be a service root without credentials.")
    if parsed.query or parsed.fragment or parsed.path not in {"", "/"}:
        raise ClientError("DOITLIST_API_URL must not include a path, query, or fragment.")
    return value


def validate_idempotency_key(value: str) -> str:
    if not value or value.isspace():
        raise ClientError("Idempotency key must not be blank.")
    if len(value) > 255:
        raise ClientError("Idempotency key must be at most 255 characters.")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ClientError("Idempotency key must not contain control characters.")
    return value


def read_limited(stream: BinaryIO) -> bytes:
    data = stream.read(MAX_RESPONSE_BYTES + 1)
    if len(data) > MAX_RESPONSE_BYTES:
        raise ClientError("DoItList response exceeded 10 MiB limit.")
    return data


def decode_json(data: bytes) -> Any:
    if not data:
        return None
    try:
        return json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ClientError("DoItList returned a non-JSON response.") from exc


def api_error_message(status: int, body: Any) -> str:
    if isinstance(body, dict):
        error = body.get("error")
        if isinstance(error, dict):
            code = error.get("code", "api_error")
            message = error.get("message", "Request failed.")
            return f"DoItList API {status} {code}: {message}"
    return f"DoItList API request failed with HTTP {status}."


class DoItListClient:
    def __init__(
        self,
        base_url: str,
        token: str,
        timeout: float = 30.0,
        opener: Any | None = None,
    ) -> None:
        if not token:
            raise ClientError("DOITLIST_API_TOKEN is not set.")
        self.base_url = validate_base_url(base_url)
        self._token = token
        self.timeout = timeout
        self.opener = opener or build_opener(NoRedirectHandler())

    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
        idempotency_key: str | None = None,
    ) -> Any:
        if not path.startswith("/api/v1/"):
            raise ClientError("API path must begin with /api/v1/.")

        headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {self._token}",
        }
        data = None
        if payload is not None:
            data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if idempotency_key is not None:
            headers["Idempotency-Key"] = validate_idempotency_key(idempotency_key)

        request = Request(f"{self.base_url}{path}", data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                return decode_json(read_limited(response))
        except HTTPError as exc:
            try:
                body = decode_json(read_limited(exc))
            except ClientError:
                body = None
            raise ClientError(api_error_message(exc.code, body)) from None
        except URLError as exc:
            reason = getattr(exc, "reason", None)
            kind = type(reason).__name__ if reason is not None else "transport error"
            raise ClientError(f"Could not reach DoItList ({kind}).") from None
        except TimeoutError:
            raise ClientError("DoItList request timed out; read state before retrying a write.") from None

    def get(self, path: str) -> Any:
        return self.request("GET", path)

    def apply(self, operations: list[dict[str, Any]], idempotency_key: str) -> Any:
        validate_operations(operations)
        return self.request(
            "POST",
            "/api/v1/operations",
            {"operations": operations},
            idempotency_key,
        )


def validate_operations(operations: Any) -> list[dict[str, Any]]:
    if not isinstance(operations, list) or not operations:
        raise ClientError("Operations input must be a non-empty JSON array.")
    if len(operations) > MAX_BATCH_SIZE:
        raise ClientError(f"Operations batch exceeds {MAX_BATCH_SIZE}-operation limit.")
    if not all(isinstance(operation, dict) for operation in operations):
        raise ClientError("Every operation must be a JSON object.")
    return operations


def load_operations(path: str) -> list[dict[str, Any]]:
    try:
        if path == "-":
            value = json.load(sys.stdin)
        else:
            with Path(path).open(encoding="utf-8") as handle:
                value = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise ClientError(f"Could not read operations JSON: {exc}") from None
    if isinstance(value, dict) and set(value) == {"operations"}:
        value = value["operations"]
    return validate_operations(value)


def load_comment_body(args: argparse.Namespace) -> str:
    if args.body is not None:
        body = args.body
    else:
        try:
            body = Path(args.body_file).read_text(encoding="utf-8")
        except OSError as exc:
            raise ClientError(f"Could not read comment body: {exc}") from None
    if not body.strip():
        raise ClientError("Comment body must not be blank.")
    return body


def output(value: Any) -> None:
    json.dump(value, sys.stdout, indent=2, sort_keys=True, ensure_ascii=False)
    sys.stdout.write("\n")


def default_out(name: str) -> Path:
    return Path(tempfile.gettempdir()) / name


def save_json(value: Any, path: Path) -> Path:
    try:
        with path.open("w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, separators=(",", ":"))
    except OSError as exc:
        raise ClientError(f"Could not save JSON to {path}: {exc}") from None
    return path


def display_title(task: dict[str, Any]) -> str:
    """Full title: DoItList truncates titles over 200 chars and keeps full text in description."""
    title = str(task.get("title", ""))
    description = task.get("description")
    if title.endswith("...") and isinstance(description, str) and description.startswith(title[:-3]):
        return description
    return title


def task_matches(task: dict[str, Any], match: str) -> bool:
    """All digits: task id. Digits with a dot (2. or 2.3): index prefix. Otherwise: title prefix."""
    if match.isdigit():
        return task.get("id") == int(match)
    if match[:1].isdigit() and "." in match:
        wanted = match.rstrip(".")
        index = str(task.get("index", ""))
        return index == wanted or index.startswith(wanted + ".")
    return display_title(task).lower().startswith(match.lower())


def count_tasks(tasks: list[dict[str, Any]]) -> int:
    return sum(1 + count_tasks(task.get("children") or []) for task in tasks)


def select_tasks(
    tasks: list[dict[str, Any]], matches: list[str], open_only: bool
) -> list[tuple[int, dict[str, Any]]]:
    """Rows of (relative depth, task) for matched subtrees, or the whole tree when no matches."""

    def emit(task: dict[str, Any], depth: int) -> list[tuple[int, dict[str, Any]]]:
        rows = [] if open_only and task.get("done") else [(depth, task)]
        for child in task.get("children") or []:
            rows.extend(emit(child, depth + 1))
        return rows

    def walk(nodes: list[dict[str, Any]]) -> list[tuple[int, dict[str, Any]]]:
        rows: list[tuple[int, dict[str, Any]]] = []
        for task in nodes:
            if not matches or any(task_matches(task, match) for match in matches):
                rows.extend(emit(task, 0))
            else:
                rows.extend(walk(task.get("children") or []))
        return rows

    return walk(tasks)


def task_row(depth: int, task: dict[str, Any]) -> str:
    flag = "x" if task.get("done") else " "
    indent = "  " * depth
    return (
        f"{task.get('id')}\t{task.get('parent_id')}\t{task.get('position')}\t[{flag}]\t"
        f"{indent}{display_title(task)}"
    )


def print_tree(args: argparse.Namespace, payload: Any) -> None:
    out = Path(args.out) if args.out else default_out(f"doitlist-tree-{args.initiative_id}.json")
    save_json(payload, out)
    if args.full:
        output(payload)
        return
    data = payload.get("data", payload) if isinstance(payload, dict) else {}
    tasks = data.get("tasks") or [] if isinstance(data, dict) else []
    rows = select_tasks(tasks, args.subtree or [], args.open_only)
    print(
        f"# initiative {args.initiative_id}: {count_tasks(tasks)} tasks, showing {len(rows)}; "
        f"full JSON saved to {out}"
    )
    print("# id\tparent\tpos\tdone\ttitle")
    for depth, task in rows:
        print(task_row(depth, task))
    if args.subtree and not rows:
        raise ClientError("No task matched --subtree (task id, index prefix like 2.3, or title prefix).")


def sanitize_text(value: Any, limit: int = 300) -> str:
    text = " ".join(str(value).split())
    return text if len(text) <= limit else text[: limit - 3] + "..."


def print_results(
    args: argparse.Namespace,
    operations: list[dict[str, Any]],
    payload: Any,
    key: str,
) -> None:
    safe_key = "".join(char if char.isalnum() or char in "-_." else "_" for char in key)[:80]
    out = Path(args.out) if args.out else default_out(f"doitlist-apply-{safe_key}.json")
    save_json(payload, out)
    if args.full:
        output(payload)
        return
    results = payload.get("results") if isinstance(payload, dict) else None
    if not isinstance(results, list):
        print(f"# response saved to {out}; no results array")
        return
    counts: dict[str, int] = {}
    for result in results:
        status = str(result.get("status", "unknown"))
        counts[status] = counts.get(status, 0) + 1
    summary = " ".join(f"{status}={count}" for status, count in sorted(counts.items()))
    print(f"# {len(results)} results: {summary}; response saved to {out}")
    for result in results:
        index = result.get("index")
        status = result.get("status")
        operation = operations[index] if isinstance(index, int) and index < len(operations) else {}
        if status == "ok" and operation.get("op") == "add":
            data = result.get("data") or {}
            lid = operation.get("lid")
            print(f"#{index} add -> id {data.get('id')}" + (f" (lid {lid})" if lid else ""))
        elif status != "ok":
            error = result.get("error")
            detail = ""
            if isinstance(error, dict):
                detail = f"{error.get('code', 'error')}: {sanitize_text(error.get('message', ''))}"
            elif error is not None:
                detail = sanitize_text(error)
            print(f"#{index} {status} {operation.get('op', '?')} {operation.get('id', operation.get('lid', ''))} {detail}".rstrip())


def write_or_preview(
    args: argparse.Namespace,
    operations: list[dict[str, Any]],
    client: DoItListClient | None,
) -> None:
    validate_operations(operations)
    key = validate_idempotency_key(args.idempotency_key)
    if args.dry_run:
        if getattr(args, "full", False):
            output({"dry_run": True, "idempotency_key": key, "operations": operations})
        else:
            print(f"# dry-run: {len(operations)} operations locally valid; key {key}; nothing sent")
        return
    assert client is not None
    print_results(args, operations, client.apply(operations, key), key)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--base-url",
        default=os.environ.get("DOITLIST_API_URL", DEFAULT_BASE_URL),
        help="service root (default: DOITLIST_API_URL or owner development service)",
    )
    parser.add_argument("--timeout", type=float, default=30.0)
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("me")
    commands.add_parser("initiatives")

    tree = commands.add_parser("tree")
    tree.add_argument("initiative_id", type=int)
    tree.add_argument("--out", help="save full JSON here (default: temp dir)")
    tree.add_argument(
        "--subtree",
        action="append",
        metavar="MATCH",
        help="print only this subtree: task id, index prefix (2. or 2.3), or title prefix; repeatable",
    )
    tree.add_argument("--open-only", action="store_true", help="omit done tasks")
    tree.add_argument("--full", action="store_true", help="print raw JSON (large; avoid in agent sessions)")

    activity = commands.add_parser("activity")
    activity.add_argument("initiative_id", type=int)
    activity.add_argument("--limit", type=int, default=100)
    activity.add_argument("--offset", type=int, default=0)

    members = commands.add_parser("members")
    members.add_argument("initiative_id", type=int)

    comments = commands.add_parser("comments")
    comments.add_argument("initiative_id", type=int)
    comments.add_argument("task_id", type=int)

    apply_command = commands.add_parser("apply")
    apply_command.add_argument("--input", default="-", help="JSON file, or - for stdin")
    apply_command.add_argument("--idempotency-key", required=True)
    apply_command.add_argument("--dry-run", action="store_true")
    apply_command.add_argument("--out", help="save full response here (default: temp dir)")
    apply_command.add_argument("--full", action="store_true", help="print raw response JSON")

    complete = commands.add_parser("complete-task")
    complete.add_argument("task_id", type=int)
    state = complete.add_mutually_exclusive_group(required=True)
    state.add_argument("--done", action="store_true")
    state.add_argument("--reopen", action="store_true")
    complete.add_argument("--idempotency-key", required=True)
    complete.add_argument("--dry-run", action="store_true")
    complete.add_argument("--out", help="save full response here (default: temp dir)")
    complete.add_argument("--full", action="store_true", help="print raw response JSON")

    comment = commands.add_parser("add-comment")
    comment.add_argument("task_id", type=int)
    body = comment.add_mutually_exclusive_group(required=True)
    body.add_argument("--body")
    body.add_argument("--body-file")
    comment.add_argument("--idempotency-key", required=True)
    comment.add_argument("--dry-run", action="store_true")
    comment.add_argument("--out", help="save full response here (default: temp dir)")
    comment.add_argument("--full", action="store_true", help="print raw response JSON")

    return parser


def client_from_args(args: argparse.Namespace) -> DoItListClient:
    token = os.environ.get("DOITLIST_API_TOKEN", "")
    return DoItListClient(args.base_url, token, args.timeout)


def run(args: argparse.Namespace) -> None:
    write_command = args.command in {"apply", "complete-task", "add-comment"}
    client = None if write_command and args.dry_run else client_from_args(args)

    if args.command == "me":
        output(client.get("/api/v1/me"))
    elif args.command == "initiatives":
        output(client.get("/api/v1/initiatives"))
    elif args.command == "tree":
        print_tree(args, client.get(f"/api/v1/initiatives/{args.initiative_id}"))
    elif args.command == "activity":
        query = urlencode({"limit": args.limit, "offset": args.offset})
        output(client.get(f"/api/v1/initiatives/{args.initiative_id}/activity?{query}"))
    elif args.command == "members":
        output(client.get(f"/api/v1/initiatives/{args.initiative_id}/members"))
    elif args.command == "comments":
        output(
            client.get(
                f"/api/v1/initiatives/{args.initiative_id}/tasks/{args.task_id}/comments"
            )
        )
    elif args.command == "apply":
        write_or_preview(args, load_operations(args.input), client)
    elif args.command == "complete-task":
        operations = [
            {
                "op": "update",
                "type": "task",
                "id": args.task_id,
                "data": {"done": args.done},
            }
        ]
        write_or_preview(args, operations, client)
    elif args.command == "add-comment":
        operations = [
            {
                "op": "add",
                "type": "comment",
                "data": {"task_id": args.task_id, "body": load_comment_body(args)},
            }
        ]
        write_or_preview(args, operations, client)
    else:  # pragma: no cover - argparse prevents this
        raise ClientError(f"Unsupported command: {args.command}")


def main() -> int:
    try:
        args = build_parser().parse_args()
        run(args)
        return 0
    except ClientError as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
