# エージェント共通指針（エンジン公式・全ゲーム共有）

エンジンの agents-pack から配られる共通部。ゲーム固有の方針は同じフォルダの `AGENTS.local.md` に書く。
lint・フック・make の口で止まる決まりはここに書かない（止まった所で hint が代わりの道具を示す）。

## やりたいこと → 道具（早見表。まずここを引く）

1 行 1 件・80 字まで。行には名前だけ置き、詳しい所は `--help`・engine の docs・モジュール冒頭の doc へ。
表に無ければ `make module Q=<やりたいことの語>`、型と引数は `make api Q=<名前>`。ゲーム固有は `AGENTS.local.md`。

| やりたいこと | 使う道具 |
|---|---|
| 物を重ねる・手前と奥を決める | `ZStack.of` / `leaf` の木を根で `SortingLayer.compose` |
| 必ず手前に出す（確認の窓・ポーズ） | `ZStack.topLayer(層, 木)`・層は `SortingLayer` の enum |
| 見下ろしで人が木の裏に回る | `ZStack.zIndex(Depth.orderAt(足元のy), leaf(人))` |
| 画面ごと動かす・縮める・薄める | `ZStack.mapItems(Render.scaledAllAround(..))` |
| 閉じるボタンで「終了しますか？」・ゲームから終了 | `App.withCloseRequest` + `App.quitWhen` |
| 隠れてはいけない表示（スコア・案内） | `App.withHudView` |
| 押す物を見た目の手前から選ぶ（窓の奥を押させない） | `SortingLayer.pick(点, 層ごとの当たりの列)` |
| 説明の窓をはみ出さず置く | `UiTooltip` + `ZStack.topLayer` |
| 演出の時刻表（動き・効果音・待ち） | `Timeline.build`（`insert`・`withSound`・`buildOrBug`） |
| 時刻表を描く・鳴らす | `progressOf`・`soundsOn` / `soundsBetween` → `App.withAudio` |
| 曲の拍・小節に乗せる | `Duration.Bars` / `ToNextBar` / `ToPickup` + `Timeline.tempo` |
| 演出の長さ・待ち・溜めの目安 | engine の `docs/pacing.md` |
| 曲の頭を 1 回だけ鳴らし本編をループ | `SfxSynth.renderLooped` + `App.withSustained` |
| Doc が壊れたら既定値で続けて知らせる | `DocJson.loadOr` + `Log.fellBackThen` / `warnThen` |
| 直した後に絵を確かめる | `make render SHOT=<場面>` → 仕上げ `make reference-check` |
| 直す前と後の絵・音・動画を比べる | `make compare BASE=<ref>` |
| F8 のチケットから探す | `debug/annotations/<名前>/` の README・`annotation.json` |
| ゲームの定義を引く | `make src Q=<名前>` |
| 重い処理を順に流す | `bin/fge heavy <コマンド>`（`--help`・`--status`・`--history`） |
| 作業場を別の版のエンジンへ一時的に向ける | `bin/fge use-engine <版かパス>`・戻すは `--restore` |
| 案を並べて依頼主に選んでもらう | `reports/<名前>/proposal.json` → `bin/fge proposal` |
| ドット絵（sprite.json）を描く・直す | `/pixel-art`（表でお題の種類のファイルだけ読む） |
| 道具の選び方が文書で伝わるか測る | `make agent-eval`（お題は `agent-eval/*.json`） |

新しい仕組みを入れる人は、この表（ゲーム固有なら `AGENTS.local.md`）に 1 行と `agent-eval/` のお題を 1 本足し、
`make agent-eval ONLY=<お題>` で当たるのを確かめる。**足すのと対で、まとめられる行はまとめ、使われなくなった行は消す**。

## エンジン API 優先（車輪の再発明をしない）

実装の前に、早見表 → `make module Q=<語>` → `make api Q=<名前>` の順に引く（`docs/` を丸ごと読まない）。
使い方は engine の `engine_world/src/<名前>.flix` 冒頭の doc と `templates/` の実使用例が正。
エンジンにある物（メニュー・スクロール・文字折り・当たり判定・地形・音のバス・長押し…）を自前で書かない。
「一番高い API で書けたか」を疑う。自前実装の残りはレビュー（critique-code）の指摘対象。

## 言葉と名前（コメント・会話・ドキュメント・識別子）

- **単語は業界の言葉をそのまま**（カタカナか英語: レイヤー・スプライト・`Layer`）。和語へ言い換えない・造語や比喩を作らない
  （英単語でも `bless` `carve` のようにこのリポジトリだけの意味を持たせない）。
- **説明は平易に**（「線形補間する」ではなく「2 つの値の間をなめらかにつなぐ」）。
- 名前は ゲーム業界の語 → ソフトウェア一般の語 → 他のエンジン（Unity / Godot / Bevy。迷ったら Bevy）の順に探し、
  無い物だけ説明的に組み立てる（`silhouettePng`）。英語で読んだ人に通じるかで決める。
