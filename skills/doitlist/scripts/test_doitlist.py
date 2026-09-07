#!/usr/bin/env python3
"""Unit tests for the Do It List scripted client (m03.04 4.1.7 / 4.2.5).

Standard library only, no server and no app container: the client's transport
is injectable, so request shapes and rendering are checked against canned JSON
in the shapes `DoItWeb.Api.Serializer` documents. The one exception is the
redirect test, which stands up a real loopback `http.server` to prove the
urllib path refuses a 302 rather than following it.

Run: python3 -m unittest discover -s skills/doitlist/scripts -p 'test_*.py'
"""

import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import doitlist  # noqa: E402


def _json(value):
    return json.dumps(value)


TOKEN = "tok_SECRET_do_not_leak"

#: No test may touch the real ~/.doitlist: every run parks pending writes in a
#: throwaway directory, and the write tests take a fresh one each (4.3.4).
_STATE_ROOT = tempfile.mkdtemp(prefix="doitlist-state-")

ENV = {
    "DOITLIST_API_URL": "http://localhost:4000",
    "DOITLIST_API_TOKEN": TOKEN,
    "DOITLIST_STATE_DIR": _STATE_ROOT,
}


def tearDownModule():
    shutil.rmtree(_STATE_ROOT, ignore_errors=True)


class FakeTransport(object):
    """Canned responses keyed by `METHOD path?query`, plus a request log.

    A route value is a `(status, body)` or `(status, body, headers)` tuple, an
    `Exception` to raise instead of answering (a lost response), or a list of
    those to answer successive calls with — the last entry repeats, which is
    what a retry test needs.
    """

    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def send(self, method, url, headers, body):
        self.calls.append({"method": method, "url": url, "headers": headers, "body": body})
        path = url.split("://", 1)[-1].split("/", 1)[-1]
        key = "{0} /{1}".format(method, path)
        if key not in self.routes:
            raise AssertionError("unexpected request {0}; know {1}".format(key, sorted(self.routes)))
        reply = self.routes[key]
        if isinstance(reply, list):
            reply = reply.pop(0) if len(reply) > 1 else reply[0]
        if isinstance(reply, Exception):
            raise reply
        return reply


def node(id, title, index="", progress=0, done=False, leaf=True, children=None):
    return {
        "id": id,
        "title": title,
        "index": index,
        "position": 0,
        "parent_id": 100,
        "depth": 0,
        "progress": progress,
        "manual_progress": progress,
        "status": "done" if done else "open",
        "done": done,
        "leaf": leaf,
        "priority": "normal",
        "assignee_id": None,
        "co_assignee_ids": [],
        "comment_count": 0,
        "cross_references": [],
        "referenced_by": [],
        "version": 1,
        "children": children or [],
    }


#: 1 (branch, two children incl. a done leaf) / 2 (branch -> branch -> leaf).
TREE = {
    "id": 12,
    "name": "Q3 Launch",
    "url": "https://doitlist.app/initiatives/12",
    "progress": 42,
    "index_style": "numerical",
    "root_task_id": 100,
    "version": 3,
    "tasks": [
        node(
            101,
            "Build the API",
            index="1",
            progress=50,
            leaf=False,
            children=[
                node(111, "Write the controller", index="1.1", progress=100, done=True),
                node(112, "Write the tests", index="1.2", progress=0),
            ],
        ),
        node(
            102,
            "Ship the SDK",
            index="2",
            progress=25,
            leaf=False,
            children=[
                node(
                    121,
                    "Package it",
                    index="2.1",
                    progress=25,
                    leaf=False,
                    children=[node(131, "Pick a name", index="2.1.1", progress=25)],
                )
            ],
        ),
    ],
}


def run(argv, routes, env=None, sleeper=None):
    """Run main() with a fake transport; returns (code, stdout, stderr, transport)."""
    transport = FakeTransport(routes)
    out, err = io.StringIO(), io.StringIO()
    code = doitlist.main(
        argv,
        env=ENV if env is None else env,
        transport=transport,
        out=out,
        err=err,
        sleeper=sleeper,
    )
    return code, out.getvalue(), err.getvalue(), transport


# --------------------------------------------------------------------------
# 4.1.7 — configuration, URL validation, redirects, token redaction
# --------------------------------------------------------------------------


class ConfigTest(unittest.TestCase):
    def test_missing_both_variables_names_them_and_the_panel(self):
        code, out, err, _ = run(["list"], {}, env={})
        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        self.assertIn("DOITLIST_API_URL", err)
        self.assertIn("DOITLIST_API_TOKEN", err)
        self.assertIn("connect panel", err)

    def test_blank_variables_count_as_missing(self):
        code, _, err, _ = run(["list"], {}, env={"DOITLIST_API_URL": "  ", "DOITLIST_API_TOKEN": ""})
        self.assertEqual(code, 2)
        self.assertIn("DOITLIST_API_URL", err)

    def test_missing_token_alone_is_reported(self):
        code, _, err, _ = run(["list"], {}, env={"DOITLIST_API_URL": "https://doitlist.app"})
        self.assertEqual(code, 2)
        self.assertIn("DOITLIST_API_TOKEN", err)
        self.assertNotIn("DOITLIST_API_URL is not set", err)

    def test_no_fallback_service_url_is_ever_used(self):
        # An empty environment must never fall back to a default host.
        with self.assertRaises(doitlist.ConfigError):
            doitlist.Config.from_env({})
        self.assertNotIn("doitlist.app", doitlist.CONNECT_PANEL_HINT)

    def test_https_is_accepted(self):
        cfg = doitlist.Config.from_env(
            {"DOITLIST_API_URL": "https://doitlist.app/", "DOITLIST_API_TOKEN": TOKEN}
        )
        self.assertEqual(cfg.base_url, "https://doitlist.app")

    def test_plain_http_allowed_on_loopback_only(self):
        for url in ("http://localhost:4000", "http://127.0.0.1:4000", "http://[::1]:4000"):
            self.assertEqual(doitlist.validate_base_url(url), url)

    def test_plain_http_refused_off_loopback(self):
        code, _, err, _ = run(
            ["list"], {}, env={"DOITLIST_API_URL": "http://doitlist.app", "DOITLIST_API_TOKEN": TOKEN}
        )
        self.assertEqual(code, 2)
        self.assertIn("https", err)
        self.assertIn("loopback", err)

    def test_non_url_configuration_is_refused(self):
        for bad in ("doitlist.app", "ftp://doitlist.app", "/api/v1"):
            with self.assertRaises(doitlist.ConfigError):
                doitlist.validate_base_url(bad)


