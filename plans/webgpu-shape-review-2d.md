# WebGPU 移行の段「`DrawList` の形のレビュー（2D）」— 材料と案（第 1 版・人の了承待ち）

親は `plans/engine-webgpu.md`（以下「親」）の 9 章の表の 7 番と 9.1。V1 の文書は `plans/webgpu-v1.md`（以下「V1」）。
【確】= コードか測った値 ／【推】= 読みや割り算からの見積もり。測ったのは 2026-11-15・Apple M4 Pro・Chrome 156（ヘッドレス）だけ。

## 要約（人が読む 10 行）

1. スプライトの行は**今の形（Int32 の行・1 行 10 欄・1 体 38 個の Float32）のまま確定**し、直すのは周り 4 つだけ（GL の物と前半の状態を分ける・instance の入れ物は backend が貸す・描き先の上下は backend に聞く・`Frame.flix` から行の型と GL の流し方を `RenderFrame.Internal` の下へ出す）。
2. pass の区切りは**行にせず、列 1 本に 1 つ付ける小さな record**（描き先・clear・黒帯・history の写し）にする。`renderCommands` 1 回 = 列 1 本 = pass 1 つ、を親 5.1 で決めてあるため。
3. 「上げる行」も**行にしない**。絵や buffer を上げるのは今どおり即時の呼び出しで、GL と WebGPU の両方が受ける**上げる API（render_gl の中の effect）**に 1 本化する。WebGPU の「上げる前に submit」の決まりは backend の中に残す。
4. 列は「その場で流す」（親 5.1）を確定。コマ全体を溜める形は取らない（submit は今 1 コマ 1 回で足りている【確】）。
5. 名前は `RenderList` のまま（`DrawList` は engine_tools の `SoftRaster.Internal.DrawList` とぶつかる）。pub にはしない。
6. 速さ: PC は WebGPU が GL より速い（同じ絵 20,000 個で 0.89 倍・絵 16 種で 0.33 倍）。ブラウザの絵 16 種は 0.91 倍しか縮まない。内訳を測ると、行を流す前まで 17.3 ms（絵 1 種でも 14.1 ms かかる列の外の分を含む）・行を流す Flix の輪 4.2 ms・JS への呼び出しと絵の引き当て 8.9 ms【確】。減らせるのは形でなく、P6 の「絵をアトラスの頁にまとめる」（draw が 1 本に減る）。形はそれを妨げない。
7. 持ち越し 27 件は、形で決める物 15・R1b ⇄ P6 で種類ごとに決める物 3・形に関係ない物 9 に分けた（2 章）。
8. 入れる作業は R1b の頭の小さな段（R1b-0）。実時間 1.5〜2.5 時間【推】。門は今の画素の門と sprite_stress（PC・ブラウザ・絵 1 種と 16 種）。
9. 人に伺う事は 2 つ: 名前（`RenderList` のまま）と、親 5.1 の表から「pass の区切り」「上げる行」を行の種類から外す事（5 章）。

## 1. 並べる材料

### 1.1 GL と WebGPU の backend の行数（2D・V1 の後の main・`b10cd896`）

範囲は `bin/fge refactor outline` と `show` の行番号から数えた【確】（doc のコメントを含む）。

