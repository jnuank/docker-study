# Docker Signal Handling Test: CMD vs ENTRYPOINT

Python ADK が k8s の pod terminate シグナル（SIGTERM）を受け取れるかどうかの検証。

## 検証するパターン

| ファイル | 設定 | PID 1 | SIGTERM が Python に届くか |
|---|---|---|---|
| `Dockerfile.cmd-shell` | `CMD python app.py` | `/bin/sh` | **届かない** |
| `Dockerfile.cmd-exec` | `CMD ["python", "app.py"]` | `python` | **届く** |
| `Dockerfile.entrypoint` | `ENTRYPOINT ["python", "app.py"]` | `python` | **届く** |

## なぜ PID 1 が重要か

k8s が pod を terminate するとき、コンテナの **PID 1 に SIGTERM** を送る。

```
CMD python app.py          # shell form
→ Docker が実行: /bin/sh -c "python app.py"
→ PID 1: /bin/sh           ← SIGTERM はここに届く
→ PID N: python app.py     ← SIGTERM は届かない（sh が転送しない）
→ terminationGracePeriodSeconds 後に SIGKILL → 強制終了

CMD ["python", "app.py"]   # exec form
ENTRYPOINT ["python", "app.py"]  # exec form
→ Docker が実行: python app.py  (直接)
→ PID 1: python app.py     ← SIGTERM が直接届く → graceful shutdown 可能
```

## ファイル構成

```
.
├── app.py                  # シグナルハンドラ付き Python ADK シミュレーター
├── Dockerfile.cmd-shell    # CMD シェル形式（NG パターン）
├── Dockerfile.cmd-exec     # CMD exec 形式（OK パターン）
├── Dockerfile.entrypoint   # ENTRYPOINT exec 形式（OK パターン）
├── test.sh                 # 3パターンを自動テストするスクリプト
└── README.md
```

## 実行方法

```bash
# 全パターンを一括テスト
bash test.sh

# 個別に動かして確認
docker build -f Dockerfile.cmd-shell -t test-shell .
docker run --name test-shell-run -d test-shell

# 別ターミナルでログを確認
docker logs -f test-shell-run

# k8s のシグナルをシミュレート
docker stop --time=10 test-shell-run   # SIGTERM → 10秒後 SIGKILL

# クリーンアップ
docker rm -f test-shell-run
```

## 期待される出力

### CMD シェル形式（SIGTERM が届かないケース）

```
[START] Python ADK Signal Handling Test
[INFO] PID=7, PPID=1
[INFO] NOT running as PID 1 - SIGTERM may NOT reach this process
[INFO] Signal handlers registered (SIGTERM, SIGINT)
[ADK]  step=1 agent working... (PID=7)
[ADK]  step=2 agent working... (PID=7)
# ← SIGTERM が届かず、graceful shutdown なしで強制終了
```

### CMD exec 形式 / ENTRYPOINT（SIGTERM が届くケース）

```
[START] Python ADK Signal Handling Test
[INFO] PID=1, PPID=0
[INFO] Running as PID 1 (init process) - SIGTERM will be received directly
[INFO] Signal handlers registered (SIGTERM, SIGINT)
[ADK]  step=1 agent working... (PID=1)
[ADK]  step=2 agent working... (PID=1)

[SIGNAL] *** SIGTERM received! (PID=1) ***     ← k8s からのシグナルを受信
[SIGNAL] Graceful shutdown initiated (simulating ADK cleanup)
[SIGNAL] Cleanup complete. Exiting.
```

## k8s での実践的な注意点

- k8s の `terminationGracePeriodSeconds`（デフォルト 30秒）は PID 1 への SIGTERM 後のタイムアウト
- CMD シェル形式では graceful shutdown の機会がなく、**進行中の LLM 呼び出しが途中で切れる**
- Python ADK で graceful shutdown（チャット履歴の保存、接続のクローズ等）を確実にするには **exec 形式**を使うこと

### 推奨設定

```dockerfile
# NG: シェル形式
CMD python main.py

# OK: exec 形式
CMD ["python", "main.py"]
ENTRYPOINT ["python", "main.py"]
```
