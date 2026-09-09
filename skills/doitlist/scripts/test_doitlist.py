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
import hashlib
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
    "progress_calc": "leaf_average",
    "unit_count": 3,
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

    def test_task_accepts_the_stored_bracketed_form(self):
        # Task fields store references as `%<272>` with literal brackets, so
        # all three spellings must name the same Task.
        self.assertEqual(doitlist.parse_task_ref("%<272>"), 272)
        self.assertEqual(doitlist.parse_task_ref("%272"), 272)
        self.assertEqual(doitlist.parse_task_ref("272"), 272)
        self.assertEqual(doitlist.parse_parent_ref("%<272>"), ("task", 272))

    def test_task_rejects_a_label(self):
        with self.assertRaises(doitlist.UsageError):
            doitlist.parse_task_ref("%1.2")
        with self.assertRaisesRegex(doitlist.UsageError, "is not a Task"):
            doitlist.parse_task_ref("%<abc>")
        with self.assertRaisesRegex(doitlist.UsageError, "is not a Task"):
            doitlist.parse_parent_ref("%<abc>")

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
        for verb in (
            "add",
            "done",
            "progress",
            "move",
            "comment",
            "retitle",
            "describe",
            "import",
            "diff",
            "retry",
        ):
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
            "import",
            "diff",
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
                "Initiative: Q3 Launch  https://doitlist.app/initiatives/12  42%  3 leaves",
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

    def test_header_names_the_unit_the_calc_mode_counts(self):
        single = dict(TREE, progress_calc="single_level", unit_count=2)
        routes = {"GET /api/v1/initiatives/12": (200, _json(single))}
        code, out, err, _ = run(["tree", "12"], routes)
        self.assertEqual(code, 0, err)
        self.assertEqual(
            out.splitlines()[0],
            "Initiative: Q3 Launch  https://doitlist.app/initiatives/12  42%  2 top-level Tasks",
        )

        one = dict(TREE, unit_count=1)
        routes = {"GET /api/v1/initiatives/12": (200, _json(one))}
        code, out, _, _ = run(["tree", "12"], routes)
        self.assertEqual(code, 0)
        self.assertTrue(out.splitlines()[0].endswith("  42%  1 leaf"))

    def test_header_omits_the_unit_cell_when_the_server_reports_none(self):
        older = {k: v for k, v in TREE.items() if k != "unit_count"}
        routes = {"GET /api/v1/initiatives/12": (200, _json(older))}
        code, out, _, _ = run(["tree", "12"], routes)
        self.assertEqual(code, 0)
        self.assertEqual(
            out.splitlines()[0],
            "Initiative: Q3 Launch  https://doitlist.app/initiatives/12  42%",
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
                "Initiative: Q3 Launch  https://doitlist.app/initiatives/12  42%  3 leaves",
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
                "Initiative: Q3 Launch  https://doitlist.app/initiatives/12  42%  3 leaves",
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

    def test_numbered_sends_the_override_flag_on_add_and_retitle(self):
        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_ok(task_data(id=142, title="1. Kickoff", parent_id=101)),
        }
        code, out, err, transport = self.cli(["add", "%101", "1. Kickoff", "--numbered"], routes)
        self.assertEqual(code, 0, out + err)
        body, _ = self.posted(transport)[0]
        self.assertEqual(
            body["operations"][0]["data"],
            {"parent_id": 101, "title": "1. Kickoff", "numbered_title": True},
        )

        routes = {
            "GET /api/v1/tasks/101": read_task(),
            "POST /api/v1/operations": ops_ok(task_data(title="I. Kickoff")),
        }
        code, out, err, transport = self.cli(["retitle", "--numbered", "%101", "I. Kickoff"], routes)
        self.assertEqual(code, 0, out + err)
        body, _ = self.posted(transport)[0]
        self.assertEqual(
            body["operations"][0]["data"],
            {"title": "I. Kickoff", "expected_version": 7, "numbered_title": True},
        )

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


# --------------------------------------------------------------------------
# 4.4 — import and diff
# --------------------------------------------------------------------------

#: A small source document: a `# ` heading, a tab-indented child, one `[x]`.
DOC = "# Q3 Plan\n\n- Ship the thing\n\t- Draft [x]\n- Tell everyone\n"

#: The read of the document every 200 carries, in both modes.
SUMMARY = {
    "title": "Q3 Plan",
    "style": "numerical",
    "counts": {"items": 3, "done": 1, "depth": 2, "title_overflow": 0},
    "outline": "1 Ship the thing\n  1.1 Draft [x]\n2 Tell everyone",
    "target": {"kind": "new_initiative", "name": "Q3 Plan"},
}

INITIATIVE = {"id": 12, "url": "https://doitlist.app/initiatives/12"}


def preview_body(**overrides):
    body = dict(SUMMARY)
    body["preview"] = True
    body["limits"] = {"max_items": 2000, "max_source_bytes": 1048576}
    body.update(overrides)
    return (200, _json(body))


def applied_body(**overrides):
    body = dict(SUMMARY)
    body["preview"] = False
    body["batches"] = 1
    body["initiative"] = INITIATIVE
    body.update(overrides)
    return (200, _json(body))


