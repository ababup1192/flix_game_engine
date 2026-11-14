# H: WebGPU の命令・機能で、描き手を速く単純にできる物（2026-11-14 調べ）

【確】=一次資料か手元の実測で確認　【推】=二次資料・推測　【不明】=確かめられず
手元の生データ: `h/web-adapter.json`（Chrome 156 headless・Apple M4 Pro）・`h/web-prototypes.json`（各 encoder の全メソッド名）・`h/pc-dawn.txt` `h/pc-wgpu.txt`（jWebGPU 0.3.4 の Dawn / wgpu）。

## 0. 先に結論
- 【確】`multiDraw*` は標準に無い。Chrome の `chromium-experimental-multi-draw-indirect` は開発者フラグの奥で、全体の対応は 0.12%（web3dsurvey）。**当てにしない**。`drawIndirect` / `drawIndexedIndirect` は 1 回に 1 つの draw だけ。
- 【確】直の `draw(vertexCount, instanceCount, firstVertex, firstInstance)` の `firstInstance` は標準（機能不要）。**1 つの instance buffer を `firstInstance` で切って、`instance_index` を「物の番号」にする**のが multi-draw 無しの定番。indirect で `firstInstance` を使う時だけ `indirect-first-instance`（全体 99.98%・Safari / Firefox も 100%）が要る。
- 【確】新しい物のうち「大半の端末で使える」のは `timestamp-query`(98.8%)・`indirect-first-instance`・`depth-clip-control`・`depth32float-stencil8`・`rg11b10ufloat-renderable`・`shader-f16`(94%)・`float32-blendable`(94%)・`bgra8unorm-storage`(96%)。**狭い**のは `dual-source-blending`(Safari 5%・iOS 0.1%)・`subgroups`(Safari 1%・Firefox 0.1%)・`primitive-index`(iOS 55%・Firefox 1%)・`texture-compression-astc/etc2`(47%)・`bc`(87%)。
- 【推】TeaVM（WASM GC）は emscripten と違い「WASM の線形メモリ = ArrayBuffer」が無い。`writeBuffer` に渡すには Java 配列 → JS の TypedArray への 1 回の写しが要る（試作の `copyFromJavaArray`）。toji の「WASM は writeBuffer が良い」は線形メモリ前提。**1 コマ 1 本 1 回の写し**が下限。

