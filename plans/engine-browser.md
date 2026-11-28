# ブラウザで遊べるようにする計画（2026-11-03）

前の調査: [browser-spike.md](browser-spike.md)。今回のスパイクの記録（数字・置き場・作り方）: [engine-browser-spikes.md](engine-browser-spikes.md)。
マーク: **【確】** スパイクで確かめた（確かめた範囲を括弧で書く） / **【推】** 推測（確かめ方を横に書く） / **【不明】**。

## 目標と進む順（人の決定・2026-11-04）

人の言葉: 「RPGをスマホで遊べるようにする → 不具合やパフォーマンスに問題ないことを確認する → internet-dungeonを動かす → パフォーマンスに問題があれば、磨ける部分を磨く → 問題なくなったらブラウザに関してはゴール」

1. **rpg-starter と sound-novel-starter をスマホで遊べるようにする**（フェーズ 1 = C8 → フェーズ 3 → フェーズ 4 → フェーズ 5。PC のブラウザは途中の確かめとして通る）
2. **2 本で不具合と速さを確かめる**（実機は Android。iPhone は端末が手に入った時）。あわせて次の 3 つに答えを出す（人の話・2026-11-04）:
   - スマホの画面で字が読みやすいか（縦持ち・横持ちそれぞれで、字の実際の大きさを測る）
   - メニューや UI の配置に、スマホ向けの手直しが要るか（指で押せる大きさ・パッドと重ならないか）
   - ブラウザ版と PC 版で振る舞いを分ける仕組みが要るか。要るなら何で分けるか（「ブラウザかどうか」より「画面の形・入力の種類（指かマウスか）」で分ける方が、PC のブラウザやタブレットでも正しく振る舞う【推】）
   - **操作感と重さで、スマホで遊べる既存の RPG 制作ツールの作品に勝つ**（人の目標・2026-11-04）。数字で比べる物: 開いてから操作できるまでの秒数・マップの切り替えと戦いの入りで止まる時間（その場で絵と音を読まない＝場面の前に読み終える）・タップしてから動き出すまでの遅れ・1 分あたりのコマ落ち。操作は十字キーのパッドに加えて「タップした所へ歩く」も候補【推】。
3. **internet_dungeon（`~/Desktop/internet_dungeon`・engine 0.70.0・5.5 万行・日本語の会話・ShaderDoc・音 57MB）を動かす**（先に engine の今の版への追随。下見は `engine-browser-spikes.md` の末尾）
4. **速さに問題があれば磨く**（View の組み立て・動かない物の使い回し・描かないコマを飛ばす・TeaVM の設定の順に、測ってから）
5. 問題が無くなったら、ブラウザはゴール

- フェーズ 0b の実機の結果（Android で PC の約 3 倍）は引き継ぐ。

## 範囲の決定（人の決定・2026-11-03）

- 「f8 デバッグなどはいらないかな。最終ビルドでゲームを配るときの一つという認識なので」
  → ブラウザ版は**完成したゲームを配る出力先の 1 つ**。開発はデスクトップ版でやる。
  **外す**: F8 の停止と注釈のチケット・RemoteDebug・Doc の読み直しと監視（watchFile・F1）・Studio との行き来・flow の記録と再生・ヒッチの記録・描き出し（SceneRender・engine_tools）。Doc は起動時に読む値として同梱する。
  **残す**: 描画・入力・音・セーブ・素材の読み込み。
- 「スマホからのプレイとかもできるかな？ 疑似ボタン出すか タッチのゲームとして」→ 後ろのフェーズに入れる（最初の到達点は PC のブラウザ）。
- 「ノベルゲーや RPG が遊べたらとりあえず合格」
  → **ゴール = sound-novel-starter と rpg-starter が PC のブラウザで遊べ、スマホのブラウザでも遊べる（ノベルはタップ・RPG はバーチャルパッド）**。
  3D・タッチ入力のエンジン拡張・WebGPU はゴールの外（後のフェーズとして名前だけ残す）。
- 合意済みの方針: 描画は WebGL2 が先で WebGPU は後。render_gl の GL の呼び出しを薄い 1 枚の層にそろえ、その下に LWJGL 版と WebGL2 版を置く（描く手順の本体は 1 本・gl-parity も同じ物差し）。シェーダーは `#version` 行だけ出し分ける。エンジンに足すときは歪み・重複を直しながら足し、2D 専用・3D 専用・共通が名前とモジュールで分かるようにする。

## 結論（10 行）

1. 道は前の調査どおり **Flix → JVM のバイトコード → TeaVM 0.14.1（WASM GC）＋ ブラウザ用の handler 一式**。ゴールの 2 本の「World を進める所と View で描く物を作る所」が TeaVM を通り、JVM と同じ結果を出した【確（描き手・音・入力は stub）】。
2. 速さ: 測った範囲（World の更新＋View→Render→描く命令の列）で JVM の **1.7〜2.6 倍**（rpg・ノベル）。決め所の 3 倍以内に入った【確（JVM は nice で別の作業と同時に走らせたので ±30% の幅で読む）】。描き手（RenderPaint の詰め替え）と、rAF を待つことで TeaVM がかけるコルーチン変換の代金は**まだ測っていない**【推】→ フェーズ 3 の頭で測り直す決め所を置く。
3. 止まる形のループのまま handler が rAF を待てば、小さなループで 165Hz に遅れなく乗った【確（小さなループ）】。本物の `App.launch` で同じになるかは【推】。「1 コマだけ進める」入口は、今は足さない。
4. 今の GLSL は `#version` 行を `#version 300 es`＋precision に替えるだけで、2D の固定シェーダー・ShaderGen の出力・ノベルの背景 25 本が **WebGL2 でコンパイル・リンクを通った**【確（コンパイルまで）】。ただし **絵が同じになるとは限らない**: render_gl の 2D の道は WebGL2 に無い形式を 2 つ使う（ARGB を BGRA＋`UNSIGNED_INT_8_8_8_8_REV` で上げる・フォントアトラスを R8＋swizzle で alpha に見せる）。swizzle が無いと字が全部四角になる。→ フェーズ 1 で、この差を「意図の名前の関数」にして層の中で吸収する（下）。
5. TeaVM の JSO に WebGL2・WebAudio・Gamepad のバインディングが揃っている。ただし **JSO の値を Flix の総称のデータや Object に入れると wasm が落ちる**ので、JS の物は Java の薄い facade（`fge.web`）に閉じ込め、Flix には int のハンドルと java.nio のバッファだけを見せる【確】。
6. エンジン側の作業は 3 つ: ①GL の呼び出しの層 `GlContext`（render_gl の 2D の道・バッファの確保の差し替え込み・**RenderPaint が直に呼んでいる Render3d を外から渡す形に切り出す**・デスクトップの整理）②開発の道具を起動の道から外す `App.DevTools`（pub の形は変えない）③`engine_full_web` の束に足すファイル群 `engine_web`（`WebLayer`・`WebFs`・`fge.web`）。テンプレ側は engine_tools へつながる 1〜2 行を Main へ移すのと、ブラウザの入口 `web/WebMain.flix`。
7. TeaVM の穴は 4 つ（仮想スレッド・lock 類・ConcurrentLinkedQueue・`Arrays.copyOfRange` の不具合）。小さな shim と jar のバイトコードの付け替えで 0 件になった【確】。エクスポートツールに組み込む。
8. **iOS の実機で動くかを、フェーズ 1 の前に確かめる**（30 分・人の端末が要る）。動かなければゴールの半分の作り方が変わるため。
9. 見積もり【推】: フェーズ 0b（実機の確認・層の形のマイクロベンチ・ALPHA 形式の確認）0.5〜1 週 → フェーズ 1（GL の層・2D と 3D の切り分け）3〜4.5 週 ∥ フェーズ 2（DevTools）1.5〜2 週 → フェーズ 3（handler とエクスポート・**最初の到達点 = rpg-starter が PC で遊べる**）5.5〜7.5 週 → フェーズ 4（ノベル PC）1〜1.5 週 → フェーズ 5（スマホ）2.5〜3.5 週。**ゴールまで 13.5〜19 週（2 を並行した場合）・15〜21 週（1 人で全部直列に積んだ場合）**。
10. 大きな残りの危険: iOS Safari（WASM GC の版・音のアンロック・全画面が無い・7 日でストレージが消える）、TeaVM が個人中心の道具であること、コンテキストロスト（タイル層のハンドルを App が持っている）。