| 役目 | GL | WebGPU |
|---|---|---|
| 行を受けて描く | `RenderFrame.drawRenderList`〜`drawRow` 34・`setScissorAt` 21・`RenderSprite.drawSpriteInstancedBuf` 25・`applyBlend` 12 = **92** | `WebGpuRows.drawRowsFrom`〜`firstInstanceAt` 52・`scissorInto`〜`viewportTop` 37・`WebGpuPaint.pipelineOf`/`buildPipeline` 30・`instancesFor`〜`groupOf` 70 = **189** |
| pass の扱い（clear・viewport・黒帯・描き先を開く閉じる） | `renderFrameMixed` の clear 33・`RenderPaint.beginTarget` 25・`endTarget` 8・`prepareHistory` 28 = **94** | `WebGpuRows.renderFrame` 59・`needsLetterbox`〜`loadOpOf` 18・`WebGpuPaint.beginTarget` 19・encoder と submit 28 = **124**（history は無し） |
| 物の上げ下ろし（絵の表・`ensureTexture`） | `RenderPaint.ensureTexture` 40・`RenderTexture` 95 | `addSlot`〜`rewriteSlot` 139（うち V1 で GL から写した表の分 約 300 行が `WebGpuPaint` 全体に散る。V1 1.4） |
| 前半の写し | — | `emitAll`・`emitItem`・`emitPlainSprite` 36（`RenderFrame.emitMerged`・`emitOne` と同じ形の 2 本目） |
| シェーダー | GLSL 119（`RenderShader.spriteInstanced*`） | WGSL 103（`WebGpuShader.spriteWgsl`） |
| 共有の前半（両方が使う） | `Frame.flix` の `RenderList` の節 76・`pushSpriteKeyed` 34・`emitSprite` 31・`writeInstAt` 93 | 同じ物 |

- WebGPU の行を流す所が GL の 2 倍あるのは、GL が持つ状態（scissor・blend・bind した絵）を WebGPU では自分で控えて、前と同じなら積まないため（`geom` の欄 8〜13）と、scissor を描き先の中へ収める式（`scissorInto`）のため。形の差ではない。
- GL は行ごとに `bufferData` で instance を送る（GL 3.3 と WebGL2 に baseInstance が無い・`drawSpriteInstancedBuf`）。WebGPU は列 1 本ぶんを `writeBuffer` 1 回で送り、`firstInstance` で引く（`sendInstances`）。今の行（`first`・`count` を持つ）は両方の送り方をそのまま受けられている【確】。

### 1.2 ベンチ（sprite_stress・20,000 個）

PC は `bench/sprite_stress/RESULTS.md` の V1 の節と「絵 16 種の測り直し」（3 回ずつ交互・2 区間目・ms・中央値）。ブラウザの絵 1 種も同じ節。**ブラウザの絵 16 種はこの段で測った。**

| 場面 | GL frame / submit | WebGPU frame / submit | WebGPU / GL（submit） |
|---|---|---|---|
| PC・同じ絵 | 7.563 / 2.192 | 6.753 / 2.057 | 0.94 倍 |
| PC・絵 16 種（20,000 draw） | 41.039 / 35.815 | 13.524 / 5.863 | 0.16 倍 |
| ブラウザ・同じ絵（cpu も） | 33.3 / 13.5（cpu 29.4） | 33.3 / 14.1（cpu 30.0） | 1.04 倍 |
| ブラウザ・絵 16 種（cpu も）【新】 | 50 / 33.2（cpu 50.5） | 50 / 30.1（cpu 45.7） | 0.91 倍 |

ブラウザの絵 16 種の値（`make bench-web BENCH=sprite_stress BENCH_WEB_EXPORT=off ARGS='n=20000&tex=16'` と `&backend=webgpu` を交互に 3 回ずつ。測る前に `ps` で他の重い java が無い事を見た。WebGPU の回は 3 回とも `env.backend` が `webgpu: WebGPU apple metal-3 ()`。draw は 20,000・切れた理由は `texture` 19,999）:

| | 1 回目 | 2 回目 | 3 回目 | 中央値 | 幅 |
|---|---|---|---|---|---|
| WebGL2 submit / cpu p50 | 34.8 / 52.0 | 33.2 / 50.5 | 33.2 / 50.5 | 33.2 / 50.5 | 1.6 / 1.5 |
| WebGPU submit / cpu p50 | 30.1 / 45.7 | 30.1 / 45.9 | 30.2 / 45.7 | 30.1 / 45.7 | 0.1 / 0.2 |

frame はどちらも 50 ms（ヘッドレスの描き替えの刻み）なので比べない。

