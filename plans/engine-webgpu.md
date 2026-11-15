# 描き手を WebGPU へ移す — 設計（第 5 版・相談用・未着手）

下調べ 8 本と試作 2 本は `plans/webgpu/` にある（`survey/A〜H`・`spike-pc/`・`spike-web/`）。この文書の数字はそこから引いた。
【確】= 生の記録かコードで確かめた ／【推】= 割り算や読みからの見積もり ／【不明】= まだ測っていない ／【目標】= これから目指す値。
レビューは第 1 版 68 点・第 3 版 78 点・第 4 版 84 点（3 回で 90 に届かず。判定は「P0・P1 は着手してよい。R1a 以降は残りの指摘を入れてから」）。
第 5 版は 3 回目の指摘 14 件を入れた物で、**この版はレビューを通していない**（末尾）。第 3 版は、工数を減らす工夫（`DrawList` を挟む・5.1）と、
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
| 2 | WebGPU の無いブラウザは、今の GL の描き手（WebGL2）で起動する。当初は「機能を止めた fallback」と決めたが、第 3 版では**同じ `DrawList` を流す GL の backend** に改めた（5.1。止めなくても 2 本持ちの手間が増えないため。会話で伝え済み・11 章の 1 で改めて伺う） |
| 3 | 小さな試作で確かめてから進める（PC とブラウザの 2 本は済み） |
| 4 | エンジンの側でなるべくまとめる操作を優先する API にする。2D も 3D も性能が上がる事を優先する |
| 5 | 性能の物差しは、物を足していくベンチマーク。今ある `bench/sprite_stress`・`bench/crowd2d`・`bench/scene3d` を広げる（新しく作らない）。都市は最後の確かめ |
| 6 | ゲームの中身の CPU（敵の移動・当たり判定）は Flix の速さ待ち。エンジンは「描く物を組み立てる CPU」を減らす所までやる |
| 7 | 形は最初に決め切らない。ベンチマークを取り、書き味（ゲームの側のコードがどう書けるか）のレビューを見ながら、良い形を探す |
| 8 | 先にリファクタするなど、やり方の工夫で工数を減らす |
| 9 | OS ごとの確かめは、いったん Mac でできる範囲でやる（2026-11-14）。Windows と Linux は P4a の門に入れず、実機か CI で確かめるまで「未確認」と書いて進める |
| 12 | P2 でブラウザの下限を上げる（2026-11-15）。TeaVM 0.16 の wasm は例外が exnref の `try_table` になり、読めるのは Chrome 137・Firefox 131・iOS Safari 18.4 以降【推・MDN と caniuse から。古い実機では未確認】。WebGPU 版はどのみちこれより新しいブラウザが要るので、WebGL2 版だけ 0.14.1 で訳す道（5.5）は作らない。書き出しは 1 通りのまま |
| 11 | JDK は上げてよい（2026-11-14）。PC の WebGPU を jWebGPU（JNI）に頼り切らず、wgpu-native か Dawn の C の API を Panama（Foreign Function & Memory API・JDK 22 で正式）で直に呼ぶ道を選べる。上げる版と時期は、Flix・Studio が同梱する JRE・配布物・ベンチの基準の取り直しまで含めて段を 1 つ立てて決める |
| 10 | 11 章の残りの伺い事は「全部おまかせ」（2026-11-14）。おすすめの案で進める。リリースと push は、その時に改めて伺う |

## 3. 覆す・書き換える今までの決め事

| 元の決め | 場所 | どう変えるか |
|---|---|---|
| ブラウザの 3D は WebGPU・インスタンス描き・スマホ向けの速さをやらない | `plans/engine-browser-3d.md:9` | 「軽い 3D が動けばよい」フェーズは済んだ。次として WebGPU をやる |
| TeaVM は 0.14.1。0.16 へは WebGPU のフェーズで上げる | `plans/engine-browser.md`（決定 2） | そのフェーズが今（P2） |
| 0.88.0 で性能は区切り（間引き・動かない物の送り・Par は見送り） | 人の判断（2026-11 上旬） | 動かない物の送り（static group）だけ、WebGPU の描き手の中で再開する（P9）。間引きと Par は見送りのまま |
| 層を置く物差しの表（境目 3 つ） | `docs/flix-conventions.md:193-215` | 表に `DrawList` の backend と `WebGpu`（5 章）を足し、`GlContext` の行に「GL の backend 用」と書く。「新しい機種の切れ目は `Platform.Services` の高さ」の文は、描画については「`DrawList` の backend の高さ」に書き換える（P10）。物差しそのもの（実装が 2 つある所にだけ置く）は変えない |
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
   DrawList（値）… 1 コマの「描く呼び出し」の列。pass の区切り・pipeline の鍵・行のバッファの範囲・形・絵
        │                                   ← 新しい差し替えの高さ（実装 2 つ）
        ├─ WebGPU の backend（本線）
        │     WebGpu（Java の interface・WebGPU の形）
        │        ├─ ブラウザ: TeaVM 0.16 の org.teavm.jso.webgpu
        │        └─ PC: jWebGPU の Dawn（Metal・Vulkan・D3D12）。画面なしの描き出しとテストもここ
        └─ GL の backend（fallback）
              GlContext ─ WebGl2（WebGPU の無いブラウザ）／ LwjglGl（fallback の検査を PC で回す・移行の間の PC）

   SoftRaster（CPU の描き手。絵の答え合わせの相手。今のまま。DrawList は通らない）
