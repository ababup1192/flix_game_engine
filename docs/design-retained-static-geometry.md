# 静的ジオメトリの retained 化 設計書（改訂 v2）— 洞窟 B2 を速く、z 順を守って

対象: `flix_game_engine`（Flix 製 2D エンジン・LWJGL/GL バックエンド）と、fpkg で使う `flix_ge_dungeon`。
目的: 洞窟 B2 の描画を 50〜60fps から引き上げる。手段は「毎フレーム作り直している静的な壁・床の頂点を、1 度だけ GPU に載せて使い回す」。ただし **絵を 1px も変えない**（特に同じ z の中の重なり順）。

> この v2 は超批判レビュー（`scratchpad/retained-review.md`・採点 62/100）を受けた作り直し。v1 の致命傷「静的を別 draw call で先に一括描画すると同 z の重なり順が壊れる」を、レビューの (b) 案「1 パスの z ソート列に静的 VBO 参照を残す」を軸に解いた。

---

## レビュー指摘 → どう直したか（対応表）

| 指摘 | 深刻度 | v2 での対応 |
|------|--------|-------------|
| **C1: 静的を別 draw call で先に一括描画すると同 z の重なり順が壊れる**（dungeon は z=2 で壁が液体の粒を隠す・z=5 で床飾りと松明が同居し、同 z 内の描画順に絵が依存） | 致命傷 | §2 を全面書き換え。**静的を別 draw call で分離する案を破棄**。静的多角形を「z キー付きの永続 VBO レンジ」にし、動的アイテムと**同じ z ソート列にマージ**。`renderFrameMixed` の既存 run flush に「静的レンジ描画」という第3の run 種を足すだけにして、**列順（=重なり順）を完全保存**。同じ最終描画順になることを §2.3 で型と擬似コードで示す。 |
| **R1: スナップショット（SoftRaster）は retained の退行を検知できない**（GL 経路を通らないので z 順破綻を素通し）。「1165/0 で安全」はミスリード | 要修正 | §4 を訂正。「1165/0 は fe_rogue 非回帰の確認であって retained の安全証明ではない」と明記。**glReadPixels で GL 画面を PNG 化し retained ON/OFF を diff する自動ゲート**を §4.2・各里程標に据える。dungeon に絵のスナップショットが無い点も §4.3 で直視。 |
| **R2: renderCommands は1回で swap する**。op を分割すると clear/swap 境界を跨ぐ | 要修正 | §3.1 を再設計。op を「init/free の2本＋既存 renderCommands の署名拡張（静的ハンドル列を**同じ呼びに載せる**）」にし、**clear→（z 順に static/dynamic 混在描画）→swap を renderCommands の中で1回で束ねる**。swap は最後の1回だけ。 |
| **R4: VBO ハンドルを App ランナーの可変状態に置くのは値ベースを壊す** | 要修正 | §2.4 を訂正。タイル経路と同じく **ゲーム World が `StaticVao` を保持**。鍵比較・free/init の対も **ゲームの step 内**で行う。App ランナーに可変状態を持ち込まない。 |
| **R3: カメラ uniform 化の丸め順一致は dungeon(zoom=1)では非問題だが、Float64/Float32 差は順序合わせでは消えず zoom 横展開で再燃** | 要修正 | §2.2・§5 段階5 に但し書き。**v1 は dungeon（平行移動のみ）に限定**。zoom を使う横展開時は「Float64 頂点乗算 vs Float32 uniform 乗算」を glReadPixels diff で再検証する条項を明記。 |
| **D1: 90〜120fps は線形近似。fill rate バウンドなら頭打ち** | 論点 | §5 段階0 に「静的を完全に描かない（空 VBO）実験で到達 fps 上限を測り、CPU 提出バウンドか fill rate バウンドかを**投資判断前に**切り分ける」を必須項目として追加。§7 の見積もりをこの実測に委ねる形へ。 |
| **D2: 全量 GPU 送り vs 空間分割（未実測・単一 VBO 前提）** | 妥当な保留 | §6 で単一 VBO から始め段階3で実測する順序を維持（レビューも妥当と判定）。 |
| **D3: engine op 追加は全 example に波及・uniform 漏れ配線** | 論点 | §3.3 で「多角形シェーダの `viewOffset`/`viewScale` uniform は毎 draw call で明示リセット（sprite の multiplyBlend と同じ作法）」を明記。engine 拡張は §3 冒頭どおり事前相談材料。 |

自認弱点の再判定: #1(z順)は**過小評価＝致命傷**だったと認め §2 を作り直した。#2(空間分割)は保留を維持。#3(engine op)は対策（glReadPixels ゲート・World 保持・uniform リセット）を足した。

---

## 0. 読んだファイルと確認した事実（コード引用で確定）

### カメラの当て方（retained 化の可否を決める最重要点・確定）

