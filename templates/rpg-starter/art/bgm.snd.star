# ルーネの泉の曲（タイトル・村・ワールドマップ・坑道・戦い・ボス戦）。勝った時のファンファーレは効果音の側（art/sfx.snd.star）。
# bin/fge snd build art/bgm.snd.star で譜面（メモリの中）から鳴らし、検査を通った物を atelier/bgm/<名前>.wav へ書く
# （採用した物を assets/bgm へ移し、project.json の sounds に載せる）。曲は頭 + 輪のループ点つき。
# FC の音源に寄せる: 矩形波 2 本（旋律・和音）+ 三角波（ベース）+ 雑音（太鼓）。reverb・pan など機種の外の手は使わない。
# 鳴らす所は Controls.musicOf（場面とマップの bgm → 曲の名前）。

INSTRUMENTS = {
    # 旋律: 山の割合 0.5 の太い音。離すと短く尾を引く。
    "lead": {"duty": "50", "vol": "13 12 11 | 10 / 7 4 2 0"},
    # 柔らかい旋律（村・坑道）: 山の割合 0.25 で少し遅れて揺れる。
    "soft": {"duty": "25", "vol": "11 10 9 | 8 / 5 3 1 0", "vib": "5 12 18"},
    # 和音の分散・刻み: 細い音を小さく。
    "pluck": {"duty": "12", "vol": "8 6 4 3 2 1 0"},
    "stab": {"duty": "25", "vol": "9 8 6 | 5 / 2 0"},
    # ベース（三角波）。
    "tri": {"vol": "15 | 15 / 0"},
    # 太鼓（雑音）。
    "kick": {"duty": "long", "vol": "15 11 7 3 0"},
    "snare": {"duty": "short", "vol": "13 10 7 5 3 1 0"},
    "hat": {"duty": "short", "vol": "6 3 0"},
}

# 4 本を足すと ±1 を超えるので、譜面の全体を下げてから normalize で曲の音量（-16 LUFS）へ戻す。
GAIN = 0.4

KIT = {"kick": "C-3 kick", "snare": "D-5 snare", "hat": "C-7 hat"}

def channels(lead = 0.55, harmony = 0.32, bass = 0.6, drums = 0.32):
    return [{"name": "pulse1", "part": "pulse", "vol": lead}, {"name": "pulse2", "part": "pulse", "vol": harmony},
            {"name": "triangle", "part": "triangle", "vol": bass}, {"name": "noise", "part": "noise", "vol": drums}]

def song(name, chip):
    snd.write_spec("//art/bgm/%s.sndsrc.json" % name, {
        "version": 1,
        "target": "//atelier/bgm/%s.wav" % name,
        "kind": "bgm",
        "style": "free",
        "channels": "mono",
        "voices": [{"ops": [op.song(chip = chip)]}],
        "post": [op.normalize(lufs = -16)],
    })

def beat(pattern, bars):
    return mus.drums(pattern, KIT) * bars

def title():
    # タイトル: ハ長調・行進の速さ。頭 1 小節（和音を打つ）+ 8 小節の輪。
    p = mus.chords("C | Am | F | G | C | Am | F G | C")
    mel = mus.mml("o5 c4. g8 g4 e4 | a4. g8 e4 c4 | f4. a8 o6 c4 o5 a4 | g2. r4 | c4. g8 g4 o6 c4 | o5 e4. d8 c4 o4 a4 | o5 f4 a4 g4 b4 | o6 c2 o5 g8 a8 b8 g8", inst = "lead")
    snd.write_chip("//art/bgm/bgm_title.chip.json", {
        "bpm": 100, "gain": GAIN, "channels": channels(), "instruments": INSTRUMENTS,
        "intro": {"pulse1": mus.mml("o5 c8 r8 c8 r8 c4 r4", inst = "stab"), "pulse2": mus.mml("o4 g8 r8 g8 r8 g4 r4", inst = "stab"),
                  "triangle": mus.mml("o3 c8 r8 c8 r8 c4 r4", inst = "tri"), "noise": beat({"snare": "x.x.x...........", "kick": "x.x.x..........."}, 1)},
        "body": {"pulse1": mel,
                 "pulse2": mus.arp(p, [0, 1, 2, 1], "x.x.x.x.x.x.x.x.", inst = "pluck", octave = 4),
                 "triangle": mus.bass(p, "x---x---x---x---", ["1", "5"], inst = "tri"),
                 "noise": beat({"kick": "x.......x.......", "snare": "....x.......x...", "hat": "..x...x...x...x."}, 8)},
    })
    song("bgm_title", "//art/bgm/bgm_title.chip.json")

