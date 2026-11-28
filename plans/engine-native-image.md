# GraalVM の native image を engine に入れる計画（11-26 の計測から）

人の決め（11-26）: 「今すぐやって、計測しよう」「ビルドは遅くなるので前後合わせての計測」。
この計画は、組む時間と流す時間を合わせた合計で、native が JVM を上回る所にだけ native を使う、を軸に決める。

## 0. 結論（先に）

1. **macOS の手元の確かめ（render-all・テープの比べ・gl-parity の SoftRaster 側）は native にできない。**
   SoftRaster・HeadlessFont・HeadlessLoad・Filmstrip・VideoOut が AWT（BufferedImage・Graphics2D・Font・ImageIO）の上にあり、
   macOS の native image は libawt を読めない（`BufferedImage` の static 初期化で `UnsatisfiedLinkError: awt`。
   JDK の libawt.dylib を隣に置いても libjvm に依存していて読めない。2 つとも小さな Java で確かめた）。
   11-26 の「1 回組んで何度も流す確かめは native」という見込みは、macOS では成り立たない。
2. **native が効くのは「窓を開くゲーム」だけ。** night_school の階段は 1 コマ 2.94 → 1.32（native）→ 0.99 ms（PGO）・
   RSS 1.66 → 0.64 → 0.44 GB・起動 2.6 → 1.8 → 1.6 s。Bistro の夜は GPU で詰まっていて 1 コマは変わらず（4.0 / 4.1 / 4.2 ms）、
   RSS だけ 8.2 → 3.1 / 3.0 GB に減る。native（PGO なし）の Bistro は glb の読み込みが JIT より遅く、起動は 11.5 → 14.0 s と**遅くなる**。
3. **ビルドの時間込みでは、手元の確かめで native は元が取れない。** native の道は jar の上に「metadata の収集（tracing agent で 1 本流す）18〜24 s +
   native-image 96〜130 s」、PGO はさらに「instrumented build 118〜272 s + プロファイルを取る 12〜34 s + PGO で組み直す 92〜116 s」。
   night_school の 1 本の流しで縮むのは 4.4 s（PGO 5.2 s）なので、同じビルド成果物を **31 回目（PGO 47 回目）** に流した時にやっと JVM を上回る。
   「1 行直して流す」で毎回組み直す流れでは、何回流しても上回らない（1 回あたり 110 s 以上の損）。
4. **だから native は「配る物」（dist-macos など・遊ぶ人が何百回も起動する）にだけ使う。** 配る物の根拠は起動・RSS・JRE を束ねなくてよい点
   （遊ぶ人は 60 fps の上限で回すので、1 コマの縮みは時間ではなく余裕として効く）。開発の門には入れない。
5. **普段の短い確かめは、JVM の旗の `-XX:+UseSerialGC` だけ採る。** SerialGC だけを足して測った render-all は 1 本の時間が +1〜2 %（雑音の内）で、
   RSS は 1/3〜1/6（5.1 → 0.8 GB・6.7 → 2.2 GB）。4 本並べた壁の秒は縮んだ（1 回の測り・23.7 → 20.9 s・37.6 → 31.4 s）、
   同時の RSS は 28.7 → 3.1 GB・37.7 → 8.9 GB（2.3 節）。
   `-XX:TieredStopAtLevel=1` は render-all を **1.6〜3.2 倍遅く**するので採らない。CDS（AutoCreateSharedArchive）は測って差が出なかった（雑音の内）ので採らない。
   `-Xmx2g` は Bistro で OutOfMemoryError になったので、一律の上限にしない。
6. (a)(b) は入れた（枝 `worktree-agent-ad4f5bdc273839871` の 95467c3ac）。**ただし Bistro（JPEG 393 枚）で画素の差が出た**ので、main へ入れる前に人の判断が要る（7 節の 3）。

## 1. 計測の条件

- 機械: M4 Pro・macOS 27.0.1。JVM は devbox の Zulu 25.0.3（普段の道と同じ）。native は Oracle GraalVM 25.0.4（~/tools/graalvm）。
- engine: 0.115.0 の枝（7a6e7f69d）に (a)(b) を入れた 95467c3ac。ゲームは build/ni/games/ に写した night_school と bistro_lab をこの engine で組んだ
  （bistro_lab は別の枝にしか無い `Scene3d.withSkyContribution` の 1 行だけ外した。夜は 0.0 を渡す所なので夜の絵には効かない）。
