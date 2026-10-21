# snd の op（fge snd ops --md が op の登録から作る。手で直さない）

音 1 本の指定は `<名前>.sndsrc.json`（形は docs/sndsrc.schema.json）。繰り返しは台本 `<名前>.snd.star` で書く。

- 声（voices の 1 つ）の ops は「音源の op 1 つ → 効果の op を順に」。声は `at` ミリ秒の所に置き、`pan`（-1 左・0 真ん中・1 右）で振って声の順に足す。`post` は足した後に順に掛ける効果の op。
- 書き出しはステレオ（`channels` の既定は `stereo`。`mono` で今までどおり 1 本）。左右の振り方は真ん中で両方 1・振り切ると片方 0。効果は左右に 1 本ずつ同じ式で掛ける（normalize・reverb・delay・finish は左右を一緒に見る）。
- `style` は機種の縛り（bin/lint-rules/snd.json の styles: `gb`・`neo`（チップの音色 + 今のミックス）・`free` は縛りなし）。機種の外の手（reverb・delay・sidechain・sub・pan と、今の音色 saw・sine・unison・filter・pitchenv・fm）は style の `breaks` にある物だけ書け、使えば report の `breaks` に「破った所」として残る。`kind`（ui・sfx・bgm）は音量の目安を選ぶ（normalize の既定）。
- ループ: song の op が譜面のループ点から決めるか、`loop_start_ms`。`tempo`（song は譜面の bpm）があれば輪が整数小節かを見る。
- 検査（左右を 1 本ずつ見る。音量は左右を足した LUFS で、ループする音は輪の 1 周）: gate = clip（±1 を超えた）・seam（継ぎ目）・bars（小節）・style（機種の外）。gate は「その op を外すと直る」op を原因として付ける。lint = loudness・peak・truepeak（4 倍に読み直したピーク）・head・tail・dc。advice = alias・breaks。
- 台本から呼べる物: `snd.write_spec(path, value)`・`snd.write_chip(path, value)`（曲を譜面に。下の節）・`snd.read_json(path)`（作業場の .json を読むだけ）・`op.<名前>(引数=…)`・`mus.*`（曲を書く部品。下の節）・`math`（正しく丸めた値）。箱の決まりは px の台本と同じ（starbox）。

| op | 種類 | 何をするか | 機種 |
|---|---|---|---|
| `noise` | 音源 | 雑音を ms ミリ秒。kind = hash（番号のハッシュの白色雑音）・lfsr15 / lfsr7（ゲームボーイの雑音。hz 回/秒で回す） | 雑音のチャンネル（ゲームボーイの ch4 は lfsr15・lfsr7） |
| `pulse` | 音源 | 矩形波を ms ミリ秒。to_hz を書くと hz から to_hz へ比が一定の速さで滑る | パルスのチャンネル（ゲームボーイの ch1・ch2。滑りは ch1 の sweep に当たる） |
| `rest` | 音源 | 無音を ms ミリ秒（声の長さをそろえる・曲の休符） | 無し（どの機種でも書ける） |
| `song` | 音源 | 譜面（*.chip.json）を楽器（譜面の中か *.instrument.json）で鳴らす。左右に振って混ぜ、ループ点があれば頭 + 輪の 1 本と smpl のループの頭を作る | 譜面のチャンネル（今の形は pulse1・pulse2 = パルス・triangle = 三角・noise = 雑音・wave = 波形メモリ。channels を書けば名前と部品を選べ、saw・sine も書ける）。使った部品を機種の縛りで数え、reverb・delay・sidechain・sub・pan・saw・sine・unison・filter・pitchenv・fm は style の breaks で見る |
| `delay` | 効果 | 帰還つきのディレイ（ms ごとに feedback 倍で返る。pingpong で左右に交互に返す・帰還の道で lowpass）を wet だけ足す | 無し（機種の外。機種の中なら song のチャンネルに遅らせた写しを置く） |
| `env` | 効果 | 立ち上がり attack_ms・hold_ms 保ってから decay_ms の速さで指数に減衰（decay_ms 0 は減衰なし） | 無し（ゲームボーイの音量は 16 段の steps） |
| `fade` | 効果 | 頭を 1 倍・終わりを 0 倍へ直線で先細らせる（times 回重ねると急になる） | 無し（ゲームボーイなら steps で書く） |
| `finish` | 効果 | 仕上げ: 尾の無音を切り、25Hz の低域切り・8kHz の 2 段ローパス・頭 in_ms と尾 out_ms の直線の絞りを掛け、ピークを 1 にそろえる | 無し（仕上げのフィルタは機種の外） |
| `gain` | 効果 | 音量を by 倍にする | 混ぜる段の音量（どの機種でも書ける） |
| `lowpass` | 効果 | 1 極のローパスを stages 段（hz より上をなだらかに落とす） | 無し（フィルタは機種の外） |
| `normalize` | 効果 | 統合ラウドネスを lufs にそろえ、true peak が peak_dbtp を超えるなら倍率を下げる（倍率だけ。ループする音は輪の 1 周で測る） | 混ぜる段の音量（どの機種でも書ける） |
| `rasp` | 効果 | 隣のサンプルとの差 × 0.7（低い成分を落とした擦れ。times 回重ねる） | 無し |
| `resample` | 効果 | ratio 倍の速さで読み直す（高さが ratio 倍・長さが 1/ratio。線形の補間） | 無し（読み直しは機種の外。ゲームボーイなら高さを書き直す） |
| `reverb` | 効果 | 部屋の響き（櫛形 8 本 + 全域通過 4 本の Freeverb 型。左右で長さをずらして広げる）を wet だけ足す | 無し（機種の外。スーファミのエコーより長い響き） |
| `steps` | 効果 | 音量を level/15 から every_ms ごとに 1 段ずつ下げる（0 で止まる。16 段の音量包絡） | ゲームボーイの音量包絡（NRx2: 初めの音量 4 bit・1/64 秒 × n ごとに 1 段） |
| `svf` | 効果 | 2 極のステートバリアブルフィルタ。中心を hz から to_hz へ指数で動かす（mode = band・low） | 無し（フィルタは機種の外） |

