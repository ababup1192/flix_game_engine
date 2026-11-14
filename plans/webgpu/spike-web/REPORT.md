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

---

# 追試（2026-11-14 夜）: ブラウザの側の「後半で危ない所」を先に確かめる

作業場所はこのフォルダの下だけ（engine のソースと `go/` は読んだだけ）。engine は worktree の枝（main の `f3aee5c2` の上・engine 0.95.0）。
同じ機械・Chrome 156.0.8078.47（headless・フラグ無し）・Apple M4 Pro（WebGL2 は ANGLE Metal・WebGPU は `apple / metal-3`）。
【確】= 手元で動かして確かめた　【推】= 推測　【未確認】= 確かめていない

## 結論（先に）
1. 【確】**engine 全体（rpg-starter の書き出しと同じ入口 `Main`・8,514 クラス）が TeaVM 0.16.0 で穴 0 件で訳せた。** 前の 21 件は、engine の shim（fge-web-tools）が classpath に無い時に JDK の本物のクラスが流れ込んだ物で、今の shim を置けば出ない。「JDK を見せない ClassLoader」は要らなかった（置いても同じ 0 件）。
2. 【確】穴の手当ては今の物（shim 6 本＋付け替え 6 種類）のままで足りる。0.16 で要らなくなったのは `Arrays.copyOfRange` の付け替えだけ（実行して直っていた）。engine の側を直す必要がある物は見つからなかった。
3. 【確】**0.16 で訳した rpg-starter が WebGL2 のまま動き、`?capture=6` と `?capture=120` の絵が 0.14.1 とバイトまで同じ**（PNG の SHA-256 一致）。TeaVM の段の時間は 0.14.1 と同じ（16.2〜16.5 s・3 回ずつ）。wasm は +4.5%（gzip でも +4.5%）。
4. 【確】**`firstInstance` で行を引く 20,000 本の draw（1 つの render pass・JS との行き来 1 本）は CPU 1.0 ms（3 回とも同じ）**。合格線（3 ms）を下回る。1 本ずつ Java から `draw` を呼んでも 1.3 ms。ただし submit から GPU が終わるまでは 3.2〜3.3 ms（1 回の instanced draw は 0.4 ms）。
5. 【確】**WebGPU の物（device・texture・buffer・pipeline）を Flix の record・`Map`・`List`・`Option`・`Ref`・総称の関数に入れて運べた。非同期（`requestDevice`・`createRenderPipelineAsync`・`mapAsync`）は Flix の effect の handler の中から Java の `JSPromise.await()` を呼ぶ形で待てた。** ただし `Object.isNull(device)` の 1 行で、TeaVM は通るのにブラウザが wasm 全体をコンパイルで落とした（0.14.1 と同じ落ち方）。Java の普通の類で包めば通る。

## 1. engine 全体が TeaVM 0.16 で訳せるか【確・通った】

やり方: `bin/fge export-web templates/rpg-starter --keep-work`（0.14.1・今の道のまま）で、付け替え済みの jar（`rewritten.jar`・35 MB）を作った。
その jar に対して、③ の TeaVM の段だけを 0.16.0 で流した（`engine16/teavm16.sh`。`tools/BuildEngine.java` が `TeaVMTool` を呼ぶ）。
classpath は export-web と同じ並び（fge-web-tools → TeaVM の jar → rewritten.jar）。tidepool-starter は `web/WebMain.flix` が無いので rpg-starter にした。

設定の合わせ方【確】: export-web が渡す `-O 2` は TeaVM の CLI では **ADVANCED**（1=SIMPLE・2=ADVANCED・3=FULL）、`-m` が無いので**難読化なし**（javap で TeaVMRunner を読んだ）。
前の試作の Build.java は FULL＋難読化で、engine 全体だと wasm が 16.3 MB（gzip 2.5 MB）と倍になり、時間も 51 s かかった。export-web と同じ ADVANCED で比べた。

