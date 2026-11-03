#!/bin/bash
# 開発の道具（App.DevTools のデスクトップの組）の smoke: テンプレを隠しウィンドウの DEBUG で起こし、
# 名簿（~/.flix_ge_studio/games.json）に載る・命令口が /help・/halt・/step・/resume・/perf に答える・flow の記録ができる・
# 閉じたら名簿から消える、を 1 回ずつ確かめる。make test と flow は App.Headless を通り、実機の launch と loop をほとんど通らない。
# 使い方: bin/smoke-devtools.sh [テンプレの名前（既定 rpg-starter）]。先に make sync-engine-full。
# WhyNot: DEBUG_HTTP_PORT を渡さない — 渡さない起動だけが空いたポートを自分で取って名簿に書くので、名簿と命令口を 1 回で確かめられる。
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=${1:-rpg-starter}
cd "$ROOT/templates/$T" || exit 2
REG=$HOME/.flix_ge_studio/games.json
DIR=$(pwd -P)
LOG=build/smoke-devtools.log
mkdir -p build
FAIL=0
tree() { local p=$1; echo "$p"; for c in $(pgrep -P "$p"); do tree "$c"; done; }
stopall() { local ps; ps=$(tree "$1"); kill -TERM $ps 2>/dev/null; sleep 5; kill -KILL $ps 2>/dev/null; }
portOf() {
  python3 -c "
import json
try:
  for g in json.load(open('$REG')).get('games', []):
    if g['dir'] == '$DIR': print(g['port']); break
except Exception: pass"
}
expect() { # 名前 期待する頭 実際
  case "$3" in "$2"*) echo "[smoke-devtools] ok   $1";; *) echo "[smoke-devtools] FAIL $1: $(printf '%s' "$3" | head -2)"; FAIL=1;; esac
}
rm -f debug/flow-record/latest.flow
DEBUG=1 FLIX_GE_HIDDEN=1 make run RUN_SECONDS=300 > "$LOG" 2>&1 &
PID=$!
PORT=""
for _ in $(seq 1 240); do PORT=$(portOf); [ -n "$PORT" ] && break; sleep 1; done
if [ -z "$PORT" ]; then echo "[smoke-devtools] FAIL 名簿に載らない（${LOG}）"; stopall $PID; exit 1; fi
echo "[smoke-devtools] ok   名簿に載った（port ${PORT}）"
U=http://127.0.0.1:$PORT
expect "/help" "remote debug protocol" "$(curl -s -m 20 $U/help)"
expect "/halt" "ok mode=halted" "$(curl -s -m 20 -X POST $U/halt)"
expect "/step" "ok stepped=" "$(curl -s -m 60 -X POST $U/step --data-binary $'wait 5\n')"
expect "/resume" "ok mode=running" "$(curl -s -m 20 -X POST $U/resume)"
sleep 1
expect "/perf" "ok perf" "$(curl -s -m 120 -X POST "$U/perf?last=10" --data-binary $'wait 10\n')"
if [ -s debug/flow-record/latest.flow ]; then echo "[smoke-devtools] ok   flow の記録（debug/flow-record/latest.flow）"; else echo "[smoke-devtools] FAIL flow の記録が無い"; FAIL=1; fi
stopall $PID
wait $PID 2>/dev/null
if [ -z "$(portOf)" ]; then echo "[smoke-devtools] ok   閉じたら名簿から消えた"; else echo "[smoke-devtools] FAIL 閉じても名簿に残る"; FAIL=1; fi
exit $FAIL
