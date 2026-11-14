# 都市の場面の「今の基準」と重さの内訳（WebGPU 比較用）

測った日: 2026-11-14 / 機械: Apple M4 Pro・macOS（GL は Apple の Metal 上の OpenGL）/ 窓: framebuffer 1920x1080（design 960x540・windowScale 2）/ 垂直同期なし（`FLIX_GE_NO_VSYNC=1`）・音なし。
ゲームは両方とも engine 0.92.0 の lib のまま（engine の作業木は 0.94.1。版は上げていない・動いた）。
【確】= 測れた / 【推】= 割り算・見積もり / 【不明】= 測れていない。

ソースは直していない。診断を取るために、ゲームを `scratchpad/webgpu/probe/{plateau_city,ome_city}` へ rsync でコピーし（data は symlink）、コピーの `Main.flix` に `App.withDiagnostics` と 1 コマ 1 行 println の系 `Probe.flix` を足した。元のゲームの追跡ファイルは無傷（git status 空）。

---

## 1. 既にある数字（engine docs / plans）

| 場面 | 数 | 機械 | 出典 |
|---|---|---|---|
| 箱庭（lamplighter）町を家ごとに分けた | 857 個で 14.1 ms/コマ | M4 Pro・960x540・vsync なし | plans/engine-scene3d-cpu.md |
| 同・形をつないだ後 | 約 250 個で 5.7 ms（路地 7.0 ms） | 同 | 同 |
| 同・別の MacBook | 31〜38 fps | 不明 | 同 |
| 箱庭の町（鏡面材質にした時） | 473 → 1283 draw/コマ・5.3 → 13 ms | 不明 | docs/scene3d.md:144 |
| scene3d-cpu の内訳（jstack 60 回） | `Paint.submitGpuItems` 内が約 7 割。うち planScene 系 3〜4 割・drawScene/drawBatch 2 割・buildProgram(eqSpec) 1 割。record の欄引き（RecordExtend.lookupField）が一番上の 4 割強。GL の呼び出し（draw・blit・present）は 2 割弱 | M4 Pro | 同 |
| 青梅 | 地形 56 万三角形・物 247（地形）/ aerial3k・street の前後比較は「測る」とだけ書いてあり数字は未記入 | - | plans/engine-city-scale.md:154,174 |
| horde-waves300（2D 敵 + 3D?） | draw call 304・submit 5.74 ms・GPU 1.67 ms・work 11.8 ms | - | plans/engine-horde-perf.md:12 |
| bench/scene3d（GL・部屋 1 つ） | p50 0.925 ms（GlContext 移行後） | M4 Pro | docs/backend-parity.md:35 |
| ブラウザ(wasm)の 1 コマの CPU | bench/scene3d 1.3 ms・fps3d_lab の部屋 16.6 ms（隠れた内蔵ブラウザ） | M4 Pro | docs/backend-parity.md:34 |
| ブラウザ WebGL2 の instance 描画 | 1 万個を毎コマ書いて描く 3.26 ms（PC JVM 0.93 ms・3.5 倍） | M4 Pro | plans/engine-browser-spikes.md:152 |
| スマホ | fps3d-room 46.5 fps・cpu 20.7 ms（Galaxy S24 Ultra）／bench/scene3d は 60 fps 安定 | S24 Ultra ほか | メモリ・plans/engine-browser-3d.md:90 |
| 3D の箱庭 fps3d_lab の部屋（デスクトップ） | 約 8.8 ms | M4 Pro | メモリ（出典 plans 未確認） |

都市ゲーム側の NOTES / README / plans には性能の数字も bench・perf の口も無い（README は run/flow/render のみ）。`debug/*.items.tsv` は `total=0` のみで使えない。

## 2. 測る口の一覧