| 試した組み合わせ（0.16.0） | 穴（severe） | ログ |
|---|---|---|
| shim あり・普通の ClassLoader（export-web と同じ形） | **0** | `engine16/teavm16-adv.log` |
| shim あり・JDK の本物（`jrt:`）を見せない ClassLoader | **0** | `engine16/teavm16-nojdk.log` |
| shim なし・普通の ClassLoader | 25 | `engine16/teavm16-noshim-system.log` |
| shim なし・JDK を見せない ClassLoader | 4 | `engine16/teavm16-noshim-nojdk.log` |
| shim あり・付け替え前の jar（`project.jar`） | 13 | `engine16/teavm16-norewrite.log` |

（「shim なし」は fge-web-tools から `org/teavm/classlib/...` を抜き、付け替え先の `fge/teavmfix/*` だけ残した jar で流した）

穴の種類:
- **JDK のクラスが流れ込む（25 件・shim なし・普通の ClassLoader）**: `VarHandle.compareAndSet/setRelease`（ConcurrentLinkedQueue と `jdk.internal.vm.SharedThreadContainer` から）4・`Thread.onSpinWait` 5・`Thread.isVirtual` 4・`AccessController.doPrivileged` 2・`AccessControlContext.<init>` 2・`Permission.newPermissionCollection` 2・`MethodHandles.lookup` 2・`ClassLoader.loadClass` 2・`ConcurrentHashMap.newKeySet` 1・`Class.getSigners` 1。
  前の 21 件（`VarHandle`・`LockSupport`・`ThreadContainers`）と同じ種類。**0.16 の classlib に `ReentrantLock` 等が無いので、TeaVM が JDK の本物のクラス本体を読みに行き、その中の JDK 内部の呼び出しが穴になる**。
- **0.16 の classlib に無いクラス（4 件・JDK を見せない時）**: `ConcurrentLinkedQueue` 2・`ReentrantLock` 1・`CyclicBarrier` 1。0.14.1 と同じ顔ぶれで、engine の shim（`TConcurrentLinkedQueue`・`TReentrantLock`・`TCondition`・`TCyclicBarrier`）がちょうど埋める。
- **付け替えが要る物（13 件・付け替え前）**: `Thread.startVirtualThread` 11・`Reference.refersTo` 1・`Checksum.update(byte[])` 1。0.16 にもまだ無い。
- リフレクション: 出なかった。スレッド: 上の `Thread.*` だけ。

前の 21 件との比べ: **全部消えた**（shim を置けば 0 件。ClassLoader を組む必要もない）。前の試しは shim を classpath に置いていなかったと読む【推・前の試しの classpath は残っていない】。

## 2. 穴の手当て【確】

