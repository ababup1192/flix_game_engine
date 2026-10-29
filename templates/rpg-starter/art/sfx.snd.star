# ルーネの泉の効果音。鳴らす所は Controls.soundOf（World の出来事 → 音）。
# bin/fge snd build art/sfx.snd.star で art/sfx/*.sndsrc.json を書き、検査を通った物を atelier/sfx/<名前>.wav へ書く
# （採用した物を assets/sfx へ移し、project.json の sounds に載せる）。
# FC の音源に寄せる: 矩形波（山の割合 0.125 / 0.25 / 0.5）と雑音だけ。立ち上がりは 2ms 以上（「パチ」を出さない）。

def square(hz, ms, at = 0, amp = 0.3, duty = 0.25, decay = 40, to_hz = None, attack = 2):
    return {"at": at, "ops": [op.pulse(hz = hz, ms = ms, amp = amp, duty = duty, to_hz = to_hz, accumulate = to_hz != None),
                              op.env(attack_ms = attack, decay_ms = decay)]}

def hiss(ms, at = 0, amp = 0.3, hz = 2400, decay = 30, attack = 2):
    return {"at": at, "ops": [op.noise(ms = ms, amp = amp), op.lowpass(hz = hz, stages = 2), op.env(attack_ms = attack, decay_ms = decay)]}

