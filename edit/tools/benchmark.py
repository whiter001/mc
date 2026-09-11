#!/usr/bin/env python3
"""Black-box large-file benchmark for the edit binary.

The benchmark drives the normal terminal UI over a pty, so it measures the
same file load, visible syntax highlighting, search, and save paths a user
exercises. It intentionally reports wall time and peak RSS instead of making
claims about internal allocation details.

Usage:
    python3 tools/benchmark.py [--sizes 1,4,16]

Sizes are MiB. The generated files are removed on exit. The output is a
tab-separated table suitable for attaching to a performance review.
"""
import argparse
import os
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "bin" / "edit"


def rss_kb(pid):
    try:
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)],
                                      stderr=subprocess.DEVNULL, text=True)
        return int(out.strip() or "0")
    except (OSError, ValueError, subprocess.CalledProcessError):
        return 0


class Session:
    def __init__(self, path):
        self.master, slave = pty.openpty()
        winsize = struct.pack("HHHH", 24, 120, 0, 0)
        termios.tcsetwinsz(slave, (24, 120)) if hasattr(termios, "tcsetwinsz") else \
            __import__("fcntl").ioctl(slave, termios.TIOCSWINSZ, winsize)
        self.proc = subprocess.Popen([str(BIN), str(path)], stdin=slave,
                                     stdout=slave, stderr=slave, close_fds=True)
        os.close(slave)
        self.peak_rss = 0

    def drain(self, quiet=0.08, cap=8.0):
        start = time.monotonic()
        last_output = start
        while time.monotonic() - start < cap:
            self.peak_rss = max(self.peak_rss, rss_kb(self.proc.pid))
            remaining = quiet - (time.monotonic() - last_output)
            if remaining <= 0:
                return
            wait = min(0.01, remaining)
            ready, _, _ = select.select([self.master], [], [], wait)
            if not ready:
                # A timeout is only one quiet-window slice. Keep sampling
                # until the full quiet interval has elapsed.
                continue
            try:
                os.read(self.master, 131072)
            except OSError:
                return
            last_output = time.monotonic()
        raise RuntimeError("editor did not become quiet within %.1fs" % cap)

    def stage(self, payload, quiet=0.08):
        began = time.monotonic()
        os.write(self.master, payload)
        self.drain(quiet=quiet)
        return time.monotonic() - began

    def close(self):
        if self.proc.poll() is None:
            try:
                # Escape clears any transient prompt/panel state before quit.
                os.write(self.master, b"\x1b")
                self.drain(quiet=0.15, cap=0.5)
                os.write(self.master, b"\x11")
            except OSError:
                pass
            deadline = time.monotonic() + 1
            while self.proc.poll() is None and time.monotonic() < deadline:
                try:
                    self.drain(quiet=0.10, cap=0.2)
                except (OSError, RuntimeError):
                    break
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
        self.proc.wait(timeout=5)
        os.close(self.master)


def make_fixture(path, size_mib):
    target = size_mib * 1024 * 1024
    line = b'fn sample() { let value = "syntax"; println!("{}", value); }\n'
    marker = b"BENCHMARK_TARGET_AT_END_9f2c1\n"
    with path.open("wb") as f:
        remaining = target - len(marker)
        while remaining > 0:
            chunk = line[:min(len(line), remaining)]
            f.write(chunk)
            remaining -= len(chunk)
        f.write(marker)


def run_case(path):
    session = Session(path)
    try:
        began = time.monotonic()
        session.drain()
        startup = time.monotonic() - began
        # Search for a marker at EOF to force a scan across the whole buffer.
        # Repeating F3 amplifies the scan enough to rise above pty scheduling
        # noise while preserving the normal search implementation.
        f3 = b"\x1b[13~"
        search = session.stage(b"\x06BENCHMARK_TARGET_AT_END_9f2c1" + f3 * 8)
        session.stage(b"\x1b", quiet=0.15)
        # Make one byte dirty, then save the existing file in place.
        save = session.stage(b"x\x13")
        return startup, search, save, session.peak_rss
    finally:
        session.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sizes", default="1,4,16",
                        help="comma-separated fixture sizes in MiB")
    args = parser.parse_args()
    sizes = [int(value) for value in args.sizes.split(",") if value]
    if not BIN.is_file():
        raise SystemExit("missing %s; run ./build.sh dev first" % BIN)
    with tempfile.TemporaryDirectory(prefix="edit-bench-") as temp:
        print("size_mib\tstartup_highlight_s\tsearch_s\tsave_s\tpeak_rss_mb")
        for size in sizes:
            path = Path(temp) / ("fixture-%d.rs" % size)
            make_fixture(path, size)
            startup, search, save, peak = run_case(path)
            print("%d\t%.3f\t%.3f\t%.3f\t%.1f" %
                  (size, startup, search, save, peak / 1024.0))


if __name__ == "__main__":
    main()
