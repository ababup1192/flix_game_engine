# WebGPU 移行の段階「`DrawList` の形のレビュー（2D）」— 材料と案（第 4 版・レビュー 90 点・人の了承済み・スパイクで比べた）

親は `plans/engine-webgpu.md`（以下「親」）の 9 章の表の 7 番と 9.1。V1 の文書は `plans/webgpu-v1.md`（以下「V1」）。
【確】= コードか測った値 ／【推】= 読みや割り算からの見積もり。測ったのは 2026-11-15・Apple M4 Pro・Chrome 156（ヘッドレス）だけ。
第 1 版はレビュー 74 点。指摘 16 件への対応は末尾の表。

## 決まった事（人の返事・2026-11-15）

1. 親 5.1 の表を改めてよい。ただし、軽いスパイクで今の案より良い案が見つかればその方針で（→ 6 章で比べた。**比べた上で今の案**）。
2. ブラウザの絵の多い場面が P6 まで WebGL2 とほぼ同じなのは、後で速くなる余地があるなら今は良い（→ 余地は 6.3 で測った: 絵 16 種の submit が 29.6 → 25.2 ms）。
3. WebGPU の submit が 1 コマに 2 回以上になる場面を、P6 の staging の比べまで許す。

## 要約（人が読む 10 行）

1. 描く単位は「pass の指定（`PassSpec`）と、その pass に描く行（row）の組」にする。1 回の `renderCommands` は組の順序つきの列（list）を出す（3D の場面や影の pass が先・2D の本体が最後）。
2. スプライトの行は今の形（Int32 の行・1 行 10 欄・1 体 38 個の Float32）を残す。直すのは GL の物と front-end（前半）の状態を分ける・instance の入れ物は backend が貸す・render target（描き先）の上下は backend に聞く・`Frame.flix` から出す、の 4 つ。38 個は P6 のアトラスの頁で層の番号を欄 14 に詰めて保つ。
3. pass は行にせず、組ごとに型のついた record（色の attachment の列・depth/stencil・標本数・clear・letterbox（黒帯）・history の写し）を付ける。
4. texture（絵）や buffer の upload（上げる所）は行にしない。GL と WebGPU が同じ形で受ける「関数の record」に 1 本化する（今の `WebGpuRows` と同じ流儀）。
5. WebGPU の submit は今、上げる前にコマの途中で増えうる（呼び手 8 か所）。数を R1b-0b で数え、テンプレの場面で毎コマ 2 以上が出たら staging へ移る。
6. 速さ（PC は frame・ブラウザは submit の比）: PC は WebGPU / GL が同じ絵 20,000 個で 0.89 倍・絵 16 種で 0.33 倍。ブラウザの絵 16 種は submit 0.91 倍で、WebGL2 とほぼ同じ。
7. ブラウザの内訳: 行を流す前まで 17.3 ms・行を流す Flix の輪 4.2 ms・wasm から JS への呼び出しと bind group の引き当て 8.9 ms。同じ絵の場面では `writeInstAt` が 15.5 ms のうち 3.9 ms。縮めるのは P6 のアトラスと入れ物の型で、今の形はどちらも妨げない。
8. 名前は `RenderList` のまま（Godot・three.js にも同じ名前がある）。pub にしない。
9. 入れる作業は R1b の頭の R1b-0（実時間 2.5〜4 時間）。人に伺った 3 つは了承済み。スパイク 3 本で比べた上で今の案のまま（6 章）。

## 1. 並べる材料

### 1.1 GL と WebGPU の backend の行数（2D・V1 の後の main・`b10cd896`）

範囲は `bin/fge refactor outline` と `show` の行番号から数えた【確】（doc のコメントを含む）。

| 役目 | GL | WebGPU |
|---|---|---|
| 行を受けて描く | `RenderFrame.drawRenderList`〜`drawRow` 34・`setScissorAt` 21・`RenderSprite.drawSpriteInstancedBuf` 25・`applyBlend` 12 = **92** | `WebGpuRows.drawRowsFrom`〜`firstInstanceAt` 52・`scissorInto`〜`viewportTop` 37・`WebGpuPaint.pipelineOf`/`buildPipeline` 30・`instancesFor`〜`groupOf` 70 = **189** |
| pass の扱い（clear・viewport・letterbox・描き先を開く閉じる） | `renderFrameMixed` の clear 33・`RenderPaint.beginTarget` 25・`endTarget` 8・`prepareHistory` 28 = **94** | `WebGpuRows.renderFrame` 59・`needsLetterbox`〜`loadOpOf` 18・`WebGpuPaint.beginTarget` 19・encoder と submit 28 = **124**（history は無し） |
| upload（texture の表・`ensureTexture`） | `RenderPaint.ensureTexture` 40・`RenderTexture` 95 | `addSlot`〜`rewriteSlot` 139（ほかに V1 で GL から写した表の分 約 300 行が `WebGpuPaint` 全体に散る。V1 1.4） |
| front-end の写し | — | `emitAll`・`emitItem`・`emitPlainSprite` 36（`RenderFrame.emitMerged`・`emitOne` と同じ形の 2 本目） |
| シェーダー | GLSL 119（`RenderShader.spriteInstanced*`） | WGSL 103（`WebGpuShader.spriteWgsl`） |
| 共有の front-end | `Frame.flix` の `RenderList` の節 76・`pushSpriteKeyed` 34・`emitSprite` 31・`writeInstAt` 93 | 同じ物 |

- WebGPU の行を流す所が GL の 2 倍あるのは、GL が持つ状態（scissor・blend・bind した texture）を WebGPU では自分で控え、前と同じなら積まないため（`geom` の欄 8〜13）と、scissor を描き先の中へ収める式（`scissorInto`）のため。形の差ではない。
- GL は行ごとに `bufferData` で instance を送る（GL 3.3 と WebGL2 に baseInstance が無い）。WebGPU は list 1 本ぶんを `writeBuffer` 1 回で送り、`firstInstance` で引く（`sendInstances`）。今の行（`first`・`count`）は両方の送り方を受けられている【確】。

### 1.2 ベンチ（sprite_stress・20,000 個）

PC とブラウザの同じ絵は `bench/sprite_stress/RESULTS.md` の V1 の節と「絵 16 種の測り直し」（3 回ずつ交互・中央値・ms）。**ブラウザの絵 16 種と内訳はこの段階で測った。**

| 場面 | GL frame / submit | WebGPU frame / submit | WebGPU / GL |
|---|---|---|---|
| PC・同じ絵 | 7.563 / 2.192 | 6.753 / 2.057 | frame 0.89 倍・submit 0.94 倍 |
| PC・絵 16 種（20,000 draw） | 41.039 / 35.815 | 13.524 / 5.863 | frame 0.33 倍・submit 0.16 倍 |
| ブラウザ・同じ絵 | 33.3 / 13.5（cpu 29.4） | 33.3 / 14.1（cpu 30.0）。この段階で測った日の今の main は 15.5（下の D・E の表） | submit 1.04 倍（frame は描き替えの刻みで比べられない） |
| ブラウザ・絵 16 種【新】 | 50 / 33.2（cpu 50.5） | 50 / 30.1（cpu 45.7） | submit 0.91 倍・cpu 0.90 倍 |

ブラウザの絵 16 種（`make bench-web BENCH=sprite_stress BENCH_WEB_EXPORT=off ARGS='n=20000&tex=16'` と `&backend=webgpu` を交互に 3 回ずつ。測る前に `ps` で他の重い java が無い事を見た。WebGPU の回は 3 回とも `env.backend` が `webgpu: WebGPU apple metal-3 ()`。draw は 20,000・切れた理由は `texture` 19,999）:

| | 1 回目 | 2 回目 | 3 回目 | 中央値 | 幅 |
|---|---|---|---|---|---|
| WebGL2 submit / cpu p50 | 34.8 / 52.0 | 33.2 / 50.5 | 33.2 / 50.5 | 33.2 / 50.5 | 1.6（4.8%）/ 1.5 |
| WebGPU submit / cpu p50 | 30.1 / 45.7 | 30.1 / 45.9 | 30.2 / 45.7 | 30.1 / 45.7 | 0.1 / 0.2 |

