#!/usr/bin/env python3
"""Test web server for MacPlayer link playback (self-test flow G8, 0.15): Range requests, HEAD, content types, and failing routes.
Usage: Scripts/link_test_server.py <files dir> <port>
The files dir holds clip.mp4, noext (a copy of clip.mp4), page.html, "sân bóng.jpg", hls/index.m3u8 (+ segments) and, for a live
stream, live/index.m3u8 written by ffmpeg (see docs/bao-cao-ban-giao.md, 0.15.0)."""
import os, sys, time, mimetypes, urllib.parse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

ROOT = sys.argv[1]
PORT = int(sys.argv[2])
TYPES = {".mp4": "video/mp4", ".m3u8": "application/vnd.apple.mpegurl", ".ts": "video/mp2t", ".jpg": "image/jpeg",
         ".png": "image/png", ".html": "text/html; charset=utf-8"}

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, fmt, *a):
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def route(self):
        path = urllib.parse.unquote(urllib.parse.urlparse(self.path).path)
        if path == "/missing.mp4": return ("status", 404)
        if path == "/forbidden.mp4": return ("status", 403)
        if path == "/headless.mp4": return ("nohead", os.path.join(ROOT, "clip.mp4"))
        if path == "/noext": return ("file", os.path.join(ROOT, "noext"), "video/mp4")
        if path == "/octet": return ("file", os.path.join(ROOT, "noext"), "application/octet-stream")
        if path == "/watch": return ("file", os.path.join(ROOT, "page.html"), "text/html; charset=utf-8")
        if path == "/fake.mp4": return ("file", os.path.join(ROOT, "page.html"), "text/html; charset=utf-8")
        if path == "/slow.mp4": return ("slow", os.path.join(ROOT, "clip.mp4"))
        if path == "/drop.mp4": return ("drop", os.path.join(ROOT, "clip.mp4"))
        if path == "/stall.mp4": return ("stall", os.path.join(ROOT, "clip.mp4"))
        f = os.path.normpath(os.path.join(ROOT, path.lstrip("/")))
        if not f.startswith(ROOT) or not os.path.isfile(f): return ("status", 404)
        return ("file", f, TYPES.get(os.path.splitext(f)[1].lower(), "application/octet-stream"))

    def do_HEAD(self): self.serve(head=True)
    def do_GET(self): self.serve(head=False)

    def status(self, code):
        body = b"error"
        self.send_response(code); self.send_header("Content-Type", "text/plain"); self.send_header("Content-Length", str(len(body))); self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)

    def serve(self, head):
        r = self.route()
        if r[0] == "status": return self.status(r[1])
        if r[0] == "nohead":
            if head: return self.status(405)
            r = ("file", r[1], "video/mp4")
        kind, f = r[0], r[1]
        ctype = r[2] if len(r) > 2 else "video/mp4"
        size = os.path.getsize(f)
        start, end = 0, size - 1
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            a, _, b = rng[6:].partition("-")
            start = int(a) if a else max(0, size - int(b))
            end = int(b) if (b and a) else size - 1
            end = min(end, size - 1)
            self.send_response(206); self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        else:
            self.send_response(200)
        self.send_header("Content-Type", ctype); self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1)); self.end_headers()
        if head: return
        if kind == "stall":
            # The first 300 KB of the file, then nothing more on any connection (a server that stops answering).
            if start == 0:
                with open(f, "rb") as fh:
                    try: self.wfile.write(fh.read(300000)); self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError): return
            time.sleep(120); self.close_connection = True; return
        with open(f, "rb") as fh:
            fh.seek(start); left = end - start + 1; sent = 0
            while left > 0:
                chunk = fh.read(min(65536, left))
                if not chunk: break
                if kind == "slow": time.sleep(0.05)
                if kind == "drop" and sent > 400000: self.close_connection = True; return
                try: self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError): return
                left -= len(chunk); sent += len(chunk)

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
