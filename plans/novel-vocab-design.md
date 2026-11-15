# ノベルの語彙と舞台の土台（N1〜N3）の設計

- 状態: 設計の下書き（2026-11-15）。実装はまだ。エンジン（engine_world）に pub を足すので、着手の前に人と相談する。
- 親の計画: [plans/novel-data-only.md](novel-data-only.md) の N1〜N3。語彙 19 個と書き方 B（主の引数 1〜2 つは位置・ほかは `key=value`）は 3.16〜3.18 で決めた物を前提にする。
- 数は数えた物。【推】は見込み。

## 0. 決めた事（要約）

1. **N1**: 話し手は `novel.story.json` の `names` の鍵、最初のノードは同じ Doc の `opening`、描き出しの場面は新しい Doc `novel.shots.json`。`vocab.json` は「どの Doc のどの鍵を見るか」だけを書き、go が Doc を読んで名前を集める。名前を足すのに Flix を走らせない。
2. **N2**: コマンドの表は **Flix の record の一覧**に置く（3 案を比べた。3 章）。1 コマンド = 引数の表 + `apply` 1 つ。引数の表はそのまま `vocab.json` に書き出し、go が `bin/fge yarn build` で型・範囲・必須・Doc の名前まで検査する。実行時も同じ表で読む。
3. **N2**: 時間で動く舞台の値は、エンジンの新しい `PropertyTween`（名前付きの値 + tween の表）に入れる。値をここに入れたコマンドは、セーブ・settle・素材待ちを書かずに済む。1 コマンド足すのは「表に 1 行 + View で値を読む」の 2 か所になる。
4. **N3**: セーブの Mark は「今のノードに入った時の舞台」をまるごと持つ（今は台詞の時点の 5 つの値だけ）。戻す時はそこからノードの頭を当て直すので、生きて読んだ時と同じ舞台になる。ノードの頭で言い直す決まりと血鱗の StageAudit は要らなくなる。
5. 置き場: 汎用の 2 つ（`YarnCommands`・`PropertyTween`）と ease の名前（`Curve.Ease`）を engine_world へ。コマンドの中身（bg・show など）は N2 の間はテンプレートに置き、N4 でエンジンへ上げる。go は vocab v2 と引数の検査。
6. ゲームは N2・N3 では追随しない。テンプレートだけ先に移し、ゲームは N4 の後に 1 回で移る（2 回の当て直しを避ける）。

## 1. 今の形（数えた物）

| 困り事 | 今の形 | 数 |
|---|---|---|
| 1 コマンド足すと何か所も直す | `Stage.Cue` の case・`cueOf`・`commandNames`・`applyCue`・`hasDuration`・`settle`・`Saves.Mark`（と toJson/fromJson）・`WorldRead.cueNames`・View | テンプレートの `Stage.Cue` を使う所 41（`refactor usages`。5 つの def） |
| 引数の誤りが実行まで分からない | go の `check.go` は名前だけ見る。`parse.go` は空白で割るだけ（`"…"` を 1 つの引数にできない） | — |
| 語彙の正が Flix の enum | `Talk.Speaker`・`Talk.Node`・`Stage.commandNames`。`vocab.json` は `make talk-vocab`（Flix を走らせる） | `Talk.Node` を使う所 9（test 4） |
| 場面表がコード | `Shots.names` と `sceneOf` の match（テンプレート 15 場面） | haioku の場面表 約 170 行（下書き 1 章） |
| 舞台の一部しかセーブに残らない | `Saves.Mark` = bookmark + shot・ambience・particles・mode・cast。kankan は dim・zoom・text・speed を足したが Mark に入れていない | ノードの頭に並ぶ舞台のコマンド: kankan 96（20 ノード）・血鱗 49（11）・izakaya 22（6）・haioku 7（7）。一部は本当の場面替え【推】 |
| 戻した時に相対の動きが 2 回効く | `markAt` は台詞の時点の舞台を取り、`restore` はそれにノードの頭からのコマンドをもう一度当てる。今は全部が絶対の値なので害が無い | 語彙 19 の `move dx=/dy=` が入ると 2 回効く |