## 1. 命令の一覧（Chrome 156 の prototype から全部。`h/web-prototypes.json`）
| 対象 | メソッド | 使い道（まとめる / 行き来を減らす / CPU→GPU） |
|---|---|---|
| RenderPassEncoder | `setPipeline` `setBindGroup` | 状態切替（pipeline・bind group を変えず続けると安い）。dynamic offset 版は行き来が重い（後述） |
| | `setVertexBuffer(slot,buf,offset,size)` `setIndexBuffer(buf,fmt,offset,size)` | 共通バッファの一部を切って使う＝まとめる。offset で形ごとに切り替え、pipeline を替えずに済む |
| | `draw` `drawIndexed`（`firstVertex/baseVertex/firstInstance`） | まとめる。`firstInstance`=物の番号の起点（標準）。`baseVertex` で共通 index buffer を使い回す |
| | `drawIndirect` `drawIndexedIndirect` | CPU→GPU。引数 16B/20B を buffer から読む。**1 回 1 draw**（【確】MDN）。`firstInstance`≠0 は `indirect-first-instance` が無いと **何も描かない（無言）** |
| | `executeBundles` | 行き来を減らす（static な集まり）。実行後に pipeline・bind group・vertex/index buffer が**全部リセット**（【確】MDN）。pass と bundle の `depthReadOnly`/`stencilReadOnly` と pipeline layout が一致必須 |
| | `setScissorRect` `setViewport` | 切り抜きの箱。**bundle の中では使えない**（【確】toji）。2D の clip はここ |
| | `setStencilReference` | mask の ref を進める（8 章の案）。bundle 内は不可 |
| | `setBlendConstant` | 一定色の blend。bundle 内は不可 |
| | `beginOcclusionQuery`/`endOcclusionQuery` | 遮蔽の結果を GPU で。bundle 内は不可 |
| | `writeTimestamp` | Chrome に残る（標準の pass descriptor `timestampWrites` が正）【推】。pass 内の timestamp は実験で 0%（web3dsurvey） |
| | `setImmediates(offset,data)` | **新（Chrome 149-150）**。push constant。WGSL `var<immediate>`。上限 `maxImmediateSize`=64（手元の Chrome 156） |
| | `pushDebugGroup` 等 | 診断 |
| RenderBundleEncoder | `draw*`・`drawIndirect*`・`setBindGroup`・`setPipeline`・`setVertexBuffer`・`setIndexBuffer`・`setImmediates`・`finish` | viewport/scissor/blend 定数/stencil ref/occlusion/他の bundle の実行は無い。作る時に検査と符号化をする（作る代金が主）。毎コマ作り直すと得を失う（【確】toji） |
| Queue | `writeBuffer` `writeTexture` `copyExternalImageToTexture` `submit` `onSubmittedWorkDone` | `writeBuffer`/`writeTexture` は Chrome 144 で最大 2 倍速（【確】Chrome blog。コピー数の詳細は【不明】）。`copyExternalImageToTexture` は ImageBitmap/canvas/video から直に（絵の読み込みを JS に任せる＝Java↔JS の往復が 1 回） |
| Device | `createRenderPipelineAsync` `createComputePipelineAsync` | 先に作る・待たない（8 章） |
| | `createRenderBundleEncoder` `createQuerySet` `importExternalTexture`（動画・毎コマ作り直し・bundle には入れない） `pushErrorScope` `popErrorScope` `adapterInfo` `lost` | |
| CommandEncoder | `copyBufferToBuffer` `clearBuffer` `copyTextureToTexture`（mip の写しを GPU で） `copyTextureToBuffer` `resolveQuerySet` `beginComputePass` | |
| ComputePassEncoder | `dispatchWorkgroups` `dispatchWorkgroupsIndirect` `setImmediates` `writeTimestamp` | 間引き・粒子・引数の書き込み |
| Buffer | `mapAsync` `getMappedRange` `unmap` `destroy` | |
| 無い物 | `multiDraw*`・`generateMipmap`・pass 途中での buffer 書き込み | |

### 1.1 buffer の上げ方（1 コマに大きな buffer を 1 回）
- 【確】toji: 既定は `writeBuffer`。`mappedAtCreation` は作る時 1 回だけ（作る時にゼロ埋めが要る）。`mapAsync(WRITE)` の staging ring は複雑で、測って遅い時だけ。https://toji.dev/webgpu-best-practices/buffer-uploads
- 【確】Chrome 153-154: Dawn の実験 `BufferMapWriteExtendedUsages`（MapWrite と他の usage を併用）で staging を無くせる。標準ではない。https://developer.chrome.com/blog/new-in-webgpu-153-154.md.txt
- 【確】Chrome 145 実験 `mapSync`（worker だけ・フラグ必要）。https://developer.chrome.com/blog/new-in-webgpu-145.md.txt
- 【推】TeaVM では「Java の float[] → Float32Array（1 回の写し）→ `writeBuffer`（ブラウザ内でもう 1 回）」。`mapAsync` は JS の ArrayBuffer を Java から書く事になり、写しの回数は同じか増える。**`writeBuffer` 1 本で十分**。
- 【確】sokol（C から WASM）の実測: 1 回ごとの `writeBuffer` は呼び出しの代金が高く、コマの最後に 1 回にまとめた。https://floooh.github.io/2023/10/16/sokol-webgpu.html

### 1.2 dynamic offset
- 【確】sokol: `setBindGroup` の dynamic offset 付きは「驚くほど CPU が重い」。Windows Chrome で uniform 更新+draw が WebGL2 約 64k → WebGPU 約 16k（M1 Mac は 8.5k → 11k）。（同上）
- 【確】本リポジトリの試作（`spike-web/REPORT.md`）: dynamic offset G1 は 20,000 個で 12〜13 ms、全部 storage buffer の G2 は 0.9 ms。
- => **dynamic offset は使わない**（6.1-1 の方針が正しい）。必要なら `firstInstance` で行を引く。