- **`withView` 経路のカメラは「App が CPU で全 item の座標を一様にずらす」方式。GL の uniform ではない。**
  - `App.composeScene`(`engine_world/src/App.flix:366-372`) → `CameraRig.centerOn`(`CameraRig.flix:28-34`) が各 PlacedItem に `at = (at−center)×zoom + design/2`、`item = Render.scaled(zoom, item)` を CPU の `List.map` で適用。
  - 多角形は `Render.scaled` の Poly 分岐(`Render.flix:368`)で全頂点を `List.map(v -> Vec2.mul(v, factor))`、`polyCmd`(`Render.flix:439`)で全頂点に `Vec2.add(v, pos)`。→ 多角形は「camera を書き込んだスクリーン座標」で GL に届く（`PolygonRenderCmd.vertices` は「スクリーン px に変換済み」・`DrawCmd.flix:116`）。
  - GL の多角形シェーダ `polyBatchVertexShaderSource`(`Shader.flix:284-293`) は `projection`（zoom 無し正射影）のみで座標変換 uniform を持たない。

- **タイル経路は既に retained + uniform（この設計のお手本）。** `initTileBuffer`(`GameEngine.flix:181` op、実装 `LwjglLayer.flix:518-522`) → `buildTileInstanceVBO`(`Sprite.flix:176-200`) が `GL_STATIC_DRAW` で 1 度だけ頂点を載せ、`GpuHandle.TileVao`(`GpuHandle.flix:11`) で持ち回る。毎フレームは `drawTileMapInstanced`(`Sprite.flix:232-247`) が `glDrawArraysInstanced` を呼ぶだけで、位置とズームはタイル頂点シェーダの `layerPos`/`tileScale` uniform(`Shader.flix:126-144`)。

### 1 パス z ソートの構造（C1 の核心・別 draw call 分離が壊す理由）

- 通常経路は `App.renderFrame`(`App.flix:772-780`) が `sceneItems`（world+hud 全部合成）→ `Render.draw` → **1 回の** `GameEngine.Game.renderCommands(sprites, Nil, polygons)`。
- `renderFrameMixed`(`Frame.flix:167-175`) が **sprites と polygons を 1 本の列にマージ**（`List.append(sprites map Ok, polygons map Err)`）して `stableByZ` で z 安定ソート。
- `renderFrameMixed`(`Frame.flix:330-338` のコメント原文): 「スプライト run と多角形 run を並行して溜める。種類が切り替わる瞬間にもう一方を吐き出すことで、**sortedMerged の列順（＝重なり順）を厳密に守る**」。同じ z 内は「入力順（sprites→polygons）」を stableByZ が構造的に保証(`Frame.flix:165`)。
- run を切るのはテクスチャ/scissor/blend の変化と、sprite↔polygon の種別切替のみ(`Frame.flix:200-209` の順序不変条件コメント: 「列順は一切入れ替えない」)。

### dungeon の z 表（同 z で静的/動的が同居・順序依存の 2.5D 演出）

- z 割り当て(`flix_ge_dungeon/src/View.flix:10-29`): 床0 / 水塗り1 / **液体表面(粒・むら)2 / 壁2** / フチ3 / 階段4 / **床飾り5 / 松明5** / 壁飾り6 / 北石柱9 / プレイヤー10 / 南石柱12 / …
- **z=2**: 壁(静的・`Surfaces.wallEntry`→`buildStatic`) と 液体表面の粒(動的・`Surfaces.surfaceItems`・毎フレーム `world#time`) が同居。コメント(`View.flix:15-16`): 「同 z では壁の多角形が粒より後に描かれる = 持ち上がった壁が粒を正しく隠す」。
- **同 z 内の sprite/poly 順に絵が依存**(`Surfaces.flix:17-18`): 「surface を liquid と同じ z にしてはいけない — 同じ z の中で箱・円(sprite系)を多角形より先に描くため、粒が塗りに覆われて消える（実バグ）」。
- **z=5**: 床飾り(静的 `zDecorFloor`) と 松明(動的 `zTorch`) が同居(`View.flix:21-22`)。
- **結論**: 静的を「動的の前に一括」描くと、同 z の前後が z でなく draw call 順に固定され、壁が隠すべき粒が壁の上に乗る等で崩れる。**別 draw call 分離は不可。**

### dungeon の静的の持ち方・camera

- 静的は `World.Prebuilt = { tiles: List[StaticTile], occluders }`(`World.flix:26-27`)、`StaticTile = { anchor, item: PlacedItem }`(`World.flix:21`) に生成済み。生成し直すのは `Controls.loadFloors`(起動時)・`Controls.reloadAll`(F1/保存時) だけ(`Controls.flix:54-62, 75-82`)。
- 毎フレーム dungeon の View.frame（View.flix:69-80）は `visibleStatic`(`View.flix:85-89`) で anchor カリングし `tile#item` をそのまま返す（頂点は作り直さない）。作り直しは全部下流（centerOn→draw→GL）。
- **dungeon は `withCamera(World.cameraCenter)` のみで zoom 未使用**（dungeon の Main.flix:22、ゲーム側で `withZoom` 0 件）。camera は毎フレーム平行移動だけ。静的頂点は zoom で変形されない。
- 静的:動的 ≈ 10:1〜100:1（`View.flix:65-68`「B2 は静止部品が数千個」）。

### 毎フレームのコスト（プロファイル 48%+26%）

- 多角形アップロードは毎フレーム `glBufferData(GL_DYNAMIC_DRAW)`(`Sprite.flix:166` の `drawPolygonBatch`)。→ 48% の `JNI.invokePV`。
- 三角形分割は毎フレーム `pushPoly` 内で `Triangulate.triangles`(`Frame.flix:310`)、頂点を 6 float 配列に詰め直す(`Frame.flix:313-315`)。→ 26% の `RecordExtend.lookupField`。

