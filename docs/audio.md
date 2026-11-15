# 音の鳴らし方（audio.md）

ゲームに音を付けるための一枚。BGM・効果音（sfx）を「鳴らす」までの最短手順と、
迷いやすい「どっちのやり方で鳴らすか」「音そのものはどう作るか」をまとめる。

- 実体: `GameEngine.Audio`（engine/src/platform/GameEngine.flix。再生・停止・音量・ループの effect）・
  `AudioStreamPlayer`（engine/src/render2d/AudioStreamPlayer.flix。上の薄いラッパ）・
  `AudioFade`（engine_world/src/AudioFade.flix。フェードの音量カーブを作る純関数）・
  `SfxSynth`（engine_tools/src/SfxSynth.flix。素材ファイル無しで効果音を合成する）
- `AudioMixer`（engine_world/src/AudioMixer.flix。バス・ダッキング・ローパス・クールダウン・スナップショット）・
  `AudioMixerDoc`（mixer.json の読み込み）・`AudioMixdown`（実機と同じ規則で WAV 用の波形にする）
- 音は project.json の `sounds` に載せた名前で鳴らす。ファイルの場所はゲームコードから見えない。

## 最短手順

1. WAV を用意する（合成なら後述の SfxSynth を使う。録音・素材ならそのまま `assets/sfx/` に置く）。
2. project.json の `sounds` に登録する。

```json
"sounds": [
  { "name": "push", "path": "assets/sfx/push.wav", "looping": false }
]
```

3. 「前後の World から鳴らす音名を導く」純関数を書く（templates/tidepool-starter/src/Controls.flix の `sounds` と同じ形）。

```flix
mod Sfx {
    pub def events(sessions: { before = Session, after = Session }): List[String] =
        sfxEvent(sessions#before, sessions#after) |> Option.toList

    def sfxEvent(before: Session, after: Session): Option[String] =
        if (pushed(before, after)) Some("push") else None
}
```

4. `App.withAudio` で Main に繋ぐ。

```flix
App.make(initialWorld)
    |> App.addSystem(Controls.step)
    |> App.withView(View.frame)
    |> App.withAudio(Sfx.events)
    |> App.launch
```

これで盤面が変わって `pushed` が真になったフレームだけ `push.wav` が鳴る。

## 経路の使い分け — 基準は「起きたこと」か「今そうであること」か

鳴らしたい音を 1 つ思い浮かべて、どちらの文で言えるかを考える。

- **「〜が起きた」と言える音**（当たった・取った・跳んだ・場面が変わった）→ `App.withAudio`。
  1フレームの `{before, after}`（進める前後の World）から「鳴らす音名の List」を導く
  純関数を渡す。再生そのものは App が引き受ける。同じ名前が同フレームに 2 回入っても
  App が 1 回にまとめるので、二重再生で音が途切れる心配は要らない。
  World の差分だけで判定が書けるので、テストは「何が鳴るか」を具体値で固定できる
  （sokoban / breakout / platformer / liars_room が採用）。
- **「今〜している」と言える音**（走っている・雨が降っている・エンジンが回っている）→
  `App.withSustained`（次の節）。止め時をゲームが知っている音は、始まりのフレームでなく
  「続いている状態」を毎フレーム宣言する。
- `AudioStreamPlayer.play(name)` を直接呼ぶ命令的スタイルは、World の差分では表せない場面
  （効果を経由しない生の入力ハンドラの中など）だけの逃げ道。それ以外の理由では使わない。

```flix
AudioStreamPlayer.play("cursor")
AudioStreamPlayer.stop("bgm")
AudioStreamPlayer.setVolume("bgm", 0.5)
AudioStreamPlayer.setPitch("bgm", 1.2)
AudioStreamPlayer.setLooping("bgm", true)
```

### イベントキューを使うなら: World 直下 + Step 冒頭で全置換（platformer 参照）