def batch_failure_body(total=3):
    """The endpoint's partial-apply shape: some batches committed, one didn't.

    `total=None` is the older body, before the endpoint carried a denominator.
    """
    counts = {"applied_batches": 1, "failed_batch": 2}
    if total is not None:
        counts["total_batches"] = total
    return (
        422,
        _json(
            {
                "error": {
                    "status": 422,
                    "code": "unprocessable_entity",
                    "message": (
                        "title can't be blank 1 of 3 batches had already committed, "
                        "so the target holds a partial import."
                    ),
                },
                "results": [
                    {
                        "index": 4,
                        "status": "error",
                        "error": {
                            "code": "unprocessable_entity",
                            "pointer": "title",
                            "message": "title can't be blank",
                        },
                    }
                ],
                "initiative": INITIATIVE,
                **counts,
            }
        ),
    )


CLEAN_DIFF = {
    "clean": True,
    "summary": {"matched": 3, "missing": 0, "extra": 0, "completion": 0, "order": 0},
    "missing": [],
    "extra": [],
    "completion": [],
    "order": [],
}

DIRTY_DIFF = {
    "clean": False,
    "summary": {"matched": 4, "missing": 1, "extra": 1, "completion": 1, "order": 1},
    "missing": [{"path": "Ship the SDK > Package it", "title": "Package it"}],
    "extra": [{"path": "Build the API > Old step", "title": "Old step", "id": 119}],
    "completion": [
        {
            "path": "Build the API > Write the tests",
            "source_done": True,
            "live_done": False,
            "id": 112,
        }
    ],
    "order": [
        {
            "parent": "(root)",
            "source": ["Build the API", "Ship the SDK"],
            "live": ["Ship the SDK", "Build the API"],
        }
    ],
}


def diff_body(report):
    return preview_body(
        diff=report, target={"kind": "initiative", "id": 12, "parent_task_id": None}
    )


class ImportCase(unittest.TestCase):
    """Every import test writes its document into its own temp directory."""

    def setUp(self):
        self.state = tempfile.mkdtemp(prefix="doitlist-import-")
        self.addCleanup(shutil.rmtree, self.state, True)
        self.env = dict(ENV, DOITLIST_STATE_DIR=self.state)

    def document(self, text=DOC, name="plan.md"):
        path = os.path.join(self.state, name)
        with open(path, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        return path

    def cli(self, argv, routes):
        return run(argv, routes, env=self.env)

    def posted(self, transport):
        return [
            json.loads(call["body"].decode("utf-8"))
            for call in transport.calls
            if call["method"] == "POST"
        ]


class ImportRequestShapeTest(ImportCase):
    """The document goes up unread; only the target is decided here."""

    def test_as_names_the_new_initiative(self):
        path = self.document()
        code, out, err, transport = self.cli(
            ["import", path, "--as", "  Renamed plan  "], {"POST /api/v1/imports": applied_body()}
        )
        self.assertEqual(code, 0, out + err)
        body = self.posted(transport)[0]
        self.assertEqual(body["target"], {"initiative_name": "Renamed plan"})
        self.assertEqual(body["filename"], "plan.md")
        self.assertIs(body["preview"], False)

    def test_the_first_heading_names_the_new_initiative(self):
        path = self.document()
        code, out, err, transport = self.cli(
            ["import", path], {"POST /api/v1/imports": applied_body()}
        )
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.posted(transport)[0]["target"], {"initiative_name": "Q3 Plan"})

    def test_a_headingless_document_falls_back_to_the_file_stem(self):
        path = self.document(text="- Sweep up\n- Take out the bins\n", name="chores.md")
        code, out, err, transport = self.cli(
            ["import", path], {"POST /api/v1/imports": applied_body()}
        )
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.posted(transport)[0]["target"], {"initiative_name": "chores"})

    def test_into_sends_the_existing_initiative_id(self):
        path = self.document()
        code, out, err, transport = self.cli(
            ["import", path, "--into", "https://doitlist.app/initiatives/12"],
            {"POST /api/v1/imports": applied_body()},
        )
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.posted(transport)[0]["target"], {"initiative_id": 12})

    def test_into_with_under_sends_the_parent_task(self):
        path = self.document()
        code, out, err, transport = self.cli(
            ["import", path, "--into", "12", "--under", "%101"],
            {"POST /api/v1/imports": applied_body()},
        )
        self.assertEqual(code, 0, out + err)
        self.assertEqual(
            self.posted(transport)[0]["target"], {"initiative_id": 12, "parent_task_id": 101}
        )

    def test_preview_asks_for_a_preview(self):
        path = self.document()
        code, out, err, transport = self.cli(
            ["import", path, "--preview"], {"POST /api/v1/imports": preview_body()}
        )
        self.assertEqual(code, 0, out + err)
        self.assertIs(self.posted(transport)[0]["preview"], True)

    def test_under_without_into_is_refused_before_any_request(self):
        path = self.document()
        code, out, err, transport = self.cli(["import", path, "--under", "%101"], {})
        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        self.assertIn("--into", err)
        self.assertEqual(transport.calls, [])

    def test_a_missing_file_is_refused_before_any_request(self):
        missing = os.path.join(self.state, "nope.md")
        code, out, err, transport = self.cli(["import", missing, "--into", "12"], {})
        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        self.assertIn("nope.md", err)
        self.assertEqual(transport.calls, [])

    def test_the_document_travels_byte_for_byte(self):
        # CRLF, a tab, trailing spaces, a non-ASCII character, trailing newline:
        # none of it is trimmed, normalized, or reflowed on the way out.
        text = "# Plan\r\n\r\n- Tabs\tand trailing space   \n\t- Nested — em dash\n"
        path = self.document(text=text)
        code, out, err, transport = self.cli(
            ["import", path, "--into", "12"], {"POST /api/v1/imports": applied_body()}
        )
        self.assertEqual(code, 0, out + err)
        raw = transport.calls[0]["body"]
        self.assertEqual(json.loads(raw.decode("utf-8"))["text"], text)
        self.assertFalse(raw.startswith(b"\xef\xbb\xbf"))  # no BOM on the wire

    def test_an_apply_carries_no_idempotency_key_and_parks_nothing(self):
        # The endpoint is idempotent by source hash per target, so there is
        # nothing to park and nothing to retry.
        path = self.document()
        code, out, err, transport = self.cli(
            ["import", path], {"POST /api/v1/imports": applied_body()}
        )
        self.assertEqual(code, 0, out + err)
        self.assertNotIn("Idempotency-Key", transport.calls[0]["headers"])
        self.assertFalse(os.path.isdir(os.path.join(self.state, "pending")))