## フェーズの一覧

| フェーズ | やる事 | 到達点 | 見積もり【推】 | 決め所 |
|---|---|---|---|---|
| 0 下見 | スパイク 1〜7 | 済み（[記録](engine-browser-spikes.md)） | — | 3 倍以内 → 進む（測った範囲で最大 2.6 倍） |
| 0b 前提の確認 | ①iOS / Android の実機で既存のスパイクの頁を開く ②`GlContext` の形のマイクロベンチ ③ALPHA 形式で SDF の字が出るか | 実機で WASM GC・WebGL2・WebAudio が動く版が分かる。層の形と字の上げ方が決まる | 0.5〜1 週 | iOS で WASM GC が動かない版が対象に多い → TeaVM の JS 出力を同じ頁で試してから進む |
| 1 GL の層（2D と 3D の切り分け） | render_gl の 2D の道の GL の呼び出しとバッファの確保を `GlContext` へ。WebGL2 と違う形式は意図の名前の関数に。RenderPaint から Render3d を外から渡す形（`Scene3dRenderer`）に切り出す。既存のキャプチャの口で控えを取る | 本体が `org.lwjgl.*` も `java.awt` も import せず、`Scene3dRenderer.none()` の 2D の入口から Render3d に届かない。デスクトップの GL のキャプチャがバイト一致 | 3〜4.5 週 | 1 コマの時間が中央値で 5% 以上増えた → 0b で 2 番目だった形へ替える |
| 2 開発の道具を外へ | 起動の道から RemoteDebug 等を `App.DevTools` へ（pub の形は残す）。テンプレの engine_tools への行を Main へ | rpg とノベルの本物の WebMain を TeaVM にかけて ERROR 0 件 | 1.5〜2 週（相談・`engine_full_web` の入口込み） | — |
| 3 handler とエクスポート | `engine_web`・エクスポートツール・フォントアトラスの事前生成・起動の流れ・gl_parity の web 版 | **rpg-starter が PC の Chrome / Firefox / Safari で最後まで遊べる**（音・セーブ込み） | 5.5〜7.5 週 | 頭で、本物のループと描き手込みの 1 コマの CPU を測る。閾値はスマホから逆算（下の「速さの閾値」）: PC で 3ms 以下なら進む・3〜6ms なら速さの手当てをフェーズ 5 の前に入れる・16ms 超なら止めて別の道を測る |
| 4 ノベル PC | 写真の背景・日本語のフォントアトラス・マウス・全画面・時刻 | sound-novel-starter が PC で最後まで読める | 1〜1.5 週 | — |
| 5 スマホ | バーチャルパッド（rpg）・タップ（ノベル）・画面の向きと拡大・iOS の癖・音のアンロック・実機の速さ・コンテキストロスト | **ゴール**: 2 本が iPhone と Android のブラウザで遊べる | 2.5〜3.5 週 | 中くらいの Android で 1 コマの CPU が 12ms 超 → 30fps の設定か手当て |
| 後（ゴール外） | タッチ入力の拡張・3D（Render3d の層への移し替えを含む）・WebGPU・TeaVM を上げる・Studio に「Web にエクスポート」 | — | — | — |

### 速さの閾値（スマホから逆算する）

- ゴールはスマホで遊べること。60fps の 1 コマは 16.7ms で、そのうち CPU（wasm の中の World・View・描き手）に使ってよいのを 12ms と置く（残りは GPU とブラウザ）。
- スマホは PC（この Mac）の 3〜6 倍遅いと見る【推・0b ①で実機の Bench を開いて直す】。→ **PC の 1 コマの CPU は 2〜4ms 以下**が要る。フェーズ 3 の頭の決め所は「3ms 以下なら進む」。
- 3〜6ms なら、フェーズ 5 の前に速さの手当てを入れるか、スマホでは 30fps（33ms）を許すかを人が決める（人に決めてほしい事 13）。ノベルは 30fps でも遊びに困らない【推】。
- スパイク 1 の値（World と View だけ・描き直しの回数で割って rpg の戦い約 1.2ms・ノベルの会話約 0.6ms）は、この閾値の内側にある。描き手とコルーチン変換の分がどれだけ乗るかが残り。

依存: 0b → 1。2 は 0b・1 と独立（並行できる。触るのは engine_world の App とテンプレ）。ただし 2 の後半（到達点の確かめ）は、先に `engine_full_web` の make の入口を作ってから。3 は 1 と 2 の両方が要る（`GlContext` の WebGL2 版と、ERROR 0 件の起動の道）。4・5 は 3 の上。

---

## フェーズ 0b — 前提の確認（フェーズ 1 の前に）

1. **実機の確認（人の端末で 30 分・段取り込みで半日）**: スパイクの頁（`site-gs`＝1 コマの速さ・`site-pad`＝バーチャルパッドとセーブと音・`site-rpg`＝rpg の 1 コマ・`site-gl`＝WebGL2 と rAF）を、iPhone の Safari と Android の Chrome で開く。
   - **段取り**: 今の頁は消えうる scratchpad にあり、jwebserver は 127.0.0.1 だけで待つ。LAN の `http://` は secure context ではない（`navigator.storage.persist`・`audioSession` などが使えない）。→ ①頁と wasm をリポジトリの外の決まった場所（例 `~/Documents/fge-web-spike/`）へ写して残す ②HTTPS で配る（GitHub Pages の私用の repo か、`npx` を使わずに済む物なら何でも）。人の判断で置き先を決める（人に決めてほしい事 12 と同じ）。
   - 見る物: wasm が読めるか（WASM GC と例外処理）・1 コマの µs（PC の何倍か → 速さの閾値を直す）・タップが全部届くか・音が鳴るか（消音スイッチ・`navigator.audioSession.type = 'playback'` を付けた時）・rAF の間隔（**低電力モードで 30Hz に落ちる**【推】）・`MAX_TEXTURE_SIZE`（安い Android は 4096 の物がある【推】）。iPhone の Chrome / Firefox も中は WebKit なので、iOS は Safari の結果で代表できる【推】。Safari の WASM GC の対応は 18.2 以降と記憶している【推】。
   - 動かない iOS の版が多い → 同じ jar を TeaVM の JS 出力にかけて同じ頁で試す。JS 出力は前の調査で Float32 が 1 ビットずれ、`Thread.sleep` の形では rAF に返らなかった。`@Async` の rAF 待ちなら返る見込み【推】。JS 出力に乗るならフェーズ 3 の作り方（浮動小数の前提・速さ）を見直す。
2. **`GlContext` の形を決める（半日〜1 日）**: 1 コマに数千回 GL の関数を呼ぶ形を、(i) 直の静的呼び出し（基準） (ii) Flix の record の欄の関数 (iii) Java の interface 越し (iv) ビルドの時に同じ名前のモジュールを差し替える形、で比べる。判定は速さだけでなく、
   - **録る版が作れるか**（フェーズ 1 の確かめ方は `GlContext.recording(inner)` のように「中身を包む値」を前提にする。(iv) は値ではないので包めない）
   - **パッケージとして組めるか**（engine_full と `engine_full_web` の両方で同じソースから組めるか）
   - **gl の値を全部の関数へどう届けるか**（描く手順の関数の引数に足す・今 GL の文脈を持ち回している `Paint` のレコードに 1 欄足す・起動時に 1 度だけ入れる Ref のどれか。本体は今 GL を静的に呼んでいるので、引数に足すと書き換えの量が増える）
   で見る。Flix の record は欄を名前で引く作りとみられ、closure の呼び出しで引数を箱に入れる代金も乗りうる【推】。推しは**値の層（record か interface のうち速い方）**（人に決めてほしい事 4）。
