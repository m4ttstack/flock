#!/usr/bin/env python3
"""Throwaway helper: spawn a child on a real pty with an explicit winsize.

This sandbox's own stdin is not a tty (`script -q` inherits a zero winsize
and herdr rejects it: "terminal reported a zero-sized grid"), so the normal
`script -q /dev/null <cmd>` recipe from the task brief does not work here
unmodified. This sets TIOCSWINSZ explicitly before exec.
"""
import fcntl
import os
import pty
import struct
import termios


def spawn(cmd, env, rows=24, cols=80):
    pid, master_fd = pty.fork()
    if pid == 0:
        # child
        winsz = struct.pack("HHHH", rows, cols, 0, 0)
        fcntl.ioctl(0, termios.TIOCSWINSZ, winsz)
        os.execvpe(cmd[0], cmd, env)
        os._exit(127)
    winsz = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(master_fd, termios.TIOCSWINSZ, winsz)
    return pid, master_fd


def alive(pid):
    try:
        wpid, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        return False
    return wpid == 0
