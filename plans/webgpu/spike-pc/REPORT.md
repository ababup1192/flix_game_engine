# WebGPU スパイク（PC / Apple M4 Pro・macOS）報告

作業場所（第 1 回）: 当時の scratchpad。第 2 回でこのフォルダへ移した（`build.sh`・`run.sh` はこのフォルダの `libs/` を見る。第 2 回の節は末尾）。
（engine リポジトリは読むだけ。LWJGL の版は flix.toml の 3.4.1 に合わせた）
JDK: Zulu 21.0.8（engine の devbox）。マシン: arm64 / Apple M4 Pro。

## 1. バインディング選び
| 候補 | 最後のリリース | 最後の commit | Maven Central | ネイティブ配布 | 要る JDK | ライセンス | GLFW の窓から surface |
|---|---|---|---|---|---|---|---|
| jWebGPU (xpenatan) 【確】 | 0.3.4（Central 2026-07-27） | 2026-09-20 | あり（com.github.xpenatan.jWebGPU） | wgpu-native 版と Dawn 版の 2 系統。mac_arm64 / mac_x64 / linux_x64 / windows_x64 を別 jar で配る | JNI 版は 21 で動いた。FFM 版は README で JDK 25 | Apache-2.0 | 可。`instance.createMacSurface(NSWindow のアドレス)` が CAMetalLayer まで作る（LWJGL の glfwGetCocoaWindow の値をそのまま渡す） |
| wgpu-native を Panama(FFM) で直接 | wgpu-native v29.0.1.1（2026-06-23・GitHub Releases に macOS/Windows/Linux の zip。macOS arm64 release zip 13.7MB） | 2026-10-26 push | wgpu-native 自体は Central に無い | 公式 Releases | Panama は JDK 21 では preview/22+ で正式。今回は試していない | Apache-2.0 | 自前で ObjC 呼び出し |
| LWJGL 自体の WebGPU | Central の org.lwjgl 配下に webgpu/wgpu の artifact は無い【確】 | - | - | - | - | - | - |
選定: jWebGPU 0.3.4 の JNI 版（JDK 21 で動く・Central にある・両バックエンドを選べる）。wgpu-native の FFM 直叩きは「ヘッダから全部書く」作業量のため時間内では見送り（【不明】: 性能・安定性）。
つまずき（重要）:
- 実行時の classpath に `webgpu-core` を入れてはいけない（スタブが先に読まれ UnsatisfiedLinkError）。README にも書いてある。
- 実行に要る jar: webgpu-jni, webgpu-desktop-jni, webgpu-desktop-jni-{wgpu|dawn}_mac_arm64, jParser の api-core / loader-core / runtime-jni / runtime-desktop-jni_mac_arm64（後者は pom の推移依存に出ないので手で足した）。
- ネイティブは $TMPDIR/jParser$USER/ に同名（libjWebGPUarm64.dylib）で展開される。wgpu 版と Dawn 版を続けて動かすと、同じパスの dylib が書き換わり macOS が「Code Signature Invalid」で JVM を即 SIGKILL する【確】。run.sh で毎回そのフォルダを消して回避。製品に入れる時は展開先を版ごとに分ける必要がある。
- 0.3.4 の WGPUInstanceDescriptor に setBackendType が無い（examples の SNAPSHOT にはある）。

## 2. 三角形を画面なしで描いて読み戻す 【確】
コマンド: `./run.sh Offscreen wgpu /…/triangle_wgpu.png`（BACK=dawn で Dawn 版）
- adapter（wgpu）: backend=Metal type=IntegratedGPU device=Apple M4 Pro。init（loader〜device）165ms。
- adapter（Dawn）: backend=Metal arch=metal-3 device=Apple M4 Pro、init 172ms。
- 256x256 RGBA8Unorm へ描画 → copyTextureToBuffer → mapAsync → PNG。中心画素 ff0066ff（期待どおり 0,102,255）、隅 ff1a1a1a。目視で青い三角形が出ている。
- PNG: pc/triangle_wgpu.png, pc/triangle_dawn.png

