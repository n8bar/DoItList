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
client only shapes requests, formats responses, and mirrors completion into
the operator's own Markdown (m03.04 4.7), which the API never reads or writes.

Operator-facing output uses labels, titles, and URLs; ids appear only as
`%<id>` beside a title, which is how the companion skill names Tasks.
API requests use ids (m03.04 4.1.5).

Every write reads current state first and submits ONE operation through
`POST /api/v1/operations` carrying the `expected_version` from that read
(m03.04 4.3.2), under a generated `Idempotency-Key` that is parked on disk
before the request leaves (4.3.4). A lost response therefore never becomes a
lost or duplicated write: `retry` resends the parked request with the same key
and the same body, and the server replays its stored response.

`import` is the one write that parks nothing (m03.04 4.4): the imports endpoint
is idempotent by source hash per target, so re-running the same command replays
the first apply instead of duplicating it. `diff` is that endpoint's preview
against an existing target, and writes nothing at all.

Streams: a write's outcome block — success, failure, conflict, unknown
outcome, and any `saved:` path — goes to stdout as one compact unit
(m03.04 4.8) so an agent reads it in one place; the exit code carries the
verdict. stderr carries only the `doitlist: ...` line for a usage,
configuration, or read error.

Exit codes: 0 ok, 1 API/network error, 2 usage or configuration error.
"""

import argparse
import hashlib
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

#: `diff` exits nonzero when the document and the live tree disagree, so a
#: script can branch on it. Same value as EXIT_API: nonzero is "not clean".
EXIT_DIFFERENT = EXIT_API

#: The one write endpoint: every verb submits a single-operation batch.
OPERATIONS_PATH = "/api/v1/operations"

#: Documents go here instead (m03.04 4.4). Parsing stays on the server.
IMPORTS_PATH = "/api/v1/imports"

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


class MirrorError(Exception):
    """The mirror's checkbox could not be resolved or written (m03.04 4.7).

    Raised before the live write it becomes a usage error and nothing is sent;
    raised after it, the live Task is already done, so it is reported as an
    owed file update rather than a failed completion.
    """


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
    """Accept a numeric id, `%272`, or the stored `%<272>` form (literal brackets)."""
    text = (value or "").strip()
    if text.startswith("%"):
        text = text[1:]
        if text.startswith("<") and text.endswith(">"):
            text = text[1:-1]
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


def fmt_units(payload):
    """The Initiative's unit count as `N leaves` / `N top-level Tasks`, per its
    `progress_calc`; `None` when the server did not report one."""
    if "unit_count" not in payload:
        return None
    count = int(payload.get("unit_count") or 0)
    if payload.get("progress_calc") == "single_level":
        noun = "top-level Task" if count == 1 else "top-level Tasks"
    else:
        noun = "leaf" if count == 1 else "leaves"
    return "{0} {1}".format(count, noun)


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

    header = [
        payload.get("name") or "",
        payload.get("url") or "",
        fmt_progress(payload.get("progress")),
    ]
    units = fmt_units(payload)
    if units is not None:
        header.append(units)
    out.write("Initiative: {0}\n".format("  ".join(header)))
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


def write_failure(config, payload, status, out):
    """The one-line verdict a refused write or import opens with."""
    top = (payload or {}).get("error") or {}
    out.write(
        "failed ({0} {1}): {2}\n".format(
            top.get("status", status),
            top.get("code", "error"),
            config.redact(top.get("message") or "request failed"),
        )
    )


def write_op_errors(config, results, out):
    """One line per refused operation — actionable, not just the batch verdict."""
    for item in results or []:
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

    payload = response.payload if isinstance(response.payload, dict) else {}
    results = payload.get("results") or []
    top = payload.get("error") or {}
    conflict = first_conflict(results)
    committed = conflict is None and not top and response.status < 400

    # Delivered and definitive: whatever it says, this key is settled — unless
    # a mirrored completion still owes its local checkbox, in which case the
    # record advances to `live_done` and stays parked so `retry` can finish the
    # file without ever re-POSTing the completion (m03.04 4.7.4).
    if committed and record.get("mirror"):
        record["stage"] = STAGE_LIVE_DONE
        save_pending(config, record)
    else:
        clear_pending(config, record["key"])

    if conflict is not None:
        # 4.3.5: hand back the current record and stop. Resubmitting with the
        # version we just learned would overwrite whatever changed under us.
        out.write("conflict: {0}\n".format(record["summary"]))
        out.write("  {0}\n".format(current_line(conflict.get("current") or {})))
        out.write("  nothing was applied — re-read, then decide.\n")
        return EXIT_API, payload

    if top or response.status >= 400:
        write_failure(config, payload, response.status, out)
        write_op_errors(config, results, out)
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


def save_response(client, args, payload, out, code):
    """`--out`: park the full response instead of printing JSON (4.8.2).

    A save failure never rewrites what already happened on the server, so it
    only downgrades an otherwise-clean exit.
    """
    if payload is None or not getattr(args, "out", None):
        return code
    if not write_response_file(client.config, args.out, payload, out) and code == EXIT_OK:
        return EXIT_API
    return code


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
    return save_response(client, args, payload, out, code)


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
    if args.numbered:
        data["numbered_title"] = True

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
    mirror = mirror_options(args)
    if mirror is not None:
        return done_mirrored(client, args, out, task_id, mirror)

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
    data = {"title": title, "expected_version": task["version"]}
    if args.numbered:
        data["numbered_title"] = True
    return run_write(
        client,
        args,
        out,
        verb="retitle",
        operation={"op": "update", "type": "task", "id": task_id, "data": data},
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
        if record.get("mirror") and record.get("stage") == STAGE_LIVE_DONE:
            # The live half committed already; only the checkbox is owed, and
            # re-POSTing it would be a second completion (m03.04 4.7.4).
            worst = max(worst, resume_mirror(client, record, out))
            continue
        code, payload = deliver(client, record, out, args.sleeper)
        if code == EXIT_OK and record.get("mirror"):
            code = mirror_after_retry(client, record, out)
        worst = max(worst, code)
        if payload is not None:
            saved.append({"key": record["key"], "response": payload})
    if saved and getattr(args, "out", None):
        # A list, one entry per resent key: `retry` may settle several at once.
        if not write_response_file(client.config, args.out, saved, out) and worst == EXIT_OK:
            worst = EXIT_API
    return worst


# --------------------------------------------------------------------------
# Import and diff (m03.04 4.4)
# --------------------------------------------------------------------------
# The document's own bytes go over the wire and the API decides the tree
# (4.1.2): nothing here parses, reflows, or renumbers a source file. An apply
# carries NO `Idempotency-Key` and parks nothing, because the imports endpoint
# is already idempotent by source hash per target — re-running the same command
# replays the first apply instead of duplicating it. `diff` is the same
# endpoint's preview against an existing target: read-only on both sides.


def read_source(path):
    """The source document, verbatim.

    `newline=""` keeps the file's own line endings, so a CRLF document reaches
    the API exactly as written; nothing here trims, normalizes, or reflows it.
    """
    try:
        with open(path, encoding="utf-8", newline="") as handle:
            return handle.read()
    except UnicodeDecodeError:
        raise UsageError("{0} is not UTF-8 text — re-save it as UTF-8 and retry.".format(path))
    except OSError as exc:
        raise UsageError("could not read {0}: {1}".format(path, exc.strerror or exc))


def initiative_name(text, path, given):
    """Name a NEW Initiative: `--as`, else the document's first `# ` heading,
    else the file's stem.

    Picking a name is not parsing — the API still decides every Task, the
    nesting, and the numbering (4.1.2).
    """
    if given is not None:
        name = given.strip()
        if not name:
            raise UsageError("--as cannot be empty.")
        return name
    for line in text.splitlines():
        if line.startswith("# "):
            heading = line[2:].strip()
            if heading:
                return heading
            break
    stem = os.path.splitext(os.path.basename(path))[0].strip()
    if not stem:
        raise UsageError("could not name an Initiative from {0} — pass --as NAME.".format(path))
    return stem


def import_target(args, text):
    """Where the document lands: an existing Initiative, or a new one."""
    if args.into:
        target = {"initiative_id": parse_initiative_ref(args.into)}
        if args.under:
            target["parent_task_id"] = parse_task_ref(args.under)
        return target
    return {"initiative_name": initiative_name(text, args.file, args.name)}


def counts_line(payload, batches=None):
    """The document's measurements, one line — the same line in both modes."""
    counts = payload.get("counts") or {}
    cells = [
        "{0} items".format(counts.get("items", 0)),
        "{0} done".format(counts.get("done", 0)),
        "depth {0}".format(counts.get("depth", 0)),
        "style {0}".format(payload.get("style") or "none"),
    ]
    if batches is not None:
        cells.append("{0} batch{1}".format(batches, "" if batches == 1 else "es"))
    return ", ".join(cells)