## 2. N1 — 語彙の正を Doc と台本へ

### 2.1 Doc の形

```jsonc
// assets/novel.story.json（足すのは opening だけ。names はもうある）
{ "opening": "Station", "names": { "chinatsu": "千夏", "me": "私" }, ... }

// assets/novel.shots.json（新しい Doc。make render の SHOT とギャラリーの並びの正）
{ "version": 1, "title": "描き出しの場面",
  "shots": [
    { "name": "nvl",    "node": "Station", "say": 2,  "at": 4.0 },
    { "name": "choice", "node": "Paddy",   "until": "choices", "at": 4.0 },
    { "name": "night",  "node": "River",   "until": "choices", "vars": { "$closeness": "2" }, "at": 6.5 },
    { "name": "save",   "node": "River",   "say": 2, "open": "save", "at": 4.0 },
    { "name": "title",  "open": "title", "at": 3.0 } ] }
```

- `say` = ノードの n 番目の台詞（今の `nthLine`）、`until: "choices"` = 選択肢まで（今の `toChoices`）。どちらも無ければノードの頭。
- `open` は画面の種類で、取れる値はテンプレートの画面だけ（title・log・save・load・settings・ask・credits・hold）。読む所で 1 回だけ enum に変える。知らない値は `Log.fellBack` してその場面を飛ばす（描き出しは止めない）。
- 「セーブを 3 つ入れた」「縁側まで読んだ」のような組み立て（`withSlots`・`readThrough`）はテンプレートのコードに残し、`open: "save"` などがそれを呼ぶ。場面ごとの値（ノード・台詞・変数・秒）だけを Doc に出す。
- コードで組みたい場面（haioku の 3D の部屋など）は、ゲームの `Shots.extra()` が返す一覧を後ろに足す口を残す（今の形のまま）。

### 2.2 vocab.json v2 は「どこを見るか」を書く

```jsonc
{ "version": 2,
  "speakers": { "from": [{ "doc": "../novel.story.json", "keys": "names" }] },
  "nodes":    { "from": [{ "doc": "../novel.story.json", "path": "opening" },
                         { "doc": "../novel.shots.json", "path": "shots[].node" }] },
  "tags": { ... },          // N4c まで今のまま（コードが書く）
  "commands": [ ... ] }     // 3 章。コードが書く
```

- go は `from` の Doc を読んで名前を集める。Doc が無い・読めない時は 1 行言って、その欄の検査だけを飛ばす（今の `--no-vocab` と同じ扱い）。
- v1（文字列の配列）もそのまま読む。ゲームは N4 の後まで v1 のまま動く。
- `speakers` と `nodes` の欄は Doc を見るだけなので、話し手やノードを足しても `vocab.json` は変わらない。`vocab.json` が変わるのはコマンドの表（コード）を変えた時だけになり、その時はどうせ Flix を走らせている。

### 2.3 コード側

- `Talk.Speaker`・`Talk.speakers`・`Talk.speakerId`・`Talk.Node`・`Talk.nodeName` を消す。最初のノードは `StoryDoc.openingOf(res#story)`、話し手の一覧は `StoryDoc.speakerIds`。使う所は src 5・test 4（`refactor usages`）。
- `Shots.flix` は Doc を読んで World を組む物になる（`names()` は Doc の並び）。
- 検査: `TestDocs` の「vocab.json がコードと一致」は残す（中身はコマンドの表だけになる）。「opening がシナリオにある」「shots の node がシナリオにある」は go の build が見るので、Flix のテストからは外せる。

## 3. N2 — 演出コマンドの共通の口

### 3.1 表をどこに置くか: 3 案の書き味

同じ `<<overlay 濃さ [color=] [from=] [time=] [ease=]>>` を 3 通りで書いた（Flix は見本。細部の型は実装で決める）。

**案 A: Flix の record の一覧（引数は型付きの handle）**