class ImportOutputTest(ImportCase):
    def test_an_apply_reports_the_tree_the_url_and_the_batches(self):
        path = self.document()
        code, out, err, _ = self.cli(["import", path], {"POST /api/v1/imports": applied_body()})
        self.assertEqual(code, 0, out + err)
        self.assertEqual(
            out.splitlines(),
            [
                "imported  Q3 Plan  https://doitlist.app/initiatives/12",
                "3 items, 1 done, depth 2, style numerical, 1 batch",
            ],
        )

    def test_a_replay_says_nothing_new_was_created(self):
        path = self.document()
        code, out, err, _ = self.cli(
            ["import", path], {"POST /api/v1/imports": applied_body(batches=3, replayed=True)}
        )
        self.assertEqual(code, 0, out + err)
        self.assertEqual(
            out.splitlines(),
            [
                "imported  Q3 Plan  https://doitlist.app/initiatives/12",
                "3 items, 1 done, depth 2, style numerical, 3 batches",
                "replayed (nothing new was created)",
            ],
        )

    def test_a_preview_prints_the_counts_and_the_outline_verbatim(self):
        path = self.document()
        code, out, err, _ = self.cli(
            ["import", path, "--preview"], {"POST /api/v1/imports": preview_body()}
        )
        self.assertEqual(code, 0, out + err)
        self.assertEqual(
            out.splitlines(),
            [
                "3 items, 1 done, depth 2, style numerical",
                "1 Ship the thing",
                "  1.1 Draft [x]",
                "2 Tell everyone",
            ],
        )

    def test_a_batch_failure_says_what_landed_and_names_every_refused_op(self):
        path = self.document()
        code, out, err, _ = self.cli(
            ["import", path, "--into", "12"], {"POST /api/v1/imports": batch_failure_body()}
        )
        self.assertEqual(code, 1)
        self.assertEqual(
            out.splitlines(),
            [
                "failed (422 unprocessable_entity): title can't be blank 1 of 3 batches "
                "had already committed, so the target holds a partial import.",
                "applied 1 of 3 batches — the target holds a partial import; "
                "diff it to see what landed",
                "  https://doitlist.app/initiatives/12",
                "  op 4 unprocessable_entity title: title can't be blank",
            ],
        )

    def test_a_batch_failure_without_a_total_keeps_the_bare_count(self):
        # No denominator in the body, none invented in the line.
        path = self.document()
        code, out, err, _ = self.cli(
            ["import", path, "--into", "12"],
            {"POST /api/v1/imports": batch_failure_body(total=None)},
        )
        self.assertEqual(code, 1)
        self.assertIn(
            "applied 1 batch — the target holds a partial import; diff it to see what landed",
            out,
        )

    def test_a_validation_refusal_claims_no_partial_import(self):
        path = self.document()
        refusal = (
            422,
            _json(
                {
                    "error": {
                        "status": 422,
                        "code": "unprocessable_entity",
                        "message": "No tasks found in the source text.",
                    }
                }
            ),
        )
        code, out, err, _ = self.cli(
            ["import", path, "--into", "12"], {"POST /api/v1/imports": refusal}
        )
        self.assertEqual(code, 1)
        self.assertEqual(
            out.splitlines(),
            ["failed (422 unprocessable_entity): No tasks found in the source text."],
        )
        self.assertNotIn("partial", out)

    def test_a_lost_response_says_the_command_is_safe_to_re_run(self):
        path = self.document()
        code, out, err, _ = self.cli(
            ["import", path],
            {"POST /api/v1/imports": doitlist.TransportError("could not reach the host")},
        )
        self.assertEqual(code, 1)
        self.assertIn("outcome unknown: import {0}".format(path), out)
        self.assertIn("re-run the same command", out)
        self.assertNotIn("retry with", out)  # nothing is parked, so nothing to retry

    def test_out_saves_the_full_import_response(self):
        path = self.document()
        target = os.path.join(self.state, "responses", "import.json")
        code, out, err, _ = self.cli(
            ["import", path, "--out", target], {"POST /api/v1/imports": applied_body()}
        )
        self.assertEqual(code, 0, out + err)
        self.assertIn("saved: {0}".format(target), out)
        with open(target, encoding="utf-8") as handle:
            raw = handle.read()
        self.assertEqual(json.loads(raw)["initiative"]["id"], 12)
        self.assertNotIn(TOKEN, raw)


