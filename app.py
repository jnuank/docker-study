#!/usr/bin/env python3
"""
Signal handling test for Docker CMD vs ENTRYPOINT comparison.
Simulates a Python ADK (Agent Development Kit) long-running process.
"""

import os
import signal
import sys
import time
import threading


def print_process_info():
    pid = os.getpid()
    ppid = os.getppid()
    print(f"[INFO] PID={pid}, PPID={ppid}", flush=True)
    if pid == 1:
        print("[INFO] Running as PID 1 (init process) - SIGTERM will be received directly", flush=True)
    else:
        print("[INFO] NOT running as PID 1 - SIGTERM may NOT reach this process", flush=True)


def sigterm_handler(signum, frame):
    print(f"\n[SIGNAL] *** SIGTERM received! (PID={os.getpid()}) ***", flush=True)
    print("[SIGNAL] Graceful shutdown initiated (simulating ADK cleanup)", flush=True)
    # Simulate ADK cleanup (e.g., finishing ongoing LLM calls, flushing state)
    time.sleep(0.5)
    print("[SIGNAL] Cleanup complete. Exiting.", flush=True)
    sys.exit(0)


def sigint_handler(signum, frame):
    print(f"\n[SIGNAL] SIGINT received (PID={os.getpid()})", flush=True)
    sys.exit(0)


def simulate_adk_work():
    """Simulate ADK agent doing work (LLM calls, tool use, etc.)"""
    step = 0
    while True:
        step += 1
        print(f"[ADK]  step={step} agent working... (PID={os.getpid()})", flush=True)
        time.sleep(3)


def main():
    print("=" * 60, flush=True)
    print("[START] Python ADK Signal Handling Test", flush=True)
    print_process_info()

    # Register signal handlers
    signal.signal(signal.SIGTERM, sigterm_handler)
    signal.signal(signal.SIGINT, sigint_handler)
    print("[INFO] Signal handlers registered (SIGTERM, SIGINT)", flush=True)
    print("=" * 60, flush=True)

    # Run ADK simulation in main thread
    try:
        simulate_adk_work()
    except SystemExit:
        raise
    except Exception as e:
        print(f"[ERROR] {e}", flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