「起きたこと」を before/after の見比べで導けない出来事（同フレーム内で起きて消える衝突など）は、
Step が World の **イベントキュー**（`events = List[Event]`）に記録し、`withAudio` は
`after#events` を名前に写すだけにする。このとき守る形は 2 つ:

- **イベントキューは World の直下に 1 つ**置く。入れ子のレコード（フェーズごとの状態など）の
  中に置くと、レコードの作り直し・フェーズの結末でクリアし忘れ、鳴り損ねや亡霊音になる。
- **Step の冒頭でキューを丸ごと空にしてから**、そのフレームの出来事を詰め直す
  （platformer の `events = Nil`）。「消費した分だけ取り除く」方式は取りこぼす。

```flix
// World 直下
events = List[Event],   // このフレームの出来事（毎フレーム冒頭で空に）

// Step 冒頭で全置換 → そのフレームの出来事を詰める
let cleared = { events = Nil | world };

// Sfx は写すだけ
pub def events(worlds: { before = World, after = World }): List[String] =
    worlds#after#events |> List.map(eventName)
```

## 鳴り続ける音（`App.withSustained`）

`App.withAudio` が返せるのは「このフレームで鳴らし始める名前」だけなので、走行音・風・雨・炎・
機械の唸り・走っている間の足音のような**止め時をゲームが知っている音**は書けない。
`App.withSustained` は逆に「**このフレームで鳴り続けていてほしい音**」を World から宣言する。

```flix
pub def hums(w: World): List[App.Sustain] =
    if (not w.running) Nil
    else { name = "engine", volume = 0.4, pitch = 1.0 + 0.6 * speedRatio(w) } :: Nil

App.make(initialWorld)
    |> App.withAudio(Sfx.events)
    |> App.withSustained(Sfx.hums)
    |> App.launch
```

| 宣言の変わり方 | 音の振る舞い |
|---|---|
| 前のフレームに無く、今のフレームにある | ループを ON にして頭から鳴らし始める |
| 前のフレームにも今のフレームにもある | 鳴らし直さず、音量と高さだけ流し込む（音が途切れない） |
| 前のフレームにあり、今のフレームに無い | 止める |

- `name` は project.json の `sounds` の論理名。**素材は継ぎ目なくループする波形**にする
  （`looping` の初期値は宣言のたびに ON へ上書きされるので project.json 側は false でよい）。
- `volume` は 0.0〜1.0、`pitch` は高さ（1.0 = 元のまま・2.0 で 1 オクターブ上・0.5 で 1 オクターブ下）。
  **どちらも毎フレーム与え直せる** — 速度で唸りが変わるエンジン音はこれで作る。
- 同じ名前を 2 回宣言しても 1 本にまとめられる（先勝ち）。二重に鳴らすと同じ音源を頭から
  鳴らし直して音が途切れるため。
- 「短い音を一定間隔で焚き直して続いているように見せる」逃げ方はもう要らない。
  続く音は 1 本の宣言で書く。

単発の効果音（当たった・取った・場面が変わった）は今までどおり `App.withAudio` で書く。

### 曲の頭を 1 回だけ鳴らして、後ろの輪だけを回す（ループ点）

イントロのある曲は、**1 本の WAV にループ点（`smpl` チャンク）を入れて**鳴らす。頭と輪を 2 本の音に割り、
「頭の長さを過ぎたら輪へ切り替える」時刻をゲームが持つと、手で写した長さと実際の音の長さがずれたり、
フレームの刻みで継ぎ目に隙間が空いたりする。ループ点なら継ぎ目は音の側で決まり、ゲームは 1 つの名前を
宣言し続けるだけでよい（Godot の WAV の取り込み・OpenAL Soft の `AL_SOFT_loop_points` と同じ考え方）。

```flix
// 書き出し（SfxRender）: 譜面のループ点のサンプル番号を渡す
SfxSynth.renderLooped(cfg(), "assets/sfx", "bgmFight", List.append(intro, body), List.length(intro))
// 鳴らす側（Sfx.hums）: 頭から終わりまで、同じ名前を宣言し続ける
{ name = "bgmFight", volume = 0.6, pitch = 1.0 } :: Nil
```

