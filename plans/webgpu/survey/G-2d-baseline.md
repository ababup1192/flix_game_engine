# G: 2D の描き手の「速くする余地」の実測（M4 Pro・GL 3.3・vsync off）
【確】=この機械で測った/GL の呼び出しログから数えた 【推】=割り算・読んだ事からの見立て 【不明】=測れなかった
engine = /Users/abab/Desktop/flix_game_engine（追跡ファイルの差分 0）。ゲームの依存は 0.94.1（flix.toml の pin。scratch の stress も同じ版を取った）。

## 1. 既にある数字と測る口
| 物 | 中身 |
|---|---|
| 口: `FLIX_GE_FRAME_STATS=1` | 600 コマごとに「塗り」(= renderCommands の submit・Frame.renderFrameMixed と GL 呼び出し) と「間隔」(コマ→コマ全体)の avg/p99 を println。GPU は含まない（docs/performance.md §11） |
| 口: `App.withDiagnostics` → `FrameDiagnostics` | submitNs・swapNs・gpuNs(1〜2 コマ遅れ)・drawItems(sprite+polygon+タイル層の数)・3D の drawCalls。**2D の draw call 数は無い**。F3 の表示はゲーム側が `summaryLines` を描く物で、3 テンプレとも withDiagnostics を使っていない |
| 口: `FLIX_GE_GL_LOG=<file>` `FLIX_GE_GL_LOG_FRAMES=n`（0.85.0〜） | 実機の GL 呼び出しを起動+頭の n コマ 1 行ずつ記録（RecordingGl）。**今回 2D の draw call 数・run の割れ目の唯一の取り方**。ただし頭のコマだけ（`SHOT=<場面> make run` の F8 停止状態と組む） |
| 口: `gallery/<場面>.items.tsv` | 描き物の総数（タイル・静的層は CPU 投影で混ざる）。render-budget が 2000 個で止める |
| bench/sprite_stress/RESULTS.md | 同一テクスチャ 1 run・半分単色箱+SDF 文字 300 字。N=500:3.1ms→N=10000:18.7ms(53fps)、N=5000:9.6ms。ソートが 8 割だった→counting sort(stableByZ)で 25〜37 倍。インスタンス化単独は効果ゼロ（GL は脇役）。HUD 付き 10000: 22.8ms |
| 同 R2b | 人型 1 体 18 box の列 vs 1 クアッド(アトラス): N=1900 で 54.6ms vs 8.3ms（polygon 列の CPU が支配） |
| bench/texture_upload | 320x240x2 枚の毎コマ上げ直し 0.68ms（ドライバ転送） |
| plans/engine-sort-quadratic.md | 2D でなく 3D(Render3d.inDrawOrder)の話。標準 sort が最悪二乗（2,000 物 46〜52ms→13ms） |
| plans/engine-browser-spikes.md | ブラウザ(WebGL2/WASM): rpg 戦い 1 コマ 3.1〜3.3ms・GL 呼び出し 47 回/コマ 0.05ms。GL の 1 万 instance 書き上げ 0.93ms(JVM)/3.26ms(WASM)。internet_dungeon 戦い Android 17.1ms で View(ゲーム側)が主。JVM は 8000B 超の関数を JIT しない（Render.drawInto で超える）→ 旗で 35% 減の報告・人の決定「コードで直す・時期は後」 |
| plans/device-check-0.81.md / engine-core-polish.md | 実機確認チェックリスト・C9(インスタンス描きを GL の層の整理に含める)の計画。2D の数字は無し |
| docs/backend-parity.md | 絵の一致表。2D の速さの数字は無し |
| bench/crowd2d | 敵 6000/10000 の 1 コマ・規則・submit・swap・GPU（make crowd2d-bench）。今回は未実行 |

