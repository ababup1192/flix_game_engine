# WebGPU スパイク報告（TeaVM 0.16.0 / wasm-gc / Chrome 156 headless / macOS・Apple GPU・Metal）

作業場所: このファイルと同じフォルダ。engine のリポジトリは読んだだけ（変更なし・コミットなし）。
【確】= 手元で動かして確かめた　【推】= 読んだ物からの推測　【不明】= 測れていない

## 結論（先に）
- 【確】TeaVM 0.16.0 の `org.teavm.jso.webgpu`（Maven Central の teavm-jso-apis 0.16.0 に入っている）で、Java から WebGPU を直に呼べる。wasm-gc・`-O 2` 相当（FULL）で訳せて、三角形・非同期・読み戻し・3 通りの重さの比べまで動いた。
- 【確】WebGPU の物（device・queue・buffer・pipeline・bind group・texture・encoder）は **Java の static 欄・ラムダの捕まえる変数・配列の要素にそのまま持てる**。WebGL2 版の「JS 側の表 fgeH に置いて int で引く」形は WebGPU では要らなかった（警告 0・エラー 0）。engine の WebGl2.java の WhyNot（総称のデータや Object を受ける所へ渡すと落ちる）には当たらなかった（総称の入れ物に入れる所は試していない）。
- 【確】非同期は `JSPromise.await()`（0.16.0 にも 0.14.1 にもある）で Java の直列の書き方のまま待てた。requestAdapter・requestDevice・createRenderPipelineAsync・mapAsync・onSubmittedWorkDone を全部これで待った。engine の AnimationFrame と同じ TeaVM のコルーチン変換の上で動く（rAF の @Async は今回は試していない）。
- 【確】**一番の障害は TeaVM の CLI**: `teavm-cli`（`org.teavm.cli.TeaVMRunner`）は Maven Central に 0.14.1 までしか無い。0.15.0・0.16.0 には無い。engine の go/cmd_exportweb.go は TeaVMRunner を呼ぶので、そのままでは上げられない。代わりに `org.teavm.tooling.TeaVMTool`（teavm-tooling に残っている）を呼ぶ小さな Java（このフォルダの tools/Build.java・約 20 行）で訳せた。
- 【確】重さ（CPU の時間・Java の側）: 「1 個 1 draw・1 個ごとに行列」のやり方では WebGPU の G1 は WebGL2 の W と同じか少し悪い。**全部の行列を storage buffer に入れて 1 回の instanced draw にする G2 は N=20,000 で約 0.9 ms（W は約 12 ms）**。draw call 数を減らす書き方に変えられるかが効く。

## 1. 版
| 物 | 値 |
|---|---|
| engine の今の版 | TeaVM 0.14.1（go/exportweb_teavm.go の teavmVersion・Makefile の TEAVM_VERSION） |
| 出力の種類 | wasm-gc（`-t wasm-gc -O 2`・main は `Main`・`-f classes.wasm`） |
| Maven Central の最新 | 0.16.0（teavm-jso-apis の maven-metadata: latest/release=0.16.0, lastUpdated 20261002）。0.15.0 もある |
| WebGPU の宣言が入った版 | **0.16.0**（GitHub リリースノート「WebGPU API: `org.teavm.jso.webgpu`・入口は `Navigator.getGPU()`・`Navigator.isWebGPUSupported()`」）。0.15.0 には無い【確: 0.14.1 の jar では `org.teavm.jso.webgpu` が見つからずコンパイルが落ちる】 |
| 0.16.0 の jar で使った物 | teavm-classlib/core/interop/jso/jso-apis/jso-impl/metaprogramming-api/-impl/platform/tooling/relocated-libs-asm(+analysis/commons/tree/util)/hppc/rhino、**新規**: teavm-extension-apis・teavm-extension-spi・teavm-extension-spi-util（classlib の pom から）、commons-io 2.20.0・joda-time 2.12.2・jzlib 1.1.3（engine の表のまま） |