- 実機（render_gl）は読み込みのときに `smpl` の最初のループ `[頭, 終わり)` をバッファへ付ける。
  `AL_LOOPING` が ON の間、頭から 1 回鳴った後はループの頭へ戻る。拡張の無い環境では全体を繰り返す。
- 動画の書き出し（`AudioMixdown.mixdownLooped`）も同じ回り方をする。ループ点は `AudioMixdown.loadLoopStart` で読む。
- `smpl` を読む口は `AudioUtil.loopPointsOf`（終わりを含まない形で返す）。外のツールで作った WAV でも、
  `smpl` に前へ進むループが 1 本あれば同じように回る。
- ステレオの曲も同じ（`SfxSynth.renderLoopedStereo`）。ループ点は左右 1 組の番号なので、左右は同じサンプルで頭へ戻る。

### ステレオの WAV（0.39.0 から）

16bit の WAV はモノラルでもステレオでもそのまま `assets/` に置いて鳴らせる（project.json の書き方も同じ）。

- 実機はステレオをステレオのまま鳴らす。モノラルは今までどおり両耳に同じ音。サンプルレートは WAV ごとに
  違ってよい（OpenAL が鳴らす側で合わせる）。`setVolume`・`setPitch`・バスの音量とローパスはステレオにも同じに効く。
  左右の振り（パン）を付ける口は無い。
- 動画の音をステレオで書き出すなら `AudioMixdown.loadWavStereo` → `mixdownStereo` → `SfxSynth.wavBytesStereo`。
  モノラルの素材は左右に同じ音で入る。`loadWav` / `mixdown` は今までどおりモノラル（ステレオの素材は左右の平均）。
- `fge waveform`（`make gallery-sounds`）はステレオを上（左）と下（右）に描き、左右のピークと `side`
  （左右の差の大きさ。0 = 左右が同じ）を出す。`make compare` の音の差にもチャンネル数・長さ・ピークが出る。

## 音の通り道（`App.withMixer` と mixer.json）

音が増えてくると「効果音が鳴ると BGM に埋もれる」「会話の間は曲を遠くしたい」「ルーレットのカチッが
細かすぎて頭だけの音になる」が出てくる。これを音ごとの音量の手調整で直さず、**バス**でまとめて決める
（Godot の Audio Bus・Unity の AudioMixer と同じ考え方）。

```flix
App.make(initialWorld)
    |> App.withAudio(Sfx.events)
    |> App.withSustained(Sfx.hums)
    |> App.withMixer(w -> w.mixer)                         // AudioMixerDoc.load(AudioMixer.defaults(), "assets/game.mixer.json")
    // 場面で聞こえ方を変えるなら: w -> if (talking(w)) AudioMixer.withSnapshot("talk", w.mixer) else w.mixer
```

```json
{ "version": 1,
  "transitionSeconds": 0.35,
  "buses":     [ { "name": "music", "volume": 0.9 }, { "name": "sfx" }, { "name": "ui" } ],
  "routes":    [ { "bus": "music", "prefixes": ["bgm"] }, { "bus": "ui", "prefixes": ["cursor", "decide"] } ],
  "ducks":     [ { "bus": "music", "by": ["sfx"], "depth": 0.6, "attackSeconds": 0.03, "holdSeconds": 0.08, "releaseSeconds": 0.45 } ],
  "cooldowns": [ { "prefix": "cursor", "seconds": 0.045 } ],
  "snapshots": [ { "name": "talk", "buses": [ { "name": "music", "volume": 0.8, "lowpassGainHF": 0.12 } ] } ] }
```

