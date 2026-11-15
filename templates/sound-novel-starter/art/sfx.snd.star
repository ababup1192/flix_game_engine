# 返事の音 5 つ（Controls.soundOf）。
# bin/fge snd build art/sfx.snd.star で art/sfx/*.sndsrc.json を書き、検査を通った物を atelier/sfx/<名前>.wav へ書く
# （採用した物を assets/sfx へ移し、project.json の sounds に載せる）。
# 冬の風の環境音は合成でなく実際の録音（効果音ラボ。出典は CREDITS.md）。
# 返事の音は正弦に近い柔らかい音（矩形波を音の高さで 4 段絞って倍音を落とす）にし、ゲームの電子音に聞こえさせない。
# 演出の効果音を合成で足す時は、sound(名前, [...], kind = "sfx") の形で足す（hiss・bell・rustle の組み合わせ）。

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
    sound("ui_page", [rustle(140, 2600, 1400, amp = 0.5, decay = 55, attack = 18)])                 # 戻る（ロールバック）: 紙の擦れ。文の送りは鳴らさない（Controls.soundOf）
    sound("ui_cursor", [sine(1568, 40, amp = 0.25, decay = 14, attack = 2)])                         # カーソル: 小さな木の粒
    sound("ui_choice", bell(880, decay = 220) + bell(1319, at = 90, amp = 0.32, decay = 300))       # 選んだ: 柔らかい鈴を 2 つ
    sound("ui_open", bell(659, decay = 160, partials = [(1.0, 1.0, 1.0), (3.0, 0.12, 0.3)]))         # 窓を開く: 低い木琴の 1 打
    sound("ui_save", bell(1047, decay = 220) + bell(1319, at = 110, amp = 0.3, decay = 240) +
                     bell(1568, at = 220, amp = 0.28, decay = 420), room = 0.5, wet = 0.18)          # セーブした: 上がる 3 つの鈴

main()