class RedactionTest(unittest.TestCase):
    def test_token_never_appears_on_an_api_error_path(self):
        routes = {
            "GET /api/v1/initiatives": (
                403,
                '{"error":{"status":403,"code":"forbidden","message":"token '
                + TOKEN
                + ' is not allowed"}}',
            )
        }
        code, out, err, _ = run(["list"], routes)
        self.assertEqual(code, 1)
        self.assertNotIn(TOKEN, out)
        self.assertNotIn(TOKEN, err)
        self.assertIn("***", err)
        self.assertIn("forbidden", err)

    def test_token_never_appears_on_a_transport_error_path(self):
        class Boom(object):
            def send(self, *_args):
                raise doitlist.TransportError("could not reach host with " + TOKEN)

        out, err = io.StringIO(), io.StringIO()
        code = doitlist.main(["list"], env=ENV, transport=Boom(), out=out, err=err)
        self.assertEqual(code, 1)
        self.assertNotIn(TOKEN, out.getvalue() + err.getvalue())

    def test_token_travels_only_in_the_authorization_header(self):
        routes = {"GET /api/v1/initiatives": (200, '{"data":[]}')}
        code, out, err, transport = run(["list"], routes)
        self.assertEqual(code, 0)
        call = transport.calls[0]
        self.assertEqual(call["headers"]["Authorization"], "Bearer " + TOKEN)
        self.assertNotIn(TOKEN, call["url"])
        self.assertNotIn(TOKEN, out + err)


class _RedirectHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(302)
        self.send_header("Location", "https://evil.example.com/api/v1/initiatives")
        self.end_headers()

    def log_message(self, *_args):  # keep the test output clean
        pass


class RedirectTest(unittest.TestCase):
    """A real loopback server, so the urllib transport itself is exercised."""

    def setUp(self):
        self.server = HTTPServer(("127.0.0.1", 0), _RedirectHandler)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.daemon = True
        self.thread.start()
        self.base = "http://127.0.0.1:{0}".format(self.server.server_port)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def test_redirect_is_refused_not_followed(self):
        config = doitlist.Config(self.base, TOKEN)
        client = doitlist.Client(config)
        with self.assertRaises(doitlist.TransportError) as caught:
            client.get("/api/v1/initiatives")
        self.assertIn("redirect refused", str(caught.exception))
        self.assertNotIn("evil.example.com", str(caught.exception))

    def test_redirect_exits_one_without_leaking_the_token(self):
        out, err = io.StringIO(), io.StringIO()
        code = doitlist.main(
            ["list"],
            env={"DOITLIST_API_URL": self.base, "DOITLIST_API_TOKEN": TOKEN},
            out=out,
            err=err,
        )
        self.assertEqual(code, 1)
        self.assertIn("redirect refused", err.getvalue())
        self.assertNotIn(TOKEN, out.getvalue() + err.getvalue())


# --------------------------------------------------------------------------
# Argument parsing and request shapes
# --------------------------------------------------------------------------


class ReferenceTest(unittest.TestCase):
    def test_initiative_accepts_id_and_url(self):
        self.assertEqual(doitlist.parse_initiative_ref("12"), 12)
        self.assertEqual(doitlist.parse_initiative_ref("https://doitlist.app/initiatives/12"), 12)
        self.assertEqual(doitlist.parse_initiative_ref("http://localhost:4000/initiatives/7"), 7)

    def test_initiative_rejects_a_name(self):
        with self.assertRaises(doitlist.UsageError):
            doitlist.parse_initiative_ref("Q3 Launch")

    def test_task_accepts_id_and_percent_form(self):
        self.assertEqual(doitlist.parse_task_ref("101"), 101)
        self.assertEqual(doitlist.parse_task_ref("%101"), 101)

    def test_task_rejects_a_label(self):
        with self.assertRaises(doitlist.UsageError):
            doitlist.parse_task_ref("%1.2")

    def test_unknown_verb_exits_two(self):
        with contextlib.redirect_stderr(io.StringIO()) as usage:
            with self.assertRaises(SystemExit) as caught:
                doitlist.main(["frobnicate"], env=ENV, out=io.StringIO(), err=io.StringIO())
        self.assertEqual(caught.exception.code, 2)
        self.assertIn("usage:", usage.getvalue())

    def test_no_verb_exits_two(self):
        out, err = io.StringIO(), io.StringIO()
        self.assertEqual(doitlist.main([], env=ENV, out=out, err=err), 2)
        self.assertIn("verb is required", err.getvalue())
        for verb in ("add", "done", "progress", "move", "comment", "retitle", "describe", "retry"):
            self.assertIn(verb, err.getvalue())

    def test_every_verb_has_help(self):
        for verb in (
            "list",
            "tree",
            "comments",
            "activity",
            "add",
            "done",
            "progress",
            "move",
            "comment",
            "retitle",
            "describe",
            "retry",
        ):
            with contextlib.redirect_stdout(io.StringIO()) as help_text:
                with self.assertRaises(SystemExit) as caught:
                    doitlist.build_parser().parse_args([verb, "--help"])
            self.assertEqual(caught.exception.code, 0)
            self.assertIn("usage:", help_text.getvalue())


