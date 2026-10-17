"""Mac抽取心跳协议攻击回归；不联网、不写正式内容。"""
import io
import json
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import urlopen
from unittest.mock import patch

from mac import extract_daemon as daemon


class Response(io.BytesIO):
    def __init__(self, frames, content_type="application/x-ndjson"):
        super().__init__(frames)
        self.headers = {"Content-Type": content_type}


def frame(value):
    return json.dumps(value, ensure_ascii=False).encode() + b"\n"


def parse(raw):
    return daemon._read_proxy_response(Response(raw), time.monotonic() + 10)


def rejects(raw):
    try:
        parse(raw)
    except (RuntimeError, ValueError, UnicodeError):
        return
    raise AssertionError("accepted corrupt or failed stream")


def test_complete_and_legacy():
    body = {"content": "完整中文", "model": "step-5-preview"}
    assert parse(frame({"type": "ping"}) + frame({"type": "result", "status": 200, "body": body})) == body
    legacy = Response(json.dumps(body).encode(), "application/json")
    assert daemon._read_proxy_response(legacy, time.monotonic() + 10) == body


def test_truncated_malformed_and_failure():
    for raw in (b"", frame({"type": "ping"}), b'{"type":"result"}', b"[]\n", b"\xff\n",
                frame({"type": "unknown"}), frame({"type": "result", "status": "200", "body": {}}),
                frame({"type": "result", "status": True, "body": {}}),
                frame({"type": "result", "status": 502, "body": {"error": "truncated"}}),
                b"x" * (2 * 1024 * 1024 + 1) + b"\n"):
        rejects(raw)


def test_heartbeat_count_and_deadline():
    rejects(frame({"type": "ping"}) * 128)
    try:
        daemon._read_proxy_response(Response(frame({"type": "ping"})), time.monotonic() - 1)
    except TimeoutError:
        pass
    else:
        raise AssertionError("deadline ignored")


def test_real_call_negotiates_and_rejects_false_success():
    def open_fake(request, timeout):
        assert request.get_header("Accept") == "application/x-ndjson"
        assert timeout == 900
        assert json.loads(request.data)["provider"] == "deepseek-flash"
        return Response(frame({"type": "result", "status": 502, "body": {"error": "upstream failed"}}))
    with patch.dict("os.environ", {"GROWTH_CLIENT_TOKEN": "test"}), patch("urllib.request.urlopen", open_fake):
        try:
            daemon._call_proxy("test", 900, provider="deepseek-flash")
        except RuntimeError as error:
            assert "502" in str(error)
        else:
            raise AssertionError("transport 200 hid logical 502")


def test_stalled_socket_obeys_remaining_deadline():
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.end_headers()
            self.wfile.write(frame({"type": "ping"})); self.wfile.flush()
            time.sleep(1)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    try:
        with urlopen(f"http://127.0.0.1:{server.server_port}/", timeout=900) as response:
            start = time.monotonic()
            try:
                daemon._read_proxy_response(response, start + 0.1)
            except (TimeoutError, socket.timeout):
                assert time.monotonic() - start < 0.5
            else:
                raise AssertionError("stalled read ignored total deadline")
    finally:
        server.shutdown(); server.server_close(); thread.join()


if __name__ == "__main__":
    tests = [test_complete_and_legacy, test_truncated_malformed_and_failure,
             test_heartbeat_count_and_deadline, test_real_call_negotiates_and_rejects_false_success,
             test_stalled_socket_obeys_remaining_deadline]
    for test in tests:
        test()
        print("PASS", test.__name__)
    print(f"all passed ({len(tests)})")
