#!/usr/bin/env python3
"""A throwaway HTTP server for the end-to-end tests.

Serves a fixed status on every path (or the status named by the path, so
/503 answers 503) and prints the port it bound to on stdout, so the test does
not have to guess a free one.

It records the request methods it saw in a file named by $SEEN_METHODS, when
that is set, so a test can assert that --head actually sends HEAD rather than
trusting that the flag reached curl.
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SEEN = os.environ.get("SEEN_METHODS")


def record(method):
    if not SEEN:
        return
    with open(SEEN, "a") as fh:
        fh.write(method + "\n")


class Handler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        record("HEAD")
        # A HEAD response carries the headers of the GET and no body.
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", "3")
        self.end_headers()

    def do_GET(self):
        record("GET")
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


# Threaded, not the plain single-connection server: pulsecheck holds one
# keep-alive connection open for a whole batch of requests, and a test that
# kills it mid-flight can leave a single-threaded server blocked on the dead
# socket — so the *next* probe in the suite gets no response at all and looks
# like a bug in the program. That produced three "empty output" failures on one
# CI runner while the same tests passed on three others.
srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
srv.daemon_threads = True
print(srv.server_port, flush=True)
sys.stdout.close()
srv.serve_forever()
