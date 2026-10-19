# デバッグと描き出し（F8・外からの操作・目録・ヘッドレス）

> [docs/module-index.md](../module-index.md) の分野の 1 つ。1 行 = 1 件で、`make module Q=<語>` が行ごとに引く。
> 型と引数は `make api Q=<名前>`、使い方は `engine_world/src/<名前>.flix` 冒頭の doc。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| 起動中のゲームを外から操作・観測する | App.RemoteDebug |
| 好きな場面を窓なしで 1 枚撮る・起動中のゲームを動かさずに見る（会話のプレビュー） | App.Headless（ゲームの E2e.serveHeadless を bin/headless-run で）+ App.onShotRequest（`view=shot`） |
| DEBUG で起動したゲームの命令口を外から見つける | App.GameRegistry（~/.flix_ge_studio/games.json・`bin/fge talk goto` が読む） |
| Studio に「いま表示中の Doc」を名乗る（表示中バッジ） | App.withDocTable（中身は ActiveDocs。実例: `templates/tetris-starter/src/Game.flix`） |
| 好きな場面から起動する・テストと flow が場面を名前で組む | App.withStarts（START="名前 k=v"・GET /starts・POST /start・App.startOrBug。実例: `templates/tetris-starter/src/Starts.flix`） |
| 知らない名前に「もしかして」の候補を付ける | Suggest.hint / near |
| 生成した絵に出ない指定を知る（実機との食い違い防止） | SoftRaster（dropped）/ [対応表](../backend-parity.md) |
| 描き出した 1 枚に「この塊は何として描いたか」の目録を添える（材質の色の潰れ・主役の埋没を数で出す） | RenderManifest（検査を鳴らす条件は intent。実行中の矩形の記録は Annotate、UI の幾何破綻は RenderLint） |
| 走行中に生成した絵を静止画の描き出しでも同じ絵にする | HeadlessRender.imagePngs / imageTextureInfo（実例: `templates/race-starter/src/render/SceneRender.flix`） |

## モジュール 1 行紹介

- **RenderManifest** — 描き出した 1 枚の「目録」を JSON にする。1 行（Claim）は kind / material / role（4 つで閉じた enum） / layer / world 座標 / src / intent を持ち、画面ぜんたいの下地の色は design の隣にトップレベルで出る。PNG からは読めない欠陥（材質どうしの色が同じに潰れた・主役が背景に溶けた・地形が Doc と違う高さで描かれた）が数で出る。**検査は作者が intent に書いたことについてだけ動き、書かなかった行は undeclared に id を並べる**（沈黙もさせず、止めもしない）。**aabb と colors は作者の申告であって描き出した画素の計測ではない** — build が unmeasured にその断りを必ず 1 本足す。書き出し（write）は失敗を Result で返す（PaletteExport と同じ形）。
- **ActiveDocs** — 「いま表示に使っている Doc(JSON)はどれか」を debug/active-docs.json に名乗る（Studio の「表示中」バッジはこれを読む）。書くのは App.withDocTable の出力（一覧が変わった実機のフレームの後だけ）。
- **Suggest** — 知らない名前に近い名前の候補を付ける（編集距離 2 以内か頭が同じ物を 3 つまで）。flow の check・始まりの名前・台本の節の名前で使う。
- **Annotate** — 実行中のゲームを一時停止して、画面の気になる場所を矩形で囲んで記録する。App.withAnnotationContext でゲームが「その瞬間の文脈」（場面・台本の行など (見出し, 値) の並びと、層の enum の列。z の範囲は zRange から引く）を渡すと、チケットの README 冒頭と z の横に載る。App.withWorldDump を繋ぐとその瞬間の World の要約が world.json として同梱される（チケットから直す Doc を引く順: README の文脈 → annotation.json → world.json）。README では 1 字ずつ置かれた字を 1 行の文字列に束ねて出す。
- **App.RemoteDebug** — 起動中のゲームを外部プロセスが HTTP で操作・観測する口。POST /render は App.onRenderRequest で登録した「描き出しの実体」を温まった JVM で実行し、描き出したパス列を返す（プレイ状態には触れない）。`view=shot` は App.onShotRequest で今の World を 1 枚に描く。
- **App.Headless** — 窓を開かないゲーム。始まり（`talk node=… line=…` など）から組んで 1 枚撮る口を、待ち受けか 1 回きり（FGE_SHOT）で開く。セーブも記録も書かない。
- **App.GameRegistry** — DEBUG で起動したゲームの命令口の書き置き（~/.flix_ge_studio/games.json）。DEBUG_HTTP_PORT が無ければ空いたポートを自分で取って書く。
- **GameLogger** — 起きたことを 1 行ずつログに積み、あとでまとめて取り出す effect。