```

名前は仮（11 章で伺う）。`Gpu` だけの名前は今の `GpuResources`・`GpuHandle`・`GpuTimer` と紛れるので使わない。

### 5.1 `DrawList` を挟む（第 3 版からの柱。工数を減らすための工夫）

今の描き手は「何を描くか決める」と「GL を呼ぶ」が同じ関数に混ざっている（`Sprite.flix` に GL の呼び出しが 238・`Render3d.flix` に 166【確】）。
このまま WebGPU 版をもう 1 本書くと、2D と 3D の全部が書き直しになる。そこで順番を変える。

1. **先に今の描き手をリファクタする。** GL を直に呼ぶ代わりに `DrawList`（描く呼び出しの列）を作り、それを GL で流す実行役（backend）を別に置く。
   **絵は 1 画素も変わらない**ので、今ある門（`gl-parity` 0 px・テンプレの `reference`・`gl-capture-check`）でそのまま守れる。
2. **WebGPU は backend だけを新しく書く。** 「何を描くか」は書き直さない。
3. fallback は「止まった別の描き手」ではなく、同じ `DrawList` を流すもう 1 つの backend になる。

今のコードは既にこの形に近い。2D は `emitMerged` が 6 種類を run にまとめて流す時に run の状態（`st` の欄 11〜18 と Float32 の配列）を持ち、
3D は `SceneDraws[MeshBatch]`・`MeshBatch{head, count, first}`（`first` は行の起点で、`firstInstance` と同じ考え）を持つ【確】。
**新しい型を 1 から足すのでなく、この 2 つを「GL の物を含まない形」に広げる。** この文書では、広げた後の物をまとめて `DrawList`、その 1 行を「描く 1 行」と呼ぶ（型の名前は 11 章の 7）。

**描く 1 行の高さは「物の集まりを 1 回描く」**にする。WebGPU の命令（`setBindGroup` など）の高さにはしない。1 行が GPU の draw 何本かになる事はある（mask つきは 2 本）。
診断の「draw の数」は backend が実際に出した数を数える（今の `Counter.DrawCalls` のまま）。

種類（enum）と欄:

| 種類 | 今の出どころ | 種類ごとの欄 |
|---|---|---|
| 2D: スプライト・字・箱の run | `RenderSprite.drawSpriteInstancedBuf` | 行の範囲・絵（頁か登録の番号）・blend・切り抜き・mask の形 |
| 2D: 多角形の run | `RenderSprite.drawPolygonBatch` | 頂点の範囲・blend・切り抜き |
| 2D: タイルの層 | `RenderSprite.drawTileMapInstanced` | タイルのバッファの番号・**draw ごとの値**（position・tileSize・tileScale・color）・絵 |
| 2D: static layer の範囲 | `Static.flix` | 置き場の番号と範囲・**draw ごとの値**（viewOffset・viewScale・halfDesign） |
| 2D: 面（`ShaderDoc`） | `RenderSprite.drawShaderSurface` | シェーダーの鍵・**draw ごとの値**（rect・time・alpha・`params` の列）・**絵の組**（`texReads` の列と補間）・mask の形 |
| 2D: 3D の場面を貼る | `MScene3d` | 場面の描き先の番号・矩形 |
| 3D: 形の batch（不透明・材質・半透明・影） | `MeshBatch`・`MaterialBatch` | 材質の鍵・形の番号と範囲・行の起点と数・**draw ごとの値**（`uParamN`・cutout）・**絵の組**（材質の絵の列・sampler・normal map・lightmap） |
| 3D: ビルボードの集まり・空・後がけ | `drawBillboards` ほか | 行の範囲・絵・draw ごとの値 |
| pass の区切り | `beginTarget`・`endTarget`・影の地図・Design の描き先 | 描き先の番号・クリア・resolve・history の写し・pass ごとの値（カメラ・`LightData`・時刻・影と環境の絵） |
| 物の上げ下ろし | `GpuResources` の handler・`meshEntry`・フォントの部分更新 | 作る・中身を書く・消す（下の「物の寿命」） |
| 読み戻しの依頼 | F8・frame shot | 描き先の番号と矩形・届け先 |

- **行と draw ごとの値の持ち方は backend が決める。** WebGPU は draw ごとの値も行に入れて storage buffer に置き、`firstInstance` で引く（dynamic offset は使わない）。
  GL は今と同じ（instance 用の頂点バッファ・データ用テクスチャ・uniform）。だから「古い方に合わせて新しい方の手を縛る」事にならない。
- **面と材質は、draw ごとの値の並びがシェーダーごとに変わる。** 並び（WGSL の struct）は `ShaderGen` が出す（P5）。P5 の前の「縦に 1 本」は、並びが固定の組み込み（スプライト・字・箱）だけで通す。
- **持ち方は配列。** `DrawList` は Int32 の配列（種類と番号と範囲）と Float32 の配列（行と値）で持つ（今の `st` と同じ流儀）。絵が 1 個ごとに交互の 20,000 個でも record を 20,000 個作らない。
  後で「配列を JS へ 1 回で渡す」形（9 章の「後」）がそのまま乗る。
- **いつ流すか: `renderCommands` 1 回につき 1 つの列を、その場で流す。** 今の即時の順（`renderCommands` のたびに描く・Pass は `beginTarget`〜`endTarget` の別の呼び出し・
  間に `GpuResources` の操作が同期で番号を返す）を変えない。コマ全体を溜めて最後に流す形は、Pass の間のテクスチャ更新の順を列に入れる決まりが要るので取らない（9.1 で測って見直せる）。
  WebGPU の backend は 1 コマ分の行を 1 本の大きなバッファに順に詰める（列ごとに重ならない範囲へ `writeBuffer`。submit はコマの終わりに 1 回）。
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
| **GPU の物の寿命**（形・絵・影の描き先・Design の描き先・シェーダー・static layer のバッファ・タイルのバッファ） | `meshEntry`・`Material.flix` の後半（約 300 行）・`ShaderCache`・`RenderStatic`・`RenderTargetGl` | **置き場の表（鍵・世代・予算・捨てる順・preload・知らせ）は前半、「作る・中身を書く・消す」だけ backend。** 今は描く時に上げているので（`drawBatch` → `meshEntry`）、R2 で「上げる行」を `DrawList` の先頭に出す形に直す |
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
| 呼び出しのログ（`GlCallLog`） | GL の backend だけ | 無し（`DrawList` を書き出す口を別に持つ） |
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
6. **送るのは 1 コマ 1 回。** 頂点と行のバッファは 1 コマ分を 1 本に詰めて 1 回で送る（今は run ごとに `bufferData`。tidepool で 1 コマ 133 回）。
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

**進め方の工夫**: (1) 先にリファクタして `DrawList` を挟む（5.1）。(2) 呼び手の無い道を先に消す。
(3) **形を早く確かめる** — リファクタを全部終える前に、スプライトだけで GL と WebGPU の両方を縦に 1 本通し、そこで `DrawList` の形をレビューして確定する。3D も同じ順（不透明だけで通してから残り）。

| 順 | # | 中身 | 門（合格線） | 見積もり |
|---|---|---|---|---|
| 1 | P0 | **ベンチを広げる。** `sprite_stress` に絵の種類（1 / 16 / 256）と blend の混在、`crowd2d` を 20,000 まで、`scene3d` に物の数・形の種類・材質の種類・動く割合・半透明・影のつまみ。3 つともブラウザの入口。2D の draw の数と切れた理由を診断に出す（決まり 8。engine の pub の `FrameDiagnostics` を広げる。`Frame.flix` に入れる数え方は R1a で書き直しになる）。診断の `glEndQuery` を間引く。PC・ブラウザ・スマホ（S24 Ultra・iPhone）で基準を取る。**スマホの実機で WebGPU の limit と feature の一覧を取る**（小さな頁）。agents-pack の早見表と eval（新しい診断の口） | 基準の数字が `bench/baseline/` と `RESULTS.md` に残る。診断を付けても 1 コマが 1.1 倍以内 | 8〜12 時間 |
| 2 | P1 | **描き手より上の直し**（決まり 9）。effect より上（engine_world が描く物の列を作る所。2D 20,000 個で約 25 ms）から record の欄の引き当てを外す。render_gl の中（3D の `planScene` 系）は R2 が同じ関数を作り替えるので、ここでは触らない | `gl-parity` 0 px・テンプレの `reference`。2D 同じ絵 20,000 個: 32 ms → 20 ms 以下【目標】 | 5〜8 時間 |
| — | | **リリース 1**（WebGPU を待たずに速くなる分） | リリースの門 | — |
| 3 | R1a | **2D のスプライト・字・箱だけ `DrawList` に。** 呼び手の無い道を消す → `emitMerged` のスプライトの run が描く 1 行を出し、GL の backend が流す。ほかの種類は今のまま | `gl-parity` 0 px・テンプレの `reference`・`gl-capture-check`。P0 のベンチで 5% 以内。**GL の呼び出しの並びは同じでなくてよい**（門は画素） | 4〜6 時間 |
| 3 | P2 | （R1a と並べて）**TeaVM を 0.16 へ。** `export-web` の呼び方を `TeaVMTool` に替え、JDK の本物のクラスが流れ込まない ClassLoader を組む。足している部品 6 本と runtime を合わせる。WebGL2 のまま全部のテンプレが動く事 | `web-capture` の絵が、**R1a を入れる前のコミット**で 0.14.1 と 0.16 を比べて同じ。書き出しの大きさと時間の前後。古い版のブラウザで WebGL2 版が動く（5.5） | 5〜8 時間。危険あり |
| 4 | P4a | **`WebGpu` と PC の門。** interface を決め、Dawn の実装で三角形（cull の向きの確かめを含む）・読み戻し・ウィンドウ（5.3 の「backend に聞く口」）。**画面なしの session**（今の `GlOffscreen` の open・readRgba・drawFloatRows に当たる物。P5・P6 の門が使う）。ウィンドウに出た絵を機械で確かめる。2 プロセス同時に起動して落ちない事。limit を Dawn から正しく読める事。**`firstInstance` の試作**: 形ごとに `draw(…, firstInstance)` を数千本・`instance_index` で行を引く形の 1 コマの時間。Windows と Linux で同じ試作 | Flix から interface を通して描いた絵が期待と同じ。3 つの OS で通る。通らない時は人に伺う（11 章の 3）。`firstInstance` の形が 20,000 本で 3 ms を超えたら（`setBindGroup` を毎回呼ぶ形と同じかそれより遅い）、決まり 1・2 の前提が崩れるので、次の手（頂点を storage buffer から引いて 1 回で描く形）と一緒に人に伺う | 9〜13 時間 + 別の機械 |
| 5 | P4b | **ブラウザの実装**（P2 の後）。同じ interface を TeaVM の JSO で。物を Flix の record に入れて運べる事。起動の時の選び分け（5.5）。`firstInstance` の試作を Chrome と iPhone の Safari で。**起動の時の選び分けと WebGL2 版の起動は V1 へ回した（12.12）** | PC と同じ Flix のコードで同じ絵。WebGPU の無いブラウザで WebGL2 版が起動する（V1 へ）。`firstInstance` の合格線は P4a と同じ（ブラウザは 20,000 本で 3 ms） | 4〜6 時間 |
| 6 | V1 | **縦に 1 本（2D）。** WebGPU の backend にスプライト・字・箱（WGSL は手書き。この 3 つは今も 1 つのプログラム）と、それに要る最小の「絵とフォントのアトラスを上げる」「Pass を 1 つ挟む」。お題は rpg のテンプレの題名の画面（スプライト 7 個だけ・多角形と面が無い）と、それを Pass 1 つに通した物。PC とブラウザで出す | GL の backend と画素を比べる。`sprite_stress` の同じ絵 20,000 個が GL より遅くない | 6〜9 時間 |
| 7 | | **`DrawList` の形のレビュー（2D）**: GL と WebGPU の backend の行数・ベンチ・書き味の見本を並べ、**スプライトの行と pass の区切りと「上げる行」の形**を確定する（9.1）。ほかの種類の形は、下の交互の進め方で 1 つずつ確かめる | レビュー役 90 点・人の了承 | 1〜2 時間 |
| 8 | R1b ⇄ P6 | **2D の残りを、種類ごとに「GL でリファクタ → すぐ WebGPU の backend に足す」を交互に。** 順: 物の上げ下ろしと寿命の表（5.3）→ 多角形とタイルと static layer → history と MSAA の resolve → mask（比べる値を進める形・8 章）→ 3D の場面を貼る → （P5 の後）面。GL と形が一番違う所（pass・history・mask）を早く WebGPU に通す。「送るのを 1 コマ 1 回に」（決まり 6）は、GL では測って得な時だけ（GL 3.3 / WebGL2 に baseInstance が無く、run ごとに頂点の属性を付け直す事になるため）。アトラスの頁（決まり 3）・読み戻しと F8・動画もここ | 種類ごとに、GL は `gl-parity` 0 px・`reference`・`gl-capture-check`・ベンチ 5% 以内。WebGPU は GL の backend と同じ機械で `gl-capture` の場面を比べる（許容は場面ごとに理由を書く。既定は差 0・丸めが出る場面だけ 2/255）と SoftRaster との `gl-parity`（画面なしの session）。終わりに: テンプレ 3 本が PC とブラウザで GL より遅くない（5% 以内）・ブラウザは `?capture` を自動で回す門 | 18〜26 時間 |
| 9 | P5 | （上の交互の途中で、面の前に）**WGSL の出口**（7 章）。`Codegen.Target.Wgsl`・`ShaderGen` の書き手と、面と材質の draw ごとの値の並び（struct）・組み込み | Dawn で全部の変種が通るテスト。式の行の突き合わせ（画面なしの session の drawFloatRows） | 10〜16 時間 |
| — | | **リリース 2**: 2D のゲームは WebGPU を「試しに選べる」。選ぶ口は、PC は環境変数（`FLIX_GE_BACKEND=webgpu`）、ブラウザは URL の `?backend=webgpu`。何も付けなければ今までどおり GL。入口が 3D（`withProject3d`）のゲームは、付けても GL のまま起動して理由を知らせる | | |
| 11 | R2a | **3D の不透明の batch だけ `DrawList` に。** `planScenes` から `gl` と GL の `State` を外す（capability・順の番号・材質の状態を backend に聞く）。`MaterialBatch#entry` を材質の鍵に替える。形と絵の「上げる行」。**`planScene` 系を配列で運ぶ**（決まり 9 の 3D の分。record の欄の引き当てを内側の輪から出す） | `gl-parity` 0 px・**偽の GL を通るテスト 6 ファイル（Batch・Instancing・JointTexture・Sun・GpuMipmap・Preload。うち GL の呼び出しの並びまで比べるのは 3 ファイル）はそのまま門に残す**（`DrawList` を見るテストは足す）・fps3d_lab が 5% 以内。`bench/scene3d` の動く割合 100%・12,000 個と、東京 1 棟ずつ: 137 ms → 100 ms 以下【目標】 | 8〜11 時間 |
| 12 | V2 | **縦に 1 本（3D）。** WebGPU の backend に不透明と頂点の色・光 1 つ。`bench/scene3d` の部屋を出す。3D を 2D へ貼る形（5.4）を `bench/scene3d` で測る（fps3d_lab での確かめは P8 の終わり） | GL の backend と画素を比べる。**形のレビュー（3D）で確定** | 6〜9 時間 |
| 13 | R2b | **3D の残りを `DrawList` に。** 小分け: 材質と絵の組／影／骨と instance（`DataTexture`・`Instancing`・`JointTexture` を GL の backend の中へ）／環境マップ・空・lightmap／ビルボード・半透明・後がけ／寿命の表 | R2a と同じ門 | 8〜12 時間 |
| 14 | P8 | **WebGPU の backend・3D の残り。** R2b の小分けの順。骨と instance は storage buffer と `firstInstance`。mip（決まり 7）と preload | P6 と同じ形の門。fps3d_lab の部屋と `bench/scene3d` が GL より遅くない（5% 以内） | 12〜16 時間 |
| 15 | P9 | **動かない物の持ち越し**（決まり 10）。前半は描く行を持ち越し、WebGPU の backend は行と render bundle を持ち越す | `bench/scene3d` の動く割合 0%・12,000 個が 16 ms 以下【目標】。東京 1 棟ずつが 16 ms 以下【目標】（届かなければ内訳を出して人に伺う） | 8〜12 時間 |
| 16 | P10 | **切り替え。** PC の既定を WebGPU に（画面なしの描き出し・テスト・動画の既定も）。`gl-capture` の基準を取り直す（Dawn の版を pin）。`docs/flix-conventions.md`・`backend-parity.md`・agents-pack・eval・migrations。外のゲームの追随 | リリースの門を全部。CI（GPU が無い）で回る門と手元だけの門を分けて書く | 6〜10 時間 |
| — | | **リリース 3**: WebGPU が既定 | | |
| 後 | | スプライトの集まりの口（決まり 11）・粒子（決まり 12）・GPU の上での間引き（compute で引数のバッファを書く。引数は 1 本のバッファに詰める）・ブラウザで `DrawList` の配列を JS へ 1 回で渡す形（draw が 100 本を超える場面が残った時） | 別に計画して伺う | — |