engine の teavmArtifacts（SHA-256 付きの一覧）を 0.16.0 へ上げる時に引っかかりそうな所（リリースノートと実物の jar から）:
1. 【確】**teavm-cli が 0.15.0 以降 Central に無い**（relocated-libs-commons-cli・relocated-libs-commons-io も 0.14.1 で止まる）。TeaVMRunner を呼ぶ cmd_exportweb.go の呼び方を TeaVMTool の API 呼び出し（今回の Build.java）に替えるか、別の入口が要る。Build.java は 0.14.1 と 0.16.0 の両方で動いた。
2. 【確】jar の一覧が変わる: cli・relocated-libs-commons-cli/io が消え、extension-apis・extension-spi・extension-spi-util が増える（SHA-256 の表を作り直し）。
3. 【確】wasm-gc-runtime.js は teavm-core の同じ場所（org/teavm/backend/wasm/wasm-gc-runtime.js）にあり、0.16.0 では 38,486 B（0.14.1 は 38,477 B・中身は違う）。stampWebIndex の版の確かめを通すなら 0.16.0 の物を使う。0.16.0 の wasm と 0.14.1 のランタイムの組み合わせは危ない【推】。
4. 【確】engine_web/teavm の shim（THexFormat・TMessageDigest・TCyclicBarrier・TConcurrentLinkedQueue・TReentrantLock・TCondition）は 0.16.0 の classlib にも無い＝まだ要る（重なって二重になる物は無い）。新しく `java.lang.ref.Cleaner`（TCleaner）が classlib に入った。
5. 【推】0.15.0: Java の下限が 17（engine は `--release 17` なので問題なし）。wasm 命令の内部表現の置き換えと `try` → `try_table`（例外の命令の変更）。出す wasm のバイナリ形式が変わるので、対応する Chrome・Safari・Firefox の下限が上がる可能性がある。モバイルの実機で確認するべき【不明: 実機は未確認】。
6. 【推】0.15.0: 旧い反射用 API（ReflectionSupplier・`META-INF/teavm.properties`）は使えなくなった。engine が使っているかは未確認（engine_web/teavm を読んだ範囲では見当たらない）。
7. 【推】0.16.0: classlib の `Arrays.copyOfRange`・NIO バッファ・`GregorianCalendar` などの直し。engine の Rewrite.java の付け替え（Arrays.copyOfRange・allocateDirect・Checksum.update・Reference.refersTo・`\R`）が不要になった物があるかもしれないが、付け替えは残しても無害のはず【推・未確認】。`Math.min/max` の intrinsic など wasm-gc の最適化も入った。
8. 【推】0.16.0 の「`@JSProperty` は record 形式の getter も可」「wasm-gc で suspension point が thread の外に来た時にはっきりした例外」は影響なし〜良い方向。

## 2. 三角形・JS の物の置き場
- 【確】`tools/Build.java` で `TeaVMTool`（WEBASSEMBLY_GC・FULL・obfuscated）→ `classes.wasm`。`index.html` が `TeaVM.wasmGC.load("classes.wasm")` → `exports.main([])`。
- 【確】Java から `Navigator.getGPU()`・`requestAdapter().await()`・`requestDevice().await()`・`GPUDescriptor.create()` で作る各 descriptor・`createRenderPipelineAsync(...).await()`・`getContext('webgpu')`（これだけは `@JSBody`）・`configure`・`getCurrentTexture`・`beginRenderPass`・`draw`・`submit` まで宣言で書けた。canvas に WGSL の赤い三角形を出した。
- 【確】欄に持てた: `static GPUDevice device; static GPUQueue queue; static GPUTexture target;`。ラムダの中でも使えた。JSObject の配列（`ColorTargetState[]`・`BindGroupLayoutEntry[]` など）を setter へ渡せた。
- 【確】`@JSBody` で JSObject を引数に渡して JS 側の関数へ（`p.setBindGroup(0, g, o, i, 1)`）も動く。TeaVM の宣言に無い呼び方（`setBindGroup` の「配列・開始・長さ」の 5 引数版）はこれで補った。
- 【確】宣言の足りない所: `setBindGroup` の 5 引数版が無い、`Uint32Array` に `create(int)` が無い（`new Uint32Array(n)` を使う）。descriptor は `GPUDescriptor.create()` の総称で作る流儀で、定数は `GPUBuffer.Usage.*` はあるが texture usage や shader stage の定数は見つからず数値を直書きした（RENDER_ATTACHMENT=0x10・COPY_SRC=1・VERTEX=1 等）。
- 量の目安: 自分で `@JSBody` だけで書いた場合の比較は取っていない【不明】。宣言を使った今回の Main.java は 約 330 行（bench と報告の組み立てを含む）。三角形だけの部分は、descriptor の組み立てで約 60 行。