**内訳（試しのコード・commit していない）**: 版ごとに `WebGpuRows.flix` などを変える → `make sync-engine-full-web` → `make bench-web-export BENCH=sprite_stress` → 書き出しを版ごとのフォルダへ移し、
`bin/fge web-bench <フォルダ> --query '<つまみ>&backend=webgpu' --size 960x720 --wait 120` を今の形と 1 本ずつ交互に 3 回ずつ（submit p50・ms）。

絵 16 種（`n=20000&tex=16`）。A = scissor を前と同じなら積まない／B = A から行を 1 つも流さない（行は作る）／C = A から `setTexture` の閉包（中の bind group の `Map` の引き当てと `setBindGroup`）と `draw` を呼ばない（輪・数え・scissor の式は回す）:

| 組 | 1 回目 | 2 回目 | 3 回目 | 中央値 |
|---|---|---|---|---|
| 今の main と A | 30.5 と 30.0 | 30.7 と 29.9 | 30.9 と 29.9 | 30.7 と 29.9 |
| B と A | 17.3 と 30.2 | 17.3 と 30.3 | 17.4 と 30.0 | 17.3 と 30.2 |
| C と A | 21.5 と 30.4 | 21.5 と 30.2 | 21.5 と 30.4 | 21.5 と 30.4 |

同じ絵（`n=20000&tex=1`）。D = `RenderFrame.writeInstAt` の中身を飛ばす／E = 画面の pass を積んだ後に 1 回 submit を足す（1 コマ 2 回）:

| 版 | 1 回目 | 2 回目 | 3 回目 | 中央値（submit / cpu） |
|---|---|---|---|---|
| 今の main | 15.5 / 31.0 | 15.6 / 31.1 | 15.5 / 31.1 | 15.5 / 31.1 |
| D | 11.6 / 27.0 | 11.7 / 26.7 | 11.6 / 26.7 | 11.6 / 26.7 |
| E | 15.5 / 31.1 | 15.4 / 30.9 | 15.6 / 31.2 | 15.5 / 31.1 |

- 絵 16 種: 行を流す前まで（`renderCommands` の中で list を作り終えるまで・空の pass を開いて閉じる）17.3 ms・行を流す Flix の輪 4.2 ms（C − B）・`setTexture` と `draw` 8.9 ms（同じ組の A − C・1 行 約 0.45 µs）。
  書き出しは WebAssembly GC なので、8.9 ms の大半は wasm から JS への呼び出しと見るが、B と C は GPU の仕事も消すので、GPU プロセスとの CPU の取り合い・戻りの待ちの分が A − C に混ざりうる【推】。
- scissor を毎行積むのをやめても 0.8 ms（2.6%）。**状態の変化だけを行にする（行の高さを下げる）案は、backend が前と同じ物を積まないだけで同じ所まで行ける**ので、行の高さは今の「物の集まり」のままでよい。
- 同じ絵: `writeInstAt`（1 体 38 回の `put` × 20,000 体）が 3.9 ms（1 体 約 0.2 µs）。残りの 11.6 ms は未分解で、中身は共有の front-end（`mergedByZ`・`emitSprite` の登録簿の引き当てと run の鍵・`writeBuffer` への写し）。
  この日の今の main は 15.5 ms で、V1 の記録（14.1 ms）より高い（測った時刻の違い。差の理由は見ていない）。
- E: submit を 1 回足しても、CPU の側は 0.1 ms の刻みで差が見えない。GPU の側の値段（pass が別の command buffer に分かれる分）は測っていない。

### 1.3 書き味の見本（新しい種類の行を 1 つ足す時）

**今の main でスプライトの行に書いた物**（実際のコード）:

| 書いた所 | 行数 | GL / WebGPU / 共有 |
|---|---|---|
| `RenderFrame.appendSpriteRow`・`closeSpriteRun` | 18 + 8 | 共有 |
| `RenderFrame.pushSpriteKeyed`（run の鍵の比べ） | 34 | 共有（R1a の前からある） |
| `RenderFrame.drawRow`（行 → GL） | 17 | GL |
| `RenderSprite.drawSpriteInstancedBuf` | 25 | GL（R1a の前からある） |
| `WebGpuRows.drawRow`・`bindPipeline`・`firstInstanceAt` | 30 + 8 + 2 | WebGPU |
| `WebGpuPaint.pipelineOf`・`buildPipeline` と WGSL | 30 + 103 | WebGPU |

**R1b で多角形の行を足す時の見込み【推】**（3 章の形を入れた後）: 共有 = `appendPolyRow` 約 15 行。頂点は今の別の入れ物 `polyData` をやめ、`RenderList` の `vertices`（3.1 の 8）へ書く（`pushPolyKeyed` の比べは今の物）。
GL = `GlRows.drawRow` の枝 1 行と `drawPolyRow` 約 12 行（中は今の `drawPolygonBatchBuf`）。WebGPU = `drawPolyRow` 約 25 行・頂点を送る所 約 15 行・pipeline 約 25 行・WGSL 約 30 行。
GL は「行の欄を読んで今の GL の関数へ渡す」だけ。WebGPU は pipeline と WGSL が毎回の主な量になる。

見本（**型検査を通していない**）:

```flix
// RenderFrame.Internal.RenderList（共有）。頂点は list#vertices の [firstVert, firstVert + verts)
pub def appendPolyRow(list: RenderList, firstVert: Int32, verts: Int32, blendC: Int32,
                      clipFlag: Int32, x0: Int32, y0: Int32, x1: Int32, y1: Int32): Unit \ IO =
    appendRow(list, kindPoly(), firstVert, verts, 0, blendC, clipFlag, x0, y0, x1, y1)

// RenderFrame.Internal.GlRows（GL の backend）
@DontInline
def drawRow(gl: GlContext, gs: GlState, list: RenderList, row: Int32): Unit \ IO =
    let kind = rowAt(rowsOf(list), row, 0);
    if (kind == kindSprite()) drawSpriteRow(gl, gs, list, row)
    else if (kind == kindPoly()) drawPolyRow(gl, gs, list, row)
    else bug!("RenderList: 知らない種類 ${kind}");
    ()
```

WebGPU の `drawRow` は今 `(pass, st, rows, geom, setPipeline, setTexture, skip, row)` を受ける（`WebGpuRows.drawRow`）。引数は backend ごとに違ってよく、
そろえるのは「種類で分ける if の連鎖と、種類ごとに別の `@DontInline` の def」の形だけ（1 本に全部を書くと 8,000 バイトを超えて JIT されない・`docs/performance.md` 13 節）。

## 2. 今の形の問題点（V1 12 章の持ち越し 1〜27 の仕分け）

| 仕分け | 番号 |
|---|---|
| **形のレビューで決める** | 1・2・3・4・5・6・7・8・10・11・12・13・14・17・18・19（16 件）と、9 の stencil の attachment の半分 |
| **R1b ⇄ P6 で種類ごとに決める** | 9（mask の行の種類）・15（中間の texture を省くか）・16（ブラウザで画像を解く・読む所） |
| **形に関係ない** | 20（診断の swapNs と GPU の時間）・21・22（済み）・23（gl-capture の基準）・24（Studio の種）・25（lint-huge-methods）・26（早見表）・27（PC の device lost） |

決める物ごとに、今の形で困る所:

