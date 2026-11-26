# web_engine_compare の結果

比べる相手: https://github.com/endel/webgpu-webgl-benchmarks（`harness/upstream.sha` のコミット）。リポに LICENSE が無いので、コードは写さず `build/upstream` に取って手元で回すだけ。
Sponza は CRYENGINE Limited License・Fox は CC-BY-4.0（rig とアニメ）なので、どちらも git にも配る物にも入れない。

## S0: 比べる相手の 5 つの engine（M4 Pro・Chrome・WebGPU・quick）

`make upstream-quick ONLY='backend=webgpu'` → `npm run report -- --sessions <session>` → `npx tsx ../../harness/table.ts`（`build/upstream` で）。

測った日 2026-11-26・機械 Apple M4 Pro・Chrome 156.0.0.0（webgpu）・profile quick（1 回）・session 2026-11-26T20-42-05-chrome-quick

| 場面 | pixi3d | babylon-lite | babylon | playcanvas | three |
|---|---:|---:|---:|---:|---:|
| K1 TTFF（Sponza・K4 段 0）ms | 531 | 751 | 655 | 826 | 367 |
| K1 frame cost ms | 2.7 | 3.6 | 4.0 | 2.2 | 4.6 |
| K2 動く物 scene graph（naive） | 39k | 3.1k | 2.0k | 11k | 4.0k |
| K2 動く物 良い方（naive / optimized） | 171k | 189k | 133k | 128k | 187k |
| K3 churn frame cost / CPU 最悪 ms | 3.2 / 3.9 | 11 / 4.7 | 27 / 46 | 8.1 / 11 | 14 / 38 |
| K4 段 0（素）ms | 1.7 | 1.5 | 1.5 | 1.4 | 1.7 |
| K4 段 3（影＋31 灯＋bloom）ms | 3.1 | 4.1 | 5.3 | 4.3 | 17 |
| K4 段 4（256 灯）ms | n/a | 9.5 | 11 | 13 | 5.3 |
| K5 10 万 既定 ms | 2.2 | skipped | 69 | 12 | 33 |
| K5 10 万 optimized ms | 2.2 | 2.9 | 7.4 | 3.2 | 4.8 |
| K6 crossfade（naive） | 3.2k | 1.1k | 444 | 734 | 686 |
| K6 1 clip（optimized） | 6.5k | ≥ 6.4k | 43k | 925 | 823 |
| K7 半透明 | 16k | 3.0k | 2.5k | 8.2k | 3.2k |
| K7 compute 1M ms | n/a | 9.4 | 8.3 | 8.4 | 8.6 |
| K8 1 万の中の pick ms | 0.2 | 3.2 | 6.4 | 14 | 0.4 |
| K8 1M 三角形の pick ms | 5.7 | 16 | 17 | 0.8 | 36 |
| K9 名札 良い方 | 10.0k | 2.6k | 491 | 2.0k | ≥ 16k |

- quick は 1 回だけなので、公開の表（full・3 回の中央値）には使わない。並びは README（M1 Pro）とおおむね同じ。
- K5 の babylon-lite の 10 万は、2 万で予算を大きく超えたので段を飛ばした（README の「予算超え」と同じ）。
- 後半（K6〜K9 の辺り）は、型検査と書き出しを効率コア（`taskpolicy -b`）で並べて流していた。数字の揺れの元になりうる。
- **1 回の所要時間**: WebGPU の 5 つで 54 分（595 回・1 回 平均 5.4 秒。timing 257・counters 240・prime と canary 98）。
  - full（timing 3 回＋counters）は同じ 5 つで約 1 時間 40 分、WebGL2 の 4 つを足して約 3 時間、flix の 2 つ（WebGPU・WebGL2）を足して約 3.5〜4 時間（計画の推測 4〜8 時間を下げる）。

## S0.5: X1 案 c のスパイク（engine 無改修で harness の frame の中で 1 コマ回るか）

`make spike`: minimal の書き出しの頁で `window.requestAnimationFrame` を包んで callback を溜め、外の loop（harness の `frame()` に当たる）が溜まった物を呼ぶ。
呼ぶ時刻はコマの番号 × 16.67 ms の単調な時計。`GPUQueue.submit` と `GPUCanvasContext.getCurrentTexture` を数える。押して始める画面は合成の keydown で通す。

ヘッドレスの Chrome（WebGPU・apple metal-3）で 600 コマ:

| 量 | 値 |
|---|---|
| 1 回に呼んだ callback | 1（頭の 1 回だけ splash の分と 2） |
| 呼び出しの中で submit したコマ | 540 / 540（温めの 60 を除く）・1 コマに 1 回 |
| 呼び出しの中で getCurrentTexture したコマ | 540 / 540 |
| 呼び出しの中で次の rAF を予約して戻ったコマ | 540 / 540 |
| 呼び出しの外の submit | 1（起動の時の 1 回だけ） |
| 1 回の呼び出しの時間（光の当たる箱・MSAA 4×・後がけ） | p50 2.1 ms・p95 3.0 ms・最大 4.0 ms |

→ **通る**。callback を呼ぶと wasm のループがその場で再開し、更新・描き・submit・次の待ちまで進んでから戻る（TeaVM のコルーチンの再開は同じ JS の呼び出しの中）。
engine_web に口を足す案 a は要らない。

## S1: 場面の土台

- `src/Rng.flix`（mulberry32。k 番目の値は種と k だけで決まる形で引く）・`src/Geometry.flix`（8 つの形）・`src/Scenes.flix`（K1・K2）・`src/Draw.flix`（右手系 → engine の左手系・線形 → 画面の値）。
- `make scene-compare`: Flix の場面 5 つ（K1 の t=0・1.25、K2 の 500 個の t=0・1.25、4,000 個の t=0.7）を、比べる相手の `buildScene` の値と比べる
  （位置・倍率・四元数・親・world の行列・材質・8 つの形の頂点と番号）。Float32 へ丸めて相対 1e-5・整数は完全一致で **173 の配列が全部一致**。
- engine の口で回す道（案 B・`make bench-web BENCH=web_engine_compare ARGS='scenario=k2&level=<n>&repeat=1'`・ヘッドレスの Chrome・1920×1080・WebGPU）。
  物差しが比べる相手と違う（GPU の時間が無い・rAF の 60 Hz に張り付く）ので CPU p95 だけを見る。表には並べない。

| 場面 | CPU p50 ms | CPU p95 ms | draw call | 3D の描き手の区間（split / draw）ms |
|---|---:|---:|---:|---|
| K1 | 2.2 | 3.0 | 1 | 0.3 / 0.5 |
| K2 500 | 4.5 | 5.5 | 124 | 1.0 / 1.3 |
| K2 2,000 | 8.8 | 10.5 | 128 | 2.5 / 2.2 |
| K2 4,000 | 18.2 | 21.5 | 128 | 3.9 / 3.7 |
| K2 8,000 | 34.2 | 39.5 | 128 | 7.2 / 8.0 |

  - K2 naive の「60 fps に収まる最大」を CPU p95 だけで補間すると約 3.1k（2,000 と 4,000 の間）。比べる相手の M4 Pro の naive は 2.0k〜39k。
  - engine は物ごとに置いても同じ形と材質を自動でまとめる（draw call は 8 形 × 16 材質の組の数まで）。比べる相手の report では「naive で自動にまとめた」の印が付く形。
  - CPU の半分ほどは、Flix の側で物ごとに四元数から world の行列を作り、親の回転を重ねる仕事（K2 は場面の側で親子を計算する・Bevy と同じ）。
- Float32Array を写す値段は測れていない: JS の配列を wasm の Flix の値へ写す口が engine_web に無い（`fge.web` の外で JSO を使えない）。
  案 c では場面を Flix の側で同じ乱数から作り（S1 の土台）、JS から渡すのは時刻 t だけにする（`Browser.queryPairs` が呼ぶ頁の `fgeQueryPairs` を adapter が差し替える道が engine 無改修で使える・S3 で確かめる）。

## S2: 配る大きさ（Footprint）

`make footprint`: `../web_engine_compare_minimal`・`../web_engine_compare_featured` の 2 つの app を本番で書き出し（`--draft` でない）、brotli の quality 11 で数える（比べる相手の `bundle-size` と同じ quality。比べる相手は JS だけを数える）。