**ブラウザの絵 16 種の内訳（試しのコード・commit していない）**: `WebGpuRows` を 3 通りに変えて書き出し、WebGPU で今の形と 1 本ずつ交互に 3 回ずつ測った（submit p50・ms）。
組み方: `WebGpuRows.flix` を変える → `make sync-engine-full-web` → `make bench-web-export BENCH=sprite_stress` → 書き出しを版ごとのフォルダへ移し、`bin/fge web-bench <フォルダ> --query 'n=20000&tex=16&backend=webgpu' --size 960x720 --wait 120`。
変えた版: A = scissor を前と同じなら積まない／B = A から行を 1 つも流さない（行は作る）／C = A から `setBindGroup` と `draw` だけ呼ばない（輪・数え・scissor の式は回す）。

| 組 | 1 回目 | 2 回目 | 3 回目 | 中央値 |
|---|---|---|---|---|
| 今の main と A | 30.5 と 30.0 | 30.7 と 29.9 | 30.9 と 29.9 | 30.7 と 29.9 |
| B と A | 17.3 と 30.2 | 17.3 と 30.3 | 17.4 と 30.0 | 17.3 と 30.2 |
| C と A | 21.5 と 30.4 | 21.5 と 30.2 | 21.5 と 30.4 | 21.5 と 30.4 |

- 行を流す前まで（View から列を作り終えるまで・空の pass を開いて閉じる）17.3 ms・行を流す Flix の輪 4.2 ms（C − B）・JS への呼び出しと絵の bind group の引き当て 8.9 ms（同じ組の A − C・1 行 約 0.45 µs）。
- scissor を毎行積むのをやめても 0.8 ms（2.6%）しか減らない。**行の高さを下げて（状態の変化だけを行にして）呼び出しを減らす案は、backend が前と同じ物を積まないだけで同じ所まで行ける**ので、行の高さは今の「物の集まり」のままでよい。
- 大きい所は 1 行ごとの `setBindGroup` と `draw`。減らすのは P6 の決まり 3（絵をアトラスの頁にまとめると、この場面は draw 1 本になる）と、後の「列を JS へ 1 回で渡す」（親 9 章の「後」）。どちらも今の Int32 の行のまま乗る。
- 同じ絵の場面（ブラウザ 14.1 ms）は行が 1 つなので、残りは行を作る前（View から `Drawable` まで・z の並べ）の重さ。形の外（親 12.1 の「割り当てを減らす」）。

### 1.3 書き味の見本（新しい種類の行を 1 つ足す時）

**今の main でスプライトの行に書いた物**（実際のコード）:

| 書いた所 | 行数 | GL / WebGPU / 共有 |
|---|---|---|
| `RenderFrame.appendSpriteRow`・`closeSpriteRun`（行を足す・run を閉じる） | 18 + 8 | 共有 |
| `RenderFrame.pushSpriteKeyed`（run の鍵の比べ） | 34 | 共有（R1a の前からある） |
| `RenderFrame.drawRow`（行 → GL） | 17 | GL |
| `RenderSprite.drawSpriteInstancedBuf` | 25 | GL（R1a の前からある） |
| `WebGpuRows.drawRow`・`bindPipeline`・`firstInstanceAt` | 30 + 8 + 2 | WebGPU |
| `WebGpuPaint.pipelineOf`・`buildPipeline` と WGSL | 30 + 103 | WebGPU |

**R1b で多角形の行を足す時の見込み【推】**（3 章の形を入れた後）: 共有 = `appendPolyRow` 約 15 行（`pushPolyKeyed` は今の物を使い、`flushPolys` が GL を呼ぶ代わりに行を足す）。
GL = `GlRows.drawRow` の枝 1 行と `drawPolyRow` 約 12 行（中は今の `drawPolygonBatchBuf`）。WebGPU = `WebGpuRows.drawPolyRow` 約 25 行・頂点の buffer を送る所 約 15 行・pipeline 約 25 行・WGSL 約 30 行。
GL は「行の欄を読んで今の GL の関数へ渡す」だけで、新しい GL の関数は書かない。WebGPU は pipeline と WGSL が毎回の主な量になる。