class DiffTest(ImportCase):
    """`diff` is the preview against an existing target: read-only, exit-coded."""

    def routes(self, report):
        return {
            "GET /api/v1/initiatives/12": (200, _json(TREE)),
            "POST /api/v1/imports": diff_body(report),
        }

    def test_a_clean_diff_names_the_initiative_and_exits_zero(self):
        path = self.document()
        code, out, err, transport = self.cli(["diff", path, "12"], self.routes(CLEAN_DIFF))
        self.assertEqual(code, 0, out + err)
        self.assertEqual(
            out.splitlines(),
            ["clean: {0} matches Q3 Launch  https://doitlist.app/initiatives/12".format(path)],
        )
        # Read-only on both sides: the preview flag is set, so nothing is written.
        self.assertIs(self.posted(transport)[0]["preview"], True)

    def test_differences_render_every_section_and_exit_one(self):
        path = self.document()
        code, out, err, _ = self.cli(["diff", path, "12"], self.routes(DIRTY_DIFF))
        self.assertEqual(code, 1, err)
        self.assertEqual(
            out.splitlines(),
            [
                "missing (1):",
                "  Ship the SDK > Package it",
                "extra (1):",
                "  Build the API > Old step  %119",
                "completion (1):",
                "  Build the API > Write the tests  source [x]  live [ ]  %112",
                "order (1):",
                "  under (root): source Build the API > Ship the SDK / "
                "live Ship the SDK > Build the API",
                "matched 4",
            ],
        )

    def test_under_scopes_the_comparison_and_names_the_task(self):
        path = self.document()
        code, out, err, transport = self.cli(
            ["diff", path, "12", "--under", "%101"], self.routes(CLEAN_DIFF)
        )
        self.assertEqual(code, 0, out + err)
        self.assertEqual(
            self.posted(transport)[0]["target"], {"initiative_id": 12, "parent_task_id": 101}
        )
        self.assertIn("%101 in Q3 Launch", out)

    def test_out_saves_the_full_preview_and_keeps_the_verdict(self):
        path = self.document()
        target = os.path.join(self.state, "diff.json")
        code, out, err, _ = self.cli(
            ["diff", path, "12", "--out", target], self.routes(DIRTY_DIFF)
        )
        self.assertEqual(code, 1)
        self.assertIn("missing (1):", out)
        self.assertIn("saved: {0}".format(target), out)
        with open(target, encoding="utf-8") as handle:
            saved = json.load(handle)
        self.assertEqual(saved["diff"]["summary"]["missing"], 1)

    def test_a_preview_without_a_diff_is_reported_not_called_clean(self):
        path = self.document()
        routes = {
            "GET /api/v1/initiatives/12": (200, _json(TREE)),
            "POST /api/v1/imports": preview_body(),
        }
        code, out, err, _ = self.cli(["diff", path, "12"], routes)
        self.assertEqual(code, 1)
        self.assertEqual(out, "")
        self.assertIn("without a diff", err)


# --------------------------------------------------------------------------
# 4.7 — completion mirroring
# --------------------------------------------------------------------------
# The mirror is the operator's own Markdown plan, so every test here works on a
# real temp file and checks the bytes that come back out: one box ticked, every
# other byte — indent, marker, spacing, line ending, and the operator's own
# concurrent edits — exactly as it was.

#: A maintained mirror of `TREE`: an Initiative link, four sections, and every
#: shape the matcher has to survive — a dash list and a numbered one, a nested
#: heading that does NOT end its section, a line naming no live Task, a line
#: naming a branch, a line naming an already-done Task, and one section whose
#: two identical lines can never be told apart.
MIRROR_DOC = """# Q3 Launch

Mirror of https://doitlist.app/initiatives/12 — keep the boxes in sync.

## Build the API

Notes about the API stay exactly where they are.

- [x] Write the controller
- [ ] Write the tests

## Ship the SDK

1. [ ] Package it
2. [ ] Ghost item
3. [ ] Pick a name
4. [ ] Write the controller
5. [ ] Write the tests

### Packaging notes

* [ ] Nothing to see

## Duplicates

- [ ] Write the tests
- [ ] Write the tests

## Ticked ahead

- [x] Pick a name
- [ ] Write the tests
"""


