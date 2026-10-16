# エージェント共通指針（エンジン公式・全ゲーム共有）

このファイルはエンジンの agents-pack から配られる共通部。ゲーム固有の方針は
同じフォルダの `AGENTS.local.md` に書く。

## やりたいこと → 道具（早見表。まずここを引く）

1 行 1 件。型と引数は `make api Q=<名前>`、使い方は engine の `engine_world/src/<名前>.flix` 冒頭の doc。ゲーム固有の行は `AGENTS.local.md` の早見表。

| やりたいこと | 使う道具 |
|---|---|
| 物を重ねる・手前と奥を決める | View は `ZStack` の木（`of` に奥→手前・`leaf`。葉の中の z は 0..31）。根で `SortingLayer.compose`。engine の `docs/z-bands.md` |
| 必ず手前に出す（確認の窓・説明の窓・ポーズ） | `ZStack.topLayer(層, 木)`。新しい層は `SortingLayer` の enum に case を足す |
| 見下ろしで人が木の裏に回る | `ZStack.zIndex(Depth.orderAt(足元のy), leaf(人))` |
| 画面ごと動かす・縮める・薄める | `ZStack.mapItems(Render.scaledAllAround(..))` |
| スコア・案内など隠れてはいけない表示 | `App.withHudView`（中の前後は HUD の層の表と木） |
| 説明の窓の置き場（はみ出さない） | `UiTooltip`（置き場）+ `ZStack.topLayer`（手前へ） |
| 演出の拍に効果音・動きを合わせる | `Timeline.build`（`append` / `join`・音は `withSound`。秒・拍は Doc）→ 描く側 `progressOf`・鳴らす側 `soundsOn` を `App.withAudio` へ |
| 演出を曲の拍・小節に乗せる（小節の頭で始める・小節の頭の n 拍前に置く・伸ばしても拍から外れない） | `Timeline.build` の長さと遅らせを `Duration.Beats` / `Bars` / `ToNextBar` / `ToBeat` / `ToPickup`（次の小節の頭の n 拍前）で書き、テンポは `Timeline.tempo(譜面の bpm, 拍子)` で 1 か所から渡す |
| 曲の頭（イントロ）を 1 回だけ鳴らして本編だけループする | 1 本の WAV にループ点を書く `SfxSynth.renderLooped`（実機も `AudioMixdown.mixdownLooped` も smpl から輪の頭へ戻る）。鳴らす側は同じ名前を `App.withSustained` で宣言し続ける |
| Doc が壊れていたら既定値で続けて知らせる | `DocJson.loadOr` + `Log.fellBackThen` / `warnThen` / `warnAllThen` |
| 直した後に絵を確かめる | `make render SHOT=<場面>`（1 枚・既定の手）→ 仕上げに `make reference-check` |
| F8 のチケットから直す所を探す | `debug/annotations/<名前>/` の `README.md` 冒頭の文脈（場面・Doc と行）→ `annotation.json` の `context` → `world.json`（`App.withAnnotationContext` / `withWorldDump`。一覧は `make status`） |
| API の型・ゲームの定義を引く | `make api Q=<名前>` / `make src Q=<名前>` |
| 重い処理（check・test・描き出し・make sync）をほかのエージェントと順番に流す | `bin/fge heavy <コマンド...>`（持ち主と待ち列は `bin/fge heavy --status`・CHECKD=0 が既定） |
| 作業場を別の版・開発中のエンジンへ一時的に向ける | `bin/fge use-engine <版かパス>`（今は `--status`・戻すのは `--restore`） |
| 直す前と後の絵・音・動画を比べる | `make compare BASE=<ref>`（絞るなら `SHOTS=` か `VIDEOS=`。`debug/compare/index.html`。基準側だけ別のエンジンなら `BASE_ENGINE=`） |
| 案を並べて依頼主に選んでもらう | `reports/<名前>/proposal.json` → `bin/fge proposal build`（形は引数なしの `bin/fge proposal`・決定後の片付けの残りは `bin/fge proposal knobs`） |
| 道具の選び方が文書で伝わるか測る | `make agent-eval`（お題は `agent-eval/*.json`）・版ごとの比べは `make agent-eval-release`（記録は `agent-eval/history/`・最新は `make status` の 1 行） |