| # | 困る所（コードの場所） | 決める物 |
|---|---|---|
| 1 | 描き先の上下を `FrameArgs#targetNames`（`Frame.flix:285-287`）で受け、`targetUvFlipped`（`:766-775`）が名前ごとに `Set.memberOf` で引く。WebGPU は `Set.empty()` を渡して逃げている（`WebGpuRows.emitPlainSprite`） | backend の capability 1 つ（3.1） |
| 2 | 行の instance の番号が `renderCommands` ごとに 0 から。WebGPU は送った位置 `base` を足す（`WebGpuRows.firstInstanceAt`） | 今のまま（list ごとに 0 から・起点は backend が足す）で確定（3.1・3.5） |
| 3 | `st`（`Frame.flix:402-418`）に GL の番号（欄 0〜6・26）・viewport（7〜10）・run の状態（11〜25・51）・draw の数え（27〜50）が同居。WebGPU は数えの初めの値（欄 28・30）を写している | front-end の状態と backend の状態に分ける（3.1） |
| 4 | instance の入れ物を GL の `RenderBuf`（`gl.allocFloats`）が作り、WebGPU は自分の LITTLE_ENDIAN の `ByteBuffer` | backend が貸す（3.1） |
| 5 | 登録簿・`ensureTexture` の key・描き先の表・`lastFrame` が `RenderPaint` と `WebGpuPaint` に 2 本 | CPU の側の表を共有の module へ（3.3） |
| 6・19 | 読み込みが全部 `GlContext` を受け、WebGPU は上げる所を別に写した（V1 3.1）。`copyImageBitmap` は一時の texture へ写して読み戻す | upload を 1 本化し、「外の画像を写す」op を持たせる（3.3） |
| 7 | 画面の clear と letterbox が `renderFrameMixed`（`Frame.flix:1074-1100`）の中の GL の呼び出しで、WebGPU は別に組み直した（`loadOpOf`・`clearBox`） | `PassSpec` に持たせる（3.2） |
| 8 | pipeline の鍵のうち描き先の形式が pass の性質で、行は blend だけを持つ | 行は blend だけで確定。形式・depth/stencil の有無・標本数は `PassSpec` から backend が引く（WebGPU は pipeline の値が pass と一致しないと検証の誤り）（3.2） |
| 9 の半分 | mask は stencil を要る。stencil の attachment を持つかは pass の性質 | `PassSpec` の depth/stencil の欄で持つ。行の種類は R1b ⇄ P6（3.2） |
| 10 | history の写し（`RenderPaint.prepareHistory`・`Paint.flix:335-362`）が GL の Paint の中にあり、行にも `WebGpu` にも無い | `PassSpec` の欄。`WebGpu` の texture の写しは R1b の history の小分けで足す（3.2） |
| 11・17 | WebGPU は upload の前に積んだ pass を submit する（`WebGpuPaint.flushPending`）。submit の回数は `FLIX_GE_FRAME_STATS` だけで、ベンチと門から見えない | submit が増える道を数えて見えるようにし、staging へ移る条件を決める（3.4） |
| 12 | instance を頂点バッファで読む。面・材質の draw ごとの値をどこに置くか | スプライトは頂点バッファで確定（storage と同じ 1.45 ms【確】・V1）。draw ごとの値は別の Float32 の配列（3.1 の 8） |
| 13・14 | 字の texture の成分（GL `.a`・WebGPU `.r`）と sampler を表の番号の裏に持たせた | 行は texture の番号だけで確定（字の場面は GL と 0 px【確】・V1） |
| 18 | bench が engine の fpkg から `RenderPaint.Internal.*` を呼べない | pub にしない。bench は今の木のまま（3.6） |

R1b ⇄ P6 の 3 つが今の形に足せるか:
- 9（mask）: スプライトの行 + mask の頂点の範囲（`vertices` の中）を持つ種類。stencil の比べる値を進める・255 を超えたら pass を分けるのは backend の中。stencil の attachment は `PassSpec` が持つ（front-end は list に mask の行があれば stencil つきの `PassSpec` にする。pipeline は両方を読み込みの間に作っておく・3.2）。足せる。
- 15（中間の texture）: `PassSpec` の描き先が「画面」なので、backend が中間を使うかを決められる。足せる。
- 16: list と関係ない（`fge-web.js` の読み込みと `?capture`）。

## 3. 案

### 3.0 描く単位: `(PassSpec, 行)` の組の列

第 1 版の「`renderCommands` 1 回 = list 1 本 = pass 1 つ」は 3D で崩れる。親 5.4 は 3D の場面を先に自分の texture へ描き（depth・MSAA・影はその中で閉じる）、2D の z の位置で貼る形で、
今の GL にも `Merged.MScene3d` と `RenderPaint.paintTarget`・`paintFrame` の `prepareScenes` がある。1 回の `renderCommands` が「影の pass → 場面の pass → 2D の pass」と何本も作る。

そこで単位を **`(PassSpec, 行)` の組**にし、1 回の `renderCommands` は**組の順序つきの列**を出す。先に置く pass（影・場面）が前、2D の本体が最後。
3D の場面の組は、親 5.3 のとおり場面の計画（`planScenes`）を持つ front-end が作る（`PassSpec` も front-end が組む）。

- WebGPU: 組を順に encoder へ積む。場面の pass はどれも 2D の pass を開く前に閉じ終わるので、**2D の pass を途中で閉じない**（親 5.4）。貼る行は resolve 済みの texture を読むだけで、encoder の上の順（書いてから読む）も守られる。
- GL: 同じ順に流してよい。今どおり 2D の途中で場面を直に描く形を残すかは、R1b の「3D を貼る」の小分けで決める（その時は front-end が場面の組を作らず、貼る行が場面を描く。capability で切り替える）。
- Pass を何段階も重ねる場面と history は、今どおり `beginTarget`〜`endTarget` ごとに別の `renderCommands` になり、別の組の列で書ける（組の列は 1 回の `renderCommands` の中の順だけを決める）。
- 2D だけの画面では、組は 1 つ（2D の本体）で、今の形と同じ。

### 3.1 スプライトの行

| 軸 | S1. 今の形（Int32 の行・10 欄・Float32 の instance） | S2. 低い高さ（状態の変化を行にする） | S3. 行ごとの record / enum |
|---|---|---|---|
| GL で書く | 行 → 今の GL の関数（17 行） | GL の状態（program・blend の uniform・texture）へ WebGPU の形の命令を訳し直す | 書きやすい |
| WebGPU で書く | 前と同じ物を積まない控えを backend が持つ（`geom`） | 行 = 命令でそのまま | 書きやすい |
| 速さ | 1.2 の表 | ブラウザで減るのは backend の控えと同じ分（scissor の試しで 2.6%）【確】 | 絵が 1 個ごとに替わると行が 20,000 個の割り当て。V1 で record の欄を 1 個ごとに読んだだけで submit 1.28 倍【確】 |
| JIT の罠 | 1 行ごとの `@DontInline` の def で輪が JIT に乗る【確】 | 同じ | 欄の引き当て（`lookupField`）が輪に入る |
| wasm と JS | list を JS へ 1 回で渡す形が乗る（3.5） | 同じ | 乗らない |
| 次の種類 | 欄の意味を種類ごとに変え、長さの変わる物は別の配列の範囲 | 種類ごとの違いが命令に溶けて GL の backend が膨らむ | 足しやすい |

**おすすめ: S1 を残し、次を直す。**

1. **front-end の状態と backend の状態を分ける**（#3）: `st` を run の状態と数え（front-end）と、backend が持つ物（GL は program・VAO・buffer の番号と viewport・WebGPU は今の `geom`）に分ける。draw の数えは今どおり backend が呼ぶ（`countSpriteDraw` を共有・数える先は front-end の配列）。
2. **instance の入れ物は backend が貸す**（#4）: front-end は `instancesFor(n)` で受けた入れ物に書く。GL は `RenderBuf` を貸し、WebGPU は今の LITTLE_ENDIAN の入れ物。
   ブラウザでは、書いた値を `writeBuffer` へ写す所が今の front-end の重さに入っている（1.2 の 11.6 ms の中・未分解）。入れ物を backend が貸す形なら、ブラウザの backend が JS の `Float32Array` を後ろに持つ入れ物へ替える道が残る【推】。
3. **描き先の上下は backend に聞く**（#1）: capability `targetUpsideDown: Bool`（GL は真・WebGPU は偽）。front-end は描き先の表（今の `RenderPaint` の `targetsRef`。3.3 で共有の module へ移す）で名前を引き、真の時だけ uv を返す。`targetNames` の欄は消す。
4. **1 体 38 個は P6 のアトラスの頁でも保つ**: 0〜37 は全部使っている（`writeInstAt`）。頁の層の番号は欄 14（今は useTex の 0 / 1。GLSL も WGSL も `> 0.5` で見る）に「層 + 1」で詰める（0 = texture 無し。Float32 で 2^24 まで正確）。
   頁の中の uv は front-end が欄 6〜9 へ書く。run の鍵は capability `atlasPages: Bool` で切り替える（真 = 頁の texture・偽 = 1 枚ごとの texture。GL は決まり 3 を使わないので偽）。
   front-end が頁の uv を書けない絵（繰り返して貼る・大きすぎる）は今どおり 1 枚の texture。**これで足りなければ 38 は P6 で変わり得る**（その時は 39 個目を足し、GL の属性の並びも 1 本足す）。