def import_label(payload, path):
    """The document's title, else the Initiative it named, else the file."""
    target = payload.get("target") or {}
    return payload.get("title") or target.get("name") or os.path.basename(path)


def write_imported(payload, path, out):
    initiative = payload.get("initiative") or {}
    out.write(
        "imported  {0}  {1}\n".format(import_label(payload, path), initiative.get("url") or "")
    )
    out.write(counts_line(payload, payload.get("batches")) + "\n")
    if payload.get("replayed"):
        out.write("replayed (nothing new was created)\n")


def write_import_failure(config, payload, status, out):
    """A refused import, and — when batches had already committed — what landed.

    `total_batches` is the response's own denominator; without it the line
    still says what committed rather than inventing one.
    """
    write_failure(config, payload, status, out)
    applied = payload.get("applied_batches") or 0
    if applied:
        total = payload.get("total_batches")
        landed = (
            "applied {0} batch{1}".format(applied, "" if applied == 1 else "es")
            if not total
            else "applied {0} of {1} batches".format(applied, total)
        )
        out.write(
            "{0} — the target holds a partial import; "
            "diff it to see what landed\n".format(landed)
        )
        url = (payload.get("initiative") or {}).get("url")
        if url:
            out.write("  {0}\n".format(url))
    write_op_errors(config, payload.get("results"), out)
    return EXIT_API


