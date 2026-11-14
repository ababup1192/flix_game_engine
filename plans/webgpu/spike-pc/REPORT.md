# WebGPU スパイク（PC / Apple M4 Pro・macOS）報告

作業場所: /private/tmp/claude-501/-Users-abab--claude-spares-spare-q72Ibn/1e409b86-520d-4126-86d6-d8af78577988/scratchpad/webgpu-spike/pc/
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
