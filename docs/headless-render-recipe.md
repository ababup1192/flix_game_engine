# ヘッドレス描き出しの最小レシピ

**ここで言う「ヘッドレス描き出し」**は、実ウィンドウ（GLFW/OpenGL）を開かずに、場面を PNG 連番と
GIF へ描き出すこと。テスト・CI・見た目の確認、どれもこれで足りる。新しい場所（リポジトリの
外の `/tmp` でも、このリポジトリの `scratch/` の下でも）に最小構成を組むときの写経元がこの
1 ページ。Makefile や templates を読み歩かなくても、ここだけ読めば組める。

このレシピは 2 つの実例を検証済みの正として写した:

- `github:ababup1192/flix_game_engine` を丸ごと 1 依存として借りる形
  （`/tmp/probe_bonfire` で実際に描き出せることを確認済み）
- `flix_engine_core` / `flix_engine_world` / `flix_engine_tools` を個別に借り、
  `flix test` の中から `HeadlessRender.renderGif` を直接呼ぶ形（`scratch/field_walk_demo`）

どちらも中身は同じ 4 手（依存を借りる・フォントを 1 本置く・場面を作る・描き出して確認する）。

## 1. ディレクトリ構成（最小）

```
my_render/
  flix.toml
  bin/flix        # リポジトリの外に組むときだけ要る（後述）
  Makefile         # 任意。無くても flix run で描き出せる
  assets/
    Xolonium-Regular.ttf   # フォント本体（後述）
  src/
    Scene.flix     # 場面（絵の中身）
    render/
      SceneRender.flix # entrypoint（SceneRender.all）
      Gallery.flix     # 描き出しの設定 + renderGif 呼び出し
```

## 2. flix.toml — 依存の借り方

一番簡単なのは、このエンジンを丸ごと 1 依存として借りる形:

```toml
[package]
name        = "my_render"
description = "何を描き出す場面か、一言"
version     = "0.1.0"
flix        = "0.75.1"
authors     = ["you <you@example.com>"]

[dependencies]
"github:ababup1192/flix_game_engine" = { version = "0.19.0", security = "unrestricted" }
```

`version` は書いている時点の最新に読み替える（`flix.toml` の直下、このリポジトリ自身の
`[dependencies]` を見れば分かる）。個別のパッケージ（`flix_engine_core` /
`flix_engine_world` / `flix_engine_tools`）を要るぶんだけ借りる形でもよい
（`scratch/field_walk_demo/flix.toml` が実例）。どちらでも `HeadlessRender` / `HeadlessFont` /
`Render` などの語彙は同じように使える。

依存の実体（jar）は `flix build` や `flix run` を初めて走らせたときに `lib/` の下へ
自動で降ってくる。**`lib/` は自分で作らない・中身を手で置かない** — 空でよいので
`.gitignore` に入れておく。

## 3. フォント 3 点セット

`Text` を 1 文字でも描くなら（描かない場面はまず無い）、フォントが要る。要るのは 3 つだけ:

1. **TTF 本体**を 1 本、`assets/` に置く（Xolonium 等。このリポジトリの
   `templates/game-starter/assets/Xolonium-Regular.ttf` を丸ごとコピーしてよい）
2. `HeadlessFont.buildAtlas("ui", ttfPath)` を呼んで `FontAtlas` を作る
   （GL が無くても Java2D の `FontMetrics` だけでメトリクスを測る。グリフ画像そのものは
   bake しない — 実描画は `SoftRaster` が出力解像度で直接 `drawString` するので不要）
3. その `FontAtlas` を `RenderConfig#fontAtlas` に、TTF パスを `RenderConfig#fontTtf` に渡す

```flix
let atlas = HeadlessFont.buildAtlas("ui", "assets/Xolonium-Regular.ttf");
```

## 4. 場面を作る（Scene）

`Render.PlacedItem` のリストを返す関数を 1 つ用意すれば場面になる。最小形:

```flix
mod Scene {
    pub def design(): Vec2.Vec2 = { x = 320.0, y = 240.0 }

    pub def itemsAt(t: Float64): List[Render.PlacedItem] =
        Render.vgrad(design(), { top = Color.rgb8(16, 18, 42), bottom = Color.rgb8(35, 44, 85) }, 0)
            |> (bg -> { at = { x = 0.0, y = 0.0 }, item = bg })
            :: Nil
}
```

絵を書く前に `docs/art-ref/visual-dict.md` を引く（このレシピの範囲外。絵の下限 5 性質は
[docs/drawing-floor.md](drawing-floor.md)）。

## 5. 描き出しの設定 + HeadlessRender 呼び出し