- 動詞: `get*` 取り出すだけ（安い）/ `load*` `fetch*` 外から取る（失敗しうる）/ `build*` `make*` `compute*` 計算して作る /
  `is*` `has*` `can*` Bool / `set*` 差し替え・`with*` 新しい値を返す / `to*` 作り直す・`as*` 見方だけ変える。1 つの動詞に 2 つの意味を持たせない。

## Doc（ゲームデータ JSON）

- 1 種類 = 1 Doc（`<名前>.<種類>.json`）+ 1 スキーマ（`<種類>.schema.json`）。全 Doc が `version` を持つ。
- 読み込みは fail-open（欠け・書き損じは既定値へ。既定値はコード側）・watchFile で保存即反映。
- **データは Doc・振る舞いはコード**。繰り返し調整する数値・増減する rows・色・文言は Doc、
  描き方・演出の形・導出できる値・ルールはコード。ロジックを JSON に書き始めたら設計の匂い。
- **プレイヤーの目に入る文言は必ず Doc に置く**（コードには既定値だけ。直書きは Studio から変えられない）。

## atelier/（採用前の候補置き場）

**AI が素材を作るときは `assets/` に直接書かず `atelier/` に書く**（中身は同じ Doc 形式）。`assets/` のパスはスロット。
採用は swap（候補をスロットへ移し、前の中身は `atelier/archive/<base>.vN.<kind>.json` に積む）。

## 進め方

- `.flix` は丸読みしない。`grep -n` か `make src Q=<名前>` で位置を引き、Read の offset/limit で読む。
  広い探索はサブエージェント（Explore）に任せ、結論だけ返させる。
- 区切りごとに `NOTES.md` の先頭へ「今どこまで・次やること」を 3 行（次の `make status` に載る）。
  古い項は `make notes-rotate` で `notes/<年-月>.md` へ送る（溜まるとコミットで止まる）。
- make の口は `make help`。共通の口は engine の `mk/game.mk` にあり、ゲームの Makefile へ写さない
  （写すとエンジンの修正が届かない）。ゲーム側には `SHOTS` 等の値と固有の口だけ。
- 絵と音は `debug/` のコンタクトシート（`make gallery-prologue`・`make gallery-sounds`）で目と耳で確かめて批評する。

## テスト（詳しくは `/quality-assurance`）

テストするのはルール・進行・収支と、JSON とコードの橋渡しだけ（モーション・座標の丸写しはしない。クリック当たりはルール）。
期待値は Doc の既定値から導く。橋渡しテストは 1 Doc に最大 3 本（壊れた JSON / 1 項目の上書き / rows 長の追随）。

## 初学者の足場（生成・拡張の完了条件）

- README に「遊ぶ → 読む順（エントリ→状態→描画）→ JSON をいじる」の一節（専用ファイルは増やさない）。
- Main か World の冒頭 doc に、毎フレームの入力→状態更新→描画がどの行か。場面遷移は 1 行の図（`title → play → clear`）。
- 各 Doc の `note` に「いじると何が変わるか」、schema の `label` / `description` を埋める。
- 高抽象 API（`Terrain.fromRows` 等）を呼ぶ所に一言と engine の `docs/module-index.md` への言及。

## 絵

**絵を描く前に `.claude/rules/drawing.md` を読む**（Claude Code 本体は絵のファイルを触ると自動で読むが、
サブエージェントは直接読む）。ドット絵は `/pixel-art`、格子に乗らない絵は `/smooth-render` が入口。
絵を委ねる親は prompt に「N 周まで」と書かず、drawing.md の「絵の周回」の節を指すだけにする。

## エージェントの違い

- スキルはただの markdown（`.claude/skills/<名前>/SKILL.md`・同じ物が `.agents/skills/` にも）。一覧はこのファイルの末尾。
  作業に入る前に当たるスキルを読む。
- `.claude/rules/*.md` とスキルの自動読みはサブエージェントでは効かない。サブエージェントは作業前に rules を直接読み、
  委ねる親は読ませるスキルを prompt で名指しする。
- フックの無いエージェントは手で同じことをする: 最初に `make status`・`.flix` を直すたび `make check`・
  clone ごとに 1 回 `make hooks`（コミットのゲート）。Codex の `.codex/hooks.json` と `.agents/skills/` は project trust の後に有効。
- 「engine の `docs/...`」は ゲームの `Makefile` 冒頭の `ENGINE` が指す所にある。

## 迷ったら読む物

- Flix: `/flix-docs`（構文）・`/compile-fix`（コンパイルエラー）。画風が決まっていない: `/style-interview`
- engine の `docs/doc-conventions.md`（Doc の外形）・`docs/shader-doc.md`（シェーダー）・`docs/audio.md`・`docs/glossary.md`（UI の言葉）
- 動く見本: engine の `templates/game-starter` と、隣にある既存ゲームのソース
