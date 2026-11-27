## 会話ポリシー

日本語で会話してください。途中報告なども含めて、日本語で回答してください。

言葉づかいには 2 つの層があります。混ぜないでください。

**単語は業界の言葉をそのまま使う。** ゲーム業界・ソフトウェア業界で通じる語を優先し、
カタカナ（和製英語）か英語のまま書く（レイヤー・バージョン・ボタン・オーバーレイ・
スプライト・`Layer` `Version`）。**和語へ言い換えない。造語も作らない。**
読み手はエンジニアです。

**説明は平易に。** 難しい数学用語・専門用語に寄りかからず、何が起きるのかを普通の
言葉で書く（「線形補間する」ではなく「2 つの値の間をなめらかにつなぐ」）。

**独自の比喩で名付けない。** このリポジトリでしか通じない言い回しは、人が読めない
だけでなく grep で辿れなくなる（同じ物が別の字で書かれ、1 つの字が 4 つの意味を持つ）。
コミット時に `bin/fge jargon` が**新しく書いた行だけ**を検査して止める。
言い換え先（と英語）はその WORDS を見る。手動で全量なら `make lint ONLY=jargon`。

## .flix の名前を探す（grep の前に・最初の 1 手から）

`.flix` に grep / rg / `sed -n` を打ちそうになったら、打つ前にこの表の行に置き換える。

| したいこと | 打ちそうになる形 | 代わりに打つ |
|---|---|---|
| 名前の一部から宣言を探す | `grep -rn "def foo"` / `"enum Foo"` | `bin/fge refactor search <語>` |
| 関数・型の本文だけを読む | `grep -n -A30 "def foo"`・`sed -n 120,180p X.flix` | `bin/fge refactor show <Mod.名前>` |
| 使う所・呼び手を全部（直す所の洗い出し） | `grep -rn "foo("`・`grep -rn "Mod.foo"` | `bin/fge refactor usages <Mod.名前> [--callers]` |
| 使われていない pub | （grep では探せない） | `bin/fge refactor usages --unused` |

grep は別の mod の同じ名前を拾い、`use` で入れた素の名前を落とす。grep のままで良いのは文字列・文書（.md）・JSON の値・Makefile と設定だけ。

- **どこで流すか**: engine の .flix は engine 直下で `bin/fge refactor …`。ゲーム・テンプレートの .flix はそのフォルダで流す（`cd <ゲーム> && bin/fge refactor …`。`bin/fge` の無い `templates/*` は `../../bin/fge refactor …`）。
- **refactor が落ちたら grep へ戻らない**: 出たログ（`build/refactor/*.log`）を読んで直す。java は PATH の物が動かなければ engine の devbox の jdk を自分で使う。
- **サブエージェントに .flix を読ませる・書かせる時**は、依頼文にこの表を貼り、報告に「refactor で引いた回数と、.flix に grep を使った所とその理由」を書かせる（AGENTS.md を読めと書くだけでは守られなかった）。

詳しい表は `/flix-docs`。

## 名前の付け方（モジュール・関数・変数）

**英語にすれば安全、ではない。** `bless` `carve` のように、英単語でも
このリポジトリだけの意味を持たせると、初めて読む人にも海外の人にも通じない。
上の言葉づかいの決まりは、そのまま識別子にも当てはまる。

### 1. 同じ物を指す言葉が業界にあるなら、それを使う

探す順番:

1. **ゲーム業界の語** — `sprite` `tilemap` `viewport` `hitbox` `atlas` `tween`
2. **ソフトウェア一般の語** — `cache` `buffer` `snapshot` `pipeline` `handler` `registry`
3. **他のゲームエンジンが同じ物をどう呼んでいるか** — Unity / Unreal / Godot / Bevy。
   同じ物に別の名前を付けない（このエンジンは Bevy の render-from-World の考え方に
   そろえているので、迷ったら Bevy の語を見る）

3 つとも当てはまらない物にだけ、説明的な名前を組み立てる（`silhouettePng` のように、
読んで何をする物か分かる形）。**比喩で名付けない。**

