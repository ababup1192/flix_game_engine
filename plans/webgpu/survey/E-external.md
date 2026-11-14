# WebGPU 導入の下調べ(外部情報) 2026-11-14

凡例: 【確】一次情報で確認 / 【推】二次情報・推論 / 【不明】確かめられず。
注意: 検索結果には低品質な二次記事(cinevva・bugnet・abratabia など)が多い。数字は一次情報を優先し、二次のみの物は【推】にした。

## 1. ブラウザ対応(2026-11)

| ブラウザ | 状況 | 確度 | 出どころ |
|---|---|---|---|
| Chrome / Edge デスクトップ | Windows(D3D12)・macOS・ChromeOS は 113 から既定で有効。Linux は Intel Gen12+ が 144 から、NVIDIA(driver 535.183.01+・Wayland)が 147 から。他の Linux 構成はフラグ | 【確】 | https://github.com/gpuweb/gpuweb/wiki/Implementation-Status |
| Chrome Android | 121 から(Android 12+ かつ Qualcomm / ARM / Intel GPU)。Imagination は Android 16+ で 139 から。Samsung Xclipse ほか他の端末は TBD | 【確】 | 同上 / https://web.dev/blog/webgpu-supported-major-browsers |
| Safari | Safari 26(macOS Tahoe 26・iOS 26・iPadOS 26・visionOS 26)で既定有効 | 【確】 | 同上 |
| iOS の他ブラウザ・WebView | iOS の全ブラウザは WebKit なので OS 版(26+)で決まる。アプリ内 WKWebView が WebGPU を出すかの公式記述は見つからず | 【推】/【不明】(WKWebView) | web.dev 上記は OS 版で決まる旨。WKWebView は【不明】 |
| Firefox Windows | 141 から既定有効 | 【確】 | Implementation-Status |
| Firefox macOS | Apple Silicon: 145(macOS 26+)、147 で全 macOS 版。Intel Mac は Nightly のみ | 【確】 | 同上(web.dev 公開時点 2025-11-25 は 145・Tahoe のみ) |
| Firefox Linux / Android | Linux は Nightly のみ(2026 中に出す見込み)。Android はフラグ裏で既定無効 | 【確】 | 同上。caniuse も Firefox for Android は既定無効 |