## 2. feature と対応（手元の Chrome 156 / Apple M4 Pro と web3dsurvey の割合）
web3dsurvey は報告の集計（【推】二次。https://web3dsurvey.com/webgpu ）。ブラウザ別は feature ごとのページ（`/webgpu/features/<名前>`）。

手元 Chrome 156 の adapter.features（24 個・【確】）: bgra8unorm-storage, clip-distances, core-features-and-limits, depth-clip-control, depth32float-stencil8, dual-source-blending, float32-blendable, float32-filterable, indirect-first-instance, primitive-index, rg11b10ufloat-renderable, shader-f16, subgroup-size-control, subgroups, texture-component-swizzle, texture-compression-astc, -astc-sliced-3d, -bc, -bc-sliced-3d, -etc2, -unaligned, texture-formats-tier1, -tier2, timestamp-query。（`atomic-vec2u-min-max` は仕様にあるがこの Chrome には出ず。multi-draw 実験も出ない。）
仕様（w3.org/TR/webgpu §3.6.1.1）の feature は 25 個で上の 24 + `atomic-vec2u-min-max`。https://www.w3.org/TR/webgpu/

| feature | 全体 | 端末の偏り（web3dsurvey） | この描き手での使い道 | 判定 |
|---|---|---|---|---|
| indirect-first-instance | 99.98% | 全 OS・全ブラウザ ~100% | indirect で firstInstance。GPU 間引きの引数 | 使う |
| timestamp-query | 98.8% | Safari 93%・iOS 99.9% | GpuTimer（pass の前後のみ） | 使う（無ければ出さない） |
| depth-clip-control | 98.1% | | 影の near 切り | 使える |
| depth32float-stencil8 | 99.97% | | 3D の深度+stencil | 使う |
| rg11b10ufloat-renderable | 99.98% | | HDR の軽い形式 | 使える |
| bgra8unorm-storage | 96% | | canvas 形式への compute | 使える |
| float32-blendable | 94% | | 浮動小数 blend | 使える |
| shader-f16 | 94% | iOS・Safari 100%・Android 88%・Linux 79% | 骨・粒子で帯域減 | 任意（shader の変種が増える） |
| float32-filterable | 91% | iOS 57%・Safari 59%・Android 73% | float 画像を線形補間 | **前提にしない**（影は depth + 比較 sampler で） |
| texture-compression-bc | 87% | PC 向け | PC の texture 容量 | PC だけ |
| texture-compression-astc / etc2 | 47% | iOS/Android/Apple Silicon ~100%・Windows 0% | スマホの texture 容量 | **端末ごとに分かれる**。無ければ非圧縮。Windows は BC |
| clip-distances | 82% | | 影・clip | 任意 |
| dual-source-blending | 82% | Safari 5%・iOS 0.1%・Mac 72%・Android 72% | Normal/Add/Multiply を 1 本に | **iOS で使えない。やめる** |
| texture-component-swizzle | 78% | | R8 の字を rrr1 で | 任意（シェーダー側で足りる） |
| primitive-index | 85% | iOS 55%・Firefox 1% | 選択の ID | 前提にしない |
| subgroups | 68% | Safari 1%・Firefox 0.1% | 粒子・prefix sum | **やめる** |
| texture-formats-tier1/tier2 | 93% / 84% | | 16bit unorm・rw storage | 任意 |
| core-features-and-limits | 99% | | 互換モードの制限を外す印 | 要求しておく（互換モードが来た時に備える） |
| texture-compression-unaligned | 60% | | | 不要 |