### renderCommands の swap 境界（R2）

- `renderCommands` ハンドラ(`LwjglLayer.flix:511-517`) は `renderFrame(...)` の直後に `glfwSwapBuffers(window)`。`renderFrameMixed` は冒頭で `glClear`(`Frame.flix:143-149`)。**1 呼び = 1 フレームを clear→描画→swap し切る。**

### スナップショット / 生成の独立性（R1）

- ゲーム側のテストはスナップショット比較で、 `SoftRaster.render`(`SoftRaster.flix`) の CPU 描画 PNG のバイト比較で、`org.lwjgl.*` を import せず render_gl 非依存。描き出しも `HeadlessRender.renderPng`→`SoftRaster`。→ **GL 経路を変えてもスナップショットは動かない = retained の退行を検知できない（R1 の核心）。**

### 切り分けトグルの前例

- `useRenderFromWorld()`(`fe_rogue/src/rendering/RenderToggle.flix`)・`useEcsCombat()`(`fe_rogue/src/combat/CombatToggle.flix`・呼び元 `CombatResolve.flix:51`)。1 箇所の `pub def … : Bool` で新旧経路を切替。踏襲する。

---

## 1. 問題の再定義

B2 が遅い直接原因は「中身が前フレームと同一の静的な壁・床を、毎フレーム『三角形分割 → float 配列組み立て → `glBufferData` アップロード』し直している」こと。タイルは既にこの無駄を解いている（頂点は GPU 固定・位置は uniform）。**多角形にも同じ解を、ただし z 順を壊さずに与えるのが本設計。**

---

## 2. 設計の核心：z 順を守る retained（「z キー付き静的 VBO レンジ」方式）

### 2.1 発想：静的を「別 draw call」でなく「z ソート列の一員」にする

v1 の誤りは「静的を先に一括描画」だった。v2 は逆に、**静的多角形を動的アイテムと同じ z ソート列に残す**。ただし、静的分の頂点は毎フレーム作り直さず、**初回に三角形分割済みで永続 VBO へ載せ、z ごとにその VBO の「どの範囲か（レンジ）」だけを軽い値として列に流す**。

- 初回（フロア/テーマ変更時）だけ: 静的多角形を **z 昇順に並べて三角形分割し、1 本の永続 VBO に連続配置**。同時に「z ごとの (開始頂点, 頂点数, blend, clip)」の目次（レンジ表）を作る。三角形分割はここで 1 回きり。
- 毎フレーム: 静的分は **`StaticRange`（VBO ハンドル + 目次の1エントリ + z）という軽い値**として z ソート列に流す。頂点は運ばない（`#vertices` の読みも起きない）。
- `renderFrameMixed` の run flush に **第3の run 種「静的レンジ描画」**を足す。sprite run・poly run と同じく、種別が切り替わる瞬間に他方を flush して列順を守る。静的レンジは `glDrawArrays(VBO の該当範囲)` を発行するだけ（アップロードなし・三角形分割なし）。

これで **z 順は 1 パスの安定ソートのまま完全保存**され、消えるのは「静的分のアップロード（48% の大半）と三角形分割/頂点組み立て（26% の大半）」だけ。

### 2.2 camera は uniform で当てる（頂点は不変・dungeon 限定で平行移動のみ）

永続 VBO には静的多角形を **ワールド座標**（pos 加算済み・zoom を掛けない座標）で載せる。毎フレームは camera を多角形頂点シェーダの uniform で当てる（タイルの `layerPos`/`tileScale` と同型）:

```
screenPos = (worldPos − viewOffset) * viewScale + halfDesign;
gl_Position = projection * vec4(screenPos, 0, 1);
```

- `viewOffset` = camera center（`World.cameraCenter`）、`viewScale` = zoom（dungeon では常に 1.0）。
- **dungeon は zoom=1 固定**なので `viewScale=(1,1)`。CPU の `centerOn`（`Vec2.sub(at, center)` + `Vec2.add(half)`）と式が一致し、頂点乗算は起きない。
- **但し書き（R3）**: CPU 経路は Float64 で引いてから Float32 化、retained はワールド座標を Float32 で確定してから Float32 で引く。**Float64/Float32 の精度差は式の順序合わせでは消えない。** dungeon（zoom=1・平行移動のみ）では 1px ずれる可能性は低いが、ゼロではない → §4.2 の glReadPixels diff で 1px でも差が出たら失格にして担保する。**zoom を使う横展開では `Render.scaled`(Float64 乗算) と `viewScale`(Float32 乗算) が割れるので、v1 は dungeon 限定とし横展開時に再検証（§5 段階5）。**

### 2.3 z 順が保存されることの型と擬似コード

**型（スケッチ）**: 既存の 2 種（`Drawable`=sprite、`PolygonCmd`=動的多角形）に第3種を足し、マージ列を 3 択にする。