class RequestShapeTest(unittest.TestCase):
    def test_tree_reads_the_initiative_by_id(self):
        routes = {"GET /api/v1/initiatives/12": (200, _json(TREE))}
        code, _, err, transport = run(["tree", "https://doitlist.app/initiatives/12"], routes)
        self.assertEqual(code, 0, err)
        self.assertEqual(transport.calls[0]["method"], "GET")
        self.assertTrue(transport.calls[0]["url"].endswith("/api/v1/initiatives/12"))
        self.assertIsNone(transport.calls[0]["body"])

    def test_comments_resolves_the_task_to_its_initiative(self):
        routes = {
            "GET /api/v1/tasks/101": (200, '{"data":{"id":101,"initiative_id":12,"version":5}}'),
            "GET /api/v1/initiatives/12/tasks/101/comments": (200, '{"data":[]}'),
        }
        code, out, err, transport = run(["comments", "%101"], routes)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(transport.calls), 2)
        self.assertTrue(transport.calls[1]["url"].endswith("/api/v1/initiatives/12/tasks/101/comments"))
        self.assertIn("no comments", out)

    def test_activity_sends_limit_and_task_filters_as_query_params(self):
        routes = {
            "GET /api/v1/initiatives/12/activity?limit=5&task_id=101": (
                200,
                '{"data":[],"meta":{"limit":5,"offset":0,"has_more":false}}',
            )
        }
        code, out, err, _ = run(["activity", "12", "--task", "%101", "--limit", "5"], routes)
        self.assertEqual(code, 0, err)
        self.assertIn("no activity", out)

    def test_bad_depth_is_a_usage_error(self):
        code, _, err, _ = run(["tree", "12", "--depth", "0"], {})
        self.assertEqual(code, 2)
        self.assertIn("--depth", err)


# --------------------------------------------------------------------------
# 4.2 — read verbs
# --------------------------------------------------------------------------


class ListTest(unittest.TestCase):
    def test_prints_name_url_and_progress(self):
        routes = {
            "GET /api/v1/initiatives": (
                200,
                _json(
                    {
                        "data": [
                            {"id": 12, "name": "Q3 Launch", "url": "https://doitlist.app/initiatives/12", "progress": 42},
                            {"id": 13, "name": "Chores", "url": "https://doitlist.app/initiatives/13", "progress": 0},
                        ]
                    }
                ),
            )
        }
        code, out, err, _ = run(["list"], routes)
        self.assertEqual(code, 0, err)
        self.assertEqual(
            out.splitlines(),
            [
                "Q3 Launch  https://doitlist.app/initiatives/12  42%",
                "Chores  https://doitlist.app/initiatives/13  0%",
            ],
        )

    def test_empty_list_says_so(self):
        code, out, _, _ = run(["list"], {"GET /api/v1/initiatives": (200, '{"data":[]}')})
        self.assertEqual(code, 0)
        self.assertEqual(out, "no Initiatives\n")


class TreeTest(unittest.TestCase):
    def setUp(self):
        self.routes = {"GET /api/v1/initiatives/12": (200, _json(TREE))}

    def test_full_tree_header_scope_and_outline(self):
        code, out, err, _ = run(["tree", "12"], self.routes)
        self.assertEqual(code, 0, err)
        self.assertEqual(
            out.splitlines(),
            [
                "Initiative: Q3 Launch  https://doitlist.app/initiatives/12  42%",
                "Scope: whole tree",
                "Depth: all",
                "1 Build the API  %101  50%  [ ]  branch",
                "  1.1 Write the controller  %111  100%  [x]  leaf",
                "  1.2 Write the tests  %112  0%  [ ]  leaf",
                "2 Ship the SDK  %102  25%  [ ]  branch",
                "  2.1 Package it  %121  25%  [ ]  branch",
                "    2.1.1 Pick a name  %131  25%  [ ]  leaf",
            ],
        )

    def test_completed_tasks_are_always_visible(self):
        code, out, _, _ = run(["tree", "12"], self.routes)
        self.assertEqual(code, 0)
        self.assertIn("[x]  leaf", out)
        self.assertIn("Write the controller", out)
        # There is no open-only filter to add (shared-work standard).
        self.assertNotIn("--open", doitlist.build_parser().format_help())

    def test_under_scopes_to_the_subtree_and_names_it(self):
        code, out, err, _ = run(["tree", "12", "--under", "%102"], self.routes)
        self.assertEqual(code, 0, err)
        self.assertEqual(
            out.splitlines(),
            [
                "Initiative: Q3 Launch  https://doitlist.app/initiatives/12  42%",
                "Scope: under %102 Ship the SDK",
                "Depth: all",
                "2 Ship the SDK  %102  25%  [ ]  branch",
                "  2.1 Package it  %121  25%  [ ]  branch",
                "    2.1.1 Pick a name  %131  25%  [ ]  leaf",
            ],
        )
        self.assertNotIn("Build the API", out)

    def test_depth_is_relative_to_the_scope_root(self):
        code, out, err, _ = run(["tree", "12", "--under", "%102", "--depth", "1"], self.routes)
        self.assertEqual(code, 0, err)
        self.assertEqual(
            out.splitlines(),
            [
                "Initiative: Q3 Launch  https://doitlist.app/initiatives/12  42%",
                "Scope: under %102 Ship the SDK",
                "Depth: 1",
                "2 Ship the SDK  %102  25%  [ ]  branch",
                "  2.1 Package it  %121  25%  [ ]  branch (1 child not shown)",
            ],
        )

    def test_depth_one_on_the_whole_tree_shows_top_level_only(self):
        code, out, err, _ = run(["tree", "12", "--depth", "1"], self.routes)
        self.assertEqual(code, 0, err)
        self.assertEqual(
            out.splitlines()[3:],
            [
                "1 Build the API  %101  50%  [ ]  branch (2 children not shown)",
                "2 Ship the SDK  %102  25%  [ ]  branch (1 child not shown)",
            ],
        )

    def test_cut_rows_keep_api_progress_and_branch_status(self):
        """Progress and leaf/branch come from the API, not from visible rows."""
        _, full, _, _ = run(["tree", "12"], self.routes)
        _, cut, _, _ = run(["tree", "12", "--depth", "1"], self.routes)
        for line in cut.splitlines()[3:]:
            head = line.split(" (")[0]
            self.assertIn(head, full)  # identical progress, mark, and branch token
        row = [line for line in cut.splitlines() if "%101" in line][0]
        self.assertIn("50%", row)  # not 0% derived from a hidden done child
        self.assertIn("branch", row)

    def test_leaf_at_the_cutoff_carries_no_hidden_count(self):
        code, out, _, _ = run(["tree", "12", "--under", "%101", "--depth", "1"], self.routes)
        self.assertEqual(code, 0)
        self.assertNotIn("not shown", out)
        self.assertIn("  1.1 Write the controller  %111  100%  [x]  leaf", out)

    def test_under_a_task_outside_the_initiative_is_a_usage_error(self):
        code, _, err, _ = run(["tree", "12", "--under", "%999"], self.routes)
        self.assertEqual(code, 2)
        self.assertIn("%999", err)

    def test_index_token_is_omitted_under_the_none_style(self):
        tree = {"id": 14, "name": "Loose", "url": "u", "progress": 0, "tasks": [node(200, "Just a Task")]}
        code, out, _, _ = run(["tree", "14"], {"GET /api/v1/initiatives/14": (200, _json(tree))})
        self.assertEqual(code, 0)
        self.assertIn("Just a Task  %200  0%  [ ]  leaf", out)
        self.assertNotIn("  Just a Task", out)

    def test_empty_initiative_says_so(self):
        tree = {"id": 15, "name": "Empty", "url": "u", "progress": 0, "tasks": []}
        code, out, _, _ = run(["tree", "15"], {"GET /api/v1/initiatives/15": (200, _json(tree))})
        self.assertEqual(code, 0)
        self.assertIn("no Tasks", out)