## noise

雑音を ms ミリ秒。kind = hash（番号のハッシュの白色雑音）・lfsr15 / lfsr7（ゲームボーイの雑音。hz 回/秒で回す）

例: `{"noise": {"ms": 30, "amp": 0.16}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `ms` | number（0〜600000） | （必須） | 長さ（ミリ秒） |
| `amp` | number（0〜4） | `0.5` | 振幅（0〜1） |
| `kind` | hash / lfsr15 / lfsr7 | `"hash"` | 雑音の作り方 |
| `hz` | number（1〜1.048576e+06） | `8000` | LFSR を回す速さ（回/秒。hash は読まない） |
| `to_hz` | number（1〜1.048576e+06） | `null` | 回す速さの着く先（比が一定の速さで滑る。省くと滑らない） |

## pulse

矩形波を ms ミリ秒。to_hz を書くと hz から to_hz へ比が一定の速さで滑る

例: `{"pulse": {"hz": 784, "ms": 40, "amp": 0.16}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `hz` | number（1〜20000） | （必須） | 高さ（Hz） |
| `ms` | number（0〜600000） | （必須） | 長さ（ミリ秒） |
| `amp` | number（0〜4） | `0.5` | 振幅（0〜1） |
| `duty` | number（0.01〜0.99） | `0.5` | 山の割合（0.125・0.25・0.5・0.75 が機種の 4 種） |
| `to_hz` | number（1〜20000） | `null` | 滑って着く高さ（Hz。省くと滑らない） |
| `accumulate` | bool | `false` | 位相を 1 サンプルずつ足して進める（滑る時は常にこれ。省くとサンプルの番号から位相を出す） |

## rest

無音を ms ミリ秒（声の長さをそろえる・曲の休符）

例: `{"rest": {"ms": 180}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `ms` | number（0〜600000） | （必須） | 長さ（ミリ秒） |

## song

譜面（*.chip.json）を楽器（譜面の中か *.instrument.json）で鳴らす。左右に振って混ぜ、ループ点があれば頭 + 輪の 1 本と smpl のループの頭を作る

例: `{"song": {"chip": "go/internal/snd/testdata/snd/tiny.chip.json", "instruments": "go/internal/snd/testdata/snd/tiny.instrument.json"}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `chip` | string | （必須） | 譜面のパス（作業場の根から。台本の snd.write_chip が書いた物も読める） |
| `instruments` | string | `null` | 楽器のパス（作業場の根から。省くと譜面の中の instruments だけ） |

## delay

帰還つきのディレイ（ms ごとに feedback 倍で返る。pingpong で左右に交互に返す・帰還の道で lowpass）を wet だけ足す

例: `{"delay": {"ms": 300, "feedback": 0.35, "wet": 0.25}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `ms` | number（1〜4000） | （必須） | 遅れ（ミリ秒） |
| `feedback` | number（0〜0.95） | `0.35` | 返る量（0〜0.95） |
| `wet` | number（0〜2） | `0.25` | 返りの量 |
| `pingpong` | bool | `true` | 左右に交互に返す（モノラルの書き出しでは真ん中） |
| `lowpass` | number（100〜20000） | `6000` | 帰還の道のローパス（Hz。返るたびに暗くなる） |

## env

立ち上がり attack_ms・hold_ms 保ってから decay_ms の速さで指数に減衰（decay_ms 0 は減衰なし）

例: `{"env": {"attack_ms": 0.5, "decay_ms": 40}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `attack_ms` | number（0〜10000） | `0.5` | 立ち上がり（ミリ秒） |
| `decay_ms` | number（0〜60000） | `0` | 1/e まで落ちる時間（ミリ秒） |
| `hold_ms` | number（0〜60000） | `0` | 保つ時間（ミリ秒） |

## fade

頭を 1 倍・終わりを 0 倍へ直線で先細らせる（times 回重ねると急になる）

例: `{"fade": {}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `times` | int（1〜8） | `1` | 重ねる回数 |

## finish

仕上げ: 尾の無音を切り、25Hz の低域切り・8kHz の 2 段ローパス・頭 in_ms と尾 out_ms の直線の絞りを掛け、ピークを 1 にそろえる

例: `{"finish": {"in_ms": 2, "out_ms": 12}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `in_ms` | number（0〜1000） | `2` | 頭の絞り（ミリ秒） |
| `out_ms` | number（0〜1000） | `12` | 尾の絞り（ミリ秒） |

## gain

音量を by 倍にする

例: `{"gain": {"by": 0.5}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `by` | number（0〜64） | （必須） | 倍率 |

## lowpass

1 極のローパスを stages 段（hz より上をなだらかに落とす）

例: `{"lowpass": {"hz": 4500, "stages": 2}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `hz` | number（1〜20000） | （必須） | 切る所（Hz） |
| `stages` | int（1〜4） | `1` | 段の数 |

## normalize

統合ラウドネスを lufs にそろえ、true peak が peak_dbtp を超えるなら倍率を下げる（倍率だけ。ループする音は輪の 1 周で測る）

例: `{"normalize": {"lufs": -16}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `lufs` | number（-60〜0） | `null` | 目標の統合ラウドネス（LUFS。省くと kind の目安） |
| `peak_dbtp` | number（-20〜0） | `null` | true peak の上限（dBTP。省くと snd.json の truePeakDbtp） |

## rasp

隣のサンプルとの差 × 0.7（低い成分を落とした擦れ。times 回重ねる）

例: `{"rasp": {"times": 2}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `times` | int（1〜8） | `1` | 重ねる回数 |

## resample

ratio 倍の速さで読み直す（高さが ratio 倍・長さが 1/ratio。線形の補間）

例: `{"resample": {"ratio": 1.125}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `ratio` | number（0.0625〜16） | （必須） | 速さの倍率 |

## reverb

部屋の響き（櫛形 8 本 + 全域通過 4 本の Freeverb 型。左右で長さをずらして広げる）を wet だけ足す

例: `{"reverb": {"room": 0.6, "wet": 0.2}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `room` | number（0〜1） | `0.5` | 部屋の大きさ（0〜1。響きの長さ） |
| `damp` | number（0〜1） | `0.5` | 響きの高域の減り（0〜1） |
| `wet` | number（0〜2） | `0.2` | 響きの量 |
| `predelay_ms` | number（0〜200） | `0` | 響きの始まりの遅れ（ミリ秒） |

## steps

音量を level/15 から every_ms ごとに 1 段ずつ下げる（0 で止まる。16 段の音量包絡）

例: `{"steps": {"level": 15, "every_ms": 15.625}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `level` | int（0〜15） | `15` | 初めの段（0〜15） |
| `every_ms` | number（0〜10000） | `15.625` | 1 段下げる間（ミリ秒。0 は下げない） |

## svf

2 極のステートバリアブルフィルタ。中心を hz から to_hz へ指数で動かす（mode = band・low）

例: `{"svf": {"hz": 5500, "to_hz": 450, "q": 0.6, "gain": 0.42}}`

| 引数 | 型 | 既定 | 説明 |
|---|---|---|---|
| `mode` | band / low | `"band"` | 出口（band = 中心のまわり・low = 中心より下） |
| `hz` | number（1〜20000） | （必須） | 頭の中心（Hz） |
| `to_hz` | number（1〜20000） | `null` | 終わりの中心（Hz。省くと動かない） |
| `q` | number（0.01〜2） | `0.6` | 減衰（小さいほど鋭く鳴る） |
| `gain` | number（0〜8） | `1` | 出口の倍率 |

## 譜面（chip.json）

song の op が読む譜面。形は docs/chip.schema.json。今の形（phrase 16 段 → chain → rows・5 本のチャンネル）はそのまま読め、足した欄は書かなければ今までどおり。

| 欄 | 中身 |
|---|---|
| `bpm` | 速さ（4 分音符/分。既定 120） |
| `ticks` | 1 段の tick（既定 6） |
| `groove` | 段ごとの tick の並び（[7, 5] で跳ねる。平均が拍の速さを決める・長さは 16 を割り切る） |
| `loop` | ループの頭の rows の行（無ければループしない） |
| `gain` | 全体の倍率 |
| `mix` | 今の形の 5 本のチャンネルの倍率（channels を書かない時だけ） |
| `channels` | チャンネルの並び [{name, part（pulse・triangle・noise・wave。機種の外の saw・sine）, vol, pan（-1〜1）, cents（デチューン）, sub（1 オクターブ下のサイン。機種の外）, duck（サイドチェインで沈める）, send: {reverb, delay}, unison, filter, pitchenv, fm}]。rows の鍵はこの名前。機種の外の音色は下の表 |
| `fx` | 機種の外の厚み {reverb: {room, damp, wet, predelay_ms}, delay: {steps（段）, feedback, wet, pingpong, lowpass}, sidechain: {key（合図の楽器の名前の並び）, depth_db, release_ms}} |
| `instruments` | 楽器（*.instrument.json と同じ形。譜面の方が勝つ） |
| `waves` | 波形メモリの形（名前 → 32 段 × 0〜15） |
| `phrases` | 名前 → 16 段の段の文字 |
| `chains` | 名前 → phrase の並び（"名前 +半音" で移調） |
| `rows` | 曲の並び（行ごとに {チャンネル: chain}） |

機種の外の音色（style の breaks に名前がある時だけ書ける。neo は全部許す・gb は止める）:

| 欄 | 中身 | 例 |
|---|---|---|
| `part: saw` | ノコギリ（polyBLEP で折り返しを抑える。duty の表は読まない） | `{"name": "lead", "part": "saw"}` |
| `part: sine` | サイン（808 のキックの本体・柔らかいベース） | `{"name": "kick", "part": "sine", "pitchenv": {"semis": 30, "ms": 25}}` |
| `unison` | 同じ音を voices 本（2〜7）、cents（0〜100）の幅でずらして重ね、左右へ width（0〜1）だけ広げる。sub は 1 本目だけ | `{"voices": 5, "cents": 18, "width": 0.8}` |
| `filter` | 2 極のフィルタ（mode = low・band・high、q 0.3〜12）。切る所 hz から、鳴らした頭に env オクターブ（-8〜8）上がり env_ms で戻る。sweep = [[小節, Hz], …] は頭からの小節で切る所を動かす（間は比で滑らか・ループの 2 周目も同じ位置） | `{"mode": "low", "hz": 900, "q": 1.2, "env": 3, "env_ms": 180, "sweep": [[0, 400], [8, 6000]]}` |
| `pitchenv` | 鳴らした頭（打ち直しも）に semis 半音（-60〜60）上から ms の速さで指数に落ちる | `{"semis": 24, "ms": 30}` |
| `fm` | 2 オペレータの FM（part が sine だけ）。サインの高さを ratio（0.25〜16）倍のサインで index（0〜20 ラジアン）だけ揺らし、深さは鳴らした頭（打ち直しも）から decay_ms で floor（0〜1）の割合まで減る。ratio 1 で柔らかいエレピ・3.5 や 7 でベル・オルゴール | `{"ratio": 3.5, "index": 4, "decay_ms": 300, "floor": 0.1}` |

段の文字は `音 楽器 v音量 コマンド…`（`C#5 lead v12 DLY 2 VSL -1`。`OFF` は離す）。コマンドは 1 段に並べて書ける:

| コマンド | 中身 |
|---|---|
| `ARP a b c` | 1 tick ごとに半音 a・b・c… を回す（1 本で和音） |
| `VIB hz cents` | ビブラート |
| `SLD n` | 前の音から n tick で滑って着く（次の音へ滑る） |
| `DLY n` | 段の頭を n tick 遅らせる（段の長さ未満。前の音はその間鳴り続ける） |
| `CUT n` | 鳴らしてから n tick で離す（段をまたいで数える。楽器に release があれば離した後の表へ） |
| `RTG n` | n tick ごとに同じ音を打ち直す |
| `VSL n` | 1 tick に n/8 段ずつ音量を滑らせる（負は下げる。次の音で止まる） |

楽器は今の rows（1 行に全部）か、表の形（表ごとに長さ・ループ・離した後を持つ）:

| 表 | 中身 |
|---|---|
| `vol` | 音量 0〜15 の表（"15 13 12 | 11 10 / 6 3 0": | の後をループ・/ の後は離した後に流す） |
| `arp` | 音程（半音）の表。arp_fixed: true なら音の高さそのもの（太鼓） |
| `pitch` | 音程のずれ（セント）の表 |
| `duty` | デューティ（12・25・50・75）・波形の名前・雑音（long・short）の表 |
| `vib` | "hz cents 遅れの tick"（遅れてかかるビブラート） |
| `speed` | 表を何 tick ごとに進めるか（既定 1） |

## 台本で曲を書く（mus と snd.write_chip）

段の並び（part）は Starlark の list。`+` でつなぎ、`*` でくり返し、`[a:b]` で切り出す。

| 関数 | 中身 |
|---|---|
| `mus.chords(text)` | 和音の進行（"G | C | Em D | D7"。| が小節・1 小節に 2 つで半分ずつ）。和音は C・Cm・C7・Cmaj7・Cm7・Cdim・Caug・Csus4・Csus2・C6・Cm6・Cadd9・C9・Cm7b5・Cdim7 と /E の低音。返すのは小節ごとの和音の並び |
| `mus.mml(text, inst=, octave=5, length=8, vol=, quantize=8, ticks=6)` | 旋律の短い記法: c d e f g a b（+ か # で半音上・- で下）・長さ 1 2 4 8 16 と付点 .・r 休み（音を離す）・^ で前の音をのばす・o 音域・< >・l 既定の長さ・v 音量・@ 楽器・q n（長さの n/8 の tick で離す。CUT を付ける・ticks は 1 段の tick）・{SLD 2} は次の音にコマンド・| は小節の線（長さを確かめる） |
| `mus.comp(chords, rhythm, inst=, octave=4, vol=, tones=3)` | 和音打ち: rhythm（16 字。x 打つ・- のばす・. 離す。並びなら小節ごとに回す）の x で和音の根を ARP で鳴らす |
| `mus.bass(chords, rhythm, shape=["1"], inst=, octave=2, vol=)` | ベース: rhythm の x ごとに shape の度数を順に（1 根・3・5・7・8 オクターブ上・-5 下の 5 度・~ 次の小節の根へ半音下から） |
| `mus.arp(chords, pattern, rhythm="xxxxxxxxxxxxxxxx", inst=, octave=4, vol=)` | 分散和音: rhythm の x ごとに pattern の番号（和音の音を下から 0・1・2…。音の数を超えると 1 オクターブ上）を順に |
| `mus.drums(pattern, kit)` | 1 小節の太鼓: pattern = {楽器の役: 16 字（x 打つ・1〜9 と a〜f は音量つき）}・kit = {役: 段の文字（"C-4 kick"）}。重なれば pattern の先の役が勝つ |
| `mus.transpose(part, n)` | 半音 n だけ上げ下げ（音のある段だけ） |
| `mus.echo(part, steps=3, vol=-4, inst=, transpose=0)` | 機種の中のエコー: steps 段遅らせた写し（はみ出した尾は頭へ回す）。音量は vol 段下げる（別のチャンネルに置く） |
| `mus.with_inst(part, inst)` | 音のある段の楽器を替える（B で音色を替える） |
| `mus.rest(bars=1)` | 休みの小節（頭の段で前の音を離し OFF・残りは空の段。16 × bars） |
| `mus.bars(part)` | 小節の数 |

`snd.write_chip(path, value)` は value の part を 16 段ずつ phrase にまとめ（同じ中身は 1 つ）、チャンネルごとの chain と rows を作って譜面を書く（build ではメモリの中だけ・gen ではファイル）。返すのは path（`op.song(chip = …)` に渡す）。value の鍵:

| 鍵 | 中身 |
|---|---|
| `bpm` | 速さ（4 分音符/分） |
| `ticks` | 1 段の tick（既定 6） |
| `groove` | 段ごとの tick の並び（跳ねる） |
| `gain` | 全体の倍率 |
| `channels` | チャンネルの並び [{name, part, vol, pan, cents, sub, duck, send}] |
| `instruments` | 楽器（表の形 vol・arp・pitch・duty か rows） |
| `waves` | 波形メモリの形（32 段 × 0〜15） |
| `fx` | 機種の外の厚み {reverb, delay, sidechain} |
| `intro` | 頭（1 回だけ鳴らす）{チャンネル: part} |
| `body` | 本編（ループする）{チャンネル: part}。intro と body の頭の段が空なら OFF に替える（前の周の最後の音を残さない。継ぎ目をまたいで伸ばすなら頭を "---"） |
