#!/usr/bin/env python3
"""Local-only deterministic fixtures and tracker for independent-client tests.

prepare OUTPUT [--mib 16] creates original data and public/private torrent files.
tracker --port 18765 runs a loopback tracker without external dependencies.
Never contacts public trackers or modifies a torrent client's existing profile.
"""
import argparse
import hashlib
import http.server
import json
import pathlib
import socket
import struct
import threading
import time
import urllib.parse


def bencode(value):
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, str):
        value = value.encode()
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, list):
        return b"l" + b"".join(map(bencode, value)) + b"e"
    return b"d" + b"".join(bencode(k) + bencode(value[k]) for k in sorted(value)) + b"e"


def prepare(root, mib, port):
    root.mkdir(parents=True, exist_ok=True)
    seed = root / "seed"
    seed.mkdir(exist_ok=True)
    path = seed / "Torrenza-fixture.bin"
    if path.exists():
        raise SystemExit(f"Refusing to overwrite {path}")
    block = bytes(range(256)) * 4096
    with path.open("xb") as stream:
        for _ in range(mib):
            stream.write(block)
    hashes = []
    sha256 = hashlib.sha256()
    with path.open("rb") as stream:
        while piece := stream.read(256 * 1024):
            hashes.append(hashlib.sha1(piece).digest())
            sha256.update(piece)
    manifest = {"sha256": sha256.hexdigest(), "length": path.stat().st_size, "torrents": {}}
    for private in (False, True):
        info = {"name": path.name, "length": path.stat().st_size,
                "piece length": 256 * 1024, "pieces": b"".join(hashes)}
        if private:
            info["private"] = 1
        name = "private" if private else "public"
        metainfo = {"announce": f"http://127.0.0.1:{port}/announce", "info": info}
        (root / f"{name}.torrent").write_bytes(bencode(metainfo))
        manifest["torrents"][name] = hashlib.sha1(bencode(info)).hexdigest()
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest))


class Tracker(http.server.BaseHTTPRequestHandler):
    peers = {}
    lock = threading.Lock()

    def do_GET(self):
        params = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query,
                                      encoding="latin1")
        try:
            info_hash = params["info_hash"][0].encode("latin1")
            peer_id = params["peer_id"][0].encode("latin1")
            port = int(params["port"][0])
            left = int(params["left"][0])
            assert len(info_hash) == 20 and len(peer_id) == 20 and 0 < port < 65536
        except (KeyError, ValueError, AssertionError):
            self.send_error(400)
            return
        with self.lock:
            now = time.monotonic()
            swarm = self.peers.setdefault(info_hash, {})
            for key in list(swarm):
                if now - swarm[key][3] > 1800:
                    del swarm[key]
            if params.get("event", [""])[0] == "stopped":
                swarm.pop(peer_id, None)
            else:
                swarm[peer_id] = (self.client_address[0], port, left, now)
            peers = b"".join(socket.inet_aton(host) + struct.pack("!H", peer_port)
                             for key, (host, peer_port, _, _) in swarm.items() if key != peer_id)
            seeds = sum(entry[2] == 0 for entry in swarm.values())
            response = bencode({"interval": 10, "min interval": 5, "complete": seeds,
                                "incomplete": len(swarm) - seeds, "peers": peers})
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, fmt, *args):
        # Avoid printing raw announce URLs or peer identifiers.
        print(f"tracker {self.client_address[0]} {args[1] if len(args) > 1 else ''}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    fixture = sub.add_parser("prepare")
    fixture.add_argument("output", type=pathlib.Path)
    fixture.add_argument("--mib", type=int, default=16)
    fixture.add_argument("--port", type=int, default=18765)
    tracker = sub.add_parser("tracker")
    tracker.add_argument("--port", type=int, default=18765)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.output, args.mib, args.port)
    else:
        print(f"Local tracker: http://127.0.0.1:{args.port}/announce", flush=True)
        http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Tracker).serve_forever()