3 章の形での書き方（**見本・型検査を通していない**）:

```flix
// RenderFrame.Internal.RenderList（共有）
pub def appendPolyRow(list: RenderList, firstVert: Int32, verts: Int32, blendC: Int32,
                      clipFlag: Int32, x0: Int32, y0: Int32, x1: Int32, y1: Int32): Unit \ IO =
    appendRow(list, kindPoly(), firstVert, verts, 0, blendC, clipFlag, x0, y0, x1, y1)

// RenderFrame.Internal.GlRows と WebGpuRows（両方とも同じ形）
@DontInline
def drawRow(gl: GlContext, gs: GlState, list: RenderList, row: Int32): Unit \ IO =
    let kind = rowAt(rowsOf(list), row, 0);
    if (kind == kindSprite()) drawSpriteRow(gl, gs, list, row)
    else if (kind == kindPoly()) drawPolyRow(gl, gs, list, row)
    else bug!("RenderList: 知らない種類 ${kind}");
    ()
```

種類ごとの本文は別の `@DontInline` の def に置く（`drawRow` 1 本に全部を書くと 8,000 バイトを超えて JIT されない・`docs/performance.md` 13 節）。

## 2. 今の形の問題点（V1 12 章の持ち越し 1〜27 の仕分け）

| 仕分け | 番号 |
|---|---|
| **形のレビューで決める**（スプライトの行・pass・上げる所） | 1・2・3・4・5・6・7・8・10・11・12・13・14・18・19（15 件。下の表では 6 と 19、13 と 14 を 1 行にまとめた） |
| **R1b ⇄ P6 で種類ごとに決める**（形はこの段で足りる事だけ見る） | 9（mask）・15（中間の texture を省くか）・16（ブラウザで画像を解く・読む所） |
| **形に関係ない** | 17・20（診断の出し方）・21・22（済み）・23（gl-capture の基準）・24（Studio の種）・25（lint-huge-methods）・26（早見表）・27（PC の device lost） |

決める物ごとに、今の形で困る所:

| # | 困る所（コードの場所） | 決める物 |
|---|---|---|
| 1 | 描き先の上下を `FrameArgs#targetNames`（`Frame.flix:285-287`）で受け、`targetUvFlipped`（`:766-775`）が名前ごとに `Set.memberOf` で引く。WebGPU は `Set.empty()` を渡して逃げている（`WebGpuRows.emitPlainSprite`） | backend の capability「描き先は上下逆か」1 つにする（3.2） |
| 2 | 行の instance の番号が `renderCommands` ごとに 0 から。WebGPU は送った位置 `base` を足す（`WebGpuRows.firstInstanceAt`） | 今のまま（列ごとに 0 から）で確定。足すのは backend の仕事（3.1） |
| 3 | `st`（`Frame.flix:402-418`）に GL の番号（欄 0〜6・26）・viewport（7〜10）・run の状態（11〜25・51）・draw の数え（27〜50）が同居。WebGPU は数えの初めの値（欄 28・30）を `renderFrameMixed` から写している（`WebGpuRows.renderFrame`） | 前半の状態（run と数え）と backend の状態に分ける（3.1） |
| 4 | instance の入れ物を GL の `RenderBuf`（`gl.allocFloats`・`Buf.flix:15`）が作る。WebGPU は自分の LITTLE_ENDIAN の `ByteBuffer`（`WebGpuPaint.instancesFor`） | backend が貸す（`instancesFor(n)` の形を GL にも）（3.1） |
| 5 | 登録簿・`ensureTexture` の key・描き先の表・`lastFrame` が GL の `RenderPaint` と `WebGpuPaint` に 2 本（V1 1.4） | CPU の側の表を共有の module へ（3.3） |
| 6・19 | 読み込みが全部 `GlContext` を受け、WebGPU は上げる所を別に写した（V1 3.1）。`copyImageBitmap` は一時の texture へ写してから読み戻す（外で作った texture を表に載せる関数が無い） | 上げる API を 1 本化し、「外の画像を写す」op を持たせる（3.3） |
| 7 | 画面の clear（黒帯と `clearColor`）が `renderFrameMixed`（`Frame.flix:1074-1100`）の中の GL の呼び出しで、WebGPU は別に組み直した（`WebGpuRows.loadOpOf`・`clearBox`） | pass の record に持たせる（3.2） |
| 8 | pipeline の鍵の半分（描き先の形式）が pass の性質で、行は blend だけを持つ | 今のまま確定（形式は pass の record から backend が引く）（3.1） |
| 10 | Pass の history の写し（`RenderPaint.prepareHistory`・`:335-362`）が GL の Paint の中にあり、行にも `WebGpu` にも無い | pass の record に「前のコマを写す」を持たせる。`WebGpu` の texture の写しは R1b の history の小分けで足す（3.2） |
| 11 | WebGPU は `writeTexture` などの前に積んだ pass を submit する（`WebGpuPaint.flushPending`・V1 3.2） | 「その場で流す」と即時の上げる APIのまま確定。staging は P6 で submit が 2 以上の場面が出た時（3.3） |
| 12 | instance を頂点バッファで読む（V1 2.1）。面・材質の draw ごとの値をどこに置くか | スプライトは頂点バッファで確定（storage と同じ 1.45 ms【確】・V1）。draw ごとの値は別の Float32 の配列（3.1） |
| 13・14 | 字の絵の成分（GL `.a`・WebGPU `.r`）と sampler を表の番号の裏に持たせた | 行は絵の番号だけで確定（字の場面は GL と 0 px【確】・V1） |
| 18 | bench が engine の fpkg から `RenderPaint.Internal.*` を呼べない（`mod RenderPaint` が pub でない） | pub にしない。bench は今の木（symlink で 1 つのパッケージ）のまま（3.4） |

R1b ⇄ P6 の 3 つが今の形に足せるか:
- 9（mask）: スプライトの行 + mask の頂点の範囲（多角形の頂点の配列の中）を持つ種類 `kindMaskedSprite`。stencil の比べる値を進める・255 を超えたら pass を分けるのは backend の中（pass の record は分け方を持たない）。足せる。
- 15（中間の texture）: pass の record の描き先が「画面」なので、backend が中間を使うかを決められる。足せる。
- 16: 列と関係ない（`fge-web.js` の読み込みと `?capture`）。

## 3. 案（3 つの決める物と、横断する 3 つ）

### 3.1 スプライトの行

| 軸 | S1. 今の形（Int32 の行・10 欄・Float32 の instance） | S2. 低い高さ（状態の変化を行にする: pipeline・絵・scissor・draw） | S3. 行ごとの record / enum |
|---|---|---|---|
| GL で書く | 行 → 今の GL の関数（17 行） | GL の状態（program・blend の uniform・絵）へ WebGPU の形の命令を訳し直す | 書きやすい |
| WebGPU で書く | 前と同じ物を積まない控えを backend が持つ（`geom`） | 行 = 命令でそのまま | 書きやすい |
| 速さ | 1.2 の表 | ブラウザで減るのは backend の控えと同じ分（scissor の試しで 2.6%）【確】 | 絵が 1 個ごとに替わると行が 20,000 個の割り当て。V1 で record の欄を 1 個ごとに読んだだけで submit 1.28 倍【確】 |
| JIT の罠 | 輪は `@DontInline` の 1 行ごとの def で JIT に乗る【確】 | 同じ | 欄の引き当て（`lookupField`）が輪に入る |
| wasm・JS | 列を JS へ 1 回で渡す形がそのまま乗る | 同じ | 乗らない |
| 次の種類 | 欄の意味を種類ごとに変え、長さの変わる物は別の配列の範囲 | 種類ごとの違いが命令に溶けて GL の backend が膨らむ | 足しやすい |