### 2. 動詞は大手の命名規則に合わせる

| 動詞 | 意味 |
|---|---|
| `get*` | 取り出すだけ（安い・失敗しない） |
| `load*` / `fetch*` | 外から取ってくる（遅い・失敗しうる） |
| `build*` / `make*` / `compute*` | 計算して作る |
| `is*` / `has*` / `can*` | Bool を返す |
| `set*` / `with*` | 値を差し替える（`with*` は元を変えず新しい値を返す） |
| `to*` / `as*` | 型を変える（`to*` は作り直す・`as*` は見方を変えるだけ） |

**1 つの動詞に 2 つの意味を持たせない。** `get` が実は読み込みに行く、のような名前は
呼ぶ側が値段を読み違える。

### 3. 迷ったときの決め方

その名前を英語で読んだ人に意味が通るか。通らないなら、業界の語をもう一度探す。

### 4. 取り違えは型で止める

外から作らせない値は pub mod の中の非 pub の enum + `pub type alias`（Flix 0.78。書き方は `/flix-docs`）。
新しく作る型と、直すついでの所から使う。一度に全部は替えない。

## 設計・実装

- **絵の下限（矩形だけの画面から脱する 5 性質）**: [docs/drawing-floor.md](docs/drawing-floor.md)
- **Flix の決まり（予約語・コメントの流儀）**: [docs/flix-conventions.md](docs/flix-conventions.md)
- **層を置く物差し（抽象の境目は実装が 2 つある所にだけ・新しい機種の切れ目は、描画は `RenderList` の backend・入力と音とファイルは `Platform.Services` と Fs と LoadProgress の handler）**: [docs/flix-conventions.md](docs/flix-conventions.md) の「層を置く物差し」
- **エラー処理（既定値で続ける / `Err` を返す / `bug!` で止める の使い分け）**: [docs/error-handling.md](docs/error-handling.md)
- **z-index の範囲の地図（world / UI / Transition / HUD / デバッグの重なり順の仕切り）**: [docs/z-bands.md](docs/z-bands.md)
- **性能（3 つの門・どこまで直すか・残っている二乗の一覧）**: [docs/performance.md](docs/performance.md)
- engine_world の「やりたいこと → モジュール」逆引き: `make module Q=<語>` で 1 行ずつ引く（分野の目次は [docs/module-index.md](docs/module-index.md)・本文は `docs/modules/<分野>.md`）
- **API の型・引数はソースを grep する前に** [docs/api-digest.md](docs/api-digest.md)（全 pub 宣言の生成物）を引く
- headless の描き出しを新しい場所で組むときの写経元: [docs/headless-render-recipe.md](docs/headless-render-recipe.md)
- 音の付け方（効果音づくり・鳴らす配線・音の下限チェックリスト・外から持ってくる BGM と効果音のフリー素材の候補（ノベル・RPG・ファミコン風）と規約）: [docs/audio.md](docs/audio.md)
- 時計（遊び・物語・実時間を型で分ける・ポーズ・ヒットストップ・止まる誤りと止まらない誤り）: [docs/clock.md](docs/clock.md)
- セーブの後方互換（id で持つ・欄は既定値で読む・版と書き換え・見本のテスト・控え・未来の版・フラグ 1 つで潰さない）: [docs/save-compat.md](docs/save-compat.md)

複雑で大規模な変更の場合は、いきなり実装をせず、レビュー役を立てて、壁打ちして80~90点以上を目指してください。
実装はするだけで満足せず、レビュー役に仕様漏れ・リファクタリング余地が無いかを確認してもらいましょう。

エンジン（engine/ 配下）を拡張するときは、**実施前に必ず相談する**。判断軸は汎用性。

## 仕事の配り方（サブエージェント）

**調べ物・広い検索・独立して進む実装はサブエージェントへ渡す**（軽い物は安いモデルで
足りる）。自分は分解・検証・報告に専念する。試行錯誤の過程を自分の文脈へ流し込むと、
肝心の判断に使える余地が減る。**渡さない**のはエンジン拡張の相談・リリース・コミットと、
受け取った結果の検証（緑の主張は自分で 1 回確かめる）。

