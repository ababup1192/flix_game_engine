# 300 体の skinned を速くする engine の拡張と、conduit_hive の汎用パーツの昇格（草案 rev4・2026-11-05）

人の承認: 「動画撮影を終えたら汎用改善案の設計実装へ移りましょう。エンジンをいじるなら、手で書いている汎用パーツの昇格も同時に」（2026-11-05）。
計測の元: conduit_hive/plans/bench-horde.md の末尾の節「同時の数を 75・300 に上げた時」。
rev1（66 点）からの直しは plans/engine-horde-perf.review1.md の 10 項目、rev2（84 点）からの直しは 2 回目の採点の 9 項目、rev3（88 点）からは 3 回目の 5 項目。採らなかった所は 7 節。

## 0. 前提（数はソースと計測の記録で確かめた値）

### 計測

- 測った機械は Apple M4 Pro（macOS・外付けの画面・ウィンドウ 960×540）の 1 台だけ。ほかの機械（Windows・Intel の Mac・ブラウザ）の数は無い。
- horde-waves300（3 分・生きている数 283〜300）: work 11.80 / p95 16.29 / 最大 49.9 ms、submit 5.74 / p95 9.56 ms、GPU 1.67 ms、
  draw call 304（敵 1 体 1 本）、1 コマの姿勢 6.4。horde300（最初から 300 体置く）は姿勢 43.1・cpu_plan 2.4 ms。cpu_step 0.6〜1.8 ms。
- submit の 40〜45 ms の spike が途中（frame 2055・6888・7064）でも出る。50 体では測り始めだけ。G1 と世代別 ZGC で同じ位置に出るので、GC が主因の見込みは低い。
- HordeBench の間隔は `frame#realNow` の差（engine の dt のクランプ後）。spike の 3 コマはどれも 50.0 ちょうどで、本当はもっと長い可能性がある。
  dt が実時間で揺れるので、同じ組を 2 回流しても World の列は同じにならない（2 回の比べはそのままでは役に立たない）。

### 今の skinned の描き方（render_gl/src/Render3d.flix・Render3d/Material.flix・Render3d/Shadow.flix）

- 敵の glb: creature_melee.glb はジョイント 18、creature_ranged.glb は 19（どちらも mesh 1・primitive 1・材質 1）。
- `Skin3d.maxJoints()` は 64（engine/src/scene3d/Skin3d.flix:19）。joint の UBO は 64 × mat4 = 4 KB（Render3d.flix:1057）。
- 1 体ごとに `drawPosedMesh` → `putJoints` → `drawMesh`（Render3d.flix:676-681）。`putJoints` は前に書いた中身と違えば
  `glBufferData` で orphan してから `glBufferSubData`（:712-718）。比べる `needsUpload` は `List.range` で 1 本ずつ比べる（:723-725）。
- 不透明の材質の物は program の番号だけで並べる（:483）。姿勢を 8 組で共有しても隣の物の姿勢が同じとは限らず、ほぼ毎体 orphan する。
  同じ program の中の順は絵を変えない（:482 の WhyNot: 不透明は深度で前後が決まる）。ただし `sortBy` は安定ソートではない（Material.flix:56）。
- 影の道（Shadow.flix:116-127）は光ごとに skinned をもう一度 `drawPosedMesh` で描くので、影を落とす光が 1 つあれば orphan の回数がほぼ倍になる。
- `prepare` は描き先（画面・Pass・Design）ごとに呼ばれる（Render3d.flix:280-298）。Pass の場面は画面のコマの 1 つ前の世代で描く（Material.flix:300・:412）。
- 1 体ごとに CPU で作る物: `matrixArray` の float[16] ×2（:666-667）・joint の float 配列（:709）・`needsUpload` の `List.range`・
  `materialKey` の文字列（:163-166）・`splitByMaterial` の材質の解決（Material.flix:26-41）・絵を貼るたびの `mipCopyOf` / `texture3dBound` の
  `Map.insert`（Material.flix:216-228・:285-297）。
- texture unit: 材質の絵 0〜5・法線マップ 6・影の地図 7・lightmap 8（Render3d.flix:239-246）。joint の UBO の binding は 1（:249）。
- 頂点の属性は location 0〜7 を使用中（aPos 0・aNormal 1・aColor 2・aJoints 3・aWeights 4・aUv 5・aTangent 6・aUv2 7。Render3dGlsl.flix）。
  GL 3.3 / WebGL2 の最低保証は 16。GLSL は 330 core（web は 300 es へ差し替え）。

### eviction と re-upload

- mesh: 128 コマ使わなければ捨てる（`meshIdleFrames`・Render3d.flix:231）。
- 場面の絵（Texture3d）: idle で捨て、さらに予算（`textureCountBudget`・`textureByteBudget`）を超えたら古い物から捨てる（`sweepTextures3d`・Material.flix:301-312）。
  再び使う時は CPU で `Mip.build` してから上げる（:291）。
- mip copy（2D の登録の絵に mip level を付けたコピー）: idle だけで捨て、予算に数えない（Material.flix:313-316）。再び使う時は `glGetTexImage`（同期）で
  読み戻し、`Mip.build` して re-upload する（:224-226）。CPU に画素を持たないのは決めた事（:212 の WhyNot）。
- 材質の program は LRU。

### 診断と計測の道具（engine に既にある物）

- `App.Internal.Hitch`（engine_world/src/App/Internal/Hitch.flix）: 1 コマの `totalNs`（nanoTime・クランプ前）・GC の回数と ms・`FrameDiagnostics` を
  1 行にし（`hitchRow`・:27-36）、重いコマの並びを hitch.md に書く。
- POST /perf（`perfRun`・`perfPaint`・`perfSummary`）: record.flow を決まった刻みで流した World の列を、本物の GL で 1 コマずつ塗り直し、
  同じ判定で hitch.md を書いて p50 / p95 / max を返す。更新は通らず塗りだけ。この計画では隠しウィンドウは使わない（C0 の 2）。
- docs/performance.md §11（:463-）が使い方。:502 に「自前で `System.nanoTime` を測って出さない」。
- `FrameDiagnostics.Scene3dCounts` は instances・drawn・drawCalls・落とした光の数だけ（engine/src/core/FrameDiagnostics.flix:38）。
  `textureUploads` は 2D の絵だけ。Texture3d・mip copy・mesh の re-upload・UBO の orphan はどこにも出ない（spike の行の uploads=0 は無実の証拠にならない）。

### GL の層と既存の計画

- `GlContext`（render_gl/java/fge/gl/GlContext.java）の実装は LwjglGl・WebGl2（engine_web/java/fge/web/WebGl2.java）・RecordingGl（GlCallLog が包む版）の 3 つ。
  今ある instanced の呼び出しは 2D の Sprite 用の `vertexAttribDivisor`・`drawArraysInstanced`（GlContext.java:48-50）だけで、
  `drawElements*`・`bufferSubData`・float の texture は無い。
