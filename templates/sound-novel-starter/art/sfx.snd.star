# 演出の音 2 つ・返事の音 5 つ・川の環境音（Controls.soundOf と、台本の <<se>> <<ambience>>）。
# bin/fge snd build art/sfx.snd.star で art/sfx/*.sndsrc.json を書き、検査を通った物を atelier/sfx/<名前>.wav へ書く
# （採用した物を assets/sfx へ移し、project.json の sounds に載せる）。
# 夕方の蜩・夜の鈴虫・朝の鶯は合成でなく実際の録音（Wikimedia Commons。出典と切り出した所は CREDITS.md）。
# 虫の声は矩形波の粒を並べるとブザーに聞こえる（倍音が高い所まで梯子に立ち、粒ごとに頭がはじける）ので、合成しない。
# 返事の音は正弦に近い柔らかい音（矩形波を音の高さで 4 段絞って倍音を落とす）にし、ゲームの電子音に聞こえさせない。

def sine(hz, ms, at = 0, amp = 0.4, decay = 80, to_hz = None, attack = 4):
    return {"at": at, "ops": [op.pulse(hz = hz, ms = ms, amp = amp, duty = 0.5, to_hz = to_hz, accumulate = to_hz != None),
                              op.lowpass(hz = hz, stages = 4),
                              op.env(attack_ms = attack, decay_ms = decay)]}

# 鈴の 1 打: 高さの比が整数に並ばない部分音を、高い物ほど速く消す（金属や硝子の鳴り）。
def bell(hz, at = 0, amp = 0.4, decay = 400, partials = [(1.0, 1.0, 1.0), (2.76, 0.35, 0.45), (5.40, 0.14, 0.25)]):
    return [sine(hz * ratio, int(decay * d * 7), at = at, amp = amp * a, decay = decay * d, attack = 2) for (ratio, a, d) in partials]

def hiss(ms, at = 0, amp = 0.3, hz = 2000, decay = 40, attack = 2):
    return {"at": at, "ops": [op.noise(ms = ms, amp = amp), op.lowpass(hz = hz, stages = 2), op.env(attack_ms = attack, decay_ms = decay)]}

# 帯域を絞った雑音の粒（紙の擦れ・水のはじけ）。
def rustle(ms, hz, to_hz, at = 0, amp = 0.4, decay = 40, attack = 6, q = 0.5):
    return {"at": at, "ops": [op.noise(ms = ms, amp = amp), op.svf(hz = hz, to_hz = to_hz, q = q),
                              op.env(attack_ms = attack, decay_ms = decay)]}

# 途切れない雑音の床（水の流れ）。env は掛けない。
def bed(ms, amp, hz, stages = 2):
    return {"at": 0, "ops": [op.noise(ms = ms, amp = amp), op.lowpass(hz = hz, stages = stages)]}

def sound(name, voices, kind = "ui", room = 0.4, wet = 0.12):
    snd.write_spec("//art/sfx/%s.sndsrc.json" % name, {
        "version": 1,
        "target": "//atelier/sfx/%s.wav" % name,
        "kind": kind,
        "rate": 44100,
        "style": "free",
        "voices": voices,
        "post": [op.reverb(room = room, wet = wet), op.finish(), op.normalize(lufs = -24 if kind == "ui" else -20)],
    })

def ambience(name, ms, voices, room = 0.5, wet = 0.2):
    snd.write_spec("//art/sfx/%s.sndsrc.json" % name, {
        "version": 1,
        "target": "//atelier/sfx/%s.wav" % name,
        "kind": "bgm",
        "rate": 44100,
        "style": "free",
        "loop_start_ms": 0,
        "voices": voices,
        "post": [op.reverb(room = room, wet = wet), op.normalize(lufs = -18, peak_dbtp = -2)],
    })

def main():
    # 蛍の川（12 秒）: 低く籠もった流れと、高さのばらばらな小さなはじけ（同じ間で並べると機械に聞こえる）。
    pops = [(130, 900), (470, 1500), (820, 700), (1290, 2100), (1610, 1100), (2240, 1800), (2580, 800), (3110, 1300),
            (3720, 2400), (4050, 950), (4630, 1600), (5200, 1200), (5480, 2000), (6120, 750), (6790, 1400), (7230, 1900),
            (7660, 1000), (8350, 2300), (8810, 850), (9420, 1700), (9990, 1250), (10540, 2050), (11080, 900), (11500, 1500)]
    ambience("amb_river", 12000,
             [bed(12000, 0.30, 600, stages = 3), bed(12000, 0.05, 1500)] +
             [rustle(60, hz, hz * 1.6, at = at, amp = 0.22, decay = 25, attack = 3, q = 0.25) for (at, hz) in pops],
             room = 0.6, wet = 0.25)

    # 手を打つ（坂道で千夏が背中を叩く）: 乾いた雑音の一打と、低い胴の鳴り。
    sound("se_slap", [hiss(90, amp = 0.6, hz = 4000, decay = 25, attack = 0.5), sine(180, 80, amp = 0.3, decay = 30)], kind = "sfx", room = 0.3, wet = 0.08)
    # 風鈴: 硝子の鈴を 2 度。2 度目は少し弱く、少し違う所を打つ（部分音の比を変える）。
    glass = [(1.0, 1.0, 1.0), (2.32, 0.4, 0.5), (4.25, 0.18, 0.3), (6.63, 0.08, 0.18)]
    sound("se_furin", bell(2350, amp = 0.35, decay = 520, partials = glass) +
                      bell(2350, at = 650, amp = 0.2, decay = 420, partials = [(1.0, 1.0, 1.0), (2.41, 0.5, 0.5), (4.1, 0.2, 0.3)]) +
                      [rustle(12, 6000, 6000, amp = 0.15, decay = 4, attack = 0.3, q = 0.3)],
          kind = "sfx", room = 0.7, wet = 0.3)

    sound("ui_page", [rustle(140, 2600, 1400, amp = 0.5, decay = 55, attack = 18)])                 # 頁を送る: 紙の擦れ
    sound("ui_cursor", [sine(1568, 40, amp = 0.25, decay = 14, attack = 2)])                         # カーソル: 小さな木の粒
    sound("ui_choice", bell(880, decay = 220) + bell(1319, at = 90, amp = 0.32, decay = 300))       # 選んだ: 柔らかい鈴を 2 つ
    sound("ui_open", bell(659, decay = 160, partials = [(1.0, 1.0, 1.0), (3.0, 0.12, 0.3)]))         # 窓を開く: 低い木琴の 1 打
    sound("ui_save", bell(1047, decay = 220) + bell(1319, at = 110, amp = 0.3, decay = 240) +
                     bell(1568, at = 220, amp = 0.28, decay = 420), room = 0.5, wet = 0.18)          # セーブした: 上がる 3 つの鈴

main()