def village():
    # 村: ヘ長調・ゆったり。太鼓は使わず、細い分散和音で揺らす。
    p = mus.chords("F | C | Dm | Bb C | F | Bb | Gm C | F")
    mel = mus.mml("o5 a4. g8 f4 c4 | e4. f8 g4 c4 | d4 f4 a4 o6 c4 | o5 b-4. a8 g4 c4 | a4. g8 f4 a4 | b-4. o6 c8 d4 o5 b-4 | g4 b-4 o6 c4 o5 e4 | f2. r4", inst = "soft")
    snd.write_chip("//art/bgm/bgm_village.chip.json", {
        "bpm": 88, "gain": GAIN, "channels": channels(lead = 0.5, harmony = 0.3, bass = 0.55, drums = 0.0), "instruments": INSTRUMENTS,
        "body": {"pulse1": mel,
                 "pulse2": mus.arp(p, [0, 1, 2, 3, 2, 1, 0, 1], "x.x.x.x.x.x.x.x.", inst = "pluck", octave = 4),
                 "triangle": mus.bass(p, "x-------x-------", ["1", "5"], inst = "tri"),
                 "noise": mus.rest(8)},
    })
    song("bgm_village", "//art/bgm/bgm_village.chip.json")

def world():
    # ワールドマップ: ト長調・前へ進む行進。
    p = mus.chords("G | D | Em | C D | G | Bm | C D | G")
    mel = mus.mml("o5 g4 d8 g8 b4 o6 d4 | c4. o5 b8 a4 f+4 | g4. f+8 e4 b4 | o6 c4 o5 g4 a4 f+4 | g4 d8 g8 b4 o6 d4 | f+4. e8 d4 o5 b4 | o6 e4 c4 d4 o5 a4 | g2. r4", inst = "lead")
    snd.write_chip("//art/bgm/bgm_world.chip.json", {
        "bpm": 120, "gain": GAIN, "channels": channels(), "instruments": INSTRUMENTS,
        "body": {"pulse1": mel,
                 "pulse2": mus.comp(p, "x.x.x.x.x.x.x.x.", inst = "stab", octave = 4),
                 "triangle": mus.bass(p, "x---x---x---x---", ["1", "5", "8", "5"], inst = "tri"),
                 "noise": beat({"kick": "x.......x.......", "snare": "....x.......x...", "hat": "..x...x...x...x."}, 8)},
    })
    song("bgm_world", "//art/bgm/bgm_world.chip.json")

def mine():
    # 坑道: ニ短調・遅く暗く。旋律は低く、もう 1 本の矩形波が少し遅れて同じ旋律を返す（坑道の響き）。太鼓は水の滴りだけ。
    p = mus.chords("Dm | Dm | Bb | A | Dm | Gm | Bb A | Dm")
    mel = mus.mml("o4 d2 r4 f8 e8 | d4. c+8 d2 | d4 f4 b-4 a8 g8 | a2. r4 | f2 r4 a8 g8 | g4. f8 e4 d4 | f4 d4 e4 c+4 | d2. r4", inst = "soft")
    snd.write_chip("//art/bgm/bgm_mine.chip.json", {
        "bpm": 76, "gain": GAIN, "channels": channels(lead = 0.5, harmony = 0.22, bass = 0.6, drums = 0.18), "instruments": INSTRUMENTS,
        "body": {"pulse1": mel,
                 "pulse2": mus.echo(mel, steps = 3, vol = -4, inst = "soft"),
                 "triangle": mus.bass(p, "x-------x-------", ["1", "-5"], inst = "tri"),
                 "noise": beat({"hat": "......x.........", "kick": "x..............."}, 8)},
    })
    song("bgm_mine", "//art/bgm/bgm_mine.chip.json")