class CommentsTest(unittest.TestCase):
    def _routes(self, comments):
        return {
            "GET /api/v1/tasks/101": (200, '{"data":{"id":101,"initiative_id":12,"version":5}}'),
            "GET /api/v1/initiatives/12/tasks/101/comments": (200, _json({"data": comments})),
        }

    def test_prints_author_time_and_body_without_envelope_fields(self):
        routes = self._routes(
            [
                {
                    "id": 33,
                    "task_id": 101,
                    "body": "looks good",
                    "author_id": 7,
                    "author_name": "Ada Lovelace",
                    "deleted": False,
                    "edited": True,
                    "inserted_at": "2026-06-26T21:16:46Z",
                    "updated_at": "2026-06-26T21:20:01Z",
                }
            ]
        )
        code, out, err, _ = run(["comments", "101"], routes)
        self.assertEqual(code, 0, err)
        self.assertEqual(out.splitlines(), ["Ada Lovelace  2026-06-26 21:16  looks good"])
        for envelope in ("task_id", "author_id", "updated_at", "edited", "deleted"):
            self.assertNotIn(envelope, out)

    def test_tombstones_render_as_deleted(self):
        routes = self._routes(
            [
                {
                    "id": 34,
                    "body": None,
                    "author_name": "Bob",
                    "deleted": True,
                    "inserted_at": "2026-06-26T21:30:00Z",
                }
            ]
        )
        code, out, _, _ = run(["comments", "%101"], routes)
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), ["Bob  2026-06-26 21:30  [deleted]"])


class ActivityTest(unittest.TestCase):
    def test_prints_time_actor_kind_and_compact_data(self):
        routes = {
            "GET /api/v1/initiatives/12/activity": (
                200,
                _json(
                    {
                        "data": [
                            {
                                "id": 555,
                                "kind": "progress_changed",
                                "task_id": 101,
                                "user_id": 7,
                                "user_name": "Ada Lovelace",
                                "actor_kind": "browser",
                                "api_token_id": None,
                                "api_token_label": None,
                                "data": {"from": 0, "to": 50},
                                "inserted_at": "2026-06-26T21:16:46Z",
                            },
                            {
                                "id": 556,
                                "kind": "created",
                                "task_id": 112,
                                "user_id": 7,
                                "user_name": "Ada Lovelace",
                                "actor_kind": "api_token",
                                "api_token_id": 3,
                                "api_token_label": "planning agent",
                                "data": {"title": "Write the tests"},
                                "inserted_at": "2026-06-26T22:00:00Z",
                            },
                        ],
                        "meta": {"limit": 50, "offset": 0, "has_more": True},
                    }
                ),
            )
        }
        code, out, err, _ = run(["activity", "12"], routes)
        self.assertEqual(code, 0, err)
        self.assertEqual(
            out.splitlines(),
            [
                "2026-06-26 21:16  Ada Lovelace  progress_changed  from=0 to=50",
                "2026-06-26 22:00  planning agent  created  title=Write the tests",
                "more available",
            ],
        )
        for envelope in ("api_token_id", "user_id", "offset"):
            self.assertNotIn(envelope, out)

    def test_no_more_available_line_when_the_page_is_the_last(self):
        routes = {
            "GET /api/v1/initiatives/12/activity": (
                200,
                _json({"data": [], "meta": {"limit": 50, "offset": 0, "has_more": False}}),
            )
        }
        code, out, _, _ = run(["activity", "12"], routes)
        self.assertEqual(code, 0)
        self.assertNotIn("more available", out)


class FormattingTest(unittest.TestCase):
    def test_long_activity_values_are_truncated_on_one_line(self):
        summary = doitlist.summarize_data({"title": "x" * 100})
        self.assertTrue(summary.endswith("..."))
        self.assertNotIn("\n", summary)

    def test_unparseable_timestamps_pass_through(self):
        self.assertEqual(doitlist.fmt_time("whenever"), "whenever")
        self.assertEqual(doitlist.fmt_time(None), "")


# --------------------------------------------------------------------------
# 4.3 / 4.8 — write verbs, retry state, and compact results
# --------------------------------------------------------------------------