- **他の担当の仕事が並んで走っていて、load average は 10〜110 だった。** 値の幅が広い所は幅も書く。比べる物は 1 周ごとに交互に流して、雑音を両方へ散らした。
- ゲームの 1 コマ: 隠した窓（`FLIX_GE_HIDDEN=1`・中間の texture は design の大きさ。night_school 320×240・Bistro 960×540）・`FLIX_GE_FIXED_DT=1/60`・音なし。
  Bistro の差の表（plans/engine-bistro-gap.md）は見える 1920×1080 の窓で測っているので、GPU の値はそろわない（CPU 側の比べには足りる）。
  1 コマの値は RenderFrameStats の窓を 600 → 1 コマに書き換えた jar（スパイクと同じ）で取り、601 コマ目からの中央値。
  - night_school: 中央の階段を 1 階から 3 階まで上る台本（e2e/stairs.flow と同じ手・1,811 コマ）。
  - Bistro: `START="shot name=street night=1 hud=0"` で 30 秒（1,799 コマ）。
  - 「1 本の流し」は、隠した窓で vsync をかけずに台本を回し切った壁の秒（遊ぶ時の長さではない）。
- ビルドの時間は 2 回ずつ組んだ。生ログ（build/ni/logs/build_*.log）は 2 回目で上書きしたので、1 回目の値はその時の画面の出力から写した
  （night_school の instrumented build 118 s・Bistro の native-image 96 s と instrumented build 120 s が 1 回目。2 回目はそれぞれ 272 s・130 s・140 s）。
- 3 回ずつ（AWT と stb の比べは 5 回ずつ）の中央値。各通りの前に 1 回空回しする。
- 置き場: 道具と生ログは `<枝>/build/ni/`（tools/・logs/・config/・profiles/）。

## 2. 測った値

### 2.1 ゲーム（JVM・JVM の旗・native・PGO）

| | 起動（最初のコマが出た時刻） | 1 コマ p50 | 1 コマ p99 | RSS | 1 本の流し（台本の終わりまで） |
|---|---|---|---|---|---|
| night_school 階段・JVM（普段の旗） | 2.61 s [2.16–2.79] | 2.94 ms [2.92–3.09] | 4.95 ms | 1.66 GB [1.36–1.88] | 8.85 s [8.80–9.45] |
| 同・4 つ全部（Serial + C1 + Xmx2g + CDS） | 3.58 s [3.10–3.67] | 2.82 ms [2.66–3.24] | 5.44 ms | 0.89 GB | 10.30 s [9.50–10.77] |
| 同・native | 1.84 s [1.64–2.01]（×1.4） | 1.32 ms [1.28–1.44]（×2.2） | 2.64 ms | 0.64 GB [0.45–0.67]（×2.6） | 4.50 s [4.21–4.84]（×2.0） |
| 同・native + PGO | 1.61 s [1.44–1.62]（×1.6） | 0.99 ms [0.98–1.02]（×3.0） | 1.80 ms | 0.44 GB [0.44–0.44]（×3.8） | 3.69 s [3.52–3.71]（×2.4） |
| Bistro 夜・JVM | 11.54 s [11.28–11.61] | 4.02 ms [3.96–4.05] | 5.03 ms | 8.24 GB [6.16–8.54] | 19.21 s [19.14–19.26] |
| 同・4 つ全部 | — | — | — | — | Xmx2g で OutOfMemoryError |
| 同・native | 13.99 s [13.21–14.50]（×0.82） | 4.08 ms | 5.21 ms | 3.07 GB [2.93–3.48]（×2.7） | 21.53 s [20.65–21.94]（×0.89） |
| 同・native + PGO | 10.48 s [10.14–11.17]（×1.1） | 4.18 ms | 5.35 ms | 2.98 GB [2.90–4.00]（×2.8） | 18.00 s [17.79–18.81]（×1.07） |

JVM の旗を 1 つずつ足した比べ（上の表と別の時間帯。同じ回の普段の旗と並べる）:

| night_school 階段 | 起動 | 1 コマ p50 | 1 コマ p99 | RSS | 1 本の流し |
|---|---|---|---|---|---|
| 普段の旗（その回） | 2.93 s | 3.13 ms | 5.28 ms | 1.76 GB | 10.09 s |
| SerialGC | 2.38 s | 3.02 ms | 5.61 ms | 0.97 GB | 8.93 s |
| TieredStopAtLevel=1 | 3.80 s | 3.40 ms | 6.64 ms | 2.06 GB | 11.19 s |
| CDS | 2.36 s | 3.40 ms | 6.60 ms | 1.80 GB | 9.87 s |

- Bistro の glb の読み込み（`[bistro] glb を読んだ`）: JVM 7.3 s・native 8.9 s・PGO 6.9 s。JIT の無い native は重い解読で負け、PGO で取り戻す。
- Bistro の 1 コマは 3 通りとも 4 ms 前後（GPU を待つ時間が大半）。native が効くのは CPU で詰まる場面だけ。

### 2.2 CPU の描き出し（render-all・JVM だけ。native は 0 節の 1 で作れない）

| テンプレート | 旗 | 全体 | 最初の 1 枚まで | 1 枚あたり | RSS |
|---|---|---|---|---|---|
| retro3d-horror-starter（16 場面） | 普段 | 8.19 s | 2.38 s | 0.33 s | 4.67 GB |
| | SerialGC + Xmx2g | 8.85 s | 2.70 s | 0.38 s | 0.77 GB |
| | TieredStopAtLevel=1 | 26.25 s | 2.92 s | 1.19 s | 6.21 GB |
| | CDS | 8.48 s | 2.38 s | 0.36 s | 5.35 GB |
| | 4 つ全部 | 19.64 s | 2.49 s | 0.93 s | 0.86 GB |
| hd2d-starter（4 場面） | 普段 | 11.54 s | 5.30 s | 1.74 s | 8.73 GB |
| | SerialGC + Xmx2g | 10.95 s | 4.08 s | 1.87 s | 2.14 GB |
| | TieredStopAtLevel=1 | 18.55 s | 5.84 s | 4.11 s | 6.21 GB |
| | CDS | 12.53 s | 5.33 s | 2.23 s | 7.33 GB |
| | 4 つ全部 | 28.85 s | 6.00 s | 7.40 s | 2.11 GB |

`FGE_RENDER_CACHE=off`・jar は先に作った物（bin/headless-run SceneRender.all を直に流した）。

SerialGC だけ（Xmx なし）を後で同じ回の普段の旗と並べて測り直した値:

| テンプレート | 旗 | 全体 [幅] | 最初の 1 枚まで | 1 枚あたり | RSS |
|---|---|---|---|---|---|
| retro3d-horror-starter | 普段（その回） | 8.63 s [8.55–13.16] | 2.65 s | 0.36 s | 5.13 GB |
| | SerialGC だけ | 8.75 s [8.72–8.95] | 2.38 s | 0.39 s | 0.80 GB |
| hd2d-starter | 普段（その回） | 10.85 s [10.07–15.78] | 4.66 s | 1.92 s | 6.71 GB |
| | SerialGC だけ | 11.02 s [10.47–12.30] | 4.52 s | 1.96 s | 2.21 GB |

### 2.3 並べて流した時のメモリ（render-all を 4 本同時）

| | 壁の秒 | 4 本の最大 RSS の和 | 同時に数えた RSS の最大 |
|---|---|---|---|
| retro3d・普段 | 31.5 s | 26.5 GB | 25.2 GB |
| retro3d・SerialGC + Xmx2g | 27.9 s | 2.9 GB | 2.9 GB |
| hd2d・普段 | 37.8 s | 32.7 GB | 30.2 GB |
| hd2d・SerialGC + Xmx2g | 50.7 s | 8.4 GB | 8.4 GB |
| （後の回）retro3d・普段 | 23.7 s | 28.7 GB | 28.7 GB |
| （後の回）retro3d・SerialGC だけ | 20.9 s | 3.1 GB | 3.1 GB |
| （後の回）hd2d・普段 | 37.6 s | 39.6 GB | 37.7 GB |
| （後の回）hd2d・SerialGC だけ | 31.4 s | 8.9 GB | 8.9 GB |

普段の旗の `-XX:MaxRAMPercentage=50` は 1 本ずつが物理メモリの半分まで膨らむのを許すので、並べると足し算で溢れる。
最初の回の hd2d・SerialGC + Xmx2g の 50.7 s は load average が 110 まで上がった回で、SerialGC だけで測り直した後の回は普段より速かった（31.4 s）。
`-Xmx2g` を付けずに済むので、段 4 は SerialGC だけにする。
native の並べた時のメモリは、ゲーム 1 本の RSS（2.1 節）が 1/2.6〜1/3.8 なので同じ割合で減る見込み（4 本並べては測っていない）。