```
// render_gl 側の内部型（DrawCmd には出さない・engine の Game op が StaticRange を運ぶ）
StaticRange = { vao = Int32, first = Int32, count = Int32,   // 永続 VBO の描画範囲（初回に確定）
                blend = BlendMode, clip = Option[Rect2],
                zIndex = Int32 }

// 現状: List[Result[PolygonCmd, Drawable]]（Ok=sprite, Err=poly）
// v2:   List[Merged] where Merged = Sprite(Drawable) | DynPoly(PolygonCmd) | Static(StaticRange)
```

**擬似コード（renderFrameMixed の fold を 3 種対応に拡張。既存の 2 run flush 機構をそのまま踏襲）**:

```
sortedMerged = stableByZ(zOf, sprites ++ dynPolys ++ staticRanges)   // z 昇順・同 z は入力順を保持
fold over sortedMerged, carrying (spriteRun, dynPolyRun):
  case Sprite(d):
      flushDynPoly(dynPolyRun)         // 種別が変わるので他方を先に吐く（既存の作法・Frame.flix:338）
      pushSprite(d) into spriteRun
  case DynPoly(pc):
      flushSprite(spriteRun)
      pushDynPoly(pc) into dynPolyRun  // 三角形分割＋アップロードは動的分だけ残る
  case Static(r):
      flushSprite(spriteRun); flushDynPoly(dynPolyRun)   // 両 run を吐いてから
      setScissor(r.clip); applyBlend(r.blend)
      drawStaticRange(r)               // glDrawArrays(vao, r.first, r.count) だけ・アップロードなし
```

- **列順は一切入れ替えない**（`Frame.flix:205-209` の順序不変条件を維持）。よって同 z 内の「壁(静的)が粒(動的)の後」も、stableByZ が入力順を保つ限り保存される。
- ただし **静的と動的が同じ z にいるとき、両者の相対順は「入力（sceneItems）に並べた順」で決まる**。現状は `sceneItems` が 1 本の PlacedItem 列を作り、`Render.draw` が sprite/poly に振り分ける。v2 では静的分が別チャンネル（`StaticRange`）で来るので、**z=2 で「粒(動的) → 壁(静的 range)」の入力順を再現する並べ方**を保証する必要がある（後述 §2.5 の合流点）。
- 静的レンジは連続する同 z・同 blend・同 clip をまとめて 1 本の `glDrawArrays` にできる（run 化）。三角形分割済みなので `Triangulate` は呼ばない。

### 2.4 VBO ハンドルと dirty 鍵は「ゲーム World が持つ」（R4）

タイル経路（`initTileBuffer` が `TileVao` を返しゲームが持つ）に合わせる。App ランナーに可変状態を持ち込まない。

- `initStaticPolys(cmds)` が `{ vao = StaticVao, ranges = List[StaticRange 目次] }` を返す。**ゲームの World がこれを保持**。
- ゲームの step が dirty 鍵を比較し、変わっていたら `freeStaticPolys(old)` → `initStaticPolys(new)` を **step 内で**行い、World のハンドルを差し替える。
- dungeon の dirty 鍵 = `{ floorId, gen }`（`Eq` を持つ軽い値）。フロア移動で `floorId` 変化、`Controls.reloadAll` が `gen +1`。**大きな頂点列の内容比較はしない**（鍵の `!=` だけ）。
- 生成し直すのは `loadFloors`/`reloadAll` だけなので、鍵の更新点は既存の 2 箇所に自然に乗る。

### 2.5 純粋 View を壊さない宣言 API と dungeon の合流点

`withView`（動的・List を返す即時モード）は engine の値ベースの芯。ここを汚さず、静的は別口で宣言する。

```
// App[w, ef] に足すフィールド（スケッチ・実装はしない）
staticLayer = Option[{
    key   = w -> StaticKey \ ef,                 // dirty 鍵（軽い Eq 値）
    build = w -> List[Render.PlacedItem] \ ef    // ワールド座標の静的 PlacedItem（camera 無し）
}]
```

- `build` は `withView` と同じ `PlacedItem` 語彙で書け、camera は App/GL が uniform で当てるので触らない。純粋関数（`w ->`）。
- App ランナーの `sceneItems` は、静的レイヤーの `build` 結果を **z 付きの `StaticRange` チャンネルとして動的アイテムと合流**させ、`renderCommands` に 3 チャンネル（sprites / dynPolys / staticRanges）で渡す（§3.1 の署名拡張）。
- **合流点の要（§2.3 の入力順保証）**: 静的レンジと動的アイテムは、それぞれの `zIndex` で `stableByZ` にかかる。同 z（例 z=2 の壁レンジと粒アイテム）の相対順は、App ランナーが **「静的レンジを動的アイテムより後に append する」規則**を固定すれば、現状 dungeon の「粒 → 壁」順（=壁が後で粒を隠す）と一致する。この規則が現状の絵と一致することを §4.2 の glReadPixels diff で機械確認する。

#### dungeon 側の呼び出し例（スケッチ）

```
App.make(World.initial(...))
    |> App.addSystem(Controls.step)                 // step 内で dirty 鍵比較 → free/init → World にハンドル保持
    |> App.withStaticLayer(
         { key   = w -> World.floorKey(w),           // { floorId, gen }
           build = w -> View.staticWorldItems(w) })  // Prebuilt#tiles をワールド座標で（camera 無し）
    |> App.withView(View.frameDynamic)               // 動的だけ（松明・プレイヤー・影・水面の粒）
    |> App.withHudView(View.hud)
    |> App.withCamera(World.cameraCenter)
    |> App.withCameraBounds(View.cameraBounds)
    ...
```