def tree_with_done(*ids):
    """`TREE` again, with the named Tasks completed — the live state a mirror
    `retry` reads back after its POST already committed."""
    tree = json.loads(_json(TREE))

    def walk(nodes):
        for item in nodes:
            if item["id"] in ids:
                item["done"] = True
                item["progress"] = 100
            walk(item["children"])

    walk(tree["tasks"])
    return tree


class HookedTransport(FakeTransport):
    """A transport that runs a callback after a chosen method's reply.

    That is the only place a test can stand: `--mirror` reads the file, POSTs,
    then writes the file, so "the operator edited the plan while the write was
    in flight" is exactly "edit it when the POST answers".
    """

    def __init__(self, routes, method, hook):
        FakeTransport.__init__(self, routes)
        self.method = method
        self.hook = hook

    def send(self, method, url, headers, body):
        reply = FakeTransport.send(self, method, url, headers, body)
        if method == self.method:
            self.hook()
        return reply


class MirrorCase(WriteCase):
    """Each test gets its own state directory and its own plan file."""

    def setUp(self):
        WriteCase.setUp(self)
        self.files = tempfile.mkdtemp(prefix="doitlist-mirror-")
        self.addCleanup(shutil.rmtree, self.files, True)

    def mirror(self, text=None, name="plan.md", newline="\n"):
        body = MIRROR_DOC if text is None else text
        if newline != "\n":
            body = body.replace("\n", newline)
        path = os.path.join(self.files, name)
        self.write_mirror(path, body)
        return path

    def write_mirror(self, path, body):
        with open(path, "w", encoding="utf-8", newline="") as handle:
            handle.write(body)

    def read_mirror(self, path):
        with open(path, encoding="utf-8", newline="") as handle:
            return handle.read()

    def routes(self, result=None, tree=None, post=None):
        if post is None:
            post = ops_ok(
                result
                if result is not None
                else task_data(id=112, title="Write the tests", progress=100, done=True, version=9)
            )
        return {
            "GET /api/v1/initiatives/12": (200, _json(TREE if tree is None else tree)),
            "POST /api/v1/operations": post,
        }

    def cli_with(self, argv, transport):
        out, err = io.StringIO(), io.StringIO()
        code = doitlist.main(
            argv, env=self.env, transport=transport, out=out, err=err, sleeper=lambda _s: None
        )
        return code, out.getvalue(), err.getvalue(), transport

    def changed_lines(self, before, after):
        """The lines that differ, as (before, after) pairs."""
        old, new = before.splitlines(True), after.splitlines(True)
        self.assertEqual(len(old), len(new), "a mirror update must not add or drop lines")
        return [pair for pair in zip(old, new) if pair[0] != pair[1]]


class MirrorMatchTest(MirrorCase):
    """4.7.1 / 4.7.2 — one exact match, or nothing happens at all."""

    def test_a_unique_match_ticks_one_line_and_leaves_every_other_byte(self):
        path = self.mirror()
        before = self.read_mirror(path)
        code, out, err, _ = self.cli(
            ["done", "%112", "--mirror", path, "--section", "Build the API"], self.routes()
        )
        self.assertEqual(code, 0, out + err)
        after = self.read_mirror(path)
        self.assertEqual(
            out.splitlines(),
            [
                "done  %112  Write the tests  100%  [x]",
                "mirror  plan.md § Build the API: [x] Write the tests",
                "next  none in section",
            ],
        )
        self.assertEqual(
            self.changed_lines(before, after),
            [("- [ ] Write the tests\n", "- [x] Write the tests\n")],
        )
        self.assertEqual(self.pending_paths(), [])

    def test_a_crlf_mirror_keeps_its_line_endings(self):
        path = self.mirror(newline="\r\n")
        before = self.read_mirror(path)
        code, out, err, _ = self.cli(
            ["done", "%112", "--mirror", path, "--section", "Build the API"], self.routes()
        )
        self.assertEqual(code, 0, out + err)
        after = self.read_mirror(path)
        self.assertEqual(
            self.changed_lines(before, after),
            [("- [ ] Write the tests\r\n", "- [x] Write the tests\r\n")],
        )
        self.assertEqual(after.count("\r\n"), before.count("\r\n"))
        self.assertEqual(after.count("\n"), after.count("\r\n"), "no bare LF may creep in")

    def test_a_numbered_marker_and_a_nested_heading_are_both_in_section(self):
        # `3. [ ] Pick a name` sits under a `###` sub-heading's parent section:
        # a deeper heading does not end it, and `1.` is a list marker.
        path = self.mirror()
        before = self.read_mirror(path)
        code, out, err, _ = self.cli(
            [
                "done",
                "%131",
                "--mirror",
                path,
                "--section",
                "Ship the SDK",
            ],
            self.routes(result=task_data(id=131, title="Pick a name", progress=100, done=True)),
        )
        self.assertEqual(code, 0, out + err)
        self.assertEqual(
            self.changed_lines(before, self.read_mirror(path)),
            [("3. [ ] Pick a name\n", "3. [x] Pick a name\n")],
        )

    def test_a_duplicate_match_refuses_and_writes_nothing_anywhere(self):
        path = self.mirror()
        before = self.read_mirror(path)
        code, out, err, transport = self.cli(
            ["done", "%112", "--mirror", path, "--section", "Duplicates"], self.routes()
        )
        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        self.assertIn('2 checkbox lines under "Duplicates"', err)
        self.assertIn("nothing was written", err)
        self.assertEqual([call["method"] for call in transport.calls], ["GET"])
        self.assertEqual(self.read_mirror(path), before)
        self.assertEqual(self.pending_paths(), [])

    def test_no_match_refuses_and_never_matches_fuzzily(self):
        # The live title is "Write the tests"; the section holds "Pick a name"
        # and friends. Nothing close enough is close enough.
        path = self.mirror()
        code, out, err, transport = self.cli(
            ["done", "%112", "--mirror", path, "--section", "Packaging notes"], self.routes()
        )
        self.assertEqual(code, 2)
        self.assertIn('0 checkbox lines under "Packaging notes"', err)
        self.assertEqual([call["method"] for call in transport.calls], ["GET"])

    def test_a_missing_section_names_the_heading_it_wanted(self):
        path = self.mirror()
        code, _, err, transport = self.cli(
            ["done", "%112", "--mirror", path, "--section", "Nowhere"], self.routes()
        )
        self.assertEqual(code, 2)
        self.assertIn('no "Nowhere" heading', err)
        self.assertEqual([call["method"] for call in transport.calls], ["GET"])

    def test_an_already_ticked_line_is_reported_and_left_alone(self):
        path = self.mirror()
        before = self.read_mirror(path)
        code, out, err, _ = self.cli(
            ["done", "%111", "--mirror", path, "--section", "Build the API"],
            self.routes(result=task_data(id=111, title="Write the controller")),
        )
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.read_mirror(path), before)
        self.assertIn(
            "mirror  plan.md § Build the API: already [x] Write the controller", out
        )


