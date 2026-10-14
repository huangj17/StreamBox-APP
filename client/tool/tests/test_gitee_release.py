import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch
from urllib.error import HTTPError
from urllib.parse import parse_qs


spec = importlib.util.spec_from_file_location(
    "gitee_sync", Path(__file__).resolve().parents[1] / "sync_gitee_release.py",
)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class GiteeReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.metadata = {
            "tagName": "v0.4.0", "name": "Version 0.4.0", "body": "发布说明",
            "isPrerelease": True, "isDraft": False,
        }
        self.write_metadata()
        self.apk = self.directory / "StreamBox-v0.4.0-android.apk"
        self.apk.write_bytes(b"signed-apk-fixture")

    def write_metadata(self):
        (self.directory / "release.json").write_text(json.dumps(self.metadata))

    def test_create_preserves_release_metadata_and_original_apk(self):
        api = MagicMock()
        api.request.side_effect = [None, {"id": 12}, {"id": 100}]
        api.attachments.return_value = []
        sync.synchronize(api, self.directory)
        create = api.request.call_args_list[1]
        self.assertEqual(create.args[:2], ("POST", "/releases"))
        self.assertEqual(create.args[2]["body"], "发布说明")
        self.assertEqual(create.args[2]["target_commitish"], "v0.4.0")
        self.assertEqual(create.args[2]["prerelease"], "true")
        self.assertEqual(api.request.call_args.kwargs["file"].read_bytes(), b"signed-apk-fixture")

    def test_rerun_replaces_only_same_name_attachment(self):
        api = MagicMock()
        api.request.return_value = {"id": 12}
        api.attachments.return_value = [
            {"id": 3, "name": self.apk.name}, {"id": 4, "name": "desktop.zip"},
        ]
        sync.synchronize(api, self.directory)
        deleted = [call.args[1] for call in api.request.call_args_list if call.args[0] == "DELETE"]
        self.assertEqual(deleted, ["/releases/12/attach_files/3"])
        self.assertEqual(api.request.call_args.args[0], "POST")

    def test_draft_and_missing_apk_fail_before_modifying_gitee(self):
        api = MagicMock()
        self.metadata["isDraft"] = True
        self.write_metadata()
        with self.assertRaisesRegex(ValueError, "Draft"):
            sync.synchronize(api, self.directory)
        self.metadata["isDraft"] = False
        self.write_metadata()
        self.apk.unlink()
        with self.assertRaisesRegex(ValueError, "No APK"):
            sync.synchronize(api, self.directory)
        api.request.assert_not_called()

    def test_documented_form_token(self):
        api = sync.GiteeAPI("owner/repo", "private-token")
        with patch.object(sync, "urlopen") as open_request:
            open_request.return_value.__enter__.return_value.read.return_value = b'{"id": 12}'
            api.request("POST", "/releases", {"body": "发布说明"})
            request = open_request.call_args.args[0]
            fields = parse_qs(request.data.decode())
            self.assertEqual(fields["access_token"], ["private-token"])
            self.assertEqual(fields["body"], ["发布说明"])
    def serve(self, handler):
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def stop():
            server.shutdown()
            server.server_close()
            thread.join()
        self.addCleanup(stop)
        return f"http://127.0.0.1:{server.server_port}"

    def test_curl_sends_original_bytes_and_form_token(self):
        received = []
        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            def do_POST(self):
                received.append(self.rfile.read(int(self.headers["Content-Length"])))
                response = b'{"id": 42}'
                self.send_response(201)
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)
            def log_message(self, *args):
                pass
        api = sync.GiteeAPI("owner/repo", "private-token")
        api.base = self.serve(Handler)
        self.assertEqual(api.request("POST", "/upload", file=self.apk), {"id": 42})
        self.assertIn(b'name="access_token"', received[0])
        self.assertIn(b"private-token", received[0])
        self.assertIn(b'name="file"', received[0])
        self.assertIn(self.apk.read_bytes(), received[0])

    def test_curl_handles_rejection_before_sending_file(self):
        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            def handle_expect_100(self):
                self.send_error(403, "private-token not allowed")
                return False
            def log_message(self, *args):
                pass
        api = sync.GiteeAPI("owner/repo", "private-token")
        api.base = self.serve(Handler)
        with self.assertRaisesRegex(RuntimeError, "HTTP 403") as caught:
            api.request("POST", "/upload", file=self.apk)
        self.assertNotIn("private-token", str(caught.exception))

    def test_http_failure_does_not_expose_token_and_only_404_means_missing(self):
        api = sync.GiteeAPI("owner/repo", "private-token")
        for status in (401, 403, 422, 500):
            error = HTTPError("https://gitee.com/?access_token=private-token", status, "error", {}, io.BytesIO())
            with patch.object(sync, "urlopen", side_effect=error):
                with self.assertRaises(RuntimeError) as caught:
                    api.request("GET", "/releases/tags/v1", allow_missing=True)
            self.assertNotIn("private-token", str(caught.exception))
            self.assertIn(str(status), str(caught.exception))
        error = HTTPError("https://gitee.com/", 404, "missing", {}, io.BytesIO())
        with patch.object(sync, "urlopen", side_effect=error):
            self.assertIsNone(api.request("GET", "/releases/tags/v1", allow_missing=True))

    def test_attachment_listing_paginates(self):
        api = sync.GiteeAPI("owner/repo", "private-token")
        with patch.object(api, "request", side_effect=[[{"id": i} for i in range(100)], [{"id": 101}]]) as request:
            self.assertEqual(len(api.attachments(12)), 101)
            self.assertEqual(request.call_args.args[2]["page"], 2)


if __name__ == "__main__":
    unittest.main()
