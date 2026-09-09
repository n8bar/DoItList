from __future__ import annotations

import importlib.util
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("doitlist_api.py")
SPEC = importlib.util.spec_from_file_location("doitlist_api", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
api = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(api)


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


class RecordingOpener:
    def __init__(self, body: dict):
        self.body = body
        self.request = None
        self.timeout = None

    def open(self, request, timeout):
        self.request = request
        self.timeout = timeout
        return FakeResponse(json.dumps(self.body).encode())


class DoItListApiTests(unittest.TestCase):
    def test_base_url_requires_https_except_loopback(self):
        self.assertEqual(
            api.validate_base_url("https://doitlist.example/"),
            "https://doitlist.example",
        )
        self.assertEqual(
            api.validate_base_url("http://localhost:4000"),
            "http://localhost:4000",
        )
        with self.assertRaises(api.ClientError):
            api.validate_base_url("http://doitlist.example")
        with self.assertRaises(api.ClientError):
            api.validate_base_url("https://user:password@doitlist.example")

    def test_get_adds_bearer_header_without_changing_url(self):
        opener = RecordingOpener({"data": {"id": 2}})
        client = api.DoItListClient(
            "https://doitlist.example",
            "secret-token",
            opener=opener,
        )
        result = client.get("/api/v1/me")
        self.assertEqual(result, {"data": {"id": 2}})
        self.assertEqual(
            opener.request.full_url,
            "https://doitlist.example/api/v1/me",
        )
        self.assertEqual(
            opener.request.get_header("Authorization"),
            "Bearer secret-token",
        )
        self.assertNotIn("secret-token", opener.request.full_url)

    def test_default_client_refuses_redirects(self):
        client = api.DoItListClient("https://doitlist.example", "token")
        self.assertTrue(
            any(isinstance(handler, api.NoRedirectHandler) for handler in client.opener.handlers)
        )

    def test_apply_is_atomic_shape_with_idempotency_header(self):
        opener = RecordingOpener({"results": [{"index": 0, "status": "ok"}]})
        client = api.DoItListClient("https://doitlist.example", "token", opener=opener)
        operations = [
            {
                "op": "update",
                "type": "task",
                "id": 12,
                "data": {"done": True},
            }
        ]
        client.apply(operations, "sync-commit-abc123")
        self.assertEqual(opener.request.method, "POST")
        self.assertEqual(
            opener.request.get_header("Idempotency-key"),
            "sync-commit-abc123",
        )
        self.assertEqual(json.loads(opener.request.data), {"operations": operations})

    def test_idempotency_key_rejects_controls_and_excess_length(self):
        with self.assertRaises(api.ClientError):
            api.validate_idempotency_key("bad\nkey")
        with self.assertRaises(api.ClientError):
            api.validate_idempotency_key("x" * 256)

    def test_operation_input_accepts_array_or_exact_envelope(self):
        operations = [
            {
                "op": "update",
                "type": "task",
                "id": 1,
                "data": {"done": True},
            }
        ]
        for value in (operations, {"operations": operations}):
            with tempfile.NamedTemporaryFile(
                "w", encoding="utf-8", delete=False
            ) as handle:
                json.dump(value, handle)
                path = handle.name
            try:
                self.assertEqual(api.load_operations(path), operations)
            finally:
                os.unlink(path)

    def test_dry_run_needs_no_token_and_does_not_write(self):
        parser = api.build_parser()
        args = parser.parse_args(
            [
                "complete-task",
                "42",
                "--done",
                "--idempotency-key",
                "complete-42-abc",
                "--dry-run",
            ]
        )
        old_stdout = api.sys.stdout
        api.sys.stdout = io.StringIO()
        try:
            api.run(args)
            text = api.sys.stdout.getvalue()
        finally:
            api.sys.stdout = old_stdout
        self.assertIn("# dry-run: 1 operations locally valid", text)
        self.assertIn("complete-42-abc", text)
        self.assertNotIn('"op"', text)

    def test_dry_run_full_echoes_operations(self):
        parser = api.build_parser()
        args = parser.parse_args(
            ["complete-task", "42", "--done", "--idempotency-key", "k", "--dry-run", "--full"]
        )
        old_stdout = api.sys.stdout
        api.sys.stdout = io.StringIO()
        try:
            api.run(args)
            result = json.loads(api.sys.stdout.getvalue())
        finally:
            api.sys.stdout = old_stdout
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["operations"][0]["id"], 42)


def sample_tree() -> dict:
    long_title = "9. " + "x" * 197
    return {
        "data": {
            "id": 68,
            "tasks": [
                {
                    "id": 1, "parent_id": None, "position": 0, "index": "1", "done": True,
                    "title": "Milestone 1: Done", "children": [
                        {"id": 11, "parent_id": 1, "position": 0, "index": "1.1", "done": True,
                         "title": "Arc 1", "children": []},
                    ],
                },
                {
                    "id": 2, "parent_id": None, "position": 1, "index": "2", "done": False,
                    "title": "Milestone 2: Open", "children": [
                        {"id": 21, "parent_id": 2, "position": 0, "index": "2.1", "done": False,
                         "title": "Arc 1", "children": [
                             {"id": 211, "parent_id": 21, "position": 0, "index": "2.1.1",
                              "done": True, "title": "done leaf", "children": []},
                             {"id": 212, "parent_id": 21, "position": 1, "index": "2.1.2",
                              "done": False, "title": long_title[:197] + "...",
                              "description": long_title + " tail", "children": []},
                         ]},
                        {"id": 22, "parent_id": 2, "position": 1, "index": "2.2", "done": False,
                         "title": "Arc 2", "children": []},
                    ],
                },
            ],
        }
    }