### 2.4 テープの比べ（sound-novel-starter・e2e/tape.flow 1 本・CPU で塗る・23 コマ）

`bin/fge migrate shoot … --jobs 1 --no-resident --full --paint cpu`（`-Xmx3g` は shoot が付ける）。

| 旗 | 1 本 | RSS |
|---|---|---|
| 普段 | 11.9 s [6.7–12.2] | 2.28 GB |
| SerialGC | 9.6 s [9.4–12.8] | 0.74 GB |

FlowVideo は SoftRaster と ImageIO の上なので native にできない（GPU で塗る道も VideoOut・GpuShot が AWT を使う）。

### 2.5 gl-parity の SoftRaster 側

`make -C bench/gl_parity cpu-time`（ParityMain.timeSoft・76 場面）: 描く時間の和は 0.7〜1.0 s で、全体の 20.6〜24.8 s の大半は
`bin/flix run` のコンパイルと JVM の立ち上げ。SoftRaster の描く所を native にしても縮むのは 1 s 未満で、そもそも AWT で作れない。
`make gl-parity`（GL と SoftRaster を突き合わせる門）は全体 17.5 s。

### 2.6 組む時間

| 段 | night_school | Bistro | テンプレート |
|---|---|---|---|
| flix の jar（headless-run --build-only・FGE_JAR_CACHE=off） | 22〜29 s | 23〜37 s | 17〜28 s |
| metadata を取る（tracing agent で 1 本流す） | 17.7 s | 24.2 s | — |
| native-image | 114〜119 s | 96〜130 s | — |
| instrumented build（--pgo-instrument） | 118〜272 s | 120〜140 s | — |
| プロファイルを取る（1 本流す） | 11.6 s | 33.9 s | — |
| PGO で組み直す | 91.5 s | 116 s | — |
| native-image の RSS | 5.7〜6.1 GB（instrumented build 6.4〜9.2 GB） | 4.9〜5.4 GB（instrumented build 8.0〜8.7 GB） | — |

native-image は `-J-Xmx14g --parallelism=8`。instrumented build の 272 s は load average 40 の回で、静かな時は 118 s。
metadata（reachability-metadata.json）は 5 KB で、Flix の生成物はほとんどリフレクションを使わない（LWJGL・jWebGPU の JNI と resource が主）。

### 2.7 普段の JVM で AWT の版と stb の版を比べる（(a) の効き目）

AWT の版 = 95467c3ac の親・stb の版 = 95467c3ac。同じ場面・同じ旗で交互に 5 回（空回し 1 回）の中央値 [最小–最大]。

| | 起動（最初のコマ） | ゲームの読み込み（gamepad の行 → 最初のコマ） | glb の読み込み | 絵 1 枚（1 スレッド・Bistro の 405 枚） | RSS |
|---|---|---|---|---|---|
| night_school・AWT | 3.13 s [2.40–8.45] | 2.33 s [1.70–5.76] | （行が無い） | — | 1.69 GB |
| night_school・stb | 2.40 s [2.10–8.26] | 1.68 s [1.45–5.06] | （行が無い） | — | 1.57 GB |
| Bistro 夜・AWT | 15.45 s [12.66–17.71] | 14.22 s [11.92–15.71] | 10.58 s [8.46–12.03] | 9.1 ms（405 枚で 3.67 s） | 8.57 GB |
| Bistro 夜・stb | 11.86 s [10.56–14.03] | 10.90 s [9.62–12.54] | 6.99 s [5.97–7.51] | 2.6 ms（405 枚で 1.05 s） | 9.38 GB |

- 絵 1 枚の列は、glb から抜いた 405 枚（JPEG 393・PNG 12・43 MB）を 1 スレッドで 6 周解いた中央値（build/ni/tools/DecodeBench.java）。stb は **3.4〜3.5 倍速い**（1 枚の中央値 9.1 → 2.6 ms・合計 3.67 → 1.05 s）。
  ゲームの中では LoadProgress の pool（CPU の数のスレッド）で並べて解くので、glb の読み込みの縮みは 3.6 s。
