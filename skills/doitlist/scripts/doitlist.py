#!/usr/bin/env python3
"""Do It List scripted client — read and write verbs over the /api/v1 surface.

Standalone by design (m03.04 4.1.4): Python 3 standard library only, no app
container, no repo checkout. Copy this file next to the agent's work and run
it. Configuration comes from the environment the connect panel emits:

    DOITLIST_API_URL     e.g. http://localhost:4000  (hosted: https://...)
    DOITLIST_API_TOKEN   the bearer token minted by the connect panel
    DOITLIST_STATE_DIR   optional; where pending writes are parked
                         (default ~/.doitlist/state)

Division of labor (m03.04 4.1.2): import parsing stays in the API — this
client only shapes requests, formats responses, and (later) mirrors
completion into local Markdown. See the mirroring seam near the bottom.

Operator-facing output uses labels, titles, and URLs; ids appear only as
`%<id>` beside a title, which is how the companion skill names Tasks.
API requests use ids (m03.04 4.1.5).

Every write reads current state first and submits ONE operation through
`POST /api/v1/operations` carrying the `expected_version` from that read
(m03.04 4.3.2), under a generated `Idempotency-Key` that is parked on disk
before the request leaves (4.3.4). A lost response therefore never becomes a
lost or duplicated write: `retry` resends the parked request with the same key
and the same body, and the server replays its stored response.

Streams: a write's outcome block — success, failure, conflict, unknown
outcome, and any `saved:` path — goes to stdout as one compact unit
(m03.04 4.8) so an agent reads it in one place; the exit code carries the
verdict. stderr carries only the `doitlist: ...` line for a usage,
configuration, or read error.

Exit codes: 0 ok, 1 API/network error, 2 usage or configuration error.
"""

import argparse
import json
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone

ENV_URL = "DOITLIST_API_URL"
ENV_TOKEN = "DOITLIST_API_TOKEN"
ENV_STATE_DIR = "DOITLIST_STATE_DIR"

#: Hosts allowed to speak plain HTTP. Everything else must be HTTPS
#: (m03.04 4.1.6) — a token must never cross a network in the clear.
LOOPBACK_HOSTS = frozenset({"localhost", "127.0.0.1", "::1", "[::1]"})

CONNECT_PANEL_HINT = (
    "The connect panel on your account page emits both variables in its "
    "copy-paste block; re-run that paste, then retry."
)

DEFAULT_TIMEOUT = 30
REDACTED = "***"

EXIT_OK = 0
EXIT_API = 1
EXIT_USAGE = 2

#: The one write endpoint: every verb submits a single-operation batch.
OPERATIONS_PATH = "/api/v1/operations"

#: Server-side content limits, checked here so a rejection costs no round trip
#: and names the rule instead of arriving as a validation error (m03.04 4.3.3).
TITLE_MAX = 200
DESCRIPTION_MAX = 8000
COMMENT_MAX = 4000
PROGRESS_MIN = 0
PROGRESS_MAX = 100

#: A 429 whose `Retry-After` is this short is waited out and resent once with
#: the same key; anything longer is left parked for `retry` (m03.04 4.3.4).
RETRY_AFTER_AUTO_MAX = 30


# --------------------------------------------------------------------------
# Errors
# --------------------------------------------------------------------------


class UsageError(Exception):
    """Bad arguments or bad configuration. Exit 2."""


class ConfigError(UsageError):
    """Missing or unusable environment configuration. Exit 2."""


class TransportError(Exception):
    """The request never produced a usable response. Exit 1."""


class ApiError(Exception):
    """The API answered with an error envelope. Exit 1."""

    def __init__(self, status, code, message):
        super().__init__("{0} {1}: {2}".format(status, code, message))
        self.status = status
        self.code = code
        self.message = message


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------


class Config(object):
    """Base URL and token, validated (m03.04 4.1.3, 4.1.6)."""

    def __init__(self, base_url, token, state_dir=None):
        self.base_url = base_url.rstrip("/")
        self.token = token
        self._state_dir = (state_dir or "").strip() or None

    @property
    def state_dir(self):
        """Where pending writes are parked. Resolved lazily: a read verb never
        needs it, so a machine with no home directory can still read."""
        if self._state_dir:
            return pathlib.Path(self._state_dir)
        try:
            home = pathlib.Path.home()
        except (RuntimeError, OSError):
            raise ConfigError(
                "no home directory to park pending writes in — set {0} to a "
                "writable directory.".format(ENV_STATE_DIR)
            )
        return home / ".doitlist" / "state"

    @property
    def pending_dir(self):
        return self.state_dir / "pending"

    @classmethod
    def from_env(cls, env=None):
        env = os.environ if env is None else env
        url = (env.get(ENV_URL) or "").strip()
        token = (env.get(ENV_TOKEN) or "").strip()
        state_dir = env.get(ENV_STATE_DIR) or ""

        # No fallback service URL: an unset variable is reported, never guessed.
        missing = [name for name, val in ((ENV_URL, url), (ENV_TOKEN, token)) if not val]
        if missing:
            raise ConfigError(
                "{0} is not set. {1}".format(" and ".join(missing), CONNECT_PANEL_HINT)
            )

        validate_base_url(url)
        return cls(url, token, state_dir)

    def redact(self, text):
        """Strip the token from anything headed for a terminal or a file."""
        if not self.token:
            return text
        return str(text).replace(self.token, REDACTED)


