#!/usr/bin/env python3
# ブラウザ版の手触りを数で測る（ヘッドレスの Chrome・CDP）。直す前の切り分け用。
# usage: web_feel_measure.py <URL> <出力のフォルダ>
#   2. 区間ごとの 1 コマ: 手順書 bin/web_walk_demo.json の区間（＋止まっている区間）ごとに、rAF の間隔（ms）と
#      engine の頁が数える 1 コマの CPU（fgeStats・wasm がコマを組む時間）を集める → sections.json
#   1. 入力の遅れとカメラの止まり方: 画面を Page.startScreencast で毎コマ受け取り（f*.jpg と frames.tsv）、キーを押した時刻・離した時刻と並べる。
#      画面の動きは ffmpeg で地面の帯の前のコマとの差（YAVG）にする → motion.tsv。キーの時刻は keys.tsv。
# 起こした Chrome はプロセスの組ごと止め、使い捨ての user-data-dir を消す。
import base64, json, os, shutil, signal, subprocess, sys, tempfile, time, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import web_walk_record as R

PROBE = """(function () {
  var p = window.__hd2dProbe = { gaps: [], last: 0 };
  function tick(now) { if (p.last > 0) p.gaps.push(now - p.last); p.last = now; requestAnimationFrame(tick); }
  requestAnimationFrame(tick);
  return true;
})()"""
TAKE = """(function () {
  var p = window.__hd2dProbe, g = p.gaps.slice().sort(function (a, b) { return a - b; });
  var at = function (q) { return g.length ? +g[Math.min(g.length - 1, Math.floor(q * g.length))].toFixed(2) : 0; };
  var over = function (ms) { return g.filter(function (x) { return x > ms; }).length; };
  var cpu = window.fgeStats ? fgeStats.cpuRing.summary() : {};
  var out = { frames: g.length, fps: g.length ? +(1000 * g.length / g.reduce(function (a, b) { return a + b; }, 0)).toFixed(1) : 0,
              gap_p50: at(0.5), gap_p95: at(0.95), gap_max: at(1), over20ms: over(20), over34ms: over(34),
              cpu_p50: cpu.median || 0, cpu_p95: cpu.p95 || 0, cpu_max: cpu.max || 0 };
  p.gaps = []; if (window.fgeStats) fgeStats.reset();
  return JSON.stringify(out);
})()"""


def start(ws, url):
    ws.call("Page.navigate", {"url": url})
    assert R.wait_for(ws, "!!(window.fgeSplash && window.fgeSplash.ready)", 120), "押せる所まで来ない"
    for t in ("mousePressed", "mouseReleased"):
        ws.call("Input.dispatchMouseEvent", {"type": t, "x": 640, "y": 360, "button": "left", "clickCount": 1})
    assert R.wait_for(ws, "(document.getElementById('fge-boot') || {style: {}}).style.display === 'none'", 120), "最初のコマまで来ない"
    R.evaluate(ws, PROBE)
    time.sleep(1.5)
    R.evaluate(ws, TAKE)


def hold(ws, keys, secs):
    for k in keys:
        R.key(ws, "down", k)
    time.sleep(secs)
    for k in keys:
        R.key(ws, "up", k)


