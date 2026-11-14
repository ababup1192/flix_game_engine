# A: GlContext の面が GL の考え方にどれだけ寄りかかっているか（読むだけの調査）

凡例: 【確】= ファイルを読んで確かめた / 【推】= そこから考えた

## 1. GlContext.java の分類（render_gl/java/fge/gl/GlContext.java・178 行・interface 1 つ）
合計およそ 102 本【確（数え上げは目視。±2）】。ジェネリックなし・ハンドルは全部 int・定数は GlConst（83 行）。

| 分類 | 本数 | 代表 |
|---|---|---|
| 状態の切り替え | 19 | enable/disable(cap)・viewport・scissor・blendFunc/blendFuncSeparate・colorMask・depthMask/depthFunc・stencilMask/Func/Op・cullFace/frontFace・clear*・pixelStorei |
| バッファ・頂点配列 | 13 | createBuffer・bindBuffer・bufferData(float[]/FloatBuffer/int[])・createVertexArray・bindVertexArray・vertexAttribPointer/IPointer/Divisor・enableVertexAttribArray |
| 描く | 3 | drawArrays・drawArraysInstanced・drawElementsInstanced（draw mode は TRIANGLES のみ使用） |
| テクスチャ・sampler | 21 | bindTexture・activeTexture・texParameteri・texImageArgb(Level/Zero)・texImageAlphaMask・texImageBytes・texImageRgba16fZero/Depth24/Rgba32f・texSub*・generateMipmap・texImagePlatform・copyTextureLevel0・createSampler/bindSampler/samplerParameteri |
| framebuffer・renderbuffer | 13 | bindFramebuffer・framebufferTexture2D/Renderbuffer・checkFramebufferStatus・blitFramebuffer・useNoColorBuffer・renderbufferStorage(Multisample) |
| シェーダー・program | 14 | createShader・shaderSource・compileShader・getShaderi・linkProgram・useProgram・getUniformLocation |
| uniform | 9 | uniform1i/1f/2f/3f/4f・uniform1fv/2fv/3fv・uniformMatrix4fv（location は int・-1 は何もしない） |
| 読み戻し | 1 | readTextureArgb（texture を名指す・ARGB の int 列）。即時の glReadPixels は interface に無い |
| 問い合わせ・機種の差 | 3 | getInteger（実際に引くのは MAX_SAMPLES・MAX_TEXTURE_SIZE だけ）・hasAlphaToOne・prefersGpuMipmap |
| 直接バッファの借り貸し | 6 | alloc/free × Floats/Ints/Bytes |
| タイマー | 0 | GlContext には無い（GpuTimer.flix は別。未確認【推】） |

【確】既にある「機種差の吸収」は意図の名前の関数になっている: texImageArgb（BGRA 8888_REV が WebGL2 に無い）・texImageAlphaMask（R8+swizzle か ALPHA か）・readTextureArgb・prefersGpuMipmap・copyTextureLevel0・texImagePlatform・hasAlphaToOne。WebGPU はここを同じ方針で足せる。

GL 的な寄りかかり（【確】interface の宣言から）:
- 「今 bind している物」に対して働く関数が大半: bindBuffer→bufferData、bindTexture→texParameteri/texImage*/generateMipmap、bindFramebuffer→framebufferTexture2D/useNoColorBuffer、activeTexture→bindTexture、useProgram→uniform*。texImage* 系は doc に「今 bind している TEXTURE_2D へ」と明記（texImageArgb・Alpha・Bytes・Rgba16fZero・Depth24・Rgba32f・Zero）。
- 描画状態（blend/depth/stencil/cull/scissor/viewport/colorMask）は 1 つずつ個別に set する機械。WebGPU では RenderPipeline に固めて作る物。
- uniform を 1 つずつ入れる（uniform buffer ではない）。location 名引き。
- program は実行時に GLSL を compile/link（GlContext 内に shaderSource）。WebGPU は WGSL・pipeline 作成。
- renderbuffer（MSAA・深度ステンシル）と blitFramebuffer（resolve）が API に出ている。

