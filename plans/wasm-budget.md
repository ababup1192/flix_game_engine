# ブラウザ版の wasm の内訳と、勝手に太らせない予算の門（相談用の案）

2026-11-21。engine を触る所（2 節の削る候補・3 節の門）は**まだ実装していない**。人と決めてから進める。
入れた物（未コミット）: 測る道具 `bin/fge wasm-size`（試し）・lint の `java-regex`（人の指示）・正規表現を使わない `TextSplit.split` と `TextSplit.lines`（人の了承・2 節の 1）。

## 0. 先に結論

- **TeaVM は関数の単位で、入口から届かない物をもう落としている。** 「全部の Doc の読み手」「全部のノードの型の match」「登録簿」は、
  どのテンプレートでも合わせて 25〜35 KB（brotli）で、ほとんどはゲームが本当に読む物だった。心配していたほどの塊ではない。
- 残っているのは **「実行時の旗や分岐の先にある物」**: 開発用の道具（一時停止・注釈・名前の候補）・診断の時だけ使う物・
  JSON から実行時に組み立てるシェーダー・正規表現。どれも「起動の時は通らないが、通るかもしれない道がある」ので入る。
- 2D のテンプレート 1 本で削れる見込みは、手の軽い物だけで **約 45〜50 KB（4G で約 0.23 秒）**、シェーダーを書き出しの時に生成しておく所まで行って **約 80 KB（約 0.4 秒）**。
  wasm の brotli 1,035〜1,159 KB の 4〜8%。engine の中心（App のループ・塗り・WebGPU の描き手・頁との橋渡しで約 300 KB）は削れない。
- だから「ダイエット」の本命は、機能を入れても**使わないゲームが払わない形を決まりにして、門で見張る**こと（3 節）。今ある物を削るのは効きが小さい。

## 1. 測る道具と表

### 道具: `bin/fge wasm-size`（`go/cmd_wasmsize.go`・`go/wasmsize_names.go`）

書き出しのフォルダ（`classes.wasm` と `classes.names`）か、作業フォルダの名前入りの `classes.wasm` を渡す。

```bash
bin/fge wasm-size templates/rpg-starter/build/web
```

```bash
bin/fge wasm-size <書き出し> --by module --top 60
```

```bash
bin/fge wasm-size <書き出し> --without '  (ShaderGen|ShaderEval|ShaderJson)(\.|$)'
```

```bash
bin/fge wasm-size <今の書き出し> --diff <前の書き出し> --by module
```

- 名前の区画（`classes.names`）で関数の番号を名前へ引き、code 区画の本文の大きさを集める。
- 名前の読み分け: engine の束から入った物は TeaVM が `$pkg$github$ababup1192$flix_game_engine.` を頭に付ける。その後ろのモジュールの道を、
  engine・render_gl・engine_world・engine_web の `src/` の `mod` 宣言（長い道を先に）でパッケージへ。頭の無い物は、ゲームの `src/`・`web/` の
  `mod` に当たればゲーム、`java.`・`org.teavm` は Java/TeaVM、`dev.flix.runtime` は Flix の実行環境、残りは Flix の標準。`fge.web.*` は engine_web の Java。
- `--by package | module | def | name`。`def` は単相化の複製（`Def$名前$番号`）を元の関数にまとめる（関数の列が複製の数）。
- brotli の列は、区分の本文だけを並べて q11 で詰めた大きさ。区分ごとに詰めた和は全体より大きい（区分をまたぐ繰り返しが効かない）ので、
  全体に合わせて割り戻した列も出す。**削れる量は `--without` を使う**（当たる関数を抜いた残りを詰め直して差を取る。これが外した時に一番近い）。
- 速さ: パッケージ・モジュール別は 8 秒（書き出しの `classes.wasm.br` を使い回す）。`--without` は 20 秒〜1 分。

### 表: パッケージ別（brotli・割り戻し・KB）

main（5cd70ceb）の engine で書き出した。全体は名前の区画を除いた wasm を q11 で詰めた大きさ（`classes.wasm.br` と同じ作り方）。

| | rpg-starter | sound-novel-starter | hd2d-starter | internet_dungeon |
|---|---:|---:|---:|---:|
| **wasm 全体（brotli）** | **1,035** | **1,159** | **1,114** | **1,972** |
| ゲーム | 326 | 414 | 111 | 1,078 |
| engine_world | 211 | 241 | 213 | 299 |
| render_gl | 121 | 122 | 326 | 121 |
| engine | 87 | 88 | 173 | 101 |
| engine_web | 55 | 57 | 57 | 55 |
| **engine の計** | **475** | **508** | **769** | **577** |
| Java/TeaVM（`teavm@initializer` 56 KB を含む） | 138 | 145 | 138 | 186 |
| Flix の標準＋実行環境 | 96 | 91 | 96 | 131 |
| 書き出しの 4G の遊べるまで | 9.8 秒 | 12.5 秒 | — | — |