def validate_base_url(url):
    """Require an absolute http(s) URL; plain HTTP only on loopback."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ConfigError(
            "{0} must be an absolute http:// or https:// URL (got {1!r}).".format(ENV_URL, url)
        )
    if parts.scheme == "https":
        return url
    host = (parts.hostname or "").lower()
    if host not in LOOPBACK_HOSTS:
        raise ConfigError(
            "{0} must use https:// — plain http:// is allowed only on loopback "
            "({1}); got host {2!r}.".format(ENV_URL, ", ".join(sorted(LOOPBACK_HOSTS)), host)
        )
    return url


# --------------------------------------------------------------------------
# Transport
# --------------------------------------------------------------------------


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    """Refuse every redirect (m03.04 4.1.6).

    Returning ``None`` leaves the 3xx unhandled, so ``urlopen`` raises it as an
    ``HTTPError``; the transport hands the status back and the client refuses
    it. A redirect could send the bearer token to another origin.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class UrllibTransport(object):
    """The real HTTP transport. Swappable so tests need no server."""

    def __init__(self, timeout=DEFAULT_TIMEOUT):
        self.timeout = timeout
        self.opener = urllib.request.build_opener(_NoRedirects)

    def send(self, method, url, headers, body):
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                text = response.read().decode("utf-8", "replace")
                return response.getcode(), text, dict(response.headers.items())
        except urllib.error.HTTPError as exc:
            payload = exc.read().decode("utf-8", "replace") if exc.fp else ""
            return exc.code, payload, dict((exc.headers or {}).items())
        except urllib.error.URLError as exc:
            raise TransportError("could not reach {0}: {1}".format(url, exc.reason))
        except OSError as exc:  # socket timeouts, connection resets
            raise TransportError("could not reach {0}: {1}".format(url, exc))


class Response(object):
    """A delivered HTTP response: status, decoded body, response headers.

    `payload` is `None` when the body was not JSON — indistinguishable from a
    lost response as far as a write's outcome goes, so writers treat it that way.
    """

    def __init__(self, status, text, headers=None):
        self.status = status
        self.text = text
        self.headers = dict(
            (str(name).lower(), value) for name, value in (headers or {}).items()
        )
        self.payload = _decode_soft(text)

    def header(self, name):
        return self.headers.get(name.lower())


class Client(object):
    """One request method over one injectable transport."""

    def __init__(self, config, transport=None):
        self.config = config
        self.transport = transport if transport is not None else UrllibTransport()

    def send(self, method, path, body=None, params=None, extra_headers=None):
        """Deliver one request and hand back the raw `Response`.

        Only an undelivered request raises here. A delivered error response is
        returned intact so a write can read per-operation errors, a conflict's
        current record, and `Retry-After` — none of which survive `request`.
        """
        url = self.config.base_url + path
        query = _query_string(params)
        if query:
            url = url + "?" + query

        headers = {
            "Authorization": "Bearer " + self.config.token,
            "Accept": "application/json",
            "User-Agent": "doitlist-cli",
        }
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if extra_headers:
            headers.update(extra_headers)

        status, text, response_headers = _unpack(self.transport.send(method, url, headers, data))

        if 300 <= status < 400:
            # Never follow: the next hop could be another origin holding our token.
            raise TransportError(
                "redirect refused ({0} from {1}) — configure {2} with the final "
                "URL.".format(status, url, ENV_URL)
            )
        return Response(status, text, response_headers)

    def request(self, method, path, body=None, params=None):
        """`send` plus the strict envelope check: any error becomes `ApiError`."""
        response = self.send(method, path, body=body, params=params)
        payload = _decode(response.text, response.status)

        if isinstance(payload, dict) and "error" in payload:
            err = payload["error"] or {}
            raise ApiError(
                err.get("status", response.status),
                err.get("code", "error"),
                err.get("message", "request failed"),
            )
        if response.status >= 400:
            raise ApiError(response.status, "http_error", "request failed")
        return payload

    def get(self, path, params=None):
        return self.request("GET", path, params=params)


def _unpack(result):
    """Transports may answer `(status, text)` or `(status, text, headers)`."""
    if len(result) == 3:
        return result
    status, text = result
    return status, text, {}


def _query_string(params):
    if not params:
        return ""
    pairs = [(k, v) for k, v in sorted(params.items()) if v is not None]
    return urllib.parse.urlencode(pairs)


def _decode(text, status):
    if not (text or "").strip():
        if status >= 400:
            raise ApiError(status, "http_error", "request failed")
        return {}
    try:
        return json.loads(text)
    except ValueError:
        raise TransportError("response was not JSON (HTTP {0})".format(status))