```flix
// テンプレート src/Commands.flix
def overlay(): Command[Stage.Stage] =
    let alpha = Param.num("alpha", 0.0, 1.0) |> Param.at(1) |> Param.required;
    let color = Param.choice("color", "black" :: "white" :: Nil) |> Param.default("black");
    let from  = Param.num("from", 0.0, 1.0);
    let time  = Param.time(0.0);
    let ease  = Param.ease(Curve.Ease.SmoothStep);
    { spec  = YarnCommands.spec("overlay", "画面に被せる色の濃さを時間で変える",
                  Param.erase(alpha) :: Param.erase(color) :: Param.erase(from) :: Param.erase(time) :: Param.erase(ease) :: Nil),
      apply = (now, a, st) -> st
          |> Stage.tween(Keys.overlayAlpha(), Param.get(from, a), Param.get(alpha, a), now, Param.get(time, a), Param.get(ease, a))
          |> Stage.set(Keys.overlayColor(), Param.get(color, a)),
      needs = Command.noAssets }
```

**案 B: Doc（JSON）に置き、Flix は汎用に読むだけ**

```jsonc
"overlay": { "summary": "画面に被せる色の濃さを時間で変える",
  "params": [ { "name": "alpha", "pos": 1, "type": "num", "min": 0, "max": 1, "req": true },
              { "name": "color", "type": "choice", "values": ["black", "white"], "default": "black" },
              { "name": "from", "type": "num", "min": 0, "max": 1 }, { "name": "time", "type": "time" }, { "name": "ease", "type": "ease" } ],
  "writes": [ { "tween": "overlay.alpha", "from": "$from", "to": "$alpha", "time": "$time", "ease": "$ease" },
              { "set": "overlay.color", "to": "$color" } ] }
// bg の via=slide・show の from=left・素材待ちの名前の引き方は writes で書けない
//   → "handler": "bg" と書いて Flix の match に戻る（表と中身が 2 か所に割れる）
```

**案 C: Flix の enum が正、go 用の表は enum から作る**

```flix
pub enum Cue { case Overlay(Float64, Color, Option[Float64], Float64, Curve.Ease)  ... }
pub enum CueKind { case Overlay ... }              // Flix には型から表を作る仕組みが無いので、種類の enum を別に持つ
def specOf(k: CueKind): Spec = match k { case CueKind.Overlay => spec("overlay", ...) ... }   // 網羅の検査は効く
def cueOf(c: Yarn.Command): Result[String, Cue] = match c#name { case "overlay" => ... }      // 引数の読み方は手で
def applyCue(now, cue, st) = match cue { case Cue.Overlay(a, col, from, t, e) => ... }
def settle / markOf / cueNames ... = match ...                                               // 今と同じく case ごとに
```

| | A record の一覧 | B Doc | C enum から生成 |
|---|---|---|---|
| 1 コマンド足す所 | 表に 1 行（+ View で値を読む） | Doc に 1 行（書けない物は + Flix の handler） | enum・CueKind・specOf・cueOf・applyCue・settle…（今と同じ 4〜6 か所） |
| 引数の読み違い | handle で読むので鍵の打ち間違いが無い。型は handle が持つ | 鍵は文字列。`$alfa` は実行時まで分からない | 手で読むので今と同じ |
| 書ける演出の幅 | Flix で書ける物は全部 | tween と set の組だけ | 全部 |
| go の検査の元 | 表を書き出す（同じ表で実行時も読む） | Doc をそのまま | specOf を書き出す（cueOf とずれうる） |
| Doc の流儀 | 振る舞いはコード | 振る舞いが JSON に入る（`doc-conventions.md` の「ロジックを JSON に書き始めたら設計の匂い」） | 振る舞いはコード |
| ゲームが足す | ゲームの Flix で 1 行 | Doc で足せる（ただし tween と set の組だけ） | 足せない（enum を持つのはテンプレート） |

**決めた: 案 A。** 理由は 3 つ。(1) 1 コマンドの正が 1 か所で、実行時の読み方と build の検査が同じ表から出る。(2) B の利点「ゲームが Doc で部品を足せる」は、下書き 3.15 の「部品はエンジン、名前付きの組み合わせは Doc（N5 の preset）」と役が重なり、B で書けない物（bg・show）で結局 Flix に戻る。(3) C は網羅の検査が効くだけで、直す所の数は減らない。Flix に型から表を作る仕組みが無いので、生成ではなく「表を別に書く」になる。

