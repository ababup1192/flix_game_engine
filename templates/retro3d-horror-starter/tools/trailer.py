"""X に載せる 1 分の紹介の動画（trailer_x.mp4）を作る道具。

  1. flows  … 場面ごとの手順を e2e/trailer/*.flow に書き、音を置く時刻の表を build/trailer/plan.json に書く
  2. (make video で場面ごとに debug/video/trailer_<名前>.mp4 を撮る。tools/trailer.sh が流す)
  3. mix    … 場面をフェード（黒へ）でつなぎ、効果音（assets/sfx/・make sfx の合成音）を時刻の表どおりに重ね、
              -14 LUFS にそろえて H.264（High）・AAC 128 kbps・48 kHz ステレオの MP4 にする
              BGM を渡した時は BGM が主役: 効果音の全体を BGM より SFX_UNDER_BGM_DB 下へそろえる（ebur128 で両方を測って決める）

効果音どうしの釣り合いはゲームと同じ sound.kind.json（足音を 1 とした比）。紹介の動画では空気・風・戸・時計を TRAILER_QUIET 倍でさらに控えめにする。

カメラの動きはゲームの操作だけ（歩く・向きを変える・ピッチ・止まる）。台詞は会話の手順で送り、見せたい行の所だけを撮る（mark in_ / out_）。
"""
import json, math, struct, subprocess, sys, wave, pathlib, random

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEED, BACK, STRIDE = 1.3, 0.8, 0.7   # walk.kind.json の speed・backSpeed・stride
FADE = 0.4

# 場面: (名前, 始まり, 手順, 音)。手順の 1 つは (役, 秒) か ("wait", 秒) か ("tap", n)（n 回押す）か ("in"/"out")。
# 音: ("door", 秒) = 戸を開ける音（戸の種類は DOORS）。足音は歩く秒から出し、時計は CLOCK_SCENES・風は WIND_AT
SCENES = [
    ("entrance", "x=-22.96 y=0 z=5.25 yaw=180", [("wait", 1.2), ("forward", 1.28), ("turnLeft", 0.6), ("wait", 0.8)], []),
    ("corridor", "x=-7.2 y=0 z=-1.2 yaw=270", [("forward", 1.92), ("turnRight", 1.125), ("lookDown", 0.2), ("wait", 1.0), ("lookUp", 0.2),
                                          ("turnLeft", 1.125), ("forward", 1.6), ("turnLeft", 1.125), ("lookDown", 0.4), ("wait", 0.6),
                                          ("lookUp", 0.4), ("turnRight", 1.125), ("wait", 1.0)], []),
    ("classroom", "x=-39.12 y=0 z=-1.2 yaw=0", [("forward", 2.4), ("lookDown", 0.5), ("wait", 0.8), ("turnRight", 0.5), ("wait", 0.5)], [("door", 1.1)]),
    ("library", "x=-26.96 y=3.35 z=1.57 yaw=90 unlocked=library", [("wait", 0.3), ("lookUp", 0.5), ("wait", 0.8), ("forward", 1.2)], []),
    ("girl", "x=-39.12 y=0 z=3.94 yaw=0", [("forward", 1.12), ("turnRight", 0.62), ("wait", 0.4), ("out",), ("tap", 1), ("tap", 4), ("in",),
                                       ("wait", 3.8), ("tap", 1), ("wait", 3.4)], []),
    ("toilet", "x=-5.84 y=0 z=-3 yaw=180", [("forward", 0.8), ("lookDown", 0.6), ("wait", 0.6)], [("door", 0.2)]),
    ("stairs", "x=-19.44 y=0 z=-1.4 yaw=180", [("lookUp", 0.4), ("forward", 2.0)], []),
    ("teacher", "x=-27.84 y=0 z=-4.3 yaw=250.6", [("out",), ("tap", 1), ("tap", 8), ("in",), ("wait", 3.8)], []),
    ("nurse", "x=-25.04 y=0 z=1.19 yaw=324", [("out",), ("tap", 1), ("tap", 6), ("in",), ("wait", 3.8)], []),
    ("vacant", "x=-22.96 y=6.7 z=-1.92 yaw=0", [("wait", 0.5), ("forward", 1.04), ("lookDown", 0.1), ("wait", 2.2), ("lookUp", 0.1),
                                            ("forward", 0.44), ("wait", 3.5)], [("door", 1.9)]),
]
TAIL_BLACK = 2.5