def _decode_soft(text):
    """`{}` for an empty body, the decoded value, or `None` when it isn't JSON."""
    if not (text or "").strip():
        return {}
    try:
        return json.loads(text)
    except ValueError:
        return None


def _data(payload):
    if isinstance(payload, dict) and "data" in payload:
        return payload["data"]
    return payload


# --------------------------------------------------------------------------
# Reference parsing — ids in, labels out
# --------------------------------------------------------------------------

_INITIATIVE_URL = re.compile(r"/initiatives/(\d+)")


def parse_initiative_ref(value):
    """Accept a numeric id or an Initiative URL (.../initiatives/12)."""
    text = (value or "").strip()
    if text.isdigit():
        return int(text)
    match = _INITIATIVE_URL.search(text)
    if match:
        return int(match.group(1))
    raise UsageError(
        "{0!r} is not an Initiative — pass its id or its URL "
        "(https://host/initiatives/12).".format(value)
    )


def parse_task_ref(value):
    """Accept a numeric id or the `%<id>` form the skill uses for Tasks."""
    text = (value or "").strip()
    if text.startswith("%"):
        text = text[1:]
    if text.isdigit():
        return int(text)
    raise UsageError("{0!r} is not a Task — pass its id or %<id>.".format(value))


def parse_parent_ref(value):
    """Resolve a parent for `add` and `move`, where either kind is legal.

    The sigil decides, so the form the operator already has is the form that
    works: `%<id>` is the Task naming used everywhere in this product, and a
    bare id or an Initiative URL names an Initiative, meaning the top level.
    Returns `("task", id)` or `("initiative", id)`.
    """
    text = (value or "").strip()
    if text.startswith("%"):
        return ("task", parse_task_ref(text))
    if text.isdigit() or _INITIATIVE_URL.search(text):
        return ("initiative", parse_initiative_ref(text))
    raise UsageError(
        "{0!r} is not a parent — pass %<id> for a Task, or an Initiative id or "
        "URL for the top level.".format(value)
    )


def require_text(value, what, limit):
    """Check supplied content against a server limit without altering it.

    Nothing here trims, truncates, or rewrites what the operator passed
    (m03.04 4.3.3): over-limit content is refused and named so the author
    decides what to cut.
    """
    text = "" if value is None else str(value)
    if not text.strip():
        raise UsageError("{0} cannot be empty.".format(what))
    if len(text) > limit:
        raise UsageError(
            "{0} is {1} characters; the limit is {2}. Shorten it yourself — this "
            "client never truncates supplied content.".format(what, len(text), limit)
        )
    return text


def require_int(value, what, low, high=None):
    text = "" if value is None else str(value).strip()
    try:
        number = int(text, 10)
    except ValueError:
        raise UsageError("{0} must be a whole number (got {1!r}).".format(what, value))
    if high is None:
        if number < low:
            raise UsageError("{0} must be {1} or more (got {2}).".format(what, low, number))
    elif number < low or number > high:
        raise UsageError(
            "{0} must be between {1} and {2} (got {3}).".format(what, low, high, number)
        )
    return number


# --------------------------------------------------------------------------
# Formatting
# --------------------------------------------------------------------------


def fmt_progress(value):
    return "{0}%".format(int(value or 0))


def fmt_time(value):
    """ISO-8601 UTC -> `YYYY-MM-DD HH:MM`; unparseable input passes through."""
    text = (value or "").strip()
    if not text:
        return ""
    try:
        return datetime.strptime(text[:19], "%Y-%m-%dT%H:%M:%S").strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return text


def task_row(node, indent, hidden_children=0):
    """One outline line: label, title, id, Progress, done mark, branch/leaf.

    `progress` and `leaf` are printed as the API reports them (m03.04 4.2.3) —
    never recomputed from the rows that happen to be visible, so a depth cut
    cannot change what a Task claims about itself.
    """
    cells = []
    index = (node.get("index") or "").strip()
    if index:
        cells.append(index)
    cells.append(node.get("title") or "")
    line = "{0}{1}  %{2}  {3}  {4}  {5}".format(
        "  " * indent,
        " ".join(cells),
        node.get("id"),
        fmt_progress(node.get("progress")),
        "[x]" if node.get("done") else "[ ]",
        "leaf" if node.get("leaf") else "branch",
    )
    if hidden_children:
        line += " ({0} {1} not shown)".format(
            hidden_children, "child" if hidden_children == 1 else "children"
        )
    return line


def render_outline(nodes, level, indent_offset, depth_limit, lines):
    """Emit `nodes` and their descendants; `level` is depth below the scope root.

    Completed Tasks are always included — the shared-work standard forbids an
    open-only filter, so there is no flag to add one.
    """
    if depth_limit is not None and level > depth_limit:
        return lines
    for node in nodes:
        children = node.get("children") or []
        cut = depth_limit is not None and level == depth_limit and bool(children)
        lines.append(task_row(node, level - indent_offset, len(children) if cut else 0))
        if not cut:
            render_outline(children, level + 1, indent_offset, depth_limit, lines)
    return lines


