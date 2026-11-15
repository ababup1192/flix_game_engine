# ノベルの語彙と舞台の土台（N1〜N3）の設計

- 状態: 第 3 版（レビュー 3 回目 91 点で合格・2026-11-15）（2026-11-15）。1 回目のレビュー（70 点）の M1〜M11・O1〜O11、2 回目（84 点）の N1・N2・P1〜P5 を入れた。実装はまだ。
- 親の計画: [plans/novel-data-only.md](novel-data-only.md) の N1〜N3。語彙 19 個と書き方 B（主の引数 1〜2 つは位置・ほかは `key=value`）は 3.16〜3.18 で決めた物、変数の表示名は 3.19 を前提にする。
- 数は数えた物。【推】は見込み。

## 0. 決めた事（要約）

1. **N1**: 話し手は `novel.story.json` の `names`、変数とフラグの表示名は同じ Doc の `vars`、最初のノードは `opening`、描き出しの場面は新しい Doc `novel.shots.json`。`vocab.json` には「どの Doc のどの鍵を見るか」（`from`）だけを書き、go が Doc から名前を集める。名前を足すのに Flix を走らせない。
2. **N2**: コマンドの表は **Flix の record の一覧**に置く（3 案を比べた。3.1）。1 コマンド = 引数の表 + `apply` 1 つ。`apply` は舞台と「出来事の列」（頁をめくる・音を鳴らすなど）を返す。引数の表はそのまま `vocab.json` に書き出し、go が `bin/fge yarn build` で型・範囲・必須・Doc の名前まで検査する。実行時も同じ表で読む。
3. **N2**: 時間で動く舞台の値はテンプレートの `PropertyTween`（名前付きの値 + tween の表）に入れる。ここに値を書いたコマンドは、セーブ・settle・素材待ちを書かずに済む。1 コマンド足すのは「表に 1 行 + View で値を読む」の 2 か所になる。
4. **N3**: セーブの Mark は**台詞の時点の舞台と頁をまるごと**持つ。戻す時は、バックログを作るために台本の当て直しは続けるが、舞台と頁は最後に Mark の値で置き換える。「ノードに入った時の舞台」を持つ案と写しで比べ、頁が崩れる事も写しで確かめてから決めた（4.1）。
5. 置き場: `YarnCommands`（引数の表・読み方・書き出し）と `Curve.Ease`（ease の名前）を engine_world へ。`PropertyTween` とコマンドの中身（bg・show など）は N4 までテンプレートに置く。go は vocab v2 と引数の検査。YarnRunner は変えない。
6. ゲームは N2・N3 では追随しない。テンプレートだけ先に移し、ゲームは N4 の後に 1 回で移る（当て直しを 2 回しない）。

## 1. 今の形（数えた物）

| 困り事 | 今の形 | 数 |
|---|---|---|
| 1 コマンド足すと何か所も直す | `Stage.Cue` の case・`cueOf`・`commandNames`・`applyCue`・`hasDuration`・`settle`・`Saves.Mark`（と toJson/fromJson）・`WorldRead.cueNames`・`WorldRead.cue`（頁と音）・View | テンプレートで `Stage.Cue` を使う所 41（5 つの def） |
| 引数の誤りが実行まで分からない | go の `check.go` は名前だけ見る。`parse.go` は空白で割るだけ（`"…"` を 1 つの引数にできない） | — |
| 語彙の正が Flix の enum | `Talk.Speaker`・`Talk.Node`・`Stage.commandNames`。`vocab.json` は `make talk-vocab`（Flix を走らせる） | `Talk.Node` を使う所 9（test 4） |
| 場面表がコード | `Shots.names` と `sceneOf` の match（テンプレート 15 場面）。縦・小さい画面の場面は `SceneRender` | haioku の場面表 約 170 行（下書き 1 章） |
| 舞台の一部しかセーブに残らない | Mark = bookmark + shot・ambience・particles・mode・cast。kankan は dim・zoom・text・speed を足したが Mark に入れていない | ノードの頭に並ぶ舞台のコマンド: kankan 96（20 ノード）・血鱗 49（11）・izakaya 22（6）・haioku 7（7）。一部は本当の場面替え【推】 |
| 戻した時に相対の動きがずれる | `restore` は Mark の値にノードの頭からのコマンドをもう一度当てる。今は全部が絶対の値なので害が無い | 4.1 のスパイクで再現した |

## 2. N1 — 語彙の正を Doc と台本へ

### 2.1 Doc の形

```jsonc
// assets/novel.story.json（足すのは opening と vars）
{ "opening": "Station",
  "names": { "chinatsu": "千夏", "me": "私" },
  "vars":  { "closeness": "親しさ" },          // 鍵は $ を付けない変数の名前。値は人に見せる名前
  ... }

// assets/novel.shots.json（新しい Doc。make render の SHOT とギャラリーの並びの正）
{ "version": 1, "title": "描き出しの場面",
  "shots": [
    { "name": "nvl",    "node": "Station", "say": 2,  "at": 4.0 },
    { "name": "choice", "node": "Paddy",   "until": "choices", "at": 4.0 },
    { "name": "night",  "node": "River",   "until": "choices", "vars": { "closeness": "2" }, "at": 6.5 },
    { "name": "log",    "open": "log", "pointer": [400, 300], "at": 4.0 },
    { "name": "save",   "node": "River",   "say": 2, "open": "save", "at": 4.0 },
    { "name": "title",  "open": "title", "at": 3.0 } ] }
```

- `say` = ノードの n 番目の台詞（今の `nthLine`）、`until: "choices"` = 選択肢まで（今の `toChoices`）。どちらも無ければノードの頭。
- `open` は画面の種類。取れる値はテンプレートの画面だけ（title・log・save・load・settings・ask・credits・hold）。読む所で 1 回だけ enum に変える。知らない値は `Log.fellBack` してその場面を飛ばす（描き出しは止めない）。
- 変数の鍵は Doc の間でそろえて `$` を付けない（story.json の `vars` と shots の `vars` が同じ書き方）。`$` を付けるのは台本の中だけ。shots の `vars` を `YarnStorage.withArgs` に渡す所で `$` を足す。
- 名指しの場面（`make render SHOT=foo`・`START=shot:foo`）が Doc に無い時は `Err`（近い名前の案つき）。全部を描く時（`render-all`）に読めない場面があれば 1 行言って飛ばす。
- `pointer` はマウスの位置（design の px）。今の log 場面の `{ x = 400, y = 300 }`。描き出しの場面だけの値で、遊びの配置ではないので px で持つ。
- 「セーブを 3 つ入れた」「縁側まで読んだ」の組み立て（`withSlots`・`readThrough`）はコードに残し、`open: "save"`・`open: "log"` がそれを呼ぶ。Doc に出すのは場面ごとの値（ノード・台詞・変数・秒・マウス）だけ。
- **Doc で表さない場面**: `portrait-*`・`short-*` は Doc の場面に画面の向きと大きさを掛けた物なので、`SceneRender` が Doc の場面の名前を引いて作る（今の `variantShots`・`smallShots`・`portraitShots` の形のまま）。`cast-sample`・`cast-veil`・`hold-none`・`hold-ring` はテスト用の Doc に差し替える場面なので、`SceneRender` のコードに残す。どれも描き出しだけの物で、ブラウザ版には入らない。
- コードで組みたい場面（haioku の 3D の部屋など）は、ゲームの `Shots.extra()` が返す一覧を後ろに足す口を残す。

### 2.2 vocab.json v2 は「どこを見るか」を書く

```jsonc
{ "version": 2,
  "speakers": { "from": [{ "doc": "../novel.story.json", "keys": "names" }] },
  "vars":     { "from": [{ "doc": "../novel.story.json", "keys": "vars" }] },
  "nodes":    { "from": [{ "doc": "../novel.story.json", "path": "opening" }] },              // 起点だけ
  "nodeRefs": { "from": [{ "doc": "../novel.shots.json", "path": "shots[].node" }] },         // あるかだけ見る
  "tags": { ... },                 // N4c まで今のまま（コードが書く）
  "commands": { "bg": { ... }, "show": { ... } } }   // 3.3。名前を鍵にした object（vocab-spike の primitives と同じ形）
```

