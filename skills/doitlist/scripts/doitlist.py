#!/usr/bin/env python3
"""Do It List scripted client — read verbs over the /api/v1 HTTP surface.

Standalone by design (m03.04 4.1.4): Python 3 standard library only, no app
container, no repo checkout. Copy this file next to the agent's work and run
it. Configuration comes from the environment the connect panel emits:

    DOITLIST_API_URL     e.g. http://localhost:4000  (hosted: https://...)
    DOITLIST_API_TOKEN   the bearer token minted by the connect panel

Division of labor (m03.04 4.1.2): import parsing stays in the API — this
client only shapes requests, formats responses, and (later) mirrors
completion into local Markdown. See the mirroring seam near the bottom.

Operator-facing output uses labels, titles, and URLs; ids appear only as
`%<id>` beside a title, which is how the companion skill names Tasks.
API requests use ids (m03.04 4.1.5).

Exit codes: 0 ok, 1 API/network error, 2 usage or configuration error.
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

ENV_URL = "DOITLIST_API_URL"
ENV_TOKEN = "DOITLIST_API_TOKEN"

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

    def __init__(self, base_url, token):
        self.base_url = base_url.rstrip("/")
        self.token = token

    @classmethod
    def from_env(cls, env=None):
        env = os.environ if env is None else env
        url = (env.get(ENV_URL) or "").strip()
        token = (env.get(ENV_TOKEN) or "").strip()

        # No fallback service URL: an unset variable is reported, never guessed.
        missing = [name for name, val in ((ENV_URL, url), (ENV_TOKEN, token)) if not val]
        if missing:
            raise ConfigError(
                "{0} is not set. {1}".format(" and ".join(missing), CONNECT_PANEL_HINT)
            )

        validate_base_url(url)
        return cls(url, token)

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
                return response.getcode(), response.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            payload = exc.read().decode("utf-8", "replace") if exc.fp else ""
            return exc.code, payload
        except urllib.error.URLError as exc:
            raise TransportError("could not reach {0}: {1}".format(url, exc.reason))
        except OSError as exc:  # socket timeouts, connection resets
            raise TransportError("could not reach {0}: {1}".format(url, exc))


class Client(object):
    """One request method over one injectable transport."""

    def __init__(self, config, transport=None):
        self.config = config
        self.transport = transport if transport is not None else UrllibTransport()

    def request(self, method, path, body=None, params=None):
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

        status, text = self.transport.send(method, url, headers, data)

        if 300 <= status < 400:
            # Never follow: the next hop could be another origin holding our token.
            raise TransportError(
                "redirect refused ({0} from {1}) — configure {2} with the final "
                "URL.".format(status, url, ENV_URL)
            )

        payload = _decode(text, status)

        if isinstance(payload, dict) and "error" in payload:
            err = payload["error"] or {}
            raise ApiError(
                err.get("status", status),
                err.get("code", "error"),
                err.get("message", "request failed"),
            )
        if status >= 400:
            raise ApiError(status, "http_error", "request failed")
        return payload

    def get(self, path, params=None):
        return self.request("GET", path, params=params)


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
        line += " ({0} children not shown)".format(hidden_children)
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


def cmd_list(client, args, out):
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


def cmd_tree(client, args, out):
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


def cmd_comments(client, args, out):
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


def cmd_activity(client, args, out):
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

    return parser


def main(argv=None, env=None, transport=None, out=None, err=None):
    argv = sys.argv[1:] if argv is None else argv
    out = sys.stdout if out is None else out
    err = sys.stderr if err is None else err

    parser = build_parser()
    args = parser.parse_args(argv)  # argparse exits 2 on an unknown verb
    if not getattr(args, "handler", None):
        parser.print_usage(err)
        err.write("doitlist: a verb is required (list, tree, comments, activity)\n")
        return EXIT_USAGE

    config = None
    try:
        config = Config.from_env(env)
        client = Client(config, transport=transport)
        return args.handler(client, args, out)
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