preset（N5）は Doc に置く。preset の `cue` は台本と同じ書き方なので、go は同じ表で preset の中も検査できる。

### 3.2 コマンド 1 つの形

```flix
// テンプレート（N4 でエンジンへ上げる）
pub type alias Command[st] = {
    spec  = YarnCommands.Spec,                                        // 名前・説明・引数の表
    apply = (Clock.Time[Stage.Story], YarnCommands.Args, st) -> st,   // 舞台を替える（純粋）
    needs = (Res.Res, YarnCommands.Args, st) -> List[String]          // 待つ素材の名前（textures / sounds）
}
```

- 今の `cueOf`・`applyCue`・`hasDuration`・`cueNames`・`commandNames` は、表を引く汎用の 1 本（`Commands.run`）に置き換わる。表に無い名前と引数の誤りは `Err` を返し、World が 1 行言って舞台はそのまま（今と同じ。台本の書き損じで止めない）。
- `hasDuration` は `PropertyTween.isMoving` で表から引けるので、コマンドごとに書かない。
- `needs` の既定は「`Param.name` の引数で `ref` が素材の表を指す物」から自動で作る。bg のように Doc を 1 段引く物だけ手で書く。
- `se`（1 回鳴らすだけ）のように舞台を変えないコマンドは `apply` で何もせず、出来事を出す口（`emit`）を record に足す【推】。

### 3.3 引数の表（`YarnCommands`）

- 型: `num`（min・max）・`time`（秒 0〜60）・`ease`・`choice`（取れる値の列）・`name`（`ref` で Doc の鍵か素材の表を指す）・`flag`（true/false）・`text`（`"…"`）・`offset`（`40px` か `3.2%`）。
- 位置の引数は 2 つまで（3.17 の表の直し）。ほかは `key=value`。同じ鍵を 2 回書く・知らない鍵・位置の数の超過は誤り。
- 「どちらか 1 つは要る」（`hide` の名前か `at=`、`feed` の本文か `clear=`）は `oneOf` で表に書く。
- `Args` は外から作らせない（非 pub の enum + `pub type alias`）。`parse(spec, command)` を通った物だけが `Param.get` で読めるので、`get` は失敗しない。
- 書き出し: `YarnCommands.toJson(specs)` が `vocab.json` の `commands` を書く。形は scratchpad の vocab-spike/vocab.json の `primitives` に合わせる（`name`・`pos`・`type`・`min`・`max`・`values`・`ref`・`default`・`req`・`summary`）。

### 3.4 go の検査（`bin/fge yarn build`）

- `parse.go`: コマンドの中を空白で割る前に `"…"` を 1 つの引数にまとめる（`feed` の本文）。`{式}` を断るのは今のまま。
- `check.go`: v2 の `commands` があれば引数を表で検査する。知らない鍵には近い鍵を `suggest.Hint` で出す（今の名前の検査と同じ言い方）。`ref` は `from` と同じ書き方で Doc の鍵を集めて照らす（`<<bg statoin>>` が build で落ちる。今は実行時の `Err`）。
- 実行時と build で判定がずれないように、受ける行と断る行の見本を 1 つの JSON（`go/internal/yarn/testdata/command-args.json`【推】）に置き、go のテストと engine_world のテストの両方が読む。

### 3.5 時間で動く値（`PropertyTween`）

```flix
let k = PropertyTween.numKey("overlay.alpha");          // NumKey と NameKey は別の型（取り違えを型で止める）
let t = PropertyTween.tween(k, from, to, now, seconds, Curve.Ease.SmoothStep, table);
PropertyTween.numAt(now, k, fallback, t)                // View が読む
PropertyTween.settle(t)                                 // 動きを終わりの値にし、one-shot を消す
PropertyTween.toJson(t) / fromJson(json)                // セーブ（終わりの値だけ）
```