- `nodes` は今と同じく「コードが開くノード」（起点）。go の `Unreached` と `yarn graph` の roots はここだけを起点にする。描き出しの場面のノードを起点に混ぜると、たどり着けないノードの知らせが黙るので、`nodeRefs`（シナリオにあるかだけ見る）に分ける。
- go は `from` の Doc を読んで名前を集める。Doc が無い・読めない時は 1 行言って、その欄の検査だけを飛ばす（今の `--no-vocab` と同じ扱い）。
- `vars`: 名前の無い変数（`<<declare>>` と `$x` に出てくる物）は `yarn check` で知らせる（止めない）。`yarn graph`・テープの状態の表・分岐の式・読み台本の条件は、表示名を主に出し `$名前` を小さく添える（下書き 3.19）。表示名の正は Doc で、go もテンプレートの TapeOut も同じ Doc を読む。
- v1（文字列の配列）もそのまま読む。ゲームは N4 の後まで v1 のまま動く。
- `vocab.json` が変わるのはコマンドの表（コード）を変えた時だけになる。その時はどうせ Flix を走らせている。
- **N1 で入れた形（実装 d513c2ef と 1 回目のレビューの直し）**:
  - `commands` は N1 では中身の空な object（`{"bg": {}, …}`）。引数の表（3.3）は N2 で中を埋める。go は配列と object の両方を読む。
  - `from` が名前を 1 つも拾わない時（`path`・`keys` の綴り違い）は 1 行言ってその欄を飛ばす。読めない Doc は Doc 1 つに 1 行。`nodes` が空なら届かないノードの知らせを流さない。版 3 以上の語彙は止める。
  - **段 4 で済んだ**: 引数の `ref` と `orNames`（from と同じ書き方で Doc の名前を集めて照らす）と、`DocsOf` が `ref`・`orNames` の Doc も返す所（`yarn check <ref の Doc>` が台本を見る）。読めない Doc の知らせは、その Doc を見ている欄の名前を全部並べる。from の行き先はあるが空（`"vars": {}`・`"shots": []`）の時は知らせず、綴り違いだけ知らせる。
  - **段 4 で済んだ**: 変数の表示名を `yarn graph`（JSON の `vars` と HTML の行）・テープのグラフの行・読み台本（条件と `<<set>>` の〔〕を「親しさ（$closeness）」に。台詞の `{$x}` は書き替えを .yarn へ戻すので変えない）に出す所。
  - **後へ回した**: テープの「状態」の表（plans/tape/mock-state.html の状態の行・カード・シート・分岐の式と「なぜ」）。今のテープには状態の表が無く、作るには実行中の変数を記録する口から要るので、plans/novel-data-only.md 3.19 の「後で」で作る。

### 2.3 門（コミット前の検査）

- `bin/lint-rules/precommit.json` の yarn の門の `when` に、vocab の `from` と `ref` が指す Doc（`novel.story.json`・`novel.shots.json`・`novel.backdrops.json`・`novel.cast.json` など）を足す。Doc だけを直したコミットでも、台本の名前の検査が流れる。
- `bin/fge yarn check <Doc のパス>`: Doc のパスを渡されたら、同じゲーム（`project.json` のあるフォルダ）の中で、その Doc を `from` か `ref` に書いている `vocab.json` を探し、そのフォルダを検査する。そういう `vocab.json` が無ければ（v1 のゲーム）何もせずに通る（ゲームのコミットを止めない）。

### 2.4 コード側

- `Talk.Speaker`・`Talk.speakers`・`Talk.speakerId`・`Talk.Node`・`Talk.nodeName` を消す。最初のノードは `StoryDoc.openingOf(res#story)`、話し手の一覧は `StoryDoc.speakerIds`、変数の表示名は `StoryDoc.varLabelOf`。使う所は src 5・test 4（`refactor usages`）。
- `Shots.flix` は Doc を読んで World を組む物になる（`names()` は Doc の並び）。
- `assets/story.schema.json` に `opening`（文字列）と `vars`（鍵 → 表示名の map。`names` と同じ形）を足す。`shots.schema.json` を新しく書き、`project.json` の `editor.resources[]` に載せる。
- `TestDocs` の「vocab.json がコードと一致」は残す（中身はコマンドの表だけになる）。「opening がシナリオにある」「shots の node がシナリオにある」は go の build が見るので、Flix のテストからは外せる。

## 3. N2 — 演出コマンドの共通の口

### 3.1 表をどこに置くか: 3 案の書き味

同じ `<<overlay 濃さ [color=] [from=] [time=] [ease=]>>` を 3 通りで書いた（Flix は見本。細部の型は実装で決める）。

**案 A: Flix の record の一覧（引数は型付きの handle）**

```flix
// テンプレート src/Commands.flix
def overlay(): Command[Stage.Stage] =
    let alpha = Param.num("alpha", 0.0, 1.0) |> Param.at(1) |> Param.required;    // Param.Req[Float64]
    let color = Param.choice("color", "black" :: "white" :: Nil) |> Param.default("black");
    let from  = Param.num("from", 0.0, 1.0);                                       // Param.Opt[Float64]
    let time  = Param.time(0.0);
    let ease  = Param.ease(Curve.Ease.SmoothStep);
    { spec      = YarnCommands.spec("overlay", "画面に被せる色の濃さを時間で変える",
                      Param.erase(alpha) :: Param.erase(color) :: Param.erase(from) :: Param.erase(time) :: Param.erase(ease) :: Nil),
      takesTime = true,
      apply     = (ctx, a, st) -> (st
          |> Stage.tween(Keys.overlayAlpha(), Param.getOpt(from, a), Param.get(alpha, a), ctx#now, Param.get(time, a), Param.get(ease, a))
          |> Stage.set(Keys.overlayColor(), Param.get(color, a)), Nil),
      needs     = Command.noAssets }
```

**案 B: Doc（JSON）に置き、Flix は汎用に読むだけ**