class MirrorRequestTest(MirrorCase):
    """4.7.5 — the normal path costs one GET and one POST, and no more."""

    def test_the_normal_path_makes_exactly_one_get_and_one_post(self):
        path = self.mirror()
        code, out, err, transport = self.cli(
            ["done", "%112", "--mirror", path, "--section", "Build the API"], self.routes()
        )
        self.assertEqual(code, 0, out + err)
        self.assertEqual([call["method"] for call in transport.calls], ["GET", "POST"])
        body, headers = self.posted(transport)[0]
        self.assertEqual(
            body["operations"][0],
            {
                "op": "update",
                "type": "task",
                "id": 112,
                "data": {"done": True, "expected_version": 1},
            },
        )
        uuid.UUID(headers["Idempotency-Key"])

    def test_the_initiative_comes_from_the_files_own_link(self):
        path = self.mirror()
        code, out, err, transport = self.cli(
            ["done", "%112", "--mirror", path, "--section", "Build the API"], self.routes()
        )
        self.assertEqual(code, 0, out + err)
        self.assertIn("/api/v1/initiatives/12", transport.calls[0]["url"])

    def test_initiative_overrides_the_link_and_a_linkless_file_is_refused(self):
        linkless = self.mirror(text=MIRROR_DOC.replace("https://doitlist.app/initiatives/12", "-"))
        code, _, err, transport = self.cli(
            ["done", "%112", "--mirror", linkless, "--section", "Build the API"], self.routes()
        )
        self.assertEqual(code, 2)
        self.assertIn("carries no Initiative link", err)
        self.assertEqual(transport.calls, [])

        code, out, err, transport = self.cli(
            [
                "done",
                "%112",
                "--mirror",
                linkless,
                "--section",
                "Build the API",
                "--initiative",
                "https://doitlist.app/initiatives/12",
            ],
            self.routes(),
        )
        self.assertEqual(code, 0, out + err)
        self.assertIn("[x] Write the tests", out)

    def test_a_task_outside_the_mirrored_initiative_is_refused(self):
        path = self.mirror()
        code, out, err, transport = self.cli(
            ["done", "%999", "--mirror", path, "--section", "Build the API"], self.routes()
        )
        self.assertEqual(code, 1)
        self.assertIn("%999 is not in Q3 Launch", err)
        self.assertEqual([call["method"] for call in transport.calls], ["GET"])


class MirrorUsageTest(MirrorCase):
    """4.7.1 — the option pair is one instruction, and reopening is not mirrored."""

    def test_mirror_without_section_is_a_usage_error(self):
        path = self.mirror()
        code, _, err, transport = self.cli(["done", "%112", "--mirror", path], self.routes())
        self.assertEqual(code, 2)
        self.assertIn("--mirror and --section go together", err)
        self.assertEqual(transport.calls, [])

    def test_section_without_mirror_is_a_usage_error(self):
        code, _, err, transport = self.cli(
            ["done", "%112", "--section", "Build the API"], self.routes()
        )
        self.assertEqual(code, 2)
        self.assertIn("--mirror and --section go together", err)
        self.assertEqual(transport.calls, [])

    def test_reopen_cannot_be_mirrored(self):
        path = self.mirror()
        code, _, err, transport = self.cli(
            ["done", "%112", "--reopen", "--mirror", path, "--section", "Build the API"],
            self.routes(),
        )
        self.assertEqual(code, 2)
        self.assertIn("--reopen is not mirrored", err)
        self.assertEqual(transport.calls, [])

    def test_initiative_without_mirror_is_a_usage_error(self):
        code, _, err, transport = self.cli(["done", "%112", "--initiative", "12"], self.routes())
        self.assertEqual(code, 2)
        self.assertIn("--initiative only applies to a mirrored completion", err)
        self.assertEqual(transport.calls, [])


