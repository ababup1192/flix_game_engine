# 塗った PNG のキャッシュ（DrawHash・RenderCache）

reference-check・make compare・動画のコマで、**前に塗ったのと同じ絵は塗らずに写す**ための仕組み。
1 枚の塗り（SoftRaster → PNG）は 200 ms 前後かかるが、描く命令を組んでハッシュを取るのは 10 ms 前後で済む。

- `DrawHash.computeKey`（engine_tools・純粋）: 1 コマの描く命令と、命令に出ない描き出しの入力を 1 本の SHA-256 に畳む。
  `computeKeyCached` は同じ鍵を、字のアトラスを畳んだバイト列を覚え（`AtlasCache`・RenderCache の Session が持つ）から
  引いて作る（数千字のアトラスをコマごとに畳むと、それだけで鍵の時間の大半を占める）
- `RenderCache`（engine_tools・IO）: その鍵で、塗った PNG を `~/.cache/flix-render-cache/` にキャッシュに入れる。
  同じ鍵が来たら塗らずに PNG を写す（バイト列は塗った時と同じ）
- 塗る道（SoftRaster）は残る。鍵を作れない時（下の「鍵を作らない時」）は今まで通り塗る

## 誰が通るか

| 口 | 何もしなくても効くか |
|---|---|
| `SoftRaster.render` / `renderFonts` / `renderWithSurfaces` / `renderFull`（= `HeadlessRender.renderPng*`） | **効く**。雛形の render-all はこの口なので直さなくてよい |
| 動画・自前のギャラリーで `Filmstrip.renderFrame(SoftRaster.renderToImageCached(…), path)` と書いている所 | 効かない。下の `RenderCache.writeFramePng` へ置き換える |
| `HeadlessRender.renderGif*` | 効かない（GIF を組むのに全部のコマの画像が要る） |

```flix
// コマ列（動画 1 本）の前に 1 本作って持ち回る（ファイルの指紋を 1 回だけ読む）
let session = RenderCache.freshSession();
// …コマごとに（引数は SoftRaster.renderToImageCached と同じ + session。書き先は req#outPath）
RenderCache.writeFramePng(session, req, surfaces, extraFonts, Map.empty(), warnLog, textures);
// …終わったら
println(RenderCache.statsLine(session))   // [render-cache] 塗った 12・写した 940・鍵なしで塗った 0（置き場 …）
```

`writeFramePng` は `Filmstrip.renderFrame` と同じバイト列（256 色以下なら PNG-8）、`SoftRaster.render*` は今まで通りのフルカラー。

## 鍵の中身

1 つでも抜けると「絵が変わったのに同じ」と言う偽の緑になる。抜けは型で止める:
`DrawHash` は描き出しの入力の record を**閉じた形で全部の欄を名前つきで** match し、enum は全引数で受ける。
`RasterReq`・`SurfaceCmd`・`FontEntry`・`FontAtlas`・`GlyphMetrics`・`PolygonRenderCmd`・`Drawable`・`BoxStyle` に
欄を足すと `DrawHash.flix` がコンパイルで止まる。鍵と塗りは `RenderCache.writePng` の 1 か所で同じ値から作る。

| 入れる物 | どう入れるか |
|---|---|
| 描く命令: `Drawable` の全欄（テクスチャ名・位置・倍率・傾き・色・濃さ・中心・UV・z・style・clip・blend・mask） | 値そのまま（Float64 はビット列。**丸めない**） |
| `PolygonRenderCmd` の全欄（`grad` の `None` と `Some(Nil)` は別の物） | 値そのまま |
| シェーダー面 `SurfaceCmd`（置き場・Spec・時刻・mask・z・blend） | Spec は `ShaderJson.toJson` の字（往復テストのある正規の形） |
| 描き出しの設定（design・scale・背景・`shapeAntialias`・`textAntialias`） | 値そのまま |
| テクスチャ（そのコマの命令が引く名前だけ） | 名前 + 塗る時に使う `TextureCache` の中の画像の画素の SHA-256（パスは入れない — compare の基準は別の場所の worktree。画素は塗りと同じ物を見るので、読む間に保存されても鍵と絵がずれない） |
| フォント（`fontTtf` の中身・`fontAtlas`・`extraFonts` の名前・TTF の中身・atlas） | TTF はファイルの中身の SHA-256（session で 1 回）、atlas は全欄 |
| pass などの描き出し済み画像（`extraImages`。命令が引く名前だけ） | 画素の SHA-256（型・幅・高さつき）。Keep で前のコマを持ち越す絵もこれで拾う |
| SoftRaster の版 | エンジンの fpkg（flix.toml が指す版）の中身の SHA-256。`packages.lock` の記録（`fpkg = "sha256:…"`）があればそれを、無ければゲームの `lib/` にある fpkg の中身から取る。jar を取ってきて `lib/` の無い作業場（`bin/fge jar`）でも、lib のある作業場と同じ鍵になる。JVM の中で 1 回だけ取り、lock か fpkg が JVM の起動より新しければ鍵を作らない（起動したままのゲームの裏で組み直した時に、古いコードの絵を新しい鍵でキャッシュに入れない） |
| JVM と OS | `java.vendor`・`java.runtime.version`・`java.vm.version`・`os.name`・`os.version`・`os.arch`・`java.awt.headless`・`sun.java2d.uiScale`・JVM の起動旗（Java2D の文字と縁は JDK・OS・旗で変わりうる） |
| PNG の書き方 | `Plain`（SoftRaster.render*）と `Filmstrip`（PNG-8 にしうる）は別の鍵 |