def task_data(id=101, title="Write the controller", progress=100, done=True, parent_id=100, version=8):
    """A `task_result` record in the shape the operations endpoint returns."""
    return {
        "id": id,
        "type": "task",
        "title": title,
        "parent_id": parent_id,
        "status": "done" if done else "open",
        "done": done,
        "progress": progress,
        "manual_progress": progress,
        "priority": "normal",
        "assignee_id": None,
        "version": version,
    }


def read_task(id=101, title="Write the controller", version=7, parent_id=100):
    return (
        200,
        _json(
            {
                "data": {
                    "id": id,
                    "title": title,
                    "initiative_id": 12,
                    "parent_id": parent_id,
                    "version": version,
                    "status": "open",
                    "done": False,
                    "progress": 0,
                }
            }
        ),
    )


def ops_ok(data, lid=None):
    result = {"index": 0, "status": "ok", "data": data}
    if lid:
        result["lid"] = lid
    return (200, _json({"results": [result]}))


def ops_error(status, code, message, pointer=None, current=None):
    error = {"code": code, "message": message}
    if pointer:
        error["pointer"] = pointer
    if current:
        error["current"] = current
    return (
        status,
        _json(
            {
                "error": {"status": status, "code": code, "message": message},
                "results": [{"index": 0, "status": "error", "error": error}],
            }
        ),
    )


class WriteCase(unittest.TestCase):
    """Every write test parks its pending requests in its own temp directory."""

    def setUp(self):
        self.state = tempfile.mkdtemp(prefix="doitlist-write-")
        self.addCleanup(shutil.rmtree, self.state, True)
        self.env = dict(ENV, DOITLIST_STATE_DIR=self.state)

    def cli(self, argv, routes, sleeper=None):
        return run(argv, routes, env=self.env, sleeper=sleeper)

    def pending_paths(self):
        directory = os.path.join(self.state, "pending")
        if not os.path.isdir(directory):
            return []
        return sorted(
            os.path.join(directory, name)
            for name in os.listdir(directory)
            if name.endswith(".json")
        )

    def pending_records(self):
        records = []
        for path in self.pending_paths():
            with open(path, encoding="utf-8") as handle:
                records.append(json.load(handle))
        return records

    def posted(self, transport):
        """The decoded body and headers of every POST the run made."""
        return [
            (json.loads(call["body"].decode("utf-8")), call["headers"])
            for call in transport.calls
            if call["method"] == "POST"
        ]


class WriteRequestShapeTest(WriteCase):
    """4.3.1 / 4.3.2 — one op per command, versioned by the preceding read."""

    def test_add_under_a_task_sends_parent_id(self):
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_ok(
                task_data(id=140, title="New title", parent_id=101, progress=0, done=False), lid="t1"
            ),
        }
        code, out, err, transport = self.cli(["add", "%101", "New title"], routes)
        self.assertEqual(code, 0, out + err)
        self.assertEqual([call["method"] for call in transport.calls], ["GET", "POST"])
        body, headers = self.posted(transport)[0]
        self.assertEqual(
            body,
            {
                "operations": [
                    {
                        "op": "add",
                        "type": "task",
                        "lid": "t1",
                        "data": {"parent_id": 101, "title": "New title"},
                    }
                ]
            },
        )
        self.assertEqual(out, "added  %140  New title  under %101\n")
        uuid.UUID(headers["Idempotency-Key"])  # raises if it is not a UUID

    def test_add_at_the_top_level_sends_initiative_id(self):
        routes = {
            "GET /api/v1/initiatives/12": (200, _json(TREE)),
            "POST /api/v1/operations": ops_ok(
                task_data(id=141, title="New title", parent_id=100, progress=0, done=False)
            ),
        }
        code, out, err, transport = self.cli(
            ["add", "https://doitlist.app/initiatives/12", "New title"], routes
        )
        self.assertEqual(code, 0, out + err)
        body, _ = self.posted(transport)[0]
        self.assertEqual(
            body["operations"][0]["data"], {"initiative_id": 12, "title": "New title"}
        )
        self.assertEqual(out, "added  %141  New title  top level of Q3 Launch\n")

    def test_done_carries_the_expected_version_from_the_read(self):
        routes = {
            "GET /api/v1/tasks/101": read_task(version=7),
            "POST /api/v1/operations": ops_ok(task_data(version=8)),
        }
        code, out, err, transport = self.cli(["done", "%101"], routes)
        self.assertEqual(code, 0, out + err)
        body, _ = self.posted(transport)[0]
        self.assertEqual(
            body["operations"][0],
            {
                "op": "update",
                "type": "task",
                "id": 101,
                "data": {"done": True, "expected_version": 7},
            },
        )
        self.assertEqual(out, "done  %101  Write the controller  100%  [x]\n")

    def test_reopen_sends_done_false(self):
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_ok(task_data(progress=40, done=False)),
        }
        code, out, err, transport = self.cli(["done", "101", "--reopen"], routes)
        self.assertEqual(code, 0, out + err)
        body, _ = self.posted(transport)[0]
        self.assertEqual(body["operations"][0]["data"], {"done": False, "expected_version": 7})
        self.assertEqual(out, "reopened  %101  Write the controller  40%  [ ]\n")

    def test_progress_sends_manual_progress(self):
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_ok(task_data(progress=40, done=False)),
        }
        code, out, err, transport = self.cli(["progress", "%101", "40"], routes)
        self.assertEqual(code, 0, out + err)
        body, _ = self.posted(transport)[0]
        self.assertEqual(
            body["operations"][0]["data"], {"manual_progress": 40, "expected_version": 7}
        )
        self.assertEqual(out, "progress  %101  Write the controller  40%\n")

    def test_move_under_a_task_sends_parent_and_position(self):
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_ok(
                task_data(parent_id=105, progress=0, done=False)
            ),
        }
        code, out, err, transport = self.cli(["move", "%101", "%105", "2"], routes)
        self.assertEqual(code, 0, out + err)
        body, _ = self.posted(transport)[0]
        self.assertEqual(
            body["operations"][0]["data"],
            {"parent_id": 105, "position": 2, "expected_version": 7},
        )
        self.assertEqual(out, "moved  %101  Write the controller  under %105 at 2\n")

    def test_move_to_the_top_level_uses_the_initiative_root_task(self):
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "GET /api/v1/initiatives/12": (200, _json(TREE)),
            "POST /api/v1/operations": ops_ok(task_data(parent_id=100, progress=0, done=False)),
        }
        code, out, err, transport = self.cli(["move", "%101", "12"], routes)
        self.assertEqual(code, 0, out + err)
        body, _ = self.posted(transport)[0]
        self.assertEqual(
            body["operations"][0]["data"], {"parent_id": 100, "expected_version": 7}
        )
        self.assertEqual(out, "moved  %101  Write the controller  top level of Q3 Launch\n")

    def test_comment_adds_a_comment_op_without_a_version(self):
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_ok(
                {
                    "id": 33,
                    "type": "comment",
                    "task_id": 101,
                    "body": "decided to ship it",
                    "author_id": 7,
                    "deleted": False,
                },
                lid="c1",
            ),
        }
        code, out, err, transport = self.cli(["comment", "%101", "decided to ship it"], routes)
        self.assertEqual(code, 0, out + err)
        body, _ = self.posted(transport)[0]
        self.assertEqual(
            body["operations"][0],
            {
                "op": "add",
                "type": "comment",
                "lid": "c1",
                "data": {"task_id": 101, "body": "decided to ship it"},
            },
        )
        self.assertEqual(out, "commented  %101  Write the controller\n")

    def test_retitle_and_describe_each_send_one_concern(self):
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_ok(task_data(title="Write the HTTP controller")),
        }
        code, out, err, transport = self.cli(["retitle", "%101", "Write the HTTP controller"], routes)
        self.assertEqual(code, 0, out + err)
        body, _ = self.posted(transport)[0]
        self.assertEqual(
            body["operations"][0]["data"],
            {"title": "Write the HTTP controller", "expected_version": 7},
        )
        self.assertEqual(out, "retitled  %101  Write the HTTP controller\n")

        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_ok(task_data(progress=0, done=False)),
        }
        code, out, err, transport = self.cli(["describe", "%101", "run mix precommit first"], routes)
        self.assertEqual(code, 0, out + err)
        body, _ = self.posted(transport)[0]
        self.assertEqual(
            body["operations"][0]["data"],
            {"description": "run mix precommit first", "expected_version": 7},
        )
        self.assertEqual(out, "described  %101  Write the controller\n")

    def test_a_committed_write_leaves_nothing_pending(self):
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_ok(task_data()),
        }
        code, _, _, _ = self.cli(["done", "%101"], routes)
        self.assertEqual(code, 0)
        self.assertEqual(self.pending_paths(), [])