## 3. 非同期・読み戻し
- 【確】全部 `JSPromise.await()` で待てた: requestAdapter → requestDevice（initMs ≈ 34〜41 ms）→ createRenderPipelineAsync（三角形 ≈ 70〜93 ms・四角 2 本で ≈ 65〜79 ms）→ mapAsync（読み戻し）→ onSubmittedWorkDone（毎コマの完了待ち）。
- 【確】読み戻し（64×64 の rgba8unorm・黒でクリア・赤い三角形）: 4 隅 (0,0)(63,0)(0,63)(63,63) = `[0,0,0,255]`、真ん中 (32,32) = `[255,0,0,255]`。`getMappedRange()` の ArrayBuffer は unmap すると空になるので、Uint8Array へ写してから unmap した。

## 4. 重さの比べ
条件【確】: 描き先は 512×512 の rgba8unorm（WebGPU は texture・WebGL2 は renderbuffer の FBO。画面への合成は含まない）。1 個は 6 頂点の小さな四角（頂点は頂点番号から作る・頂点バッファ無し）で、全部が同じ pipeline/program。行列は毎コマ Java の側で `Math.sin/cos` を使って計算し直す（動く物）。測った時間は 1 コマの「Java の行列計算 → 上げる/描く → submit（WebGL2 は最後の drawArrays まで）」で、`performance.now()` の差。GPU の待ち（`onSubmittedWorkDone`・`gl.finish`）は含めず、毎コマ後に待って次のコマへ入る。ウォームアップ 30 コマの後 200 コマの**中央値**。3 回（別の Chrome の起動）流して、下は run1 / run2 / run3 の順。
`performance.now()` は 0.1 ms 刻み（クロスオリジン分離なし）なので、0.1〜0.3 ms の所は粗い。

- W  : WebGL2・engine の書き方に近い（1 個ごとに `Float32Array.copyFromJavaArray(float[16])` → `uniformMatrix4fv` → `drawArrays`。橋は 3 回/個）
- W2 : WebGL2・全行列を 1 回だけ Float32Array に写し、`uniformMatrix4fv(loc,false,arr,srcOffset,16)`（橋は 2 回/個。今回足した参考）
- G1 : WebGPU・uniform buffer（256 B 刻み）＋ dynamic offset。TeaVM の宣言で `offs.set` → `setBindGroup(0,bg,offs)` → `draw(6)`（橋 3 回/個）
- G1b: G1 と同じ GPU の呼び方で、`setBindGroup` を `@JSBody` 1 本にして橋を 2 回/個にした（参考）
- G2 : WebGPU・storage buffer 1 本に全行列・`draw(6, N)` を 1 回

CPU の中央値 [ms]（total = 行列計算 + 描き〜提出）:
| N | W | W2 | G1 | G1b | G2 |
|---|---|---|---|---|---|
| 1,000 | 0.6 / 0.5 / 0.5 | 0.1 / 0.2 / 0.2 | 0.7 / 0.7 / 0.7 | 0.2 / 0.2 / 0.2 | 0.1 / 0.1 / 0.1 |
| 5,000 | 2.5 / 2.5 / 2.6 | 0.7 / 0.7 / 0.8 | 3.3 / 3.3 / 3.3 | 1.1 / 1.1 / 1.1 | 0.2 / 0.2 / 0.2 |
| 20,000 | 12.0 / 12.2 / 11.9 | 3.0 / 3.1 / 3.1 | 11.7 / 13.2 / 12.5 | 3.1 / 3.5 / 3.2 | 1.0 / 0.9 / 0.9 |