## 2. テンプレートの実測
方法: `SHOT=<場面> FLIX_GE_FRAME_STATS=1 FLIX_GE_NO_VSYNC=1 FLIX_GE_MUTE=1 FLIX_GE_GL_LOG=<f> FLIX_GE_GL_LOG_FRAMES=8 make run RUN_SECONDS=20`（窓あり・1 本ずつ）。draw 数は GL ログの frame 4（frame 1〜7 は全場面で同数）を `g2d/analyze.py` で数えた。ms は 600 コマ窓の最後 5 本の平均。
注意: SHOT は gallery の World を F8 で止めた状態（動かない絵の 1 コマを繰り返し描く）。歩き・戦いの遷移中は測っていない。GPU ms はテンプレに withDiagnostics が無いので【不明】（下の stress では取れた）。

| 場面 | draw | 内訳 | 描き物(sprite inst+poly 三角形) | 使ったテクスチャ数 | bufferData 回数 | 塗り avg/p99 ms | 間隔(全体) avg/p99 ms |
|---|---|---|---|---|---|---|---|
| rpg title | 7 | spr 7 | 62 | 4 | 7 | 0.48/2.07 | 0.84/2.75 |
| rpg village | 8 | tile 2 + spr 6 | 45 (+タイル 346+31 マス=gallery 422) | 3 | 6 | 0.41/0.55 | 0.76/1.01 |
| rpg world | 3 | tile 1 + spr 2 | 42 (+タイル) | 2 | 2 | 0.36/0.49 | 0.75/0.93 |
| rpg battle | 12 | spr 12 | 245 | 5 | 12 | 0.46/0.63 | 1.39/1.85 |
| tidepool title | 96 | poly 84・spr 5・面/静的 7 | 8,252 (poly 三角形 8,134) | 3 | 89 | 4.60/8.39 | 8.94/16.48 |
| tidepool play | 140 | poly 115・spr 18・面/静的 7 | 9,653 (三角形 9,419) | 3 | 133 | 6.70/10.73 | 12.85/24.70 |
| tidepool flood | 174 | poly 147・spr 20・面/静的 7 | 10,330 (三角形 10,053) | 3 | 167 | 6.30/9.79 | 12.23/20.88 |
| novel title | 6 | spr 4・poly 1・面 1 | 44 | 2 | 5 | 0.88/1.87 | 1.25/2.77 |
| novel adv | 7 | spr 4・poly 2・面 1 | 88 | 2 | 6 | 0.81/1.79 | 1.25/2.47 |
| novel nvl | 6 | spr 4・poly 1・面 1 | 256 (文字 ≈250) | 2 | 5 | 1.15/2.15 | 2.08/3.53 |
| novel choice | 9 | spr 6・poly 2・面 1 | 127 | 2 | 8 | 1.05/1.86 | 1.61/2.74 |
（ログの全体: `g2d/<テンプレ>-<場面>.gllog` `.out`、集計 `g2d/scenes.json`。「面/静的」は useProgram 無しで bufferData 無しの drawArrays＝シェーダー面か静的レンジ。区別は【推】）

**draw が切れた理由の内訳**（GL ログで直前の draw との差。【確】）
| 場面 | 内訳 |
|---|---|
| rpg title | texture 6（箱(tex 0)・字アトラス・画像が z 順で交互） |
| rpg village | texture 4・kind(tile↔spr) 3 |
| rpg world | texture 1・kind(tile→spr) 1 |
| rpg battle | texture 11（箱と字の交互。全部 Normal・clip 無し） |
| tidepool title | **blend 72**（Normal↔Multiply の交互）・kind(spr↔poly↔面) 19・mask 4 |
| tidepool play | **blend 99**・kind 27・texture 8・mask 5 |
| tidepool flood | **blend 129**・kind 31・texture 8・mask 5 |
| novel 4 場面 | texture 1〜3・kind(spr/poly/面) 3〜5 |
clip(scissor) で切れた draw は全場面 0、Add の draw も 0。Normal↔Multiply の交互が tidepool の draw の 7 割。

