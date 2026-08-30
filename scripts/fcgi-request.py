#!/usr/bin/env python3
"""Client FastCGI minimal.

Execute un script PHP dans un conteneur php-fpm sans passer par nginx et sans
shell dans l'image (elle est FROM scratch), et sans dependance : la
bibliotheque standard suffit, la ou cgi-fcgi imposerait un paquet a installer
ou un conteneur jetable de plus.

Sert au harnais de tests (scripts/test.sh) comme au diagnostic d'un pod en
production, ou c'est le seul moyen d'executer du code depuis que le CLI php
n'est plus embarque.

Usage :
    fcgi-request.py <host> <port> <script_filename> [query_string]
    fcgi-request.py <host> 9000 /status          # page d'etat de php-fpm
"""
import socket, struct, sys

FCGI_BEGIN, FCGI_PARAMS, FCGI_STDIN, FCGI_STDOUT, FCGI_STDERR, FCGI_END = 1, 4, 5, 6, 7, 3

def rec(t, content=b"", rid=1):
    return struct.pack("!BBHHBB", 1, t, rid, len(content), 0, 0) + content

def enc(name, value):
    out = b""
    for s in (name.encode(), value.encode()):
        out += struct.pack("!I", len(s) | 0x80000000) if len(s) > 127 else bytes([len(s)])
    return out + name.encode() + value.encode()

host, port, script = sys.argv[1], int(sys.argv[2]), sys.argv[3]
qs = sys.argv[4] if len(sys.argv) > 4 else ""
params = {
    "GATEWAY_INTERFACE": "FastCGI/1.0", "REQUEST_METHOD": "GET",
    # SCRIPT_NAME doit etre relatif a DOCUMENT_ROOT : php-hardened.ini fixe
    # doc_root=/var/www/html, et le SAPI CGI recompose alors le chemin en
    # doc_root + SCRIPT_NAME. Un SCRIPT_NAME absolu donne
    # /var/www/html/var/www/html/... -> "No input file specified".
    "SCRIPT_FILENAME": script,
    "SCRIPT_NAME": script[len("/var/www/html"):] if script.startswith("/var/www/html") else script,
    "QUERY_STRING": qs, "REQUEST_URI": script + ("?" + qs if qs else ""),
    "DOCUMENT_ROOT": "/var/www/html", "SERVER_PROTOCOL": "HTTP/1.1",
    "SERVER_SOFTWARE": "fcgi.py", "REMOTE_ADDR": "127.0.0.1",
    "SERVER_NAME": "localhost", "SERVER_PORT": "80", "CONTENT_LENGTH": "0",
}
s = socket.create_connection((host, port), timeout=60)
s.sendall(rec(FCGI_BEGIN, struct.pack("!HB5s", 1, 0, b"\0" * 5)))
body = b"".join(enc(k, v) for k, v in params.items())
s.sendall(rec(FCGI_PARAMS, body) + rec(FCGI_PARAMS) + rec(FCGI_STDIN))
out, err = b"", b""
while True:
    head = s.recv(8)
    if len(head) < 8:
        break
    _, t, _, clen, plen, _ = struct.unpack("!BBHHBB", head)
    data = b""
    while len(data) < clen + plen:
        chunk = s.recv(clen + plen - len(data))
        if not chunk:
            break
        data += chunk
    data = data[:clen]
    if t == FCGI_STDOUT:
        out += data
    elif t == FCGI_STDERR:
        err += data
    elif t == FCGI_END:
        break
s.close()
sys.stdout.write(out.decode("utf-8", "replace"))
if err:
    sys.stderr.write("--- STDERR ---\n" + err.decode("utf-8", "replace"))