## 3. 窓に出す
コマンド: `JOPTS=-XstartOnFirstThread ./run.sh Window <wgpu|dawn> <vsync|novsync> window`
- LWJGL 3.4.1 GLFW（GLFW_NO_API）の窓は開いた。ObjC の自作は不要（バインディングが layer を作る）。
- Dawn 【確】: createMacSurface 約 0.7〜1.0ms。surface 形式 BGRA8Unorm。getCurrentTexture は SuccessOptimal。120 コマ描画して閉じた（フレーム中央値 0.03ms、encode+submit 0.027ms、120 コマの壁時間 23〜26ms。vsync 有無で差なし＝present がブロックしていない。窓が背面/非表示扱いの可能性。【不明】）。
- 画面に実際に三角形が出たかは screencapture が全面黒（権限か画面ロック）で確認できず 【不明】。
- wgpu-native 版（0.3.4 同梱）【確】: surface は作れる・形式一覧も取れるが、getCurrentTexture の status が不正値（raw=196609）で texture が null、createView で wgpu 側が panic（JVM 落ち）。形式を Bgra8Unorm に変えても同じ。原因は【不明】（同梱 wgpu-native と Java 側の構造体/enum のずれが疑い・【推】）。この版では窓出しは Dawn 版だけ使える。
- 自前 ObjC（LWJGL の JNI.invokePPP で contentView/CAMetalLayer を作って渡す）は pc/src/Mac.java に書いたが、バインディングは NSWindow を期待し、view/layer を渡すとハング（【確】、渡す物は NSWindow が正）。

## 4. 小さな重さの比べ（1024x1024 の画面なし RGBA8、四角 6 頂点を 1 個ずつ）
計測: ウォームアップ 40 コマ後の 100 コマの中央値。「CPU」は buffer 書き込み+encoder+draw 群+finish+submit まで（行列の生成 fill は除外・全方式同じ）。GL は glFlush まで。数値は ms。
コマンド: `JOPTS=-XstartOnFirstThread BACK=<wgpu|dawn> ./run.sh Bench <dyn|sto|gl> <wgpu|dawn>`（生ログ pc/b_*.log）

| 方式 | N=1,000 | N=5,000 | N=20,000 | 1 個あたり(N=20k) |
|---|---|---|---|---|
| OpenGL 3.3（glUniformMatrix4fv+glDrawArrays、実体は Apple の GL 4.1 over Metal） | 0.501 | 2.382 | 9.453 | 0.47 µs |
| wgpu-native (a) dynamic offset | 0.371 | 1.020 | 3.563 | 0.18 µs |
| wgpu-native (b) storage + 1 draw | 0.144 | 0.175 | 0.265 | 0.013 µs |
| Dawn (a) dynamic offset | 0.285 | 0.946 | 4.384 | 0.22 µs |
| Dawn (b) storage + 1 draw | 0.073 | 0.074 | 0.086 | 0.004 µs |
- 「GPU 完了まで待つ」込みの値は dyn 20k で 約 8.2〜9.1ms、sto は約 3.1〜3.3ms（ただし待ち方が Thread.sleep(1) 付きのポーリングなので約 3ms の床がある。GPU 時間の正確な値ではない）。GL は glFinish 込みで 20k=10.0ms。
- 描画結果の読み戻しによる絵の確認はベンチではしていない（Offscreen では確認済み）【不明】。
- 注意: 実際の engine は 1 個ごとにテクスチャ・ブレンド・パイプラインが変わる。ここは同一パイプラインの最良ケース。(a) は uniform を 256B 刻みで N 個並べるので 20k で 5.1MB を毎コマ書いた込み。

## 5. Java とネイティブの間の代金
- JNI 1 回の代金（WGPUVectorInt の clear/push_back 500 万回）: 約 3.7ns/呼び出し（wgpu・Dawn とも）【確】。(a) 方式は 1 個あたり JNI 4 回（clear, push_back, setBindGroup, draw）＝約 15ns で、0.18〜0.22µs の大半は JNI でなくネイティブ側の encode【推】。GL の 1 個 0.47µs（2 呼び出し）も同様にドライバ側。
- バッファの写し: `queue.writeBuffer(buffer, offset, ByteBuffer, size)` は direct ByteBuffer のアドレスを JNI にそのまま渡す（javap で確認・Java 側コピー無し）【確】。native 内で staging へ 1 回 memcpy（1/5/20MB で wgpu 約 9〜11GB/s、Dawn 約 14〜15GB/s）。heap の ByteBuffer は試していない【不明】。ByteBuffer には position/offset の指定が無く、先頭から size 分（スライスが要る）。buffer 側の offset は int（2GB 上限）。
- API は jParser 生成のオブジェクト版（WGPUxxx.obtain() の使い回しオブジェクトと WGPUVectorXxx への push_back で descriptor を組む）。1 個 draw ごとの dynamic offset も WGPUVectorInt に詰める形で、直接 int を渡す口は無い。Flix から呼ぶなら薄いラッパーが要る。