**見積もりの合計**: フェーズの足し算で 117〜176 時間。これに 9.1 の比べ（候補を小さく 2 つ作って測る。11 件 × 1〜2 時間 = 11〜22 時間）と、
レビュー役（R1b ⇄ P6・P5・R2b・P8・P10 の終わりと形のレビュー（3D）。直しを含めて 8〜12 時間）を足して、**合わせて 136〜210 時間**【推】。
同じ数え方をすると、第 2 版（描き手をもう 1 本書く形）は 139〜207 時間で、**時間はほぼ同じ**。`DrawList` を挟む得は時間でなく危険の下がり方:
リファクタは今の門で 1 画素まで守られ、WebGPU の側で合わせる相手は backend だけになり、形の誤りが V1・V2 と交互の進め方で早く出る。fallback も止まった描き手にならない。
リリースは 3 回（表の行）。リファクタだけの版は、次の定例のリリースに混ぜる。

### 9.1 測りながら・書き味を見ながら決める（人の判断 7）

最初に決め切らない物は、候補を小さく作って比べてから決める。比べ方は 2 つ: **ベンチの数字**（P0 のベンチ・背中合わせ）と、
**書き味のレビュー**（ゲームの側・エンジンの側のコードが実際にどう書けるかを、短い見本で人とレビュー役に見せる）。