class TreeProjectionTests(unittest.TestCase):
    def rows(self, matches, open_only=False):
        tasks = sample_tree()["data"]["tasks"]
        return [(d, t["id"]) for d, t in api.select_tasks(tasks, matches, open_only)]

    def test_display_title_restores_overflow_from_description(self):
        task = sample_tree()["data"]["tasks"][1]["children"][0]["children"][1]
        self.assertTrue(task["title"].endswith("..."))
        self.assertTrue(api.display_title(task).endswith(" tail"))
        self.assertEqual(api.display_title({"title": "short", "description": "unrelated"}), "short")

    def test_subtree_matches_by_id_index_prefix_and_title_prefix(self):
        self.assertEqual(self.rows(["21"]), [(0, 21), (1, 211), (1, 212)])
        self.assertEqual(self.rows(["2."]), [(0, 2), (1, 21), (2, 211), (2, 212), (1, 22)])
        self.assertEqual(self.rows(["2.2"]), [(0, 22)])
        self.assertEqual(self.rows(["milestone 1"]), [(0, 1), (1, 11)])
        self.assertEqual(self.rows(["2.", "1."])[0], (0, 1))
        self.assertEqual(self.rows([]), [(0, 1), (1, 11), (0, 2), (1, 21), (2, 211), (2, 212), (1, 22)])
        self.assertEqual(self.rows(["nomatch"]), [])

    def test_open_only_drops_done_tasks(self):
        self.assertEqual(self.rows(["2."], open_only=True), [(0, 2), (1, 21), (2, 212), (1, 22)])
        self.assertEqual(self.rows([], open_only=True), [(0, 2), (1, 21), (2, 212), (1, 22)])

    def test_print_tree_saves_compact_json_and_prints_rows(self):
        parser = api.build_parser()
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "tree.json")
            args = parser.parse_args(["tree", "68", "--subtree", "2.1", "--out", out])
            old_stdout = api.sys.stdout
            api.sys.stdout = io.StringIO()
            try:
                api.print_tree(args, sample_tree())
                text = api.sys.stdout.getvalue()
            finally:
                api.sys.stdout = old_stdout
            lines = text.splitlines()
            self.assertTrue(lines[0].startswith("# initiative 68: 7 tasks, showing 3;"))
            self.assertEqual(lines[2].split("\t"), ["21", "2", "0", "[ ]", "Arc 1"])
            self.assertEqual(lines[3].split("\t")[:4], ["211", "21", "0", "[x]"])
            self.assertTrue(lines[4].endswith(" tail"))
            saved = json.loads(Path(out).read_text(encoding="utf-8"))
            self.assertEqual(saved["data"]["id"], 68)
            self.assertNotIn("\n", Path(out).read_text(encoding="utf-8"))

    def test_print_tree_unmatched_subtree_raises(self):
        parser = api.build_parser()
        with tempfile.TemporaryDirectory() as tmp:
            args = parser.parse_args(["tree", "68", "--subtree", "zzz", "--out", os.path.join(tmp, "t.json")])
            old_stdout = api.sys.stdout
            api.sys.stdout = io.StringIO()
            try:
                with self.assertRaises(api.ClientError):
                    api.print_tree(args, sample_tree())
            finally:
                api.sys.stdout = old_stdout


class ResultSummaryTests(unittest.TestCase):
    def test_print_results_summarizes_adds_and_errors(self):
        parser = api.build_parser()
        operations = [
            {"op": "add", "type": "task", "lid": "new-1", "data": {"title": "T"}},
            {"op": "update", "type": "task", "id": 5, "data": {"title": "U"}},
            {"op": "update", "type": "task", "id": 6, "data": {"title": "V"}},
        ]
        payload = {
            "results": [
                {"index": 0, "status": "ok", "data": {"id": 900}},
                {"index": 1, "status": "error", "error": {"code": "invalid", "message": "bad  title"}},
                {"index": 2, "status": "not_applied"},
            ]
        }
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "r.json")
            args = parser.parse_args(["apply", "--idempotency-key", "k/1", "--out", out])
            old_stdout = api.sys.stdout
            api.sys.stdout = io.StringIO()
            try:
                api.print_results(args, operations, payload, "k/1")
                text = api.sys.stdout.getvalue()
            finally:
                api.sys.stdout = old_stdout
            self.assertIn("# 3 results: error=1 not_applied=1 ok=1", text)
            self.assertIn("#0 add -> id 900 (lid new-1)", text)
            self.assertIn("#1 error update 5 invalid: bad title", text)
            self.assertIn("#2 not_applied update 6", text)
            self.assertEqual(json.loads(Path(out).read_text(encoding="utf-8")), payload)


if __name__ == "__main__":
    unittest.main()