## 2. 実装 3 つ
| 実装 | 場所 | 行数 | 作り方 |
|---|---|---|---|
| LwjglGl | render_gl/java/fge/gl/LwjglGl.java | 172 | `GL11.glXxx(...)` 等へ 1 行ずつ素通し（GL11/12/13/14/15/20/30/31/33）。BGRA+8_8_8_8_REV で ARGB を直に上げる・R8+TEXTURE_SWIZZLE_RGBA・DEPTH_COMPONENT24 が例外的に中身を持つ（72・87-90・103 行） |
| RecordingGl | render_gl/java/fge/gl/RecordingGl.java | 168 | inner へ委譲する包み。1 呼び出し = 1 行の文字列（引数と戻り値。buffer は長さ+CRC32、シェーダーは長さ+ハッシュ）を StringBuilder へ。markFrame/drainLog/setEnabled。interface に足すとここも足さないと javac が落ちる |
| WebGl2 | engine_web/java/fge/web/WebGl2.java | 451 | TeaVM JSO。`@JSBody(params, script="fgeGl.xxx(...)") private static native` + 公開メソッドの 2 行セット。GL の物（WebGLTexture 等）は engine_web/js/fge-web.js（1523 行）の `fgeH` 配列に置き、Java へは int のハンドルだけ（`fgeNew(obj)`/`fgeFree(id)`・0=null）。getUniformLocation は (program,name) ごとに 1 つの int（無ければ -1）。wasm-gc では JS の物を Java の欄/Object に持てないので表を JS 側に置く（クラス冒頭の WhyNot） |

WebGl2 のバッファの写し方【確】:
- float[]/int[] → `Float32Array.copyFromJavaArray` / `Int32Array.copyFromJavaArray`（毎回コピー）。
- FloatBuffer/IntBuffer/ByteBuffer → direct でなければ direct にコピー → `Float32Array.fromJavaBuffer(whole(direct))`（頭から capacity までの view）+ position を from として JS へ渡し `gl.bufferData(t, data, usage, from, count)`。count==0 は bufferData(size 0) に分ける（WebGL2 は length 0 を「最後まで」と読むため）。
- ARGB int 列 → JS 側で RGBA バイトへ並べ替えて RGBA8 に上げる（texImageArgbView）。
- 読み戻し: direct IntBuffer を作って JS が埋め、Java の int[] へ get（readTextureArgb。JS 側 fgeReadGlTextureArgb は FBO に付けて readPixels・FBO 不完全なら透明な黒+警告・fge-web.js:100-112）。
- alloc*: allocateDirect（free は何もしない・GC 任せ）。
- 【推】JSBody 1 本ごとに wasm↔JS 境界を越える。呼び出し数がそのまま境界の回数。WebGPU は 1 コマの命令をまとめて渡す形のほうが得。

## 3. Flix 側の呼び出し
注: refactor は Java メソッドの呼び出しを引けないので .flix に grep（変数名は全て `gl`。`gl.xxx(` を数えた。他の名前の呼び出しは 97 件の `gl` 以外に無し）。合計 779 呼び出し（render_gl/src + engine_web/src）。engine_world・engine_tools・bench・templates からは 0。

ファイル別の上位（本数）:
| 順 | ファイル | 本数 |
|---|---|---|
| 1 | render_gl/src/Sprite.flix | 238 |
| 2 | render_gl/src/Render3d.flix | 166 |
| 3 | render_gl/src/Render3d/Material.flix | 71 |
| 4 | render_gl/src/Shader.flix | 64 |
| 5 | render_gl/src/Target.flix | 58 |
| 6 | render_gl/src/Render3d/Shadow.flix | 54 |
| 7 | render_gl/src/Render3d/Light.flix | 30 |
| 8 | render_gl/src/RenderTexture.flix | 24 |
| 9 | render_gl/src/Frame.flix | 18 |
| 10 | render_gl/src/Paint.flix | 15 |
（続き: Render3d/DataTexture 14・engine_web/src/WebAssets 6・LwjglLayer 4・GlyphGrow 4。Render3d/Batch/Instancing/JointTexture/Counts/ScenePlan/Preload は 0=gl を直に持たない）

メソッド別の上位: uniform1i 48・getUniformLocation 42・bindVertexArray 41・uniform1f 34・bindBuffer 34・texParameteri 31・enableVertexAttribArray 31・vertexAttribPointer 30・bindTexture 29・useProgram 28・activeTexture 28・disable 27・uniform2f 20・enable 20・uniform3fv 17・bufferData 15・bindFramebuffer 15。描くのは drawArrays 8・drawArraysInstanced 3・（drawElementsInstanced は 3D 側）だけ。draw の入口が少ない（【推】WebGPU の移植面は小さい。逆に状態設定の本数が多い）。