- night_school の project.json の絵（LwjglAssets.loadTexture）は前から stb で、変わったのは glb の中の絵だけ。
- 両方の 8 s 台の外れは load average が上がった回。中央値で読む。
- RSS は stb の版がやや大きい（ネイティブのメモリに入力の写しと解いた画素を置く分）。幅の内にも入るので、言えるのは「減らない」まで。
- 画素: night_school は 96 コマ全部一致。Bistro は差が出た（7 節の 3）。

## 3. 損益分岐（組む時間込み）

合計 = 組む時間 + N × 1 本の流し。jar は JVM と native の両方に要るので差には入らない。
「native の追加」= metadata の収集 + native-image。「PGO の追加」= metadata の収集 + instrumented build + プロファイル + 組み直し（native を別に組まない道）。

| 流す物 | JVM の 1 本 | native の 1 本 | PGO の 1 本 | 1 回だけ流す時の合計（JVM / native / PGO） | native が上回る回 | PGO が上回る回 |
|---|---|---|---|---|---|---|
| night_school 階段の台本 | 8.85 s | 4.50 s | 3.69 s | 34 / 161 / 268 s | **31 回目** | **47 回目** |
| night_school 起動して最初のコマを見るだけ | 2.61 s | 1.84 s | 1.61 s | 28 / 157 / 265 s | 172 回目 | 239 回目 |
| Bistro 夜の 30 秒 | 19.2 s | 21.5 s | 18.0 s | 49 / 206 / 342 s | 上回らない | 200〜300 回目 |
| render-all（retro3d・hd2d） | 8.2 s・11.5 s | 作れない | 作れない | — | — | — |
| テープの比べ 1 本 | 11.9 s | 作れない | 作れない | — | — | — |
| gl-parity の SoftRaster 側 | 20〜25 s（描くのは 1 s 未満） | 作れない | 作れない | — | — | — |

- 数えた値: jar は night_school 25 s・Bistro 30 s。native-image は 2 つとも 2 回目の値（night_school 114 s・Bistro 130 s）。
  instrumented build は静かな時の 1 回目（118 s・120 s）。load average が高い回（272 s）を使うと PGO の回数は 47 → 77 回目になる。
- 回数は「追加のビルド時間 ÷ 1 本あたりの縮み」を切り上げた物（night_school native: 131.7 / 4.35 = 30.3 → 31 回目）。
  Bistro の PGO は 1 本あたりの縮みが 1.2 s と小さく、雑音（load average 10〜110）で大きく動くので幅で書いた。

### 作業中の「1 行直して流す」

- **組み直しが毎回要る場合**（src か engine を直した）: JVM は 1 回 jar 25 s + 流し 9 s = 34 s。native は jar 25 s + native-image 114 s + 流し 4.5 s
  = 144 s（metadata を使い回しても）。**毎回 110 s 損をし、何回流しても上回らない。** PGO はさらに 200 s 以上の損。
  前提: GraalVM の `-Ob`（quick build）と layered image（engine の分を先に組んでおく）は試していない。どちらかで native-image が
  20〜30 s まで縮むなら、この結論は変わりうる（段 6 で 1 回だけ測る）。
- **組み直しが要らない場合**（engine もゲームも変えずに、同じビルド成果物を何度も流す。テープの比べ・bench の繰り返し・同じ版で何十本も flow を流す）:
  ゲームの流しなら 31 回目（PGO 47 回目）で上回る。ただし macOS では、今この形で何度も流している物（テープの比べ・render-all・gl-parity）が
  すべて AWT の上で、native にできない。今の時点で当てはまるのは「窓を開くゲームを同じ版で何十回も起動する」物だけ。

## 4. どの門で native を使うか

| 門・口 | native を使うか | 根拠 |
|---|---|---|
| render-all・reference-check・compare・テープ（migrate shoot・tape）・gl-parity・determinism の再生・テスト | 使わない | macOS で作れない（AWT）。作れても毎回組み直す門で、3 節のとおり元が取れない |
| gl-capture-check・webgpu-v1-check（窓を開く門） | 使わない | 1 回ずつ組み直す門。流すのは 1〜2 本 |
| 遊ぶ確かめ（make run・debug） | 使わない | 毎回組み直す。起動の縮み 0.8 s では 172 回目でやっと上回る |
| **配る物（dist-macos・将来 dist-windows / dist-linux）** | **使う（PGO まで）** | 遊ぶ人が組まずに何百回も起動する。RSS 1.7 → 0.44 GB・JRE を束ねなくてよい。組む 4〜5 分は配る時の 1 回だけ |
| bench の繰り返し（同じビルド成果物で 31 回以上流す計測） | 今は口を作らない（段 2 の `bin/fge native build` の成果物を手で流せば足りる） | night_school 型の CPU で詰まる場面なら 31 回目で上回る。Bistro 型の GPU で詰まる場面は上回らない。使う物が出てから口を足す |
| agent-eval | 使わない | 時間の主は LLM。ゲームの起動は 1 お題に数回 |