def flows():
    out = ROOT / "e2e" / "trailer"
    out.mkdir(parents=True, exist_ok=True)
    plan = []
    for name, start, steps, sounds in SCENES:
        lines = [f"# 紹介の動画の場面「{name}」（tools/trailer.py が書いた手順。直すなら tools/trailer.py を直して flows を流し直す）", "fps 60",
                 f"start at {start}"]
        t, recording, shown, walking = 0.0, False, [], []
        mark = "`"
        rec_start = 0.0
        # 頭から撮る場面は撮り始めの印を先に置く（頭で out する場面は、撮らない所から始まる）
        steps = list(steps) if steps[0] == ("out",) else [("in",)] + list(steps)
        if steps[0] == ("out",): steps = steps[1:]
        for st in steps:
            kind = st[0]
            if kind == "out":
                lines.append(f"mark out_{mark}"); shown.append((rec_start, t)); recording = False
            elif kind == "in":
                mark = chr(ord(mark) + 1); lines.append(f"mark in_{mark}"); rec_start = t; recording = True
            elif kind == "tap":
                for _ in range(st[1]):
                    lines.append("tap talk"); lines.append("wait 0.05"); t += 1 / 60 + 0.05
            elif kind == "wait":
                lines.append(f"wait {st[1]}"); t += st[1]
            else:
                lines.append(f"hold {kind} {st[1]}")
                if kind in ("forward", "back"):
                    walking.append((t, t + st[1], SPEED if kind == "forward" else BACK))
                t += st[1]
        if recording:
            lines.append(f"mark out_{mark}"); shown.append((rec_start, t))
        (out / f"{name}.flow").write_text("\n".join(lines) + "\n", encoding="utf8")
        # 撮った区間の上の時刻へ写す（区間の外の音は落とす）
        def to_video(ft):
            acc = 0.0
            for a, b in shown:
                if a <= ft <= b: return acc + ft - a
                acc += b - a
            return None
        length = sum(b - a for a, b in shown)
        steps_at = []
        for a, b, v in walking:
            period = STRIDE / v
            k = 1
            while a + k * period <= b + 1e-6:
                steps_at.append(a + k * period); k += 1
        evs = [("step", vt) for vt in (to_video(x) for x in steps_at) if vt is not None]
        for s in sounds:
            evs.append((s[0], s[1]))
        plan.append({"name": name, "length": length, "events": evs})
    (ROOT / "build" / "trailer").mkdir(parents=True, exist_ok=True)
    (ROOT / "build" / "trailer" / "plan.json").write_text(json.dumps(plan, ensure_ascii=False, indent=1), encoding="utf8")
    print("flows:", " ".join(f"{p['name']}={p['length']:.2f}s" for p in plan), f"計 {sum(p['length'] for p in plan) + TAIL_BLACK:.1f}s")

def read_wav(name):
    with wave.open(str(ROOT / "assets" / "sfx" / f"{name}.wav")) as w:
        rate, n, ch = w.getframerate(), w.getnframes(), w.getnchannels()
        raw = w.readframes(n)
    samples = struct.unpack("<%dh" % (n * ch), raw)[::ch]
    out_n = int(n * 48000 / rate)
    return [samples[min(n - 1, int(i * rate / 48000))] / 32768.0 for i in range(out_n)]

# 場面ごとの戸の音（部屋に入る所）。教室・特別教室は教室の引き戸、便所などは古い戸（ゲームの Sounds.doorOf と同じ使い分け）。
DOORS = {"classroom": "door_classroom", "toilet": "door_old", "vacant": "door_classroom"}
CLOCK_SCENES = {"corridor": 0.5}   # 廊下の場面だけ振り子の音を重ねる（壁の時計に近い所）
WIND_AT = 31.0                      # 風を 1 回だけ薄く重ねる秒