「前の呼び出しが残した状態」に頼る代表 5 例【確】:
1. render_gl/src/Sprite.flix:89-95, 268-272 — 「テキスト以外は 0 にして GL state 持ち越しを防ぐ」「静的レンジ描画が設定した値が持ち越されないよう毎 draw call で明示リセット」。同じ program の uniform が前の draw のまま残る前提を、毎回の上書きで抑えている。
2. render_gl/src/Sprite.flix:36-44（applyBlend）— 「呼んだ後の描画から効く」。blend は書いた場所から後ろ全部に効く状態。WebGPU では blend は pipeline の一部（Normal/Add/Multiply で pipeline が分かれる）。
3. render_gl/src/Sprite.flix:515-533（drawShaderSurfaceMasked）と 656-674（drawSpriteMasked）— enable(STENCIL_TEST)→stencilMask/Func/Op→colorMask(false)→描く→戻す→「後始末（次の描画にステンシル状態を持ち越さない）」。状態の push/pop を手でやる。
4. render_gl/src/Frame.flix:435-446, 846-859, 921 — clip で scissor を enable/disable、viewport と scissor を描き先ごとに set。次の描きがそれを前提にする。Render3d.flix:430-432, 471-476, 504-510, 597-612 も viewport/scissor/blend/depthMask/depthTest/cull を毎回並べて set（3D の Pass の頭で全状態を明示している）。
5. render_gl/src/Target.flix:65-75, 97-101, 121-127, 143-160 と Render3d/Shadow.flix:124-136, 151-184 — bindFramebuffer(…,fbo)→描く→bindFramebuffer(…,0)/戻す。Shadow は activeTexture(TEXTURE0+n) して bindTexture して activeTexture(TEXTURE0) に戻す対になっている（Shadow.flix:124/134, 224/226、Render3d.flix:510, 582）。今の unit・今の FBO が暗黙の引数。
- 補: bindVertexArray(vao)…bindVertexArray(0) の括りが Sprite.flix に 20 回超。bindBuffer(ARRAY_BUFFER, vbo)→bufferData→bindBuffer(…,0) も同様。
- 補: 「あえて全部明示しているので持ち越しに頼らない書き方」も多い（Render3d の Pass の頭）。ここは WebGPU の pipeline 化で素直にまとまる可能性（【推】）。逆に Sprite の uniform の持ち越し抑止は、WebGPU では毎 draw に uniform/bind group を作る形に自然に変わる。

