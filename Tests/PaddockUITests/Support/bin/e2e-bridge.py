#!/usr/bin/env python3
"""Loopback TCP front end for the herdr session an e2e run is driving.

Xcode's macOS UI-test runner is App Sandboxed, and that sandbox denies
connect() on any unix socket outside the runner's container: both `nc -U` and a
native AF_UNIX connect come back EPERM. It does permit outbound TCP to
loopback. herdr listens on a unix socket only, so this process is how the test
bundle reaches it, and it also performs the two session operations no sandboxed
process can perform for itself.

One request per connection, one line each way, mirroring herdr's own socket
contract. Every request begins with the token this process generated:

    <token> herdr <json line>     forward to the session socket, return its reply
    <token> control restart-server
    <token> control reseed-session
    <token> ping

Control replies are {"ok": true} or {"error": {"message": ...}}.

The token is not ceremony. A loopback port is not a secret (65k of them scan in
about a second), and `herdr` forwards arbitrary requests, one of which is
`workspace.create` with a cwd -- which is a PTY running a shell. Without the
token, any local account on a shared machine has execution as the user running
the tests, not merely the ability to disturb a scratch session.
"""

import argparse
import hmac
import json
import os
import secrets
import socket
import socketserver
import subprocess
import sys
import threading
import time

# Under the Swift client's own 60s receive timeout, so a helper that runs long
# surfaces as this process saying which helper it was rather than as the client
# giving up on the connection with nothing to report.
HELPER_TIMEOUT_SECONDS = 45
HERDR_TIMEOUT_SECONDS = 10


class Bridge:
    def __init__(self, socket_path, lib_dir, session_name, herdr_bin, token):
        self.socket_path = socket_path
        self.lib_dir = lib_dir
        self.session_name = session_name
        self.herdr_bin = herdr_bin
        self.token = token
        # Serialized because a control verb tears the server down and back up,
        # which any herdr request overlapping it would see as a dead socket.
        # Held across the work only, never across the reply write: a client
        # that sends and then stops reading would otherwise block every other
        # request until its connection timed out.
        self.lock = threading.Lock()

    def authorized(self, presented):
        return hmac.compare_digest(presented, self.token)

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
                client.settimeout(HERDR_TIMEOUT_SECONDS)
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
            return self.run_helper("scratch-session.sh", ["restart", self.session_name])
        if verb == "reseed-session":
            return self.reseed()
        return json.dumps({"error": {"message": "unknown control verb: %s" % verb[:40]}})

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
                capture_output=True, text=True, timeout=HELPER_TIMEOUT_SECONDS,
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
    timeout = 90

    def handle(self):
        line = self.rfile.readline()
        if not line:
            return
        token, _, request = line.decode("utf-8", "replace").strip().partition(" ")
        bridge = self.server.bridge
        if not bridge.authorized(token):
            reply = json.dumps({"error": {"message": "bad bridge token"}})
        else:
            with bridge.lock:
                reply = bridge.handle(request)
        self.wfile.write((reply + "\n").encode("utf-8"))


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def watch_parent(pid, server):
    """Ends this process when the wrapper that started it is gone.

    Without it a SIGKILL of the wrapper leaves an unauthenticated listener
    running indefinitely, against a session directory that no longer exists.
    """
    while True:
        time.sleep(1)
        try:
            os.kill(pid, 0)
        except OSError:
            server.shutdown()
            os._exit(0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--lib", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--herdr-bin", required=True)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--parent-pid", required=True, type=int)
    args = parser.parse_args()

    token = secrets.token_hex(16)
    # Loopback only: the sandbox grants the runner outbound TCP, and nothing
    # off this machine has any business reaching a session's herdr socket.
    server = Server(("127.0.0.1", 0), Handler)
    server.bridge = Bridge(args.socket, args.lib, args.session, args.herdr_bin, token)
    port = server.server_address[1]

    handle = os.open(args.port_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(handle, "w") as port_file:
        port_file.write("%d %s\n" % (port, token))

    threading.Thread(target=watch_parent, args=(args.parent_pid, server), daemon=True).start()
    print("e2e-bridge: listening on 127.0.0.1:%d" % port, file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