| 口 | 何が取れる | 都市ゲームで使えたか |
|---|---|---|
| `FLIX_GE_FRAME_STATS=1`（環境変数・LwjglEnv） | 600 コマごとに「塗り avg/p99」「間隔 avg/p99」（ms）。診断の query を使わないので**測定が軽い** | 使えた（コード変更なし）。「間隔」= 1 コマの実時間 |
| `App.withDiagnostics`（コード 1 行・`frame#diagnostics`） | submitNs・swapNs・gpuNs・gpuPasses（Pass ごと）・drawItems・scene3dCounts（instances/drawn/drawCalls・cpuPhases = shadows/split/draw/endFrame・uploads） | 都市ゲームには繋がっていない。コピーに足して使えた。**ただし測定が重い（下記）** |
| `FrameDiagnostics.summaryLines` | 上の整形（画面に出す用） | 未使用（println を自前で書いた） |
| `Render3d.Counts` | 3D の数（上の scene3dCounts の元） | withDiagnostics 経由 |
| `GpuTimer`（`GL_TIME_ELAPSED`） | Pass ごとの GPU 時間 | withDiagnostics 経由 |
| **`FLIX_GE_GL_LOG=<file>`（`GlCallLog`/`RecordingGl`）** | GlContext 経由の GL 呼び出しを 1 行ずつ。`FLIX_GE_GL_LOG_FRAMES=N` で頭の N コマ（既定 6）。`--- frame n` 区切り。**呼び出しの総数・種類別が数えられる** | 使えた（コード変更なし）。※名前は `RecordingGl`/`GlCallLog`（Flix 側の refactor 索引では RecordingGl は 0 件。Java 側 render_gl/java/fge/gl/RecordingGl.java） |
| jstack を 0.15 秒おきに 100 回（メイン thread） | CPU の時間がどこにあるかの割合（GL native 対 Flix） | 使えた（engine-scene3d-cpu.md の流儀） |
| `make scene3d-bench`（bench/scene3d の `make run`） | p50/p95・GPU p50（軽い部屋） | 使えた |
| `POST /perf`・hitch.md | 重いコマだけ | 未使用（平均は出ない） |
| `make smoke-devtools`・`bin/fge web-capture` | 命令口・絵の撮影（?capture=n のコマ）。**1 コマの時間は測らない** | 都市は対象外（下記） |
| uniform の呼び出し回数 | 専用の口は無いが GL_LOG の `uniform*` 行を数えれば出る | 取れた |
| 状態の切り替えの数 | GL_LOG の bind*/enable/useProgram を数えれば出る | 取れた |

測定の落とし穴【確】:
- `withDiagnostics`（GPU の timer query）を付けると 1 コマが倍になる。同じ Tokyo aerial3k で、診断なし（FRAME_STATS）間隔 3.04 ms → 診断あり dt 6.0 ms。jstack では診断あり側のメイン thread の 36% が `glEndQuery`（Ome street）。**GPU 時間の絶対値は GL_TIME_ELAPSED で取れるが、CPU 側の ms は診断なしの FRAME_STATS を基準にすること。**
- GPU の passes に bloomA/B が負の値で出る（query の引き算の都合・実質 0）。

## 3. デスクトップでの実測

場面の名前: Tokyo = `aerial`（1km? 旧）/`aerial3k`/`street`、Ome = `aerial3k`/`street`。起動は `START="preset name=<名前>" make run RUN_SECONDS=…`。
都市のモデルは `assets/sample.kind.json` の model。Tokyo の出荷既定は `3k_merged_2048`（区画ごとに 1 物 = 61 個）。比較のため `PLATEAU_MODEL=3k_each_2048`（建物 1 棟 1 物 = 12,557 個）も測った（draw call が桁違いに多い、WebGPU の効きを見る極端側）。

### 3-1. 1 コマの時間（診断なし・`FLIX_GE_FRAME_STATS=1`・中央値の窓）【確】

| 場面 | 間隔 avg（ms） | p99 | fps 換算 |
|---|---|---|---|
| Tokyo merged aerial3k | 3.04 | 4.12 | 約 330 |
| Tokyo merged street | 2.48 | 3.29 | 約 400 |
| Tokyo merged aerial（旧 1km 構図） | 3.20 | 4.20 | 約 310 |
| Ome aerial3k | 3.66 | 5.02 | 約 270 |
| Ome street | 3.59 | 4.71 | 約 280 |
| Tokyo **each** aerial3k | 137 | 182 | 約 7 |
| Tokyo **each** street | 122 | 167 | 約 8 |
| （参考）bench/scene3d の部屋 | p50 0.87〜1.14 / p95 1.07〜1.33（診断あり・CPU の submit 相当）・GPU p50 0.19〜0.29 | | |

「塗り avg」（present だけ）は 0.08〜0.16 ms。each は最初の 600 コマ窓 1 つだけ（読み込み 31〜33 秒の後）。