### 2.1 limit（手元の Chrome 156 / Dawn の既定・【確】`h/web-adapter.json`）と、端末の目安（web3dsurvey・【推】）
| limit | 仕様の下限 | 手元 Chrome 156 (M4 Pro) | 端末の目安 |
|---|---|---|---|
| maxTextureArrayLayers | 256 | 2048 | ≥2048 が 99% |
| maxSampledTexturesPerShaderStage | 16 | 48 | ≥44 が 92%・≥48 が 77% |
| maxStorageBuffersPerShaderStage | 8 | 10 | ≥16 が 80%。Android は 8/10/16 が混在 |
| maxStorageBuffersInVertexStage / FragmentStage | 8 | 10 / 10 | 非互換モードでは per-stage に引き上げられる（MDN） |
| maxStorageBufferBindingSize | 128 MiB | 4 GiB-4 | ≥約 614 MiB が 94% |
| maxUniformBufferBindingSize | 64 KiB | 64 KiB | 64 KiB が 100%（128 MiB 以上は 17%） |
| maxBindGroups | 4 | 4 | 4 が 100%・8 以上は 21% |
| maxTextureDimension2D | 8192 | 16384 | ≥16384 が 99% |
| maxVertexAttributes | 16 | 30 | ≥29 が 93% |
| maxColorAttachments | 8 | 8 | 8 が 100% |
| minUniformBufferOffsetAlignment | 256 | 256 | |
| maxImmediateSize | | 64 | 【不明】 |
| maxBufferSize | 256 MiB | 4 GiB-4 | |
- 設計への示唆: bind group は 4 つ以内。1 つの stage で storage buffer は 8 本まで（確実に取れる）。texture 16 枚（下限）か、texture array（≥256 層は確実・2048 は 99%）。16 枚つなぐ案は下限ちょうどで安全。
- Chrome 146 で `maxStorageBuffersPerShaderStage` を 16、`maxSampledTexturesPerShaderStage` を 48 まで上げられる（Android 向けに Dawn が広げた）。https://developer.chrome.com/blog/new-in-webgpu-146.md.txt
- PC の jWebGPU（Dawn 0.3.4）の adapter（`h/pc-dawn.txt`）: Dawn は M4 Pro の Metal・feature は Chrome とほぼ同じだが**この binding の enum が古く**、subgroups・primitive-index・texture-formats 等が見えない。limit は struct の読みがずれて 32 bit の符号が壊れた値（-1202585600 等）があり、`maxSampledTexturesPerShaderStage` は 16（Chrome は 48）。**PC 側の limit はこの binding では信用できない**【確】。wgpu 側は更に壊れている（`maxBindGroupsPlusVertexBuffers`=0 など）。

## 3. 仕様に入った・入りそうな物（2025〜2026）
| 物 | Chrome | Safari | Firefox | 状態 |
|---|---|---|---|---|
| immediates（`setImmediates`・`var<immediate>`・`requires immediate_address_space`） | 149-150（Chrome 151-152 で検証エラーが OperationError に）。https://developer.chrome.com/blog/new-in-webgpu-149-150.md.txt | 【不明】 | 【不明】 | 仕様に入っている（w3.org/TR/webgpu の pipeline layout の `immediateSize`）。手元 Chrome 156 で 64B |
| sized binding arrays（`binding_array<T,N>`） | 未出荷【確: wgpu issue #822 は Milestone 2・「進行中」】https://github.com/gpuweb/gpuweb/issues/822 | 【不明】 | 【不明】 | 提案 `proposals/sized-binding-arrays.md` |
| bindless（`GPUResourceTable` 等） | 実験 `chromium-experimental-sampling-resource-table` 0.14% | 【不明】 | 【不明】 | 仕様化の議論中（2025 の作業ログ）。https://www.w3.org/groups/wg/gpu/activity/2025/ |
| `texture_and_sampler_let` | 146 | WebKit は「立場なし（Closed Without a Position）」 | Mozilla は標準の立場を CR まで保留 | 将来の bindless の準備。https://groups.google.com/a/chromium.org/g/blink-dev/c/uSCwz1uZpto |
| 互換モード（`featureLevel:"compatibility"`） | 139 から実験・origin trial は 145（2026-04-21）で終了・146 で OpenGL ES 3.1（Android） | 【不明】 | 【不明】 | 手元 Chrome 156 で `requestAdapter({featureLevel:'compatibility'})` は返る（【確】）が既定では出ない |
| transient attachments | 146 | 【不明】 | 【不明】 | tile メモリだけで済む attachment（モバイルで帯域減）。https://developer.chrome.com/blog/new-in-webgpu-146.md.txt |
| `adapterInfo`（device 側）・`subgroupMin/MaxSize` | 手元で確認【確】 | | | `isFallbackAdapter` は削除（140） |
| WGSL language features（手元 Chrome 156 の `wgslLanguageFeatures`・【確】13 個）| buffer_view・immediate_address_space・linear_indexing・packed_4x8_integer_dot_product・pointer_composite_access・readonly_and_readwrite_storage_textures・subgroup_id・subgroup_uniformity・swizzle_assignment・texture_and_sampler_let・texture_formats_tier1・uniform_buffer_standard_layout・unrestricted_pointer_parameters | 他は【不明】 | | `packed_4x8_integer_dot_product`（`dot4I8Packed`）・`unrestricted_pointer_parameters`（ポインタの引数）・`pointer_composite_access` は WGSL の標準の `requires` |
| `primitive_index`（`enable primitive_index`） | 142 | iOS 55% | 1% | 狭い |
| `buffer_view`（storage を型を替えて読む） | 153-154 | 【不明】 | 【不明】 | 頂点引き（vertex pulling）の詰め方が楽になる程度 |
| `fragment_depth` | 155-156 だが**全プラットフォームで一時無効**（Windows のコンパイルエラー） | | | 使えない |
| `subgroup_size_control` | 151-152 | | | やめる |
| `texture-component-swizzle` | 143 | | | 任意 |
| mapSync（worker・実験） | 145 | | | 使わない |
- Safari: WebGPU は Safari 26（macOS/iOS/iPadOS/visionOS）で既定有効（【確】https://webkit.org/blog/16993/news-from-wwdc25-web-technology-coming-this-fall-in-safari-26-beta/ ）。WebKit の記事に feature / limit の一覧は無い【不明】。
- Firefox: Windows 141・macOS 26+ は 145・Apple Silicon の全 macOS は 147・worker は 148（【確】MDN https://developer.mozilla.org/en-US/Firefox/Releases/147 ・実装状況 https://github.com/gpuweb/gpuweb/wiki/Implementation-Status ）。Linux は Nightly、Android はフラグ。
- Chrome: Mac/Windows 113・Android 121（Android 12+）・Linux Intel 144 / NVIDIA 147（同 wiki）。Android の Imagination は 139（Android 16+）。Samsung Xclipse は TBD。
- 端末の割合（web3dsurvey）: Android 77%・iOS 88%・macOS 91%・Windows 84%・Linux 19%（【推】）。

