#!/usr/bin/env python3
# ブラウザ版の昼の町を、ヘッドレスの Chrome（CDP）でキーを押して歩かせ、画面を続けて撮る（PC のブラウザで歩けるかの確かめと短い動画）。
# usage: web_walk_record.py <URL> <出力のフォルダ> [台本.json]
#   台本 = [[始まりの秒, 終わりの秒, ["ArrowUp", ...]], ...]（押している間のキー・最初のコマからの秒）。無ければ bin/web_walk_demo.json
#   （水路の脇の低木に当たって滑り、広場を抜けて大通りを北へ・池に当たって回り込み・木と建物に当たる）。
#   出力: <フォルダ>/f0000.jpg … と frames.txt（ffmpeg の concat の形・1 枚ごとの長さ）。最後に頁の console の行を console.txt へ。
# 起こした Chrome はプロセスの組ごと止め、使い捨ての user-data-dir を消す（人の Chrome には触らない）。
# WhyNot: bin/fge web-capture を 1 コマずつ呼ばない — 1 回の起動で 1 枚しか撮れず、キーも押せない。
import base64, json, os, shutil, signal, socket, struct, subprocess, sys, tempfile, time, urllib.request

CHROME = os.environ.get("FGE_CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
FPS = 15.0
KEYS = {"ArrowLeft": 37, "ArrowUp": 38, "ArrowRight": 39, "ArrowDown": 40, "KeyA": 65, "KeyD": 68, "KeyS": 83, "KeyW": 87}
DEMO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web_walk_demo.json")


class Ws:
    def __init__(self, url):
        host, rest = url[len("ws://"):].split("/", 1)
        h, p = host.split(":")
        self.s = socket.create_connection((h, int(p)))
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall(("GET /%s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (rest, host, key)).encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.s.recv(4096)
        self.rest = buf.split(b"\r\n\r\n", 1)[1]
        self.next_id = 0
        self.events = []

    def _read(self, n):
        while len(self.rest) < n:
            chunk = self.s.recv(1 << 20)
            if not chunk:
                raise EOFError
            self.rest += chunk
        out, self.rest = self.rest[:n], self.rest[n:]
        return out

    def send(self, text):
        data = text.encode()
        mask = os.urandom(4)
        n = len(data)
        head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else bytes([0x80 | 127]) + struct.pack(">Q", n))
        self.s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def recv(self):
        message = b""
        while True:
            b0, b1 = self._read(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            message += self._read(n)
            if b0 & 0x80:
                return message.decode()

    def call(self, method, params=None):
        self.next_id += 1
        self.send(json.dumps({"id": self.next_id, "method": method, "params": params or {}}))
        while True:
            m = json.loads(self.recv())
            if m.get("id") == self.next_id:
                if "error" in m:
                    raise RuntimeError("%s: %s" % (method, m["error"]))
                return m.get("result", {})
            self.events.append(m)


def evaluate(ws, expr):
    return ws.call("Runtime.evaluate", {"expression": expr, "returnByValue": True}).get("result", {}).get("value")


def wait_for(ws, expr, limit):
    end = time.time() + limit
    while time.time() < end:
        if evaluate(ws, expr):
            return True
        time.sleep(0.1)
    return False


def key(ws, kind, code):
    name = code if code.startswith("Arrow") else code[-1].lower()
    ws.call("Input.dispatchKeyEvent", {"type": "rawKeyDown" if kind == "down" else "keyUp", "code": code, "key": name,
                                       "windowsVirtualKeyCode": KEYS[code], "nativeVirtualKeyCode": KEYS[code]})


def main():
    url, out = sys.argv[1], sys.argv[2]
    script = json.load(open(sys.argv[3] if len(sys.argv) > 3 else DEMO))
    os.makedirs(out, exist_ok=True)
    profile = tempfile.mkdtemp(prefix="hd2d_cdp_")
    proc = subprocess.Popen([CHROME, "--headless=new", "--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1",
                             "--user-data-dir=" + profile, "--no-first-run", "--no-default-browser-check", "--disable-extensions",
                             "--disable-background-networking", "--disable-component-update", "--disable-sync", "--mute-audio",
                             "--hide-scrollbars", "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
                             "--disable-backgrounding-occluded-windows", "--window-size=1280,720", "about:blank"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    print("[record] chrome pid", proc.pid)
    try:
        port_file = os.path.join(profile, "DevToolsActivePort")
        end = time.time() + 20
        while not os.path.exists(port_file) and time.time() < end:
            time.sleep(0.1)
        port = open(port_file).read().split()[0]
        pages = json.load(urllib.request.urlopen("http://127.0.0.1:%s/json/list" % port))
        ws = Ws([p for p in pages if p["type"] == "page"][0]["webSocketDebuggerUrl"])
        ws.call("Runtime.enable")
        ws.call("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 720, "deviceScaleFactor": 1, "mobile": False})
        ws.call("Page.enable")
        ws.call("Page.bringToFront")
        ws.call("Emulation.setFocusEmulationEnabled", {"enabled": True})
        ws.call("Page.navigate", {"url": url})
        if not wait_for(ws, "!!(window.fgeSplash && window.fgeSplash.ready)", 120):
            raise RuntimeError("押せる所まで来ない")
        for t in ("mousePressed", "mouseReleased"):
            ws.call("Input.dispatchMouseEvent", {"type": t, "x": 640, "y": 360, "button": "left", "clickCount": 1})
        if not wait_for(ws, "(document.getElementById('fge-boot') || {style: {}}).style.display === 'none'", 120):
            raise RuntimeError("最初のコマまで来ない")
        last = max(e for _, e, _ in script) + 1.5
        held = set()
        start = time.time()
        shots = []
        while True:
            now = time.time() - start
            if now > last:
                break
            want = set(k for s, e, ks in script if s <= now < e for k in ks)
            for k in sorted(held - want):
                key(ws, "up", k)
            for k in sorted(want - held):
                key(ws, "down", k)
            held = want
            shot = ws.call("Page.captureScreenshot", {"format": "jpeg", "quality": 85})
            name = "f%04d.jpg" % len(shots)
            with open(os.path.join(out, name), "wb") as f:
                f.write(base64.b64decode(shot["data"]))
            shots.append((name, time.time() - start))
            time.sleep(max(0.0, (len(shots) / FPS) - (time.time() - start)))
        for k in held:
            key(ws, "up", k)
        with open(os.path.join(out, "frames.txt"), "w") as f:
            for i, (name, at) in enumerate(shots):
                after = shots[i + 1][1] if i + 1 < len(shots) else at + 1.0 / FPS
                f.write("file '%s'\nduration %.4f\n" % (name, after - at))
            f.write("file '%s'\n" % shots[-1][0])
        lines = [m["params"]["args"][0].get("value", "") for m in ws.events if m.get("method") == "Runtime.consoleAPICalled" and m["params"]["args"]]
        with open(os.path.join(out, "console.txt"), "w") as f:
            f.write("\n".join(str(l) for l in lines) + "\n")
        print("[record] %d 枚・%.1f 秒" % (len(shots), shots[-1][1]))
    finally:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=5)
        except Exception:
            os.killpg(proc.pid, signal.SIGKILL)
        shutil.rmtree(profile, ignore_errors=True)


if __name__ == "__main__":
    main()