5. **長さの変わる物は行に入れない**: 行の幅は固定（今は 10。欄が足りなくなれば `rowStride` を広げる）。面の `texReads` のような物は、別の Int32 の配列の (先頭, 数) を行に持つ。
6. **list は作り終えてから流す**: WebGPU は既にそう（3.0 の場面の pass に要る）。GL は全部の種類が行になるまで、GL を直に呼ぶ種類が来るたびに途中で流す（`flushSprites`）のを残す。
7. **行を流す所は backend が前と同じ状態を積まない**（scissor も。1.2 の A）。
8. **`RenderList` の record の形**（次の種類まで入れた物）:

| 欄 | 中身 | 持ち主 |
|---|---|---|
| `rows` | 頭（行の数・次の instance の番号・次の頂点の番号）と 1 行 10 欄の Int32 | front-end（広げると差し替える） |
| `instances` | 1 体 38 個の Float32（スプライト・字・箱） | backend が貸す（GPU へそのまま送る） |
| `vertices` | 多角形と mask の頂点（今の `polyData` の 1 頂点 6 個） | backend が貸す（同上） |
| `values` | draw ごとの値（タイルの position・面の params）。front-end の並びで書き、backend が uniform か storage へ詰め直す（親 5.1） | front-end |
| `ranges` | 長さの変わる物の中身（`texReads` の texture の番号など）。行は (先頭, 数) を持つ | front-end |

### 3.2 pass の区切り（`PassSpec`）

| 軸 | P1. 今のまま（pass は暗黙。GL は `renderFrameMixed` の中で clear、WebGPU は `openPass(op)` の閉包） | P2. 行の種類にする | P3. 組ごとに型のついた record |
|---|---|---|---|
| 書く | clear・letterbox・viewport の式を両方が別に持つ（GL の clear 33 行・WebGPU の `renderFrame` と letterbox 77 行） | LoadOp と色を Int32 と Float32 へ詰め直し、読む所でほどく | enum のまま読む。letterbox の塗り方（GL は scissor で 2 回 clear・WebGPU は黒で clear して箱 1 個）は backend ごと |
| 速さ | 同じ | 同じ（1 コマに数個） | 同じ |
| 次の種類 | history・resolve・場面の pass を置けない | 置ける | 置ける（欄） |
| コマ全体を溜める形へ変える時 | 作り直し | そのまま | record を行の種類へ 1 対 1 で写す |

**おすすめ: P3。** 組の数は 1 コマに数個で、配列へ詰める得が無い。`RenderTarget.LoadOp` などの enum を型のまま持てる。欄（【推】・名前は R1b-0 で決める）:

共通の欄:

| 欄 | 中身 |
|---|---|
| `target` | 描き先（下の表の 2 つのどちらか） |
| `depthStencil` | 無し / depth / depth と stencil（形式と clear の値）。2D は mask の行がある時だけ stencil、3D の場面は depth |
| `samples` | 標本数 |
| `viewport` | design の矩形を描き先の画素で（左上が原点。GL は y を返す） |
| `copyHistory` | `Option[Int32]`（前のコマを写す先の表の番号。R1b の history の小分けで使い始める） |

描き先ごとの欄（`target` の中身）:

| 描き先 | 欄 |
|---|---|
| `Screen` | `clearColor`・`letterbox: Bool`（色の attachment は画面か中間の texture の 1 つで、backend が決める） |
| `Target` | `colors`: 色の attachment の列。1 つごとに表の番号・形式・`RenderTarget.LoadOp`・resolve 先の番号（標本 2 以上の時）。今は 1 つだけ使う（親 12.3: 名前つきの attachment を後で足せるように列にしておく） |

- **pipeline の数え方**: 鍵（親 7 章）は blend × 色の形式の列 × depthStencil × 標本数 × 頂点の形。このうち色の形式の列・depthStencil・標本数の 3 つは `PassSpec` から backend が引く（#8）。
  2D のスプライトは stencil つきと無しの両方を数えるので、V1 の 6 本（blend 3 × 形式 2）は 12 本になる。
- **stencil つきと無しの両方の pipeline を、読み込みの間に作っておく。** mask が初めて出たコマで stencil つきの pipeline を作り始めると、1 本 65〜93 ms（親 4.3）かかり、できるまで単色で描くので、そのコマは普通のスプライトまで崩れる。
  WhyNot: 画面と中間の texture をいつも stencil つきにしない — stencil の attachment のメモリと、毎コマの clear と書き出しの帯域を、mask を使わないゲームまで払う。

pass の途中で分ける事（mask が 255 を超える）は backend の中で決める。

### 3.3 upload（texture と buffer を GPU へ上げる指示）

| 軸 | U1. 今のまま（GL は `GlContext` を受ける読み込み・WebGPU は写した別の道） | U2. list に「上げる行」を入れる | U3. 即時の upload を 1 本にする |
|---|---|---|---|
| 書く | 読み込み 9 種を backend ごとに 2 本（約 300 行が 2 本目） | 上げる中身を list が流れるまで持つ。list はすぐ流れるので、外で即時に呼ぶのと同じ結果 | 読み込みは 1 本・backend ごとの実装 2 つ |
| WebGPU の順（`writeTexture` は積んだだけの pass より先に反映される） | 上げる前に submit（`flushPending`） | list に入れても同じ（queue の書き込みは encoder の外）。直すには staging buffer と `copyBufferToTexture` を `WebGpu` に足す（GL の層の jar のハッシュが動く） | 上げる前に submit を backend の中に残す（3.4） |
| 次の種類（タイルの buffer・static layer・3D の形） | 種類ごとに 2 本ずつ増える | 足せる | op を足す。3D の `meshEntry` も描く前に呼ぶ形へ移せる（親 5.3 の「上げる行を先頭に」と同じ順） |

**おすすめ: U3。** 「上げる行」の狙い（描く前に上げ終える・描く所で上げない）は、list が即時に流れる限り「list を作る前に upload を呼ぶ」で満たせる。
op（【推】）: texture を作る（形式・filter・address）・中身を書く・外の画像を写す（ブラウザの `ImageBitmap`。#19 の読み戻しを無くす）・捨てる・buffer を作る・書く・捨てる。返すのは backend の表の番号（`GpuHandle` の読み替え・親 5.3）。
CPU の側の表（登録簿・key・描き先の表・`lastFrame`）は共有の module に置き（#5）、`RenderPaint` と `WebGpuPaint` が同じ関数を呼ぶ。

U3 をどう渡すか:

| 形 | 良い所 | 困る所 |
|---|---|---|
| (a) 今の pub の effect `GpuResources` の handler を backend ごとに持ち（今もある: `RenderPaintHandlers`・`WebGpuPaint.handleGpuResources`）、表は共有の module | 新しい物を足さない | 読み込み（`AssetLoader`・`LwjglAssets.loadTexture` など）は `GpuResources` の外で `GlContext` を受けていて、op も足りない（作る・外の画像・buffer）。足すと engine の pub が増える |
| (b) 関数の record（`WebGpuRows.renderFrame` の `cfg` と同じ流儀）を、今 `GlContext` を渡している所へ渡す | 行を流す所と同じ流儀。GL の側は `GlContext`（Java の interface）を渡していたのと同じ形。effect の行が関数の型に乗らない | record を持ち回る引数が 1 つ増える |
| (c) render_gl の中の新しい effect | 「機種の差は handler で受ける」（親 12.4 の 4） | 親 12.1 の「ブラウザで 9%」は、effect を背負った def を呼ぶたびの続きの入れ物の値段（perform の回数ではない）。列を作る def（`emitSprite` など）の型にこの effect が乗ると 1 体ごとに払う。handler を差す場所と `run` を入れ子にしない決まり（1 関数に 1 つ）も要る |

