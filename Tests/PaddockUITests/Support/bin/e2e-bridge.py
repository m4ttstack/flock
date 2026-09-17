#!/usr/bin/env python3
"""Loopback TCP front end for the herdr session an e2e run is driving.

Xcode's macOS UI-test runner is App Sandboxed, and that sandbox denies
connect() on any unix socket outside the runner's container: both `nc -U` and a
native AF_UNIX connect come back EPERM. It does permit outbound TCP to
loopback. herdr listens on a unix socket only, so this process is how the test
bundle reaches it, and it also performs the two session operations no sandboxed
process can perform for itself.

One request per connection, one line each way, mirroring herdr's own socket
contract. Requests:

    herdr <json line>     forward to the session socket, return its reply line
    control restart-server
    control reseed-session
    ping

Control replies are {"ok": true} or {"error": {"message": ...}}.
"""

import argparse
import json
import os
import socket
import socketserver
import subprocess
import sys
import threading


class Bridge:
    def __init__(self, socket_path, lib_dir, session_name, herdr_bin):
        self.socket_path = socket_path
        self.lib_dir = lib_dir
        self.session_name = session_name
        self.herdr_bin = herdr_bin
        # Serialized because a control verb tears the server down and back up,
        # which any herdr request overlapping it would see as a dead socket.
        self.lock = threading.Lock()

    def handle(self, request):
        if request == "ping":
            return json.dumps({"ok": True})
        if request.startswith("herdr "):
            return self.forward(request[len("herdr "):])
        if request.startswith("control "):
            return self.control(request[len("control "):])
        return json.dumps({"error": {"message": "unknown bridge request: %s" % request[:80]}})

    def forward(self, line):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(10)
                client.connect(self.socket_path)
                client.sendall((line.rstrip("\n") + "\n").encode("utf-8"))
                chunks = []
                while b"\n" not in b"".join(chunks):
                    chunk = client.recv(65536)
                    if not chunk:
                        break
                    chunks.append(chunk)
        except OSError as error:
            return json.dumps({"error": {"message": "herdr socket %s: %s" % (self.socket_path, error)}})
        payload = b"".join(chunks).decode("utf-8", "replace")
        first = payload.split("\n", 1)[0]
        if not first:
            return json.dumps({"error": {"message": "herdr closed the connection without answering"}})
        return first

    def control(self, verb):
        if verb == "restart-server":
            argv = ["restart", self.session_name]
        elif verb == "reseed-session":
            return self.reseed()
        else:
            return json.dumps({"error": {"message": "unknown control verb: %s" % verb[:40]}})
        return self.run_helper("scratch-session.sh", argv)

    def reseed(self):
        stopped = self.run_helper("scratch-session.sh", ["stop", self.session_name])
        if "error" in json.loads(stopped):
            return stopped
        started = self.run_helper("scratch-session.sh", ["start", self.session_name])
        if "error" in json.loads(started):
            return started
        return self.run_helper("seed-layout.sh", [self.socket_path])

    def run_helper(self, script, argv):
        try:
            completed = subprocess.run(
                ["/bin/bash", "%s/%s" % (self.lib_dir, script)] + argv,
                capture_output=True, text=True, timeout=120,
                env={"HOME": os.environ["HOME"],
                     "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                     "HERDR_BIN": self.herdr_bin},
            )
        except (OSError, subprocess.SubprocessError) as error:
            return json.dumps({"error": {"message": "%s: %s" % (script, error)}})
        if completed.returncode != 0:
            return json.dumps({"error": {"message": "%s exit %d: %s" % (script, completed.returncode, completed.stderr.strip()[:300])}})
        return json.dumps({"ok": True})


class Handler(socketserver.StreamRequestHandler):
    timeout = 180

    def handle(self):
        line = self.rfile.readline()
        if not line:
            return
        request = line.decode("utf-8", "replace").strip()
        with self.server.bridge.lock:
            reply = self.server.bridge.handle(request)
        self.wfile.write((reply + "\n").encode("utf-8"))


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--lib", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--herdr-bin", required=True)
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()

    # Loopback only: the sandbox grants the runner outbound TCP, and nothing
    # off this machine has any business reaching a session's herdr socket.
    server = Server(("127.0.0.1", 0), Handler)
    server.bridge = Bridge(args.socket, args.lib, args.session, args.herdr_bin)
    port = server.server_address[1]
    with open(args.port_file, "w") as handle:
        handle.write("%d\n" % port)
    print("e2e-bridge: listening on 127.0.0.1:%d" % port, file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