## 4. GlConst の定数のうち WebGPU に同じ物が無さそうな物
GlConst は 83 行・約 80 定数。実際に Flix から使われる定数は約 40（上の頻度表）。
- 【確】描く形は TRIANGLES のみ（LINES・POINTS・LINE_WIDTH・POINT_SIZE の定数は GlConst に無い）。線の太さ・点は既に使っていない = 問題なし。
- 即時の glReadPixels: interface に無い。readTextureArgb が代わり（WebGPU は copyTextureToBuffer + mapAsync で非同期。同期の戻り値で返す今の形は崩れる【推】）。GlReadback.flix・Render3d/Material.flix:277 が呼ぶ（その他の呼び手は未調査）。
- 状態の個別 set: BLEND/DEPTH_TEST/STENCIL_TEST/CULL_FACE/SCISSOR_TEST の enable/disable、SRC_ALPHA 等の blend 因子、NEVER/LESS/EQUAL/ALWAYS・KEEP/REPLACE（pipeline の固定の値へ）。SCISSOR は pass 内の setScissorRect で残るが「無効にする」操作は無い（全面の scissor を set）。
- 【推】STENCIL: WebGPU にもあるが ref/mask の渡しが setStencilReference で別。stencilMask の読み書き分離は writeMask/readMask で pipeline 側。
- COLOR_BUFFER_BIT|DEPTH_BUFFER_BIT|STENCIL_BUFFER_BIT の clear(mask) と clearDepth/clearStencil: WebGPU は pass の loadOp/clearValue（pass 開始時のみ）。pass の途中で clear（Sprite.flix:515 の stencil clear）は「pass を切る」か別の描き方が要る。
- UNPACK_ALIGNMENT/PACK_ALIGNMENT/pixelStorei: 無い（bytesPerRow は 256 の倍数が要る別の制約が出る）。
- FRAMEBUFFER/READ_FRAMEBUFFER/DRAW_FRAMEBUFFER/RENDERBUFFER/FRAMEBUFFER_COMPLETE/checkFramebufferStatus: 無い（render pass の attachments。不完全という状態が無い）。MAX_SAMPLES も無い（WebGPU の MSAA は 1/4 のみ）。renderbufferStorageMultisample+blitFramebuffer の resolve は resolveTarget。
- ELEMENT_ARRAY_BUFFER/ARRAY_BUFFER の target・STATIC_DRAW/DYNAMIC_DRAW: usage ビット（VERTEX/INDEX/COPY_DST）へ。bufferData の「丸ごと差し替え（orphaning）」は writeBuffer か新しい buffer（Sprite.flix の drawPolygonBatch が orphaning に頼る）。
- TEXTURE_WRAP_S/T の REPEAT/CLAMP_TO_EDGE・MIN/MAG_FILTER・NEAREST/LINEAR・LINEAR_MIPMAP_LINEAR・TEXTURE_BASE_LEVEL/MAX_LEVEL・TEXTURE_COMPARE_MODE: sampler の記述子（mipmapFilter が別・WebGPU に mirror-repeat/clamp/repeat はある・base/max level は view の範囲へ）。texParameteri が texture に付く GL の形（sampler 別 object もある: createSampler）は WebGPU の sampler と合う。
- テクスチャの形式: RGBA8・RGBA16F・RGBA32F・DEPTH24（+STENCIL8）・ALPHA/R8+swizzle・RGB（3 バイト画素 texImageBytes）。【推】WebGPU 側: rgba8unorm・rgba16float・rgba32float（filterable でない＝NEAREST 固定は今と同じ事情）・depth24plus(-stencil8)・r8unorm（swizzle は無い→シェーダーで .r を .a に読み替え）・RGB 8 ビット（3 成分）は形式が無い→ CPU で RGBA へ拡げて上げる。DEPTH24 は depth24plus で「24 ビットの保証が無い」ので depth32float 等へ。BGRA の上げ（ARGB int）は CPU で並べ替え（今 WebGL2 がやっている形）。
- SAMPLE_ALPHA_TO_COVERAGE/TO_ONE（hasAlphaToOne）: alpha-to-coverage は pipeline の multisample.alphaToCoverageEnabled。TO_ONE は無い（WebGL2 と同じ）。
- CW/BACK/frontFace/cullFace: pipeline の primitive.frontFace/cullMode。
- uniform の location（-1 で無視）・getUniformLocation の名前引き・program の COMPILE_STATUS/LINK_STATUS/InfoLog: 無い（bind group の layout・WGSL の compile メッセージは非同期の getCompilationInfo）。
- getInteger(MAX_TEXTURE_SIZE) → device.limits.maxTextureDimension2D。
- 頂点: vertexAttribIPointer/vertexAttribDivisor/enableVertexAttribArray → vertexBufferLayout（stepMode: instance）。VAO は無い（pipeline + setVertexBuffer）。bindVertexArray の括りは消える。