| 穴 | 0.16 で | 手当て | 量 |
|---|---|---|---|
| ReentrantLock・Condition・CyclicBarrier・ConcurrentLinkedQueue | まだ無い | 今の shim のまま（fge-web-tools を TeaVM の classpath の頭に置く） | 0 |
| MessageDigest・HexFormat の shim | 穴は出ない（今の shim が当たっている） | そのまま | 0 |
| `Thread.startVirtualThread`・`Reference.refersTo`・`Checksum.update(byte[])` | まだ無い | 今の付け替え（Rewrite）のまま | 0 |
| `Arrays.copyOfRange`（`to` が長さを超えると配列の外を読む） | **直っていた**【確】: 0.16 は `len=5・後ろは null／0`。0.14.1 は同じ頁が `RuntimeError: array element access out of bounds` で落ちた（`sink-fi/classlib-*.json`・`src/ClasslibProbe.java`） | 付け替えは外してよい（残しても害は無い【推】） | -1 種類 |
| 正規表現の `\R` | **まだ無い**【確】: 0.16 も `PatternSyntaxException` | 今の付け替えのまま | 0 |
| `ByteBuffer.allocateDirect`（64 KiB の倍数で落ちる） | 【未確認】: 試した形（1000 B を持ったまま 1 MiB を 8 回）は 0.14.1 でも落ちず、比べになっていない | 今の付け替えのまま | 0 |
| JDK のクラスが流れ込む | shim を置けば起きない | ClassLoader を組む必要は無い（組むなら `tools/BuildEngine.java` の `NoJdkLoader`・約 20 行。shim を外し忘れた時の穴が 25 → 4 件になり読みやすい利点はある） | 0〜20 行 |
| TeaVM の CLI が 0.16 に無い | — | `TeaVMTool` を呼ぶ Java（`tools/BuildEngine.java`・約 50 行）。**export-web の Go は、`org.teavm.cli.TeaVMRunner` の呼び出しをこの類に替え、`teavmArtifacts` を 0.16 の 22 本（cli・commons-cli/io を抜き extension-apis/spi/spi-util を足す）と SHA-256 に替える**。ADVANCED・難読化なしを渡す事（FULL にすると wasm が倍） | Go 数十行＋Java 50 行【推】 |
| fge-web.jar・fge-web-tools.jar | 0.14.1 の jso と relocated asm に向けて組んだ物のままで 0.16 の TeaVM が読めた | Makefile の `TEAVM_VERSION` を上げて組み直すのが筋【推】 | 0 |

**engine の側を直す必要がある物: 見つからなかった。**

## 3. 訳せたら動くか・書き出しの時間【確・通った】

- 0.14.1 の書き出し（`engine16/out-0.14.1`）を写し、`classes.wasm` と `wasm-gc-runtime.js` だけ 0.16.0 の物に替えた（`engine16/out-0.16.0`）。127.0.0.1 の簡易サーバーで配り、`bin/fge web-capture "…/index.html?capture=<n>" … --size 768x720` で撮った。
- 撮った絵（git の外・`engine16/shots/rpg-<版>-f<n>.png`）の SHA-256:

| コマ | 0.14.1 | 0.16.0 |
|---|---|---|
| 6 | `068f8fd4d60ec4bba868770a5550740782484b1f2f2dff4da64d04f753a24bd5` | 同じ |
| 120 | `38ab806cc37b14d042b69a46fc25a4b6a0a5be766346a46101cf3beaf5295c0a` | 同じ |

  どちらも題名の画面（ルーネの泉・メニュー・水面）を目で見た。描き手の表示は `ANGLE Metal Renderer: Apple M4 Pro`。**入力を入れた後の場面（歩く・戦う）は撮っていない【未確認】**。ほかのテンプレ（novel 等）も【未確認】。
- 時間（TeaVM の段・同じ `BuildEngine` で 3 回ずつ交互・同じ rewritten.jar）: 0.14.1 = 16.5 / 16.4 / 16.2 s、0.16.0 = 16.4 / 16.3 / 16.3 s。差は無い。
  export-web 全体（0.14.1・1 回）は 56.8 s（うち CLI での TeaVM 19.3 s）。0.16 で変わるのは ③ だけなので、全体も同じくらい【推】。
- 大きさ: classes.wasm 7,898,319 B（gzip -9 1,763,111 B）→ 8,253,361 B（1,841,638 B）。+4.5%。`wasm-gc-runtime.js` は 0.16 の物を使う（38,486 B）。
- **古いブラウザで WebGL2 版が動くか（try → try_table）は【未確認】**（この Mac には古い版の Chrome も古い端末も無い）。

## 4. ブラウザの `firstInstance`【確・合格線の内】

`src/FirstInstance.java`（TeaVM 0.16・FULL・wasm-gc）。512×512 の rgba8unorm の texture へ、1 個 6 頂点の四角を N 個。行列は毎コマ Java で作り直し、
storage buffer へ `writeBuffer` 1 回（`copyFromJavaArray` 1 回）。測ったのは「行列を作る → 上げる → 描く → submit」まで（`performance.now()`・0.1 ms 刻み）。
ウォームアップ 30 コマの後 200 コマの中央値。Chrome を 3 回起こして 3 回とも同じ値だった（`sink-fi/fi-run1〜3.json`。`fi-run0.json` は submit から終わるまでの欄が無い前の版で、同じ値）。

