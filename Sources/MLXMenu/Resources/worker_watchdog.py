#!/usr/bin/python3
"""Run a local worker and terminate its process group when MLX Menu disappears."""
import os, signal, subprocess, sys, time

if len(sys.argv) < 4:
    raise SystemExit("usage: worker_watchdog.py <parent-pid> <executable> [args...]")
parent = int(sys.argv[1])
child = subprocess.Popen(sys.argv[2:], start_new_session=True)

def terminate(*_):
    if child.poll() is None:
        try: os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        try: child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try: os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError: pass
    raise SystemExit(child.returncode or 0)

signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)
while child.poll() is None:
    try: os.kill(parent, 0)
    except (ProcessLookupError, PermissionError): terminate()
    if os.getppid() != parent: terminate()
    time.sleep(0.2)
raise SystemExit(child.returncode)