### 3-2. 診断あり（`withDiagnostics` + 1 コマ 1 行 println）の内訳【確】

数は診断あり実行の中央値・n=385〜3118 コマ（最初の 300 コマは捨てた）。CPU の ms は診断の query で膨らんでいる（上記）。

| 場面 | placed/drawn | draw call | submit | swap | **GPU 合計** | GPU scene Pass | CPU 区間 shadows/split/draw | dt |
|---|---|---|---|---|---|---|---|---|
| Tokyo merged aerial3k | 61/61 | 70 | 4.27 | 0.27 | 2.93 | 2.67 | 0.16/0.58/0.46 | 6.03 |
| Tokyo merged street | 61/39 | 75 | 4.07 | 0.23 | 2.72 | 2.40 | 0.20/0.57/0.37 | 5.75 |
| Tokyo merged aerial | 61/43 | 69 | 4.93 | 0.26 | 3.48 | 3.16 | 0.18/0.57/0.40 | 6.48 |
| Ome aerial3k | 272/148 | 152 | 5.02 | 0.26 | 2.88 | 2.46 | 0.21/0.86/0.88 | 6.77 |
| Ome street | 272/142 | 178 | 4.19 | 0.38 | 2.15 | 1.81 | 0.24/0.83/0.82 | 5.77 |
| Tokyo each aerial3k | 12,557/12,557 | 12,566 | 135.8 | 0.30 | 59.8 | 58.9 | 10.3/53.6/67.3 | 50（clamp） |
| Tokyo each street | 12,557/8,390 | 10,881 | 124.6 | 0.29 | 64.1 | 63.0 | 14.9/52.0/53.1 | 50（clamp） |

- post の GPU は 0.08〜0.09 ms・screen 0.2〜0.3 ms・bright 0.04〜0.06 ms。都市の GPU はほぼ scene Pass（影の地図もこの中か別の枠かは gpuPasses の名前に無い=scene に含まれる）。
- 2D の描き物 draw2d = 0。
- 三角形の数（ゲームの書き出し統計）: Tokyo 建物 1,205,234（each も merged も同じ）＋ 地面（ground3k: 道路 26k・公園 12k・線路 1k・水 0.5k・コンクリート 192k = 約 23 万）= **約 144 万**【確・地面は log の合計】／Ome 建物 215,738 ＋ 地形 557,652 = **約 77 万**【確】。実際に描いた三角形（視錐台で間引いた後）の数は取れる口が無い【不明】。
- 物の数: Tokyo merged 61 / each 12,557 / Ome 272（地形 247 を含む）。

### 3-3. GL の呼び出し（`FLIX_GE_GL_LOG`・定常状態 1 コマ）【確】

| 場面 | GL 呼び出しの総数/コマ | うち drawElementsInstanced | uniform 系 | bind 系（VAO・Texture・Sampler・Framebuffer） | useProgram | 備考 |
|---|---|---|---|---|---|---|
| Tokyo merged aerial3k | 956 | 69（＋drawArrays 6） | 約 390（uniform1i 162・1f 152・3fv 33・2f 13・Matrix4fv 11 ほか） | VAO 83・Texture 75・Sampler 74・FB 15 | 13 | prefersGpuMipmap 59 は GL でなく問い合わせ（引くと約 897） |
| Ome aerial3k | 1,907 | 151 | 約 700（1i 321・1f 323） | VAO 165・Texture 163・Sampler 162 | 13 | prefersGpuMipmap 271 |
| Ome street | 1,949 | 177 | 約 730（1i 341・1f 311） | VAO 191・Texture 157・Sampler 156 | 13 | prefersGpuMipmap 271 |
| Tokyo each aerial3k | **125,916** | 12,565 | 約 50,300（1i 25,154・1f 25,144） | VAO 12,579・Texture 12,571・Sampler 12,570 | 13 | prefersGpuMipmap 12,555（引くと約 113,400） |

draw 1 本あたり: each は約 10 呼び出し（uniform1i×2・uniform1f×2・activeTexture・bindVAO・bindTexture・bindSampler・draw・prefersGpuMipmap）。**同じ texture でも毎 draw で bind し直している**（重複除去が無い）。merged は約 13.9 呼び出し/draw（共通の Pass 設定を含む）。useProgram が 13 しかない = プログラムはほとんど替えていない（材質プログラムは少数）。