```jsonc
"overlay": { "summary": "画面に被せる色の濃さを時間で変える",
  "params": [ { "name": "alpha", "pos": 1, "type": "num", "min": 0, "max": 1, "req": true },
              { "name": "color", "type": "enum", "values": ["black", "white"], "default": "black" },
              { "name": "from", "type": "num", "min": 0, "max": 1 }, { "name": "time", "type": "time" }, { "name": "ease", "type": "ease" } ],
  "writes": [ { "tween": "overlay.alpha", "from": "$from", "to": "$alpha", "time": "$time", "ease": "$ease" },
              { "set": "overlay.color", "to": "$color" } ] }
// bg の via=slide・show の from=left・素材待ちの名前の引き方・頁をめくる は writes で書けない
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

**決めた: 案 A。** (1) 1 コマンドの正が 1 か所で、実行時の読み方と build の検査が同じ表から出る。(2) B の利点「ゲームが Doc で部品を足せる」は、下書き 3.15 の「部品はエンジン、名前付きの組み合わせは Doc（N5 の preset）」と役が重なり、B で書けない物（bg・show）で結局 Flix に戻る。(3) C は網羅の検査が効くだけで、直す所の数は減らない。Flix に型から表を作る仕組みが無いので、生成ではなく「表を別に書く」になる。

preset（N5）は Doc に置く。preset の `cue` は台本と同じ書き方なので、go は同じ表で preset の中も検査できる。preset の引数（`params`）も 3.3 と同じ型で書く。

### 3.2 コマンド 1 つの形

```flix
// テンプレート（N4 でエンジンへ上げる）
pub type alias Ctx = { now = Clock.Time[Stage.Story], node = String }   // apply が読める物（後に残る値は st の中）
pub enum Out {                       // apply が舞台の外へ出す出来事（後に残る状態は書かない）
    case ClearPage                   // NVL の頁をめくる（<<window clear>>・型が替わった時）
    case TurnPage                    // ADV の頁を送る（ADV の時の bg）
    case Sound(String)               // 効果音を 1 回（project.json の sounds の名前）
    case Event(String)               // その場の音や見た目の合図だけ。状態を書かない
}
pub type alias Command[st] = {
    spec      = YarnCommands.Spec,
    takesTime = Bool,                                              // 後の <<wait>> の間、テープの位置がこの行を指すか
    apply     = (Ctx, YarnCommands.Args, st) -> (st, List[Out]),   // 純粋
    needs     = (Res.Res, YarnCommands.Args, st) -> List[String]   // 待つ素材の名前（textures / sounds）
}
```

- **決まり**: `apply` と `Out` の結果で後に残る物（文字の枠を消しているか・頁の数・`game.` の値）は全部 `Stage` に入れ、Snapshot で戻す。World に残すのは頁だけで、頁も Mark で戻す（4.1）。`Out.Event` はその場の合図だけで、受けた側も状態を書かない。
- 今の `WorldRead.cue` が手で書いている 3 つは全部 `Out` で書ける。`<<clear>>` → `ClearPage`。`<<nvl>>`/`<<adv>>`（語彙 19 では `<<window>>`）は `apply` が古い舞台の型を見て、替わった時だけ `ClearPage`。ADV の時の `<<bg>>` は `apply` が `st` の型を見て `TurnPage`。`<<se>>` → `Sound`。
- `Commands.run(replay, ctx, command, st)` が表を引き、`Replay.Silent`（当て直し）の時は `Sound` と `Event` を落とす。頁の出来事は Silent でも通す（頁を作り直すため）。表に無い名前と引数の誤りは `Err` を返し、World が 1 行言って舞台はそのまま（今と同じ。台本の書き損じで止めない）。
- `takesTime` は表の欄で持つ（`PropertyTween.isMoving` からは引かない。秒が 0 の時も今の `hasDuration` と同じ答えにするため）。
- `needs` の既定は「`Param.name` の引数で `ref` が素材の表を指す物」から作る。bg のように Doc を 1 段引く物だけ手で書く。
- 台本を読んだ時に 1 回だけ引数を読む（O2）: `Res` に台本を入れる時、全部のコマンドを `YarnCommands.parse` して `Map[Yarn.Source, Result[String, Args]]` を作っておく。毎回の実行では読み直さない。台本が替わった時（`Resources.reloadRow`）に作り直す。

- **段 6 で入れた形（実装 5a81a390 と 1 回目のレビュー 79 点の直し）**:
  - `Commands.run` は `Commands.execute`（`run` は Flix の予約語）。
  - `takesTime = Bool` は `timing = Timing`（`Timed` / `Instant`。意味を Bool に持たせない決まり）。
  - `Ctx` に `res` を足し、`apply` の戻りは `Result[String, (st, List[Out])]`。show の既定の表情・位置（Doc の face・slot）を引き、Doc に無い名前を Err にするため（「名前を引く apply」）。
  - `needs` は 7 つとも手で書けたので、Spec から ref を読む pub（`YarnCommands.refsOf`）は要らなかった。engine_world は触っていない。
  - 台本を読んだ時に 1 回だけ引数を読む表（O2 の `Map[Source, Args]`）は入れていない（毎回 parse。性能だけの話なので N3 へ回した）。
  - コマンド名は語彙 19 へ: `bg 写真 [grade=] [time=]`（grade を省くと今の時間帯）・`window nvl|bottom|clear`・`audio ambience|se 音|off`（音は project.json の sounds の名前そのまま）・`fx`・`shake`・`show 名前 [表情] [at=] [time=]`・`hide 名前|all` / `hide at=位置`。show・hide の名前は cast にあれば人物・props にあれば小物（両方にあれば人物。重なりは TestDocs が止める）。`hide all` は人物と小物を全部消す（旧 `<<char off>>` は人物だけ）。show・hide の `time` は既定が Doc（fadeSeconds）なので `Param.time` でなく `num`。
  - 環境音の値の意味が短い名前（`evening`）から音の名前（`amb_evening`）へ変わった。Mark は version 2 のまま、音の名前は新しい鍵 `ambienceSound` に書く。`Saves.fromJson` はその鍵を先に見て、無ければ古い鍵 `ambience` の短い名前に `amb_` を付けて読む（字が `amb_` で始まるかで見分けると、`rain_loop` のような音の名前が読み違えられる）。version を 3 に上げる案は、N3 の Mark v3（Snapshot）と番号がぶつかるので取らなかった。タイトルの `titleAmbience` も音の名前にそろえた。
  - yarn graph（とテープのグラフ）の既定の分類に window（stage）と audio（sound）を足し、舞台の鍵を「名前 1 つ目の引数」（`audio ambience`・`audio bgm`）でも書けるようにした（`audio se` は残らない）。

### 3.3 引数の表（`YarnCommands`）

型は vocab-spike/vocab.json の 19 個に出てくる物に合わせた。N2 で表に入れる物と、使う部品が来る段まで表から外す物を分ける。

| vocab-spike の型 | 使う所 | N2 の型 | 入れる段 |
|---|---|---|---|
| `num`（30）・`name`（16）・`enum`（16）・`bool`（4） | ほぼ全部 | `num`（min・max）・`time`・`name`（`ref`）・`choice`・`flag` | N2 |
| `name\|off`・`name\|all`・`num/input` | fx・hide・wait | 型 + `orWords`（`off`・`all`・`input` を足して受ける） | N2（fx・audio が要る。wait はエンジンが読むので表に入れない） |
| `list(name)\|off` | audio の環境音を `a,b` で重ねる | `name` + `list` + `orWords` | N2（今の ambience を移す） |
| `num\|name` | audio の volume（数か Doc の音量の名前） | `num` + `orNames`（`ref`） | N2 |
| `offset`（`40px`・`3.2%`） | move の dx・dy | `offset` | N4（move と一緒） |
| `enum\|#rgb` | overlay の color | `color`（決まった語か `#rgb`） | N4（overlay と一緒） |
| `name.name`（点で区切った名前） | fx の `on=whale.stab` | `point`（絵の名前 + Doc の点の名前） | N4b（絵の中の点と一緒） |
| text（`"…"`） | feed の本文 | `text` | N6（feed と一緒）。`parse.go` の `"…"` だけ N2 で入れる |
| 項目の Doc が決める | hud の値 | — | N6 で決める |
| preset の params が決める | preset の引数 | 上の型で preset ごとに書く | N5 |

- 共通の引数は `time` と `ease` だけにする。語彙 19 の案の `wait=` は 4 本で 0 回なので N2 では表に入れない（止めたい時は台本で `<<wait 秒>>`）。要る作品が出たら、エンジンが読む形を決めてから足す。
- 位置の引数は 2 つまで（3.17）。ほかは `key=value`。同じ鍵を 2 回書く・知らない鍵・位置の数の超過は誤り。
- 「どちらか 1 つは要る」（`hide` の名前か `at=`）は `oneOf` で表に書く。
- 必須と省ける物は型で分ける（O1）: `Param.Req[t]` の `get` は `t`、`Param.Opt[t]` の `getOpt` は `Option[t]`。既定のある物は `Req` と同じ扱い。表に入れていない handle を `get` するのはプログラマの誤りなので `bug!`（`docs/error-handling.md` の「前提が破れた所」）。7 章のテストで全部のコマンドを 1 回流して拾う。
- `Args` は外から作らせない（非 pub の enum + `pub type alias`）。`parse(spec, command)` を通った物だけが読める。
- 書き出し: `YarnCommands.toJson(specs)` が `vocab.json` の `commands`（名前を鍵にした object）を書く。1 つの引数の欄は vocab-spike と同じ（`name`・`pos`・`type`・`min`・`max`・`values`・`ref`・`default`・`req`）に `orWords`・`orNames`・`list`・`oneOf` を足す。
- **段 3 で済んだ（実装 a47c9646 と 1 回目のレビューの直し）**:
  - `summary` はコマンドにだけ付ける（引数ごとの説明は持たない）。
  - `ease` は `"type": "ease"` に `values`（Curve.easeTable の 26 の名前）を並べて書き、go は名前の一覧を持たない。`choice` と `ease` で `values` が空なら表の誤り（go の validate と Flix の fromJson の両方で止める）。型に合わない既定の値も表の誤り。
  - `Param.Req` / `Param.Opt` を見分ける目印の型 `Must` / `May` は pub にした。Flix 0.78 では非 pub の空の enum は型の別名から使っても「使っていない」と止まるため（Clock.Real と同じ形）。
  - 表の誤り（`spec`）と、表に入れていないハンドルを読む誤り（`Param.get`）は bug!。`bin/lint-rules/fallback.json` に理由つきで除外した。
  - 2 つ目の使い手（rpg-starter の 13 個）は表で書けた。足りなかった物は 8 章の持ち越しに書いた。

