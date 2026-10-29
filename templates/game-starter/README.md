# __TITLE__

flix_game_engine のスターター。主人公（ドット絵）を矢印キーで動かせるだけの、
「ここから自分のゲームを育てる」ための骨組みが入っています。
`make new-game` で生成された時点で check / test / render が全部通る状態です。

## 始め方

Flix コンパイラはエンジンリポの `bin/flix` ラッパ経由で呼ぶので、devbox shell の外でも動きます。
エンジンの場所が既定（生成時に埋め込み）と違うときは `ENGINE=/path/to/flix_game_engine` を付けてください。

| コマンド | 何をするか |
|---|---|
| `make run`    | ゲームを起動する（ウィンドウが開く） |
| `make debug`  | 保存即反映(watchFile)と F8 を有効にして起動 |
| `make check`  | 型検査だけ走らせる（一番速い確認） |
| `make test`   | テストを実行する |
| `make palette` | Studio 用の色の写し(`assets/__NAME__.palette.json`)を作り直す |
| `make render-all`   | ギャラリー PNG を全部描き出す（決定的） |
| `make render SHOT=main` | その場面だけ `debug/main.png` へ描き出す |
| `make reference-check`  | 描き出した絵をリファレンス画像とバイト比較する |
| `make reference-update` | いまの gallery をリファレンス画像として更新する |
| `make atelier-preview` | atelier/ の候補と assets/ の現行を debug/atelier/ に描き出す |
| `make flow FLOW=e2e/walk.flow` | 手順書（1 行 1 手）を画面なしで実機と同じ道に流す |
| `START="at x=40 y=40" make run` | 始まりの登録簿（`src/Starts.flix`）の場面から起動する |

## 読む順（全体像のつかみ方）

**遊ぶ → 読む → JSON をいじる** の順で仕組みが見えます。

1. まず `make run` で遊ぶ（矢印キーで主人公が動く）。
2. コードは **エントリ→状態→描画** の順で読む:
   1. `src/Game.flix` … 3 つを App に繋ぐ目次。冒頭 doc に**毎フレームの流れ
      （入力→状態更新→描画 がどの行か）**が書いてある。まずここ。実機の起動（`src/Main.flix`）・
      flow・テストが同じ `Game.app` を使う。`src/Main.flix` は窓にだけ効く口（アトラス・終了の確認）を足して起動する。
   2. `src/World.flix` … 遊びの状態そのものと、次の状態を作る規則（`step` が入力→更新。純粋）。
      画面は `Screen` の enum（今は `Play` だけ）で、その画面だけの値は payload の中に持つ。
   3. `src/Res.flix` … 描く元（Doc と、Doc から作る仕上げ済みのドット絵・アトラス）。Doc を読み直した時だけ替わる。
      Doc を足すときは World でなくここに欄と `with*` を足す。
   4. `src/View.flix` … 描く元と状態を絵に写す（何をどこに描くか）。冒頭 doc に場面に**積んだ部品**
      （背景・主役・粒がどの関数か）と、終了の確認の窓・静的な縁の枠が並べてある。
   5. `src/ZOrder.flix` … 画面全体の層の表（場面・縁の枠・確認の窓の前後）。新しい層はここに case を足す。
   6. `src/Controls.flix` … キーの割り当てと Doc の読み込み・読み直し。Esc で終了の確認を出す（閉じるボタンは Main の `App.withCloseRequest`）。
   7. `src/Starts.flix` … 始まりの登録簿。起動（`START=`）・flow の `start`・テストが名前で場面を組む。
   8. `src/E2e.flix` … `e2e/*.flow` の語彙（役・問い）と指紋。手順書の書き方は engine の `engine_world/src/Flow.flix` 冒頭。
   9. `src/render/SceneRender.flix` … 決定的な場面を PNG に描き出す（リファレンス画像とアトリエ）。
3. 手触り・色・絵は下の `assets/` の Doc を保存即反映でいじる。

数値・色・絵は `assets/` の Doc（保存即反映）:

- `assets/sample.kind.json` … 手触りの数値（例: 速さ）。`src/SampleDoc.flix` が読む。
- `assets/*.theme.json` … 色票。`src/ThemeDoc.flix` が読む。
- `assets/__NAME__.palette.json` … Studio のドット絵エディタに「意味色キー → 実色」を教える写し（生成物）。
  つや・影のような派生色はコードで導いていて Studio からは見えないので、`make palette` で
  書き出して `*.sprite.json` の `paletteFile` から指す。手で直さない（色を変えるのはテーマ側）。
- `assets/*.sprite.json` … ドット絵（文字格子）。entityId は `<パッケージ名>.sprites`。
  絵は差し色 1 色で平らに塗り、ふち光・影は読み込み時に `PxShade` が乗せます。
- `assets/*.shader.json` … 背景の塗り（画素ごとの計算）。単色の四角の代わり。
  書き方は engine の `docs/shader-doc.md`。

それぞれに Studio 用の schema（sections 方言 / sprite は draft-07）が並んでいて、
`project.json` の `editor.resources` が宣言しています。Studio で開けばそのまま編集できます。

## 絵の開発ループ

- **画風は最初に決めて `AGENTS.local.md` に書く**。この骨組みの見た目は一例で、
  そのまま引き継ぐ物ではありません（好みの聞き取りは `/style-interview`、部品選びは engine の `docs/art-ref/visual-dict.md`）。
- `make render-all` で `gallery/` に決定的な PNG を描き出し、`make reference-update` で更新、`make reference-check` で防護。
- 候補のスプライト・テーマは `atelier/` に置き、`make atelier-preview` で `debug/atelier/` に描き出して目視。

## AI エージェント向け指針の配布（sync-agents）

エンジン側で `make sync-agents GAME=/path/to/このゲーム` を実行すると、エンジン共通の
エージェント指針（agents-pack/AGENTS.core.md）とこのゲームの `AGENTS.local.md` を連結した
`AGENTS.md` が生成され、共通スキルが `.claude/skills/` にコピーされます。`AGENTS.md` は
生成物なので直接編集せず、ゲーム固有の原則は `AGENTS.local.md` に書いて再 sync してください。