**おすすめ: S1 を確定し、次の 4 つだけ直す。**

1. **前半の状態と backend の状態を分ける**（#3）: `st` を「run の状態と数え」（前半・`RunState`）と、backend が持つ物（GL は program・VAO・buffer の番号と viewport・WebGPU は今の `geom`）に分ける。draw の数えは今どおり backend が呼ぶ（`countSpriteDraw` を共有・数える先は前半の配列）。
2. **instance の入れ物は backend が貸す**（#4）: 前半は `instancesFor(n)` で受けた `FloatBuffer` に書く。GL は `RenderBuf` を貸し、WebGPU は今の LITTLE_ENDIAN の入れ物。行の番号は列ごとに 0 から（#2）。
3. **描き先の上下は backend に聞く**（#1）: capability `targetUpsideDown: Bool`（GL は真・WebGPU は偽）。前半は描き先の表（今の `RenderPaint` の `targetsRef` の名前。3.3 で共有の module へ移す）で名前を引き、真の時だけ uv を返す。`targetNames` の欄は消す。
4. **長さの変わる物は行に入れない**: 行の幅は固定（今は 10。種類が増えて欄が足りなければ `rowStride` を広げる）。面の `texReads` のような長さの変わる物は、別の Int32 の配列の (先頭, 数) を行に持つ。draw ごとの値（タイルの position・面の params）は別の Float32 の配列（並びは backend が決める・親 5.1）。

### 3.2 pass の区切り

| 軸 | P1. 今のまま（pass は暗黙。GL は `renderFrameMixed` の中で clear、WebGPU は `openPass(op)` の閉包） | P2. 行の種類にする（Int32 の行の頭に pass の行） | P3. 列 1 本に 1 つ付ける小さな record（`PassSpec`） |
|---|---|---|---|
| GL / WebGPU で書く | clear・黒帯・viewport の式を両方が別に持つ（GL の clear 33 行・WebGPU の `renderFrame` と黒帯 77 行） | LoadOp と色を Int32 と Float32 へ詰め直し、読む所でほどく | 型のついた値をそのまま読む。黒帯の塗り方（GL は scissor で 2 回 clear・WebGPU は黒で clear して箱 1 個）は backend ごと |
| 速さ | 同じ | 同じ（1 コマに数個） | 同じ（`renderCommands` 1 回に 1 つ・record を作るのは数個） |
| 次の種類 | history・MSAA の resolve・3D を貼る前の pass がどこにも置けない | 置ける | history は欄、resolve は描き先の表から backend、3D の場面の先の pass と mask の 255 超えの分け直しは backend の中 |
| コマ全体を溜める形へ変える時 | 作り直し | そのまま | record を行の種類へ 1 対 1 で写す |

**おすすめ: P3。** `renderCommands` 1 回 = 列 1 本 = pass 1 つ（親 5.1 の「その場で流す」）なので、pass の行はいつも列の頭に 1 つしか無い。
1 つしか無い物を配列へ詰める得は無く、`RenderTarget.LoadOp` のような enum をそのまま持てる方が読み違いが無い。欄（【推】・名前は R1b-0 で決める）:

| 欄 | 中身 |
|---|---|
| `target` | `Screen({ clearColor, letterbox: Bool })` か `Target({ id, op: RenderTarget.LoadOp, format })`（`id` は backend の表の番号） |
| `viewport` | design の矩形を描き先の画素で（左上が原点。GL は y を返す） |
| `copyHistory` | `Option[Int32]`（前のコマを写す先の表の番号。R1b の history の小分けで使い始める） |

