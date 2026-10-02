#!/usr/bin/env python3
"""Drop UID/GID before exec when a minimal userland has no runuser/setpriv."""
import os
import pwd
import sys


def execute(uid: int, gid: int, command: list[str]) -> None:
    if not (0 < uid < 2**32 - 1 and 0 <= gid < 2**32 - 1) or not command:
        raise ValueError('valid non-root owner and command are required')
    try:
        name = pwd.getpwuid(uid).pw_name
    except KeyError:
        name = None
    if name:
        os.initgroups(name, gid)
    else:
        os.setgroups([])
    os.setgid(gid)
    os.setuid(uid)
    os.execvp(command[0], command)


if __name__ == '__main__':
    execute(int(sys.argv[1]), int(sys.argv[2]), sys.argv[3:])