- 利用率: caniuse の WebGPU は世界利用率 88.63%(86.83% + 部分対応 1.8%) 【確】(取得時点の表示) https://caniuse.com/webgpu 。Safari デスクトップは「partial」扱い。世界シェアの数字は iOS 26 の普及度に依存する。モバイルだけの割合は二次記事が 70〜78% など食い違う【不明】。
- 「Chrome / Edge 144」は web.dev が書いた Linux などの拡張を指すと見られる(113 が元の出荷)。 https://web.dev/blog/webgpu-supported-major-browsers (2025-11-25)
- WebGL2 への fallback: **今も要る**【推】。理由は (a) Android の 12 未満・Samsung Xclipse など TBD 端末、(b) iOS 26 未満、(c) Firefox Android / Linux / Intel Mac、(d) 他エンジンの実例: Unity 6.6 は WebGPU を正式サポートにしたが既定は WebGL2 のまま(二次: https://app.cinevva.com/news/2026-09-01-unity-6-6-webgpu-production 、一次の Unity docs も「WebGL2 が既定・WebGPU は端末とブラウザの対応が限られる」 https://docs.unity.com/en-us/engine/6000.7/manual/platform-specific/webgl/develop/graphics/web-graphics-apis-intro 【確】)。

## 2. WebGPU で得る物・得ない物

一次の実測は見つからなかった。数字は薄い。

| 項目 | 2D スプライト中心 | 軽い 3D(影・PBR・skinning・数百 draw) | 確度 |
|---|---|---|---|
| draw call の CPU 代金 | 1 バッチに寄せているなら差はほぼ無い。100 draw 未満は差が小さいという二次の声 | 数百なら WebGL2 でも足りる。10,000 個の別 draw では WebGL ≈30fps・WebGPU ≈50fps(デモ記事 2023・デスクトップ・インスタンス無し) https://ics.media/en/entry/230426/ | 【推】 |
| render bundle | 動かない物の描き直しに効くが、スプライト中心なら旨味は小さい | 静的シーンの CPU 代金削減に有効 | 【推】(実測無し) |
| uniform / storage buffer | 頂点に storage buffer を使うと楽(スプライトのインスタンスデータ) | skinning の骨行列を storage で持てる | 【確】仕様。ただし互換モードでは頂点段の storage buffer が既定 0 |
| compute | 使わなければ得ない | skinning・カリング・粒子で得る | 【確】 |
| 間接描き | 不要 | GPU カリングと組むと得る。multi-draw-indirect は WebGPU 標準に無い・indirect-first-instance は feature 扱い | 【推】(spec の feature 一覧で要確認・今回は【不明】) |
| テクスチャ圧縮 | WebGL2 の拡張と同等(BC / ETC2 / ASTC は feature で要求。端末依存) | 同左。Chrome 139 で BC・ASTC の sliced-3D が追加 | 【確】 https://developer.chrome.com/blog/new-in-webgpu-139 、MDN GPUSupportedFeatures |
| timestamp query | 任意 feature。Chrome は既定で量子化(タイミング攻撃対策)。要求しないと使えない | 同左 | 【確】(検索結果の記述。一次 spec は未精読) |
| スマホで遅い・電池 | 逆に遅くなる・電池を食う、という**信頼できる実測は見つからなかった** | 同左 | 【不明】 |

結論【推】: スプライト 2D だけなら WebGPU の性能上の得はほぼ無い(CPU 側が詰まっていない限り)。得は compute・storage buffer・大量 draw・将来の機種への近さ。

## 3. 非同期

| 項目 | 内容 | 確度 / 出どころ |
|---|---|---|
| device 取得 | `requestAdapter` / `requestDevice` は Promise。TeaVM では起動時に待つ段が要る | 【確】仕様 |
| パイプライン | `createRenderPipelineAsync` が標準にある。起動時に非同期で作り loading 画面で隠す、後から作る物は仮の効果で代替、が定番 | 【確】MDN https://developer.mozilla.org/docs/Web/API/GPUDevice/createRenderPipelineAsync 。対策記事は低品質【推】 |
| カクつき | ブラウザは初回使用時にシェーダーを訳す。Chrome は訳した物を cache し 2 回目以降は速い(PlayCanvas フォーラムの報告)。web ではゼロにできず、warm-up で loading へ移すだけ | 【推】 https://docs.wavedash.com/tutorials/shader-stutter / https://forum.playcanvas.com/t/shader-compilation-stutters/40213 |
| 読み戻し | `mapAsync`(Promise)のみ。**同期で画素を読む道は無い**。Unity の WebGPU docs も「同期 readback 不可・AsyncGPUReadback を使う」 | 【確】 https://docs.unity.com/en-us/engine/6000.7/manual/platform-specific/webgl/develop/graphics/web-graphics-apis-intro |
| canvas から読む / copyExternalImageToTexture | 前者は 2D canvas の `getImageData` 等で読める可能性があるが WebGPU canvas からの同期読みは今回確認できず。後者は ImageBitmap・canvas 等 → テクスチャの**書き込み方向** | 【不明】(前者) |
| device lost | `device.lost` Promise。再作成の定石は一次で精読できず | 【不明】(詳細) |

## 4. シェーダー

| 項目 | 内容 | 確度 / 出どころ |
|---|---|---|
| naga の GLSL 入力 | `glsl-in` は **GLSL 440 以上・Vulkan セマンティクスのみ**(二次扱い)。**GLSL 330 / ES 300 の入力は対象外**。出力側 `glsl-out` は GLSL 330+ / ES 300+ | 【確】 https://github.com/gfx-rs/wgpu/blob/trunk/naga/README.md |
| 既知の問題 | glsl-in は深い if/else の連鎖で stack 溢れ(#5652)。isnan / isinf・imageCube の写像無し、比較サンプラーと通常サンプラーの混在が苦手(第三者ツールの記述) | 【推】 https://github.com/gfx-rs/wgpu/issues/5652 |
| 他の道 | glslang + SPIRV-Cross(SPIR-V 経由)、twgsl(glslang + Tint の WASM。Babylon が使用) | 【推】 |
| 実行時に訳す WASM の大きさ | naga WASM・twgsl とも数値は確認できず | 【不明】 |
| Babylon.js | 8.0(2025-03)で核のシェーダーを WGSL に書き下ろし。材質ライブラリ・CustomMaterial は GLSL→twgsl(今も)。**2 本持ち**+変換の併用 | 【推】 https://forum.babylonjs.com/t/will-built-in-shaders-be-rewritten-for-the-webgpu-renderer-in-wgsl-eventually/47572 |
| three.js | WebGPURenderer は WebGPU が無いと WebGL2 backend に fallback。TSL(JS 製の node 式)が WGSL と GLSL の**両方を出す**(1 つの元から 2 つ出す型) | 【推】 https://discourse.threejs.org/t/tsl-and-webgl2-vs-webgpu/87974 |
| Bevy | WGSL で書く。web は `webgl2` と `webgpu` の cargo feature の**切り替え**(webgpu 有効だと webgl2 を上書き・WebGPU 無い物では動かない)。1 つの wasm で両対応は要望(#13168)で未確認 | 【推】 https://github.com/bevyengine/bevy/issues/13168 、公式の古い記事 https://bevy.org/news/bevy-webgpu/ |
| Unity | WebGL2 が既定。WebGPU は 6.6 で正式(二次) | 上記 |
| Godot | 公式の web 出力は WebGL2 のみ。WebGPU は優先事項に載るが日付無し | 【確】 https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html 、https://godotengine.org/priorities/ |
| PlayCanvas | 調べきれず | 【不明】 |

## 5. TeaVM から WebGPU

- **TeaVM 0.16.0(10 月 2 日。年は画面に出ないが 0.13.0=2025-11 の後で 0.14.0=5/2・0.15.0=6/14 が続く並びから 2026-10-02 と推定)** で JSO に WebGPU の宣言が入った。パッケージは `org.teavm.jso.webgpu`、入口は `Navigator.getGPU()`、有無は `Navigator.isWebGPUSupported()`。 【確(版と中身)/【推】(年)】 https://github.com/konsoletyper/teavm/releases/tag/0.16.0
- 0.12.0 で JSO が NIO バッファを Wasm のメモリ越しに JS へ渡せる(コピー越境より「何倍も良い」と記載)。0.10.0 で String が JS の string を包む(コピー無し)。呼び出し 1 回の代金の数字は【不明】。 https://github.com/konsoletyper/teavm/releases
- 0.14.0 以降 Wasm GC と Emscripten linking(2 つの module が 1 つの linear memory を共有)。0.13.1 に Safari 用の回避。
- 0.15.0 は Java 17 以上が最低。0.14.0 で旧 WebAssembly / WASI backend は削除。
- 別の道: jWebGPU の `webgpu-teavm`(Maven Central に 0.1.0・0.1.1=2025-07)。Emscripten SDK 6.0.3 が要る C 経由の作りで、**0.16.0 の JSO とは別物**。 https://github.com/xpenatan/jWebGPU 【確】
- 自作の量の目安: 0.16.0 があるので不要になった。0.16.0 より前は【不明】。

## 6. デスクトップ JVM から wgpu-native / Dawn

| 実装 | 内容 | 確度 / URL |
|---|---|---|
| jWebGPU (xpenatan) | wgpu-native と Dawn の両方。デスクトップは JNI(`webgpu-desktop-jni`)か FFM(`webgpu-desktop-ffm`・JDK 25 要)。Android AAR あり・Web は emdawnwebgpu。Apache-2.0。482 commit・1 issue。最終 commit 日は【不明】。gdx-webgpu(libGDX 用)が下に使っている様子 | 【確】 https://github.com/xpenatan/jWebGPU |
| webgpu-java (MyWorldLLC) | Panama で wgpu-native を生成 | 【推】 https://github.com/MyWorldLLC/webgpu-java |
| wgpu4j (tychedelia) | Panama・Java 22+・jextract | 【推】 |
| vulkan4j の webgpu module | 実験的・Dawn では動かない見込みと自ら警告 | 【推】 https://vulkan4j.doki7.club/club.doki7.webgpu/module-summary.html |
| wgpu4k | Kotlin・FFM | 【推】 |
| LWJGL | WebGPU の binding は**見つからず**(GLFW だけ) | 【推】 |

- 保守状況の一次確認は jWebGPU のみ不十分。デスクトップを WebGPU に寄せる価値: 描き手 1 本化の利点はあるが、(a) JVM 側の binding が 1 人プロジェクト中心、(b) 現行の GL3.3 で足りる、(c) 配る本命はブラウザ。【推】デスクトップは GL のまま始め、描き手の interface を WebGPU の形(pipeline / bind group / pass)で切る方が低リスク。他エンジンの判断: Godot は web を WebGL2 のまま(上記)、Unity は WebGL2 既定・WebGPU は選択制。

## 7. 家庭用ゲーム機との近さ

- WebGPU は Vulkan / Metal / D3D12 の共通部分を取った形(pipeline の固定・bind group・render pass・明示的な command encoder)。GL(状態機械)より新 API に近い、という一般論は妥当だが、**根拠の一次記事は今回集めきれていない**【推】。
- SDL3 GPU API(SDL_gpu): Vulkan・D3D12・Metal を包む(公式の方針)。**ブラウザ向けの backend は本体に無い**。 https://discourse.libsdl.org/t/can-sdl3-gpu-functions-shader-be-compiled-to-wasm/59691 (2025-05)。WebGPU backend の PR #12046 は 2025-03-16 に未 merge で閉じた(メンテナが自分で実装する意向)。 https://github.com/libsdl-org/SDL/pull/12046 【確】。新しい PR #16020「Experimental WebGPU SDLGPU Backend」(wgpu-native は 2026-08-11 に非対応・Dawn へ。Emscripten は emdawnwebgpu を自動で link)は merge 状態【不明】。 https://github.com/libsdl-org/SDL/pull/16020
- Java から SDL3 GPU: 専用 binding は見つからず【不明】(SDL3 の Java binding の有無は別調べが要る)。
- wgpu / Dawn / bgfx / sokol_gfx の「共通の形」の設計の比較記事: 今回は集めきれず【不明】。Emscripten は `-sUSE_WEBGPU` を廃止(4.0.18)し `--use-port=emdawnwebgpu` へ。 https://github.com/emscripten-core/emscripten/pull/24220 【確】。

## 8. 互換モード

| 項目 | 内容 | 確度 / URL |
|---|---|---|
| 状態 | Chrome 146(2026-02-25)で opt-in 出荷。`requestAdapter({featureLevel:"compatibility"})`。当初は Android。ChromeOS(OpenGL ES 3.1)・Windows(D3D11)は検討中。139 でフラグ裏 | 【確】 https://developer.chrome.com/blog/new-in-webgpu-146 |
| 他ブラウザ | Safari / Firefox の対応は【不明】(記述無し) | |
| 制限 | 頂点段の storage buffer / storage texture が既定 0、cube-array 無し、colorAttachment 4、テクスチャ 4096、sample_mask 無し、bgra8unorm-srgb 無し、view の再解釈無し、depth の textureLoad 無し 他 | 【確】 https://webgpufundamentals.org/webgpu/lessons/webgpu-compatibility-mode.html |
| 古い Android で意味 | 「古い端末の約 45% は頂点段の storage buffer 非対応」と記載。最小 Android 版・何割の端末が増えるかは【不明】 | 【確】(記載の引用) |

意味の判断【推】: 互換モードは WebGPU の「部分集合」なので、描き手を互換モードの制限内(頂点 storage buffer を使わない・インスタンスは頂点 attribute)で書けば、WebGL2 fallback の一部を WebGPU が肩代わりできる可能性がある。ただし Safari / Firefox で効くかは【不明】で、WebGL2 fallback の廃止は当面できない。

## 設計への含意(参考・【推】)
1. WebGL2 fallback は残す。描き手の interface を GL 形のままにするか、WebGPU 形(pipeline / bind group / pass)へ変えて GL 側に翻訳させるかが主な設計判断。
2. シェーダーは「GLSL を 1 つの元にして WGSL へ訳す」は naga が 440+/Vulkan のみで 330/ES300 を食えないため**そのままでは厳しい**。選択肢: WGSL と GLSL の 2 本持ち(Babylon・Bevy 型)・TSL のような中間言語(three.js 型)・SPIR-V 経由(glslang + SPIRV-Cross)。
3. 同期の読み戻しが無いので、現在の画素 readback(テスト・スクショ)の仕組みは非同期化が要る。
4. TeaVM 0.16.0 以上なら JSO で WebGPU を直に書ける(自作 binding 不要)。