**新しい仕組みを入れる人は**、この表（ゲーム固有なら `AGENTS.local.md` の表）に 1 行と、
`agent-eval/` のお題を 1 本足し、`make agent-eval ONLY=<お題>` で当たるのを確かめてから入れる。

## 言葉づかい（コメント・会話・ドキュメント）

2 つの層があります。混ぜないでください。

- **単語は業界の言葉をそのまま使う。** ゲーム業界・ソフトウェア業界で通じる語を優先し、
  カタカナ（和製英語）か英語のまま書く（レイヤー・バージョン・ボタン・オーバーレイ・
  スプライト・`Layer` `Version`）。**和語へ言い換えない。造語も作らない。** 読み手はエンジニア。
- **説明は平易に。** 難しい数学用語・専門用語に寄りかからず、何が起きるのかを普通の
  言葉で書く（「線形補間する」ではなく「2 つの値の間をなめらかにつなぐ」）。

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

## Doc 規約（ゲームデータ JSON）

- **1 種類 = 1 Doc + 1 スキーマ**（`<名前>.<種類>.json` と `<種類>.schema.json`）。
  全 Doc が `version` を持ち、`note` 歓迎。
- **読み込みは fail-open**（書き損じ・欠けは既定値へ。既定値はコード側）。**watchFile で保存即反映**。
- **データは Doc・振る舞いはコード**。繰り返し調整する数値（テンポ・閾値・収支・確率）、
  増減するデータ（rows）、色テーマ、文言は Doc へ。描画アルゴリズム・演出の形・
  導出できる値・ルールはコードのまま。ロジックを JSON に書き始めたら設計の匂い。
- **プレイヤーの目に入る文言は必ず Doc に置く（既定値はコード側）**。
  コード直書きの表示文字列は違反 — Studio から変えられない。
- **ドット絵の `legend` の色キーはパレットに実体を置く**（`*.theme.json` のトップレベル・
  sprite Doc の `paletteFile` が指すパレット・直下の `palette` のどれか）。派生色をコードで
  導いたままにすると Studio は仮色で塗る。導くならパレット JSON を生成して `paletteFile` で指す。

## atelier/ 規約（採用前の候補置き場）

- `atelier/` は **採用前の候補**を置く場所。中身は `assets/` と同じ Doc 形式。
- `assets/` のパスは**スロット**（Doc の `entityId` で互換を確認する）。
- 採用は **swap**: 候補の中身をスロットへ移す(候補ファイルは消える)。それまでの中身は
  `atelier/archive/<base>.vN.<kind>.json` に積まれる(何も捨てない。戻すのもここから)。
- **AI が素材を作るときは `assets/` に直接書かず、必ず `atelier/` に書く。**

## セッションの始め方と終わり方

- 開始時は SessionStart フックが `make status`（テスト記録・リファレンス画像一致・
  アノテーションチケット・git の 1 画面）を流す。個別に git log を掘ったりテストを回し直したりせず、まずこの 1 画面から入る。
- `.flix` は cat/sed で丸読みしない。まず `grep -n` か `make src Q=<名前>` で位置を引き、Read の offset/limit で必要な範囲だけ読む。広い探索はサブエージェント（Explore）に任せ、結論だけ 1〜2k トークンで返させる。
- 区切りごとに `NOTES.md` の先頭へ「今どこまで・次やること」を 3 行残す（次の status に載る）。

## make の入口

- `make check`（型検査・一番速い）/ `make test` / `make run` / `make debug`（watchFile・F8）
- `make render SHOT=<場面名>`（1 枚だけ。既定の手）/ `make render-all`（全部）/
  `make reference-check`（gallery/ と reference/ のバイト比較）/ `make reference-update`
- `debug/` のコンタクトシート（`make gallery-prologue` の all.png、`make gallery-sounds` の
  sounds.png・BGM があれば music.png）で**目と耳で確かめて**批評する。