def import_unknown(config, path, out, reason):
    """Neither applied nor refused — and safe to simply run again."""
    out.write("outcome unknown: import {0} ({1})\n".format(path, config.redact(reason)))
    out.write("  re-run the same command — a repeat apply replays instead of duplicating\n")
    return EXIT_API


def cmd_import(client, args, out, err):
    if args.under and not args.into:
        raise UsageError(
            "--under names a Task inside --into; pass --into <initiative> as well."
        )

    text = read_source(args.file)
    body = {
        "text": text,
        "filename": os.path.basename(args.file),
        "target": import_target(args, text),
        "preview": bool(args.preview),
    }

    if args.preview:
        payload = client.request("POST", IMPORTS_PATH, body=body)
        out.write(counts_line(payload) + "\n")
        outline = payload.get("outline") or ""
        if outline:
            out.write(outline + "\n")
        return save_response(client, args, payload, out, EXIT_OK)

    try:
        response = client.send("POST", IMPORTS_PATH, body=body)
    except TransportError as exc:
        return import_unknown(client.config, args.file, out, str(exc))

    if response.status == 408 or response.status >= 500 or response.payload is None:
        return import_unknown(client.config, args.file, out, "HTTP {0}".format(response.status))

    payload = response.payload if isinstance(response.payload, dict) else {}
    if payload.get("error") or response.status >= 400:
        code = write_import_failure(client.config, payload, response.status, out)
    else:
        write_imported(payload, args.file, out)
        code = EXIT_OK
    return save_response(client, args, payload, out, code)