| 欄 | 何が起きるか |
|---|---|
| `buses` | バスごとの音量と `lowpassGainHF`（高い音の残り具合。1 = 素通し・小さいほど 5000Hz より上が落ちて籠もる。OpenAL の EFX の lowpass と同じ意味）。載っていないバスは音量 1・素通し |
| `routes` | 音の名前の頭（`prefixes`）でバスを選ぶ。長く一致した方が勝ち、どれにも当たらない音は `defaultBus`（既定 sfx） |
| `ducks` | `by` のバスで音が鳴っている間（一発の音は音の長さ、鳴り続ける音は宣言が続く間）、`bus` を `depth` 倍へ下げる |
| `cooldowns` | 同じ名前の音が `seconds` 以内にもう一度来たら鳴らさない（1 つの名前は同時に 1 本しか鳴らず、鳴り直すと頭からなので、細かい連打は頭だけの音になる） |
| `snapshots` | 名前つきの上書き。`AudioMixer.withSnapshot` で選ぶと `transitionSeconds` でちょうど移り切る |

- ミキサーが掛かるのは **`withAudio` と `withSustained` の音だけ**。`AudioStreamPlayer` で直接鳴らす音は
  バスを通らないので、ダッキングもスナップショットも効かない（繋いだゲームでは一発の音の音量もミキサーが決める）。
- `AudioFade` との分担: フェードは宣言の `volume` で作り、ミキサーはその上に掛け算で効く（宣言 × バス × ダッキング）。
- `withMixer` を繋がないゲームは今までどおり（名前のまま鳴る）。
- **互換の注意（0.34 の次の版から）**: `GameEngine.Audio` effect に `setLowpass(name, gainHF)` と
  `audioSeconds(name)` が増えた。エンジンのハンドラ（LwjglLayer・RemoteDebug）は対応済みだが、
  ゲームやテストが自前で `GameEngine.Audio` のハンドラを書いている場合は、この 2 つを足さないと
  コンパイルが通らない（偽物なら `def setLowpass(_n, _g, k) = k()` / `def audioSeconds(_n, k) = k(0.0)` でよい）。
- 実機と同じ規則で混ぜた音を WAV にしたいとき（動画の音・書き換え前後の聞き比べ）は `AudioMixdown.mixdown`。
  コマごとの `{ plays, sustained, mixer }` を並べれば、App と同じ `AudioMixer.step` を通して波形になる。

## project.json の sounds

```json
"sounds": [
  { "name": "move", "path": "assets/sfx/move.wav", "looping": false }
]
```

| フィールド | 意味 |
|---|---|
| `name` | ゲームコードから鳴らすときの論理名（`App.withAudio` が返す文字列・`AudioStreamPlayer.play` に渡す文字列） |
| `path` | project root からの相対パス（WAV/OGG） |
| `looping` | 起動時にロードした音源へ既定で付ける AL_LOOPING の初期値。実行中に変えるなら `AudioStreamPlayer.setLooping`（`App.withSustained` の宣言は自動で ON にする） |

パスは project root からの相対で書く（実行時に rootDir と結合される。engine/src/core/ProjectLoader.flix）。

音の名前には置き場が 3 つある（生成名・sounds の論理名・コード内リテラル）。ずれても
エラーは出ず、音だけ鳴らない・別の音が鳴る。**論理名 = WAV ファイル名の茎 = 生成名**の
1 本にそろえ、音を足した・改名したら `make lint-audio` で突き合わせる。

## 外から持ってくる BGM・効果音（素材の候補）

外から BGM・効果音を足す時は、まず次のフリー素材から、ゲームのジャンルに合う物を選ぶ（人の指定・2026-11-15）。
環境音・UI の短い音を `SfxSynth` で作るのは今までどおりでよい。

