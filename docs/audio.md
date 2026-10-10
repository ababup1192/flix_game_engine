# 音の鳴らし方（audio.md）

ゲームに音を付けるための一枚。BGM・効果音（sfx）を「鳴らす」までの最短手順と、
迷いやすい「どっちのやり方で鳴らすか」「音そのものはどう作るか」をまとめる。

- 実体: `GameEngine.Audio`（engine/src/GameEngine.flix。再生・停止・音量・ループの effect）・
  `AudioStreamPlayer`（engine/src/render/AudioStreamPlayer.flix。上の薄いラッパ）・
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

3. 「前後の World から鳴らす音名を導く」純関数を書く（templates/race-starter/src/Sfx.flix を削った形）。

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

ゲーム側は `src/render/SfxRender.flix` に「音のデザイン」だけを書き、`SceneRender.all` から
`renderAll` を呼んで `assets/sfx/` へ WAV を書き出す（`make render-all`）。合成と WAV エンコードは
engine_tools 側の `SfxSynth.wavBytes` / `writeBytes` / `renderSet` が持つので、ゲーム側は
波形の足し算だけ書けばよい。

`templates/race-starter/src/render/SfxRender.flix` と同じ組み立て方の抜粋:

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