3. **ALPHA 形式の確認（半日）**: フェーズ 1 は `texImageAlphaMask` の形を前提に書き換えるので、先に確かめる。スパイクの `site-gl` の頁に、1 画素 1 バイトの `ALPHA` 形式で SDF の 1 字（デスクトップの生成した距離場をそのまま）を上げ、今の sprite のシェーダー（`.a` を読む）で描いて、デスクトップの GL のキャプチャと見比べる。外れたら推し 9 の代わりの案（デスクトップも `.r` を読む）へ。

## フェーズ 1 — GL の呼び出しを 1 枚の層へ（2D の道・デスクトップの整理・絵を変えない）

### やる事

- **`GlContext`**（GL の関数を集めた 1 つの値・名前は Rust の glow の `glow::Context` にそろえる）を作り、render_gl の 2D の道の GL の呼び出し（grep で字を数えて約 470 か所: Sprite 239・Shader 72・Target 39・GlOffscreen 30・LwjglLayer 21・Frame 19・RenderTexture 18・Paint 15・Font 9・GlyphGrow 5）をそこへ通す。ハンドルは今と同じ int、バッファは java.nio。
- **バッファの確保も層へ**: 本体は GL 以外の LWJGL も直に使う（`RenderBuf` の `MemoryUtil.memAllocFloat/memFree`・`RenderTexture` の `memAllocInt` と `MemoryStack`・`RenderGlyphGrow` と `RenderFont` の `MemoryStack` / `BufferUtils`・`RenderTargetGl` の `BufferUtils`・`RenderFontCache` の `BufferUtils`・`RandomAccessFile`・`FileChannel`・`CRC32.update(ByteBuffer)`・`File.exists`・`MessageDigest`（`FontCache.flix:9-22`）、約 50 か所）。ネイティブの malloc なので TeaVM を通らない。`GlContext` に「直接バッファを取る・返す」を入れる（LWJGL 版は今の memAlloc、WebGL2 版は `ByteBuffer.allocateDirect`。スパイクで WebGL2 に渡せたのは後者【確】）。
- **WebGL2 と違う所は、意図の名前の関数にする**（GL の素の関数ではなく）。中身は LWJGL 版で今と同じ呼び出し、WebGL2 版で同じ結果になる別の呼び出し:

  | 今の形（デスクトップ） | 使う所 | 意図の名前（案） | WebGL2 版 |
  |---|---|---|---|
  | `GL_BGRA`＋`UNSIGNED_INT_8_8_8_8_REV` で ARGB の int 列を上げる | `RenderTexture.texImage`（**rpg のドット絵のアトラスは全部ここ**・rpg の project.json は `"textures": []`）・`Target.flix:65-66`（レンダーターゲットの確保） | `texImageArgb` | `fge.web` の中で ARGB → RGBA のバイトへ並べ替えて `RGBA8`・`UNSIGNED_BYTE`。鍵が同じ間は上げ直さないので、並べ替えの代金は上げる時だけ |
  | `GL_R8` で上げて `TEXTURE_SWIZZLE` で (1,1,1,R) に見せ、シェーダーが `.a` を読む | `Font.flix:293-300`・`GlyphGrow.flix:157`・`Shader.flix:67,236` | `texImageAlphaMask` / `texSubImageAlphaMask` | WebGL2 に swizzle は無いが、旧来の **`ALPHA` 形式**（1 画素 1 バイト・読むと (0,0,0,a)）は使える【推: WebGL2 の仕様で unsized の ALPHA は texImage2D に渡せる・フェーズ 0b ③で確かめる】。シェーダーは `.a` だけ読むので変えずに済む。RGBA に広げる逃げ道は、4096² のアトラスで 64MB（8192² なら 256MB）になるので取らない |
  | `glReadPixels` を BGRA で | `GlOffscreen`（デスクトップ専用） | そのまま（WebGL2 版は持たない） | — |
- **生成する所・デコードする所と、GPU へ上げる所を分ける**: `Font.flix`（stb の SDF 生成と GL の上げ）・`RenderTexture.flix`（stb の画像デコードと GL の上げ）・`RenderPaint.loadAssets` は同居している。生成・デコードはバックエンドの都合（デスクトップは stb・ブラウザは事前生成と `createImageBitmap`）なので `LwjglLayer` 側へ、上げる所は `GlContext` 経由の本体へ。
- 本体の一覧（2D・共通）: `RenderSprite` `RenderPaint` `RenderFrame` `RenderTargetGl` `RenderStatic` `RenderShader` `RenderBuf` `RenderTexture`（上げる所） `RenderGlyphGrow`（上げる所） `Scene3dRenderer`（型だけ）。`RenderFontCache` は「byte 列からフォントアトラスを読む所（本体・純粋）」と「ファイルを開いて読み書きし、鍵を MessageDigest で作る所（デスクトップ）」に分ける（ブラウザはアセットバンドルの byte 列から読む）。`GlReadback`（AWT と ImageIO）と `GlOffscreen` はデスクトップ専用として本体の外に置く（同じ層は使う）。
- **2D の道から Render3d へ静的に届いているのを切る**（ソースで確かめた）: `RenderPaint` は `Paint` のレコードに `render3d = Render3d.State` を持ち（`Paint.flix:52`）、`Render3d.fresh`・`drawItem`（238-240）・`endFrame`（376）・`prepareScenes`（387-388）を直に呼ぶ。`Frame`（RenderFrame）の並べ替えも `Merged.MScene3d(Render3d.SceneItem)`（`Frame.flix:23`）と `drawScene` を持つ。TeaVM は呼ばれるかどうかでなく静的にたどるので、2D のゲームでも Render3d の LWJGL の呼び出し 255 か所を全部読み、ERROR になる。
  - 手当て: 3D を **外から渡す値 `Scene3dRenderer`** にする（欄は `prepare`・`drawItem`・`endFrame`・場面の z を返す関数。3D の場面を描く役を外から渡す）。`RenderPaint` は `Scene3dRenderer` を受け取って呼ぶだけにし、`Render3d` の名前を書かない。`Frame` の `MScene3d` は `Render3d.SceneItem` ではなく `Scene3dRenderer` の持つ不透明な項目を運ぶ。
  - デスクトップは `LwjglLayer` が `Render3d.renderer(...)`（今の Render3d の呼び出しを詰めた物）を渡す。ブラウザは `Scene3dRenderer.none()`（何も描かない）を渡す。2D のゲームは Scene3d を使わないので困らない。
  - 2D 専用・3D 専用・共通の分け方と名前: **共通** = `GlContext`・`RenderFrame`（2D と 3D の z の合流）・`RenderTargetGl`・`RenderShader`（program を作る所）・`RenderBuf`・`Scene3dRenderer`（3D を渡す口の型）／**2D** = `RenderPaint`・`RenderSprite`・`RenderStatic`・`RenderTexture`（上げる所）・`RenderGlyphGrow`（上げる所）／**3D** = `Render3d`（LWJGL を直に呼ぶまま・後のフェーズ「3D」で `GlContext` へ）。
  - 確かめ方: デスクトップは下の GL のキャプチャのバイト一致（`bench/scene3d`・gl_parity の 3D の場面・fps3d_lab も撮る）。ブラウザは `Scene3dRenderer.none()` の入口を TeaVM にかけて Render3d の ERROR が 0 件。
  - 見積もり 1 週【推】（Paint の 4 か所・Frame の 5 か所と型・LwjglLayer の渡し方・3D のキャプチャ）。
- **Render3d の中の GL を層へ移すのはこのフェーズから外す**（254 か所・ゴールの外・`bench/scene3d`・fps3d_lab の 3D を壊す危険に得が無い）。後のフェーズ「3D」で同じ層へ移す。
- ウィンドウ・入力・音・画像のデコード・字の生成（GLFW・SDL・OpenAL・stb）は `GlContext` に入れない。`LwjglLayer`（デスクトップの handler）のまま。

### 順番と、デスクトップの絵が変わらないことの確かめ方