### 3.4 go の検査（`bin/fge yarn build`）

- `parse.go`: コマンドの中を空白で割る前に `"…"` を 1 つの引数にまとめる。**`"` は木（dialogue.json）に残し、外すのは読む側（`YarnCommands.parse` と go の検査）**。外してしまうと `"x=1"` が key=value に読み違えられるため。台本のコマンドを `c#args` から直に読むコードには `"` が見える。`{式}` を断るのは今のまま。まとめるのは `<<set>>`・`<<declare>>`・`<<jump>>`・`<<stop>>` を分けた後のコマンドだけで、`<<set $x = "a b">>` の文字列には触れない（go のテストで 1 本見る）。
- `check.go`: v2 の `commands` があれば引数を表で検査する。知らない鍵には近い鍵を `suggest.Hint` で出す（今の名前の検査と同じ言い方）。`ref` は `from` と同じ書き方で Doc の鍵を集めて照らす（`<<bg statoin>>` が build で落ちる。今は実行時の `Err`）。
- 実行時と build で判定がずれないように、受ける行と断る行の見本を 1 つの JSON（`go/internal/yarn/testdata/command-args.json`【推】）に置き、go のテストと engine_world のテストの両方が読む。

### 3.5 時間で動く値（`PropertyTween`・テンプレート）

```flix
let k = PropertyTween.numKey("overlay.alpha");          // NumKey と NameKey は別の型（取り違えを型で止める）
let t = PropertyTween.tween(k, from, to, now, delay, seconds, Curve.Ease.SmoothStep, table);
PropertyTween.numAt(now, k, fallback, t)                // View が読む
PropertyTween.settle(t)                                 // 遅れて始まる物も含め、全部を終わりの値にし、one-shot を消す
PropertyTween.toJson(t) / fromJson(json)                // セーブ（終わりの値だけ）
```

- 値は数（tween できる）と名前（すぐ替わる）の 2 種類。`trigger(key, now, delay, seconds)` は一度だけの演出（揺れ・刺す）用で、`settle` で消える。
- **開始の遅れ（`delay`）を今から入れる**。preset（N5）の `at:` と GameCommands の時刻表がこれで書ける。`settle` は「まだ始まっていない物」も終わりの値にそろえる。
- 名前は Godot の `Tween.tween_property` に合わせた。鍵は `層.値`（`overlay.alpha`・`camera.zoom`・`text.at`）。ゲームが足す値は `game.` で始める。
- 背景（前の写真を下に敷いて重ねる）と立ち絵（出入りと表情のクロスフェード）は値 1 つでは表せないので、今の `Stage` と `Cast` の型のまま残す。この 2 つは自分の `settle` と JSON を持つ（今もある）。
- **EcsTween を広げない理由**: EcsTween は ECS の物（エンティティ）に付く動きで、実時間の秒で進む。舞台の値は物語の時計（`Clock.Time[Stage.Story]`。画面を開くと止まる）で進み、セーブに終わりの値を残し、settle で一度に終わらせる。進む時計とセーブの有無が違う。
- **ease の名前**: 今は `EcsTween.Easing`（Linear・EaseIn・EaseOut・EaseInOut）と `FxDoc.CurveSpec` の 2 系統がある。語彙 19 は Penner の名前と smoothstep を使う（3.17）。`Curve.Ease` を engine_world に置き、`PropertyTween` はそれを使う。道筋: `EcsTween.Easing` の case を `Curve.Ease` の同じ動きへ写す関数を足し、次の版で `EcsTween` の引数を `Curve.Ease` に替えて `Easing` を外す（FxDoc は JSON の語なので、読む所で `Curve.Ease` に替える）。
- **ease の既定は今の動きに合わせる**: 背景の重ねは線形（今の `Stage.fadeProgress`）、立ち絵は今の `Cast` の曲線のまま。語彙 19 の案の既定（smoothstep）は N4 で新しい部品にだけ使う。

### 3.6 ゲームが自分のコードで演出を 1 つ足す口

- 当て直しの間に `apply` が読む `Stage.pages` は途中の値（台詞の時点から数え足す）。後に残る結果は Snapshot で上書きされるので害は無い。頁の数を足すのは `ClearPage` を受ける所と NVL で入り切らずにめくる所の 2 つで、どちらも World の 1 つの関数を通す。

```flix
// ゲームの src/GameCommands.flix（テンプレートは空の一覧。テンプレートの追随で上書きしない）
pub def all(): List[Commands.Command[Stage.Stage]] = stab() :: Nil
// ゲームの src/GameView.flix（テンプレートは Nil を返す）
pub def draw(res: Res.Res, now: Clock.Time[Stage.Story], stage: Stage.Stage): List[Render.Item]
```

- 足したコマンドは `PropertyTween` にだけ値を書く決まりにする。そうすればセーブ・settle・素材待ちはテンプレートの汎用の道を通る（ゲームが Saves や WorldRead を直さない）。
- 口に入れる力: 頁の数を読む（`Stage` の `pages`。頁をめくるたびに World が足す。NVL で入り切らずにめくった時も。血鱗の「頁で沈む深さ」）・文字の枠を消す（`Stage` の `window.hidden` の値。View が読む）・`Out.Event`（その場の合図）・`Out.Sound`。どれも後に残る物は `Stage` にあるので、セーブと戻すは汎用の道を通る。
- GameView の z: `docs/z-bands.md` の world の中で、立ち絵（`Cast.items`）より上に小さな範囲を切る。文字の枠は hud の範囲（View の `zText` など）にあるので必ずその下になる。範囲の数は実装で `ZOrder` に 1 行書く。
- 値 1 つで足りない物（線を描き足す傷）は、`game.` の値を数個持って GameView で描く。それでも足りない時だけ src を持つ作品になる（2 本立ての境目。下書き 2 章）。
- `make talk-vocab` は `Commands.all() ++ GameCommands.all()` を書き出す。ゲームのコマンドも同じ検査に乗る。N4 で標準の表がエンジンに上がったら、標準の表はエンジンの版と一緒に配り（go が持つ）、ゲームの `vocab.json` には GameCommands の分だけを書く（O3）。

- **段 5・6 で入れた形**:
  - `PropertyTween` は鍵の型を 3 つ（`NumKey`・`NameKey`・`TriggerKey`）に分け、表は時計の名前を引数に取る `Table[c]`。同じ鍵に delay で予定を並べると時刻の順に動き、後から書いた物はそれより後に始まる予定を捨てる。始まった予定がまだ無い鍵は読む側の fallback（名前は None）。Godot の delay と同じ。
  - 環境音・パーティクル・揺れは `Stage` の `props` へ移した（鍵 `audio.ambience`・`fx.particles`・`camera.shake`）。背景と立ち絵は自分の形のまま。
  - `GameCommands.all()` と `GameView.draw(env: View.Env, stage)` はテンプレートでは空。env に Doc・並べ方の組（fit）・物語の時計・実時間が入る。z は `View.zGameView()` から 4 つ（立ち絵の 5 より手前）。
  - `Out.Event` は `World.Event.Signal` になる（テンプレートのコマンドは出さない）。
  - **N3 へ回した**: 口に入れる力のうち、文字の枠を消す（`window off`・`window.hidden`）と頁の数（`Stage.pages`）。今の Mark v2 には残せず、入れてもセーブで消えるため、Snapshot と一緒に入れる。