### 3-4. CPU の時間がどこにあるか（診断なし・jstack 100 回・メイン thread の一番上の frame の分類）【確・安全点の偏りあり】

| 場面 | Flix/JVM コード | LWJGL native（GL 呼び出し） | native の内訳（上位） | Flix の内訳（上位） |
|---|---|---|---|---|
| Tokyo merged aerial3k | 61% | 39% | glBlitFramebuffer 13%・drawElementsInstanced 8%・JNI invoke 約 13%・glDrawArrays 2% | RecordExtend.lookupField 約 19%（record の欄引き）・ShaderGen 9%（inclusive）・Render3d.prepareScenes 22%（inclusive）・View 9% |
| Ome street | 54% | 46% | drawElementsInstanced 15%・glBlitFramebuffer 11%・JNI 約 13%・glfwSwapBuffers 10%（inclusive） | lookupField 約 26%・prepareScenes 21%（inclusive）・ScenePlan 12% |
| Tokyo each aerial3k | 70% | 30% | drawElementsInstanced 26%（それだけで約 35 ms）・bindVAO 2% | lookupField 約 37%・sceneDrawsOf 系 約 14%・RedBlackTree.get 7%・prepareScenes 49%（inclusive）・drawBatch 40% |

inclusive: Render3d 全体は Tokyo merged 40%・Ome street 55%・each 100%（each は 3D の準備と描きだけで 1 コマが埋まる）。

## 4. ブラウザで測れるか【確】

- 都市 2 本とも **`web/WebMain.flix` が無い**。`bin/fge export-web <ゲーム> --check` は即 exit 1:「web/WebMain.flix が無い … テンプレートの web/WebMain.flix を写して入口を書く」（コピーで確認・0.05 秒）。通すにはゲームのソース（入口の追加）が要る。今回は「ソースを直さない」ので行っていない。
- 仮に入口を足しても、Tokyo は glb 124 MB・アトラス 49 枚×2048²（RGBA で 784 MB）・`scene3dTextureBudgetMB 1400`、Ome は 432 MB のアトラス。ブラウザ（WebGL2 の MAX_TEXTURE_SIZE 8192・メモリ）で読めるかは【不明】。
- engine 側の export-web も `bench/scene3d` で試すと「engine_full_web の物が無い（build/web-jar/fge-web-0.94.1.jar）。engine の根で `make sync-engine-full-web` を流す」で止まった（engine の build 生成物を作る手順なので今回は流していない）。
- 1 コマの時間を取る口: `smoke-devtools`・`web-capture`（`?capture=n` で n コマ目の絵を撮る・go/internal/cdp）は**絵と命令口の検査で、時間は測らない**。ブラウザの 1 コマは頁側（`?loadtime=1` や console.time）か、CDP の javascript で rAF の間隔を取る形になる。docs/backend-parity.md の「wasm 1 コマの CPU の中央値」は隠れた内蔵ブラウザの 7 コマで、rAF の回数は測れないと書いてある。
- したがってブラウザの数字は都市では【不明】。参考に既存の数字（上の 1 節）: bench/scene3d wasm 1.3 ms（デスクトップ約 0.9〜1.1 ms）、fps3d_lab の部屋 wasm 16.6 ms（デスクトップ約 8.8 ms。メモリの記録）→ **wasm はデスクトップの約 1.2〜1.9 倍**。

## 5. 内訳の見積もり

前提: 診断なしの間隔を 1 コマの実時間とする。CPU（メイン thread）の割合は jstack、GL の呼び出し数は GL_LOG、GPU は GL_TIME_ELAPSED（診断あり実行の値）。M4 Pro・Apple の GL。

### デスクトップ