## 6. 配る時の重さ（jWebGPU 0.3.4 の Maven jar・圧縮）／ネイティブ展開後
| OS | wgpu 版 jar | wgpu 展開後 | Dawn 版 jar | Dawn 展開後 |
|---|---|---|---|---|
| macOS arm64 | 4.03MB | 11.6MB | 2.58MB | 9.4MB |
| macOS x64 | 4.12MB | 11.9MB | 2.79MB | 10.1MB |
| Linux x64 | 5.87MB | 17.8MB | 5.61MB | 16.0MB |
| Windows x64 | 3.32MB | 9.3MB | 2.09MB | 5.6MB |
Java 側: webgpu-jni 0.37MB、webgpu-core 0.19MB（コンパイル用のみ）、jParser 系 3 本 + runtime ネイティブ 計約 0.14MB（mac arm64）。参考: LWJGL 3.4.1 のうち lwjgl-opengl の mac arm64 ネイティブ jar は 43KB（GL は OS 同梱のライブラリを呼ぶだけ）。
参考: 公式 wgpu-native v29.0.1.1 の release zip は macOS arm64 13.7MB / Windows x64(msvc) 17.1MB / Linux x64 16.0MB。

## 結論（要約）
【確】JDK 21 + LWJGL 3.4.1 の GLFW 窓から、jWebGPU 0.3.4（JNI）の Dawn 版で Metal の surface を作り描画できる。画面なし描画・読み戻しは wgpu / Dawn 両方で成功。
【確】wgpu-native 版は窓の getCurrentTexture が壊れて使えない（画面なしは可）。
【確】多数の小物は GL より安い（dyn offset で約 2〜2.6 倍、storage+instance で数十倍）が、これは同一パイプラインの最良ケース。
【不明】実画面への表示・vsync の実挙動・Windows/Linux での動作・FFM 版・実エンジンの描画量での差。

---

# 第 2 回の試作（2026-11-14・P4a の危ない所を先に確かめる・この Mac だけ）

作業場所はこのフォルダ（`plans/webgpu/spike-pc/`）。jar は `fetch.sh` で `libs/` に取る（git には入れない）。
JDK は engine の devbox の Zulu 21.0.8。走らせる段の前に毎回 `guard.sh` が性能の測りの有無を見る
（`pgrep` の式に当たったのは、`--root` に `bench/scene3d` を含む flixlint の常駐 server だけだった。CPU 0% の型検査の常駐なので外した）。

| 口 | 中身 |
|---|---|
| `./build.sh` | `src/*.java` を `out/` へ |
| `NATIVE_DIR=$PWD/native/dawn JOPTS="-XstartOnFirstThread -Djava.awt.headless=true" ./run.sh WinCheck` | 1・2（`-Dfmt=bgra\|srgb` `-Dpresent=fifo\|immediate\|mailbox` `-Dretina=` `-Dvisible=` `-DsurfaceThread=worker` `-Dlsof=true`） |
| `NATIVE_DIR=… ./run.sh FiBench inst,fi,fi_bg,fi_mix,dyn 1000,5000,20000` | 3 |
| `hold/build-wg.sh && hold/flix.sh run` | 4（Flix 0.78） |
| `./run.sh Quirks`・`./native-test.sh`・`./native-test2.sh` | 5 |
| `java --enable-preview --source 21 panama/FfmProbe.java <dylib>` | 6 |

生の記録は `logs/`。絵は `shots/`（git には入れない。上の口で作り直せる）。

## 1. 窓に絵が本当に出るか — 半分通った

**通った所【確】**: LWJGL 3.4.1 の GLFW（`GLFW_NO_API`）の窓に Dawn で三角形を描き、**present の直前に surface の texture を `copyTextureToBuffer` で読み戻して**、
中・外・上下を見る 4 点が期待の値と 1/255 以内で一致した（`logs/wincheck_*.log`）。

| 設定 | 三角形の中 (0.3w,0.7h)・(0.5w,0.6h) | 外 (0.3w,0.3h)・隅 | 期待 |
|---|---|---|---|
| BGRA8Unorm（640x360） | 255,128,64 / 255,128,64 | 51,51,51 / 51,51,51 | 1.0, 0.5, 0.25 と 0.2 をそのまま 8 ビットに |
| BGRA8UnormSrgb | 255,188,137 / 255,188,137 | 124,124,124 | 書く時に sRGB の曲線が掛かった値 |
| 800x450 に広げて configure し直した後 | 同じ値（800x450 の位置で） | 同じ | — |
| 1280x720 → 1440x810 | 同じ | 同じ | — |

- surface の format は `BGRA8Unorm BGRA8UnormSrgb RGBA16Float RGB10A2Unorm`。先頭（auto）は BGRA8Unorm。
  **surface の usage に `CopySrc` を足して configure できた**（Dawn が拒まない。読み戻しの道に使える）。
