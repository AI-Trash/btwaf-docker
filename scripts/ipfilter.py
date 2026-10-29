#!/usr/bin/env python3
import os
import signal
import socket
import sys
import threading

SOCK_PATH = "/www/cloud_waf/nginx/conf.d/ip_filter.sock"
NGINX_HOST = os.environ.get("NGINX_HOST", "cloudwaf_nginx")
NGINX_INTERNAL_PORT = int(os.environ.get("NGINX_INTERNAL_PORT", "10251"))


def cleanup(*args):
    if os.path.exists(SOCK_PATH):
        try:
            os.unlink(SOCK_PATH)
        except OSError:
            pass
    sys.exit(0)


signal.signal(signal.SIGTERM, cleanup)
signal.signal(signal.SIGINT, cleanup)


def pipe(src, dst):
    try:
        while True:
            data = src.recv(16384)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        for sock in (src, dst):
            try:
                sock.close()
            except Exception:
                pass


def handle_loopback_bridge(client_sock):
    try:
        upstream = socket.create_connection((NGINX_HOST, NGINX_INTERNAL_PORT), timeout=5)
        threading.Thread(target=pipe, args=(client_sock, upstream), daemon=True).start()
        threading.Thread(target=pipe, args=(upstream, client_sock), daemon=True).start()
    except Exception:
        try:
            client_sock.close()
        except Exception:
            pass


def serve_loopback_bridge():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.251", 80))
    srv.listen(128)
    while True:
        try:
            client_sock, _ = srv.accept()
            threading.Thread(target=handle_loopback_bridge, args=(client_sock,), daemon=True).start()
        except Exception:
            pass


threading.Thread(target=serve_loopback_bridge, daemon=True).start()

if os.path.exists(SOCK_PATH):
    try:
        os.unlink(SOCK_PATH)
    except OSError:
        pass

os.makedirs(os.path.dirname(SOCK_PATH), exist_ok=True)
unix_srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
unix_srv.bind(SOCK_PATH)
os.chmod(SOCK_PATH, 0o777)
unix_srv.listen(128)

while True:
    try:
        conn, _ = unix_srv.accept()
        conn.recv(1024)
        conn.sendall(b"1\n")
        conn.close()
    except Exception:
        pass