**worktree を立てたら最初に `make worktree-seed WT=<worktree>`**（worktree の中からなら WT は省ける）。
git の外の依存（各パッケージの lib・`bin/flix.jar`・`bin/fge-go`・`build/gl-jar`・fpkg）を main から張る。
張らずに flix を流すと依存を Maven Central へ取りに行き、HTTP 429 で止まる。Studio の worktree も同じ `make worktree-seed WT=<Studio の worktree>` で張れる（Studio の main から張る）。
Maven の取り物（各パッケージの `lib/cache`）は共有の置き場 1 か所（`make mvn-cache-share`・`MVN_CACHE` で差し替え）を使う
（複数のプロセスが同時に使っても壊れない根拠は `bin/mvn-cache-share.sh`）。`bin/flix`・`bin/fge`（checkd・refactor・export-web・font-bake）・
ゲームの make は、flix を起こす前に lib/cache をその置き場への symlink にする。**`java -jar bin/flix.jar` を直に叩くとこれを通らず、
Maven へ取りに行く**ので、flix は `bin/flix`・`bin/fge`・make から流す。向いていない lib/cache は `make status` が 1 行で知らせる。

並行で走らせるときは**同じパッケージを 2 人に触らせない**（型検査は Stop /
SubagentStop で走り、他人が編集中の赤で止まる。常駐 repl の数の上限は
[docs/checkd.md](docs/checkd.md)）。設定でサブエージェントが使えないときは、
黙って全部自分でやらず**止まっていることを人へ言う**。

絵に触る担当には**「画素の差が出たら入れる前に止めて報告」**を依頼文に書く。前のコミットの後に描き出した gallery が
リファレンスと違うままのコミットは pre-commit が止める（意図した差は `make reference-update` の SHA256SUMS.txt を同じコミットに入れて通す）。
片付け: 担当が終わったら `make strays`（取り残された Chrome・http.server・ウィンドウ・常駐）、worktree がたまったら `make worktree-gc`（どちらも一覧が先・止める / 消すのは `KILL=1` / `APPLY=1`）。

## コーディングポリシー

コードには **How** / テストコードには **What** / コミットログには **Why** / コードコメントには **WhyNot**

特にコードコメントは WhyNot を重視し、How・What を書かない。実装の由来や旧実装などの歴史背景も書かない。

## 絵と音

**`RawDraw.box` を並べただけの画面は未完成。** 求めるのは 5 性質（面に階調か質感 / 主役が背景から
分離 / 層が分かれている / 時間が流れている / 形が物として読める）で、**どの画風で満たすかは自由**。
画風はゲームごとに決め直す（既定は無い。テンプレどうしでもそろえない）。
図形プリミティブ（RawDraw）は材料。View は完成品の部品で組む。

新しい画面（View）を書く前に [docs/art-ref/visual-dict.md](docs/art-ref/visual-dict.md) の手順を読む（ドット絵の sprite.json は `/pixel-art`。
部品選びは `docs/art-ref/visual-dict/reference.md` と `unused-parts.md`）。
下限の全文は [docs/drawing-floor.md](docs/drawing-floor.md)。
音も絵と同じ強さで意識する（[docs/audio.md](docs/audio.md)）。

lint 群（矩形だけの View・色票・画像の量・画素の並び・コマ間）は保存時とコミット時の
フックが自動で走らせる。手動で回す口の一覧は `make help`。

### 生成した絵は git に入れない

生成した `gallery/` と `reference/*.png` は git 管理外。人に見せる絵は
[docs/gallery/](docs/gallery/README.md) へ選んでコピー、退行検知は
`templates/*/reference/SHA256SUMS.txt`（例外は Studio が読む `reference/title.png` のみ）。
違反はコミット時に pre-commit ゲートが止める（配線 `make hooks`、理屈ごと `bin/fge precommit`）。