| app | classes.wasm | glue の JS（fge-web.js・wasm-gc-runtime.js・index.html の script） | brotli-decode.js | 最初に要る分 | 後で読む分（sw.js・glb の Worker） | 合計 |
|---|---:|---:|---:|---:|---:|---:|
| minimal（光の当たる箱・MSAA・ACES） | 1,305 KB | 52.5 KB | 61.5 KB | 1,419 KB | 9.8 KB | **1,429 KB** |
| featured（glb の骨つきの狐・アニメ・太陽の影・bloom・ACES） | 1,339 KB | 52.6 KB | 61.5 KB | 1,453 KB | 9.8 KB | **1,463 KB** |

- 比べる相手（README・M1 Pro の表）: 最小 44〜422 KB・glTF＋影＋bloom 192〜864 KB。**最小で 3.4〜32 倍・featured で 1.7〜7.6 倍の大きさで負ける**。
- minimal と featured の差は 34 KB だけ。大きさの大半は TeaVM の classlib・Flix の runtime・3D の描き手（GL・WebGPU の 2 つ）で、使う機能ではほとんど減らない。
- `brotli-decode.js`（61.5 KB）は置き場が `Content-Encoding: br` で配らない時に `.br` を JS で解くための物。置き場が br で配れば要らない（その時 1,368 KB・1,401 KB）。

## S3: 比べる相手の harness に flix の adapter を足す（案 A）

`make compare ONLY='engine=flix,three;scenario=k1'`（`PROFILE=smoke|quick|full`）: `harness/upstream.patch` を当て、`harness/flix-adapter.ts` を写し、本番で書き出して `public/flix/` へ写してから回す。

- **adapter**（`harness/flix-adapter.ts`・engine は無改修）: 書き出しの頁の部品と script を harness の頁に載せ、harness の canvas を `fge-canvas` にする（WebGL2 もこの canvas の `getContext('webgl2')` を取るので probe が数える）。
  rAF を包んで engine の callback を溜め、`frame()` の中で呼ぶ。場面の時刻 t は頁の `fgeQueryPairs` を包んで渡す。押して始める画面は keydown で通す。
  `load()` は 60 コマ回して pipeline と形の初めての上げを済ませる。
- **patch**（自分で書いた 4 行の組・`harness/upstream.patch`）: `EngineId`・`ENGINES`（types と matrix と run の表）に flix を足す。
  場面の更新の時間を外すために、adapter が `takeSimMs()` を持つ時は CPU 時間から差し引いて sim に足し、差し引く前の値を `frames.cpuRaw` に残す（他の adapter は持たないので何も変わらない）。
- **場面の更新の ms**: Flix の側で物ごとの行列を作る区間を測り、console の 1 行（`[wec] sim <ms>`）で返す。adapter が `console.log` を包んで受ける（console へは出さない）。
- **確かめ**（smoke・counters の回）: WebGPU と WebGL2 の両方で K1・K2 が通る。K2 の描いた三角形は期待の数と一致（render guard を通る）。
- **絵**: K1 の frame 60 の箱の向きは three.js と同じ（t の受け渡しが効いている）。
  - 初めは裏の面が描かれた。Z を裏返しただけでは engine の表の向きと合わず、三角形の 2 番目と 3 番目を入れ替えて直した。
  - 光の倍率は three.js と同じ π にした（1 では手前の面が暗い。π で手前の明るい面がほぼ合う）。
  - 背景と影の側の面は three.js より明るい。AcesNarkowicz が画面の値に掛かり、暗い所を持ち上げるため（X2 を待つ）。

smoke（1 回・M4 Pro・Chrome 156）の flix の値:

| backend | variant | 物の数 | CPU p95（差し引いた後）| CPU p95（差し引く前）| 場面の更新 p50 | interval p50 | GPU p95 | draw |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| WebGPU | naive | 500 | 3.6 | 4.2 | 0.6 | 3.8 | 2.3 | 127 |
| WebGPU | naive | 4,000 | 9.2 | 16.9 | 7.8 | 15.5 | 4.5 | 131 |
| WebGPU | optimized | 4,000 | 4.6 | 9.5 | 4.9 | 8.9 | 3.3 | 131 |
| WebGPU | optimized | 32,000 | 9.4 | 47.4 | 37.6 | 47.0 | 7.1 | 131 |
| WebGL2 | naive | 4,000 | 8.5 | 16.5 | 7.9 | 14.9 | — | 129 |
| WebGL2 | optimized | 32,000 | 10.6 | 50.3 | 38.8 | 48.8 | — | 129 |