- hd2d-starter は main のままでは書き出せない（`web/WebMain.flix` が非 pub の `Res.loadDocs` を呼ぶ。写しで pub にして測った）。別の直しが要る。
- ダンジョンの 3598ec98 の前の書き出し（11-20）と比べると 2,193 → 1,972 KB（−221 KB）。render_gl −131・engine −66・Flix 標準 −20・Java −12。
- **本文（brotli 前）と brotli 後で順位が大きく違う。** RedBlackTree（Flix の Map・Set の単相化の複製）はダンジョンで本文 1,452 KB・brotli 44 KB、
  Timeline は本文 918 KB・brotli 24 KB。回線に乗る量では効かないが、スマホで wasm をコンパイルする時間には効く（本文 15 MB）。こちらは別の軸として 4 節に残す。

### 表: engine 側の上位モジュール（rpg-starter・brotli KB）

| モジュール | KB | 何か |
|---|---:|---|
| Java/TeaVM `teavm@initializer` | 55 | 全部のクラスの初期化をまとめた 1 本。中身は未調査 |
| App.Internal.Runner | 36 | App のループ |
| RenderPaint.Internal.WebGpuPaint | 30 | WebGPU の塗り |
| RedBlackTree（Flix 標準） | 28 | Map・Set の複製 |
| App.Internal.Paint | 24 | |
| RenderPaint | 22 | |
| WebLayer.Internal.WebGpuLayer・WebLayer | 19・18 | 頁との橋渡し |
| ShaderGen・ShaderEval・ShaderDoc・ShaderJson・SpecKey | 14・10・6・4・6 | 実行時のシェーダーの組み立て |
| App.Internal.Halt | 12 | 開発用の一時停止・巻き戻し・注釈の画面 |
| Annotate | 8 | 開発用の注釈 |

全部の表は scratchpad の `*_mod.tsv`（`--by module --tsv`）。人に見せる時は道具で出し直せる。

## 2. 「使っていないのに入口から届くので入っている」物と、削る候補

`--without` の実測（code 区画の brotli の差・KB）。4G は 1 KB ≈ 5 ms（3598ec98 の 277 KB で −1.4 秒から）。

| # | 候補 | 何で届くか（refactor の呼び手で確かめた） | rpg | novel | hd2d | dungeon | 4G | 手間 |
|---|---|---|---:|---:|---:|---:|---|---|
| 1 | Java の正規表現 | `String.split(regex = …)` が 3 か所（`WebLayer.policyOfText`・`linesOf` は改行、`App.Internal.Hitch.perfNameOf` は `/`）。Flix の `String.lines` も中で `split("\\R")` | −18.4 | −17.9 | −17.0 | −18.7 | −0.09 秒 | 小 |
| 2 | 開発用の道具（Halt・Annotate・Suggest・DevTools・Hitch） | `App.Internal.Runner.localStep` → `Halt.pausedStep`（止めた時だけ）。`Annotate.named3d` → `Scene3d.instancesOf` → `Ray3d` などで **2D にも 3D の当たり判定が入る**（3D の残り −7 KB の出どころ） | −20.4 | −21.9 | −21.4 | −23.2 | −0.1 秒 | 中 |
| 3 | 実行時のシェーダーの組み立て（ShaderGen・ShaderEval・ShaderJson） | `RenderPaint.buildProgram` → `ShaderGen.compile`。2D でも組み込みの絵の Spec を JSON から実行時に WGSL・GLSL へ組む | −35.9 | −36.3 | −45.0 | −45.9 | −0.18〜0.23 秒 | 大 |
| 3a | 3 のうちシェーダーを JSON へ書く側だけ | `RenderPaint.buildReason`（「作り直した理由」の診断）だけが `ShaderJson.toJson` を呼ぶ | −3.6 | −4.4 | −3.1 | −5.8 | −0.02 秒 | 小 |
| 4 | jzlib（Java の zlib の展開） | 埋め込み素材の復号 `fge.web.EmbeddedCodec` の `Inflater` | −6.0 | −7.8 | −5.0 | −6.8 | −0.03 秒 | 小 |
| 5 | Yarn | rpg-starter・sound-novel は会話に使っている（正当）。使わないゲームには入らない | −8.3 | −29.1 | 0（使わない） | 未測 | — | — |
| 6 | WebGL2 の道（WebGPU の無い頁） | 要る（WebGPU の無いブラウザで落ちる）。残す | −3.4 | −4.1 | −3.7 | 未測 | — | — |