mask(stencil): tidepool は 1 コマ 5 回（clearStencil 5・colorMask false の poly 5 + 本体の面 5。stencil 付き draw 10）。他の 2 テンプレは 0。

## 3. 字（テキスト）【確: ソース Text.toDrawables・GL ログ】
- 1 字 = 1 Drawable（`toDrawables` が字ごとに fromParts）。z 順の列では他の sprite と同列。
- 同じフォントの字は **同じ SDF アトラス 1 枚（textureName = font_…。フォント 1 つ・R8・1 枚）**なので、前後が同じ z で連続していれば 1 行も 1 画面も **1 run = 1 draw**（instance 38 float/字）。novel nvl は約 250 字が 1 draw（draw 6 のうち字は 1〜2）。
- 字が多い画面で draw が増えるのは「箱 → 字 → 箱 → 字」と z で交互に重なる時（rpg battle は 245 物で 12 draw：窓の箱と文字が交互）。字そのものでは割れない。
- 3 テンプレのフォントはどれも 1 つ（default: 10/48/32）。font_ 以外のフォントを混ぜれば字アトラスごとに割れる【推】。

## 4. 数を増やした時の伸び【確】（`g2d/stress` = bench/sprite_stress の複製を改造。1 コマ 400 回の avg/p50・捨て 100〜150 コマ。窓 960x720・design 320x240・文字なし）
MODE=same: 全部 "flag" 1 枚（1 draw）／alt: flag と px_atlas を 1 個ごとに交互（N draw）／box: 単色箱（texId 0・1 draw）。

| mode | N | frame avg | p50 | submit avg(塗り) | swap | GPU avg |
|---|---|---|---|---|---|---|
| same | 1,000 | 2.78 | 2.74 | 1.22 | 0.16 | 0.30 |
| same | 5,000 | 9.01 | 8.62 | 2.71 | 0.21 | 1.06 |
| same | 20,000 | 32.31 | 31.77 | 6.89 | 0.26 | 4.07 |
| alt (N draw) | 1,000 | 4.64 | 4.60 | 3.09 | 0.17 | 0.85 |
| alt | 5,000 | 16.80 | 16.54 | 10.37 | 0.25 | 6.29 |
| alt | 20,000 | 65.60 | 63.03 | 40.41 | 0.30 | 35.99 |
| box | 1,000 | 1.81 | 1.80 | 0.80 | 0.14 | 0.21 |
| box | 5,000 | 5.65 | 5.34 | 1.92 | 0.20 | 0.46 |
| box | 20,000 | 23.65 | 23.29 | 5.66 | 0.28 | 1.92 |
（alt8 の MODE と t2〜t7 は用意したが走らせていない）
読み取り:
- 伸びはほぼ線形（same: 1000→20000 で 11.6 倍）。
- **alt − same の差 = 1 draw 当たりの追加代金**: N=20000 で submit +33.5ms（≈1.7µs/draw・bufferData と状態の切り替え込み）、GPU +31.9ms（≈1.6µs/draw）。frame は +33.3ms。つまり「テクスチャが 1 個ごとに変わる」最悪は 1 draw ≒ CPU 1.7µs + GPU 1.6µs。GL の draw はドライバ越しで安くはなく、WebGPU でも draw/バインドの切り替えが同じ桁で効く見込み【推】。
- 同一テクスチャでも GPU は 20000 枚で 4ms（半透明 sprite の塗り面積。box は 1.9ms）。

