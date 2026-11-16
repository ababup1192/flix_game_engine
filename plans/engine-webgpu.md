# 描き手を WebGPU へ移す — 設計（第 5 版・相談用・未着手）

下調べ 8 本と試作 2 本は `plans/webgpu/` にある（`survey/A〜H`・`spike-pc/`・`spike-web/`）。この文書の数字はそこから引いた。
【確】= 生の記録かコードで確かめた ／【推】= 割り算や読みからの見積もり ／【不明】= まだ測っていない ／【目標】= これから目指す値。
レビューは第 1 版 68 点・第 3 版 78 点・第 4 版 84 点（3 回で 90 に届かず。判定は「P0・P1 は着手してよい。R1a 以降は残りの指摘を入れてから」）。
第 5 版は 3 回目の指摘 14 件を入れた物で、**この版はレビューを通していない**（末尾）。第 3 版は、工数を減らす工夫（`RenderList` を挟む・5.1）と、
WebGPU の命令の再調査（`survey/H`）と、「測りながら・書き味を見ながら形を決める」進め方（2 章の 7・9.1）を入れた。

## 1. 何のためにやるか

主目的は性能ではない。次の 4 つ。

1. **描き手を機種から切り離す。** 今は GL 3.3（PC）と WebGL2（ブラウザ）を 1 つの interface（`GlContext`・102 メソッド【確】）で済ませているが、
   GL の形（状態を 1 つずつ切り替える）なので、新しい機種へ持って行けない。「何を描くか」は 1 本にし、機種ごとの差は薄い backend に閉じ込める（5.1）。
   新しい機能を足す時に触る所は、前半・backend（GL と WebGPU）・SoftRaster になる（今は GL の描き手と SoftRaster の 2 か所）。
2. **Mac の OpenGL から離れる。** Mac の GL は 4.1 で止まった非推奨の API で、Metal の上の互換のレイヤー。storage buffer も無い。
3. **家庭用ゲーム機へ近づく。** pipeline・bind group・render pass の形は、Vulkan・Metal・各機種の API と同じ考え方【推】。
4. **エンジンの側でまとめて描く作りにする。** 作り直すなら最初から「まとめる」と性能を優先する（人の判断）。

## 2. 人の判断（2026-11-14）

| # | 判断 |
|---|---|
| 1 | PC もブラウザも、本線は WebGPU に統一する |
| 2 | WebGPU の無いブラウザは、今の GL の描き手（WebGL2）で起動する。当初は「機能を止めた fallback」と決めたが、第 3 版では**同じ `RenderList` を流す GL の backend** に改めた（5.1。止めなくても 2 本持ちの手間が増えないため。会話で伝え済み・11 章の 1 で改めて伺う） |
| 3 | 小さな試作で確かめてから進める（PC とブラウザの 2 本は済み） |
| 4 | エンジンの側でなるべくまとめる操作を優先する API にする。2D も 3D も性能が上がる事を優先する |
| 5 | 性能の物差しは、物を足していくベンチマーク。今ある `bench/sprite_stress`・`bench/crowd2d`・`bench/scene3d` を広げる（新しく作らない）。都市は最後の確かめ |
| 6 | ゲームの中身の CPU（敵の移動・当たり判定）は Flix の速さ待ち。エンジンは「描く物を組み立てる CPU」を減らす所までやる |
| 7 | 形は最初に決め切らない。ベンチマークを取り、書き味（ゲームの側のコードがどう書けるか）のレビューを見ながら、良い形を探す |
| 8 | 先にリファクタするなど、やり方の工夫で工数を減らす |
| 9 | OS ごとの確かめは、いったん Mac でできる範囲でやる（2026-11-14）。Windows と Linux は P4a の門に入れず、実機か CI で確かめるまで「未確認」と書いて進める |
| 13 | 形のレビュー（2D・2026-11-15）: 5.1 の表を改める（pass の区切りは組ごとの `PassSpec`、upload は関数の record にして、どちらも行の種類から外す）。ただし他の案も軽いスパイクで比べてから決める（比べた上で今の案。`plans/webgpu-shape-review-2d.md` の 6 章）。ブラウザの絵の多い場面が P6 まで WebGL2 とほぼ同じなのは、後で速くなる余地がある（JS へ 1 回で渡す形で submit −15%・アトラスの頁）ので今は良い。WebGPU の submit が 1 コマに 2 回以上になる場面は、P6 で staging を比べるまで許す |
| 12 | P2 でブラウザの下限を上げる（2026-11-15）。TeaVM 0.16 の wasm は例外が exnref の `try_table` になり、読めるのは Chrome 137・Firefox 131・iOS Safari 18.4 以降【推・MDN と caniuse から。古い実機では未確認】。WebGPU 版はどのみちこれより新しいブラウザが要るので、WebGL2 版だけ 0.14.1 で訳す道（5.5）は作らない。書き出しは 1 通りのまま |
| 11 | JDK は上げてよい（2026-11-14）。PC の WebGPU を jWebGPU（JNI）に頼り切らず、wgpu-native か Dawn の C の API を Panama（Foreign Function & Memory API・JDK 22 で正式）で直に呼ぶ道を選べる。上げる版と時期は、Flix・Studio が同梱する JRE・配布物・ベンチの基準の取り直しまで含めて段を 1 つ立てて決める |
| 10 | 11 章の残りの伺い事は「全部おまかせ」（2026-11-14）。おすすめの案で進める。リリースと push は、その時に改めて伺う |

## 3. 覆す・書き換える今までの決め事

| 元の決め | 場所 | どう変えるか |
|---|---|---|
| ブラウザの 3D は WebGPU・インスタンス描き・スマホ向けの速さをやらない | `plans/engine-browser-3d.md:9` | 「軽い 3D が動けばよい」フェーズは済んだ。次として WebGPU をやる |
| TeaVM は 0.14.1。0.16 へは WebGPU のフェーズで上げる | `plans/engine-browser.md`（決定 2） | そのフェーズが今（P2） |
| 0.88.0 で性能は区切り（間引き・動かない物の送り・Par は見送り） | 人の判断（2026-11 上旬） | 動かない物の送り（static group）だけ、WebGPU の描き手の中で再開する（P9）。間引きと Par は見送りのまま |
| 層を置く物差しの表（境目 3 つ） | `docs/flix-conventions.md:193-215` | 表に `RenderList` の backend と `WebGpu`（5 章）を足し、`GlContext` の行に「GL の backend 用」と書く。「新しい機種の切れ目は `Platform.Services` の高さ」の文は、描画については「`RenderList` の backend の高さ」に書き換える（P10）。物差しそのもの（実装が 2 つある所にだけ置く）は変えない |
| `docs/backend-parity.md` は GL と SoftRaster の 2 列 | 同 | WebGPU を足して 3 列にする |
| Pass の MSAA の標本数は 1・2・4・8 | `RenderTarget` | WebGPU は 1 と 4 だけ。2 と 8 は 4 にする（絵が変わる。11 章で伺う） |
| context が失われたら頁の読み直し | `plans/engine-browser.md`（決定 8） | **変えない。** device lost も同じ扱い |
| 絵の門の合格線（`docs/performance.md` の 3 つの門） | 同 | **変えない。** WebGPU の列を足すだけ |
| PC の cutout（切り抜きの材質）は MSAA の時に alpha to coverage で抜く（`hasAlphaToOne()` が真の時） | `ScenePlan.planScene` | WebGPU に alpha-to-one が無い。discard で抜く（今のブラウザと同じ。縁がやや荒くなる）。絵が変わるので 11 章の 6 で伺う |

## 4. 下調べと試作で分かった事

### 4.1 今の作り

- 描画の差し替えの高さは `Platform.Services` の 5 つの handler（`Draw2d`・`Draw3d`・`GpuResources`・`RenderTarget.Target`・`Diagnostics`）。
  PC（`LwjglLayer`）・画面なし（`GlOffscreen`）・ブラウザ（`WebLayer`）が `RenderPaintHandlers` の同じ 5 本を共有し、違いは `GlContext` の実装だけ【確】。
- Flix から `GlContext` を呼ぶのは render_gl と engine_web だけで 779 か所。ゲーム・engine_world・engine_tools からは 0。
- **render_gl は描き手だけのパッケージではない。** 11,445 行の中に、PC のウィンドウ（`LwjglLayer` 1,042 行: GL の context・swap・vsync・F8・frame shot・GL のログ）・
  入力（`LwjglInput`・`SdlPad`）・音（`Audio`）・字（`Font*`・`GlyphGrow`）・素材（`LwjglAssets`）・起動画面（`Splash`）が同居している【確】。
- **3D の計画の層は GL に寄りかかっている**【確】。`Render3d.ScenePlan.planScenes`・`planScene` は `gl: GlContext` と GL の `State` を受ける。
  中で `gl.hasAlphaToOne()`・`rowLimit(gl, …)` を呼び、材質ごとに分ける所（`materialEntry(gl, …)`）が GLSL のプログラムを組む。描く順は GL のプログラムの番号。
  GL を呼ばないのは `Batch`・`Counts`・`Light` の `LightData` 作り・engine の側の `Scene3d` の純粋な関数。
- 3D は 2D の z の並びの途中で描かれる（`RenderFrame.emitMerged` の `MScene3d`）【確】。Design の解像度の場面は、先に別のテクスチャへ描いてから貼っている。
  1 つの canvas に WebGL2 と WebGPU は同居しないので、3D だけ先に移す道は無い。2D から移す。
- 2D の口 `Draw2d.renderCommands` は `List[GameEngine.Drawable]` を受ける【確】。描く物の列を作る代金は effect より上（engine_world とゲーム）で払っている。
- ゲームが GLSL を直に書く口は無い【確】。GLSL を作るのは `ShaderGen`（1,218 行。字を直に組む作りで、出口を切り替える所は無い）と、
  光の式の木からの `LightModel3d.Codegen`（出口は `Target = Flix | Glsl`。パターンは 46 か所）。
  手書きの GLSL は、2D の組み込みが 7 本（呼び手の無い旧 2 本を除く）・`ShaderGen` の前置き約 150 行・3D が 579 行・`GlOffscreen` の補助 3 本。
- 同期の読み戻しを使う所: F8 のスクリーンショット・`FLIX_GE_FRAME_SHOT`・`GlOffscreen`（動画・1 枚撮り）・隠して起動した時の隅の 1 画素（`LwjglLayer.flix:377`）・
  3D の材質が 2D の絵の mip の写しを読む所（PC だけ）。
- 門のうち GL の呼び出しの並びを比べるのは render_gl のテスト 3 ファイルだけ。`gl-parity`（GL と SoftRaster の画素）・`gl-capture-check`（PNG の SHA）・
  `determinism`（World の指紋）は画素か World を比べる。ブラウザの絵を比べる門は今は手動（`bin/fge web-capture`）。

### 4.2 外の事情（`survey/E`。二次情報が混じるので、設計が頼る物だけ）

- WebGPU が使える割合は世界で約 89%（caniuse。部分対応を含む）。スマホだけの割合は【不明】。外れるのは iOS 25 以前・Android 11 以前と一部の GPU・Android の Firefox。
  fallback に落ちる人は少なくない前提で考える。
- TeaVM 0.16.0 に WebGPU の宣言（`org.teavm.jso.webgpu`）がある【確・試作で使った】。
- naga は GLSL 330 / ES 300 を入力として受けない。**機械訳には頼らず、生成の所に WGSL の出口を足す。**
- 同期で画素を読む道は無い（`mapAsync` だけ）。`generateMipmap` に当たる物も無い。GPU の時間を測る timestamp-query は選べる機能（無い端末がある）。
- 複数の形を 1 回で描く multi-draw は WebGPU の標準に無い【確】。Chrome の実験の機能は開発者フラグの奥で、使える端末は 0.12%。
  `drawIndirect` も 1 回に 1 draw だけ。
- 直の `draw` の `firstInstance` は標準で、どの端末でも使える【確】。1 つの行のバッファを `firstInstance` で区切れば、形ごとに 1 draw・間に状態の切り替え無しで描ける。
- dynamic offset 付きの `setBindGroup` を draw ごとに呼ぶ形は取らない。試作では 20,000 本で 11.7〜13.2 ms、同じ形で JS との行き来を 1 本にしても 3.1〜3.5 ms かかった【確】。
  `firstInstance` で行を引く形（draw だけを続けて呼ぶ）は**まだ試作していない**【不明】。P4a・P4b の門で測る。
- 引数のバッファを draw ごとに別にすると、Dawn の検査が draw ごとに入る（5,000 instance・412 draw で pass 約 6 ms のうち約 3 ms。1 本に詰めると約 10 µs。Windows の値）。
- 選べる機能の広さ（web3dsurvey の集計・二次資料）: `timestamp-query` 98.8%・`indirect-first-instance` 99.98%。
  狭い物は使わない: `dual-source-blending`（iOS 0.1%）・`float32-filterable`（iOS 57%）・ASTC / ETC2 / BC（OS で割れる）・bindless（未出荷）。
- 上限の既定: bind group は 4 つ・頂点の段と塗りの段の storage buffer は確実には 8 本・絵は 16 枚・texture array の層は 256（2048 以上が 99%）。
  この Mac の Chrome 156 では storage buffer 10 本・絵 48 枚・層 2048【確】。スマホの実機の値は【不明】（P0 で取る）。
- TeaVM の WASM GC には線形メモリが無いので、`writeBuffer` には Java の配列から TypedArray への写しが 1 回要る【推】。1 コマ 1 本にまとめるのが下限。
- LWJGL に WebGPU は無い。Java のバインディングは jWebGPU（wgpu-native と Dawn の両対応）が中心。

### 4.3 試作（この Mac・M4 Pro）

「四角 20,000 個を、**1 個ずつ別の draw で、1 個ごとに行列を渡して**描く」という最悪の形の 1 コマの CPU 時間【確・生の記録あり】。
**これはエンジンの今の書き方ではない**（今の 2D は同じ絵なら 1 draw、3D はデータ用のテクスチャで instance 描き）。API の呼び出しの代金を比べるための形。

| 書き方 | ブラウザ（Chrome 156・TeaVM 0.16 の WASM GC） | PC（JDK 21） |
|---|---|---|
| GL / WebGL2・1 個ずつ | 11.9〜12.2 ms | 9.5 ms |
| WebGPU・1 個ずつ（dynamic offset） | 11.7〜13.2 ms | 3.6 ms（wgpu）／4.4 ms（Dawn） |
| WebGPU・1 個ずつ・JS との行き来を 1 本に | 3.1〜3.5 ms | — |
| WebGPU・storage buffer に入れて 1 回で draw | 0.9〜1.0 ms | 0.27 ms（wgpu）／0.09 ms（Dawn） |

ここから言える事:

- ブラウザで重いのは Java（WASM）と JS の行き来の**回数**と、配列を渡すたびの写し（1 回 0.5〜0.6 µs）。行き来そのものは 1 回約 17 ns。API を替えるだけでは変わらない。
- PC の Mac では、同じ形なら WebGPU の呼び出しの方が安い。エンジンの描きでどれだけ変わるかは【不明】（今は draw が少ないので、差は小さい見込み【推】）。
- まとめれば、どちらも 1 桁以上速い。
- ブラウザ: WebGPU の物は Java の static の欄とラムダに持てた（総称の入れ物・record に入れる形は試していない）。
  非同期（`requestAdapter`・`requestDevice`・`createRenderPipelineAsync`・`mapAsync`）は `JSPromise.await()` で待てる。
  pipeline を 1 本作るのに 65〜93 ms かかった。headless の Chrome でフラグ無しで WebGPU が出る。
  TeaVM 0.16 は CLI の jar が無く、`TeaVMTool` を呼ぶ約 20 行の Java で訳せた（小さな Java だけ。engine 全体は未確認）。
- PC: jWebGPU 0.3.4 の JNI 版（JDK 21 で動く）で、画面なしの描きと読み戻しは wgpu・Dawn の両方で通った。
  **ウィンドウは Dawn だけが描き先の取得と 120 コマの描画まで通り、画面に絵が出たかは未確認**（撮った絵が黒）。wgpu 版はウィンドウで落ちる。Windows・Linux は未試行。
  jWebGPU はネイティブを `$TMPDIR/jParser$USER/` へ同じ名前で開くので、wgpu 版と Dawn 版を続けて動かすと macOS が JVM を止める。

### 4.4 今の重さ（PC・GL）

| 場面 | 物 | draw | 1 コマ | 一番大きい物 |
|---|---|---|---|---|
| 東京・建物をつないだ版（今の既定） | 61 | 70 | 3.0 ms【確】 | GPU の塗り（約 2.9 ms） |
| 東京・1 棟ずつ | 12,557 | 12,566 | 137 ms【確】 | Flix の組み立て 約 96 ms【推】（`planScene` 系が約 67 ms）。GL の呼び出し 約 41 ms【推】。GPU 約 60 ms【確】 |
| 2D・同じ絵のスプライト 20,000 | 20,000 | 1 | 32.3 ms【確】 | Flix が描く物の列を作る 約 25 ms【推】。送る 6.9 ms |
| 2D・絵が 1 個ごとに交互 20,000 | 20,000 | 20,000 | 65.6 ms【確】 | 送る 40.4 ms・GPU 36 ms |
| テンプレ rpg / novel | — | 3〜12 | 塗り 0.4〜1.2 ms | 余裕 |
| テンプレ tidepool | — | 96〜174 | 9〜13 ms | Normal と Multiply の blend の交互が draw の 7 割。スプライトと多角形の入れ替わりで 27 |

- **物が多い場面では、一番大きいのは Flix の側の組み立て。** 物が少ない場面（今の既定の都市・テンプレ）は GPU の塗りか、もともと余裕がある。
  スレッドダンプでは record の欄の引き当て（`RecordExtend.lookupField`）が目立つ。`bench/sprite_stress/RESULTS.md` の過去の記録と同じ。
- `App.withDiagnostics` を付けると 1 コマが倍になる（3.0 → 6.0 ms。`glEndQuery` がメインスレッドの 36%）。
- 2D の draw の数を出す口は無い（今回は GL のログから数えた）。
- ブラウザの都市は測れていない（入口が無い・東京の絵が約 784 MB）。

## 5. 最終の形

```
ゲーム・engine_world（Draw2d・Draw3d・GpuResources・RenderTarget.Target・Diagnostics の effect）
        │                                   ← 機種の差し替えの高さ（今と同じ・docs/flix-conventions.md）
   描き手の前半（1 本・Flix）… 何を描くかを決める
        │   2D: z の並べ・run の切り方・絵の頁への割り当て ／ 3D: ScenePlan・Batch・材質の鍵・LightData
        ▼
   RenderList（値）… 1 コマの「描く呼び出し」の列。pass の区切り・pipeline の鍵・行のバッファの範囲・形・絵
        │                                   ← 新しい差し替えの高さ（実装 2 つ）
        ├─ WebGPU の backend（本線）
        │     WebGpu（Java の interface・WebGPU の形）
        │        ├─ ブラウザ: TeaVM 0.16 の org.teavm.jso.webgpu
        │        └─ PC: jWebGPU の Dawn（Metal・Vulkan・D3D12）。画面なしの描き出しとテストもここ
        └─ GL の backend（fallback）
              GlContext ─ WebGl2（WebGPU の無いブラウザ）／ LwjglGl（fallback の検査を PC で回す・移行の間の PC）

   SoftRaster（CPU の描き手。絵の答え合わせの相手。今のまま。RenderList は通らない）
```

名前は仮（11 章で伺う）。`Gpu` だけの名前は今の `GpuResources`・`GpuHandle`・`GpuTimer` と紛れるので使わない。

### 5.1 `RenderList` を挟む（第 3 版からの柱。工数を減らすための工夫）

今の描き手は「何を描くか決める」と「GL を呼ぶ」が同じ関数に混ざっている（`Sprite.flix` に GL の呼び出しが 238・`Render3d.flix` に 166【確】）。
このまま WebGPU 版をもう 1 本書くと、2D と 3D の全部が書き直しになる。そこで順番を変える。

1. **先に今の描き手をリファクタする。** GL を直に呼ぶ代わりに `RenderList`（描く呼び出しの列）を作り、それを GL で流す実行役（backend）を別に置く。
   **絵は 1 画素も変わらない**ので、今ある門（`gl-parity` 0 px・テンプレの `reference`・`gl-capture-check`）でそのまま守れる。
2. **WebGPU は backend だけを新しく書く。** 「何を描くか」は書き直さない。
3. fallback は「止まった別の描き手」ではなく、同じ `RenderList` を流すもう 1 つの backend になる。

今のコードは既にこの形に近い。2D は `emitMerged` が 6 種類を run にまとめて流す時に run の状態（`st` の欄 11〜18 と Float32 の配列）を持ち、
3D は `SceneDraws[MeshBatch]`・`MeshBatch{head, count, first}`（`first` は行の起点で、`firstInstance` と同じ考え）を持つ【確】。
**新しい型を 1 から足すのでなく、この 2 つを「GL の物を含まない形」に広げる。** この文書では、広げた後の物をまとめて `RenderList`、その 1 行を「描く 1 行」と呼ぶ（型の名前は 11 章の 7）。

**描く 1 行の高さは「物の集まりを 1 回描く」**にする。WebGPU の命令（`setBindGroup` など）の高さにはしない。1 行が GPU の draw 何本かになる事はある（mask つきは 2 本）。
診断の「draw の数」は backend が実際に出した数を数える（今の `Counter.DrawCalls` のまま）。

種類（enum）と欄:

| 種類 | 今の出どころ | 種類ごとの欄 |
|---|---|---|
| 2D: スプライト・字・箱の run | `RenderSprite.drawSpriteInstancedBuf` | 行の範囲・絵（頁か登録の番号）・blend・切り抜き・mask の形 |
| 2D: 多角形の run | `RenderSprite.drawPolygonBatch` | 頂点の範囲・blend・切り抜き |
| 2D: タイルの層 | `RenderSprite.drawTileMapInstanced` | タイルのバッファの番号・**draw ごとの値**（position・tileSize・tileScale・color）・絵 |
| 2D: static layer の範囲 | `Static.flix` | 置き場の番号と範囲・**draw ごとの値**（viewOffset・viewScale・halfDesign） |
| 2D: 面（`ShaderDoc`） | `RenderSprite.drawShaderSurface` | シェーダーの鍵・**draw ごとの値**（rect・time・alpha・`params` の列）・**絵の組**（`texReads` の列と補間）・mask の形（R1b-6: program の番号・values の 64 個の倍数の位置・`reads` の範囲・mask の頂点の範囲・比べる値。12.22） |
| 2D: 3D の場面を貼る | `MScene3d` | 場面の描き先の番号・矩形（今は場面の番号だけ・12.21） |
| 3D: 形の batch（不透明・材質・半透明・影） | `MeshBatch`・`MaterialBatch` | 材質の鍵・形の番号と範囲・行の起点と数・**draw ごとの値**（`uParamN`・cutout）・**絵の組**（材質の絵の列・sampler・normal map・lightmap）（R2a: 不透明だけ `Render3d.SceneList` の行・種類・材質の表の番号・順の番号・行の起点と数・分かれた理由・フラグ。形は backend が上げて返す番号、draw ごとの値と絵の組はまだ行の外。12.23） |
| 3D: ビルボードの集まり・空・後がけ | `drawBillboards` ほか | 行の範囲・絵・draw ごとの値 |
| pass の区切り | `beginTarget`・`endTarget`・影の地図・Design の描き先 | 描き先の番号・クリア・resolve・history の写し・pass ごとの値（カメラ・`LightData`・時刻・影と環境の絵） |
| 物の上げ下ろし | `GpuResources` の handler・`meshEntry`・フォントの部分更新 | 作る・中身を書く・消す（下の「物の寿命」） |
| 読み戻しの依頼 | F8・frame shot | 描き先の番号と矩形・届け先 |

**判断 13（形のレビュー（2D）・2026-11-15）で改めた所**: 上の表の「pass の区切り」と「物の上げ下ろし」は行の種類にしない。
1 回の `renderCommands` は `(PassSpec, 行)` の組の列を出し、pass は組ごとの型のついた record（`PassSpec`: 描き先・depth/stencil・標本数・viewport・history の写し）で渡す。
upload は GL と WebGPU が同じ形で受ける関数の record（`TextureTable.Uploads`）にして、list を作る前に呼ぶ（record は list を作る def へ渡さない）。
スプライトの行は今の形（Int32 の行・1 行 10 欄・1 体 38 個の Float32）。R1b-0 で入れた（`webgpu-shape-review-2d.md` の 3 章・7 章）。

- **行と draw ごとの値の持ち方は backend が決める。** WebGPU は draw ごとの値も行に入れて storage buffer に置き、`firstInstance` で引く（dynamic offset は使わない）。
  GL は今と同じ（instance 用の頂点バッファ・データ用テクスチャ・uniform）。だから「古い方に合わせて新しい方の手を縛る」事にならない。
- **面と材質は、draw ごとの値の並びがシェーダーごとに変わる。** 並び（WGSL の struct）は `ShaderGen` が出す（P5）。P5 の前の「縦に 1 本」は、並びが固定の組み込み（スプライト・字・箱）だけで通す。
- **持ち方は配列。** `RenderList` は Int32 の配列（種類と番号と範囲）と Float32 の配列（行と値）で持つ（今の `st` と同じ流儀）。絵が 1 個ごとに交互の 20,000 個でも record を 20,000 個作らない。
  後で「配列を JS へ 1 回で渡す」形（9 章の「後」）がそのまま乗る。
- **いつ流すか: `renderCommands` 1 回につき 1 つの列を、その場で流す。** 今の即時の順（`renderCommands` のたびに描く・Pass は `beginTarget`〜`endTarget` の別の呼び出し・
  間に `GpuResources` の操作が同期で番号を返す）を変えない。コマ全体を溜めて最後に流す形は、Pass の間のテクスチャ更新の順を列に入れる決まりが要るので取らない（9.1 で測って見直せる）。
  WebGPU の backend は 1 コマ分の行を 1 本の大きなバッファに順に詰める（列ごとに重ならない範囲へ `writeBuffer`。submit はコマの終わりに 1 回。ただし upload の前にそのコマに積んだ pass を submit するので、1 コマに 2 回以上になる場面がある。P6 で staging buffer を比べるまで許す・判断 13）。
- 手本は Dear ImGui の draw list と backend、Bevy の phase item、Unreal の mesh draw command。
- **層を置く物差し**: 実装は最初から 2 つ（GL・WebGPU）。3 つ目は家庭用ゲーム機の backend（その時は `Platform.Services` の高さでなく、この高さで足せる。物差しの文は P10 で書き換える）。

### 5.2 `WebGpu`（WebGPU の backend の下の interface）

実装が最初から 2 つある（ブラウザの JSO と PC の Dawn）。2 つ目は P4a・P4b で要る。
名前は WebGPU の語をそのまま使う（`RenderPipeline`・`BindGroup`・`RenderPass`・`Buffer`・`Texture`・`Sampler`）。Bevy（wgpu）と同じ語。
WebGPU の全部は写さず、backend が使う物だけにする（数十メソッドの見込み）。
物（buffer・texture・pipeline）は、実装ごとの物を包む小さな Java の型で運ぶ。Flix の record や Map に入れて運べる事を P4a・P4b の門で確かめる（試作は未確認）。
device を作る時は `core-features-and-limits` を求め、選べる機能は `timestamp-query` だけを「あれば使う」にする。

### 5.3 何を前半に残し、何を backend にするか

| 物 | 今の場所 | 扱い |
|---|---|---|
| 2D: z の並べ（`mergedByZ`）・run の切り方 | `RenderFrame`（`emitMerged` は `gl` を受ける） | 前半（R1 で `gl` を外す）。run の鍵は今 GL のテクスチャの番号だが、「backend の表の番号」と読み替えるだけで形は同じ |
| 描き先の絵の上下・clip の z の範囲 | 前半が知っている（`emitMerged` の `targetNames`・`RegisteredTexture#flipped`）。射影行列と影の行列も前半が作る | backend の capability に「描き先の絵が上下逆か」「clip の z が 0〜1 か」を足し、前半はそれを見て uv と行列を作る |
| 2D: テクスチャの登録簿・フォントのアトラスの中身（名前 → アトラスの Map） | render_gl | CPU の側の表は前半。GPU の物は backend |
| 3D: `planScenes`・`Batch`・`Counts`・`LightData`・材質の鍵 | `Render3d.*`（`planScenes` は `gl` と GL の `State` を受ける） | 前半（R2 で `gl` を外す）。backend に聞く物は 3 つ: capability（alpha to coverage が使えるか・行の上限）・材質の鍵ごとの**順の番号**（今は GL のプログラムの番号で描く順を決めている。同じ深さの面の勝ち方が変わらないよう、GL の backend は今と同じ番号を返す）・材質の状態（使える / 作成中 / 失敗） |
| **GPU の物の寿命**（形・絵・影の描き先・Design の描き先・シェーダー・static layer のバッファ・タイルのバッファ） | `meshEntry`・`Material.flix` の後半（約 300 行）・`ShaderCache`・`RenderStatic`・`RenderTargetGl` | **置き場の表（鍵・世代・予算・捨てる順・preload・知らせ）は前半、「作る・中身を書く・消す」だけ backend。** 今は描く時に上げているので（`drawBatch` → `meshEntry`）、R2 で「上げる行」を `RenderList` の先頭に出す形に直す（→ 12.23 で、行でなく描く前に呼ぶ backend の関数（`GlRows.uploadRows`）に） |
| 材質が組めない時 | 計画の中で頂点の色の batch へ落とす（`materialEntry` が `None`） | 同じにそろえる。WebGPU で pipeline が作成中の間も「頂点の色へ落とす」（8 章）。計画は backend の「材質の状態」を聞いて決める |
| GL の番号の漏れ | `Dest#framebuffer`・`RegisteredTexture#texId`・engine の pub の `GpuHandle`（`TextureId`・`TileVao`・`ShaderProgram`。effect の戻り値でゲームまで出る）・`GpuHandle.StaticVao(Int32, Int32)`（vao と vbo の組。使うのは `RenderStatic` だけ）・`RenderStatic.Range#vao`・`RenderTargetGl.Entry`（25 か所）・`SceneInputs#jointTexture / instanceTexture`・`MaterialBatch#entry`（uniform の番号の束） | `GpuHandle` は **Int32 のまま「backend の表の番号」と読み替える**（engine の pub を変えない）。render_gl の中の物（`Entry`・`entry`・`vao`・`jointTexture`）は backend の中へ移す（R1・R2） |
| GL の呼び出し（`RenderSprite`・`Target`・`RenderTexture`・`Render3d` の draw・`Shadow`・`Material` の bind・`DataTexture`・`Instancing`・`JointTexture`） | render_gl | GL の backend にまとめる（R1・R2）。WebGPU の backend は新しく書く（P6・P8） |
| `Scene3dRenderer.Renderer` の値 | render_gl | 形はそのまま |
| 呼び手の無い古い道（`RenderSprite.drawSprite`・Array 版の `drawSpriteInstanced` など） | render_gl | R1 の最初に消す |

**PC のウィンドウ（`LwjglLayer`）が backend に聞く口**（P4a で作る。パッケージは分けない。音（OpenAL）・入力・ゲームパッド（SDL）・字のラスタライズ・素材の読み込みは触らない）:

| 口 | GL の backend | WebGPU の backend |
|---|---|---|
| ウィンドウの hint | GL 3.3 core・stencil 8・depth 24 | `GLFW_NO_API` |
| 描き先を作る・作り直す（リサイズ） | context を作る・viewport | surface を作る・configure し直す。`lastFrame` の描き直しは同じ |
| 画面へ出す・vsync | `glfwSwapBuffers`・`glfwSwapInterval` | present・present mode（Fifo / Immediate） |
| 読み戻し（F8・frame shot・隠して起動した時の隅の 1 画素） | `GlReadback`（同期） | 次のコマで届く（8 章） |
| 描き手を作る（`RenderPaint.create`・`Render3d.makeRenderer`・`RenderSplash.install`） | `gl` を渡す | backend を渡す |
| GPU の時間 | `GpuTimer`（間引く） | timestamp-query（あれば） |
| 呼び出しのログ（`GlCallLog`） | GL の backend だけ | 無し（`RenderList` を書き出す口を別に持つ） |
| 起動の時の初期の状態（viewport・クリア・blend。`LwjglLayer.flix:368-402`） | GL の呼び出し | pass を開く時の値として持つ |
| 画面へ出した後に待つ（`finishAfterSwap` の `glFinish`） | `glFinish` | submit した仕事の終わりを待つ（`onSubmittedWorkDone`） |

**画面なし（`GlOffscreen`）とブラウザ（`WebLayer`）が backend に聞く口**（画面なしは P4a・ブラウザは P4b）:

| 口 | GL の backend | WebGPU の backend |
|---|---|---|
| 画面なしの session を開く | LWJGL の隠しウィンドウと `RecordingGl` | Dawn の device だけ（ウィンドウ無し） |
| 画素を読む（`readRgba`）・浮動小数の行を描いて読む（`drawFloatRows`。式の行の突き合わせが使う） | 同期 | `mapAsync` を待つ |
| ブラウザの canvas と context | `fge-web.js` が WebGL2 の context を取り、物は JS の表と番号 | TeaVM の JSO で `navigator.gpu` から device。物は Java の欄に持つ |
| 1 コマを出す | `requestAnimationFrame` を待つ | 同じ。中間のテクスチャを canvas へ写して submit（5.4） |
| context が失われた | 頁の読み直しの案内 | `device.lost` で同じ案内 |

### 5.4 1 コマの render pass の切り方

- **canvas へは直に描かない。** 1 コマは中間のテクスチャへ描き、最後に 1 回だけ canvas へ写す。
  TeaVM はコマの途中でブラウザへ手を返す事があり、canvas のテクスチャ（`getCurrentTexture`）はそこで切れる。canvas は前の絵も保たない。
- **3D は先に自分のテクスチャへ描き、2D の並びの z の位置で四角として貼る。** 今の Design の解像度の場面と同じ形を、Native の解像度にも使う。
  2D の render pass を途中で閉じて開き直さない。3D の depth と MSAA は 3D のテクスチャの中で閉じる（resolve してから貼る）。
  代金は場面 1 つにつき全画面の貼り 1 回。V2 で `bench/scene3d` の前後を測り、P8 の終わりに fps3d_lab の部屋で確かめる。
- Pass（`RenderTarget.Target`）は今と同じく別の render pass。

### 5.5 ブラウザの書き出し

- 書き出しは 2 つ作る（WebGPU 版・WebGL2 版）。起動の時に選び、片方だけ読み込む。WebGPU 版を選ぶ条件: `navigator.gpu` がある・`requestAdapter` が成功する・
  `core-features-and-limits` がある・頂点の段の storage buffer が要る本数だけ取れる。1 つでも欠ければ WebGL2 版。
  今の「入口の字で 2D と 3D を分ける」作りの延長。同じソースの木に両方のレイヤーを置き、入口だけ分ける（ビルドの時にモジュールを差し替えない）。
- 2 つとも普段の型検査を通す門を足す（`make check` の相手に WebGPU の入口を足す）。
- ~~WebGL2 版が動くブラウザの下限を上げない。~~ 判断 12 で下限を上げると決めた（0.14.1 の道は作らない）。

### 5.6 配る物

- PC は jWebGPU の Java の jar（約 0.6 MB）と、OS ごとのネイティブ（Dawn 版で macOS arm64 2.6 MB・Linux x64 5.6 MB・Windows x64 2.1 MB。jar の大きさ）が増える。
  ゲームの `flix.toml` は全 OS のネイティブを並べるので、合わせて約 13 MB 増える【推】。
- jWebGPU の実行時の jar（jParser の runtime）は Maven の依存に出ないので、手で並べる。
- 置き方は今の `gl-jar`（`render_gl/java` を jar にして Release に置き、ハッシュで pin する）と同じ仕組みに、`WebGpu` の Java を足す。
- GL と LWJGL の GL は、fallback の検査（PC で WebGL2 相当の描き手を回す）と Studio のために残す。Studio の同梱一式（`stage-engine`）と `studio-parity` に WebGPU のネイティブを足す。
- JDK は 21 のまま（jWebGPU の JNI 版）。

## 6. 描き手の作りの決まり（まとめる事を優先する）

ゲームは「何があるか」を宣言するだけ。どうまとめて描くかはエンジンが決める。

### 6.1 描き手の中の決まり（ゲームの書き方はそのまま）

1. **1 体ごとの違いはデータにする。** 位置・色・材質の数値・絵の番号を、1 つの storage buffer の行にする。
   draw が分かれるのは pipeline（シェーダーの種類・blend・描き先の形式）と頂点の形が違う時だけ。
   頂点の段で storage buffer を読めない端末（互換モードの一部）は相手にしない（その端末は WebGL2 の fallback へ行く）。
2. **形は共通のバッファに集め、pipeline と bind group を替えずに続けて描く。** multi-draw が無いので、形が違えば draw の呼び出しは分かれる。
   行のバッファは 1 本で、形ごとの範囲を `firstInstance` で指す（dynamic offset は使わない）。draw だけを続けて呼ぶ形の 1 本の代金は【不明】（P4a・P4b で測る。`setBindGroup` と draw の 2 つを呼ぶ形で 20,000 本・約 3 ms だったので、それより安い見込み【推】）。
   bind group は 3 つに分ける（コマごと・材質ごと・行のバッファ）。作り直さず、中のバッファを書き換える。storage buffer は 1 つの段で 8 本までに収める。
3. **2D の絵はアトラスの頁にまとめる。** 絵は大きさがばらばらなので、同じ大きさの大きな頁（例: 2048×2048）に詰め、頁を texture array の層にして番号で引く。
   2D は NEAREST・mip 無しなので、にじみは 1 画素の余白で止まる。繰り返して貼る絵（uv が 0〜1 の外）と大きすぎる絵は頁に入れず、別のテクスチャのままにする（そこで draw は切れる）。
   字のアトラス（R8・4096）は別のテクスチャだが、同じ bind group につないでおくので、フォントが 1 つの間は切れない（フォントごとにアトラスが別なので、フォントが替わる所では切れる）。絵の無い箱も切れない。
   比べた案: 1 つの bind group に絵を 16 枚までつないで番号で選ぶ（詰め直しが要らないが、16 枚を超えると切れる）。P6 の最初に小さく両方を測って決める。
4. **2D の頂点の形は 2 つ残す**（instance の四角 = スプライト・字・箱／三角形の列 = 多角形）。種類が入れ替わる所では draw が切れる（tidepool で 27）。
   四角を三角形の列へ開いて 1 本にする案は、スプライト 1 個の送る量が 4 倍になるので取らない。P0 のベンチで切れ目が重いと分かった時に見直す。
5. **1 個だけ描く口を作らない。** 描き手の内側の API は物の集まりを受ける。ビルボード（今は 1 枚 1 draw）も集まりにする。
6. **行と頂点は 1 コマぶんを 1 本に詰める（upload は除く）。** 頂点と行のバッファは 1 コマ分を 1 本のバッファに詰める（今の GL は run ごとに `bufferData`。tidepool で 1 コマ 133 回）。送る回数は list ごとに `writeBuffer` 1 回で、1 コマ 1 回ではない（判断 13。upload はその前に submit する）。
7. **mip は自分で作る。** WebGPU に `generateMipmap` が無いので、小さくしながら描く render pass を回す（ブラウザの 3D は今 GPU の mip に頼っている）。
8. **まとまらなかった理由を見えるようにする。** 診断に draw の数と、切れた理由（pipeline・頂点の形・絵・半透明の順・描き先）の内訳を出す。

GL の backend（fallback）は 1〜3・7 を使わず、6 は測って得な時だけ入れる。古い端末では今と同じ draw の数のまま動く。

**まとめても減らない物**: 半透明は遠い順に描くので、間に別の pipeline が挟まると切れる。Multiply の blend は Normal と pipeline が別（tidepool の draw の 7 割）。
dual-source blending を使えば 1 本にできるが、iOS でほぼ使えない（0.1%）ので取らない。Add と切り抜きの矩形で切れている場面は、測った 11 場面に無かったので手を入れない。

### 6.2 描き手より上の決まり（今の GL でも速くなる・一部はゲームに見える）

9. **record の欄の引き当てを内側の輪から出す。** 計画と詰める所は Float32 の配列で運ぶ（`bench/sprite_stress` の第二弾と同じ手）。ゲームは直さずに速くなる。
10. **動かない物は 1 回だけ送る。** `plans/engine-static-group.md` の `Scene3d.staticGroup` の形（ゲームが「この集まりは動かない」と宣言する）をそのまま使う。
    WebGPU では行と render bundle を持ち越し、計画（`planScene`）も通さない。render bundle の制約を先に書く:
    中の物を間引けない（視錐台の外も流れる。集まりを区画に分けるのはゲームの側）・描き先の形式ごとに別に要る（色・影）・半透明は入れない・
    中で scissor と stencil の比べる値と blend の定数を変えられない・流した後は pass の状態が全部戻る（pipeline と bind group を付け直す）。
    render bundle を使うのは動かない物だけにする。
    static group の計画にある人への 3 つの問い（11 章の 5）と、「1 bit も違わない」の決まりは、その計画のまま引き継ぐ。
11. **スプライトの集まりを直に渡す口を足す**（ヴァンサバ系）。今の `Draw2d.renderCommands` は `List[Drawable]` を受けるので、1 個ごとに値を作って並べる代金（1 個 約 1.3 µs）が
    effect より上に残る。位置・色・絵の番号の配列を渡す口（Bevy の sprite batch、Godot の MultiMesh に当たる物）を `Platform.Draw2d` と `Render.Item` に足す案。
    **effect と pub が増え、全部の handler（偽物・Studio）と SoftRaster・`gl-parity` に波及する。既存の書き方のゲームは速くならない**（9 の分だけ速くなる）。
    形は別に案を書いて伺う（11 章の 4）。
12. **粒子を GPU で動かす（後）。** 当たり判定の要らない演出を計算シェーダーで動かす。fallback では CPU のまま。別に計画する。

## 7. シェーダー

- **生成の所に WGSL の出口を足す。** `LightModel3d.Codegen.Target` に `Wgsl`（46 か所のパターンに腕を足す）。
  `ShaderGen` は字を直に組んでいるので、型の名前・型変換・関数の呼び出し・テクスチャの読みを組む小さな書き手を挟み、GLSL と WGSL を同じ所から出す。
  P5 の最初の 1〜2 時間で、書き手を挟む形と、WGSL 用に 2 本目を書く形を小さく比べて決める。ゲームの `ShaderDoc` は直さない。GLSL の出口は fallback のために残す。
- **手書きの式は WGSL で書き直す**: 2D の組み込み 7 本・`ShaderGen` の前置き・3D の影の PCF・TBN・`sg_texMip`・`surfaceOut`・画面なしの補助。
- 引っかかる所: clip の z が -1〜1 でなく 0〜1（射影行列・影の bias・深度を出す所を直す）。描き先のテクスチャの上下が GL と逆なので、貼る時の uv と、面の表裏（cull）の向きが変わるかは【不明】（clip 空間の y の向きは GL と同じはず。P4a の三角形で確かめる）。微分（`fwidth`）を `if` の中で呼べない（uniformity）。暗黙の型変換が無い。R8 の swizzle が無い（フォントはシェーダーの側で読む）。
  RGB8 が無い（詰め直す）。描き先の上下が逆（貼る側の uv の反転をやめる）。
- **検査**: PC の Dawn（Tint）で、テストとして全部の組み込みと、テンプレ・bench の材質の変種を作って通す。ブラウザを開かずに WGSL の誤りが出る。
- 式の行（`ExprRows`）の突き合わせは今のまま使う。
- pipeline の鍵 = シェーダーの鍵 × blend × 描き先の形式 × 標本数 × 頂点の形。今の `ShaderCache` より本数が増えるので、上限と LRU を鍵ごとに見直す。

## 8. 同期でなくなる物

| 物 | 今 | WebGPU での扱い |
|---|---|---|
| device の取得 | 同期 | 起動の時に待つ（起動画面の間） |
| pipeline を作る | 同期。失敗したら単色で続ける | 1 本 65〜93 ms（試作・ブラウザ）。**コマの途中で同期では作らない。** 読み込みの間に、分かっている物（組み込み・`withPreload3d` と `ShaderDoc` の宣言から出る材質）を非同期で作る。コマの途中で初めて要る物は非同期で作り始める。できるまで、3D の材質は頂点の色の batch へ落とし（今、材質が組めない時と同じ）、2D の面は単色で描く（今の失敗の時と同じ）。`buildProgram` が同期で返す番号は前半の表の番号で、pipeline の出来上がりとは切り離す。数は材質の種類 × blend × 形式 × 標本数 × Pass（色・影）なので、本数と作る時間を診断に出す |
| F8 のスクリーンショット・`FLIX_GE_FRAME_SHOT`・隠して起動した時の隅の 1 画素 | `glReadPixels` | 次のコマで届く形にする（注釈のチケットはコマが止まっているので待てる） |
| 動画・1 枚撮り（今の `GlOffscreen` の役） | 同期 | PC の Dawn で `mapAsync` を待つ。待つ間コマを進めないので絵は同じ |
| 3D の材質が 2D の絵の mip の写しを読む | PC だけ同期で読む | GPU の上で写す（読み戻さない） |
| GPU の時間（`GpuTimer`） | `glBeginQuery`（毎コマ。重い） | timestamp-query がある時だけ（98.8%）。pass の前後だけを測り、数コマに 1 回に間引く。無い端末では出さない |
| GPU の物の解放 | GL の番号を消す | GC に任せず、`destroy()` を描き手が呼ぶ（WASM GC と JS の物の寿命は別。テクスチャとバッファは明示で消す）。PC の JNI の側は view・bind group・pipeline・sampler・shader module・bind group layout も `release()` で明示で手放す（jWebGPU は GC では手放さない。ブラウザの実装の `release()` は何もしない） |
| device lost | 頁の読み直しの案内 | 同じ |
| mask の途中の stencil のクリア | pass の途中でクリア | stencil は残し、mask ごとに比べる値（ref）を 1 ずつ進める。pass の途中のクリアが要らなくなり、絵は変わらない（1 つの pass で 255 個まで。超えたら pass を分ける）。mask の絵をシェーダーで掛ける案は絵の縁が変わり得るので取らない |

## 9. 段取り

各フェーズは今の GL 版を動かしたまま進める。フェーズの終わりに同じベンチを背中合わせで回す（`bench/sprite_stress/RESULTS.md` の流儀）。
見積もりは実時間で、下位モデルの作業と私の検証を含む（行数からの見立て【推】）。

**進め方の工夫**: (1) 先にリファクタして `RenderList` を挟む（5.1）。(2) 呼び手の無い道を先に消す。
(3) **形を早く確かめる** — リファクタを全部終える前に、スプライトだけで GL と WebGPU の両方を縦に 1 本通し、そこで `RenderList` の形をレビューして確定する。3D も同じ順（不透明だけで通してから残り）。

| 順 | # | 中身 | 門（合格線） | 見積もり |
|---|---|---|---|---|
| 1 | P0 | **ベンチを広げる。** `sprite_stress` に絵の種類（1 / 16 / 256）と blend の混在、`crowd2d` を 20,000 まで、`scene3d` に物の数・形の種類・材質の種類・動く割合・半透明・影のつまみ。3 つともブラウザの入口。2D の draw の数と切れた理由を診断に出す（決まり 8。engine の pub の `FrameDiagnostics` を広げる。`Frame.flix` に入れる数え方は R1a で書き直しになる）。診断の `glEndQuery` を間引く。PC・ブラウザ・スマホ（S24 Ultra・iPhone）で基準を取る。**スマホの実機で WebGPU の limit と feature の一覧を取る**（小さな頁）。agents-pack の早見表と eval（新しい診断の口） | 基準の数字が `bench/baseline/` と `RESULTS.md` に残る。診断を付けても 1 コマが 1.1 倍以内 | 8〜12 時間 |
| 2 | P1 | **描き手より上の直し**（決まり 9）。effect より上（engine_world が描く物の列を作る所。2D 20,000 個で約 25 ms）から record の欄の引き当てを外す。render_gl の中（3D の `planScene` 系）は R2 が同じ関数を作り替えるので、ここでは触らない | `gl-parity` 0 px・テンプレの `reference`。2D 同じ絵 20,000 個: 32 ms → 20 ms 以下【目標】 | 5〜8 時間 |
| — | | **リリース 1**（WebGPU を待たずに速くなる分） | リリースの門 | — |
| 3 | R1a | **2D のスプライト・字・箱だけ `RenderList` に。** 呼び手の無い道を消す → `emitMerged` のスプライトの run が描く 1 行を出し、GL の backend が流す。ほかの種類は今のまま | `gl-parity` 0 px・テンプレの `reference`・`gl-capture-check`。P0 のベンチで 5% 以内。**GL の呼び出しの並びは同じでなくてよい**（門は画素） | 4〜6 時間 |
| 3 | P2 | （R1a と並べて）**TeaVM を 0.16 へ。** `export-web` の呼び方を `TeaVMTool` に替え、JDK の本物のクラスが流れ込まない ClassLoader を組む。足している部品 6 本と runtime を合わせる。WebGL2 のまま全部のテンプレが動く事 | `web-capture` の絵が、**R1a を入れる前のコミット**で 0.14.1 と 0.16 を比べて同じ。書き出しの大きさと時間の前後。古い版のブラウザで WebGL2 版が動く（5.5） | 5〜8 時間。危険あり |
| 4 | P4a | **`WebGpu` と PC の門。** interface を決め、Dawn の実装で三角形（cull の向きの確かめを含む）・読み戻し・ウィンドウ（5.3 の「backend に聞く口」）。**画面なしの session**（今の `GlOffscreen` の open・readRgba・drawFloatRows に当たる物。P5・P6 の門が使う）。ウィンドウに出た絵を機械で確かめる。2 プロセス同時に起動して落ちない事。limit を Dawn から正しく読める事。**`firstInstance` の試作**: 形ごとに `draw(…, firstInstance)` を数千本・`instance_index` で行を引く形の 1 コマの時間。Windows と Linux で同じ試作 | Flix から interface を通して描いた絵が期待と同じ。3 つの OS で通る。通らない時は人に伺う（11 章の 3）。`firstInstance` の形が 20,000 本で 3 ms を超えたら（`setBindGroup` を毎回呼ぶ形と同じかそれより遅い）、決まり 1・2 の前提が崩れるので、次の手（頂点を storage buffer から引いて 1 回で描く形）と一緒に人に伺う | 9〜13 時間 + 別の機械 |
| 5 | P4b | **ブラウザの実装**（P2 の後）。同じ interface を TeaVM の JSO で。物を Flix の record に入れて運べる事。起動の時の選び分け（5.5）。`firstInstance` の試作を Chrome と iPhone の Safari で。**起動の時の選び分けと WebGL2 版の起動は V1 へ回した（12.12）** | PC と同じ Flix のコードで同じ絵。WebGPU の無いブラウザで WebGL2 版が起動する（V1 へ）。`firstInstance` の合格線は P4a と同じ（ブラウザは 20,000 本で 3 ms） | 4〜6 時間 |
| 6 | V1 | **縦に 1 本（2D）。** WebGPU の backend にスプライト・字・箱（WGSL は手書き。この 3 つは今も 1 つのプログラム）と、それに要る最小の「絵とフォントのアトラスを上げる」「Pass を 1 つ挟む」。お題は rpg のテンプレの題名の画面（スプライト 7 個だけ・多角形と面が無い）と、それを Pass 1 つに通した物。PC とブラウザで出す | GL の backend と画素を比べる。`sprite_stress` の同じ絵 20,000 個が GL より遅くない | 6〜9 時間 |
| 7 | | **`RenderList` の形のレビュー（2D）**: GL と WebGPU の backend の行数・ベンチ・書き味の見本を並べ、**スプライトの行と pass の区切りと「上げる行」の形**を確定する（9.1）。ほかの種類の形は、下の交互の進め方で 1 つずつ確かめる | レビュー役 90 点・人の了承 | 1〜2 時間 |
| 8 | R1b ⇄ P6 | **2D の残りを、種類ごとに「GL でリファクタ → すぐ WebGPU の backend に足す」を交互に。** 順: 物の上げ下ろしと寿命の表（5.3）→ 多角形とタイルと static layer → history と MSAA の resolve → mask（比べる値を進める形・8 章）→ 3D の場面を貼る → （P5 の後）面。GL と形が一番違う所（pass・history・mask）を早く WebGPU に通す。「送るのを 1 コマ 1 回に」（決まり 6）は、GL では測って得な時だけ（GL 3.3 / WebGL2 に baseInstance が無く、run ごとに頂点の属性を付け直す事になるため）。アトラスの頁（決まり 3）・読み戻しと F8・動画もここ | 種類ごとに、GL は `gl-parity` 0 px・`reference`・`gl-capture-check`・ベンチ 5% 以内。WebGPU は GL の backend と同じ機械で `gl-capture` の場面を比べる（許容は場面ごとに理由を書く。既定は差 0・丸めが出る場面だけ 2/255）と SoftRaster との `gl-parity`（画面なしの session）。終わりに: テンプレ 3 本が PC とブラウザで GL より遅くない（5% 以内）・ブラウザは `?capture` を自動で回す門 | 18〜26 時間 |
| 9 | P5 | （上の交互の途中で、面の前に）**WGSL の出口**（7 章）。`Codegen.Target.Wgsl`・`ShaderGen` の書き手と、面と材質の draw ごとの値の並び（struct）・組み込み | Dawn で全部の変種が通るテスト。式の行の突き合わせ（画面なしの session の drawFloatRows） | 10〜16 時間 |
| — | | **リリース 2**: 2D のゲームは WebGPU を「試しに選べる」。選ぶ口は、PC は環境変数（`FLIX_GE_BACKEND=webgpu`）、ブラウザは URL の `?backend=webgpu`。何も付けなければ今までどおり GL。入口が 3D（`withProject3d`）のゲームは、付けても GL のまま起動して理由を知らせる | | |
| 11 | R2a | **3D の不透明の batch だけ `RenderList` に。** `planScenes` から `gl` と GL の `State` を外す（capability・順の番号・材質の状態を backend に聞く）。`MaterialBatch#entry` を材質の鍵に替える（→ 12.23 で、鍵の字でなく backend の材質の表の番号（`handle`）に）。形と絵の「上げる行」。**`planScene` 系を配列で運ぶ**（決まり 9 の 3D の分。record の欄の引き当てを内側の輪から出す） | `gl-parity` 0 px・**偽の GL を通るテスト 6 ファイル（Batch・Instancing・JointTexture・Sun・GpuMipmap・Preload。うち GL の呼び出しの並びまで比べるのは 3 ファイル）はそのまま門に残す**（`RenderList` を見るテストは足す）・fps3d_lab が 5% 以内。`bench/scene3d` の動く割合 100%・12,000 個と、東京 1 棟ずつ: 137 ms → 100 ms 以下【目標】 | 8〜11 時間 |
| 12 | V2 | **縦に 1 本（3D）。** WebGPU の backend に不透明と頂点の色・光 1 つ。`bench/scene3d` の部屋を出す。3D を 2D へ貼る形（5.4）を `bench/scene3d` で測る（fps3d_lab での確かめは P8 の終わり） | GL の backend と画素を比べる。**形のレビュー（3D）で確定**（形のレビュー（3D）は V2b の直後（コーディネーターの判断・人のおまかせ・2026-11-16）。12.25。V2b のレビューと同時に行い、行の欄と高さはこの形で確定した・9.1・12.26） | 6〜9 時間 |
| 12b | V2b | **実物の欠けの一覧（人の判断・2026-11-16）。** WebGPU の backend に「まだ描けない物は描かずに飛ばし、種類ごとの回数を知らせる」口を足し、fps3d_lab の部屋とみやげの町（`~/Documents/flix_ge_workspace/lamplighter`）を `FLIX_GE_BACKEND=webgpu` で流す。欠けた種類と回数の表で R2b・P8 の小分けの順を決め直す。以後、R2b と P8 の小分けごとに同じ 2 本を流して欠けが減るのを見る（**済・12.26**。欠けの表は 12.26。下の 2 行の小分けの順を決め直した） | 欠けた絵は画素で比べない（門は今までどおり gl-parity と `bench/scene3d`）。飛ばす口が GL の道と既定の起動を変えない事・知らせが 1 コマごとに増えない事 | 1〜2 時間 |
| 13 | R2b | **3D の残りを `RenderList` に。** 小分け（V2b の欠けの表と形のレビュー（3D）で決め直した順・12.26）: (0) `WebGpuPaint` の 3D の分を子の mod へ分ける（P8 の側だけ・**済・12.27**）／(1) 奥行きの書き出し（Output.Depth）と `ScenePassSpec`（計画が `List[(ScenePassSpec, SceneList)]` を出す・**済・12.27**）／
(1b) 形と 3D の絵の番号の寿命の表を前半へ（行に形の番号の欄を 1 つ・材質の絵は reads で番号・**済・12.28**）／(2) 材質と絵の組（values は uniform の 256 バイトの区画で読むと決めた・lightmap の版と alpha to coverage の版は残した・**済・12.28**）／
(3) 骨と instance（`DataTexture`・`Instancing`・`JointTexture` を GL の backend の中へ・姿勢は storage・1 体ごとの値は instance の頂点の buffer のまま・**済・12.29**）／(4) 影（影の地図の pass の計画と描き先の寿命の表を前半の `Render3d.ShadowMaps` へ・GL の FBO は `Render3d.Shadow` の中の鍵 → FBO だけ・影の pass は場面の列の外の別の型・**済・12.30**）／(5) lightmap・空（人の決めで半分に割る: (5a) lightmap（lightmap の値と絵の組を前半の `Render3d.MaterialValues` が材質の行に書く・GL は uniform の道のまま・**済・12.32**）・(5b) 空（前半の行にはしない・GL は今の drawSky のまま・**済・12.33**））／(6) 半透明・後がけ（人の決めで半分に割る: (6a) 半透明（計画が遠い順に並べ、SceneList の末尾に半透明の材質の行として足す・GL も行で描く・**済・12.34**）・(6b) 後がけ（3D の場面を 2D の Pass に描いて面で加工する形のままで、前半の行は増やさない・空は kindSky にしない・**済・12.35**））／(7) ビルボード・環境マップ（人の決めで半分に割る: (7a) ビルボード（行の種類 kindBillboard を不透明の行と半透明の行の間に 1 行 1 つ・GL と WebGPU の両方が不透明 → ビルボード → 半透明の順に流す・場面の history もここで閉じた・**済・12.36**）・(7b) 環境マップ（mip・preload は P8 の側だけ・前半の行は増やさない・**済・12.37**））／(8) 残りの寿命（描き先。影の地図の寿命は (4) で前半へ・12.30。場面の描き先の寿命の表を前半の `Render3d.SceneTargets` へ・GL の Design の FBO と WebGPU の場面の描き先が同じ表を使う・**済・12.39**）。小分けごとに P8 の同じ番号と交互に進め、終わるたびに fps3d_lab とみやげの町を `FLIX_GE_BACKEND=webgpu` で流して欠けの表が減るのを見る | R2a と同じ門 | 8〜12 時間 |
| 14 | P8 | **WebGPU の backend・3D の残り。** R2b の小分けの順（12.26）。(1) に 3D の診断の数（`scene3dCounts`）を添える（(0)・(1) の Output.Depth は済・12.27。`scene3dCounts` は (1) から外して (2) へ: 数える所（`Render3d.Counts`）が GL の `State` の入れ物に足す形で、WebGPU に同じ入れ物を持たせる仕事が Output.Depth と別の大きさだったため・12.27。(2) で数えるようにした・**済・12.28**）。骨と instance は storage buffer と `firstInstance`（姿勢は group 2 の storage・1 体ごとの値は比べて instance の頂点の buffer のまま・**済・12.29**）。影は深度だけの pass を場面の前に積み、色の pass が group 0 の binding 1・2 で読む（**済・12.30**）。lightmap は材質の group 1 の r3dDraw と binding 19・20 で読む（**済・12.32**）。空は色の pass の頭で、空の 3 色と曲がりを group 0 の場面の値から・向きの材料を R3dScene の末尾から読む別の pipeline で塗る（**済・12.33**）。半透明は材質の pipeline の半透明の版（GL と同じ混ぜ方・深度を書かない）で、行の末尾の半透明の行を描く（**済・12.34**）。後がけは 2D の Pass と面の道のまま描けていて、Design の場面を縮んだ Pass へ貼る WGSL の縦の texel の選び方だけ GL にそろえた（横の境目の揺れは許容を置いて残した・**済・12.35**）。ビルボードは行の順のまま別の pipeline で描き、貼る絵は 2D の描き手の絵の group を借り、値は行の values を stride 0 の頂点の buffer で読む（**済・12.36**）。環境マップは場面の group 0 の binding 3 に材質の絵と同じ置き場の mip つきの絵を付け、景色を背景に描く場面は空の frag が絵を読む。preload は形・材質の program と絵・画面の形式の pipeline を先に上げる（**済・12.37**）。mip（決まり 7）は場面の絵（環境マップを含む）は CPU の Mip.build の mip で GL と同じ。全体の登録の絵の mip つきの写しは、`Texture.createView(baseMip, mipCount)` を `WebGpu` の interface に足し、`Render3d.WebGpuMipmaps` が Mip.build と同じ平均を GPU の pass で作る（**済・12.38**）。
WGSL の決まり（形のレビュー（3D））: 影の座標は頂点で作って渡さず frag で world の位置から作る（頂点 → 画素の値 16 の余裕を残す）・形の並びは版ごとに 1 本の buffer へ交互に並べる（頂点の buffer 8 本の上限のため。`ensureTangents` のように後から別の buffer を足す形をまねない）・
bind group は 0 = コマと場面・1 = 材質（と lightmap）・2 = storage | P6 と同じ形の門。fps3d_lab の部屋と `bench/scene3d` が GL より遅くない（5% 以内） | 12〜16 時間 |
| 15 | P9 | **動かない物の持ち越し**（決まり 10）。前半は描く行を持ち越し、WebGPU の backend は行と render bundle を持ち越す（**済・12.40**） | `bench/scene3d` の動く割合 0%・12,000 個が 16 ms 以下【目標】。東京 1 棟ずつが 16 ms 以下【目標】（届かなければ内訳を出して人に伺う） | 8〜12 時間 |
| 16 | P10 | **切り替え。** PC の既定を WebGPU に（画面なしの描き出し・テスト・動画の既定も）。`gl-capture` の基準を取り直す（Dawn の版を pin）。`docs/flix-conventions.md`・`backend-parity.md`・agents-pack・eval・migrations。外のゲームの追随（**人の指示で前倒し・12.41。既定の切り替え・基準・文書は済。計測・動画・外のゲームの追随は残り**） | リリースの門を全部。CI（GPU が無い）で回る門と手元だけの門を分けて書く | 6〜10 時間 |
| — | | **リリース 3**: WebGPU が既定 | | |
| 後 | | スプライトの集まりの口（決まり 11）・粒子（決まり 12）・GPU の上での間引き（compute で引数のバッファを書く。引数は 1 本のバッファに詰める）・ブラウザで `RenderList` の配列を JS へ 1 回で渡す形（draw が 100 本を超える場面が残った時） | 別に計画して伺う | — |

**見積もりの合計**: フェーズの足し算で 117〜176 時間。これに 9.1 の比べ（候補を小さく 2 つ作って測る。11 件 × 1〜2 時間 = 11〜22 時間）と、
レビュー役（R1b ⇄ P6・P5・R2b・P8・P10 の終わりと形のレビュー（3D）。直しを含めて 8〜12 時間）を足して、**合わせて 136〜210 時間**【推】。
同じ数え方をすると、第 2 版（描き手をもう 1 本書く形）は 139〜207 時間で、**時間はほぼ同じ**。`RenderList` を挟む得は時間でなく危険の下がり方:
リファクタは今の門で 1 画素まで守られ、WebGPU の側で合わせる相手は backend だけになり、形の誤りが V1・V2 と交互の進め方で早く出る。fallback も止まった描き手にならない。
リリースは 3 回（表の行）。リファクタだけの版は、次の定例のリリースに混ぜる。

### 9.1 測りながら・書き味を見ながら決める（人の判断 7）

最初に決め切らない物は、候補を小さく作って比べてから決める。比べ方は 2 つ: **ベンチの数字**（P0 のベンチ・背中合わせ）と、
**書き味のレビュー**（ゲームの側・エンジンの側のコードが実際にどう書けるかを、短い見本で人とレビュー役に見せる）。

| 決める物 | いつ | 候補 | 比べ方 |
|---|---|---|---|
| `RenderList` の 1 行の欄と高さ | R1a と V1 の後（2D）・R2a と V2 の後（3D） | 「物の集まり」の高さ／もう少し低い高さ（bind group まで決める） | GL の backend と WebGPU の backend の行数・ベンチ |
| `RenderList` をいつ流すか（5.1） | V1 の後 | `renderCommands` 1 回ごとにその場で流す／コマ全体を溜めて最後に流す | ブラウザの JS との行き来の回数・Pass のある場面のベンチ |
| 面と材質の draw ごとの値の並びを誰が決めるか（5.1） | P5 の最初 | `ShaderGen` が struct を出す／前半が決めた並びにシェーダーを合わせる | `ShaderGen` の行数・材質を足す時の書き味 |
| GPU の物の寿命の持ち主（5.3） | R1b の「上げ下ろし」の小分け | 表は前半・作る消すだけ backend／全部 backend | backend 2 つの行数・preload のテスト |
| `RenderList` の持ち方（5.1） | R1a | Int32 と Float32 の配列／record の列 | `sprite_stress` の絵が交互の 20,000 個 |
| 2D の絵のまとめ方（決まり 3） | P6 の最初 | アトラスの頁（texture array）／1 つの bind group に 16 枚 | `sprite_stress` の絵 16 / 256 種類・詰め直しの時間・絵のにじみ |
| 2D の頂点の形（決まり 4） | P6 の途中 | 2 つ残す／storage buffer から頂点を引いて 1 本にする | tidepool の draw の数・`sprite_stress` |
| WGSL の出し方（7 章） | P5 の最初 | 書き手を挟む／2 本目を書く | `ShaderGen` の行数の増え方・式の行の突き合わせの通り方 |
| スプライトの集まりの口（決まり 11） | P1 の後 | 今の `Drawable` の列のまま内側だけ速くする／配列を渡す新しい口／集まりを表す `Render.Item` を 1 つ足す | `crowd2d` の 20,000 体・ゲームの View の見本コード（書き味） |
| 動かない物の宣言（決まり 10） | P9 の前 | `Scene3d.staticGroup`（static group の計画の形）／物ごとのフラグ／エンジンが変わらない物を自分で見つける | `bench/scene3d` の動く割合・都市の見本コード（書き味） |
| PC の cutout の縁（3 章） | P8 の材質の小分け | discard（今のブラウザと同じ）／塗りの段の `sample_mask` で標本を自分で決める | MSAA の縁の絵（今の GL と比べる） |
| 3D を 2D へ貼る形（5.4） | V2 | 先に自分のテクスチャへ描いて貼る／pass を閉じて開き直す | `bench/scene3d` の 1 コマ・MSAA の縁の絵（fps3d_lab は P8 の終わりに） |

**形のレビュー（2D）で決めた物（2026-11-15・判断 13・`webgpu-shape-review-2d.md`）**: `RenderList` の 1 行の欄と高さ（2D）は今の「物の集まり」の高さ・1 行 10 欄（3.1）。
いつ流すかは `renderCommands` 1 回ごとにその場で流す（JS へ 1 回で渡す得は list ごとに取れ、ブラウザの絵 16 種で submit −15%。6.3）。持ち方は Int32 と Float32 の配列。
pass の区切りは組ごとの `PassSpec`、upload は関数の record（6.2・6.4 で別の案と比べた上で）。3D の欄は R2a と V2 の後に決める。

**R1b-1 で決めた物（2026-11-15）**: GPU の物の寿命の持ち主は「表は前半・作る消すだけ backend」（2D のレンダーターゲットで両方を書いて比べた・`samples/gpu-lifetime.md`）。
行の合計は前半の表の分だけ多い（185 行と 95 行）。選んだ理由は、寿命の決まりを GPU 無しのテスト 10 本で GL と WebGPU の両方について固定できる事・決まりが 1 か所にある事・片方の backend だけ直す事故が起きない事。
全部 backend の形は、WebGPU に history を足す時に同じ決まりの 2 本目（約 45 行・【見積もり】）が要る。比べの関数だけを共有する中間の案は比べていない。入れた物と門は `webgpu-shape-review-2d.md` の 7.6。

**R1b-2 で決めた物（2026-11-15）**: draw ごとの値（タイルの層の position など・static の view）は `RenderList` の `values`（Float32 の配列・前半の持ち物）に置き、行は 12 欄（形のレビュー 3.1 の 8 のとおり）。
WebGPU はその values を stride 0 の instance の頂点の buffer として読み、行ごとに offset だけ替える（uniform の枠ごとの bind group・dynamic offset と比べた・`samples/per-draw-values.md`）。12.18。

**R1b-3 で決めた物（2026-11-15）**: history は毎コマ写す（2 枚の入れ替えと比べた）・MSAA は pass の終わりごとに resolve する（endTarget で 1 回と比べた）・
WebGPU で history へ写すのは present と同じ WGSL で描く（encoder の copyTextureToTexture と比べた）。3 つとも両方を動かして GL と 0 px（`samples/history-msaa.md`）。12.19。

**R1b-4 で決めた物（2026-11-15）**: mask の比べる値は前半が進めて行に書く（GL と WebGPU の backend がそれぞれ数える形と比べた）・255 を超えた時、WebGPU は pass の中で
design の全面を値 0 で描いて stencil を戻す（pass を閉じて開き直す形と比べた）。2 つとも両方を動かして GL と 0 px（`samples/mask-stencil.md`）。12.20。

**R1b-5 で決めた物（2026-11-15）**: 3D の場面を貼る所は GL と WebGPU で同じ行（`kindScene3d`・欄は場面の番号だけ）にし、GL は行の所で今どおり場面を直に描く
（Native の場面も中間の texture に描いてから貼る形と比べた。GL では標本つきの描き先で MSAA が消え、絵が動いた）。WebGPU は場面を z の位置まで並べて描かずに知らせ、run の切れ目と draw の数は GL と同じ。12.21。

**R1b-6 で決めた物（2026-11-15）**: 面は GL と WebGPU で同じ行（`kindSurface`）にし、`emitRowItem` の Bool をやめた（GL を直に呼ぶ種類は 2D に無くなった）。
面の値は values に置き、WebGPU は values の buffer を uniform としても bind して、面ごとに 256 バイトの倍数の位置で読む（ShaderGen が出す `var<uniform> sg` のまま。storage にするのは engine の変更）。
bind group は draw ごとに作って submit の後に手放す（番号と位置と絵で控えて使い回す形と比べた。速さは揺れの内で、控えを外す決まりが要る）。pipeline は program × blend × 形式 × 標本 × stencil の鍵で控える（draw ごとに作る形と比べた）。
mask つきの面も比べる値を mask つきスプライトと同じく前半が進めて行に書く（面ごとに stencil を 0 に戻す今の GL の形と比べた。絵は同じで、WebGPU は戻すたびに全面の draw が 1 本増える）。12.22・`samples/surface-values.md`。

**R2a で決めた物（2026-11-16）**: `RenderList` の 1 行の欄と高さ（3D）は 2D と同じ「物の集まり」の高さ（1 行 = 不透明の batch 1 つ）にし、前の材質の行と同じ付け方で描ける行に前半がフラグを立てる
（backend が毎行付け直す形・材質を付ける行を分ける低い高さと比べた。GL の `draw` の区間が field 12,000・形が物ごとで 33.5〜35.4 → 28.3〜30.1 ms）。計画は材質の状態を値で聞き（聞く材質を並べて backend が順の番号の列を返す。関数の record を計画に渡す形と比べた）、
材質の batch は backend の材質の表の番号を持つ（材質の鍵の字で引き直す形と比べた）。計画の内側は材質の値ごとに分け方を 1 回だけ決め、描く物を配列の範囲で運ぶ
（物ごとに record を作って列で運ぶ形と比べた。field 12,000 の split 12〜14.5 → 6.3 ms）。V2 の後に WebGPU の行数とあわせて見直す。12.23・`samples/scene-list-3d.md`。

**V2 で決めた物（2026-11-16）**: 3D を 2D へ貼る形（5.4）は「先に自分の texture へ描いて貼る」（A）にした（「pass を閉じて開き直す」B と、`bench/scene3d` の部屋の 1 コマで比べた）。
1 コマは B が速い: 3 回 × 4 区間（JIT の温まる 1 区間目を除く）のどれでも B が短く、差は 0.006〜0.058 ms（中央値 0.026 ms・約 5%）で揺れの内ではない。
比べ方は B の不利が出ない条件に偏っている（標本 1・場面 1 つ・2D の中身なし。B は場面の数だけ 2D の pass が切れ、標本つきの描き先は閉じるたびに resolve する）。
それでも A にした理由: 道が 1 本（Design の解像度の場面はどちらの形でも自分の texture が要る）・B は 2D の pass を行の途中で開き直す道（viewport・控え・黒帯・stencil の張り直し）が要る・
B は標本つきの描き先で pass の切れ目ごとに resolve が増える・スマホのタイル型 GPU では pass の切れ目ごとに描き先の全画面の読み書き（store と load）が増える【推: この Mac では測っていない】。
MSAA のふちは A で消えない（標本 4 の Pass に描いた 3D の斜めの棒で、標本 4 と 1 の差が GL 4,761 px・WebGPU 4,158 px。GL との差 3,330 px は 3D を使わない 2D の斜めの多角形でも 5,040 px の同じ桁で出る標本の位置の違い（12.25。4 標本の型が上下に鏡写しな事は 12.26 で確かめた）。
`RenderList` の 1 行の欄と高さ（3D）は R2a の形のままで WebGPU が流せた（`SceneList` の欄のうち使うのは種類・1 体ごとの値の先頭・数）。形のレビュー（3D）は V2b（実物の欠けの一覧）の直後（コーディネーターの判断・人のおまかせ・2026-11-16）。→ 下の「形のレビュー（3D）の決め」で確定した。12.25。
**形のレビュー（3D）の決め（V2b のレビュー 1 回目と同時・コーディネーターの判断・人のおまかせ・2026-11-16）**: 行の欄と高さ（1 行 = batch 1 つ・Int32 で 7 欄・heads・materials・firstMaterial）は**この形で確定**。
足す物は「欄を末尾へ」「種類（kind）を足す」「pass の側に置く」のどれかで載る（Output.Depth は pass・材質と絵の組は `SceneList` に values と reads を足して行の末尾に位置・lightmap は 1 行 1 体で reads・骨は storage・
影は光ごとの `SceneList`・空は kindSky・半透明は前半で並べて材質の行として足す・ビルボードは kindBillboard・環境マップは場面の値）。
行の 1 つ外側で 2 つ替える: (1) 計画が `List[(ScenePassSpec, SceneList)]` を出す形にする（`ScenePassSpec` は ShadowMap(light)・Color・DepthOut(range) のような enum・描き先は 2D の `PassTarget` と同じ attachment の列 → 12.27 で attachment の列を値で持つ形は (4) へ回した）。R2b・P8 の (1) Output.Depth と一緒に入れる。
(2) 形と 3D の絵の番号の寿命の表を前半へ寄せる分を、(8) から (1) の直後・(2) 材質の前へ出す（行に形の番号の欄を 1 つ・材質の絵は reads で番号）。描き先・影の地図の寿命は最後のまま。12.26。

決めた結果と数字は、この文書の該当の節に書き足す（候補を捨てた理由も 1 行）。
**書き味の見本の形**: 同じお題（例: 敵 2,000 体を出す View・町の建物を並べる場面・材質を 1 つ足す）を候補ごとに 30 行以内で書き、前後のベンチの数字と 1 枚に並べる。
置き場は `plans/webgpu/samples/<決める物>.md`。フェーズの終わりの報告で人に見せ、同じ物をレビュー役にも渡す（名前と読みやすさを見てもらう）。

## 10. 危険と逃げ道

| 危険 | どれくらい | 逃げ道・手当て |
|---|---|---|
| PC のウィンドウに絵が出ない・Windows と Linux で動かない | 中。試作で未確認 | P4a を門にする。通らない時は人に伺う（PC だけ GL に残すと判断 1 と食い違うため、勝手に決めない） |
| jWebGPU の保守が止まる・癖（同じ名前でネイティブを開く・依存に出ない jar・機能の列挙が古い・上限の読みがずれる） | 中 | `WebGpu` の裏に隠すので、wgpu-native を Panama で直に呼ぶ実装に替えられる（JDK 25 が要る）。ネイティブを開く場所はプロセスごとに分ける設定を探し、無ければ自分で先に開く |
| TeaVM 0.16 で engine 全体が訳せない | 中。前の試し（`plans/engine-browser-spikes.md`）では JDK の本物のクラスが流れ込み 21 件の穴が出た | P2 を単独にして WebGL2 のまま通す。通らなければ、WebGPU の宣言だけを 0.14.1 の上に `@JSBody` で自分で書く（量は【不明】） |
| TeaVM 0.16 で WebGL2 版の動くブラウザの下限が上がる | 中【推】 | 5.5（P2 の門・WebGL2 版だけ 0.14.1 で訳す道） |
| WGSL と GLSL の 2 つの出口がずれる | 中 | 同じ書き手から出す・式の行の突き合わせ・SoftRaster を答えにした画素の門を両方に掛ける |
| pipeline を作る時の引っかかり・本数の爆発 | 中 | 8 章（非同期で作る・できるまで頂点の色か単色・preload・診断に本数） |
| GPU の物の解放もれ（WASM GC は JS の物を早くは消さない） | 中 | 8 章（明示の `destroy()`）。長く回す検査（今の `shader_cache_soak` の形）を WebGPU でも回す |
| iOS の Safari のメモリ・device lost の頻度 | 【不明】 | P6 の後に実機（iPhone）で P0 のベンチとテンプレを回す |
| スマホで遅くなる・電池 | 【不明】 | 同上（S24 Ultra）。P0 で基準を取ってある |
| Dawn の版や GPU が変わると絵の SHA が変わる | 高 | `gl-capture` の基準は機械ごと（今も M2 と M4 で違う）。Dawn の版を pin し、上げる時は基準を取り直す |
| CI に GPU が無い | 中 | CI は SoftRaster と WGSL の検査（Dawn の Tint だけ・GPU は要らない【推・P4a で確かめる】）まで。絵の門は手元（今の `gl-capture-check`・`smoke-devtools` と同じ扱い） |
| fallback が腐る | 中 | リリースの門に WebGL2 版の `?capture` を残す。新しい機能を使ったゲームを書き出す時に「WebGPU の無い端末では絵が欠ける」と知らせる |
| 書き出しが 2 つになって遅い | 低 | 書き出しの時間を P2 で測る（今は記録が無い） |
| `RenderList` を挟んで今より遅くなる・R1 と R2 の途中で絵がずれる | 低〜中 | 小分けごとに `gl-parity` 0 px と P0 のベンチ（5% 以内）。遅くなったら行の持ち方を直してから次へ |
| `RenderList` の形が合わず、WebGPU の backend を書く時に作り直しになる | 中 | リファクタを全部終える前に V1（2D）・V2（3D）で縦に 1 本通し、形のレビューで確定してから残りを進める（9 章の順） |
| GL の backend がいつまでも残る（新しい機能ごとに backend 2 つと SoftRaster を触る） | 中 | やめる条件を決めておく: WebGPU の無いブラウザの割合が十分小さくなり（数字は人に伺う・11 章の 1）、Studio が WebGPU で動くようになった時。Studio は当面 GL のまま（別のリポジトリ。P10 の後に別に計画） |

## 11. 人に伺う事

1. **古い端末の扱い**: fallback は同じ `RenderList` を流す GL の backend になる。GL の backend をやめる時の目安（WebGPU の無いブラウザが何 % を切ったら）も伺う。前半に足した機能は fallback でも動くが、WebGPU でしかできない物（粒子の計算・storage buffer が前提の量）は古い端末で欠けるか遅い。これで良いか。
2. **PC のバインディング**: jWebGPU の Dawn 版を本線にする（ウィンドウまで通ったのがこちらだけ・Chrome と同じ実装）。外の小さなプロジェクトに頼り、配る物が約 13 MB 増える。
3. **P4a が通らない時**: PC だけ GL に残すか（判断 1 と食い違う）、通るまで別のバインディングを試すか。その時に伺う。
4. **スプライトの集まりの口**（決まり 11）: effect と pub が増える。P1 の後に候補を小さく作って数字と見本を出し（9.1）、入れるかどうかと形を伺う。入れる作業は P10 の後。
5. **動かない物の宣言の形**: `plans/engine-static-group.md` の 3 つの問いを、P9 の前に改めて伺う。
6. **絵が変わる物**: MSAA の 2 と 8 が 4 になる。PC の cutout の縁が discard になる（alpha to coverage が使えない）。丸めで 1〜2 階調ずれる場面が出る。門の許容を場面ごとに書いて、その一覧をお見せする。
7. **名前**: 決めた — `RenderList`（判断 13・`webgpu-shape-review-2d.md` の 3.6）。Godot の RenderingDevice の render list と three.js の `WebGLRenderList` も、1 コマに描く物を並べた list を同じ名前で呼ぶ。第 5 版までの仮の呼び名 `DrawList` は、engine_tools の `SoftRaster.Internal.DrawList`・engine の mod `DrawCmd`・診断の `Counter.DrawCalls` と字が重なり grep で混ざるので取らない。置き場は `RenderFrame.Internal.RenderList`（pub にしない）。interface は `WebGpu`、実行役は backend。パッケージは分けず render_gl の中に置く（名前は P10 で見直す）。
8. **目標の数字**: 「東京・1 棟ずつが 60 fps（16 ms）」を P9 の目標に置く。
9. **リリースの切り方**: P1 の後（今の GL のままの高速化）・P6 の後（2D で WebGPU を試しに選べる）・P10（既定にする）の 3 回。リファクタだけの版は定例のリリースに混ぜる。
10. **Windows と Linux の確かめ**: 手元に機械があるか。無ければ CI の機械で試作を回す。 → **判断 9: いったん Mac でできる範囲で進める。**
11. **スマホの実機**（P0・P4b）: S24 Ultra と iPhone で、ベンチと「limit と feature を出す小さな頁」を開いて結果を送っていただく必要がある。
12. **診断の口の形**（P0）: draw の数と切れた理由を engine の pub の `FrameDiagnostics` に足す。形は P0 の最初に案を出す。
13. **「試しに選べる」口**（リリース 2）: PC は環境変数、ブラウザは URL の `?backend=webgpu`。project.json に欄を足す形の方が良いか。
14. **合計の時間**: 136〜210 時間の見込み。第 2 版の形と時間はほぼ同じで、得は危険の下がり方。この大きさで進めて良いか（まず P0・P1 だけ先に進める事もできる）。

## 12. 第 5 版の後に分かった事・決めた事（2026-11-14。次の版で本文へ畳む）

### 12.1 P1 で分かった事（速さの元は 3 種類ある）

P1（描き手より上の直し）で、同じ絵のスプライト 20,000 個が 1 コマ 30 ms → 約 8 ms になった（`bench/sprite_stress/RESULTS.md`。最後のコミットの 20,000 個と 3D の草原は測り直しが残る）。
重かったのは record でも並べ替えでもなく、**JVM が JIT しなかったループ**だった（直す前の標本の 75% がインタプリタ。`docs/performance.md` の 13 節）。
この事から、速さの元を 3 つに分けて、どの段で取るかを決める。

| 速さの元 | 中身 | 効く所 | 取る段 |
|---|---|---|---|
| 罠を外す | JIT されないループ（8,000 バイトを超えるメソッド・末尾呼び出しで OSR を諦める）・毎回の `Map[String]` の引き当て・record の欄の引き当て | PC（JVM）だけ。wasm には JIT が無いので効かない | WebGPU と独立。先に取る |
| 割り当てを減らす | effect を呼ぶたびの続きの入れ物・Java と JS の行き来の回数 | ブラウザ（wasm）で効く。PC は JIT が消す分がある | R1a・R1b で `RenderList` へ詰める時に一緒に取る |
| 仕事を減らす | まとめて描く（draw call）・動かない物を送り直さない・見えない物を描かない | PC もブラウザも。数が増えるほど効く | P6・P9・P10（WebGPU の backend） |

- 4.4 の「今の重さ」は P1 の前の値。R1a の前に、P1 の後の値で表を作り直す（どの段が残っているかが変わった）。
- 1 つ目の直し（1 個ぶんを別の def へ出す）だけだと、ブラウザは 9% 遅くなった（effect を持つ def を呼ぶたびに続きの入れ物を割り当てる）。
  **PC で速くなった直しは、ブラウザでも測ってから入れる**（門に足す）。
- 同じ罠が 3D の描き手とゲームの側に残っているかは未調査。crowd2d はベンチの側のループ（`Crowd.moveByGrid`）がインタプリタのまま（1 コマの約 15%）。

### 12.2 2D と 3D で共通にする所・分ける所

`RenderList` の命令を 2D と 3D で 1 つの形にまとめない。共通にするのは入れ物と下の層だけにする。

| 層 | 共通か | 理由 |
|---|---|---|
| `RenderList` の入れ物（Int32 と Float32 の配列・種類ごとの enum・1 コマぶんを使い回す） | 共通 | 割り当てを減らす手が同じ |
| backend の下（buffer・texture・pipeline の cache・bind group・render pass の開け閉め） | 共通 | WebGPU の命令は 2D も 3D も同じ |
| 命令の種類（スプライトの集まり・多角形・タイル層 / mesh の集まり・影の pass） | 分ける | まとめる鍵が違う（2D は重なり順が先・3D は material と mesh が先）。1 つにすると、どちらの最適な並べ方も取れない |
| 並べ方 | 分ける | 2D は z の順を守る。3D の不透明は順を入れ替えて良い（depth が前後を決める） |
| シェーダーの式（式の木 → GLSL / WGSL / CPU） | 共通 | 12.4 |

### 12.3 構造の決まりに足す 2 つ（`analysis-render-structure.md` から）

- **描き先を 1 枚と決め打ちしない。** 3D の場面は今、色 1 枚だけを出す。`RenderList` と render pass の形は、名前つきの attachment（depth・normal）を後から足せる形にしておく（足すのは WebGPU の backend の後。輪郭線・SSAO・被写界深度が読む）。
- **手書きのシェーダーの字を、式の木へ寄せる。** GLSL を字で持つ所（`Render3dGlsl` など）は、WGSL を足す時に 2 本になる。P5 で、型のついた式の木 1 本から GLSL・WGSL・CPU を出す形へ寄せる。全部を render graph にはしない。
- 取らない物: 前のコマとの差分を自動で追う形（View が毎コマ値を返す作りと合わない。動かない物は、ゲームが static と宣言する）。GPU の側の間引きは、CPU の描き手と絵がずれない範囲だけ。

### 12.4 貫く考え（WebGPU へ移っても変えない）

1. View は毎コマ値を返す純粋な関数。
2. CPU の描き手（SoftRaster）で絵の答え合わせをする。WebGPU の backend も同じ門（gl-parity の形）を通す。
3. ゲームにシェーダーの字を書かせない（ShaderDoc・式の木）。
4. 機種の差は effect の handler で受ける。
5. ゲームは宣言し、エンジンが決め、理由を診断で見せる（draw call が割れた理由など）。
6. 調整する値は Doc に出す。

### 12.5 独立に進める物・相乗りする物・後から入れる物

| 分類 | 物 |
|---|---|
| 独立（WebGPU と無関係に今すぐ） | 罠を外す直し（12.1）・JIT されないループを知らせる lint・post process を値の列で宣言する形（`PostStack`。試作の後に相談）・光と色の単位（`survey/K`。新しい口だけ別の型で受ける）・解析テスト（白い球・tonemap の曲線） |
| 相乗り（R1・P5・P6 の中で） | 割り当てを減らす直し・texture の名前を handle で持ち回る・式の木の 1 本化・texture が違っても割れないまとめ方 |
| 後から（WebGPU の backend の後） | 名前つきの attachment（depth・normal）・それを読む効果（輪郭線・SSAO）・HDR の Pass を linear にする・逆二乗と 1/π の直し（絵が変わる）・GPU で置く草 |

### 12.6 光と色（`survey/K`。柱の 3 つはコードで確かめた）

- 3D の出口は `r3d_linearToSrgb3` を通ってから HDR の Pass に入る（`Render3dGlsl.surfaceOutSource`）。tonemap は sRGB の曲線を掛けた後の値に掛かる。
- diffuse は `Albedo × Light × (1 − metallic)` で 1/π が無く、specular の分布には 1/π がある（`LightModel3d.pbrModel`・`withSurface` の `dScale`）。
- 点光源の減り方は `(1 − d²/range²)²` で、逆二乗の項が無い（`LightModel3d.bindAttenuationAndFacing`）。
- WebGPU へ移す時に式を変えない（backend の比べの門が 0 px でなくなる）。式を標準へ寄せるのは、移した後の別の段にする。

### 12.7 後半の危ない所の試作（2026-11-14・この Mac だけ。`spike-pc/REPORT.md`・`spike-web/REPORT.md` の「第 2 回」「追試」）

確かめた（10 章の危険のうち 2 つの山が消えた）:

- **PC の窓**: engine と同じ LWJGL 3.4.1 の GLFW の窓（旗は `GLFW_NO_API` だけ変える）に Dawn で描き、読み戻しと画面からの撮影（`screencapture`・ScreenCaptureKit）の両方で絵が出ている事を確かめた。前の試作の黒い絵は画面のロックのため。LWJGL と jWebGPU のネイティブはぶつからない
- **PC の `firstInstance`**: 20,000 本で CPU 1.6 ms（3 回中 2 回。1 回 2.5 ms）・GPU 1.05 ms。合格線の内
- **ブラウザの engine 全体**: rpg-starter の書き出しを TeaVM 0.16 で訳して穴 0 件。0.14.1 と絵の SHA が同じ。書き出しの時間は変わらず、wasm は +4.5%。engine の側を直す所は無く、直すのは書き出しの入口（`TeaVMRunner` → `TeaVMTool`・jar の一覧）だけ。P2 の「JDK のクラスを見せない ClassLoader」は要らない
- **ブラウザの `firstInstance`**: 20,000 本を JS との行き来 1 本で積んで CPU 1.0 ms
- **Flix から持つ**: PC もブラウザも、WebGPU の物を Flix の record・`Map` に入れて運べた。ブラウザの非同期は effect の handler から `JSPromise.await()` で待てる
- jWebGPU の癖 4 つは原因と手当てが分かった（ネイティブの置き場を版と backend ごとに分ける・u64 の上限を直に読む・名前の無い機能は数で要る・jar は `[mvn-dependencies]` に書けば取れる）

新しく分かった危ない所（段の門に足す）:

- PC: 画面に出す待ちは次の描き先をもらう所（`getCurrentTexture`）で起き、隠した窓でも待たされる。1 コマの時間の測り方を直す。headless は窓を使わず texture に描く。窓の大きさが変わっても Dawn は知らせないので、GLFW の側で受けて作り直す
- ブラウザ: draw を 1 本ずつ積むと GPU のプロセスに 3.2 ms 残る（instanced なら 0.4 ms）。まとめて描く段（P6）の値打ちの裏付け
- ブラウザ: WebGPU の物を `Object` を受ける所へ渡すと、TeaVM は通るのにブラウザが wasm を読む所で落ちる（真っ白）。Java の型に包んで渡す。書き出しの門に「ブラウザで wasm を読めるか」を入れる
- 撮った絵には画面の色の設定が掛かる。絵の門は読み戻した値で見る

まだ【未確認】: Retina の 2 倍・窓を引っぱる間の動き・入力を入れた後の場面・古いブラウザの下限・Safari と iPhone・Windows と Linux（判断 9）。

PC の橋は jWebGPU のまま P4a を進め、`WebGpu` の裏に隠して後で Panama へ替えられる形にする（Panama は JDK 21 の preview で GPU の情報と上限まで読めた。Dawn の公式の配布は dylib が無く、自分で組む）。

### 12.8 P4a で入った物（2026-11-15・この Mac だけ）

- `render_gl/java/fge/webgpu`（interface `WebGpu` と物の型・Desc の類）と `fge/webgpu/dawn`（jWebGPU 0.3.4 の Dawn）。Flix の側は
  `WebGpuOffscreen`（ウィンドウなしの session・`readRgba`・`drawFloatRows`）と `WebGpuWindow`（PC だけ・`GLFW_NO_API`）。
- 確かめる口は engine の `make webgpu-check`（`bench/webgpu_check`。上限・三角形と面の向き・readRgba・式の行・firstInstance の 20,000 本・
  device の取り直し・ネイティブの置き場の誤り・2 プロセス同時・ウィンドウの読み戻しと作り直し）。GPU が要るので CI には載せない。
- ゲームへ配る物（agents-pack の早見表と eval のお題）には、ゲームが WebGPU を選べるようになる「リリース 2」まで載せない。
  その時に足すお題の案: 「ウィンドウを開かずに WebGPU の device で三角形を描き、画素を読み戻して期待の色と比べる」→ 期待は `WebGpuOffscreen`、
  避けるのは `glReadPixels`・`LwjglGl`。
- Dawn のネイティブ（macOS arm64 で 2.6 MB）は `render_gl` と `bench/webgpu_check` の flix.toml だけが持つ。`engine_full` は API の jar だけ
  （リリース 2 でネイティブの行を足す。その時に Windows・Linux の jar の行も）。

### 12.9 P4a の後に直す物（2 回目のレビュー 91 点の残り。P4b か P6 の頭で）

1. `DawnNatives.markLoaded` は jParser の内側の表に名前を入れる。jParser が名前の作り方を変えると、init が自分の置き場へ書き出してもう一度読み、門は緑のまま同じ dylib が 2 回読まれる。init の後に表の大きさが 2 のままかを見て、増えていたら止める。Studio の中で別の class loader から読む形になったら確かめ直す
2. `make two` の待ち合わせが 2 秒の決め打ち。2 つが「用意ができた」ファイルを置くまで待ってから放つか、両方の `waited` が 0 より大きい事を合格の条件にする。Makefile の `java` は PATH のままなので、engine の devbox の jdk へ落とす
3. `DawnWebGpu.destroy()` の後に `DawnSurface` が手放した adapter を使いうる（窓を先に閉じる順を doc に書くか、surface に adapter を持たせない）。`open` のたびに `WGPUInstance` を作って手放していない。`getCurrentTexture` で無効な texture の包みを捨てている
4. `defaultView()` の返り値を呼び手が `release()` すると壊れる。返り値の `release()` を何もしない形にするか、`TextureView.release` の doc にも書く
5. Studio の Maven の種を、jWebGPU と jParser を含めて取り直す（リリースの手順に入れる）。2026-11-15 に Maven Central が 429 を返し、merge 後の main の sync が jWebGPU を取れずに止まった（手元のキャッシュから写して通した）
6. `TestWebGpuOffscreen` の `unchecked_cast(… as _ \ {})` で IO を型の上で消している。テストを `\ {Assert, IO}` で書けるなら替える
7. `readRgba`・`drawFloatRows` の中の例外（10 秒の待ち越え・短い data）は Err にしていない。device lost を Err にするかを P10 までに決める

P4b で片づけた物: 6（`TestWebGpuOffscreen` を `\ {Assert, IO}` で書き、`unchecked_cast` を外した）。
残した物: 1〜5・7（1・3・4 は Dawn の側で、P4b は `render_gl/java` を触らなかった。2 は `make two`・5 は Studio の手順・7 は P10 まで）。P4b のレビューで足した物:

8. 次に `render_gl/java` を触る時に、`WebGpu.errorCount` の doc へ「ブラウザでは submit した仕事の終わりまで待つ（イベントの輪へ 1 度手を返す）ので毎コマ呼ばない」と書く。
   今は書いていない（GL の層の jar のハッシュは文書を含むソースから出るので、コメントだけでも置き直しになる）。同じ時に doc の「後でブラウザの JSO」を `fge.web.webgpu.BrowserWebGpu` に直す
9. `make two` の `-Dorg.lwjgl.system.SharedLibraryExtractDirectory=$(CURDIR)/build/lwjgl` が相対扱いになり、`bench/webgpu_check/Users/…` に空の木ができる
10. `bin/fge export-web` は java を PATH から探すので、devbox の無い worktree では `/usr/bin/java` のスタブを掴んで止まる（bin/flix のように engine の `.devbox` の java へ落とさない）
11. `bin/fge refactor` の索引に `engine_web`・`bench`・`render_gl/test` が入っておらず、search・usages が実在の呼び手を落とす
12. `lastError` の文の形が実装で違う（Dawn は `Validation: …`、ブラウザは `GPUValidationError: …`）。今は字で比べる所が無い。P6 で突き合わせる時に揃える
13. `bin/fge refactor usages --unused` の字の出力は、更新時刻で `build/refactor/last-usages.txt` を拾う。同じ checkout で別の usages が同時に走ると、後ろに足す「別のソースツリーから使われている物」に関係の無い行が混じる（ルートの答えと終了コードは正しい）。一覧のパスをその回だけの物にする

## 版ごとに直した事

**第 5 版**（第 4 版のレビュー 84 点の指摘 14 件。**この版はレビューを通していない**）: V1 のお題をスプライトだけの画面に・画面なしの session を P4a に前倒しし、
`GlOffscreen` と `WebLayer` が backend に聞く口の表を足した・見積もりの足し算の誤り（136〜210 時間。第 2 版の形とほぼ同じと認めた）・
R1b と P6 を種類ごとに交互に・3D の `planScene` 系を配列で運ぶ事と目標を R2a に・capability に上下と clip の z・`LwjglLayer` の直の GL 2 か所・`StaticVao`・
表裏は【不明】として P4a で確かめる・cutout の縁の候補・3D を貼る形を測る場所・P0 を 8〜12 時間に・「試しに選べる」口・`firstInstance` の合格線と次の手・伺う事 4 件。

**第 4 版**（第 3 版のレビュー 78 点の指摘）: 描く 1 行を種類ごとの enum にし「draw ごとの値」「絵の組」を足した・GPU の物の寿命は表が前半で作る消すだけ backend・
`RenderList` は `renderCommands` 1 回ごとにその場で流す・GL の番号の漏れの一覧と `GpuHandle` の読み替え・`LwjglLayer` が backend に聞く口の表・
順を「スプライトだけリファクタ → 縦に 1 本 → 形のレビュー → 残り」に（V1・V2・R1a/b・R2a/b）・`firstInstance` は未試作と認めて P4a・P4b の門に試作を足した・
alpha-to-one が無い事と clip の z と表裏・古い番号の食い違い・GL では「1 コマ 1 回で送る」を測ってからに・描く順の番号と材質の状態を backend に聞く・
偽の GL を通るテスト 6 ファイルを R2 の門に残す・新しい型を足さず今の `SceneDraws` と run の状態を広げる・配列で持つ・P1 を effect より上に絞る・
起動の選び分けの条件・目的 1 の文と GL の backend をやめる条件・見積もりに比べとレビューを入れた（115〜180 時間）・9.1 に 4 行と見本の形。

**第 3 版**: `RenderList` を挟み、先に今の描き手をリファクタしてから WebGPU の backend だけを書く形にした（5.1・R1・R2）。パッケージを分ける引っ越し（第 2 版の P3・P7）をやめた。
fallback は止まった別の描き手でなく、同じ `RenderList` を流す GL の backend にした。WebGPU の命令の再調査（`survey/H`）を入れた（`firstInstance`・dynamic offset を使わない・
bind group 3 つ・storage buffer 8 本まで・dual-source blending を取らない・render bundle の制約・引数のバッファは 1 本）。測りながら・書き味を見ながら決める表（9.1）。見積もりを 100〜150 時間に。

**第 2 版**（第 1 版のレビュー 68 点の指摘 21 件）:


計画の層が GL に寄りかかっている事を認めて P7 を足した・render_gl からウィンドウなどを分ける P3 を足した・スプライトの集まりの口を描き手の中の話から外して伺う事にした・
render pass の切り方（5.3）を決めた・2D を 1 pipeline に寄せる話をアトラスの頁と「頂点の形は 2 つ残す」に改めた・mip を自分で作る事・試作の表を「最悪の形」と書き直した・
門に合格線と目標・P4 を PC とブラウザに分けた・見積もりを 120〜175 時間に・pipeline を作る時間・危険 6 件・GL だけの直しを P1 から外した・static group の制約・
dual-source blending・mask は ref を進める形・GL との比べの門・覆す決め事 4 件・名前・配る物（5.5）・細かい数字の誤り・レビュー役と agents-pack の置き場。

### 12.10 P2 で入った物（2026-11-15・この Mac だけ）

- `export-web` は TeaVM 0.16.0 を `fge.teavmfix.BuildWasm`（`TeaVMTool`）で呼ぶ。`CopyOfRange` の付け替えは外した。手順は `docs/migrations/0.96.0.md`。
- 書き出しの最後に ⑨ を足した。ヘッドレスの Chrome で頁を開き、wasm の compile と最初の 3 コマで止まれば exit 1（`--no-browser-check` で飛ばす）。
- rpg-starter と sound-novel-starter の `?capture` の絵 12 枚が、0.14.1 とバイトまで同じ（題名の画面と、キーを入れた後の場面）。
- merge の後の main で、rpg-starter の書き出しが 43 秒で通り ⑨ も緑。wasm は 8,256,469 バイト（0.14.1 から約 +4.5%）。頁を開いて題名の画面まで動くのを目で見た。
- 古い版のブラウザでは確かめていない（判断 12）。
- Maven Central が 429 を返した時は、`build/engine_full_web/lib/cache` に TeaVM の一式を手で置けば `make sync-engine-full-web` が通る（P4a の jWebGPU と同じ）。

### 12.11 JDK 25 の段（2026-11-15・この Mac だけ）

- main は devbox の jdk@25（mac は Zulu 25.0.3・Linux は OpenJDK 25.0.5）。配る物の JRE は Temurin 25.0.5+8。GL の層の jar は `--release 17` のままで、ハッシュは変わらない。
- `--enable-native-access=ALL-UNNAMED` は窓を開く経路に無条件。`--sun-misc-unsafe-memory-access=allow` は bin/flix と headless-run が java の major ≥ 24 を見た時だけ足す（Studio が同梱する JRE 21 でも起動が落ちない）。Windows の make は native access の旗だけ。
- compact object headers は入れない。
- devbox.lock に x86_64-darwin の行は無い（nixpkgs のその rev が外している。go・ffmpeg も同じ）。
- main で確かめた物: テスト 4 層（engine 960・render_gl 305・engine_world 1473・engine_tools 305）とテンプレート 3 本の reference-check が緑。gl-parity の castShadow「差 565 px」は JDK 21 の main でも同じ（B 段階の既知の差）。
- GC（bench/scene3d の field 12,000 個・-Xlog:gc・2 回ずつ交互）: JDK 21 は停止 55 回 491 ms・96 回 674 ms、JDK 25 は 68 回 550 ms・62 回 547 ms。frame p50 は 21 が 16.3〜16.8 ms、25 が 15.7〜16.6 ms。どちらも揺れの中で、前の試しで見えた「25 の方が GC が多い」は出なかった。
- 残り: Studio が同梱する JRE を 25 へ上げる（別リポ）。配る物を実際に組んで起動する確かめ・Linux の CI で jdk@25 が入るかは【未確認】。

### 12.12 P4b で入った物（2026-11-15・この Mac・Chrome 156 だけ）

- ブラウザの実装は `engine_web/java/fge/web/webgpu`（`BrowserWebGpu`・`BrowserObjects`・`BrowserFormats`。Dawn の 3 本と対）。TeaVM 0.16 の JSO を使い、
  宣言に無い所だけ `@JSBody`: device の上限を全部求める descriptor・null の見分け・`hasFeature`（device の features）・`describe`（adapter の info）・
  `errorMessage`（uncapturederror の文）・`setTimeout(0)` の Promise（`errorCount` の待ち）・読み戻しの写し（`Uint8Array.set`）・
  `getPreferredCanvasFormat`・canvas の大きさ・canvas の webgpu の文脈。
  置き場を `fge/webgpu/browser` にしなかったのは、lint-forbid の `teavm-jso-outside-fge-web`（JSO の import は `engine_web/java/fge/web/` の下だけ）に合わせたため。
  `fge.webgpu` の interface は変えていない（render_gl/java は触らず、GL の層の jar のハッシュも同じ）。
- 実装を選ぶ所: effect `WebGpuDevice`（op は `requestDevice`・`render_gl/src/WebGpuDevice.flix`）。`WebGpuOffscreen.open` はこれで device を取る。handler は
  PC が `WebGpuDevice.runDawn`・ブラウザが `WebLayer.runBrowserWebGpu`。入口で差すだけで、session を使うコードは同じ（Fs の handler と同じ形）。
  `docs/flix-conventions.md` の「層を置く物差し」の表に行を足した。AGENTS.md の「新しい機種の切れ目」の行は変えていない
  （この境目は GlContext と同じく PC とブラウザの 2 つのための物で、新しい機種は今までどおり `Platform.Services` などの handler の高さで切る）。
- 待つ所（requestAdapter・requestDevice・getCompilationInfo・mapAsync・onSubmittedWorkDone）は Java の中で `JSPromise.await()`。
  `errorCount` は submit した仕事の終わりを待ってからイベントの輪へ 1 度手を返す（uncapturederror がタスクで届くため）。毎コマは呼ばない（12.9 の 8）。
- 確かめる口: `make webgpu-check-web`（`bench/webgpu_check/web/WebMain.flix` を `bench-web` の道で書き出し、ヘッドレスの Chrome で流す。待つ上限 120 秒・
  例外でも NG の行と終わりの合図を出す）と `make webgpu-check-same`（同じ機械で PC とブラウザの門を流して digest を比べる）。
  ウィンドウを使わない門は `bench/webgpu_check/src/Checks.flix`（`WebGpuSharedChecks`）にあり、PC（`make webgpu-check`）と同じコードを流す。ブラウザだけの門は canvas の描き先。
- PC とブラウザで同じだった物（`make webgpu-check-same`）: digest は triangle-cull-back が −1039704047・triangle-cull-none が −638468079・
  firstInstance の 20,000 本の絵が −225122287（PC も Chrome も同じ値）。式の行（drawFloatRows）の 2 行 16 個の値も同じ。
- 違う物は上限だけ。`make webgpu-check-same` の同じ回の limits の行（PC は `build/bench-web/webgpu_check-pc.txt`・Chrome は `build/bench-web/webgpu_check.json`）で、
  Chrome は maxBufferSize と maxStorageBufferBindingSize を 4,294,967,292（PC の Dawn は 41,747,087,360）・maxUniformBufferBindingSize を 65,536 に絞り、
  maxSampledTexturesPerShaderStage は 48（PC は 16）。
- firstInstance の 20,000 本（1 本ずつ draw）: Chrome で CPU 0.5 ms（3 回とも同じ）・GPU 0.33 ms。PC の Dawn は CPU 1.4〜1.5 ms・GPU 1.05 ms。
  刻み: 各コマの値の小さい方は CPU が 0.4・0.5・0.6・0.7 ms（`performance.now` の 0.1 ms 刻み）、GPU が 0.262144・0.32768 ms（timestamp が 65.536 µs = 2^16 ns 刻み。
  PC の Dawn の 1.048576 ms も同じ刻みの 16 倍）。どちらも刻みより細かい差は読めない。
- 【未確認】Safari（Mac・iPhone）・Windows・Linux・WebGPU の無いブラウザでの起動（起動の時の選び分けと WebGL2 版の起動は V1）。

### 12.13 V1 の設計（2026-11-15・第 3 版。レビューは 78 点 → 91 点で合格。残りの 6 件も入れた）

V1（縦に 1 本・2D）の設計は `plans/webgpu-v1.md`。この文書に関わる決め事:
- 書き出しは 1 つ（wasm 1 本に両方を入れて起動で選ぶ。5.5 の「2 つ作る」を改める。増える分は rpg-starter の 4〜7% の見込み【推】で、段階 4 で 2 つに分けて測る）。
- WebGPU の流し方は `RenderFrame.Internal.WebGpuRows` に置き、`RenderFrame` の関数を pub に開かない（子孫の mod から先祖の pub でない物が見える【確】）。増える pub は同じ文書の 0 章の表。
- instance の 38 float は instance の頂点バッファでそのまま読む。
- 読み込みは V1 の仮の道（CPU の側の pub だけを共有し、上げる所を WebGPU の側に別に書く。同じ文書の 3.1）。PC で起動の後に字を足すのは V1 の外。
- 決めた事: Pass のお題は `bench/gl_parity` の `passPaste` などで代える・Dawn の macOS arm64 のネイティブを V1 で `engine_full` に載せる・PC の 3D は描かずに知らせる・GL へ落ちた理由は画面に出さない。
- ブラウザで `getContext("webgpu")` の後に落ちたら、`backend` を外した URL で `location.replace` して GL で開き直す（同じ canvas から webgl2 は取れないため）。
- 形のレビューへの持ち越しは同じ文書の 12 章（17 件）。

### 12.14 計画の終わりの確かめ（人の希望・2026-11-15。P10 の門に足す）

- **スマホの 3D**: fps3d-room を S24 Ultra（と iPhone）で、WebGL2 と WebGPU の両方で測り、基準（S24 Ultra で 46.5 fps・CPU 20.7 ms）と比べる。場面と測り方は基準の時と同じにする。
- **東京駅**（`~/Documents/flix_ge_workspace/plateau_city`）: PC で「1 棟ずつ」（今 137 ms・目標は R2a で 100 ms 以下、P9 で 16 ms 以下）と「建物をつないだ版」（今 3.0 ms）を、GL と WebGPU で測る。
  ブラウザとスマホは、絵が約 784 MB で今のままでは開けない（4.4）。絵を縮めた版か範囲を絞った版を作って「多少は確認できる」所まで持っていけるかを、P9 の後に試す（作れるか・何 MB まで落とせるかは【未確認】）。
- 3D の段（P5・V2）の前に、スマホで WebGPU の limit と feature の一覧を取る小さな頁を開いてもらう（P0 の残り）。

### 12.15 形のレビュー（2D）と R1b-0（2026-11-15・この Mac だけ）

- 判断 13 で 5.1 の表を改めた（上の 5.1 の「判断 13 で改めた所」）。名前は `RenderList`（11 章の 7）。6.1 の決まり 6 は「行と頂点は 1 コマぶんを 1 本に詰める（upload は除く）」へ書き直した。
- R1b-0 で入れた物: 行の型と GL の流し方を `RenderFrame.Internal.RenderList`・`GlRows` へ出した・front-end の状態（`st`）と backend の状態を分けた・instance と頂点の入れ物は backend が貸す・
  描き先の上下は backend に聞く（`targetUpsideDown`）・`PassSpec`・ensureTexture の表と upload の関数の record（`TextureTable`）・PC の `FLIX_GE_FRAME_STATS` に 1 コマの submit が 2 回以上のコマの数。
  絵は gl-parity・テンプレの reference・gl-capture・webgpu-v1-check（PC とブラウザ）で前と同じ。sprite_stress は前と後で 5% の内。
- 3 章と食い違った所と持ち越しは `webgpu-shape-review-2d.md` の 7 章（`FrameArgs` が pub なので `targetNames`・`targetClear` が残る・描き先の表と `lastFrame` は共有していない・
  読み込みの record・`copyImageBitmap`・sprite_stress の JSON の `submits` は engine の拡張の相談）。

### 12.16 相談事の決め（人の「おまかせ」・2026-11-15）

- submit の回数を engine の pub の `FrameDiagnostics` に足す件: 今は足さない。テンプレ 3 本の最初の場面で submit が 2 回以上のコマは 0 で、staging の判断に今すぐ要らないため。P6 で staging を比べる時に要れば、その時に足す。数は PC の `FLIX_GE_FRAME_STATS` で見られる。
- `gl-capture` の基準（0.88.4 と違う 30 枚）: 今は撮り直さない。P10 で Dawn の版を pin して基準を撮り直す予定なので、そこでまとめる。それまでは「30 枚のまま増えない」を門にする。
- 速さの計測（人の方針・2026-11-15）: 計測の仕組みと基準は P0〜R1b-0 でそろったので、ここから先の小分けでは sprite_stress などの前後の比べ（5% の門）を回さず、計画の最後（P10 の前）にまとめて測る。画素の門（gl-parity・reference・gl-capture-check・webgpu-v1-check と -web）とテストは小分けごとに回す。最後の計測で 5% を超えて遅くなっていたら、どの小分けで遅くなったかを二分探索で探す。

### 12.17 P5 の前半で入った物（2026-11-15・この Mac・Dawn の Metal だけ）

- **WGSL の出し方は「書き手を挟む」に決めた**（9.1 の表）。式の組み立て（`ShaderGen.fieldExpr` ほか 257 行）は GLSL と 1 本のまま、言葉で字が違う所（`atan`・`textureSize`・`texture`・`textureLod`・宣言の頭・`smoothstep`）だけを小さな関数に寄せた。
  WGSL 用に 2 本目を書く形は、試した 3 節で 27 行・全部で約 320 行の写しになり、節を足すたびに 2 か所を直す。GLSL を訳す形は、jWebGPU（webgpu.h）の `createShaderModule` が WGSL と SPIR-V しか受けず、
  ゲームの `ShaderDoc` は走りながら変わるので訳す道具をブラウザ（wasm）へ運ぶ事になる（Tint が GLSL を読めるかは【未確認】）。文の形が違う物（ノイズの関数・ぼかし・mip を選ぶ読み・3D の frag の組み立て）は WGSL で書き足した。見本は `plans/webgpu/samples/wgsl-codegen.md`。
- **面と材質の draw ごとの値の並びは「ShaderGen が struct を出す」に決めた**。欄は全部 f32 の `SgValues`（`var<uniform> sg`）で、`slots` の i 番目が buffer の i × 4 バイト目。名前は GLSL の uniform と同じ。
  場面で共通の値（光・影・霧・空・環境マップ）は手で書いた `R3dScene`（`Render3dWgsl`）。見本は `plans/webgpu/samples/material-layout.md`。
- 入れた物: engine の `ShaderGen.Wgsl`（2D の面 `compile`・3D の材質の部品 `compile3d`・ノイズの関数・`sg_texMip`・`sg_clipFromGl`）・`LightModel3d.Codegen` の `Target.Wgsl` と `toWgsl`・`Texture3d.srgbToLinearWgsl` / `linearToSrgbWgsl`。
  render_gl の `Render3dWgsl`（材質の frag・頂点の色の frag と、それが使う影の PCF・TBN・環境マップ・lightmap・`r3d_surfaceOut`）。GLSL の字は 1 文字も変えていない。
- 7 章の引っかかる所の手当て（出す側で）: clip の z は頂点シェーダーが `sg_clipFromGl`（z を -w..w から 0..w へ）で移し、射影と影の行列は GL の物のまま（奥行きの値が GL と同じになり、影の比べ `ndc.z × 0.5 + 0.5` はそのまま）。
  描き先の上下は、WGSL では `uTexFlip`・`uNormalFlip` を持たない（WebGPU の描き先の texture は上の行が先）。影の地図だけは、画素を GL の数え方で決めて端にそろえてから、読む時に行を返す。
  微分は 3D の `sg_texMip` の中だけで、2D の面の読みは `textureSampleLevel(…, 0)`（ぼかしの半径 0 の分岐の後で読むため）。暗黙の型変換は `f32(…)` を書く。uniform の f32 と vec2 の光の配列は vec4 の配列に入れた（16 バイト刻み）。
  端が定数で等しい `smoothstep`（Disk の feather 0・同じ位置の stop）は Tint がシェーダーを作る所で止める（`smoothstep called with 'low' (0.5) equal to 'high'`。x が定数でなくても）ので、WGSL は `sg_smoothstep`（CPU と同じく端が等しければ step）を通す。
  `select` は選ばない側も計算するので、関数の呼び出し（影の PCF）がある側は if の文にした。R8 の swizzle と RGB8 は上げる側（backend）の事で、出す字には関わらない。
- 検査: render_gl の `TestWgslDawn` が PC の Dawn で **364 本**（2D の面 25・材質の部品 13・3D の材質の frag 324（絵を読む材質と頂点の色の材質は ProgramKind の 96 組・ほかの 11 の材質は 12 組）・lit と空 2）を組んで誤り 0。2D の面は pipeline まで作る。
  組まずに通すのは Dawn のネイティブが無い OS と adapter が無い機械だけ（`[wgsl] SKIP:` の行を出す）。ほかの理由で device が開けなければ落とす。
  GPU に頼らない検査: 同じ 364 本に GLSL にしか無い字（`float(`・`texture(`・` ? `・`mod(` など 12 種）が 0 個（`testGeneratedWgslHasNoGlslOnlyText`）。2 本書きの組（ノイズの関数・ぼかし・mip を選ぶ読み・割り算・影の PCF・TBN・環境マップの読み）は、数のリテラルを出てくる順に抜いて GLSL と WGSL で同じ（`TestShaderGenWgslPairs`・`TestRender3dWgslPairs`）。
  値の比べ: `make -C bench/gl_parity wgsl-rows` が同じ面と材質を GL と WebGPU で 256 × 1 の RGBA32F に塗って比べる（2026-11-15・Apple M4 Pro・macOS 27 の GL と Dawn の Metal）。最初の 59 行のうち 41 行は差 0・最大 1.5e−5（テンプレの caustics。sin に大きな引数が入る節で、GL の driver と Tint の MSL で丸め方が違う）・lava 1.2e−5。上限 1e−4。
  60 行目は 2 つのレベルの色が違う絵を mip のレベルが行の中で移る座標で読む材質で、r が変わらなければ落とす（mip を選ばずに読んでいないかの確かめ）。
- **GPU の無い機械では Dawn に届かない**: jWebGPU 0.3.4 の Dawn に Null の backend が無い（`requestAdapter` が `No supported adapters`）。`TestWgslDawn` が組まずに通すのは、Dawn のネイティブを配っていない機種（`DawnNatives` の「この機種の WebGPU のネイティブはまだ配っていない」。今は macOS の arm64 だけに配る）と adapter が無い機械だけで、`[wgsl] SKIP:` の行を出す。ほかの理由で device が開けなければ落ちる。Linux の CI はネイティブが無いので SKIP になる。
- `agents-pack` の早見表と agent-eval には足していない: `ShaderGen.Wgsl`・`toWgsl`・`Render3dWgsl`・`wgsl-rows` はゲームが呼ばない engine の中の口（ゲームは今までどおり `ShaderDoc` を書くだけ）。
- 持ち越し（P5 の後半）: 3D の頂点シェーダー（骨・instance・lightmap の uv）・ビルボード・空・奥行きだけ・貼り付けの WGSL、2D の組み込みの残り（多角形・タイル・単色の代わり）、`R3dScene` を詰める所と光の式の値の比べ（ExprRows の WGSL 版）、
  3D の frag の pipeline と bind group layout まで作る検査、言葉の印を表の鍵（`@mode:wgsl`）で運ぶ形を enum の文脈へ替える事、f32 に収まらない定数（`Pow` の定数の積など）、
  2D の面の絵に mip が付いた時の読み（今はレベル 0 に決めている）、影の地図を描く頂点シェーダーも `sg_clipFromGl` を通す約束。
  P6 の頭で: `R3dScene` の欄の offset のテスト（詰める所と組で。mat4 の前は pad0〜pad2 で埋めてある）。f32 に収まらない `Const` を `ShaderDoc` の parse で弾くか丸める（今は WGSL の側でシェーダーを作る所の誤りになる）。

### 12.18 R1b-2: 多角形とタイルと static layer（2026-11-15・この Mac・Dawn の Metal だけ）

表の 8 行目の 2 つ目の種類。GL で多角形・タイルの層・static layer の範囲を `RenderList` の行にし（GL を直に呼ぶのは面・mask つきスプライト・3D の場面だけになった）、同じ行を WebGPU の backend に流した。

- **決めた事 1 — draw ごとの値の置き場**: `RenderList` に `values`（Float32 の配列・前半の持ち物）を足し、行の欄を 10 → 12 にした（10 = 頂点の buffer の番号・11 = values の先頭）。
  タイルの層は 8 個（position・tileSize・tileScale・color）、多角形と static は view の 6 個（viewOffset・viewScale・halfDesign）。values の頭の 6 個はいつも identity の view で、動く多角形の行はそこを指す（多角形と static が shader 1 本・GL の関数 1 本になる）。
  比べた別の案は「行は元の record の番号だけ持ち、record の列を横に置く」: GL は今の uniform の差し方のままで済むが、WebGPU に record をほどいて float に詰め直す 2 本目ができ、P9 の持ち越しと JS へ 1 回で渡す形（形のレビュー 3.5）に乗らない。見本は `plans/webgpu/samples/per-draw-values.md`。
- **決めた事 2 — WebGPU で draw ごとの値を shader へ渡す形**: values をコマに 1 回 `writeBuffer` し、**stride 0 の instance の頂点の buffer**（頂点の buffer の 1 番）として読み、行ごとに `setVertexBuffer` の offset だけ替える。
  別の案は「uniform の buffer を 256 バイトの枠に割って枠ごとの bind group を作り置く」と「dynamic offset」。前者は bind group の数が 1 コマの draw の数を追い、1 draw 256 バイトに広げる。後者は `render_gl/java` の `WebGpu` の口（`setBindGroup` の offset）を足す事になり、GL の層の jar のハッシュとブラウザの JSO の実装が動く。
  前者は `bench/webgpu_check` に形だけの門 `uniform-slot-bind-groups`（8 draw）を足して PC の Dawn と headless の Chrome で動かした: 動くが bind group が draw の数（8 個）だけ要り、1 draw 256 バイト（中身 20 バイト）。dynamic offset は道具の口が変わるので試さずに捨てた。
  入れた形は Dawn の Metal で 5 場面とも GL と 0 px。stride 0 の形そのものも門を 1 本足し（`stride0-instance-attribute`: offset を替えた 2 つの draw・firstInstance 3 でも同じ要素を読む）、PC の Dawn と headless の Chrome の両方で通した。
  **ブラウザで確かめたのは headless の Chrome（Metal）だけ**で、Safari と Firefox（wgpu の Metal での stride 0）は【未確認】。ブラウザで多角形とタイルの絵を GL と比べる門もまだ無い（ブラウザの門は rpg の題名の画面だけ）。
- **頂点の buffer の寿命**: R1b-1 の「表は前半・作る消すだけ backend」に載せた（比べ直していない）。タイルの層は `RenderPaint.Internal.TileTable`（作った番号 → 入る枚数・入れ直すか大きくするか作るか・1 枚 10 個の並び）と `TileAllocator{create, write, grow}`。
  大きくする時も番号（ゲームが持つ `GpuHandle.TileVao`）は変えない（`Platform.GpuResources.updateTileBuffer` の約束「VAO を増やさない」と engine_world の `TileCache` のまま。GL は `glBufferData` で VBO が大きくなるだけ、WebGPU は同じ番号のまま buffer を作り直して表を差し替える）。
  static layer は `RenderStatic.resolve` が `StaticAllocator{create, destroy}` を受ける形にした（鍵が替われば古い方を捨てて作り直す・`release`）。`RenderStatic.Range#vao` は `buffer`（backend の表の番号）にした。
- 入れた物（render_gl の中だけ・engine の pub は増えていない）:
  - 前半: `RenderList.appendPolyRow`・`appendTileRow`・`appendStaticRow`・`values`・`nextVertexOf`。`RenderFrame.emitRowItem`（行になる種類を積む・GL と WebGPU が同じ物を呼ぶ）・`closeRuns`・`flushRows`（GL を直に呼ぶ種類の前だけ行を流す）。多角形の run は front-end の状態だけで持つ（頂点の先頭の番号を st の 40 番に）。
  - GL: `GlRows.drawRow` が種類で分かれる（`drawPolyRow`・`drawTileRow`・`drawStaticRow`）。uniform の location は GL の状態の配列（gs の 12〜19）に置き、`RenderSprite.drawPolygonRange`・`drawStaticRange`・`drawTileMapInstanced` が values の位置から差す。
  - WebGPU: `WebGpuShader.polyWgsl`・`tileWgsl`（対の GLSL と 1 行ずつ同じ式）・pipeline の鍵に形（スプライト・多角形・タイル）を足す・instance / 頂点 / values の 3 本の `Stream`（どれかが空きに入らなければ先に submit して 3 本とも頭から送る）・
    タイルと static の buffer の表・`initTileBuffer`・`updateTileBuffer`。Pass へはタイルと static を乗せない（GL の `paintTarget` と同じ）。起動の時に作る pipeline は 3 本 → 7 本（スプライトと多角形の blend 3 つずつとタイル 1 本）。
- 振る舞いの変化（絵は変わらない）: GL の多角形の run は、スプライトが来るたびに GL へ流していたのが、行として溜めて GL を直に呼ぶ種類の前（か pass の終わり）にまとめて流す。GL の呼び出しの並びは変わるが、draw の順と数・数え方は同じ。
- 門（この Mac・2026-11-15）: 下の 7.7（`webgpu-shape-review-2d.md`）。
- 3 本の `Stream` の送り方（どれかが入らなければ submit して 3 本とも頭から・頭からでも入らない本は伸ばす）は純粋な関数 `planUpload` に出し、GPU 無しのテスト 3 本（`TestUploadPlan`）と、Pass と本編に 12,600 頂点ずつ置く場面 `polygonFlood`（submit 2・0 px）で確かめた。
- WebGPU でタイルの数が buffer に入っている枚数より多い時と、static の範囲が buffer の外へ出る時は、入っている分だけ描いて 1 回知らせる（buffer の外を読む draw は pass ごと誤りになり、コマ全体が消える）。
- 持ち越し: `bench/webgpu_v1` の 5 場面をブラウザでも回す口・Safari と Firefox での stride 0・面（P5 の後）の行・mask（比べる値・8 章）・history と MSAA の resolve。タイルの層の buffer は捨てる口が無い（層ごと要らなくなった時の口は `GpuResources` に無く、足すなら engine の pub の拡張。GL も前から捨てない）。
  engine の `GpuHandle.StaticVao`・`wrapStaticVao`・`staticVaoInt`・`staticVboInt` は使う所が無くなった（render_gl は static の buffer を番号 1 つで持つ）。消すのは engine の pub の変更なので相談事として残す。

### 12.19 R1b-3: history と MSAA の resolve（2026-11-15・この Mac・Dawn の Metal だけ）

表の 8 行目の 3 つ目の種類。前半が「pass を開く前の history の始末」と「pass の終わりの resolve」を `PassSpec` で決め、GL と WebGPU の backend はその答えをそのまま実行する形にした。
history の寿命（作る・形が変われば作り直す・描き先を作り直す時に捨てる）は R1b-1 の `TargetTable` のまま（比べ直していない）。

- **決めた事 1 — history は毎コマ写す**: 前半の `TargetTable.historyFor`（読むか・前のコマを持つか → `PassHistory.CopyTo(n)`・`ClearTransparent(n)`・`NoHistory`）が `PassSpec#history` を決める（R1b-0 で欄だけ置いた `copyHistory` を enum にした）。
  別の案「2 枚を描き先と history で毎コマ入れ替える」も WebGPU で動かした（Clear の描き先だけ入れ替え）。絵は同じだが、LoadOp.Keep の描き先は写しが要るので道が 2 本になり、
  名前 → 表の番号が毎コマ動くので標本つきの描き先を付け替える行が要った（GL は `RenderTargetGl.Entry` を割る作り替えが要る）。得は Clear の描き先で写す pass が 1 本減る事で、P10 の前の計測で写しが見えたら Clear の描き先だけに足す。
- **決めた事 2 — MSAA は pass の終わりごとに resolve する**: `RenderList.targetPass` が標本 2 以上の時だけ `ColorAttachment#resolveTo` を入れる。WebGPU は pass の `resolveTarget`、GL は `RenderPaint.paintTarget` の pass の終わりの blit（前は `endTarget`）。
  別の案「endTarget で 1 回」も WebGPU で動かした（空の pass の resolveTarget）。絵は同じで、標本つきの描き先 1 枚あたり pass が 1 本増える。
- **決めた事 3 — WebGPU で history へ写す道具は描いて写す**（present と同じ WGSL の全面の三角形・形式ごとの pipeline 1 本）。別の案 `CommandEncoder.copyTextureToTexture` を `render_gl/java` に足して PC の Dawn で動かした（絵は同じ・Flix は約 25 行少ない）。
  jar のハッシュとブラウザの実装と Release の置き場が動くので今は入れず、staging（`copyBufferToTexture`）で jar を開ける時に替える。
- **標本の数の決まり**: `RenderList.drawSamplesOf`（頼まれた数を超えない、backend が描ける一番大きい数。ただし 2 以上を頼まれてそれが 1 になる時は、描ける 2 以上の一番小さい数へ上げる）。
  GL は 1・2・4・8 のうち `GL_MAX_SAMPLES` 以下（前と同じ答え）、WebGPU は 1 と 4（core の device が必ず持つ数）なので、**WebGPU は標本 2 を 4 で描く**（8 は 4）。
  1 回目のレビュー（84 点）で「2 を 1 にするのは engine の `RenderTarget.withMsaa` の doc（1・2・4・8 に下へ丸め・GPU の上限で頭打ち）の範囲と言えない（4 が描けるのに MSAA が消え、backend で絵が変わる）」と指摘され、
  親が相談事として (b)「WebGPU では 2 を 4 に上げる」に決めた。2 を 4 で描く時は名前ごとに 1 回 `Log.fellBack`。
  engine の `withMsaa` の doc に「WebGPU の描き手は 1 と 4 しか描けないので、2 は 4 で描く」を 1 行足した（人の「おまかせ」・型と動きは変えない）。
  `bench/webgpu_v1` の `msaaTwo`（標本 2）は GL（2 標本）と WebGPU（4 標本）で縁の画素が違うので、許す差を 56/255 にして理由を `tolerance.tsv` に書いた（既定 0 の例外）。
  代わりに、WebGPU の `msaaTwo` の絵が標本 4 の `msaaPass` と画素まで同じ事を Main が見る。
- **GL と比べて分かった事**: GL の描き先は上下逆に格納されるので、標本の位置が中身に対して上下に返り、**斜めの縁の MSAA は GL と WebGPU で 1〜2 標本ずれる**（多角形の場面で 89 px・最大 ±51）。
  軸に沿った縁は一致する（標本の x の組と y の組が上下に返しても同じ）。MSAA の門の場面は端数の位置の箱と四角形の多角形にし、端数は画素の中心と標本の位置を避けた（ちょうど乗ると標本 1 でも最大 ±224）。
  9.1 の表の「PC の cutout の縁」（MSAA の縁の絵を今の GL と比べる）は、斜めの縁を GL と画素で比べられないので、P8 で門の形を決め直す。
- 入れた物（render_gl の中だけ・engine の pub は増えていない）:
  - 前半: `RenderList.PassHistory`・`TargetColor`・`resolveTargetOf`・`drawSamplesOf`・`targetPass` の引数（標本の数と history）・`TargetTable.historyFor`・`spritesReadHistory`。
  - GL: `RenderPaint.applyHistory`（`prepareHistory` を置き換え・写すか塗るかは前半の答え）・resolve を pass の終わりへ・描く標本の数は `glTargetAllocator` が `RenderTargetGl.sampleCounts` と `drawSamplesOf` で決めて `createWithSamples` へ渡す・
    `GlOffscreen.withHistoryKept`（render_gl の pub を 1 つ足した。窓と同じく history に前のコマを写す session。`bench/webgpu_v1` が GL と WebGPU の写しを比べるのに使う）。
  - WebGPU: history（`applyHistory`・`copyInto`・`copyGroupOf`（写す元の bind group は描き先を捨てるまで使い回す）・`copyPipelineOf`。history を読むスプライトを「まだ描かない」で捨てていたのをやめた）・
    MSAA（標本つきの描き先と標本の数 `msaaTargets`・pipeline の鍵に標本・`openPass` の `resolveTo`）。
    WebGPU の描き手は窓とその撮影でしか動かないので、1 枚撮りの「history は毎回透明」（GL の `keepHistory = false`）は持たない。
- 門（この Mac・2026-11-15）: `webgpu-shape-review-2d.md` の 7.8。
- 持ち越し: ブラウザでの history と MSAA の絵の門（`bench/webgpu_v1` の場面をブラウザで回す口が無い・R1b-2 から）・Safari と Firefox・history の入れ替え（P10 の計測次第）・copyTextureToTexture（jar を開ける時）・
  P8 の cutout の縁の門の形・1 回の begin〜end に renderCommands が 2 回来る時の resolve が 2 回になる事（今のゲームには無い）。
  （P10）標本つきの pipeline は初めてその Pass を描くコマの中で作る（ブラウザの試作で 1 本 65〜93 ms・4.3）ので、そのコマが詰まる。本当に避けるには読み込みの間に作る。
  その時は 2 回目の renderCommands が history を読むと、写るのは前のコマの最後でなく、同じコマの 1 回目を描いた後の中身になる（GL も前から同じ）。

### 12.20 R1b-4: mask（比べる値を進める形・2026-11-15・この Mac・Dawn の Metal だけ）

表の 8 行目の 4 つ目の種類。mask つきスプライトを `RenderList` の行（`kindMask`・1 体 = 1 行）にし、GL を直に呼ぶ種類は面と 3D の場面だけになった。同じ行を WebGPU の backend に流した。
8 章の「stencil は残し、mask ごとに比べる値を 1 ずつ進める」を GL と WebGPU の両方の形にした（GL も mask ごとの stencil の clear をやめた）。

- **決めた事 1 — 比べる値は前半が進めて行に書く**: `RenderList.nextMaskRef`（前の値 → 次の値。1 から 1 ずつ・255 の次は 1）を前半の `pushMaskedItem` だけが呼び、行の 11 番に書く。
  値 1 の行の前で backend は stencil を全部 0 にする（pass の頭か 255 を使い切った後）。前の値は front-end の状態（`st` の 41 番）に pass ごとに持つ。
  別の案「GL と WebGPU の backend がそれぞれ数える」も動かした（mask の 5 場面とも GL と 0 px）。決まりが 2 か所に分かれ、GPU 無しのテストで固定できないので取らなかった。
  形のレビュー（2D）の 3.1 の 9 と 3.2 の終わりは「比べる値を進めるのは backend の中」と書いていたが、ここで前半へ寄せた。見本は `plans/webgpu/samples/mask-stencil.md`。
- **決めた事 2 — 255 を超えた時、WebGPU は pass の中で stencil を 0 に戻す**: design の全面（1 px ずつ外へ広げた）6 頂点を、mask を書く pipeline に比べる値 0 で描く（`WebGpuRows.resetStencil`）。
  別の案は 8 章の「pass を分ける」（区切りごとに閉じて、色は前の中身のまま・stencil は clear で開き直す）。動かして 5 場面とも 0 px だったが、pass が 255 個ごとに 1 本増え、
  標本つきの描き先は閉じるたびに resolve し、画面の pass を「前の中身のまま」で開く形（今の `PassSpec` の `Screen` は clear しか持たない）と控えの張り直しが要る。
  GL は値 1 の行の前で scissor を外して `glClear(STENCIL_BUFFER_BIT)`。
- **WebGPU の stencil の attachment**: 前半が行に stencil を使う mask を積んだ時だけ（`RenderFrame.usesStencil`）、`PassSpec#depthStencil` を `DepthAndStencil` にして pass を開く（3.2 のとおり）。
  形式は `DEPTH24_PLUS_STENCIL8`（`render_gl/java` の Dawn の実装は depth の LoadOp をいつも書き、WebGPU は depth の無い形式にそれを書くと誤りにする。`STENCIL8` は試していない）。描き先ごとに 1 枚（中間の texture は鍵 0・Pass は表の番号）、
  初めて mask を描く pass で作り、大きさか標本の数が違えば作り直し、描き先を捨てる時と `release` で捨てる。標本 4 の Pass は stencil も標本 4。
  mask を書く draw は blend を (0, 1) にして色を変えない（`render_gl/java` の `RenderPipelineDesc` に色の書き込みの mask の口が無いため）。
- **pipeline**: 鍵に stencil の使い方（`WebGpuRows.stencil*`: None・Keep・Write・Equal）を足した。起動の時に作る物は 7 本 → 18 本（RGBA8・標本 1 の stencil 無しと Keep のスプライトと多角形の 3 本ずつとタイル 1 本・
  Equal のスプライト 3 本・Write の多角形 1 本。3.2 の「両方を読み込みの間に作っておく」）。初めて mask が出たコマで作ると、Dawn は作り終えるまで待つのでそのコマが詰まり、
  stencil つきの pass では mask の無い行まで Keep の pipeline に替わるので、スプライトと多角形とタイルの分も要る（12.19 の標本つきの pipeline と同じ言い方）。
  **ブラウザの起動が 11 本ぶん重くなる**（試作で 1 本 65〜93 ms・4.3）は測っていない。
- **GL の mask つきの面**: 面は今も GL を直に呼び、自分で stencil を 0 にして 1 を書く。そこで mask つきの面を描いた後は前半の前の値（`st` の 41 番）を 0 にし、次の mask の前に stencil を 0 に戻させる。
  「この pass に stencil を使う行を積んだか」は別の欄（42 番）に持ち、面の後も真のまま（`usesStencil` が読む）。WebGPU は面をまだ描かない。
- 入れた物（render_gl の中だけ・engine の pub は増えていない）:
  - 前半: `RenderList.kindMask`・`appendMaskRow`・`maxMaskRef`・`nextMaskRef`・`RenderFrame.pushMaskedItem`・`spriteCaps`（体数と mask の頂点の数を 1 回の周回で数え、入れ物を先に広げる）・`usesStencil`。
    `emitRowItem` が mask つきも行にする。WebGPU の `emitItem` は面と 3D の場面を受け取らない（`mergedByZ` に渡さない）ので、知らせて飛ばす枝を消した。
  - GL: `GlRows.drawMaskRow`・`RenderSprite.writeMaskVerts`・`clearStencil`・`drawSpriteMaskedRange`（`drawSpriteMasked` を置き換え・mask の頂点は多角形と同じ入れ物から `drawPolygonRange` で流す）。
  - WebGPU: `WebGpuRows.drawMaskRow`・`resetStencil`・`bindStencilPipeline`・`bindStencilRef`。pipeline と stencil の表は `WebGpuPaint` から新しい `RenderPaint.Internal.WebGpuPipelines`
    （`pipelineOf`・`buildStartupPipelines`・`describeStencil`・`stencilOf`・`dropStencil`・`createResetQuad`）へ分けた。`openPass` は `PassSpec` を受ける。
- 振る舞いの変化（絵は変わらない）: GL は mask ごとの stencil の clear が pass の頭と 255 個ごとの 1 回になった。mask つきスプライトの instance は 0 番に書き直さず、行の列の中に書く。
  draw の数え方は前と同じ（mask つきは 2・三角形にならない mask は 1）。
- 門（この Mac・2026-11-15）: `webgpu-shape-review-2d.md` の 7.9。
- `bench/webgpu_v1` の `unsupported` は、mask つきスプライトが描けるようになったので、中身を面（ShaderDoc）1 つと 3D の場面に差し替えた（2 コマ渡して、名前ごとに 1 回だけ知らせ・WebGPU の誤り 0）。
- 持ち越し: ブラウザで mask の絵を GL と比べる門（`bench/webgpu_v1` の場面をブラウザで回す口が無い・R1b-2 から）・
  `spriteCaps` が毎コマ全部のスプライトの mask を数える分（P10 の前の計測で）・面に mask を付ける時に比べる値を面の行にも持たせるか（面の小分けで）。
  - `render_gl/java/fge/webgpu/dawn/DawnWebGpu.java` の 590 行目は stencil を Store で書き出すが、pass の後に stencil を読む物は無いので捨てる設定（Discard）で足りる（jar に触るので今は直さない）。
  - 起動の時に作る pipeline が 11 本増える重さは、mask を使わないゲームにも掛かる。P10 の前に測り、重ければ非同期で作る案（8 章の pipeline の行）と比べる。

### 12.21 R1b-5: 3D の場面を貼る（2026-11-15・この Mac・Dawn の Metal だけ）

表の 8 行目の 5 つ目の種類。3D の場面を貼る所を `RenderList` の行（`kindScene3d`・1 番 = 場面の番号）にし、GL と WebGPU の backend が同じ行を流す形にした。GL を直に呼ぶ種類は面だけになった。
WebGPU で場面そのものを描くのは V2・P8 なので、WebGPU の backend は貼る行を z の位置まで並べてから描かずに知らせる（「まだ描かない: 3D の場面」を 1 回）。

- **決めた事 1 — GL は行の所で場面を直に描く形を残す**（`webgpu-shape-review-2d.md` の 3.0 の「今どおり 2D の途中で場面を直に描く形を残すか」）。
  GL の backend は貼る行で `Scene3dRenderer.Prepared#draw` を呼び、Native の解像度の場面は今どおり描き先へ直に、Design の解像度の場面は先に描いた texture を貼る（`Render3d.drawItem` は変えていない）。
  別の案「Native の場面も先に自分の texture（場面の矩形の画素の大きさ・透明から）へ描いて、Design と同じく α を掛けた後の値として貼る」を GL で動かした（`drawItem` の Native の枝だけを書き替えた試し・commit していない）:
  `gl-parity` は msaaEdges が 652 px → 3,362 px（許容 1,200）で落ちた（中間の texture は標本 1 で、標本 4 の Pass の中の場面の MSAA が消える）。ほかに mipFloor・mipFloorScaled が 724 → 722 px・spotSoftEdge3d が 26 → 23 px と、
  GL の絵が SoftRaster との差の中で動いた（中間の 8 bit で丸めてから重ねるため）。`gl-capture` の bench/scene3d は 6 枚のうち 1 枚が 1 px・±1 違った。
  合わせるには中間の texture も標本つきにして resolve する道と、場面ごとの描き先の付け替えと全面の貼り 1 回が要る（5.4 の「代金は場面 1 つにつき全画面の貼り 1 回」は WebGPU の話で、GL に払わせる得が無い）。
  親 5.4 の「3D は先に自分のテクスチャへ描き、z の位置で貼る」は WebGPU の形で、今は WebGPU が場面を描かないので崩れていない。GL の形は 3.0 のとおり backend ごとに選べる。
- **決めた事 2 — 貼る行の欄は場面の番号だけ**。5.1 の表の欄（場面の描き先の番号・矩形）のうち、矩形と clip は番号で引く場面の命令（`Scene3d.RenderCmd`）が持ち、GL は `Render3d.drawItem` がそこから出す。行にも写すと 2 か所が食い違いうる。
  描き先の番号は、V2 で WebGPU の前半が場面の組（`(PassSpec, 行)`）を 2D の組の前に作る時に、行の 3 番（絵の番号）へ入れる見込み。矩形を行に要るのもその時で、`planScenes` を `gl` から外す R2a の後になる。
- **決めた事 3 — WebGPU の「1 回知らせて捨てる」を行の道へ移した**。前は `handleDraw3d` が場面をその場で捨てていたので、WebGPU の 2D の並びに場面の z が無く、場面を挟んだスプライトの run が GL と違う所で切れた（draw の数が GL と合わない）。
  今は `WebGpuPaint` が GL の `RenderPaint` と同じく場面を溜め（`pendingScenes`）、`renderCommands` で `mergedByZ` に場面の z を渡し、貼る行で `skip` して数え（`countSceneRow`。次の 2D の draw call が kind で切れる）を GL と同じにする。
  先に上げる物の宣言（`preload3d`）は今どおり捨てる（知らせの名前は「3D の場面の preload」に分けた）。
- **`emitItem` の `discard emitRowItem(...)`（R1b-4 のレビューの持ち越し）**: 場面は行になる（`emitRowItem` が真）ので、偽が返るのは面だけになった。WebGPU は面を `mergedByZ` に渡さないので今は通らない。
  面の小分け（P5 の後）で面も行にし、そこで `emitRowItem` の Bool をやめる（skip にも bug! にも戻さない）。それまでの間に面を `mergedByZ` へ渡す変更が入ると黙って捨てるので、面の小分けの最初に Bool をやめる。
- 入れた物（render_gl の中だけ・engine の pub は増えていない）:
  - 前半: `RenderList.appendSceneRow`・`emitRowItem` の `MScene3d` の枝（run を閉じて行を足す）・`RenderFrame.countSceneRow`。`emitOne` の場面の枝と、場面の前の `flushRows` が無くなった。
  - GL: `GlRows.drawSceneRow`。`drawRenderList`・`flushRows`・`emitMerged`・`emitOne` は場面を番号で描く関数（`Int32 -> Unit`。viewport と倍率は `emitFrameMixed` が 1 回だけ閉じ込める）を受ける。
  - WebGPU: `WebGpuRows.renderFrame` の `sceneZs`・`drawSceneRow`・`WebGpuPaint` の `pendingScenes`（`RenderPaint.Frame#scenes` に入れ、Pass の中の場面も同じく並べる）。`WebGpuPaint.flix` は 1,015 行。
- 振る舞いの変化（絵は変わらない）: GL は場面の前で溜めた行を流さず、場面の行も同じ列で流す（GL の呼び出しの順は同じ・instance と頂点の入れ物の位置が場面の後も頭へ戻らないだけ）。draw の数え方は同じ。
- テスト: `TestShapeRows` の「3D の場面は行にならない」を「行になる」へ替え、場面の番号の欄・スプライトと多角形の run を場面の前で閉じる事・GL の backend が行の順に場面の番号で描かせる事（何も描かない GL）の 4 本を足した。
  1 回目のレビュー（87 点）の必須を受けて、「同じ箱・場面・同じ箱」を GL の backend で流し、場面を描く callback の中で draw call の数が 1（前の箱だけ）・終わりで 2・kind の切れ目が 1 になる事を見る 1 本を足した。
  `TestMaskRows.testMaskAfterMaskedSurfaceRestartsRef` に「面の所で flushRows が列を空にするので、残る行 0 が面の後の mask」と前提を 1 行書いた（R1b-4 のレビューの持ち越し）。
- `bench/webgpu_v1` に `sceneBetween`（同じ色・同じ blend の 2 つの箱の間に、何も置かず地の色も無い 3D の場面・その後に市松の絵）を足した。GL では場面が画素を変えないので GL と比べられ、
  場面の行の後の 2D が前と同じ状態（blend・scissor・viewport）で描かれる事を見る。WebGPU は場面を描かずに知らせる。
  2 つの箱の run が切れる理由は場面だけにしてある。Main は場面ごとに GL と WebGPU の 2D の draw の数（数と切れた理由 6 つ）を比べ、違えば落とす（GL は `GlOffscreen.lastDraw2dCounts`・WebGPU は `WebGpuPaint.lastDraw2dCounts` を足した）。
  `sceneBetween` は期待（箱・箱・市松の絵の 3 本・kind 1・texture 1）とも比べる（`V1Main.expectedDraws`）。場面が run を切らなければ箱 2 つは 1 本にまとまり、落ちる。
- `bench/gl_parity` に `sceneBetweenBoxes`（地の色が不透明な場面を、重なる同じ色・同じ blend の 2 つの箱で挟む。前の箱は場面の下・後の箱は上）を足し、SoftRaster とバイトで比べる（A 段階）。
  2 つの箱が場面をまたいで 1 つの run になると、後の箱も場面より先に描かれて隠れ、重なりの 40 × 40 が地の色になる。
- 門（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal・2026-11-15）:
  - render_gl のテスト 437 緑（`.layers/render_gl` の flix test。前の 432 から「場面は行にならない」1 本を替え、5 本を足した）。偽の GL を通る `TestDrawCounts` の「場面がスプライトの間で kind で切る」はそのまま緑。
  - `make gl-parity` 緑。足した `sceneBetweenBoxes` は A 段階で 0 px。ほかの場面の行は変える前と 1 字も同じ（castShadow の 565 px は前からの B）。
  - `make webgpu-v1-check` 緑（後半の rpg の題名の画面の窓の 2 回撮り・GL との比べ・gl_parity の V1 の場面まで）: 28 場面とも許す差の内で、2D の draw の数と切れた理由も 28 場面とも GL と同じ。
    `sceneBetween` は 0 px・submit 1・draw 3（kind 1・texture 1）で期待どおり。WebGPU の誤り 0・「まだ描かない: 3D の場面」は 1 回。
  - `make webgpu-v1-check-web` 緑（WebGL2 と 0 px・WebGPU の無い頁 0 px・PC と 22 px ±1 で前と同じ）。
  - `make gl-capture-check`: a と b の 54 枚がバイトまで同じ。基準 0.88.4 と違うのは 30 枚（前と同じ数・同じ 5 場面）。bench/scene3d の 6 枚は変える前の木で撮った物とバイトまで同じ。
  - テンプレ 3 本の `reference-check` 緑（rpg 16・novel 43・tidepool 8）・`make lint-huge-methods` 緑（sprite_stress の jar を作り直し、`bench/webgpu_v1` と bench/scene3d の jar も渡して）・`make lint-max-lines` 緑・`make gl-jar-pin-check` 緑（`render_gl/java` は触っていない）。
  - 速さの前後は人の方針（12.16）で回していない。毎コマの変化: GL は場面の前で行を流さなくなった分、`drawRenderList` の呼び出しが場面 1 つにつき 1 回減る。WebGPU は場面のあるコマで 2D の run が場面の所で切れる（GL と同じ）。
- 持ち越し: WebGPU で場面を描く（V2: 場面の組を 2D の組の前に積み、貼る行は resolve 済みの texture を α を掛けた後の値として重ねる。行の 3 番に描き先の番号）・GL を直に呼ぶ面（P5 の後の面の小分けで行にし、`emitRowItem` の Bool をやめる）・
  場面に色の付いた物を置いた場面を GL と WebGPU で比べる門（V2）・`bench/scene3d` で 5.4 の貼りの代金を測る事（V2）。
  - GL の `RenderPaint.paintTarget` は、場面のビルボードが Pass の history を読むか（`scene3d#readsTexture`）も見て history の要否を決めるが、WebGPU の `paintTarget` はスプライトしか見ていない（V2 で場面を描く時に要る）。

### 12.22 R1b-6: 面（2026-11-15・この Mac・Dawn の Metal だけ）

表の 8 行目の 6 つ目（最後）の種類。面（`ShaderDoc` の面・`Render.shaderFill` と `shaderFillMasked`）を `RenderList` の行（`kindSurface`・1 枚 = 1 行）にし、GL と WebGPU の backend が同じ行を流す形にした。
**2D で GL を直に呼ぶ種類は無くなった**。WebGPU の backend は面を描く（P5 の前半で入った `ShaderGen.Wgsl.compile` の WGSL と `SgValues` の並びをそのまま使う）。
12.21 の持ち越しのとおり、最初に `emitRowItem` の Bool をやめた（Unit。GL の `emitOne` と WebGPU の `emitAll`・`emitItem` を消し、GL と WebGPU が同じ `RenderFrame.emitMerged` を呼ぶ）。

- **面の行の欄**: 1 = program（backend の表の番号）・2 = values に書いた値の数・4 = blend・5 = 0（面は clip を持たない）・6 と 7 = 絵の組（`reads`）の範囲・8 と 9 = mask の頂点の範囲・10 = 比べる値・11 = values の先頭。
  絵の組は行に入らないので `RenderList` に `reads`（Int32 の配列・1 つ 3 個: 絵の番号・補間・上下逆）を足した。名前から番号を引くのと、無い名前を名前ごとに 1 回知らせるのは前半（前は GL の閉包）。
  上下逆の印は前半の `upsideDownTargets`（GL だけが Pass の名前を入れる）から書き、GL は今どおり `uTexFlipN` へ差す。WebGPU は読まない。
- **決めた事 1 — 面の値は values に置き、WebGPU は values の buffer を uniform としても読む**（見本の 1）。ShaderGen が `var<uniform> sg` を出すので、bind する位置は 256 バイト（core の `minUniformBufferOffsetAlignment` の上限）の倍数でないといけない。
  前半（`RenderList.appendSurfaceRow`）が面の値を values の 64 個の倍数の位置へ置き（間と残りは 0 で埋める）、WebGPU の `upload` は values を送る位置を 256 バイトにそろえる。values の buffer の usage に `UNIFORM` を足した。
  比べた別の案: 面だけの uniform の buffer（4 本目の Stream）は同じく 256 バイトの倍数になり、本が 1 本増えるだけ。storage にして instance の番号で引く形は `ShaderGen.Wgsl` の変更（engine）なので取らない。面 200 枚で余る bytes は 1 コマ 約 45 KB。
  送る位置のそろえを外すと `surfaceTexture` が 55,200 px 違い WebGPU の誤り 6 で落ちる事を確かめた（Pass の後の本編の面の位置がずれる）。
- **決めた事 2 — bind group は draw ごとに作り、submit の後に手放す**（見本の 2）。別の案「(位置・buffer・絵の番号) を鍵に控えて使い回す」を動かした: 面 200 枚（絵 1 枚を読む・同じ Spec）の 1 コマ（300 コマの平均）が
  作る形 645〜846 µs・控える形 535〜744 µs で、差は 1 面 0.5 µs ほど（同じ形でも回ごとに 200 µs 揺れる）。控える形は buffer を作り直した後に古い group を読み、`surfaceMask` が 592 px 違った（外す決まりが要る）。ブラウザの代金は測っていない。
- **決めた事 3 — pipeline は program × blend × 描き先の形式 × 標本 × stencil の鍵で控える**（見本の 3）。draw ごとに作る形は面 200 枚の 1 コマが 1,065〜1,294 µs（Dawn は中で同じ形を使い回すので差が小さい。ブラウザは 1 本 65〜93 ms・4.3）。
  違う Spec 200 個を初めて描くコマは 38.8 ms（WGSL の組み立て・shader module・pipeline を 200 回）。8 章の「コマの途中で同期では作らない」は持ち越し。blend の因子と stencil は `WebGpuPipelines.describeTarget`（スプライトの形と同じ物。Multiply は GL の面と同じく `fs_multiply` を通さない）。
- **決めた事 4 — mask つきの面の比べる値も前半が進めて行に書く**（12.20 の持ち越しの答え・見本の 4）。mask つきスプライトと同じ `nextMaskRef` で、GL の「mask つきの面は自分で stencil を 0 にして 1 を書き、前半の前の値を 0 に戻す」をやめた。
  別の案（面は毎回値 1・前の値を 0 に戻す）も動かした: 面の 6 場面とも GL と 0 px だが、WebGPU は面ごとに stencil を 0 に戻す全面の draw が 1 本と、面の後の最初の mask つきスプライトの前に 1 本増える（`surfaceMask` で 3 本）。
  GL の mask の書き込みは mask つきスプライトと同じ関数にまとめた（`RenderSprite.writeStencilMask`・`endStencilMask`。`drawSpriteMaskedRange`・`drawShaderSurfaceMasked`・`buildMaskData`・`drawPolygonBatch` は消した）。
- **program の表**（`RenderPaint.Internal.WebGpuSurfaces`）: Spec の名前で引き、中身が同じなら作り直さない（GL の `buildProgram` と同じ `isSameSpec`・`eqSpec`）。中身が違えば組み直し、前の番号はコマの終わり（present の submit の後）に手放す（最後に画面へ描いたコマの面が指す番号は、大きさが変わった時の描き直しが使うので、そのコマが替わるまで残す）。
  組めない Spec（`getCompilationInfo` に Error の行）は単色の代わり（`WebGpuShader.surfaceFallbackWgsl`・GL の `fallbackFragmentSource` と同じ色）で塗り、名前ごとに 1 回 `Log.fellBack`。group 0 の layout は読む絵の数ごとに 1 つ。
  組めない Spec を 1 つ置いた試し（`Const(1.0e40)`。WGSL は f32 に収まらない定数を誤りにする）: WebGPU は単色の代わり（128, 51, 51）で塗るが、`createShaderModule` の誤りは error scope で受けないと device の誤りに数えられ、
  `errorCount` が 1 増えた（scope を開く口は `render_gl/java` の `WebGpu` に無い）。GL は同じ Spec を組めて（255, 128, 128）を塗った（12.17 の持ち越しの「f32 に収まらない `Const`」と同じ根）。
  params が Spec の欄より少ない面は、GL は足りない `uParamN` に前に差した値（初めは 0）が残り、WebGPU は 0 を読む（行が取った values の残りは 0 で埋めてある）。engine_world の `Render` は欄の数だけ params を作るので今は起きない。
  無い名前の絵は不透明な黒（GL が絵の無い unit で読む値）。読む絵に描き先と同じ絵があれば描かずに知らせる（WebGPU は pass ごと誤りにする）。
  GL の LRU（`evictShaderPrograms`）に当たる物はまだ無い（名前の数だけ増える）。
- **P5 の後半の持ち越しのうち 2D の面の分**: 2D の組み込みの残りは単色の代わりだけが要った（多角形とタイルは R1b-2）。`TestWgslDawn` に足して 365 本。
  2D の面の絵の mip の読みは「レベル 0」のままでよいと決めた: GL の面は sampler の object で MIN_FILTER を NEAREST か LINEAR（mip を使わない）にしているのでいつもレベル 0 を読み、WebGPU の 2D の絵も mip 1 段で作る。3D の物（頂点シェーダー・ビルボード・空・`R3dScene` を詰める所ほか）は V2・P8 に残す。
- 入れた物（render_gl の中だけ・engine の pub は増えていない）:
  - 前半: `RenderList.kindSurface` の行・`appendSurfaceRow`・`reads`・`readsOf`・`readFields`・`surfaceValueAlign`・`stencilRefOf`。`RenderFrame.emitSurface`・`surfaceTextureOf`・`surfaceMaskCap`（mask の頂点の入れ物を先に広げる）。
    `emitRowItem` は Unit・`emitMerged` は GL を受けない。`blendOf` を pub に（塗りのコアの面の閉包が使う）。`TargetTable.spritesReadHistory` を `isHistoryRead`（面の読みも見る）にして GL と WebGPU の両方が呼ぶ。
  - GL: `GlRows.RowDrawers`（場面と面を描く口の record。行のループの外で 1 回だけ欄を引く）・`SurfaceDrawer`・`drawSurfaceRow`。`FrameArgs#drawSurface` は面の行 1 つを塗る閉包（`GlRows.SurfaceDrawer`）。
  - WebGPU: `WebGpuRows.drawSurfaceRow`・`hasTextureIn`・`SurfaceDrawer`・`renderFrame` の `surfaces` と `drawSurface`。`WebGpuPaint` の `pendingSurfaces`・`linearClamp`・`buildProgram` と `drawSurface` の handler（「まだ描かない: 面」を消した）。
    `WebGpuPipelines.targetKeyOf`（pipeline の鍵の描き先と重ね方の分。スプライトの形と面で同じ物）。`WebGpuSurfaces`（228 行）。`WebGpuPaint.flix` は 1,048 行。
    group 1 の控えは `WebGpuRows` が持つ（面の draw は group 0 だけ戻し、`drawSurfaceRow` が絵の控えを捨てて、次の行が空の絵か自分の絵を積み直す）。
- 振る舞いの変化（絵は変わらない）: GL は面の前で行を流さず、面も同じ列で流す（GL の呼び出しの並びは変わる・draw の順と数と数え方は同じ）。GL の mask つきの面は stencil の clear が pass の頭と 255 個ごとになった。
  面の値は前は `Float64` から f32 にして差していたのを、前半が f32 にして values に置いた物を差す（同じ値）。
- テスト: render_gl 445 緑（1 回目の時点・2 回目は下の表の 452。`.layers/render_gl` の flix test。前の 437 から「面は行にならない」「mask の後の mask つきの面も stencil を使ったまま」「mask つきの面の後は値が 1 に戻る」の 3 本を消し、
  面の行 6 本（`TestShapeRows`）・mask つきの面 4 本（`TestMaskRows`）・面の history の読み 1 本（`TestTargetTable`）を足した。`TestWgslDawn` は単色の代わりを足して 365 本）。
  核の主張を直しを外して確かめた: 前半で面の前の run を閉じないと `testSurfaceSplitsSpriteRun` と `testGlDrawsSurfaceInRowOrder`（GL の backend が面を塗る時に前の箱が 1 本だけ出ている）が落ちる。
  WebGPU の面の mask を描かないと `surfaceMask`・`surfacePass`・`surfaceMsaa` が 3,150〜6,926 px 違い、draw の数も GL と合わずに落ちる。
- `bench/webgpu_v1` に面の 6 場面を足した（許す差は足していない・どれも既定の 0）: `surfaceFill`（単色・箱との重なり順・uv・params・time・Add・Multiply・α）・`surfaceBetween`（同じ箱の間の面・期待 draw 3・kind 2）・
  `surfaceTexture`（アトラスを Nearest と Linear で・GL では上下逆の Pass・無い名前）・`surfaceMask`（mask つきスプライトとの交互・前の面の mask の内側の小さい mask・三角形にならない mask・2 つの矩形の mask で絵を読む。期待 draw 12・kind 4・texture 1・mask 6）・
  `surfacePass`（Pass の中の面と mask つきの面）・`surfaceMsaa`（標本 4 の Pass の端数の位置の面と mask つきの面）。`unsupported` は 3D の場面だけにした。
- 門（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal・2026-11-15）:
  - render_gl のテスト 445 緑（1 回目の時点）・`TestWgslDawn` 365 本を Dawn で組んで誤り 0。
  - `make gl-parity` 緑。81 行が変える前の木（R1b-5）で流した物と 1 字も同じ（castShadow の 565 px は前からの B。面の場面 `texField`・`passMask`・`paramRead` は A 段階で 0 px）。
  - `make webgpu-v1-check` 緑: 画面なしの比べは 34 場面とも許す差の内（足した面の 6 場面は 0 px・submit 1）・2D の draw の数と切れた理由も 34 場面とも GL と同じで、
    `surfaceBetween`・`surfaceMask` は期待とも同じ。WebGPU の誤り 0・「まだ描かない: 3D の場面」は 1 回。後半の rpg の題名の窓の 2 回撮り・GL との比べ・gl_parity の V1 の場面も緑。
  - `make webgpu-v1-check-web` 緑（WebGL2 と 0 px・WebGPU の無い頁 0 px・PC と 22 px ±1 で前と同じ）。面の場面をブラウザで回す口はまだ無い。
  - `make gl-capture-check`: a と b の 54 枚がバイトまで同じ。基準 0.88.4 と違うのは 30 枚（前と同じ数・同じ 5 場面）。main の控え（11-15 21:08）とは sound-novel-starter の title の 6 枚だけ違い、7.6 の今のソースのハッシュ（`c367c77d…`）と同じ（R1b-3 からの状態）。
  - テンプレ 3 本の `reference-check` 緑（rpg 16・novel 43・tidepool 8）・`make lint-huge-methods` 緑（sprite_stress の jar を作り直し、`bench/webgpu_v1` の jar も渡して）・`make lint-max-lines` 緑・`make gl-jar-pin-check` 緑（`render_gl/java` は触っていない）。
  - 速さの前後は人の方針（12.16）で回していない（比べの数字は面 200 枚の試しの場面だけ）。
- 持ち越し: 組めない Spec が device の誤りに数えられる事（error scope の口・jar を開ける時）・面の pipeline をコマの途中で同期で作る事（8 章・P10。作るまで単色で描く形）・WebGPU の面の program の LRU と診断（`shaderBuilds`・`liveShaders`）・ブラウザで面の絵を GL と比べる門（R1b-2 からの、`bench/webgpu_v1` の場面をブラウザで回す口）・
  ブラウザで draw ごとの bind group を作る代金（P10 の前の計測）・面 1 枚に 256 バイト取る values の余り（面が数千枚の画面が出たら、engine と相談して storage へ）。
- 1 回目のレビュー（87 点）への対応（2 回目のコミット）:

  | # | 指摘 | 直した所 |
  |---|---|---|
  | 必須 1 | 値 1 の面で stencil を戻す道が門を通っていない | `TestMaskRows` に `stencilRefOf` が面の行で 10 番を読む 1 本と、255 体の後の面が値 1 になる 1 本。`bench/webgpu_v1` に `surfaceAfterOverflow`（255 体の後に、1 体目のセルを含まない mask の面と mask つきスプライト。期待 draw 515・kind 2・texture 1・mask 511）。`stencilRefOf` を kindMask だけに戻すと 2 本落ち、場面が 24 px ±231 で落ちる。GL の `clearStencil` を消しても場面が 24 px ±231 で落ちる |
  | 必須 2 | 組めない Spec の道を確かめていない | 試した（上の program の表の項）。誤りは 1 つ数えられ、WebGPU は単色の代わり・GL は組めて別の色。java の口は変えず、`compileProgram` の WhyNot と持ち越しへ。試しの場面は門に入れていない（誤り 0 の門が落ちる） |
  | 必須 3 | `buildProgram` の match の入れ子 | `old \|> Option.map(snd) \|> Option.filter(…) \|> Option.forEach(…)` |
  | 必須 4 | `TestWgslDawn` の doc の置き違い | `builtinSurfaces` を `sceneFunctions` の doc の前へ |
  | 任意 5 | Pass で面が自分の history を読む場面 | `surfaceHistory`（historyFade の面の版・3 コマ・0 px） |
  | 任意 6 | 名前 | `groupOf` → `buildDrawGroup`・`readsTexture` → `hasTextureIn`・`readsHistory` → `isHistoryRead` |
  | 任意 7 | `fallbackProgram` の pub | 外した |
  | 任意 8 | 長い関数の型 | `GlRows.SurfaceDrawer`（GlRows 4 か所・Frame 1 か所）・`WebGpuRows.SurfaceDrawer`（4 か所） |
  | 任意 9 | pipeline の鍵の重複 | `WebGpuPipelines.targetKeyOf`・`targetKeys`（形の pipeline と面の pipeline と retire の割り算が使う） |
  | 任意 10 | sampler の持ち主 | `linearClamp` も `WebGpuPaint` が作って手放す（`WebGpuSurfaces.fresh` は 2 つを受けるだけ）。`nearestClamp` の行は元の位置へ |
  | 任意 11 | params が少ない時・128 個の道と描かない道のテスト | 上の program の表の項に 1 行。`TestShapeRows.testLongSurfaceTakesTwoSteps`・新しい `TestSurfaceValues`（`canReadValues` 4 本） |
  | 任意 12 | group 1 の後始末の重複 | 面の draw は group 0 だけ戻す。group 1 の控えは `WebGpuRows` が持ち、面の後は -1 にして、次の行が絵（0 の絵は空の絵）を積み直す（控えの初めの値は空の絵の 0） |
  | 任意 13 | 行数・空行・WhyNot の番号・retire した program の描き直し | 行数を今の数へ・`TestShapeRows` の末尾の空行・「st の 41 番」を消した。retire は直した: `endFrame` が最後に画面へ描いたコマの面の program を残す |

  2 回目の門（同じ機械・2026-11-15）: render_gl 452 緑（7 本足した）・`TestWgslDawn` 365 本・`make gl-parity` 緑（81 行が R1b-5 の木と 1 字も同じ）・`make webgpu-v1-check` 緑（36 場面とも許す差の内・面の 8 場面は 0 px・draw の数も GL と同じ・誤り 0）・
  `make webgpu-v1-check-web` 緑（前と同じ）・`make gl-capture-check`（54 枚が a と b で同じ・基準との差 30 枚で前と同じ）・テンプレ 3 本の `reference-check` 緑・`lint-huge-methods`・`lint-max-lines`・`gl-jar-pin-check` 緑。

### 12.23 R2a: 3D の不透明の batch（2026-11-16・この Mac・GL だけ）

表の 11 行目。3D の不透明の batch（頂点の色の物・骨つきの物・不透明の材質の物）を `Render3d.SceneList` の行（1 行 = batch 1 つ）にし、GL の backend（`Render3d.GlRows`）が流す形にした。
計画（`Render3d.ScenePlan`）から `gl` と GL の `State` を外した。WebGPU の backend はまだ 3D を描かない（V2）。半透明・ビルボード・空・影の地図は今どおり GL を直に呼ぶ（R2b）。

- **計画が backend に聞く物（5.3 の 3 つ）**: 描き先の能力は `PlanCaps`（alpha to coverage が使えるか・姿勢の行の上限）。材質の状態と順の番号は値で聞く:
  前半の `groupScenes` が置いた物を batch の候補に分けて聞く材質（頭の物の材質とプログラムの版）を場面の順・候補の順に並べ、backend の `Material.resolveMaterials` が引いて（初めての材質はここで組む）
  順の番号の列（0 = 使えない）を返し、前半の `planScenes` がそれで頂点の色の batch と材質の batch に分けて並べる。計画の側の状態（描き方と知らせ済みの鍵）は `ScenePlan.Planner` に分け、`Render3d.State#planner` が持つ。
  GL の backend の順の番号は今どおりプログラムの番号（同じ深さの面の勝ち方が変わらない）。
- **`MaterialBatch#entry` を替えた**: `{ handle, order, kind, material, batch }`。handle = その prepare の材質の表（`Material.MaterialTable`・GL の backend の持ち物）の番号で、聞いた並びの番号がそのまま番号になる。
  材質の鍵の字で引き直す形は、同じ鍵で中身の違う材質が同じコマに来た時に先の batch の絵が変わるので取らなかった。
- **行の欄**（`SceneList` の頭のコメント）: 種類・材質の表の番号・順の番号・1 体ごとの値の先頭・数・分かれた理由（`Counts.breakSlotOf` の番号。前半が決める）・フラグ（両面・alpha to coverage・法線マップ・前の材質の行と同じ付け方）。
  行ごとの頭の物と材質は `heads`・`materials` の列に持つ（形を上げる・lightmap と絵の名前を引くのに要る）。材質の draw ごとの値（`uParamN`・cutout）と絵の組はまだ行の外で、GL は材質から引く（R2b の「材質と絵の組」）。
- **決めた事 1 — 1 行の高さは batch 1 つ + 同じ付け方のフラグ**（9.1 の表の 3D の行・見本の 1）。backend が毎行付け直す形と比べ、GL の `draw` の区間が field 12,000・形が物ごと・材質 1 種で 33.5〜35.4 → 28.3〜30.1 ms。
  材質を付ける行と形を描く行を分ける低い高さは、GL の呼び出しがフラグの形と同じになり、並びの決まりが backend 2 つに増えるので動かさずに取らなかった。V2 の後に WebGPU の行数とあわせて見直す。
- **決めた事 2 — 形と絵を描く前に上げる**（5.3 の「上げる行」）: `GlRows.uploadRows` が場面を描き始める前に行の形（間引いた行も・置き場の lastUsed を進める）・材質の絵・法線マップ・lightmap・タンジェントを上げ、
  行ごとの (VAO, 添え字の数) を返す。行を描く所は置き場を引かない（前は batch ごとに `meshEntry` の Map を引いていた）。前の `noteCulled`（間引いた材質の絵だけ先に上げる）はここへまとめた。
  「上げる行」を `RenderList` の行の種類にはしていない（upload は list を作る前に呼ぶ関数という判断 13 と同じ並び）。材質の絵は描く時にもう一度引く（置き場に当たるだけ。番号を行へ入れるのは R2b）。
- 入れた物（render_gl の中だけ・engine の pub は増えていない）:
  - 前半: `ScenePlan.Planner`・`freshPlanner`・`warnOnce`・`warnOnceIn`・`PlanCaps`・`GroupedScene`・`groupScenes`・`planScenes`（引数を替えた）。`Material.PlacedDraw`（pub に）・`MaterialRequest`・`groupPlaced`・`requestsOf`・`splitGroups`。
    新しい `Render3d.SceneList`（`buildSceneList`・`batchBreakOf`（Material から移した・lightmap は `kind` から）・`isSameBinding`）。`Shadow.shadowPlansOf` と `meshDrawOf` は `Planner` を受ける。
  - GL: 新しい `Render3d.GlRows`（`SceneInputs`・`SceneTarget`・`SceneItem` を ScenePlan から移した・`uploadRows`・`drawRows`）。`Material.resolveMaterials`・`MaterialTable`・`entryAt`・`lookupMaterial`（`materialEntry` を替えた）・
    `freshBound`・`useMaterial`・`bindMaterial`・`drawWithLook`・`drawMaterialWith`・`releaseBound`（`drawMaterialBatch` を分けた）・`splitByMaterial`（Preload が使う、GL を持つ側の形）。`Render3d.drawMeshRange`・`planCapsOf`・`Counts.countDrawCallAt`。
    消した物: `Render3d.drawInstancesLit`・`drawLitWith`・`drawInstancesDepth`・`drawDepthWith`・`noteCulled`。`Render3d.flix` は 1,175 → 1,124 行。
- 振る舞いの変化（絵は変わらない）: GL は場面ごとに形と絵の upload を先にまとめて出す（draw の間に `bufferData` が挟まらない）。前の材質の行と同じ付け方の行は cutout・`uParamN`・絵・sampler を入れ直さない。
  `hasAlphaToOne` と姿勢の行の上限は prepare ごとに 1 回聞く（前は Native で標本つきの場面の時だけ聞いた）。間引いた法線マップの物のタンジェントも上げる。draw の数と分かれた理由は前と同じ。
- テスト: render_gl 469 緑（前の 452 に `TestSceneList` の 17 本。行 11 本・計画 5 本（GL を呼ばず backend の答えを値で渡す）・GL の backend 1 本）。偽の GL を通る 6 ファイル（Batch・Instancing・JointTexture・Sun・GpuMipmap・Preload）は 1 字も替えずに緑。
  直しを外した確かめ: 材質を順の番号で並べないと `testMaterialsSortByBackendOrder` と `testInstancedSortsMaterialsByProgram` が落ちる。同じ付け方の比べから params を外すと `testOtherParamsRebind` が落ちる。
  形を描く時に上げる形へ戻すと `testMeshesUploadBeforeFirstDraw` と `testCulledBatchKeepsMeshInUse` が落ちる。
- 門（この Mac・Apple M4 Pro・macOS 27・2026-11-16）:
  - `make gl-parity` 緑。81 行が変える前の木（R1b-6・a3c6e397）で流した物と 1 字も同じ（決めた事 1 のフラグを入れる前と後の両方）。
  - `make gl-capture-check`: a と b の 54 枚がバイトまで同じ。基準 0.88.4 と違うのは 30 枚（前と同じ）。変える前の木で撮った 54 枚とバイトまで同じ。
  - `make webgpu-v1-check` 緑（36 場面とも許す差の内・draw の数も GL と同じ・誤り 0・「まだ描かない: 3D の場面」1 回）。`make webgpu-v1-check-web` 緑（WebGL2 と 0 px・WebGPU の無い頁 0 px・PC と 22 px ±1 で前と同じ）。
  - テンプレ 3 本の `reference-check` 緑（rpg 16・novel 45・tidepool 8）・`make lint-huge-methods` 緑（sprite_stress・bench/scene3d・bench/webgpu_v1 の jar）・`make lint-max-lines` 緑・`make gl-jar-pin-check` 緑（`render_gl/java` は触っていない）。
  - 速さ（`bench/scene3d`・`make run SCENE=field COUNT=12000 MOVING=100`・2 回 × 2 区間・frame p50。人の方針（12.16）では最後にまとめて測るが、表の行が速さの【目標】を持つので測った）:

    | 条件 | 変える前（a3c6e397） | 後（フラグ無し） | 後（入れた形） |
    |---|---|---|---|
    | 形 1 つ・材質 1 種 | 15.7〜18.4 ms（split 12.1〜14.5） | 15.3〜15.5 ms（split 11.7〜11.8） | 15.4〜18.9 ms（split 11.7〜14.7） |
    | 形が物ごと・材質 1 種（1 棟ずつの都市に近い形） | 71.1〜82.4 ms（split 25.4〜31.3・draw 41.4〜44.7） | 70.5〜74.9 ms（draw 33.5〜35.4） | 73.2〜78.0 ms（draw 28.3〜30.1） |

    1 コマは起動ごとの揺れ（`bench/scene3d/RESULTS.md` の ±20%）の内で、はっきり減ったのは GL の `draw` の区間だけ。split（計画）は変わっていない。
    東京 1 棟ずつと fps3d_lab は 1 回目では測っていない（下の 2 回目の門）。
- 1 回目のずれ（2 回目で直した）: 「`planScene` 系を配列で運ぶ」を計画の出口だけにしていた。5.3 の「上げる行を `RenderList` の先頭に」は行の種類でなく描く前に呼ぶ backend の関数にした（決めた事 2・5.3 の表に →）。
- 1 回目のレビュー（78 点）への対応（2 回目のコミット）:
  - **決めた事 3 — 計画の内側を配列で運ぶ**（見本の 4）。field 12,000 の JFR（変える前の木）で標本の 51% が record の欄の引き当てで、呼び手は `Batch.hasSameTree`・`kindBits`・`batchKeyOf`・`Material.vertexKindOf`・`batchOf`（物ごとに鍵の組・木の比べ・版の record を作っていた）。
    分け方（聞く材質・batch の鍵の番号・材質の絵の名前の並びの番号）を材質の値（同じ 1 つの値・`IdentityHashMap`）と頂点の形（uv・骨・lightmap）の組ごとに 1 回だけ決め、物ごとは配列の上で番号を引くだけにした（`ScenePlan.groupWith`・`placeOne`・`spansOf`）。
    描く物は batch ごとの列でなく prepare の配列（`Grouped#members`）の範囲（`Batch.SpanBatch`）で運び、`Instancing` も範囲から詰める。候補の並びは `groupInOrder`・`groupByTextures` と同じ（同じ深さの面の勝ち方を変えない）。
    同じプログラム（版と材質の木の鍵）の材質は 1 回だけ backend に聞く（木の鍵の衝突でだけ、後の材質が先の材質のプログラムで描かれる。`groupScenes` の WhyNot）。
    `TestRender3dBatch` が呼ぶ純粋な関数（`batchOf`・`shapeBatches`・`groupInOrder`・`groupByTextures`・`numberBatch`・`packDraw`）は record を返す口のまま残し、テストは替えていない。ただし本番（`groupWith`・`numberSpan`）はそれらを呼ばなくなり、
    `TestRender3dBatch` は本番の並びを守らなくなった（2 回目では書き漏らした。3 回目で、古い関数を答え合わせの見本と WhyNot に書き、本番の並びを見本と比べるテストを足した）。
  - 計画の側の関数（置いた物 1 つ・材質の版・材質の問い合わせ・影の計画・`isSkinned`・`hasUv`・`meshDrawOf`・`inDrawOrder`・`isCoverageCutout`）を GL を import しない `ScenePlan` へ集め、`Material`・`Shadow` との相互の use を解いた（`TestRender3dDrawOrder` の名前だけ替えた）。
  - 半透明の batch の形・絵・タンジェントも `uploadRows` で先に上げる（`GlRows` の「描く途中で上げない」の WhyNot を本当にした）。`buildSceneList` は `timed(Phase.Split)` の中で 1 回で埋め、行と upload のループは自分への再帰にした（docs/performance.md の 13 節）。
    `isSameBinding` の絵は (名前, 補間) の組で比べる。`ScenePlan` の頭のコメントを WhyNot に、`Render3d.flix` の頭のモジュールの一覧に `ScenePlan`・`SceneList`・`GlRows` を足した。
  - 見本 1 の (B)（材質を付ける行を分ける）を動かした: gl-parity は同じ・`draw` は 27.1〜30.1 ms で (C) の 27.0〜27.2 ms と揺れの内・行の形のテストが落ちる。(C) のまま。
  - テスト: render_gl 479 緑（`TestSceneList` は 27 本。足した物: isSameBinding の cutout・wrap・法線マップ・順の番号・絵の補間で付け直す 5 本・同じ材質を 1 回だけ聞く・2 つ目の場面の材質が答えの 2 つ目を指す・
    間引いた物は範囲に入らない・材質の絵も描く前に上がる・偽の GL で同じ材質の 2 行目は cutout の uniform と絵を付け直さない・lightmap の版の 2 行目は付け直す）。偽の GL を通る 6 ファイルは a3c6e397 と 1 字も同じ。
  - 直しを外した確かめ（2 回目）: GL が `flagSameBinding` を見ない → `testSecondSameMaterialRowDoesNotRebind` が落ちる。材質の問い合わせの番号を場面ごとに 0 から振る（1 回目の `firstRequest` を 0 にするのと同じ誤り）→ `testSecondSceneMaterialPointsAtSecondAnswer` が落ちる。
    半透明の形を先に上げない → `testMeshesUploadBeforeFirstDraw` が落ちる。材質の絵を先に上げない → `testTexturesUploadBeforeFirstDraw` が落ちる（1 回目の書き方では落ちなかったので、先に描く頂点の色の物を足した）。
  - 2 回目の門（この Mac・2026-11-16）:
    - `make gl-parity` 緑。81 行が a3c6e397 の木と 1 字も同じ。
    - `make gl-capture-check`: a と b の 54 枚がバイトまで同じ。基準 0.88.4 と違うのは 30 枚（前と同じ）。a3c6e397 の木で撮った 54 枚ともバイトまで同じ。
    - `make webgpu-v1-check` 緑（36 場面・誤り 0・「まだ描かない: 3D の場面」1 回）・`make webgpu-v1-check-web` 緑（WebGL2 と 0 px・WebGPU の無い頁 0 px・PC と 22 px ±1）・
      テンプレ 3 本の `reference-check` 緑（rpg 16・novel 45・tidepool 8）・`lint-huge-methods`（sprite_stress を作り直し・bench/scene3d・bench/webgpu_v1 の jar）・`lint-max-lines`・`gl-jar-pin-check` 緑。
    - 速さ（`bench/scene3d`・field 12,000・動く割合 100%・2 回 × 2 区間・frame p50（split・draw））:

      | 条件 | 変える前（a3c6e397） | 1 回目 | 2 回目 |
      |---|---|---|---|
      | 形 1 つ・材質 1 種 | 15.7〜18.4 ms（12.1〜14.5・0.2） | 15.4〜18.9 ms（11.7〜14.7・0.2） | 9.8〜10.1 ms（6.3〜6.4・0.2） |
      | 形が物ごと・材質 1 種 | 71.1〜82.4 ms（25.4〜31.3・41.4〜44.7） | 73.2〜78.0 ms（23.7〜26.4・28.3〜30.1） | 57.2〜59.0 ms（26.0〜27.7・27.0〜27.2） |

    - **東京 1 棟ずつ**（`plateau_city`・`PLATEAU_MODEL=3k_each`・12,557 棟・`FLIX_GE_FRAME_STATS` の 600 コマの平均の間隔）: 変える前（a3c6e397）101.9〜112.4 ms・2 回目 83.9〜97.6 ms（2 本ずつ交互）。
      100 ms 以下【目標】に届いた。4.4 の 137 ms は 0.95.0 より前の engine の数で、変える前の今の木はすでに約 103 ms（P1 と R1 の分）。リポジトリは触らず、写し（データは symlink）を 0.95.0 の fpkg で組んで測った。
    - **fps3d_lab の部屋**（`START=room`・同じ測り方・温まった後の 600 コマの平均の中央値）: 2 回目の時点で変える前 2.56〜2.60 ms（5 本）・後 2.57〜3.23 ms（5 本・うち 2 本が 3.2 ms 前後の遅い回）。
      3 回目で前後を交互に 8 本ずつ回した（下）。部屋は材質の値を毎コマ作り直すので、材質の値ごとの控えが当たらず、物ごとに材質の絵の名前の並びを辿る（`ShaderDoc.texReadsIn` の標本が 36 → 70）。
- 設計とずれた所: 「上げる行」は行の種類でなく描く前に呼ぶ backend の関数（5.3 の表に →）。`MaterialBatch#entry` は鍵の字でなく材質の表の番号（9 章の表に →）。材質の絵の組と draw ごとの値はまだ行の外（R2b）。
- 2 回目のレビュー（85 点）への対応（3 回目のコミット）:
  - **答え合わせの見本**: `Batch.groupInOrder`・`groupByTextures`・`batchOf`・`shapeBatches`・`Instancing.numberBatch` を、本番（`ScenePlan.groupWith`・`Instancing.numberSpan`）から呼ばない答え合わせの相手と WhyNot に書いて残した（`TestRender3dBatch` は替えない）。
    `TestSceneList` に、形・材質・絵の名前・間引きの混ざった入力で本番の候補の並びが見本（`groupInOrder` + `groupByTextures` + `batchOf`）と同じ事・XYX → XX, Y・1 つの鍵の中で絵の名前で分かれる・
    形が違えば同じ鍵でも分かれる・`numberSpan` が上限で止まる、の 5 本を足した（間引いた物が範囲に入らない事は 2 回目の 1 本）。どこからも呼ばれない `JointTexture.withBatchPoseRows` を消した。
  - `ScenePlan.placementOf` の match の入れ子を `cachedPlacement` へ出した。`Material.MaterialTable` の WhyNot を今の問い合わせのまとめ方に合わせた。
  - `requestOf` は、既に聞いた番号に当たった時に `ShaderGen.eqMaterial`（参照が同じ木なら辿らない）で 1 回比べ、同じ GLSL を生まなければ別の番号で聞く（木の鍵がぶつかった時に黙って先の材質で描かない。4 回目で候補の頭の 1 回に移した・下）。
    テストは書いていない: `Scene3d.Material3d` は閉じた型で、render_gl のテストから木の鍵がぶつかった 2 つの材質を作れない。
  - `kindCodeOf` に `Batch.kindBits` と分ける理由の WhyNot・`spanPoseRows` のループを自分への再帰に。
  - 直しを外した確かめ（3 回目）: `groupWith` の候補の並びを逆にすると `testGroupsMatchTheReference`・`testXyxGroupsXxThenY`・`testTextureNamesSplitOneKey` が落ちる。
  - render_gl 484 緑（`TestSceneList` 32 本）。偽の GL を通る 6 ファイルは a3c6e397 と 1 字も同じ。
  - **fps3d_lab の部屋・前後を交互に 8 本ずつ**（2 回目のコミット fc440960 の engine。3 回目のコミットで計画の速さに関わる所は `requestOf` の比べだけ）:

    | 組 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
    |---|---|---|---|---|---|---|---|---|
    | 変える前（a3c6e397） | 2.63 | 2.53 | 2.56 | 2.60 | 3.16 | 2.61 | 2.59 | 3.12 |
    | 後 | 2.59 | 2.59 | 2.63 | 2.61 | 3.36 | 2.56 | 2.67 | 2.61 |

    中央値の中央値は前 2.605 ms・後 2.61 ms（+0.2%）で 5% の内。3.1〜3.4 ms の遅い回は前にも 2 本・後に 1 本出たので、この Mac の揺れとして通す（2 回目に後にだけ見えた 2 本も同じ揺れと見る）。
  - 3 回目の門（同じ機械・2026-11-16・3 回目のコミット a9b5c778）: `make gl-parity` 緑（81 行が a3c6e397 と 1 字も同じ）・`make gl-capture-check`（a と b の 54 枚が同じ・基準との差 30 枚・a3c6e397 の 54 枚ともバイトまで同じ）・
    `make webgpu-v1-check` 緑（36 場面・誤り 0）・`make webgpu-v1-check-web` 緑（0 px・0 px・PC と 22 px ±1）・テンプレ 3 本の `reference-check` 緑・`lint-huge-methods`・`lint-max-lines`・`gl-jar-pin-check` 緑。
    `bench/scene3d`（2 回 × 2 区間・frame p50（split・draw））: 形 1 つ 9.8〜10.4 ms（6.4〜6.6・0.2）・形が物ごと 57.6〜59.6 ms（26.4〜27.9・27.0〜27.3）で 2 回目と同じ。
- 3 回目のレビュー（89 点）への対応（4 回目のコミット）:
  - 3 回目のコミットの engine で fps3d_lab の部屋を前後交互に 3 本ずつ測り直した: 変える前 2.54・2.56・2.52 ms・後 2.65・2.67・2.65 ms（中央値 +4.3%・3 本とも遅い）。
    3 回目の `requestOf` は物ごとに `ShaderGen.eqMaterial` を通り、部屋は材質の値を毎コマ作り直すので参照の比べで抜けず、物ごとに木を辿っていた。
  - 木の鍵の衝突の確かめを、物ごとの `requestOf` から候補の頭で 1 回の `verifiedHandle` へ移した（候補の中の物は頭の材質で描くので、頭で比べれば足りる）。
    直した後に同じく 3 本ずつ: 変える前 2.57・2.57・2.55 ms・後 2.63・2.64・2.65 ms（中央値 2.57 → 2.64 ms・+2.7%）。5% の内。3 本とも後が 0.06〜0.10 ms 遅い差は残り、理由は【未確認】
    （候補の頭の比べか、2 回目の 8 本ずつの組（+0.2%）との日の揺れか。上の持ち越しの「物ごとに材質の絵の名前を辿る分」と一緒に R2b で見る）。
  - テスト: 同じ 1 つの材質の値を uv の有る形・無い形・骨つきの形に付けても候補の並びが見本と同じ（控えに当たる道）・木の鍵がぶつかった材質は別の番号、の 2 本を足した（`requestOf`・`verifiedHandle`・`freshTables` を pub に）。
    render_gl 486 緑。衝突の確かめを外すと `testCollidingTreeKeyAsksSeparately` が落ちる。`make gl-parity` は 81 行が a3c6e397 と 1 字も同じ。
- 持ち越し: 材質の値を毎コマ作り直すゲームで、物ごとに材質の絵の名前の並びを辿る分（材質の木（spec）の値で控える案。9 章の表の 13 行目 R2b の「材質と絵の組」の小分けで、絵の組を行へ入れる時に一緒に）・
  形が物ごとの場面の split（候補ごとの仕事・26 ms。P9 の「動かない物の持ち越し」で計画ごと省く）・
  材質の draw ごとの値と絵の組を行へ（R2b。WebGPU の材質の bind group と一緒に）・半透明・ビルボード・空・影の地図を行へ（R2b）・WebGPU で 3D の行を流す（V2。`SceneList` と `MaterialTable` の形をそこで見直す）。

### 12.24 リリース 2（0.96.0・2026-11-16）

- 2D のゲームが WebGPU を試しに選べる版として 0.96.0 を出した（人の「リリース進めていいよ」）。選ぶ口は R1b までに入っていた物のまま（PC は `FLIX_GE_BACKEND`・ブラウザは `?backend=webgpu`・3D の入口は GL で起動して知らせる）。
- 12.8 の決めどおり、ここで agents-pack の早見表に 1 行とお題 `try-webgpu-backend` を足した（100 点）。手当ては `docs/migrations/0.96.0.md`。
- 門: `make release`（全量・gl-parity）緑・`make determinism`・`make smoke-devtools` 緑。`make gl-capture-check` は 54 枚が a と b で同じ・基準 0.88.4 との差 30 枚で前と同じ（12.16 の決めで P10 まで撮り直さない）。
- 外から取る確かめ: rpg-starter の写しから lib を消し、fpkg・flix.toml・`fge-gl-9261957f995f.jar` を Release から取って build と起動が通った。GL と `FLIX_GE_BACKEND=webgpu`（Dawn の Metal）の両方でタイトル画面が出た。Maven Central が 429 を返したので、Maven の jar だけは手元のテンプレートの置き場を借りた。
- 【未確認】Windows・Linux・Safari・Firefox（12.12 からの持ち越しのまま）。
- スマホ（人の申告・2026-11-16）: Galaxy S24 Ultra の Chrome で Pages の rpg-starter（0.96.0・`?backend=webgpu&hud=1`）が WebGPU で起動した（adapter は `qualcomm adreno-7xx`）。WebGPU と WebGL2 のどちらもふだんは 60 fps（画面の更新の上限）で、タイトル画面が出た時と起動の直後だけ一瞬下がる【推: 素材とパイプラインを作る所】。60 で頭打ちなので、この場面では 2 つの速さの差は読めない。差を見るのは重い場面（sprite_stress の頁など）で。
- gl-capture の基準（人の判断・2026-11-16）: 基準を機械ごとのファイルにした（`bench/baseline/0.96.0/gl-capture-<機械>.sha256`・`make gl-capture-baseline` で撮る・基準の無い機械は 2 回撮りの一致だけ）。0.88.4 の基準は M2 で撮った物で、この機械（M4 Pro）との差 30 枚の 5 場面は、0.88.4 で撮り直した時に「M2 と M4 でずれた」場面と同じだった【推: 差の大半は機械の違い】。M4 Pro の基準を 0.96.0 の絵で撮り、以後の門は「差 0 枚」。12.16 の「P10 まで撮り直さない」はこれで置き換える（P10 で Dawn の版を pin した時の WebGPU の基準は別に撮る）。
- スマホの上限（Galaxy S24 Ultra・Chrome 157・adreno-7xx・2026-11-16・Pages の `webgpu-limits/`。683 行目の「3D の段の前に取る」を済ませた）: Mac の Chrome（`build/bench-web/webgpu_check.json`）より狭いのは `maxStorageBufferBindingSize` 134,217,728（128 MiB。Mac の Chrome は 4 GiB 弱）と `maxBufferSize` 2 GiB。ほかに 3D の形を決める物: `maxInterStageShaderVariables` 16（頂点から画素へ渡す値の数。影の座標・霧・lightmap の uv・法線などを足す P8 の WGSL で当たりうる）・`maxUniformBufferBindingSize` 65,536（Mac の Chrome と同じ）・`maxBindGroups` 4・`maxVertexBuffers` 8・`maxVertexAttributes` 30・`maxSamplersPerShaderStage` 16・`maxSampledTexturesPerShaderStage` 48・`maxColorAttachmentBytesPerSample` 128・`maxImmediateSize` 64。features は `indirect-first-instance`・`timestamp-query`・`shader-f16`・`texture-compression-astc`／`etc2`／`bc`・`float32-filterable`・`float32-blendable` を持つ。canvas の形は `rgba8unorm`（Mac は `bgra8unorm`。rpg-starter はこのまま描けたので、選び分けは効いている）。128 MiB は instance を 64 バイトで持って 200 万個分なので、P8 の storage buffer の形の妨げにはならない見込み【推】。

### 12.25 V2: 縦に 1 本（3D）（2026-11-16・この Mac・Dawn の Metal だけ）

表の 12 行目。WebGPU の backend に 3D の不透明・頂点の色・光（点光源・スポット・太陽・環境光・hemisphere・かすみ）を足し、`bench/scene3d` の部屋を WebGPU で出した。
計画（`Render3d.ScenePlan`）と行（`Render3d.SceneList`）は GL と同じ物を使い、行を流す所だけを WebGPU の側に足した（GL の `Render3d.GlRows` と対の `Render3d.WebGpuRows`）。engine の pub（ゲームから見える API）は増えていない。
レビュー 1 回目（84 点）の必須 4 件と任意を直した（下の「1 回目のレビューへの対応」）。

- **決めた事 1 — 3D を 2D へ貼る形は A「先に自分の texture へ描いて貼る」**（9.1 の表の最後の行）。2D の pass を開く前に、場面ごとに自分の texture（色と DEPTH24_PLUS。標本つきの描き先なら標本つきで描いて resolve）へ描き、
  2D の行の z の位置で、その texture を α を掛けた後の値として（ONE, ONE_MINUS_SRC_ALPHA）場面の矩形 ∩ clip ∩ design 領域の scissor で貼る（`WebGpuShader.sceneWgsl`。読む texel の式は GL の `Render3d.blitDesign` と同じ）。
  B「場面の所で 2D の pass を閉じ、場面を描き先へ直に描いて、2D の pass を開き直す」を、同じ道具で 1 コマずつ組んで比べた（`bench/webgpu_v2` の `SplitPassTrial`。2D の中身は無く、pass を開く・閉じる・貼る代金だけが違う）。
  - 数: 部屋（960 × 540・Native）の 1 コマ（waitIdle まで・300 コマの中央値）を 3 回流し、JIT の温まる 1 区間目を除いた 4 区間ずつ（12 区間）: A 0.452〜0.498 ms・B 0.421〜0.462 ms。
    **12 区間のどれでも B が短く**、差は 0.006〜0.058 ms（中央値 0.026 ms・約 5%）。揺れの内ではない。
  - 比べ方の偏り: 標本 1・場面 1 つ・2D の中身なし。B の不利（場面の数だけ 2D の pass が切れる・標本つきの描き先は閉じるたびに resolve する・切れ目の後で viewport・pipeline・buffer・黒帯・stencil を張り直す）が出ない条件で測っている。
  - それでも A にした理由: (1) 道が 1 本 — Design の解像度の場面はどちらの形でも自分の texture が要る。(2) B は 2D の pass を行の途中で開き直す道が要り、`WebGpuRows` の控え（`geom`）を全部張り直す。
    (3) 標本つきの描き先では、B は pass の切れ目ごとに resolve が増える。(4) スマホのタイル型 GPU では、pass の切れ目ごとに描き先の全画面の読み書き（store と load）が増える【推: この Mac では測っていない】。
  - MSAA のふちは A で消えない（必須 3 で見た・下の門の表の railsMsaa）。P8 の終わりに fps3d_lab の部屋で確かめる（5.4 のとおり）。
- **決めた事 2 — 1 体ごとの値は instance の頂点の buffer**（GL の 1 体ごとの値のテクスチャ・`Render3d.Instancing` の 1 体 8 texel の並びのまま 128 バイト）を location 3〜10 で読み、行の頭の物は `drawIndexed` の firstInstance で引く。
  storage buffer にしないのは 2D のスプライト（V1）とそろえるため。骨の行と一緒に storage へ移すかは P8 で決める（→ 12.29 で比べて instance の頂点の buffer のままにした）。並びは `Instancing.numberSpan` をそのまま使う（GL と同じ詰め方）。
- **決めた事 3 — 材質・骨つき・ビルボード・空・影・Output.Depth は描かずに名前ごとに 1 回知らせる**（「まだ描かない: 3D の材質（頂点の色で描く）」など）。材質は backend に「使えない」（順の番号 0）と答えるので、GL が使えないと答えた材質と同じく頂点の色で描く。
  診断の 3D の数（`scene3dCounts`）は数えないので、診断が有効で場面のあるコマに「まだ描かない: 3D の数を数える事（診断の scene3dCounts は 0 のまま・未計測）」を 1 回出す（`FrameDiagnostics` に「未計測」の値を足すのは engine の pub の変更なので取らない）。
- **`RenderList` の 1 行の欄と高さ（3D）**（9.1）: R2a の `SceneList` の行のまま WebGPU で流せた。WebGPU の側で読む欄は種類・1 体ごとの値の先頭・数だけ（材質の表の番号・フラグは P8 の材質で読む）。行を流す所は `Render3d.WebGpuRows` の 128 行（形の置き場を含む）・GL の `Render3d.GlRows` は 177 行。
  12.21 の見込み（場面を貼る行の 3 番に描き先の番号を入れる）は取らなかった: 描き先は prepare の答え（場面の番号で引く `Paste`）が持ち、行の欄を増やさずに済んだ。
- **形のレビュー（3D）は V2b（実物の欠けの一覧）の直後**（コーディネーターの判断・人のおまかせ・2026-11-16）。欠けの一覧で材質・骨・instance の行に要る欄が見えてから形を確定する方が作り直しが少ないため。9 章の表の V2 の行にも書いた。
- スマホの上限（12.24 の S24 Ultra の値）の内: varying は 4 つ（16 の内）・場面の値の uniform は 944 バイト（65,536 の内）・bind group は 3D の pipeline が 1 つ・貼る pipeline が 2 つ（4 の内）・頂点の buffer は 2 本（8 の内）・storage は使わない。
- 入れた物（render_gl の中だけ）:
  - 新しい `Render3d.WebGpuRenderer`（pub mod。呼び手の `WebGpuPaint` が `Render3d` の子孫でないので pub が要る・親の `Render3d` が pub でないのでゲームからは見えない。WhyNot に書いた）:
    場面ごとの描き先（`SceneTarget`・描き先の鍵とそのコマの場面の番号ごと）・`prepare`（計画 → 1 体ごとの値を送る → 形を上げる → 場面の値を書く → pass を積む）・`notePasted`・`afterSubmit`・`endFrame`（GL と同じ頂点の上限で形を捨てる・128 コマ描かなかった描き先を捨てる）・
    `packSceneValues`（GL の `Light.lightDataOf` の答えを `R3dScene` の欄の位置へ。12.17 の持ち越しの「`R3dScene` を詰める所」）。画面（RGBA8・標本 1）の 3D の pipeline と貼る pipeline は create の時に作る。
  - 新しい `Render3d.WebGpuRows`: 形の buffer の置き場（`MeshTable`）・`uploadRows`・`drawRows`。
  - `Render3dWgsl.litVertexSource`・`cameraDeclarations`・`instanceBytes`（12.17 の持ち越しの 3D の頂点シェーダーのうち、骨の無い頂点の色の版）。`WebGpuShader.sceneWgsl`（貼る形）。
  - `WebGpuPipelines` に貼る形（`WebGpuRows.shapeScene`・blend の番号 `blendScene` = 3・group 1 の `sceneLayout`）。`targetKeys()` の 64 にちょうど収まる。
  - `RenderFrame.Internal.WebGpuRows`: 場面の行は貼る口（`SceneDrawer`）を場面の番号と stencil の使い方で呼び、pipeline・group 1・scissor の控えを捨てる（`forgetBindings` を面の行と共有。数えは前と同じ・2D の draw call には数えない）。
  - `WebGpuPaint`: `paintInto` が 2D の pass の前に `prepare` を呼ぶ・貼る時に `notePasted`・submit の後に `afterSubmit`・present の後に `endFrame`。
    残りが少ない（上限 1,200 行）ので、3D の Host・`sceneViewportOf`・`pasteScene` を子の mod（例 `RenderPaint.Internal.WebGpuScenes`）へ移すのを P8 の最初の小分けにする。
  - 寿命の決まり: 同じ encoder で同じ描き先の値を 2 回書く時（同じコマに同じ Pass を 2 回開く・大きさが変わって描き直す）は先に submit する。控え（`written`）は値を書いた時と、2D の pass に貼った時（`notePasted`）に付ける
    （prepare から 2D の pass を積むまでの間に submit が入ると控えが消えるので、pass の中で付け直す。pass を閉じるまで submit は入らない）。1 体ごとの値の buffer があふれた時は submit して頭から書き、頭からでも入らなければ伸ばす（2D の Stream と同じ決まり）。
  - 根の `src/render_gl/Render3d/` にも新しい 2 ファイルの symlink を足した（無いと refactor の索引の木で `TestWebGpuScene3d` が Undefined use になる・任意 13）。
- 1 回目のレビュー（84 点）への対応:
  - 必須 1（控えが submit で消える）: `Paste` に描き先の鍵を持たせ、`WebGpuPaint.pasteScene` が貼る時に `notePasted` を呼ぶ。回帰テスト `TestWebGpuScene3dDawn`（Dawn を開く・prepare → submit → 貼る → 同じ描き先の prepare で submit を 1 回頼む）。
    直しを外した確かめ: テストの中の貼る所の `notePasted` を外すと「expected 1, but got 0」で落ちる。
    このテストが守るのは `Render3d.WebGpuRenderer` の寿命の決まり（`notePasted` を呼べば、同じ描き先の次の prepare が submit を頼む）までで、
    `WebGpuPaint.pasteScene` が `notePasted` を呼ぶ配線は守っていない（V2b で書き方を正した。配線を外して落ちる門は今は無い【推・外して試してはいない: `bench/webgpu_v2` にも、控えが消える submit が prepare と貼る間に入る場面が無い】。配線を守るテストは P8 で 3D の分を子の mod へ移す時に）。
  - 必須 2・4: 上の決めた事 1 と「形のレビュー（3D）」と 9.1・9 章の表に書いた。
  - 必須 3（MSAA のふち）: `bench/webgpu_v2` に railsMsaa（標本 4 の Pass に bench/gl_parity の msaaEdges の手すりと同じ斜めの棒 3 本を頂点の色の 3D で描き、`Render.blitRegion` で画面へ貼る・passPaste と同じ道）・railsNoMsaa（同じ物を標本 1）・
    slant2dMsaa（3D を使わず 2D の斜めの多角形を標本 4 の Pass へ。比べ相手）を足した。数は下の門の表。
  - 任意で直した物: CPU の入れ物を使い回す（1 体ごとの値は足りなければ倍に作り直す）・画面の 3D と貼る pipeline を create で作る・14 px の説明に【推】・違う画素の総数の上限（64）・pub mod の WhyNot・
    pipeline の鍵に標本の数・`SplitPassTrial` が寿命の道を通らない限界を WhyNot に・`make webgpu-v1-check` の終わりに `make -C bench/webgpu_v2 check`・12.21 の見込みを取らなかった理由・`forgetBindings`・
    `RendererData` の欄の説明を型の頭へ・`scene3dCounts` の知らせ・refactor の索引（根の src の symlink）。
  - 任意で残した物: `WebGpuPaint` の 3D の分を子の mod へ移す（P8 の最初の小分け・上に書いた）。
- テスト: render_gl 492 緑（前の 486 に 6 本: `TestWebGpuScene3d` 4 本（場面の値の欄の位置・光の配列の 16 バイト刻み・影と奥行きの書き出しを切る値・矩形の上下）・`TestWebGpuRows` に場面の行が番号と stencil の使い方で貼る口を呼び控えを捨てる 1 本・
  `TestWebGpuScene3dDawn` 1 本（寿命の決まり・Dawn を開く。開けない機種と GPU の無い機械では SKIP）。`TestWgslDawn` は頂点の色の頂点シェーダーと貼る形を足して 367 本を Dawn で組んで誤り 0。
- 門（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal・2026-11-16・main（c6c772e3）に rebase した後の 2 回目）:
  - `make -C bench/webgpu_v2 run`（GPU が要るので CI に載せない。組めるかだけは `make webgpu-v1-check` の終わりで見る）: GL（`GlOffscreen`）と WebGPU（`WebGpuPaint`）で 960 × 540 に描いて比べる。WebGPU の誤り 0。

    | 場面 | 違う画素（許容） | ±2 以上（許容） | 差の最大 |
    |---|---|---|---|
    | room（Native・正面） | 14 px / 518,400（64） | 7 px（32） | ±82 |
    | roomTurned（Native・yaw 0.5） | 8 px（64） | 6 px（32） | ±52 |
    | roomDesign（Design の解像度 320 × 180 を 3 倍で貼る） | 0 px（0） | 0 px（0） | ±0 |
    | railsMsaa（標本 4 の Pass の 3D の斜めの棒を貼る） | 3,330 px（4,000） | 2,493 px（3,000） | ±55 |
    | railsNoMsaa（同じ物を標本 1） | 0 px（0） | 0 px（0） | ±0 |
    | slant2dMsaa（標本 4 の Pass の 2D の斜めの多角形・比べ相手） | 5,040 px（6,000） | 4,464 px（5,400） | ±55 |

    標本 4 と 1 の差（MSAA が掛かっているか・門）: GL 4,761 px・WebGPU 4,158 px。
  - 部屋の差の理由（画素を 1 つずつ見た）: ±1 の 7 px と 2 px は光とかすみの坂の丸め。大きい差は、同じ深さに重なる面（燭台の台と卓の天板・y = 351 の 6 px）と三角形のふちの画素で、勝つ面が入れ替わった物
    【推: GL は clip の z を固定の段で、WebGPU は頂点シェーダーの `sg_clipFromGl` で 0..1 へ移すので奥行きの最後の bit が違う。Apple Silicon の GL は Metal の上で動くので、GLSL と MSL の compiler の FMA のまとめ方の違いかもしれない】。
    式を取り違えれば面の中が丸ごと違って千 px の桁になる（Design の場面が 0 px なのも、式と貼る形が GL と同じ事の裏づけ）。
  - MSAA のふち（必須 3）: railsMsaa の差は斜めのふちの画素だけで、成分の差は覆う割合 1/4 の段（背景と棒の差 219 の 1/4 = 55）。GL は 1/4・3/4 の段（65・174）を、WebGPU は 1/2 の段（120）を出す画素が並ぶ。
    3D を使わない 2D の斜めの多角形（slant2dMsaa）でも同じ段・同じ桁（5,040 px）で出るので、3D の貼る形（A）の差ではなく、GL と WebGPU の標本の位置の違い
    【推: 描き先の行の並びが上下逆で、4 標本の位置の型が上下に鏡写しになる。bench/webgpu_v1 の msaaPass は軸に沿ったふちだけなので 0 px】。
    3,330 px は design の画素で約 370 px（3 倍に貼っている）で、bench/gl_parity の msaaEdges（GL と CPU の差 652 px）と同じ桁。12.21 の GL の試しのように MSAA が消えた時は、標本 4 と 1 の差が 0 になる。
  - `make gl-parity` 緑（GL の道は触っていない。前の木の表との 1 字ずつの比べはしていない）。`bench/gl_parity` の WebGPU の V1 の scene に `sceneBetweenBoxes`（地の色が不透明な 3D の場面を 2 つの箱で挟む）を足し、SoftRaster と GL の両方に 0 px。
  - `make webgpu-v1-check` 緑（36 場面とも許す差の内・draw の数も GL と同じ・誤り 0・`sceneBetween` は場面を描いて貼るようになって 0 px・draw 3（kind 1・texture 1）で前と同じ。終わりの `bench/webgpu_v2` の型検査も緑）。
  - テンプレ 3 本の `reference-check` 緑（rpg 16・novel 45・tidepool 8）。
  - `make gl-capture-check`（基準 `bench/baseline/0.96.0/gl-capture-apple-m4-pro.sha256`）: a と b の 54 枚がバイトまで同じ。基準と違うのは novel の title の 6 枚だけで、この枝の変更ではない:
    main の作業の木の `templates/sound-novel-starter/saves/novel.json`（git の外の中断セーブ）があると title に「続きから」が出る。この worktree に同じファイルを写して title だけ撮り直すと 6 枚とも基準とバイトまで同じだった（写したファイルは消した）。
    基準が git の外のセーブの有無で変わる（撮る機械の作業の木の状態に依る）事は、基準の撮り方の持ち越し。
  - `lint-huge-methods` 緑（`bench/webgpu_v1` と `bench/webgpu_v2` の jar。engine の全部を束ねた木の jar で、sprite_stress と bench/scene3d の jar は作り直していない）・`lint-max-lines` 緑・`gl-jar-pin-check` 緑（`render_gl/java` は触っていない）。
  - 1 コマの時間（記録・門ではない）: `bench/webgpu_v2` で GL（glFinish まで）と WebGPU（waitIdle まで）を同じ回で交互に（300 コマの中央値・5 区間を 3 回）: GL 0.354〜0.898 ms・WebGPU 0.460〜0.821 ms。
    部屋は 1 ms に届かず、GPU の時計の揺れで区間ごとに 2 倍近く動く。WebGPU が GL より大きく遅い事は無い。
    実機の窓（`cd bench/scene3d && make run` と `FLIX_GE_BACKEND=webgpu`）では、WebGPU の frame が 8.2〜8.3 ms に張り付く（2D だけの sprite_stress の 100 個でも同じ。`FLIX_GE_NO_VSYNC` で IMMEDIATE を頼んでも、この Mac では 120 Hz の垂直同期を待っている【推】）ので、1 コマの比べに使えない。
    submit の中央値は GL 0.309 ms・WebGPU 0.270 ms（1 回ずつ）。
- 持ち越し:
  - スマホとブラウザ（`?backend=webgpu`）で 3D を出す確かめ【未確認】（スマホの上限は 12.24 で取れた。3D の絵を S24 Ultra と iPhone で出すのは人の手が要る）。
  - 形のレビュー（3D）: V2b の直後（上）。
  - 3D の数（`scene3dCounts`・draw の分かれた理由・CPU の区間）を WebGPU で数える（P8 までに。今は知らせだけ）。
  - 材質・骨つき・半透明・ビルボード・空・影・環境マップ・lightmap・Output.Depth・preload（P8）。WebGPU の `paintTarget` の history の要否にビルボードの絵を数える事（12.21 の持ち越し）はビルボードと一緒に。
  - MSAA の標本の位置が GL と違う理由（行の並びが上下逆で 4 標本の型が鏡写しになるのか）を確かめる【推のまま】（→ 12.26 で鏡写しを確かめた）。
  - 実機の窓の WebGPU で垂直同期を待たない形（IMMEDIATE が効かない理由）を調べる【未確認】。速さの比べは 12.16 のとおり P10 の前にまとめる（→ 12.26 で待つ所を突き止めた・直せていない）。

### 12.26 V2b: 実物の欠けの一覧（2026-11-16・この Mac・Dawn の Metal だけ）

表の 12b 行目。WebGPU の backend にまだ描けない物を「描かずに飛ばし、種類ごとの回数を数える」口を足し、fps3d_lab とみやげの町（lamplighter）を `FLIX_GE_BACKEND=webgpu` で流して欠けの表を取った。
engine の pub（ゲームから見える API）は増えていない。GL の道と既定の起動（何も付けない時の GL）は触っていない。

- 入れた物（render_gl の中だけ）:
  - 新しい `RenderPaint.Internal.SkippedDraws`: 種類 → 回数の表。`add` は初めての種類かを返し、`endFrame` は画面のコマが 300 に届いたコマで表の字を返す（ログは呼ぶ側の `WebGpuPaint` が出す。テストの走り手は stderr へ書いたテストを落とすので、表の側は書かない）。
    知らせは種類ごとの初めの 1 回（今までと同じ「まだ描かない: …」）と、表を起動から 300 コマ目と `WebGpuPaint.release` の時に 1 回ずつ。コマごとには増えない。
    `RUN_SECONDS` で止めると TERM で終わり `release` まで来ないので、表は 300 コマ目の物を読む。1 コマあたりの回数の分母は起動の画面のコマも数える。
  - 数え方（`Render3d.WebGpuRenderer.skipsOf`。`Host#skip` に回数を足した）: 物は計画が間引かなかった物（`culled` でない物）を **1 体 1 回だけ**数える。
    骨つきの物は材質があっても骨つきの物（WebGPU は材質の順の番号を 0 で答えるので、材質つきの骨つきの物も計画では骨つきの batch に入り、描かれずに消える）。
    骨つきの物は `Scene3d.isOutsideFrustum` が間引かない（GL も描く）ので、目の後ろの物も数える。lightmap の物は材質の物の内数。
    ビルボードは数、影は影を落とす光の数、空・環境マップは場面の数。**Output.Depth の場面は「奥行きの書き出し（場面）」の 1 回だけ**で、中身（材質・骨・影など）は数えない（`prepareScene` が描かずに捨てる場面のため）。
    2D（描き先と同じ絵を読む行・組んでいない面・起動の後に足す字・preload）は 1 回ずつ。
- 流し方（2 本のフォルダは直していない）: scratchpad へ写し（`build`・`gallery`・`debug`・`reference`・`lib/github` などを除く）、写しの `local.mk` の ENGINE をこの worktree に、`flix.toml` の engine の版を 0.96.0 に、
  `lib/github/…/0.96.0/` をこの worktree の `engine_full/artifact/package.fpkg` への symlink にし、`lib/cache`・`lib/external` を `engine_full/lib` から写した（Maven Central が 429 を返すため）。
  **2 本とも今の engine（0.96.0）でそのまま型が通った**（写しに直しは要らなかった。fps3d_lab は 0.87.0・みやげの町は 0.91.0 から）。
  窓は `FLIX_GE_HIDDEN=1`（480 × 270）・`RUN_SECONDS=40`・`FLIX_GE_FRAME_SHOT` で頭の 64 コマ。場面は fps3d_lab が `START=room`（部屋）・`START=chapel`（礼拝堂）・`START=play`（通路）、みやげの町が `SHOT=arrival`・`market`・`night`。
  落とし穴 2 つ: (1) `bin/headless-run` の jar の置き場（段 1・`~/.cache/flix-headless-jar`）の鍵は src・flix.toml・packages.lock だけで fpkg の中身を見ないので、engine を作り直しても古い jar が使われる（`FGE_JAR_CACHE=off` で流した。写しが作った置き場の 2 つは消した）。
  (2) 写しの `packages.lock` は fpkg を作り直すたびに食い違うので消した。
- 欠けの表（起動から 300 コマの表の 1 コマあたり。0 の種類は出ない＝ビルボード・環境マップ・preload・描き先と同じ絵を読む行・面は 2 本とも 0）:

  | 種類 | fps3d_lab 部屋 | 礼拝堂 | 通路 | みやげの町 arrival | market | night | 目で見た欠け方 |
  |---|---|---|---|---|---|---|---|
  | 材質の物（頂点の色で描く） | 110.5 | 119.3 | 1.6 | 11.9 | 26.4 | 33.3 | 絵（木・石・漆喰・石畳・屋根）が無く、頂点の色の白っぽい平らな面になる。ステンドグラスや旗など頂点の色の物は残る |
  | 骨つきの物 | 12.8 | 0.0 | 0.0 | 43.1 | 63.7 | 63.7 | 人が丸ごと消える（部屋の衛兵・町の旅人と町の人）。町では足元の丸い影（頂点の色の板）だけが黒い楕円で残る |
  | 奥行きの書き出し（Output.Depth・場面） | 0.9 | 0.9 | 0.0 | 0.6 | 0.9 | 0.9 | **3D の場面が全部ぼける**（被写界深度の後がけが奥行きを読むのに、奥行きの Pass が描かれない）。2D の窓と字はくっきり |
  | 影（影を落とす光） | 0.9 | 0.9 | 0.0 | 0.6 | 0.9 | 0.9 | 影が無く、部屋も町も明るく平たい |
  | lightmap の物（今の光で描く） | — | — | — | 7.9 | 21.5 | 30.3 | 前もって計算した光（lightmap）が無い（夜の窓の明かりが地面に落ちない）。材質の物の内数 |
  | 半透明の材質の物（不透明に描く） | — | — | — | 12.6 | 18.6 | 12.7 | 木の葉・ガラスが不透明の塊になる |
  | 空（場面） | — | — | — | 0.6 | 0.9 | 0.9 | 見下ろしの画角で空はほとんど映らない（目では違いが見えない） |
  | 3D の診断の数（未計測で 0） | 1.9 | 1.9 | 0.1 | 1.3 | 1.9 | 1.9 | 絵には出ない（場面を描く Pass と画面の 2 回） |

  - 通路（`START=play`）は 2D（面と多角形とスプライト）で、GL と目で見て同じ。3D は頭の数コマの扉の場面だけ。
  - WebGPU の誤り（検証の誤り）は 6 場面とも 0。落ちた場面も無い。
  - 表は V2b のレビュー 1 回目の後に数え方を直して流し直した物（下の「レビュー 1 回目への対応」）。直す前は Output.Depth の場面の中身と材質つきの骨つきの物を重ねて数えていて、骨つきの物が 2 倍前後（町 127.4・部屋 25.7）、部屋の材質の物が 123.4 だった。
    小分けの順は直す前と同じ（大きい順は変わらない）。arrival は流した回ごとに頭の読み込みのコマの数が違い、場面のあるコマが 300 のうち 199 だったので、1 コマあたりが小さく出ている。
  - 骨つきの物は目の後ろの物も数える（計画が間引かない・GL も描く）。market と night で同じ数なのは、町の人を全部置いて間引かないため【推】。
  - 絵の置き場: `/private/tmp/claude-501/-Users-abab-Desktop-flix-game-engine/1e409b86-520d-4126-86d6-d8af78577988/scratchpad/v2b/out/<ゲーム>-<場面>-<gl|webgpu>/frame-N.png`（**scratchpad の物は消えうる**。人に見せる 1 組はコーディネーターが別に扱う）。
- **R2b と P8 の小分けの順の決め直し**（9 章の表の 13・14 行目に書いた）: 2 本の両方で欠ける物と、欠けると画面全体が崩れる物から。形のレビュー（3D）の決め（下）で (0) と (1b) を足した。
  0. **`WebGpuPaint` の 3D の分を子の mod へ分ける**（P8 の側だけ・Host・`sceneViewportOf`・`pasteScene`）。`pasteScene` → `notePasted` の配線を守るテストもここで。
  1. **奥行きの書き出し（Output.Depth）と `ScenePassSpec`**: 2 本とも毎コマ 1 場面で、欠けると 3D の全部がぼける（一番目立つ）。頂点の色の物は `uDepthOut` を立てて R32F の描き先へ描くだけ（→ 12.27 で R32F は作らず、場面の描き先の形式のまま）で、`R3dScene` の欄も WGSL の分岐（`Render3dWgsl` の frag）も V2 で入っている【推: 一番安い】。
     計画が `List[(ScenePassSpec, SceneList)]` を出す形はここで入れる。cutout と両面の材質の物は材質の道で描くので (2) で埋まる。P8 では 3D の診断の数（`scene3dCounts`）を一緒に数える（場面のあるコマに毎回知らせが出ている）。
  1b. **形と 3D の絵の番号の寿命の表を前半へ**（元の (8) から前へ出した。行に形の番号の欄を 1 つ・材質の絵は reads で番号）。描き先・影の地図の寿命は (8) のまま。
  2. **材質と絵の組**: 2 本とも欠け、fps3d_lab では 1 コマに 110〜119 個の一番大きい欠け。lightmap の物もここの内数（lightmap の欄は材質の道に乗る）。
     values を uniform か storage かはここで決める（uniform は 64 KiB・256 バイト揃えで 256 個が上限）。
  3. **骨と instance**: 2 本とも欠け、みやげの町では 1 コマに 43〜64 体・人が丸ごと消える。元の順（影の後）より前に出す。
  4. **影**: 2 本とも 1 場面に光 1 つ。欠けても形は残る（明るく平たいだけ）ので、骨より後。
  5. **lightmap・空**: みやげの町だけ。元の「環境マップ・空・lightmap」から環境マップを外した（2 本とも 0）。
  6. **半透明・後がけ**: みやげの町だけ（1 コマに 13〜19 個）。半透明の物を並べる所（`blendOrderOf`）を前半へ移し、材質の行として足す。元の「ビルボード・半透明・後がけ」からビルボードを外した（2 本とも 0）。
  7. **ビルボード・環境マップ・mip・preload**: 2 本とも 0。fps3d_lab とみやげの町で確かめられないので、`bench/scene3d` か `bench/gl_parity` に場面を足して門にする。
  8. **残りの寿命（描き先・影の地図）**: 最後。
- **形のレビュー（3D）の決め**（V2b のレビュー 1 回目と同時・コーディネーターの判断・人のおまかせ・2026-11-16。9.1 と 9 章の表にも書いた）:
  - 行の欄と高さ（1 行 = batch 1 つ・Int32 で 7 欄・heads・materials・firstMaterial）は**この形で確定**。足す物は「欄を末尾へ」「種類（kind）を足す」「pass の側に置く」のどれかで載る:
    Output.Depth は pass・材質と絵の組は `SceneList` に values と reads を足して行の末尾に位置・lightmap は 1 行 1 体で reads・骨は storage・影は光ごとの `SceneList`・空は kindSky・
    半透明は前半で並べて材質の行として足す・ビルボードは kindBillboard・環境マップは場面の値。
  - 行の 1 つ外側で 2 つ替える: (1) 計画が `List[(ScenePassSpec, SceneList)]` を出す（`ScenePassSpec` は ShadowMap(light)・Color・DepthOut(range) のような enum・描き先は 2D の `PassTarget` と同じ attachment の列）。上の (1) と一緒に。
    (2) 形と 3D の絵の番号の寿命の表を前半へ寄せる分を上の (1b) へ前倒し。
  - P8 の WGSL の決まり: 影の座標は頂点で作って渡さず frag で world の位置から作る（頂点 → 画素の値 16 の余裕を残す）・形の並びは版ごとに 1 本の buffer へ交互に並べる
    （頂点の buffer 8 本の上限のため。`ensureTangents` のように後から別の buffer を足す形をまねない）・bind group は 0 = コマと場面・1 = 材質（と lightmap）・2 = storage。
- V2 のレビュー 2 回目の任意:
  - MSAA の門を「WebGPU の標本 4 と 1 の差が、GL の同じ差の半分以上」に（`bench/webgpu_v2` の `msaaOk`。今は GL 4,761 px・WebGPU 4,158 px）。
  - rails と slant の場面に差の最大の上限 ±60 を足した（tolerances の 3 つ目・judge）。標本の位置の違いなら覆う割合 1/4 の段（±55）で止まる。room と roomTurned は勝つ面の入れ替わりで ±82 まで出るので切らない（255）。
  - 地の色の無い場面の MSAA（`railsMsaaClear`: railsMsaa の background = None を、色 (0.3, 0.15, 0.05) で消した標本 4 の Pass に描く）: 違う画素 4,761 px・±2 以上 2,493 px・max ±54。
    ±2 以上は railsMsaa と同じ数で、増えた 1,431 px は ±1 だけ【推: ふちの α が 1 未満の画素を clear の色に重ねる時の丸め】。許す差は (3,000・6,000・±60)。
  - 標本の位置の【推】を確かめた: `slant2dMsaaFlip`（slant2dMsaa の多角形を design の上下に裏返した物）を WebGPU で描いて上下に裏返し戻すと、GL の slant2dMsaa との差が 2,808 px・**±2 以上 0 px・max ±1**
    （裏返さない比べは 5,040 px・±55）。**4 標本の位置の型は GL と WebGPU で上下に鏡写し**（なぜ鏡写しかは【推: 描き先の行の並びが上下逆】のまま）。門にはしない（行は「記録」）。
  - `TestWebGpuScene3dDawn` が守る所を 12.25 に正しく書いた（`WebGpuPaint.pasteScene` → `notePasted` の配線は守っていない。配線を守るテストは P8 で 3D の分を子の mod へ移す時に）。
  - `packSceneValues` の頭に WhyNot（書く欄の組を場面ごとに変えない・書かない欄は作った時の 0 のまま）。診断の知らせの文を名詞に（「3D の診断の数（scene3dCounts は未計測で 0）」）。
  - `WebGpuPaint` は 1,101 行（上限 1,200）。3D の分を子の mod へ移すのは P8 の最初の小分けのまま（V2b では前倒ししていない）。
- V2b のレビュー 1 回目（84 点）への対応:
  - 必須 1（数え方の偏り 3 つ）: (a) Output.Depth の場面は「奥行きの書き出し（場面）」の 1 回だけにした・(b) 材質つきの骨つきの物は骨つきの物として 1 回だけ・
    (c) 物は `culled` を除く同じ絞り込み（骨つきの物は計画が間引かないので、目の後ろでも数える）。数えは `skipsOf`（場面ごとの種類と回数）に 1 本にまとめ、members を添え字で回す輪にした（任意の List.range をやめる分も兼ねる）。
    テスト 3 本（`TestWebGpuScene3d`: Depth の場面は奥行きの書き出しだけ・材質つきの骨つきの物は 1 回・目の後ろの材質の物は数えず骨つきの物は数える）。2 本のゲームを流し直して表を差し替えた。順は変わらない。
  - 必須 2: `bench/webgpu_v2` の `compareAndTime` の入れ子の match を `msaaDiffOf`・`printSlantFlipProbe` へ切り出した。
  - 任意で直した物: `WebGpuPaint` の `skipped` を `msaaWarned` へ改名・`SkippedDraws.add` の doc（回数を足し、初めての種類かを返す）・`Counts` を Ref にそろえた・
    railsMsaaClear の 4,761 px が GL の標本 4 と 1 の差と同じ数な理由を tolerances の頭に 1 行【推】・テスト 2 本（frames 0 の "-"・飛ばした物が無い時の 300 コマ目は None）・絵が scratchpad で消えうる事。
- 窓の WebGPU が 8.3 ms（120 Hz）に張り付く件（12.25 の持ち越し）: **待っているのは `Surface.getCurrentTexture`**（Dawn の Metal の nextDrawable）で、**直せていない**。
  - 測り方: 見える窓の `bench/sprite_stress`（100 個・`FLIX_GE_NO_VSYNC=1`）に、getCurrentTexture・submit・present の時間を出す一時の行を足した（測った後に消した。コミットに入れていない）。
  - 数（300 コマの平均）: getCurrentTexture 7.1〜7.4 ms・submit 0.10〜0.14 ms・present 0.02 ms。**FIFO・IMMEDIATE・MAILBOX のどれで configure しても同じ**で、Dawn の検証の誤りも出ない（IMMEDIATE は configure に通っている）。
    同じ窓の GL は 1 コマ p50 0.83 ms・WebGPU は 8.57 ms。
  - さらに、ウィンドウの content view の layer（CAMetalLayer。`respondsToSelector:` で確かめた）の `displaySyncEnabled` を LWJGL の ObjCRuntime から直に NO にしても 8.4 ms のまま（一時の直し・消した）。
  - 見立て【推】: present mode と垂直同期の旗ではなく、窓の合成（window server）が drawable（既定 3 枚）を画面の更新まで手放さず、nextDrawable が空きを待つ。GL は swap interval 0 でコマを捨てて先へ進むので待たない。
    確かめていない手: `maximumDrawableCount`・`allowsNextDrawableTimeout`・フルスクリーン（直に画面へ出す道）・Dawn の版を上げる。
  - PC で速さを比べる時は、今までどおり隠した窓（surface を作らず present しない）か `bench/webgpu_v2`（waitIdle まで）で測る。窓の 1 コマの比べは P10 の前にまとめる（12.16）。
- 門（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal・2026-11-16）:
  - render_gl のテスト（`.layers/render_gl` で `flix test`）503 緑（前の 492 に `TestSkippedDraws` 8 本・`TestWebGpuScene3d` の数えの 3 本）。
  - `make -C bench/webgpu_v2 run` 緑・誤り 0: room 14 px（±82）・roomTurned 8 px（±52）・roomDesign 0・railsMsaa 3,330 px（±55）・railsNoMsaa 0・railsMsaaClear 4,761 px（±54）・slant2dMsaa 5,040 px（±55）・
    標本 4 と 1 の差 GL 4,761 px・WebGPU 4,158 px。1 コマ（記録）: GL 0.344〜0.539 ms・WebGPU 0.460〜0.578 ms。
  - `make webgpu-v1-check` 緑・`make gl-parity` 緑（GL の道は触っていない）。テンプレ 3 本の `reference-check` 緑（rpg 16・novel 45・tidepool 8）。
  - `lint-max-lines` 緑・`lint-huge-methods` 緑（`bench/webgpu_v1` と `bench/webgpu_v2` の jar を JARS で渡した）・`gl-jar-pin-check` 緑（`render_gl/java` は触っていない）。
  - `gl-capture-check` は流していない（GL の道を触っていないため）。
- 持ち越し:
  - R2b と P8 の小分けごとに、同じ 2 本（写しの作り方は上）を流して欠けの表が減るのを見る。
  - ビルボード・環境マップ・preload は 2 本で確かめられない（上の 7）。
  - 窓の WebGPU の垂直同期（上）。
  - `WebGpuPaint.pasteScene` → `notePasted` の配線を守るテスト（小分けの (0)）。

### 12.27 R2b・P8 の (0) と (1): 3D の分を子の mod へ・奥行きの書き出しと `ScenePassSpec`（2026-11-16・この Mac・Dawn の Metal だけ）

表の 13・14 行目の小分け (0) と (1)。engine の pub（ゲームから見える API）は増えていない。GL の絵は変えていない（下の門）。

- **(0) `WebGpuPaint` の 3D の分を子の mod へ**: 3D の描き手へ貸す Host・場面の design 領域・prepare の呼び出し（診断の知らせを含む）・貼る所を `RenderPaint.Internal.WebGpuPaint.Scenes`（`prepare`・`paste`）へ移した。動きは同じ。
  - 兄弟（例 `RenderPaint.Internal.WebGpuScenes`）でなく子の mod にした: Host は `WebGpuPaint` の encoder・submit・数え（`encoderOf`・`flushPending`・`skipMany`・`frameCounters`）を借りるので、兄弟にするとそれらを pub にすることになる。子の mod は親の pub でない物に届く。
  - `WebGpuPaint.flix` は 1,101 → 1,068 行（上限 1,200）。
  - 配線を守るテスト `TestScenesDawn`（Dawn を開く・`WebGpuPaint` の子の mod から `openPass` と `flushPending` を直に呼ぶ）: 場面を描く → submit → `Scenes.paste` で 2D の pass に貼る → 同じ描き先をもう一度描く、で 2 回目が submit を 1 回頼む。
    **`paste` の中の `notePasted` を外すと「expected 1, but got 0」で落ちる**のを確かめた（12.25・12.26 の持ち越しを埋めた）。
- **(1) 決めた事 1 — `ScenePassSpec` の形**: `Render3d.ScenePlan.ScenePassSpec` は `Color`・`DepthOut({ near, range })` の enum（影の地図は (4) で `ShadowMap(light)` の case を足す。今は作っていない）。
  - 計画が決める: `GroupedScene` と `ScenePlan` に `mainPass`（場面の置いた物を場面の描き先へ描く pass。影の地図の pass は含まない）の欄を足し、`groupScene` が `Output` から 1 回だけ決め（`passSpecOf`・pub でない）、
    候補の分け方と `sceneDrawsOf` は `mainPass` を見る（`Output` を見直さない）。
  - 計画の答え: `Render3d.SceneList.buildScenePasses(plan)`（1 体ごとの値の番号を振り終えた `ScenePlan[MeshBatch]` を丸ごと受ける。(4) で影の組を足す時に引数を替えずに済む）が `ScenePasses = List[(ScenePassSpec, SceneList)]`（今は場面ごとに 1 組）を出す。GL（`Render3d.prepareScenes`）と WebGPU（`numberInstances`）の両方がこれを呼ぶ。
    `ScenePlan` に `SceneList` を直に持たせなかったのは、行の 1 体ごとの値の先頭が backend の番号の振り方（GL は `Instancing.upload`・WebGPU は `numberSpan` で instance の buffer）で決まり、計画の時には決まらないため。
  - 描き先: 2 つの case はどちらも「色 1 つ（場面の描き先の形式）と深度」で、2D の `PassSpec` の `ColorAttachment` と `DepthStencil.Depth` と同じ組（enum の doc に書いた）。
    **texture の番号は持たせなかった**: 場面の描き先は backend が場面の番号で持つ（WebGPU の `SceneTarget`・GL は 2D の描き先か Design の描き先）。2D の `PassTarget` の型をそのまま使う形は、影の地図（色を持たない）を `Target(ColorAttachment, …)` に入れられないので取らなかった。
    attachment の列を値で持つ形（`{ color = Option[…], depth = DepthStencil }`）は、今の 2 つの case で同じ値しか返さず読む所が無いので、影の地図を足す時に入れる。
  - GL: `GlRows.SceneInputs#list` を `passes` にし、`uploadRows` は pass ごとの形の置き場（`List[Array[Int32]]`）を返す。`Render3d.drawScene` は pass ごとに `drawPass`（色の pass はビルボード・半透明も重ねる・`DepthOut` は `MaterialPass.Depth` で行とビルボード）。
    `MaterialPass`（GL の材質の道の中の enum）は残した: 影の地図の case は材質の道を通らない（`Render3d.Shadow` の別のプログラム）ので、`ScenePassSpec` に寄せると材質の道に読まない case が生える。
    ビルボードの灰色と空の白は今も `scene#output` で決める（どちらも行になっていない間は、場面の pass が 1 つで spec と output が 1 対 1・WhyNot に書いた）。
- **(1) 決めた事 2 — WebGPU の奥行きの書き出し**: `DepthOut` の pass は、頂点の色の頂点シェーダー（`litVertexSource`）と、GL の `depthFragmentSource` と同じ式の `Render3dWgsl.depthFragmentSource`（`vWorld` だけを読み、`depthGray` の灰色を書く）の pipeline で描く。
  pipeline の鍵は (形式, 標本, pass の番号)。奥行きの書き出しの pipeline は起動の時に作らない（画面の RGBA8・標本 1 の色の pipeline だけを作る今の方針のまま。初めて Output.Depth が出たコマで Dawn が組み終えるのを待つ）。
  - pass ごとに色と深度を消す（GL は場面の頭で 1 回）。列の頭の pass だけ消して残りを前の中身から描く形は入れていない: 今は列に pass が 1 つで、2 つ目を足す (4) の影の地図は描き先が違う（WhyNot に書いた）。
  - 場面の値は `mainPass` で書く（場面の値の buffer は描き先ごとに 1 つで、writeBuffer は encoder の pass より先に効くので、1 つの encoder の中で pass ごとに書き替えるとどの pass も最後の値で描く。WhyNot に書いた）。
  - 描き先は**場面の描き先のまま**（2D の Pass の形式 Rgba8Unorm か Rgba16Float）。R32F は作らない: GL も Output.Depth を 2D の Pass の色へ灰色で書き、被写界深度はその R を読む（`RenderTarget.Format` に R32F は無い）。場面の texture を α を掛けた後の値で貼る道（V2 の A）はそのまま。
  - 場面の値: `uDepthRange`（224・228）と `uDepthOut`（248）は `packPassValues` が毎回書く（入れ物は場面をまたいで使い回すので、色の pass で `uDepthOut` を 0 に戻す。幅は GL の `putDepthRange` と同じく 0.000001 を下限）。
    `uDepthOut` は今の頂点の色の道では読まない（材質の frag が読む・(2)）が、書く欄の組を pass で変えないために書く。
  - 地の色（`clearOf`）: GL と同じく空の無い場面は background（無ければ透明）。奥行きの書き出しで空を塗る場面（`Scene3d.drawnSkyOf`）は一番奥の白（GL の空の frag の `uDepthOut` の枝と同じ）。
  - 奥行きの書き出しで、まだ GL と同じに書けない物は描かずに（か形のまま書いて）数える: 骨つきの物（飛ばす）・cutout と両面の材質の物（「3D の奥行きの書き出しの材質の物（cutout と両面を見ずに形で書く）」。
    WebGPU は材質を全部「使えない」と答えるので頂点の色の道へ回り、裏の面の間引きと cutout の抜きが GL と違う。(2) で材質の道に乗る）・ビルボード（飛ばす）。影と環境マップは奥行きの書き出しで読まないので数えない。
  - スマホの上限（12.24）の内: varying は頂点シェーダーが 4 つ出し、frag は 1 つ読む・bind group は 1 つ（場面の値）・頂点の buffer 2 本・storage は使わない。
- **確かめ — `bench/webgpu_v2`** に 2 場面を足した（部屋を yaw 0.3 で・near 16・幅 200 = 目から 1 m で黒・13.5 m で白）:

  | 場面 | 違う画素（許容） | ±2 以上（許容） | 差の最大（許容） |
  |---|---|---|---|
  | roomDepth（画面へ直に・Native・地の色は部屋の黒） | 3 px / 518,400（16） | 1 px（8） | ±4（±16） |
  | roomDepthPass（白で消した Rgba16Float の Pass に地の色の無い奥行きの書き出しを描き、画面いっぱいに貼る＝ゲームの被写界深度の形） | 0 px（0） | 0 px（0） | ±0（±0） |

  - 許す差の理由: roomDepth の 3 px は room（14 px・±82）と同じく、三角形のふちと重なる面で勝つ面が奥行きの丸めで入れ替わる画素【推: 画素を 1 つずつは見ていない。room と同じ所で起き、灰色は重なる 2 面の距離の差しか違わないので差の最大が小さい】。
    式（距離・near・幅・空の白）を取り違えれば面の中が丸ごと違い、万 px の桁になる。roomDepthPass は design の解像度で描くので 0 px（roomDesign と同じ）。
  - 絵: `bench/webgpu_v2/debug/{gl,webgpu}/roomDepth.png`・`roomDepthPass.png`（git の外）。目で見て、家具の手前が黒く奥の壁へ白くなる灰色の坂が GL と同じ。
- **確かめ — 実物の 2 本**（V2b の写しを写し直し、engine をこの worktree に向けた。流し方は 12.26 と同じ・`FGE_JAR_CACHE=off`・`FLIX_GE_HIDDEN=1`・`RUN_SECONDS=40`・頭の 64 コマ）:
  - **奥行きの書き出しの欠けは 6 場面とも 0**（表から行が消えた）。3D のぼけが直った: fps3d_lab の部屋・礼拝堂、みやげの町の arrival・market・night で、WebGPU の絵が GL と同じ所にピントが合い（部屋は中ほどの本棚と卓・町は画面の中ほど）、
    GL と同じく手前と奥がぼける（町の左下の木など）。V2b では WebGPU だけ画面の全部がぼけていた。WebGPU の誤り 0・落ちた場面なし。
  - 欠けの表（起動から 300 コマの表の 1 コマあたり。V2b の表との違いだけ）:

    | 種類 | fps3d_lab 部屋 | 礼拝堂 | 通路 | みやげの町 arrival | market | night |
    |---|---|---|---|---|---|---|
    | 奥行きの書き出し（Output.Depth・場面） | 0.9 → **0** | 0.9 → **0** | 0 | 0.6 → **0** | 0.9 → **0** | 0.9 → **0** |
    | 骨つきの物 | 12.8 → 25.2 | 0.0 → 0.0 | 0.0 → 0.0 | 43.1 → 84.5 | 63.7 → 81.4 | 63.7 → 86.2 |
    | 奥行きの書き出しの材質の物（cutout と両面） | 0 | 0 | 0 | 0 | 0 | 0 |

    - 骨つきの物が 2 倍前後になったのは、奥行きの書き出しの場面の中身を数えるようになったため（V2b では場面ごと 1 回だけ数えていた・12.26 の必須 1 の (a)）。同じ人を色の場面と奥行きの場面で 2 回描くので、欠けも 2 回。
      market は 300 コマのうち頭の読み込みのコマの数が流した回で違う（12.26 と同じ注意）。
    - 奥行きの書き出しの材質の物（cutout と両面）は 2 本とも 0（奥行きの場面に cutout と両面の材質が無い【推: 2 本の材質を全部は読んでいない】）。
    - 材質の物・半透明・lightmap・影・空は V2b と同じ桁（(2) 以降）。
  - 絵の置き場: `/private/tmp/claude-501/-Users-abab-Desktop-flix-game-engine/1e409b86-520d-4126-86d6-d8af78577988/scratchpad/r2b/out/<ゲーム>-<場面>-<gl|webgpu>/frame-N.png`（**scratchpad の物は消えうる**）。
- テスト: render_gl 512 緑（前の 503 に 9 本: `TestScenesDawn` 1 本・`TestWebGpuScene3d` の奥行きの書き出しの欄 3 本（near と幅と旗・色の pass で旗を戻す・幅は下限 0.000001）と地の色 4 本（下のレビュー 1 回目の必須 1）・`TestSceneList` の pass が Output に従う 1 本。
  `TestWebGpuScene3d` の「Depth の場面は奥行きの書き出しだけを数える」を「描けない物だけを数える」へ替えた）。`TestWgslDawn` は奥行きの書き出しの frag を足して 368 本を Dawn で組んで誤り 0。偽の GL を通るテストは直さずに緑。
- 門（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal・2026-11-16）:
  - render_gl のテスト（`.layers/render_gl` で `flix test`）512 緑（main の 0.97.0 に rebase した後）。
  - `make gl-parity` 緑。**場面ごとの行（93 行）が (1) を入れる前の木（(0) のコミット）の行と 1 字も同じ**（GL の道は形を変えたが絵を変えていない）。
  - `make gl-capture-check`（基準 `bench/baseline/0.96.0/gl-capture-apple-m4-pro.sha256`）: a と b の 54 枚がバイトまで同じ・**基準とも 54 枚がバイトまで同じ**（差 0 枚。この worktree には 12.25 の novel の中断セーブが無い）。
  - `make webgpu-v1-check` 緑（36 場面・draw の数も GL と同じ・誤り 0・終わりの `bench/webgpu_v2` の型検査も緑）。
  - `make -C bench/webgpu_v2 run` 緑・誤り 0: room 14 px（±82）・roomTurned 8 px（±52）・roomDesign 0・**roomDepth 3 px（±4）・roomDepthPass 0**・railsMsaa 3,330 px（±55）・railsNoMsaa 0・
    railsMsaaClear 4,761 px（±54）・slant2dMsaa 5,040 px（±55）・標本 4 と 1 の差 GL 4,761 px・WebGPU 4,158 px。`SplitPassTrial` は pass ごとの組を読む形に直した（比べる中身は同じ）。
  - テンプレ 3 本の `reference-check` 緑（rpg 16・novel 45・tidepool 8）。
  - `lint-max-lines` 緑（`Render3d.flix` 1,119 行・`WebGpuPaint.flix` 1,068 行）・`lint-huge-methods` 緑（`bench/webgpu_v1` と `bench/webgpu_v2` の jar を JARS で渡した）・`gl-jar-pin-check` 緑（`render_gl/java` は触っていない）。
- レビュー 1 回目（86 点）への対応:
  - 必須 1（`clearOf` の空の白の枝にテストが無い）: `TestWebGpuScene3d` に 4 本 — 奥行きの書き出しで sky がある → 白（background があっても）・sky が無く background がある → background・
    色の pass で sky がある → 透明・sky が無く景色を背景に描く（`withEnvironmentAsBackground` で `drawnSkyOf` が Some）→ 白。
  - 必須 2（`scene3dCounts` の持ち越しの理由と行き先）: 下の持ち越しと 9 章の表の 14 行目に、外した理由と行き先 (2) を書いた。
  - 必須 3: `Render3d.flix` の `PassAround` と `around` を `PassContext` と `ctx` に。
  - 任意で直した物: `buildScenePasses` は番号を振り終えた `ScenePlan[MeshBatch]` を丸ごと受ける形に（WebGPU は影の材料を空にした plan を組んで渡す）・
    計画の欄 `pass` を `mainPass` に（(4) で影の pass と取り違えない）・`passSpecOf` を pub でなく・pass ごとに消す事と `writeSceneValues` が `mainPass` に縛られる事を WhyNot と上の決めた事 2 に・
    (4) の持ち越しに影の地図を 2D の並びより先に描く要と別の列の案・9.1 と 12.26 の 1 に 12.27 への書き戻し・欠けの表の「—」を 0 に・テストを use で短く・幅の下限のテストを値で比べる・奥行きの書き出しの pipeline を起動の時に作らない事。
- 持ち越し:
  - P8 の (1) の 3D の診断の数（`scene3dCounts`）を WebGPU で数える（今も「未計測」の知らせ）→ **(2) の材質と絵の組へ**。外した理由: 数える所（`Render3d.Counts.count` など）が GL の `State#countsHolder` に足す形で、
    WebGPU の描き手に同じ入れ物と draw の分かれた理由の数えを持たせる仕事が、Output.Depth（frag 1 つと場面の値の 3 欄）と別の大きさだった。分かれた理由の大半（材質・絵）が (2) で WebGPU に生まれるので、そこで一緒に数える。
  - 奥行きの書き出しの cutout と両面の材質（(2) の材質の道で）・骨つきの物（(3)）・ビルボード（(7)）。
  - 影の地図の pass（(4)）: `ScenePassSpec` に case を足し、計画が光ごとの組を出す。その時に attachment の列を値で持つ形と、pass ごとの描き先の付け替えを入れる。
    GL では影の地図を Design の場面が読むので 2D の並びより先に描く要があり、ShadowMap を同じ列（`ScenePasses`）に入れると GL の `drawScene` と WebGPU の `drawInto` の前提（列の pass は全部場面の描き先 1 つへ書く）が崩れる。
    影の pass を場面の列と別の列（例 `ScenePlan` の外の、prepare 1 回分の影の組）に持つ案も比べる。
  - 場面の値の buffer は場面の描き先ごとに 1 つで、pass が 2 つ以上になると pass ごとの値（奥行きの書き出しの旗・影の地図の目）を分ける要る【推: (4) で】。

### 12.28 R2b・P8 の (1b) と (2): 形と絵の番号の表を前半へ・材質と絵の組（2026-11-16・この Mac・Dawn の Metal だけ）

表の 13・14 行目の小分け (1b) と (2)。engine の pub（ゲームから見える API）は増えていない（足した型と関数は render_gl の中だけ）。GL の絵と GL の呼び出しの並びは変えていない（下の門）。

- **(1b) 形と 3D の絵の番号と寿命の表を前半へ**（R1b-1 の決め「表は前半・作る消すだけ backend」にそろえた）:
  - 新しい `Render3d.MeshTable`: 鍵（`Mesh3d.contentHash`）→ 番号・頂点の数・lastUsed・捨てた番号の使い回し・頂点の上限で捨てる物（`Render3d.meshEvictions` の順）を決める。GPU の形を作る・捨てるのは backend の `MeshAllocator{create, destroy}`。
    番号は計画が振り（`numberOf`・GPU には作らない）、backend は行を流す前に `ensure` で作る。GL は `State#meshEntriesRef`（番号 → VAO）・WebGPU は `WebGpuRows.MeshStore`（番号 → buffer）だけを持つ。
  - 新しい `Render3d.TextureTable3d`: 3D の材質の絵（`TextureSlot.Scene` = 場面の絵・`Copy` = 全体の登録の絵の段つきの写し）の鍵 → 番号・段の数・大きさ・作り直しの鍵（写しは元の絵の番号と版）・作れなかった絵の試し直しの間（60 コマ）・
    上限で捨てる物（`Render3d.Material.budgetEvictions`・先に上げた物は後へ）を決める。GL の `textures3dRef`・`mipCopiesRef`・`platformRetryRef` を畳み、GL は番号 → テクスチャ（`textureIdsRef`）だけを持つ。名前から鍵と段の数を引く `readOf`（`findTexture`・`mipKeyOf`・`levelsOf`）も前半へ移した。
  - `SceneList` の行に欄 7 = 形の番号を足した（末尾。12.26 の確定どおり）。GL も WebGPU も描く時に番号で形を引く（`uploadRows` が行ごとの形の配列を返す形をやめた）。
  - 描き先・影の地図の寿命は (8) のまま。
  - GL の呼び出しの並びが変わらない理由: 作る所（`meshEntry`・`resolveTextureAs` の中）と順は前と同じで、表の側が番号を控えるだけ。計画が先に振る番号は GL を呼ばない。
  - テスト: `TestMeshTable`（番号を振るだけでは作らない・振った番号のまま 1 回だけ作る・上限で捨てて番号を使い回す・stamp が変われば捨ててから作る・作れない絵は 60 コマ試さない・枚数の上限で古い絵を捨てる ほか）。偽の GL を通るテストは置き場の欄の読み方だけ直した（`state#meshesRef` → `MeshTable.createdOf`・`textures3dRef` → `TextureTable3d.createdOf` の場面の絵）。
- **(2) 材質と絵の組**:
  - **行と values・reads**（2D の R1b-6 と同じ流儀）: `SceneList` に `values`（Float32）と `reads`（Int32）を足し、行を 11 欄にした（8 = 材質の値の先頭・9 = 絵の組の先頭・10 = 絵の組の数。描く物のある材質の行だけ。ほかは 8 が -1）。
    並びは新しい `Render3d.MaterialValues`: 材質 1 つ = 物ごとの値の区画 64 個（Render3dWgsl の `R3dDraw`: cutout・法線マップの強さと段の数・lightmap の段の数）＋ sg の区画（`ShaderGen.Wgsl.compile3d` の slots と同じ並び: uTime・uTexLevelsN・uParamN を 64 個の倍数へ切り上げ）。
    どちらの区画も 256 バイトの倍数の位置（WebGPU の binding の位置のそろえ）。絵の組は 1 つ 3 個（絵の表の番号・補間・読み方）で、材質の絵 → 法線マップの順。uParamN の並びは材質の木の鍵ごとに 1 回だけ求めて控える（`layoutOf`）。
    GL は今も materials から uniform を差す（values と reads は読まない）。計画が GL にも values と reads を書くのは、行の作り方を backend で分けないため（GL に足した仕事は材質の行ごとの名前の引き当てと値の書き込み）。
  - **pipeline は材質の handle で決める**: WebGPU は計画の問い合わせ（`MaterialRequest`）ごとに `WebGpuMaterials.resolve` が材質の frag を組み（`ShaderGen.Wgsl.compile3d(…, 1)` と `Render3dWgsl.materialFragmentSource`）、順の番号（program の番号）で答える。
    行の欄 1（問い合わせの番号）で program を引き、pipeline は (program・描き先の形式・標本・形の頂点のバイト数) の鍵で控える。材質の頂点シェーダーは新しい `Render3dWgsl.materialVertexSource(uv, lightmap)`（GLSL の `materialVertexSource` の骨の無い版と同じ式）。
  - **bind group**（P8 の WGSL の決まり）: 0 = 場面（今までどおり）・1 = 材質（sg と絵と sampler・`R3dDraw` を binding 16・法線マップを 17・18）・2 = storage（まだ使わない）。`Render3dWgsl.drawDeclarations` を group 2 から group 1 へ移し、`uCutout` を f32 にした（values は Float32）。
    group 1 は行ごとに作って submit の後に手放す（2D の面と同じ。前の材質の行と同じ付け方の行（flagSameBinding）は付け直さない）。
  - **形の版**（P8 の WGSL の決まり）: WebGPU の形の頂点を版ごとに 1 本の buffer へ交互に並べた（位置・法線・色 9 個 ＋ uv つきは uv 2 個とタンジェント 4 個 ＋ 2 本目の uv つきは 2 個）。頂点の色の pipeline も頂点のバイト数を鍵に足した。
  - **材質の絵**: 場面の絵は CPU で段を作って（`Mip.build`・GL の CPU の段と同じ鍵）BGRA8 で上げる。全体の登録の絵は 2D の描き手の texture を段 1 つのまま借りる（`Host#textureOf`・`textureById` を足した）。レンダーターゲットの絵（上下逆に読む物）は表に載せず黒で読む。
  - **描く版と描かない版**（`WebGpuMaterials.isDrawable`）: 描く = 骨の無い・lightmap の無い・半透明でない・alpha to coverage でない材質（uv・法線マップ・両面・cutout・metallic と roughness を含む）。描かない版は順の番号 0 で答え、計画が頂点の色の道へ回す（数えて知らせる）。
    - alpha to coverage: `render_gl/java` の `RenderPipelineDesc` に口が無いので描かない。計画には描き先の能力として alpha to one が無いと答えるので、計画は cutout を discard の版にする（ブラウザの GL と同じ）。9.1 の「PC の cutout の縁（discard か sample_mask か）」は比べていない（持ち越し）。
    - **lightmap は (5) に残した**（→ 12.32 で入れた・R3dDraw に色空間と強さを足し、R3dScene の 2 欄は pad にした）: lightmap の段の数・色空間・強さは物ごとの値なのに、今の WGSL は色空間と強さを場面の値（`R3dScene`）に置いている。物ごとの値の区画へ移す直しと lightmap の絵の bind を一緒に入れる方がまとまる（lightmap の行は 1 行 1 体で、reads の組が 1 つ増えるだけ）。
  - **決めた事 — 材質の値は uniform の 256 バイトの区画で読む**（9.1 の流儀で 2 つ作って測った）:
    - 比べた 2 つ: (A) uniform の buffer を行ごとに 256 バイトの位置で bind する・(B) 同じ区画を読むだけの storage で bind する（WGSL の `var<uniform> sg` と `var<uniform> r3dDraw` を `var<storage, read>` に替え、layout を READ_ONLY_STORAGE に）。
    - 測り方: `bench/webgpu_v2` の部屋に、params だけが違う材質の小物 300 個（材質の行が 300 本を超える）を足した場面を、貼る形 A の道で 300 コマ描いて GPU を待つ時間の中央値（5 回）。
    - 数（ms）: uniform 2.949・2.711・2.712・2.693・2.759、storage 3.103・2.709・2.683・2.695・2.697。差は回ごとの揺れ（±0.2 ms）の内。
    - **言える範囲**: 比べた 2 つはどちらも行ごとに `createBindGroup` を作る形で、違いは shader が区画を読む読み方だけ。1 コマの時間は group を作る CPU の仕事が大半なので、読み方の差は出にくい。
      つまり分かったのは「行ごとに group を作る形の中では、uniform と storage は同じ速さ」まで。storage が本当に効く形（group を材質か場面に 1 つ作り、firstInstance か draw の番号で区画を引く）は比べていない。
      測ったのはこの Mac（Apple M4 Pro・Dawn の Metal）だけで、スマホ（adreno）は測っていない。
    - uniform にした理由: (1) `ShaderGen.Wgsl` が出す `var<uniform> sg` のまま使える（storage にするには engine の ShaderGen の出口を替えるか字を置き換える）・(2) スマホの上限（12.24）の内: 1 つの binding は 256〜512 バイトで `maxUniformBufferBindingSize` 65,536 に遠く、
      「uniform は 64 KiB・256 バイト揃えで 256 個が上限」は buffer 全体を 1 つの binding にした時の数で、行ごとに位置を替えて bind する今の形には掛からない（300 個の場面で確かめた）。値の buffer は足りなければ倍に作り直す。
    - storage の版は、group 1 つで区画を引く形を測る時の比べ相手として `WebGpuMaterials.ValuesBinding.Storage`（`WebGpuRenderer.createWith`・bench の `SplitPassTrial.openWith`）に残した（WhyNot に書いた）。
  - **1 体ごとの値と材質の値の送り方**: 場面ごとに両方の大きさを先に見積もり、どちらかが空きに入らなければ先に 1 回 submit してから両方を送る（片方を送った後にもう片方が submit すると、次の場面が先に送った方を頭から上書きするため）。
  - **3D の診断の数を WebGPU でも数える**（12.27 の持ち越し）: `Render3d.Counts` の関数を record の欄の組（`countsHolder`・`phaseNsHolder`・`materialBuildsRef`）で受ける形にし、WebGPU の描き手の状態に同じ欄を持たせた。
    数える物: 置いた物と描く物・draw call と分かれた理由（行の欄 5）・落とした光・形を上げた数と捨てた数・組んだ材質・CPU の区間（split と draw）。`WebGpuPaint` の診断が `scene3dCounts` を返し、「未計測」の知らせを消した。集めていない間は毎コマ捨てる（GL と同じ）。
- **確かめ — `bench/webgpu_v2`** に 6 場面を足した（部屋の物を箱投影の uv にし、CPU で作った市松の絵を貼る・yaw 0.3）:

  | 場面 | 違う画素（許容） | ±2 以上（許容） | 差の最大 |
  |---|---|---|---|
  | matTextured（絵つき・Linear） | 222（450） | 75（150） | ±77 |
  | matCutout（穴あきの絵・Nearest・cutout） | 6（32） | 5（16） | ±149 |
  | matTwoSided（cutout ＋ 両面・物を床から 3 cm 浮かせる） | 25（50） | 25（50） | ±68 |
  | matNormal（絵 ＋ 縞の法線マップ） | 248（500） | 76（150） | ±75 |
  | matDepth（cutout ＋ 両面の奥行きの書き出し・同じく浮かせる） | 2（8） | 1（4） | ±105 |
  | matMany（params だけ違う材質 300 個） | 219（440） | 214（430） | ±147 |

  - 許す差の理由: ±2 以上の画素は room と同じく重なる面（床と敷物・天板と小物・格子に重ねた小物）で勝つ面が奥行きの丸めで入れ替わる所に固まる（差の絵で確かめた）。
    初めは matTwoSided が 1,251 px（両面にした敷物の裏の面が床と同じ高さで勝ち負けを争う）で、両面を守る門になっていなかった（レビューの必須 2）。殻でない物を床から 3 cm 浮かせて争いを無くし、許容を締め直した。
    ±1 の画素は面の中に点で散る【推: 絵の段の間の補間と sRGB の戻しの丸め】。上限は実測のほぼ 2 倍・差の最大は面の入れ替わりで切らない。
  - **壊して確かめた**（同じ日に 1 回ずつ・確かめた後に戻した）:
    - 材質の頂点シェーダーで uv の上下を返す（`vUv = (u, 1 − v)`）: 絵つきの 5 場面が 47.8 万〜51.7 万 px 違って落ちる（matTextured 515,981 px）。matMany（絵なし）は 219 px のまま。
    - 両面の裏の法線の向きを逆にする（`facingNormal` の select を入れ替える）: matTwoSided が 331,806 px 違って落ちる（ほかは同じ数）。
    - 両面の材質の裏も間引く（pipeline の CullMode を BACK）: matTwoSided 66,355 px・matDepth 65,617 px 違って落ちる。
  - 絵（git の外）: `bench/webgpu_v2/debug/{gl,webgpu}/mat*.png`。写しと差の絵: `/private/tmp/claude-501/-Users-abab-Desktop-flix-game-engine/1e409b86-520d-4126-86d6-d8af78577988/scratchpad/r2c/v2shots/`（**scratchpad の物は消えうる**）。
- **確かめ — 実物の 2 本**（12.27 と同じ流し方・engine は 0.97.0 の fpkg・`FGE_JAR_CACHE=off`・`FLIX_GE_HIDDEN=1`・`RUN_SECONDS=40`・頭の 64 コマ）:
  - **材質の物の欠けは 6 場面とも 0**（fps3d_lab の部屋 110.5・礼拝堂 119.3 → 0）。絵が貼られた: fps3d_lab の部屋の板の床・漆喰の壁・梁・本棚・敷物、礼拝堂の石の壁と柱・床・長椅子、みやげの町の家の壁と屋根が GL と同じ絵になった。
    全体の登録の絵（fps3d_lab の床と壁）は初めの流しでは黒かった（WebGPU が登録の絵を読まなかった）ので、2D の描き手の texture を借りる形を足して流し直した。WebGPU の誤り 0・落ちた場面なし。
  - 欠けの表（起動から 300 コマの表の 1 コマあたり。12.27 の表との違い）:

    | 種類 | fps3d_lab 部屋 | 礼拝堂 | 通路 | みやげの町 arrival | market | night |
    |---|---|---|---|---|---|---|
    | 材質の物（頂点の色で描く） | 110.5 → **0** | 119.3 → **0** | 1.6 → **0** | 11.9 → **0** | 26.4 → **0** | 33.3 → **0** |
    | lightmap の材質の物（頂点の色で描く・今は材質の物の内数でない） | — | — | — | 7.9 | 14.5 | 20.5 |
    | 半透明の材質の物 | — | — | — | 12.5 | 12.5 | 8.6 |
    | 骨つきの物 | 25.7 | 0.0 | 0.0 | 85.8 | 85.8 | 86.2 |
    | 影・空 | 0.9 | 0.9 | 0.0 | 0.6 | 0.6 | 0.6 |

    - lightmap の物は前は「材質の物の内数」で今の光で材質を描くと数えていたが、今は lightmap の版を描かないので、lightmap の物は頂点の色で描く（町の石畳が白い）。(5) で埋める。
    - market の lightmap の物が 21.5 → 14.5 なのは、300 コマのうち頭の読み込みのコマの数が流した回で違うため【推: 12.26 と同じ注意】。
  - 残った見え方の違い: 人（骨つき・(3)）・影（(4)）・lightmap と空（(5)）・半透明（(6)）のほかに、全体の登録の絵に段が無いので遠くの床と壁が GL より細かくちらつく（礼拝堂の石の目地がやや明るく硬い）。
  - 絵の置き場: `/private/tmp/claude-501/-Users-abab-Desktop-flix-game-engine/1e409b86-520d-4126-86d6-d8af78577988/scratchpad/r2c/out/<ゲーム>-<場面>-<gl|webgpu>/frame-N.png`（登録の絵を借りる前の流しは `out-first/`。**scratchpad の物は消えうる**）。
- テスト: render_gl 525 緑（前の 512 に `TestMeshTable` 11 本・`TestSceneList` の材質の値の区画 1 本・`TestWebGpuScene3d` の描ける材質を数えない 1 本。`TestWebGpuScene3d` の数えの 3 本は種類の名前と、描ける材質を数えない事に合わせて直した）。
  `TestWgslDawn` は材質の頂点シェーダー 3 本を足して 371 本を Dawn で組んで誤り 0。偽の GL を通るテストは置き場の欄の読み方の直しだけで緑。
- 門（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal・2026-11-16。(1b) のコミットと (2) のコミットの両方で流した）:
  - render_gl のテスト（`.layers/render_gl` で `flix test`）: (1b) 520 緑・(2) 525 緑。
  - `make gl-parity` 緑。場面ごとの行（93 行）が (1b) の木と (2) の木で 1 字も同じ。
  - `make gl-capture-check`（基準 `bench/baseline/0.96.0/gl-capture-apple-m4-pro.sha256`）: (1b)・(2) とも a と b の 54 枚がバイトまで同じ・**基準とも 54 枚がバイトまで同じ**（差 0 枚）。
  - `make webgpu-v1-check` 緑（誤り 0・draw の数も GL と同じ・終わりの `bench/webgpu_v2` の型検査も緑）。
  - `make -C bench/webgpu_v2 run` 緑・誤り 0（今までの 10 場面は 12.27 と同じ数・足した材質の 6 場面は上の表）。値の binding の比べの 2 回目（門の回）: uniform 2.986・2.73・2.722・2.73・2.704 ms・storage 2.941・2.717・2.715・2.711・2.69 ms。
  - テンプレ 3 本の `reference-check` 緑（rpg 16・novel 45・tidepool 8）。
  - `lint-max-lines` 緑（`Render3d.flix` 1,111 行・`WebGpuPaint.flix` 1,072 行・`WebGpuRenderer.flix` 687 行）・`lint-huge-methods` 緑（`bench/webgpu_v1` と `bench/webgpu_v2` の jar を JARS で渡した）・`gl-jar-pin-check` 緑（`render_gl/java` は触っていない）。
- 持ち越し:
  - 全体の登録の絵の段つきの写し（WebGPU は段 1 つの 2D の texture を借りている。GL は読み戻して段を作る）。
  - WebGPU の材質の program の LRU と、木の鍵がぶつかった材質の見分け（GL の `reuseOrRebuild`）。組めない材質の WGSL は device の誤りに数えられる（12.22 と同じ根）。
  - 3D の材質の絵の置き場の上限は GameEngine の既定（256 MB・64 枚）で、project.json の値を WebGPU の描き手に届けていない。
  - PC の cutout の縁（discard か sample_mask か・9.1）と alpha to coverage（java の口）。
  - lightmap の版（(5)）: 物ごとの値の区画へ色空間と強さを移し、lightmap の絵を reads に足す（→ 12.32 で済）。
  - GL は values と reads を読まない（材質の uniform を今の道で差す）。GL を values から差す形に替えるかは、GL の呼び出しの並びを変えてよい小分けで決める。
  - 値の binding の測り直し（P9・P10 の前）: 行ごとに group を作る代金（材質 300 個で 1 コマ約 2.7 ms の大半）と、group を材質か場面に 1 つ作って firstInstance か draw の番号で区画を引く形（storage）か dynamic offset（java の口が要る）を比べる。スマホ（adreno）でも測る。
  - レビュー 1 回目（85 点）の任意で持ち越した物（直したのは 5 = storage の版を残す理由の WhyNot と 9 = r3dDraw の binding の大きさを関数に）:
    - budgetEvictions・isOverBudget・Budget・meshEvictions を表の mod の側へ移す（前半の表が GL の `Render3d.Material` と `Render3d` に寄りかかっている）。
    - GL が読まない values と reads を毎コマ作る代金を `bench/scene3d` で前後に測る。
    - `TextureTable3d.touch` が毎回 Map を作り直す → lastUsed を Array[Int64] にして MeshTable にそろえる。
    - 鍵（場面の絵・段つきの写し・作り直しの鍵）を TextureTable3d の 1 か所にまとめ、GL と WebGpuMaterials の両方から呼ぶ。
    - 作っていない番号の掃除が、上限を超えるまで走らない（MeshTable.trim）。
    - MaterialValues の uParamN と uTexLevelsN の位置が ShaderGen.Wgsl.compile3d の slots と同じ事のテスト。
    - pipeline の控えの鍵の数（`-2 - stride - 1000000 * pass`・`id * 4096 + stride`）を小さな enum にする。
    - WGSL を組めない材質を欠けの表に数える・いつも 0 の種類（alpha to coverage の材質の物）を doc に書くか外す。
    - borrowTexture の作り直しの鍵（texId と version）が、2D の絵の作り直しで変わるか確かめる。
    - uploadTextures・countRows の List.range を添え字の輪にする。
    - TestMeshTable の同居テストを分け、足りないテスト 3 本（上限超えで作っていない番号も外す・60 コマ後に試し直す・sweep の順）を足す。

### 12.29 R2b・P8 の (3): 骨と instance（2026-11-16・この Mac・Dawn の Metal だけ）

表の 13・14 行目の小分け (3)。engine の pub（ゲームから見える API）は増えていない（足した型と関数は render_gl の中だけ）。GL の絵と GL の呼び出しの並びは変えていない（下の門）。

- **R2b — `DataTexture`・`Instancing`・`JointTexture` を GL の backend の中へ**:
  - 前半（計画の側。GPU を呼ばない）へ 2 つを分けた: 新しい `Render3d.PoseRows`（姿勢に行を割り当てる表・同じ姿勢かの見分け・行の順に joint 行列を詰める `packRows`）と、
    新しい `Render3d.InstanceValues`（1 体ごとの値の番号の振り方と詰め方・`PackMode`・`numberSpan`・`packDraw`）。計画（`Render3d.ScenePlan`）は `PoseRows` を、WebGPU は両方を使う。
  - GL の backend に残る物は `Render3d.GlRows` の子の mod へ移した: `Render3d.GlRows.DataTexture`（RGBA32F の絵の置き場と回し方）・`Render3d.GlRows.Instancing`（`upload`・`rowsFor`）・
    `Render3d.GlRows.JointTexture`（`upload`）。中身は前と同じで、mod の名前と `use` だけが替わった（`git mv` で履歴を残した）。
  - 3 つは `pub mod`（WhyNot に書いた）: 呼び手の `Render3d` と偽の GL を通るテストは `GlRows` の外で、pub でない孫の mod に届かない。親の `Render3d` が pub でないので、ゲームからは見えない。
  - 偽の GL を通るテスト（Batch・Instancing・JointTexture）は `use` の名前だけ直して緑（中身は替えていない）。
- **P8 — WebGPU で骨つきの物を描く**:
  - 計画に姿勢の行の上限（`poseRowLimit` = 姿勢の予算 64 MiB ÷ ジョイント 64 本の行 = 16,384）を渡し、計画が振った姿勢の行（`PoseRows`）を prepare ごとに 1 回詰める（頭の 16 バイトに 1 行のジョイントの数・その後に行の順の mat4）。
  - 頂点の色の骨つきの行（`kindSkinned`）と、骨つきの材質（`WebGpuMaterials.isDrawable` に骨つきを入れた）を描く。形の版の buffer の末尾にジョイントの番号（float 4 つ）と重み（4 つ）を足し、location 14・15 で読む。
    式は GLSL の `skinPrelude` と同じ（重みつきの joint 行列の和を位置に掛けてから model・法線とタンジェントは左上 3×3）。姿勢の行は 1 体ごとの値の normal1.w（GL と同じ並び）。
  - bind group（P8 の WGSL の決まり）: 0 = 場面・1 = 材質（骨つきの頂点の色の pipeline は空の group）・2 = 姿勢（読むだけの storage）。group 2 は pass の頭で 1 回付ける。
  - 寿命の決まり: 姿勢は prepare で 1 回詰め、encoder の中で初めて使う場面で送る（submit の数 `epoch` で控え、submit の後の最初の場面で送り直す）。
    1 体ごとの値・姿勢・材質の値の空きを場面ごとにまとめて見積もり、どれかが入らなければ先に 1 回 submit する（片方を送った後にもう片方が submit すると、次の場面が先に送った方を頭から上書きする・12.28 と同じ決まりに姿勢を足した）。
    group 2 は submit の後に手放す。回帰テスト `TestWebGpuScene3dDawn.testPosesAreResentAfterSubmit`（同じ encoder の 2 回目は同じ group・submit の後は新しい group）。
  - 欠けの数え（`skipsOf`）から「骨つきの物」の種類を外した。描けない版の材質の骨つきの物（半透明・alpha to coverage）は骨つきの頂点の色で描き、その材質の種類で数える。
- **決めた事 1 — 姿勢は group 2 の読むだけの storage**:
  - uniform にしない: 1 回の prepare の違う姿勢を 1 つの binding に入れると 64 KiB を超える（ジョイント 64 本の姿勢 1 つで 4 KiB・16 体で上限）。姿勢ごとに区画を bind すると行ごとに group を作ることになり、姿勢を共有する batch が分かれる。
  - GL と同じ RGBA32F の絵にしない: storage は番号で引くだけで、絵の幅（4 × ジョイントの数）と高さの上限に縛られない。WebGPU の core は頂点の段の storage を保証する（スマホの上限 12.24 の storage 128 MiB の内・行 16,384 本 × 64 本で 64 MiB）。
  - 頂点の段で storage を読めない機種（WebGPU の互換の版）では骨つきの物が描けない【推: 互換の版は今の対象（PC の Dawn・Chrome・iPhone の Safari）の外】。
- **決めた事 2 — 1 体ごとの値は instance の頂点の buffer のまま**（storage から `instance_index` で引く形と比べた・9.1 の流儀）:
  - 比べ方: 頂点の色の pipeline だけを storage から引く形に一時の直しで替え（group 2 に 1 体ごとの値の buffer 全体・頂点の buffer の 1 番を外す）、`bench/webgpu_v2` の小物 4,800 個の場面（形 2 種）を貼る形 A の道で 300 コマ描いて GPU を待つ時間の中央値を、
    5 区間 × 2 回ずつ流した（JIT の温まる頭の 2 区間を除いた 3 区間ずつ）。一時の直しはコミットに入れていない。storage の形でも crowd と room の差の画素は今の形と 1 px も違わなかった（読む値が同じ）。
  - 数（ms）: 頂点の buffer 3.659・3.44・3.238／3.213・3.253・3.182、storage 3.443・3.229・3.17／7.713・3.292・3.245（7.713 は 1 区間だけの外れ）。差は揺れの内。
  - 言える範囲: 1 コマの大半は CPU（計画と 1 体ごとの値を詰める所）で、頂点の取り込みの差は出にくい。測ったのはこの Mac（Apple M4 Pro・Dawn の Metal）だけで、スマホ（adreno）は測っていない。
  - 頂点の buffer にした理由: (1) 速さが同じ・(2) 2D のスプライト（V1）と同じ形・(3) 属性の数は一番多い版（uv つきの骨つきの材質: 0〜2・3〜10・11・12・14・15）でも 15 個で上限 16 の内・
    (4) storage にすると group 2 を姿勢と 1 体ごとの値で分け合うことになり、骨の無い物まで頂点の段の storage に頼る（互換の版で全部が描けなくなる）。
  - 骨つきの版は lightmap を読まない（`Scene3d.lightmapOf` が None）ので、(5) で lightmap の版を描くようにしても一番多い版は 15 個のまま（uv と lightmap の版は 14 個）・残りは 1 個。
- **直しながら足した物**（12.28 の持ち越しのうち (3) で触った所）:
  - pipeline の控えの鍵の数（`-2 - stride - 1000000 * pass`・`id * 4096 + stride`）を enum `WebGpuMaterials.BoundPipeline`（`Unbound`・`Shape(pass, 頂点のバイト数, 骨つきか)`・`Material(program, 頂点のバイト数)`）にした。
  - `countRows`・`uploadTextures`・材質の group の絵を付ける所・場面の値の光の配列を詰める所の `List.range` を添え字の輪にした（毎コマ通る所）。
- **確かめ — `bench/webgpu_v2`** に 4 場面を足した（部屋・正面）。人形はジョイント 3 本（根・腰・胸）で曲がる柱（4 面・高さで 6 つのリングに割り、頂点を下と上のジョイントへ高さで振り分けた重み）を 24 体。
  姿勢は人形ごとに違い、3 体に 1 体は同じ 1 つの姿勢を共有する（同じ行を読む）。向きと tint も人形ごと:

  | 場面 | 違う画素（許容） | ±2 以上（許容） | 差の最大（許容） |
  |---|---|---|---|
  | skinned（頂点の色の人形 24 体） | 9（32） | 1（8） | ±70（255） |
  | skinnedTextured（絵つきの材質の人形・uv とタンジェント） | 46（100） | 1（8） | ±70（255） |
  | skinnedDepth（人形の奥行きの書き出し） | 3（8） | 0（4） | ±1（±16） |
  | crowd（小物 1,200 個・松明と骨の無い柱の 2 種・物ごとに向きと tint・行の頭が 1 体ごとの値の途中を指す） | 21（64） | 10（32） | ±146（255） |

  - 許す差の理由: ±2 以上の画素は room と同じく重なる面（人形と卓・小物どうし）で勝つ面が奥行きの丸めで入れ替わる所【推: 画素を 1 つずつは見ていない。room と同じ桁で、奥行きの書き出しは ±1 で止まる】。
    ±1 の画素は面の中に点で散る【推: 光の坂と絵の補間の丸め】。上限は実測のほぼ 2〜4 倍・差の最大は面の入れ替わりで切らない（skinnedDepth は roomDepth と同じ ±16）。
  - **壊して確かめた**（同じ日に 1 回ずつ・確かめた後に戻した）:
    - 骨の行列の掛け順を逆にする（WGSL の位置を `skin * vec4f(aPos, 1)` から `vec4f(aPos, 1) * skin` へ）: skinned 52,573 px・skinnedTextured 52,574 px・skinnedDepth 51,895 px 違って落ちる（crowd は 21 px のまま）。
    - instance の番号を 1 つずらす（`drawIndexed` の firstInstance を行の頭 + 1）: 3D の 15 場面が 31 万〜50 万 px（crowd 364,124 px）・rails の 3 場面が 6 千〜8.5 千 px 違って落ちる。
  - 絵（git の外）: `bench/webgpu_v2/debug/{gl,webgpu}/skinned*.png`・`crowd.png`。目で見て、人形が腰と胸で曲がり、GL と同じ形と色。
  - 1 コマ（記録・門ではない）: 小物 1,200 個と人形 24 体の場面を貼る形 A で 300 コマの中央値（5 区間）: 2.838・1.97・1.302・1.373・1.282 ms。
- **確かめ — 実物の 2 本**（12.28 と同じ流し方・engine は 0.97.0 の fpkg をこの worktree で作り直した物・`FGE_JAR_CACHE=off`・`FLIX_GE_HIDDEN=1`・`RUN_SECONDS=40`（fps3d_lab の部屋は 70。40 では他の門と同時に流して 300 コマに届かなかった）・WebGPU だけ）:
  - **骨つきの物の欠けは 6 場面とも 0**（表から行が消えた）。fps3d_lab の部屋の衛兵と、みやげの町の主人公と町の人が WebGPU で描かれ、GL の同じコマと同じ姿勢（部屋の 50 コマ目・night の 40 コマ目を GL と並べて目で見た）。WebGPU の誤り 0・落ちた場面なし。
  - 欠けの表（起動から 300 コマの表の 1 コマあたり。12.28 の表との違い）:

    | 種類 | fps3d_lab 部屋 | 礼拝堂 | 通路 | みやげの町 arrival | market | night |
    |---|---|---|---|---|---|---|
    | 骨つきの物 | 25.7 → **0** | 0 | 0 | 85.8 → **0** | 85.8 → **0** | 86.2 → **0** |
    | lightmap の材質の物 | — | — | — | 7.9 → 7.8 | 14.5 → 21.5 | 20.5 → 30.3 |
    | 半透明の材質の物 | — | — | — | 12.5 → 12.4 | 12.5 → 18.6 | 8.6 → 12.7 |
    | 影・空 | 0.9 | 0.9 | 0.0 | 0.6 | 0.9 | 0.9 |

    - 「instance の物」という種類は欠けの表に元から無い（1 体ごとの値の batch は V2 から描いている）。この小分けの instance の分は 1 体ごとの値の置き場を決める事（決めた事 2）と、骨つきの batch に番号を振る事。
    - market と night の lightmap と半透明が増えたのは、300 コマのうち頭の読み込みのコマの数が流した回で違うため【推: 12.26 と同じ注意。V2b の表（21.5・30.3・18.6・12.7）と同じ数に戻った】。
  - 絵の置き場: `/private/tmp/claude-501/-Users-abab-Desktop-flix-game-engine/1e409b86-520d-4126-86d6-d8af78577988/scratchpad/r2d/out/<ゲーム>-<場面>-webgpu/frame-N.png`（market の GL は `lamplighter-market-gl`。**scratchpad の物は消えうる**）。
- テスト: render_gl 529 緑（前の 525 に 4 本: `TestWebGpuScene3d` の形の版の並び 2 本（骨つきは 17 float・骨の無い形は 9 float）と半透明の材質の骨つきの物を半透明として数える 1 本・`TestWebGpuScene3dDawn` の姿勢を submit の後に送り直す 1 本。
  `TestWebGpuScene3d` の骨つきの物を数えていた 3 本と `TestMeshTable` の描ける版の 1 本は、骨つきを描く事に合わせて直した）。`TestWgslDawn` は骨つきの頂点シェーダー 3 本を足して 374 本を Dawn で組んで誤り 0。偽の GL を通るテストは `use` の名前の直しだけで緑。
- 門（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal・2026-11-16）:
  - render_gl のテスト（`make sync-layers` の後 `.layers/render_gl` で `java -jar ../../bin/flix.jar test`）: 529 緑・exit 0。
  - `make gl-parity` exit 0。場面ごとの行（81 行）が 12.28 の木の門の記録と 1 字も同じ（GL の道は mod の名前を替えただけ）。
  - `make gl-capture-check` exit 0（基準 `bench/baseline/0.96.0/gl-capture-apple-m4-pro.sha256`）: a と b の 54 枚がバイトまで同じ・**基準とも 54 枚がバイトまで同じ**（差 0 枚）。
  - `make webgpu-v1-check` exit 0（誤り 0・draw の数も GL と同じ・終わりの `bench/webgpu_v2` の型検査も緑）。
  - `make -C bench/webgpu_v2 run` exit 0・誤り 0（今までの 16 場面は 12.28 と同じ数・足した 4 場面は上の表）。
  - `make lint-max-lines` exit 0（`WebGpuRenderer.flix` 834 行・`Render3d.flix` 1,111 行）・`make gl-jar-pin-check` exit 0（`render_gl/java` は触っていない）。
  - `make sync-engine-full` exit 0（engine_full の型検査と fpkg）。
- 持ち越し:
  - 影の地図の骨つきの物（(4)。計画は影の batch の姿勢の行も振っているので、WebGPU の影の pass は同じ group 2 を読めば足りる【推】）。
  - 1 体ごとの値の置き場の比べはこの Mac だけ。スマホ（adreno）と、group を材質か場面に 1 つ作って区画を引く形（12.28 の持ち越し）と一緒に P9・P10 の前に測り直す。
  - 姿勢の行の上限は予算 64 MiB から求める（device の maxStorageBufferBindingSize を読まない。core の最低保証 128 MiB の内）。上限を下げた機種が出たら読む。
  - submit が場面の間に入るたびに、prepare の姿勢を全部送り直す（場面が使う行だけに絞らない）。姿勢が数 KB の今は代金が小さいが、人が千体を超える場面で 1 コマに何度も submit が入るなら場面ごとに絞る。
    診断の JointUploads は GL と同じく prepare 1 回に 1 つ数え、送り直しは数えない（`packPoses` の doc に書いた）。
  - 12.28 の持ち越しで (3) で触らなかった物: `budgetEvictions`・`isOverBudget`・`Budget`・`meshEvictions` を表の mod へ移す・鍵の 1 か所化・`TextureTable3d.touch` の Map・`MeshTable.trim`・
    MaterialValues の位置のテスト・WGSL を組めない材質を欠けの表に数える・`borrowTexture` の作り直しの鍵・`TestMeshTable` の分割と足りないテスト 3 本・GL が読まない values と reads の代金。
  - 2 本のゲームで確かめられない物（骨つきの物の影・骨つきの物の半透明の材質）は (4)・(6) で `bench/webgpu_v2` に場面を足す。
- レビュー 1 回目（88 点）への対応:
  - 必須 1（姿勢の送り直しを場面 2 つと途中の submit で守るテストが無い）:
    - (a) `TestWebGpuScene3dDawn.testSecondSceneResendsPosesAfterSubmitInsidePrepare`: 骨つきの三角 1 枚と骨の無い三角 2 枚の場面を 2 つ、1 回の prepare に渡す。
      1 体ごとの値の buffer を 512 バイト（場面 1 つが 384 バイト）にすると、2 つ目の場面の前で submit が 1 回入り、2 つ目の場面が送り直した group 2 が 1 つ残る（(1, 1)）。
      4,096 バイトにすると submit は入らず、2 つ目の場面は 1 つ目の group 2 を使い回す（(0, 1)。姿勢の buffer は 1 回分の見積もりちょうどの 336 バイトにして、送り直しを見積もると submit が増える形にした）。
    - (b) `bench/webgpu_v2` の skinnedTwice: 小物 1,200 個と人形 24 体の場面を左右に 2 つ並べて 1 回の prepare で描く（左右で yaw ±0.2）。
      場面の一覧の頭に置き、1 体ごとの値の buffer が始めの 1,024 体のまま、1 つ目（823 体）は入り、2 つ目（801 体）の前で毎コマ submit が入る事を一時の println で確かめた（コミットに入れていない）。
      GL との差: 違う画素 22 px（許容 64）・±2 以上 14 px（許容 32）・max ±230（255）【推: crowd と同じく重なる小物で勝つ面が入れ替わる画素】。
    - 壊して確かめた（同じ日に 1 回ずつ・戻した）:
      - `isWrittenNow` をいつも偽にする（送ってある姿勢も見積もる）: (a) が `((1, 1), (1, 1))` で落ちる（あふれない方で余計な submit が 1 回増える）。
      - `sendPoses` が submit の後も前の group 2 を使い続ける（epoch を見ない）: (a) が `((1, 0), (0, 1))`・前からの `testPosesAreResentAfterSubmit` も落ちる。
        `bench/webgpu_v2` は skinnedTwice で手放した group 2 を使い、Dawn が止まって exit 2（Abort trap）。
      - 画素だけでは `isWrittenNow` の壊れは見えない（submit が 1 回増えるだけで絵は同じ）ので、守るのは (a) のテスト。
  - 任意で直した物:
    - `poseRowLimit` を姿勢の予算（64 MiB）÷（`Skin3d.maxJoints()` × 64 バイト）で求める形にし、WhyNot から「GL の上限と同じ桁」を消した（スマホの WebGL2 は 4,096 で成り立たない）。
    - `WebGpuMaterials.bindRow` も骨つきの材質で姿勢の group と形のジョイントを確かめる（`MaterialPass#hasPoses`）。付けられずに飛ばした行は、`RowDrawer#unbound` が
      「3D の付けられなかった行の物（pipeline か group が無い・飛ばす）」として欠けの表に数える（材質を組めない時も同じ種類に入る）。
    - `GlRows.Instancing` の WhyNot を GL の理由（baseInstance が無い）に限った。
    - 1 体の長さ（8 組 = 32 float）を `Render3d.InstanceValues.texelsPerInstance` に持たせ、`Render3dGlsl.texelsPerInstance` と `Render3dWgsl.instanceBytes` はそれを読む（`InstanceValues` は pub mod にした・WhyNot に書いた）。
    - `pipelineOf` の鍵にジョイントの番号の位置を入れない理由（形の版の末尾の 8 float なので頂点のバイト数で決まる）を WhyNot に。
    - 上の持ち越しに送り直しの代金と JointUploads の数え方、決めた事 2 に (5) の後の属性の数。
  - テスト: render_gl 530 緑（(a) を 1 本足した）。

### 12.30 R2b・P8 の (4): 影（2026-11-16・この Mac・Dawn の Metal だけ）

表の 13・14 行目の小分け (4)。engine の pub（ゲームから見える API）は増えていない（足した型と関数は render_gl の中だけ）。GL の絵は変えていない（下の門）。

- **進め方 — (4a) と (4b) に割る決めと、その答え**: 前の担当が main 799ecceb の上で未コミットのまま止まったので、コーディネーターは (4) を
  (4a)（影の pass の計画を前半へ・WebGPU で影の地図を描く・骨の無い物の影を材質と頂点の色の物で引く）と (4b)（骨つきの物と instance の物の影）に割って引き継がせた。
  引き継いだ書きかけ（9 ファイルの patch と、patch に入っていなかった新しい 4 ファイル（`ShadowMaps`・`WebGpuShadows`・`ShadowCases`・`TestShadowMaps`）は前の担当の worktree に残っていた）を今の main に当てると、
  **骨つきの物と instance の物の影も描けていた**（影の pass が色の pass と同じ group 2 と 1 体ごとの値の buffer を読むので、骨の無い物と分けて書く所が無かった）。
  下の bench（人形 24 体・小物 1,200 個が影を落とす 6 場面）と、壊して確かめた 4 つ（うち 2 つは骨つきの物と instance の物の影）がそのまま通ったので、**(4a) と (4b) の描く所は 1 回で入れた**。
  (4b) に残すのは下の「持ち越し」の確かめだけ（ブラウザ・2 本目のゲーム・診断の数え）。

- **R2b — 影の地図の pass の計画と描き先の寿命を前半へ**（R1b-1 の決め「表は前半・作る消すだけ backend」と (1b) の `MeshTable` にそろえた）:
  - 新しい `Render3d.ShadowMaps`（GPU を呼ばない）: `assign` が prepare 1 回の場面ごとの影の材料（`ScenePlan#shadowPlans`）に描き先の鍵（一辺の画素, 同じ prepare の中で同じ一辺の何枚目か）と
    色の pass が地図を引く値（`ShadowSampling` = Spot・Sun。行列・bias・pcf・濃さ・太陽は normalShift と forward と薄め）を決める。一辺と pcf の頭打ちと知らせ（"size"・"pcf"）は GL の `Render3d.Shadow` から移した（同じ文・同じ鍵）。
    `buildPasses` が 1 体ごとの値の番号を振った材料から `ShadowPass = { map, list }` の列を作る（行は `Render3d.SceneList.buildShadowList`: 頂点の色の行 → 骨つきの行・分かれた理由はどれも影の pass）。
    寿命の表（鍵 → 最後に使った世代）の `ensure`・`sweep`（`Render3d.idleTargetFrames()` = 128 コマ）・`release` が、backend の `Allocator{create, destroy}` に作らせ捨てさせる。
  - GL: `Render3d.Shadow` は鍵 → FBO（`ShadowTarget` から lastUsed を外した）だけを持ち、地図は `ShadowPass` の行を流して描く（`drawShadowRow`。プログラムの付け方・`meshEntry`・`drawMeshRange` の順は前の `drawBatch` と同じ）。
    GL の `prepareScenes` は場面の pass の行を作った後に `assign` と `buildPasses` を呼ぶ（形の表の番号の振り順を前と同じにするため）。
- **決めた事 1 — 影の pass は `ScenePassSpec` の case にせず、場面の列の外の別の型（`ShadowPass`）にした**（12.26・12.27 の「(4) で ShadowMap(light) の case を足す・別の列の案も比べる」への答え）:
  - case にすると、場面の列（`ScenePasses`）を流す GL の `drawScene` と WebGPU の `drawInto` の前提「列の pass は全部場面の描き先 1 つへ書く」が崩れ、両方に読まない case が生える。GL は地図を Design の場面より先に prepare の全部の場面の分を描くので、列の順にも乗らない。
  - 別の型なら、描き先が深度だけなことが型で決まり、`attachment の列を値で持つ形`（12.27 の持ち越し）は読む所が無いので入れていない（色と深度の組は今も 2 つの case で同じ値）。
  - 9.1 の流儀の「2 つ作って比べる」はしていない（case の形は書いていない）。上の理由は形の上の物【推: 書き味の差は case の形を書けば確かめられる】。
- **P8 — WebGPU で影の地図を描き、材質と頂点の色の物で影を引く**:
  - 新しい `Render3d.WebGpuShadows`: 鍵 → 描き先（DEPTH32_FLOAT の texture・光の目の値の buffer 128 バイト・その group 0）。影の pass は frag の無い深度だけの pipeline（頂点シェーダーは頂点の色の物と同じ `litVertexSource`・裏の面も描く・LESS）で、
    group 0 = 光の目と単位行列の射影（binding 5）・1 = 空・2 = 姿勢（色の pass と同じ group 2 を読む＝骨つきの物の影は作り直しなく描けた・12.29 の【推】を確かめた）。1 体ごとの値は場面の値の後ろに ShadowDepth で詰め、色の pass と同じ instance の buffer で読む。
  - 場面ごとに影の pass を先に積み、色の pass の group 0 の binding 1（スポット）・2（太陽）に地図を付けた group を作る（submit の後に手放す）。影の無い場面は前と同じ描き先の group。場面の値の影の欄は `packShadowValues` が毎回書く（地図の無い方は on を 0）。
  - WGSL は 12.25 から入っていた `shadowSource`（行を上下に返して読む・PCF は GLSL と同じ数え方）をそのまま使った。属性の数・varying の数は変えていない（影の座標は frag で world の位置から作る）。
  - 欠けの数え（`skipsOf`）から「3D の影（影を落とす光）」を外した。WebGPU の診断も影の pass の draw call と分かれた理由（影の pass）と描き先を作った数（TargetRebuilds）を GL と同じ欄で数える。
- **決めた事 2 — 寿命の決まり**: 光の目の値は描き先ごとの buffer で、writeBuffer は encoder の全部の pass より先に効く。同じ encoder の 2 回目の prepare が同じ鍵の地図を描き直す時は、
  1 体ごとの値・姿勢・材質の値と同じ見積もりの所（`stageScene` の頭）で先に submit する（`WebGpuShadows.needsFlush`）。送った後に submit すると、送った姿勢の group 2 を手放した後の影の pass が読む。
  - 回帰テスト `TestWebGpuScene3dDawn.testSecondPrepareRedrawingAShadowMapFlushesFirst`: 描き先の違う 2 回の prepare を同じ encoder で流すと、影のある場面は submit 1・group 2 が 1・地図を読む group 0 が 1・device の誤り 0、影の無い場面は submit 0・group 2 が 2・group 0 が 0。
  - **壊して確かめた**: `needsFlush` を外すと `((0, 2, 2, 0), …)` で落ちる。submit を姿勢を送った後へ動かすと、手放した group 2 を影の pass が使い、テストが Dawn の abort（exit 134）で止まる。
- **確かめ — `bench/webgpu_v2`** に 6 場面を足した（`ShadowCases.flix`）: 部屋に天井の近くから人形の格子を照らす影つきのスポット（地図 1024・PCF 1）、殻を外した部屋の物と広い市松の床に奥の右上から差す太陽（地図 2048・PCF 1・影が目の側へ伸びる）。
  影を落とす物は骨の無い家具・骨つきの人形 24 体・小物 1,200 個（instance）。受ける物は頂点の色の床と壁・絵つきの材質の床と家具と人形。

  | 場面 | 違う画素（許容） | ±2 以上（許容） | 差の最大 |
  |---|---|---|---|
  | shadowSpot（スポット・頂点の色の人形と部屋） | 12（32） | 1（8） | ±84 |
  | shadowSpotTextured（スポット・絵つきの材質の部屋と人形） | 173（350） | 1（8） | ±69 |
  | shadowSun（太陽・家具と人形） | 4（16） | 3（8） | ±71 |
  | shadowSunCrowd（太陽・小物 1,200 個も） | 31（64） | 22（48） | ±145 |
  | shadowSunTextured（太陽・絵つきの材質の床と家具） | 40（80） | 3（8） | ±58 |
  | shadowBoth（1 つの場面にスポットと太陽の地図 2 枚） | 8（16） | 2（8） | ±83 |

  - 許す差の理由: ±2 以上は room と同じく重なる面で勝つ面が入れ替わる所と、影のふちで比べ（z − bias ≦ 地図の値）が最後の bit で入れ替わる画素【推: GL の地図は 24 bit・WebGPU は 32 bit の float。画素を 1 つずつは見ていない】。
    ±1 は面の中に点で散る（絵の補間と光の坂の丸め）。上限は実測のほぼ 2 倍（小さい物は 8）・差の最大は面の入れ替わりで切らない（255）。
  - **壊して確かめた**（同じ日に 1 回ずつ・確かめた後に戻した。上の 2 つは引き継いだ後に今の main の上でもう一度流し、同じ数で落ちた）:
    - 色の pass の影の行列（スポットと太陽）を単位行列にする: 6 場面が 57,738〜143,125 px 違って落ちる。
    - bias を 0 にする: 11,552〜175,392 px 違って落ちる（影のにきび）。
    - 骨つきの物の影の pass で姿勢を読まない（骨の無い版の pipeline で描く）: 5,396〜30,818 px 違って落ちる。
    - 影の pass の firstInstance を 1 つずらす: 17,426〜103,938 px 違って落ちる。
  - 今までの 22 場面は 12.29 と同じ数。絵（git の外）: `bench/webgpu_v2/debug/{gl,webgpu}/shadow*.png`。目で見て、人形と家具と小物の影が GL と同じ所に同じ濃さで落ちる。
- **レビュー（1 回・86 点・必須なし）で直した物**:
  - 描き先の鍵を素のタプルから `Render3d.ShadowMaps.Key`（`keyOf`・`sizeOf`・`pairOf`）に替え、`ShadowMapUse` の `size` を消した（一辺を 2 か所に持つと食い違う）。
  - GL の描き先が表から引けない時に fbo 0（画面）へ深度を描いていたのを、その地図を描かない形にした（WebGPU の backend と同じ振る舞い。起こらないはずの道）。
  - WebGPU の 1 体ごとの値の番号振りを `Render3d.InstanceValues.countOf`・`mapBatches` で振る形にした（計画の側の関数の写しをやめた。番号の振り順は同じで bench の差も同じ）。
  - `packShadowValues` の欄の位置を固定するテストを 3 本足した（bench の画素の差では pcf と濃さのように近い値の欄の取り違えを見逃す）。
  - 直していない指摘（好み）は下の持ち越しへ。
- **欠けの表と実物 — fps3d_lab の部屋**（`~/Documents/flix_ge_workspace/fps3d_lab` の写し・engine はこの worktree の engine_full・`START=room`・`FGE_JAR_CACHE=off`・`FLIX_GE_HIDDEN=1`・`RUN_SECONDS=70`・WebGPU と GL を 1 本ずつ）:
  - **欠けの表が出なくなった**（12.29 では影 0.9 回/コマだけが残っていた。300 コマ目の表も終わりの表も出ない＝飛ばした物が 0）。部屋の衛兵（骨つき）の影も描く側に入った。WebGPU の誤り 0・落ちない。
  - 見え方: 50・64 コマ目を GL と並べた。机の下の絨毯と脚の周り・椅子の後ろに影が落ち、場所と濃さは GL と同じに見える（影の無い 12.29 の WebGPU の同じコマは机の下が明るい）。
    画素で比べると 9 割の画素が違うが、松明の光が時間で揺らぐ（コマの時刻が 2 本でそろわない）のと、WebGPU に mip がまだ無い（(7)）ので床の木目が細かくちらつくのが大きい【推: 影の差だけを取り出してはいない】。
  - みやげの町は流していない（影を落とす光は 0.6〜0.9 回/コマの物で、fps3d_lab と同じ道。(4b) の確かめへ）。
- テスト: render_gl 540 緑（前の 530 に `TestShadowMaps` 6 本（同じ一辺は場面をまたいで次の番号・上限の一辺・pcf の頭打ち・1 回だけ作る・使わない物だけ捨てる・捨てた鍵を作り直す）と
  `TestWebGpuScene3dDawn` の 1 本と、`TestWebGpuScene3d` の影の欄の位置 3 本（スポット・太陽・影の無い場面で両方 0））。偽の GL を通るテスト（Sun・JointTexture の影の数え）は直さずに緑。
- 門（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal・2026-11-16）:
  - 引き継いだ後に今の main（daa80f28）の上で全部流し直した（レビューの直しの後にもう一度全部流し、下の数と同じ。gl-parity の場面ごとの行 81 行は前の担当の記録と 1 字も同じ）。
  - render_gl のテスト（`make sync-layers` の後 `.layers/render_gl` で `java -jar ../../bin/flix.jar test`）: 537 緑・exit 0（直しの後 540 緑）。
  - `make gl-parity` exit 0。場面ごとの行（81 行）が 12.29 の木の門の記録と 1 字も同じ。
  - `make gl-capture-check` exit 0（基準 `bench/baseline/0.96.0/gl-capture-apple-m4-pro.sha256`）: a と b の 54 枚がバイトまで同じ・**基準とも 54 枚がバイトまで同じ**。
  - `make webgpu-v1-check` exit 0。`make -C bench/webgpu_v2 run` exit 0・誤り 0。
  - `make lint-max-lines` exit 0（`WebGpuRenderer.flix` 916 行・`Render3d.flix` 1,116 行）・`make gl-jar-pin-check` exit 0（`render_gl/java` は触っていない）。
- 言える範囲: この Mac（Dawn の Metal）だけ。スマホ（adreno）・ブラウザ（TeaVM の JSO の実装で frag の無い pipeline と色の無い pass が通るか）は未確認【未確認】。
  ブラウザの `BrowserWebGpu` は frag の無い pipeline を作り分ける枝を持っている（読んだだけ・流していない）。
- (4b) に残す確かめ:
  - ブラウザ（12.31 の口・`?backend=webgpu`）で fps3d_lab の部屋と `bench/scene3d` の field（shadow=1）を流し、欠けの表から影が消える事と WebGPU の誤り 0 を見る。
  - みやげの町（night・market）を `FLIX_GE_BACKEND=webgpu` で流す。
  - WebGPU の `countRows` は、姿勢が無くて描かなかった骨つきの影の行も draw call に数える（GL は描いた行だけ）。診断の数だけの差。
  - GL で影の行を作る区間が `Phase.Shadows` から `Phase.Split` へ移った（診断の区間の数え方が少し変わった）。`ShadowMaps.ensure` の返り値は本番で読まない（テストだけ）。
- 持ち越し:
  - WebGPU の影の pass の CPU の区間を `Phase.Shadows` で数えていない（prepare 全体が `Phase.Draw` の中で、入れ子に数えると二重になる）。
  - 影の地図の描き先を場面の描き先ごとに控えず、影のある場面は毎回 group 0 を作る（場面 1 つに 1 つ・submit の後に手放す）。
  - 影を落とす物の間引き（視錐台）は計画の今のまま。地図の一辺は上限 `Scene3d.maxShadowMapSize()` のまま device の maxTextureDimension2D を読まない（スマホ 12.24 の上限の内【推】）。
  - 12.28・12.29 の持ち越しで (4) で触らなかった物（`budgetEvictions` などを表の mod へ・鍵の 1 か所化・`TestMeshTable` の分割・`TextureTable3d.touch` の Map ほか）はそのまま（触った所に無かった）。

### 12.31 ブラウザの 3D を WebGPU で（2026-11-16・この Mac・Chrome 156 の headless・WebGPU は apple metal-3 だけ）

`WebLayer.withProject3d` も `?backend=webgpu` で WebGPU で描く。2D の入口と同じ `withWebGpuOrGl` を通し、WebGPU の文脈を取る前に落ちたら理由を console に出して WebGL2 で描く。
3D の描き手は WebGPU の塗りのコア（`WebGpuPaint`）が前から持っているので、ブラウザの側で足した物は無い。`withWebGpuOrGl` が「WebGL2 へ落ちた時の 3D の描き手の作り方」を受け取るようにしただけ（2D の入口は今までどおり場面を描かない描き手）。
engine の pub と render_gl は触っていない。

- 確かめた場面と絵（`bin/fge export-web` の出力を 127.0.0.1 で配り、headless の Chrome で `?capture=<n>`。console は頁の頭に差した script で全部拾った）:

  | 場面 | 大きさ | WebGL2 と比べた差 | 欠けの表（300 コマ目） |
  |---|---|---|---|
  | `bench/scene3d` の部屋（`?capture=6`） | 320 × 180（design） | 0 px（max ±0） | 出ない（飛ばした物が無い） |
  | `bench/scene3d` の field（n=2000・alpha=10・shadow=1） | 960 × 540 | 比べていない | 半透明の材質 200 回/コマ・影 1 回/コマ |
  | fps3d_lab の部屋（`?room&capture=240`） | 480 × 270（design） | 121,434 / 129,600 px が違う。影が無いぶん床と壁が明るい（目で見て差は影だけ） | 影 288 回（0.9/コマ） |
  | fps3d_lab の礼拝堂・通路（2D） | 960 × 540 | 比べていない（目で見て描けている） | 影だけ |

  どれも真っ黒・真っ白でない。`renderer: webgpu: WebGPU apple metal-3`。WebGPU の誤り（validation error・device lost）は 1 つも出ない。欠けの表に出たのは影と半透明だけ（空と lightmap はこの 2 本が使わないので出ていない）。
- 数（Chrome 156 headless・960 × 540・コマは 60 Hz の描き替えで頭打ち）:
  - `bench/scene3d` の部屋（`make bench-web` と同じ口・240 コマ × 3 区間）: WebGL2 の cpu p50 1.4〜2.4 ms・WebGPU 1.5〜2.1 ms。どちらも 60 fps。
  - field n=2000（257 draw）: WebGL2 の cpu p50 10.5〜10.6 ms・WebGPU 10.9〜11.0 ms。field n=12000 は WebGL2 12.7 fps・WebGPU 14.8 fps。
  - fps3d_lab の部屋（rAF の中で wasm が使った時間・12 秒）: WebGL2 median 11.2 ms・WebGPU 10.3 ms。礼拝堂 7.3 ms・通路 5.3 ms（WebGPU）。どれも 60 fps。
  - 起動の一番長いコマ（押した後・最初のコマの前）: WebGL2 約 260 ms・WebGPU 約 400〜420 ms。WebGPU は canvas の文脈を取る前に pipeline を同期で作って絵とフォントを上げるので、その分が 1 コマに乗る。遊んでいる間に 50 ms を超えるコマは無い。
- 落ちる道: `?webgpuFail=prepare` は WebGL2 の絵と 0 px 差（3D の描き手つき）。`?webgpuFail=canvas` は頁を開き直して WebGL2 で部屋を描く。
- 2D を壊していない: `make webgpu-v1-check-web`（rpg-starter・WebGL2 と WebGPU と WebGPU の無い頁）OK・差 0 px。
- wasm の大きさ: `bench/scene3d` 6.3 MB → 7.6 MB（gzip 1.5 MB → 1.8 MB）。前は WebGPU の塗りのコアが 3D の入口から届かず TeaVM が捨てていた。fps3d_lab 10.5 MB（gzip 2.5 MB）。
- ブラウザでだけ起きると見ていた物の扱い:
  - shader の組み立て・pipeline を同期で作る時間: 上の起動の 1 コマ（+150 ms 前後）だけ。遊ぶ間に新しい材質が出た時の pipeline はこの 2 本では見ていない（部屋ごとに起動で揃う）。
  - storage の上限: device は adapter の上限をそのまま頼む（`BrowserWebGpu`）。姿勢の行の予算 64 MiB は core の最低保証 128 MiB の内なので、この Mac では当たらない。
  - canvas の形式: この Mac の Chrome は `bgra8unorm` を選び、そのまま描けた。`rgba8unorm` を選ぶ機種（Android の Chrome）は確かめていない。
  - 直した物は無い（ブラウザだけの誤りは出なかった）。
- 持ち越し:
  - 点光源が 8 本を超えた時の知らせ（「scene3d: 点光源が 11 本ある」）は WebGL2 の頁にだけ出て、WebGPU の頁には出ない（fps3d_lab の部屋）。PC の WebGPU でも同じか、(4) の後に `WebGpuRenderer` の側で見る。
  - 2D の入口（`withProject`）も `?backend=webgpu` なら 3D の場面を描く（WebGPU の塗りのコアが 3D の描き手を持つため）。WebGL2 の 2D の入口は描かずに 1 回知らせるので、振る舞いが分かれている。
  - Retina の 2 倍・Android の Chrome・Safari・空と lightmap を使う場面は確かめていない。
  - fps3d_lab は engine 0.87.0 のままなので、写しを 0.97.0 にして書き出した（コードは直さずに通った）。font-bake は無い字 178 字で止まるので、font-bake が作ったアトラスを `--font-atlas-dir` で渡した（ゲームのフォントの話で WebGPU とは別）。

### 12.32 R2b・P8 の (5a): lightmap（2026-11-16・この Mac・Dawn の Metal だけ）

表の 13・14 行目の小分け (5)「lightmap・空」の前半。(5) 以降の小分けは半分ずつに割る（人の決め）ので、空は (5b) として次の担当へ回した（触っていない）。
engine の pub（ゲームから見える API）は増えておらず、公開の型シグネチャも変えていない。GL の絵は変えていない（下の門）。

- **R2b — lightmap の値と絵の組を前半へ**（12.28 で残した「lightmap の版」の続き）:
  - 前半の `Render3d.MaterialValues.put` が、lightmap の版の材質の行（1 行 1 体。`Render3d.Batch` が lightmap つきを batch にしない）に、物ごとの値の区画の欄 3 = 段の数（`lightmapLevelsOf` = 絵の段の数と `maxLevels` の小さい方）・
    欄 4 = 色空間（sRGB なら 1）・欄 5 = 強さを書き、絵の組の末尾に lightmap（`TextureUse.Lightmap(colorSpace)`・Linear・Clamp）を足す。並びは 材質の絵 → 法線マップ → lightmap（番号は `lightmapReadAt` の 1 か所）。
    `readCountOf` は lightmap の版で 1 つ多い。行のフラグに `flagLightmap`（16）を足した。
  - lightmap の絵の番号と寿命は (1b) の `Render3d.TextureTable3d` のまま（新しい表は要らなかった。lightmap は場面の textures の絵だけ＝`Scene3d.lightmapProblem` が名前で止める）。
  - **GL の backend の中に残した物**: lightmap の unit（8）・uniform の位置・2 本目の uv を location 7 の別の vbo で上げる道・`bindLightmap` が物ごとに付け直す順。
    GL は今も values と reads を読まない（12.28 の決めのまま）。段の数の切り方だけ `lightmapLevelsOf` を GL と前半で共有した（GL の呼び出しの並びは同じ）。
- **P8 — WebGPU で lightmap を描く**:
  - **決めた事 — 色空間と強さは場面の値でなく物ごとの値（`r3dDraw`）で読む**: 12.28 の WGSL は `R3dScene`（group 0）の `uLightmapSrgb`・`uLightmapIntensity` を読んでいた。場面の値の buffer は描き先ごとに 1 つで、writeBuffer は encoder の pass より先に効くので、物ごとに替えられない。
    そこで engine の `LightModel3d.Codegen` の WGSL の字だけを `r3dDraw.uLightmapSrgb`・`r3dDraw.uLightmapIntensity` に替えた（GLSL は 1 字も変えていない・型シグネチャは同じ）。`R3dDraw` は f32 が 6 つ（binding は 32 バイト）・`R3dScene` の 2 欄は pad にした（欄の位置は変えない）。
    ほかの案: (a) lightmap の色を frag で先に線形へ戻して強さを掛け、場面の値は「線形・強さ 1」に固定する（engine を触らないが、LightModel3d の式を render_gl に写すことになる）・(b) 生成した字を置き換える（字の形に寄りかかる）。どちらも取らなかった。
  - bind group は計画の決め（0 = コマと場面・1 = 材質（と lightmap）・2 = storage）のまま: lightmap の絵と sampler は group 1 の `drawBinding()` + 3・+ 4（19・20。`Render3dWgsl.drawDeclarations` と layout と bind group の 3 か所が同じ番号）。
  - 2 本目の uv は形の版の 1 本の buffer の中（uv つきは 15 float 目・uv なしは 9 float 目・`WebGpuRows.MeshBuffers#uv2At`）を location 13 で読む（WGSL の決まり「形の並びは版ごとに 1 本の buffer へ交互」のまま。新しい buffer は足していない）。varying は 8 個（上限 16 の内）。
  - 材質の頂点シェーダーの鍵を (uv, lightmap, 骨) にした（骨つきは lightmap を読まない）。pipeline の鍵は program の番号で、program の鍵（`materialKey`）に `+lm` があるので lightmap の版は別の pipeline。lightmap の行は毎回 group 1 を作る（`isSameBinding` が lightmap の行を同じ付け方にしない）。
  - `WebGpuMaterials.isDrawable` から lightmap を外し、欠けの数え（`WebGpuRenderer.skipsOf`）から「3D の lightmap の材質の物」を消した。lightmap つきの半透明の材質は今は半透明の物として数える（(6)）。
- **確かめ — `bench/webgpu_v2`** に 3 場面を足した（`LightmapCases.flix`。部屋の物を箱投影の uv にし、2 本目の uv は同じ投影を部屋 1 つ分で 0..1 に縮めた物。lightmap の絵は CPU で作る 64 × 64 の明るさと色の坂に 4 × 4 の升の濃淡）:

  | 場面 | 違う画素（許容） | ±2 以上（許容） | 差の最大 |
  |---|---|---|---|
  | lmTextured（絵つきの材質・sRGB の lightmap・強さ 1.5） | 231（460） | 74（150） | ±79 |
  | lmNormalLinear（絵 ＋ 縞の法線マップ・線形の lightmap・強さ 2・段 2 まで＝絵の組 3 つ） | 289（580） | 80（160） | ±86 |
  | lmDepth（lmTextured を奥行きの書き出しで） | 3（16） | 1（8） | ±4（±16） |

  - 許す差の理由: matTextured（222・75）・matNormal（248・76）と同じ所（重なる面の入れ替わり）で同じ桁。lightmap を足して増えたのは ±1 の点だけ【推: lightmap の段の間の補間と sRGB の戻しの丸め】。lmDepth は roomDepth と同じ画素。上限は実測のほぼ 2 倍・差の最大は面の入れ替わりで切らない（lmDepth は roomDepth と同じ ±16）。
  - **壊して確かめた**（同じ日に 1 回ずつ・確かめた後に戻した）:
    - 材質の頂点シェーダーで 2 本目の uv の上下を返す: lmTextured 399,946 px・lmNormalLinear 401,241 px 違って落ちる（lmDepth は 3 px のまま）。
    - lightmap の強さを 1 のままにする（欄 5 に 1.0）: lmTextured と lmNormalLinear が全 518,400 px 違って落ちる。
    - 法線マップの版で lightmap の絵の組の番号を 1 つ手前（法線マップの絵）にする: lmNormalLinear だけが全 518,400 px 違って落ちる（lmTextured は 231 px のまま）。
  - 今までの 26 場面は 12.30 と同じ数。目で見て、lightmap の坂と升の濃淡が GL と同じ所に同じ明るさで乗る（`bench/webgpu_v2/debug/{gl,webgpu}/lm*.png`・git の外）。
- **欠けの表と実物**（12.28 と同じ流し方・写しの engine はこの worktree の fpkg・`FGE_JAR_CACHE=off`・`FLIX_GE_HIDDEN=1`・`RUN_SECONDS=40`（arrival の WebGPU は 40 秒で頭の読み込みが終わらず 0 コマだったので 70 秒で流し直した）・頭の 64 コマ）:

  | 種類（1 コマあたり） | fps3d_lab 部屋 | 礼拝堂 | 通路 | みやげの町 arrival | market | night |
  |---|---|---|---|---|---|---|
  | lightmap の材質の物（12.28 の数） | — | — | — | 7.9 → **0** | 14.5 → **0** | 20.5 → **0** |
  | 半透明の材質の物 | — | — | — | 12.4 | 12.4 | 8.0 |
  | 空（場面） | — | — | — | 0.6 | 0.6 | 0.6 |
  | 骨つきの物・影 | 0 | 0 | 0 | 0 | 0 | 0 |

  - fps3d_lab の 3 場面は欠けの表が出ない（飛ばした物が 0・12.30 と同じ）。みやげの町は半透明（(6)）と空（(5b)）だけが残った。WebGPU の誤り 0・落ちた場面なし。
  - 骨つきの物と影はみやげの町でも 0（(3)・(4) の後にみやげの町を流したのはこれが初めて・12.30 の (4b) の確かめの 1 つ）。
  - 見え方: night の 60 コマ目を GL と並べた。町の石畳・壁の lightmap の明るさ（窓の明かりが地面に落ちる所）が GL と同じに見える（12.28 では石畳が白かった）。画素で比べてはいない【推: コマの時刻が 2 本でそろわない】。
  - 絵の置き場: `/private/tmp/claude-501/-Users-abab-Desktop-flix-game-engine/1e409b86-520d-4126-86d6-d8af78577988/scratchpad/lm/games/out/<ゲーム>-<場面>-<gl|webgpu>/frame-N.png`（**scratchpad の物は消えうる**）。
- テスト: render_gl 542 緑（前の 540 に `TestSceneList` の lightmap の行の値と絵の組 2 本。`TestMeshTable.testDrawableKinds` は lightmap を描く版に直した。`TestWgslDawn` に uv の無い lightmap の頂点シェーダーを足した）。
  engine の `make test-engine` 987 緑（`TestLightModel3d` に WGSL の lightmap の式が `r3dDraw` から読む 1 本）。
- **レビュー（1 回・86 点・必須 2）で直した物**: 必須 1 = この記録（12.32 と 9 章の表と 12.28 の指し）。必須 2 = lightmap の行のテストが色空間を書き漏らしても通った（線形で期待 0 は初めの値と同じ）ので sRGB に替え、線形は法線マップと lightmap の両方の行のテストで見る。
  任意で直した物: 絵の組の lightmap の番号を `MaterialValues.lightmapReadAt` の 1 か所に・頂点シェーダーの鍵と中身へ同じ丸めた値を渡す・足りないテスト 3 本（uv の無い lightmap の頂点シェーダー・WGSL の式・法線マップと lightmap の並び）。
- 門（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal・2026-11-16。直しの後の木で流し直した）:
  - render_gl のテスト（`make sync-layers` の後 `.layers/render_gl` で `java -jar ../../bin/flix.jar test`）542 緑・`make test-engine` 987 緑。
  - `make gl-parity` exit 0・`make gl-capture-check` exit 0（a と b の 54 枚がバイトまで同じ・基準とも 54 枚がバイトまで同じ）。
  - `make webgpu-v1-check` exit 0・`make -C bench/webgpu_v2 run` exit 0・誤り 0（29 場面）。
  - `make lint ONLY=max-lines` exit 0（`WebGpuRenderer.flix` 914 行・`WebGpuMaterials.flix` 453 行・`Render3d.flix` 1,116 行）・`make gl-jar-pin-check` exit 0（`render_gl/java` は触っていない）。
- 言える範囲: この Mac（Dawn の Metal）だけ。ブラウザ（12.31 の口）・スマホ（adreno）で lightmap の場面は流していない【未確認】。
- (5b) へ回した物（→ 12.33 で入れた）: 空（kindSky・`skipsOf` の「3D の空」はそのまま）。みやげの町の空は見下ろしの画角でほとんど映らないので、`bench/webgpu_v2` に空の場面を足して門にする。
- 持ち越し:
  - `drawValueBytes`（32）は `R3dDraw` の欄の数と手で合わせている（欄を足す時は両方を直す）。
  - lightmap の行は物ごとに group 1 を作る（GL も物ごとに付け直すので同じ桁）。lightmap の物が数百ある場面が来たら、(絵の番号, 値の区画) の鍵で控える形を測る。
  - bench で壊して確かめていない所: 段の数（欄 3）・色空間（欄 4 は `TestSceneList` で守る）・Clamp と Repeat の取り違え（2 本目の uv を 0..1 に収めたので出にくい）。
  - 12.28・12.30 の持ち越しで (5a) で触らなかった物はそのまま。

### 12.33 R2b・P8 の (5b): 空（2026-11-16・この Mac・Dawn の Metal だけ）

表の 13・14 行目の小分け (5) の後半（(5a) の lightmap は 12.32）。engine の pub（ゲームから見える API）は増えておらず、engine/ の公開の型シグネチャも変えていない（足した型と関数は render_gl の中だけ）。
GL の絵と GL の呼び出しの並びは変えていない（GL の `Render3d.drawSky` は 1 字も触っていない・下の門）。

- **決めた事 1 — 空は前半の行（kindSky）にしない**: 12.26 の見立ては「空は kindSky」だったが、空は場面に 1 回の draw で、形も材質も絵の組も持たない（読むのは場面の値と向きの材料だけ）。
  行にすると前半の `SceneList` に読む欄の無い kind が 1 つ増え、GL は行を読まず今の `drawSky` のまま（12.28 の決め「GL の呼び出しの並びは変えない」）なので、backend が 2 つとも行を使わない。
  そこで WebGPU の backend の中で、場面の色の pass の頭（地の色で消した直後・行の前）に描く形にした。行にする得が出るのは、空を場面の pass の列の途中に挟む物（空の後に描く後がけ・(6)）が来た時で、その時に見直す。
- **決めた事 2 — 空の 3 色と曲がりは場面の値（group 0 の R3dScene）から読む**: R3dScene の `uZenith`・`uHorizon`・`uGround`・`uCurve` は映り込みの空の値（`LightModel3d.reflectionSkyOf`）で、
  空のある場面では空の色を線形へ戻した物と `Scene3d.skyCurveOf` ＝ GL の `drawSky` が空のプログラムへ渡す値（`putLinearizedColor`）と同じ。空の frag はこの欄をそのまま読む（`LightModel3d.Codegen.toWgsl` の `skyAt` が `r3d.uZenith` 等を読む形のまま・engine の字は触っていない）。
  前提は `TestWebGpuScene3d.testSkySceneValuesAreLinearSkyColors` で固定した。
- **決めた事 3 — 向きの材料は R3dScene の末尾の vec4 3 本**（`uSkyForward`・`uSkyRight`・`uSkyUp`・48 バイト・位置は `Render3dWgsl.skyValuesAt`）: xyz に forward・right・up（`Scene3d.skyBasisOf`）、w に描き先の幅と高さ。光の配列の後ろへ足したので今までの欄の位置は 1 つも動かず、R3dScene の宣言は `sceneDeclarations` の 1 か所だけ。
  `packSceneValues` と同じく空の無い場面でも毎回書く（書く欄の組を場面ごとに変えない決まり）。場面の値の buffer は描き先ごとに 1 つなので、同じ encoder で同じ描き先を 2 回書く時は今までの `noteWritten` の submit がそのまま効く。
  初めの版は描き先ごとの別の buffer（group 1 の R3dSky）にしていたが、レビューで「末尾に足せば並びは動かない」と指摘され、group 1 の layout・描き先ごとの buffer と bind group・その寿命の行がまるごと要らなくなるので替えた。
  頂点シェーダーで隅の 3 点の向きを作って補間する形も、どちらにしても基底を送る場所が要るので取らなかった。目と射影の行列（binding 5）から逆に作る形は、tan と縦横の比を行列から戻す丸めが入るので取らなかった。
- **WGSL**（`Render3dWgsl.skyVertexSource`・`skyFragmentSource`）: 頂点は buffer を読まず `vertex_index` の 3 点で描き先いっぱいを覆う三角形（GL は 6 点の四角の vbo）。frag は GLSL の空の枝と同じ式で、描き先の上の行が先なので NDC の y は画素の y を返して作る。
  GLSL の `uEnvOn`（景色を背景に描く枝）と `uDepthOut`（奥行きの書き出しの白）の枝は持たない: 前者は環境マップの絵を上げる道がまだ無い（(7)）・後者は奥行きの書き出しの pass が空を描かず地の色の白で消す（12.27 の `clearOf`）。
- **pipeline**（新しい `Render3d.WebGpuSky`）: 鍵は (形式, 標本)。group は 0 = 場面の layout だけ。深度は読まず書かない（`ALWAYS`・書かない。GL は深度の判定を切って描く）が、pass が深度を持つので形式（DEPTH24_PLUS）だけ合わせる。裏の面は間引かない。
  空を描いた後は行の pipeline を付け直す（行を描く `bindShape` は Unbound から始まる）。group 1 は空が付けないので、材質の行（`groupRow` が -1 から）と骨つきの形の行（空の group）が今までどおり付ける。骨の無い形の行は group 1 を付けず、その pipeline の layout に group 1 が無いので通る（形の pipeline に group 1 を足す時は付け直しが要る）。draw call は GL と同じく `BatchBreak.Sky` で数え、sky と background が両方ある場面は GL と同じ文（`Scene3d.skyWarning`）で 1 回知らせる。
- **描く場面**: `WebGpuSky.isDrawn` = sky のある場面だけ。sky の無い景色を背景に描く場面（`Scene3d.drawnSkyOf` は Some）は今までどおり「3D の環境マップ」として数え、空では描かない（(7)）。
  sky と景色を背景に描く環境マップが両方ある場面は、GL は空の坂を描く（`Scene3d.backgroundEnvironmentOf` は sky があれば None で、GL の空の frag の `uEnvOn` は 0）。WebGPU も今回から同じ空の坂を描く（環境マップは今までどおり数える）。
  `skipsOf` から「3D の空」を外した。`bench/webgpu_v2` の貼る形 B（`SplitPassTrial`）は画面の途中の矩形へ描くので空を描かない（空の frag は描き先の左上を場面の左上として向きを作る・比べる部屋に空は無い・WhyNot に書いた）。
- **確かめ — `bench/webgpu_v2`** に 5 場面を足した（`SkyCases.flix`。殻を外した部屋の物を影の場面の広い床に置き、3 色のはっきりした空の下で目を上へ向ける。真上は濃い青・地平は淡い橙・真下は暗い緑）。
  比べ相手 1 つは記録だけ（門にしない）:

  | 場面 | 違う画素（許容） | ±2 以上（許容） | 差の最大（許容） |
  |---|---|---|---|
  | sky（見上げ・curve 1） | 7（16） | 0（4） | ±1（±16） |
  | skyTurned（後ろ向きに見下ろし・床の向こうに地平と真下の色・curve 0.6） | 0（8） | 0（4） | ±0（±16） |
  | skyDesign（sky を design の解像度で） | 0（8） | 0（4） | ±0（±16） |
  | skyDepth（sky を奥行きの書き出しで＝空は白） | 0（8） | 0（4） | ±0（±16） |
  | skyMsaaPass（標本 4 の Pass に描いて貼る・空の pipeline の標本 4 の版） | 14,238（28,000） | 12,249（24,000） | ±60（±128） |
  | yardMsaaPass（skyMsaaPass から空を外した比べ相手・記録） | 13,653 | 12,195 | ±64 |

  - 空の画素はどれも GL と ±1 以内（sky の 7 px も ±1 だけ）。skyMsaaPass の差は物のふちで、空を外しても同じ桁なので railsMsaa と同じ標本の位置の違い（bench の slantFlipProbe で確かめた物）で、空の差ではない。
    上限は違う画素を実測のほぼ 2 倍・±2 以上は小さい物の下限の 4・差の最大は ±16（skyMsaaPass は MSAA のふちが ±64 まで出るので ±128）。
  - 初めに目を下へ向けた版（pitch が正だと下を向く）で流した時は、sky が 5 px・±77、skyDesign が 45 px・±227 だった（床と家具のふちで面の入れ替わり・room と同じ形）。今の版は空の割合を増やして面の重なりを減らした物【推: 差は空でなく重なる面】。
  - **壊して確かめた**（同じ日に 1 回ずつ・確かめた後に戻した）:
    - 空の frag で NDC の y を返さない: sky 504,249・skyTurned 432,514・skyDesign 505,134・skyMsaaPass 434,466 px 違って落ちる。
    - 空の色を sRGB へ戻さない（`r3d_linearToSrgb3` を外す）: 同じ 4 場面が 433,538〜505,818 px 違って落ちる。
    - 空の向きの材料の幅と高さを入れ替える（初めの版の R3dSky で）: 同じ 4 場面が 431,149〜503,055 px 違って落ちる。
    - skyDepth は上の 3 つではどれも 0 px（空を描かず白で消すので）。
    - （レビューの後に足した・R3dScene の末尾へ移した後の木で）空の曲がりを 1 に決め打ちする（場面の値の uCurve に 1）: 曲がりが 1 でない skyTurned 433,538 px・skyMsaaPass 433,170 px 違って落ちる（曲がり 1 の sky と skyDesign は通る）。
    - 奥行きの書き出しの pass でも空を描く: skyDepth だけが 505,665 px 違って落ちる。
  - 今までの 29 場面は 12.32 と同じ数。目で見て、空の坂（真上の青から地平の橙・床の向こうの緑への寄り）が GL と同じ所に同じ色で出る（`bench/webgpu_v2/debug/{gl,webgpu}/sky*.png`・git の外）。
- **欠けの表と実物**（12.32 と同じ流し方・写しの engine はこの worktree の fpkg を作り直した物・`FGE_JAR_CACHE=off`・`FLIX_GE_HIDDEN=1`・頭の 64 コマ・WebGPU だけ。
  `RUN_SECONDS` は 70（arrival と market は 70 秒では jar を作るだけで 0 コマだったので 160 で流し直した））:

  | 種類（1 コマあたり） | fps3d_lab 部屋 | 礼拝堂 | 通路 | みやげの町 arrival | market | night |
  |---|---|---|---|---|---|---|
  | 空（場面） | — | — | — | 0.6 → **0** | 0.6 → **0** | 0.6 → **0** |
  | 半透明の材質の物 | — | — | — | 12.4 → 18.6 | 12.4 → 11.4 | 8.0 → 8.0 |
  | lightmap・骨つきの物・影 | 0 | 0 | 0 | 0 | 0 | 0 |

  - みやげの町に残った欠けは半透明（(6)）だけ。fps3d_lab の 3 場面は欠けの表が出ない（12.32 と同じ）。WebGPU の誤り 0・落ちた場面なし。
  - 半透明の数の揺れ（arrival 12.4 → 18.6・market 12.4 → 11.4）は今回の直しと関わらない（半透明の道は触っていない）【推: 起動から 300 コマの数え方で、頭の読み込みの長さ（今回は 160 秒で流した）によって 300 コマの中で映る物が変わる】。
  - 見え方: night の 60 コマ目を 12.32 の GL の絵と並べて、違いが見えない（みやげの町は見下ろしで空が映らない。空の門は上の bench）。
  - 絵の置き場: `/private/tmp/claude-501/-Users-abab-Desktop-flix-game-engine/1e409b86-520d-4126-86d6-d8af78577988/scratchpad/sky/games/out/<ゲーム>-<場面>-webgpu/`（**scratchpad の物は消えうる**）。
- テスト: render_gl 547 緑（12.32 の 542 に `TestWebGpuScene3d` の空の 5 本: 場面の値の空の色が線形の空の色・空の欄の位置・空の欄が場面の値の末尾・空を描くのは sky のある場面だけ・skipsOf が空を数えない。
  `TestWgslDawn` に空の頂点シェーダーと frag を足して Dawn で 377 本）。engine の `make test-engine` 987 緑（engine は触っていない）。
- **レビュー（1 回・85 点・必須 1）で直した物**: 必須 1 = 初めの版は向きの材料を描き先ごとの別の buffer（group 1 の R3dSky）に置き、理由を「R3dScene の並びを替えると全部の WGSL に波及する」と書いていたが、
  末尾に足せば並びは動かない（宣言は 1 か所）ので、R3dScene の末尾へ移した（上の決めた事 3）。
  任意で直した物: sky と background が両方ある時の知らせ（GL と同じ `Scene3d.skyWarning` の文・1 回）・壊して確かめるを 2 つ足した（曲がり・奥行きの書き出しの pass）・
  sky と景色を背景に描く環境マップが両方ある場面の書き残し（レビューは「GL は景色の絵を描く」と見立てたが、`backgroundEnvironmentOf` が sky のある場面で None を返すので GL も空の坂を描く。それを書いた）・
  `noteWritten` の doc・行の group 1 の付け直しの書き方・NDC の y の How を WhyNot へ・テストの期待値を手で書いた値に・skipsOf のテストを 1 つのアサートに。
- 門（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal・2026-11-16。直しの後の木で流し直した）:
  - render_gl のテスト（`make sync-layers` の後 `.layers/render_gl` で `bin/flix test`）547 緑・`make test-engine` 987 緑。
  - `make gl-parity` exit 0・`make gl-capture-check` exit 0（54 枚がバイトまで同じ）。
  - `make webgpu-v1-check` exit 0・`make -C bench/webgpu_v2 run` exit 0・誤り 0（34 場面と記録 2）。
  - `make lint ONLY=max-lines` exit 0・`make gl-jar-pin-check` exit 0（`render_gl/java` は触っていない）。
  - 落とし穴: engine の fpkg を作り直す（`engine_full` で `build-pkg`）と、bench の `packages.lock`（git の外）が古い fpkg の sha を持ったまま食い違い、`gl-parity`・`gl-capture-check` が依存の入れ直しで落ちる。bench の `packages.lock` を消して流し直した。逆に作り直さないと `gl-capture-check` と `webgpu-v1-check` が「fpkg が engine のソースより古い」で止まる（直しの後に作り直して流し直した）。最後の回は同じ機械で別の重い仕事が走っていて、bench の 1 コマの時間（記録）は 12.32 の数倍に出た（門の画素の数は同じ）。
- 言える範囲: この Mac（Dawn の Metal）だけ。ブラウザ（12.31 の口・TeaVM の JSO で頂点の buffer の無い pipeline を作れるか）・スマホ（adreno）で空の場面は流していない【未確認】。
- 持ち越し:
  - 空の frag は描き先の左上を場面の左上として向きを作る（`encodeScene` は任意の viewport を受けるが、空の向きの材料は描き先いっぱいの大きさで書く）。描き先の途中の矩形へ描く形（bench の貼る形 B）を本番に入れる時は、viewport の原点も R3dScene の末尾に足す。
  - 景色を背景に描く場面（sky の無い・`withEnvironmentAsBackground`）は (7) の環境マップと一緒に（空の frag に GLSL の `uEnvOn` の枝を足す）。
  - 空を前半の行にする（kindSky）かは、空の後に描く物（(6) の後がけ）が来た時に見直す（→ 12.34 で (6a) では変えないと決めた・(6b) で見直す）。
  - 12.28〜12.32 の持ち越しで (5b) で触らなかった物はそのまま。

### 12.34 R2b・P8 の (6a): 半透明（2026-11-16・この Mac・Dawn の Metal だけ）

表の 13・14 行目の小分け (6)「半透明・後がけ」の前半（人の決めで半分に割った。後がけは (6b)・ビルボードと環境マップは (7) で、どちらも触っていない）。
engine の pub（ゲームから見える API）は増えておらず、engine/ の公開の型シグネチャも変えていない（変えたのは render_gl の中だけ）。GL の画は変えていない（下の門）。GL の呼び出しの並びは変わった。

- **R2b — 半透明の並べ替えを前半へ・半透明を材質の行に**（形のレビュー（3D）の決め「半透明は前半で並べて材質の行として足す」のとおり）:
  - 計画（`Render3d.ScenePlan.sceneDrawsOf`）が半透明の材質の batch（1 体ずつ）を `Scene3d.blendOrderOf`（目から遠い順・同じ距離なら来た順）で並べる。並べる目は GL が描く時に使っていた目と同じ（`scene#camera#eye`）で、並べ替えは安定なので順は前と同じ。
    `DrawMode.OneByOne` でも並べる（GL も前から並べていた）。
  - `Render3d.SceneList` に `firstBlended`（読む口は `firstBlendedRowOf`）を足し、不透明の材質の行の後ろへ半透明の材質の行を計画の順のまま足す。行の欄・値（values）・絵の組（reads）は不透明の材質の行と同じ（12.28 の形のまま。行の欄は増やしていない）。
    分かれた理由は前と同じ `BatchBreak.Transparent`。「前の材質の行と同じ付け方」（`flagSameBinding`）は半透明の頭の行で数え直す（GL の `drawBlendedRows` は付けた物の控えを新しく作って始めるので、頭の行にフラグがあるとプログラムを付けずに描く）。
  - GL（`Render3d.GlRows`）: `drawRows` は `firstBlended` の前の行だけを描き、ビルボードの後に `drawBlendedRows` が残りの行を、深度を読むが書かず `glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA)` で描く（前の `drawBlended` と同じ状態の付け外し）。
    形と絵は行の `uploadRows` が上げる（前の `uploadBlended` を消した）。消した物: `Render3d.Material.drawMaterials`・`drawMaterialWith`・`Render3d.drawBatch`・`SceneInputs#blended`。`SceneList.batchBreakOf` は pub でなくした（使うのは SceneList の中だけになった）。
  - GL の呼び出しが変わった所: 同じ材質の半透明の物が続くと、2 つ目からは `flagSameBinding` でプログラムと材質の uniform と絵を付け直さない（前の `drawMaterials` は物ごとに入れ直していた）。値は材質で決まり、lightmap つきは `isSameBinding` が外すので絵は同じ【推: 画素で確かめたのは下の bench と gl-capture・gl-parity の範囲】。
  - 1 体ごとの値の番号と姿勢の行は `draws#blended` の並びで振るので、振る順が「来た順」から「遠い順」になった。上限（1 体ごとの値の絵の行・姿勢の行）を超えると後ろから落ちるので、**半透明の物は目に近い物から落ちる**（前は来た順の後ろから）。上限の内側では画は変わらない。`planScenes` の doc に書いた。
- **P8 — WebGPU で半透明を描く**:
  - `WebGpuMaterials.isDrawable` から半透明を外した（描けない版は alpha to coverage だけ）。材質の program の鍵（`materialKey` の `+bl`）が半透明の版を分けるので、pipeline の鍵（program の番号・形式・標本・頂点のバイト数）は今のまま。
  - 半透明の版の pipeline は GL と同じ混ぜ方（色 SRC_ALPHA・ONE_MINUS_SRC_ALPHA、α ONE・ONE_MINUS_SRC_ALPHA）で、深度は LESS で読むが書かない。frag が出す α は材質の albedo の α（`Render3dWgsl.materialFragmentSource` の blend の枝・12.28 で入れてあった）。
  - 行は今までどおり 1 本の `drawRows` で順に流す（不透明の行の後に半透明の行が来る）。GL が間に描くビルボードを WebGPU はまだ描かないので、この順で GL と同じ重なり（WhyNot に書いた）。
  - `skipsOf` から「3D の半透明の材質の物」を外した（骨つき・lightmap つきの半透明も描く）。Output.Depth の場面は前から計画が半透明の物を外している（`solidInstances`）ので、深度を書かない pipeline が奥行きの書き出しの pass に乗る事は無い。
  - スマホの上限（12.24）の内: 足した binding・頂点の buffer・varying は無い（不透明の材質の版と同じ）。
- **決めた事 — 空は kindSky にしない（12.33 の決めのまま）**: 12.33 は「空の後に描く物が場面の pass の列の途中に挟まる時に見直す」とした。(6a) の半透明は場面の色の pass の中で不透明の行の後（GL はビルボードの後）に描くので、空（pass の頭で地の色の直後）との順は変わらず、列の途中に空を挟む物は増えていない。
  行にしても GL は `drawSky` のまま行を読まず、backend が 2 つとも読まない kind が増えるだけなのも 12.33 と同じ。後がけ（(6b)）が来た時にもう一度見直す。
- **確かめ — `bench/webgpu_v2`** に 4 場面を足した（`BlendCases.flix`。部屋の手前に色の違う半透明の板を奥行きをずらして重ね、**目に近い物から**置く（来た順で描くと重なりの色が変わる）。1 枚は他の板と交わる向き（深度を書くと欠ける）・半透明の燭台の形（片面・裏を間引く）も 1 つ）:

  | 場面 | 違う画素（許容） | ±2 以上（許容） | 差の最大（許容） |
  |---|---|---|---|
  | blend（画面へ直に） | 14（64） | 7（32） | ±70（±255） |
  | blendDesign（design の解像度・α を掛けた後の値で貼る道） | 0（8） | 0（4） | ±0（±16） |
  | blendDepth（奥行きの書き出し＝半透明は書かない） | 11（24） | 1（4） | ±2（±16） |
  | blendMsaaPass（標本 4 の Pass に描いて貼る） | 17,181（34,000） | 13,689（28,000） | ±49（±128） |

  - 許す差の理由: blend は room と同じ所（重なる面の入れ替わり・14 px・±82）で同じ数で、半透明の板の画素は差に出ていない。blendDepth は半透明を書かないので部屋の奥行きの書き出しと同じ形の差。blendMsaaPass は skyMsaaPass（14,238）と同じ標本の位置の違い（12.25・12.26）。
    上限は実測のほぼ 2 倍（blend は room と同じ・blendDesign は skyDesign と同じ小さい物の下限）・差の最大は blend が面の入れ替わりで切らない。
  - **GL の画が変わらない事の確かめ**: 同じ bench を変更の前の render_gl（main の 10a934b4）でも流し、GL の絵 4 枚（blend・blendDesign・blendDepth・blendMsaaPass）が変更の後とバイトまで同じ。前の木の WebGPU は blend が 134,956 px 違って落ちた（半透明を頂点の色で不透明に描くため・(6a) の前の姿）。
  - **壊して確かめた**（同じ日に 1 回ずつ・確かめた後に戻した）:
    - WebGPU の半透明の pipeline の混ぜ方を外す: blend 134,956 px・blendDesign 135,099 px・blendMsaaPass 148,041 px 違って落ちる（blendDepth は 11 px のまま）。
    - WebGPU の半透明の pipeline で深度を書く: 交わる板が欠け、blend 12,563 px・blendDesign 12,474 px 違って落ちる（blendMsaaPass は 29,871 px で上限 34,000 の内・blendDepth は 11 px）。
    - 計画の並べ順を逆にする（近い順）: GL と WebGPU の両方が同じに変わるので bench は通る（GL の blend の絵は正しい順の絵と違う事を確かめた）。守るのは `TestSceneList.testPlanSortsBlendedFarToNear`（「expected m0.2 :: m0.3 :: m0.1, but got m0.1 :: m0.3 :: m0.2」で落ちた）。
  - 今までの 34 場面は 12.33 と同じ数。目で見て、赤と緑の板の重なり・交わる青い板・半透明の燭台が GL と同じ色で出る（`bench/webgpu_v2/debug/{gl,webgpu}/blend*.png`・git の外）。WebGPU の誤り 0。
- **欠けの表と実物**（12.33 と同じ流し方・写しは `scratchpad/a6a/setup.sh`・写しの engine はこの worktree の fpkg・`FGE_JAR_CACHE=off`・`FLIX_GE_HIDDEN=1`・`RUN_SECONDS=160`・頭の 64 コマ・WebGPU だけ。
  前は (5b) の fpkg で同じ日にみやげの町の 3 場面を流し直した物）:

  | 種類（1 コマあたり） | fps3d_lab 部屋 | 礼拝堂 | 通路 | みやげの町 arrival | market | night |
  |---|---|---|---|---|---|---|
  | 半透明の材質の物（前 → 後） | — | — | — | 18.6 → **0** | 18.6 → **0** | 12.7 → **0** |
  | ほかの種類 | 0 | 0 | 0 | 0 | 0 | 0 |

  - **後は 6 場面とも欠けの表が出ない**（飛ばした物が 0・`まだ描かない` の知らせも 0）。fps3d_lab は前から半透明が無い（12.32・12.33 と同じ）。WebGPU の誤り 0・落ちた場面なし・6 場面とも頭の 64 コマを撮れた。
  - 前の数は 12.33（18.6・11.4・8.0）と market・night で違う。同じ日の前の回では 18.6・18.6・12.7 で、V2b（12.26）の 12.6・18.6・12.7 とも並ぶ【推: 起動から 300 コマの中で頭の読み込みのコマの数が回ごとに違う（12.33 と同じ注意）】。
  - 見え方: market の 60 コマ目を 12.32 の GL の絵と並べて違いが見えない（店の窓が手前に出ているコマ）。画素で比べてはいない【推: コマの時刻が 2 本でそろわない】。
  - 絵の置き場: `/private/tmp/claude-501/-Users-abab-Desktop-flix-game-engine/1e409b86-520d-4126-86d6-d8af78577988/scratchpad/a6a/games/out/<ゲーム>-<場面>-webgpu/`（前は `…/a6a/before/out/`。**scratchpad の物は消えうる**）。
- テスト: render_gl 553 緑（12.33 の 547 に `TestSceneList` の 6 本: 半透明の行が不透明の行の後に並ぶ・半透明が無ければ頭は行の数・半透明の頭の行は付け直す・半透明の行の値と分かれた理由・計画が遠い順に並べる・骨つきの半透明の姿勢の行を遠い順に振る。
  `TestWebGpuScene3d` の半透明を数える 2 本は「数えない」と alpha to coverage で数える形に替え、`TestMeshTable.testDrawableKinds` は半透明を描ける版に直した）。engine の `make test-engine` 987 緑（engine は触っていない）。
- **レビュー（1 回・88 点・必須 2）で直した物**: 必須 1 = 上限を超えた時に半透明は近い物から落ちる事を `planScenes` の doc とこの記録に書いた（番号だけ来た順で振る形は取らなかった: 番号を振る並びと描く並びを別に持つ事になる。近い物から落ちる方が目立つが、上限を超えるのは 1 回知らせの出る異常な場面なので受け入れた）。必須 2 = この記録。
  任意で直した物: `blendedRowOf` → `firstBlendedRowOf`・`withLayouts` → `layoutPairsOf`（`with*` は値を差し替える意味）・`undrawableOf` → `undrawableCountOf`・GlRows の頭の流れに `drawBlendedRows`・`buildSceneList` の WhyNot に頭の行で付け直す本当の理由・
  WebGpuRenderer の予定の行を持ち越しへ・bench の許容（blend を room と同じ・blendDesign を skyDesign と同じ）・テストの helper（`skipsOfSceneOn`）と空行・骨つきの半透明の姿勢の行のテスト。
  直さなかった物: `skipsOf` の奥行きの書き出しの行（今はいつも 0。DepthOut では coverage が偽なので）は 12.27 からの物で (6a) で触らない・半透明の行の値を GL は読まない（1 行 1 体で物ごとに `putMaterialValues` が走る。数千の半透明の場面で測る）。
- 門（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal・2026-11-16。直しの後の木で流し直した）:
  - render_gl のテスト（`make sync-layers` の後 `.layers/render_gl` で `bin/flix test`）553 緑・`make test-engine` 987 緑。
  - `make gl-parity` exit 0・`make gl-capture-check` exit 0（a と b の 54 枚がバイトまで同じ・基準とも 54 枚がバイトまで同じ）。
  - `make webgpu-v1-check` exit 0・`make -C bench/webgpu_v2 run` exit 0・誤り 0（38 場面と記録 2・標本 4 と 1 の差 GL 4,761 px・WebGPU 4,158 px）。
    1 コマ（記録）は GL 1.03〜1.08 ms・WebGPU 1.76〜1.77 ms で、12.27 の 0.34〜0.58 ms より両方とも重い【推: 同じ機械でゲームの写しを流した後で、部屋の場面に半透明は無く (6a) の道を通らない】。
  - `make lint ONLY=max-lines` exit 0（`Render3d.flix` 1,098 行・`WebGpuRenderer.flix` 927 行）・`make gl-jar-pin-check` exit 0（`render_gl/java` は触っていない）。
  - 12.33 の落とし穴（fpkg を作り直した後の bench の `packages.lock`）は、門の前に bench の `packages.lock` を消して流した（この worktree では初めから無かった）。
- 言える範囲: この Mac（Dawn の Metal）だけ。ブラウザ（12.31 の口）・スマホ（adreno）で半透明の場面は流していない【未確認】。
- 持ち越し:
  - ビルボードを WebGPU に足す時（(7)）は、行の流し方を不透明の行・ビルボード・半透明の行の 3 つに分ける（GL の `drawPass` と同じ順）。
  - 空を前半の行にする（kindSky）かは後がけ（(6b)）で見直す。
  - 半透明の行の値（values・reads）は GL が読まないのに 1 体ごとに書く。粒子のように半透明が数千ある場面が来たら測る（`docs/performance.md` の候補）。
  - 12.28〜12.33 の持ち越しで (6a) で触らなかった物はそのまま。

### 12.35 R2b・P8 の (6b): 後がけ（2026-11-17・この Mac・Dawn の Metal だけ）

表の 13・14 行目の小分け (6)「半透明・後がけ」の後半（(6a) の半透明は 12.34。ビルボードと環境マップは (7)・描き先の寿命は (8) で、どちらも触っていない）。
engine の pub（ゲームから見える API）は増えておらず、engine/ の公開の型シグネチャも変えていない（変えたのは render_gl の中の WGSL の字と、それに渡す uniform の中身だけ）。GL は触っていない（下の門）。

- **後がけに当たる物の一覧**（計画書の 5.1 の表の「3D: ビルボードの集まり・空・後がけ」・`plans/webgpu/survey/B-2d-shader.md` の 5.2・`analysis-render-structure.md`・`docs/shader-doc.md` の「後処理」と `skipsOf` から洗い出した）:
  後がけは専用の描き手を持たず、**3D の場面を 2D の Pass に描き、ShaderDoc の面で画面全体を加工する**形で組まれている（`withPassPlan`。lamplighter の `PostView.flix` とほぼ同じ物が 9 本の試作にある）。部品は:
  1. 場面の Pass: ウィンドウの画素・`RenderTarget.withHdr`（Rgba16Float）・`withMsaa`（標本 4 なら resolve してから読む）
  2. 奥行きの Pass: 同じ場面の `Output.Depth` を縮んだ（0.5 倍など）Rgba16Float の Pass へ（被写界深度の材料）
  3. ぼかし: `Field.TexBlur`（Linear の sampler・縮んだ Pass に半分・4 分の 1 で 2 段）
  4. 明るい所: 場面の Pass を Linear で読み、`PostProcess.luma709` と Smoothstep で 1 を超える所だけ残す（ブルームの材料）
  5. 本編の面: くっきりした場面とぼかした場面を奥行きで混ぜ、ブルームを足し、ビネット（`Field.RadialAspect`）を掛け、`PostProcess.tonemappedWith`（AcesFitted か Reinhard）と彩度で仕上げてウィンドウの画素の Rgba8Unorm の Pass へ
  6. FXAA: `PostProcess.fxaaSpec` の面で画面へ
  - `skipsOf`（3D の欠けの数え）に後がけの種類は無い（数えているのは alpha to coverage・ビルボード・環境マップ・奥行きの書き出しの描けない材質だけ）。2D の側の飛ばす口（`WebGpuSurfaces` の「組んでいない program」「値の欄が行の値より多い」・起動の後に足す字・preload）も後がけでは出ない。
    **外す種類は無かった**: 部品の 1〜6 は R1b（Pass・HDR・MSAA の resolve・面と絵の組・12.19〜12.22）と (1) の奥行きの書き出し（12.27）で、もう WebGPU が描ける。
- **決めた事 1 — 後がけは前半の行にしない（今の形のまま）**: 後がけは 2D の `(PassSpec, 行)` の列で流れ、場面の pass の列（`ScenePasses`）の外にある。場面の中で後がけを描く形（場面の列に後がけの pass を足す・3D の描き手が自分の後がけを持つ）は、
  GL も WebGPU も今の 2D の Pass と面で描けて、ゲームの書き方（9 本の `PostView`）も変わらないので取らなかった（読む物の無い kind と、同じ加工の 2 本目の道が増えるだけ）。
- **決めた事 2 — Design の場面を縮んだ Pass へ貼る時の縦の texel を GL にそろえた**: bench で鎖を比べて見つけた差。Design の場面（design px の描き先に描いた絵）を 2:1 に縮んだ Pass（後がけの奥行きの Pass の形）へ貼ると、
  貼る画素の真ん中がちょうど 2 つの texel の境目に来る。GL（`Render3d.blitDesign`・FBO は下の行が先・nearest で読む）は縦を下から数えて floor し、WebGPU（`WebGpuShader.sceneWgsl`）は上から数えて floor していたので、縦が 1 行ずれた。
  - 直し: `sceneWgsl` は縦を下から数えて floor し、上からの行番号に戻す（`last - fromBottom`）。Paste の uniform を（左上・texture の画素 ÷ 矩形の画素）から（左上・矩形の大きさ）へ替えた（`WebGpuRenderer.writePaste`。16 バイトのまま・bind group の layout は同じ）。
    Native の場面は texture と矩形が同じ大きさなので 1 画素ずつ写す性質は変わらない（bench の Native の場面は全部前と同じ数）。3 倍に拡げる Design の場面（roomDesign など）は境目に来ないので 0 px のまま。
  - 残った差: halfDepthDesign 233,784 → **95,868 px**・±2 以上 74,952 → **9,576 px**。残りは横で、列ごとに GL の補間した uv が境目のどちら側に落ちるかが揺れる所【推: 差の絵で、右の 1/5 の列はそろい、ほかの列で GL だけ 1 つ手前の texel を読む】。
    横の選び方を 3 通り試して減らなかった（GL と同じ順に uv を作ってから掛ける形は今と 1 px も同じ・横だけ境目の手前へずらすと 97,272・12,996・縦横とも手前へずらすと 232,020・78,732）。
    決まった側を選ぶ形では GL にそろわないので、許容（実測のほぼ 2 倍）を置いて残した。GL の補間を写す形（矩形の四角を頂点で描き、uv を頂点から補間する）は、ふちの外へはみ出す矩形の viewport の誤り（`sceneWgsl` の WhyNot）を避ける組み直しが要るので試していない。
  - 2 本の実物と、`~/Documents/flix_ge_workspace` の試作に Design の場面を使う物は無い（`Resolution.Design` を書いたフォルダが無かった）。この差が出るのは bench の組み合わせだけ【推: 2 本と試作の .flix を字で探しただけ】。
- **決めた事 3 — 空は kindSky にしない（閉じる）**: 12.33・12.34 は「空の後に描く物が場面の pass の列の途中に挟まる時（後がけ）に見直す」とした。後がけは上のとおり場面の列の外の 2D の Pass で走り、場面の列の途中に空の後で描く物は増えなかった。
  行にしても GL は `drawSky` のまま行を読まず、backend が 2 つとも読まない kind が増えるだけなのも 12.33 と同じ。**次に見直すのは P9 で行を render bundle として持ち越す時**（空は行の外の別の pipeline なので、bundle と空の draw の並びを決め直す）。
  (7) の景色を背景に描く場面は空の frag に `uEnvOn` の枝を足す形（12.33 の持ち越し）で、行にする理由にはならない【推】。
- **確かめ — `bench/webgpu_v2`** に 5 場面を足した（`PostCases.flix` の `V2Post.chain`: 上の部品の 1〜6 を lamplighter の `PostView` と同じ並び・形式・大きさで組み、部屋（yaw 0.3）を通す。`halfDepthPassCase`: 半分の大きさの奥行きの Pass に部屋の奥行きの書き出しを描いて貼る）:

  | 場面 | 違う画素（許容） | ±2 以上（許容） | 差の最大（許容） |
  |---|---|---|---|
  | post（場面の Pass は標本 1・AcesFitted） | 247（500） | 42（84） | ±34（±255） |
  | postMsaa（場面の Pass は標本 4） | 55,680（112,000） | 13,138（27,000） | ±47（±128） |
  | postDesign（場面を Design で・Reinhard） | 15,386（31,000） | 3,624（7,300） | ±48（±128） |
  | halfDepthDesign（Design の奥行きの書き出しを半分の Pass へ） | 95,868（192,000） | 9,576（19,000） | ±63（±128） |
  | halfDepthNative（Native の奥行きの書き出しを半分の Pass へ） | 0（0） | 0（0） | ±0（±0） |

  - 許す差の理由: post は room と同じ所（重なる面の入れ替わり・14 px）の差をぼかしと FXAA が周りへ広げた物（差の絵で確かめた・家具のふちの数か所に固まる）。postMsaa は blendMsaaPass と同じ標本の位置の違い（±2 以上が同じ桁）をぼかしが広げた物。
    postDesign と halfDepthDesign は上の決めた事 2 の横の揺れ。上限は実測のほぼ 2 倍・差の最大は post だけ面の入れ替わりで切らない（255）。
  - MSAA の門を後がけにも足した（`isMsaaApplied`）: postMsaa と post の差は GL 103,546 px・WebGPU 101,880 px（WebGPU が GL の半分未満なら落とす。railsMsaa と railsNoMsaa は GL 4,761・WebGPU 4,158 のまま）。
  - Reinhard の曲線を通すのは postDesign だけ（解像度と曲線を同時に替えている。落ちた時は halfDepthDesign と見比べて分ける）。
  - **壊して確かめた**（同じ日に 1 回ずつ・確かめた後に戻した）:
    - 縦を上から数える（直す前の式）: halfDepthDesign 233,784 px・±2 以上 74,952、postDesign 39,305・8,971 で落ちる。
    - 面の Linear の sampler を Nearest にする（`WebGpuSurfaces.fresh`）: post 242,261・postMsaa 244,492・postDesign 199,268 px で落ちる。
    - Rgba16Float の Pass を RGBA8 で作る（`WebGpuPipelines.textureFormatOf`）: post 380,643・postMsaa 389,924・postDesign 269,794 px と roomDepthPass 13,581・halfDepthNative 14,472 px で落ちる。
    - 縦の選び方を守るのは bench だけ（`make test` の範囲のテストは無い。`TestWgslDawn` は WGSL を組めるかだけを見る）。
  - 今までの 38 場面は 12.34 と同じ数。目で見て、ぼけ（手前の卓と奥の壁）・灯りのブルーム・ビネットが GL と同じ所に出る（`bench/webgpu_v2/debug/{gl,webgpu}/post*.png`・git の外）。WebGPU の誤り 0。
- **比べていない物**（【未確認】）:
  - 後がけの Pass が history を読む形（Rgba16Float・MSAA の resolve の後の history を面が読む）。history は 2D の 12.19（Rgba8 が中心）で確かめただけ【推: `applyHistory` と写す pipeline は形式を受けるので通る】。
  - 場面のビルボードが Pass の history を読む時（WebGPU の描き先の使い中の控えがスプライトと面しか見ない件・12.21 の持ち越し）は (7) で。
  - HUD を FXAA の面の上に重ねる形は 2D だけなので `bench/webgpu_v1` の範囲。
  - 描き先の外へはみ出す Design の場面を縮んだ Pass へ貼る形（今回 `rel` を使う所が変わった。はみ出す場面は bench に無い）・整数でない縮め比（3:2 などでも境目に来る。2:1 だけ確かめた）・Design の場面を標本 4 の Pass へ貼る形（postDesign は標本 1）。
  - ブラウザ（12.31 の口）・スマホ（adreno）で後がけの場面は流していない。
- **欠けの表と実物**（12.34 と同じ流し方・写しは `scratchpad/a6b/setup.sh`・写しの engine はこの worktree の fpkg（後）と (6a) の fpkg（前）・`FGE_JAR_CACHE=off`・`FLIX_GE_HIDDEN=1`・`RUN_SECONDS=160`・頭の 64 コマ・WebGPU だけ）:

  | 種類（1 コマあたり） | fps3d_lab 部屋 | 礼拝堂 | 通路 | みやげの町 arrival | market | night |
  |---|---|---|---|---|---|---|
  | どの種類も（前 → 後） | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 |

  - 前も後も 6 場面とも欠けの表が出ない（`まだ描かない` の知らせも 0）。WebGPU の誤り 0・落ちた場面なし・6 場面とも頭の 64 コマを撮れた。
  - 2 本とも Design の場面を使わないので、今回の直しは絵を変えないはず。みやげの町の 3 場面は前と後の 64 コマが**全部バイトまで同じ**。
    fps3d_lab は 3 場面とも頭の 5〜8 コマだけ同じで後は違う。2D だけの通路（`START=play`）でも同じ割合で違うので、場面の時計が実時間で進む物【推: 灯りの揺れや衛兵の動きが撮ったコマの時刻でずれる】で、今回の直しとは関わらない。
  - 後がけを使うほかの試作 2 本（参考・`~/Documents/flix_ge_workspace` から写して engine だけ 0.98.0 へ向けた・元のフォルダは触っていない・大きな `data`・`assets` は symlink・写しは `scratchpad/a6b/setup-others.sh`）:

    | 試作（場面） | 欠けの表（前 → 後） | WebGPU の誤り | 見え方 |
    |---|---|---|---|
    | plateau_city（`SHOT=street`・0.92.0 から） | 0 → 0 | 0 | 町の通りと影・空・後がけが出る（GL と並べていない） |
    | sea_cave_walk（`SHOT=cave`・0.88.0 から） | 3D の場面の preload 0.8 → 0.5（頭の読み込みのコマの数の揺れ） | **5**（前も同じ 5） | 洞窟の岩と砂が出る。海の材質（`sea:wave`）の WGSL が Dawn の解析の入れ子の深さの上限で組めない（下の持ち越し） |

    - 2 本とも今の engine で写しに直しを入れずに型が通った。どちらも `PostView`（後がけの鎖）を持つ。前と後の 64 コマが 2 本とも全部バイトまで同じ（Design の場面を使わない）。
    - sea_cave_walk の誤り: 海の材質の frag の 1 行が、同じ `max(0.0, clamp(…))` を 200 段ほど掛け合わせた式（光の鋭さを掛け算で展開した物【推】）で、Tint の「maximum parser recursive depth reached」で組めない。GLSL は通る。
      材質の WGSL の出し方（(2)・P5 の `ShaderGen` の WGSL の書き手）の問題で、後がけではない。preload は (7)。

- テスト: render_gl 553 緑（12.34 と同じ。足したテストは無い・上の「守るのは bench だけ」）。engine の `make test-engine` 995 緑（engine は触っていない）。
- **レビュー（1 回・86 点・必須 2）で直した物**: 必須 1 = 残った横の揺れに許容を置く前に、安い別案を試す（GL と同じ順に uv を作ってから掛ける形・横だけ境目の手前へずらす形・縦横とも手前へずらす形を試し、どれも減らなかった事を上の決めた事 2 と bench の許容の記録に書いた）。
  必須 2 = この記録の「比べていない物」と、kindSky を次に見直す時（P9 の render bundle）を書いた。
  任意で直した物: `sceneWgsl` の doc を「同じ選び方（最も近い画素・縦は下から数える）」に・`msaaGate` を `isMsaaApplied` に・`writePaste` の doc の要らない括弧を消した・
  Reinhard を通すのは postDesign だけな事と、縦の選び方を守るのは bench だけな事をこの記録に・9 章の表の 14 行目に横の揺れを残した事を一言。
  直さなかった物: 縦の選び方の Dawn のテスト（小さな絵を 2:1 で貼って読み戻す 1 本）は足していない（bench が守る。`make test` の範囲で止めるなら P10 の前に）・`PostCases.flix` の小さな helper（`k`・`add` など）は lamplighter の `PostView` と同じ書き方のまま。
- 門（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal・2026-11-17。直しの後の木で流し直した）:

  - render_gl のテスト（`make sync-layers` の後 `.layers/render_gl` で `bin/flix test`）553 緑・`make test-engine` 995 緑。
  - `make gl-parity` exit 0・`make gl-capture-check` exit 0（a と b の 54 枚がバイトまで同じ・基準とも 54 枚がバイトまで同じ）。
  - `make webgpu-v1-check` exit 0・`make -C bench/webgpu_v2 run` exit 0・誤り 0（43 場面と記録 2・標本 4 と 1 の差 GL 4,761 px・WebGPU 4,158 px と、postMsaa と post の GL 103,546 px・WebGPU 101,880 px）。
    1 コマ（記録）は GL 1.00〜1.06 ms・WebGPU 1.58〜1.76 ms（12.34 と同じ桁・同じ機械でゲームの写しを流しながら）。
  - `make lint ONLY=max-lines` exit 0・`make gl-jar-pin-check` exit 0（`render_gl/java` は触っていない）。
  - 12.33 の落とし穴（fpkg を作り直した後の bench の `packages.lock`）は、門の中で `make sync-engine-full` の後に bench の `packages.lock` を消して流した。

- 言える範囲: この Mac（Dawn の Metal）だけ。
- 持ち越し:
  - Design の場面を縮めて貼る所の横の境目の揺れ（上の決めた事 2・許容で残した）。GL の補間を写す形を試すなら、はみ出す矩形の viewport の誤りを避ける組み直しと一緒に。
  - 上の「比べていない物」。
  - 空を前半の行にする（kindSky）かは P9 の render bundle の時に見直す。
  - sea_cave_walk の海の材質の WGSL が Tint の解析の入れ子の深さの上限で組めない（上の欠けの表）。材質の WGSL の書き手で、深い式を中間の let に分けて出すか、同じ部分式を 1 回だけ置く（GLSL と同じ式のまま）。fps3d_lab とみやげの町と bench では出ていない。
  - 12.28〜12.34 の持ち越しで (6b) で触らなかった物はそのまま。

### 12.36 R2b・P8 の (7a): ビルボード（2026-11-17・この Mac・Dawn の Metal だけ）

表の 13・14 行目の小分け (7)「ビルボード・環境マップ」の前半（人の決めで半分に割った。環境マップ・mip・preload は (7b)・描き先の寿命は (8) で、どちらも触っていない）。
engine の pub（ゲームから見える API）は増えておらず、engine/ の公開の型シグネチャも変えていない（変えたのは render_gl の中だけ）。GL の画は変えていない（下の確かめ）。GL の呼び出しの並びは同じ（描く物を行から読むだけ）。

- **R2b — ビルボードを場面の行に**（形のレビュー（3D）の決め「ビルボードは kindBillboard」と、12.34 の持ち越し「行の流し方を不透明・ビルボード・半透明の 3 つに分ける」のとおり）:
  - 計画（`Render3d.ScenePlan.sceneDrawsOf`）が場面のビルボードを来た順で `SceneDraws#billboards`（`BillboardDraw` = 中身と culled）に置く。視錐台は置いた物と同じ `Scene3d.frustumOf`・間引きは前と同じ `Scene3d.isBillboardOutsideFrustum`。
    視錐台の外の物も列から外さない（GL は絵が見つからない知らせを間引く前に出すので、外すと知らせが消える）。色の pass と奥行きの書き出しの pass の両方に置く。
  - `Render3d.SceneList` が不透明の材質の行の後・半透明の行の前に、ビルボードの行（`kindBillboard`・1 行 1 つ）を足す（`firstBillboard`・読む口は `firstBillboardRowOf`）。行の欄は 1 = 全体の登録の絵の番号（見つからなければ -1）・4 = 視錐台の中なら 1・5 = 分かれた理由（Billboard）・8 = 値の先頭。
    値（16 float: 立てる点と lit・anchor と size・貼る範囲の uv・線形へ戻した tint）は視錐台の中で絵がある行だけ、values の**材質の値の後ろ**に書く（材質の 256 バイトの区画のそろえを崩さない）。貼る範囲の v はレンダーターゲットでも上から数える（読むのは上の行が先の WebGPU）。
    GL は uniform を今までどおり中身の配列（`billboards`・`billboardAt`）から差す（材質の行が `materials` から差すのと同じ形）。
  - GL（`Render3d.drawPass`）: `GlRows.drawRows` は `firstBillboard` の前まで・`Render3d.drawBillboards` がビルボードの行・`drawBlendedRows` が残りの行（前と同じ順）。奥行きの書き出しは前の 2 つ。
    GL は絵を描く時に引き、行の欄 4（視錐台）だけを見る（レビューの必須 2: 計画の時に引いた絵の有無で GL を止めると、計画と描く時で表が違う時に知らせ無しで描かなくなる）。`CameraData#frustum` は読む物が無くなったので消した。
- **P8 — WebGPU でビルボードを描く**:
  - `Render3d.WebGpuBillboards`（pipeline の表）と `Render3dWgsl.billboardVertexSource`・`billboardFragmentSource`（GLSL と同じ式）。四角の角は vertex_index の 6 点（GL の `buildQuad` と同じ並び）。裏を間引かず・深度は LESS で書く・α < 0.5 を捨てる（GL と同じ）。
  - bind group: 0 = 場面（`R3dCamera` にカメラの right・up・−forward を足して 176 バイト。影の地図の pass の camera の buffer も同じ大きさへ）・1 = **2D の描き手の絵の group をそのまま借りる**（`Host#groupById`。絵と sampler が GL の 2D の絵と同じ組で、絵ごとに group を作らない）。
    値は材質の値の buffer（usage に VERTEX を足した）を stride 0 の instance の頂点の buffer 0 として、行ごとに位置だけ替えて読む（2D の行の値と同じ形）。
  - 影: ビルボードは影を受けない（GLSL のビルボードのプログラムは uShadowOn・uSunShadowOn を付けず 0 のまま読む）。WGSL は場面の group 0 の on を読まず、`spotShadow` が 1・`r3d_sunLit` が 1 の版（`unshadowedSource`）で光の式を組む。
  - 行の流し方: WebGPU は行の順のまま 1 本の `drawRows` で流す（行の順が不透明 → ビルボード → 半透明で、GL が 3 回に分ける理由の深度の書き込みと blend は WebGPU では pipeline ごとに決まっている）。ビルボードの行の後は材質の行が pipeline と group 1 を付け直す（共用の控え `mp`）。
  - 絵が見つからない行は描かず、GL と同じ字（`Render3d.missingBillboardTextureLine`）で 1 回知らせる（`SceneList.missingBillboardTexturesOf`）。draw の数は GL と同じ欄（Billboard）で、描く物の数には入れない。
  - `skipsOf` から「3D のビルボード」を外した（色の pass・奥行きの書き出しの両方）。
  - スマホの上限（12.24）の内: varying 5 本・頂点の buffer 1 本（stride 0）・group 0 の binding 5 は 176 バイト・group 1 は絵と sampler の 2 つ。
- **決めた事 — 場面の history は (7a) で閉じた**（12.21 の持ち越し「場面のビルボードが Pass の history を読む時、WebGPU の `paintTarget` はスプライトと面しか見ない」）:
  ビルボードが Pass の絵を貼る道そのものが (7a) で入り、直しは 2D の描き手の history の要否に場面のビルボードを足す 1 か所（`WebGpuPaint.isHistoryReadIn`・GL の `RenderPaint.paintTarget` と同じ式）で済んだので、(7b) へ回さなかった。
- **確かめ — `bench/webgpu_v2`** に 6 場面を足した（`BillboardCases.flix`。絵は組み込みの放射の絵と、毎コマ透明の上に穴の空いた看板を描く Pass（GL は行 0 が下・WebGPU は上なので、uv の上下の取り違えが出る）。
  光を当てる物・当てない物・家具に半分隠れる物・目の後ろの物・絵の一部を貼る物を混ぜた。GL の撮りも history を写す形（`GlOffscreen.withHistoryKept`）にした）:

  | 場面 | 違う画素（許容） | ±2 以上（許容） | 差の最大（許容） |
  |---|---|---|---|
  | billboard（部屋・画面へ直に） | 61（128） | 26（52） | ±82（±255） |
  | billboardDesign（design の解像度） | 0（8） | 0（4） | ±0（±16） |
  | billboardDepth（奥行きの書き出し） | 10（24） | 1（4） | ±2（±16） |
  | billboardGlass（半透明の板の奥と手前） | 14（64） | 7（32） | ±70（±255） |
  | billboardMsaaPass（標本 4 の Pass に描いて貼る） | 13,212（27,000） | 11,178（23,000） | ±60（±128） |
  | billboardHistory（Pass の中の場面のビルボードがその Pass 自身の history を貼る） | 18（40） | 0（4） | ±1（±16） |

  - 許す差の理由: billboard は room と同じ所（重なる面の入れ替わり・14 px）に、光を当てない放射の絵の 1 行（47 px・±1〜2）が足された物（256 texel を約 105 px に縮めて最も近い texel を読み、その行だけ画素の真ん中が texel の境目に来る【推: 差の画素が 1 行に並び、値が隣の texel の値】）。
    billboardGlass は blend と同じ数・billboardDepth は blendDepth と同じ形・billboardMsaaPass は skyMsaaPass と同じ標本の位置の違い・billboardHistory は入れ子の看板の中の ±1 だけ。上限は実測のほぼ 2 倍。
  - **GL の画が変わらない事の確かめ**: 変更の前の render_gl（main の 837602dc）へ戻して fpkg を作り直し、`make gl-parity` の GL の絵 63 枚（ビルボードの 3 場面を含む）と `bench/webgpu_v2` の GL の絵 51 枚（上の 6 場面を含む）が、変更の後とバイトまで同じ。前の木の WebGPU はビルボードの 6 場面がどれも落ちた（描かないので 1.9 万〜8.2 万 px）。
  - **壊して確かめた**（同じ日に 1 回ずつ・確かめた後に戻した）:
    - WebGPU のビルボードの pipeline で深度を書かない: billboardGlass が 9,586 px 違って落ちる（手前の看板の後ろの板が上に重なる。ほかの 5 場面は通る）。
    - WebGPU の uv を GL のように上下に返す: 6 場面とも落ちる（8,011〜38,187 px）。
    - `isHistoryReadIn` から場面のビルボードを外す: billboardHistory が 18,684 px 違って落ちる（history の絵が無く看板が描かれない）。
    - 計画の行の順でビルボードを半透明の後へ回す: GL と WebGPU が同じに変わるので bench では止まらない。`TestSceneList` のビルボードの 7 本が落ちる（行の並び・値・材質の引きが崩れる）。
  - 今までの 43 場面は 12.35 と同じ数。目で見て、看板の色の並び・穴・半透明の板の奥の放射の絵・入れ子の history が GL と同じ所に出る（`bench/webgpu_v2/debug/{gl,webgpu}/billboard*.png`・git の外）。WebGPU の誤り 0。
- **欠けの表と実物**（12.35 と同じ流し方・写しは `scratchpad/a7a/games.sh`・後 = この worktree の fpkg（レビューの直しの前の木・直しは絵の無いビルボードの道だけ）・前 = (6b) の fpkg・`FGE_JAR_CACHE=off`・`FLIX_GE_HIDDEN=1`・`RUN_SECONDS=160`・頭の 64 コマ・WebGPU だけ）:

  | 種類（1 コマあたり） | fps3d_lab 部屋 | 礼拝堂 | 通路 | みやげの町 arrival | market | night |
  |---|---|---|---|---|---|---|
  | どの種類も（前 → 後） | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 |

  - 2 本ともビルボードを使わない（12.26 の表で 0）ので、前も後も欠けの表が出ない。WebGPU の誤り 0・落ちた場面なし・6 場面とも頭の 64 コマを撮れた。
    みやげの町の 3 場面は前と後の 64 コマが全部バイトまで同じ。fps3d_lab は頭の 10〜14 コマだけ同じで、12.35 と同じく場面の時計が実時間で進む物【推】。
  - 参考の試作 2 本（12.35 と同じ写し方・engine だけこの worktree の fpkg へ向けた・元のフォルダは触らない）:

    | 試作（場面） | 欠けの表（前 → 後） | WebGPU の誤り | 64 コマ |
    |---|---|---|---|
    | plateau_city（`SHOT=street`） | 0 → 0 | 0 | 前と後でバイトまで同じ |
    | sea_cave_walk（`SHOT=cave`） | 3D の場面の preload 0.8 → 0.5（頭の読み込みのコマの数の揺れ・12.35 と同じ） | 5（前も同じ 5・海の材質の WGSL の入れ子の深さ・12.35 の持ち越し） | 前と後でバイトまで同じ |

  - ビルボードを使う実物はこの 4 本に無い。ビルボードの門は bench（上の 6 場面）と `bench/gl_parity` の GL の 3 場面だけ。
- テスト: render_gl 564 緑（12.35 の 553 に、`TestSceneList` の 8 本（行の並び・値・target の uv・値の置き場・視錐台の外・絵が無い・材質を持たない・計画の culled）・
  `TestWebGpuScene3d` の 2 本（ビルボードを数えない・場面のビルボードが history を読む）・`TestWebGpuScene3dDawn` の 1 本（ビルボードの pipeline を標本 1 と 4 で Dawn が誤り無しに作る）。
  `TestWgslDawn` にビルボードの WGSL 2 本を足した（379 本）。奥行きの書き出しの数え方のテストは「ビルボードを数えない」形に直した）。`make test-engine` 995 緑（engine は触っていない）。
- **レビュー（1 回・84 点・必須 3）で直した物**: 必須 1 = この記録と 9 章の表。必須 2 = 絵の有無を GL は描く時だけ引く（行の欄 4 は視錐台だけ・WebGPU は値の無い行を描かない）。必須 3 = 使わなくなった `CameraData#frustum` と `drawScene` の視錐台を消した。
  任意で直した物: 行の欄 3（billboards の番号）をやめて行の位置で引く・描く条件を `isDrawnBillboard` 1 か所に・`billboardDrawsOf` を pub でなく・局所の名前 `valueCursor`・WhyNot の計画の節の番号を消した・
  `drawBillboard` の末尾を `()` で終える（JIT・docs/performance.md の 13 節）・`WebGpuRenderer.readsTexture` を通す理由の WhyNot・WebGPU の draw の数を描く前に数える事を doc に・`headAt` をビルボードの行で呼ばない事を SceneList の頭に・ビルボードの pipeline を作る Dawn のテスト（T1）。
  直さなかった物: `materials` と `heads` の配列のビルボードの行の所の空き（番号を詰めると半透明の行の引きが 2 通りになる。`materialAt` が None を返し、頭のコメントに書いた）・
  WebGPU の 3D の診断の数（ビルボードの draw の数）のテスト（T2）と、GL の FakeGl でビルボードの行を描く数と知らせが 1 回のテスト（T3・T4）は持ち越し（bench は絵だけを比べる）。
- 門（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal・2026-11-17。直しの後の木で流した）:
  - render_gl のテスト（`make sync-layers` の後 `.layers/render_gl` で `bin/flix test`）564 緑・`make test-engine` 995 緑。
  - `make gl-parity` exit 0・`make gl-capture-check` exit 0（a と b の 54 枚がバイトまで同じ・基準とも 54 枚がバイトまで同じ）。
  - `make webgpu-v1-check` exit 0・`make -C bench/webgpu_v2 run` exit 0・誤り 0（49 場面と記録 2・標本 4 と 1 の差は GL 4,761・WebGPU 4,158 px と GL 103,546・WebGPU 101,880 px で 12.35 と同じ）。
    1 コマ（記録）は GL 1.04〜1.07 ms・WebGPU 1.50〜1.83 ms（12.35 と同じ桁・ゲームの写しを流しながら）。
  - `make lint ONLY=max-lines` exit 0（`Render3d.flix` 1,111 行・`WebGpuRenderer.flix` 972 行）・`make gl-jar-pin-check` exit 0（`render_gl/java` は触っていない）。
  - fpkg を作り直した後に bench の `packages.lock` を消して流した（12.33 の落とし穴）。
- 言える範囲: この Mac（Dawn の Metal）だけ。ブラウザ（12.31 の口）・スマホ（adreno）でビルボードの場面は流していない【未確認】。
- **比べていない物**（【未確認】）: 絵の無いビルボードの知らせが GL と WebGPU で同じ回数出る事（字は同じ関数・回数はテストが無い）・ビルボードを数千立てる場面の速さ（1 行 1 つの draw・束ねるなら欄 4 を数にする）・
  Rgba16Float の Pass へビルボードを描く形・Design の場面を縮んだ Pass へ貼る形にビルボードを載せる形（12.35 の横の揺れと同じ道）。
- 持ち越し:
  - 上のテストの持ち越し（T2〜T4）。
  - 同じ絵の続くビルボードを 1 つの instanced draw に束ねる（GL も WebGPU も今は 1 行 1 つ。粒子のように数千ある場面が来たら測る・`docs/performance.md` の候補）。
  - 12.28〜12.35 の持ち越しで (7a) で触らなかった物はそのまま（sea_cave_walk の WGSL の入れ子の深さ・Design の縮めの横の揺れ・kindSky は P9）。

### 12.37 R2b・P8 の (7b): 環境マップ・mip・preload（2026-11-17・この Mac・Dawn の Metal だけ）

表の 13・14 行目の小分け (7) の後半（(7a) のビルボードは 12.36。描き先の寿命は (8) で、触っていない）。engine の pub（ゲームから見える API）は増えておらず、engine/ の公開の型シグネチャも変えていない
（engine/ で変えたのは WGSL の書き手の中だけ・render_gl の中は WebGPU の backend と、GL の preload の知らせを共用の関数へ寄せた所）。GL の画は変えていない（下の門）。

- **決めた事 1 — 環境マップは前半の行にしない**（形のレビュー（3D）の決め「環境マップは場面の値」のとおり）: 絵は場面に 1 枚で、材質の行も空も同じ物を読むので、場面の group 0 の binding 3 に付ける（前から宣言だけあった口）。
  - 絵は材質の絵と同じ置き場（`TextureTable3d`・CPU の `Mip.build` の mip・使い方 `MaterialTexture`）で作る（`WebGpuMaterials.ensureEnvironmentTexture`）。見つからなければ代わりの絵（透明な黒・mip 無し）で読み、GL と同じ文で名前ごとに 1 回知らせる（`WebGpuRenderer.ensureEnvironment`）。
    環境マップの絵の名前は `Scene3d.environmentMap` が Texture3d から作る "tex3d:" の名前だけなので、上下を返して読む全体の登録の絵（レンダーターゲット）が来る道は持たない（WhyNot に書いた）。
  - 場面の値: R3dScene の `uEnvOn`・`uEnvBoxOn`・箱・`uEnvLevels`・`uEnvIntensity` を GL の `Render3d.Light.environmentUniforms` と同じ値で書く（`packSceneValues`。環境マップの無い場面も毎回書く決まりのまま）。
  - group 0: 影の地図と同じく、環境マップのある場面はその絵を付けた group 0 を作り（submit の後に手放す）、無い場面は描き先の物のまま。
  - 景色を背景に描く場面（`withEnvironmentAsBackground`・sky が無い）: 空の pipeline で描き、空の frag が `uSkyUp.w`（今まで 0 だった欄）のフラグで絵を mip のレベル 0 で読んで強さを掛ける（GLSL の空の frag の `uEnvOn` の枝と同じ式）。
    `uEnvOn` は材質の映り込みでも立つので空のフラグに使わない（sky と背景の景色が両方ある場面は GL も空の坂を描く・`Scene3d.backgroundEnvironmentOf`）。`WebGpuSky.isDrawn` は GL と同じ `Scene3d.drawnSkyOf`。
  - `skipsOf` から「3D の環境マップ」を外した。
- **決めた事 2 — preload は GL と同じ約束で WebGPU の backend が持つ**（`WebGpuRenderer.preload`・`WebGpuMaterials.preloadMaterial`・`WebGpuPaint` の `preload3d` → `WebGpuPaint.Scenes.preload`）:
  宣言の置いた物を計画と同じ `groupInstances` で候補に分け、候補ごとに形（`MeshTable.ensure`）・材質の program・読む絵と、画面の形式（RGBA8・標本 1）の pipeline（材質の版と頂点の色の版）を作る。
  - 同じ key なら何もしない・組み直しが続けば知らせる（`Render3d.Preload.noteRebuild` に寄せて GL と共用）・宣言の textures に無い "tex3d:" の絵は GL と同じ文で知らせる（`Render3d.Preload.missingTextureLine`）。
  - 先に上げた形と絵は、`endFrame` の上限で捨てる順を後へ回す（`MeshTable.trim` と `TextureTable3d.sweep` に控えを渡す。捨てた時の知らせ `Render3d.warnDroppedMeshes`・`warnDroppedTextures` は planner で知らせる形にして GL と共用）。
  - 材質の program は WebGPU では捨てないので控えない。pipeline は描き先の形式と標本が宣言の時に分からないので、画面へ直に描く形だけを作る（GL の coverageVersions と同じ理由・WhyNot）。
  - 材質が読む絵の並び（材質の絵 → 法線マップ → lightmap）は `WebGpuMaterials.textureReadsOf` に寄せ、行の分（`uploadRowTextures`）と preload で共用。
- **決めた事 3 — mip（決まり 7）は場面の絵は今のまま・全体の登録の絵の mip つきの写しは人に伺う**:
  - 場面の絵（"tex3d:"・環境マップを含む）は (2) から CPU の `Mip.build` の mip で上げていて、GL（PC）の CPU の mip と同じ物（ブラウザの WebGPU も wasm の中で同じ Mip.build）。bench の mipFloor（浅い角度の市松の床）と環境マップの roughness の球で、mip のレベルを選ぶ式（`sg_texMip`・`roughness × (レベルの数 − 1)`）まで GL と ±2 以内で合う。
  - 全体の登録の絵（project.json の絵・2D の描き手の絵）は WebGPU では mip 無しのまま借りている（GL の PC は読み戻して Mip.build、ブラウザの GL は generateMipmap）。決まり 7 の「小さくしながら描く render pass」には **texture の mip のレベル 1 つを描き先にする view** が要るが、
    `render_gl/java/fge/webgpu/Texture.java` には全部のレベルを見る view しか無く、encoder にも texture から texture へ写す口が無い。interface に口を足すと GL の層の jar のハッシュが動き（`gl-jar-pin`・`gl-jar-publish`）、ブラウザの実装（`engine_web` の `BrowserObjects`）にも足すことになるので、この段では作らず人に伺う。
    読み戻す別案（`copyTextureToBuffer` と `readBuffer` で mip のレベル 0 を読み、CPU の Mip.build）は PC では GL と同じ画になるが、`readBuffer` は答えが出るまで返らず、ブラウザでは requestAnimationFrame の中で使えない。
    もう 1 つの別案は 2D の描き手が絵を上げる時の CPU の画素を持っておく形（全部の絵を二重に持つ。GL が持たないと決めた理由と同じ）。
  - 差の大きさ（記録）: bench の `mipFloorRegistered`（組み込みの放射の絵を材質に貼った同じ床）で 43,823 px・±2 以上 16,934 px・max ±148（奥ほどちらつく）。
- **sea_cave_walk の海の材質（12.35 の持ち越し）**: 照り返しの `Pow`（指数 180）を、WGSL の書き手が GLSL と同じ入れ子の括弧の積（179 重）で出していたので、Tint が "maximum parser recursive depth reached" で組めなかった。
  WGSL だけ、整数の指数の 2 以上は `sg_powi(底, n)`（左から 1 回ずつ掛ける輪・入れ子の積と同じ掛け順）を呼ぶ形にした（`ShaderGen.powProductFor`・`ShaderGen.Wgsl.powiSource`）。目安の「中間の let に分ける」形より字が短く、底の式を 1 回だけ置ける。
  GLSL の字は変えていない（`make test-engine` の GLSL の固定・`gl-capture-check` バイト一致）。`sg_powi` は GLSL と数を突き合わせる prelude（`TestWgslPairs`）の外に置いた。
- **確かめ — `bench/webgpu_v2`** に 9 場面と記録 1 場面を足した（`EnvironmentCases.flix`: bench/gl_parity の pbrEnvironment3d と同じパノラマを、金色の球の metallic × roughness の格子に映す。景色を背景に描く場面は目の正面に絵の継ぎ目）:

  | 場面 | 違う画素（許容） | ±2 以上（許容） | 差の最大（許容） |
  |---|---|---|---|
  | envSpheres（箱なし・強さ 1） | 7（16） | 0（4） | ±1（±16） |
  | envBox（箱で補正・強さ 0.8） | 5（16） | 0（4） | ±1（±16） |
  | envBackground（景色を背景に・強さ 0.9） | 19（40） | 0（4） | ±1（±16） |
  | envBackgroundTurned（後ろ向きに見下ろし） | 0（8） | 0（4） | ±0（±16） |
  | envBackgroundDesign（design の解像度） | 0（8） | 0（4） | ±0（±16） |
  | envBackgroundDepth（奥行きの書き出し＝空は白） | 1（8） | 0（4） | ±1（±16） |
  | envSkyAndBackground（sky と背景の景色の両方＝空の坂） | 17（36） | 0（4） | ±1（±16） |
  | envMsaaPass（標本 4 の Pass に描いて貼る） | 8,469（17,000） | 4,005（8,000） | ±60（±128） |
  | mipFloor（場面の絵の市松の床・mip のレベルの選び方） | 421（850） | 2（8） | ±2（±16） |
  | mipFloorRegistered（全体の登録の絵の床・記録） | 43,823 | 16,934 | ±148 |

  - 環境マップの画素はどれも GL と ±1 以内【推: mip のレベルの間の補間と sRGB の戻しの丸め】。envMsaaPass は球のふちで skyMsaaPass と同じ標本の位置の違い。上限は実測のほぼ 2 倍。
  - (7b) の前の木の WebGPU では環境マップの場面は映り込みが無く（材質の `uEnvOn` が 0）、景色を背景に描く場面は地の色のまま（前の木では流していない【未確認】。下の「空のフラグを 0 に」と同じ形の差になる見込み【推】）。
  - **壊して確かめた**（同じ日に 1 回ずつ・確かめた後に戻した）:
    - 空の frag の景色のフラグを 0 に決め打ち: envBackground 481,674・envBackgroundTurned 518,400・envBackgroundDesign 481,698・envMsaaPass 479,889 px 違って落ちる。
    - 環境マップの mip のレベルの数を 1 に: envSpheres 24,103・envBox 23,561・envBackground 26,803・envBackgroundDesign 26,838・envSkyAndBackground 26,801・envMsaaPass 36,855 px 違って落ちる。
    - 箱の on を 0 に: envBox だけが 21,325 px 違って落ちる。
    - 場面の絵の mip をレベル 0 だけに（CPU の Mip.build の頭だけ上げる）: mipFloor 161,608 px と、絵つきの材質・lightmap・骨・影の 10 場面が 3.2 万〜8.6 万 px 違って落ちる。
    - bench で捕まらない物はテストで止めた: `sg_powi` を外すと `TestWgslDawn` の deep-pow の 13 本が同じ誤りで組めずに落ちる・preload で絵を作らないと `testPreloadUploadsOnceAndKeepsWhatItUploaded` が・endFrame に先に上げた控えを渡さないと `testEndFrameDropsWhatWasNotPreloadedFirst` が落ちる。
  - 今までの 49 場面は 12.36 と同じ数。WebGPU の誤り 0。目で見て、球の映り込み（空の青・地平の縞・白い四角）と背景の景色が GL と同じ所に同じ色で出る（`bench/webgpu_v2/debug/{gl,webgpu}/env*.png`・git の外）。
- **欠けの表と実物**（12.36 と同じ流し方・写しは `scratchpad/e7b/games.sh`・後 = この worktree の fpkg（レビューの直しの前の木・直しは preload の知らせと名前と submit を外した所で、描く物は同じ）・前 = (7a) の fpkg（2 本の 6 場面と plateau_city は 12.36 の後の数）・
  `FGE_JAR_CACHE=off`・`FLIX_GE_HIDDEN=1`・`RUN_SECONDS=160`・頭の 64 コマ・WebGPU だけ）:

  | 種類（1 コマあたり・前 → 後） | fps3d_lab 部屋 | 礼拝堂 | 通路 | みやげの町 arrival | market | night |
  |---|---|---|---|---|---|---|
  | どの種類も | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 |

  - 2 本とも環境マップと preload を使わない。後も欠けの表が出ず、WebGPU の誤り 0。みやげの町の 3 場面は 12.36 の後と 64 コマが全部バイトまで同じ。fps3d_lab は頭の 9〜14 コマだけ同じ（12.35・12.36 と同じく場面の時計が実時間で進む物【推】）。
  - 試作 4 本（`~/Documents/flix_ge_workspace` から写して engine だけこの worktree の fpkg へ向けた・元のフォルダは触らない）:

    | 試作（場面） | 欠けの表（前 → 後） | WebGPU の誤り（前 → 後） | 見え方 |
    |---|---|---|---|
    | plateau_city（`SHOT=street`） | 0 → 0 | 0 → 0 | 12.36 の後と 64 コマがバイトまで同じ |
    | sea_cave_walk（`SHOT=cave`） | 3D の場面の preload 0.5 → **0** | **6 → 0**（海の材質の WGSL が組めた） | 洞窟の画角で海は映らず、絵は目で見て前と同じ（コマはバイトでは揃わない【推: 場面の時計】） |
    | pbr_room（`SHOT=spheres`・環境マップと箱） | 3D の環境マップ 0.9 → **0** | 0 → 0 | 鏡の球に部屋が映り、roughness の高い球ほどぼける（前は映り込みが無かった） |
    | conduit_hive（`SHOT=hall`・環境マップと preload） | 3D の環境マップ 1.9・3D の場面の preload 0.9 → **0・0** | 0 → 0 | 前と後で 64 コマが全部違う（映り込みが足された【推】） |

  - 絵の置き場: `/private/tmp/claude-501/-Users-abab-Desktop-flix-game-engine/1e409b86-520d-4126-86d6-d8af78577988/scratchpad/e7b/{games,others,others-before}/out/<ゲーム>-<場面>-webgpu/`（**scratchpad の物は消えうる**）。試作を GL と並べては比べていない【未確認】。
- テスト: render_gl 571 緑（12.36 の 564 に、`TestWebGpuScene3d` の 4 本（背景の景色のフラグ・環境マップの欄の位置・環境マップの無い場面がフラグを 0 に戻す・skipsOf が環境マップを数えない。空を描く場面の 1 本は書き替え）・
  `TestWebGpuScene3dDawn` の 3 本（preload を 1 回だけ上げて控える・上限を超えた endFrame は先に上げていない物から捨てる・環境マップの絵が無い時は代わりの絵で読んで知らせる）。`TestWgslDawn` に指数 180 と -40 の材質を足して Dawn で 392 本）。`make test-engine` 995 緑。
- **レビュー（1 回・82 点・必須 4）で直した物**: 必須 1 = 先に上げた物を後へ回すテストが上限を超えておらず何も確かめていなかった（上限を受ける `endFrameWithin` を切り出し、上限を超えるテストに）・
  必須 2 = preload の無い "tex3d:" の絵を知らせていなかった（GL と同じ文に）・必須 3 = 古い doc（blankImage・sceneGroups）・必須 4 = レンダーターゲットの絵を環境マップにした時の扱い（来ない道なので WhyNot に）。
  任意で直した物: preload の前の submit を外した（借りた絵は捨てず、場面の絵は作り直さないので、submit 前の pass の読む物を捨てる道が無かった）・名前（`ensureEnvironmentTexture`・`ensureEnvironment`・`powProductFor`）・法線マップを読む条件を行の側と同じに・
  `groupInstances` の outside を GL と同じに・WGSL の prelude の空行・全体の登録の絵の mip の WhyNot（読み戻す道はあるがブラウザで待てない）。
  直さなかった物: preload の pipeline の形式と標本を画面の物に合わせる（RGBA8・標本 1 だけ。画面に MSAA を使うゲームでは初めてのコマで作る）・`Preloaded` と GL の `PreloadState` の骨組みの共用・`uploadRowTextures` の `textureReadsOf` の 2 回呼び・
  preload の無い "tex3d:" の絵の知らせのテスト。
- 門（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal・2026-11-17。直しの後の木で流した）:
  - render_gl のテスト（`make sync-layers` の後 `.layers/render_gl` で `bin/flix test`）571 緑・`make test-engine` 995 緑。
  - `make gl-parity` exit 0・`make gl-capture-check` exit 0（54 枚がバイトまで同じ）。
  - `make webgpu-v1-check` exit 0・`make -C bench/webgpu_v2 run` exit 0・誤り 0（58 場面と記録 3・標本 4 と 1 の差は GL 4,761・WebGPU 4,158 px と GL 103,546・WebGPU 101,880 px で 12.36 と同じ）。1 コマ（記録）は GL 1.02〜1.06 ms・WebGPU 1.58〜1.68 ms（12.36 と同じ桁・ゲームの写しを流しながら）。
  - `make lint ONLY=max-lines` exit 0（`WebGpuRenderer.flix` 1,051 行）・`make gl-jar-pin-check` exit 0（`render_gl/java` は触っていない）。
  - fpkg を作り直した後に bench の `packages.lock` を消して流した（12.33 の落とし穴）。
- 言える範囲: この Mac（Dawn の Metal）だけ。ブラウザ（12.31 の口）・スマホ（adreno）で環境マップと preload の場面は流していない【未確認】。
- **人に伺う事**: 全体の登録の絵の mip つきの写し（決まり 7）を、`WebGpu` の interface に「texture の mip のレベル 1 つを見る view」（`Texture.createView(baseMip, mipCount)` のような口）を足して GPU の render pass で作るか。
  足すと GL の層の jar の形が変わり（`gl-jar-pin` と、main への push で `gl-jar-publish`）、ブラウザの `BrowserObjects` にも同じ口が要る。別案は上の決めた事 3（PC だけ読み戻す・CPU の画素を持つ）。
- 持ち越し:
  - 上の伺い事（決まれば `mipFloorRegistered` を門にする）。
  - preload の pipeline を画面の標本数に合わせる・ブラウザでの preload の時間（pipeline を同期で作る）を測る（8 章の「非同期で作る」は今の口に無い）。
  - 12.28〜12.36 の持ち越しで (7b) で触らなかった物はそのまま（Design の縮めの横の揺れ・kindSky は P9・ビルボードのテスト T2〜T4）。

### 12.38 R2b・P8 の (7c): 全体の登録の絵の mip つきの写しを GPU で（2026-11-17・この Mac・Dawn の Metal だけ）

12.37 の伺い事は、コーディネーターが人の代わりに「`WebGpu` の interface に口を足す」と決めた（読み戻し案はブラウザで待てない・CPU の画素を二重に持つ案はメモリ）。engine の pub（ゲームから見える API）は増やしていない。GL の画は変えていない。

- **決めた事**:
  - `render_gl/java/fge/webgpu/Texture.java` に `createView(baseMip, mipCount)`（面は 1 枚）。Dawn（`DawnObjects`）とブラウザ（`engine_web` の `BrowserObjects`・TeaVM の `GPUDescriptor.TextureView`）に実装。`make gl-jar-pin` で 3 つの flix.toml を `fge-gl-8e4009e92501` へ（publish は push の時の CI）。
  - `Render3d.WebGpuMipmaps`（新規）: レベル 0 は元の絵を textureLoad で写し、レベル k はレベル k − 1 を読む view とレベル k を描く view で 1 pass。frag が 2 × 2 を Mip.build と同じ決まりで平均する（端の繰り返し・Raw は (和 + 2) / 4 の切り捨て・SrgbCurve は線形で平均して 8bit の sRGB へ・α は Raw）。描き先は RGBA8・段は 1 × 1 まで。
  - `WebGpuMaterials` は登録の絵を借りる代わりに写しを作る（`mipCopyTexture`・鍵は GL と同じ texId と version）。pass は 3D の描き手の Host の encoder に積み、view と group は submit の後に手放す。写しの数は診断の `mipCopies` に数える（GL と同じ）。
- **bench（`bench/webgpu_v2`）**: `mipFloorRegistered` を記録から門へ。

  | 場面 | 前（12.37） | 後（許容） |
  |---|---|---|
  | mipFloorRegistered 違う画素 | 43,823 | 1,792（3,600） |
  | ±2 以上 | 16,934 | 0（4） |
  | 差の最大 | ±148 | ±1（±16） |

  ほかの 58 場面は 12.37 と同じ範囲で OK・WebGPU の誤り 0。
- **壊して確かめた**（確かめた後に戻した）: 写しのレベルを 1 つに → mipFloorRegistered 43,823 px で落ちる（12.37 の数に戻る）・SrgbCurve を Raw の平均に → 16,765 px・±36 で落ちる・Raw の +2 を外す → `TestWebGpuMipmapsDawn` の Raw と sRGB が落ちる（最初の素材は 1 次の式で 4 つの和が 4 の倍数にそろい捕まえられなかったので、2 乗と 3 乗の素材に替えた）。
  端の繰り返し（`min(…, last)`）を外しても Dawn では落ちない（Dawn が textureLoad の範囲外を内側へ寄せる【推】）。ブラウザの仕様では範囲外は 0 もありうるので残した。
- **テスト**: `TestWebGpuMipmapsDawn`（Dawn で写しをレベルごとに読み戻し Mip.build と比べる: 5 × 3・3 × 8・1 × 1 の Raw は画素まで同じ・SrgbCurve は成分ごとに ±1 以内）。
- 持ち越し: ブラウザ（Chrome・Firefox）で登録の絵を材質に貼った場面を見ていない【未確認】。写しの usage の COPY_SRC はテストの読み戻しのためだけ（害は無い）。

### 12.39 R2b・P8 の (8): 場面の描き先の寿命（2026-11-17・この Mac・Dawn の Metal だけ）

engine の pub は増やしていない。GL の画と GL の呼び出しの並びは変えていない（gl-capture-check 54 枚がバイトまで同じ）。P9 と並行なので、`SceneList` と描く順には触っていない。

- **決めた事**: 場面の描き先の寿命の表を前半の `Render3d.SceneTargets`（新規・GPU を呼ばない）へ。鍵ごとに形（大きさ・形式・標本）と最後に使った世代と backend が作った物を持ち、`ensure`（形が違えば捨てて作る）・`sweep`（`Render3d.idleTargetFrames` を超えて使わなかった物を捨てる）・`release`。作る・捨てるは backend の Allocator（影の地図の `Render3d.ShadowMaps` と同じ分け方）。
  - GL: Design の解像度の FBO（`Render3d.designTarget`。鍵は場面の番号と形式の名前のまま）。`endFrame` で sweep するようになった（前は鍵の数だけ持ち続けていた）。作り直しは今までどおり TargetRebuilds に数える。
  - WebGPU: 場面ごとの描き先（`WebGpuRenderer.targetOf`。鍵は描き先の番号と場面の番号のまま・同じ encoder で同じ鍵に 2 回書く前の submit は backend に残した）。`SceneTarget#lastUsed` と WebGPU だけの idleTargetFrames を消した。作り直しは数えない（GL は Native の場面を描き先なしで描くので数がそろわない・WhyNot）。
  - 影の地図の表は今回は寄せなかった（GL と WebGPU の影の描き先の持ち方を同時に書き換えることになり、P9 と触る所が重なる・WhyNot）。
- **テスト**: `TestSceneTargets`（同じ形は使い回す・形が変われば前の物を捨てて作り直す・idleTargetFrames を超えた物だけ捨てる）。
- **bench**: (8) は WebGPU の絵を変えない（webgpu_v2 の 59 場面は (7c) の後と同じ範囲で OK）。

#### (7c)・(8) の共通（門・欠けの表・レビュー）

- **レビュー（2 段をまとめて 1 回・86 点・必須 0）で直した物**: sRGB の平均を値の配列の実行時の番号で引かず vec3 でまとめて計算（拒む WGSL の実装がある）・sRGB のテストを ±1 に（pow の精度は実装ごと）・縦長の絵と 1 × 1 の絵のテスト・WebGPU も mipCopies を数える・pipeline の鍵を frag の入口の名前に・TargetRebuilds の WhyNot に Design の場面の理由を足す・影の地図の表を寄せない WhyNot を書き直す。
  直さなかった物: COPY_SRC（上）・`SceneTargets.release` のテスト・ブラウザでの確かめ。
- **門**（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal。直しの後の木で 1 回）: render_gl のテスト 579 緑（12.37 の 571 に TestWebGpuMipmapsDawn 5 本と TestSceneTargets 3 本）・`make sync-engine-full` exit 0・`make test-engine` 995 緑・`make gl-parity` exit 0・`make gl-capture-check` exit 0（54 枚がバイトまで同じ）・
  `make webgpu-v1-check` exit 0・`make -C bench/webgpu_v2 run` exit 0（59 場面と記録 2・誤り 0・`packages.lock` を消してから）・`make gl-jar-pin-check` exit 0・`make lint ONLY=max-lines` exit 0（`WebGpuRenderer.flix` 1,042 行）。
- **欠けの表**（2 段の後に 1 回・12.37 と同じ流し方・後 = この worktree の fpkg・前 = 12.37 の後・`FLIX_GE_BACKEND=webgpu`・160 秒・頭の 64 コマ）: 10 場面（fps3d_lab の 3・みやげの町の 3・plateau_city・sea_cave_walk・pbr_room・conduit_hive）とも欠け 0 → 0・WebGPU の誤り 0 → 0。
  みやげの町の 3 場面と試作 4 本は 64 コマが全部 12.37 の後とバイトまで同じ（どれも全体の登録の絵を 3D の材質に貼っていない【推】）。fps3d_lab は 4〜7 コマだけ同じ（12.35〜12.37 と同じく場面の時計が実時間で進む物【推】）。
  写しの置き場は `scratchpad/e8/{games,others}/out/`（消えうる）。
- 持ち越し: 影の地図の寿命の表を `SceneTargets` へ寄せる（P9 の後）・12.37 の持ち越し（preload の pipeline の標本数・ブラウザでの preload の時間）と 12.28〜12.36 の持ち越しはそのまま。

### 12.40 P9: 動かない物の持ち越し（2026-11-17・この Mac・Dawn の Metal だけ）

表の 15 行目（決まり 10）。engine の pub を足した（人の了承: 候補 1・ゲームが明示・1 個だけ変える物は外して instances に置く・`engine-scene3d-cpu.md` の結果は待たない）。
GL の画と呼び出しの並びは変えていない（集まりの物を instances の後ろに並べて今の道で描く・gl-capture-check 54 枚がバイトまで同じ）。16 ms の目標は WebGPU だけ（人の決め）。

- **決めた事 1 — 宣言は `Scene3d.staticGroup`**: 型 `StaticGroup`（非 pub の enum + alias）・`staticGroup(名前, (鍵, 物) の列)`・`withoutItems(鍵の Set)`・`withGroupTint`・`staticGroupFieldsOf`・`groupInstancesOf`・`instancesOf(場面)`、`Scene3dCmd#groups`。
  持ち越さない描き手（CPU・DrawHash・注釈・GL・preload）は `instancesOf` を描く（DrawHash は集まりの物を instances の後ろに並べた場面と同じ鍵）。早見表に 1 行・agent-eval に `static-group-many-buildings`（100 点）。
- **決めた事 2 — 前半 `Render3d.StaticRows`**: 集まりごとに 1 回だけ候補に分け（視錐台で間引かない）、1 体ごとの値を詰め、色の pass の行（頂点の色 → 不透明の材質）と影の地図の行を作る。
  同じ集まりかは名前・items の参照・removed・tint（中身は比べない）。同じ名前で中身の違う集まりは 1 コマに何個でも控え、外れた時は今のコマで使っていない物だけ手放す。
  半透明（遠い順に並べ直す）と骨つき（姿勢が毎コマ変わる）と奥行きの書き出しの場面は毎コマ計画へ（`groupScenesWith` に場面と組で渡す）。同じ付け方の行は前の行の値を指し、時刻（uTime）を書き直す区画を付け方の数にした。
  30 コマ続けて同じ名前を作り直したら 1 回知らせる。
- **決めた事 3 — WebGPU `Render3d.WebGpuStatic`**: 1 体ごとの値と材質の値の buffer を 1 回書き、毎コマは形と絵を使った物にして時刻の区画だけ書き直す。色の pass の空の後・場面の行の前と、影の地図の pass に描く。
  行は render bundle に積む（鍵 = 描き先・形式・標本・pass。影は地図の鍵）。group 0 か材質の絵の世代（`WebGpuMaterials.textureEpochOf`）が替わったら積み直す。
  影の地図か環境マップを読む場面の group 0 は、描き先と付ける view が同じなら前のコマの物を使う（`sceneGroups`。bundle が参照で比べる）。手放すのはコマを締めた後（endFrame）だけ。置き場が形か絵を捨てたコマは持ち越しを全部作り直す。
- **決めた事 4 — jar の形**（(7c)/(8) の merge の後・人の了承）: `RenderCommands`（pass と bundle に共通の命令）・`RenderBundleEncoder`・`RenderBundle`・`RenderPass.executeBundle`・`WebGpu.createRenderBundleEncoder`。Dawn と `BrowserObjects`（bundle は命令ごとに JS を呼ぶ・pass の命令の列に乗せない WhyNot）。jar `fge-gl-46f52a0dcfbb`（gl-jar-pin 済み・置き場は main への push で作る）。

- **時間**（WebGPU・ms。**どれも PC が混んでいる時（load average 9〜33）の数で【未確認】**。人の決めで、16 ms の判定と時間の測りは後でまとめて取る。下は途中で取った参考）:

  | 場面 | 前（集まり無し） | 集まり・bundle 無し | 集まり・bundle |
  |---|---|---|---|
  | bench/scene3d field n=12000 shapes=each moving=0 | p50 90.4〜113.1（split 17〜21・draw 68〜86） | p50 13.2〜16.4（split 1.9・draw 6〜9.5） | **p50 8.6**（split 0.9・draw 2.1） |
  | 同 shadow=1（draw call 24,002） | — | p50 21.4（split 2.1・draw 10.4） | **p50 12.6**（split 1.1・draw 3.2） |
  | 東京 1 棟ずつ（plateau_city `3k_each`・aerial3k・600 コマの間隔の平均・太陽の影） | 116.5〜164.5 | 22.9〜24.7 | **12.6〜14.9** |

  - field shapes=1 moving=0 は前から p50 14.4〜15.9（16 ms 以下）。GL の field each は 140 ms（GL は集まりでも今の道・目標の外）。
  - 東京は試作の写し（`scratchpad/p9/plateau_city`・`PLATEAU_STATIC=1` で読み込みの時に `staticGroup` 1 つへ移す）。元のゲームは触っていない。
- **壊して確かめた**（確かめた後に戻した）: 持ち越した行を色の pass に描かない → bench/webgpu_v2 の static 5 場面が 13.7 万〜51.8 万 px 違って落ちる（staticDepth は持ち越さないので OK のまま）・
  影の地図に描かない → staticSunTextured 52,172 px・staticSpotAndSun 81,600 px で落ちる・置き場が捨てた後に作り直さない → `testMeshEvictionDropsCarried`・
  bundle の鍵から描き先を外す → `testTwoScenesShareCarriedAndKeepTheirBundles`（積んだ回数 2 → 6）が落ちる。いつも使い回す・いつも作り直すは `TestStaticRows` の作り直しの 5 本（同じ値・作り直した値・外す鍵・tint・同じ名前 2 つ）が止める。
- **欠けの表**（12.39 と同じ流し方・`FLIX_GE_BACKEND=webgpu`・160 秒・頭の 64 コマ・後 = bundle を入れた後・レビューの直しの前の fpkg（直しは集まりのある場面だけに効く）・前 = 12.39 の fpkg（e8））:

  | 場面 | 欠け（前 → 後） | WebGPU の誤り | 頭の 64 コマが前とバイトまで同じ |
  |---|---|---|---|
  | fps3d_lab 部屋・礼拝堂・通路 | 0 → 0 | 0 | 12・3・3 コマ（12.35〜12.39 と同じく場面の時計が実時間で進む【推】） |
  | みやげの町 arrival・market・night | 0 → 0 | 0 | 64・64・64 |
  | plateau_city（`SHOT=street`）・sea_cave_walk（`SHOT=cave`） | 0 → 0 | 0 | 64・64 |

  どれも集まりを使っていない（GL と WebGPU の今の道が変わらない事の確かめ）。写しは `scratchpad/p9g/{before,after}/out/`（消えうる）。
- **bench**: `bench/webgpu_v2` に static 6 場面（部屋の小物・絵つき・半透明・奥行きの書き出し・太陽の影・スポットと太陽）。どれも集まり無しの同じ場面と同じ差（65 場面 OK・誤り 0）。`bench/scene3d` に `GROUP=1`。
- **テスト**: render_gl 604 緑（`TestStaticRows` 18 本・`TestWebGpuStaticDawn` 7 本）・`make test-engine` 1000 緑（`TestScene3dStaticGroup` 5 本）。
- **門**（この Mac・直しの後の木で 1 回）: render_gl のテスト・`make sync-engine-full`・`make test-engine`・`make gl-parity`・`make gl-capture-check`（54 枚がバイトまで同じ）・`make webgpu-v1-check`・
  `bench/webgpu_v2 run`（`packages.lock` を消してから・65 場面と記録・誤り 0）・`make gl-jar-pin-check`・`make lint ONLY=max-lines` がどれも exit 0。
- **レビュー**: 1 回目 78 点（必須 3: 同じ名前の集まりを 2 場面で描くと作り直しと使用中の buffer の破棄・bundle を描き先ごとに分けていない・影の有無で集まりの列を毎コマ作る）→ 直して 2 回目 88 点・必須 0。
- 持ち越し:
  - 置き場が 1 つでも捨てたら持ち越しを全部作り直す（捨てた slot を持つ集まりだけにする）・材質の絵の世代が全体で 1 本（毎コマ版が変わる登録の絵を材質に使うと毎コマ積み直す）。
  - 診断の drawn は視錐台で間引かない分 GL より多い・CPU の 1 体ごとの値の写しを GPU へ書いた後も持つ・同じ深さで重なる面の勝ち方が GL と逆になりうる（WhyNot に書いた）。
  - 2D の集まり（候補 4 の `withStaticLayers`）・区画ごとの集まりを助ける関数・GL の側の持ち越し（GL は描き方の代金が残り目標の外）。
  - 時間の表を静かな時に取り直す・ブラウザで bundle の道を流していない【未確認】・`Scene3d.hasDrawnInstance` と `StaticRows.hasDrawnItem` が同じ中身（engine の pub を増やさないために 2 本）。

### 12.41 P10: 切り替え（前倒し・2026-11-17・この Mac・Dawn の Metal だけ）

人の指示で P10 を前倒しした。計測（時間の測り・16 ms の判定・欠けの表の時間）は後で行う。engine の外のゲームは触る時に追随する（engine の中のテンプレート・bench は追随した）。engine の pub（ゲームから見える API）は変えていない。

- **決めた事**:
  - PC の既定の描き手を WebGPU に: `FLIX_GE_BACKEND` を置かない・空・`webgpu` は WebGPU・`gl` は GL・知らない字は 1 行言って WebGPU（`LwjglEnv.parseBackend`）。`FLIX_GE_GL_LOG`（GL の呼び出しの控え）だけを置いた時は GL（GL の backend にしか無い口なので）。
  - WebGPU を使えない機械: 窓は今までどおり `[backend] WebGPU を使えない: … — GL で起動する` を 1 行言って GL（5 章の fallback = 同じ `RenderList` を流す GL の backend。止めない WhyNot は `LwjglLayer.withWebGpuOrGl`）。Dawn のネイティブは macOS arm64 だけなので、ほかの OS は今はこの道。
  - 窓なしの 1 枚撮り（`GpuShot`）: 新しい `GpuOffscreen`（WebGPU の `WebGpuPaint` を Dawn の device の上で・または `GlOffscreen`）で、窓と同じ `FLIX_GE_BACKEND` で選ぶ。WebGPU を開けなければ GL、GL も無ければ SoftRaster。history は GL と同じく毎回透明（`WebGpuPaint.withoutHistory`）。
  - 動画（`VideoOut`）は GL のまま: 塗った物を返す `VideoOut.Painter`（ゲームから見える enum）に WebGPU の case が要るので、人に伺うまで作らない。`GpuOffscreen` に乗せれば数行で移せる。
  - 既定にすると露わになる欠けを 2 つ埋めた: (1) WebGPU の窓も起動の後に出た字を足す（`RenderGlyphGrow` の上げる口を `Writer` で差し替え・R8 の絵の空いた所へ `writeTexture`。`RenderPaint.Fonts#grow` から GlContext を外した）。(2) WebGPU の窓も F8 の注釈を書く（`LwjglLayer.saveAnnotationWith` に切り出し、WebGPU は中間の texture を読む）。
  - 層を置く物差し（`docs/flix-conventions.md`）: 描画の新しい機種の切れ目を「`RenderList` の backend の高さ」に書き換え、表に `RenderList` の行を足した（5.1 の宿題）。
  - GL を前提にした harness に `FLIX_GE_BACKEND=gl` を明示（gl_parity の run・wgsl-rows・webgpu の GL 撮り・shader_cache_soak・texture_upload・webgpu-v1-check の GL 撮り）。窓の性能ベンチ（sprite_stress・crowd2d・scene3d）は既定の WebGPU で測る（GL と比べる時は `FLIX_GE_BACKEND=gl`・`docs/performance.md`）。
- **gl-capture の基準**: 既定を WebGPU に（`make gl-capture-check [BACKEND=gl]`）。基準は描き手ごとのファイル: WebGPU は `bench/baseline/0.99.0/gl-capture-webgpu-jwebgpu0.3.4-apple-m4-pro.sha256`（名前に jWebGPU の版＝Dawn の版を入れて pin・頭の `#` の行に adapter）・GL は今の `bench/baseline/0.96.0/gl-capture-apple-m4-pro.sha256`。54 枚が 2 回撮りでバイトまで同じ。同じ場面の GL（`CAPTURE_GLYPHS=used`）との差は 9 場面のうち tidepool の 2 場面の字の縁だけ（level 453 px・±2／title 259 px・±1）、ほかは 0 px。
- **agent-eval**: お題 `pc-backend-gl-fallback` を足し `try-webgpu-backend` を既定に合わせた。rpg-starter の写しで 2 題とも 100 点（1 回目は期待の語が choice に当たらず 50 点だったので語を直した）。
- **テンプレートの reference**: 比べの絵は SoftRaster なので既定の切り替えで変わらない（3 本とも reference-check 緑・取り直していない）。
- **門**（この Mac・Apple M4 Pro・macOS 27・Dawn の Metal。CI に載るのは render_gl の GPU の要らないテスト・test-engine・lint だけで、ほかは GPU の要る手元の門）: render_gl のテスト 606 緑（`TestGpuOffscreenDawn`・`testGlLogPicksGlUnlessBackendIsSet` を足した）・`make sync-engine-full` exit 0・`make test-engine` 1,000 緑・`make gl-parity` exit 0・`make gl-capture-check`（WebGPU・基準と一致）と `BACKEND=gl`（基準と一致）exit 0・`make webgpu-v1-check` exit 0・`make -C bench/webgpu_v2 run` exit 0（`packages.lock` を消してから）・`make gl-jar-pin-check` exit 0・`make lint ONLY=max-lines` exit 0・テンプレート 3 本の `reference-check` 緑・`make determinism` exit 0。
- **レビュー（1 回・80 点・必須 4）で直した物**: `FLIX_GE_GL_LOG` が WebGPU の窓で黙って効かない（GL を選ぶようにした）・`bench/texture_upload` が GL を直に呼ぶ（`FLIX_GE_BACKEND=gl`）・WebGPU の 1 枚撮りの history（毎回透明に）・窓の性能ベンチの描き手（文書に書いた）。任意で直した物: 使われていない `GpuOffscreen` の pub を外した・古いコメント・物差しの表の `GpuOffscreen`。
- 持ち越し:
  - 動画の既定（`VideoOut.Painter` に WebGPU の case を足すかを伺う）・外のゲームの追随（触る時に）・Studio（別のリポジトリ・GL のまま）・計測（12.16 のまとめ・16 ms の判定・欠けの表の時間）。
  - F8 の注釈は型検査と GL の振る舞いの読み比べだけで、WebGPU の窓で実際に F8 を押していない【未確認】。WebGPU の窓の起動の後の字の足し方は gl-capture（used）と Dawn のテストでは通らず、auto のゲームを目で見ていない【未確認】。
  - ブラウザの既定は WebGL2 のまま（`?backend=webgpu`）。
  - `GpuOffscreen.readImage` は ARGB の画像から RGB へ写す回り道（1 枚撮りの予算で測ってから）。