hd2d-starter は PostStack が −28.8 KB（使っているので正当）・3D の描き手が −235 KB（同じく正当）。ダンジョンの Yarn・WebGL2 は結論に効かないので測るのを途中で止めた。

候補ごとのやり方（どれも 3598ec98・withPostStack と同じ「入口が選んで入れる」形）:

1. **正規表現**: 決まった字で区切る関数と、改行（`\n`・`\r\n`）で行に分ける関数を、正規表現を使わずに書く（1 字ずつ読むだけの 20 行ほど）。
   Java の `split` は末尾の空の要素を捨てる（`"a\n"` → `["a"]`）ので、同じ答えになるようにしてテストで突き合わせる。
   **済み（11-21・人の了承）**: `engine/src/core/TextSplit.flix` の `split(区切り, s)` と `lines(s)`。標準の `String.split`・`String.lines` と同じ答えを返すことを
   `engine/test/TestTextSplit.flix` で突き合わせた。engine・engine_tools・engine_web・bench の 24 ファイルを置き換え、lint の例外も消した。
   rpg-starter を書き出し直して測った: 正規表現の関数は 0 本・wasm 全体の brotli 1,034.6 → 1,001.8 KB（**−32.8 KB**・4G で約 −0.17 秒）。
   code 区画だけの見積もり（−18 KB）より大きいのは、クラスと型の情報の区画も一緒に減るため。TextSplit の分の増えは +0.6 KB。
2. **開発用の道具**: Runner が Halt・Annotate を直に呼ぶのをやめ、入口が渡す道具の束（無ければ止めない・注釈しない）にする。
   デスクトップの入口は今どおり渡し、ブラウザの WebMain は渡さない。止める鍵（F8 など）はブラウザでは効かなくなる。ブラウザで止めて調べたい時の道は要相談。
3. **シェーダー**: 書き出しの時にデスクトップの ShaderGen で、ゲームが使い得る Spec を全部 WGSL・GLSL へ生成しておき、ブラウザは生成済みの字を引くだけにする。
   Spec がゲームの値（Doc の数）で実行時に変わる物を、どこまで先に数え上げられるかの下調べが先。3a（診断の時だけの JSON 書き）は、診断を入口が渡す形にすれば単独で外せる。
4. **jzlib**: 埋め込みを無圧縮にして wasm 全体の brotli に任せる（wasm の本文は増えるが回線の量はほぼ同じ）か、頁の `DecompressionStream("deflate")` に任せる。

**合わせた見込み**（2D の rpg-starter）: 1＋2＋3a＋4 で約 −45 KB（−0.23 秒）、3 まで行って約 −80 KB（−0.4 秒）。
足すと少し重なる（2 と 3D の残りは同じ物を含む）ので、入れる時に `--without` を 1 本の式でまとめて測り直す。

### lint `java-regex`（入れ済み・人の指示）

- `bin/lint-rules/forbid.json` の `java-regex`。`.flix` と `.java` で、`String.split`・`String.lines`・`isMatch`・`isSubmatch`・`replaceMatches`・
  `replaceFirstMatch`・`toRegex`・`Regex.*`・正規表現リテラル・`java.util.regex`・`Pattern.compile` など・Java の `.split(` `.matches(` `.replaceAll(` `.replaceFirst(` を止める。
- テスト（`test/`）は見ない（wasm に入らない）。`src/`・`engine_full/src/` の symlink の写しは本体と二重になるので見ない。
- 今ある所は `TextSplit` へ置き換え済み。exempt は書き出しの道具 `fge/teavmfix/Rewrite.java`（コメントで名を出すだけ・wasm に入らない）の 1 本だけ。
- テスト: `go/internal/forbid/forbid_test.go` に 2 本（止まる行・止まらない行・Java の split）。
- **ゲームへの波及**: forbid.json はゲームへ配る。ダンジョンは 10 か所使っていて、engine を上げた後にそのファイルを直すとコミットで止まる。
  置き換え先の `TextSplit` は入れたので、ゲームの追随（`engine-upgrade`）の注意書きに「`String.split`・`lines` は `TextSplit` へ」の 1 行を足す。

## 3. 門の設計案