## 5. 1 コマの内訳の見積もり
| 区間 | stress same N=20000 | stress same N=5000 | tidepool play | rpg battle |
|---|---|---|---|---|
| 全体（間隔） | 32.3 | 9.0 | 12.85 | 1.39 |
| (b) submit = mergedByZ+列の走査+instance 詰め+bufferData+GL 呼び出し 【確】 | 6.9 | 2.7 | 6.7 | 0.46 |
| (a) Flix 側で列を作る（view→PlacedItem→Drawable→camera/z 並べ。submit の前）【推: 間隔−submit−swap】 | ≈25 | ≈6.1 | ≈5.9（うち poly の三角形化は submit 側に入る） | ≈0.9 |
| swap 【確】 | 0.26 | 0.21 | 未取得 | 未取得 |
| (c) GPU の塗り 【確・非同期】 | 4.07 | 1.06 | 【不明】 | 【不明】 |
- (a) は物 1 個 ≈1.3µs（N=5000〜20000 で (frame−submit)/N = 1.27〜1.3µs、N=1000 で 1.6µs）。**今回の測定ではどの N でも CPU の最大項は Flix 側の列作り（a）で、GL の呼び出し（b）は 2〜4 割**【推（割り算）】。plans/engine-browser-spikes の「rpg の GL 呼び出し 47 回 0.05ms」と同じ向き。
- tidepool は poly の CPU 三角形化＋毎 run の頂点作り（b の中）が重い：submit 6.7ms は 133 回の bufferData と 9.4k 三角形。
- GPU は M4 Pro では全テンプレで余裕（間隔が 1ms 台の物は vsync 待ちが支配）【推】。

## 6. 余地の一覧（上の場面で draw をいくつ減らすか。順序は入れ替えない前提。GL ログの列で隣り合う draw が「その違いだけ」の時に併合して数えた simulation＝【推】。各レバーを単独／累積で）
| 場面(今の draw) | ① テクスチャを配列/アトラス化 | ②+sprite/poly 1 シェーダー | ③+Normal/Add を premultiplied で 1 つ | ④+clip を instance 化 | ⑤ blend Multiply も 1 draw にできたと仮定(上限・固定機能では不可) |
|---|---|---|---|---|---|
| rpg title (7) | 1 | 1 | 1 | 1 | 1 |
| rpg village (8) | 4（タイルは別 draw のまま） | 4 | 4 | 4 | 4 |
| rpg world (3) | 2 | 2 | 2 | 2 | 2 |
| rpg battle (12) | 1 | 1 | 1 | 1 | 1 |
| tidepool title (96) | 96 | 92 | 92 | 92 | 17 |
| tidepool play (140) | 132 | 119 | 119 | 119 | 18 |
| tidepool flood (174) | 166 | 153 | 153 | 153 | 18 |
| novel title (6) | 4 | 3 | 3 | 3 | 3 |
| novel adv (7) | 6 | 3 | 3 | 3 | 3 |
| novel nvl (6) | 5 | 3 | 3 | 3 | 3 |
| novel choice (9) | 6 | 3 | 3 | 3 | 3 |
- ①: rpg と novel の draw 割れは大半がテクスチャ交互。**rpg は 7〜12 → 1〜4 に**。tidepool には効かない（割れ目は blend）。
- ②: novel の poly（背景の帯など）と sprite の交互が畳める（6〜9 → 3）。tidepool は 4〜13 減るだけ。
- ③ Normal/Add 統合: **測った 11 場面すべてで 0**（Add の draw が 1 つも無い）。ただし Add を使う画（粒子・光）では効く。
- ④ clip の instance 化: **0**（scissor 付き draw が全場面で 0）。UI のスクロール窓のような所で出る物で、今回の場面では効かない。
- ⑤ tidepool の割れ目は Normal↔Multiply（影・水の濃淡）の交互。Multiply の式は固定機能の blend で Normal と同居できない（src=DST_COLOR 対 SRC_ALPHA）ので、**blend のパイプライン切替は残る**。それでも次はできる:
  - **run ごとの bufferData を 1 コマ 1 回に**: tidepool play で bufferData 133 回 → 1 回（draw 140 は pipeline 切替つきで残るが、毎回の頂点 orphaning と VAO/uniform の再設定が消える）。rpg battle 12→1・novel 5〜8→1。WebGPU では writeBuffer の範囲重なりが先の draw にも効く罠があるので、そもそも必須【確: B-2d-shader.md】。
  - **mask を stencil でなくテクスチャで**: tidepool の 5 回 ×（clearStencil+colorMask 切替+poly 1 draw+面 1 draw）。draw 数は mask の poly 5 + 面 5 のまま（mask をテクスチャに描く別パスが要るので増える可能性）でも、WebGPU で描き途中の stencil clear ができない問題が消える【推】。rpg・novel には mask が無い。
  - **Normal↔Multiply の交互が z 順に必要か**を絵のほうで見直す（たとえば Multiply を 1 枚の層にまとめる）のが draw を一番減らす（140→20 前後）が、絵の変更（仕様変更）になる。