**おすすめは (b)。** 決まり: upload の record は list を作る def（`emitSprite` など 1 体ごとに通る物）へ渡さない。
(c) を選び直す時は、上の決まりを effect に読み替え、`docs/flix-conventions.md` の「層を置く物差し」の表に 1 行足す（R1b-0b の設計で決める）。

### 3.4 submit が増える道と staging へ移る条件

WebGPU は upload の前に、そのコマに積んだ pass があれば submit する（`WebGpuPaint.flushPending`。V1 3.2）。呼び手は 8 か所【確・`bin/fge refactor usages … --callers`】:

| 呼び手 | どんな時 |
|---|---|
| `uploadRgba`・`uploadBgra`・`uploadR8` | texture を作る（起動・`ensureTexture` の初めての名前・ブラウザの後回しの絵が届いた時） |
| `rewriteSlot` | `ensureTexture` の key が変わり大きさは同じ（毎コマ key が変わるゲームは毎コマ） |
| `dropSlot` | `ensureTexture` の大きさが変わった・`beginTarget` が描き先を作り直す |
| `beginTarget` | 描き先の形が変わって作り直す |
| `resize` | 中間の texture を作り直す |
| `sendInstances` | instance buffer が溢れた（submit して頭から使い直す・それでも足りなければ伸ばす） |

- V1 の記録では、`bench/webgpu_v1` の 9 場面のうち Pass の後に生成の絵を書き替える場面だけが 2 回、ほかは 1 回。sprite_stress と rpg-starter の title は 1 回。第 1 版の「1 コマ 1 回【確】」は言い過ぎだった。
- もう 1 つの道: PC で起動の後に字を足す（GL は `RenderPaint.ensureGlyphs` → `RenderGlyphGrow.ensure` → `growAll` → `growOne`）。V1 は WebGPU でこれをしていない。WebGPU に入れると、コマの途中の upload になる。
- 値段: ブラウザで 1 コマに 1 回足しても CPU の側は差が見えない（1.2 の E）。GPU の側は測っていない。
- **#17 は形で決める**: R1b-0b で submit の回数を backend が数え、`FLIX_GE_FRAME_STATS` に加えて sprite_stress の区間の JSON（`submits`）に出す。engine の pub の `FrameDiagnostics` へ足すのは engine の拡張なので、その時に別に相談する。
- **staging へ移る条件**: テンプレ 3 本と `gl-capture` の場面のどれかで、1 区間（300 コマ）の半分を超えるコマが submit 2 回以上になった時。staging は `WebGpu` に `copyBufferToTexture` を足し、上げる中身を encoder の上の順に並べる（P6 で比べる）。
- 親 6.1 の決まり 6（「送るのは 1 コマ 1 回」）は、親 5.1 の「list ごとに `writeBuffer`」と既にずれていて、U3 はそれを広げる。親へ書き足す時に、決まり 6 を「行と頂点は 1 コマぶんを 1 本に詰める（upload は除く）」と書き直す。

### 3.5 その場で流す・持ち越す list（P9）・JS へ 1 回で渡す形

- **いつ流すか（親 9.1）**: その場で流すで確定。コマ全体を溜める理由（JS との行き来をまとめる）は、下の「JS へ 1 回で渡す形」で別に取れる。溜めると Pass の間の upload の順を list に入れる決まりが要る。
- **P9（動かない物の持ち越し）がこの形に乗るか**: 親 6.2 の 10 は、front-end が行を持ち越し、WebGPU は行と render bundle を持ち越す。
  - 持ち越す list はコマごとに消さない（鍵を付けて残す）。その instance は、今の `sendInstances` の buffer（submit のたびに頭から使い直す）とは別の、持ち越す buffer に置く。
  - 行の番号は list ごとに 0 から・起点は backend が足す（#2）なので、持ち越す list は起点が「持ち越す buffer の中の位置」になるだけで、行は変わらない。
  - 「bundle を流す」行の種類を 1 つ足す（WebGPU は `executeBundles`・GL は持ち越した行を流し直す）。bundle の中では scissor・stencil の比べる値・blend の定数を変えられない（親 6.2 の 10）ので、front-end はそれらが変わる行を持ち越す list に入れない。
- **JS へ 1 回で渡す形（親 9 章の「後」）**: 行は Int32 の配列なのでそのまま渡せる。要るのは JS の側にも bind group と pipeline の表（番号 → `GPUBindGroup`）を持つ事。書き出しは WebAssembly GC で、1.2 の 1 行 約 0.45 µs の大半はこの wasm から JS への行き来と見ている【推】。試しのコードで JS の輪へ移すと絵 16 種の submit が 29.6 → 25.2 ms になった（6.3）。

### 3.6 名前・置き場・pub

- **名前は `RenderList` のまま（決めた）。** `DrawList` は engine_tools の `SoftRaster.Internal.DrawList`（CPU の描き手の中身）・`DrawCmd`・`Counter.DrawCalls` と字が重なり grep で混ざる。
  Godot の RenderingDevice の forward renderer（`RenderListParameters` などの render list）と three.js の `WebGLRenderList` も、1 コマに描く物を並べた list を同じ名前で呼ぶ（AGENTS.md の命名の 3）。
  今の型とテスト（`TestRenderList`）を 1 字も変えずに済む。親の文書の `DrawList` は、了承の後に親を書き直す時に `RenderList` へ直す。
- **置き場**: `RenderFrame.Internal.RenderList`（行の型と足す・読む関数）と `RenderFrame.Internal.GlRows`（GL の流し方）へ出す。`Frame.flix` は 1,162 行で上限 1,200 行。
  子孫は先祖の pub でない物を読め、先祖は子孫の pub を呼べる【確・V1 1.1】ので、`Internal` の下に置けばゲームからは lint の `app-internal` で止まる。
- **pub にしない**（#18）。engine の pub と `mod RenderFrame` の pub は変えない。3 つ目の backend を別のパッケージに置く時に P10 で見直す。

## 4. 決めた後の段取り

R1b の頭に R1b-0 を置く（R1b の最初の小分け「物の上げ下ろしと寿命の表」と同じ所を触るので続けて入れる）。

| 段階 | 中身 | 門 | 実時間【推】 |
|---|---|---|---|
| R1b-0a-1 | `RenderList` と GL の流し方を `RenderFrame.Internal.RenderList`・`GlRows` へ移すだけ（中身は変えない）。commit を分ける | `make check`・`TestRenderList` 緑 | 0.5 時間 |
| R1b-0a-2 | `st` を分ける・入れ物を backend が貸す（`vertices` も）・`targetUpsideDown`・組の列と `PassSpec`（GL の clear と WebGPU の `loadOpOf`・`clearBox` をこれで受ける）・行を流す所で scissor も前と同じなら積まない | `gl-parity` 0 px・テンプレの `reference`・`gl-capture-check`・`make webgpu-v1-check` と `-web` が 0 px・sprite_stress（下） | 1.5〜2 時間 |
| R1b-0b | upload の関数の record と CPU の側の表の共有・`copyImageBitmap` を直に表へ載せる・submit の数（3.4） | 同じ門と、ブラウザの絵（`hasAlpha = false` を含む）が WebGL2 と 0 px・`submits` が出る | 0.5〜1.5 時間（R1b の見積もりの中） |
| レビュー | 1 回目で全部の指摘を出させ、まとめて直して 2 回目 | 90 点 | 上に含む |

- 合わせて 2.5〜4 時間（R1b-0a は 2〜2.5 時間）。物差し: P4b 約 1 時間・V1 約 2 時間 10 分（設計の 8.5〜11 時間に対し）。R1b-0a-2 は V1 の段階 1〜2 ほどの量【推】。親の R1b ⇄ P6 の 18〜26 時間は変えない。
- **sprite_stress の門**: 絵 1 種と 16 種を PC とブラウザで、前と後を 3 回ずつ交互。中央値で 5% 以内。**どちらかの 3 回の幅が 5% を超えるか、前と後の幅が重なって 5% の内か外かを言えない時は、3 回ずつ足して 6 回の中央値で決める。** それでも言えなければ「判定できない」として数字を付けて人に見せる（ブラウザの WebGL2 は 3 回の幅が既に 4.8% ある・1.2）。