- present mode は Fifo・Immediate・Mailbox の 3 つとも configure が通り、GPU の error は 0。
- `shots/win_bgra_readback.png` を目で見て、灰色の地に橙の三角形が上向きに出ている。
- createMacSurface の後、contentView の layer は `NSViewBackingLayer` から `CAMetalLayer` に替わった（Dawn が付けた）。
- **present の待ちは getCurrentTexture の側で起きる**: 120 コマの 1 コマの間隔の中央値は 7.9〜8.8 ms（約 120 Hz）。
  そのうち「描き先の取得〜encode〜submit」が 7.8〜8.7 ms、`present()` 自体は 0.013〜0.03 ms。Immediate・Mailbox でも同じ 8 ms 前後。
  window server が約 8 ms ごとに drawable を受け取って返している、という間接の証拠にはなる【推】。
  前の試作で 120 コマが 25 ms で回ったのとは違う（前と何が違ったかは【不明】）。
- 窓を広げた直後、configure し直す前の getCurrentTexture は **SuccessOptimal のまま**（Suboptimal も Outdated も返らない）。
  **大きさが変わった事は Dawn からは来ない。GLFW の framebuffer size の callback で configure し直す形が要る**【確】。

**通らなかった所【未確認】: 画面に出た絵を外から撮る事。**
- `screencapture -l <windowNumber>` は「could not create image from window」、ScreenCaptureKit（`tools/wincap.swift`）は SCStreamError -3811 で、どちらも撮れなかった。
- 原因は**画面のロック**: `ioreg` の `CGSSessionScreenIsLocked=Yes`（22:30:29 にロック）・`system_profiler` で 2 枚の表示とも `Display Asleep: Yes`。
  画面の収録の権限は有る（`CGPreflightScreenCaptureAccess()=true`）。全画面の `screencapture` も真っ黒だった。
- window server の側では窓は `kCGWindowIsOnscreen=1`・alpha 1（撮れないが、出ている扱い）。
- 前の試作の「撮った絵が黒」も同じ原因の見込みが高い【推】（前の試作の時刻にロックされていたかは【不明】）。
- **次に試す事**: 画面のロックが外れている時に `WinCheck` を回すだけ。`screencapture` と ScreenCaptureKit の 2 通りで撮り、中身の帯の中の三角形の割合（期待 1/8）と
  中と外の 1 点ずつを確かめる処理は書いてある。人の操作は要らないが、ロックが外れている時間に走らせる必要がある。
- Retina の 2 倍【未確認】: この起動ではどの窓も `backingScaleFactor=1.0`（表示が眠っている間の値か、外付けの表示が 1 倍なのかは【不明】）。
  `GLFW_COCOA_RETINA_FRAMEBUFFER` の有無で framebuffer の大きさは変わらなかった。configure は framebuffer の大きさで渡すので、2 倍でも同じ道で動く見込み【推】。

## 2. engine と同じ窓の作り方で載るか — 通った【確】

- engine は render_gl の `LwjglLayer.withLwjgl` で LWJGL 3.4.1 の GLFW の窓を作り、macOS では `ensureMainThread` が `-XstartOnFirstThread` を付けて起動し直す。
  試作も同じ版・同じ起動で、`JAVA_STARTED_ON_FIRST_THREAD_<pid>=1`・main thread で窓と surface を作った。
  WebGPU の時に変わるのは hint だけ（`GLFW_CLIENT_API=GLFW_NO_API`。GL の版・stencil・depth の hint が要らない）。
- `glfwGetCocoaWindow` の NSWindow をそのまま `createMacSurface` に渡せば、Dawn が CAMetalLayer を付ける（自前の Objective-C は要らない）。
- **ネイティブはぶつからない**: 同じ JVM で開いた dylib は LWJGL の `$TMPDIR/lwjgl_abab/3.4.1+2/arm64/{liblwjgl,libglfw}.dylib` と、
  jWebGPU の `libjWebGPUarm64.dylib`・`libruntimearm64.dylib` で、名前も置き場も別（`-Dlsof=true` の出力）。
  Dawn の dylib は Dawn を中に抱え、外へは Cocoa・Metal・QuartzCore・IOSurface・IOKit・libc++ だけを引く（`otool -L`）。GLFW とは共有しない。
- engine と同じく `-Djava.awt.headless=true` を付けても動いた。
- 隠した窓（engine の隠しウィンドウの形・`GLFW_VISIBLE=false`・Retina 切り）でも surface に描け、読み戻しが合った（GPU の error 0）。
  ただし**隠した窓でも 1 コマ約 8 ms で待たされる**。今の GL の隠しウィンドウ（vsync 切り）の代わりに surface を使うと harness が遅くなるので、
  画面なしの session（texture へ描く）を使うのが良い【推・設計の 5.3 と同じ】。
- device と surface を main 以外のスレッド（`-DsurfaceThread=worker`）で作っても落ちず、描画と読み戻しも合った。窓の物は main で扱う決まりなので、engine は今どおり main で作る。

## 3. `firstInstance` で 1 本ずつ draw を積む形の速さ — 通った【確】