def diff_target(initiative, under_id):
    where = "  ".join(
        part for part in (initiative.get("name") or "", initiative.get("url") or "") if part
    )
    return where if under_id is None else "%{0} in {1}".format(under_id, where)


def completion_row(entry):
    return "  {0}  source {1}  live {2}  %{3}".format(
        entry.get("path") or "",
        "[x]" if entry.get("source_done") else "[ ]",
        "[x]" if entry.get("live_done") else "[ ]",
        entry.get("id"),
    )


def order_row(entry):
    return "  under {0}: source {1} / live {2}".format(
        entry.get("parent") or "",
        " > ".join(entry.get("source") or []),
        " > ".join(entry.get("live") or []),
    )


#: Each finding list, in the order a reader acts on it, with its row renderer.
DIFF_SECTIONS = (
    ("missing", lambda entry: "  {0}".format(entry.get("path") or "")),
    ("extra", lambda entry: "  {0}  %{1}".format(entry.get("path") or "", entry.get("id"))),
    ("completion", completion_row),
    ("order", order_row),
)


def write_diff(report, out):
    for key, render in DIFF_SECTIONS:
        entries = report.get(key) or []
        if not entries:
            continue
        out.write("{0} ({1}):\n".format(key, len(entries)))
        for entry in entries:
            out.write(render(entry) + "\n")
    out.write("matched {0}\n".format((report.get("summary") or {}).get("matched", 0)))


def cmd_diff(client, args, out, err):
    text = read_source(args.file)
    initiative_id = parse_initiative_ref(args.initiative)
    under_id = parse_task_ref(args.under) if args.under else None

    # Named before the document goes up: a bad reference costs no upload, and
    # the report can say which Initiative it read.
    initiative = read_initiative(client, initiative_id)

    target = {"initiative_id": initiative_id}
    if under_id is not None:
        target["parent_task_id"] = under_id

    payload = client.request(
        "POST",
        IMPORTS_PATH,
        body={
            "text": text,
            "filename": os.path.basename(args.file),
            "target": target,
            "preview": True,
        },
    )

    report = payload.get("diff")
    if not isinstance(report, dict):
        raise ApiError(
            200,
            "unexpected_response",
            "the preview came back without a diff for Initiative {0}.".format(initiative_id),
        )

    if report.get("clean"):
        out.write("clean: {0} matches {1}\n".format(args.file, diff_target(initiative, under_id)))
        code = EXIT_OK
    else:
        write_diff(report, out)
        code = EXIT_DIFFERENT
    return save_response(client, args, payload, out, code)


# --------------------------------------------------------------------------
# Local completion mirroring (m03.04 4.7)
# --------------------------------------------------------------------------
# Mirroring belongs on this side of the wire: the API owns import parsing and
# the live tree, the client owns the operator's local files. `done <task>
# --mirror <file> --section <heading>` completes the Task and ticks its one
# matching checkbox in one invocation, over ONE GET and ONE POST (4.7.5) — the
# GET is the Initiative's whole tree, which carries the Task's title and
# version for the write and every other Task's live state for the next-leaf
# line.
#
# Two rules shape everything below. Nothing is matched fuzzily: a checkbox is
# this Task's only when its text is exactly the live title (4.7.2). And the
# live Task is completed first, the file second, with the mirror's recovery
# details parked before either — so a half-finished mirror is always a
# `retry`, never a re-completion (4.7.4).

#: Where a parked mirror write got to. `pending` is the ordinary parked write:
#: the POST has not been resolved. `live_done` means the completion committed
#: and only the checkbox is still owed — `retry` must never re-POST from here.
STAGE_PENDING = "pending"
STAGE_LIVE_DONE = "live_done"