- ⑥ 動かない物を毎コマ組み直さない（Static.flix）: 現状は **`App.withStaticLayer`（polygon だけ・鍵が変わるまで VBO を作り直さず、z・blend・clip ごとのレンジを 1 draw ずつ永続 VBO から描く・CPU の三角形化と upload が消える）**と、**`App.withTileLayers`（タイル層 1 枚 1 draw・毎コマの組み直し無し）**の 2 つ。使っているのは rpg の village/world/cave の床と壁（tileLayers）・tidepool の枠 1 か所（staticLayer）だけ。sprite・字・UI は対象外（Item.Sprite は無視される）で毎コマ組み直す。**tidepool の 9.4k 三角形の大半（水・魚・影）は動的で毎コマ三角形化＋bufferData**。ここは静的化の対象外（毎コマ変わる）なので、効くのは「CPU の三角形化を GPU 頂点シェーダーへ移す」側【推】で、静的化の拡張では減らない。rpg の UI(窓・字)は毎コマ組み直しだが 0.4〜0.5ms で小さい。
- 数の効き目の整理【推】: **draw 数を減らして効くのは tidepool 型（poly 大量）と、N 万個でテクスチャが交互になる群れ**（alt の 1 draw ≒ 3.3µs=CPU1.7+GPU1.6）。rpg・novel 型は元々 3〜12 draw・塗り 0.4〜1.2ms で、draw を 1 にしても得は 0.1ms 未満。**一番大きい項は Flix 側の列作り（物 1 個 ≈1.3µs）**で、描き手の移行ではなく列の作り方（毎コマ組み直さない・差分）が効く。

## 7. 使ったコマンド・scratch
- 場面: `cd templates/<t> && SHOT=<s> FLIX_GE_FRAME_STATS=1 FLIX_GE_NO_VSYNC=1 FLIX_GE_MUTE=1 FLIX_GE_GL_LOG=<g2d>/<t>-<s>.gllog FLIX_GE_GL_LOG_FRAMES=8 make run RUN_SECONDS=20`（`g2d/run_scenes.sh`）。
- 集計: `g2d/analyze.py`（GL ログから run を切る・理由・併合 simulation）→ `g2d/scenes.json`。
- stress: `cd g2d/stress && MODE=same|alt|box COUNTS=1000,5000,20000 FLIX_GE_NO_VSYNC=1 FLIX_GE_MUTE=1 /Users/abab/Desktop/flix_game_engine/bin/flix run`（出力 `g2d/stress-*.out` の RESULT 行）。`App.withDiagnostics` の submit/swap/gpu を使用。
- 取れなかった物: テンプレの GPU ms（診断を出す口がテンプレに無い・scratch 複製は作らなかった）【不明】/ 歩き・戦いの遷移中の動く 1 コマ / alt8 / ブラウザ側 / crowd2d。
- 注意: tidepool の ms は窓あり vsync off の avg で、F8 停止(動かない World)でも poly を毎コマ再三角形化する（動くと変わる）。熱の影響で ±10%【推】。