def find_task(nodes, task_id):
    for node in nodes:
        if node.get("id") == task_id:
            return node
        found = find_task(node.get("children") or [], task_id)
        if found is not None:
            return found
    return None


def summarize_data(data):
    """Compact `key=value` rendering of an activity event's payload."""
    if not data:
        return ""
    if not isinstance(data, dict):
        return _compact_value(data)
    return " ".join(
        "{0}={1}".format(key, _compact_value(data[key])) for key in sorted(data)
    )


def _compact_value(value, limit=60):
    if isinstance(value, str):
        text = " ".join(value.split())
    elif value is None:
        text = "null"
    else:
        text = json.dumps(value, separators=(",", ":"))
    if len(text) > limit:
        text = text[: limit - 3] + "..."
    return text


def actor_name(event):
    if event.get("actor_kind") == "api_token" and event.get("api_token_label"):
        return event["api_token_label"]
    return event.get("user_name") or event.get("api_token_label") or "unknown"


# --------------------------------------------------------------------------
# Verbs
# --------------------------------------------------------------------------


def cmd_list(client, args, out, err):
    initiatives = _data(client.get("/api/v1/initiatives")) or []
    if not initiatives:
        out.write("no Initiatives\n")
        return EXIT_OK
    for initiative in initiatives:
        out.write(
            "{0}  {1}  {2}\n".format(
                initiative.get("name") or "",
                initiative.get("url") or "",
                fmt_progress(initiative.get("progress")),
            )
        )
    return EXIT_OK


def cmd_tree(client, args, out, err):
    initiative_id = parse_initiative_ref(args.initiative)
    depth = args.depth
    if depth is not None and depth < 1:
        raise UsageError("--depth must be 1 or more (levels below the displayed root).")

    payload = _data(client.get("/api/v1/initiatives/{0}".format(initiative_id)))
    tasks = payload.get("tasks") or []

    if args.under:
        task_id = parse_task_ref(args.under)
        root = find_task(tasks, task_id)
        if root is None:
            raise UsageError(
                "Task %{0} is not in {1}.".format(task_id, payload.get("name") or "that Initiative")
            )
        scope = "under %{0} {1}".format(task_id, root.get("title") or "")
        nodes, level, offset = [root], 0, 0
    else:
        scope = "whole tree"
        nodes, level, offset = tasks, 1, 1

    out.write(
        "Initiative: {0}  {1}  {2}\n".format(
            payload.get("name") or "",
            payload.get("url") or "",
            fmt_progress(payload.get("progress")),
        )
    )
    out.write("Scope: {0}\n".format(scope))
    out.write("Depth: {0}\n".format("all" if depth is None else depth))

    lines = render_outline(nodes, level, offset, depth, [])
    if not lines:
        out.write("no Tasks\n")
    for line in lines:
        out.write(line + "\n")
    return EXIT_OK


def cmd_comments(client, args, out, err):
    task_id = parse_task_ref(args.task)
    ref = _data(client.get("/api/v1/tasks/{0}".format(task_id)))
    initiative_id = ref.get("initiative_id")
    comments = (
        _data(
            client.get(
                "/api/v1/initiatives/{0}/tasks/{1}/comments".format(initiative_id, task_id)
            )
        )
        or []
    )
    if not comments:
        out.write("no comments on %{0}\n".format(task_id))
        return EXIT_OK
    for comment in comments:
        body = "[deleted]" if comment.get("deleted") else (comment.get("body") or "")
        out.write(
            "{0}  {1}  {2}\n".format(
                comment.get("author_name") or "unknown",
                fmt_time(comment.get("inserted_at")),
                body,
            )
        )
    return EXIT_OK


def cmd_activity(client, args, out, err):
    initiative_id = parse_initiative_ref(args.initiative)
    params = {}
    if args.task:
        params["task_id"] = parse_task_ref(args.task)
    if args.limit is not None:
        if args.limit < 1:
            raise UsageError("--limit must be 1 or more.")
        params["limit"] = args.limit

    payload = client.get(
        "/api/v1/initiatives/{0}/activity".format(initiative_id), params=params or None
    )
    events = _data(payload) or []
    if not events:
        out.write("no activity\n")
        return EXIT_OK
    for event in events:
        line = "{0}  {1}  {2}  {3}".format(
            fmt_time(event.get("inserted_at")),
            actor_name(event),
            event.get("kind") or "",
            summarize_data(event.get("data")),
        )
        out.write(line.rstrip() + "\n")
    meta = payload.get("meta") if isinstance(payload, dict) else None
    if isinstance(meta, dict) and meta.get("has_more"):
        out.write("more available\n")
    return EXIT_OK


# --------------------------------------------------------------------------
# Pending-write store (m03.04 4.3.4)
# --------------------------------------------------------------------------
# A write is parked on disk BEFORE it is sent, so an interrupted run always
# leaves behind the two things a safe retry needs: the exact body and the
# idempotency key it went out under. Nothing else is written — no token, no
# base URL, no headers — because the file outlives the process and the token
# does not belong in it. `retry` resends what is parked; the server replays
# its stored response for a key it has already committed.