#: ATX headings, up to three spaces of indent; a closed heading's trailing
#: hashes are decoration, not text. Setext (underlined) headings are not
#: sections here — a mirror names its checklists with `#`.
_HEADING = re.compile(r"^[ \t]{0,3}(#{1,6})[ \t]+(.*)$")
_CLOSING_HASHES = re.compile(r"[ \t]+#+[ \t]*$")

#: `- [ ] text`, `* [x] text`, `+ [X] text`, `1. [ ] text`, `1) [ ] text`.
_CHECKBOX = re.compile(r"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+\[([ xX])\][ \t]+(\S.*?)[ \t]*$")


def split_text(text):
    """The file as raw lines with their endings kept, so a rewrite can put
    every untouched line back byte for byte (CRLF included)."""
    return text.splitlines(True)


def split_line(raw):
    """One raw line as `(body, ending)`."""
    parts = raw.splitlines()
    body = parts[0] if parts else ""
    return body, raw[len(body):]


def heading_of(body):
    """`(level, text)` for an ATX heading line, else `None`."""
    match = _HEADING.match(body)
    if match is None:
        return None
    return len(match.group(1)), _CLOSING_HASHES.sub("", match.group(2)).strip()


def checkbox_of(body):
    """`(checked, text, state_span)` for a checkbox line, else `None`.

    The span is where the box's single character sits in `body`, which is how
    a tick is applied without touching one other byte of the line.
    """
    match = _CHECKBOX.match(body)
    if match is None:
        return None
    return match.group(1) != " ", match.group(2), match.span(1)


def section_lines(raw, section):
    """Line indices inside the named heading's section, or `None` if absent.

    The section runs from the heading whose text is exactly `section` to the
    next heading of the same or a shallower level, or to the end of the file.
    """
    start, level = None, 0
    for index, line in enumerate(raw):
        found = heading_of(split_line(line)[0])
        if found is None:
            continue
        if start is None:
            if found[1] == section:
                start, level = index, found[0]
        elif found[0] <= level:
            return list(range(start + 1, index))
    if start is None:
        return None
    return list(range(start + 1, len(raw)))


def checkbox_rows(raw, indices):
    """`(index, checked, text, span)` for every checkbox line in the section."""
    rows = []
    for index in indices:
        found = checkbox_of(split_line(raw[index])[0])
        if found is not None:
            rows.append((index, found[0], found[1], found[2]))
    return rows


def locate_checkbox(raw, section, title):
    """The one line in `section` whose text is exactly `title` (4.7.2).

    Zero matches and several are both refusals: this client never guesses which
    checkbox an operator meant, and never matches fuzzily.
    """
    indices = section_lines(raw, section)
    if indices is None:
        raise MirrorError('no "{0}" heading'.format(section))
    matches = [row for row in checkbox_rows(raw, indices) if row[2] == title]
    if len(matches) != 1:
        raise MirrorError(
            '{0} checkbox lines under "{1}" read exactly "{2}"'.format(
                len(matches), section, title
            )
        )
    return matches[0]


def flip_line(raw_line, span):
    """The same line with its box ticked — indent, marker, spacing, text, and
    line ending all untouched."""
    body, ending = split_line(raw_line)
    return body[: span[0]] + "x" + body[span[1] :] + ending


def file_digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def write_mirror(path, raw):
    """Replace the file atomically: temp alongside it, then `os.replace`.

    A crash therefore leaves either the old file or the new one, never a
    truncated plan. `newline=""` writes the endings the lines already carry.
    """
    target = pathlib.Path(path)
    temp = target.parent / (target.name + ".doitlist.tmp")
    try:
        with open(str(temp), "w", encoding="utf-8", newline="") as handle:
            handle.write("".join(raw))
        try:
            os.chmod(str(temp), os.stat(str(target)).st_mode & 0o7777)
        except OSError:
            pass  # the content matters; the mode is a courtesy
        os.replace(str(temp), str(target))
    except OSError as exc:
        try:
            os.unlink(str(temp))
        except OSError:
            pass
        raise MirrorError("could not write {0}: {1}".format(path, exc.strerror or exc))