うち行列計算（Java）は N=1,000 で 0.0、5,000 で 0.1、20,000 で 0.3 ms。残りが描き〜提出。90 パーセンタイルは W の N=20,000 で 16.8〜17.6 ms と散る（G1 は 13〜14.5・G1b 3.4〜3.7・G2 約 1.0）。生の JSON は `sink/run1.json`〜`run3.json`。
Java ↔ JS の橋（`jsCrossingsPerFrame`・数え方は呼び出し側の足し算で、`copyFromJavaArray` を 1 回と数える）:
| | N=1,000 | N=5,000 | N=20,000 |
|---|---|---|---|
| W | 3,000 | 15,000 | 60,000 |
| W2 | 2,001 | 10,001 | 40,001 |
| G1 | 3,012 | 15,012 | 60,012 |
| G1b | 2,012 | 10,012 | 40,012 |
| G2 | 12 | 12 | 12 |

すべての方式で描かれた画素数は同じ（非黒画素 N=1,000: 63,748・5,000: 65,034・20,000: 約 64,908。WebGPU と WebGL2 で 1 画素差の揺れ）＝同じ絵を描けている【確】。

橋 1 回の値段（同じ頁の小実験・3 回: 1.8/1.7/1.7 ms と 12.2/9.7/11.3 ms）:
- 何もしない `@JSBody` 10 万回 = 約 1.7 ms ＝ **1 回 約 17 ns**。橋そのものは安い。
- `Float32Array.copyFromJavaArray(float[16])` 2 万回 = 約 10〜12 ms ＝ **1 回 約 0.5〜0.6 µs**（橋 1 回の 30 倍以上）。W の N=20,000 の 12 ms のうち約 10〜11 ms がこれ。W と W2 の差（12 → 3 ms）のほぼ全部はこれだった。
- 同じく G1 と G1b の差（12 → 3 ms）は `Uint32Array.set` ＋ JSO 経由の `setBindGroup`（配列を毎回渡す）が、橋より重い JS オブジェクトの変換をしていた分【推。個別には分けていない】。

読み方:
- 【確】「1 個ずつ別の draw call」の形では、WebGPU（G1）は WebGL2（W）に対して速くない（N=20,000 で同じか 0〜10% 遅い）。JS の API の呼び出しの重さと橋の値段が支配している。CPU 面では WebGPU へ替えるだけの得は出ない。
- 【確】WebGL2 でも橋の渡し方（W → W2）で 4 倍速くなる。engine の `uniform*fv` の `copyFromJavaArray` は 1 回ごとに JS の配列を作って写している。WebGPU を入れる前に、ここ（大きな 1 本の Float32Array を 1 回写して srcOffset で引く）の方が安い改善になる可能性が高い【推・engine へは未適用】。
- 【確】draw call を束ねられる（同じ pipeline・同じ見た目の物を instance にして storage buffer の行列を引く）なら、G2 は N=20,000 で約 1 ms ＝ W の約 1/12。ただし engine の 2D/3D 描きは今は 1 個ずつ uniform を渡す作りなので、これを活かすには描く側のバッチ化（render_gl の層の作り直し）が要る【推】。
- G2 の行列の上げ方は `copyFromJavaArray(float[N*16])` を 1 回。N=20,000 で 5 MB 強（0.3 ms の行列計算のほか上げる分が 0.6〜0.7 ms）。G1 は 256 B 刻みの都合で N×1 KB を上げる（20,000 で 5 MB）。

【不明】GPU 側の時間（今回は CPU だけ）、モバイル・Windows・低い性能の GPU での値、2D の実際の engine の描き（テクスチャ・ブレンド・stencil 込み）での値、画面（canvas）へ出す時の合成込みの値、`@JSBody` だけで書いた WebGPU 版の量と速さ。