pass の途中で分ける事（3D の場面を先に自分の texture へ描く・mask が 255 を超える）は backend の中で決める。WebGPU は列を全部作ってから pass を開く（今の `WebGpuRows.renderFrame`）ので、3D を貼る行が来る前に場面の pass を済ませられる。

### 3.3 上げる行（絵と buffer を GPU へ上げる指示）

| 軸 | U1. 今のまま（GL は `GlContext` を受ける読み込み・WebGPU は写した別の道） | U2. 列に「上げる行」を入れる（中身は別の配列・列の頭で流す） | U3. 即時の上げる API を 1 本にする（render_gl の中の effect・handler は GL と WebGPU） |
|---|---|---|---|
| 書く | 読み込み 9 種を backend ごとに 2 本（V1 3.1 の表・約 300 行が 2 本目） | 上げる中身を列が流れるまで持つ。列はすぐ流れるので、列の外で即時に呼ぶのと同じ結果 | 読み込みは 1 本。handler 2 本 |
| WebGPU の順の問題（`writeTexture` は積んだだけの pass より先に反映される） | 上げる前に submit（`flushPending`） | 列に入れても同じ問題が残る（queue の書き込みは encoder の外）。直すには staging buffer と `copyBufferToTexture` を `WebGpu` に足す（GL の層の jar のハッシュが動く） | 上げる前に submit を handler の中に残す。submit の回数は今 1 コマ 1 回（sprite_stress・rpg-starter の title）【確】 |
| 速さ・JIT・wasm | 上げるのは読み込みと key が変わった時だけで、輪の中に無い | 同じ | 同じ（effect の続きの割り当ては毎コマ数回までなら問題にならない【推】） |
| 次の種類（タイルの buffer・static layer・3D の形） | 種類ごとに 2 本ずつ増える | 足せる | op を足す（`createBuffer`・`writeBuffer`・`destroy`）。3D の `meshEntry` も描く前に呼ぶ形へ移せる（親 5.3 の「上げる行を先頭に」と同じ順） |

**おすすめ: U3。** 「上げる行」の狙い（描く前に上げ終える・描く所で上げない）は、列が即時に流れる限り「列を作る前に上げる API を呼ぶ」で満たせる。
行にすると中身を持ち回る分だけ増え、WebGPU の順の問題は解けない。API の op（【推】）: 絵を作る（形式・filter・address）・中身を書く・外の画像を写す（ブラウザの `ImageBitmap`。#19 の読み戻しを無くす）・捨てる・buffer を作る・書く・捨てる。返すのは backend の表の番号（`GpuHandle` の読み替え・親 5.3）。
effect にするのは「機種の差は handler で受ける」（親 12.4 の 4）と、`WebGpuDevice`・`Fs` と同じ形にそろえるため。engine の pub は増やさない（render_gl の中・`Internal` の下）。
CPU の側の表（登録簿・key・描き先の表・`lastFrame`）はこの API の外の共有の module に置き（#5）、GL の `RenderPaint` と `WebGpuPaint` が同じ関数を呼ぶ。

### 3.4 横断する物