1. **GL のキャプチャの控えを取る（1〜2 日）**: 撮る口は既にある。`FLIX_GE_FRAME_SHOT=<フォルダ>`（swap の直前の絵を `frame-N.png` へ・`LwjglLayer.flix:214-229`）・`FLIX_GE_HIDDEN`（隠しウィンドウで framebuffer を design の大きさに固定・364 行）・`START="<場面> k=v…"`（`App.bootWorld` が Starts の場面から始める）を組み合わせて、4 本のテンプレの主な場面（rpg の field・battle・menu、ノベルの talk・title・menu、game-starter、tidepool）を撮る小さなスクリプトを書くだけでよい。gl_parity の全場面も撮る。3D の控えは、templates に 3D の物が無いので `bench/scene3d`・gl_parity の 3D の場面・fps3d_lab（リポジトリの外・読むだけで撮る）で取る。**書き換えの前に**撮って控える。
   - **バイト一致が成り立つ条件**: `getDeltaTime` は実時間（`LwjglLayer.flix:881-887`）なので、動く場面は撮るたびに 2 コマ目以降が変わる。→ **最初は各場面の 1 コマ目だけを比べる**（START で組んだ World を描いた絵。ループは dt で World を進めてから描くので、今の口では「dt を使う前の絵」は撮れない見込み【推】。1 コマ目の dt は起動からの時間が `maxDeltaTime` で切られた値になりやすく、そうなれば撮るたびに同じになる【推・控えを 2 回撮って比べる】）。数コマ進めて比べたい時のために、**dt を固定する環境変数（例 `FLIX_GE_FIXED_DT=0.016`）を LwjglLayer に足す**のはエンジン拡張なので相談する（人に決めてほしい事 14）。
2. **(a) 機械的な置き換えを一度に**: 2D の道の GL の呼び出しを、中身を変えずに全部 `GlContext.lwjgl()` 経由にする（`GL11.glX(...)` → `gl#x(...)` の置き換えだけ）。ここで GL の呼び出しの並びを記録する版（`GlContext.recording(inner)`・関数と引数を 1 行ずつ）で、上の場面の並びを録って**基準**にする。PNG のバイト一致も確かめる。
3. **(b) 形を直す段階**（バッファの確保・意図の名前の関数・生成と上げるの分離）: 1 つずつ直し、そのたびに **PNG のバイト一致を主**、並びの比較を従にして確かめる（並びは int の引数だけなので、`bufferData` の中身の違いは拾えない。PNG で拾う）。
4. **gl_parity の A 段階が 0 px のまま**（今の物差し）。A 段階に字は入っていない（backend-parity.md で字は「近似」）ので、字は 1. の場面のキャプチャで見る。
5. **速さ**: 隠しウィンドウで rpg の battle の場面を N 回（例 5 回 × 600 コマ）流し、FrameStats の描く所の中央値を、書き換え前と後で背中合わせに比べる（同じマシンで別の作業が走ると ±30% ぶれるので、1 回の値で決めない）。
6. **pub を使う側**: render_gl の pub mod（`GlOffscreen`・`RenderTexture`・`LwjglLayer`）の形が変わると、テンプレ・外のゲーム・flix_ge_studio に響く。`make studio-parity` は AGENTS の写しの突き合わせ（`Makefile:598-605`）で pub の変化は見ないので、確かめ方は **4 本のテンプレの `make test` と、外のゲーム（docs/performance.md の 11 本）と Studio の `flix check`**。pub の形は変えない方針で進め、変えざるを得ない所は相談する。
7. 最後に人が `make run` で 4 本を触る。
- 注意: templates の `reference/SHA256SUMS.txt` は SoftRaster（engine_tools）の絵なので、このフェーズの証拠にはならない。

### 到達点と決め所

- 到達点: 本体（上の一覧）が `org.lwjgl.*` も `java.awt` も import しない。`Scene3dRenderer.none()` を渡す 2D の入口を TeaVM にかけて、render_gl から来る ERROR が 0 件。1〜6 が一致。
- 決め所: 5 の中央値が 5% 以上増えたら、0b のマイクロベンチで 2 番目だった形へ替える。

### 見積もり・危険

- 見積もり 3〜4.5 週【推】（キャプチャの控え 0.25〜0.5・機械的な置き換え 0.5・バッファと意図の関数と分離（FontCache 含む） 1〜1.5・3D の切り出し（`Scene3dRenderer`） 1・確かめと虫取り 0.5〜1）。
- 危険: LWJGL の便利な形（`glUniform1fv(int, FloatBuffer)` 等）を WebGL2 にもある形へそろえる手間。Flix の型推論が長い関数で崩れる既知の癖（関数を短く保つ）。

---

## フェーズ 2 — 開発の道具を、ゲームの起動の道から外す（エンジン拡張・要相談）

### やる事

- 本物の `App.launch` を TeaVM に通すと出る ERROR 9 件は、全部開発の道具から来ている【確（game-starter・stub の handler・`App.launch`）】: `App.RemoteDebug`（InetSocketAddress・LinkedBlockingQueue）・`App.GameRegistry`（ProcessHandle）・`Flow.Record`（File.toPath）・`App.HitchDetector`（ManagementFactory・File.toPath）・`ProcessEnv.snapshot`（System.getenv）。テンプレの本当の入口 `App.loadAndLaunch` は加えて `Flow.Record.captureReads` を呼ぶ（スパイクの fpkg が古くてこの道は TeaVM を通していない）。
- これらを、App が「無ければ何もしない」形で受け取る 1 つの値 **`App.DevTools`** にまとめる（Bevy の `bevy_dev_tools` と同じ考え）。中身: リモートデバッグ・ゲームの名簿・flow の記録・ヒッチの見張り・Doc の監視・環境変数の表。
- **pub の形は変えない**: engine と engine_world の pub は外のゲーム 11 本が呼ぶ（docs/performance.md）。`App.launch(app)` と `App.loadAndLaunch(...)` は今の形のまま、中で `App.DevTools.desktop(env)` を作って渡す。ブラウザ用に **別の入口** `App.launchWithDevTools(devTools, app)`（名前は案）を足し、WebMain は `App.DevTools.none()` を渡す。ブラウザの入口から本物の道具のコードへ届く呼び出しが無くなれば、TeaVM はそれを読まない。
- ループの状態（`LoopState`）に道具の状態が平らに入っているので、道具の状態は `DevTools` の 1 つの欄にまとめる（二重にしない）。
- テンプレ 4 本: `Game.app` の中の `App.onRenderRequest(SceneRender.allShots)`・`App.onShotRequest(...)` を Main（デスクトップの入口）へ移す。`Game.app` はテスト・flow・デスクトップ・ブラウザが共有するので、engine_tools へつながる物を持たない。手順は `/add-template`。

### デスクトップが変わらないことの確かめ方

- 4 本のテンプレの `make test`（e2e の flow の再生を含む）と engine_world のテスト（`.layers` の中で）が緑。ただし `make test` と flow は `App.Headless` を通り、`launch` と `loop` の変更はほとんど通らない。→ **smoke を 1 本足す**: 隠しウィンドウで DEBUG の起動をし、RemoteDebug のポートが開いて `/step` が答える・flow の記録のファイルができる・GameRegistry に載る、を確かめて閉じる。
- 人が `make run` で F8・Doc の保存即反映を 1 回ずつ触る。pub を使う側（4 本のテンプレの `make test`・外のゲーム 11 本と Studio の `flix check`）で、今の `App.launch` / `loadAndLaunch` の形が残っていることを確かめる。
- **名前の衝突**: 今の App には非 pub の `App.launchWith`（`engine_world/src/App.flix:1078`・launch の本体）がある。新しい pub の入口を同じ名前にしない（`launchWithDevTools` とする）。中の非 pub の名前も紛らわしいので、`refactor usages App.launchWith` で呼び手（App の中だけ）を洗い出してから `launchBooted` などへ改名する（中だけなので外のゲームに響かない）。

### 到達点・見積もり・危険