- 値は数（tween できる）と名前（すぐ替わる）の 2 種類。`trigger(key, now, seconds)` は一度だけの演出（揺れ・刺す）用で、`settle` で消える。
- 名前は Godot の `Tween.tween_property` に合わせた。鍵は `層.値`（`overlay.alpha`・`camera.zoom`・`text.at`）。ゲームが足す値は `game.` で始める。
- ease の名前は今 `EcsTween.Easing`（EaseIn・EaseOut・EaseInOut）しか無い。語彙 19 は Penner の名前と smoothstep を使う（3.17）ので、`Curve.Ease` を足して `EcsTween` もそれを使えるようにする（相談事）。
- 背景（前の写真を下に敷いて重ねる）と立ち絵（出入りと表情のクロスフェード）は、値 1 つでは表せないので、今の `Stage` と `Cast` の型のまま残す。この 2 つは自分の `settle` と JSON を持つ（今もある）。

### 3.6 ゲームが自分のコードで演出を 1 つ足す口

```flix
// ゲームの src/GameCommands.flix（テンプレートは空の一覧。テンプレートの追随で上書きしない）
pub def all(): List[Commands.Command[Stage.Stage]] = stab() :: Nil
// ゲームの src/GameView.flix（テンプレートは Nil を返す。View が決まった z の範囲で呼ぶ）
pub def draw(res: Res.Res, now: Clock.Time[Stage.Story], stage: Stage.Stage): List[Render.Item]
```

- 足したコマンドは `PropertyTween` にだけ値を書く決まりにする。そうすればセーブ・settle・素材待ちはテンプレートの汎用の道を通る（ゲームが Saves や WorldRead を直さない）。
- 値 1 つで足りない物（線を描き足す傷・頁で沈む深さ）は、`game.` の値を数個持って GameView で描く。それでも足りない時だけ src を持つ作品になる（2 本立ての境目。下書き 2 章）。
- `make talk-vocab` は `Commands.all() ++ GameCommands.all()` を書き出す。ゲームのコマンドも同じ検査に乗る。

## 4. N3 — 舞台の値をセーブに残す

### 4.1 Mark が持つ物を「ノードに入った時の舞台」に変える

```flix
pub type alias Mark = { bookmark = YarnRunner.Bookmark, entry = Stage.Snapshot }
// Snapshot = 背景（写真・時間帯）・立ち絵と小物（今の Cast.Mark）・文章の出し方・PropertyTween の終わりの値。
// 環境音・BGM・続く粒（fx）も PropertyTween の名前の値に入れる。
```

- `World.Read` に `entry: Stage.Snapshot` を持ち、ノードが替わった時（YarnRunner の nodeOf が替わった時）に今の舞台を settle して入れる。
- `restore` は `entry` から舞台を作り、ブックマークでノードの頭から当て直す（今の流れのまま）。ノードの頭からのコマンドが全部もう一度効くので、**生きて読んだ時と同じ舞台**になる。相対の動き（`move dy=`）も 2 回効かない（1 章の最後の行）。途中の動きは settle で終わりの値にそろう。
- バックログと「戻る」も同じ Mark を使う。`entry` はノードの間で同じ値を共有するので、行ごとに増えるのは参照だけ【推】。
- セーブの JSON は version 3。`"entry": { "bg": …, "cast": …, "mode": …, "props": { "overlay.alpha": 0.6, … } }`。version 2 の枠（photo・grade・ambience・particles・mode・cast）は読む所で entry に読み替える。v2 は台詞の時点の値だが、今のコマンドは全部が絶対の値なので同じ舞台になる。読めない欄は既定で続ける（fail-open）。

### 4.2 頭から開く時（Studio のプレビュー・`talk node=`・描き出し・テープの「ここから遊ぶ」）

- セーブが無いのでノードに入った時の舞台が分からない。これが今「ノードの頭で言い直す」決まりの残りの理由。
- `WorldRead.entryOf(res, node)`: 最初のノードから音を出さずに流し、選択肢は全部たどって、そのノードに最初に着いた道の舞台を返す（血鱗の `StageAudit.arrive` と同じ流し方）。着かないノードは空の舞台で 1 行言う。
- Res（台本が替わると作り直す物）に、ノードごとの結果を一度だけ作って置く【推】。作る代金は 4 本の台本（ノード 6〜20）で数 ms【推】。測ってから置き場を決める。
- `openAt` はこの `entry` から始める。これで実機・プレビュー・セーブから戻した所が同じ舞台になる。