| 決める物 | いつ | 候補 | 比べ方 |
|---|---|---|---|
| `DrawList` の 1 行の欄と高さ | R1a と V1 の後（2D）・R2a と V2 の後（3D） | 「物の集まり」の高さ／もう少し低い高さ（bind group まで決める） | GL の backend と WebGPU の backend の行数・ベンチ |
| `DrawList` をいつ流すか（5.1） | V1 の後 | `renderCommands` 1 回ごとにその場で流す／コマ全体を溜めて最後に流す | ブラウザの JS との行き来の回数・Pass のある場面のベンチ |
| 面と材質の draw ごとの値の並びを誰が決めるか（5.1） | P5 の最初 | `ShaderGen` が struct を出す／前半が決めた並びにシェーダーを合わせる | `ShaderGen` の行数・材質を足す時の書き味 |
| GPU の物の寿命の持ち主（5.3） | R1b の「上げ下ろし」の小分け | 表は前半・作る消すだけ backend／全部 backend | backend 2 つの行数・preload のテスト |
| `DrawList` の持ち方（5.1） | R1a | Int32 と Float32 の配列／record の列 | `sprite_stress` の絵が交互の 20,000 個 |
| 2D の絵のまとめ方（決まり 3） | P6 の最初 | アトラスの頁（texture array）／1 つの bind group に 16 枚 | `sprite_stress` の絵 16 / 256 種類・詰め直しの時間・絵のにじみ |
| 2D の頂点の形（決まり 4） | P6 の途中 | 2 つ残す／storage buffer から頂点を引いて 1 本にする | tidepool の draw の数・`sprite_stress` |
| WGSL の出し方（7 章） | P5 の最初 | 書き手を挟む／2 本目を書く | `ShaderGen` の行数の増え方・式の行の突き合わせの通り方 |
| スプライトの集まりの口（決まり 11） | P1 の後 | 今の `Drawable` の列のまま内側だけ速くする／配列を渡す新しい口／集まりを表す `Render.Item` を 1 つ足す | `crowd2d` の 20,000 体・ゲームの View の見本コード（書き味） |
| 動かない物の宣言（決まり 10） | P9 の前 | `Scene3d.staticGroup`（static group の計画の形）／物ごとのフラグ／エンジンが変わらない物を自分で見つける | `bench/scene3d` の動く割合・都市の見本コード（書き味） |
| PC の cutout の縁（3 章） | P8 の材質の小分け | discard（今のブラウザと同じ）／塗りの段の `sample_mask` で標本を自分で決める | MSAA の縁の絵（今の GL と比べる） |
| 3D を 2D へ貼る形（5.4） | V2 | 先に自分のテクスチャへ描いて貼る／pass を閉じて開き直す | `bench/scene3d` の 1 コマ・MSAA の縁の絵（fps3d_lab は P8 の終わりに） |

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
| `DrawList` を挟んで今より遅くなる・R1 と R2 の途中で絵がずれる | 低〜中 | 小分けごとに `gl-parity` 0 px と P0 のベンチ（5% 以内）。遅くなったら行の持ち方を直してから次へ |
| `DrawList` の形が合わず、WebGPU の backend を書く時に作り直しになる | 中 | リファクタを全部終える前に V1（2D）・V2（3D）で縦に 1 本通し、形のレビューで確定してから残りを進める（9 章の順） |
| GL の backend がいつまでも残る（新しい機能ごとに backend 2 つと SoftRaster を触る） | 中 | やめる条件を決めておく: WebGPU の無いブラウザの割合が十分小さくなり（数字は人に伺う・11 章の 1）、Studio が WebGPU で動くようになった時。Studio は当面 GL のまま（別のリポジトリ。P10 の後に別に計画） |