def new_key():
    return str(uuid.uuid4())


def now_utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def pending_path(config, key):
    return config.pending_dir / (key + ".json")


def save_pending(config, record):
    path = pending_path(config, record["key"])
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.parent / (path.name + ".tmp")
    temp.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temp.replace(path)  # atomic: a crash mid-write never leaves half a record
    return path


def clear_pending(config, key):
    """Drop a parked request once its outcome is known, whatever the outcome."""
    try:
        pending_path(config, key).unlink()
    except OSError:
        pass


def load_pending(config, key=None):
    """Parked requests, oldest first; one of them when `key` is given."""
    directory = config.pending_dir
    if not directory.is_dir():
        return []
    records = []
    for path in sorted(directory.glob("*.json")):
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(record, dict) and record.get("key") and record.get("body"):
            records.append(record)
    if key:
        records = [record for record in records if record["key"] == key]
    records.sort(key=lambda record: record.get("created_at") or "")
    return records


def parse_retry_after(value):
    """Seconds from a `Retry-After` header; `None` for a date or a bad value."""
    text = (value or "").strip()
    return int(text) if text.isdigit() else None


# --------------------------------------------------------------------------
# Compact write results (m03.04 4.8)
# --------------------------------------------------------------------------


def result_line(display, data):
    """One line per affected Task: what happened, which Task, and the change.

    `display` is stored with the parked request, so a `retry` days later prints
    the same line the original run would have.
    """
    data = data or {}
    is_comment = data.get("type") == "comment"
    identifier = data.get("task_id") if is_comment else data.get("id")
    cells = [display.get("label") or "ok", "%{0}".format(identifier)]
    title = data.get("title") or display.get("title") or ""
    if title:
        cells.append(title)
    if display.get("progress"):
        cells.append(fmt_progress(data.get("progress")))
    if display.get("done"):
        cells.append("[x]" if data.get("done") else "[ ]")
    if display.get("suffix"):
        cells.append(display["suffix"])
    return "  ".join(cells)


def current_line(current):
    """The conflict's current record, compact enough to reassess from."""
    return "%{0}  {1}  {2}  {3}  version {4}".format(
        current.get("id"),
        current.get("title") or "",
        fmt_progress(current.get("progress")),
        "[x]" if current.get("done") else "[ ]",
        current.get("version"),
    )


def first_conflict(results):
    for item in results or []:
        error = item.get("error") or {}
        if item.get("status") == "error" and error.get("code") == "conflict":
            return error
    return None


def write_response_file(config, path, payload, out):
    """Save the full response for inspection instead of printing JSON (4.8.2).

    A failure here never rewrites what already happened on the server, so it is
    reported alongside the outcome rather than raised over the top of it.
    """
    target = pathlib.Path(path)
    try:
        if str(target.parent) not in ("", "."):
            target.parent.mkdir(parents=True, exist_ok=True)
        text = json.dumps(payload, indent=2, sort_keys=True) + "\n"
        target.write_text(config.redact(text), encoding="utf-8")
    except OSError as exc:
        out.write("could not save the response to {0}: {1}\n".format(target, exc))
        return False
    out.write("saved: {0}\n".format(target))
    return True


# --------------------------------------------------------------------------
# Write verbs (m03.04 4.3)
# --------------------------------------------------------------------------


def read_task(client, task_id):
    """The pre-write read: proves the Task exists and yields its version."""
    task = _data(client.get("/api/v1/tasks/{0}".format(task_id)))
    if not isinstance(task, dict) or task.get("version") is None:
        raise ApiError(200, "unexpected_response", "Task %{0} came back without a version.".format(task_id))
    return task


def read_initiative(client, initiative_id):
    initiative = _data(client.get("/api/v1/initiatives/{0}".format(initiative_id)))
    if not isinstance(initiative, dict):
        raise ApiError(200, "unexpected_response", "Initiative {0} came back empty.".format(initiative_id))
    return initiative