- `make src Q=<名前>`（ゲームの src/ の pub 定義を 1 行で）/ `make src-index`（全部を `debug/src-index.md` へ。ファイル別・行番号つき）
- 口の一覧は `make help`。共通の口の実体はエンジンの `mk/game.mk`（ゲームの Makefile が include）。
  **共通ターゲットをゲームの Makefile へ写さない**（`upgrade-game` は Makefile を運ばないので、
  写すとエンジンの修正が届かない）。ゲーム側に置くのは `SHOTS` / `PALETTE` / `RENDER_NOTE` と固有の口だけ。

## テスト方針（要約。詳しくは quality-assurance スキル）

- テストするのは「ゲームの**ルール・進行・収支**」と「JSON とプログラムの橋渡し」だけ。
  モーション・表示タイミング・座標の丸写しはテストしない（スナップショットと目視の仕事）。
  クリック当たりの有無はルールなので残す。
- **期待値は Doc（JSON 既定値）から導く**。数値リテラルを貼らない。
- 橋渡しテストは **1 Doc につき最大3本**（壊れた JSON→既定値 / 1 フィールド上書き / rows 長の追随）。

## エンジン API 優先(車輪の再発明禁止)

- 実装の前に engine リポの `docs/module-index.md`（やりたいこと → モジュールの逆引き）を引く。
  **エンジンにある物を自前で書かない** — メニュー・スクロール・文字折り・当たり判定・
  マップ地形（Terrain / TerrainDoc・MapResource）・フォーカス巡りとツールチップ（UiFocusNav / UiTooltip）・
  音のバスとダッキング（App.withMixer + mixer.json）・演出の時刻表（動き・効果音・待ちを 1 本に書く Timeline.build・曲の頭を 1 回だけ鳴らすのは WAV のループ点）・
  ヒットストップ（TimeScale）・長押し（HoldPress）・数え上げ（EcsTween.steppedInt）など。
- API の型・引数は、ソースを grep/unzip する前に `docs/api-digest.md`（`make api Q=<名前>` で 1 行）。
  使い方は `engine_world/src/<名前>.flix` 冒頭の doc コメントと templates/ の実使用例が正。
- 「一番高い API で書けたか」を疑う。自前実装が残っていたらレビュー（critique-code）の指摘対象。

## 初学者の足場（生成コードに必須）

成果物は「初学者が仕組みを読み取れる」ことを謳う。以下は**生成・拡張の完了条件**。

- **読む順序**: README に一節 — **遊ぶ → 読む順（エントリ→状態→描画）→ JSON をいじる**。専用ファイルは増やさない。
- **ゲームループの明示**: Main か World の冒頭 doc に、毎フレーム **入力→状態更新→描画** がどの行かを数行で。
  場面遷移があれば 1 行の遷移図（`title → play → clear`）。
- **Doc の学びやすさ**: 各 Doc の `note` に「いじると何が変わるか」、調整パラメータに効果の一言。可能なら最小例。
  schema の `label` / `description` を埋める（空の schema は違反）。
- **黒箱に触れたら engine 解説へ誘導**: 高抽象 API（`Terrain.fromRows` 等）を呼ぶ箇所に
  「何をするか」一言 + engine の `docs/module-index.md` への言及。

## 絵の下限（生成コードに必須）

**絵を描く前に `.claude/rules/drawing.md` と `.claude/skills/visual-dict` を読む**（View を書く前に毎回。
Claude Code 本体は View 系 `.flix`・`*.sprite.json`・`*.shader.json`・絵を打ち起こす `gen-*.py` などを触ると自動で読むが、
**サブエージェントは自動読みが効かないので直接読む**）。本文（画風を先に決めて `AGENTS.local.md` へ書く・
5 性質＝階調か質感 / 主役と背景の分離 / 層 / 時間 / 形・満たせなければ `AGENTS.local.md` に理由）はそちら。

## 絵の周回（描いた後の直し方）