### 3.7 語彙 19 で書けない行と preset の行き先（M9）

3.17 のスパイクで「意味が変わる」11 行と、preset に回した種類を、どこが受けるかで振り分けた。

| 物 | 行数・作品 | 受ける所 | 要る物 |
|---|---|---|---|
| girl-depth（頁で 1 段ずつ沈む少女） | 4・血鱗 | GameCommands | `Stage` の `pages`・`game.girl.depth` |
| apparition-flicker（ライトの揺れと出て消える） | 2・haioku | N5 の preset | N4 の filter が時間で動くこと |
| blood-item-window（小物の間は枠を消す） | 2・血鱗 | N4b（絵ごとに「出る間は枠を消す」を Doc に） | `window.hidden` |
| vial-core（瓶に核を入れて大写し・枠を消す） | 2・血鱗 | GameCommands（N4b の後は preset） | `window.hidden` |
| haioku-blood（画面の上から血が垂れる） | 1・haioku | N4 の filter（時間で動く ShaderDoc） | — |
| scene（鯨・傷・瓶・少女・深さの組） | 10・血鱗 | GameCommands（深さの決まり）+ 組は N5 | `Stage` の `pages` |
| hop（跳ねる） | 8・izakaya | N5 の preset（N5 までは GameCommands） | `delay` |
| stab（ナイフが刺さる） | 5・血鱗 | GameCommands（切り抜き・物だけの揺れ・重ね順・線が N4 に無い） | `trigger`・GameView |
| wound（傷の線を描き足す） | 5・血鱗 | GameCommands | GameView |
| end（暗転→結末の字→スチル） | 3・血鱗 | N5 の preset（字を story.json の labels から引く口は N4 の text） | — |
| crash（揺れ + 砂嵐 + 筋のずれ） | 1・haioku | N5 の preset | N4 の filter |
| days（昼夜の窓と針） | 1・血鱗 | GameCommands（針と目盛り） | GameView |
| roll（光の点が跳ねて外へ） | 1・血鱗 | N4 の move `path=` の後に N5 | — |

## 4. N3 — 舞台の値をセーブに残す

### 4.1 Mark に何を入れるか: 2 案を写しで試した

前提（M1）: YarnRunner の出来事は Line・Choices・Command・Done の 4 つで、ノードの境目が無い。1 回の送りの中に「前のノードの残りのコマンド → jump → 次のノードの頭のコマンド → 台詞」がまとめて入る。

| | (a) YarnRunner に `Event.Entered(ノード)` を足し、ノードに入った時の舞台を Mark に持つ | (b) 台詞の時点の舞台をまるごと Mark に持ち、戻した後に舞台を置き換える |
|---|---|---|
| 戻し方 | 入った時の舞台から、ノードの頭のコマンドを当て直す | 頁とバックログのために当て直すが、最後に舞台を Mark の値にする |
| 相対の動き | 正しい | 正しい（当て直しの結果を使わない） |
| セーブ後に .yarn の頭を直した時 | 戻した舞台に効く | 効かない（セーブの時の舞台のまま） |
| エンジンの変更 | YarnRunner に case 1 つ。網羅の match が割れる所: engine の TestYarnOfficial・rpg-starter の `WorldTalk.applyEvent`・sound-novel の `WorldRead.absorbOne`、と各ゲームの写し | なし |
| v2 のセーブの読み替え | 台詞の時点の値を入った時の値として読む（絶対の値だけなので同じ） | 台詞の時点の値をそのまま読む |

**スパイク**（scratchpad の n3-spike。テンプレートを 3 つに写し、通るたびに 1 足すだけの `<<nudge>>` を足した。2 ノード・台詞 5 行の台本で、各台詞の「生きて読んだ値」と「その台詞の Mark から戻した値」を比べるテスト `TestNudge`。テストは TestKit・TestCast・TestRules・TestHold と合わせて流した）:

| 写し | 変えた行（src） | テスト | 各台詞の (生きて読んだ値, 戻した値) |
|---|---|---|---|
| 今のまま | — | 102 通過・1 落ち | (1,1) (2,2) **(3,1) (4,2) (4,2)** — 前のノードの分が消える（ノードの頭で言い直す理由そのもの） |
| (b) | Saves 6 行・WorldRead 5 行（計 11） | 103 通過 | (1,1) (2,2) (3,3) (4,4) (4,4) |
| (a) | Saves・World・WorldRead で計 16 行 + YarnRunner 2 行（エンジンの写しをテンプレートに置いて試した。use の書き換えは数えない） | 103 通過 | (1,1) (2,2) (3,3) (4,4) (4,4) |

どちらも今のテスト（読み込み・戻る・バックログ・素材待ち）を落とさなかった。

(a) と (b) を比べた時点の結論は (b)。結果は同じで、(b) はエンジンを変えず、行数も少なく（11 行と 18 行）、網羅の match を割らない。(b) の損（セーブ後に台本の頭を直しても戻した舞台に効かない）は作る人の手元だけの話で、作る人が見るプレビューは `openAt`（4.2）を通るのでセーブを使わない。YarnRunner に出来事は足さない。

**頁も戻す（2 回目のレビューの N1）**: (b) は舞台を戻すが、頁は当て直しで作るので崩れる。頁の作りは型（NVL / ADV）で変わり（`Page.show` が型を見て行を積む・型が替わった時だけ頁をめくる・ADV の bg は頁を送る）、当て直しの始めの型が台詞の時点の型になるため。同じ写しに、型が替わる台本（頭に `<<nvl>>` を書かない NVL → `<<adv>>` → `<<nvl>>`）と、ノードをまたいで続く NVL の頁の台本（`TestPage`・台詞 6 行）を足して比べた。

| 写し | 変えた行（src） | テスト | 結果 |
|---|---|---|---|
| (b) 舞台だけ戻す | 11 | 103 通過・1 落ち（`TestPage`） | 6 行のうち 3 行で頁が違う。ADV の 1 行目から戻すと前の NVL の 2 行が頁に残る。ノードをまたいだ 2 行から戻すと前のノードの行が頁から消える |
| (b) + 頁も Mark に入れる | +10（頁の分が Saves 2・WorldRead 5、JSON の往復の分が Saves 3） | 105 通過 | 6 行とも頁・型・枠を消した値が一致。セーブの JSON の往復（下）も一致 |

今は各ノードの頭で型を言い直しているので崩れが見えないが、4.3 で言い直しを消すと表に出る。縦の画面は同じ `Page` の行を積んで描く（`Page.show` の WhyNot）ので、頁の中身が一致すれば縦の形も同じになる。

**決めた: (b) に頁を足した形。** Mark は台詞の時点の舞台と頁を持ち、戻した後に両方を置き換える。

```flix
pub type alias Mark = { bookmark = YarnRunner.Bookmark, stage = Stage.Snapshot, page = Page.Page }
// Snapshot = settle した舞台: 背景（写真・時間帯）・立ち絵と小物（今の Cast.Mark）・文章の出し方・頁の数（pages）・
// PropertyTween の終わりの値（文字の枠を消しているか・環境音・BGM・続く粒（fx）・game. の値も入る）。
// page = その台詞を出した後の頁（積んだ行と今の行。文字送りは出し終えた形）。
```