def main():
    url, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    profile = tempfile.mkdtemp(prefix="hd2d_cdp_")
    proc = subprocess.Popen([R.CHROME, "--headless=new", "--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1",
                             "--user-data-dir=" + profile, "--no-first-run", "--no-default-browser-check", "--disable-extensions",
                             "--mute-audio", "--hide-scrollbars", "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
                             "--disable-backgrounding-occluded-windows", "--window-size=1280,720", "about:blank"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    print("[feel] chrome pid", proc.pid)
    try:
        pf = os.path.join(profile, "DevToolsActivePort")
        end = time.time() + 20
        while not os.path.exists(pf) and time.time() < end:
            time.sleep(0.1)
        port = open(pf).read().split()[0]
        pages = json.load(urllib.request.urlopen("http://127.0.0.1:%s/json/list" % port))
        ws = R.Ws([p for p in pages if p["type"] == "page"][0]["webSocketDebuggerUrl"])
        ws.call("Runtime.enable")
        ws.call("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 720, "deviceScaleFactor": 1, "mobile": False})
        ws.call("Page.enable")
        ws.call("Page.bringToFront")
        ws.call("Emulation.setFocusEmulationEnabled", {"enabled": True})
        start(ws, url)

        # 1. 入力の遅れとカメラの止まり方（区間の測りより先・立ち始めの開いた所で）（画面を毎コマ受け取る）
        frames = []
        ws.call("Page.startScreencast", {"format": "jpeg", "quality": 80, "everyNthFrame": 1, "maxWidth": 1280, "maxHeight": 720})
        keys = []

        def pump(secs):
            end = time.time() + secs
            while time.time() < end:
                m = json.loads(ws.recv())
                if m.get("method") == "Page.screencastFrame":
                    p = m["params"]
                    name = "f%04d.jpg" % len(frames)
                    with open(os.path.join(out, name), "wb") as f:
                        f.write(base64.b64decode(p["data"]))
                    frames.append((name, p["metadata"]["timestamp"]))
                    ws.next_id += 1
                    ws.send(json.dumps({"id": ws.next_id, "method": "Page.screencastFrameAck", "params": {"sessionId": p["sessionId"]}}))

        def press(kind, code, label):
            keys.append((label, kind, code, time.time()))
            ws.next_id += 1
            name = code if code.startswith("Arrow") else code[-1].lower()
            ws.send(json.dumps({"id": ws.next_id, "method": "Input.dispatchKeyEvent",
                                "params": {"type": "rawKeyDown" if kind == "down" else "keyUp", "code": code, "key": name,
                                           "windowsVirtualKeyCode": R.KEYS[code], "nativeVirtualKeyCode": R.KEYS[code]}}))

        # 立ち始め（南の大通り・北へ 12 m ほど開いている）から: 北へ歩いて止まり、広場で斜め → 横だけへ向きを替えて止まる
        pump(1.5)
        press("down", "ArrowUp", "歩き出す（上）"); pump(1.3)
        press("up", "ArrowUp", "止まる"); pump(2.0)
        press("down", "ArrowUp", "歩き出す（上・2 回目）"); pump(0.4)
        press("down", "ArrowRight", "斜め（右上）"); pump(0.5)
        press("up", "ArrowUp", "向きを替える（右だけ）"); pump(0.5)
        press("up", "ArrowRight", "止まる"); pump(2.0)
        ws.call("Page.stopScreencast")
        with open(os.path.join(out, "frames.tsv"), "w") as f:
            for name, at in frames:
                f.write("%s\t%.4f\n" % (name, at))
        with open(os.path.join(out, "keys.tsv"), "w") as f:
            for label, kind, code, at in keys:
                f.write("%.4f\t%s\t%s\t%s\n" % (at, kind, code, label))
        print("[feel] 画面 %d 枚" % len(frames))

        # 区間の測りは立ち始めから流すので、頁を開き直す
        start(ws, url)

        # 2. 区間ごとの 1 コマ（手順書の区間に名前を付けて流す）
        sections = []
        plan = [("広場・止まって立つ", [], 2.0)] + [
            (name, keys, secs) for name, keys, secs in [
                ("南の大通り・低木に当たる（左）", ["ArrowLeft"], 0.5),
                ("南の大通り → 広場（左上・水路に沿って滑る）", ["ArrowLeft", "ArrowUp"], 0.8),
                ("広場（右）", ["ArrowRight"], 0.36),
                ("広場 → 北の大通り（上）", ["ArrowUp"], 2.0),
                ("北の大通り（上・建物の間）", ["ArrowUp"], 2.1),
                ("池の脇・建物の前（右上）", ["ArrowRight", "ArrowUp"], 1.0),
                ("池の東（左・池に当たる）", ["ArrowLeft"], 0.9),
            ]] + [("池の東・止まって立つ", [], 2.0)]
        for name, keys, secs in plan:
            hold(ws, keys, secs)
            row = json.loads(R.evaluate(ws, TAKE))
            row["section"] = name
            sections.append(row)
            print("[feel]", name, row)
        json.dump(sections, open(os.path.join(out, "sections.json"), "w"), ensure_ascii=False, indent=1)
    finally:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=5)
        except Exception:
            os.killpg(proc.pid, signal.SIGKILL)
        shutil.rmtree(profile, ignore_errors=True)


if __name__ == "__main__":
    main()