1024x1024 の RGBA8 へ四角（6 頂点）を N 本。行列は storage buffer に 64 B ずつ。1 つの render pass。ウォームアップ 40 コマの後の 200 コマの中央値（ms）。
CPU は「encode（pass の begin〜end）」+「finish+submit」。GPU は pass の timestamp-query の差。別のプロセスで 3 回（`logs/fibench_run{1,2,3}.log`。3 回目は全体に遅く、機械の揺れ）。

| 形（N=20,000） | CPU（encode+submit）3 回 | うち encode | GPU の pass | writeBuffer |
|---|---|---|---|---|
| inst: `draw(6, N)` を 1 回 | 0.040 / 0.084 / 0.087 | 0.02〜0.04 | 0.328 | 0.03〜0.06 |
| **fi: `draw(6, 1, 0, k)` を N 回** | **1.60 / 1.59 / 2.48** | 0.34〜0.50 | 1.049 | 0.04〜0.06 |
| fi_bg: fi + 毎回同じ bind group を setBindGroup | 2.39 / 2.68 / 2.43 | 1.04〜1.17 | 1.049 | 0.04 |
| fi_mix: pipeline 2 本を 8 本ごとに切り替え + setBindGroup | 2.01 / 2.65 / 2.03 | 0.49〜0.63 | 1.311 | 0.04 |
| dyn: dynamic offset で毎回 setBindGroup（前の試作の (a)） | 3.44 / 3.91 / 3.47 | 1.31〜1.53 | 1.049 | 0.37 |

| N=5,000（CPU 3 回） | inst | fi | fi_bg | fi_mix | dyn |
|---|---|---|---|---|---|
| | 0.036 / 0.065 / 0.219 | 0.46 / 0.49 / 1.57 | 0.64 / 0.69 / 0.62 | 0.52 / 0.55 / 1.90 | 0.88 / 0.99 / 2.20 |

- **P4a の合格線（20,000 本で 3 ms 以下・setBindGroup を毎回呼ぶ形より速い）は通った**: fi は 1.6〜2.5 ms、dyn は 3.4〜3.9 ms。8 本ごとに pipeline を替えても 2.0〜2.6 ms。
- inst と fi は同じ絵になった（読み戻した 1024x1024 の FNV-1a が N ごとに一致）。GPU の error は全部 0。
- **代金の大半は `finish`+`submit`**（fi の 20,000 本で encode 0.34 ms・finish+submit 1.26 ms）。Dawn は記録を溜め、finish の時に Metal の命令へ直す【推】。JNI の 1 回（約 3.7 ns・前の試作）は小さい。
- GPU の側も 1 本ずつは 1 回描きの約 3.2 倍（1.05 ms と 0.33 ms）。2D の 20,000 個は 1 回描きにまとめる方が両方で得（設計の決まり 1・2 と同じ向き）。
- **timestamp-query の値は約 0.0655 ms 刻み**（2^16 ns。Dawn が時刻を丸めている【推】）。1 コマ全体の GPU の時間には足りるが、細かい pass の比べには粗い。
- 読み戻しで GPU の終わりを待つ所は、前と同じく `Thread.sleep(1)` の床（約 3 ms）がある（表の数字には入れていない）。

## 4. Flix から持てるか — 通った【確】

`hold/`（Flix 0.78・JDK 21）。`hold/spike/wgpu/` に Dawn の物を包む小さな Java の型（`WgDevice`・`WgBuffer`・`WgPipeline`・`WgTexture`）と、作る・描くの static の口 `Wg` を書き、`spike-wg.jar` にした。

- Flix の側（`hold/src/Main.flix`）: `type alias Gpu = { device = WgDevice, target = WgTexture, rows = WgBuffer, pipelines = Map[String, WgPipeline] }` に入れて運び、
  名前で pipeline を引いて描いて読み戻した: `orange` → `ff8040ff`・`teal` → `008080ff`（期待どおり）。
- `{ pipelines = Map.remove("teal", …) | gpu }` で record を写した後も、同じ device の物として描けた（`logs/hold_run.log`・`RESULT flix all=true`・GPU の error 0）。
- Java の import は `mod` の中・Java の呼び出しは `\ IO`（`Long.toHexString` は IO が付かず、付けると「Unused effect」で止まる）。
- **Flix は `flix.toml` に宣言の無い jar を classpath に入れない**（`lib/` に置くだけでは「Undefined Java class」）。手作りの jar は
  `[jar-dependencies]` に名前だけ書けば、同じ名前の file が `lib/external/` に有る時は取りに行かない（`Cached … from https://example.invalid/…` と出て通る）。
  engine に入れる時は、今の `fge-gl-*.jar` と同じく Release に置いた jar の URL を書く。

## 5. わかった癖を 1 つずつ