def apply_mirror(record):
    """Tick the checkbox now that the live completion has committed (4.7.3).

    The file is read again first. Unchanged since the pre-write read, the
    parked line index is used directly. Changed under us — the operator edited
    their plan while this ran — the checkbox is found again by the same
    exact-match rule, so their edit is preserved and the tick still lands on
    the right line. Returns `(lines, wrote_anything)`.
    """
    mirror = record["mirror"]
    try:
        text = read_source(mirror["file"])
    except UsageError as exc:
        raise MirrorError(str(exc))

    raw = split_text(text)
    row = None
    if file_digest(text) == mirror["file_sha256"]:
        index = mirror["line_index"]
        if 0 <= index < len(raw):
            found = checkbox_of(split_line(raw[index])[0])
            if found is not None and found[1] == mirror["title"]:
                row = (index, found[0], found[1], found[2])
    if row is None:
        row = locate_checkbox(raw, mirror["section"], mirror["title"])

    index, checked, _title, span = row
    if checked:
        return raw, False
    raw = list(raw)
    raw[index] = flip_line(raw[index], span)
    write_mirror(mirror["file"], raw)
    return raw, True


def title_map(nodes, index=None):
    """Every Task in the tree keyed by its exact title, in tree order."""
    index = {} if index is None else index
    for node in nodes:
        index.setdefault(node.get("title") or "", []).append(node)
        title_map(node.get("children") or [], index)
    return index


def next_unfinished(raw, section, tasks):
    """The first still-open leaf named by an unticked line in the section.

    File order decides *which is next*, because the section is the operator's
    own plan; the live tree decides *unfinished*, because it is authoritative.
    Only leaves qualify, so a branch's rolled-up Progress never nominates it. A
    line naming no live Task is skipped rather than guessed at.
    """
    indices = section_lines(raw, section)
    if indices is None:
        return None
    index = title_map(tasks)
    for _line, checked, text, _span in checkbox_rows(raw, indices):
        if checked:
            continue
        for node in index.get(text, []):
            if node.get("leaf") and not node.get("done"):
                return node
    return None


def mirror_line(mirror, flipped):
    return "mirror  {0} § {1}: {2}[x] {3}".format(
        os.path.basename(mirror["file"]),
        mirror["section"],
        "" if flipped else "already ",
        mirror["title"],
    )


def next_line(node):
    if node is None:
        return "next  none in section"
    cells = [
        cell
        for cell in ((node.get("index") or "").strip(), node.get("title") or "")
        if cell
    ]
    return "next  {0}  %{1}".format(" ".join(cells), node.get("id"))


def mirror_options(args):
    """`(file, section)` when this `done` mirrors, else `None`.

    The two options are one instruction, so half of it is a usage error rather
    than a silent live-only completion; and `--reopen` is refused outright,
    because unticking someone's plan is not what reopening a Task asked for.
    """
    path = getattr(args, "mirror", None)
    section = getattr(args, "section", None)
    if not path and not section:
        if getattr(args, "initiative", None):
            raise UsageError(
                "--initiative only applies to a mirrored completion; pass "
                "--mirror <file> --section <heading> as well."
            )
        return None
    if not path or not section:
        raise UsageError(
            "--mirror and --section go together: name the Markdown file and "
            "the heading whose checklist holds the Task."
        )
    if getattr(args, "reopen", False):
        raise UsageError(
            "--reopen is not mirrored — reopening leaves the checkbox alone. "
            "Reopen without --mirror, then complete it again to mirror."
        )
    return path, section