## 5. 人に伺う事（2026-11-15 に 3 つとも了承。頭の「決まった事」）

1. **親 5.1 の表を改める事**: 「pass の区切り」と「物の上げ下ろし」を行の種類から外す。pass は組ごとの `PassSpec`（3.0・3.2）、upload は即時の関数の record（3.3）にする。
   **おすすめはこの形**（list は即時に流れ、組ごとに pass が 1 つなので、行にする得が無い。コマ全体を溜める形へ変える時は record を行の種類へ 1 対 1 で写せる）。了承をいただいたら、親の 5.1・6.1 の決まり 6・9.1・12 章へ書き足す。
2. **ブラウザの速さ**: ブラウザの絵が多い場面は、P6 のアトラスの頁が入るまで WebGPU でも WebGL2 とほぼ同じ（絵 16 種で submit 0.91 倍）。リリース 2（2D のゲームが WebGPU を試しに選べる）の時点でこれで良いか。
   **おすすめは「良い」**（PC は既に 0.33 倍。アトラスは P6 の最初に入る）。
3. **コマの途中の submit**: P6 で staging を比べるまで、WebGPU の submit が 1 コマに 2 回以上になる場面を許すか（`ensureTexture` の key が毎コマ変わり Pass もあるゲームなど）。
   **おすすめは「許す」**（絵は GL と同じ・CPU の側の値段は測って見えない・3.4 の条件を超えたら staging へ移る）。

技術の細部（欄の並び・関数の record の op の名前・R1b-0 の分け方）はこちらで決めて R1b-0 の設計に書く。

## 6. スパイクの結果（2026-11-15・試しのコードは commit していない）

人の返事 1 を受けて、まだ試していない候補を今の案（S1・組ごとの `PassSpec`・upload は関数の record・その場で流す）と比べた。
測ったのはブラウザ（Chrome 156 ヘッドレス）。どの回も測る前と後に `ps` で他の重い java が無い事を見て、3 回ずつ交互に流した。

### 6.1 (a) upload: その場で submit する今の案 と staging

- **試していない。** 理由: staging が無くす物（コマの途中の submit 1 回）の CPU の値段が、1.2 の E で 0.1 ms の刻みより小さく、比べても差が出ない。staging の側には、staging buffer への写しと `bytesPerRow` の 256 そろえの詰め直しが CPU に足される。
- staging に要る物: `fge.webgpu.CommandEncoder` に `copyBufferToTexture` を 1 つ（interface と Dawn とブラウザの 3 か所）。GL の層の jar のハッシュが動き、`make gl-jar-pin` で 3 つの flix.toml と jar の置き直しが要る。
  ほかに staging buffer の ring（`WebGpuPaint` に 1 本）。interface に無い物はこの 1 つだけ。
- `passThenGenerated` の場面（V1 の記録で submit 2 回）は PC の `bench/webgpu_v1` の木を組み直す手間があり、測っていない。GPU の側の値段も測っていない。staging へ移る条件（3.4）は submit の数で見るので、この場面は R1b-0b で `submits` を出した後に数で追う。
- **結論: 今の案のまま**（人の返事 3 で P6 まで許す事になった）。

### 6.2 (b) pass: 組ごとの `PassSpec` と、pass の区切りも行の 1 種類にする形（元の親 5.1）

書き味だけで比べた（速さは 1 コマに数個の物なので差が出ない）。

| 見る点 | 組ごとの `PassSpec`（今の案） | pass の行 |
|---|---|---|
| front-end で書く | record を 1 つ作る（約 10 行） | LoadOp の 3 つ・clear の色・depthStencil・標本数・viewport・`copyHistory` を Int32 と Float32 へ詰める。色の attachment の列は長さが変わるので `ranges` へ（約 30 行【推】） |
| GL で読む | 欄を読む（約 5 行） | ほどく（約 25 行【推】） |
| WebGPU で読む | 欄を読む（約 5 行） | ほどく（約 25 行【推】） |
| 3D の場面 | 場面ごとに組を 1 つ前に置く | 1 本の list の中に pass の行を何本も置く |
| history | `copyHistory` の欄 | pass の行の欄 |
| mask | `depthStencil` の欄（stencil）。255 を超えた分け直しは backend | 同じ（分け直しを pass の行で書く事もできる） |
| コマ全体を溜める時 | 組を行の種類へ 1 対 1 で写す | そのまま |

- pass の行の得は「1 本の list に pass を何本も入れられる」事だけで、それが要るのはコマ全体を溜める形を選んだ時。6.3 のとおり、JS へ 1 回で渡す得は list ごとに取れ、溜める形は要らない。
- **結論: 今の案（組ごとの `PassSpec`）のまま。** 書く量が少なく、enum を型のまま読める。

### 6.3 (c) list: その場で流す と JS へ 1 回で渡す形（ブラウザの wasm から JS への行き来を減らす）

試しのコード: 行を流す所を、Flix で 1 行 3 個（bind group の番号・体数・`firstInstance`）の `int[]` に詰め、ブラウザの実装で `Int32Array` に写して JS の輪で `setBindGroup` と `draw` を回す形に替えた。
bind group は作った時に JS の側の配列へ登録し、番号で引く（3.5 の「JS の側にも bind group の表」）。足した物は `fge.webgpu.RenderPass.drawPacked`・`BindGroup.jsId`（どちらも default の method）とブラウザの実装、`WebGpuRows` の詰める輪（約 25 行）。
scissor と pipeline は pass の頭で 1 回だけ積んだ（sprite_stress の場面はどちらも変わらない。本番では JS の輪でも前と同じ物を積まない控えが要る）。
絵は `?capture=10`（`n=2000&tex=16`）の PNG が今の形とバイトまで同じだった。

| 版（`backend=webgpu`） | 1 回目 | 2 回目 | 3 回目 | 中央値（submit / cpu・ms） |
|---|---|---|---|---|
| 絵 16 種・今の形 | 29.1 / 44.4 | 29.6 / 45.3 | 29.9 / 45.6 | 29.6 / 45.3 |
| 絵 16 種・JS の輪 | 24.9 / 40.0 | 25.4 / 40.9 | 25.2 / 40.8 | 25.2 / 40.8 |
| 同じ絵・今の形 | 15.3 / 30.8 | 15.4 / 30.9 | 15.4 / 30.9 | 15.4 / 30.9 |
| 同じ絵・JS の輪 | 15.5 / 30.9 | 15.3 / 30.6 | 15.4 / 30.8 | 15.4 / 30.8 |

- 絵 16 種で submit が 15% 下がった（29.6 → 25.2 ms）。1.2 の C（`setBindGroup` と `draw` を呼ばない）の 21.5 ms との差 3.7 ms が、JS の輪の中の 20,000 回の `setBindGroup` と `draw` の分。同じ絵（行が 1 つ）は変わらない。
- 人の返事 2 の「後で速くなる余地」はある: JS へ 1 回で渡す形で −15%、P6 のアトラスの頁（この場面は draw 1 本になる）でさらに下がる見込み【推】。
- この形は**その場で流すまま**取れた（list ごとに渡す）。コマ全体を溜める形は要らない。持ち越す list（P9）も、行の配列を JS の側へ持ち越せば同じ輪で流せる【推】。
- interface に足す物（`drawPacked`・`jsId`）は GL の層の jar のハッシュを動かすので、入れるのは P6 の頭（アトラスと同じ時）にし、親 9 章の「後」から前に出す事を P6 の設計で決める。
- **結論: 今の案のまま**（Int32 の行は JS へそのまま渡せた。形を変えずに取れる）。

### 6.4 まとめ

| 候補 | 試したか | 結論 |
|---|---|---|
| (a) staging | 試していない（減らせる値段が測れる大きさに無い） | 今の案のまま |
| (b) pass の行 | 書き味で比べた | 今の案のまま |
| (c) JS へ 1 回で渡す | 試した（絵 16 種で −15%・絵は同じ） | その場で流すままで取れる。今の案のまま。P6 の頭で入れるかを決める |

**比べた上で今の案。** 乗り換えた所は無い。

## 7. 実装で分かった事（R1b-0・2026-11-15・枝 `webgpu-r1b0`）

