#!/usr/bin/env python3
"""Pty smoke test for the V edit binary (quiescence-based).

Drives bin/edit over a pty. Stages are separated by '--' in the hex string;
after each stage we wait until the editor has been silent for 0.3s (max 3s),
which gives the 100ms ESC-timeout flush time to fire — the old fixed-sleep
version raced it.

Usage: smoke.py <file1:file2...> <keys-as-hex-with--separators>
Exit-code convention: prints '=== editor exit code: N' at the end.
"""
import os, pty, select, subprocess, sys, time

BIN = '/Volumes/Extreme/github2/mc/edit/bin/edit'


def main():
    paths = sys.argv[1].split(':')
    stages = [bytes.fromhex(s) for s in (sys.argv[2] if len(sys.argv) > 2 else '').split('--') if s]
    master, slave = pty.openpty()
    import fcntl, termios, struct
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    proc = subprocess.Popen([BIN] + [p for p in paths if p], stdin=slave, stdout=slave,
                            stderr=slave, close_fds=True)
    os.close(slave)
    out = b''

    def drain(quiesce=0.3, cap=3.0):
        """Read until no output for `quiesce` seconds (or `cap` total)."""
        nonlocal out
        start = time.time()
        while time.time() - start < cap:
            r, _, _ = select.select([master], [], [], quiesce)
            if not r:
                return
            try:
                chunk = os.read(master, 65536)
            except OSError:
                return
            if not chunk:
                return
            out += chunk
            start = time.time()

    drain()  # initial frame
    for stage in stages:
        try:
            os.write(master, stage)
        except OSError:
            # The editor may have exited between stages (e.g. the last
            # Ctrl+Q of a quit sequence), closing the pty before poll()
            # reaps it. Treat a dead pty as "editor gone" and stop.
            break
        drain()
        if proc.poll() is not None:
            break
    # Wait for exit after the last stage.
    deadline = time.time() + 5
    while proc.poll() is None and time.time() < deadline:
        drain(quiesce=0.2, cap=0.5)
    drain(quiesce=0.2, cap=1.0)  # final drain
    if proc.poll() is None:
        proc.kill()
        print('TIMEOUT: editor did not exit', file=sys.stderr)
    rc = proc.wait()
    sys.stdout.buffer.write(out)
    print('\n=== editor exit code:', rc)


if __name__ == '__main__':
    main()