| 素材 | 置き場 | 向いているジャンル | 種類 |
|---|---|---|---|
| 魔王魂 | https://maou.audio/ | ノベル・汎用 | BGM・効果音・環境音（数が多い） |
| PeriTune | https://peritune.com/（曲の記事の一覧は https://peritune.com/blog/category/music-material/・表は https://peritune.com/freematerial_list/・YouTube は https://www.youtube.com/@PeriTune） | ノベル・汎用 | BGM（MP3・OGG・M4A） |
| 甘茶の音楽工房 | https://amachamusic.chagasi.com/ | ノベル | BGM |
| ユーフルカ | https://youfulca.com/ | RPG | BGM・効果音・声 |
| PANICPUMPKIN | https://pansound.com/panicpumpkin/ | ファミコン風（レトロ） | BGM・効果音（ゲームには無限ループの WAV を使う。MP3 は 2 周してフェードアウトする） |
| 効果音ラボ | https://soundeffect-lab.info/ | 効果音全般 | 効果音・環境音・声（数が多い） |
| RPGツクールの付属素材（人が持っているのは MZ と VX Ace・Steam 版） | ツクールのインストール先（新しいプロジェクトの `audio/se`・`audio/bgm` など【推】） | RPG・汎用 | 効果音・BGM・環境音（OGG） |

規約の要点（2026-11-15 に原文で確かめた物。規約は変わるので、配る前に原文を開き直す。「書いていない」は規約に記載が無いこと）:

| 素材（規約の頁） | クレジット | 有償の作品 | ゲームに入れる時 | 主な禁止 |
|---|---|---|---|---|
| 魔王魂（https://maou.audio/rule/） | **必要**。「音楽：魔王魂」（「音楽」は「BGM」「効果音」に替えてよい） | 可 | ゲームでの暗号化は許されている。素材だけの再配布は不可。加工は自由だが、改変した物を完全な自作として出さない | **生成 AI に学習させること**・自作と偽ること・素材サイトや配信ストアへの登録 |
| PeriTune（https://peritune.com/about/） | 任意（できれば「PeriTune」）。**2026 年 2 月以前に出た曲は CC BY 4.0 なので必要** | 可。ただし**ファイルを直接取り出せない処置（暗号化など）が要る** | 無償・非営利で暗号化できない物は例外で同梱してよい。有料の WAV は同梱不可 | YouTube の Content ID への登録・ファイル単体の販売や再配布・曲の紹介が目的のまとめ動画 |
| 甘茶の音楽工房（https://amachamusic.chagasi.com/terms.html） | 任意（サイト名・作曲者名・URL のどれか 1 つ。例「甘茶の音楽工房」） | 可 | 加工は自由（テンポ・キー・フェード）。暗号化の決まりは書いていない | 音楽だけの販売と再配布・作曲者を偽ること・Content ID への登録・著作権管理団体への登録・直リンク |
| ユーフルカ（https://youfulca.com/kiyaku_jp/） | できれば「音楽：ユーフルカ」 | 可 | 加工は自由（切ってループにするのも可）。**ファイル名に `RPGmaker` を含むツクール専用素材と、`Touhou` を含む東方アレンジは使えない**（このエンジンはツクールではない） | 素材そのものの再配布・販売・他サイトからのダウンロードを促す表記・NFT |
| PANICPUMPKIN（https://pansound.com/panicpumpkin/music/kiyaku.html） | 任意（できれば「(C)PANICPUMPKIN」） | 可 | 加工は自由（フェード・音量・形式の変換・名前の変更） | 音楽だけの再配布と音楽集としての販売・音楽が主体の動画・直リンク |
| 効果音ラボ（https://soundeffect-lab.info/agreement/） | 不要（書くのは任意） | 可 | アプリの操作音としてファイルがむき出しで入るのは可。**効果音を自由に鳴らせる作り（サウンドボード・音の一覧の画面）は再配布にあたり不可**。加工は自由だが改変した物の再配布は不可 | **AI の学習データにすること**・Content ID などへの登録・ファイルの再配布と販売・直リンク・アダルトや公序良俗に反する作品・声素材で声優を傷つける使い方 |
| RPGツクールの付属素材（https://rpgmakerofficial.com/?p=120 の「素材利用条件」） | 表記の決まりは下の「RPGツクールの付属素材」 | 可（個人・同人サークルだけ。法人は個別に協議） | **正規に買った製品の素材だけ**。**改変できない**（改変してよいのはブログ・ポートフォリオで紹介する時だけ） | 素材の頒布・抽出・改変した物の商用利用・**生成 AI に学習させること**・別売りの素材集や DLC をこの条件で使うこと（それぞれの条件に従う） |

