#!/bin/bash
# usage: run-chrome.sh <url> <sink-file> [extra flags...]
URL=$1; SINK=$2; shift 2
D=$(mktemp -d /tmp/webgpu-spike-chrome.XXXXXX)
rm -f "$SINK"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --user-data-dir=$D --no-first-run --no-default-browser-check \
  --disable-extensions --disable-background-networking --mute-audio --hide-scrollbars \
  --disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows \
  --window-size=800,600 "$@" "$URL" > $D/chrome.log 2>&1 &
PID=$!
for i in $(seq 1 ${WAIT:-240}); do [ -s "$SINK" ] && break; sleep 1; done
kill $PID 2>/dev/null; sleep 1; pkill -P $PID 2>/dev/null; rm -rf $D
[ -s "$SINK" ] && echo got || echo timeout