- F1: `pass.draw(6, 1, 0, i)` を Java から 1 本ずつ（TeaVM の宣言・JS との行き来 N 回）
- F2: draw の並び（頂点数・firstInstance）を `int[]` にして 1 回写し、JS の 1 回の呼び出しが N 本の draw を出す（行き来 1 回）
- F2v: F2 で頂点数を 6 と 3 で交互にした物（1 本の instanced draw にまとめられない並び）
- G2: 比べ用。`draw(6, N)` 1 本

| N | F1 | F2 | F2v | G2 |
|---|---|---|---|---|
| 1,000 | 0.1 | 0.1 | 0.1 | 0.0〜0.1 |
| 5,000 | 0.3 | 0.2〜0.3 | 0.2〜0.3 | 0.2 |
| 20,000 | **1.3** | **1.0** | **1.0** | 0.8 |

（ms・CPU・中央値。N=20,000 の内訳: 行列 0.3・上げる〜submit 0.7（F2）。F2 の JS の draw の輪だけなら 0.2 ms。90 パーセンタイルは F1 1.4〜1.5・F2 1.1）

submit から `onSubmittedWorkDone` が返るまで（GPU のプロセスと GPU の分。メインのスレッドは待たなくてよい）: N=20,000 で F1/F2/F2v 3.2〜3.3 ms・G2 0.4 ms。N=5,000 で 0.9 ms・0.2 ms。
描いた画素数は F1・F2・G2 で同じ（N=20,000 で 64,907）＝同じ絵【確】。F2v は三角が半分なので少ない（48,689）。

読み方:
- 【確】設計の P4b の合格線（20,000 本で 3 ms）を CPU で下回る。前の試作の「dynamic offset の `setBindGroup` を毎回」の 11.7〜13.2 ms（行き来を 1 本にしても 3.1〜3.5 ms）より 1 桁近く速い。**重かったのは `setBindGroup` に配列を渡す所で、`draw` そのものは安い**。
- 【確】行き来をまとめなくても（F1）1.3 ms。JS へ 1 回で渡す形の得は 0.3 ms。
- 【確】Chrome の WebGPU はメインのスレッドで命令を積むだけで、検査と Metal への変換は GPU のプロセスでする。その分は submit の後の 3.2 ms に出ている（1 本の instanced draw の 8 倍）。60 fps の 1 コマ（16.7 ms）には収まるが、**draw 1 本あたり約 0.14 µs の代金が GPU の側に残る**。
- 【未確認】Safari（iPhone）・Windows・Android。同じ頁（`fi-site/`）を配れば測れる。

## 5. Flix から WebGPU の物を持てるか【確・通った（落とし穴 1 つ）】

`flix-probe/`（Flix 0.78・`build.sh` が fatjar → engine の Rewrite → TeaVM 0.16 → `site/`）。Java は `flix-probe/java/wgpuprobe/Gpu.java`（JSO の型のまま受け渡す static の関数だけ）。
Flix の側（`flix-probe/src/Main.flix`）で:
- record `{ device = GPUDevice, target = GPUTexture, pipes = Map[String, GPUPipeline$Render], bufs = List[GPUBuffer] }` に入れ、欄を引いて描いた。
- `Map.insert` / `Map.get` で pipeline を名前で引いて描いた（赤 `255,0,0,255`・緑 `0,255,0,255`・無い名前は `missing`）。
- `List.map` で buffer を 3 本作って大きさを読んだ（256・512・768）。`Some(texture)`・`Ref.fresh(Static, device)`・`def keep(x: a): a = x` も通した。
- 非同期: `eff GpuAsync { def device(): GPUDevice; def pipeline(...): GPUPipeline$Render }` を宣言し、handler の中で `Gpu.requestDevice()`・`Gpu.createPipelineAsync(...)`（Java の中で `JSPromise.await()`）を呼んで `k(...)` へ返した。読み戻しの `mapAsync` も Java の中で await。**Flix のコードは止まる形のまま書けた**（engine の `AnimationFrame` と同じ TeaVM のコルーチン変換）。
- 結果: `sink-fi/flix-probe-run1〜3.json`（run1 は下の isNull の行を足す前の版）。