### 4.3 消える物

- ノードの頭の言い直し: 台本から消してよい（消さなくても絶対の値なので害は無い）。kankan の `<<text bottom normal left>>` 32 回など。消すのは N4 の追随の時に機械で（同じノードに入る全部の道の `entry` に同じ値があれば消す）。
- 血鱗の `StageAudit`（122 行）: 「生きて読んだ舞台 = 戻した舞台」が作りで守られるので要らない。代わりにテンプレートに汎用のテスト 1 本（7 章）。

## 5. 置き場と増える pub

| パッケージ | 足す・変える物 |
|---|---|
| engine_world | `YarnCommands`（Spec・Param・Args・parse・toJson）、`PropertyTween`、`Curve.Ease` |
| テンプレート | `Commands.flix`（表と `run`）、`GameCommands.flix`・`GameView.flix`（空）、`Stage`（PropertyTween を持つ・Snapshot）、`Saves`（Mark v3）、`WorldRead`（entry・entryOf・`cue` を `Commands.run` に）、`Shots`（Doc を読む）、`StoryDoc`（opening）、`Talk`（enum を消す）、`assets/novel.shots.json` と schema・`editor.resources` |
| go | `parse.go`（`"…"`）、`check.go`（vocab v2・引数・ref・from）、`graph.go`（コマンドの分類を v2 の表から色分け。下書き 3.18 の残り） |
| engine（core） | なし |

増える pub（engine_world・見込み 30 前後）:

- `YarnCommands`: `Spec`・`spec`・`Args`（外から作れない）・`parse`・`toJson`・`fromJson`（テスト用）
- `YarnCommands.Param`（mod）: `Param[t]`・`num`・`time`・`ease`・`choice`・`name`・`flag`・`text`・`offset`・`at`・`required`・`default`・`oneOf`・`erase`・`get`
- `PropertyTween`: `Table`・`NumKey`・`NameKey`・`numKey`・`nameKey`・`empty`・`tween`・`set`・`trigger`・`numAt`・`nameAt`・`pulseAt`・`isMoving`・`settle`・`toJson`・`fromJson`
- `Curve.Ease`（enum: Linear・SmoothStep・Penner の In/Out/InOut × Sine・Quad・Cubic・Quart・Expo・Back・Elastic・Bounce）・`Curve.ease`

層の物差しとの関係: どれも抽象の境目（実装を差し替える層）ではなく、1 つの実装の部品。`YarnCommands` の 2 つ目の使い手は RPG のテンプレートの会話【推・未確認】。無くても、Yarn と同じパッケージに置いて go と表の形を合わせる理由がある。

## 6. 移り方

| 対象 | いつ | 中身 | 機械でできるか |
|---|---|---|---|
| テンプレート | N1〜N3 の中で | 10 個のコマンドを語彙 19 の名前に（nvl・adv・clear → window、ambience・se → audio、char・item → show・hide） | 台本 51 行は convert.py（4 本 924 行で書けなかった行 0） |
| izakaya | N2 の後に試しに 1 本目【推】 | `<<hop>>` は preset が N5 まで無いので GameCommands に 1 行。湯気と煙は fx | 台本は convert.py。src はテンプレートを当て直し、足した 105 行のうち 66 行が消える【推】 |
| kankan・haioku・血鱗 | N4 の後に 1 回で | 追加のコマンドは標準の語彙に移り、残りは GameCommands と GameView へ | 台本は convert.py（引数を足せば 95.1% が同じ意味）。src はテンプレートを当て直してから、ゲームだけの演出を手で写す |

- N2・N3 だけでゲームを移すと、kankan の追加コマンド（dim・flash・zoom・text・speed・hold）を GameCommands に書き直した後、N4 で標準に移ってもう一度消すことになる。当て直しは kankan で 2 回・血鱗で約 5 時間かかった（下書き 1 章）ので、ゲームは N4 の後の 1 回にする。
- 古いセーブ（v2）は読める（4.1）。古い vocab.json（v1）も go が読める（2.2）。

## 7. テストと門

