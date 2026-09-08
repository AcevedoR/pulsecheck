#!/usr/bin/env python3
"""A throwaway HTTP server for the end-to-end test.

Serves a fixed status on every path (or the status named by the path, so
/503 answers 503) and prints the port it bound to on stdout, so the test does
not have to guess a free one.
"""
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            code = int(self.path.strip("/"))
        except ValueError:
            code = 200
        body = b"ok\n"
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


srv = HTTPServer(("127.0.0.1", 0), Handler)
print(srv.server_port, flush=True)
sys.stdout.close()
srv.serve_forever()