def deliver(client, record, out, sleeper):
    """Send (or resend) one parked request and resolve its outcome.

    Returns `(exit code, response payload or None)`. The payload is `None`
    exactly when the outcome is unknown, which is also when the request stays
    parked — an unknown outcome is never reported as success (m03.04 4.3.4).
    """
    config = client.config
    headers = {"Idempotency-Key": record["key"]}

    def attempt():
        return client.send(
            record["method"], record["path"], body=record["body"], extra_headers=headers
        )

    try:
        response = attempt()
        if response.status == 429:
            wait = parse_retry_after(response.header("Retry-After"))
            if wait is not None and wait <= RETRY_AFTER_AUTO_MAX:
                # Short backoff, then one resend under the SAME key: either the
                # first attempt never ran, or the server replays its response.
                sleeper(wait)
                response = attempt()
    except TransportError as exc:
        return unresolved(config, record, out, str(exc)), None

    if response.status == 429:
        wait = parse_retry_after(response.header("Retry-After"))
        out.write("rate limited: {0}\n".format(record["summary"]))
        out.write(
            "  {0}still pending — retry with: doitlist.py retry {1}\n".format(
                "" if wait is None else "wait {0}s; ".format(wait), record["key"]
            )
        )
        return EXIT_API, None

    if response.status == 408 or response.status >= 500 or response.payload is None:
        return unresolved(config, record, out, "HTTP {0}".format(response.status)), None

    # Delivered and definitive: whatever it says, this key is settled.
    clear_pending(config, record["key"])
    payload = response.payload if isinstance(response.payload, dict) else {}
    results = payload.get("results") or []
    top = payload.get("error") or {}

    conflict = first_conflict(results)
    if conflict is not None:
        # 4.3.5: hand back the current record and stop. Resubmitting with the
        # version we just learned would overwrite whatever changed under us.
        out.write("conflict: {0}\n".format(record["summary"]))
        out.write("  {0}\n".format(current_line(conflict.get("current") or {})))
        out.write("  nothing was applied — re-read, then decide.\n")
        return EXIT_API, payload

    if top or response.status >= 400:
        out.write(
            "failed ({0} {1}): {2}\n".format(
                top.get("status", response.status),
                top.get("code", "error"),
                config.redact(top.get("message") or "request failed"),
            )
        )
        for item in results:
            if item.get("status") == "error":
                error = item.get("error") or {}
                out.write(
                    "  op {0} {1} {2}: {3}\n".format(
                        item.get("index", 0),
                        error.get("code") or "error",
                        error.get("pointer") or "-",
                        config.redact(error.get("message") or ""),
                    )
                )
        return EXIT_API, payload

    display = record.get("display") or {"label": record.get("verb") or "ok"}
    if not results:  # a committed batch always reports its ops; say so if not
        out.write("ok: {0}\n".format(record["summary"]))
    for item in results:
        out.write(result_line(display, item.get("data")) + "\n")
    return EXIT_OK, payload


def unresolved(config, record, out, reason):
    """Neither applied nor refused. Say exactly that, and how to settle it."""
    out.write(
        "outcome unknown: {0} ({1})\n".format(record["summary"], config.redact(reason))
    )
    out.write(
        "  still pending — retry with: doitlist.py retry {0}\n".format(record["key"])
    )
    return EXIT_API


def run_write(client, args, out, verb, operation, summary, display):
    """Park the request, send it, print the compact outcome, save it if asked."""
    record = {
        "key": new_key(),
        "created_at": now_utc(),
        "method": "POST",
        "path": OPERATIONS_PATH,
        "body": {"operations": [operation]},
        "verb": verb,
        "summary": summary,
        "display": display,
    }
    save_pending(client.config, record)
    code, payload = deliver(client, record, out, args.sleeper)
    if payload is not None and getattr(args, "out", None):
        if not write_response_file(client.config, args.out, payload, out) and code == EXIT_OK:
            code = EXIT_API
    return code


def cmd_add(client, args, out, err):
    title = require_text(args.title, "title", TITLE_MAX)
    kind, ref_id = parse_parent_ref(args.parent)

    if kind == "task":
        read_task(client, ref_id)  # a missing parent fails before anything is parked
        data = {"parent_id": ref_id, "title": title}
        where = "under %{0}".format(ref_id)
    else:
        initiative = read_initiative(client, ref_id)
        data = {"initiative_id": ref_id, "title": title}
        where = "top level of {0}".format(initiative.get("name") or ref_id)

    return run_write(
        client,
        args,
        out,
        verb="add",
        operation={"op": "add", "type": "task", "lid": "t1", "data": data},
        summary='add "{0}" {1}'.format(title, where),
        display={"label": "added", "suffix": where},
    )


def cmd_done(client, args, out, err):
    task_id = parse_task_ref(args.task)
    task = read_task(client, task_id)
    reopening = bool(args.reopen)
    return run_write(
        client,
        args,
        out,
        verb="reopen" if reopening else "done",
        operation={
            "op": "update",
            "type": "task",
            "id": task_id,
            "data": {"done": not reopening, "expected_version": task["version"]},
        },
        summary="{0} %{1} {2}".format(
            "reopen" if reopening else "done", task_id, task.get("title") or ""
        ).rstrip(),
        display={
            "label": "reopened" if reopening else "done",
            "title": task.get("title"),
            "progress": True,
            "done": True,
        },
    )


def cmd_progress(client, args, out, err):
    percent = require_int(args.percent, "progress", PROGRESS_MIN, PROGRESS_MAX)
    task_id = parse_task_ref(args.task)
    task = read_task(client, task_id)
    return run_write(
        client,
        args,
        out,
        verb="progress",
        operation={
            "op": "update",
            "type": "task",
            "id": task_id,
            "data": {"manual_progress": percent, "expected_version": task["version"]},
        },
        summary="progress %{0} to {1}%".format(task_id, percent),
        display={"label": "progress", "title": task.get("title"), "progress": True},
    )