- 到達点: **rpg とノベルの本物の `web/WebMain.flix` を TeaVM にかけて ERROR 0 件**。このとき WebLayer は、engine_web の芽として `engine_full_web` の木に先に置く stub（全操作が何もしない handler）で組む（フェーズ 3 でそのまま中身を足す）。
- 相談: App に入口を足すので、実施前に人と相談する（AGENTS.md）。代わりの「shim で穴を埋めて呼ばれないことを祈る」は、届かない保証が無いので推さない。
- `engine_full_web` の make の入口を作る（`make sync-engine-full` の symlink の集め方を写し、web のファイルを足して fpkg を作る・1〜2 日）。中身は engine_full と同じソースに engine_web（`WebLayer` `WebFs` `GlContext.webGl2`）を足した物。LwjglLayer・GlOffscreen・Render3d は木に残ってもブラウザの入口から届かないので TeaVM は読まない（届かないことはフェーズ 1・2 の到達点の TeaVM の ERROR 0 件で確かめる）。LWJGL の mvn の依存は `engine_full_web` にも要る（Flix は届くかどうかに関係なく木の全部を型検査するので、LwjglLayer などを組む時に LWJGL の jar が要る。配る wasm には入らない）。
- 見積もり 1.5〜2 週（相談・smoke・`engine_full_web` の入口込み）【推】。危険: App は 2,400 行。分け方を誤ると LoopState が二重になる。

---

## フェーズ 3 — ブラウザの handler 一式とエクスポートツール（最初の到達点: rpg-starter）

### 最初の到達点を rpg-starter にする理由

- ゴールそのもの（game-starter はゴールに入っていない）。1 コマの速さと TeaVM の通りは確かめ済み【確（World と View）】。
- 使う物の幅が広い: ドット絵のアトラス（ARGB の上げ）・タイル・多角形・フォントアトラス（10px の PixelMplus）・音（効果音と BGM の wav・ループ）・セーブ・キー入力。ノベルが追加で要るのは写真（jpg）・大きな日本語のフォントアトラス・マウス・全画面・時刻で、フェーズ 4 に回せる。
- game-starter は handler を立ち上げる最初の数日の確かめにだけ使う。

### 頭の決め所（最初の 3〜4 日）

- `GlContext.webGl2()` と `WebLayer` の最小（描く・rAF を待つ）で、**本物の `App.launch` を rpg の battle で回し、1 コマの CPU（rAF の中で wasm が使った時間）を測る**。描き手（RenderPaint の z の並べ替えと詰め替え）とコルーチン変換の代金がここで初めて入る。
- 閾値は「速さの閾値（スマホから逆算する）」の節: **PC で 3ms 以下なら進む**。3〜6ms なら速さの手当て（docs/performance.md の流儀）をフェーズ 5 の前に入れるか、スマホで 30fps を許すかを人が決める（人に決めてほしい事 13）。16ms を超えたら止めて、別の道（下）を同じ Bench で測る。

### やる事（engine_web）

**`engine_web`**（パッケージではなく、推し 5 の `engine_full_web` の束に足すファイル群。デスクトップの engine_full には入らない）。

| モジュール | 中身 | 確かめた事 |
|---|---|---|
| `fge.web`（Java・jar） | JSO を閉じ込める薄い facade。`Gl2`（WebGL2 の関数を int のハンドルで・JS の物は中の表。`getUniformLocation` も JS の物を返すので、program ごとの表で int へ付け替える）・`AnimationFrame`（`@Async` で rAF を待つ）・`Keys`（キーの表と「1 回読まれるまで残す」フラグ）・`WebAudio`・`LocalStorage`・`AssetTable`（起動前に fetch した表） | rAF 待ち・キーの表・localStorage・WebGL2 の三角形【確】 |
| `GlContext.webGl2()`（Flix） | `fge.web.Gl2` を詰めた `GlContext`。`shaderSource` は `#version 330 core` 行を `#version 300 es`＋`precision highp float; int; sampler2D;` に替える。意図の名前の関数（上の表）の WebGL2 版 | `#version` の差し替えでコンパイルが通る【確】 |
| `WebLayer`（Flix） | `GameEngine.Game`・`Audio`・`ShaderEffect.Shader`・`RenderTarget.Target`・`LoadProgress` の handler。`LwjglLayer` と同じ役 | ループの形【確（小さなループ）】 |
| `WebFs`（Flix） | `Fs.FileRead`（`AssetTable` から・`saves/` は localStorage から）・`Fs.FileWrite`（`saves/` だけ localStorage へ・ほかは何もせず Ok） | 表から読む・localStorage の同期の読み書き【確】 |
| TeaVM の穴の shim | `TReentrantLock` `TCondition` `TCyclicBarrier` `TConcurrentLinkedQueue`・`VirtualThreadFix`（startVirtualThread の付け替え先）・`CopyOfRangeFix` | 0 件になった【確】 |

`WebLayer` の中身（LwjglLayer 1,127 行の役を 1 つずつ）:

- **WebGL2 のコンテキストの属性**: `{alpha: false, antialias: false, stencil: true, depth: true, premultipliedAlpha: false, preserveDrawingBuffer: false}`。既定のままだと、alpha の欄のブレンド（`glBlendFunc` は alpha にも掛かる）でページの背景が透け、MSAA でドット絵がにじみ、ステンシルが無くて多角形マスクが効かない（デスクトップは 8bit のステンシルを取っている）。キャプチャ（gl_parity の web 版）は rAF を返す前の同じ処理の中で `readPixels` する。
- **canvas の解像度**: backing store を「CSS の大きさ × devicePixelRatio」にし、RenderPaint にはデスクトップの framebuffer の大きさと同じ扱いで渡す（デスクトップは framebuffer の解像度でレターボックスを付けて描く）。design の解像度で描いて CSS で引き延ばすと、ノベルの SDF の字が Retina やスマホで 2〜3 倍ににじむ。ドット絵の拡大の決め方（整数倍）はデスクトップと同じ式を使う。ウィンドウの大きさが変わったら ResizeObserver で backing store を作り直す。
- **時間**: `getDeltaTime` は rAF の時刻の差（`maxDeltaTime` で切る）。60Hz に間引く設定（人に決めてほしい事 6）。
- **キーボード**: `keydown/keyup` の `code` を `GameEngine.Key` へ。矢印・スペース・Tab の `preventDefault`（ページがスクロールする）。`blur` と `visibilitychange` でキーの表を空にする（押したままのキーが残る）。押したフラグは 1 回読まれるまで残す【確】。
- **マウス**: `getMousePosition`・`isMouseButtonPressed`・`consumeScrollDelta` を pointer と wheel から。canvas の位置とレターボックスを引いて design の座標へ。カーソルの形と表示（`setCursor` `setCursorVisible`）は CSS の `cursor`。
- **パッド**: Gamepad API を `GamepadMap` の表でキーへ（デスクトップの SdlPad と同じ表）。`isGamepadTouched` `gamepadKind`。
- **音**（`GameEngine.Audio` の各操作）: `playAudio` = 頭から鳴らし直し（AudioBufferSourceNode は使い捨てなので毎回作る）・`stopAudio`・`setVolume`（名前ごとの GainNode）・`setPitch`（playbackRate）・`setLooping`（鳴っている途中にも `loop` を切り替え）・`setMasterVolume`（master の GainNode）・`setLowpass(gainHF)`（OpenAL EFX の高い音の減り方を BiquadFilter へ。対応の式（例: 5kHz の highshelf を `20·log10(gainHF)` dB）を決めて、デスクトップと耳で比べる）・`audioSeconds`（buffer の長さ）・`reloadAudio`（開発の道具なので何もしない）。wav のループ点は engine の `AudioUtil.loopPointsOf`（純粋な Flix）で読んで loopStart/loopEnd へ【推】。タブが裏に回ったら `AudioContext.suspend`・戻ったら `resume`（ループは止まるのに BGM だけ進むのを防ぐ）。
- **終了**: rpg とノベルは `quitWhen` / `withCloseRequest` を持つ。ブラウザでループを抜けると絵が固まって残るので、抜けたら「おわり」の画面（もう一度遊ぶボタン＝頁の読み直し）を HTML で出す。タイトルの「やめる」を隠すかはゲームの判断（WebMain の組み立てで）。
- **全画面**: `setFullscreen` は `requestFullscreen` を呼ぶが、ユーザーの操作の中でしか通らない（rAF の中からだと Safari は失敗する）。handler は要求を覚えておき、次の pointer / key のイベントの中で行う。`isFullscreen` は `document.fullscreenElement`。Esc でブラウザが抜けた時に World と食い違って毎コマ入り直そうとしないよう、「要求したが断られた」状態を覚える。
- **起動の流れ**（PC でも要る）: HTML が Doc の束と絵・音を fetch（進み具合のバー）→「クリック / タップして始める」（Chrome も自動再生を止めるので PC でも要る）→ その場で AudioContext をアンロックし、全部の音をデコードし終える（アンロック直後の 1 回目はデコード前で落ちた【確】）→ wasm の main。`LoadProgress.report` の handler は rAF に返す（Doc の読み込みの間にタブが固まらない。スパイクで最大 459ms）。wasm の中で例外が出たら、黒い画面のままにせずエラーを HTML で出す。
- **画像**: `createImageBitmap(blob, {premultiplyAlpha: 'none', colorSpaceConversion: 'none'})` と `UNPACK_COLORSPACE_CONVERSION_WEBGL = NONE`（stb で読んだ色と同じにする）。JPEG はデコーダが違うのでバイト一致は保証できない（backend-parity.md に「近似」と書く）。
- **ProjectLoader**: project.json を `AssetTable` から読む（`LwjglLayer.withProject` と同じ手順で `EngineConfig` を作る）。