## 4. まとめて描く定番（出典つき）
(a) **頂点を storage buffer から引く（vertex pulling）で形を 1 本に**: Dawn の Metal は元々 vertex pulling で bounds check をする（【確】toji indirect-draws）。代金は読みが 1 段増える事と、頂点 buffer の format 最適化を失う事。【推】2D の「四角 4 頂点」は頂点番号から作れる（試作でも頂点 buffer 無し）ので代金はほぼ無い。三角形の列は 1 本の pipeline に混ぜるより頂点 buffer の draw を別にした方が単純（計画 6.1-4 のまま）。数字は【不明】（形の混在で測った一次の資料は見つからず）。
(b) **GPU の上での間引き**: compute で視錐台外を落とし、可視の物を詰めた instance buffer と `drawIndirect` の引数を書く。multi-draw が無いので、**形（メッシュ）ごとに 1 つの indirect draw**（`instanceCount` を GPU が書く・`firstInstance` で自分の区間の起点）。1 コマ 412 draw・約 5000 instance で、引数を **別 buffer** にすると Chrome（Dawn）が引数の検査を buffer ごとに入れて pass 約 6 ms のうち約 3 ms が検査、**1 つの buffer に詰めると検査は約 10 µs（約 300 倍）**（【確】toji https://toji.dev/webgpu-best-practices/indirect-draws。Windows D3D12 での話）。three.js は BatchedMesh の indirect 版が PR 中【推】。
(c) **bind group の 3 分割**: コマ（group 0）・材質（group 1）・物（group 2）。ただし物ごとの bind group は作らず、物の違いは storage buffer の行（【確】toji bind-groups https://toji.dev/webgpu-best-practices/bind-groups。bind group は buffer の中身を写さないので `writeBuffer` で更新しても作り直し不要・同じ中身で作らない）。
(d) **2D のスプライト**: kelp-2d は「atlas の texture array」で 1 target を 1 draw（【推】https://github.com/emmyleaf/kelp-2d）。層は 2048 以上が 99%。
(e) **字**: MSDF の atlas + 3 channel の median を WGSL で（luma.gl・stratum-map 等【推】）。R8 の SDF なら現行の案のまま。
(f) **pipeline の引っかかり**: `createRenderPipelineAsync`（試作で 65〜93 ms/本・【確】spike REPORT）。仕様に shader module の `compilationHints` がある（【確】w3.org/TR/webgpu §9.1 に名前のみ・効果は【不明】）。Chrome の cache は【不明】。
(g) **影の地図**: 光ごとの pass を別々に切る。同じ draw 列を bundle で使い回すなら、形式（深度のみ）ごとに bundle が別（【確】toji）。数字は【不明】。
(h) **粒子**: compute で更新し、同じ buffer を vertex pulling で描く（`dispatchWorkgroups` 1 回＋ `draw(6,N)` 1 回）。【推】
- Babylon の snapshot rendering（FAST = bundle を 1 回記録して毎コマ再生）は「1 mesh あたり 6〜10 の API 呼び出しを削る」ものとしてフォーラムで説明されている。10 倍という数字は二次のニュース記事だけ【不明】。https://doc.babylonjs.com/setup/support/webGPU/webGPUOptimization/webGPUSnapshotRendering （検索結果の写し）
- Unity は 6.6（2026-09-01）で WebGPU の experimental を外したが opt-in（【推】二次）。Godot は公式の web は WebGL2 のまま、WebGPU は第三者の fork が beta（【推】二次）。

