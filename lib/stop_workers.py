"""Stop this run's worker trees before deleting their private staging.

GNU timeout creates process groups of its own, so killing just worker PIDs or
process groups leaves producers alive. Freeze parents before discovering children
and kill leaves first. Collection is read-only and cancellation publishes nothing.
"""

import os
from pathlib import Path
import signal
import sys
import time


def namespace_pid(proc):
    # /proc can be mounted from an ancestor PID namespace (e.g. a container).
    # Never send a signal to a procfs PID without translating it to our namespace.
    if os.readlink(proc / "ns/pid") != os.readlink("/proc/self/ns/pid"):
        return None
    fields = dict(line.split(":", 1) for line in (proc / "status").read_text().splitlines())
    return int(fields.get("NSpid", fields["Pid"]).split()[-1])


def worker_paths(pids):
    wanted = set(pids)
    found = {}
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit():
            continue
        try:
            pid = namespace_pid(proc)
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        if pid in wanted:
            found[pid] = proc
    for pid in wanted - found.keys():
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        raise RuntimeError(f'cannot inspect live worker {pid} through /proc')
    return found


def stop_tree(proc, pid):
    try:
        os.kill(pid, signal.SIGSTOP)
        # Ensure a parent cannot fork between child discovery and termination.
        deadline = time.monotonic() + 1
        while True:
            state = next(line for line in (proc / 'status').read_text().splitlines()
                         if line.startswith('State:')).split()[1]
            if state in ('T', 't', 'Z', 'X'):
                break
            if time.monotonic() > deadline:
                raise RuntimeError(f'worker {pid} did not stop')
            time.sleep(0.001)
        # PPid is available even on kernels without CONFIG_CHECKPOINT_RESTORE
        # (which controls /proc/PID/task/TID/children).
        for child_proc in Path('/proc').iterdir():
            if not child_proc.name.isdigit():
                continue
            try:
                fields = dict(line.split(':', 1) for line in
                              (child_proc / 'status').read_text().splitlines())
                if int(fields['PPid']) != int(proc.name):
                    continue
                child_pid = namespace_pid(child_proc)
                if child_pid is not None:
                    stop_tree(child_proc, child_pid)
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                continue
        os.kill(pid, signal.SIGKILL)
    except (FileNotFoundError, ProcessLookupError):
        return


if __name__ == '__main__':
    paths = worker_paths([int(x) for x in sys.argv[1:]])
    for worker, proc in paths.items():
        stop_tree(proc, worker)