### フォントアトラス（事前生成）

- デスクトップは起動時に stb で TTF から距離場のフォントアトラスを生成する（`RenderFont`・`RenderFontCache`・`RenderGlyphGrow`）。ブラウザに stb は無い。
- **エクスポートツールが JVM でデスクトップの生成を回し、`RenderFontCache` の今の形式（magic＋記録）のまま同梱する**。ブラウザ側はその形式を読む。ただし今の読み手は純粋ではない（`RandomAccessFile`・`FileChannel`・`org.lwjgl.BufferUtils`・`CRC32.update(ByteBuffer)`・`File.exists`・`MessageDigest`・`FontCache.flix:9-22,79,96-128`）。フェーズ 1 で「byte 列から読む所」を分けておき（上の本体の一覧）、ブラウザはアセットバンドルの byte 列を渡す（1〜2 日・フェーズ 3 の見積もりに入れた）。
- 集める字: ノベルは project.json の `glyphs: used` と同じ集め方。**rpg は `glyphs: auto`（出た字から順に生成）なので、エクスポートの時は `used` か `all` を強制する**（PixelMplus は小さいので `all` でもよい【推】）。
- 実行中にフォントアトラスに無い字が出ると、`App.renderFrame` は毎コマ `missingGlyphs` を引き直す（欠けがある間は指紋を覚えない）。handler は「1 回だけ知らせる」が、引き直しの代金は残る → エクスポートで漏れが無いことを確かめる（シナリオと Doc の字を数えて、フォントアトラスにあるか見る）。
- **漏れはエクスポートを止める門にする**（2026-11-04 人の話: 他のエンジンのブラウザ版は「字が足りない・うまく動かない」が多い。ここで勝てる）。台詞（yarn）・Doc の文字列・コードの文字列の字を全部集め、アトラスに無い字が 1 つでもあれば字と出所（ファイル:行）を出して止める。人が打つ字（名前の入力など）のように前もって集められない物は、エクスポートで「この入力欄は字の集合の外」と知らせる。
- 生成を JVM で回すには render_gl に新しい入口（`bakeFontCpu` を呼ぶ main）が要る。エンジン拡張なので相談。

### エクスポートツール（`bin/fge export-web`・Go）

① 【推】`flix build-fatjar --entrypoint WebMain.main`（ゲームを一時のフォルダへ写し、`web/WebMain.flix` を src へ入れ、lib に `engine_full_web` を置いて組む。ゲームのフォルダは汚さない）②jar のバイトコードの付け替え（startVirtualThread・copyOfRange）③TeaVM 0.14.1（WASM GC・shim を classpath に。TeaVM と ASM の jar は版を固定してリリースか lib に置く）④アセットバンドル（project.json が名指す絵・音・字＋assets の Doc）⑤フォントアトラスの事前生成 ⑥`index.html`・TeaVM の runtime js・起動の js を `build/web/` へ。Windows でも動くこと（Go と java だけで回す）。①〜③は手でやった【確】・④〜⑥は【推】。

### セーブ

- localStorage の鍵の頭にゲームの id を付ける（`<package 名>/saves/rune.json`）。itch.io などは全部のゲームが同じ origin なので、付けないと別のゲームと衝突する。
- iOS Safari は 7 日触らないとスクリプトが書いたストレージを消す【推】。`navigator.storage.persist()` を頼み、タイトルに「ブラウザのセーブは消えることがある」と出すかは人の判断（下）。

### 検査（gl_parity を同じ物差しで）

- **gl_parity の web 版**: A 段階の 2D の場面を `GlContext.webGl2()` でヘッドレスの Chromium に描かせて `readPixels` し、SoftRaster の PNG と比べる。リポジトリに Node の道具は無いので、Go の bin/fge から Chrome の `--headless` を CDP で動かす（Playwright は入れない）【推】。CDP の口を Go で一から書くので、0.5〜1 週には収まりにくい（1〜1.5 週と見る）。同じ GPU・ANGLE なので A 段階は 0 px の見込み【推】。backend-parity.md に WebGL2 の列を足す。
- A 段階に字は無いので、**字の場面で LWJGL 版の GL のキャプチャと WebGL2 版を直に比べる**口も足す（swizzle の代わりの ALPHA 形式が正しいかはここで拾う）。

### 到達点と見積もり・危険

- 到達点: `build/web/` を静的サーバーで配り、PC の Chrome・Firefox・Safari で rpg-starter をタイトルから最後まで遊べる。音が鳴り、セーブして閉じて開き直すと「つづきから」が選べる。
- 見積もり 5.5〜7.5 週【推】: 頭の決め所 0.5・fge.web と GlContext.webGl2 1・WebLayer（入力・canvas・パッド・全画面・終了）1・WebAudio（対応表込み）0.5〜1・WebFs とアセットバンドル 0.5・フォントアトラスの事前生成とブラウザ用の読み手 0.5〜0.75・エクスポートツール（WebMain の型検査の門を含む） 0.5〜1・gl_parity の web 版（CDP） 1〜1.5・rpg を最後まで通す虫取り 0.5〜1。
- 危険: TeaVM の別の不具合（copyOfRange と同じ類）。JSO の値を Flix 側へ漏らすと wasm が落ちる（スパイク 2）→ `fge.web` の外へ JS の型を出さない決まりを `bin/lint-rules/forbid.json` で止める。

---

## フェーズ 4 — sound-novel-starter を PC のブラウザで

- 写真（jpg・5 枚・736KB）を起動前にデコードしてテクスチャへ。背景の宣言シェーダー（blur）は 25 本ともコンパイルが通った【確（コンパイルまで）】。
- 日本語のフォントアトラス: `ShipporiMincho-Regular.subset.ttf`（1.7MB）から、シナリオ（.yarn）と Doc に出る字だけ。4096² に収まるかをエクスポートツールで表示し、溢れたら複数枚（今の `RenderFont` が複数枚を持てるかは【不明】）。
- マウスとクリック（フェーズ 3 の WebLayer）。全画面（`App.withFullscreen` を使う）。
- 時刻: `Main.flix` の `localEpochSeconds` は `TimeZone.getDefault()` を使う（TeaVM で確かめていない）。WebMain では JS の `Date#getTimezoneOffset` から作る。
- 音: wav 11 本（7.4MB）。最初は wav のまま。
- セーブの枠と設定も localStorage。
- 確かめ方: PC の 3 つのブラウザで、タイトル → 会話を最後まで → セーブ → 開き直して続きから。デスクトップは engine_web と WebMain しか触らないので変わらない（テンプレの `make test` が緑・`git diff` が engine_web と web/ だけ）。
- 見積もり 1〜1.5 週【推】。

