# ルーネの泉の効果音（フェーズ P1 の 5 つと、P5.5 の会話の 5 つ・レバー）。鳴らす所は Controls.soundOf（World の出来事 → 音）。
# bin/fge snd build art/sfx.snd.star で art/sfx/*.sndsrc.json を書き、検査を通った物を atelier/sfx/<名前>.wav へ書く
# （採用した物を assets/sfx へ移し、project.json の sounds に載せる）。
# FC の音源に寄せる: 矩形波（山の割合 0.125 / 0.25 / 0.5）と雑音だけ。立ち上がりは 2ms 以上（「パチ」を出さない）。

def square(hz, ms, at = 0, amp = 0.3, duty = 0.25, decay = 40, to_hz = None, attack = 2):
    return {"at": at, "ops": [op.pulse(hz = hz, ms = ms, amp = amp, duty = duty, to_hz = to_hz, accumulate = to_hz != None),
                              op.env(attack_ms = attack, decay_ms = decay)]}

def hiss(ms, at = 0, amp = 0.3, hz = 2400, decay = 30, attack = 2):
    return {"at": at, "ops": [op.noise(ms = ms, amp = amp), op.lowpass(hz = hz, stages = 2), op.env(attack_ms = attack, decay_ms = decay)]}

def sound(name, voices, kind = "ui"):
    snd.write_spec("//art/sfx/%s.sndsrc.json" % name, {
        "version": 1,
        "target": "//atelier/sfx/%s.wav" % name,
        "kind": kind,
        "style": "free",
        "channels": "mono",
        "voices": voices,
        "post": [op.finish(in_ms = 2, out_ms = 15), op.normalize(lufs = -24 if kind == "ui" else -22)],
    })

def main():
    # カーソル: 高く短い 1 音（山の割合 0.125 の細い音）。
    sound("cursor", [square(1760, 35, duty = 0.125, decay = 20)])
    # 決定: 上がる 2 音。
    sound("confirm", [square(988, 45, decay = 25), square(1480, 70, at = 45, decay = 45)])
    # 取消: 下がる 2 音。
    sound("cancel", [square(880, 45, decay = 25), square(587, 80, at = 45, decay = 50)])
    # ぶつかる: 低い鈍い音と短い雑音。
    sound("bump", [square(110, 70, duty = 0.5, amp = 0.35, decay = 40, to_hz = 80), hiss(30, amp = 0.15, hz = 900, decay = 15)], kind = "sfx")
    # 扉: 木の戸が開く「ギィ」（下がる音）と閉まる「トン」。
    sound("door", [square(330, 160, duty = 0.25, amp = 0.25, decay = 120, to_hz = 220),
                   hiss(60, at = 150, amp = 0.3, hz = 700, decay = 40), square(147, 60, at = 150, duty = 0.5, amp = 0.3, decay = 35)], kind = "sfx")
    # 会話の文字送り（2 字ごと）: 短い 1 音。話し手の声の高さで 3 つ（rpg.text.json の speakers の voice）。
    # 1 秒に 10 回ほど鳴るので、短く（25ms）小さく、山の割合 0.5 の丸い音にする。
    sound("talk_low", [square(262, 25, duty = 0.5, amp = 0.22, decay = 18)])
    sound("talk_mid", [square(440, 25, duty = 0.5, amp = 0.2, decay = 18)])
    sound("talk_high", [square(698, 22, duty = 0.25, amp = 0.18, decay = 16)])
    # 会話のウィンドウが開く: 上がる 3 音を速く（ポロン）。
    sound("talk_open", [square(784, 30, duty = 0.25, decay = 18), square(1047, 30, at = 30, duty = 0.25, decay = 18),
                        square(1319, 50, at = 60, duty = 0.125, decay = 35)])
    # 台詞を送る: 細く短い 1 音（決定より軽く）。
    sound("talk_next", [square(1319, 30, duty = 0.25, amp = 0.2, decay = 18)])
    # レバー: 金属の「ガチャン」（短い雑音と低い 2 音）。
    sound("lever", [hiss(40, amp = 0.3, hz = 3000, decay = 25), square(196, 60, at = 20, duty = 0.5, amp = 0.3, decay = 40, to_hz = 147),
                    hiss(80, at = 70, amp = 0.2, hz = 1200, decay = 60)], kind = "sfx")
    # 岩を押す: 重い「ゴリッ」（低い雑音を長めに引きずり、低い音が少し下がる）。
    sound("rock", [hiss(180, amp = 0.35, hz = 500, decay = 140, attack = 8), square(82, 160, at = 10, duty = 0.5, amp = 0.25, decay = 120, to_hz = 65, attack = 6)], kind = "sfx")
    # トロッコが走り出す: 車輪の「ガタン ゴトン」（雑音 2 つと低い 2 音を 120ms あけて）。
    sound("cart", [hiss(50, amp = 0.3, hz = 1800, decay = 35), square(147, 60, at = 10, duty = 0.5, amp = 0.25, decay = 45),
                   hiss(50, at = 130, amp = 0.3, hz = 1500, decay = 35), square(123, 70, at = 140, duty = 0.5, amp = 0.25, decay = 55),
                   hiss(160, at = 260, amp = 0.15, hz = 2500, decay = 120)], kind = "sfx")
    # 水晶を点ける: 澄んだ上がる 2 音（細い音の鈴）。
    sound("chime", [square(1568, 90, duty = 0.125, amp = 0.25, decay = 80), square(2093, 160, at = 70, duty = 0.125, amp = 0.22, decay = 140)], kind = "sfx")
    # 水晶が消える: 下がって細る 1 音。
    sound("fizzle", [square(1047, 240, duty = 0.125, amp = 0.22, decay = 200, to_hz = 392), hiss(120, at = 60, amp = 0.1, hz = 3000, decay = 100)], kind = "sfx")
main()