- optimized は形と材質の組ごとに `MultiMesh3d.build` を毎コマ組む（組の数 = 8 形 × 16 材質のうち出た物）。
- **frame cost は差し引きの効きが小さい**: frame cost = max(CPU p95, GPU p95, interval p50) で、interval（コマの間隔）は場面の更新を含む。
  他の engine の場面の更新は 0.01〜0.06 ms なので、K2 の 32,000 の差（9.4 ms と 47 ms）はほぼ Flix の側の行列づくりの値段。
- 場面の更新が重い所は bench の Flix のコード（物ごとに Vector を作る `Scenes.worldColumns`）で、engine の外。S4 の前に軽くする余地がある。
- 4,000 個の naive では engine が console に staticGroup と MultiMesh3d を勧める 1 行を出す（report の consoleErrors に 1 件と数えられる）。

### 場面の更新を軽くした前と後（S4 の前・WebGPU・smoke）

`Scenes.worldColumns` を、物ごとに 4〜6 個の Vector を作る形から、四元数の回転を数だけで計算して最後に 1 つの Vector に詰める形にした（親の回転を重ねる式は同じ・ゲームが普通に書く範囲）。
naive は物ごとの `Scene3d.meshInstance`、optimized は形と材質の組ごとの `MultiMesh3d.build` のまま（どちらも毎コマ組み直す）。

| variant | 物の数 | 場面の更新 p50 前 → 後 | CPU p95（差し引いた後）前 → 後 | CPU p95（差し引く前）前 → 後 | interval p50 前 → 後 |
|---|---:|---:|---:|---:|---:|
| naive | 500 | 0.59 → 0.36 | 3.6 → 3.1 | 4.2 → 3.5 | 3.8 → 3.2 |
| naive | 4,000 | 7.8 → 6.1 | 9.2 → 9.1 | 16.9 → 14.7 | 15.5 → 12.8 |
| naive | 32,000 | 62.9 → 48.3 | 55.1 → 55.0 | 128.0 → 110.8 | 113.2 → 101.3 |
| optimized | 4,000 | 4.9 → 3.1 | 4.6 → 5.0 | 9.5 → 8.0 | 8.9 → 7.4 |
| optimized | 32,000 | 37.6 → 26.5 | 9.4 → 11.3 | 47.4 → 38.6 | 47.0 → 37.2 |

- 表の決まり: frame cost は元の決まり（max(CPU p95, GPU p95, interval p50)）のまま載せる。CPU は差し引いた後（主）と前の 2 列。interval からは差し引かない。
  **注: 場面の更新は Flix の bench のコード（`src/Scenes.flix`）の値段で、ゲームが払う本当の値段として interval と frame cost に入る。**
- engine が 4,000 個以上の物で console に出す置き方の助言の 1 行は、adapter が consoleErrors から外して `counters` の `hints` に数える（naive の 4,000・32,000 で 1）。

## S4（途中）: K5・K7

`make scene-compare` に K5（20,000・t=3.0）と K7（500・t=0.8）を足し、7 場面・275 の配列が比べる相手と一致（カメラの注視点・材質の opacity も比べる）。

smoke（1 回・counters の回・WebGPU）の flix の値（ms）:

| 場面 | variant | 物の数 | CPU p95（差し引いた後）| CPU p95（差し引く前）| 場面の更新 p50 | interval p50 | GPU p95 | draw |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| K5 | naive（毎コマ物を作る・前） | 20,000 | 26.5 | 58.5 | 30.6 | 51.7 | 2.1 | 67 |
| K5 | naive（毎コマ物を作る・前） | 100,000 | 90.1 | 280.9 | 160.3 | 240.7 | 3.0 | 67 |
| K5 | naive（物の列を読み込みで 1 回作る・後） | 20,000 | 18.1（smoke の CPU p50） | — | ほぼ 0 | 18.3 | 0.9 | — |
| K5 | naive（同・後） | 100,000 | 89.3（同） | — | ほぼ 0 | 90.0 | 1.3 | — |
| K5 | optimized（区画ごとの staticGroup） | 20,000 | 2.7 | 2.7 | 0.05 | 2.6 | 1.5 | 1,299 |
| K5 | optimized（同） | 100,000 | 2.7 | 2.8 | 0.09 | 2.5 | 1.5 | 1,296 |
| K7 | naive（半透明・遠い順） | 500 | 9.4 | 9.9 | 0.4 | 9.1 | 1.5 | 503 |
| K7 | naive（同） | 4,000 | 63.8 | 68.4 | 3.6 | 50.4 | 3.1 | 4,003 |

