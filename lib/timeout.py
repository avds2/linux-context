#!/usr/bin/env python3
"""Linux/Python timeout fallback for BusyBox userlands or missing coreutils.

Use a new process group, a monotonic deadline, and TERM/KILL escalation. The
command inherits its output pipes so the runner's existing byte cap still applies.
"""
from __future__ import annotations

import os
import select
import signal
import subprocess
import sys
import time
from pathlib import Path


def signal_group(pid: int, sig: int) -> None:
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass


def run(seconds: float, command: list[str], tree: bool = False, quiet: bool = False) -> int:
    if seconds <= 0 or not command:
        raise ValueError('positive timeout and a command are required')
    try:
        process = subprocess.Popen(command, start_new_session=True,
                                   stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL if quiet else None,
                                   stderr=subprocess.DEVNULL if quiet else None)
    except FileNotFoundError:
        return 127
    except PermissionError:
        return 126

    interrupted = 0

    def on_signal(sig, _frame):
        nonlocal interrupted
        interrupted = sig

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, on_signal)
    deadline = time.monotonic() + seconds
    timed_out = False
    pidfd = None
    if hasattr(os, 'pidfd_open'):
        try:
            pidfd = os.pidfd_open(process.pid)
        except OSError:
            pass
    try:
        while process.poll() is None:
            if interrupted or time.monotonic() >= deadline:
                timed_out = not interrupted
                if tree:
                    # Collectors nest timeout groups. Freeze/stop their complete
                    # process tree BEFORE killing the parent, so descendants
                    # cannot be reparented and continue writing staging.
                    from stop_workers import worker_paths, stop_tree
                    for pid, path in worker_paths([process.pid]).items():
                        stop_tree(path, pid)
                    process.wait()
                    break
                signal_group(process.pid, signal.SIGTERM)
                # The group can outlive its leader. Always KILL the remaining
                # group at the end of the grace period, even if the leader exits.
                grace = time.monotonic() + 2
                while time.monotonic() < grace:
                    try:
                        os.killpg(process.pid, 0)
                    except ProcessLookupError:
                        break
                    process.poll()
                    time.sleep(0.01)
                signal_group(process.pid, signal.SIGKILL)
                process.wait()
                break
            remaining = max(0, deadline - time.monotonic())
            if pidfd is not None:
                # Wake immediately when the process exits on newer kernels,
                # instead of adding a polling interval to every short probe.
                select.select([pidfd], [], [], min(0.1, remaining))
            else:
                time.sleep(min(0.002, remaining))
    finally:
        # A shell may exit while asynchronous descendants keep inherited output
        # pipes open. No probe is allowed to leave those producers behind.
        signal_group(process.pid, signal.SIGKILL)
        if process.poll() is None:
            process.wait()
        if pidfd is not None:
            os.close(pidfd)
    if interrupted:
        return 128 + interrupted
    if timed_out:
        return 124
    return process.returncode if process.returncode >= 0 else 128 - process.returncode


if __name__ == '__main__':
    args = sys.argv[1:]
    if args[0] == '--collector':
        command, seconds, status_path = args[1:]
        # Detection and acquisition share one supervisor/interpreter startup,
        # but each has its own deadline and full-tree termination boundary.
        detected = run(5, [command, '--detect'], tree=True, quiet=True)
        if detected:
            Path(status_path).write_text(f'detect {detected}\n', encoding='ascii')
            raise SystemExit(69)
        collected = run(float(seconds), [command, '--run'], tree=True)
        # An internal supervisor exception never leaves a successful-looking
        # status marker; publication must fail rather than mislabel it partial.
        Path(status_path).write_text(f'run {collected}\n', encoding='ascii')
        raise SystemExit(collected)
    tree = args[0] == '--tree'
    if tree:
        args = args[1:]
    raise SystemExit(run(float(args[0]), args[1:], tree=tree))
