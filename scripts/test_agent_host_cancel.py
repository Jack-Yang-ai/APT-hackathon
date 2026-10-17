#!/usr/bin/env python3
"""A real native provider request cancelled by SIGTERM: one unknown-usage receipt, no UI/data."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

entered, release = threading.Event(), threading.Event()

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        assert self.headers['Authorization'] == 'Bearer fixture'
        entered.set()
        release.wait(10)
    def log_message(self, *args):
        pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory(prefix='apt-provider-cancel-') as folder:
    home = Path(folder)
    endpoint = f'http://127.0.0.1:{server.server_port}'
    request = dict(schema='apt.model.request/1', request_id='aaaaaaaa-1111-2222-3333-123456789abc', operation='text', scene='voice_polish',
                   system='fixture', prompt='fixture', background=False, deep_review=False, json=False, timeout=90, max_tokens=10,
                   language='auto', hotwords=[], route='plan', credential=dict(endpoint=endpoint, key='fixture'))
    env = {**os.environ, 'CFFIXED_USER_HOME': folder}
    # NSArgumentDomain isolates route settings even when cfprefsd caches the real suite.
    # Only a fixture URL/model go in argv; the fixture credential stays on stdin.
    process = subprocess.Popen([sys.argv[1], '--agent-answer', '-endpoint', endpoint, '-modelName', 'fixture'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    try:
        process.stdin.write(json.dumps(request).encode())
        process.stdin.close()
        if not entered.wait(10):
            process.kill() if process.poll() is None else None
            process.wait(timeout=5)
            raise AssertionError('native host did not reach isolated provider: '+process.stdout.read().decode(errors='replace')+' '+process.stderr.read().decode(errors='replace'))
        process.send_signal(signal.SIGTERM)
        process.wait(timeout=5)
        usage = home / 'Library/Application Support/EchoMemoryIME/Usage'
        rows = [json.loads(line) for file in usage.glob('*.jsonl') for line in file.read_text().splitlines()]
        assert len(rows) == 1 and rows[0]['scene'] == 'voice_polish' and rows[0]['error'] == 'cancelled', rows
        assert rows[0]['input'] is None and rows[0]['output'] is None and rows[0]['usd'] is None
        print('PASS: real native SIGTERM cancels provider and records exactly one receipt with unknown usage')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        release.set()
server.shutdown()