---

## フェーズ 5 — スマホのブラウザで遊べる（ゴール）

### 入力の 2 つの道

| 道 | 中身 | エンジン | 向くテンプレ |
|---|---|---|---|
| **A. バーチャルパッド（推す）** | 十字キーと A/B（とメニュー）を HTML のオーバーレイで出し、押したら `fge.web.Keys` の表に書く。ゲームからは普通のキーに見える | **無改修**（handler と頁だけ）。届くことを確かめた【確（内蔵ブラウザの mobile 表示）】 | rpg-starter（キーで遊ぶ物全部） |
| A'. タップ = マウス | 指で触ったら、その位置の左クリックとして渡す（pointer のイベントはマウスと指を同じに扱う） | **無改修** | sound-novel-starter（タップで送る・選択肢を押す） |
| B. タッチを直に扱う入力 | エンジンに「触った点の並び」を足す（`App.Frame#touches`・2D/3D 共通・Godot の `InputEventScreenTouch`・Bevy の `Touches` にそろえる） | **エンジン拡張** | タッチ専用に作るゲーム。**ゴールの外** |

- バーチャルパッドの決まり（スパイクで分かった事）: **押したフラグは 1 回読まれるまで残す**（1 コマより短いタップを落とさない）【確】。指を滑らせて隣のボタンへ移れるよう `setPointerCapture` しない。
- 配置は project.json の新しい欄（例 `"virtualPad": { "layout": "dpad+ab", "keys": { "a": "Z", "b": "X" } }`・ゲームの keys の Doc の名前を使う）【推】。出す・出さないは `pointer: coarse` で自動に。

### 画面の向きと拡大

- rpg（256×240・ほぼ正方形）は縦持ちで上に画面・下にバーチャルパッド。ノベル（960×540・16:9）は横持ち推奨。縦のときは「横にしてください」を出すか、レターボックスを付けてそのまま遊ばせる（iOS Safari は画面の向きを固定できない【推】）。
- セーフエリア: `viewport-fit=cover` と `env(safe-area-inset-*)`（スパイクの頁に入れた）。

### iOS Safari の癖【推・フェーズ 0b と実機で確かめる】

- WASM GC が要る版（0b で確かめる）。
- 全画面: iPhone の Safari は Fullscreen API が使えない【推】。「ホーム画面に追加」（web app manifest の `display: fullscreen` / `standalone`）で近づける。
- 長押しのメニュー・字の選択・ダブルタップの拡大・2 本指の拡大: `-webkit-touch-callout: none`・`user-select: none`・`touch-action: none`・`gesturestart` の既定を止める（iOS は `user-scalable=no` を無視するので、ジェスチャーのイベントで止める）。
- タブのメモリの上限: wasm 3〜6MB＋素材 10MB 前後で、上限から遠い【推】。
- 音: 最初のタップでアンロック（iOS は `touchend` の方が確実と言われる【推】）。消音スイッチで WebAudio が鳴らない端末がある【推】→ Safari 17 以降の `navigator.audioSession.type = "playback"` で鳴るようにする【推・0b ①で確かめる】。
- 低電力モードでは rAF が 30Hz に落ちる【推】。dt で遊びの速さは保たれるが、0b ①で確かめる。
- iPhone の Chrome / Firefox も中は WebKit なので、iOS の癖は Safari と同じ【推】。
- フォントアトラスの大きさ: デスクトップは 4096 か 8192 の正方形（`Font.flix:8`）。安い Android は `MAX_TEXTURE_SIZE` が 4096 の物がある【推】ので、エクスポートツールはブラウザ向けに 4096 を上限にして、溢れたら複数枚に分ける（フェーズ 4 の【不明】と同じ所）。
- 全画面（iPad・Android）: Esc やジェスチャーでブラウザが全画面を抜けた時の扱いはフェーズ 3 の「全画面」と同じ（断られた状態を覚える）。
- ストレージ: 7 日で消える（フェーズ 3 のセーブ）。

### コンテキストロスト（スマホで裏に回すと起きうる）

- タイル層の VAO のハンドルは App の `LoopState#tileCache` が持ち、静的な層・フォントアトラス・sprite のアトラスも「鍵が同じ間は上げ直さない」作り。コンテキストが戻っても App は上げ直しを頼まないので、**handler だけでは直せない**。
- 案 1: `fge.web.Gl2` の int のハンドルを「仮のハンドル」として扱い、**作った時と状態を決めた時の呼び出し**（テクスチャの画素とパラメータ・バッファの中身・program のソースとリンク・uniform の location の付け替え・VAO の attrib の設定・sampler object）を控えておき、コンテキストが戻ったら同じ int に向けて流し直す。2D のゴールの 2 本は控えが数十 MB 以下【推】。
- 案 2（先にやる）: 「タップで再開」を出して頁を読み直し、セーブから続ける（セーブしていない進みは消える）。実装が軽いので、ゴールではまずこれを入れ、実機でコンテキストロストがどれだけ起きるかを見てから案 1 を判断する。案 1 は控えて流し直す物が多く 1〜1.5 週と見る（ゴールの見積もりの外）。
- 人に決めてほしい事 8。

### スマホの速さと浮動小数のレンダーターゲット

- PC（この Mac）の WASM GC で、World と View までが rpg の戦い約 1.2ms・ノベルの会話約 0.6ms（スパイク 1 の値を描き直しの回数で割った物）【確＋推】。描き手とコルーチン変換の分は未測定（フェーズ 3 の頭で測る）。スマホは PC の 3〜6 倍遅いと見る【推】。
- ゴールの 2 本は HDR の Pass（`RGBA16F`）を使っていない（`withHdr`・`PostProcess` は 2 本のソースに無い【確・grep】）。後のフェーズで使うときは、`EXT_color_buffer_float` が無ければ 8bit に落として 1 回知らせる。

### 到達点・見積もり

- 到達点（ゴール）: iPhone（Safari）と Android（Chrome）で、rpg-starter をバーチャルパッドで、sound-novel-starter をタップで最後まで遊べる。音が鳴り、セーブが残る。
- 見積もり 2.5〜3.5 週【推】（オーバーレイと拡大 0.5・iOS の癖 0.5〜1・コンテキストロストの案 2 0.25〜0.5・実機の速さと 2 本を通す 0.5〜1・低電力モード・audioSession・フォントアトラスの分割 0.5）。実機（iPhone・Android）を人が用意できることが前提。

---

## 後のフェーズ（ゴールの外・名前だけ）

- **タッチ入力の拡張**（道 B）。
- **3D**: Render3d を `GlContext` へ（`glGetTexImage` → FBO の `readPixels`・`glDrawBuffer` → `drawBuffers`・BGRA の上げ 2 か所）・数百 MB の素材（KTX2 / Basis・glb の圧縮・後から読む）・lightmap。
- **WebGPU**: TeaVM 0.16 の `org.teavm.jso.webgpu`【確・未使用】。ShaderGen に中間の形を挟んで GLSL と WGSL を出す。WebGPU は GL の形ではないので `GlContext` の隣に別の層が要る。
- **TeaVM を上げる**: 0.16 は CLI の jar が無く、tooling の API で回すと JDK の本物のクラスが流れ込んだ【確】。上げるときは JDK を見せない ClassLoader の runner と shim を作り直す。copyOfRange が直ったかもその時に。
- **Studio に「Web にエクスポート」**。

## 別の道（止めて乗り換える時の基準）

| 起きた事 | 乗り換え先 |
|---|---|
| TeaVM の不具合が重なり、付け替えで追いつかない／フェーズ 3 の頭で 16ms を超える | GraalVM Web Image（試していない）か CheerpJ（LWJGL 3 の対応は 2026-12 予定・商用の条件）を、スパイク 1 と同じ Bench（`src/Bench.flix`）で測って比べる |
| iOS の WASM GC が使えない端末が多い（0b） | TeaVM の JS 出力（同じ jar・同じ handler） |
| Flix が公式に WASM を出し始める | `engine_web` の JS 側（fge.web の中身・頁・アセットバンドル）は使い回し、Flix 側は Java の interop を外す必要がある（フェーズ 2 の DevTools はそのまま役に立つ） |