- 案の View.staticWorldItems（dungeon）は現状 View.buildStatic の書き込み内容を、camera 無し・ワールド座標で返す。
- 案の View.frameDynamic（dungeon）は現状 View.frame から動的行（`surfaceItems`/`Torches`/`columnItems`/`playerItems`/`lightingItems`）だけを残す。
- **注意**: z=2 の壁は静的、z=2 の粒は動的。両方 z=2 で同じソート列に入る。§2.3/§2.5 の入力順規則で「粒 → 壁」を保つ。

---

## 3. engine 側に足すもの（最小・要事前相談）

engine ソース変更は事前相談が必要（CLAUDE.md 方針）。本書がその相談材料。

### 3.1 op は init/free の2本 ＋ renderCommands の署名拡張（clear/swap を跨がない・R2）

v1 の「drawStaticPolys を別に呼ぶ」は clear/swap 境界を跨いで壊れる（`renderFrameMixed` の `glClear` が先に描いた静的を消す）。v2 は **描画を renderCommands の 1 呼びに束ねる**:

```
// GameEngine.Game eff（GameEngine.flix:176-216 に追加）
def initStaticPolys(cmds: List[PolygonRenderCmd]): { vao = GpuHandle.StaticVao, ranges = List[StaticRangeMeta] }
def freeStaticPolys(vao: GpuHandle.StaticVao): Unit
// renderCommands を拡張: 静的レンジ列を同じ呼びに載せる（clear→z混在描画→swap を1回で束ねる）
def renderCommands(sprites: List[Drawable], tileMaps: List[TileMapRenderCmd],
                   polygons: List[PolygonRenderCmd],
                   staticRanges: List[StaticRangeCmd]): Unit   // ← 引数 1 本追加
```

- `StaticRangeCmd` = `{ vao, first, count, blend, clip, zIndex }`（`DrawCmd` に置く共有型。SoftRaster は §4.1 の通りこれを見ない）。
- `GpuHandle.StaticVao`（新）= タイルの `TileVao` と同じ `Int32` opaque enum（`GpuHandle.flix` に 1 enum 追加）。
- `initStaticPolys` の実装は `buildTileInstanceVBO`(`GL_STATIC_DRAW`) が下敷き。違いは「入力の多角形を z 昇順に並べ、`Triangulate.triangles` で三角形化して連続配置し、z ごとのレンジ目次を返す」こと（三角形分割は初回だけ）。
- `renderCommands` の実装（`renderFrameMixed`）を §2.3 の 3 種マージへ拡張。**swap は最後の 1 回のまま**（renderCommands の中で clear→3 種 z 混在描画→swap）。
- **既存の呼び側**（fe_rogue 等 `staticLayer = None` のゲーム）は `staticRanges = Nil` を渡すだけで、`renderFrameMixed` の fold は Static ケースが 0 件 = 従来と完全に同じ経路。**波及は「引数 1 本増えるが常に Nil」。**

### 3.2 多角形頂点シェーダに uniform 2 本追加（既存経路は恒等・毎回明示リセット・D3）

現状 `projection`+`multiplyBlend` のみ。`viewOffset`(vec2)・`viewScale`(vec2) を足し、式を `screenPos = (aPos − viewOffset) * viewScale + halfDesign;` にする。

- **動的多角形（既存 `drawPolygonBatch`）は毎 draw call で `viewOffset=(0,0)`, `viewScale=(1,1)` を明示設定**する。動的多角形は既に centerOn 済みスクリーン座標で来るので恒等。
- **GL の uniform はプログラム単位で保持される（D3 の指摘）**。retained レンジ描画で設定した `viewOffset` が動的経路に漏れないよう、**両経路とも毎回明示リセット**する（sprite の `multiplyBlend` が毎回 0 明示される `Sprite.flix:96` と同じ作法）。
- 静的レンジ描画は同じシェーダに `viewOffset=camera center`, `viewScale=zoom` を渡す。**1 本のシェーダを両経路で共有**でき、既存経路の絵は 1px も変わらない。

### 3.3 SoftRaster（snapshot/生成）は変更しない

SoftRaster は `DrawCmd` を CPU で描くだけで GPU を知らない。retained は GPU 提出方式の話。**SoftRaster・HeadlessRender・スナップショットテストには手を触れない。** これが「GPU 側だけ変える」境界。ただしこの独立性は §4 の通り「安全証明にならない」ので、GL 経路は別途 glReadPixels で検証する。

---

## 4. 絵を守る検証（スナップショットの取り違えを正す・R1）

### 4.1 SoftRaster スナップショットは「非回帰の確認」であって「retained の安全証明」ではない

| 経路 | 入力 | GPU 依存 | v2 での変更 |
|------|------|---------|-------------|
| 本番描画（GL） | DrawCmd + StaticRangeCmd | あり | **retained 提出に変更** |
| スナップショット（`make test-fe_rogue`） | DrawCmd → SoftRaster | なし | **変更なし。だが retained を通らない = retained の退行を検知できない** |
| 生成（gallery PNG） | DrawCmd → SoftRaster | なし | 変更なし |