| 癖 | 確かめた事 | 手当ての案 |
|---|---|---|
| ネイティブを同じ名前で開く | jParser は `${java.io.tmpdir}/jParser${user.name}/<名前>` に、CRC が違う時だけ**その場で上書き**する（`JParserLibraryLoader` を javap で読んだ）。**片方のプロセスが開いている間に、別の backend のもう片方が上書きすると、上書きした側が SIGKILL**（2 回中 2 回・`logs/native-test2.log`）。前のプロセスが終わってから続けて動かすだけなら 11 回とも落ちなかった。同じ backend の 2 プロセス同時は、書き出しの前・後とも落ちない（`logs/native-test.log`） | 読み込みの間だけ `java.io.tmpdir` を「版と backend ごとの場所」に差し替える（`Gpu.loadNatives`・`Wg.open`。lsof で `native/dawn/` から開いている事を確かめた。分けると 2 回中 2 回落ちない）。engine では `~/Library/Caches/<engine>/jwebgpu/<版>-dawn/` のように版を名前に入れる。jWebGPU の版を上げても、古い版のゲームが動いている間に落ちなくなる |
| 上限の読みがずれる | **struct の並びはずれていない。** WGPULimits の native の中身を webgpu.h の並びで直に読むと値は正しい。webgpu.h で u64 の `maxBufferSize`・`maxStorageBufferBindingSize`・`maxUniformBufferBindingSize` の getter が int を返すため、下位 32 bit に切れている（adapter の生の値 41,747,087,360 → getter は -1,202,585,600）（`logs/quirks.log`）。また requiredLimits を渡さないと device の上限は仕様の既定（2D の texture 8192・storage の binding 128 MiB・buffer 256 MiB）になる | u64 の 3 つは `native_address` + webgpu.h の位置から直に読む（LWJGL の `MemoryUtil.memGetLong`）。device を作る時は adapter の `WGPULimits` をそのまま `setRequiredLimits` に渡す（device の 2D の texture が 16384 になる事を確かめた）。ただし storage と uniform の binding の大きさの setter は int しか受けないので 2 GiB 以上は要れない（今の使い方では足りる） |
| 機能の列挙が古い | 何も要らなくても device の feature に `CUSTOM(0x1)` が 1 つ返る（新しい webgpu.h の `CoreFeaturesAndLimits`【推】）。binding の enum は 16 個の名前しか持たない。`WGPUFeatureName.CUSTOM.setValue(1)` を requiredFeatures に積むと受け付けられ、device の feature に `CUSTOM(0x1) TimestampQuery` が出た | 名前の無い feature は数で要る。`core-features-and-limits` もこの形で要れられる。CUSTOM は 1 つの値を持ち回る作りなので、使い回す前に値を読んで写す |
| jar が依存に出ない | **Flix の `[mvn-dependencies]` に `webgpu-desktop-jni` と `webgpu-desktop-jni-dawn_mac_arm64` の 2 行を書けば、`runtime-desktop-jni_mac_arm64` まで 7 本全部取れた**（ネイティブの jar の pom が scope=runtime で持っている。Flix の Maven の解決は runtime も拾う）。木に出ないのは機種ごとのネイティブの jar そのもの | OS ごとのネイティブの jar の行を並べる（今の LWJGL の natives と同じ形）。`webgpu-core` は木に入らない（入れると UnsatisfiedLinkError・前の試作） |
| Dawn は 1 つの adapter から device を 1 つしか作らせない | 2 つ目の requestDevice が「adapter is "consumed"」で失敗 | device を作り直す時（device lost を含む）は adapter から取り直す |

## 6. Panama（FFM）で webgpu.h を直に呼ぶ道

**配り方（公式の GitHub Release だけを見た・2026-11-14）**

| | wgpu-native v29.0.1.1（2026-06-23） | Dawn v20261113.214538（毎日出る） |
|---|---|---|
| macOS arm64 の物 | `wgpu-macos-aarch64-release.zip` 13.7 MB: `include/webgpu/webgpu.h`・`wgpu.h`・**`lib/libwgpu_native.dylib` 6.9 MB**・`.a` | `…-macos-latest-Release.tar.gz` 13.9 MB: `include/webgpu/webgpu.h` ほか・**`lib/libwebgpu_dawn.a` 21 MB（dylib は無い）**・tint の .a |
| ほかの OS | Windows・Linux の zip あり | Windows 119.6 MB・Linux 36.8 MB・Apple の xcframework・headers だけの tar も別に有る |
| そのまま FFM で開けるか | 開ける | dylib を自分で作る（`clang -dynamiclib -Wl,-all_load libwebgpu_dawn.a -framework Metal …` で 11 MB の dylib ができ、`wgpu*` が 279 個出た） |