## 5. ブラウザ特有（JS との行き来）
- 【確】sokol: C から WASM で 1 回ごとの WebGPU 呼び出しは高く、バッチとキャッシュ（bind group の hash cache）で減らした。JS だけの WebGPU の方が WASM 経由より速い事がある。https://floooh.github.io/2023/10/16/sokol-webgpu.html
- 【推】「WASM 側の buffer に命令を詰め、JS の小さなインタプリタが 1 回で流す」方式は Go の WebGPU 実装などが採る（検索の結果から。実装の一次は未確認）。emdawnwebgpu（Dawn の emscripten 用 binding）は `ExternalTexture` を JS からだけ作れる等、**1 呼び出し 1 橋**で、命令列方式ではない【推】。Unity・Godot・Bevy・Flutter が WebGPU でどうしているかは確かめられなかった【不明】。
- 【確】本リポジトリの試作: 橋を 3 回/個 → 2 回/個で 20,000 個 12.5 → 3.2 ms、storage buffer 1 本 + `draw(6,N)` 1 回で 0.9 ms。**橋の回数が主因**。
- 【推】命令列方式を入れるなら、1 コマの命令（setPipeline・setBindGroup・setVertexBuffer・draw 等 20 前後の種類）を `Int32Array` に詰め、JS 側の `switch` で流す。JS の物（buffer・bind group・pipeline）は表（配列）に置いて整数で引く（WebGL2 版の fgeH と同じ形）。WebGPU の物は Java の欄に持てる（試作で確認済）が、命令列方式を採ると結局表が要る。ただし試作で draw が数十本の所は 1 本ずつ橋を渡っても 1 ms 未満なので、**切れ目が 100 本を超える場面が出てから**でよい。
- 【不明】OffscreenCanvas + Worker で WebGPU を描く形の今（MDN は各メソッドが worker で使えると記す。TeaVM 側に worker 上の WASM GC を置く話は未確認）。Firefox は 148 から service worker を含む全 worker で WebGPU。