### RPGツクールの付属素材（MZ・VX Ace）

2023-05 の規約の改定で、正規に買った人は、製品に入っている素材を「GGG 製品以外の自作プログラムや他社のツールで作った作品」に
使えるようになった（素材利用条件 第 1 条・2026-06-22 改定版を 2026-11-15 に読んだ）。使う時は次を守る。

- **使えるのは、人が持っている製品（RPGツクール MZ と VX Ace）に付いてくる素材だけ**。別売りの素材集・DLC・「二次的利用禁止」の附則に載った素材は対象外。
- **ファイルをそのまま使う**。素材利用条件 第 2 条は、改変を「ブログやポートフォリオで紹介する目的」に限っている。切る・フェード・音量・ピッチを
  変えることが改変に当たるかは規約に定義が無い【未確認】ので、変えずに使う。音量はミキサー（mixer.json のバス）で合わせ、ファイルには手を入れない。
  ツクールの音は OGG なので、形式も変えずに project.json の `sounds` に載せる（PC の Audio は OGG を読む。ブラウザ版の Safari で鳴るかは【未確認】なので、出す前に確かめる）。加工したくなったら、作る前に人へ相談する（問い合わせ先 info@gotchagotcha.jp）。
- **表記**: 頒布条件 第 2 条（ロゴ・「GGG 製品で制作した」の明示・著作権と商標の表記）は、文面では「GGG 製品を使って作ったソフトウェア」（本規約 第 5 条の
  ユーザーソフトウェア）に掛かる条文で、他のツールで素材だけを使う作品に掛かるかは書かれていない【未確認】。そこで、安くできる物だけ先回りして書く:
  - `CREDITS.md` とゲームの中のクレジットに、使った製品の著作権表記と商標表記を書く:
    - MZ: `©Gotcha Gotcha Games Inc./YOJI OJIMA 2020`
    - VX Ace: `©2011 Gotcha Gotcha Games Inc./YOJI OJIMA`
    - 商標: `RPG MAKER は、株式会社 Gotcha Gotcha Games の登録商標又は商標です。`
  - 起動の時のロゴ（スプラッシュ）は出さない。条文はツクールで作った作品に「可能な限り」と求める物で、指定のロゴの置き場も規約に書かれていない。
    また、ツクールで作ったと誤って読まれる表示になる（頒布条件 第 2 条 2 号の明示は、ツクールで作った作品のための物）。
  - 「ツクールで制作した」とは書かない（このエンジンで作っているので事実と違う）。素材の出どころとして「効果音：RPGツクール MZ 付属素材」のように書く。
- **配り方**: 素材の頒布は禁止。ゲームの一部として入れるのが利用で、素材だけを取り出せる形で配るのが頒布、という区別だと読める【推】。
  ブラウザ版は音をそのままのファイルで配るので、ここが頒布に当たらないかは【未確認】。有償で配る前と、ストアで売る前に人へ相談する。
- **生成 AI**: 規約は学習を禁じている（本規約 第 7 条 2 項 6 号）。公式の「生成AI利用のガイドライン」（https://rpgmakerofficial.com/support/faq/guidelines）は、
  AI に入力して結果を得る「利用」（自分のゲームのための作業の手伝い）は可、AI に覚えさせる「学習」と、素材を学ばせて似た音を作ることは不可と分けている。
  AI のエージェントがファイルを写して project.json に載せる・波形の図で長さを確かめるのは「利用」の側。素材をもとに似た音を作らせない。
