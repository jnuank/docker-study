#!/usr/bin/env python3
"""
Docker CMD vs ENTRYPOINT のシグナルハンドリング検証。
Python 稼働プロセスをシミュレートする。
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
        print("[INFO] PID 1（initプロセス）として起動中 - SIGTERM は直接このプロセスに届く", flush=True)
    else:
        print("[INFO] PID 1 ではない - SIGTERM がこのプロセスに届かない可能性がある", flush=True)


def sigterm_handler(signum, frame):
    print(f"\n[SIGNAL] *** SIGTERM を受信！ (PID={os.getpid()}) ***", flush=True)
    print("[SIGNAL] グレースフルシャットダウン開始（クリーンアップをシミュレート）", flush=True)
    # クリーンアップをシミュレート（例: 実行中のLLM呼び出しの完了、状態のフラッシュ）
    time.sleep(5.5)
    print("[SIGNAL] クリーンアップ完了。終了します。", flush=True)
    sys.exit(0)


def sigint_handler(signum, frame):
    print(f"\n[SIGNAL] SIGINT を受信 (PID={os.getpid()})", flush=True)
    sys.exit(0)


def simulate_adk_work():
    """エージェントの作業をシミュレート（LLM呼び出し、ツール使用など）"""
    step = 0
    while True:
        step += 1
        print(f"[INFO] step={step} 処理中... (PID={os.getpid()})", flush=True)
        time.sleep(3)


def main():
    print("=" * 60, flush=True)
    print("[START] Python シグナルハンドリングテスト", flush=True)
    print_process_info()

    # シグナルハンドラを登録
    signal.signal(signal.SIGTERM, sigterm_handler)
    signal.signal(signal.SIGINT, sigint_handler)
    print("[INFO] シグナルハンドラ登録済み（SIGTERM, SIGINT）", flush=True)
    print("=" * 60, flush=True)

    # シミュレーションをメインスレッドで実行
    try:
        simulate_adk_work()
    except SystemExit:
        raise
    except Exception as e:
        print(f"[ERROR] {e}", flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