入れた物は 3 つの commit（R1b-0a-1・0a-2・0b）。置き場は `render_gl/src/RenderFrame/Internal/RenderList.flix`（行の型・`PassSpec`）・`GlRows.flix`（GL の backend）・
`render_gl/src/RenderPaint/Internal/TextureTable.flix`（絵の CPU の側の表と `Uploads`）。`Frame.flix` は 1,162 行 → 965 行。

### 7.1 3 章と食い違った所・決めた範囲で止めた所

| # | 3 章の案 | 入れた形 | 理由 |
|---|---|---|---|
| 1 | `targetNames` の欄は消す（3.1 の 3） | `FrameArgs#targetNames` は残し、front-end が `targetUpsideDown` を backend に聞いて、真の時だけ使う（WebGPU は描き先の表を引かない） | `FrameArgs` と `renderFrameMixed` は `mod RenderFrame` の pub で、3.6 の「pub を変えない」と食い違う。もう 1 つ、描き先の表が backend ごとにあり共有されていない（#11）ので、front-end が自分で引ける表が無い。`FrameArgs` を Internal へ移す時（R1b）に消す |
| 2 | clear・letterbox は `PassSpec` で受ける（3.2） | GL は `GlRows.renderPass(gl, args, pass)` が `pass` だけを読む。`FrameArgs#targetClear` は残り、`renderFrameMixed`（pub・呼ぶのはテストだけ）は `targetClear` から `pass` を作る（Pass の番号は -1・形式は Rgba8Unorm。GL はどちらも読まない） | 上と同じ。`targetClear` と `pass` が二重に持つのは #1 と一緒に消す |
| 3 | 組の列 `(PassSpec, 行)`（3.0） | 型は作っていない。1 回の `renderCommands` は組 1 つ | 2D だけの今は組が 1 つで、GL は GL を直に呼ぶ種類の手前で行を途中で流す。3D の場面の pass を組にする R1b の小分けで型にする |
| 4 | stencil つきと無しの pipeline を読み込みの間に両方作る（3.2） | `PassSpec#depthStencil` の欄と WhyNot だけ（WebGPU は `NoDepthStencil`・GL は `DepthAndStencil`） | WebGPU の行に mask がまだ無い（brief どおり「形の余地」） |
| 5 | `copyHistory`（3.2） | 欄だけ。どちらの backend も読まない（いつも None） | history の写しは R1b の history の小分け |
| 6 | `RenderList` の `values`・`ranges`（3.1 の 8） | 入れていない（`vertices` だけ足した） | 使う種類（タイル・面）がまだ行に無い |
| 7 | 行を流す所は前と同じ scissor を積まない（3.1 の 7） | WebGPU だけ（`WebGpuRows.applyScissor`）。GL は今のまま | GL は行の間に GL を直に呼ぶ種類（面・mask・3D の場面）が scissor を触るので、控えが外れる。GL の種類が全部行になってから入れる |
| 8 | upload を関数の record に 1 本化（3.3 (b)） | `TextureTable.Uploads`（`createArgb`・`writeArgb`・`drop`）で `ensureTexture` と組み込みの放射の絵だけを 1 本にした | 読み込み（`RenderPaint.AssetLoader` は `GlContext` を受ける pub の型・`LwjglAssets.loadTexture`）を record に替えるのは pub の型の変更。PC の WebGPU の stb の読み込み（`WebGpuWindowLayer.loadImageOrBug`）は GL と成分の数が違う（GL は alpha の無い絵を RGB の 3 成分で上げ、WebGPU は 4 成分で読んで alpha を埋める）。op の「外の画像を写す」「buffer」も未 |
| 9 | `copyImageBitmap` を直に表へ載せる（4 章の R1b-0b） | していない | `hasAlpha = false` の絵は alpha を 255 で埋める所が CPU にあり、`copyExternalImageToTexture` では埋められない。`BrowserWebGpu`（engine_web/java）と `fge-web.js` に手が要る |
| 10 | `submits` を sprite_stress の区間の JSON に出す（3.4） | 出していない。PC の `FLIX_GE_FRAME_STATS` の行だけ（下の 7.2） | bench が読めるのは engine の pub の `FrameDiagnostics` だけで、欄を足すのは engine の拡張（3.4 の「その時に別に相談」）。ブラウザには `FLIX_GE_FRAME_STATS` そのものが無い |
| 11 | CPU の側の表（登録簿・key・描き先の表 `targetsRef`・`lastFrame`）を共有の module へ（3.3・#5） | 共有したのは登録簿と ensureTexture の key だけ（`TextureTable.Tables`）。描き先の表と `lastFrame` は `RenderPaint` と `WebGpuPaint` に 2 本のまま | 描き先の表の中身が backend の物（GL は `RenderTargetGl.Entry` の FBO・history、WebGPU は `TargetSlot` の texture）で、共有するには名前 → 表の番号・形の表と backend の実体の表に割る作り替えが要る。`lastFrame` は Paint の型（`RenderPaint.Paint` は pub の record）の欄で、動かすと pub が変わる。R1b の「物の上げ下ろしと寿命の表」の小分けで、#1 と一緒に入れる |

### 7.2 submit の回数

- PC の `FLIX_GE_FRAME_STATS=1` の行の終わりは、前は「行を出したコマ 1 つの submit の数」だった。staging へ移る目安（3.4: 半分を超えるコマが 2 回以上）を見るには足りないので、
  前の行の後のコマのうち 2 回以上だったコマの数と、1 コマの一番多い回数（`・submits 2 回以上 k/n コマ（最大 m）`）にした（`WebGpuPaint.takeSubmitCounts`）。
  `RenderFrameStats.record` の `tail` は行を出す時だけ組む関数にした（render_gl の中の pub で、engine の pub ではない）。
- `bench/webgpu_v1`（`make webgpu-v1-check` の 1）は場面ごとに submit の数を出す: 9 場面のうち `passThenGenerated` だけ 2、ほかは 1（V1 の記録と同じ）。
- テンプレ 3 本（PC の WebGPU・`FLIX_GE_FRAME_STATS=1`・入力なしで最初の場面のまま 600 コマの行を 3 本以上。測る前の `ps` で重い java は無かった）:

| テンプレ（最初の場面） | 行の数 | `submits 2 回以上 k/n コマ` | 最大 |
|---|---|---|---|
| rpg-starter（title） | 7 | どの行も 0（0/607・0/600 × 6） | 1 |
| sound-novel-starter（最初の場面） | 14 | どの行も 0（0/656・0/600 × 13） | 1 |
| tidepool-starter（最初の場面） | 3 | どの行も 0（0/689・0/600 × 2） | 1 |

  3.4 の staging へ移る条件（半分を超えるコマが 2 回以上）には、測った場面のどれも掛からない。

### 7.3 門の結果

- テスト: render_gl 336（1 回目のレビューの直しの後）・engine_world 1473・engine_tools 305・engine 964 が緑（render_gl は TestTextureTable・TestSubmitCounts・pass と scissor のテストを足し、WebGpuRows の pass の 2 本を TestRenderList へ移した）。
- `make gl-parity` 緑（castShadow の 565 px は前からの B）。テンプレ 3 本の `reference-check` 緑（rpg 16 枚・novel 43 枚・tidepool 8 枚）。
- `make webgpu-v1-check` 緑（9 場面 0 px・rpg-starter の title の GL と WebGPU 0 px）・`-web` 緑（WebGL2 と 0 px）・`webgpu-check`・`-web`・`-same` 緑。
- `make gl-capture-check`: 基準 0.88.4 と違うのは 30 枚で、R1b-0 の前の main（`7189053a`）で撮った 54 枚の SHA256SUMS とバイトまで同じ（増えていない）。
- `lint-huge-methods`（engine・rpg-starter）・`gl-jar-pin-check`・`go test ./...`・`bin/fge export-web templates/rpg-starter` の ⑨ が緑。render_gl/java は触っていない。

sprite_stress（20,000 個・2 区間目・前 = `7189053a`・後 = R1b-0。前と後を交互に。どれも 3 回の幅が 5% を超えたか重なったので 6 回の中央値）:

