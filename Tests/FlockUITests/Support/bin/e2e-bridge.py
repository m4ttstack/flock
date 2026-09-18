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
    <token> control seed-worktree-group
    <token> control fault-proxy-start
    <token> control fault-proxy-arm-subscription-cut
    <token> control fault-proxy-report
    <token> control fault-proxy-recording
    <token> ping

Control replies are {"ok": true} or {"error": {"message": ...}}. A verb whose
helper produces ids carries them as {"ok": true, "result": {...}}.

The token gates the port because `herdr` forwards arbitrary requests, and
`workspace.create` with a cwd is a PTY running a shell: an untokened listener
would be execution as whoever is running the suite, for any local account.
"""

import argparse
import hmac
import json
import os
import secrets
import select
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
# The token gates requests, not connections, and a worker thread is committed
# before the first line arrives. A short deadline on the socket itself is what
# stops an unauthenticated connection from parking one. It bounds the socket
# operations only, never the work between them, so a control verb still gets
# its full HELPER_TIMEOUT_SECONDS.
CONNECTION_TIMEOUT_SECONDS = 10


class FaultProxy:
    """A unix socket the app under test is pointed at in place of herdr's own,
    so ONE of the app's connections can be cut at a chosen point in its
    bootstrap, and so every request the app makes can be recorded. Nothing an
    outside process can do reaches a single socket a running app holds:
    stopping the server takes every connection at once, which is a different
    failure, and herdr's own socket keeps no record of who asked it what.

    Only the app goes through it. The ground-truth channel (`herdr <line>`)
    talks to the session socket directly, so a fault armed here changes what
    the app sees and nothing else, and the recording is the app's traffic
    alone rather than the traffic of the case reading up on it.
    """

    # The store's blanket subscription carries this id (`subscribeRequestLine`
    # in HerdrStore.swift). Every pane-scoped subscription uses the same
    # `events.subscribe` method, so the id is the only thing that tells the one
    # connection the session model rides from the per-pane feeds.
    STORE_SUBSCRIBE_ID = "flock:subscribe"

    # Held between cutting the subscription and forwarding the snapshot request
    # that triggered the cut, so the app has read the end of its subscription
    # before the snapshot it is waiting on can answer. That ordering is the
    # window this exists to reproduce: a store that only learns of the death
    # through a stream it has not switched to yet forgets it outright.
    CUT_SETTLE_SECONDS = 0.25

    # A recorded line is kept whole up to this, and truncated past it with its
    # true length carried beside it. Every verb a drop sends answers well
    # inside it (a `pane.move` reply carries two layouts and runs about 1.5KB);
    # `session.snapshot` does not, and nothing asserts on one.
    MAX_RECORDED_LINE = 4096

    # The app resnapshots on a timer and exports a layout per tab, so a case
    # that dwells records steadily. Past this the recording stops growing and
    # counts what it refused, which is honest about a truncated tail in a way
    # that dropping the oldest entries would not be.
    MAX_RECORDED_EXCHANGES = 400

    def __init__(self, upstream_path, listen_path):
        self.upstream_path = upstream_path
        self.listen_path = listen_path
        self.lock = threading.Lock()
        self.armed = False
        self.cuts = 0
        self.subscriptions = []
        self.listener = None
        self.exchanges = []
        self.dropped = 0
        self.epoch = time.monotonic()

    def start(self):
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            os.unlink(self.listen_path)
        except OSError:
            pass
        listener.bind(self.listen_path)
        listener.listen(128)
        self.listener = listener
        threading.Thread(target=self._accept_loop, args=(listener,), daemon=True).start()

    def arm_subscription_cut(self):
        with self.lock:
            self.armed = True

    def report(self):
        with self.lock:
            return {"armed": self.armed, "cuts": self.cuts, "subscriptions": len(self.subscriptions)}

    def clear_recording(self):
        """Called when a case starts the proxy, so what it reads back is its
        own app's traffic: one bridge process serves a whole `xcodebuild test`
        invocation, and the proxy outlives the app that was launched against
        it."""
        with self.lock:
            self.exchanges = []
            self.dropped = 0
            self.epoch = time.monotonic()

    def recording(self):
        with self.lock:
            return {"exchanges": [dict(entry) for entry in self.exchanges], "dropped": self.dropped}

    def _elapsed_ms(self):
        return round((time.monotonic() - self.epoch) * 1000, 1)

    def _record_request(self, line, request):
        """Returns the entry this connection fills the reply into, or None once
        the recording is full. `request` is the decoded line when it decoded:
        the pane bridges the app spawns are pointed at this same socket and
        their traffic is not JSON-RPC, so a line that is not a request is
        recorded with no method rather than dropped."""
        text, truncated, length = self._cap(line)
        entry = {
            "n": None,
            "method": request.get("method") if isinstance(request, dict) else None,
            "id": request.get("id") if isinstance(request, dict) else None,
            "request": text,
            "requestTruncated": truncated,
            "requestBytes": length,
            "requestAt": self._elapsed_ms(),
            "reply": None,
            "replyTruncated": False,
            "replyBytes": 0,
            "replyAt": None,
        }
        with self.lock:
            if len(self.exchanges) >= self.MAX_RECORDED_EXCHANGES:
                self.dropped += 1
                return None
            entry["n"] = len(self.exchanges)
            self.exchanges.append(entry)
        return entry

    def _record_reply(self, entry, line):
        text, truncated, length = self._cap(line)
        with self.lock:
            entry["reply"] = text
            entry["replyTruncated"] = truncated
            entry["replyBytes"] = length
            entry["replyAt"] = self._elapsed_ms()

    @classmethod
    def _cap(cls, line):
        text = line.decode("utf-8", "replace")
        if len(text) <= cls.MAX_RECORDED_LINE:
            return text, False, len(text)
        return text[: cls.MAX_RECORDED_LINE], True, len(text)

    def _accept_loop(self, listener):
        while True:
            try:
                client, _ = listener.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(client,), daemon=True).start()

    def _serve(self, client):
        upstream = None
        registered = False
        try:
            first, rest = self._read_first_line(client)
            if first is None:
                return
            try:
                request = json.loads(first.decode("utf-8", "replace"))
            except ValueError:
                request = {}
            # Before the request is forwarded, never after: a cut that landed
            # while the reply was already on its way back would be the ordinary
            # post-bootstrap death instead.
            if request.get("method") == "session.snapshot":
                self._cut_subscription()
            # Recorded before the forward, so the order the entries carry is
            # the order the app sent them in rather than the order herdr got
            # round to answering them.
            entry = self._record_request(first, request)
            upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            upstream.connect(self.upstream_path)
            upstream.sendall(first + b"\n" + rest)
            if request.get("id") == self.STORE_SUBSCRIBE_ID:
                with self.lock:
                    self.subscriptions.append((client, upstream))
                registered = True
            self._pump(client, upstream, entry)
        except OSError:
            pass
        finally:
            if registered:
                with self.lock:
                    self.subscriptions = [pair for pair in self.subscriptions if pair[0] is not client]
            for end in (client, upstream):
                if end is not None:
                    try:
                        end.close()
                    except OSError:
                        pass

    def _cut_subscription(self):
        with self.lock:
            if not self.armed or not self.subscriptions:
                return
            pairs = list(self.subscriptions)
            self.armed = False
            self.cuts += len(pairs)
        # `shutdown`, not `close`: the connection's own thread is parked in
        # select() on these, and only a shutdown both wakes it and hands the
        # app the end-of-stream it has to notice.
        for pair in pairs:
            for end in pair:
                try:
                    end.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        time.sleep(self.CUT_SETTLE_SECONDS)

    @staticmethod
    def _read_first_line(client):
        buffered = b""
        while b"\n" not in buffered:
            try:
                chunk = client.recv(65536)
            except OSError:
                return None, b""
            if not chunk:
                return None, b""
            buffered += chunk
        line, _, rest = buffered.partition(b"\n")
        return line, rest

    def _pump(self, client, upstream, entry=None):
        """Relays both ways, and records the FIRST line coming back as the
        reply to the request this connection opened with.

        The first line only: herdr answers one request per connection, so
        everything after it belongs to a stream rather than to the request.
        The subscription's event firehose and a pane bridge's terminal output
        both ride connections that opened with a request, and recording those
        would be an unbounded log of a session's whole output.

        A reply is recorded as it passes through, so a client that hangs up
        without reading its answer leaves the entry with none: the app always
        reads its own, but a hand-driven probe piped into `head` does not, and
        an unanswered entry there is the probe's doing rather than herdr's.
        """
        ends = [client, upstream]
        pending = b"" if entry is not None else None
        while True:
            try:
                readable, _, _ = select.select(ends, [], [])
            except (OSError, ValueError):
                return
            for source in readable:
                target = upstream if source is client else client
                try:
                    chunk = source.recv(65536)
                except OSError:
                    return
                if not chunk:
                    return
                if pending is not None and source is upstream:
                    pending += chunk
                    line, separator, _ = pending.partition(b"\n")
                    if separator:
                        self._record_reply(entry, line)
                        pending = None
                    elif len(pending) > self.MAX_RECORDED_LINE:
                        # A reply that never ends is not a reply. Recorded as
                        # far as it got so the entry says what arrived rather
                        # than reading as a request nothing answered.
                        self._record_reply(entry, pending)
                        pending = None
                try:
                    target.sendall(chunk)
                except OSError:
                    return


class Bridge:
    def __init__(self, socket_path, lib_dir, session_name, herdr_bin, work_dir, token):
        self.socket_path = socket_path
        self.lib_dir = lib_dir
        self.session_name = session_name
        self.herdr_bin = herdr_bin
        self.work_dir = work_dir
        # Compared as bytes: compare_digest raises TypeError on a str holding
        # any non-ASCII character, which a caller controls outright.
        self.token_bytes = token.encode("ascii")
        # Serialized because a control verb tears the server down and back up,
        # which any herdr request overlapping it would see as a dead socket.
        # Held across the work only, never across the reply write: a client
        # that sends and then stops reading would otherwise block every other
        # request until its connection timed out.
        self.lock = threading.Lock()
        self.fault_proxy = None

    def authorized(self, presented):
        return hmac.compare_digest(presented.encode("utf-8", "replace"), self.token_bytes)

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
        if verb == "seed-worktree-group":
            return self.run_helper(
                "seed-worktree-group.sh", [self.socket_path, self.work_dir], capture=True
            )
        if verb == "fault-proxy-start":
            return self.start_fault_proxy()
        if verb == "fault-proxy-arm-subscription-cut":
            if self.fault_proxy is None:
                return json.dumps({"error": {"message": "no fault proxy is running; start one first"}})
            self.fault_proxy.arm_subscription_cut()
            return json.dumps({"ok": True})
        if verb == "fault-proxy-report":
            if self.fault_proxy is None:
                return json.dumps({"error": {"message": "no fault proxy is running; start one first"}})
            return json.dumps({"ok": True, "result": self.fault_proxy.report()})
        if verb == "fault-proxy-recording":
            if self.fault_proxy is None:
                return json.dumps({"error": {"message": "no fault proxy is running; start one first"}})
            return json.dumps({"ok": True, "result": self.fault_proxy.recording()})
        return json.dumps({"error": {"message": "unknown control verb: %s" % verb[:40]}})

    def start_fault_proxy(self):
        """Idempotent: a second call hands back the socket the first one bound,
        so a case that starts one after another has left theirs running still
        gets a proxy pointed at this run's session. It always clears the
        recording, since the caller is about to launch its own app through
        it and the previous case's traffic is not its evidence."""
        if self.fault_proxy is None:
            # Named for the run's own session, and only 7 characters past that
            # name: `Scripts/e2e.sh` sweeps this run's processes by matching
            # that name in argv and environment, and a pane bridge the app
            # launches against this path carries the path in place of the
            # session socket. sun_path is 104 bytes including its terminator.
            path = os.path.join(self.work_dir, "flock-%s-p.sock" % self.session_name)
            if len(path) > 100:
                return json.dumps({"error": {"message": "fault proxy path too long for a unix socket: %s" % path}})
            proxy = FaultProxy(self.socket_path, path)
            try:
                proxy.start()
            except OSError as error:
                return json.dumps({"error": {"message": "fault proxy could not bind %s: %s" % (path, error)}})
            self.fault_proxy = proxy
        self.fault_proxy.clear_recording()
        return json.dumps({"ok": True, "result": {"socket": self.fault_proxy.listen_path}})

    def reseed(self):
        stopped = self.run_helper("scratch-session.sh", ["stop", self.session_name])
        if "error" in json.loads(stopped):
            return stopped
        started = self.run_helper("scratch-session.sh", ["start", self.session_name])
        if "error" in json.loads(started):
            return started
        return self.run_helper("seed-layout.sh", [self.socket_path])

    def run_helper(self, script, argv, capture=False):
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
        if not capture:
            return json.dumps({"ok": True})
        try:
            return json.dumps({"ok": True, "result": json.loads(completed.stdout)})
        except ValueError as error:
            return json.dumps({"error": {"message": "%s printed no ids (%s): %s" % (script, error, completed.stdout.strip()[:300])}})


class Handler(socketserver.StreamRequestHandler):
    timeout = CONNECTION_TIMEOUT_SECONDS

    def handle(self):
        try:
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
        except Exception as error:  # noqa: BLE001 - the reply IS the report
            reply = json.dumps({"error": {"message": "bridge handler: %r" % (error,)}})
        try:
            self.wfile.write((reply + "\n").encode("utf-8"))
        except OSError:
            pass


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
    parser.add_argument("--work-dir", required=True)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--parent-pid", required=True, type=int)
    args = parser.parse_args()

    token = secrets.token_hex(16)
    # Loopback only: the sandbox grants the runner outbound TCP, and nothing
    # off this machine has any business reaching a session's herdr socket.
    server = Server(("127.0.0.1", 0), Handler)
    server.bridge = Bridge(args.socket, args.lib, args.session, args.herdr_bin, args.work_dir, token)
    port = server.server_address[1]

    handle = os.open(args.port_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(handle, "w") as port_file:
        port_file.write("%d %s\n" % (port, token))

    threading.Thread(target=watch_parent, args=(args.parent_pid, server), daemon=True).start()
    print("e2e-bridge: listening on 127.0.0.1:%d" % port, file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