| | Tokyo merged aerial3k（61 物・70 draw・約 144 万三角形） | Ome street（272 物・178 draw・約 77 万三角形） | Tokyo each aerial3k（12,557 物・12,566 draw） |
|---|---|---|---|
| 1 コマ（診断なし） | 3.04 ms【確】 | 3.59 ms【確】 | 137 ms【確】 |
| (a) GL の呼び出しの代金（draw・uniform・bind・JNI） | 約 0.3〜0.4 ms【推】（native 39% − blit 13% − swap 約 7% ≒ 19% ≒ 0.6 ms から GPU 待ちを除いた幅。呼び出し約 900 回 × 約 0.36 µs ≒ 0.3 ms と合う） | 約 0.7〜1.0 ms【推】（native 46% − blit 11% − swap 10% ≒ 25% ≒ 0.9 ms。呼び出し約 1,900 回×0.36 µs ≒ 0.7 ms） | 約 41 ms【推】（native 30% × 137 ms。呼び出し約 113,000 回 → 約 0.36 µs/呼び出し・draw 1 本 約 3.3 µs） |
| (b) Flix の CPU の計算（準備・並べ替え・間引き・record の欄引き・View） | 約 1.8 ms【推】（61% × 3.04 ms。診断ありの cpuPhases は split+draw+shadows ≒ 1.2 ms で整合） | 約 1.9 ms【推】（54% × 3.59 ms。cpuPhases 1.9 ms で整合【確】） | 約 96 ms【推】（70%。cpuPhases 合計 131 ms と整合【確】。planScene 系だけで約 67 ms=prepareScenes 49%） |
| (c) GPU の塗り（GL_TIME_ELAPSED・診断あり） | 2.7〜2.9 ms【確】（scene Pass 2.67・post 0.08・screen 0.2） | 1.8〜2.2 ms【確】 | 約 60 ms【確】 |
| 待ち（blit の resolve・swap で GPU を待つ分） | 約 0.6 ms【推】（blit 13% + swap 7%） | 約 0.8 ms【推】 | 不明（CPU が支配的で待ちは隠れる） |

読み方（【推】）:
- **merged の 2 都市は GPU の 2〜3 ms が 1 コマ（約 3 ms）とほぼ同じ = GPU が支配（または CPU と同じ長さ）。CPU は (b) Flix が (a) GL の約 3〜5 倍**。WebGPU で減らせる (a) は 1 コマの約 1〜3 割（0.3〜1.0 ms）で、fps で言えば 330 → 3 割増しが上限。三角形 144 万を描く (c) は WebGPU でも減らない。
- **each（draw 1.2 万本）は完全に CPU 支配（137 ms vs GPU 60 ms）で、(a) は 3 割（約 41 ms）、(b) が 7 割**。WebGPU の render bundle・bind group の持ち越しで (a) の多く（約 41 ms のうち draw 1 本 3 µs・uniform 5 万回・bind 3.8 万回）は減らせる見込みだが、(b) の約 96 ms は残る → 137 ms → 約 100 ms 前後が上限（約 3 割減）【推】。
- GPU 時間が each だけ 60 ms（merged は同じ三角形数で 2.7 ms）なのは、1 draw あたり約 4.6 µs の GPU 側の固定費（Metal の GL ドライバの draw ごとの仕事）が乗っている【推】。ここは WebGPU（draw ごとの検証の少ない Metal 直）で減る可能性があるが、これは測っていない【不明】。
- 「draw 1 本あたりの代金」: each は CPU の submit 全体で 10.8 µs/draw（136 ms / 12,566）、そのうち GL native 約 3.3 µs【推】・Flix の計画（planScene・batch・uniform の組み立て）約 7.5 µs【推】。uniform 1 回あたり・bind 1 回あたりの個別の値は分けて測れていない（native 全体を呼び出し数で割った平均 約 0.36 µs/呼び出しだけ）【推】。
- merged の draw 1 本あたりは 70 draw で割ると 43 µs/draw に見えるが、これは固定の仕事（blit・swap・post・Flix の準備）が混ざっていて意味が無い。
- 診断ありだと 3 ms → 6 ms に倍増する（GPU timer query）。WebGPU 側で同じ timestamp query を使う比較をするなら、**診断なしの FRAME_STATS の間隔**を基準に取ること。

### ブラウザ（WebGL2・wasm）

測れていない【不明】。割り当てる前提だけ書く【推】:
- GL の呼び出しは wasm → JS 越え + ANGLE（Metal）。1 呼び出しはデスクトップの JNI（約 0.36 µs）より重く、数 µs になりうる（出典なしの一般的な見立て）。呼び出し回数は**同じ**（GlContext が同じ）なので、merged は 900〜1,900 回/コマで +1〜数 ms、each は 11 万回/コマで 100 ms 以上になる見込み。draw call 数が効くのはデスクトップより**ブラウザ**側（WebGPU で最も効く所）。
- (b) Flix の計算は wasm でデスクトップの約 1.2〜1.9 倍（既存の bench/scene3d・fps3d_lab の比）→ merged の (b) は 2〜3.5 ms 程度に見込む【推】。
- 都市はブラウザでは WebMain 無し・メモリの問題で今は動かない。比べる土台は bench/scene3d（wasm 1.3 ms・GPU 0.2〜0.3 ms）と fps3d_lab の部屋（wasm 16.6 ms）が既にあり、これらを WebGPU でも流して比べる方が早い。