## 6. 設計に入れるべき物（効く順・10 個まで）
| # | 何を | どこで | 端末 | 計画の番号をどう変えるか | 根拠 |
|---|---|---|---|---|---|
| 1 | **`draw` の `firstInstance` を物の番号の起点にする**（`instance_index` で storage buffer の行を引く）。形ごとに 1 draw、バッファは 1 本・1 回の `writeBuffer` | 2D・3D・橋 | 全部（標準） | 6.1-1・2・6 に 1 行足す。dynamic offset は禁止と明記 | 試作 G2・sokol・仕様 |
| 2 | **引数 buffer は 1 本に詰める**（indirect を使う時）。形ごとに 1 つの `drawIndexedIndirect`、`firstInstance` で区間 | 3D の 1 万個の建物 | `indirect-first-instance` 99.98% | 6.2-10・12 の前提に。「GPU 間引き」を compute で書く案を 3D の計画に | toji indirect-draws |
| 3 | **multi-draw を前提にしない**。計画 6.1-2 の「multi-draw が無いので」はそのまま。将来 `multiDraw*` が標準に入ったら差し替える薄い口にしておく | | 0.12% | 6.1-2 変更なし。診断に「切れた draw の数」を残す（8 項目） | Dawn 文書・Chrome 131 記事 |
| 4 | **`writeBuffer` を 1 コマ 1 本**。Java 配列 → TypedArray の写しを 1 回に | ブラウザ | 全部 | 6.1-6 に「TeaVM では写しが 1 回要る・`mapAsync` に替えても減らない」を注記 | toji・sokol・Chrome 144（最大 2 倍速） |
| 5 | **2D の絵は texture array の頁（2048）。層 2048 以上が 99%、`maxSampledTexturesPerShaderStage` 16 は下限で確実** | 2D | 全部 | 6.1-3 の「比べる 2 案」はどちらも下限で動く。テストは Safari で。texture array の層数は 256 まで確実 | web3dsurvey |
| 6 | **dual-source-blending を使わない**（6.1 の後案を削る） | 2D の blend | Safari 5%・iOS 0.1% | 6.1 末尾の案を「iOS で無いので不採用」へ | web3dsurvey |
| 7 | **timestamp-query は pass の前後だけ**で使う（pass 内は実験） | 診断 | 98.8% | 8 章の GpuTimer 行を「pass 単位」に | web3dsurvey |
| 8 | **bind group は 4 つ以内・コマ/材質/物の 3 つ**。bind group を作り直さず buffer の中身を書き換える。bind group のキャッシュを持つ | 全部 | 100% | 6.1 に「maxBindGroups=4」を足す。物ごとの bind group は作らない | toji bind-groups・sokol |
| 9 | **render bundle は static group のみ**（実行後の状態リセット・scissor/stencil/blend は bundle の中で使えない・形式ごとに別）。計画 6.2-10 の制約に「viewport/scissor/stencil ref が使えない」を足す（2D の clip と mask を含む場面は入れない） | 3D の 1 万個の建物 | 標準 | 6.2-10 | MDN executeBundles・toji render-bundles |
| 10 | **`core-features-and-limits` を device 作成時に要求**（互換モードが既定になる場合に備える）。**immediates は任意**（`firstInstance` で足りるので急がない）。Safari/Firefox が不明 | | 99% | 8 章に 1 行 | Chrome 139 記事 |

### やめた方がよい物
- `multiDraw*` / `chromium-experimental-*`（0.12%・標準外・フラグ）。
- bindless・`binding_array`・`texture_and_sampler_let` を軸にした設計（未出荷・WebKit は立場なし・Mozilla 保留）。
- `subgroups`（Safari 1%・Firefox 0.1%）・`primitive-index`（iOS 55%）・`dual-source-blending`（iOS 0.1%）・`float32-filterable` 前提（iOS 57%）。
- `texture-compression-astc/etc2` を既定の texture 形式にする（47%・Windows 0%）。使うなら端末ごとの変種。
- `mapSync`・`BufferMapWriteExtendedUsages`（実験・標準外）。`fragment_depth`（Chrome が全プラットフォームで一時無効）。
- 命令列インタプリタを今すぐ（試作で draw 数十本なら橋は 1 ms 未満。切れ目が増えてから）。
- 互換モード（origin trial は 2026-04 で終了・既定ではない）に依存する事。

## 7. 確かめられなかった事【不明】
- Safari / iOS の各 feature・limit の一覧（WebKit の記事に無い）。web3dsurvey のブラウザ別だけ（二次）。
- Dawn の pipeline の cache の挙動、`compilationHints` の効果。
- Unity / Godot / Bevy / Flutter の WASM の WebGPU の呼び出しのまとめ方（一次）。
- OffscreenCanvas + Worker で TeaVM の WASM GC から描く形。
- W3C 仕様の §17（render pass）・§18（bundle）は、取得した頁が途中で切れて読めなかった。render commands の細部は MDN と toji で補った。
