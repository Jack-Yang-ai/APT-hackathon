import http.server
import json
import threading
import unittest
from unittest.mock import patch

import auth
import fetch


def serve(handler_cls):
    server = http.server.HTTPServer(('127.0.0.1', 0), handler_cls)
    server.seen = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.seen.append((self.path, self.headers.get('Authorization')))
        self.reply()


class RequestRedirectTests(unittest.TestCase):
    def setUp(self):
        class Target(Handler):
            def reply(self):
                body = json.dumps({'ok': True}).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.target = serve(Target)
        target_url = 'http://127.0.0.1:%d/stolen' % self.target.server_port

        class Redirector(Handler):
            def reply(self):
                self.send_response(302)
                self.send_header('Location', target_url)
                self.send_header('Content-Length', '0')
                self.end_headers()

        self.redirector = serve(Redirector)
        for s in (self.target, self.redirector):
            self.addCleanup(s.server_close)
            self.addCleanup(s.shutdown)
        self.addCleanup(patch.stopall)
        patch('auth.ensure_fresh', return_value={'access_token': 'secret-token'}).start()
        patch('auth.refresh', side_effect=AssertionError('302 不应触发令牌刷新')).start()

    def test_redirect_is_refused_and_token_not_forwarded(self):
        with patch('auth.API_BASE', 'http://127.0.0.1:%d' % self.redirector.server_port):
            with self.assertRaises(fetch.APIError) as cm:
                fetch.request('/v1/daily', {'limit': 1})
        self.assertEqual(cm.exception.error, 'http_302')
        self.assertEqual(self.redirector.seen, [('/v1/daily?limit=1', 'Bearer secret-token')])
        self.assertEqual(self.target.seen, [])

    def test_direct_request_still_works(self):
        with patch('auth.API_BASE', 'http://127.0.0.1:%d' % self.target.server_port):
            self.assertEqual(fetch.request('/v1/daily', {}), {'ok': True})
        self.assertEqual(self.target.seen, [('/v1/daily', 'Bearer secret-token')])


if __name__ == '__main__':
    unittest.main()