def cmd_move(client, args, out, err):
    task_id = parse_task_ref(args.task)
    kind, ref_id = parse_parent_ref(args.parent)
    position = None if args.position is None else require_int(args.position, "position", 0)

    task = read_task(client, task_id)
    if kind == "task":
        parent_id = ref_id
        where = "under %{0}".format(ref_id)
    else:
        initiative = read_initiative(client, ref_id)
        parent_id = initiative.get("root_task_id")
        if not parent_id:
            raise ApiError(
                200,
                "unexpected_response",
                "Initiative {0} came back without a root_task_id to move under.".format(ref_id),
            )
        where = "top level of {0}".format(initiative.get("name") or ref_id)

    data = {"parent_id": parent_id, "expected_version": task["version"]}
    if position is not None:
        data["position"] = position
        where += " at {0}".format(position)

    return run_write(
        client,
        args,
        out,
        verb="move",
        operation={"op": "update", "type": "task", "id": task_id, "data": data},
        summary="move %{0} {1}".format(task_id, where),
        display={"label": "moved", "title": task.get("title"), "suffix": where},
    )


def cmd_comment(client, args, out, err):
    body = require_text(args.text, "comment body", COMMENT_MAX)
    task_id = parse_task_ref(args.task)
    task = read_task(client, task_id)
    # `add comment` takes no expected_version — a comment cannot clobber a
    # concurrent edit — so the read is here to prove the Task and name it.
    return run_write(
        client,
        args,
        out,
        verb="comment",
        operation={
            "op": "add",
            "type": "comment",
            "lid": "c1",
            "data": {"task_id": task_id, "body": body},
        },
        summary="comment on %{0}".format(task_id),
        display={"label": "commented", "title": task.get("title")},
    )


def cmd_retitle(client, args, out, err):
    title = require_text(args.title, "title", TITLE_MAX)
    task_id = parse_task_ref(args.task)
    task = read_task(client, task_id)
    return run_write(
        client,
        args,
        out,
        verb="retitle",
        operation={
            "op": "update",
            "type": "task",
            "id": task_id,
            "data": {"title": title, "expected_version": task["version"]},
        },
        summary="retitle %{0}".format(task_id),
        display={"label": "retitled", "title": task.get("title")},
    )


def cmd_describe(client, args, out, err):
    description = require_text(args.text, "description", DESCRIPTION_MAX)
    task_id = parse_task_ref(args.task)
    task = read_task(client, task_id)
    return run_write(
        client,
        args,
        out,
        verb="describe",
        operation={
            "op": "update",
            "type": "task",
            "id": task_id,
            "data": {"description": description, "expected_version": task["version"]},
        },
        summary="describe %{0}".format(task_id),
        display={"label": "described", "title": task.get("title")},
    )


def cmd_retry(client, args, out, err):
    """Resend parked writes under their original keys and bodies (4.3.4)."""
    records = load_pending(client.config, args.key)
    if not records:
        if args.key:
            raise UsageError(
                "no pending request with key {0} — run `retry` with no key to "
                "see what is parked.".format(args.key)
            )
        out.write("no pending requests\n")
        return EXIT_OK

    worst = EXIT_OK
    saved = []
    for record in records:
        out.write("retrying: {0}\n".format(record.get("summary") or record["key"]))
        code, payload = deliver(client, record, out, args.sleeper)
        worst = max(worst, code)
        if payload is not None:
            saved.append({"key": record["key"], "response": payload})
    if saved and getattr(args, "out", None):
        # A list, one entry per resent key: `retry` may settle several at once.
        if not write_response_file(client.config, args.out, saved, out) and worst == EXIT_OK:
            worst = EXIT_API
    return worst