SFX_UNDER_BGM_DB = 4.5   # 効果音の全体を BGM よりこの dB だけ下に置く（3〜6 dB の真ん中）
TRAILER_QUIET = 0.6      # 空気・風・戸・時計を、ゲームの釣り合いからさらに控えめにする倍率

def sound_ratios():
    """sound.kind.json の大きさを、足音を 1 とした比にする（ゲームの釣り合いと同じ）。"""
    doc = json.loads((ROOT / "assets" / "sound.kind.json").read_text(encoding="utf8"))
    step = doc["step"]
    return {k: doc[k] / step * TRAILER_QUIET for k in ("ambience", "wind", "door", "clock", "paper")}

def build_audio(plan, total):
    n = int(total * 48000)
    left = [0.0] * n; right = [0.0] * n
    ratio = sound_ratios()
    amb = read_wav("amb_quiet")
    for i in range(n):
        left[i] += amb[i % len(amb)] * ratio["ambience"]; right[i] += amb[(i + 9600) % len(amb)] * ratio["ambience"]
    sfx = {k: read_wav(k) for k in [f"step_{i}" for i in range(6)] + ["door_classroom", "door_old", "door_unlock", "pickup", "clock", "wind"]}
    rng = random.Random(7)
    def put(name, at, gain, pan, length=None):
        s = sfx[name]; start = int(at * 48000)
        m = len(s) if length is None else int(length * 48000)
        for j in range(m):
            k = start + j
            if 0 <= k < n:
                v = s[j % len(s)]
                left[k] += v * gain * (1 - pan); right[k] += v * gain * (1 + pan)
    offset, count = 0.0, 0
    for p in plan:
        for kind, t in p["events"]:
            at = offset + t
            if kind == "step":
                count += 1
                put(f"step_{count % 6}", at, 0.9 + 0.15 * rng.random(), rng.uniform(-0.12, 0.12))
            elif kind == "door":
                put(DOORS.get(p["name"], "door_old"), at, ratio["door"], -0.2)
            elif kind == "unlock":
                put("door_unlock", at, ratio["door"], -0.2); put("door_classroom", at + 0.25, ratio["door"], -0.2)
            elif kind == "pickup":
                put("pickup", at, ratio["paper"], 0.0)
        if p["name"] in CLOCK_SCENES:
            put("clock", offset, ratio["clock"] * CLOCK_SCENES[p["name"]], 0.4, p["length"])
        offset += p["length"]
    put("wind", WIND_AT, ratio["wind"], 0.0)
    wav = ROOT / "build" / "trailer" / "audio.wav"
    with wave.open(str(wav), "w") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
        frames = bytearray()
        for i in range(n):
            frames += struct.pack("<hh", max(-32767, min(32767, int(left[i] * 32767))), max(-32767, min(32767, int(right[i] * 32767))))
        w.writeframes(bytes(frames))
    return wav

def loudness(inputs, chain):
    out = subprocess.run(["ffmpeg", "-hide_banner"] + inputs + ["-filter_complex", chain + ",ebur128", "-f", "null", "-"], capture_output=True, text=True).stderr
    return float(out[out.rindex("I:"):].split()[1])