## 検証

現状把握は、セッション開始時に自動で流れる `make status` の 1 画面から。
git log 掘りやテスト回し直しから始めない。

**新しい仕組み（API・make の口・lint）を入れたら**、`agents-pack/AGENTS.core.md` の早見表に 1 行と
`agents-pack/agent-eval/engine.json` にお題を 1 本足し、ゲームの足元で `make agent-eval ONLY=<お題>` が当たるのを確かめる。
ただし engine のリポでだけ打てる口（門をまとめて流す `make verify`・`bin/fge gates` のような）はゲームへ配る早見表とお題に入れず、
この節に 1 行と `testdata/agent-eval/engine-repo.json` にお題を 1 本足し、engine の根で
`bin/fge agent-eval --tasks testdata/agent-eval/engine-repo.json --only <お題>` が当たるのを確かめる。
古い書き方は `bin/lint-rules/forbid.json`（1 行の正規表現 + 代わりの物）で止める。
リリースの後は、ゲームを追随させてから `make agent-eval-release`（全部のお題を 3 回・約 20 分・`docs/agent-eval.md`）で前の版と比べる。ゲートではない（知らせるだけ）。

**テストは絞って速く回す。全量の検証はリリース直前の 1 回だけ。**
変更が波及したパッケージだけ `make test-<name>`、それ以外は `flix check` で足りる。
門（テスト・検査）の一覧は根の `gates.json`。差分から流す門を選ぶのは `bin/fge test-select`（流さない。`--explain` でファイル → パッケージ → 下流 → 門・
`--since <ref>` で枝の差・`--files <パス…>`）。パッケージの表と依存の向き（engine → 3 層 → engine_full → テンプレート・bench。層どうしは互いを見ない）も gates.json。
まとめて流すのは `make verify SUITE=<名前>`（`affected` = 差分から選んだ門（`SINCE=<ref>`・画面を開く門は `GUI=1`）／`quick` = 作業中の型検査・precommit の素振り・lint／
`test` = テンプレートを含む全部のテスト／`release` = リリースの門／`gui` = 画面を開く門（release の前に手元で）。`SUITE` 無しで一覧・`DRY=1` で何を流すかだけ）。
作業中の確かめは `make verify SUITE=affected` を既定にしてよい（絞るのはパッケージの単位だけ・release の全量の門は絞らない）。答え合わせは薄く済ませてあり、
外れ（選ばなかった門で赤）に気づいたら、そのコミットを `make test-select-replay COMMITS=<sha>` で流して台に足し、gates.json の表を直す（plans/test-selection.md の 12 節）。
テストの口は `make test`（`ALL=1` でテンプレートとテストを持つ bench（bench/hd2d_town）も・`JOBS=<数>` で並べて流す）。絞る旗は `make gl-capture-check SCENES=<テンプレートか場面>`・`make go-test PKG=<名前>`。go のテストの全部を cache なしで 1 回流すのは `make go-test-full`（リリースの門。作業中の go-test は tape を cache に任せる）。
ベンチのブラウザ版をスマホの代わりに CPU を絞って測るのは `make bench-web BENCH=<名前> ARGS='…' CPU=4`（`bin/fge web-bench --cpu <倍>`・出す JSON の `cpuThrottle` に倍率が入る）。
書き出したゲームの頁（ベンチでなくてよい）の毎コマの固定費は `bin/fge web-perf <書き出したフォルダ> [--query …] [--cpu 4] [--uncapped] --profile <file.cpuprofile>`（rAF の間隔と rAF の中の CPU・`classes.names` で wasm の関数名を引いた自分の時間の多い関数。engine のリポだけの口・知らせるだけで門ではない）。
2D の物理（PhysicsWorld2d）の指紋が PC とブラウザで同じかと 1 刻みの重さは `make physics2d-same CPU=4`（bench/physics2d の 4 場面・画面を開く門で release の前に手元で・予算は docs/physics.md の「重さの予算」）。
3D のブラウザ版が書き出せて（TeaVM に無いメソッドで落ちないか）ヘッドレスの Chrome の WebGPU と WebGL2 で数コマ描け、console の誤りが 0 件か、wasm（classes.wasm.br）が testdata/web-size.tsv の記録から 3% を超えて増えていないかは `make web-load-check`（retro3d-horror-starter・約 1 分 45 秒・release の門・`WEB_LOAD_GAMES=<ゲーム…>` で替える・2D の rpg-starter は `make web-load-check-2d` でリリースの門だけ・増えを受け入れるのは `make web-size-update`・docs/web-capture.md）。
3D の描き手のシェーダー（render_gl の Render3dGlsl・Render3dWgsl・Render3dShaders・Render3d/）は入口の字（`"#version 330"`・`"@fragment"`・`"@vertex"`）を手で書かず、本文を Render3dShaders に ShaderAst の木で書いて `FragmentEntry` / `VertexEntry` で GLSL と WGSL を出す（forbid の `render3d-shader-entry-by-hand` が止める・手書きで残すのは置いた物の頂点の `Render3dGlsl.MeshVertex` / `Render3dWgsl.MeshVertex` と、WebGPU の backend の道具の pass の `Render3d.WebGpuMipmaps`・`Render3d.WebGpuShadowCache` で、forbid の skip と同じ）。
テストの範囲・書き方は `/quality-assurance`、リリース手順は `/release`。

