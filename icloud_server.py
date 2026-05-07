#!/usr/bin/env python3
# iCloud Search – local web server
# Serves index files and opens files via /open?path=...

import os, subprocess, urllib.parse
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

INDEX_DIR = Path.home() / ".icloud_index"
PORT = 8742

class Handler(SimpleHTTPRequestHandler):

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)

        if parsed.path == "/open":
            params = urllib.parse.parse_qs(parsed.query)
            path = params.get("path", [None])[0]

            if path and os.path.exists(path):
                subprocess.call(["open", path])
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(b"OK")
            else:
                self.send_response(404)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.end_headers()
                self.wfile.write(b"File not found")
            return

        # Everything else: serve files from INDEX_DIR
        super().do_GET()

    def log_message(self, format, *args):
        # Only log /open requests
        if "/open" in (args[0] if args else ""):
            print(f"[open] {args}")

if __name__ == "__main__":
    os.chdir(INDEX_DIR)
    print(f"Server running at http://127.0.0.1:{PORT}")
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
