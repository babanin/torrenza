#!/usr/bin/env python3
"""Controlled, local-only download benchmark for a built TorrentProbe.

Uses generated data, a private tracker and independent Python protocol peers.
Every requested block becomes available after --latency-ms; responses pipeline
independently, modelling delay rather than a serialized upload rate limit.
The exclusive output directory contains the torrent, probe log and JSON result.
No personal profile, public discovery, or third-party dependency is used.
"""
import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import time

sys.dont_write_bytecode = True
from interop_fixture import bencode


def message(kind, payload=b""):
    return struct.pack("!I", len(payload) + 1) + bytes([kind]) + payload


async def benchmark(args):
    args.output.mkdir(parents=True, exist_ok=False)
    size = args.mib * 1024 * 1024
    piece_size = 1024 * 1024
    piece = bytes(range(256)) * (piece_size // 256)
    sha = hashlib.sha256()
    for _ in range(args.mib):
        sha.update(piece)
    info = {"name": "fixture.bin", "length": size, "piece length": piece_size,
            "pieces": hashlib.sha1(piece).digest() * args.mib, "private": 1}
    info_hash = hashlib.sha1(bencode(info)).digest()
    stats = {"requests": 0, "outstanding": 0, "peakOutstanding": 0,
             "peakPerPeerOutstanding": 0, "connections": 0, "peakConnections": 0,
             "payloadBytes": 0, "firstRequest": None, "lastResponse": None}

    async def peer(reader, writer):
        pending = set()
        peer_pending = 0
        counted = False
        try:
            handshake = await reader.readexactly(68)
            if handshake[28:48] != info_hash:
                return
            reserved = bytearray(8)
            reserved[5] = 0x10
            writer.write(b"\x13BitTorrent protocol" + reserved + info_hash + b"-PYTEST-123456789012")
            bitfield = bytearray((args.mib + 7) // 8)
            for index in range(args.mib):
                bitfield[index // 8] |= 0x80 >> (index % 8)
            writer.write(message(5, bitfield))
            writer.write(message(20, b"\x00" + bencode({"m": {}, "reqq": args.reqq})))
            writer.write(message(1))
            await writer.drain()
            stats["connections"] += 1
            counted = True
            stats["peakConnections"] = max(stats["connections"], stats["peakConnections"])

            async def respond(index, begin, length):
                nonlocal peer_pending
                released = False
                try:
                    await asyncio.sleep(args.latency_ms / 1000)
                    writer.write(message(7, struct.pack("!II", index, begin) + piece[begin:begin + length]))
                    # Mark the response sent before yielding: the client may read
                    # it and replenish while drain waits for transport capacity.
                    stats["outstanding"] -= 1
                    peer_pending -= 1
                    released = True
                    stats["lastResponse"] = time.monotonic()
                    stats["payloadBytes"] += length
                    await writer.drain()
                finally:
                    if not released:
                        stats["outstanding"] -= 1
                        peer_pending -= 1

            while True:
                length, = struct.unpack("!I", await reader.readexactly(4))
                if length == 0:
                    continue
                frame = await reader.readexactly(length)
                if frame[0] != 6:
                    continue
                index, begin, length = struct.unpack("!III", frame[1:])
                assert 0 <= index < args.mib and 0 <= begin < piece_size
                assert 0 < length <= 16384 and begin + length <= piece_size
                stats["firstRequest"] = stats["firstRequest"] or time.monotonic()
                stats["requests"] += 1
                stats["outstanding"] += 1
                peer_pending += 1
                stats["peakOutstanding"] = max(stats["peakOutstanding"], stats["outstanding"])
                stats["peakPerPeerOutstanding"] = max(stats["peakPerPeerOutstanding"], peer_pending)
                task = asyncio.create_task(respond(index, begin, length))
                pending.add(task)
                task.add_done_callback(pending.discard)
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            if counted:
                stats["connections"] -= 1
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass

    servers = [await asyncio.start_server(peer, "127.0.0.1", 0) for _ in range(args.peers)]
    compact = b"".join(b"\x7f\x00\x00\x01" + struct.pack("!H", server.sockets[0].getsockname()[1])
                       for server in servers)

    async def tracker(reader, writer):
        try:
            await reader.readuntil(b"\r\n\r\n")
            body = bencode({"interval": 1800, "complete": args.peers, "incomplete": 1, "peers": compact})
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: "
                         + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
            await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()

    tracker_server = await asyncio.start_server(tracker, "127.0.0.1", 0)
    tracker_port = tracker_server.sockets[0].getsockname()[1]
    torrent = args.output / "fixture.torrent"
    torrent.write_bytes(bencode({"announce": f"http://127.0.0.1:{tracker_port}/announce", "info": info}))
    environment = os.environ.copy()
    environment["TORRENZA_PROBE_SETTINGS"] = args.settings
    start = time.monotonic()
    process = await asyncio.create_subprocess_exec(str(args.probe.resolve()), "download", str(torrent),
                str(args.output / "download"), str(args.output / "state"), str(args.timeout),
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT, env=environment)
    try:
        output, _ = await asyncio.wait_for(process.communicate(), args.timeout + 15)
    except TimeoutError:
        process.kill()
        output, _ = await process.communicate()
        raise RuntimeError("Probe timed out: " + output.decode(errors="replace"))
    elapsed = time.monotonic() - start
    text = output.decode(errors="replace")
    (args.output / "probe.log").write_text(text)
    downloaded = args.output / "download" / "fixture.bin"
    actual_sha = None
    if downloaded.exists():
        with downloaded.open("rb") as payload:
            actual_sha = hashlib.file_digest(payload, "sha256").hexdigest()
    diagnostics = [json.loads(line.removeprefix("DIAGNOSTICS ")) for line in text.splitlines()
                   if line.startswith("DIAGNOSTICS ")]
    shutdown = [json.loads(line.removeprefix("SHUTDOWN_DIAGNOSTICS ")) for line in text.splitlines()
                if line.startswith("SHUTDOWN_DIAGNOSTICS ")]
    payload_seconds = ((stats["lastResponse"] - stats["firstRequest"])
                       if stats["lastResponse"] and stats["firstRequest"] else None)
    result = {"label": args.label, "probe": str(args.probe.resolve()), "mib": args.mib,
              "peers": args.peers, "responseDelayMilliseconds": args.latency_ms, "remoteReqq": args.reqq,
              "settings": json.loads(args.settings), "probeExit": process.returncode,
              "wallSeconds": elapsed, "wallMiBPerSecond": args.mib / elapsed,
              "payloadSeconds": payload_seconds,
              "payloadMiBPerSecond": args.mib / payload_seconds if payload_seconds else None,
              "sha256": actual_sha, "expectedSHA256": sha.hexdigest(), "hashMatches": actual_sha == sha.hexdigest(),
              "server": stats, "sampledEnginePeakOutstandingRequests": max((d["outstandingRequests"] for d in diagnostics), default=None),
              "sampledEnginePeakConnections": max((d["admittedConnections"] for d in diagnostics), default=None),
              "budgetHighWaterBytes": max((d["budgetHighWaterMark"] for d in diagnostics), default=None),
              "budgetLimitBytes": max((d["budgetLimit"] for d in diagnostics), default=None),
              "shutdownDiagnostics": shutdown[-1] if shutdown else None}
    (args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    for server in servers + [tracker_server]:
        server.close()
        await server.wait_closed()
    if process.returncode or not result["hashMatches"]:
        raise SystemExit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("probe", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--label", default="benchmark")
    parser.add_argument("--mib", type=int, default=64)
    parser.add_argument("--peers", type=int, default=2)
    parser.add_argument("--latency-ms", type=float, default=50)
    parser.add_argument("--reqq", type=int, default=128)
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--settings", default="{}")
    args = parser.parse_args()
    if args.mib <= 0 or args.peers <= 0 or args.latency_ms < 0 or args.reqq <= 0:
        parser.error("Size, peers and reqq must be positive; latency must be nonnegative")
    asyncio.run(benchmark(args))