## 5. RecordingGl / GlCallLog.flix を使う検査
GlCallLog.flix（render_gl/src/GlCallLog.flix・53 行）= デスクトップが GlContext を作る口。環境変数 FLIX_GE_GL_LOG=<ファイル> の時だけ LwjglGl を RecordingGl で包み、頭の FLIX_GE_GL_LOG_FRAMES コマ（既定 6）をファイルへ控える。LwjglLayer.flix:411 と GlOffscreen.flix:105 が呼ぶ。控える間は起動画面を止める（Splash.flix:49-54）。
【確】これを使う make の口・テストは無い（Makefile・bin/*.sh に FLIX_GE_GL_LOG は 0 件）。人が手で「描く手順を替える前と後で呼び出しの並びを比べる」ための道具で、機械の門ではない。

RecordingGl を使う自動のテスト【確】（render_gl/test/Render3dFakeGl.flix・181 行が java.lang.reflect.Proxy で GlContext の偽物を作り、呼び出しの名前と一部の引数を Ref に溜める。RecordingGl を import するが実際の包みの使い方はこの偽物の方）:
| テスト | @Test 数 | 控えを見る箇所 |
|---|---|---|
| TestRender3dInstancing.flix | 19 | 16 参照（instanceData/Widths/Binds/Bases/Counts・usedPrograms） |
| TestRender3dJointTexture.flix | 24 | 11 参照（allocated/uploaded/uploadWidths・jointBinds・targets・texParams） |
| TestRender3dGpuMipmap.flix | 12 | 2 参照（calls・booleans で prefersGpuMipmap を真にする） |
| TestRender3dBatch / Sun | 29 / 10 | 控えは見ない（Render3dFakeGl の場面組みだけ使う） |
| TestRender3dPreload | 21 | 見ない（GlContext の偽物を別に使うかは未確認） |
→ GL の呼び出しの並び/引数を直に比べるテストは 3 ファイル・約 55 本のうち 29 参照程度【推:数は粗い】。「3D の joint/instance データ用のテクスチャへ何を何行上げたか」「どの unit に貼ったか」という内容が中心。WebGPU 版の同じ検査は使えない（API が違う）。ただしこの検査の中身は「Render3d が上げるデータの値・unit・順序」で、描き手の計画（Batch/Instancing/JointTexture の純粋な部分）の検査に寄せ直せる可能性が高い【推】。

Makefile の他の検査【確】:
- `gl-parity`（Makefile:345 → bench/gl_parity の `make run`）: 隠しウィンドウで同じ scene 宣言を GL と SoftRaster（CPU）の両方で 1 コマ描き、画素を突き合わせて 1 scene 1 行の表。A 段階=バイト一致、B 段階=許容差（Scenes.toleranceOf）、3D の光の式は 8 bit に丸める前の値で比べる（E 段階）。上限を超えれば exit 1。→ GL の呼び出しは見ない・画素だけ。WebGPU も SoftRaster との画素比較として同じ枠で使える（B 段階の許容差の調整は要る【推】）。
- `gl-capture-check`（Makefile:451・bin/gl-capture.sh）: テンプレの場面を実機の GL（隠しウィンドウ・FLIX_GE_FIXED_DT）で頭の 6 コマ撮って PNG の SHA-256 を控え、同じ場面を 2 回撮ってバイト一致を見て、基準（bench/baseline/0.88.4/gl-capture.sha256）とも比べる。→ 同じ機械・同じ描き手の自己一致のみ。WebGPU 用には別の基準を持てば同じ形で使える（機械・ドライバ依存）。
- `determinism`（Makefile:437・bin/determinism.sh）: テンプレを隠しウィンドウの DEBUG で台本を流して記録（フレームごとの指紋+World 全体の要約）を書き、画面なしで再生して同じか見る。→ 描画に依存しない（World の決定性）。WebGPU を入れても影響なし【確】。
- 補: `baseline-check`（Makefile:416）は gl-parity の行と絵の SHA と 3D の部屋の CPU の絵を基準と比べる。`shader-cache-soak`（Makefile:356）はシェーダープログラムのキャッシュの上限（GlContext を使う）。どちらも GL の API を呼ぶ口の上に載るので WebGPU 版は別に要る。
- 結論: 「GL の呼び出しの並びをそのまま比べている機械の門」は 0 本。呼び出しの並びの検査は Render3d の単体テスト（3 ファイル）と手作業用の FLIX_GE_GL_LOG だけ。門は画素（gl-parity・gl-capture-check）か World（determinism）で比べるので WebGPU でも流用できる。

## 6. WebGPU 設計への含意（推）
- 呼び出しの入口は draw 3 本・pipeline の状態は ~19 本の set・uniform 9 本 + 名前引き。Sprite.flix（238）と Render3d.flix（166）で 5 割強。ここに「状態を持つ機械」の考えが集中している。
- GlContext をそのまま WebGPU で実装するより、Draw2d/Draw3d（Platform.Services の高さ）で切る方が自然（docs/flix-conventions.md:202,204 の既存の方針とも合う）。
- シェーダーは GLSL で書かれている（Render3dGlsl.flix 579 行・Shader.flix 534 行）。WGSL への変換（または並行の生成）が最大の別の仕事。
- 同期の readTextureArgb（Material.flix:277・GlReadback）は WebGPU で非同期になる。呼び手の洗い出しが要る（refactor usages で）。