- **決まり**: `apply` と `Out` の結果で後に残る物（文字の枠を消しているか・頁の数・`game.` の値）は全部 `Stage` に入れ、Snapshot で戻す。World に残すのは頁だけで、頁も Mark で戻す。`Out.Event` はその場の音や見た目の合図だけで、状態を書かない。写しでは枠を消す値（`veiled`）を Stage に置き、前のノードで消したまま jump した後の台詞から戻して、消したまま戻る事を確かめた。
- `restore` は Mark の舞台から当て直しを始め、バックログ・選択肢・ブックマークを作る。当て直した後に舞台を `Snapshot`、頁を `page` で置き換える。途中の動きは settle で終わりの値にそろう。
- Mark は `showLine` の中で、頁に行を積んだ後に作る（今の `markAt` は行を積む前に呼ばれるので、頁だけ後から入れる）。**セーブ画面とクイックセーブの道（`WorldRead.slotHere` → `slotAt(None)` → `markAt`）も、今の頁（`r#page` の出し終えた形）を入れる**。7 章の v3 の JSON の往復のテストは `slotHere` から始め、頁も比べる。
- 頁には書いた時の字（話し手の表示名・組んだ本文）が残る。セーブの後に台本や `names` を直すと、戻した頁だけ古い字になる。作る人の手元だけの話なので受け入れる。
- バックログと「戻る」も同じ Mark を使う。頁は `nvlRows` 行までなので、バックログの行ごとに持っても重くない【推】。
- セーブの JSON は version 3。`"stage": { "bg": …, "cast": …, "mode": …, "pages": 3, "props": { "overlay.alpha": 0.6, … } }` と `"page": { "lines": […], "current": … }`。version 2 の枠（photo・grade・ambience・particles・mode・cast）は読む所で `stage` に読み替え、頁が無いので頁は当て直しで作った物を使う（今と同じ）。読めない欄は既定で続ける（fail-open）。
- 写しで確かめた範囲（P1）: 1 本目の写しで直したのは `fromJson`（v2 の欄から舞台を作る）だけで、`toJson` は変えておらず、`nudge` はセーブの JSON を通っていない。2 本目の写しで `toJson` に `nudge` と `veiled` を足し、セーブ → JSON → 読み戻し → restore の往復で出し方と枠を消した値が戻る事を 1 本確かめた（`testStageSurvivesSaveJson`）。**頁・背景・立ち絵・PropertyTween の JSON の往復は試していない**（写しでは JSON から読んだ Mark の頁は None で、当て直しの頁に落ちる）。

### 4.2 頭から開く時（Studio のプレビュー・`talk node=`・描き出し・テープの「ここから遊ぶ」）

- セーブが無いので、前のノードから持ち越す舞台が分からない。これが「ノードの頭で言い直す」決まりの残りの理由。(a) でも (b) でも同じく要る。
- `WorldRead.buildEntryStage(res, node)`（計画の時の名前は entryOf）: 最初のノードから音を出さずに流し、選択肢は全部たどって、そのノードに最初に着いた道の舞台を返す（血鱗の `StageAudit.arrive` と同じ流し方）。着かないノードは空の舞台で 1 行言う。
- たどり方の上限: 選択肢の組み合わせで道が増えるので、ノードごとに最初に着いた 1 本で止め、全体で出来事の数に上限（StageAudit と同じ fuel）を置く。上限に当たったら着いていないノードは空の舞台で 1 行言う。
- Res（台本が替わると作り直す物）に、ノードごとの結果を一度だけ作って置く【推】。台本の差し替え（`Res.withDialogue`）と台詞の直し（`Res.withScriptEdits`。注釈の頁の「ここから遊ぶ」）の両方で作り直す。作る代金は 4 本の台本（ノード 6〜20）で数 ms【推】。測ってから置き場を決める。
- `openAt` はこの舞台から始める。これで実機・プレビュー・セーブから戻した所が同じ舞台になる。

### 4.3 消える物と残る物

- ノードの頭の言い直し: 台本から消してよい（消さなくても絶対の値なので害は無い）。消すのは N4 の追随の時に機械で（そのノードに入る全部の道の舞台に同じ値があれば消す）。
- 血鱗の `StageAudit`（122 行）の 2 つの検査のうち、「ノードの頭の 4 文」と「生きて読んだ舞台と頭だけ当てた舞台の比べ」は要らなくなる。「前のノードが scene の頁の上限（cap）に着いているか」は血鱗だけの決まりなので、ゲームのテストに残す。
- 代わりに、テンプレートの既存の `TestCast.testLiveStageMatchesTheRestoredStageOnEveryLine`（今は立ち絵だけを比べる）を広げ、舞台の全部（Snapshot）と頁を全部の台詞で比べる（O4）。

### 4.4 段 7 で入れた形（実装と、計画とのずれ。1 回目のレビュー 84 点の直しまで）

- **Mark**: `{ bookmark, stage = Stage.Snapshot, page = Option[Page.Page], entry = Option[Stage.Snapshot] }`。`Stage.Snapshot` は外から作らせない型（非 pub の enum + `pub type alias`）で、作る口は `Stage.snapshotOf`（settle してから包む）と、セーブの JSON を読む所の `Stage.makeSnapshot`。`page` と `entry` は、それを書く前のセーブ（version 2 と、`entry` の無い version 3）では None。
- **ずれ: Mark にノードに入った時の舞台（`entry`）も持つ**（4.1 の (a) の情報を、YarnRunner を変えずに持つ形）。生きて読む時も当て直しも、出来事の .yarn の行で居るノードを引き（`Res#nodesBySource`・`Talk.nodesBySource`）、別のノードの行か、同じノードで前に通った行より上の行（自分への jump）に来た所でノードに入ったと見て、入る直前の舞台を `Read#entry`（`World.NodeEntry`）に残す（`WorldRead.trackEntry`。`absorbOne` の頭で毎回）。`restore` は `entry` から当て直すので、ロードした直後のバックログの前の台詞の戻れる所に、ノードの途中で替えた物（立ち絵・背景・型・小物・props）が早く入らない。`entry` の無い枠は今までどおり Mark の舞台から当て直す。
- **JSON は version 3**: 枠に `"stage": { "bg": {photo, grade} か null, "mode", "pages", "props", "cast" }`・`"page": { "lines", "current", "next" }`・`"entry"`（stage と同じ形か null）。version 2 か 3 かは根の `version` でなく、枠に `stage` の鍵があるかで見る（枠ごとに読み替える）。version 2 の欄（photo・grade・環境音・particles・mode・cast）は `Saves.stageOf` が `Stage.makeSnapshot` で組む。読めない欄はその欄の既定で続ける。
- **restore**: `entry`（無ければ Mark の舞台）から当て直してバックログと選択肢を作り、`settled` の後に舞台と頁を Mark の値で置き換える。
- **ずれ: セーブの道（`slotHere`）は、`<<wait>>` の間はバックログの頭の項目だけを見る**（`WorldRead.markHere`・`headMarkOf`）。頭が戻れる所つきの台詞ならそれを使い、選んだ選択肢か空（はじめから読んだ頭の待ち・選択肢を選んだ直後の待ち）なら None で、その間はセーブしない。今のブックマークで作ると、当て直しが待ちを飛ばして次の台詞まで進むのに、舞台と頁は待つ前の物で置き換えるので食い違う。選んだ選択肢より前の台詞へさかのぼると、選ぶ前に戻る。台詞と選択肢を出している間は計画どおり今のブックマーク・舞台・頁で作る。
- **ずれ: `window off`（`window.hidden`）は次の台詞・選択肢と `window nvl|bottom` で戻る**（`Stage.withWindowShown`。Ren'Py の window hide と同じ）。消したまま台詞を出すと、押せば進むのに何も読めない画面になるため。値は `props` の数の鍵 `window.hidden`（1 = 消す）で、名前の鍵にしなかったのは、後で `window off time=` で薄くする時に tween で書けるから。View は `Stage.isWindowHidden` が真の間、読む画面の層（文字の枠・字・クイックメニュー）を描かない（画面の Hidden と同じ層）。このため「前のノードで消したまま jump した後の台詞から戻す」写しのテストは意味を失い、代わりに「消して待つ間にセーブして戻すと、待つ前の台詞を枠のある形で出す」を見る。
- **`Stage.pages`**: 足すのは `Out.ClearPage`（`window clear` と型の切り替え）と NVL で入り切らずにめくった時（`Page.isFullFor`）の 2 か所で、どちらも `WorldRead` の中（`takeOut` と `showLine`）。ADV の頁送り（`TurnPage`）は数えない（血鱗の「頁で沈む」は NVL の頁）。
- **O2（台本を読んだ時に 1 回だけ引数を読む表）**: `Commands.ArgsTable`（鍵は「ファイル:行」。中は外から作れない）を `Res#commandArgs` に置き、`Res.withDialogue` と `Controls.loadRes` が作る（`Res#nodesBySource` も同じ所で作る）。引く時は行の鍵に加えて名前と引数の字が同じかを見て、違えば読み直す（差し替え前の表・テストが組んだコマンド）。`ScriptEdits` は台詞だけを直すので作り直さない。`Commands.timingOf` は `res` を取るようになった。
- **ノードに着いた時の舞台（4.2）**: `WorldRead.buildEntryStage(res, node)` と `buildEntriesWithin(fuel, res)`（重い計算なので `build*`）。opening から全部の選択肢をたどり、読み進める時と同じ `absorbOne`（`trackEntry`）が残す `Read#entry` を、入った回数（`visits`）が増えるたびに見て、初めてのノードならその舞台を残す。もう着いたノードへ入った道（自分への jump も）はそこで止め、全体の歩数の上限は `entryFuel()` = 4000。着かないノードは空の舞台で 1 行言う。血鱗の `StageAudit.headEventCount`（頭の出来事の数で後ろから外す）は `<<if>>` で数え違い、コマンドだけで通り過ぎるノードを拾えないので取らなかった。
- **`<<set>>` と `<<jump>>` だけのノードは出来事を出さないので、`buildEntriesWithin` では着かない**（そのノードを頭から開くと空の舞台から始める）。
- **ずれ: ノードに着いた時の舞台を Res に置いていない**。作る代金はテスト 1 本（流す・比べるを含めて）で 7〜20 ms で、`openAt` ごとに作っている。Res に置くと Res が WorldRead（World）を使う向きになり、「Res は World を使わない」が崩れるため。
- **ずれ（退行の門）: 描き出しの 8 枚が変わった**（ask・engawa・lane・load・night・save・small-ask・small-save）。実機では Lane・Engawa・River は Paddy の ADV のまま読まれる（`TestRules.testAdvBackdropCueStartsANewPage` がそれを確かめている）のに、今までの `openAt` は空の舞台（NVL）から始めていたので、描き出しだけ NVL だった。ノードに着いた時の舞台から開くので、描き出しが実機と同じ ADV になった（4.2 のねらいどおり。レビューで受け入れた）。別案として Lane の頭に `<<window nvl>>` を足すと 43 枚とも SHA が一致したが、実機の遊びを変えて上のテストが落ちるので取らず、リファレンスを別のコミットで更新した。
- **テスト**: `TestCast` に、見本の台本 `test/fixtures/talk/stage.yarn`（前のノードの型のまま始まるノード・NVL で入り切らない頁・clear・型の切り替え・ノードをまたぐ NVL の頁・window off と wait・選択肢の 2 つの道・選択肢の直後の wait・自分へ戻るメニューと出口・`<<if>>` の中のコマンドとコマンドだけで通り過ぎるノード・どこからも来ないノード）を cast.yarn の Next の終わりから繋ぎ、全部の台詞（選択肢はどの道も・メニューの入り直しも）で舞台の全部と頁が戻ること・v3 の JSON の往復（`slotHere` から）・ロード直後のバックログで前の台詞へ戻ること・頁の数（型の切り替え・溢れ・clear を 1 本ずつ）・待つ間のセーブ（台詞の後・頭・選択肢の直後）・v2 の枠の読み替え・着いた時の舞台（上限・自分へ戻るメニュー・`<<if>>` と通り過ぎ・着かないノード・openAt）を見る。`TestCommands` に window off と引数の表。