- **サウンドテストの画面**には入れない（素材を自由に取り出せる形に近いので、頒布に当たるおそれがある【推】）。

このエンジンで使う時の決まり:

- **ブラウザ版は素材をそのままのファイルで配る**（書き出しに暗号化は無い）。PeriTune の曲を**有償**のゲームに入れる時は、
  配る前に人へ相談する（今の書き出しのままでは規約の「直接取り出せない処置」を満たさない【推】）。
- **クレジットは 2 か所にそろえて書く**: ゲームの `CREDITS.md`（ファイル・曲名・元の頁の URL・作者・規約）と、
  ゲームの中のクレジット（手本 sound-novel-starter の `assets/novel.credits.json`）。任意の素材も書いておく
  （どの素材から来たかを後から辿れるようにするため）。
- **音そのものを AI に渡して学習・生成の材料にしない**。魔王魂と効果音ラボははっきり禁止で、ほかの素材も書いていないだけなので同じに扱う。
  波形の図（`sounds.png`）で長さや音量を確かめるのは構わない。
- **音を自由に鳴らせる画面（サウンドテスト・音楽の鑑賞モード）を作る時は、作る前に人へ相談する**。効果音ラボははっきり禁止で、
  PeriTune・ユーフルカ・PANICPUMPKIN も音楽そのものを聴かせる使い方を禁じたり避けるよう求めたりしている。
- 置くのは `assets/sfx/`、登録は project.json の `sounds`（上の節）。ファイル名は論理名と同じ茎にそろえ、元の曲名は `CREDITS.md` の表に残す。
- 1 本のゲームの中で、同じ種類の音（BGM どうし・効果音どうし）に複数の作者を混ぜると質感がそろわない。BGM は 1 作者、効果音は 1 作者を基本にする（下の「音の下限」と同じ考え方）。
- YouTube にゲームの動画を上げて Content ID の申し立てが来たら、規約どおりの利用なら異議申し立てで曲の出どころを書く
  （PeriTune は 2026-08 に一部の曲が意図せず Content ID に載ったと告知している）。

## SfxSynth — 素材ファイル無しで効果音を作る

短い効果音は録音・サンプル素材を用意しなくてよい。`SfxSynth`（engine_tools）が
矩形波・雑音・減衰・重ね・連結だけの語彙で波形を作り、そのまま WAV バイト列にする。
各サンプルは番号だけで決まる純粋関数なので、毎回同じ音が生成できる（スナップショット比較にも使える）。

| 語彙 | 何を作るか |
|---|---|
| `tone(cfg, freq, amp, ms)` | 矩形波の生音（減衰なし）。「ピッ」の元になる音の高さと長さを決める |
| `noise(cfg, amp, ms)` | 擬似乱数の雑音の生音。「ザッ」「ドッ」のような質感の元 |
| `fade(samples)` | 先頭 1 倍→末尾 0 倍の直線減衰。生音を先細らせて余韻を付ける（重ねがけで急な減衰にもなる） |
| `blend(a, b)` | 2つの声を足し合わせる（短い方の長さに揃う）。tone と noise を重ねて「金属+衝撃」のような複合音を作る |
| `rasp(samples)` | 隣り合うサンプルの差分を取り、擦れた質感にする（noise にかけると太い「ドッ」が「シャッ」に変わる） |
| `sequence(voices)` | 複数の声を順につなげる。上昇音・下降音・ファンファーレのような音階の並びを作る |

ゲーム側は `<ゲーム>/src/render/SfxRender.flix` に「音のデザイン」だけを書き、`SceneRender.all` から
`renderAll` を呼んで `assets/sfx/` へ WAV を書き出す（`make render-all`）。合成と WAV エンコードは
engine_tools 側の `SfxSynth.wavBytes` / `writeBytes` / `renderSet`（ループ点つきの曲は `renderLooped`・
ステレオは `wavBytesStereo` / `renderLoopedStereo`）が持つので、
ゲーム側は波形の足し算だけ書けばよい。

