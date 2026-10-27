# 潮だまり

flix_game_engine のパズルのスターター。1 手ごとに潮が満ち引きする磯で、岩を押して水路を作り変え、
ヤドカリを巻き貝まで引っ越しさせる。ターン制・取り消し（Z）・やり直し（R）・先読み（待ったらどうなるか）の骨組み。
画面は規則の値（盤・水位・物・ヤドカリ・手数・先読み）から描き、1 手の水位の変化は `EcsTween` でなめらかにつなぐ。

## 始め方

Flix コンパイラはエンジンリポの `bin/flix` ラッパ経由で呼ぶので、devbox shell の外でも動きます。
エンジンの場所が既定（生成時に埋め込み）と違うときは `ENGINE=/path/to/flix_game_engine` を付けてください。

| コマンド | 何をするか |
|---|---|
| `make run`    | ゲームを起動する（ウィンドウが開く） |
| `make debug`  | 保存即反映(watchFile)と F8 を有効にして起動 |
| `make check`  | 型検査だけ走らせる（一番速い確認） |
| `make test`   | テストを実行する |
| `make palette` | Studio 用の色の写し(`assets/tidepool.palette.json`)を作り直す |
| `make render-all`   | ギャラリー PNG を全部描き出す（決定的） |
| `make render SHOT=play` | その場面だけ `debug/play.png` へ描き出す（場面は title play flood dam clear washed ending quit） |
| `make reference-check`  | 描き出した絵をリファレンス画像とバイト比較する |
| `make reference-update` | いまの gallery をリファレンス画像として更新する |
| `make solve` | 面を幅優先で解き、最少手数・解き方・面の指紋を `assets/tidepool.levels.json` に書く（面を直したら回す） |
| `make flow FLOW=e2e/level1.flow` | 題名の画面から面 1 をクリアするまでを画面なしで流す |

## 読む順（全体像のつかみ方）

**遊ぶ → 読む → JSON をいじる** の順で仕組みが見えます。

1. まず `make run` で遊ぶ（題名で ←→ で面を選んで Enter。矢印で動く・押す、Space で待つ、Z で 1 手戻す、R で面の初めから）。
2. コードは **エントリ→状態→描画** の順で読む:
   1. `src/Main.flix` … 3 つを App に繋いで起動する目次。冒頭 doc に**毎フレームの流れ
      （入力→状態更新→描画 がどの行か）**が書いてある。まずここ。
   2. `src/World.flix` … 1 手の規則（`act`: 動く・押す・水を更新・流された・クリア）・先読み・取り消し・面の進行。
      水の決まりは `src/Tide.flix`、盤の値（Doc の格子から組む）は `src/Board.flix`。
   3. `src/View.flix` … 状態を絵に写す（何をどこに描くか）。冒頭 doc に場面に**積んだ部品**
      （水底・岩の段・水・泡・先読み・ヤドカリ）が並べてある。右の板と重ね（クリア・流された）は `src/HudView.flix`、
      題名と終わりは `src/TitleView.flix`、物の形は `src/PropView.flix`、盤を画面へ収める寸法は `src/Layout.flix`。
   4. `src/ZOrder.flix` … 画面全体の層の表（場面・縁の枠・確認の窓の前後）。新しい層はここに case を足す。
   5. `src/Controls.flix` … キーの割り当てと Doc の読み直し。Esc で終了の確認を出す（閉じるボタンは Main の `App.withCloseRequest`）。
   6. `src/render/SceneRender.flix` … 決定的な場面を PNG に描き出す（リファレンス画像）。
3. 手触り・色・絵は下の `assets/` の Doc を保存即反映でいじる。

数値・色・絵は `assets/` の Doc（保存即反映）:

- `assets/tidepool.levels.json` … 面（heights と props の 2 枚の格子・cycle・par・solution・solvedHash）。`src/LevelsDoc.flix` が読む。
- `assets/tidepool.rules.json` … 既定の満ち引き・貝殻の幅・取り消しの数など。`src/RulesDoc.flix` が読む。
- `assets/*.theme.json` … 色票。`src/ThemeDoc.flix` が読む。
- `assets/tidepool.palette.json` … Studio のドット絵エディタに「意味色キー → 実色」を教える写し（生成物）。
  つや・影のような派生色はコードで導いていて Studio からは見えないので、`make palette` で
  書き出して `*.sprite.json` の `paletteFile` から指す。手で直さない（色を変えるのはテーマ側）。
- `assets/*.sprite.json` … ドット絵（文字格子）。entityId は `<パッケージ名>.sprites`。
  絵は差し色 1 色で平らに塗り、ふち光・影は読み込み時に `PxShade` が乗せます。
- `assets/*.shader.json` … 岩・水・光の網目の塗り（画素ごとの計算）。水は沈んだマスの塊だけを型抜きで塗る。
  書き方は engine の `docs/shader-doc.md`。

それぞれに Studio 用の schema（sections 方言 / sprite は draft-07）が並んでいて、
`project.json` の `editor.resources` が宣言しています。Studio で開けばそのまま編集できます。

## 絵の開発ループ

- **画風は最初に決めて `AGENTS.local.md` に書く**。この骨組みの見た目は一例で、
  そのまま引き継ぐ物ではありません（決め方は engine の `docs/art-ref/visual-dict.md`）。
- `make render-all` で `gallery/` に決定的な PNG を描き出し、`make reference-update` で更新、`make reference-check` で防護。

## AI エージェント向け指針の配布（sync-agents）

エンジン側で `make sync-agents GAME=/path/to/このゲーム` を実行すると、エンジン共通の
エージェント指針（agents-pack/AGENTS.core.md）とこのゲームの `AGENTS.local.md` を連結した
`AGENTS.md` が生成され、共通スキルが `.claude/skills/` にコピーされます。`AGENTS.md` は
生成物なので直接編集せず、ゲーム固有の原則は `AGENTS.local.md` に書いて再 sync してください。

## 字

- しっぽり明朝（`assets/ShipporiMincho-Regular.subset.ttf`）— Copyright 2021 The Shippori Mincho Project Authors。SIL Open Font License 1.1。engine の templates/sound-novel-starter から写した subset。