入れない物: 書き先のパス（`outPath`）・欠け名の控え（`warnLog`）。どれも画素に効かない。
命令が引かないテクスチャも入れない（画像 1 枚の描き直しで、それを使わない絵まで塗り直さない）。

鍵だけ欲しい時（ゲームの側で同じ絵をまとめる・調べる）は `RenderCache.keyOf(session, encoding, frame, extraImages, textures)`。
writeFramePng と同じ鍵が返る（指紋の取り方を写さない）。

### 鍵を作らない時（いつも塗る）

- `FGE_RENDER_CACHE=off`（または `0`）
- エンジンの fpkg が見つからない（エンジンのリポの中で足元のソースから組んで流す時。flix.toml に依存の行が無い）
- TTF のファイルが読めない（無いファイルは「無い」として鍵に入る。読めない時だけ鍵を作らない）
- エンジンの fpkg（か、記録を取った packages.lock）が JVM の起動より新しい
- 鍵づくりで例外が出た（シェーダーの Spec に NaN がある等）
- `FGE_RENDER_CACHE` が相対パス

どれも理由ごとに JVM で 1 回だけ `[render-cache] …` を出して、塗って続ける。

### 突き合わせ（verify）

`FGE_RENDER_CACHE=verify`（置き場を変えているなら `verify:<絶対パス>`）はキャッシュを写さず毎回塗り、同じ鍵のキャッシュがあればバイト列を突き合わせる。
違えば `[render-cache] キャッシュと塗った絵が違う` を出して塗った方で置き換える（鍵に入っていない入力があるという印）。
**`make reference-update` はいつもこれで流れる**（写した絵を基準として固めない）。
キャッシュには塗った画像を符号化したバイト列を直接入れ、書き先はそこから写す（書き先を読み直してキャッシュに入れない）。

## 置き場

- `FGE_RENDER_CACHE`（既定 `~/.cache/flix-render-cache`・絶対パスだけ）。1 枚は `<置き場>/<鍵の頭 2 字>/<鍵>.png`
- 鍵に絵に効く物が全部入っているので、作業場・worktree・ゲームをまたいで共有してよい（compare の基準と今で共有するのが狙い）
- 写すたびに時刻を今にする。`bin/fge render-cache prune [--max-mb N]`（既定 4096 MB）が古い順に消す。
  reference-check と compare の終わりに自動で流れる。消すのは鍵の形のファイルと 1 時間より古い書きかけだけ。様子は `bin/fge render-cache status`

## compare の基準の写し

`make compare` は、基準のコミット・基準側のエンジンの fpkg の中身・エンジンの mk と headless-run と fge-go の中身・描く口・
lib/external と lib/cache の名前と大きさと時刻・描き出しが使う java（`$JAVA` → PATH）と ffmpeg の版・描き出しが読む環境変数
（基準の Makefile・mk・src・bin とエンジンの mk・headless-run・src に出てくる名前で、今値がある物）が同じなら、前に描いた基準の出力（`~/.flix_ge_studio/compare-cache/`、新しい方から 20 個）を使い、
基準の worktree も描き出しも飛ばす。基準の描き出しに失敗した口があった回は取っておかない。`FGE_COMPARE_NO_CACHE=1` で使わない。

## 決まっている割り切り

- 1 本の動画の中で同じ絵をまとめる・座標を丸めて近い絵を同じに扱う、はしない（丸めは偽の緑になる）
- TTF は鍵（session の最初に読んだ中身）と塗り（`Font.createFont` が毎回読む）が別に読む。描き出しの最中に TTF を
  保存し直すとずれうる（テクスチャは塗りと同じ画像から指紋を取るのでずれない）
- reference-check と compare が「同じか」を決めるのは今まで通り PNG のバイト列。ハッシュは塗りを省く所にだけ効く:
  基準（reference の PNG・前の版の動画）の側にハッシュを書き残す代わりに、塗った時に鍵 → PNG をキャッシュ、
  次に同じ鍵が来たら写す。こうすると gallery/ と動画のコマは毎回そろい、比べる側（reference-check.sh・compare）は直さずに済む
- 窓なしのゲームの常駐・GPU で塗る所はここでは扱わない
