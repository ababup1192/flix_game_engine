# 盤の出来事の効果音（Controls.Sound）。bin/fge snd build art/sfx.snd.star で art/sfx/*.sndsrc.json を書き、
# 検査を通った物を atelier/sfx/<名前>.wav へ書く（案。採用して assets/sfx へ移し project.json の sounds に載せるのは人が決める）。
# 紙と鉛筆の盤なので、角の立たない矩形波を短く・低めに。1〜3 行消しは高さ違いの 2 本（Hash01.pickBy で選ぶ）。

def note(hz, ms, at = 0, amp = 0.4, duty = 0.25, to_hz = None, decay = 60):
    ops = [op.pulse(hz = hz, ms = ms, amp = amp, duty = duty, to_hz = to_hz, accumulate = to_hz != None),
           op.env(attack_ms = 1, decay_ms = decay)]
    return {"at": at, "ops": ops}

def sound(name, voices, post = []):
    snd.write_spec("//art/sfx/%s.sndsrc.json" % name, {
        "version": 1,
        "target": "//atelier/sfx/%s.wav" % name,
        "kind": "sfx",
        "style": "free",
        "voices": voices,
        "post": post + [op.finish(), op.normalize(lufs = -20)],
    })

def main():
    # 固めた: 低い鈍い当たり + 紙を叩く短い雑音。
    sound("lock", [note(147, 70, decay = 25),
                   {"at": 0, "ops": [op.noise(ms = 30, amp = 0.25), op.lowpass(hz = 2500, stages = 2), op.env(attack_ms = 0.5, decay_ms = 10)]}])
    # 1〜3 行消し: 短く上がる 2 音（A は C6 → G6・B は D6 → A6）。
    sound("line_a", [note(1047, 60, decay = 50), note(1568, 110, at = 55, decay = 70)])
    sound("line_b", [note(1175, 60, decay = 50), note(1760, 110, at = 55, decay = 70)])
    # 4 行消し: 上がる 4 音のアルペジオに軽い返り。
    sound("tetris", [note(1047, 80, at = 0), note(1319, 80, at = 70), note(1568, 80, at = 140), note(2093, 220, at = 210, decay = 140)],
          post = [op.delay(ms = 110, feedback = 0.3, wet = 0.2)])
    # GAME OVER: ゆっくり下がる 1 本。
    sound("over", [note(440, 700, to_hz = 110, duty = 0.5, decay = 400)])

main()