## まだ推測の所と、確かめる次のスパイク

| 推測 | 次のスパイク（目安） |
|---|---|
| iOS Safari / Android Chrome で WASM GC・WebAudio・タップが動く版・スマホの速さ | フェーズ 0b ①（30 分・人の端末） |
| `GlContext` の形の代金 | フェーズ 0b ②（半日） |
| 描き手とコルーチン変換込みの 1 コマの CPU | フェーズ 3 の頭（3〜4 日・`GlContext.webGl2()` と WebLayer の最小） |
| WebGL2 の `ALPHA` 形式で SDF の字が出る | フェーズ 0b ③（半日・`site-gl` の頁に足す）。本物の字の場面の比べはフェーズ 3 の gl_parity の web 版 |
| 実ゲームの GL の描画が WebGL2 で同じ絵になる（今は三角形と GLSL のコンパイルだけ） | 同上＋gl_parity の web 版 |
| `RenderFontCache` の形式をブラウザで読める | 今の読み手はファイルと LWJGL を使う（純粋ではない）。フェーズ 1 で byte 列から読む所を分けた後、その所だけを小さな jar にして TeaVM にかける（半日） |
| `TimeZone.getDefault()` の TeaVM での振る舞い | WebMain で使わない形にするので、確かめずに避ける |
| ノベルのフォントアトラスが 1 枚に収まるか | フェーズ 4 の中でエクスポートツールが表示 |
| TeaVM 0.16 で copyOfRange が直ったか | 後のフェーズ（急がない） |
| `Scene3dRenderer` で切り出した後、2D の入口から Render3d に届かない | フェーズ 1 の到達点（2D の入口を TeaVM にかけて render_gl から来る ERROR 0 件） |
| 1 コマ目の GL のキャプチャが撮るたびに同じになる（1 コマ目の dt が `maxDeltaTime` で切られるか） | フェーズ 1 の 1.（控えを 2 回撮って比べる・半日） |

## 人に決めてほしい事（推しつき）

**2026-11-03 決定: 下の 14 項目は人がすべて推しのとおりに決めた。**

1. **最初の到達点を rpg-starter にする**（game-starter ではなく）。推す: ゴールそのもので、World と View の速さは確かめ済み。
2. **TeaVM 0.14.1 で始め、0.16 以降へは WebGPU のフェーズで上げる。TeaVM と ASM の jar は版を固定してリリースか lib に置く**。推す: 0.14.1 は穴が 4 つで全部手当て済み。
3. **`App.DevTools` を足す。pub の `App.launch` / `loadAndLaunch` の形は残し、ブラウザ用の入口を別に足す**（フェーズ 2・エンジン拡張）。推す: 外のゲーム 11 本を壊さず、ブラウザの入口から開発の道具へ届かなくする一番素直な形。
4. **`GlContext` は値の層にする（record か Java の interface のうち、0b のマイクロベンチで速い方）**。 **→ 決定（2026-11-04・0b ②の結果）: Java の非ジェネリックな interface、実装も Java で書く。gl の値は描く手順の関数の引数で渡す（案 a）。** record は欄を名前で 1 つずつ比べて引く作りで、欄 3 つで 3.3 倍（WASM 5.4 倍）・64 欄で最悪 115 倍だったので外した。数字は engine-browser-spikes.md の末尾。推す理由: フェーズ 1 の確かめ方（`GlContext.recording(inner)` で包んで並びを録る）は値の層が前提で、ブラウザ版も同じ値を `GlContext.webGl2()` で作るだけで済む。「ビルドの時に同じ名前のモジュールを差し替える形」は走る時の代金が 0 だが、録る版が作れず、engine_full と `engine_full_web` で別のファイルを組む手間も増えるので推さない（マイクロベンチで値の層が重すぎた時だけ考え直す）。
5. **engine_web の組み方**。描く手順の本体（`RenderPaint` `RenderSprite` `RenderShader` `RenderBuf` `Frame` は pub でない mod・`render_gl/src/Paint.flix:10`）は、テンプレが `mount = "fge"` で見る fpkg の外から呼べない。だから単純な「別のパッケージ」では本体を 1 本に保てない。推す: **(a) engine_full と同じソースの木（`make sync-engine-full` の symlink の集め方）に web のファイル（engine_web と `GlContext.webGl2`）を足した 2 本目の束 `engine_full_web` を make で作る**。デスクトップの engine_full・`flix check`・依存は 1 バイトも変わらず、エクスポートツールだけが `engine_full_web` で組む。本体は pub にしなくてよい。代わりの (b)「本体を pub にして別パッケージから呼ぶ」は pub が増える（外のゲーム 11 本から見える API になる・エンジン拡張の相談が要る）ので推さない。WebMain は `src` の外（`web/WebMain.flix`）に置き、エクスポートツールだけが組む。src の外なのでゲームの `make check` / `make test` の型検査から外れる → **エクスポートツールの「型検査だけ」の口（`bin/fge export-web --check`）をテンプレの `make test` とコミット時のフックに足す**。fge.web（Java のソース・リポジトリに Java が入るのは初めて）の版の管理が 1 つ増える。
6. **高いリフレッシュの画面で 60Hz に間引く**。推す: 既定 60・project.json で変えられる。遊びの速さは dt で同じだが、電池に響く。
7. **音は最初 wav のまま配る**。推す: 変換の道具を増やさない。rpg 4.8MB・ノベル 7.4MB は配れる大きさ。
8. **コンテキストロストの扱い**: 推す: まず案 2（頁を読み直してセーブから・軽い）を入れ、実機で起きる回数を見てから案 1（`fge.web` が作った時と状態を決めた時の呼び出しを控えて流し直す・1〜1.5 週）を判断する。
9. **フォントアトラスの字の swizzle の代わり**: 推す: WebGL2 版だけ `ALPHA` 形式で上げ、シェーダーとデスクトップは変えない。代わりの案「デスクトップも swizzle をやめてシェーダーで `.r` を読む」は、理屈の上では画素が同じだが、デスクトップのシェーダーの字が変わる（キャプチャで確かめる手間が増える）。
10. **終了の扱い**: 推す: ループを抜けたら HTML で「おわり（もう一度遊ぶ）」を出す。「やめる」をタイトルから隠すかはゲームごと。
11. **ブラウザのセーブが消えうることの知らせ**: 推す: `navigator.storage.persist()` を頼み、タイトルに小さく 1 行出す（iOS の 7 日の決まり）。
12. **置き先**（itch.io / GitHub Pages / 自前）: origin とアセットバンドルの形（1 つの zip か、ファイルを並べるか）が変わる。推す: 最初は GitHub Pages（静的なファイルを並べる・origin がゲームごと）で確かめ、itch.io 向けの zip はエクスポートツールのオプションに。
13. **速さの閾値を超えた時のスマホの fps**: 推す: PC の 1 コマの CPU が 3〜6ms なら、ノベルはスマホで 30fps を許し、rpg は速さの手当てをフェーズ 5 の前に入れる（歩く・戦うのは 30fps だと手触りが落ちる【推】）。
14. **dt を固定する環境変数（例 `FLIX_GE_FIXED_DT`）を LwjglLayer に足す**（エンジン拡張）: 推す: 足す。GL のキャプチャで 2 コマ目以降もバイトで比べられるようになり、フェーズ 1 の確かめが強くなる。足さないなら各場面の 1 コマ目だけを比べる。

## refactor の表（.flix の名前を探すとき）

| したいこと | 代わりに打つ |
|---|---|
| 名前の一部から宣言を探す | `bin/fge refactor search <語>` |
| 関数・型の本文だけを読む | `bin/fge refactor show <Mod.名前>` |
| 使う所・呼び手を全部 | `bin/fge refactor usages <Mod.名前> [--callers]` |
| 使われていない pub | `bin/fge refactor usages --unused` |