- **訂正（v1 の誤り）**: 「スナップショット 1165/0 で安全」は誤り。1165/0 は **fe_rogue を壊していないことの確認**であって、retained（GL 経路の変更）の安全を何も担保しない。C1 の z 順破綻はまさに GL 経路で起きるので SoftRaster スナップショットは素通しする。
- retained を使うのは dungeon（別リポ `flix_ge_dungeon`）で、`make test-fe_rogue` は fe_rogue のもの。**retained の絵を守るスナップショットは現状どこにも無い（§4.3 で対策）。**

### 4.2 retained の安全ゲート = glReadPixels diff（GL 経路そのものを検証）

- `useRetainedStatic()` トグルで retained ON/OFF の GL フレームバッファを **`glReadPixels` で吸い出し PNG 化し、ピクセル diff する自動テスト**を 1 本作る。差が非ゼロなら失格。
- これが検知するもの: (a) C1 の z 順破綻（ON で壁と粒の前後が変わる）、(b) R3 の Float64/Float32 丸め差（1px でも出れば失格）、(c) camera uniform 式の誤り。
- **段階2 以降の必須ゲート**。目視 A/B（v1 の §6）は常設ゲートにならないので、機械化した diff に置き換える。
- 実装メモ: glReadPixels はヘッドレスだと GL コンテキストが要る。CI で回すなら bench/sprite_stress と同じく実 GL 起動（macOS は `-XstartOnFirstThread`・AWT は headless 注意）。まずは開発機でトグル A/B の diff を回す手順を用意し、緑を里程標ゲートに据える。

### 4.3 dungeon 側の絵のスナップショットを新設

- dungeon には描画リストスナップショットも PNG スナップショットも無い（fe_rogue にはある）。retained 前後で絵が変わっていないことを守るため、**dungeon に SoftRaster ベースの PNG スナップショットを新設**し、B1/B2 の代表フレームを固定する。
- ただし SoftRaster は retained op を通らない。このスナップショットが守るのは「`build` が返す静的 DrawCmd の内容の正しさ」まで。**GL の draw call 混在による z 順（C1）は §4.2 の glReadPixels diff でしか守れない** — 両方を里程標ゲートにする（役割が別）。

---

## 5. 段階ロードマップ（動く里程標）

各段の後で `make test-fe_rogue`（1165/0・**fe_rogue 非回帰の確認**）＋ 変更パッケージの `flix check`。retained の安全は §4.2 glReadPixels diff と §4.3 dungeon スナップショットで別途担保。

### 段階 0：計測と投資判断（コード変更なし・D1）
- bench/sprite_stress(`Bench.flix`) に倣い、dungeon B2 に固定カメラで立たせ dt を採る（vsync off・ウォームアップ捨て・**熱で 4 割ぶれるので同一熱状態で連続採取・中央値**）。
- **必須（投資判断前）**: 「**静的を完全に描かない（空 VBO 相当・静的 build を Nil に）**」実験で到達 fps を測る。
  - 空にして 120fps 近くに届く → ボトルネックは静的の CPU 提出（retained が効く・GO）。
  - 空にしても頭打ち（例 80fps 止まり）→ 残りは動的側 or **fill rate バウンド**（暗くするオーバーレイ・影・水面の大きな半透明多角形の塗り面積）。この場合 retained の上限はそこで、§7 の 90〜120fps は下方修正し、別対策（半透明の重ね削減・解像度スケール）を先に検討。
- ここで retained の見込み効果を実測で裏づけてから段階2へ。

### 段階 1：多角形シェーダに uniform を足す（恒等のまま・速くならない）
- `viewOffset`/`viewScale` を追加。既存 `drawPolygonBatch` は毎 draw call で `(0,0)/(1,1)` を明示設定（§3.2）。
- 全 example（breakout/sokoban/platformer/liars/fe_rogue）の絵が 1px も変わらないこと: スナップショット 1165/0 ＋ 各 example の glReadPixels 恒等確認（uniform 追加前後で GL フレーム一致）。
- ゲート: 1165/0 ＋ 全 example GL フレーム不変。

### 段階 2（最初に速くなる里程標）：init/free + renderCommands 拡張、dungeon の**壁だけ** retained
- engine に `initStaticPolys`/`freeStaticPolys`/`GpuHandle.StaticVao`/`StaticRangeCmd` 追加、`renderCommands` 署名拡張、`renderFrameMixed` を 3 種マージへ。既存呼び側は `staticRanges=Nil`。
- `App.withStaticLayer` 追加。dungeon で **まず壁の Poly だけ**を静的レイヤーへ（床・飾りは従来経路に残し差分を最小化）。ハンドルは World 保持（§2.4）。
- **`useRetainedStatic()` トグルで ON/OFF の glReadPixels diff（§4.2）を回し、差ゼロを確認**。特に z=2 の壁 vs 粒の前後が保存されていること。
- ここで B2 の壁ぶんのアップロードと三角形分割が毎フレームから消える → 1 フロアで速くなることを段階0 の計測で確認。
- ゲート: 1165/0（fe_rogue 非回帰）＋ dungeon glReadPixels diff ゼロ ＋ dungeon PNG スナップショット（§4.3）不変。