- engine_world: `YarnCommands` は引数の型ごとに受ける・断るを 1 本ずつ、`command-args.json` の見本を全部。`PropertyTween` は tween の途中・settle・JSON の往復。`Curve.Ease` は 0 と 1 の端と真ん中。`make sync-layers` の後に `.layers/engine_world` で流す（`make test-engine_world` は偽の解決エラーになる。メモの決まり）。
- go: `go test ./internal/yarn`。同じ `command-args.json`。v1 と v2 の両方の vocab で build が通る事。
- テンプレート:
  - **戻した舞台 = 生きて読んだ舞台**: 全部のノードの全部の台詞で、生きて流した舞台（settle 後）と、その台詞の Mark を `restore` した舞台が同じ。ゲームも自分の台本で同じテストを持つ（StageAudit の代わり）。
  - 表の全部のコマンドを、必須の引数だけで 1 回ずつ `run` して落ちない（handle の書き忘れを拾う）。
  - vocab.json がコードと一致（今の `TestDocs` のまま）。
  - Saves v2 の JSON を v3 で読んで同じ舞台。
- 退行の門: **N1 と N2 の間、描き出しの絵が変わらない**（`templates/sound-novel-starter/reference/SHA256SUMS.txt` が同じ）。場面表を Doc に移しても、コマンドを表に移しても、同じ絵が出るはず。変わったら読み違い。
- 新しい仕組みの決まり（AGENTS.md）: `agents-pack/AGENTS.core.md` の早見表に「演出コマンドを足す → Commands の表に 1 行」を足し、`agent-eval/engine.json` に「引数の誤りを build で見つけて直す」お題を 1 本。古い書き方（`Stage.commandNames`・`Talk.Speaker`）を `bin/lint-rules/forbid.json` で止める。

## 8. 小分けの順と見積もり（実時間・【推】）

各段の後に `flix check` と波及したパッケージのテストだけ回す。レビューは N1 の後・N2 の後・N3 の後の 3 回にまとめる。

| # | 段 | 中身 | 見積もり |
|---|---|---|---|
| 1 | N1 | go の vocab v2 の `from`・story.json の opening・Talk の enum を消す | 2〜3 時間 |
| 2 | N1 | novel.shots.json と schema・Shots を Doc で組む。絵が同じ事を SHA で確かめる | 3〜4 時間 |
| 3 | N2 | engine_world の `YarnCommands` と `Curve.Ease`（相談の後） | 3 時間 |
| 4 | N2 | go の引数の検査・`"…"`・ref・共通の見本 | 3〜4 時間 |
| 5 | N2 | engine_world の `PropertyTween` | 2〜3 時間 |
| 6 | N2 | テンプレートの `Commands` 表・10 個を語彙 19 の名前で・台本の書き直し・GameCommands/GameView の口。絵が同じ事を確かめる | 5〜6 時間 |
| 7 | N3 | Snapshot・entry・Saves v3 と v2 の読み替え・entryOf・「戻した舞台 = 生きて読んだ舞台」のテスト | 4〜5 時間 |
| 8 | — | 早見表・agent-eval・forbid・docs/modules の 1 行 | 1〜2 時間 |

合計 23〜30 時間。3・5 はエンジン（engine_world）なので 1・2 と並べて進められる（同じパッケージを 2 人に触らせない）。

## 9. 相談事（着手の前に人へ）

1. engine_world に `YarnCommands`・`PropertyTween`・`Curve.Ease` を足してよいか（pub 30 前後）。テンプレートに置いたままにする別案は、ゲームが src を持つ間は同じ物が各ゲームに写るので取らなかった。
2. コマンドの中身（bg・show など）を N2 ではテンプレートに置き、N4 でエンジンへ上げる順でよいか。最初からエンジンに置くと、N4 の語彙が固まる前に pub が決まってしまう。
3. テンプレートのコマンド名を N2 で語彙 19 の名前に替える（`<<char>>` → `<<show>>` など）。テンプレートを新しく作るゲームはここから新しい名前になる。
4. `se` の出来事を出す口（3.2）と、GameView の z の範囲（`docs/z-bands.md` のどこか）は実装の前に決める。