## 11. 人に伺う事

1. **古い端末の扱い**: fallback は同じ `DrawList` を流す GL の backend になる。GL の backend をやめる時の目安（WebGPU の無いブラウザが何 % を切ったら）も伺う。前半に足した機能は fallback でも動くが、WebGPU でしかできない物（粒子の計算・storage buffer が前提の量）は古い端末で欠けるか遅い。これで良いか。
2. **PC のバインディング**: jWebGPU の Dawn 版を本線にする（ウィンドウまで通ったのがこちらだけ・Chrome と同じ実装）。外の小さなプロジェクトに頼り、配る物が約 13 MB 増える。
3. **P4a が通らない時**: PC だけ GL に残すか（判断 1 と食い違う）、通るまで別のバインディングを試すか。その時に伺う。
4. **スプライトの集まりの口**（決まり 11）: effect と pub が増える。P1 の後に候補を小さく作って数字と見本を出し（9.1）、入れるかどうかと形を伺う。入れる作業は P10 の後。
5. **動かない物の宣言の形**: `plans/engine-static-group.md` の 3 つの問いを、P9 の前に改めて伺う。
6. **絵が変わる物**: MSAA の 2 と 8 が 4 になる。PC の cutout の縁が discard になる（alpha to coverage が使えない）。丸めで 1〜2 階調ずれる場面が出る。門の許容を場面ごとに書いて、その一覧をお見せする。
7. **名前**: この文書の `DrawList` は仮の呼び名。今ある名前と紛れる物がある — engine の mod `DrawCmd`・診断の `Counter.DrawCalls`（GPU の draw の数）・`Scene3d.RenderCmd`。型は今ある物を広げる（3D は `SceneDraws`・`MeshBatch`、2D は run の状態）。候補: `Batch`（今の語を 2D にも使う）／Bevy の phase item／Unreal の mesh draw command。V1 の形のレビューで決める。interface は `WebGpu`、実行役は backend。パッケージは分けず render_gl の中に置く（名前は P10 で見直す）。
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
| 割り当てを減らす | effect を呼ぶたびの続きの入れ物・Java と JS の行き来の回数 | ブラウザ（wasm）で効く。PC は JIT が消す分がある | R1a・R1b で `DrawList` へ詰める時に一緒に取る |
| 仕事を減らす | まとめて描く（draw call）・動かない物を送り直さない・見えない物を描かない | PC もブラウザも。数が増えるほど効く | P6・P9・P10（WebGPU の backend） |