## 5. 置き場と増える pub

| パッケージ | 足す・変える物 |
|---|---|
| engine_world | `YarnCommands`（Spec・Param・Args・parse・toJson）、`Curve.Ease`。2 つ目の使い手: rpg-starter の `assets/talk/vocab.json` にゲームのコマンドが 13 個ある（ending・fight・give・gold・heal・inn・join・open・quest・ride・shop・take・warp） |
| テンプレート | `Commands.flix`（表・Ctx・Out・`run`）、`PropertyTween.flix`、`GameCommands.flix`・`GameView.flix`（空）、`Stage`（PropertyTween を持つ・Snapshot）、`Saves`（Mark v3）、`WorldRead`（`cue` を `Commands.run` に・restore・entryOf）、`Shots`（Doc を読む）、`StoryDoc`（opening・vars）、`Talk`（enum を消す）、`assets/novel.shots.json` と schema・`editor.resources` |
| go | `parse.go`（`"…"`）、`check.go`（vocab v2・引数・ref・from・nodeRefs・名前の無い変数）、`run.go`（yarn check に Doc のパス）、`graph.go`（コマンドの分類と変数の表示名） |
| bin/lint-rules | `precommit.json` の yarn の門の when に Doc |
| engine（core） | なし |

増える pub（engine_world・見込み 25 前後）:

- `YarnCommands`: `Spec`・`spec`・`Args`（外から作れない）・`parse`・`toJson`・`fromJson`（テスト用）
- `YarnCommands.Param`（mod）: `Req[t]`・`Opt[t]`・`num`・`time`・`ease`・`choice`・`name`・`flag`・`at`・`required`・`default`・`orWords`・`orNames`・`list`・`oneOf`・`erase`・`get`・`getOpt`
- `Curve.Ease`（enum: Linear・SmoothStep・Penner の In/Out/InOut × Sine・Quad・Cubic・Quart・Expo・Back・Elastic・Bounce）・`Curve.ease`

`PropertyTween` は N4 まではテンプレートに置く（使い手がノベルのテンプレート 1 つだけなので、「層は実装が 2 つある所にだけ」に合わせる）。ゲームは src を持つ間テンプレートの写しを当て直す形になるが、N2・N3 ではゲームを移さない（6 章）ので、写しが増えるのは N4 で一度だけ。N4 でコマンドの中身と一緒にエンジンへ上げる。

## 6. 移り方

| 対象 | いつ | 中身 | 機械でできるか |
|---|---|---|---|
| テンプレート | N1〜N3 の中で | 10 個のコマンドを語彙 19 の名前に（nvl・adv・clear → window、ambience・se → audio、char・item → show・hide）。同じ段で `agents-pack/AGENTS.core.md` の早見表・`docs/modules`・スキルの `<<char>>` などの書き方も直す | 台本 51 行は convert.py（4 本 924 行で書けなかった行 0） |
| izakaya | N2 の後に試しに 1 本目【推】 | `<<hop>>` は preset が N5 まで無いので GameCommands に 1 行（`delay` で 4 つ並べる）。湯気と煙は fx | 台本は convert.py。src はテンプレートを当て直し、足した 105 行のうち 66 行が消える【推】 |
| kankan・haioku・血鱗 | N4 の後に 1 回で | 追加のコマンドは標準の語彙に移り、残りは GameCommands と GameView へ（3.7） | 台本は convert.py（引数を足せば 95.1% が同じ意味）。src はテンプレートを当て直してから、ゲームだけの演出を手で写す |

- N2・N3 だけでゲームを移すと、kankan の追加コマンド（dim・flash・zoom・text・speed・hold）を GameCommands に書き直した後、N4 で標準に移ってもう一度消すことになる。当て直しは kankan で 2 回・血鱗で約 5 時間かかった（下書き 1 章）ので、ゲームは N4 の後の 1 回にする。
- 古いセーブ（v2）は読める（4.1）。古い vocab.json（v1）も go が読める（2.2）。

## 7. テストと門