- Render3d と Render3d/*.flix は今も LWJGL を直に約 280 行で呼ぶ。GlCallLog は GlContext を通る呼び出ししか控えない（GlCallLog.flix:1-3）。
- plans/engine-core-polish.md:77: C9（3D の GL を GlContext へ移す）の中で instancing を 1 回だけ書く。
  「3D のシューティングを先に作ると決めたら、C9 をブラウザの前へ出す」。conduit_hive がその 3D のシューティングで、条件は満たした（6 節 問い 1）。
- engine_web/js/fge-web.js は変更中（iPhone の確認待ち）・plans/engine-browser*.md は未追跡。WebGl2.java の `fgeGl` は生の WebGL2 の context なので
  （fge-web.js:9・:731）、WebGl2.java に JSBody を足すだけで fge-web.js は触らない。
- docs/backend-parity.md の決まり 2: instancing は CPU の描き手では普通のループ（足す物なし）。
- Render3d.flix は 1,124 行（lint の上限 1,200）。足す物は別ファイル。

## 1. フェーズの順番と依存

```
C0（測る: engine・render_gl・engine_world）
 └→ C1（spike を止める安い直し・姿勢の鍵を作る: engine・render_gl）
      └→ E-engine（CollisionWorld3d.raycast: engine）……… C1 の直後に、ほかと並べずに 1 人で済ませる
           ├→ G（GL の呼び出しを GlContext へ: render_gl・engine_web）→ B（joint texture: render_gl）→ A（instancing: render_gl）→ A2（billboard: render_gl）
           └→ E-world（engine_world だけの昇格の行・Projectile3d を含む）……… G・B・A・A2 と並べてよい
E-full（VideoOut: engine_full）は、render_gl が緑の区切り（フェーズとフェーズの間）か、別の worktree で。
E の追随（docs・agents-pack・ゲーム）は A2 と E が終わってから。
D（Par）は条件付き（A の後に測って決める）。
```

並べ方はパッケージ単位で決める（AGENTS.md「同じパッケージを 2 人に触らせない」）。型検査は層ごとの木で走り、
.layers/render_gl/src と .layers/engine_world/src はどちらも engine のソースを含む。engine_full/src も engine・render_gl・engine_world・engine_tools の symlink の木。
そのため engine が赤いと render_gl と engine_world の両方が赤く、render_gl が赤いと engine_full も赤い。

| パッケージ | 触るフェーズ | 並べてよい相手 |
|---|---|---|
| engine | C0（FrameDiagnostics）・C1（Pose3d・CollisionWorld3d）・E-engine（CollisionWorld3d.raycast） | どれとも並べない（engine が赤いと render_gl・engine_world の両方が赤い）。E-engine は C1 の直後に済ませる |
| render_gl | C0・C1・G・B・A・A2 | E-world |
| engine_world | C0（Hitch の perfSummary）・E-world | E-engine が終わった後の G・B・A・A2 |
| engine_web | G | — |
| engine_full | E-full | render_gl が緑の区切りか、別の worktree で（symlink の木なので render_gl の赤を拾う） |

B は C1 で作った姿勢の鍵を使うだけで engine の Pose3d を触らないので、B・A は render_gl だけで閉じる。

- C1 を B の前に置くのは、C1 の並べ替えだけで orphan が「重複の無い姿勢の数」まで減り、C0 の見立て②の当たり外れがすぐ分かるから。並べ替えに使う姿勢の鍵は B でもそのまま使う。
- B を A の前に置くのは、B で UBO の orphan が消え、B の joint texture が A の骨の置き場そのものだから。
- G を B の前に置くのは、B と A を最初から GlContext の上で書けば C9 で書き直さずに済むから。

## 2. 各フェーズ

### C0. spike の原因を突き止める（1.5〜2 日）

engine の既存の道具（hitch.md と POST /perf）で測る。HordeBench の間隔を自前の nanoTime に替えることはしない（performance.md:502）。

1. **最初の 30 分で 3 つ確かめる**。HordeBench は `App.loadAndLaunch` を通るが、World は HordeBench 専用に組む（HordeBench.flix:96-118 の `loadKit`）。
   1. hitch の見張りが乗るか: 見張りは `App.canDebug`（debug が有効で view か debugView がある）の時だけ始まる（DevTools.flix:152・App.flix:536-538）。
   2. record.flow が書かれるか。
   3. その flow を /perf に渡して、始まりの World の指紋が合うか: 記録の頭には通った始まりと起動の World の指紋が書かれ、
      `App.withStarts` が無いと再生は flow の既定の World（init）から始まる（`writeStart`・DevTools.flix:155-165）。
      HordeBench の World は専用なので、ここで合わない見込みが高い。
   
   3 つのどれかが駄目なら、conduit_hive の `Game.app`（既に `App.withStarts(Starts.all() ...)` がある）の Starts に horde300 / horde-waves300 の始まりを足し、
   普段の DEBUG の起動から記録する（0.5〜1 日・ゲームの側の直し）。起動直後 120 コマは数えないので、測り始めの spike は対象外・途中の spike が対象。
2. hitch.md と record.flow ができたら、`POST /perf?path=<置き場>/record.flow&last=N` で同じ World の列を 2 回塗る。
   2 回とも同じコマで重い → 塗る中身（eviction・orphan）。2 回目で消える → 一度きりの物（③）。揺れる → ドライバか OS。
   2 回の比べが成り立つのは、/perf が決まった刻みで流した列を塗るから（HordeBench の 2 回の比べは dt が揺れるので成り立たない）。
   塗る時の形は bench-horde.md:12-13 の測り方にそろえる: ウィンドウを出して vsync ありで塗る（隠しウィンドウは描き先が 480×270 に縮むので使わない）。
   hitch の行は swap を分けて数える（vsync の待ちは重いコマに数えない）。GPU の ms は 1〜2 コマ遅れの値として読む（FrameDiagnostics の gpuNs の決まり）。
3. クランプ前の間隔は hitch の行の `totalNs` で読む（50.0 ちょうどの 3 コマの本当の長さ）。
4. 足す数は `Scene3dCounts` に 7 つ: meshUploads・meshEvictions・texture3dUploads・mipCopies・materialBuilds・jointUploads・targetRebuilds。
   出口は `FrameDiagnostics`（`summaryLines` と hitch.md の重いコマの表）。Render3d の区間（renderShadows・splitByMaterial・draw・endFrame）の時間も
   FrameDiagnostics の欄として出す（`gpuPasses` と同じ形の `(名前, ns)` の列）。数えるのは `setDiagnosticsEnabled` の間だけ。
5. /perf の答え（`perfSummary`）に Scene3dCounts の合計と submit の分布（p50 / p95 / max）を足す。これで FrameBench を別に作らない（4 節）。
6. bisect の env: `FGE_JOINT_UPLOAD=orphan|subdata`・`FGE_SCENE3D_EVICT=idle|budget`。release に載せない。

見立て（当たりそうな順）:

| # | 仮説 | 当たりなら出る数 | 確かめ方 |
|---|---|---|---|
| ① | eviction の後の re-upload（mip copy の `glGetTexImage` と `Mip.build`・Texture3d の `Mip.build` の CPU 時間） | spike のコマで mipCopies・texture3dUploads > 0。塗り直しでも idle のコマ数は同じなので、eviction と re-upload は 2 回目も同じ所で起きる | `FGE_SCENE3D_EVICT=budget` で消えるか |
| ② | UBO の orphan が 1 コマ数百回（GL-on-Metal は待ちが submit の中に出る）・影の道でさらに倍 | jointUploads が体の数 × (1 + 影の光の数)。2 回目も同じ所 | `FGE_JOINT_UPLOAD=subdata` と C1 の並べ替えで減るか |
| ③ | 一度きりの物（JIT の deopt と再コンパイル・シェーダー・ドライバの初回の仕事） | /perf の 2 回目で消える | どれかは JFR の `jdk.Deoptimization` と hitch の行の shaderBuilds で分ける（どちらも出なければドライバ） |
| ④ | G1 | 行の GC の ms | ZGC で同じ位置に出たので低い |
| ⑤ | 材質の program の作り直し | materialBuilds・shaderBuilds | 今の記録で 0 なので低い |

- テスト: Scene3dCounts の新しい欄が 0 で始まり `takeCounts` で 0 に戻る（render_gl/test）・`summaryLines` に出る（engine の FrameDiagnostics のテスト）。
- ゲート: `flix check`（render_gl・engine・engine_world）・`make test-<name>` は波及した所だけ。
- 出る物: どの仮説が当たったかと、C1 で何を採るか。

### C1. spike を止める安い直し（3.5〜4.5 日・C0 の結果で中身を選ぶ）

0. **最初の半日で、Flix で姿勢の参照の一致が書けるかを決める**。C1 の 1 の「比べを飛ばすのは参照が一致した時だけ」と B の 1 の 3 ステップの両方がこれに乗る。

採る物:

1. **不透明の skinned を (program, 姿勢の鍵) で並べ替える**（1〜1.5 日）。Render3d.flix:482 の WhyNot のとおり、不透明は深度で前後が決まるので順は絵を変えない。
   並べ替える所は 3 つ: 材質の道（Render3d.flix:483 の `drawMaterials` の呼び手）・材質の無い lit の道（`drawLitWith`・Render3d.flix:615-625）・影の道（Shadow.flix:116-127）。
   影の地図は奥行きだけなので順は絵を変えない。
   同じ姿勢が隣に並ぶので orphan が重複の無い姿勢の数（6.4〜43）まで減る。
   隣と比べを飛ばしてよいのは参照が一致した時だけ。鍵が同じだけなら `needsUpload` で全部比べる（鍵の衝突で違う姿勢を同じと見なさない）。
   姿勢の鍵は `Pose3d` の中身から作る Int64（B の 1 と同じ物を先に作る）。参照の一致が Flix で書けなければ、比べは毎回する（orphan が減る効果は残る）。
   `sortBy` は安定ソートではない（Material.flix:56）ので、鍵の最後に元の添え字を入れて順を決める。同じ深さの面だけは勝ち方が変わりうる。
2. **mip copy を予算に数え、idle でなく予算超えで捨てる**（0.5〜1 日）。`sweepTextures3d`（Material.flix:313-316）の mip copy を
   `textureByteBudget` に数える。CPU に画素を持たない決め（:212）は変えない。Texture3d は今の形（idle と予算）のままで、C0 で①が当たった時だけ
   Texture3d も「予算超えだけ」にそろえる（毎コマ新しい鍵が来る物は予算で押し出される）。
3. **1 体ごとに作る物を減らす**（0.5〜1 日）: `needsUpload` を `List.range` を作らないループに・matrix の scratch 配列を使い回す。
4. **`CollisionWorld3d.boxesNear` が毎回 `Map.size(r#cells)` を数え直す**（engine/src/scene3d/CollisionWorld3d.flix:66・bench-horde.md）のを、
   build の時に数えて持つ（0.5 日）。

採らない物（rev1 から外した）:

- 1 本の大きな UBO と `glBindBufferRange` — Render3d.flix:705-706 の WhyNot で既に退けた形で、しかも B で UBO ごと消える。
- mip level の CPU キャッシュ — Material.flix:212 の WhyNot（全部の絵をヒープに二重に持つ）。

- ファイル: render_gl/src/Render3d.flix（並べ替えの呼び手）・Render3d/Material.flix（sweep）・engine/src/scene3d/Pose3d.flix（姿勢の鍵）・
  engine/src/scene3d/CollisionWorld3d.flix。
- テスト: 並べ替えの順が決まる（同じ入力 → 同じ順・同じ鍵は元の添え字の順。材質・lit・影の 3 つの道とも）・同じ行列 → 同じ鍵 / 1 bit 違い → 違う鍵・
  鍵が同じで中身が違う 2 つの姿勢を並べても両方上げる・
  mip copy が予算を超えた時だけ捨てられる（pure にした判定）・`boxesNear` の答えが直す前と同じ。
- ゲート: gl-parity 全緑・`make baseline-check` の差が増えない（並べ替えで同じ深さの面が変わったら、その場面と画素の数を見せて人が承認）。
  CPU の描き手は触らないので CPU の絵は不変。
- 目標（horde-waves300）: 最大 ≤ 20 ms・p95 ≤ 13 ms・submit 中央値 ≤ 5.0 ms。
  jointUploads は並べる前が「描いた skinned の数 ×（1 + 影の光の数）」、並べた後の目標が「重複の無い姿勢の数 ×（1 + 影の光の数）」以下
  （道ごとに並べ直すので、1 つの姿勢は材質か lit の道で 1 回と、影の光ごとに 1 回上がる）。
  根拠: p95 13 ms は spike の無い horde300 の p95（12.85 ms）の水準。最大 20 ms は 60 fps で落とすコマを 1 つまでに抑える線。

### G. B と A が使う GL の呼び出しを GlContext へ（2〜3 日・問い 1 が推しの時）

- 足す呼び出し: `drawElementsInstanced`・RGBA32F の `texImage2D` / `texSubImage2D`（FloatBuffer）・
  `vertexAttribIPointer`（A で float の行に詰めるなら不要。A の 1 で決める）。sampler の NEAREST はある呼び出しで足りる。
- 足さない物: orphan 用の呼び出しと `bufferSubData`。A の 1 体ごとの値は prepare ごとに `bufferData(FloatBuffer)` で 1 回送るので、
  既存の `bufferData`（GlContext.java:40-42）で足りる（`bufferData` は毎回作り直すので orphan を別に書かない）。
- 書く所: GlContext.java（interface）・LwjglGl.java・RecordingGl.java（控えの 1 行も）・WebGl2.java（1 つにつき注記・native・委譲の 3 行。FloatBuffer の渡し方は既存の `bufferData(FloatBuffer)` に合わせる）。
  写経元は 2D の Sprite.flix の `drawArraysInstanced` と `vertexAttribDivisor`。
- ほかの約 280 行は C9 のまま動かさない。fge-web.js は触らない。
- テスト: GlCallLog の控えに新しい呼び出しが 1 行ずつ出る。WebGl2 は `flix check` と engine_web のビルドが通るまで（実機は browser の計画の確認に混ぜる）。
- ゲート: render_gl・engine_web の `flix check`、gl-parity 全緑（呼ぶ所がまだ無いので絵は 1 bit 同じ）。

### B. 同じ姿勢の骨の行列を prepare 1 回につき 1 回（5〜6.5 日）

0. **場面の分けを draw から prepare へ移す**（+0.5〜1 日）: 今は場面の分け（`splitByMaterial`・視錐台）が draw の側（`drawItem` → `drawScene`・Render3d.flix:355-365・:458-498）で行われる。
   これを prepare（:292-299）へ移して `SceneItem` に持たせ、joint texture の行の割り当てと A の batch 作りも prepare で済ませる。Design の描き先（`blitDesign` の道・:364）は
   prepare の中で Design の描き先へ先に描く道に含め、draw では blit するだけなので分けを持たせない、と書き分ける。

1. **姿勢の比べは 3 ステップ**: 参照の一致 → 鍵（C1 で作った Int64）→ 鍵が同じなら全部比べる。ゲームは共有の姿勢を 1 つの Map から配る
   （conduit_hive の `Creatures.drawnOf`・Creatures.flix:200-211）ので、ほとんどは 1 ステップ目で決まる。Flix で参照の一致が素直に書けなければ
   1 ステップ目を飛ばして鍵から始める（C1 の 0 で決めてある）。
2. **joint texture**: RGBA32F・幅 4 texel × `maxJoints`（64）= 1 行 256 texel・1 行 = 1 姿勢・高さは 2 の冪で伸ばす。
   prepare 1 回の重複の無い姿勢を詰めて `texSubImage2D` を 1 回。シェーダーは `texelFetch` 4 本で mat4。
   - filter は MIN / MAG とも NEAREST・mip なし（WebGL2 の RGBA32F は LINEAR だと texture が不完全になり、`texelFetch` が 0 を返して黒く出る）。
   - texture unit は 9（0〜5 材質・6 法線マップ・7 影の地図・8 lightmap が埋まっている）。vertex shader の texture unit の最低保証は GL 3.3・WebGL2 とも 16。
   - 回す単位は prepare の 1 回（描き先ごと）。**決め: 「prepare の数 × 3 枚」（推し）**。もう 1 案の「1 コマ 1 枚に prepare ごとの行を後ろへ足し、コマ単位で 3 枚回す」は
     前の prepare の draw が読んでいる最中の texture へ書き足すことになり、ドライバが待つ余地がある（Render3d.flix:704 の WhyNot と同じ形）ので採らない。
     1 枚は最大 43 行 × 4 KB ≒ 172 KB なので、prepare 4 回でも 12 枚 ≒ 2 MB。Pass の場面は 1 つ前の世代で描くので、前のコマの texture を上書きしない。
   - 影の道は同じ prepare の中なので同じ行を読む（orphan の倍が消える）。
3. **texture を選ぶ理由**: SSBO は GL 3.3 / WebGL2 / macOS の GL 4.1 に無い。UBO の最低保証は 16 KB。重複の無い姿勢は 1 コマ 6.4〜43 で、
   `maxJoints` で詰めると 43 × 4 KB = 172 KB、今の敵の 19 ジョイントで詰めても 43 × 1.2 KB = 52 KB で、どちらも 16 KB に入らない。
4. **skinned の全部の道を joint texture へ**: 色・深度の Output・影。行の番号は `uPoseRow` の uniform（A で 1 体ごとの値へ移る）。UBO と `bindJointsBlock` を消す。
- CPU の描き手は変えない。
- ファイル（render_gl だけ。姿勢の鍵は C1 で engine に作ってある）: render_gl/src/Render3dGlsl.flix・新規 render_gl/src/Render3d/JointTexture.flix（G の GlContext の上で書く）・
  Render3d.flix（putJoints を外す）・Render3d/Shadow.flix。
- テスト（render_gl/test・pure にした所）:
  - 重複を除いた行の割り当て（同じ姿勢 → 同じ行・順が決まる）
  - 姿勢 0 の prepare で texture を作らない・上げない
  - 行が 2 の冪を越えて伸びる（例: 64 → 65 行で高さ 128）時に前の行が壊れない
  - Pass・Design・影で prepare が 1 コマに複数回ある時、それぞれ jointUploads が 1 回
- ゲート: `make baseline-check` で gl-parity の GL の画素が B の前と 1 bit 同じ（同じ行列を同じ float で読むので変わらないはず。変われば止めて調べる）。
- 目標: jointUploads = prepare 1 回につき 1 回・submit 中央値 ≤ 4.5 ms。

### A. instancing（8〜10 日）

**版は 1 本**: 材質・lit・depth の program は instanced の版だけにする（1 体でも instance 数 1 で描く）。instanced の版と普通の版が同時に生きると、
遊びの途中で初めて instanced の版を組むコマが spike になる（BlastFx で材質の program を初めて組んだコマが 182 ms だった前例・bench-horde.md）。
新しい pub は足さない。描き手が自動で batch にする（Bevy の自動 batching と同じ考え方）。明示の MultiMesh3d は作らない（必要になったら別の計画）。

1. **1 体ごとの値の置き場を決める（1 日の spike）**。2 案を本気で比べる:

   | | 頂点の属性（推し） | インスタンスの値を RGBA32F texture に置き `gl_InstanceID + uInstanceBase` で引く |
   |---|---|---|
   | 場所 | world mat4 = 8〜11・normal mat3 を vec4 × 3 = 12〜14（.w に emissionIntensity・姿勢の行・空き）・tint = 15 | 属性は 0〜7 のまま |
   | location | 16 を使い切る（aUv2 の 7 は残る） | 空きが 8 残る |
   | 姿勢の行 | float で渡す（2^24 まで正確）→ `vertexAttribIPointer` が要らない | texel から引く |
   | 絵の一致 | 同じ float を同じ式で読むので、A の前と 1 bit 同じにしやすい | `texelFetch` の分だけ vertex shader の仕事が増える |
   | 送り方 | streaming VBO・batch ごとに offset を指し直す | joint texture と同じ回し方の texture をもう 1 枚 |

   normal 行列は CPU の `Mat4.normalMatrix` のまま渡す（uniform scale なら `mat3(model)` で済むが、伸ばした箱があるので 1 本にしない）。
   17 個目の値が要る時が来たら texture の案へ移る（3 節）。
   - fragment で使う 1 体ごとの値（tint・emissionIntensity）は vertex から `flat out` で渡す（GLSL 330 core にも 300 es にもある）。
     1 体の中で値は変わらないので、補間させない。
   - 「版は 1 本」なので、動かない物も instance 数 1 で描く。そのため `uploadMesh`（Render3d.flix:753-780・今は location 0〜2 と skin・surface・uv2 を有効化）で
     mesh の VAO に location 8〜15 の有効化と divisor 1 を足し、batch にならない draw ごとに 8〜15 の attrib を streaming VBO の offset へ指し直す。
     この指し直しの代金は、小物の多い場面（night_apartment の部屋）で /perf を使って別に 1 行測る（ゲートの行）。
2. **batch key**（材質の欄を列挙）: program（`materialKey`。kind と shaderHash を含む）・mesh の contentHash・材質の絵の名前の列（Material.flix:167:
   eqSpec は名前を並びの番号で比べるので、名前の違う材質が同じ program を使う）・wrap・cutout・params の hash・normalMap の名前と強さ（Material.flix:106-119・:160）。
   tint と emissionIntensity は 1 体ごとの値なので鍵から外す（conduit_hive の `Creatures.glowing` は敵ごとに emissionIntensity を変える）。
   batch にしない物: 半透明（遠い順に描く）・lightmap つき（物ごとに絵が違う）。
   並びは (batch key, 元の添え字) で決まる。
3. **材質の解決を batch ごとに 1 回**: `splitByMaterial` の `materialKey` の文字列と Map の lookup、`mipCopyOf` / `texture3dBound` の毎回の `Map.insert` を、
   batch の頭で 1 回に。
4. **視錐台の外**: batch から外すが、`meshEntry` で使った記録は付ける（Render3d.flix:675 の WhyNot: 付けないと 128 コマ後に捨てられ、振り向くたびに re-upload）。
5. **送り方**: prepare 1 回につき、その prepare の全 batch（色・深度の Output・影の地図）の 1 体ごとの値を 1 本の FloatBuffer に詰め、
   `bufferData(FloatBuffer)` を 1 回（既存の GlContext.java:42。毎回作り直すので orphan を別に書かない）。baseInstance が無いので batch ごとに attrib の offset を指し直す。
   FloatBuffer は `allocFloats` で持ち、足りなければ倍に伸ばす。prepare ごとに送るので、Pass の場面が 1 つ前の世代で描かれても前の値を上書きしない（B の joint texture と同じ単位）。
- CPU の描き手は足す物なし。
- ファイル: 新規 render_gl/src/Render3d/Batch.flix（pure）・Instancing.flix（G の GlContext の上で書く）、Render3d.flix・Material.flix・Shadow.flix・
  Render3dGlsl.flix（ProgramKind の版を instanced へ）。
- テスト:
  - batch key の分け方（tint と emission が違っても同じ batch・絵の名前か normalMap の強さが違えば別）・並びが決まる・視錐台の外が batch に入らない・
    視錐台の外でも meshEntry の使った記録が付く
  - A の 1 体ごとの値も、prepare が 1 コマに複数回ある（Pass・Design・影）コマで壊れない（前の prepare の batch の offset が後の prepare の送りで上書きされない）
  - gl-parity の新しい場面 skinCrowd（12 体・3 姿勢・tint 2 色・emission 1 体違い・半透明 1・単体 1）。許容は先に A の前の描き方で撮って測ってから決める。
- ゲート（A は全部の program の GLSL を替えるので、2 つの比べを分ける）:
  - **同じ版どうし**: `FGE_INSTANCING=off`（instance 数 1 で 1 体ずつ）と `on` の GL が完全一致。これは batch の組み方の正しさの比べで、A の前との比べではない
  - **A の前との比べ**: `make baseline-check`。差が出たら、差の出た場面と差の画素数を出して人が承認する（承認の前に基準を撮り直さない）
  - 遊びの途中の `shaderBuilds` が 0（hitch.md に作ったシェーダーの行が出ない）
  - scene3d-bench の p50 の悪化 5% 以内
  - 小物の多い場面で、batch にならない draw ごとの attrib の指し直しによる submit の悪化 5% 以内。測り方: night_apartment を DEBUG の起動で立ち上げて部屋を歩いた record.flow を 1 本取り、
    A の前と後に同じ flow を /perf で塗って submit の p50 を比べる（決まった刻みの同じ World の列なので比べが成り立つ）
- 目標（horde-waves300）: draw call 304 → 80 以下（敵の分は種類 2 × 描く道の数まで・残りは床・particle・肉片）・submit ≤ 3.5 / p95 ≤ 5 ms・
  work ≤ 9.5 / p95 ≤ 12 ms（submit が 5.7 → 3.5 ms に減る分を work から引いた値）。horde50 の work の悪化 2% 以内。

### A2. billboard の instancing（3〜4 日）

1 枚ごとの uniform 7 個 + `glDrawArrays` を、同じ絵ごとに batch にする（center・size・anchor・uvRect・tint・lit を 1 枚ごとの値に）。
A と同じく版は 1 本。テスト: gl-parity の既存の billboard と particle 50 枚の場面。ゲート: A と同じ（off / on の完全一致・遊びの途中の shaderBuilds 0）。

### D. Par（条件付き・A の後・5〜7 日）

- plans/deferred/c10a-par-wip.patch（Par.map・mapChunked・join2..4。純粋な関数だけ・順は入力どおり）。効果が大きい順: CPU の描き手の行ごとの塗り → horde300 の姿勢 → 群れの規則。
- 入れる条件: A の後に horde-waves300 で cpu_plan と姿勢が work の 20% を超えている時だけ。
- 入れると plans/engine-core-polish.md の「C10a も次の計画へ」（2026-11-04 の決定）を前へ引くことになる。そうなったら core-polish の計画の行も直す。

### E. 昇格（4 節の表・1 行 1〜2 日 ＋ 追随 2〜3 週）

並べ方はパッケージ単位（1 節の表）:
- E-world（engine_world だけの行: FirstPersonController3d・AnimationSharing3d・Fx を Billboard3d へ写す関数と FxDoc の 3D の欄・CameraRig の shakeRotation・
  Separation・Steering.downhillOf・Projectile3d）は E-engine の後なら G・B・A・A2（render_gl）と並べてよい。
- E-engine（CollisionWorld3d.raycast・engine）は C1 の直後に、ほかと並べずに済ませる（engine が赤いと render_gl と engine_world の両方が赤い）。Projectile3d（engine_world）は raycast の後で E-world に入る。
- E-full（VideoOut・engine_full）は、render_gl が緑の区切り（フェーズとフェーズの間）か別の worktree で（engine_full/src は symlink の木）。

## 3. リスクと代替

| フェーズ | リスク | 代替 |
|---|---|---|
| C0 | HordeBench に hitch の見張りが乗らない・record.flow が書かれない・/perf で始まりの World の指紋が合わない | conduit_hive の Game.app の Starts に horde300 の始まりを足して、そこから記録（0.5〜1 日） |
| C0 | 旗が増える | env だけ・release に載せない |
| C0 | GPU の ms が 1〜2 コマ遅れで、spike のコマと並ばない | GPU の ms は前後 2 コマを合わせて読む。比べの主役は submit と数 |
| C1 | 並べ替えで同じ深さの面の勝ち方が変わる | 鍵に元の添え字を入れて決める・差は人が承認 |
| C1 | mip copy を予算に数えると、予算の小さいゲームで 3D の絵が先に押し出される | 予算超えの知らせ（:317-319）に mip copy の量も出す |
| B | 鍵の衝突 | 同じ鍵は全部比べる |
| B | 3 枚回してもドライバが同期する | PBO・毎コマ作り直し |
| B | 参照の一致が Flix で書けない | 鍵から始める（1 ステップ減るだけ） |
| A | location 16 を使い切る | 1 体ごとの値も texture へ（A の 1 の右の列） |
| A | GL の撮り直しの SHA が変わる | 差の数を見せて人が承認 |
| A | batch を組む代金 | Int64 の鍵・300 体で 0.2 ms 以内を Batch.flix の pure なベンチで見る |
| G | WebGl2 の実機の確認が browser の計画の確認待ちになる | engine_web のビルドが通るまでで止め、実機は browser の計画に混ぜる |
| 全体 | M4 Pro でしか測っていない | 目標は M4 Pro の値。Windows の機械が手に入れば C0 と A の後に 1 回ずつ |
| 将来 | — | 前もって書き出したアニメの texture（VAT・vertex animation texture） |

## 4. 昇格の表（E）

| モジュール（conduit_hive） | 判定 | 行き先・名前 | 変える所 | ゲームに残す所 | 見積もり |
|---|---|---|---|---|---|
| render/VideoRender | 昇格（優先 1） | engine_full/src/full/VideoOut.flix に flow を撮るつなぎの関数を 1 つ（`App.Headless.videoJob`・`Flow.worldsOf`・`AudioMixdown` は既にある） | sceneOf と音の一覧を引数に | 群れの始まり・描く関数 | 1 日 ＋ 写し 8 本の追随（conduit_hive・dungeon3d_lab・fps3d_lab・hd2d_lab・night_apartment・test_rpg・templates/rpg-starter・templates/tidepool-starter） |
| CollisionWorld3d.raycast | 新設（Projectile3d より先） | engine/scene3d CollisionWorld3d.raycast（線分の問い・Godot の intersect_ray。`Ray3d.hitBox` の上に） | — | ゲームの `Collider.isLineClear`・`Hitscan`・`Projectiles.wallHit` が共通に使う | 1〜1.5 日 |
| Walker | 昇格（night と conduit に写し） | engine_world FirstPersonController3d（3D 専用は 3d で終わる・flix-conventions.md:210） | Settings・Clock[c]・動く箱と Surface を任意に | WalkDoc・キー | 2 日 |
| Creatures の姿勢の共有 | 昇格（B と組） | engine_world AnimationSharing3d | Kind・Clip を型引数・組の数と fps を Settings | glb・クリップ名 | 1.5〜2 日 |
| Particles3d | 新設しない | engine の Fx / FxDoc（docs/modules/fx.md:22-23）の結果を `Scene3d.Billboard3d` へ写す関数と、FxDoc の 3D の欄 | Doc の形式を 2D と 3D で 2 つに割らない | particle の絵・Doc の値・種類 | 2 日 |
| Gibs・Grenades・Knockback.Flight の放物線 | 共通部だけ昇格（raycast の後） | engine_world Projectile3d | 床 y=0 をやめ CollisionWorld3d.raycast | 肉片・起爆・のけぞり | 1.5〜2 日 |
| CameraShake | engine へ合流 | CameraRig の ShakeSpec・addTrauma・shakeStrength・shakeOffset（CameraRig.flix:103-133）に回転を返す shakeRotation を足す | 減り方は今の trauma の減り方のまま | 撃った時の spike の量 | 0.5 日 |
| HordeBench の測り方 | FrameBench は作らない | /perf の答え（`perfSummary`）に Scene3dCounts と submit の分布を足す（C0 の 5）。統計は App.HitchDetector・engine_tools の CpuTiming | — | 組・場面・timeline の中身 | C0 に含む |
| FpViewmodel の jointAttachment | 削除 | engine に既にある `Pose3d.jointTransform`（Pose3d.flix:41-44）を使う | — | 武器・揺れ・Doc・銃口の行列の式 | ゲームの直しだけ 0.5 日 |
| Separation | 昇格候補（中） | engine_world Separation | 升の大きさ・動かない円・壁の注入 | 敵の型・攻撃 | 1.5 日 |
| FlowField | 昇格しない（GridSearch.distances と重なる） | 代わりに engine_world の Steering に downhillOf を新設（今の engine には無い） | 距離場の上で 1 歩ずつ下る | Maze | 0.5 日 |
| Spawner.placeOf | 保留（2 本目待ち） | SpawnPoints | — | Waves | — |
| Tracers | 保留（小さい） | — | — | — | — |
| hit stop | しない（既に TimeScale・Clock.withSlow） | — | — | hitStopPlan | — |
| BlastFx | しない（このゲームの絵）。材質 1 つ + Param の手は docs/scene3d.md へ | — | — | 全部 | — |
| Collider・Stamina・Moves・Pilot・Sounds | しない（ゲームの規則・表） | — | — | 全部 | — |

昇格したら: docs/modules の 1 行・agents-pack/AGENTS.core.md の早見表・agents-pack/agent-eval/engine.json のお題・bin/lint-rules/forbid.json（古い書き方を止める）・
night_apartment と conduit_hive の追随・VideoRender の写しの追随。

## 5. 見積もりの合計

| フェーズ | 見積もり | 備考 |
|---|---|---|
| C0 | 1.5〜2 日 | Scene3dCounts 7 つ・区間の時間・/perf の答え・2 回塗り |
| C1 | 3.5〜4.5 日 | 参照の一致が書けるかの確かめ 0.5・並べ替え 1〜1.5（材質・lit・影の 3 つの道）・mip copy 0.5〜1・scratch 0.5〜1・boxesNear 0.5 |
| G | 2〜3 日 | 問い 1 が推しの時。C9 を丸ごと先にすると 2〜3.5 週 |
| B | 5〜6.5 日 | rev1 の 3〜4 日に、prepare ごとに回す分・場面の分けを prepare へ移す分（0.5〜1）を足した（参照の一致の確かめは C1 へ移した） |
| A | 8〜10 日 | rev1 の 1〜1.5 週に、版を 1 本にする分（VAO の 8〜15 と小物の場面の測りを含む）・置き場の spike・材質の解決を batch ごとに・GlContext の上で書く分を足した |
| A2 | 3〜4 日 | |
| **engine の速さの分（C0〜A2）** | **23〜30 日** | 1 本の道（並べられない） |
| E（engine の側） | 12〜13.5 日 | 4 節の表の合計。E-world と E-full は G〜A2 と並べる。E-engine（raycast 1〜1.5 日）は C1 の直後に 1 本の道へ入る |
| E（追随） | 2〜3 週（10〜15 日） | docs・agents-pack・agent-eval・forbid・ゲーム 2 本・VideoRender の写し |
| その他 | 1〜1.5 週（5〜7.5 日） | レビュー役との壁打ち（C1・B・A・E）・文書（performance.md §11・docs/scene3d.md・docs/backend-parity.md）・リリースと `make agent-eval-release`・ゲームの追随の確かめ・C0 の 1 の代わりの手（Starts に horde300 を足す 0.5〜1 日） |
| **仕事の合計（D なし）** | **50〜66 日（約 10〜13 週）** | 全部を足した量 |
| **暦の長さ（D なし）** | **39〜54 日（約 8〜11 週）** | C0〜A2 の 1 本の道 ＋ E-engine ＋ 追随 ＋ その他。E-world と E-full は G〜A2 と並べて道の外に出る |
| D（条件付き） | +5〜7 日 | C10a を前へ引く。入れるかは A の後の測りで決める |

## 6. 人への問い（2 つ）

### 問い 1. C9 の 3D の部分を先に出すか

plans/engine-core-polish.md:77 の「3D のシューティングを先に作ると決めたら C9 をブラウザの前へ」の条件を conduit_hive が満たした。

| 案 | 中身 | 代金（今） | 後で払う代金 |
|---|---|---|---|
| **推し: B と A が使う GL の呼び出しだけを先に GlContext へ（G）** | drawElementsInstanced・RGBA32F の texImage / texSubImage（と要れば vertexAttribIPointer）を 3 実装に。ほかの約 280 行は C9 のまま | +2〜3 日 | C9 で JointTexture・Instancing を書き直さない |
| LWJGL に直に書き、Instancing.flix・JointTexture.flix に閉じ込める | G をしない | 0 | C9 で 2 ファイルを書き直す（+3〜5 日）・その間 GlCallLog に instancing が出ない |
| C9 を丸ごとブラウザの前へ | 3D の GL を全部 GlContext へ移してから B・A | +2〜3.5 週 | browser の計画が後ろへずれる・fge-web.js の変更中の作業とぶつかる |

### 問い 2. 昇格の追随を同じ版で行うか

この版で増える新しい pub（追随の対象。docs/modules・早見表・agent-eval のお題もこの一覧で数える）:

| パッケージ | 新しい pub |
|---|---|
| engine | `FrameDiagnostics.Scene3dCounts` の 7 欄（meshUploads・meshEvictions・texture3dUploads・mipCopies・materialBuilds・jointUploads・targetRebuilds）・`CollisionWorld3d.raycast` |
| engine_world | `FirstPersonController3d`・`AnimationSharing3d`・Fx の結果を `Scene3d.Billboard3d` へ写す関数（と FxDoc の 3D の欄）・`CameraRig.shakeRotation`・`Separation`・`Steering.downhillOf`・`Projectile3d` |
| engine_full | `VideoOut` に flow を撮るつなぎの関数 1 つ |

| 案 | 中身 | 代金 | リスク |
|---|---|---|---|
| **推し: engine の昇格と、conduit_hive・night_apartment の追随を同じ版に。ほかのゲームの VideoRender の写しは forbid.json で次に触る時に止める** | engine の側 12〜13.5 日 ＋ 2 本の追随と templates 2 本 | 追随 2〜3 週のうち約 1.5 週を今払う | ほかの 4 本（dungeon3d_lab・fps3d_lab・hd2d_lab・test_rpg）は、次にコミットする人の手を forbid.json が止め、その場で VideoRender を VideoOut へ移す手間（1 本 0.5 日ほど）を払わせる |
| 全部のゲームを同じ版で追随 | 写し 8 本とゲーム 2 本を全部 | 2〜3 週を全部今払う | 版が出るのが約 1 週遅れる |
| engine だけ先に出し、追随は次の版 | 昇格した API と docs だけ | 追随 0 | 新しい API に使い手がいない間、agent-eval のお題が当たるか確かめられない |

### 推しで決めて書き切った物（問いにしない）

- batch は自動だけ（明示の MultiMesh3d は作らない）。
- mip copy は予算超えで eviction（Texture3d は C0 の結果次第）。
- 1 体ごとの値は tint と emissionIntensity から（conduit_hive の敵が使う 2 つ）。
- 目標値は各フェーズに根拠を書いた（C1: spike の無い horde300 の p95・A: submit の減り分）。
- Par は条件付きで A の後。
- CameraShake の減り方は今の trauma の減り方のまま、回転を足すだけ。
- GL の撮り直しで SHA が変わった時は、差の数を見せて人が承認する（rev1 の問い 5 は手順に入れた）。

## 7. rev2・rev3 で採らなかった指摘

1 回目の 10 項目・2 回目の 9 項目とも全部採った。ただし根拠のうち次の所は、ソースで確かめた結果に合わせて書き替えた。

1 回目の採点:
- 項目 5「GlContext の実装は LwjglGl と WebGl2」: RecordingGl（render_gl/java/fge/gl/RecordingGl.java・GlCallLog が包む版）も GlContext を実装しているので、
  足す呼び出しは 3 実装に書く（G フェーズ）。
- 項目 5「WebGL2 は JSBody 4 行」: 既存の WebGl2.java は 1 つの呼び出しにつき `@JSBody` の注記・native の宣言・委譲の 3 行（:117-125）。
  足す呼び出しは 3〜4 個（drawElementsInstanced・texImage2D・texSubImage2D と要れば vertexAttribIPointer）なので 9〜12 行。
- 項目 7「VideoRender の写しは 6 本」: engine の templates/rpg-starter と templates/tidepool-starter にもあり、8 本（Studio の同梱分は templates の生成物なので数えない）。
- 項目 7「docs/modules/map.md:30」: その行は TileScene で、Fx・FxDoc とは関係が無い。根拠は fx.md:22-23 だけにした（中身の判定「Particles3d を新設せず Fx / FxDoc」は採った）。
- 項目 9「インスタンスの値を texture に置く案（Bevy の WebGL2 の道）」: 案そのものは A の 1 で比べたが、Bevy がそうしているかはこのリポジトリの中で確かめられないので、
  Bevy の名前は付けなかった。
- 項目 9「姿勢は参照の一致 → 鍵 → 全部比べる」: Flix で参照の一致が素直に書けるかは未確認なので、書けなければ鍵が同じ時も毎回全部比べる代替を付けた（C1 の 1・B の 1）。

2 回目の採点:
- 項目 2「DevTools.flix:150 の App.canDebug」: 見張りを始める行は DevTools.flix:152（`startDesktop` の中）で、`App.canDebug` の本体は App.flix:536-538。行番号だけ直した。
- 項目 2「start horde300 を withStarts で足す」: conduit_hive の `Game.app` には既に `App.withStarts(Starts.all() ...)` があるので、足すのは `withStarts` ではなく Starts の 1 行。

## 8. 人の決定（2026-11-05）

- 問い 1: 推し（B と A が使う GL の呼び出しだけを先に GlContext へ・G フェーズ）。
- 問い 2: 推し（conduit_hive・night_apartment・テンプレ 2 本は同じ版で追随・ほかの 4 本は forbid.json で次に触る時に止める）。
- 新しい pub の一覧（6 節の問い 2 に添えた物）は全部承認。

## 9. C0 の結果（2026-11-05）

### 答え

submit の 40〜45 ms の跳ねは **見立て ①（使わないコマ数で捨てた物の上げ直し）** だった。捨てられて上げ直していたのは、
蹴りの間だけ出る脚（conduit_hive の boot.glb: 形 2 つ・1024×1024 の絵 2 枚）。自動の操縦は 128 コマより間を空けて蹴るので、
蹴るたびに形 2 つと場面の絵（Texture3d）2 枚が置き場から消えていて、次の蹴りで CPU の `Mip.build` からやり直していた。
mip copy（登録の絵の読み戻し）はこのゲームでは一度も起きていない（mipCopies 0）。

### 測り方

- 最初の 3 つ: HordeBench は `App.withDebug` を通していなかったので見張りが乗らなかった。HordeBench に `App.withDebug(App.debugOf(env))` を 1 行足した
  （Starts に足す代わりの手は要らなかった）。record.flow は書かれ、World は HordeBench 専用の init から始まるので、`App.withStarts` 無しの再生でも同じ始まりから流れた
  （/perf の 2 回とも、生の run と同じコマで跳ねた＝始まりが合っている証拠）。
- 生の run（DEBUG・vsync あり・960×540・3 分・horde-waves300）: submit p50 6.0 / p95 9.17 / max 54.3 ms・最悪の 3 コマは submit 44〜46 ms（bench の 1575・12232・13094 コマ目 = App の f1876・f12533・f13395）。
  ヒッチの見張りは 1 実行 10 件の上限で f1616 までに埋まり、後半の跳ねは hitch.md に出なかった。後半は /perf（上限 50）で拾った。
- 同じ記録（`debug/c0/run1.flow`・13808 コマ）を 1 つのプロセスで /perf に 2 回流した。

| 組 | 回 | 塗る時間 p50 / p95 / max | submit p50 / p95 / max | 上げ直し（全コマの合計） | ヒッチ |
|---|---|---|---|---|---|
| 今の形 | 2 回目 | 11.66 / 13.06 / 67.47 | 6.39 / 8.91 / 64.14 | mesh 57・evict 35・tex3d 30・material 4・joints 1,386,868 | 14 件（f1874・f12531・f13393 が 48〜67 ms） |
| `FGE_SCENE3D_EVICT=budget` | 1 回目 | 11.76 / 13.11 / 47.85 | 6.39 / 8.83 / 43.16 | mesh 26・tex3d 11・material 6 | 10 件（f1874 は蹴りの初回で残る・f12531・f13393 は消えた） |
| `FGE_SCENE3D_EVICT=budget` | 2 回目 | 11.63 / 13.07 / 42.97 | 6.38 / 8.91 / **25.44** | material 4 だけ | 3 件（どれも 17〜18 ms・GC 3〜7 ms 混じり） |
| `FGE_JOINT_UPLOAD=subdata` | 2 回目 | 17.52 / 24.19 / 60.66 | **12.03** / 18.28 / 56.24 | 今の形と同じ | 16 件 |

- 跳ねのコマの hitch.md の行は、今の形の 2 回とも同じ: `mesh 2 / tex3d 2`・3D の CPU の区間の draw が 40〜61 ms（ふだんは 3〜5 ms）・shaders 0・GC 0（f1874 の 2 回目だけ GC 21 ms が重なった）。
- JFR の標本（20 ms ごと）で、跳ねの時刻に `Mip.halve`・`Mip.colorMeanOf` が出る（全 5300 標本のうち Mip が 38・`uploadMipChain` と `glTexImage2D` は 0）。重さは GL ではなく CPU の mip 作り。

### 当たらなかった見立て

- ② UBO の orphan: 跳ねの原因ではない。joints は 1 コマ平均約 103 回で、跳ねのコマも 124〜184 回とふだん並み。
  逆に orphan を止める（subdata）と submit の中央値が 6.4 → 12.0 ms に倍増した（GL-on-Metal は使用中のバッファへの書き込みで待つ）。Render3d.flix の putJoints の WhyNot は正しい。
- ③ 一度きりの物: 2 回目でも同じコマで跳ねたので違う。deopt は起動と 1 回目の頭に集まり（894 件のうち 729 件が最初の 1 分）、跳ねのコマの位置とは関係なく 2 回目も同じコマで跳ねた。シェーダーは 0 本。
- ④ GC: 生の run の G1 の止まりは最大 9.3 ms（402 回）。/perf の中は最大 43 ms まで伸びるが、/perf が流し終えた 13808 コマ分の World を持ったまま塗るためで、跳ねのコマの GC は 0。
- ⑤ 材質のプログラム: 跳ねには関わらない（後半は 0）。ただし前半の f777（split 11 ms）は materialBuilds 2 で、**3D の材質のプログラムは hitch.md の「シェーダーを作った」に数えられていなかった**（今回の materialBuilds で初めて見えた）。

### C1 で直す物（順）

1. **形と場面の絵を、使わないコマ数で捨てない（上限を超えた時だけ古い物から捨てる）。** 計画の C1 の 2 では「①が当たった時だけ Texture3d も予算超えだけ」としていた分を、
   形（meshIdleFrames）にもそろえて採る。形にはもう `vertexBudget` があり、場面の絵には `textureCountBudget`・`textureByteBudget` がある。
   これだけで /perf の 2 回目の submit max が 64 → 25 ms・ヒッチ 14 → 3 件。C1 の目標の最大 ≤ 20 ms の主役はこれで、並べ替え（C1 の 1）ではない。
2. **初めて出る物の上げ（f1874 の 1 回目 48 ms・入った直後の f629 の 41 ms）を読み込みの間に済ませる口。** 予算で捨てない形にしても、1 回目の `Mip.build` は残る。
   選ぶ道は 2 つ（どちらも C1 の範囲を広げるので相談）: ゲームが読み込みの間に間引いた物として 1 度置く（`noteCulled` が絵を上げる道が既にある）か、`Mip.build` 自体を速くする
   （Vector と Tagged の箱を通らない配列の道へ。1024×1024 の 2 枚で 40 ms は重すぎる）。
3. C1 の 2（mip copy を予算に数える）はこのゲームでは起きていない（mipCopies 0）。同じ形の直しなので 1 と同じ手で一緒に入れてよいが、順は下げる。
4. C1 の 1（(program, 姿勢の鍵) の並べ替え）は跳ねではなく中央値と p95 の直し。orphan は要る（subdata で倍）ので、回数を減らす並べ替えの意味は残る。目標の submit 中央値 ≤ 5.0 ms はこちらで測る。
5. 見張りの穴: 1 実行 10 件の上限で、3 分の bench の後半の跳ねが hitch.md に出ない。/perf の上限 50 で足りたので急がないが、hitch.md の「シェーダーを作った」に材質のプログラムを入れるかは決めておく。

### C0 で足した物

- `FrameDiagnostics.Scene3dCounts` に meshUploads・meshEvictions・texture3dUploads・mipCopies・materialBuilds・jointUploads・targetRebuilds と `cpuPhases`（shadows・split・draw・endFrame。入れ子を引いた残り）。
  pub: `FrameDiagnostics.uploadsText`・`cpuPhasesText`・`addScene3dCounts`。`summaryLines` は 3D を置いたコマだけ 5・6 行目を足す。
- hitch.md: 「数」の次に 3D の行・推定原因に「重いコマで 3D の絵か形を GPU へ上げた」・表に「3D の上げ直し」「3D の CPU」の 2 列。
- /perf の答え: submit の p50 / p95 / max・3D の上げ直しの合計・3D の CPU の区間の合計。
- render_gl/src/Render3d/Counts.flix（数と区間と切り分けの env）。`FGE_JOINT_UPLOAD=subdata`・`FGE_SCENE3D_EVICT=budget` は C1 で答えを入れたら消す（release に載せない）。
- 数と区間は Render3d が毎コマ集め、診断を切っている間は Paint が捨てる（前からある数と同じ形）。区間の時刻は 1 コマに十数回の nanoTime。

## 10. C1 の結果（2026-11-05）

### 入れた物（人が決めた順）

1. **形・場面の絵・mip の写しを、使わないコマ数で捨てない。** 形は `vertexBudget`、場面の絵と mip の写しは `textureCountBudget`・`textureByteBudget` を超えた時だけ、今と前のコマで使っていない古い物から捨てる。
   mip の写しはバイトの上限にだけ数える（枚数には数えない）。捨てる物を選ぶ所は純粋な `Render3d.Material.budgetEvictions`（テストつき）。
   毎コマ新しい鍵が来る物は上限で押し出される（`noteUploadStreak` の知らせは今のまま）。`FGE_SCENE3D_EVICT`・`FGE_JOINT_UPLOAD` と `Render3d.Counts.Bisect` は消した。
   `meshIdleFrames` は影の地図の描き先にだけ残ったので `idleTargetFrames` に改名。
2. **`Mip.build` / `Mip.shrinkTo` を配列の道へ。** 遅さの主因は箱ではなく `Int32.logicalRightShift` が呼ぶたびに引数のレコードを作ること（1 画素 16 回）と、
   sRGB の 255 本のしきい値の二分探索の分かれ道の外れだった。シフトを `rightShift` と 255 の mask に、二分探索を「4096 等分した区間の左の端までの数から数え始める」に替えた（比べる式は同じなのでバイトは同じ）。
   1024² の絵 1 枚（engine のテストを並べて流した中の数）: sRGB 70〜90 ms → 8〜13 ms・Raw 33 ms → 5〜7 ms。テスト `TestMip` に前の素直な実装を基準として置き、奇数・細長・正方の 6 つの大きさで段の列のバイト一致を見る。
3. **conduit_hive の先上げ（`src/GpuWarmup.flix`）。** engine には口を足していない。起動から 0.25 秒は「遊びの途中で初めて出る物」を全部（約 70 個）視錐台の外へ置き、
   その後は材質のプログラム 1 つにつき 1 個（11 個）だけを置き続ける。置き続けるのは、材質のプログラムの置き場が使わない物を上限（今使っている数の 2 倍・16 以上）で追い出すため
   （0.25 秒だけの版では /perf の 2 回目にも f764・f777・f959 で組み直していた）。全部を置き続けると horde50 の submit が約 0.3 ms 増えたので絞った。
   骨つきの物は engine が間引かない（姿勢で形が境界の外へ出うる）ので、姿勢を外して置く。そのため骨つきの版の材質のプログラムだけは先に組めない（敵と構えている銃は始めから画面にいるので、そこで組まれる）。
4. **3D の材質のプログラムを hitch.md の「シェーダーを作った」に数える。** `Scene3dCounts#materialBuilds` を数から「組んだ物の列（名前と理由）」に替え、`Paint.consumeDiagnostics` が `shaderBuilds` の後ろに足す（`liveShaders` には数えない）。
5. **並べ替えと 1 体ごとの手間。** 最初に確かめた: Flix の値は `Reflect.reflectValue` → `java.util.Objects.equals` で参照の一致が書ける（同じ値は真・中身の同じ別の値は偽。仮に将来 equals が中身の比べになっても、飛ばしてよい条件としては安全側）。
   - 姿勢の鍵 `Pose3d.keyOf`（joint 行列の全部の数のビットから作る 64 bit・初めて読んだ時に求めて持つ。1 つの数だけが違えば必ず違う鍵）。
   - 不透明の材質の道（Color と Depth）・材質の無い lit の道の骨つき・影の道の骨つきを `Render3d.inDrawOrder`（第 1 の鍵・第 2 の鍵・元の添え字）で並べる。材質の道はプログラムと姿勢の鍵・ほかは姿勢の鍵。
   - `putJoints` は前に書いた姿勢と同じ値なら中身を作らずに飛ばし、鍵が同じだけの時は今まで通り中身を全部比べる。`needsUpload` は `List.range` を作らないループに・model と normal の行列は State の置き場を使い回す。
   - `CollisionWorld3d.boxesNear` の `Map.size` を build の時に数えて持つ。

### 数（同じ機械・ウィンドウ 960×540・vsync あり）

/perf の 2 回塗り（C0 の記録 `debug/c0/run1.flow` を 1 つのプロセスで 2 回。2 回目の値）:

| 組 | 塗る時間 p50 / p95 / max | submit p50 / p95 / max | 上げ直し（全コマの合計） | ヒッチ |
|---|---|---|---|---|
| C0 の今の形 | 11.66 / 13.06 / 67.47 | 6.39 / 8.91 / 64.14 | mesh 57・evict 35・tex3d 30・material 4・joints 1,386,868 | 14 件（48〜67 ms） |
| C0 の `FGE_SCENE3D_EVICT=budget` | 11.63 / 13.07 / 42.97 | 6.38 / 8.91 / 25.44 | material 4 | 3 件 |
| **C1** | **8.83 / 11.90 / 43.14** | **5.03 / 7.33 / 27.56** | **joints 438,389 だけ（−68%）** | **0 件** |

- 1 回目は f634 に骨つきの版の材質のプログラム 1 つ（split 7.75 ms・上の 3 の決め通り）と、GC の混じる 22〜30 ms が 3 コマ。2 回目の max は /perf が流した 13808 コマぶんの World を持ったまま塗る GC（C0 の 9 節と同じ）。
- joints の 1 コマ平均は約 103 → 約 32。

`make bench-horde BENCH_SETS="horde50 horde-waves300"`（conduit_hive/plans/bench-horde.md の「C1」の節）:

| 組 | | work 中央値 / p95 / 最大 | submit 中央値 / p95 / 最大 | 間隔の最大 |
|---|---|---|---|---|
| horde50 | 前 | 6.81 / 8.06 / 9.70 | 3.21 / 4.16 / — | — |
| horde50 | C1 | 6.75 / 8.31 / 25.1 | 3.28 / 4.72 / 5.62 | 27.5 |
| horde-waves300 | 前 | 11.80 / 16.29 / 49.9 | 5.74 / 9.56 / 45.16 | 50.0 |
| horde-waves300 | C1 | 11.10 / 14.34 / 25.15 | 5.89 / 8.68 / 13.78 | 25.4 |

- 途中の submit の跳ね（40〜45 ms）は消えた。submit の最大は 13.8 ms。残る 20〜25 ms のコマは submit 6〜8 ms で、swap の待ち（8〜12 ms）か GPU の重い所。
- horde50 の最大 25 ms は測り始めの 30 コマ目（submit 3.4 ms・GC か JIT の見込み）。
- bench の中央値は回ごとの揺れが大きい（同じ組で倒した数が 2820〜3436・最後の draw call 304〜411）ので、中央値の比べは /perf の方を信じる。

### 目標に届いたか

| 目標（horde-waves300） | 値 | |
|---|---|---|
| 最大 ≤ 20 ms | bench の work 最大 25.2・submit 最大 13.8 / /perf 2 回目 ヒッチ 0 件 | 跳ねの原因（上げ直し）は消えた。20 ms 越えは swap と GC で、submit の側では届いた |
| p95 ≤ 12 ms | bench の work p95 14.3 / /perf の塗る時間 p95 11.9 | /perf では届いた・bench では届かない |
| submit 中央値 ≤ 5.0 ms | bench 5.89 / /perf 5.03 | 届かない（/perf は 6.39 → 5.03） |
| horde50 は悪化しない | work 中央値 6.81 → 6.75・submit 3.21 → 3.28 | 揺れの内 |

### ゲート

- engine 827・render_gl 151・engine_world 1385・engine_tools 265・conduit_hive 231 が緑。
- `make gl-parity` 全一致・`make baseline-check` は GL の絵の差 0 枚・CPU の絵はバイト一致（並べ替えで同じ深さの面が変わった場面は無かった）。
- テンプレの CPU の絵: tidepool 8 枚・novel 34 枚が HEAD の worktree の描き出しとバイト一致・rpg 16 枚が基準と一致。
  tidepool と novel は HEAD でも `reference/SHA256SUMS.txt` と合わない（C1 の前からの差）。`baseline-check GALLERY=1` は `bench/baseline/0.79.0/reference-gallery.sha256` が無くて止まる。

### 見つけたこと（C1 では直さない）

- 材質のプログラムの置き場の追い出し（上限 = 今使っている数の 2 倍・16 以上）が、たまにしか出ない物のプログラムを消す。ゲームの先上げで逃げたが、形と絵と同じく「上限を超えた時だけ」にそろえるかは engine の相談。
- 骨つきの物は視錐台の外でも描く（`Scene3d.isOutsideFrustumFields`）。300 体のうち画面の外の敵も毎コマ描いている。境界を姿勢で広げて間引くかは B・A の前に測る価値がある。
