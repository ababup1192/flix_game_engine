# Tetris

flix_game_engine の落ち物パズル（テトリス）テンプレート。
落ちてくるミノ（テトロミノ）を ←→ で寄せ、Z / X で回し、↓ でそっと落とし、Space で叩きつける。
横 1 列がそろうと消えて点が入る。天井まで積み上がると GAME OVER（Space で仕切り直し）。

原始的なテトリスに、NEXT（次のミノ）表示・回転で設置面にねばる猶予（lock delay）・
簡易ウォールキック・着地予測（ゴースト）・ライン消しの閃光演出を足した、読んで学べる骨格。

操作: ←→（左右に動かす）/ ↓（そっと落とす・押しっぱなしで加速）/ Z（反時計回り）・X / ↑（時計回り）/
Space（叩きつけ・GAME OVER では仕切り直し）。

## 始め方

Flix コンパイラはエンジンリポの `bin/flix` ラッパ経由で呼ぶので、devbox shell の外でも動きます。
エンジンの場所が既定（生成時に埋め込み）と違うときは `ENGINE=/path/to/flix_game_engine` を付けてください。

| コマンド | 何をするか |
|---|---|
| `make run`    | ゲームを起動する（ウィンドウが開く） |
| `make debug`  | 保存即反映(watchFile)と F8 を有効にして起動 |
| `make check`  | 型検査だけ走らせる（一番速い確認） |
| `make test`   | テストを実行する |
| `make render-all`   | ギャラリー PNG を全部描き出す（決定的な 5 場面: title / s1_start / s2_stack / s3_clear / s4_over） |
| `make render SHOT=s3_clear` | その場面だけ `debug/s3_clear.png` へ描き出す（複数は `SHOT="title s4_over"`） |
| `make reference-check`  | 描き出した絵をリファレンス画像とバイト比較する |
| `make reference-update` | いまの gallery をリファレンス画像として更新する |

## 読む順（全体像のつかみ方）

**遊ぶ → 読む → JSON をいじる** の順で仕組みが見えます。

1. まず `make run` で遊ぶ（ミノを寄せ・回し・そろえて消す）。
2. コードは **エントリ→状態→形→描画→入力→描き出し** の順で読む:
   1. `src/Main.flix` … 3 つを App に繋いで起動する目次。冒頭 doc に**ゲームループの全体像**
      （init・update・view・reloads がどれか）が書いてある。まずここ。
   2. `src/World.flix` … ゲームの状態そのものと、次の状態を作る規則（重力・移動・回転・
      接地/固定・ライン消去・涌き。すべて純粋）。冒頭 doc に**毎フレームの流れ**と
      **場面の移り変わりの図**（Playing→Clearing→Playing / Playing→GameOver）があり、
      遷移を起こす関数には doc に `[遷移: X→Y]` が付いている。まず `step`（毎フレームの更新）を読む。
   3. `src/Pieces.flix` … ミノ 7 種の形のテーブル（rot 0..3）と、簡易ウォールキックの候補。
      「どの向きのときどの 4 マスか」の知識だけがここに集まる（World を規則に集中させるため）。
   4. `src/View.flix` … 状態を絵に写す（盤・固定セル・落下中ミノ・ゴースト・NEXT・スコア・
      ライン消しの閃光を、何をどこに描くか）。
   5. `src/Controls.flix` … キーの割り当てと Doc の読み直し。規則が出した出来事（固めた・行を消した）を
      `Emit.collectInto` で World に溜め、`sounds` が前後の差（`Emit.since`）を音の名前へ写す。
   6. `src/render/SceneRender.flix` … 決定的な 5 場面を PNG に描き出す（リファレンス画像比較・目視批評）。
   7. `test/TestTrace.flix` … 性質テスト。でたらめなキー操作を画面なしで流し、「升の数 = 前の升 + 固めたミノ × 4 −
      消した行 × 10」「行を消したフレームだけ消した音が 1 回」が、どう遊んでも崩れないかを見る（`PropertyTest.forAll`）。
3. 数値と色をいじる（保存すると走行中のゲームに即反映されます）:
   - `assets/tetris.rules.json` … 落下速度・接地の猶予・得点。
   - `assets/tetris.theme.json` … 盤・枠・ミノ・閃光の色。
   - `art/sfx.snd.star` … 効果音の案の台本。`bin/fge snd build art/sfx.snd.star` で `atelier/sfx/` へ書き出す
     （採用して `assets/sfx/` と project.json の `sounds` に載せるまでは無音。鳴らすと名前ごとに 1 回 warn）。

黒箱（エンジンの部品）に出会ったら `make module Q=<やりたいこと>`（目次はエンジンリポの `docs/module-index.md`）で
`Render`（描画）・`App`（ゲームループ）・`JsonCodec`（JSON 読み）・`HeadlessRender`（PNG の描き出し）を引きます。

## いちばん小さな変え方（保存即反映）

- **落ちる速さを変える**: `assets/tetris.rules.json` の `gravityInterval` を小さく（例 0.3）すると速くなる。
- **接地のねばりを変える**: `lockDelay` を大きくすると、着地してから固定されるまで長く動かせる。
- **ミノの色を変える**: `assets/tetris.theme.json` の `colorI`..`colorL` を好きな `#rrggbb` に。
- **演出の長さを変える**: `clearDuration` を大きくすると、ライン消しの閃光が長く出る。
- **得点を変える**: `scores`（[0, 1行, 2行, 3行, 4行]）を書き換える（配列なので JSON を直接編集）。

数値の規則そのもの（落ちる・ねばる・消える）はコード（`src/World.flix`）側にあります。
Doc はあくまで「調整したい初期値の宣言」で、壊れても既定値で必ず起動します（fail-open）。