- 4.4 の「今の重さ」は P1 の前の値。R1a の前に、P1 の後の値で表を作り直す（どの段が残っているかが変わった）。
- 1 つ目の直し（1 個ぶんを別の def へ出す）だけだと、ブラウザは 9% 遅くなった（effect を持つ def を呼ぶたびに続きの入れ物を割り当てる）。
  **PC で速くなった直しは、ブラウザでも測ってから入れる**（門に足す）。
- 同じ罠が 3D の描き手とゲームの側に残っているかは未調査。crowd2d はベンチの側のループ（`Crowd.moveByGrid`）がインタプリタのまま（1 コマの約 15%）。

### 12.2 2D と 3D で共通にする所・分ける所

`DrawList` の命令を 2D と 3D で 1 つの形にまとめない。共通にするのは入れ物と下の層だけにする。

| 層 | 共通か | 理由 |
|---|---|---|
| `DrawList` の入れ物（Int32 と Float32 の配列・種類ごとの enum・1 コマぶんを使い回す） | 共通 | 割り当てを減らす手が同じ |
| backend の下（buffer・texture・pipeline の cache・bind group・render pass の開け閉め） | 共通 | WebGPU の命令は 2D も 3D も同じ |
| 命令の種類（スプライトの集まり・多角形・タイル層 / mesh の集まり・影の pass） | 分ける | まとめる鍵が違う（2D は重なり順が先・3D は material と mesh が先）。1 つにすると、どちらの最適な並べ方も取れない |
| 並べ方 | 分ける | 2D は z の順を守る。3D の不透明は順を入れ替えて良い（depth が前後を決める） |
| シェーダーの式（式の木 → GLSL / WGSL / CPU） | 共通 | 12.4 |