def mirror_initiative(args, text, path):
    """Which Initiative the mirror belongs to: `--initiative`, else the file's
    first Initiative link — the marker a maintained mirror already carries."""
    if getattr(args, "initiative", None):
        return parse_initiative_ref(args.initiative)
    match = _INITIATIVE_URL.search(text)
    if match:
        return int(match.group(1))
    raise UsageError(
        "{0} carries no Initiative link — add the Initiative URL to the file, "
        "or pass --initiative <id or URL>.".format(path)
    )


def finish_mirror(config, record, tasks, out):
    """The local half of a mirrored completion: tick, report, name what's next.

    A failure here never rewrites what already happened on the server. The
    record stays parked at `live_done`, saying exactly what is owed, and the
    line says how to settle it (4.7.4).
    """
    mirror = record["mirror"]
    try:
        raw, flipped = apply_mirror(record)
    except MirrorError as exc:
        out.write(
            "live Task completed; mirror not updated: {0} — fix the file, "
            "then: doitlist.py retry {1}\n".format(config.redact(exc), record["key"])
        )
        return EXIT_API
    clear_pending(config, record["key"])
    out.write(mirror_line(mirror, flipped) + "\n")
    out.write(next_line(next_unfinished(raw, mirror["section"], tasks)) + "\n")
    return EXIT_OK


def mirrored_task_id(record):
    return record["body"]["operations"][0]["id"]


def done_mirrored(client, args, out, task_id, mirror):
    """`done --mirror`: one GET, one POST, then the checkbox (4.7.1, 4.7.5)."""
    path, section = mirror
    text = read_source(path)
    raw = split_text(text)
    initiative_id = mirror_initiative(args, text, path)

    initiative = read_initiative(client, initiative_id)
    tasks = initiative.get("tasks") or []
    task = find_task(tasks, task_id)
    if task is None:
        raise ApiError(
            404,
            "not_found",
            "Task %{0} is not in {1} — mirror a Task from the Initiative the "
            "file links to.".format(task_id, initiative.get("name") or initiative_id),
        )
    title = task.get("title") or ""

    # The match is resolved BEFORE anything is sent: a missing or ambiguous
    # checkbox refuses the whole command, live Task included (4.7.2).
    try:
        row = locate_checkbox(raw, section, title)
    except MirrorError as exc:
        raise UsageError("{0} in {1} — nothing was written.".format(exc, path))

    record = {
        "key": new_key(),
        "created_at": now_utc(),
        "method": "POST",
        "path": OPERATIONS_PATH,
        "body": {
            "operations": [
                {
                    "op": "update",
                    "type": "task",
                    "id": task_id,
                    "data": {"done": True, "expected_version": task["version"]},
                }
            ]
        },
        "verb": "done",
        "summary": "done %{0} {1}".format(task_id, title).rstrip(),
        "display": {"label": "done", "title": title, "progress": True, "done": True},
        "stage": STAGE_PENDING,
        "mirror": {
            "initiative_id": initiative_id,
            "file": str(pathlib.Path(path).resolve()),
            "section": section,
            "title": title,
            "line_index": row[0],
            "file_sha256": file_digest(text),
        },
    }
    save_pending(client.config, record)
    code, payload = deliver(client, record, out, args.sleeper)
    if code == EXIT_OK:
        # The one GET happened before the write; the completion it did not see
        # is applied here so the next-leaf line cannot nominate this Task.
        task["done"] = True
        code = finish_mirror(client.config, record, tasks, out)
    return save_response(client, args, payload, out, code)


