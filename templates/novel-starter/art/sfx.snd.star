# 決定・カーソルへの返事の音と、灯りが消える演出の音（Controls.Sound と LampFx）。
# bin/fge snd build art/sfx.snd.star で art/sfx/*.sndsrc.json を書き、検査を通った物を atelier/sfx/<名前>.wav へ書く
# （案。採用して assets/sfx へ移し project.json の sounds に載せるのは人が決める）。
# 雨の夜の書斎なので、返事は小さく柔らかい正弦に近い音（矩形波の山を細くして低域を絞る）・響きを少し。

def tone(hz, ms, at = 0, amp = 0.4, decay = 80, to_hz = None):
    return {"at": at, "ops": [op.pulse(hz = hz, ms = ms, amp = amp, duty = 0.5, to_hz = to_hz, accumulate = to_hz != None),
                              op.lowpass(hz = hz * 2, stages = 2),
                              op.env(attack_ms = 3, decay_ms = decay)]}

def hiss(ms, at = 0, amp = 0.3, hz = 2000, decay = 40):
    return {"at": at, "ops": [op.noise(ms = ms, amp = amp), op.lowpass(hz = hz, stages = 2), op.env(attack_ms = 2, decay_ms = decay)]}

def sound(name, voices, kind = "ui", room = 0.4, wet = 0.12):
    snd.write_spec("//art/sfx/%s.sndsrc.json" % name, {
        "version": 1,
        "target": "//atelier/sfx/%s.wav" % name,
        "kind": kind,
        "style": "free",
        "voices": voices,
        "post": [op.reverb(room = room, wet = wet), op.finish(), op.normalize(lufs = -22 if kind == "ui" else -20)],
    })

def main():
    sound("open", [tone(523, 160), tone(784, 260, at = 90, decay = 160)])          # 表紙から: C5 → G5
    sound("reveal", [tone(1568, 30, decay = 12, amp = 0.25)])                      # 全文を出した: ごく短い粒
    sound("page", [hiss(70, amp = 0.35, hz = 3000, decay = 30)])                   # 頁を送る: 紙の擦れ
    sound("end", [tone(784, 200), tone(659, 200, at = 160), tone(523, 420, at = 320, decay = 260)], room = 0.6, wet = 0.2)
    sound("move", [tone(1047, 25, decay = 10, amp = 0.25)])                         # カーソル: 軽い粒
    sound("pick", [tone(659, 90, decay = 50), tone(988, 160, at = 70, decay = 90)]) # 選んだ: E5 → B5
    sound("doubt", [tone(220, 380, decay = 220), tone(233, 380, decay = 220)], room = 0.6, wet = 0.2)  # 疑う: 短 2 度のうなり
    # 灯りが揺らいで細る 0.5 秒（LampFx の Flicker）と、消えて部屋が沈む一打（Dark の頭）。
    sound("lamp_flicker", [hiss(500, amp = 0.3, hz = 900, decay = 220), tone(110, 500, amp = 0.2, decay = 200, to_hz = 82)],
          kind = "sfx", room = 0.5, wet = 0.15)
    sound("lamp_out", [tone(98, 260, decay = 120), hiss(90, amp = 0.25, hz = 600, decay = 40)], kind = "sfx", room = 0.7, wet = 0.25)

main()