| 場面 | 前 frame / submit | 後 frame / submit | 後 / 前 |
|---|---|---|---|
| PC GL 絵 1 種 | 7.241 / 2.188 | 7.220 / 2.200 | 1.00 / 1.01 |
| PC WebGPU 絵 1 種 | 6.960 / 2.141 | 7.050 / 2.212 | 1.01 / 1.03 |
| PC GL 絵 16 種 | 41.309 / 35.927 | 41.489 / 36.094 | 1.00 / 1.00 |
| PC WebGPU 絵 16 種 | 13.742 / 5.974 | 13.593 / 5.967 | 0.99 / 1.00 |

| 場面（ブラウザ） | 前 submit / cpu | 後 submit / cpu | 後 / 前 |
|---|---|---|---|
| WebGL2 絵 1 種 | 13.70 / 29.7 | 14.25 / 30.6 | 1.04 / 1.03 |
| WebGPU 絵 1 種 | 16.45 / 32.8 | 16.60 / 32.8 | 1.01 / 1.00 |
| WebGL2 絵 16 種 | 34.30 / 51.9 | 34.90 / 52.6 | 1.02 / 1.01 |
| WebGPU 絵 16 種 | 31.65 / 47.9 | 31.20 / 47.55 | 0.99 / 0.99 |

- PC の WebGPU 絵 1 種は、1 回の起動の中で submit が約 5.2 ms に張り付く回が混ざる（2 峰）。同じ場面を前と後で 8 回ずつ足すと、前 2/8・後 2/8（合わせて前 2/14・後 4/14）で、前にも出る。V1 の記録（RESULTS.md の「約 5 ms の submit が混ざる回」）と同じ物で、R1b-0 で増えたとは言えない。
- ブラウザの WebGL2 絵 1 種は後が 6 回とも前の中央値より高く（+4%）、5% の内だが向きは揃っている。後の 1 回目は別の作業場の java（索引づくり 3 本）が動いていた回。

### 7.4 持ち越し（R1b ⇄ P6）

- 7.1 の #1・#2（`FrameArgs` を Internal へ移して `targetNames`・`targetClear` を消す）・#3（組の列の型）・#7（GL の scissor の控え）・#8（読み込みの record・stb の 2 本目）・#9（`copyImageBitmap`）・#10（`FrameDiagnostics` に `submits`・engine の拡張の相談）・#11（描き先の表と `lastFrame` の共有）。
- submit の回数を測っていない場面: テンプレの最初の場面より後（rpg-starter の field・battle・talk、tidepool の level などの Pass や生成の絵を使う場面）・`gl-capture` の場面。入力を流して回す口が要る。
- WebGPU の行を流す所の scissor の式（`WebGpuRows.scissorInto`）と GL の `GlRows.setScissorAt` は、同じ交わしを 2 本で書いている（GL は左下原点で描き先の外へ切らない）。1 本にするのは見送った。
- ブラウザの WebGPU の submit の回数を出す口（`FLIX_GE_FRAME_STATS` に当たる物がブラウザに無い）。

### 7.5 R1b-0 の 1 回目のレビュー（84 点）への対応

| # | 指摘 | 直した所 |
|---|---|---|
| R1 | 3.3 の描き先の表と `lastFrame` の共有が半分で 7 章に無い | 7.1 の #11・#1 の理由・7.4 |
| R2 | `FrameArgs` の `targetClear`・`targetNames` のコメントが古い | 今読む所（`passOfArgs`・上下逆に格納する backend だけ）と、pass と二重で残す WhyNot に直した |
| R3 | staging へ移る条件をテンプレで確かめていない | 7.2 の表（3 本とも 0）・測っていない場面は 7.4 |
| R4 | 1 コマの submit の数えにテストが無い | `noteFrameSubmits`・`takeSubmitCountsOf` を配列を受ける def に切り出し、`TestSubmitCounts` 3 本 |
| R5 | 親の文書の `DrawList` と 5 章の約束 | `plans/engine-webgpu.md` の `DrawList` を `RenderList` へ（11 章の 7 は名前を決めた文に）・5.1・6.1 の決まり 6・9.1・12.15 へ書き足した |
| O1 | 多角形ごとに `list#vertices` を引く | `emitFrameMixed` で 1 回読み、`vertices` を引数で回す |
| O2 | `formatOf`・`clearColorOf` の置き場と空の列 | `RenderList.targetFormatOf`・`screenClearColorOf` へ寄せ、`PassTarget.Target(ColorAttachment, List[ColorAttachment])` にした |
| O3 | 呼ばれない `targetNames` | `WebGpuRows.renderFrame` の cfg から消した。2 回目のレビュー（91 点）の N1 で、WebGPU にも `targetUpsideDown() = false` を戻し、`upsideDownTargetsOf(targetUpsideDown(), () -> Set.empty())` で backend に聞く形を残した（cfg の欄は増やさない） |
| O4 | `passOfArgs` の標本数 | WhyNot を 1 行 |
| O5 | コメントの予定の参照 | 自分が書いたコメントから文書の参照と予定を消した |
| O6 | `lendRenderList` | `prepareRenderList` |
| O7 | 完全名 | `use` に |
| O9 | scissor の控え・左右の黒帯・放射の絵のテスト | 比べる所（`isSameScissor`）と控える所（`noteScissor`）を分けてテスト・左右の黒帯の viewport・`putRadialBuiltins` の 2 枚 |
| O8・O10 | | 見送り（指示どおり） |

## 第 1 版のレビュー（74 点）への対応

| # | 指摘 | 入れた所 |
|---|---|---|
| 1 | 「1 回 = list 1 本 = pass 1 つ」が 3D と影で崩れる | 3.0（`(PassSpec, 行)` の組の列・場面の組は front-end・2D の pass を途中で閉じない・encoder の順・Pass の重ねと history） |
| 2 | 「submit は 1 コマ 1 回【確】」が V1 の記録と食い違う | 3.4（呼び手 8 か所・字を足す道・E の値段・#17 を形へ・staging の条件・決まり 6 の書き直し）。要約 5 |
| 3 | 同じ絵の 14.1 ms の取り違え | 1.2（D で `writeInstAt` 3.9 ms・残り 11.6 ms は front-end で未分解）・3.1 の 2（`Float32Array` の入れ物の道） |
| 4 | 38 個とアトラスの頁 | 3.1 の 4（欄 14 に層 + 1・run の鍵は capability `atlasPages`・変わり得る範囲） |
| 5 | `PassSpec` に attachment | 3.2 の表（色の列・depthStencil・標本数・#8 に stencil と標本数） |
| 6 | P9 の render bundle と JS へ 1 回 | 3.5 |
| 7 | upload を effect にする判断 | 3.3 の (a)(b)(c) の表・おすすめを (b) へ・決まり（list を作る def に渡さない）・(c) の時の物差しの 1 行 |
| 8 | `RenderList` の record の形 | 3.1 の 8・1.3 の `vertices` |
| 9 | 要約の物差し | 要約 6・1.2 の表の右の列 |
| 10 | R1b-0a を分ける・見積もり・ブラウザの 5% | 4 章（0a-1 と 0a-2・2.5〜4 時間・幅が重なった時に 3 回足す） |
| 11 | 人に伺う事を人が決める物に | 5 章（名前は 3.6 で決めた・速さと submit の 2 つを足した） |
| 12 | #17 と #9 の仕分け | 2 章の仕分けの表・#9 の半分の行 |
| 13 | 要約に英語・読めない字・「段」の警告 | 要約（render target・texture・upload・letterbox・front-end・list・row）・「段」を「段階」へ |
| 14 | 名前の理由に Godot と three.js | 3.6 |
| 15 | 見本の「同じ形」が事実と違う | 1.3（`WebGpuRows.drawRow` の実際の引数・そろえるのは分け方だけ） |
| 16 | C で bind group の引き当ても飛ばしたか・GPU プロセスの分 | 1.2（C の定義と A − C の注） |

2 回目のレビュー（90 点・合格）の残り 4 件: stencil つきと無しの pipeline を読み込みの間に両方作る（3.2・本数は 12 本）・内訳の「`renderCommands` の中で」（1.2）・`PassSpec` の欄を共通と描き先ごとに分けた（3.2）・同じ絵のこの日の値 15.5 ms（1.2 の表）。