# --------------------------------------------------------------------------
# Seam: local completion mirroring (m03.04 item 4.7 — nothing built yet)
# --------------------------------------------------------------------------
# Mirroring belongs on this side of the wire: the API owns import parsing and
# the live tree, the client owns the operator's local files. When 4.7 lands,
# `done <task> --mirror <file> --section <heading>` reads the live tree through
# `Client.request`, writes the completion, then rewrites the one matching
# checkbox in the named section. It reuses `Client`, `parse_task_ref`, and the
# formatting helpers above; no mirroring state exists yet by design.


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def build_parser():
    parser = argparse.ArgumentParser(
        prog="doitlist",
        description=(
            "Do It List scripted client. Reads {0} and {1} from the "
            "environment (the connect panel emits both).".format(ENV_URL, ENV_TOKEN)
        ),
    )
    subparsers = parser.add_subparsers(dest="verb")

    listing = subparsers.add_parser("list", help="list the Initiatives you can reach")
    listing.set_defaults(handler=cmd_list)

    tree = subparsers.add_parser("tree", help="print an Initiative's outline")
    tree.add_argument("initiative", help="Initiative id or URL")
    tree.add_argument("--under", metavar="TASK", help="scope to a Task and its descendants (id or %%<id>)")
    tree.add_argument(
        "--depth",
        type=int,
        metavar="N",
        help="levels below the displayed root (top-level Tasks are level 1)",
    )
    tree.set_defaults(handler=cmd_tree)

    comments = subparsers.add_parser("comments", help="print a Task's comments")
    comments.add_argument("task", help="Task id or %%<id>")
    comments.set_defaults(handler=cmd_comments)

    activity = subparsers.add_parser("activity", help="print an Initiative's activity")
    activity.add_argument("initiative", help="Initiative id or URL")
    activity.add_argument("--task", metavar="TASK", help="only this Task's events (id or %%<id>)")
    activity.add_argument("--limit", type=int, metavar="N", help="how many events to fetch")
    activity.set_defaults(handler=cmd_activity)

    # Every write verb can park its full response instead of printing JSON.
    saving = argparse.ArgumentParser(add_help=False)
    saving.add_argument(
        "--out",
        metavar="FILE",
        help="save the full API response as JSON to FILE and print the path",
    )

    add = subparsers.add_parser("add", parents=[saving], help="add a Task under a parent")
    add.add_argument("parent", help="%%<id> for a parent Task, or an Initiative id/URL for the top level")
    add.add_argument("title", help="the new Task's title (1-{0} characters)".format(TITLE_MAX))
    add.set_defaults(handler=cmd_add)

    done = subparsers.add_parser("done", parents=[saving], help="complete a Task")
    done.add_argument("task", help="Task id or %%<id>")
    done.add_argument("--reopen", action="store_true", help="reopen it instead")
    done.set_defaults(handler=cmd_done)

    progress = subparsers.add_parser("progress", parents=[saving], help="set a Task's Progress")
    progress.add_argument("task", help="Task id or %%<id>")
    progress.add_argument("percent", help="whole number, {0}-{1}".format(PROGRESS_MIN, PROGRESS_MAX))
    progress.set_defaults(handler=cmd_progress)

    move = subparsers.add_parser("move", parents=[saving], help="reparent or reorder a Task")
    move.add_argument("task", help="Task id or %%<id>")
    move.add_argument("parent", help="%%<id> for the new parent Task, or an Initiative id/URL for the top level")
    move.add_argument("position", nargs="?", help="zero-based position among the new siblings")
    move.set_defaults(handler=cmd_move)

    comment = subparsers.add_parser("comment", parents=[saving], help="comment on a Task")
    comment.add_argument("task", help="Task id or %%<id>")
    comment.add_argument("text", help="the comment body (1-{0} characters)".format(COMMENT_MAX))
    comment.set_defaults(handler=cmd_comment)

    retitle = subparsers.add_parser("retitle", parents=[saving], help="change a Task's title")
    retitle.add_argument("task", help="Task id or %%<id>")
    retitle.add_argument("title", help="the new title (1-{0} characters)".format(TITLE_MAX))
    retitle.set_defaults(handler=cmd_retitle)

    describe = subparsers.add_parser("describe", parents=[saving], help="set a Task's description")
    describe.add_argument("task", help="Task id or %%<id>")
    describe.add_argument("text", help="the description (1-{0} characters)".format(DESCRIPTION_MAX))
    describe.set_defaults(handler=cmd_describe)

    retry = subparsers.add_parser("retry", parents=[saving], help="resend writes whose outcome is unknown")
    retry.add_argument("key", nargs="?", help="one pending key; omit to resend all, oldest first")
    retry.set_defaults(handler=cmd_retry)

    return parser


VERBS = "list, tree, comments, activity, add, done, progress, move, comment, retitle, describe, retry"


def main(argv=None, env=None, transport=None, out=None, err=None, sleeper=None):
    argv = sys.argv[1:] if argv is None else argv
    out = sys.stdout if out is None else out
    err = sys.stderr if err is None else err

    parser = build_parser()
    args = parser.parse_args(argv)  # argparse exits 2 on an unknown verb
    if not getattr(args, "handler", None):
        parser.print_usage(err)
        err.write("doitlist: a verb is required ({0})\n".format(VERBS))
        return EXIT_USAGE

    # Injectable so the rate-limit backoff is exercised without real waiting.
    args.sleeper = time.sleep if sleeper is None else sleeper

    config = None
    try:
        config = Config.from_env(env)
        client = Client(config, transport=transport)
        return args.handler(client, args, out, err)
    except UsageError as exc:
        err.write("doitlist: {0}\n".format(_safe(config, exc)))
        return EXIT_USAGE
    except ApiError as exc:
        err.write(
            "doitlist: API error {0} {1}: {2}\n".format(
                exc.status, exc.code, _safe(config, exc.message)
            )
        )
        return EXIT_API
    except TransportError as exc:
        err.write("doitlist: {0}\n".format(_safe(config, exc)))
        return EXIT_API


def _safe(config, message):
    """Last gate before anything reaches a stream: no token ever leaves here."""
    text = str(message)
    return config.redact(text) if config is not None else text


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