- **K5 の naive**: 動かない物の列を読み込みで 1 回作り、毎コマ同じ値を渡す形にした（動かない物を毎コマ作り直さないのはゲームが普通に書く形）。残りは engine が 1 体ずつ視錐台で間引いて計画する CPU。
  比べる相手の M4 Pro の 10 万の既定は 2.2〜69 ms（three.js 33・babylon 69）。flix の 90 ms はその外。
- **K5 の optimized**: 16 m の区画ごとに staticGroup を読み込みで 1 回作り、カメラの向きから見える区画だけを渡す（間引きの式は adapter の側の Flix が持つ・計画の決め 9）。
  10 万で 2.5 ms で、比べる相手（2.2〜7.4 ms）の中に入る。
  - engine は console に 2 行出す: 「staticGroup の名前か値が 300 コマに 20 回替わった」（区画の出し入れを作り直しと読み、先に作る仕組みを止める）と「draw call が 1,300 あり形が違うので分かれた」。
  - 2 行とも adapter が consoleErrors から外して hints に数える。1 行目は、区画を `App.withPreload3d` で先に宣言すれば消える見込み。
- **K7**: 半透明の物は 1 体ずつ遠い順に描く（draw = 物の数）。500 個で CPU 9.4 ms と重い。比べる相手の「60 fps に収まる最大」は 2.5k〜16k なので、flix は約 1k の見込み（ladder を流して確かめる）。

## S4（続き）: K8 と K5 の区画の先作り

- `make scene-compare` に K8（1 万）を足し、8 場面・322 の配列が一致（pick の 64 点も比べる）。
- **K8 の pick の道**: adapter が頼み（番号・x・y）を `fgeQueryPairs` に載せて engine の 1 コマを回し、Flix の側（`Draw.pick`）が答えを console の 1 行で返す。
  - Flix の側は `Camera3d.screenPointToRay` と `Ray3d.hitMesh` で 1 つずつ当てる（engine の pick の口）。
  - harness の patch で、adapter が `takePickMs()` を持つ時は、Flix の側でレイを当てた ms を pick の時間にする（描くコマの時間は含めない）。
  - optimized は `N/A (as naive)`（engine の pick の口は 1 つだけ）。
- **K5 の区画**: 全部の区画を `App.withPreload3d` の groups で起動の時に先に作る宣言にした。

smoke（1 回・WebGPU）:

| 場面 | 段 | flix | three.js | 注 |
|---|---|---:|---:|---|
| K8 pick 1 万の中 | 1 回の ms（p50） | 24.9 | 0.41 | 64 点の答えは three.js と全部一致（当たり 47） |
| K8 pick 1M 三角形 | 1 回の ms（p50） | 656 | 30.6 | 64 点とも球（slot 0）に当たる |
| K5 naive | 2 万 / 10 万の interval ms | 18.0 / 72.2 | 9.8 / 34.2 | 物の列は読み込みで 1 回作る |
| K5 optimized | 2 万 / 10 万の interval ms | 2.5 / 4.5 | 1.7 / 5.0 | 区画の staticGroup・先に作る宣言つき |

- K8 の pick は、比べる相手の M4 Pro（1 万の中 0.2〜14 ms・1M 三角形 0.8〜36 ms）より 1 桁以上遅い。BVH が無く、物ごとに境界の箱を見て三角形を全部当てる（計画の「今は足さない物」の BVH の相談の候補）。
- K5 optimized の hints は先に作る宣言の後も 1（draw call の助言の行）。

## S4（続き）: K3（churn）

- 場面は状態を持つ: コマ f（= round(t × 60)）で組 f % 100 の 20 個を、種 300000 + f の乱数で作り直す（位置に 60 個、続けて 1 個につき形・材質・大きさの 3 個）。
  Flix では World に場面の写しと、組の番号 → 絵と材質の Map（`Draw.Churn`）を持ち、1 コマに 20 個ずつ差し替える。
- 絵は `Texture3d.fromArgb` の 128×128（模様は比べる相手の churnField と同じ式）、材質は `texturedMaterial`（Linear）＋ `withMetallicRoughness`、色は `withTint`。
  場面の textures には生きている 100 枚を渡し、絵の枚数の予算を project.json の `scene3dTextureBudgetCount` で 64 → 128 に上げた。