| 決める物 | 候補 | おすすめと理由 |
|---|---|---|
| いつ流すか（親 9.1） | その場で流す／コマ全体を溜める | **その場で流す。** submit は今 1 コマ 1 回で、溜める理由（JS との行き来をまとめる）は列を JS へ 1 回で渡す形（「後」）で別に取れる。溜めると Pass の間の上げる順を列に入れる決まりが要る |
| 作り終えてから流す | GL は今、GL を直に呼ぶ種類が来るたびに途中で流す（`flushSprites`）／列を作り終えてから流す | **作り終えてから流す**を両方の決まりにする。WebGPU は既にそう（3D の先の pass に要る）。GL は全部の種類が行になるまで途中で流すのを残す（移る間の形） |
| 名前 | `RenderList` のまま／`DrawList`／Bevy の phase item・Unreal の mesh draw command | **`RenderList` のまま。** `DrawList` は engine_tools の `SoftRaster.Internal.DrawList`（CPU の描き手の中身）・`DrawCmd`・`Counter.DrawCalls` と字が重なり grep で混ざる。phase item は Bevy の「並べ替える 1 個」で、run をまとめた後の行とは高さが違う。今の型・テスト（`TestRenderList`）と 1 字も変えずに済む。親の文書の `DrawList` は、了承の後に親を書き直す時に `RenderList` へ直す |
| 置き場・pub | `Frame.flix` のまま／`RenderFrame.Internal.RenderList` へ出す／pub の mod | **`RenderFrame.Internal.RenderList`（行の型と足す・読む関数）と `RenderFrame.Internal.GlRows`（GL の流し方）へ出す。** `Frame.flix` は 1,162 行で上限 1,200 行（R1b で種類を足すと超える）。子孫は先祖の pub でない物を読め、先祖は子孫の pub を呼べる【確・V1 1.1】ので、`Internal` の下に置けばゲームからは lint の `app-internal` で止まる。engine の pub と `mod RenderFrame` の pub は変えない（#18。3 つ目の backend を別のパッケージに置く時に P10 で見直す） |

## 4. 決めた後の段取り

**R1b の頭に小さな段 R1b-0 を置く**（独立の段にしない。R1b の最初の小分け「物の上げ下ろしと寿命の表」と同じ所を触るため、続けて入れる）。

| 段 | 中身 | 門 | 実時間【推】 |
|---|---|---|---|
| R1b-0a | `RenderList` と GL の流し方を `RenderFrame.Internal.RenderList`・`GlRows` へ移す（中身は変えない）・`st` を分ける・入れ物を backend が貸す・`targetUpsideDown`・`PassSpec`（GL の clear と WebGPU の `loadOpOf`・`clearBox` をこれで受ける） | `gl-parity` 0 px・テンプレの `reference`・`gl-capture-check`・`make webgpu-v1-check`（PC）と `-web` が 0 px・`TestRenderList` 緑・sprite_stress の絵 1 種と 16 種を PC とブラウザで 5% 以内（3 回ずつ交互・中央値と幅） | 1〜1.5 時間 |
| R1b-0b | 上げる API（effect）と CPU の側の表の共有（R1b の 1 つ目の小分けの前半）。`copyImageBitmap` を直に表へ載せる | 同じ門と、ブラウザの絵（`hasAlpha = false` を含む）が WebGL2 と 0 px | 0.5〜1 時間（R1b の見積もりの中） |
| レビュー | 1 回目で全部の指摘を出させ、まとめて直して 2 回目 | 90 点 | 上に含む |

見積もりの物差し: P4b 約 1 時間・V1 約 2 時間 10 分（設計の 8.5〜11 時間に対し）。R1b-0a は移すのと分けるのが主で V1 の半分ほどの量【推】。親の R1b ⇄ P6 の 18〜26 時間は変えない（R1b-0b はその中から前に出すだけ）。

## 5. 人に伺う事

1. **名前**: 親 11 章の 7（形のレビューで決める）。**おすすめは `RenderList` のまま**（`DrawList` は engine_tools の `SoftRaster.Internal.DrawList` とぶつかる）。親の文書の `DrawList` は書き直す時に `RenderList` へそろえる。
2. **親 5.1 の表を改める事**: 「pass の区切り」と「物の上げ下ろし」を `RenderList` の行の種類から外し、pass は列ごとの record（3.2）、上げるのは即時の上げる API（3.3）にする。
   **おすすめはこの形**（どちらも「列はその場で流す・pass は列ごとに 1 つ」から出てくる。コマ全体を溜める形に変える時は、record を行の種類へ 1 対 1 で写せる）。了承をいただいたら、親の 5.1・9.1 の該当の行と 12 章へ結果を書き足す。

技術の細部（欄の並び・effect の op の名前・R1b-0 の分け方）はこちらで決めて R1b-0 の設計に書く。