## Doc（`*.kind.json`）の流儀

ゲームの値は、なるべくコードに直書きせず **Doc へ外に出す**。外に出せばエディタ
（flix_ge_studio）でフォームやスライダーから触れて、**走らせながらその場で変えられる**。

- **外に出す物**: 繰り返し調整する数値（テンポ・閾値・収支・確率）、個数が増減するデータ
  （配置・敵・アイテム）、色テーマ、文言
- **外に出さない物**: 描画アルゴリズム・演出の形、導出できる値、一度決めたら触らない構造。
  **振る舞い（ルール・当たり判定・生成）はコードのまま**

判断軸は「保存即反映で調整できると嬉しいか」。ロジックを JSON に書き始めたら設計の匂い。
外形規約・分け方・スキーマ方言は `/doc-design` と [docs/doc-conventions.md](docs/doc-conventions.md)。

## スキル

| いつ | 必ず引く |
|---|---|
| 新しいゲームを作り始めるとき・画風がまだ決まっていないとき | `/style-interview` |
| View / 背景 / エフェクトの画面を書く**前**（ドット絵の sprite.json は下の `/pixel-art`） | `docs/art-ref/visual-dict.md` |
| ドット絵（sprite.json）のキャラ・歩き・背景・小物を描く・直す・自己批評するとき（表でお題の種類のファイルだけ読む） | `/pixel-art` |
| pixel-art で足りない時だけ（色の予算・タイル地形は `retro-pixel.md`・48px 以上の顔や四足は `px-character.md`。節だけ引く） | `docs/art-ref/` |
| Flix を書く前・テストを書く前 | `/flix-docs` |
| コンパイルエラーが出たら | `/compile-fix` |
| テストを設計するとき | `/quality-assurance` |
| Doc(JSON) を新設・拡張するとき | `/doc-design` |
| 絵・演出を直すとき | `/render-loop` |
| templates/ を足す・直すとき | `/add-template` |
| バージョンを上げる・公開するとき | `/release` |

**View を書き始める前に `docs/art-ref/visual-dict.md` を、ドット絵を打つ前に `/pixel-art` を引いていない場合、その作業は未着手として扱う。**

### スキルを持たないエージェントへ

`/名前` の中身は**ただの markdown**。どのエージェントでも `.claude/skills/<名前>/SKILL.md` を
直接読めば同じ内容が手に入る。規約の本文は `docs/` とこのファイルに一本化してあり、
`.claude/rules/*.md` は `make rules` の生成物、`CLAUDE.md` は `@AGENTS.md` の 1 行。
配線の崩れは `make check-docs-sync` が検査する。**規約を直したら本文の方を直す。**