### 12.3 構造の決まりに足す 2 つ（`analysis-render-structure.md` から）

- **描き先を 1 枚と決め打ちしない。** 3D の場面は今、色 1 枚だけを出す。`DrawList` と render pass の形は、名前つきの attachment（depth・normal）を後から足せる形にしておく（足すのは WebGPU の backend の後。輪郭線・SSAO・被写界深度が読む）。
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
`DrawList` は `renderCommands` 1 回ごとにその場で流す・GL の番号の漏れの一覧と `GpuHandle` の読み替え・`LwjglLayer` が backend に聞く口の表・
順を「スプライトだけリファクタ → 縦に 1 本 → 形のレビュー → 残り」に（V1・V2・R1a/b・R2a/b）・`firstInstance` は未試作と認めて P4a・P4b の門に試作を足した・
alpha-to-one が無い事と clip の z と表裏・古い番号の食い違い・GL では「1 コマ 1 回で送る」を測ってからに・描く順の番号と材質の状態を backend に聞く・
偽の GL を通るテスト 6 ファイルを R2 の門に残す・新しい型を足さず今の `SceneDraws` と run の状態を広げる・配列で持つ・P1 を effect より上に絞る・
起動の選び分けの条件・目的 1 の文と GL の backend をやめる条件・見積もりに比べとレビューを入れた（115〜180 時間）・9.1 に 4 行と見本の形。