class MirrorNextTest(MirrorCase):
    """4.7.5 — the next unfinished leaf, in the section's own order."""

    def test_next_skips_branches_done_leaves_and_unmatched_lines(self):
        # In file order after ticking "Pick a name": "Package it" is a branch,
        # "Ghost item" names no live Task, "Write the controller" is already
        # done — so the first line that qualifies is "Write the tests" (%112).
        path = self.mirror()
        code, out, err, _ = self.cli(
            ["done", "%131", "--mirror", path, "--section", "Ship the SDK"],
            self.routes(result=task_data(id=131, title="Pick a name", progress=100, done=True)),
        )
        self.assertEqual(code, 0, out + err)
        self.assertEqual(
            out.splitlines(),
            [
                "done  %131  Pick a name  100%  [x]",
                "mirror  plan.md § Ship the SDK: [x] Pick a name",
                "next  1.2 Write the tests  %112",
            ],
        )

    def test_next_skips_a_line_the_file_already_ticks(self):
        # "Pick a name" is ticked in the plan though %131 is still open live.
        # The section is the operator's own record of what they consider done,
        # so a ticked line is never handed back as the next thing to do.
        path = self.mirror()
        code, out, err, _ = self.cli(
            ["done", "%112", "--mirror", path, "--section", "Ticked ahead"], self.routes()
        )
        self.assertEqual(code, 0, out + err)
        self.assertEqual(
            out.splitlines(),
            [
                "done  %112  Write the tests  100%  [x]",
                "mirror  plan.md § Ticked ahead: [x] Write the tests",
                "next  none in section",
            ],
        )

    def test_the_task_just_completed_is_never_offered_as_next(self):
        # The live read happened BEFORE the write, so %112 still reads open in
        # it; the confirmed completion is applied before the section is scanned.
        path = self.mirror(
            text=MIRROR_DOC.replace(
                "- [x] Write the controller\n- [ ] Write the tests\n",
                "- [ ] Write the tests\n- [x] Write the controller\n",
            )
        )
        code, out, err, _ = self.cli(
            ["done", "%112", "--mirror", path, "--section", "Build the API"], self.routes()
        )
        self.assertEqual(code, 0, out + err)
        self.assertIn("next  none in section", out)


class MirrorConcurrencyTest(MirrorCase):
    """4.7.3 — a live edit stops the file; a file edit is preserved."""

    def test_a_version_conflict_leaves_the_mirror_untouched(self):
        path = self.mirror()
        before = self.read_mirror(path)
        conflict = ops_error(
            409,
            "conflict",
            "Task 112 has version 4, not 1.",
            current=task_data(id=112, title="Renamed in the browser", progress=0, done=False, version=4),
        )
        code, out, err, _ = self.cli(
            ["done", "%112", "--mirror", path, "--section", "Build the API"],
            self.routes(post=conflict),
        )
        self.assertEqual(code, 1)
        self.assertEqual(
            out.splitlines(),
            [
                "conflict: done %112 Write the tests",
                "  %112  Renamed in the browser  0%  [ ]  version 4",
                "  nothing was applied — re-read, then decide.",
            ],
        )
        self.assertEqual(self.read_mirror(path), before)
        self.assertEqual(self.pending_paths(), [], "a conflict is settled, not owed")

    def test_a_file_edit_during_the_write_is_preserved_and_the_right_line_ticks(self):
        path = self.mirror()

        def edit():
            # The operator adds two lines at the top while the POST is in
            # flight: every parked line index is now wrong.
            self.write_mirror(
                path,
                self.read_mirror(path).replace(
                    "# Q3 Launch\n", "# Q3 Launch\n\nAdded by hand mid-run.\n", 1
                ),
            )

        transport = HookedTransport(self.routes(), "POST", edit)
        code, out, err, _ = self.cli_with(
            ["done", "%112", "--mirror", path, "--section", "Build the API"], transport
        )
        self.assertEqual(code, 0, out + err)
        after = self.read_mirror(path)
        self.assertIn("Added by hand mid-run.", after)
        self.assertIn("- [x] Write the tests\n", after)
        self.assertIn("## Duplicates\n\n- [ ] Write the tests\n- [ ] Write the tests\n", after)
        self.assertEqual(after.count("- [x] Write the tests"), 1)
        self.assertEqual(self.pending_paths(), [])