### 段階 3：床・飾りも静的レイヤーへ、View を静的/動的に分割
- 案の View.staticWorldItems（壁+床+飾り・camera 無し）と View.frameDynamic（松明/プレイヤー/影/水面の粒）に分割。z=2 粒・z=5 松明が動的、壁・床飾りが静的で同 z 同居 → §2.5 の入力順規則で前後保存。
- 静的レイヤー build は `Prebuilt#tiles` の item をワールド座標で全量返す（カリングは §6 の判断）。
- ゲート: 1165/0 ＋ dungeon glReadPixels diff ゼロ ＋ PNG スナップショット不変。B2 の fps を段階0 の計測で確認（120fps に届くか）。

### 段階 4：dirty 鍵と VBO ライフサイクルを固める
- `StaticKey = { floorId, gen }`。`Controls.reloadAll` が `gen+1`。ゲーム step が鍵比較 → `freeStaticPolys(old)`→`initStaticPolys(new)`（先 free・後 init で 1 世代だけ持つ）。
- ゲート: F1 リロード・フロア往復を繰り返しても VBO/VAO 数が増え続けないこと（GL リソース数確認）＋ 1165/0 ＋ glReadPixels diff ゼロ。

### 段階 5：トグル判断・横展開（zoom 再検証条項・R3）
- dungeon で数日運用し安定を確認後 `useRetainedStatic()` を true 固定 or 撤去。
- **横展開（zoom を使う可能性のある example）では、`Render.scaled` の頂点乗算(Float64)とシェーダ `viewScale` 乗算(Float32)が割れ得るので、zoom 経路の glReadPixels diff を必須再検証**。SoftRaster は CPU なので気づけない。2 例目ゲートに乗せて相談。

---

## 6. リスクと封じ込め

### z 順破綻（C1・最重要）
- 封じ込め: §2.3 の 3 種マージで **1 パス z 安定ソートを保存**。列順は入れ替えない（`Frame.flix:205-209` の不変条件を踏襲）。§2.5 の「静的レンジは動的の後に append」規則で同 z の前後を現状と一致させる。§4.2 glReadPixels diff を常設ゲートにして退行を機械検知。

### GL 資源リーク / フロア切替（R4）
- タイル VBO は現状 delete していない（`LwjglLayer` に delete 無し・プロセス終了任せ）。retained はフロア往復するので `freeStaticPolys` で `glDeleteBuffers`/`glDeleteVertexArrays` を必ず対に。**ハンドルは World が 1 つだけ持ち、step で先 free・後 init**（App ランナーに可変状態を持ち込まない）。

### clear/swap 境界（R2）
- 封じ込め: drawStaticRange を **renderCommands の 1 呼びの中**（clear→z 混在描画→swap）で発行。swap は最後の 1 回だけ。別 op で「先に描く」ことはしない。

### 全量 GPU 送り vs 空間分割（D2・妥当な保留）
- 現状 `visibleStatic` で画面外を捨てている。retained 全量 VBO はこのカリングを捨て、視錐台外の三角形も頂点シェーダは走る（ラスタライズはされない）。B2 数千三角形なら許容の見込みだが未実測。まず単一 VBO で段階3 で計測 → 重ければ **z-index の範囲 or 空間タイル単位の複数 VBO** にして、レンジ描画を画面が触れる範囲だけ発行（早すぎる最適化を避け、測ってから）。

### 複数 example への波及（D3）
- retained は `withStaticLayer` を繋いだゲームだけ。他は `staticLayer=None`＋`staticRanges=Nil` で従来経路。シェーダ uniform 追加は恒等（毎回明示リセット）で既存の絵は不変。波及は「renderCommands 引数 1 本増（常に Nil）＋ シェーダ uniform 2 本増（毎回 0/1 明示）」に閉じる。

### カメラ精度（R3）
- dungeon は zoom=1・平行移動のみで非問題の見込み。だが Float64/Float32 差は順序合わせで消えないので §4.2 の 1px diff ゲートで担保。zoom 横展開は §5 段階5 で再検証。

### Flix 固有の落とし穴
- **sync**: engine（`GameEngine.flix`/`GpuHandle.flix`/`DrawCmd.flix`/`render_gl`）変更後は `make sync-engine`・`make sync-render-gl`・`make sync-engine-world` を個別に（`make sync` の clean-locks は全 worktree 走査でハング）。fpkg は `.flix` のみ・テスト非同梱。
- **レコード `#` はホットパス**: retained の狙いは「頂点ごとの `#vertices` 読みを毎フレームから消す」こと。逆に毎フレーム走る `key`/レンジ fold で不要な `#` チェーンを増やさない（`StaticKey` は浅い record・`StaticRange` の fold は薄く）。
- **エフェクト多相**: 新 op は `Game` eff に乗るので `staticLayer` の関数は `ef` を帯びる。既定は純粋 hook を `checked_ecast` で widen（`makeWith` 作法・`App.flix:107-127`）。
- **BSD userland**: 一括置換は `sed -i` 不可 → Python バイト処理。新 Makefile ターゲット（計測・glReadPixels 実行）は実運転 1 回通すまで頼らない。
- **stableByZ の安定性**: 3 種マージでも `stableByZ` が同 z の入力順を保つことに依存する。ソート実装が安定でなくなると z=2 の壁/粒が入れ替わる → §4.2 で常設検知。