class WriteValidationTest(WriteCase):
    """4.3.3 — every rule fails before a single request, and rewrites nothing."""

    def assert_refused(self, argv, needle):
        code, out, err, transport = self.cli(argv, {})
        self.assertEqual(code, 2, out + err)
        self.assertEqual(transport.calls, [], "a rejected command must not reach the API")
        self.assertEqual(self.pending_paths(), [])
        self.assertIn(needle, err)

    def test_empty_content_is_refused(self):
        self.assert_refused(["add", "%101", "   "], "title cannot be empty")
        self.assert_refused(["comment", "%101", ""], "comment body cannot be empty")
        self.assert_refused(["describe", "%101", " \n "], "description cannot be empty")

    def test_oversized_content_is_named_never_truncated(self):
        code, out, err, transport = self.cli(["retitle", "%101", "x" * 201], {})
        self.assertEqual(code, 2)
        self.assertEqual(transport.calls, [])
        self.assertIn("201 characters", err)
        self.assertIn("200", err)
        self.assertIn("never truncates", err)
        self.assert_refused(["comment", "%101", "y" * 4001], "4001 characters")
        self.assert_refused(["describe", "%101", "z" * 8001], "8001 characters")

    def test_progress_must_be_a_whole_number_in_range(self):
        self.assert_refused(["progress", "%101", "half"], "whole number")
        self.assert_refused(["progress", "%101", "40.5"], "whole number")
        self.assert_refused(["progress", "%101", "101"], "between 0 and 100")
        self.assert_refused(["progress", "%101", "-1"], "between 0 and 100")

    def test_position_must_not_be_negative(self):
        self.assert_refused(["move", "%101", "%105", "-1"], "position must be 0 or more")

    def test_bad_references_are_refused(self):
        self.assert_refused(["done", "%1.2"], "is not a Task")
        self.assert_refused(["add", "Q3 Launch", "New title"], "is not a parent")
        self.assert_refused(["move", "%101", "somewhere"], "is not a parent")


class VersionConflictTest(WriteCase):
    """4.3.5 — hand back the current record; never resubmit with its version."""

    def _routes(self):
        current = task_data(id=101, title="Renamed in the browser", progress=50, done=False, version=9)
        return {
            "GET /api/v1/tasks/101": read_task(version=7),
            "POST /api/v1/operations": ops_error(
                409,
                "conflict",
                "Task 101 has version 9, not 7.",
                current=current,
            ),
        }

    def test_conflict_prints_the_current_record_and_stops(self):
        code, out, err, transport = self.cli(["done", "%101"], self._routes())
        self.assertEqual(code, 1)
        self.assertEqual(
            out.splitlines(),
            [
                "conflict: done %101 Write the controller",
                "  %101  Renamed in the browser  50%  [ ]  version 9",
                "  nothing was applied — re-read, then decide.",
            ],
        )
        self.assertEqual(len(self.posted(transport)), 1, "a conflict must not be resubmitted")

    def test_conflict_is_a_settled_outcome_so_nothing_stays_pending(self):
        code, _, _, _ = self.cli(["done", "%101"], self._routes())
        self.assertEqual(code, 1)
        self.assertEqual(self.pending_paths(), [])