- engine_world: `YarnCommands` は引数の型ごとに受ける・断るを 1 本ずつ、`command-args.json` の見本を全部。`Curve.Ease` は 0 と 1 の端と真ん中。`make sync-layers` の後に `.layers/engine_world` で流す（`make test-engine_world` は偽の解決エラーになる）。
- go: `go test ./internal/yarn`。同じ `command-args.json`。v1 と v2 の両方の vocab で build が通る事。`nodeRefs` が `Unreached` の起点に入らない事。名前の無い変数を知らせて止めない事。
- テンプレート:
  - 舞台の全部と頁を、全部の台詞で「生きて読んだ物 = その台詞の Mark から戻した物」と比べる（`TestCast` の既存のテストを広げる。4.3）。見本の台本を test/fixtures に置く: 相対の値（スパイクの `nudge` の形）・型が替わる台本（頭に型を書かない NVL → ADV → NVL）・ノードをまたいで続く NVL の頁・前のノードで文字の枠を消したまま jump（スパイクの `TestPage` の形）。
  - セーブの JSON の往復（v3）で、舞台の全部と頁が戻る。
  - 表の全部のコマンドを、必須の引数だけで 1 回ずつ `run` して落ちない（handle の書き忘れの `bug!` を拾う）。
  - `PropertyTween`: tween の途中・遅れて始まる物・settle・JSON の往復。
  - `Out`: clear・window の型替え・ADV の bg で頁の出来事が出る。Silent で `Sound` が落ちる。
  - vocab.json がコードと一致（今の `TestDocs` のまま）。Saves v2 の JSON を v3 で読んで同じ舞台。
  - `buildEntryStage` が上限で止まる（選択肢の多い見本の台本）・台詞の直しで作り直す。
  - 名指しの SHOT が Doc に無い時は `Err`。
- go（足す分）: `"…"` のまとめが `<<set $x = "a b">>` と `<<declare>>` の文字列に触れない。v1 のゲームで `yarn check <Doc>` が何もせずに通る。
- **退行の門: N1 から N3 の終わりまで、描き出しの絵が変わらない**（`templates/sound-novel-starter/reference/SHA256SUMS.txt` が同じ）。場面表を Doc に移しても、コマンドを表に移しても、セーブの形を替えても、同じ絵が出るはず。変わったら読み違い（ease の既定を今の動きに合わせるのもこのため）。
- 新しい仕組みの決まり（AGENTS.md）: `agents-pack/AGENTS.core.md` の早見表に「演出コマンドを足す → Commands の表に 1 行」を足し、`agent-eval/engine.json` に「引数の誤りを build で見つけて直す」お題を 1 本。確かめはテンプレートから `make new-game` で作った新しいゲームの足元で `make agent-eval ONLY=<お題>`（今のゲームは N4 まで古い形なので使わない）。
- 古い書き方（`Stage.commandNames`・`Talk.Speaker`）を `bin/lint-rules/forbid.json` で止めるのは、範囲をテンプレートに絞れるならその形で、絞れなければゲームが移った後（N4 の後）に入れる（今入れると移っていないゲームのコミットが止まる）。

## 8. 小分けの順と見積もり（実時間・【推】）

各段の後に `flix check` と波及したパッケージのテストだけ回す。レビューは N1 の後・N2 の後・N3 の後の 3 回にまとめる。今回のスパイク（写し 4 つ・テスト 7 回）は書き換えから結果まで合わせて 2 時間ほどで、テンプレートのテスト 1 回は約 23 秒だった。これを物差しにした。

| # | 段 | 中身 | 見積もり |
|---|---|---|---|
| 1 | N1 | go の vocab v2 の `from`・`nodeRefs`・`vars`・story.json の opening と vars・Talk の enum を消す・precommit の when と yarn check の Doc のパス（済。`ref` の逆引きと変数の表示名を出す所は N1 では未着手・段 4 でやる） | 3〜4 時間 |
| 2 | N1 | novel.shots.json と schema・Shots を Doc で組む・SceneRender が Doc の名前を引く。絵が同じ事を SHA で確かめる | 3〜4 時間 |
| 3 | N2 | engine_world の `YarnCommands` と `Curve.Ease`（EcsTween への写しの関数まで）（済。EcsTween の曲線の式は Curve.ease の 1 か所） | 3〜4 時間 |
| 4 | N2 | go の引数の検査・`"…"`・ref・共通の見本。N1 から持ち越し: `DocsOf` が `ref` の Doc も読む・変数の表示名を yarn graph とテープのグラフと読み台本に出す（済。テープの状態の表は novel-data-only.md 3.19 の「後で」へ） | 3〜4 時間 |
| 5 | N2 | テンプレートの `PropertyTween`（delay・settle・JSON）（済。3.6 の「段 5・6 で入れた形」） | 2 時間 |
| 6 | N2 | テンプレートの `Commands` 表・Ctx・Out・10 個を語彙 19 の名前で・台本の書き直し・GameCommands/GameView の口・早見表と docs とスキルの書き方。絵が同じ事を確かめる（済。描き出しの 43 枚は SHA が同じ。ずれは 3.2 の「段 6 で入れた形」） | 6〜7 時間 |
| 7 | N3 | Snapshot と頁を持つ Mark v3・v2 の読み替え（環境音の短い名前の読み替えは段 6 で済）・restore の置き換え・頁と舞台の JSON・entryOf（上限・作り直し）・TestCast を広げる。段 6 から: `window off`（`window.hidden`）・`Stage.pages`・O2 の引数の表（済。ずれは 4.4。Mark にノードに入った時の舞台も持ち、restore はそこから当て直す・ノードに着いた時の舞台は Res に置かず毎回作る（`buildEntryStage`）・待つ間のセーブはバックログの頭の台詞だけ・描き出しの 8 枚が実機と同じ ADV に変わった） | 4〜5 時間（restore と頁はスパイクで形が決まった） |
| 8 | — | agent-eval（新しいゲームで）・docs/modules の 1 行 | 1〜2 時間 |

合計 25〜32 時間。

**段 7 からの持ち越し**:
- ロード直後のバックログの穴は、Mark にノードに入った時の舞台を持たせて直した（4.4）。`entry` の無い古い枠だけ前の形で戻る。
- 血鱗の `StageAudit` の 2 つの検査を消すのと、台本の頭の言い直しを機械で消すのは、ゲームが移る N4 の後（4.3・6 章）。
- `window off time=`（薄くして消す）は入れていない（`window.hidden` は数の値なので tween で書ける）。

**段 5・6 からの持ち越し**:
- `window off`・`Stage.pages`・O2（台本を読んだ時に 1 回だけ引数を読む表）は段 7（N3）で入れる（済）。
- 古い書き方（`<<char>>`・`Stage.commandNames`）を `bin/lint-rules/forbid.json` で止める件は入れていない（範囲をテンプレートに絞れるかは未確認）。
- go の `script_test.go` と `check_args_test` の見本には古いコマンド名が残っている（go の検査の見本なので残す）。
- agent-eval のお題 `novel-game-command` は足したが、新しいゲームの足元で流すのは段 8。

**段 3・4 からの持ち越し**:
- 整数の型が無い（個数に `3.5` を書いても断れない。今は `num` で受ける）。要る作品が出たら `Param.int` を足す。
- ノード名を `ref` で引けない（`<<fight 敵 勝った後のノード>>` など）。マップごとの Doc（open・warp の物と出口）も `ref` の from で書けない。
- テンプレートの `vocab.json` の `commands` は `{}` のまま。中に表を書くのは段 6（コマンドの名前を語彙 19 に替えるのと同じ時）。go は `params` の無いコマンドの引数を見ない。
- 段 6 への申し送り: `needs` の既定（「`Param.name` の引数で `ref` が素材の表を指す物」から作る。3.2）には、Spec から引数ごとの `ref` を読む pub（`YarnCommands.refsOf` など）が要る。今の Spec は外から中を読めない。3 は engine_world なので 1・2 と並べて進められる（同じパッケージを 2 人に触らせない）。

## 9. 決めた事（相談事への答え・人は「おまかせ」、親が決めた）

1. engine_world に `YarnCommands` と `Curve.Ease` を足す。`PropertyTween` は N4 までテンプレート。YarnRunner には出来事を足さない（4.1 のスパイクで (b) に決めたため）。
2. コマンドの中身（bg・show など）は N2 ではテンプレートに置き、N4 でエンジンへ上げる。
3. テンプレートのコマンド名を N2 で語彙 19 の名前に替える（`<<char>>` → `<<show>>` など）。`agents-pack/AGENTS.core.md` の早見表・`docs/modules`・スキルの書き方も同じ段で直す。
4. `se` は 3.2 の `Out.Sound`。GameView の z は `docs/z-bands.md` の world の中で、立ち絵より上・文字の枠より下に小さな範囲を切る（3.6）。
