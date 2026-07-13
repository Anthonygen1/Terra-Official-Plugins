"""Minimal HTTP server for the Rixen Park Designer workload.

Serves the single-page WebGL app and persists obstacle layouts as JSON
at DATA_PATH (mounted PVC when dataPersistent is enabled).
Stdlib only — runs on a stock python:3-alpine image.
"""
import json
import os
import http.server
import socketserver

PORT = int(os.environ.get("PORT", "8080"))
DATA_PATH = os.environ.get("DATA_PATH", "/data/layout.json")
PAGE_PATH = os.environ.get("PAGE_PATH", "/app/rixen.html")

with open(PAGE_PATH, "rb") as f:
    PAGE = f.read()


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _is_api(self):
        return self.path.split("?", 1)[0].rstrip("/").endswith("/api/layout")

    def do_GET(self):
        if self._is_api():
            if os.path.exists(DATA_PATH):
                with open(DATA_PATH, "rb") as f:
                    self._send(200, f.read(), "application/json")
            else:
                self._send(404, b"{}", "application/json")
        else:
            self._send(200, PAGE, "text/html; charset=utf-8")

    def do_POST(self):
        if not self._is_api():
            return self._send(404, b"not found", "text/plain")
        length = int(self.headers.get("Content-Length", 0))
        if length > 65536:
            return self._send(413, b"payload too large", "text/plain")
        raw = self.rfile.read(length)
        try:
            json.loads(raw)
        except ValueError:
            return self._send(400, b"invalid json", "text/plain")
        tmp = DATA_PATH + ".tmp"
        with open(tmp, "wb") as f:
            f.write(raw)
        os.replace(tmp, DATA_PATH)
        self._send(200, b'{"ok":true}', "application/json")

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)


socketserver.ThreadingTCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(("0.0.0.0", PORT), Handler) as srv:
    print(f"rixen-park-designer serving on :{PORT}, layout at {DATA_PATH}", flush=True)
    srv.serve_forever()