組み立て方の抜粋:

```flix
def cfg(): SfxSynth.Config = { sampleRate = 22050 }

// パドル: 明るく短い高音のブリップ
def paddleBlip(): List[Float64] = SfxSynth.fade(SfxSynth.tone(cfg(), 880.0, 0.06, 50))

// ハードが耐えた: 低い矩形波の上に鋭いノイズ（金属を叩いた手応え）
def chipClang(): List[Float64] =
    SfxSynth.blend(
        SfxSynth.fade(SfxSynth.tone(cfg(), 180.0, 0.12, 70)),
        SfxSynth.fade(SfxSynth.fade(SfxSynth.noise(cfg(), 0.08, 60))))

// CLEAR: 上昇する4音のファンファーレ（C5, E5, G5, C6）
def clearFanfare(): List[Float64] =
    SfxSynth.sequence(
        SfxSynth.fade(SfxSynth.tone(cfg(), 523.25, 0.15, 90)) ::
        SfxSynth.fade(SfxSynth.tone(cfg(), 659.25, 0.15, 90)) ::
        SfxSynth.fade(SfxSynth.tone(cfg(), 783.99, 0.15, 90)) ::
        SfxSynth.fade(SfxSynth.tone(cfg(), 1046.5, 0.2, 240)) :: Nil)

pub def renderAll(): Unit \ IO =
    SfxSynth.renderSet(cfg(), "assets/sfx",
        ("paddle", paddleBlip()) :: ("chip", chipClang()) :: ("clear", clearFanfare()) :: Nil)
```

サンプルレートは 22050Hz で足りる（短いブリップ用途。ファイルも小さい）。

## AudioFade — フェードイン・アウト・クロスフェード

`AudioFade` は状態を持たない計算だけの道具箱。進行度 `t`（0〜1）を渡すと、その瞬間の
音量が決まる。毎フレーム `t` を進め、`AudioFade.volumeOf` の値を `AudioStreamPlayer.setVolume`
（や `GameEngine.Audio.setVolume`）へ流す。

```flix
// フェードイン: 無音 → 全開
let volume = AudioFade.volumeOf(AudioFade.fadeIn(), t);
AudioStreamPlayer.setVolume("bgm", volume)

// フェードアウト: 全開 → 無音
let volume = AudioFade.volumeOf(AudioFade.fadeOut(), t)

// クロスフェード: 消える曲・現れる曲の音量を同じ t から同時に決める（和は常に1.0）
let (outVol, inVol) = AudioFade.crossfadeOf(t)
```

イージングは持たない。ゆっくり立ち上げたいなら呼び側で `t` を変形して渡す（例: `t*t`）。
`t` そのものの進め方（何秒でフェードするか）は `Transition` に任せる。

## 音の下限（生成コードに必須）

「絵の下限」（AGENTS.md）と対になる、音の側の下限。ゲームを作るときは必ず満たす。

- **決定・キャンセル / 当たった・壊れた / 手に入れた / 場面が変わった、の4種には必ず音を当てる**。
  この4つが無音だと、操作しているのに手応えが無いゲームになる。
- **無音の画面を出荷しない**。BGM を置かないゲームでも、少なくとも上の4種の sfx は鳴る状態にする。
- **同じ音を1フレームに二重に鳴らさない**。`App.withAudio` は同じ名前を 1 回にまとめるので
  経路がこれなら守られている。`AudioStreamPlayer.play` を直接呼ぶ逃げ道だけ自衛が要る。
- **「続いている音」を短い音の焚き直しで作らない**。走行音・風・雨・炎・足音のループは
  `App.withSustained` で 1 本の宣言にする（焚き直しは間隔が音より長いと途切れ、短いと二重に鳴る）。
- **音のデザインは SfxSynth かファイルのどちらかにそろえる**。1ゲームの中で合成と録音素材を
  同じ種類の音（例: 効果音どうし）で混在させない — 質感が揃わない。
