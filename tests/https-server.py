"""TLS Git fixture. Credentials are generated at runtime, never logged."""
import base64
import hmac
import http.server
import os
from pathlib import Path
import ssl
import subprocess
import sys
from urllib.parse import urlsplit


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.serve_git()

    def do_POST(self):
        self.serve_git()

    def serve_git(self):
        url = urlsplit(self.path)
        if url.path.startswith('/other.git'):
            Path('/run/redirect-followed').touch()
            self.send_error(403)
            return
        if Path('/run/redirect-enabled').exists():
            self.send_response(302)
            self.send_header('Location', 'https://localhost/other.git/info/refs?service=git-upload-pack')
            self.end_headers()
            return
        token = Path('/run/server-token').read_text().strip()
        expected = 'Basic ' + base64.b64encode(('test-user:' + token).encode()).decode()
        if not hmac.compare_digest(self.headers.get('Authorization', ''), expected):
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="git-test"')
            self.end_headers()
            return
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        env = dict(os.environ, GIT_PROJECT_ROOT='/srv/git', GIT_HTTP_EXPORT_ALL='1',
                   REQUEST_METHOD=self.command, PATH_INFO=url.path,
                   QUERY_STRING=url.query, CONTENT_TYPE=self.headers.get('Content-Type', ''),
                   CONTENT_LENGTH=str(len(body)), REMOTE_USER='test-user',
                   SERVER_PROTOCOL='HTTP/1.1')
        result = subprocess.run([sys.argv[1]], input=body, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, env=env, check=True)
        headers, data = result.stdout.split(b'\r\n\r\n', 1)
        parsed = [line.decode().split(':', 1) for line in headers.split(b'\r\n')]
        status = next((int(v.strip().split()[0]) for k, v in parsed if k.lower() == 'status'), 200)
        self.send_response(status)
        for key, value in parsed:
            if key.lower() != 'status':
                self.send_header(key, value.strip())
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


server = http.server.ThreadingHTTPServer(('127.0.0.1', 443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain('/run/test-cert.pem', '/run/test-cert-key.pem')
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