def mix():
    """mix [出力] [BGM の mp3 音量]: 場面をつなぎ、効果音を重ね、BGM があれば重ねて -14 LUFS・ピーク -1.5 dBTP より下にそろえる。"""
    plan = json.loads((ROOT / "build" / "trailer" / "plan.json").read_text(encoding="utf8"))
    total = sum(p["length"] for p in plan) + TAIL_BLACK
    out = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "debug" / "video" / "trailer_x.mp4"
    bgm = (sys.argv[3], float(sys.argv[4])) if len(sys.argv) > 4 else None
    wav = build_audio(plan, total)
    # 映像: 場面ごとに黒へのフェードを掛けてつなぎ、最後に黒を足す
    vin, vf, labels = [], [], []
    for i, p in enumerate(plan):
        vin += ["-i", str(ROOT / "debug" / "video" / f"trailer_{p['name']}.mp4")]
        L = p["length"]; f = 0.3 if L < 3 else FADE
        s0 = p.get("start", 0.0)
        vf.append(f"[{i}:v]trim={s0:.3f}:{s0 + L:.3f},setpts=PTS-STARTPTS,fps=30,fade=t=in:st=0:d={f},fade=t=out:st={max(0, L - f):.3f}:d={f}[v{i}]")
        labels.append(f"[v{i}]")
    vf.append(f"color=c=black:s=960x720:r=30:d={TAIL_BLACK}[vb]"); labels.append("[vb]")
    vf.append("".join(labels) + f"concat=n={len(labels)}:v=1:a=0[vout]")
    # 音: 効果音（と BGM）を混ぜ、頭と尻をフェードし、測った差だけ音量を上げて山をリミッターで抑える
    # WhyNot: loudnorm の linear で合わせ切らない — 足音の山が上限に当たり、-16 LUFS で止まった。
    ain = ["-i", str(wav)] + (["-i", bgm[0]] if bgm else [])
    fades = f"afade=t=in:st=0:d=0.8,afade=t=out:st={total - 3.5:.2f}:d=3.5"
    if bgm:
        # BGM が主役: 効果音と BGM を別々に測り、効果音の全体が BGM より SFX_UNDER_BGM_DB 下になる倍率を効果音に掛ける
        bgm_chain = f"[0:a]atrim=0:{total:.2f},asetpts=PTS-STARTPTS,volume={bgm[1]},afade=t=in:st=0:d=2,afade=t=out:st={total - 3.5:.2f}:d=3.5"
        bgm_lufs = loudness(["-i", bgm[0]], bgm_chain)
        sfx_lufs = loudness(["-i", str(wav)], "[0:a]anull")
        sfx_db = bgm_lufs - SFX_UNDER_BGM_DB - sfx_lufs
        print(f"BGM {bgm_lufs:.1f} LUFS（音量 {bgm[1]}）・効果音 {sfx_lufs:.1f} LUFS → 効果音に {sfx_db:+.1f} dB（BGM より {SFX_UNDER_BGM_DB} dB 下）")
        base = (f"[0:a]volume={sfx_db:.2f}dB[s];[1:a]atrim=0:{total:.2f},asetpts=PTS-STARTPTS,volume={bgm[1]},afade=t=in:st=0:d=2,afade=t=out:st={total - 3.5:.2f}:d=3.5[b];"
                f"[s][b]amix=inputs=2:normalize=0:duration=first,{fades}")
    else:
        base = f"[0:a]{fades}"
    chain = lambda g: f"{base},volume={g:.2f}dB,alimiter=limit=0.63:attack=2:release=60:level=disabled"
    gain = 0.0
    for _ in range(4):
        measured = loudness(ain, chain(gain))
        if abs(measured + 14.0) < 0.3: break
        gain += -14.0 - measured
    au = len(plan)
    afilt = chain(gain).replace("[0:a]", f"[{au}:a]").replace("[1:a]", f"[{au + 1}:a]") + ",aresample=48000[aout]"
    cmd = ["ffmpeg", "-y", "-loglevel", "error"] + vin + ain + ["-filter_complex", ";".join(vf) + ";" + afilt, "-map", "[vout]", "-map", "[aout]",
           "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-preset", "slow", "-crf", "20", "-r", "30",
           "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2", "-movflags", "+faststart", "-t", f"{total:.2f}", str(out)]
    subprocess.run(cmd, check=True)
    print("wrote", out, f"（全体を {gain:+.1f} dB・-14 LUFS にそろえた）")

if __name__ == "__main__":
    {"flows": flows, "mix": mix}[sys.argv[1]]()