普段の短い確かめ（headless の描き出し・テープ・テスト）には、native の代わりに `-XX:+UseSerialGC` を入れる（5 節の段 4）。

## 5. 段

| 段 | 中身 | 終わりの印 | 目安 |
|---|---|---|---|
| 0（済） | (a) デスクトップの絵の読み込みと FLIX_GE_FRAME_SHOT の書き出しを stb へ (b) native では起動し直さない | 95467c3ac・gl-capture-check 54 枚が直す前と画素で一致・gl-parity 緑 | 済 |
| 0.5 | **JPEG の画素の差をどうするか人が決める**（7 節の 3 の 3 案） | 決めた案が入り、Bistro の撮り物が決めた側とそろう | 1〜2 時間 |
| 1 | `bin/fge native config`: tracing agent（native-image-agent）を付けた jar で決めた台本（`--flow`）を流し、`<ゲーム>/native/reachability-metadata.json` に足し込む（config-merge-dir） | night_school・Bistro で metadata が取れ、git に入る。ゲームへ配る口なので `agents-pack/AGENTS.core.md` の早見表に 1 行・`agents-pack/agent-eval/engine.json` にお題 1 本を足し、ゲームの足元で `make agent-eval ONLY=<お題>` が当たる | 2〜3 時間 |
| 2 | `bin/fge native build [--pgo]`: headless-run の jar から native-image を組む。`--pgo` は instrumented build → 台本でプロファイルを取る → 組み直すを続けて流す。GraalVM の場所は `GRAALVM_HOME`（無ければ止めて取り方を 1 行）。組んだ後に同じ台本を 1 本流す（metadata の漏れは流すまで分からないため）。プロファイル（.iprof・17〜18 MB）は git に入れず、`build/native/` に置いて組むたびに取り直す（版ごとにずれるため） | `build/native/<ゲーム>/<ゲーム>` が台本を最後まで流し、`FLIX_GE_FIXED_DT` と `FLIX_GE_FRAME_SHOT` で撮った頭の 64 コマが JVM の版と画素まで一致する（night_school は必ず比べる。Bistro は 7 節の 3 で (ii) を選んだ時だけ比べ、(i) の時は JPEG を使わない場面で比べる）。早見表 1 行とお題 1 本（段 1 と同じ） | 3〜4 時間 |
| 3 | `make dist-macos NATIVE=1`: 2 の物を dist の形に束ねる（JRE の代わりに 1 本の実行ファイル・assets は今の DIST_INCLUDE のまま）。F8 の注釈は native では落ちる（7 節の 2）ので、配る物では F8 の口を切る。LWJGL・jWebGPU の native library を実行時に取り出す先と、codesign・notarization・Gatekeeper の扱いを決める | Java の無い Mac で起動し、F8 を押しても落ちない（人が確かめる）。早見表の dist の行に NATIVE=1 を足し、お題 1 本 | 3〜4 時間 |
| 4 | headless の JVM の旗に `-XX:+UseSerialGC` を足す（bin/headless-run の窓なしの道・migrate shoot・tape）。`MaxRAMPercentage` は残す（Bistro が 2 GB で落ちたので上限を一律にしない） | 旗を入れた後に 2.2・2.3 節の物差し（render-all 1 本と 4 本並べ・テープ 1 本）で前後を測り、1 本の時間が普段の旗の +10 % 以内・4 本並べた同時の RSS が 1/3 以下（今の測りでは 1/4.2〜1/9） | 1〜2 時間 |
| 5 | Linux の CI（ubuntu-latest）で SoftRaster の native を 1 回だけ測る（Linux の native image は AWT が使える）。CI に GPU は無いので gl-parity の GL 側と窓の門は測れない | render-all の native の値とビルドの時間が出る。上回る回が小さければ CI の render-all だけ native にする案を立てる | 2〜3 時間（スパイク） |
| 6 | `-Ob`（quick build）と layered image で native-image の時間がどこまで縮むかを 1 回だけ測る | 「1 行直して流す」の損益（3 節）を測り直し、上回るなら 4 節を見直す | 1〜2 時間（スパイク） |