**落とし穴【確】**: `Object.isNull(ctx#device)` を 1 行足すと、TeaVM は「problems=0」で訳し終えるのに、ブラウザが wasm を読む所で
`CompileError: … "Probe.Def$main::staticApply" failed: Invalid types for ref.cast null: call of type externref …` と**モジュール全体を落とした**（`sink-fi/flix-probe-isnull-direct.json`）。
engine の WebGl2.java の WhyNot と同じ落ち方で、0.16 でも直っていない。record・Map・List・Option・Ref・総称の関数は通ったので、**どの書き方で落ちるかは Flix の出すバイトコード次第で、前もって読みにくい**。
Java の普通の類（`Gpu.DeviceBox`・欄 1 つ）に包むと、`Object.isNull(Gpu.box(device))` も、箱から出して描くのも通った（run2・run3）。

次に試す事・手当ての案:
- 書き出しの門に「出来た wasm をブラウザで compile する（`WebAssembly.validate` か `compileStreaming`）」を足す。今は TeaVM が通っても配った先で真っ白になりうる。
- WebGPU の backend では JSO を Flix に直に見せず、Java の小さな類（handle）に包んで渡すのが安全側。包む代金は小さい見込み【推・測っていない】。

## 設計への返し（P2・P4b・10 章）

確かめた（【確】に変わった）物:
- P2「JDK の本物のクラスが流れ込まない ClassLoader を組む」→ **要らない**。今の shim を TeaVM の classpath に置けば 0 件。直すのは `TeaVMTool` を呼ぶ入口と jar の一覧だけ。
- P2「足している部品 6 本と runtime を合わせる」→ 6 本とも 0.16 でもそのまま要り、そのまま効く。付け替えは `copyOfRange` だけ外せる。`wasm-gc-runtime.js` は 0.16 の物を使う。
- P2 の門「`web-capture` の絵が 0.14.1 と 0.16 で同じ」→ rpg-starter の題名の画面 2 コマでバイト一致。「書き出しの大きさと時間の前後」→ +4.5%・時間は同じ。
- 10 章「TeaVM 0.16 で engine 全体が訳せない」→ **訳せた**。逃げ道（0.14.1 の上に `@JSBody` で WebGPU を自分で書く）は要らない見込み。
- 10 章「書き出しが 2 つになって遅い」→ TeaVM の段は 16 s 台で版による差は無い。2 つ書き出すと TeaVM の段 1 回分（約 +16 s）増える【推】。
- P4b「物を Flix の record に入れて運べる事」→ 運べた（Map・List・Option・Ref も）。非同期は effect の handler から待てた。
- P4b「`firstInstance` の合格線（ブラウザは 20,000 本で 3 ms）」→ Chrome・この Mac で 1.0〜1.3 ms。決まり 1・2 の前提は崩れていない。

危ないと分かった物:
- **JSO を `java.lang.Object` を受ける所へ渡すと、TeaVM は通るのにブラウザが wasm 全体を落とす**（0.16 でも）。10 章に足す: 書き出しの門でブラウザの compile まで確かめる・JSO は Java の handle に包む。
- **draw の本数の代金は GPU のプロセスの側に残る**（20,000 本で submit の後 3.2 ms・instanced 1 本の 8 倍）。CPU の門は通るが、スマホで GPU のプロセスが詰まるかは【未確認】。
- export-web の `-O 2` は ADVANCED。入口を `TeaVMTool` に替える時に FULL を選ぶと engine 全体の wasm が倍（16.3 MB）になる。
- まだ【未確認】: 古い版のブラウザ・古い端末で 0.16 の wasm が動くか（5.5 の try_table の件）・iPhone の Safari での `firstInstance`・入力を入れた後の場面の絵・ほかのテンプレ・`allocateDirect` の不具合が 0.16 で直ったか。