```flix
// src/render/Gallery.flix
mod Gallery {
    def scale(): Int32 = 2
    def ttfPath(): String = "assets/Xolonium-Regular.ttf"

    def config(atlas: FontAtlas): HeadlessRender.RenderConfig =
        { design = Scene.design(), scale = scale(), background = Color.rgb8(16, 18, 42),
          texturePath = Map.empty(), fontTtf = ttfPath(), fontAtlas = atlas,
          outDir = "gallery", frameW = 320 * scale(), frameH = 240 * scale(),
          gifDelayMs = 110, gifFps = 9 }

    // 描き出す時刻の並び。乱数や実時間に依存させない（決定的な場面にする）。
    def timeSteps(): List[Float64] = List.range(0, 12) |> List.map(i -> Int32.toFloat64(i) * 0.15)

    pub def renderAll(): Unit \ IO =
        let atlas = HeadlessFont.buildAtlas("ui", ttfPath());
        let toCmds = t -> Render.draw(Scene.itemsAt(t));
        discard HeadlessRender.renderGif(config(atlas), timeSteps(), 1, toCmds, "my_scene");
        println("描き出しました: gallery/my_scene.gif, gallery/frames/my_scene/0..11.png")
}
```

```flix
// src/render/SceneRender.flix — entrypoint
mod SceneRender {
    pub def all(): Unit \ IO = Gallery.renderAll()
}
```

`HeadlessRender.renderGif` が RasterReq 組み立て・SoftRaster 呼び出し・GIF エンコード・コマ別 PNG
書き出しを全部やる（`engine_tools/src/HeadlessRender.flix`）。呼ぶ側が用意するのは
「1 回だけ宣言する設定」と「時刻 → 描画コマンド」の投影だけでよい。

## 6. リポジトリ内 vs リポジトリ外の差分

| | リポジトリ内（`scratch/` 等） | リポジトリ外（`/tmp` 等） |
|---|---|---|
| `flix.toml` の依存 | 個別パッケージ（`flix_engine_core` 等）を相対で借りてもよい | `flix_game_engine` を GitHub 経由で丸ごと借りる |
| フォント | 既存の `templates/*/assets/*.ttf` を相対パスでそのまま使い回してよい（コピー不要） | `assets/` に TTF を 1 本コピーして持つ（借りる先が無い） |
| flix コマンドの実行 | リポジトリ直下の `bin/flix`（devbox の flix.jar を自動で見つける）をそのまま使う | `bin/flix` を自分の場所にも置く（`/tmp/probe_bonfire/bin/flix` を丸ごとコピーしてよい。devbox / PATH の flix / 手元の `bin/flix.jar` の順で jar を探す） |
| 描き出しの入口 | `@Test` の中から `HeadlessRender.renderGif` を直接呼ぶ形でもよい（`scratch/field_walk_demo/test/` のテスト）。描き出したファイルが実在するかを検査する煙テストにできる | `SceneRender.all()` を entrypoint にして `./bin/flix run --entrypoint SceneRender.all` |
| git | `scratch/` はリポジトリの `.gitignore` で丸ごと除外済み。描き出した PNG/GIF も気にせず作れる | 好きに使い捨てる場所（`/tmp` 等） |

## 7. 実行コマンド

entrypoint 形式（`SceneRender.all` を用意した場合）:

```bash
./bin/flix run --entrypoint SceneRender.all
```

テスト形式（`@Test` の中で描き出す場合、リポジトリ内なら）:

```bash
../../bin/flix test    # scratch/<name>/ から見て repo 直下の bin/flix
```

`make` を使うならこれだけの Makefile で足りる:

```makefile
.PHONY: render check
render:
	./bin/flix run --entrypoint SceneRender.all
check:
	./bin/flix check
```

## 8. 描き出した後の確認

描き出して終わりにしない。人に見せる前に自分で確かめる（このリポジトリの `bin/` にある
検査は、描き出した PNG のパスさえ渡せばリポジトリ外からでも使える）:

```bash
bin/fge view path/to/my_render/src/render/Gallery.flix   # 矩形と円だけになっていないか
bin/fge digest gallery/my_scene.png                       # 目視の前に数値で当たりを付ける
```

最後に `gallery/my_scene.gif` か `gallery/frames/my_scene/*.png` を実際に開いて目で見る。
絵の下限 5 性質（面に階調か質感 / 主役が背景から分離 / 層が分かれている / 時間が流れている /
形が物として読める）を満たしているかは、機械では最後まで判定できない。造形が怪しいときは
`HeadlessRender.silhouettePng`（シルエットの描き出し — 対象を黒・背景を白）で形だけを取り出して見る
（写経例は [docs/drawing-floor.md](drawing-floor.md)）。