## 6. 比べる時のおすすめ手順（コードを足さずに取れるもの）

1. 診断なし: `FLIX_GE_FRAME_STATS=1 FLIX_GE_NO_VSYNC=1 FLIX_GE_MUTE=1 START="preset name=aerial3k" make run RUN_SECONDS=50`（ゲームのフォルダで）→ `[frame-stats]` の「間隔 avg」の窓の中央値（最初の窓は読み込み含みで除く）。
2. GL の呼び出し: `FLIX_GE_GL_LOG=<file> FLIX_GE_GL_LOG_FRAMES=40 …` → `--- frame n` ごとに行を数える（`scratchpad/webgpu/tools/glcount.py <file> <n>`）。
3. GPU・CPU 区間・draw call: `App.withDiagnostics` をコピーに足し、`frame#diagnostics` を 1 コマ 1 行 println（`probe/*/src/Probe.flix`・集計は `tools/agg.py`）。ただし測定が 2 倍に重くなる。
4. CPU の割合: jstack 100 回（`tools/prof.sh`・`tools/stk.py`）。
5. 重い比べ相手は Tokyo の `PLATEAU_MODEL=3k_each_2048`（draw 1.2 万本）が WebGPU の効きを見やすい。出荷既定の merged は GPU 支配で差が出にくい。

## 7. 打ったコマンド

```
# 診断なし（元のゲームのフォルダで）
cd ~/Documents/flix_ge_workspace/{plateau_city,ome_city}
FLIX_GE_FRAME_STATS=1 FLIX_GE_NO_VSYNC=1 FLIX_GE_MUTE=1 START="preset name=<aerial3k|street|aerial>" make run RUN_SECONDS=50
# each 版: 前に PLATEAU_MODEL=3k_each_2048 と RUN_SECONDS=130（読み込みに 31〜33 秒）
# GL 呼び出し
FLIX_GE_GL_LOG=<file> FLIX_GE_GL_LOG_FRAMES=40 FLIX_GE_NO_VSYNC=1 FLIX_GE_MUTE=1 START="preset name=aerial3k" make run RUN_SECONDS=75
# 診断あり（コピー: scratchpad/webgpu/probe/<ゲーム>）
FLIX_GE_NO_VSYNC=1 FLIX_GE_MUTE=1 START="preset name=<名前>" make run RUN_SECONDS=30..150
# 軽い比べ相手
cd /Users/abab/Desktop/flix_game_engine/bench/scene3d && FLIX_GE_MUTE=1 make run
# ブラウザの確認
bin/fge export-web <コピーの ome_city> --check --work <scratch>      # → web/WebMain.flix が無い
bin/fge export-web bench/scene3d --out <scratch> --work <scratch>    # → engine_full_web の jar が無い
```

生ログと集計スクリプト: `/private/tmp/claude-501/-Users-abab--claude-spares-spare-q72Ibn/1e409b86-520d-4126-86d6-d8af78577988/scratchpad/webgpu/{logs,tools,probe}`。

## 8. 注意・限界

- 時間は 1 回の長い実行の中央値で、機械の熱・他セッションの負荷（測定中に別セッションの rpg-starter が走っていた時間帯あり）で数 % 揺れる。
- jstack の割合は安全点の偏りがある（Flix 側が過大・native が過小になりうる）。
- (a) の「約 0.36 µs/呼び出し」は native 全体の割合を呼び出し数で割った平均で、draw と uniform の単価は分離していない。
- 実際に GPU が描いた三角形の数・uniform の byte 数は取れていない。
- GL_LOG は GlContext 経由の呼び出しのみ（LWJGL を直接呼ぶ所があれば漏れる）。
- 元のゲームと engine のリポジトリには差分を残していない（ビルドの生成物 `build/`・`debug/` のみ）。
