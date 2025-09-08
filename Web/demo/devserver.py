#!/usr/bin/env python3
from http.server import SimpleHTTPRequestHandler, HTTPServer
import os

PORT = 8765
ROOT = os.path.dirname(__file__)

class Handler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        # serve from demo root
        rel = path.lstrip('/') or 'index.html'
        return os.path.join(ROOT, rel)

if __name__ == '__main__':
    print(f"Serving demo at http://127.0.0.1:{PORT}/")
    HTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