def melody(notes, at = 0, duty = 0.5, amp = 0.2, gap = 12):
    # notes = [(Hz, ms)]（Hz が 0 は休み）。1 音ずつ少し前で離して、粒が立つようにする。
    voices = []
    t = at
    for hz, ms in notes:
        if hz > 0:
            voices.append(square(hz, ms - gap, at = t, duty = duty, amp = amp, decay = ms * 2))
        t += ms
    return voices

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

    # ── 歩く・調べる ──
    # 階段: 足音の「コツ コツ コツ」（短い雑音と低い音を 3 つ、少しずつ下げて）。
    sound("stairs", [hiss(25, amp = 0.3, hz = 2200, decay = 15), square(330, 30, duty = 0.5, amp = 0.2, decay = 18),
                     hiss(25, at = 90, amp = 0.28, hz = 2000, decay = 15), square(294, 30, at = 90, duty = 0.5, amp = 0.2, decay = 18),
                     hiss(25, at = 180, amp = 0.26, hz = 1800, decay = 15), square(262, 40, at = 180, duty = 0.5, amp = 0.2, decay = 25)], kind = "sfx")
    # 宝箱: ふたの「ガチャ」と、上がる 3 音（中身が見えた）。
    sound("chest", [hiss(40, amp = 0.3, hz = 2500, decay = 25), square(220, 50, duty = 0.5, amp = 0.25, decay = 30, to_hz = 330),
                    square(784, 60, at = 80, duty = 0.25, amp = 0.22, decay = 40), square(988, 60, at = 140, duty = 0.25, amp = 0.22, decay = 40),
                    square(1319, 160, at = 200, duty = 0.125, amp = 0.22, decay = 120)], kind = "sfx")
    # お金: 硬貨の「チャリン」（高い 2 音を細い音で）。
    sound("gold", [square(1976, 50, duty = 0.125, amp = 0.22, decay = 30), square(2637, 200, at = 50, duty = 0.125, amp = 0.2, decay = 150)], kind = "sfx")
    # 床のスイッチ: 沈む「カチッ」と、仕掛けの「ゴトン」（レバーより低く重い）。
    sound("plate", [hiss(20, amp = 0.3, hz = 4000, decay = 10), square(98, 120, at = 30, duty = 0.5, amp = 0.32, decay = 80, to_hz = 73),
                    hiss(100, at = 30, amp = 0.2, hz = 600, decay = 70)], kind = "sfx")
    # 宿: 泊まって朝になる子守歌（ゆっくり 6 音。暗転の 1.2 秒 × 2 に収める）。
    sound("inn", [square(523, 300, duty = 0.5, amp = 0.2, decay = 260), square(659, 300, at = 300, duty = 0.5, amp = 0.2, decay = 260),
                  square(784, 300, at = 600, duty = 0.5, amp = 0.2, decay = 260), square(659, 300, at = 900, duty = 0.5, amp = 0.2, decay = 260),
                  square(698, 300, at = 1200, duty = 0.5, amp = 0.2, decay = 260), square(1047, 700, at = 1500, duty = 0.25, amp = 0.2, decay = 500),
                  square(262, 1200, duty = 0.5, amp = 0.12, decay = 900), square(349, 1000, at = 1200, duty = 0.5, amp = 0.12, decay = 700)], kind = "sfx")

    # ── 戦い ──
    # 出会い: 上がって回る「シュイン シュイン」（滑る音を 3 回、だんだん高く）。
    sound("encounter", [square(220, 120, duty = 0.25, amp = 0.25, decay = 0, to_hz = 1760), square(330, 120, at = 130, duty = 0.25, amp = 0.25, decay = 0, to_hz = 2637),
                        square(440, 180, at = 260, duty = 0.125, amp = 0.25, decay = 140, to_hz = 3520)], kind = "sfx")
    # ボスの登場: 低い唸りと、半音でぶつかる下がる 2 音（不穏）。
    sound("boss", [square(55, 900, duty = 0.5, amp = 0.3, decay = 700, attack = 20), hiss(900, amp = 0.2, hz = 400, decay = 600, attack = 20),
                   square(370, 400, at = 100, duty = 0.25, amp = 0.2, decay = 300, to_hz = 330), square(349, 500, at = 500, duty = 0.25, amp = 0.2, decay = 400, to_hz = 233)], kind = "sfx")
    # 攻撃が当たった: 振る「シュッ」と叩く「ドッ」。
    sound("attack", [hiss(60, amp = 0.3, hz = 5000, decay = 40), hiss(90, at = 50, amp = 0.35, hz = 1200, decay = 50),
                     square(196, 80, at = 50, duty = 0.5, amp = 0.3, decay = 50, to_hz = 82)], kind = "sfx")
    # 会心: 高い「キン」と、強く 2 度叩く。
    sound("critical", [square(2093, 60, duty = 0.125, amp = 0.25, decay = 40), hiss(90, at = 40, amp = 0.4, hz = 2000, decay = 60),
                       square(165, 90, at = 40, duty = 0.5, amp = 0.32, decay = 60, to_hz = 65), hiss(110, at = 140, amp = 0.4, hz = 1500, decay = 80),
                       square(147, 120, at = 140, duty = 0.5, amp = 0.32, decay = 80, to_hz = 55)], kind = "sfx")
    # 仲間が叩かれた: 重い「ドスッ」（低い雑音と、深く下がる音）。
    sound("hurt", [hiss(140, amp = 0.4, hz = 800, decay = 90), square(131, 160, duty = 0.5, amp = 0.32, decay = 110, to_hz = 49)], kind = "sfx")
    # 呪文 炎: 燃え上がる「ゴォッ」（雑音が開いていき、下で音が上がる）。
    sound("spell_fire", [hiss(140, amp = 0.25, hz = 900, decay = 0, attack = 30), hiss(320, at = 120, amp = 0.38, hz = 3500, decay = 200),
                         square(110, 380, duty = 0.5, amp = 0.2, decay = 260, to_hz = 330, attack = 20)], kind = "sfx")
    # 呪文 氷: 高い音が降ってきて凍る「キラキラ」（下がる 5 音と、細い雑音）。
    sound("spell_ice", [square(2637, 60, duty = 0.125, amp = 0.2, decay = 45), square(2349, 60, at = 60, duty = 0.125, amp = 0.2, decay = 45),
                        square(2093, 60, at = 120, duty = 0.125, amp = 0.2, decay = 45), square(1760, 60, at = 180, duty = 0.125, amp = 0.2, decay = 45),
                        square(1568, 260, at = 240, duty = 0.125, amp = 0.2, decay = 200), hiss(420, amp = 0.12, hz = 6000, decay = 300)], kind = "sfx")
    # 回復（呪文と道具）: 上がる分散和音（C E G C）を 2 本の矩形波で 8 分ずらして。
    sound("heal", [square(1047, 70, duty = 0.25, amp = 0.2, decay = 50), square(1319, 70, at = 70, duty = 0.25, amp = 0.2, decay = 50),
                   square(1568, 70, at = 140, duty = 0.25, amp = 0.2, decay = 50), square(2093, 260, at = 210, duty = 0.25, amp = 0.2, decay = 200),
                   square(523, 420, duty = 0.5, amp = 0.12, decay = 300, attack = 30)], kind = "sfx")
    # 眠り: ゆっくり下がって溶ける「ふわー」（2 音の滑り）。
    sound("sleep", [square(784, 420, duty = 0.5, amp = 0.18, decay = 350, to_hz = 392, attack = 30),
                    square(587, 420, at = 200, duty = 0.25, amp = 0.14, decay = 350, to_hz = 294, attack = 30)], kind = "sfx")
    # 逃げる: 速く下がる足音「タタタッ」。
    sound("flee", [square(1175, 60, duty = 0.25, amp = 0.22, decay = 0, to_hz = 587), square(988, 60, at = 70, duty = 0.25, amp = 0.22, decay = 0, to_hz = 494),
                   square(784, 90, at = 140, duty = 0.25, amp = 0.22, decay = 60, to_hz = 330), hiss(200, amp = 0.1, hz = 2000, decay = 150)], kind = "sfx")
    # 敵を倒した: 崩れる雑音と、深く下がる音（「シュワーン」）。
    sound("foe_down", [hiss(300, amp = 0.32, hz = 2500, decay = 220), square(659, 320, duty = 0.25, amp = 0.22, decay = 250, to_hz = 98)], kind = "sfx")
    # 全滅: 下がる 4 音をゆっくり（暗い短調）。
    sound("wiped", [square(440, 280, duty = 0.5, amp = 0.2, decay = 240), square(415, 280, at = 300, duty = 0.5, amp = 0.2, decay = 240),
                    square(392, 280, at = 600, duty = 0.5, amp = 0.2, decay = 240), square(370, 900, at = 900, duty = 0.5, amp = 0.2, decay = 700),
                    square(147, 1600, duty = 0.5, amp = 0.15, decay = 1200)], kind = "sfx")
    # レベルアップ: 跳ねて上がる短いファンファーレ（G C E G - C）。
    sound("level_up", [square(784, 90, duty = 0.5, amp = 0.2, decay = 70), square(1047, 90, at = 100, duty = 0.5, amp = 0.2, decay = 70),
                       square(1319, 90, at = 200, duty = 0.5, amp = 0.2, decay = 70), square(1568, 90, at = 300, duty = 0.5, amp = 0.2, decay = 70),
                       square(2093, 500, at = 420, duty = 0.25, amp = 0.2, decay = 400),
                       square(523, 300, at = 420, duty = 0.5, amp = 0.14, decay = 260), square(659, 400, at = 420, duty = 0.5, amp = 0.12, decay = 330)], kind = "sfx")

    # 勝った: 上がる 2 小節とのばした和音（旋律・3 度下の和音・低い音の 3 本。勝ちの伝言の間に鳴り終える）。
    E = 110
    sound("fanfare", melody([(784, E), (784, E), (784, E), (1047, 3 * E), (0, 2 * E),
                             (880, E), (988, E), (1047, E), (1175, E), (1319, 2 * E), (1175, E), (1319, E), (1568, 7 * E)], duty = 0.5, amp = 0.22) +
                     melody([(659, E), (659, E), (659, E), (784, 3 * E), (0, 2 * E),
                             (698, E), (784, E), (880, E), (988, E), (1047, 2 * E), (988, E), (1047, E), (1319, 7 * E)], duty = 0.25, amp = 0.14) +
                     melody([(131, E), (131, E), (131, E), (131, 3 * E), (0, 2 * E),
                             (175, 2 * E), (196, 2 * E), (131, 2 * E), (196, 2 * E), (131, 7 * E)], duty = 0.5, amp = 0.18), kind = "sfx")
main()