class LostResponseTest(WriteCase):
    """4.3.4 — an unknown outcome parks the request and claims nothing."""

    def _routes(self, post):
        return {"GET /api/v1/tasks/101": read_task(), "POST /api/v1/operations": post}

    def test_a_lost_response_parks_the_key_and_body_without_the_token(self):
        routes = self._routes(doitlist.TransportError("could not reach the host: timed out"))
        code, out, err, _ = self.cli(["done", "%101"], routes)
        self.assertEqual(code, 1)
        self.assertIn("outcome unknown: done %101 Write the controller", out)
        self.assertNotIn("done  %101", out)  # never a success line

        records = self.pending_records()
        self.assertEqual(len(records), 1)
        record = records[0]
        uuid.UUID(record["key"])
        self.assertIn("doitlist.py retry {0}".format(record["key"]), out)
        self.assertEqual(
            record["body"],
            {
                "operations": [
                    {
                        "op": "update",
                        "type": "task",
                        "id": 101,
                        "data": {"done": True, "expected_version": 7},
                    }
                ]
            },
        )
        with open(self.pending_paths()[0], encoding="utf-8") as handle:
            raw = handle.read()
        self.assertNotIn(TOKEN, raw)
        self.assertNotIn("Authorization", raw)
        self.assertNotIn("localhost", raw)

    def test_a_server_error_is_also_an_unknown_outcome(self):
        routes = self._routes((500, '{"error":{"status":500,"code":"server_error","message":"boom"}}'))
        code, out, _, _ = self.cli(["done", "%101"], routes)
        self.assertEqual(code, 1)
        self.assertIn("outcome unknown", out)
        self.assertEqual(len(self.pending_records()), 1)

    def test_a_non_json_body_is_an_unknown_outcome(self):
        routes = self._routes((200, "<html>gateway</html>"))
        code, out, _, _ = self.cli(["done", "%101"], routes)
        self.assertEqual(code, 1)
        self.assertIn("outcome unknown", out)
        self.assertEqual(len(self.pending_records()), 1)


class RetryIdentityTest(WriteCase):
    """4.3.4 — a retry is the same key and the same body, or it is not a retry."""

    def _lose_one(self):
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": doitlist.TransportError("could not reach the host"),
        }
        code, _, _, transport = self.cli(["done", "%101"], routes)
        self.assertEqual(code, 1)
        record = self.pending_records()[0]
        first = self.posted(transport)[0]
        return record, first

    def test_retry_resends_the_identical_key_and_body_then_clears_it(self):
        record, (first_body, first_headers) = self._lose_one()
        routes = {"POST /api/v1/operations": ops_ok(task_data())}
        code, out, err, transport = self.cli(["retry"], routes)
        self.assertEqual(code, 0, out + err)

        again_body, again_headers = self.posted(transport)[0]
        self.assertEqual(again_body, first_body)
        self.assertEqual(again_headers["Idempotency-Key"], first_headers["Idempotency-Key"])
        self.assertEqual(again_headers["Idempotency-Key"], record["key"])
        self.assertEqual(self.pending_paths(), [])
        self.assertEqual(
            out.splitlines(),
            [
                "retrying: done %101 Write the controller",
                "done  %101  Write the controller  100%  [x]",
            ],
        )

    def test_retry_reads_nothing_and_never_rebuilds_the_request(self):
        self._lose_one()
        # No GET route: a retry that re-read the Task would fail here.
        code, out, err, transport = self.cli(["retry"], {"POST /api/v1/operations": ops_ok(task_data())})
        self.assertEqual(code, 0, out + err)
        self.assertEqual([call["method"] for call in transport.calls], ["POST"])

    def test_retry_by_key_targets_one_parked_request(self):
        record, _ = self._lose_one()
        code, out, err, _ = self.cli(["retry", record["key"]], {"POST /api/v1/operations": ops_ok(task_data())})
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.pending_paths(), [])

    def test_retry_with_an_unknown_key_is_a_usage_error(self):
        code, _, err, transport = self.cli(["retry", "not-a-parked-key"], {})
        self.assertEqual(code, 2)
        self.assertEqual(transport.calls, [])
        self.assertIn("no pending request with key", err)

    def test_retry_with_nothing_parked_says_so(self):
        code, out, err, transport = self.cli(["retry"], {})
        self.assertEqual(code, 0, err)
        self.assertEqual(out, "no pending requests\n")
        self.assertEqual(transport.calls, [])

    def test_a_still_unknown_retry_stays_parked(self):
        record, _ = self._lose_one()
        routes = {"POST /api/v1/operations": doitlist.TransportError("still unreachable")}
        code, out, _, _ = self.cli(["retry"], routes)
        self.assertEqual(code, 1)
        self.assertIn("outcome unknown", out)
        self.assertEqual([r["key"] for r in self.pending_records()], [record["key"]])


class RateLimitTest(WriteCase):
    """4.3.4 — honor `Retry-After`; a long wait is reported, never slept off."""

    def test_a_short_retry_after_sleeps_and_resends_under_the_same_key(self):
        slept = []
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": [
                (429, '{"error":{"status":429,"code":"rate_limited","message":"Retry in 2s."}}', {"Retry-After": "2"}),
                ops_ok(task_data()),
            ],
        }
        code, out, err, transport = self.cli(["done", "%101"], routes, sleeper=slept.append)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(slept, [2])
        posts = self.posted(transport)
        self.assertEqual(len(posts), 2)
        self.assertEqual(posts[0][1]["Idempotency-Key"], posts[1][1]["Idempotency-Key"])
        self.assertEqual(posts[0][0], posts[1][0])
        self.assertEqual(out, "done  %101  Write the controller  100%  [x]\n")
        self.assertEqual(self.pending_paths(), [])

    def test_a_long_retry_after_reports_the_wait_and_stays_pending(self):
        slept = []
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": (
                429,
                '{"error":{"status":429,"code":"rate_limited","message":"Retry in 600s."}}',
                {"Retry-After": "600"},
            ),
        }
        code, out, err, transport = self.cli(["done", "%101"], routes, sleeper=slept.append)
        self.assertEqual(code, 1)
        self.assertEqual(slept, [])
        self.assertEqual(len(self.posted(transport)), 1)
        self.assertIn("rate limited: done %101 Write the controller", out)
        self.assertIn("wait 600s", out)
        records = self.pending_records()
        self.assertEqual(len(records), 1)
        self.assertIn("doitlist.py retry {0}".format(records[0]["key"]), out)