- `make scene-compare` に K3 の 2 場面（t = 0 と t = 2.5 = コマ 150・組が 1 周半回った後）を足した。比べる側はコマ 0 から順に update を回し、コマ 150 の絵の画素（RGBA）も完全一致で比べる。
  **10 場面・415 の配列が一致**。
- 場面の更新として差し引くのは、場面の写しと絵の画素を作る所（比べる相手の scene.update に当たる）と、物ごとの行列を作る所。`fromArgb`（16,384 画素の hash）と材質を作る所は engine の仕事として CPU に残す。
- **adapter の直し**: 初めて出る絵の材質で engine が WGSL の `getCompilationInfo` を await し、pump の外で戻って本物の rAF で回り続けた（frame() の中の CPU が 0・差し引くと負）。
  pump の外の rAF の予約でも、呼び手の stack に wasm の関数があれば engine の物として溜めるようにした（harness の予約は今までどおり本物の rAF へ）。

smoke（1 回・counters の回・WebGPU・2,000 個）:

| engine | CPU p50 / p95（差し引いた後）| CPU p50（差し引く前）| 場面の更新 p50 | interval p50 | GPU p95 | draw |
|---|---:|---:|---:|---:|---:|---:|
| flix | 44.5 / 51.7 | 47.2 | 2.3 | 47.5 | 5.1 | 1,726 |
| three | 10.1 / 11.3 | 10.1 | 0.05 | 10.4 | 11.1 | 2,008 |

- 絵（frame 60）は three.js と物の置き方・作り直した物の市松の絵まで同じ（明るさの差は X2 の既知の差）。
- **重い所は engine の 3D の描き手**（`make bench-web` の cpu_phases で split 17.5 ms・draw 17.3 ms。K2 の 2,000 個は 2.5 / 2.2 ms）。
  作り直した物はどれも絵と材質が違うので draw が約 1,700 本に分かれ（draw3d_breaks の material 1,662）、1 本につき CPU 約 20 µs（three.js は 2,000 本で約 5 µs）。
  counters の `createBindGroup` が 1 コマ 1,721 回で、絵の bind group を draw ごとに毎コマ作っている見込み（three.js は 27 回）。→ 相談の候補。

## S5: K9（HUD の名札）

- 場面: 回る 1,000 個（種 9・材質 4）の上に、板 4 枚 → 動かない icon 50 → 名札（下地 → bar → icon → 字）→ 毎コマ変わる字 30。名札の位置・体力・字は比べる相手と同じ乱数（種 99）と式。
  `make scene-compare` に K9 の 2 場面（250 枚・t = 0 と 1.75）を足し、HUD の値（板・icon・名札の位置と体力と升と字・毎コマ変わる字）まで **12 場面・531 の配列が一致**。
- icon の atlas は比べる相手の `buildScene` が canvas に描いた物を、そのまま PNG にした（`make compare-assets` が vite と Chrome で描かせる・git の外）。描き方を写していないので、PNG どうしの比べはしない。
- 字は比べる相手の Roboto（Apache-2.0）を project.json の fonts に置き、書き出しの font-bake でアトラスにする（engine の字の道はこれだけ）。`App.withFonts` で名前を宣言しないと既定の字（起動の字）へ落ちる。
- 描き方（naive）: `App.withHudView` の 2D で、名札ごとに z を 4 つ（下地・bar・icon・字）続けて置く（HudSpec の描く順のとおり）。名札の字の幅は初めのコマで 1 回量って控える。
  名札の位置（比べる相手の scene.update に当たる）は場面の更新として差し引き、絵の列を組む所は CPU に残す。HUD は PostStack の外なので tone map も bloom も掛からない。
- optimized は `N/A (as naive)`: engine の 2D は z の順に続く同じ絵を自動でまとめる 1 つの道だけで、別のまとめ方の口が無い（three.js も N/A）。
- engine の 2D が 1 コマ 2,000 個を超えると出す助言（`budget: この 1 フレームで …`）は hints に数える（HINT_PREFIXES に足した）。

smoke（1 回・counters の回・WebGPU）:

| 名札 | flix CPU p50（差し引いた後）| flix interval p50 | flix draw | three CPU p50 | three interval p50 |
|---:|---:|---:|---:|---:|---:|
| 0（HUD なし）| 2.6 | 3.7 | 35 | 2.8 | 3.2 |
| 250 | 7.1 | 9.4 | 787 | 3.2 | 3.7 |
| 500 | 12.7 | 14.0 | 1,537 | 3.5 | 4.0 |
| 1,000 | 24.3 | 25.4 | 3,037 | 3.5 | 4.0 |
| 16,000 | — | — | — | 4.1 | 4.6 |

- 60 fps に収まる最大は flix 約 600（500 と 1,000 の間）、three.js は ≥ 16k（README の M1 Pro では PlayCanvas 547・Babylon.js 393 なので、その辺り）。
- **重い所は engine の 2D**（`make bench-web` の 1,000 枚: 2D の draw 3,003 本・切れ目は全部が絵の替わり（texture 3,001）。3D の区間は split・draw とも 1 ms）。
  名札の中で 色の矩形 → icon の atlas → 字のアトラス と絵が替わるたびに batch が切れ、1 枚に約 3 本・CPU 約 22 µs。→ 相談の候補（絵を跨いでまとめる・HUD 用に字と icon を 1 枚に寄せる口）。
- 絵（frame 60）は名札・icon・板の置き方が three.js と同じ。字の縦の置き方は flix が数画素下（engine の字の置き場所は行の上・three.js は canvas の textBaseline top）。

## S6: K6（骨つきの狐の群れ・crossfade）

- 場面: 比べる相手の Fox.glb（CC-BY・`make compare-assets` が assets/ へ写す・git の外）を格子に並べる。高さを 1.6 m にそろえる倍率と間隔は、読んだ形の頂点の広がり（`Mesh3d.bounds`）から同じ式で出す。
  `make scene-compare` に K6 の 2 場面（25 体・400 体）を足し、カメラ・位置・yaw・位相・Run の重みまで **14 場面・547 の配列が一致**（広がりは比べる相手の manifest の値を渡す）。
- naive: 毎コマ体ごとに `AnimationClip3d.sample`（Walk・Run）× 2 → `Pose3d.blend` → `Pose3d.compute`、`Model3d.partInstances` に `Scene3d.withPose`。
- optimized（計画の決め 8）: 比べる相手と同じく Walk だけ。読み込みで Walk を 1 秒 30 刻みの姿勢（`Pose3d`）にしておき、体ごとに一番近い刻みを使う（同じ姿勢の体は engine が姿勢の行を分け合う・Babylon.js の baked animation と同じ考え方）。path に刻みを書く。
- 差し引く場面の更新は Run の重みだけ（比べる相手の scene.update と同じ）。姿勢を取り出して混ぜる所と置く所は engine の仕事（比べる相手の mixer）として CPU に残す。
  - Flix の最適化が純粋な let を測る thunk の中へ畳み、姿勢の値段が場面の更新に入っていた。姿勢を作る所も timed で包んで順を決めた（値は捨てる）。
- glb の形は右手系のまま読まれるので、Z の裏返しの代わりに Y の半回転で向きをそろえた（左右が対称な狐なので、違うのは左右の脚の歩みの順だけ）。frame 60 の絵で向き・大きさ・間隔が three.js と同じ。
- engine の助言の行（`scene3d: 同じ形と材質の物が …`）を hints に数える（HINT_PREFIXES に足した）。

smoke（1 回・counters の回・WebGPU）の interval p50（ms）:

| 体 | flix naive | three naive | flix optimized | three optimized |
|---:|---:|---:|---:|---:|
| 25 | 2.9 | 0.9 | — | — |
| 100 | 6.2 | 1.7 | — | — |
| 200 | 10.5 | 2.9 | 2.9 | 2.5 |
| 400 | 18.8 | 7.3 | 3.3 | 7.6 |
| 800 | — | 16.9 | 4.2 | 17.7 |
| 1,600 | — | 33.8 | 6.5 | — |
| 3,200 | — | — | 10.5 | — |
| 6,400 | — | — | 17.6 | — |

- 60 fps に収まる最大: flix naive 約 350・three.js naive 約 790 ／ flix optimized 約 6.0k・three.js optimized 約 770（three.js は姿勢を分け合う道が無く、既定の道で回す）。
  README の M1 Pro の naive は 359〜2.9k、1 clip は 621〜32.8k。
- naive の CPU は体 1 つに約 45 µs（姿勢の取り出し 2 回・混ぜ・行列 24 本）。GPU は 400 体で 1.3 ms と軽い。