段 1〜3 は engine の口（fge・make）を足す拡張なので、入る前に人と相談する（AGENTS.md の決まり）。段 4 は旗だけ。

## 6. Windows と CI

- **Windows は未確認。** GraalVM の native image は Windows で AWT を使え、MSVC（Visual Studio の Build Tools）が要る。
  LWJGL・jWebGPU の DLL の取り出しと、Studio に束ねる形は確かめていない。段 3 の後に dist-windows の native を 1 回組んで、起動と RSS を測る。
- **CI**: 今の CI（release.yml・ubuntu-latest）は配る物を作らない。native を CI で組むと 1 ゲーム 1 機種で 4〜8 分と RSS 6〜9 GB
  （GitHub の標準のランナーは 16 GB）。門には入れず、配る時の手動の口（段 3）か、段 5 のスパイクだけにする。

## 7. native で動かなかった所・残る穴

1. **SoftRaster 一式（render-all・テープ・gl-parity・migrate・VideoOut・GpuShot）**: macOS では AWT が無く作れない（0 節の 1）。
   AWT を外すには Graphics2D の塗り・Font の字形・ImageIO の PNG 書き出しを置き換える必要があり、大きな仕事なので今はやらない（段 5 の結果を見て決める）。
2. **F8 の注釈（frameImage → imageOf）と GpuOffscreen.readImage**: BufferedImage のまま。native では F8 を押すと落ちる。開発の口なので配る物では切る。
3. **JPEG の画素の差（(a) で入った）**: stb と ImageIO の JPEG の解き方（IDCT と色の変換の丸め）が違い、Bistro の夜で 96 コマ全部が
   6,342 画素（960×540 の 1.2 %）・最大 ±22 違う。同じ版どうしの撮り直しは画素まで一致したので、解き方の違いだけが原因。
   PNG だけの night_school と gl-capture-check の 54 枚は一致。CPU の描き出し（HeadlessLoad）は ImageIO のままなので、
   **JPEG の絵を貼った 3D は、GPU の窓と CPU の描き出しで画素がずれる**。案:
   - (i) デスクトップも JPEG だけ ImageIO に戻し、native の時だけ stb にする（JVM の絵は前と同じ・native だけ JPEG がずれる）
   - (ii) HeadlessLoad も stb にそろえる（GPU と CPU が同じになる。JPEG を使うゲームの gallery の基準が変わるので `make reference-update` が要る）
   - (iii) 差を受け入れる（GPU の窓と CPU の描き出しの JPEG の差は残る）
   推しは (ii)（解く速さ 3.4 倍も CPU 側に入る）。基準の更新を伴うので人が決める。
4. metadata（reachability-metadata.json）の漏れは組む時ではなく流す時に落ちる。段 2 で組んだ後に台本を 1 本流すのはそのため。
5. native（PGO なし）は重い解読（glb）で JIT に負ける。配る物は PGO まで組む。

## 8. 計測に使った物

- `<枝>/build/ni/tools/`: run.sh（ゲーム）・games.sh（3 周を交互に）・build.sh（native-image）・render.sh / renders.sh（render-all）・par.sh（並べた時のメモリ）・
  tape.sh（テープ）・awtstb.sh（AWT と stb）・DecodeBench.java（絵 1 枚の解く時間）・PixDiff.java（画素の比べ）
- `<枝>/build/ni/logs/`: 生ログ。値の集計は ~/tools/graalvm-spike/analyze.py（スパイクの物）と各スクリプトの中の python

## 人の決め（2026-11-26）

- 普段の JVM の `-XX:+UseSerialGC` は窓なしの描き出し・テープの比べ・常駐にだけ付けた（main 36ba0c7eb。窓ありの make run とコンパイラには付けない）。
- stb は案 (ii)（HeadlessLoad も stb にそろえる）で main に入れた（432662ba1・780cd2ff2・fc3f4c472・95f3c303c）。
- 「おすすめ案で」: native image は配る物（dist）にだけ使い、開発の門には入れない。dist に入れる段は配る時に改めて計画する。