### 3.1 テンプレートごとの wasm の予算（`wasm-budget`）

起動の予算 `web.startupBudget`（秒・why 付き）と同じ形を、wasm の brotli の KB で持つ。

- 予算の置き場: `templates/<名前>/project.json` の `web.wasmBudget = { "kb": 1060, "engineKb": 490, "why": "" }`。
  `kb` は wasm 全体、`engineKb` は engine の 4 パッケージの計（ゲームのコードを直しただけで engine の門が赤くならないよう分ける）。
  ゲームも同じ鍵を書ける（書けば export-web と web-check が止める・書かなければ表を出して知らせるだけ。startupBudget と同じ移行）。
- 決め方: 今の値＋余裕 2%（最小 8 KB）。小さくなったら門が「予算を下げられる」と知らせ、下げるのは手で（`reference-update` と同じく、同じコミットに入れる）。
  上げる時は `why` に理由 1 行を書く（レビューで見える）。
- 門の中身: 3 本のテンプレートを `export-web --reuse --no-browser-check` で書き出し（変わっていなければ組まない）、
  `bin/fge wasm-size --budget` で比べる。赤の時は前の書き出し（`build/wasm-budget/<名前>/last`）との `--diff --by module` の上位 10 行を出す
  （どのモジュールが太ったかがその場で分かる）。
- gates.json の行（案）:

```json
{
  "id": "wasm-budget",
  "about": "テンプレートのブラウザ版の wasm（brotli）が project.json の web.wasmBudget の内か（engine の 4 パッケージの計も）",
  "make": "wasm-budget",
  "select": "package",
  "runs": ["pre-release"],
  "time": "11m（組み直さない時 30s）"
}
```

  パッケージの表では engine・engine_world・render_gl・engine_web・3 本のテンプレートが `feeds` に `wasm-budget` を持つ。
  画面を開かないので `gui` は付けない。作業中の `make verify SUITE=affected` でも当たる。

### 3.2 決まり「新しい機能は使うゲームだけが払う」

docs/performance.md の「3 つの門」の隣に 1 節足す案。

1. 新しい機能の入口は、ゲームが書く呼び出し（`withXxx`・登録・Doc を読む関数を呼ぶ）からだけ届く。App のループ・既定の handler・
   「全部の種類」を並べた match から直に呼ばない（3598ec98 と withPostStack が見本）。
2. 開発用・診断用の道は、入口が渡す束の中に置く。ブラウザの入口は渡さない。
3. 重い依存（正規表現・`java.util.zip` など、1 回呼ぶと一式が入る物）は lint で止める（`java-regex` が 1 本目）。
4. 守れているかは 3.1 の門が見る: その機能を使わないテンプレートの wasm が増えたら赤。

### 3.3 早見表・お題（入れる時）

AGENTS の決まりに従い、門を入れる時に `agents-pack/AGENTS.core.md` の早見表に `wasm-size` の 1 行、
`agents-pack/agent-eval/engine.json` にお題 1 本（「wasm がどこで太ったか調べたい」→ `bin/fge wasm-size --diff`）を足す。
`wasm-budget` の門は engine のリポでだけ打つ口なので、AGENTS.md の検証の節と `testdata/agent-eval/engine-repo.json` へ。

## 4. 別の軸・残り

- **wasm の本文の大きさ（コンパイルの時間）**: 回線ではなくスマホが wasm を組む時間に効く。ダンジョンは本文 15 MB で、
  RedBlackTree（1.45 MB）・Timeline（0.92 MB）・ゲームのビュー（単相化の複製）が大きい。測るなら web-bench の「押した後」の時間と並べる。
- `teavm@initializer`（brotli 56 KB・どのテンプレートでも同じくらい）の中身は未調査。クラスの初期化の定数の表なら、Flix の enum の名前の字かもしれない。
- hd2d-starter の書き出しの不具合（`Res.loadDocs` が非 pub）。別の仕事。
- 書き出しの外で（scratchpad の写しで）組んだ時、フォントの焼き込みが Java を見つけられずに止まった（wasm はできている）。道具の側の別の不具合の候補。

## 5. 決めてほしいこと

1. 2 節の残りの候補のうち、どれから入れるか（案: 2 開発用の道具 → 4 jzlib → 3a。3 の事前生成は下調べを先に。1 正規表現は済み）。
2. 3.1 の門を入れるか。予算の置き場（project.json の `web.wasmBudget`）と、余裕 2%（最小 8 KB）でよいか。
3. 3.2 の決まりを docs/performance.md に足すか。