class MirrorRecoveryTest(MirrorCase):
    """4.7.4 — recovery details are parked before the write, and resumed after."""

    def _lose_the_post(self):
        path = self.mirror()
        routes = self.routes(post=doitlist.TransportError("could not reach the host"))
        code, out, err, transport = self.cli(
            ["done", "%112", "--mirror", path, "--section", "Build the API"], routes
        )
        return path, code, out, transport

    def _strand_at_live_done(self):
        """Complete the live Task, then make the file unreadable to the mirror
        stage — the record must survive at `live_done`, owing only the file."""
        path = self.mirror()
        transport = HookedTransport(self.routes(), "POST", lambda: os.unlink(path))
        code, out, err, _ = self.cli_with(
            ["done", "%112", "--mirror", path, "--section", "Build the API"], transport
        )
        self.assertEqual(code, 1, out + err)
        self.assertIn("live Task completed; mirror not updated", out)
        return path, out, self.pending_records()[0]

    def test_an_interrupted_write_parks_the_mirror_details_and_touches_nothing(self):
        path, code, out, _ = self._lose_the_post()
        self.assertEqual(code, 1)
        self.assertIn("outcome unknown: done %112 Write the tests", out)
        self.assertNotIn("mirror  ", out)
        self.assertEqual(self.read_mirror(path), MIRROR_DOC)

        record = self.pending_records()[0]
        self.assertEqual(record["stage"], "pending")
        self.assertEqual(record["mirror"]["initiative_id"], 12)
        self.assertEqual(record["mirror"]["file"], os.path.realpath(path))
        self.assertEqual(record["mirror"]["section"], "Build the API")
        self.assertEqual(record["mirror"]["title"], "Write the tests")
        self.assertEqual(record["mirror"]["line_index"], 9)
        self.assertEqual(
            record["mirror"]["file_sha256"],
            hashlib.sha256(MIRROR_DOC.encode("utf-8")).hexdigest(),
        )
        self.assertNotIn(TOKEN, json.dumps(record))

    def test_retry_from_pending_resends_the_same_key_then_mirrors(self):
        path, _, _, first = self._lose_the_post()
        record = self.pending_records()[0]
        before = self.read_mirror(path)

        code, out, err, transport = self.cli(["retry"], self.routes(tree=tree_with_done(112)))
        self.assertEqual(code, 0, out + err)
        _body, headers = self.posted(transport)[0]
        self.assertEqual(headers["Idempotency-Key"], record["key"])
        self.assertEqual(
            self.changed_lines(before, self.read_mirror(path)),
            [("- [ ] Write the tests\n", "- [x] Write the tests\n")],
        )
        self.assertEqual(
            out.splitlines(),
            [
                "retrying: done %112 Write the tests",
                "done  %112  Write the tests  100%  [x]",
                "mirror  plan.md § Build the API: [x] Write the tests",
                "next  none in section",
            ],
        )
        self.assertEqual(self.pending_paths(), [])

    def test_a_stranded_mirror_keeps_the_record_at_live_done(self):
        _path, out, record = self._strand_at_live_done()
        self.assertEqual(record["stage"], "live_done")
        self.assertIn("doitlist.py retry {0}".format(record["key"]), out)
        self.assertIn("mirror", record)

    def test_retry_from_live_done_mirrors_without_a_second_post(self):
        path, _out, record = self._strand_at_live_done()
        self.write_mirror(path, MIRROR_DOC)  # the operator put the file back
        # No POST route at all: re-completing from `live_done` would fail here.
        routes = {"GET /api/v1/initiatives/12": (200, _json(tree_with_done(112)))}
        code, out, err, transport = self.cli(["retry", record["key"]], routes)
        self.assertEqual(code, 0, out + err)
        self.assertEqual([call["method"] for call in transport.calls], ["GET"])
        self.assertIn("- [x] Write the tests\n", self.read_mirror(path))
        self.assertEqual(
            out.splitlines(),
            [
                "retrying: done %112 Write the tests",
                "mirror  plan.md § Build the API: [x] Write the tests",
                "next  none in section",
            ],
        )
        self.assertEqual(self.pending_paths(), [])

    def test_a_task_reopened_since_completion_is_not_mirrored(self):
        path, _out, record = self._strand_at_live_done()
        self.write_mirror(path, MIRROR_DOC)
        # The live Task reads open again: this mirror is void, and completing
        # it once more is a NEW operation, not the tail of this one.
        routes = {"GET /api/v1/initiatives/12": (200, _json(TREE))}
        code, out, err, transport = self.cli(["retry", record["key"]], routes)
        self.assertEqual(code, 1)
        self.assertIn("reopened since completion", out)
        self.assertIn("as a new operation", out)
        self.assertEqual([call["method"] for call in transport.calls], ["GET"])
        self.assertEqual(self.read_mirror(path), MIRROR_DOC)
        self.assertEqual(self.pending_paths(), [], "a void mirror is cleared, not left to rot")

    def test_a_second_retry_after_a_successful_mirror_has_nothing_left_to_do(self):
        path, _out, record = self._strand_at_live_done()
        self.write_mirror(path, MIRROR_DOC)
        routes = {"GET /api/v1/initiatives/12": (200, _json(tree_with_done(112)))}
        self.cli(["retry", record["key"]], routes)
        code, out, err, transport = self.cli(["retry"], {})
        self.assertEqual(code, 0, err)
        self.assertEqual(out, "no pending requests\n")
        self.assertEqual(transport.calls, [])


if __name__ == "__main__":
    unittest.main()