**試した事【確】**: JDK 22 以上はこの機械の nix store に無かった（有るのは zulu 21.0.2・21.0.8・21.0.11）。devbox で新しく入れる事はしなかった。
代わりに **JDK 21 の FFM（preview・`--enable-preview`）** で、jextract を使わず struct を手で並べ（`panama/FfmProbe.java`・約 90 行）、
instance を作る → requestAdapter（callback を upcall で受ける・struct を値で渡し、値で受ける）→ adapter の info と limits を読む、まで 3 つの dylib で通った（`logs/ffm_*.log`）:

| dylib | adapter の説明 | maxTextureDimension2D | maxStorageBufferBindingSize | maxBufferSize |
|---|---|---|---|---|
| wgpu-native v29.0.1.1 | device=Apple M4 Pro | 16384 | 4,294,967,292 | 41,747,087,360 |
| jWebGPU 0.3.4 の Dawn の dylib（`wgpu*` を 263 個出している） | Metal driver on macOS 27.0.1 | 16384 | 41,747,087,360 | 41,747,087,360 |
| 公式の Dawn の `.a` から作った dylib | 同上 | 16384 | 4,294,967,292 | 4,294,967,295 |

- u64 の上限も正しく読めた（jWebGPU の getter の切れは起きない）。三角形を描いて読み戻す所までは【未確認】（descriptor の struct をあと 15 前後並べる量）。
- **jWebGPU の Dawn の dylib は C の API を出している**。JNI の口が壊れている所だけ FFM で同じ dylib を直に呼ぶ、という混ぜ方もできる【推】（JDK 22 以上が要る。21 の preview は製品に使えない）。
- jextract: 公式の配り物は jdk.java.net（OpenJDK）で、GitHub の Release には無い。この機械には無い【確】。手で並べる形でも、使う物だけなら量は読める（engine が使うのは数十の関数の見込み・設計の 5.2）。
- **Flix 0.78 と JDK**: `flix.jar` の class file の版は 65（Java 21）なので JDK 22 以上でも読める【推】。devbox は `jdk@21`、nix の `flix` の起動 script は zulu 21.0.11 を名指し。
  JDK 22 以上の上で Flix のコンパイラと engine のテストが通るかは【未確認】。試すのに要る物は JDK 22 以上（例: nixpkgs の `jdk23` か `zulu23`）を、試作のフォルダの shell だけで PATH の先頭に置く事。devbox.json は触っていない。

**jWebGPU で行く／Panama で行く の比べ**

| | jWebGPU 0.3.4（JNI） | Panama で webgpu.h を直に（wgpu-native か Dawn） |
|---|---|---|
| 要る JDK | 21（今のまま） | 22 以上（devbox と配る JRE を上げる。Flix 0.78 が 22 以上で動くかは未確認） |
| 配る物（macOS arm64） | jar 2.58 MB（展開後 9.4 MB）+ Java 側 0.5 MB | wgpu-native: dylib 6.9 MB（zip 13.7 MB）／Dawn: 自分で作る dylib 11 MB。どちらも jar に入れて自分で展開する（置き場は自分で決められる） |
| 保守 | 1 人の保守（最後の commit 2026-09-20）。enum が古い・u64 の getter が切れる・ネイティブの置き場の癖。上流の Dawn の版を選べない | 上流（Dawn は毎日・wgpu-native は数か月ごと）をそのまま使う。webgpu.h が変わるたびに手の struct（か jextract の生成物）を直す |
| 窓のつなぎ方 | `createMacSurface(NSWindow)` が CAMetalLayer まで作る（確かめた） | `WGPUSurfaceSourceMetalLayer` に CAMetalLayer を渡す。layer は自分で作って NSView に付ける（LWJGL の `ObjCRuntime` と `JNI.invokePPP` で書ける。`src/Mac.java` に下書きあり） |
| 手間 | 包む型だけ（このフォルダの `Wg` で約 200 行） | 使う struct と関数の宣言（手なら数百行・jextract なら生成）+ 包む型 + OS ごとのネイティブを配る段取り |
| 速さ | JNI 1 回約 3.7 ns。20,000 本の draw で 1.6〜2.5 ms（大半は Dawn の中） | 【未確認】。FFM の 1 回の代金は JNI と同じ桁の見込み【推】。Dawn の中の代金は同じ |
| 壊れた所の逃げ道 | 壊れた getter は native の中身を直に読んで避けられた。直せない所が出たら fork か Panama | 自分で直せる |

見立て【推】: **P4a は jWebGPU のまま進めて良い**（JDK を上げずに、窓・読み戻し・Flix からの持ち方・`firstInstance` の速さが全部通り、癖は全部手当てが見つかった）。
`WebGpu` の interface の裏に隠すので、jWebGPU が止まった時・Dawn の新しい機能が要る時に Panama の実装へ替える。その時の候補は、
dylib をそのまま配れる wgpu-native（ただし前の試作で jWebGPU 同梱の wgpu は窓で落ちた。公式の v29 で窓が通るかは【未確認】）か、
上流に近い Dawn（dylib を自分で組む段取りが増える）。

