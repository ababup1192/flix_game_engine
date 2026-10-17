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
| 演出の時刻表（動き・効果音・待ち） | `Timeline.build`（`insert`・`withSound`・`buildOrPanic`） |
| 時刻表を描く・鳴らす | `progressOf`・`soundsOn` / `soundsBetween` → `App.withAudio` |
| 曲の拍・小節に乗せる | `Duration.Bars` / `ToNextBar` / `ToPickup` + `Timeline.tempo` |
| 演出の長さ・待ち・溜めの目安 | engine の `docs/pacing.md` |
| 曲の頭を 1 回だけ鳴らし本編をループ | `SfxSynth.renderLooped` + `App.withSustained` |
| Doc が壊れたら既定値で続けて知らせる | `DocJson.loadOr` + `Log.fellBackThen` / `warnThen` |
| 直した後に絵を確かめる | `make render SHOT=<場面>` → 仕上げ `make reference-check` |
| 直す前と後の絵・音・動画を比べる | `make compare BASE=<ref>` |
| F8 のチケット | `debug/annotations/` の README → `annotation.json` → `world.json` |
| ゲームの定義を引く | `make src Q=<名前>` |
| 重い処理を順に流す | `bin/fge heavy <コマンド>`（`--help`・`--status`・`--history`） |
| 作業場を別の版のエンジンへ一時的に向ける | `bin/fge use-engine <版かパス>`・戻すは `--restore` |
| 案を並べて依頼主に選んでもらう | `reports/<名前>/proposal.json` → `bin/fge proposal` |
| ドット絵（sprite.json）を描く・直す | `/pixel-art` → 指定 `*.pxsrc.json` を `bin/fge px build`（op は `px ops`） |
| 繰り返し・変化の要るドット絵の指定 | 台本 `*.px.star` を `bin/fge px gen`（書かずに描くのは `px build`） |
| 絵の周回を残す・前の周へ戻す | `bin/fge rounds snap` / `restore`（出る案内に従う） |
| AI が素材（絵・音）を作る・直す | `atelier/` に書く（`assets/` はスロット。採用は swap） |
| 道具の選び方が文書で伝わるか測る | `make agent-eval`（お題は `agent-eval/*.json`） |

新しい仕組みを入れる人は、この表（ゲーム固有なら `AGENTS.local.md`）に 1 行と `agent-eval/` のお題を 1 本足し、
`make agent-eval ONLY=<お題>` で当たるのを確かめる。**足すのと対で、まとめられる行はまとめ、使われなくなった行は消す**。

## 判断の向き（機械では止められない物）

- **エンジンにある物（メニュー・スクロール・文字折り・当たり判定・地形・音のバス・長押し…）を自前で書かない**。ゲームに
  自前の物があってもエンジンの物を選ぶ。早見表で道具が決まればそのまま使い、表に無い時だけ `make module` / `make api` で引く。
  使い方はモジュール冒頭の doc と `templates/` が正。「一番高い API で書けたか」を疑う。
- **言葉は業界の語**（カタカナか英語）で、説明は平易に。造語・比喩・このリポだけの意味を作らない。
  名前は業界の語 → 他のエンジン（迷ったら Bevy）の順に探す。動詞は `load`/`fetch` 外から取る（失敗しうる）・
  `build`/`compute` 計算して作る・`with` 新しい値を返す・`to` 作り直す / `as` 見方だけ変える（`is`/`get` は lint が見る）。
- **データは Doc・振る舞いはコード**。調整する数値・rows・色・**プレイヤーの目に入る文言**は Doc（コードには既定値だけ）。
  描き方・演出の形・ルールはコード。ロジックを JSON に書き始めたら設計の匂い。
- **テストはルール・進行・収支と、JSON とコードの橋渡しだけ**。期待値は Doc の既定値から導く（`/quality-assurance`）。
- 生成したコードは初学者が読める形に（読む順の README・毎フレームの流れの doc は `templates/` にある形を保つ）。
- 区切りごとに `NOTES.md` の先頭へ「今どこまで・次やること」を 3 行。広い探索はサブエージェントに任せ、結論だけ返させる。
- 絵を描く前に `.claude/rules/drawing.md` を読む。入口はドット絵 `/pixel-art`・格子に乗らない絵 `/smooth-render`。
  絵を委ねる親は prompt に「N 周まで」と文で書かず、drawing.md の「絵の周回」を指す（周を任せる時は snap の `--max N`）。
- 作業に入る前に当たるスキル（一覧は末尾）を読む。サブエージェントには rules とスキルの自動読みが効かないので、
  委ねる親は読ませる rules とスキルを prompt で名指しする。
- フックの無いエージェントは手で: 最初に `make status`・`.flix` を直すたび `make check`・clone ごとに `make hooks`。
  スキルの実体は `.claude/skills/<名前>/SKILL.md`（Codex は `.agents/skills/`・`.codex/hooks.json` は project trust の後に効く）。
- 「engine の `docs/…`」はゲームの `Makefile` の `ENGINE` が指す所にある。