## 5. 測った場所と道
- 手元のサーバー: `python3 server.py 8781`（このフォルダの server.py。POST を受けて sink/ へ置く小さな物。python3 は DEVELOPER_DIR 無しで動いた）。`site/` を配る。終わったので止めた。
- Chrome 156.0.8078.47（/Applications/Google Chrome.app）を `--headless=new` で起こした（`run-chrome.sh`。go/internal/cdp/chrome.go の chromeArgs と同じフラグ＋ `--enable-unsafe-webgpu`）。**engine の cdp パッケージ（Go の内部パッケージ）は import できないので使わず**、頁が `window.__result` を JSON にして `/post/result` へ POST し、サーバーが sink/ に書く形で結果を取った。
- 【確】adapter は `apple / metal-3`（本物の GPU）。**フラグ無しの headless でも WebGPU は出た**（`site/gpucheck.html` を `--enable-unsafe-webgpu` 有り・無しの両方で確かめた。どちらも `navigator.gpu` と adapter あり）。`--use-angle=metal` は要らなかった。
- 人がブラウザで開く時: `site/` を適当なサーバーで配り（`cd site && python3 -m http.server 8781 --bind 127.0.0.1`）、`http://127.0.0.1:8781/index.html` を WebGPU が出る Chrome で開く。数分かかる（約 80 秒）。終わると `document.title` が `done` になり、頁の下に JSON が出て、`window.__result` と `window.__log` に入る。POST の先が無くても結果は頁に出る（fetch が失敗するだけ）。
- 動かし方（作り直し）: `cd <engine> && devbox run -- bash <このフォルダ>/build.sh 0.16.0 Main <出力> <このフォルダ>/src/Main.java`（出力に classes.wasm と wasm-gc-runtime.js ができる。index.html を足して site/ へ）。

## 6. 大きさ
| 物 | classes.wasm | gzip -9 | 備考 |
|---|---|---|---|
| WebGL2 だけ（MainGlOnly）0.14.1 | 29,106 B | 17,276 B | engine と同じ版 |
| WebGL2 だけ（MainGlOnly）0.16.0 | 30,456 B | 17,927 B | 版だけの差 +1,350 B（+4.6%）【ただしこの頁は極小。engine 本体の大きさでは測っていない】 |
| WebGPU 入り（Main・0.16.0） | 61,557 B | 30,703 B | WebGPU の宣言を使う分と bench 全体（W/W2/G1/G1b/G2・読み戻し・JSON 組み立て）の合計。**WebGPU 分だけの差ではない** |
| wasm-gc-runtime.js | 38,477 B（0.14.1） / 38,486 B（0.16.0） | 8,830 B（0.16.0） | ランタイムは WebGPU で増えない |
WebGPU 宣言そのものの増分は、使った API の数に比例する小さな物と考えられる（JSO の宣言は呼んだ分だけ訳される）【推。今回は分離して測っていない】。engine 本体（Flix の全体を訳した数 MB 級の wasm）での差は【不明】。

## つまずいた所
- teavm-cli が 0.16.0 に無く、最初の取りが 404（上記）。TeaVMTool で解決。
- 最初のサーバーが `rm -rf` した出力フォルダの中で起動していて死に、chrome が待ち続けた（作り直しで解決。サイトは `site/` へ分けた）。
- zsh では `for a in $arts` が分割されない（bash のスクリプトにした）。BSD sed は `;` 区切りの s コマンドで落ちた（perl にした）。

## 置いた物（作業場所の下）
`src/Main.java`・`src/MainGlOnly.java`・`tools/Build.java`・`build.sh`・`index.html`・`server.py`・`run-chrome.sh`・`runs.sh`・`site/`（配る一式）・`sink/run1〜3.json`（生の数字）・`jars-0.14.1/`・`jars-0.16.0/`（Maven Central の jar）・`out/`（訳した物）・`classes-*`（javac の出力）。
