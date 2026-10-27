# 環境音 4 本（ループ）と、演出の音 2 つ・返事の音 5 つ（Controls.soundOf と、台本の <<se>> <<ambience>>）。
# bin/fge snd build art/sfx.snd.star で art/sfx/*.sndsrc.json を書き、検査を通った物を atelier/sfx/<名前>.wav へ書く
# （採用した物を assets/sfx へ移し、project.json の sounds に載せる）。
# 田舎の夏なので、主役は環境音。返事の音は小さく柔らかく（矩形波を細く絞って正弦に寄せる）、読む邪魔をしない。
# 環境音は継ぎ目が出ないよう、頭と尾を絞らない（finish を掛けない）。鳴き声は輪の長さの内に収める。

def tone(hz, ms, at = 0, amp = 0.4, decay = 80, to_hz = None, attack = 3):
    return {"at": at, "ops": [op.pulse(hz = hz, ms = ms, amp = amp, duty = 0.5, to_hz = to_hz, accumulate = to_hz != None),
                              op.lowpass(hz = hz * 2, stages = 2),
                              op.env(attack_ms = attack, decay_ms = decay)]}

def hiss(ms, at = 0, amp = 0.3, hz = 2000, decay = 40, attack = 2):
    return {"at": at, "ops": [op.noise(ms = ms, amp = amp), op.lowpass(hz = hz, stages = 2), op.env(attack_ms = attack, decay_ms = decay)]}

# 途切れない雑音の床（風・水）。env は掛けない。
def bed(ms, amp, hz, stages = 2):
    return {"at": 0, "ops": [op.noise(ms = ms, amp = amp), op.lowpass(hz = hz, stages = stages)]}

def sound(name, voices, kind = "ui", room = 0.4, wet = 0.12):
    snd.write_spec("//art/sfx/%s.sndsrc.json" % name, {
        "version": 1,
        "target": "//atelier/sfx/%s.wav" % name,
        "kind": kind,
        "style": "free",
        "voices": voices,
        "post": [op.reverb(room = room, wet = wet), op.finish(), op.normalize(lufs = -22 if kind == "ui" else -20)],
    })

def ambience(name, ms, voices, room = 0.5, wet = 0.2):
    snd.write_spec("//art/sfx/%s.sndsrc.json" % name, {
        "version": 1,
        "target": "//atelier/sfx/%s.wav" % name,
        "kind": "bgm",
        "style": "free",
        "loop_start_ms": 0,
        "voices": voices,
        "post": [op.reverb(room = room, wet = wet), op.normalize(lufs = -19)],
    })

# 蜩（ひぐらし）の「カナカナカナ」: 短い粒を細かく刻み、だんだん低く弱くなる 1 声。
def higurashi(at, base, count = 14, amp = 0.3):
    return [tone(base - i * 18, 55, at = at + i * 85, amp = amp * (1.0 - i * 0.05), decay = 30, to_hz = base - i * 18 - 260)
            for i in range(count)]

# 鈴虫・蟋蟀の「リーン」: 高い粒を 3 つずつ。
def cricket(at, hz, amp = 0.16):
    return [tone(hz, 40, at = at + i * 55, amp = amp, decay = 22) for i in range(3)]

# 朝の小鳥: 上へ跳ねる短い声を 2〜3 つ。
def bird(at, hz, amp = 0.22):
    return [tone(hz, 70, at = at, amp = amp, decay = 40, to_hz = hz * 1.35),
            tone(hz * 1.2, 60, at = at + 110, amp = amp * 0.8, decay = 35, to_hz = hz * 0.9),
            tone(hz * 1.1, 90, at = at + 230, amp = amp * 0.7, decay = 50, to_hz = hz * 1.5)]

def main():
    # 夕方の駅と畦道（12 秒）: 遠くの風と、ずれて重なる蜩 3 声。
    ambience("amb_evening", 12000,
             [bed(12000, 0.10, 500)] + higurashi(400, 4300) + higurashi(4700, 4050, amp = 0.2) + higurashi(8300, 4450, count = 10, amp = 0.14))
    # 夜の縁側（8 秒）: 低い風と、2 種の虫の声が 0.6 秒ごと。
    ambience("amb_night", 8000,
             [bed(8000, 0.08, 400)] +
             [v for i in range(13) for v in cricket(i * 600 + 40, 4700)] +
             [v for i in range(5) for v in cricket(i * 1500 + 330, 3900, amp = 0.1)])
    # 蛍の川（8 秒）: 低い水の流れと、高い所のさざめき。
    ambience("amb_river", 8000,
             [bed(8000, 0.35, 700, stages = 3), bed(8000, 0.06, 2600)] +
             [hiss(140, at = 300 + i * 610, amp = 0.08, hz = 1800, decay = 60, attack = 30) for i in range(12)],
             room = 0.6, wet = 0.25)
    # 朝の駅（10 秒）: 澄んだ風と、まばらな小鳥。
    ambience("amb_morning", 10000,
             [bed(10000, 0.06, 900)] + bird(600, 2600) + bird(3100, 3000, amp = 0.16) + bird(5400, 2400) + bird(8200, 2800, amp = 0.14))

    # 手を打つ（坂道で千夏が背中を叩く）: 乾いた雑音の一打と、低い胴の鳴り。
    sound("se_slap", [hiss(90, amp = 0.6, hz = 4000, decay = 25, attack = 0.5), tone(180, 80, amp = 0.3, decay = 30)], kind = "sfx", room = 0.3, wet = 0.08)
    # 風鈴: 高い 2 音が長く残る。
    sound("se_furin", [tone(2093, 1400, amp = 0.3, decay = 600), tone(2637, 1300, at = 40, amp = 0.2, decay = 520),
                       tone(2093, 1000, at = 700, amp = 0.15, decay = 450)], kind = "sfx", room = 0.7, wet = 0.3)

    sound("ui_page", [hiss(70, amp = 0.35, hz = 3000, decay = 30)])                       # 頁を送る: 紙の擦れ
    sound("ui_cursor", [tone(1047, 25, decay = 10, amp = 0.25)])                           # カーソル: 軽い粒
    sound("ui_choice", [tone(659, 90, decay = 50), tone(988, 160, at = 70, decay = 90)])   # 選んだ: E5 → B5
    sound("ui_open", [tone(523, 120, decay = 60), tone(784, 200, at = 70, decay = 120)])   # 窓を開く: C5 → G5
    sound("ui_save", [tone(784, 120, decay = 60), tone(1047, 260, at = 90, decay = 160)], room = 0.5, wet = 0.18)  # セーブした

main()