def resume_mirror(client, record, out):
    """`retry` on a record whose live completion already committed (4.7.4).

    Current state is checked before anything is written: still done, only the
    file is owed; reopened since, this mirror is void — completing it again is
    a new operation, not a resumption of this one. Never re-POSTs.
    """
    mirror = record["mirror"]
    initiative = read_initiative(client, mirror["initiative_id"])
    tasks = initiative.get("tasks") or []
    task = find_task(tasks, mirrored_task_id(record))

    if task is None:
        out.write(
            "Task %{0} is no longer in that Initiative; the mirror was not "
            "updated\n".format(mirrored_task_id(record))
        )
        clear_pending(client.config, record["key"])
        return EXIT_API
    if not task.get("done"):
        out.write(
            "reopened since completion; the mirror was not updated — complete "
            "it again as a new operation\n"
        )
        clear_pending(client.config, record["key"])
        return EXIT_API
    return finish_mirror(client.config, record, tasks, out)


def mirror_after_retry(client, record, out):
    """A resent mirror write that committed still owes its checkbox.

    The tree is read after the POST, so it already carries the completion.
    """
    initiative = read_initiative(client, record["mirror"]["initiative_id"])
    return finish_mirror(client.config, record, initiative.get("tasks") or [], out)


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
    add.add_argument(
        "--numbered",
        action="store_true",
        help="keep a leading positional number the user asked for (1., 2.3, 4), I., A))",
    )
    add.set_defaults(handler=cmd_add)

    done = subparsers.add_parser("done", parents=[saving], help="complete a Task")
    done.add_argument("task", help="Task id or %%<id>")
    done.add_argument("--reopen", action="store_true", help="reopen it instead")
    done.add_argument(
        "--mirror",
        metavar="FILE",
        help="also tick this Task's checkbox in a maintained Markdown mirror",
    )
    done.add_argument(
        "--section",
        metavar="HEADING",
        help="the heading whose checklist holds the checkbox (goes with --mirror)",
    )
    done.add_argument(
        "--initiative",
        metavar="INITIATIVE",
        help="which Initiative the mirror belongs to (default: its first Initiative link)",
    )
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
    retitle.add_argument(
        "--numbered",
        action="store_true",
        help="keep a leading positional number the user asked for (1., 2.3, 4), I., A))",
    )
    retitle.set_defaults(handler=cmd_retitle)

    describe = subparsers.add_parser("describe", parents=[saving], help="set a Task's description")
    describe.add_argument("task", help="Task id or %%<id>")
    describe.add_argument("text", help="the description (1-{0} characters)".format(DESCRIPTION_MAX))
    describe.set_defaults(handler=cmd_describe)

    importing = subparsers.add_parser(
        "import", parents=[saving], help="import a document as a Task tree"
    )
    importing.add_argument("file", help="the source document (UTF-8 text)")
    importing.add_argument(
        "--into", metavar="INITIATIVE", help="import into this existing Initiative (id or URL)"
    )
    importing.add_argument(
        "--under", metavar="TASK", help="import under this Task inside --into (id or %%<id>)"
    )
    importing.add_argument(
        "--as",
        dest="name",
        metavar="NAME",
        help="name the new Initiative (default: the document's first '# ' heading, else the file name)",
    )
    importing.add_argument(
        "--preview", action="store_true", help="report what would be imported; write nothing"
    )
    importing.set_defaults(handler=cmd_import)

    diffing = subparsers.add_parser(
        "diff", parents=[saving], help="compare a document with an existing Initiative"
    )
    diffing.add_argument("file", help="the source document (UTF-8 text)")
    diffing.add_argument("initiative", help="Initiative id or URL")
    diffing.add_argument(
        "--under", metavar="TASK", help="compare against this Task's children (id or %%<id>)"
    )
    diffing.set_defaults(handler=cmd_diff)

    retry = subparsers.add_parser("retry", parents=[saving], help="resend writes whose outcome is unknown")
    retry.add_argument("key", nargs="?", help="one pending key; omit to resend all, oldest first")
    retry.set_defaults(handler=cmd_retry)

    return parser


VERBS = (
    "list, tree, comments, activity, add, done, progress, move, comment, "
    "retitle, describe, import, diff, retry"
)


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