def battle():
    # 戦い: イ短調・速い。頭 1 小節で駆け上がって、8 小節の輪。
    p = mus.chords("Am | F | G | E | Am | F | Dm E | Am")
    mel = mus.mml("o5 a4 e8 a8 o6 c4 o5 b8 a8 | f4 a8 o6 c8 f4 e8 c8 | o5 g4 b8 o6 d8 g4 f8 d8 | o5 e2 g+4 b4 | a4 e8 a8 o6 c4 e4 | f4 e8 d8 c4 o5 a4 | d4 f4 e4 g+4 | a2 r8 e8 a8 b8", inst = "lead")
    snd.write_chip("//art/bgm/bgm_battle.chip.json", {
        "bpm": 150, "gain": GAIN, "channels": channels(), "instruments": INSTRUMENTS,
        "intro": {"pulse1": mus.mml("o5 e16 e16 e8 g8 a8 b4 o6 c4", inst = "lead"), "pulse2": mus.mml("o4 a16 a16 a8 b8 o5 c8 d4 e4", inst = "stab"),
                  "triangle": mus.mml("o2 a8 a8 a8 a8 a8 a8 e8 e8", inst = "tri"), "noise": beat({"kick": "x.x.x.x.x.x.x.x.", "snare": "............xxxx"}, 1)},
        "body": {"pulse1": mel,
                 "pulse2": mus.comp(p, "x.x.x.x.x.x.x.x.", inst = "stab", octave = 4),
                 "triangle": mus.bass(p, "x-x-x-x-x-x-x-x-", ["1", "8"], inst = "tri"),
                 "noise": beat({"kick": "x...x...x...x...", "snare": "....x.......x...", "hat": "..x...x...x...x."}, 8)},
    })
    song("bgm_battle", "//art/bgm/bgm_battle.chip.json")

def boss():
    # ボス戦: ニ短調・もっと速く、増 4 度と半音でぶつける。頭 2 小節の刻みで迫ってから 8 小節の輪。
    p = mus.chords("Dm | Dm | Bb | C | Dm | Eb | C | A")
    mel = mus.mml("o5 d4 a4 g+4 a4 | d8 e8 f8 g8 a4 r4 | b-4. a8 f4 d4 | e4. f8 g4 e4 | d4 a4 g+4 a4 | b-4 g4 e-4 g4 | o6 c4 o5 g4 e4 c4 | c+2 e4 a4", inst = "lead")
    snd.write_chip("//art/bgm/bgm_boss.chip.json", {
        "bpm": 160, "gain": GAIN, "channels": channels(lead = 0.55, harmony = 0.3, bass = 0.65, drums = 0.35), "instruments": INSTRUMENTS,
        "intro": {"pulse1": mus.mml("o4 d16 d16 d16 d16 d4 r8 d16 d16 d4 | e-16 e-16 e-16 e-16 e-4 r8 c+16 c+16 c+4", inst = "lead"),
                  "pulse2": mus.mml("o4 a16 a16 a16 a16 a4 r8 a16 a16 a4 | b-16 b-16 b-16 b-16 b-4 r8 g+16 g+16 g+4", inst = "stab"),
                  "triangle": mus.mml("o2 d8 d8 d8 d8 d8 d8 d8 d8 | e-8 e-8 e-8 e-8 c+8 c+8 c+8 c+8", inst = "tri"),
                  "noise": beat({"kick": "x...x...x...x...", "snare": "............x.x."}, 2)},
        "body": {"pulse1": mel,
                 "pulse2": mus.comp(p, "x.xx.xx.x.xx.xx.", inst = "stab", octave = 4),
                 "triangle": mus.bass(p, "x-x-x-x-x-x-x-x-", ["1", "1", "8", "1"], inst = "tri"),
                 "noise": beat({"kick": "x.x...x.x.x...x.", "snare": "....x.......x...", "hat": "xxxxxxxxxxxxxxxx"}, 8)},
    })
    song("bgm_boss", "//art/bgm/bgm_boss.chip.json")

def main():
    title()
    village()
    world()
    mine()
    battle()
    boss()
main()