**第 3 版**: `DrawList` を挟み、先に今の描き手をリファクタしてから WebGPU の backend だけを書く形にした（5.1・R1・R2）。パッケージを分ける引っ越し（第 2 版の P3・P7）をやめた。
fallback は止まった別の描き手でなく、同じ `DrawList` を流す GL の backend にした。WebGPU の命令の再調査（`survey/H`）を入れた（`firstInstance`・dynamic offset を使わない・
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

### 12.14 P5 の前半で入った物（2026-11-15・この Mac・Dawn の Metal だけ）

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
- **GPU の無い機械では Dawn に届かない**: jWebGPU 0.3.4 の Dawn に Null の backend が無い（`requestAdapter` が `No supported adapters`）。`TestWgslDawn` は device が開けなければ組まずに通し、その旨を 1 行出す。Linux の CI はネイティブも無い。
- `agents-pack` の早見表と agent-eval には足していない: `ShaderGen.Wgsl`・`toWgsl`・`Render3dWgsl`・`wgsl-rows` はゲームが呼ばない engine の中の口（ゲームは今までどおり `ShaderDoc` を書くだけ）。
- 持ち越し（P5 の後半）: 3D の頂点シェーダー（骨・instance・lightmap の uv）・ビルボード・空・奥行きだけ・貼り付けの WGSL、2D の組み込みの残り（多角形・タイル・単色の代わり）、`R3dScene` を詰める所と光の式の値の比べ（ExprRows の WGSL 版）、
  3D の frag の pipeline と bind group layout まで作る検査、言葉の印を表の鍵（`@mode:wgsl`）で運ぶ形を enum の文脈へ替える事、ノイズの関数の 2 本書きのずれを CPU で見るテスト、f32 に収まらない定数（`Pow` の定数の積など）、
  2D の面の絵に mip が付いた時の読み（今はレベル 0 に決めている）、影の地図を描く頂点シェーダーも `sg_clipFromGl` を通す約束。
  P6 の頭で: `R3dScene` の欄の offset のテスト（詰める所と組で。mat4 の前は pad0〜pad2 で埋めてある）。f32 に収まらない `Const` を `ShaderDoc` の parse で弾くか丸める（今は WGSL の側でシェーダーを作る所の誤りになる）。