## 入れた物と版
- TeaVM 0.16.0 の jar 22 本（前の試作が Maven Central から取った物をこのフォルダの `jars-0.16.0/` へ写した: classlib・core・interop・jso・jso-apis・jso-impl・metaprogramming-api/impl・platform・tooling・relocated-libs-asm(+analysis/commons/tree/util)・hppc・rhino・extension-apis・extension-spi・extension-spi-util、commons-io 2.20.0・joda-time 2.12.2・jzlib 1.1.3）。
- TeaVM 0.14.1 の jar 23 本（利用者のキャッシュ `~/Library/Caches/flix_game_engine/teavm/0.14.1` にあった物を `jars-0.14.1/` へ写した）。
- 新しく外から取った物: `make sync-engine-full-web` が engine の Makefile のとおり LWJGL 3.4.1 の natives を Maven Central から取った（worktree の `build/` と各 `lib/`・git の外）。ほかには無い。
- 道具: JDK 21（devbox の Zulu 21.0.8）・Flix 0.78.0（nix store の flix.jar を `FLIX_JAR` で。worktree に `bin/flix.jar` が無いため）・Chrome 156.0.8078.47・python3 の簡易サーバー（127.0.0.1 の 8791 と 8792。終わって止めた）。

## 測りの待ち合わせ
決まりの `pgrep -fl "bench/(sprite_stress|scene3d|crowd2d)|jfr-run|bench-ab"` は、毎回、別の worktree の `bench/scene3d` を根にした常駐の flixlint（`flixlint.Resident server … --idle-minutes 30`・型検査の常駐で、測りではない）だけに当たった。
測りの物ではないと判断し、それを除いて何も出ない事を毎回確かめて進めた。

## 置いた物（このフォルダの下・追試の分）
`engine16/teavm16.sh`（③ だけを 0.16／0.14.1 で流す）・`engine16/*.log`（穴の一覧と時間）・`tools/BuildEngine.java`・`src/FirstInstance.java`・`src/ClasslibProbe.java`・`fi-site/index.html`・`flix-probe/`（`build.sh`・`flix.toml`・`src/Main.flix`・`java/`）・`run-chrome2.sh`（待つ秒数を `WAIT` で）・`sink-fi/`（生の結果）。
前の試作の `server.py`・`run-chrome.sh`・`runs.sh`・`fetch.sh` は git に入っていなかったので、前の試作の scratchpad から写して入れた。
**`src/*.java`（Main・MainGlOnly・FirstInstance・ClasslibProbe）と `flix-probe/java/`・`flix-probe/src/` はコミットしていない**（worktree の作業ツリーには残してある）。
pre-commit の `lint-forbid` の規則 `teavm-jso-outside-fge-web`（TeaVM の JSO の import は `engine_web/java/fge/web/` の中だけ）が 34 件で止めるため。
入れるなら `bin/lint-rules/forbid.local.json` の exempt に `plans/webgpu/spike-web/` の分を足す（このフォルダの外なので、この追試では触っていない）。
git の外: `engine16/work-0.14.1/`（書き出しの作業場・rewritten.jar）・`engine16/out-*/`（配る一式）・`engine16/shots/`（撮った絵）・`jars-*/`・`classes-*/`。

つまずき: `build.sh` が出力のフォルダを消して作り直すので、そこを配っていた簡易サーバーが `os.getcwd()` で落ち続け、頁が POST できずに止まったように見えた（前の試作と同じ罠）。サーバーはこのフォルダの根で起こし直した。