- **周回は r2 で必ず止める**（効くのは作りを変えた周と原因を特定した周だけ・判定は依頼主。元の本文は drawing.md）。r1 と r2 の PNG（実寸）を並べて依頼主へ「①どちらが良いか ②続けるか ③直す所を 1 つ」だけ聞き、返事まで r3 を描かない。
- r3 以降も 1 周ごとに①を聞き、前の周が良ければ戻す（PNG は `debug/history/` に残す・最大 5 周・拡大で見つけた欠陥は実寸で読める物だけ直す）。②が「終わり」なら①で選ばれた周を提出。
- **呼び出す側への注意**: prompt に「N 周まで・直せなければ報告へ」と書くとこの決まりを殺す。進め方はこの節を指すだけにする。

## ドット絵の打ち方（sprite.json の作法）

画素を置く前に `.claude/skills/retro-pixel/SKILL.md`（格子に乗らない絵なら `smooth-render`）を読む。
作法（パレットを先に・大きい物は 1 枚・地面タイルは縁と角まで・歩き 4 方向は `carve-sprite`）の本文は `.claude/rules/drawing.md`。

## スキルと規約の在り処（どのエージェントでも読める）

- スキルの中身はただの markdown（`.claude/skills/<名前>/SKILL.md`。同じ物が `.agents/skills/` にもあり、
  Codex は `$名前` で呼べる）。**一覧はこのファイル末尾。作業に入る前に該当するスキルを読む。**
- `.claude/rules/*.md`（絵の下限 `drawing.md`・Flix の決まり `flix.md`・エラー処理 `error-handling.md`）も
  ただの markdown。Claude Code 本体は対象ファイルを触るとき自動で読むが、この自動読みは
  サブエージェントでは発火しない — **サブエージェントと他のエージェントは作業前に `.claude/rules/*.md` を直接読む**。
  skill の自動発動もサブエージェントでは効かないので、委譲する親は読ませる skill を prompt で名指しする
  （例: 絵なら「`/visual-dict` と、格子に乗る絵なら `/retro-pixel`・乗らない絵なら `/smooth-render` を読んでから描く」）。
- 「engine リポの `docs/...`」は `Makefile` 冒頭の `ENGINE` が指す場所にある。
- フック機構を持たないエージェントは手で同じことをする: セッション最初に `make status`・`.flix` を
  編集するたび `make check`。コミットのゲートは git の pre-commit（未配線なら `make hooks`、clone ごとに 1 回）。
  Codex の `.codex/hooks.json` と `.agents/skills/` は project trust の承認後に有効。

人に見せる前に自分で確かめる（OS・エージェントを問わず動く）:

```
bin/fge view [ファイル...]   # 矩形と円だけになっていないか
bin/fge palette              # ドット絵の意味色キーが色票から解けるか
bin/fge sprite [ファイル...]  # ドット絵の画素の並び(浮き・階段・細長さ・色数)
bin/fge anim [ファイル...]    # コマ間の飛び・接地と 4 方向のそろい
```

## 迷ったら読む物

- 書き方の癖と定石: `.claude/skills/flix-docs`(構文)・`compile-fix`(コンパイルエラー)・`quality-assurance`(テスト設計)
- 画風がまだ決まっていない・新しいゲームを作り始める: `.claude/skills/style-interview`(人へ最大 7 問の聞き取り。注文は AGENTS.local.md へ)
- 見栄えの実装: `.claude/skills/visual-dict`(絵の下限の節のとおり View の前に必読)と engine リポの `docs/shader-doc.md`(宣言シェーダーの語彙とレシピ)
- ドット絵で行くと決まった後: `.claude/skills/retro-pixel`(色の予算・タイルと材質・キャラの等身・小物の置き場。画風を決めるのは visual-dict が先)
- 画素の格子に乗せない絵で行くと決まった後: `.claude/skills/smooth-render`(エッジの硬さ・面積と彩度・質感の重ね方・なめらかな面に出る縞の消し方。こちらも画風を決めるのは visual-dict が先)
- 規約と地図: engine リポの `docs/doc-conventions.md`(Doc の外形)・`docs/module-index.md`(やりたいこと → モジュール)・`docs/audio.md`(音)・`docs/glossary.md`(UI に出す言葉)
- 動く見本: engine の `templates/game-starter`(最小)と、隣にある既存ゲームのソース