---

## 7. 効果の見積もり（項目分解・熱 4 割ぶれ・アムダール上限に注意・D1）

プロファイル（main 50 サンプル）: アップロード 48% + 頂点組み立て/三角形分割 26% + フレーム組み立て/吐き出し 12% + その他 14%。静的:動的 ≈ 10:1〜100:1。

- **消えるもの**: 静的分のアップロード（48% の大半・仮に 8〜9 割 → 38〜43pt）と、静的分の三角形分割/頂点組み立て（26% の大半 → 21〜23pt）。合計で main の約 60〜65pt ぶんが毎フレームから消える見込み。
- **消えないもの（アムダール上限・D1）**:
  - 12% のフレーム組み立て（`stableByZ` の z ソート・run 収集）は **静的も z ソート列に残す**（§2.3）ので減らない。むしろ静的レンジも列に入るぶん微増し得る（ただし要素数は「頂点数」でなく「z レンジ数」なので軽い）。
  - 動的分（松明の炎・影・水面の粒）のアップロードと三角形分割は残る。
  - **GPU 側（ラスタライズ・fill rate）と GLFW swap（vsync 待ち）は main プロファイルに出ない**。B2 が B1 より遅い差が本当に全部 CPU 提出由来かは jstack だけでは断定できない（jstack は CPU スタックのみ・GPU バウンドは見えない）。
- **fps への翻訳（断定しない）**:
  - 現状 B2 ≒ 55fps ⇒ 18.2ms。消える仕事が「1 フレームの約 6 割」なら残り ≒ 7.3ms ⇒ 理論上 ≒ 137fps。だがこれは **CPU 提出バウンド前提**。
  - **§5 段階0 の「静的を描かない実験」が到達 fps 上限を実測で確定させる**。空にして 120fps 近くなら retained の見込みは堅い。頭打ちなら fill rate バウンドで、90〜120fps の見積もりは下方修正し別対策へ。
  - 確度が高いのは「48%+26% の静的分が消える」まで。**fps の具体値は段階0 実測に委ね、ここでは断定しない。**

---

## 自己採点

**82 / 100**

内訳の考え方: v1 の致命傷（C1: 別 draw call 分離で z 順破綻）を、レビューの (b) 案を「z キー付き静的 VBO レンジ ＋ 3 種マージ」という実装可能な形に落として解いた。`renderFrameMixed` の既存 run flush（sprite/poly の 2 run を種別切替で交互 flush して列順保存）に第3の run 種を足すだけで、z 安定ソートを壊さない。スナップショットの取り違え（R1）を訂正し glReadPixels diff を常設ゲートに、swap 境界（R2）を renderCommands 1 呼びに束ね、ハンドルを World 保持（R4）、fps 見積もりを段階0 実測に委ねた（D1）。カメラ精度（R3）は dungeon 限定＋横展開再検証条項で封じた。分析パートは全主張が実コード（CameraRig/Render/Shader/Frame/LwjglLayer/View/Surfaces）で裏取り済み。

### 残リスクと弱点の自己申告

1. **3 種マージの入力順規則（§2.5「静的レンジは動的の後に append」）が dungeon の全同 z 同居ケースで現状と一致するかは未証明**。z=2（壁 vs 粒）は「壁が後」で規則と合うが、z=5（床飾り vs 松明）や、静的どうし・動的どうしの相対順が現状 `sceneItems` の並べ順とズレる可能性がある。§4.2 の glReadPixels diff で検知はできるが、**diff が非ゼロだった時に「どの z のどのペアが入れ替わったか」を詰める作業**が段階2 で必ず発生する。ここが実装の主戦場。
2. **`renderFrameMixed` の 2 run fold を 3 run fold に拡張する実装は「最小」ではない**。sprite run・poly run に加え「静的レンジ run」を加え、3 者の種別切替で相互 flush する fold は、現状の 2 者交互（`Frame.flix:333-370`）より場合分けが増える。順序不変条件（列順を入れ替えない）を保ったまま書き切れるかは、Frame.flix を実際に編集して確認が要る。設計上は可能だが実装難度は中。
3. **glReadPixels diff の常設化のコスト**が未見積もり。GL コンテキストを起こして 2 パス（ON/OFF）撮って比べるのは 1 テストとして重く、CI 常設か開発機手動かの判断が要る（bench と同じ実 GL 起動・macOS 制約）。まずは開発機手動 A/B から始め、常設化は別途相談。
4. **段階0 の「静的を描かない実験」で fill rate バウンドと判明した場合、本設計の効果が大幅に目減りする**。その場合の別対策（半透明の重ね削減・暗くするオーバーレイ/影/水面の描画方式見直し）は本書の範囲外で、投資判断がやり直しになる。§7 はこれを正直に「断定しない」に留めたが、90〜120fps を保証できていない点は弱み（ただし保証しないことが誠実）。
5. **engine 3 変更（op 2本＋renderCommands 署名＋シェーダ uniform）は事前相談が要る領域**。本書は相談材料で実装はしていない（指示通り）。特に `StaticRangeCmd` を `DrawCmd` に置くか render_gl 内部型に留めるか（SoftRaster が見ないなら内部型でよい）は相談で詰める。
