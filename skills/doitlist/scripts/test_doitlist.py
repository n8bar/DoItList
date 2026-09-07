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
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import doitlist  # noqa: E402


def _json(value):
    return json.dumps(value)


TOKEN = "tok_SECRET_do_not_leak"
ENV = {"DOITLIST_API_URL": "http://localhost:4000", "DOITLIST_API_TOKEN": TOKEN}


class FakeTransport(object):
    """Canned responses keyed by `METHOD path?query`, plus a request log."""

    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def send(self, method, url, headers, body):
        self.calls.append({"method": method, "url": url, "headers": headers, "body": body})
        path = url.split("://", 1)[-1].split("/", 1)[-1]
        key = "{0} /{1}".format(method, path)
        if key not in self.routes:
            raise AssertionError("unexpected request {0}; know {1}".format(key, sorted(self.routes)))
        return self.routes[key]


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


def run(argv, routes, env=None):
    """Run main() with a fake transport; returns (code, stdout, stderr)."""
    transport = FakeTransport(routes)
    out, err = io.StringIO(), io.StringIO()
    code = doitlist.main(argv, env=ENV if env is None else env, transport=transport, out=out, err=err)
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

    def test_every_verb_has_help(self):
        for verb in ("list", "tree", "comments", "activity"):
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
                "  2.1 Package it  %121  25%  [ ]  branch (1 children not shown)",
            ],
        )

    def test_depth_one_on_the_whole_tree_shows_top_level_only(self):
        code, out, err, _ = run(["tree", "12", "--depth", "1"], self.routes)
        self.assertEqual(code, 0, err)
        self.assertEqual(
            out.splitlines()[3:],
            [
                "1 Build the API  %101  50%  [ ]  branch (2 children not shown)",
                "2 Ship the SDK  %102  25%  [ ]  branch (1 children not shown)",
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


if __name__ == "__main__":
    unittest.main()