class CompactResultTest(WriteCase):
    """4.8 — outcomes and Task references, actionable errors, saved responses."""

    def test_a_failure_names_the_offending_operation_not_just_the_batch(self):
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_error(
                422,
                "unprocessable_entity",
                "manual_progress is invalid",
                pointer="manual_progress",
            ),
        }
        code, out, err, _ = self.cli(["progress", "%101", "40"], routes)
        self.assertEqual(code, 1)
        self.assertEqual(
            out.splitlines(),
            [
                "failed (422 unprocessable_entity): manual_progress is invalid",
                "  op 0 unprocessable_entity manual_progress: manual_progress is invalid",
            ],
        )

    def test_a_failure_without_a_pointer_still_names_the_operation(self):
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_error(403, "forbidden", "You cannot edit this Task."),
        }
        code, out, _, _ = self.cli(["done", "%101"], routes)
        self.assertEqual(code, 1)
        self.assertIn("failed (403 forbidden): You cannot edit this Task.", out)
        self.assertIn("op 0 forbidden -: You cannot edit this Task.", out)

    def test_no_raw_json_reaches_the_terminal(self):
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_ok(task_data()),
        }
        code, out, err, _ = self.cli(["done", "%101"], routes)
        self.assertEqual(code, 0)
        for envelope in ("results", "manual_progress", "expected_version", "{"):
            self.assertNotIn(envelope, out + err)

    def test_out_saves_the_full_response_and_prints_the_path(self):
        target = os.path.join(self.state, "responses", "done.json")
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_ok(task_data()),
        }
        code, out, err, _ = self.cli(["done", "%101", "--out", target], routes)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(
            out.splitlines(),
            [
                "done  %101  Write the controller  100%  [x]",
                "saved: {0}".format(target),
            ],
        )
        with open(target, encoding="utf-8") as handle:
            raw = handle.read()
        saved = json.loads(raw)
        self.assertEqual(saved["results"][0]["data"]["id"], 101)
        self.assertEqual(saved["results"][0]["data"]["version"], 8)
        self.assertNotIn(TOKEN, raw)

    def test_out_saves_a_failure_response_and_keeps_the_error_visible(self):
        target = os.path.join(self.state, "failure.json")
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_error(
                422, "unprocessable_entity", "title can't be blank", pointer="title"
            ),
        }
        code, out, err, _ = self.cli(["retitle", "%101", "New name", "--out", target], routes)
        self.assertEqual(code, 1)
        self.assertIn("failed (422 unprocessable_entity): title can't be blank", out)
        self.assertIn("op 0 unprocessable_entity title: title can't be blank", out)
        self.assertIn("saved: {0}".format(target), out)
        with open(target, encoding="utf-8") as handle:
            saved = json.load(handle)
        self.assertEqual(saved["error"]["code"], "unprocessable_entity")
        self.assertEqual(saved["results"][0]["error"]["pointer"], "title")

    def test_an_unknown_outcome_saves_nothing_because_there_is_nothing_to_save(self):
        target = os.path.join(self.state, "missing.json")
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": doitlist.TransportError("could not reach the host"),
        }
        code, out, _, _ = self.cli(["done", "%101", "--out", target], routes)
        self.assertEqual(code, 1)
        self.assertNotIn("saved:", out)
        self.assertFalse(os.path.exists(target))

    def test_retry_out_saves_one_entry_per_resent_key(self):
        target = os.path.join(self.state, "retried.json")
        lost = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": doitlist.TransportError("could not reach the host"),
        }
        self.assertEqual(self.cli(["done", "%101"], lost)[0], 1)
        key = self.pending_records()[0]["key"]

        code, out, err, _ = self.cli(
            ["retry", "--out", target], {"POST /api/v1/operations": ops_ok(task_data())}
        )
        self.assertEqual(code, 0, out + err)
        self.assertIn("saved: {0}".format(target), out)
        with open(target, encoding="utf-8") as handle:
            saved = json.load(handle)
        self.assertEqual([entry["key"] for entry in saved], [key])
        self.assertEqual(saved[0]["response"]["results"][0]["data"]["id"], 101)

    def test_an_unwritable_out_path_is_reported_without_undoing_the_write(self):
        target = os.path.join(self.state, "done.json", "nested.json")  # a file, not a directory
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_ok(task_data()),
        }
        with open(os.path.join(self.state, "done.json"), "w", encoding="utf-8") as handle:
            handle.write("in the way")
        code, out, err, _ = self.cli(["done", "%101", "--out", target], routes)
        self.assertEqual(code, 1)
        self.assertIn("done  %101  Write the controller  100%  [x]", out)
        self.assertIn("could not save the response", out)
        self.assertEqual(self.pending_paths(), [], "the write itself still settled")

    def test_supplied_content_reaches_the_api_and_the_saved_file_verbatim(self):
        text = '  Ship it — "as is", 100% <done>\t  '
        target = os.path.join(self.state, "comment.json")
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_ok(
                {"id": 33, "type": "comment", "task_id": 101, "body": text, "author_id": 7, "deleted": False}
            ),
        }
        code, out, err, transport = self.cli(["comment", "%101", text, "--out", target], routes)
        self.assertEqual(code, 0, out + err)
        body, _ = self.posted(transport)[0]
        self.assertEqual(body["operations"][0]["data"]["body"], text)
        with open(target, encoding="utf-8") as handle:
            self.assertEqual(json.load(handle)["results"][0]["data"]["body"], text)


if __name__ == "__main__":
    unittest.main()