## 設計（P4a・10 章）への反映

**「確かめた」に変わった物**
- P4a「Dawn の実装で三角形・読み戻し・ウィンドウ」: 窓の surface へ描いた絵を present の前に読み戻して一致（画面の上の絵は下の【未確認】）。
- P4a「limit を Dawn から正しく読める事」: 読める（u64 の 3 つは native の中身から直に。requiredLimits に adapter の値を渡す）。
- P4a「2 プロセス同時に起動して落ちない事」: 同じ backend・同じ版なら落ちない。違う物が同じ場所に書くと落ちる → ネイティブの置き場を版ごとに分けると落ちない。
- P4a「`firstInstance` の試作」: 20,000 本で 1.6〜2.5 ms（合格線 3 ms 以下・dynamic offset の 3.4〜3.9 ms より速い）。
- 5.2「物を Flix の record や Map に入れて運べる事」: 運べる（PC の側）。
- 5.2「`core-features-and-limits` を求め、`timestamp-query` をあれば使う」: どちらも要れられる（前者は数で）。
- 10 章の jWebGPU の癖 4 つ: 原因と手当てが分かった（上の 5 の表）。「依存に出ない jar」は Flix の Maven の解決では起きない。
- 10 章「PC のウィンドウに絵が出ない」のうち、LWJGL の GLFW の窓との相性・main thread の決まり・ネイティブのぶつかり: 問題なし。

**「危ない」と分かった・設計に足す物**
- present の待ちが getCurrentTexture に来る（`glfwSwapBuffers` の位置ではない）。1 コマの時間の測り方と、`finishAfterSwap` の置き換え（5.3 の表）に響く。
- 隠した窓でも約 8 ms ごとに待たされる。headless の harness は surface を使わず、画面なしの session（texture へ描く）にする。
- 窓の大きさが変わっても Dawn は SuccessOptimal を返し続ける。GLFW の callback で configure し直す（5.3 の「作り直す（リサイズ）」の行の実装の決まり）。
- timestamp-query は約 65.5 µs 刻み。GPU の時間の診断の細かさに限りがある。
- jWebGPU の版を上げる時は、ネイティブの置き場の名前に版を入れないと、古い版のゲームが動いている間に新しい版が起動すると落ちる。

**まだ【未確認】**
- 画面に出た絵を外から撮って確かめる事（画面のロックで撮れなかった。ロックが外れている時に `WinCheck` を回せば機械で決まる）。
- Retina の 2 倍の時の大きさ（この起動では倍率 1）。
- 人が窓の縁を掴んで広げている間（live resize）の描き直し。
- Windows・Linux（人の判断でやらない）。
- Panama で三角形を描いて読み戻す所・JDK 22 以上での Flix。

## 入れた物と版

| 物 | 版 | 出どころ | 使い道 |
|---|---|---|---|
| jWebGPU `webgpu-jni`・`webgpu-desktop-jni`・`webgpu-desktop-jni-{dawn,wgpu}_mac_arm64`・`webgpu-core` | 0.3.4 | Maven Central（前の試作が取った物を写した） | 1〜5 |
| jParser `api-core`・`loader-core`・`runtime-jni`・`runtime-desktop-jni_mac_arm64` | 1.2.8 | Maven Central | 同上 |
| LWJGL `lwjgl`・`lwjgl-glfw`・`lwjgl-opengl`（+ macos-arm64 の natives） | 3.4.1 | Maven Central（render_gl と同じ版） | 1・2 |
| hold/ の Flix の依存（2 行から解決された 7 本） | 0.3.4 / 1.2.8 | Flix の Maven の解決（Maven Central）→ `hold/lib/cache` | 4・5 |
| `webgpu-jni-0.3.4.pom`（依存の木を読むため） | 0.3.4 | Maven Central | 5 |
| wgpu-native `wgpu-macos-aarch64-release.zip` | v29.0.1.1 | gfx-rs/wgpu-native の GitHub Release | 6（`panama/dl/`・git には入れない） |
| Dawn `Dawn-7daf3b0b…-macos-latest-Release.tar.gz` | v20261113.214538 | google/dawn の GitHub Release | 6（同上） |

sha256（jar）: webgpu-jni `7a0ff4a5…71fda`・webgpu-desktop-jni `c6deada2…1aa3`・…-dawn_mac_arm64 `bdc37dc3…65db`・…-wgpu_mac_arm64 `226eb451…0548`・webgpu-core `8c645ac5…ca3f`・
api-core `de339e8b…a97a9e`・loader-core `df891003…36361`・runtime-jni `2913c911…6596f`・runtime-desktop-jni_mac_arm64 `d04e8dea…1dc1793`。
