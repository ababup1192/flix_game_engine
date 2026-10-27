# 潮だまりの効果音 10 個と、波の環境音 1 本（ループ）。鳴らす所は Controls.soundOf（World の出来事 → 音）と Controls.ambience。
# bin/fge snd build art/sfx.snd.star で art/sfx/*.sndsrc.json を書き、検査を通った物を atelier/sfx/<名前>.wav へ書く
# （採用した物を assets/sfx へ移し、project.json の sounds に載せる）。
# 昼の静かな浅瀬なので、どれも角を落とす: 矩形波は山の割合 0.5 を倍音のすぐ上で切って丸め、雑音は低めで切る。
# 立ち上がりは 2ms 以上（耳に刺さる「パチ」を出さない）。主役は波の環境音で、効果音はその上に小さく乗る。

def tone(hz, ms, at = 0, amp = 0.35, decay = 60, to_hz = None, attack = 3):
    return {"at": at, "ops": [op.pulse(hz = hz, ms = ms, amp = amp, duty = 0.5, to_hz = to_hz, accumulate = to_hz != None),
                              op.lowpass(hz = hz * 2, stages = 2),
                              op.env(attack_ms = attack, decay_ms = decay)]}

def hiss(ms, at = 0, amp = 0.3, hz = 1800, decay = 30, attack = 3):
    return {"at": at, "ops": [op.noise(ms = ms, amp = amp), op.lowpass(hz = hz, stages = 2), op.env(attack_ms = attack, decay_ms = decay)]}

# 寄せて返す波の 1 つ: 雑音の明るさを hz から to_hz へ動かし、ゆっくり膨らんで引く。尾は直線で 0 へ。
def wave(ms, at = 0, amp = 0.4, hz = 400, to_hz = 1100, attack = 300, decay = 300):
    return {"at": at, "ops": [op.noise(ms = ms, amp = amp), op.svf(mode = "low", hz = hz, to_hz = to_hz, q = 0.5),
                              op.env(attack_ms = attack, decay_ms = decay), op.fade()]}

# 途切れない雑音の床（遠い沖の音）。env は掛けない。
def bed(ms, amp, hz, stages = 2):
    return {"at": 0, "ops": [op.noise(ms = ms, amp = amp), op.lowpass(hz = hz, stages = stages)]}

def sound(name, voices, kind = "sfx", room = 0.35, wet = 0.1):
    snd.write_spec("//art/sfx/%s.sndsrc.json" % name, {
        "version": 1,
        "target": "//atelier/sfx/%s.wav" % name,
        "kind": kind,
        "style": "free",
        "channels": "mono",
        "voices": voices,
        "post": [op.reverb(room = room, wet = wet), op.finish(in_ms = 3, out_ms = 20), op.normalize(lufs = -24 if kind == "ui" else -22)],
    })

def main():
    # 浅瀬の波（8 秒の輪）: 低い沖の床と、間をずらして寄せる波 3 つ。継ぎ目が出ないよう頭と尾は絞らない。
    snd.write_spec("//art/sfx/amb_waves.sndsrc.json", {
        "version": 1,
        "target": "//atelier/sfx/amb_waves.wav",
        "kind": "bgm",
        "style": "free",
        "channels": "mono",
        "loop_start_ms": 0,
        "voices": [bed(8000, 0.22, 450, stages = 3), bed(8000, 0.04, 2200),
                   wave(2600, at = 300, amp = 0.24), wave(2400, at = 3000, amp = 0.2, hz = 350, to_hz = 900),
                   wave(2200, at = 5500, amp = 0.22, hz = 450, to_hz = 1000)],
        "post": [op.reverb(room = 0.5, wet = 0.15), op.normalize(lufs = -17.5)],
    })

    # 砂を歩く: 低く切った短い擦れ。
    sound("step_sand", [hiss(70, amp = 0.35, hz = 1100, decay = 22, attack = 4)], room = 0.2, wet = 0.05)
    # 岩を歩く: 濡れた岩を爪で踏む小さな「コッ」（低い粒 + ごく短い擦れ）。
    sound("step_rock", [tone(300, 60, amp = 0.3, decay = 18, to_hz = 240), hiss(25, amp = 0.15, hz = 2200, decay = 8)], room = 0.25, wet = 0.06)
    # 小石を押す: 砂の上を引きずる擦れの後に、止まった「コト」。
    sound("push", [hiss(170, amp = 0.3, hz = 900, decay = 90, attack = 12), tone(196, 70, at = 140, amp = 0.3, decay = 25)], room = 0.25, wet = 0.06)
    # 流木: 中が空いた木の「コトン」（5 度離れた 2 音）と、水が揺れる小さな返し。
    sound("driftwood", [tone(220, 90, amp = 0.32, decay = 35), tone(330, 70, at = 4, amp = 0.16, decay = 25),
                        wave(260, at = 30, amp = 0.18, hz = 500, to_hz = 300, attack = 40, decay = 90)])
    # 満ち切った: 寄せる波 1 つ（明るくなりながら膨らむ）と、下から上がる小さな 2 音。
    sound("tide_high", [wave(900, amp = 0.4, hz = 350, to_hz = 1200, attack = 350, decay = 250),
                        tone(392, 240, at = 250, amp = 0.1, decay = 120, attack = 20), tone(587, 320, at = 380, amp = 0.1, decay = 160, attack = 20)],
          room = 0.5, wet = 0.18)
    # 引き切った: 返す波 1 つ（暗くなりながら引く）と、上から下りる 2 音と、残った滴。
    sound("tide_low", [wave(900, amp = 0.38, hz = 1200, to_hz = 300, attack = 40, decay = 320),
                       tone(587, 240, at = 120, amp = 0.1, decay = 120, attack = 20), tone(392, 320, at = 260, amp = 0.1, decay = 160, attack = 20),
                       tone(1400, 40, at = 650, amp = 0.08, decay = 12, to_hz = 1900), tone(1650, 40, at = 780, amp = 0.06, decay = 12, to_hz = 2200)],
          room = 0.5, wet = 0.18)
    # 流された: 大きく覆う波と、ゆっくり沈む 1 本。
    sound("washed", [wave(1300, amp = 0.45, hz = 500, to_hz = 1400, attack = 120, decay = 450),
                     tone(523, 900, at = 60, amp = 0.14, decay = 450, to_hz = 175, attack = 15)],
          room = 0.55, wet = 0.2)
    # 面クリア: 巻き貝に触れた澄んだ 4 音（C5 E5 G5 C6）。最後を長く残す。
    sound("clear", [tone(523, 160, amp = 0.28, decay = 90), tone(659, 160, at = 100, amp = 0.28, decay = 90),
                    tone(784, 160, at = 200, amp = 0.28, decay = 90), tone(1047, 700, at = 300, amp = 0.3, decay = 320)],
          room = 0.6, wet = 0.25)
    # 取り消し（やり直し・確認の窓を閉じるも）: 下りる 2 音 G5 → D5。
    sound("undo", [tone(784, 70, amp = 0.3, decay = 35), tone(587, 110, at = 55, amp = 0.3, decay = 55)], kind = "ui", room = 0.3, wet = 0.08)
    # 選ぶ・決める: 軽い 1 粒 A5 に、上の 5 度を薄く。
    sound("select", [tone(880, 80, amp = 0.3, decay = 40), tone(1319, 60, at = 25, amp = 0.12, decay = 30)], kind = "ui", room = 0.3, wet = 0.08)

main()
