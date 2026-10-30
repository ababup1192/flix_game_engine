# HD-2D の試作で見つかった engine の足りない所 — 2 回目の拡張の設計

状態: round2a を実装済み（輪郭光・灯りの影・Field.Param・camera の確定値と Pass ごとの camera）。round2b は未着手。作業場 `fge-postfx`（ブランチ `feat/postfx-spike`）。
改訂 2（レビュー 80 点 → 範囲を round2a に絞り、指摘 1・4・5・9・10・11 を反映。§9 の表）。

土台は 1 回目の拡張（後処理・未コミット。`plans/postfx-spike.md` §9）: Pass の中の Shader 面・`Render.PassPlan` / `App.withPassPlan` /
`Render.passSpecsOf` / `Render.resolvePassReads`・`RenderTarget.Descriptor`（倍率）・`ShaderDoc.Field.Sampler`（Linear）・history・`div`。
**round2a は 1 回目の変更の上に積む**（1 回目は未コミットのままでよい）。
試すのは今までと同じく `make sync-engine-full` の `engine_full/artifact/package.fpkg` を `/Users/abab/Desktop/hd2d_lab/lib/` に差す形。

**engine/ の拡張なので、実装の前にこの文書で相談する（AGENTS.md）。**

後方互換の決まり（1 回目と同じ）: **今のゲーム・テンプレートは 1 文字も変えずにコンパイルが通り、同じ絵を出す**。破る所は §8 の表に全部書く。

---

## 0. 範囲

**round2a（この文書の本文）= 試作の絵が変わる物だけ。** 実装の順も下の順。

| 順 | 段 | 中身 | 節 |
|---|---|---|---|
| 1 | E | 輪郭光（`PxShade.rimMasks` / `Light.rimsFrom` / `PxSprite.drawRimQuad`）。A2 と `Light.flix` を取り合うので先に | §1 |
| 2 | G | 点の灯りの影（`Shadow.projectedRuns` / `projectedBox`） | §2 |
| 3 | F | 面に毎フレーム変わる数を渡す（`Field.Param` / `Render.withShaderParams`） | §3 |
| 4 | A1 | camera の確定値と写し（`CameraRig.CameraView` / `follow` / `followParallax` / `parallaxCenterScaled`） | §4 |
| 5 | A2 | Pass ごとの camera（`App.withPassPlanView` / `withScreenView` / `cameraViewOf` / `passCtxOf`・`Light.worldLightMapPass`・`Light.withUnlit`） | §4・§5 |

**round2b（§10 の一覧）**: 当たり（moveAndSlideBox）・動画の道（frameOf / writeAppFrames）・段のグラデ・予算の内訳・ZStack の render layer と名前・glowAt の案内。
削った物: `App.addParallaxLayerScaled`（本編の視差レイヤの縦横別は要るゲームが出てから）・`Mirror.items`（今の `Mirror.runs` の方が揺れまで描けて絵が上）。
入れない物: 見下ろしの段差（§10 の末尾）。

決まった所（改訂 1 の §18 への答え）: camera の確定値を渡して木の部分ごとに follow する形を採る・F8 のズームが Pass に効かない件は次へ・`withScreenView` を足す・`ZStack.Tree` の case は今回足さない。

---

## 1. 輪郭光（rim light）— 段 E

### 1.1 現状

- `PxShade.shade` は読み込み時に 1 度だけ「光の来る向き（`lightX` / `lightY`。-1/0/+1）の側が空いている画素」を ramp の明るい色に替える。向きは 1 つで、灯りの色を持たない。
- アトラス（`PxSpriteAtlas.bake`）は Doc の全コマを 1 枚に詰める。主人公は `PxSprite.drawQuad`（1 コマ 1 クアッド）で貼る。
- HD-2D の調査（hd2d_lab の docs/hd2d-research.md §2 の表・§4 の 5）は「灯りのある側の縁 1px を灯りの色で明るくする」を効き目大・手間小に挙げている。

### 1.2 API

```flix
// engine_world/src/PxShade.flix
/// 8 方向（n ne e se s sw w nw）の縁の画素だけを残したコマの Doc を作る（読み込み時に 1 度）。
/// 縁 = 地の続き（ramp に載った色。shade と同じ決まり）で、その向きの隣が地でない画素。残す画素は '#'、ほかは '.'。
/// 斜めの向きは縦と横の両方を見る（ne = 上か右が空いている）。
/// 返す Doc のスプライト名は元と同じ、コマの名前は "<元のコマ>@rim-<向き>"。
/// 返す Doc は元の Doc とは別の物で、別のアトラス（rimBaked）に作る — 元のコマの名前と同じ表に並ばないので、名前は混ざらない。
pub def rimMasks(ramp: Ramp, doc: PxSpriteDoc.Doc): PxSpriteDoc.Doc

/// 向き（画面の上 = -y）から、いちばん近い 8 方向の名前（"n" … "nw"）。長さ 0 は None。
pub def rimDirectionOf(towardLight: Vec2.Vec2): Option[String]
```

```flix
// engine_world/src/Light.flix
/// 輪郭光 1 方向ぶん（at から灯りへの向き・灯りの色・強さ 0..1）。
pub type alias Rim = { toward = Vec2.Vec2, color = Color, strength = Float64 }

/// at に立つ物の輪郭光。灯りごとに寄与（(1 − 距離/半径)² × halo。半径の外は 0）を求め、
/// 8 方向の同じ向きに入った灯りどうしだけをまとめる（強さは和で 1 が頭打ち・色は寄与で重みを付けた平均）。
/// 強い順に最大 limit 方向を返す（届く灯りが無ければ Nil）。
/// WhyNot: 全部の灯りの向きを 1 本の和にしない — 左右に灯りがあると向きが打ち消し合って縁が出なくなる。
///   向きごとに分けて返すので、両側に灯りがあれば両側の縁が光る（limit = 2 なら 2 方向まで重ねる）。
pub def rimsFrom(lights: List[Light], at: Vec2.Vec2, limit: Int32): List[Rim]
```

```flix
// engine_world/src/PxSprite.flix
/// drawQuad と同じ所に、縁の絵（rimMasks から作ったアトラス）を灯りの色で Add に重ねる。rims の 1 つごとに 1 枚。
/// flipH なら向きの左右を入れ替えて選ぶ（反転した絵の右の縁は、元の絵の左の縁）。
/// 強さ 0・アトラスにそのコマが無い向きは描かない。z は渡した z（本体の z + 1 にする）。
pub def drawRimQuad(spec: { rimDoc = PxSpriteDoc.Doc, rimBaked = PxSpriteAtlas.Baked, texture = String,
                            sprite = String, frame = String, topLeft = Vec2.Vec2, flipH = Bool, scale = Int32,
                            rims = List[Light.Rim], z = Int32 }): List[Render.PlacedItem]
```

ゲーム側の手順: Res を作る時に `PxShade.rimMasks(ramp, doc)` を `PxSpriteAtlas.bake(rimDoc, _ -> 白)` で別のアトラスに作り、`App.withSpriteAtlases` に 2 枚目として上げる。
毎フレームは `Light.rimsFrom(灯り, 主人公の胴のあたり, 2)` → `PxSprite.drawRimQuad`。

`PxSprite` が `Light.Rim` を読むので、依存は PxSprite → Light になる（今 Light は PxSprite を読んでいない — 循環しないことを実装の最初に `flix check` で確かめる。
循環するなら `Rim` を PxSprite の側に置き、`rimsFrom` がそれを返す）。

### 1.3 触るファイル

`engine_world/src/PxShade.flix`・`engine_world/src/PxSprite.flix`・`engine_world/src/Light.flix`（§5 の A2 も触る — E を先に）・
`engine_world/test/TestPxShade.flix`・`TestLight.flix`・`TestPxSprite.flix`（無ければ TestPxShade に置く）。

### 1.4 GL と CPU

重ねるのは「白の絵を tint して fade して Add で貼る sprite」で、`Render.lightAt` と同じ種類の描き物。整数倍の sprite・Nearest は gl_parity の A 段階で一致する。
fade（alpha < 1）の Add は GL が float・CPU が整数で混ぜるので ±1/255 ずれうる — `lightAt` と同じ扱い（backend-parity.md の Add の行。新しい近似は増えない）。
縁の絵の透明な画素は alpha 0 なので、どちらの道でも足されない。

### 1.5 後方互換

足すだけ。`PxShade.shade` の今の「左上から」のふち光は変えない（動く輪郭光だけにするなら、ゲームが `rim` を 0 にする）。

### 1.6 テスト

| どこ | 確かめること |
|---|---|
| TestPxShade | 3×3 の地（中の色だけ）で `@rim-e` のコマ = 右の列だけ '#'・`@rim-ne` = 上の行と右の列（List で 1 回） |
| 同 | 透明（'.'）と輪郭の色（ramp に無い色）は縁にならない |
| 同 | `rimDirectionOf((1, -1))` = Some("ne")・`((0, 0))` = None |
| TestLight | 灯り 1 つ（半径 100・halo 1）から 50 離れた点: 強さ = (1 − 0.5)² = 0.25・向き = 灯りの向き（タプルで 1 回） |
| 同 | 左右に同じ強さの灯り（点の左右 50・半径 100）・limit 2 → 2 方向（e と w）が強さ 0.25 ずつ。打ち消し合わない（List で 1 回） |
| 同 | 同じ向き（e）に 2 つの灯り（強さ 0.25 と 0.25）→ 1 方向・強さ 0.5。半径の外だけ → Nil |
| TestPxSprite | `flipH = true` で向き e の Rim を渡すと、`@rim-w` のコマの region を貼る |
| 描き出し | hd2d_lab の松明の横の主人公の場面を目視（`/render-loop`）。新しい絵なので PNG は前と変わる |

### 1.7 リスク

- アトラスが 8 倍になる。主人公の数コマなら小さい（16×32 × 8 方向 × コマ数）。全部のスプライトに掛けると大きいので、`rimMasks` に渡す Doc をゲームが選ぶ（`shadeWith` と同じ「絵ごとに選ぶ」考え方）。
- 縁が 1px なので、windowScale 2 では 2px の線になる。太さを選ぶ口は持たない（ドット絵の 1 画素 = 1 セルの決まり）。
- 寄与の式は見た目の調整で変えたくなる。式は `rimsFrom` の 1 か所に置き、ゲームは返り値の strength に掛け直せる。

### 1.8 選ばなかった案

- **法線マップ（Unity 2D の Secondary Texture・Godot の CanvasTexture の normal）**: 素材の手間が倍になる（依頼で避けたい物）。光の計算も Shader 面か専用の program が要り、CPU 側にも同じ式が要る。
- **毎フレーム PxShade で縁を作り直す**: 文字格子の変換を毎フレーム回すことになり、アトラスも毎フレーム上げ直しになる。
- **ShaderDoc の面でスプライトの alpha の隣を読んで縁を出す**: Shader 面はスプライトのテクスチャの region を読めない。スプライトごとに面が要る。
- **4 方向だけ**: 斜めの灯り（左上の松明）で縁の角が抜ける。8 方向でアトラスは 2 倍になるだけ。
- **いちばん強い灯り 1 つだけ**: 両側に灯りがある広場の真ん中で片側しか光らない。向きごとに分けて limit で切る方が、選び方を 1 つの数で調整できる。

### 1.9 汎用性・判断

灯りのある夜の場面を持つドット絵のゲーム全部（rpg-starter の夜・ダンジョンの松明）。見下ろしでも横視点でも同じ。
**入れる。** 絵の下限（主役が背景から分離）に直接効き、新しい描き物の種類を増やさない。

---

## 2. 点の灯りの影 — 段 G

### 2.1 現状

- `Daylight.groundShadow` は太陽の向き（`Shadow` の dir・scale）で、ずらした楕円 1 枚 + 接地の小判 1 枚。点の灯りの位置は受けない。
- `Shadow.shadowQuads` は壁（多角形）の影を灯りから無限に伸ばす形で、立っている物の影を地面へ倒す形ではない。
- hd2d_lab の `View.castShadows` / `castQuad`: 近い灯り 2 つから「足元の幅の台形を灯りの反対へ、高さ × 割合だけ伸ばし、先で消す」gradPolygon（Multiply）。
  先が別の段へ出る時は長さを縮める（`Terrain.heightAt` を見る）。接地の小判は `contactShadow`。

### 2.2 API

```flix
// engine_world/src/Shadow.flix

/// 立っている物の影を、灯りの反対の地面へ倒した形（planar projected shadow を見下ろしの 2D に落とした物）。
/// 絵の走り（PxSprite.runs）の行ごとに、足元からの高さ h の行を「足元 + 向き × h × reach」へ倒した帯にする。
/// 帯の濃さは根元 alpha → 先 0（gradPolygon・Multiply）。同じ行の走りは 1 本の帯にまとめ、上下で同じ幅の行も 1 枚にまとめる（数を減らす）。
/// 行ごとの帯は倒した先で隣の行の帯と重ならない（高さ h..h+1 の行は h..h+1 の距離の所へ倒れる）ので、Multiply が二重に掛からない。
/// light と foot は地面の点（高さを持たない）。灯りが足元に重なる（距離 < 1px）時は Nil。
pub def projectedRuns(spec: { runs = List[PxSprite.Run], foot = Vec2.Vec2, light = Vec2.Vec2, reach = Float64,
                              ink = Color, alpha = Float64, z = Int32 }): List[Render.PlacedItem]

/// 絵の走りを持たない物（家・木を多角形で描いた物）用: 足元の幅 half・高さ height の箱を倒した台形 1 枚。
/// 根元の幅 → 先は 1.35 倍・先で濃さ 0（hd2d_lab の castQuad と同じ形）。
pub def projectedBox(spec: { foot = Vec2.Vec2, half = Float64, height = Float64, light = Vec2.Vec2, reach = Float64,
                             ink = Color, alpha = Float64, z = Int32 }): Render.PlacedItem
```

近い灯りを選ぶ・灯りから遠いほど薄くする・先が別の段へ出たら縮める、は**ゲームが決める**（段差はゲームの Terrain）。engine は 1 つの灯りから 1 つの形を作るだけ。

### 2.3 触るファイル

`engine_world/src/Shadow.flix`・`engine_world/test/TestShadow.flix`。PxSprite は `Run` の型を読むだけ。

### 2.4 GL と CPU

gradPolygon の Multiply。今の多角形の一致の範囲（整数座標の縁はバイト一致・斜めの縁は近似）。影の帯は斜めなので近似の側で、今の hd2d_lab の台形と同じ扱い。新しい近似は増えない。

### 2.5 後方互換

足すだけ。

### 2.6 テスト

| 確かめること |
|---|
| 灯りが真左（足元 (100, 100)・灯り (0, 100)）・高さ 10 の 1 列の走り・reach 1.0 → 帯の先が (110, 100)（右へ高さぶん。点の List で 1 回） |
| 幅の同じ 3 行の走りが 1 枚にまとまる（返る数 1）・幅の違う 2 行は 2 枚 |
| 灯りが足元と同じ点 → Nil |
| `projectedBox`: 灯りが真左・half 10・height 20・reach 1 → 根元の 2 点が (100, 90)(100, 110)・先の 2 点が (120, 86.5)(120, 113.5)（10 × 1.35 = 13.5） |

### 2.7 リスク

- 走りの数が多い絵（細かい葉）では帯が増える。まとめても数十。大きな物は `projectedBox` を使う、と doc に書く。
- 見下ろしの絵は立った姿を正面から描いているので、倒した影は物理的には正しくない（真上から見た形ではない）。HD-2D の作品も同じ割り切り。

### 2.8 選ばなかった案

- **剪断（skew）できる sprite**: `Render.Item.Sprite` に欄を足し、render_gl のクアッドの頂点と SoftRaster の Java2D の変換の両方を直すことになる。Nearest で斜めに伸ばした縁の一致も新しい近似になる。
- **`Daylight.groundShadow` に灯りの位置を足す**: 楕円 1 枚では物の形が出ない（家と人が同じ形の影になる）。名前も太陽に寄っている。

### 2.9 汎用性・判断

松明・街灯・たき火のある夜の場面を持つ見下ろしのゲーム全部。**入れる。** 多角形だけで組めて、一致の検証が増えない。

---

## 3. 面に毎フレーム変わる数を渡す — 段 F

### 3.1 現状

- 面（`Render.Item.Shader`）が毎フレーム変えられる数は `t`（uTime）だけ。Spec の `Const` に入れると Spec が変わり、実機は program を作り直す（`Render.Item.Shader` の doc の WhyNot）。
- hd2d_lab の post は、ピントの帯の中心（主人公の画面の y）を `t` に入れている（`View.post` の WhyNot）。時刻を読む効果を同じ面に足すと、もう入れる所が無い。

### 3.2 API

```flix
// engine/src/ShaderDoc.flix
// Field に 1 case
/// 面を置く時に渡す数（Unity の Material.SetFloat・Godot の shader parameter と同じ「名前で渡す uniform」）。
/// 値は Render.withShaderParams で面ごとに渡す。渡されなかった名前は 0（1 回だけ知らせる）。
/// 名前は英数字と '_'（GLSL には出さないが、JSON の検査で揃える）。
case Param({ name = String })

/// Spec が読む Param の名前（正典順 = bindings → 色 → alpha の初出順。texReads と同じ並べ方）。
pub def paramNames(spec: Spec): List[String]
```

JSON: `{"kind":"param","name":"focus"}`。

```flix
// engine_world/src/Render.flix
/// Shader 面に Param の値の表を付ける（Clipped の中の Shader 面にも効く。Shader 面でない物はそのまま）。
/// 同じ名前を 2 回渡したら後の値。
pub def withShaderParams(params: Map[String, Float64], placed: PlacedItem): PlacedItem
```

- `Render.Item.Shader` のレコードに `params = Map[String, Float64]` を足す（`shaderFill` / `shaderFillMasked` は空の表で作る）。
- `Render.ShaderSurface`・`SoftRaster.SurfaceCmd`（同じ形の構造レコード）にも `params` を足す。
- `ShaderEffect.ShaderRenderCmd` に `params: List[Float64]`（`paramNames` の正典順に並べた値）。
- GLSL（`ShaderGen`）: `uniform float uParam0;` … を正典順の番号で宣言し、`Param` の式は `uParamN`。名前は GLSL に出さない（1 回目の tex の名前と同じ理由 — program のキャッシュ）。
- CPU（`ShaderEval`）: `compile` が Param を番号に振り、画素の評価で同じ番号の値を読む。
- `ShaderGen.eqSpec`: Param は名前で比べる（名前は Spec の一部。値は Spec の外なので、値が変わっても program は作り直さない）。
- `ShaderJson`: 読み書き。**DrawHash の鍵に params の値を入れる**（`ShaderJson.toJson` は Spec だけを書くので、値が鍵に入らないと、値だけ変えたコマで古い PNG が返る — 1 回目の §2.4 と同じ形の偽の緑）。

### 3.3 触るファイル

- engine: `ShaderDoc.flix`（case・`foldField` / `remappedChild` / `renameTex` / `paramNames`）・`ShaderGen.flix`・`ShaderEval.flix`・`ShaderJson.flix`・`ShaderEffect.flix`
- engine_world: `Render.flix`（`Item.Shader`・`withShaderParams`・`drawShaders`・`shaderSurfaces`・`fade` などの写し）・`App.flix`（`zMapped` の 1 か所）・`Annotate.flix`（パターンだけ）
- engine_tools: `SoftRaster.flix`（`SurfaceCmd`）・`DrawHash.flix`（鍵）
- render_gl: `Paint.flix`（uniform を差す）
- schema: `templates/*/assets/shader.schema.json` に kind を 1 つ
- bench: `bench/gl_parity` の `SurfaceCmd` を字で組む所と scene `paramRead`
- tests: engine/test（TestShader・TestShaderGenEqSpec）・engine_tools/test（DrawHash）

**1 回目で触った物とほぼ同じ集合**（ShaderDoc / Gen / Eval / Json / Render / SoftRaster / Paint）。1 回目の上に積むので、各ファイルの 1 回目の差分の後ろへ足す形になる。

### 3.4 GL と CPU

GL は uniform の float32、CPU は Float64。Const も GLSL の字（float32）と CPU の Float64 なので、精度の扱いは Const と同じ（plans/f32-boundary.md の決まりに乗る）。
gl_parity の A 段階に scene `paramRead` を足す（Param で塗る色を 0.5 にした面 → 128 の灰色でバイト一致）。

### 3.5 後方互換

- `Field` に case が増える。`Field` を網羅で match しているゲームは止まる（1 回目の `Sampler` と同じ。リポジトリの中のゲーム・テンプレートには見つかっていない）。
- `Item.Shader` の欄が増える。engine の中の組み立て 9 か所は `{ … | s }` の差し替えか `shaderFill` なので止まらない（`bin/fge refactor usages Render.Item.Shader` で確認済み）。テンプレートは engine の索引の外なので、実装時に全テンプレートで `make check`。
- `SurfaceCmd` の欄が増える: 字で組む所（bench）が止まる。ゲームは `shaderSurfaces` を通すので止まらない。
- Param を使わない Spec の GLSL は 1 文字も変わらない（uniform を宣言しない）。

### 3.6 テスト

| どこ | 確かめること |
|---|---|
| engine（ShaderEval） | `Param("focus")` を色に使う面を `focus = 0.25` で評価 → 0.25・表に無い名前 → 0（タプルで 1 回） |
| engine（ShaderGen） | Param を使わない Spec の GLSL が前と同じ（既存のテストが緑）・Param を 2 つ使う Spec に `uParam0` `uParam1` が正典順で出る |
| 同 | 値だけ違う 2 つの面は `eqSpec` が true（program を作り直さない） |
| engine（ShaderJson） | `"param"` の往復・名前に使えない字は `Err` |
| engine_tools（DrawHash） | params の値だけ違う 2 枚の鍵が違う |
| gl_parity | A 段階 `paramRead` |
| 描き出し | hd2d_lab の post を `t` から `Param("focus")` に替えた plaza の PNG が前とバイト一致（hd2d_lab の担当が替えた時の合格線） |

### 3.7 リスク

- 1 回目と同じファイルの集合を触る。1 回目の差分と混ざるので、段 F の差分は 1 回目の行と分けて見られるよう、段の終わりに `git diff` を段ごとに保存してからレビューに出す。
- 面 1 枚あたりの uniform の数は GLSL の上限（数百）まで。上限の確認はしない（数十を超える使い方は想定しない）と doc に書く。

### 3.8 選ばなかった案

- **`t` を 4 つに増やす（`t0`〜`t3`）**: 名前の無い数を渡すことになり、Spec を読んでも何の数か分からない。
- **Spec の Const を全部 uniform にする**: Const は畳み込み（定数どうしの計算をその場で済ませる）で GLSL が短くなっている。全部の面の GLSL が変わる。
- **値の表を `Render.shaderFill` の引数に足す**: 呼んでいる所が全部止まる。`withShaderParams` で後から付ける形にした。

### 3.9 汎用性・判断

体力の割合で色を変える枠・時間帯の明るさ・水面の波の強さ・選択の光り方など、面を持つゲームの多くで使う（今は全部 `t` に詰めるか Spec を作り直している）。**入れる。**

---

## 4. Pass ごとに camera を掛ける — 段 A1・A2

### 4.1 現状

- `App.withCamera` の camera は `App.resolvedCamera`（bounds で収め、`pixelSnap` で丸めた値）で求め、`App.composeScene` で **本編の view の絵**にだけ `CameraRig.centerOn` で掛かる。
  `App.renderPasses` は Pass の items をそのまま描く（camera は掛からない）。
- `resolvedCamera` の呼び手は 5 か所: `sceneItems`（本編）・`tileLayerCmds` と `staticLayerCmd`（GL の retained の道）・`tilePausedItems` と `staticPausedItems`（F8 で止めた画面）。
  どれも同じ World から同じ値を求める（`resolvedCamera` の doc の「主 view と静的レイヤーがこの同じ値から派生する」）。
- `App.withPassPlan(f: w -> Render.PassPlan)` の `f` は World しか受けないので、確定した camera の値を知らない。
- hd2d_lab は場面を全部 Pass `scene` に描き、本編には post の面 1 枚と終了の確認の窓だけを置く。`withCamera` を繋ぐと本編の post の面まで動く。
  そのため View で camera のずれを手で掛けている: `View.cameraPx`（整数に丸め）・`View.viewOrigin`・`View.toView`（`CameraRig.centerOn`）・
  `View.farView`（遠景の横だけ割合を掛ける）・`View.visibleX`（見える範囲で間引く）。光マップの灯り（`View.lights`）も画面座標へ直し、画面の外の灯りを落としている。
- 1 つの Pass の中に、camera の割合の違う物が混ざる（遠景 0・0.05・0.15・0.25・0.4／地面と置き物 1／手前の草は画面に付いて横だけ 1.25／光マップを貼る面は画面に固定）。
  **だから「Pass ごとに camera を掛けるかの 1 つの旗」では足りない**（§4.8）。
- `CameraRig.parallaxCenter(factor, center, design)` は縦と横に同じ factor を掛ける。hd2d_lab の `View.farView` は「横は factor 倍・縦は world と同じ」を
  `Render.movedAll(p(−round(o.x × factor), −o.y), items)` で書いている（縦を遅らせると山が地平から浮く）。
- Pass の中で木を絵の列へ戻すのに、hd2d_lab は `SortingLayer.stack(App.pickCtx(design), Layer.Scene, 木)` と入力の側の ctx を借りている
  （`pickCtx` の warnOnce は黙るので、区画を越えた知らせが消える。字の形も持たない）。

### 4.2 API — A1（CameraRig）

```flix
// engine_world/src/CameraRig.flix

/// このコマの camera の確定値。App が本編に掛けるのと同じ値（bounds で収め、pixelSnap で丸め済み）。
/// center = None は camera を繋いでいない（zoom が 1 なら何も動かさない — composeScene と同じ規則）。
/// Bevy の Camera + GlobalTransform、Godot の Viewport.canvas_transform に当たる「このコマの見え方」。
pub type alias CameraView = { center = Option[Vec2.Vec2], zoom = Float64, design = Vec2.Vec2, pixelSnap = Float64 }

/// camera を掛けない見え方（画面座標のまま）。
pub def screenView(design: Vec2.Vec2): CameraView

/// world 座標の列を画面へ写す。App の本編（composeScene の world 側）と同じ式。
/// 注意: Render.Item.Clipped の clip 矩形はスクリーン固定で、follow は写さない（中身だけが動く。今の withCamera の決まりと同じ）。
pub def follow(cam: CameraView, items: List[Render.PlacedItem]): List[Render.PlacedItem]

/// 縦と横で別の割合で付いていく（Godot の Parallax2D.scroll_scale と同じ Vector2）。
/// scrollScale = {x = 1, y = 1} は follow と同じ・{0, 0} は画面に固定。
/// pixelSnap > 0 なら、ずらす量を pixelSnap の升目へ Float64.round で丸める（遠景だけ半端な位置でにじむのを防ぐ）。
/// 注意: follow と同じく、Clipped の clip 矩形は写さない。
pub def followParallax(cam: CameraView, scrollScale: Vec2.Vec2, items: List[Render.PlacedItem]): List[Render.PlacedItem]

/// parallaxCenter の縦横別の形。parallaxCenter(f, c, d) = parallaxCenterScaled({ x = f, y = f }, c, d)。
pub def parallaxCenterScaled(scrollScale: Vec2.Vec2, center: Vec2.Vec2, design: {design = Vec2.Vec2}): Vec2.Vec2

/// 点 1 つを写す（光源の位置など）。toScreenPos の CameraView 版。
pub def toScreen(cam: CameraView, world: Vec2.Vec2): Vec2.Vec2

/// 画面に見えている world の矩形（間引きに使う）。App.visibleOf と同じ答え。
pub def visibleRectOf(cam: CameraView): Rect2.Rect2
```

丸めは `Float64.round`（Flix の標準ライブラリでは `Math.rint` — ちょうど半分は偶数へ。`round(0.5) = 0`・`round(1.5) = 2`）。
今の hd2d_lab の `View.farView` も `Float64.round` なので同じ答えになる。

`parallaxCenter` と `App.addParallaxLayer` は名前も答えも変えない。本編の視差レイヤの縦横別（`addParallaxLayerScaled`）は今回足さない。

### 4.3 API — A2（App と Light）

```flix
// engine_world/src/App.flix

/// Pass の計画を組む関数が受け取る「このコマの見え方」。
/// view = 本編の view と同じ字のアトラス・fontOf・warnOnce（visible は画面全体 = 画面座標。world の範囲は CameraRig.visibleRectOf(camera)）。
/// camera = 本編に掛けるのと同じ確定値。
pub type alias PassCtx = { view = ViewCtx, camera = CameraRig.CameraView }

/// Pass の計画を、このコマの見え方を受けて組む。withPassPlan(f) は withPassPlanView((_, w) -> f(w)) の薄い形になる。
/// Pass の中の木は SortingLayer.stack(pc#view, 層, 木) で絵の列へ戻す（入力の側の App.pickCtx を借りない）。
pub def withPassPlanView(f: (PassCtx, w) -> Render.PassPlan \ ef, app: App[w, ef]): App[w, ef]

/// camera を掛けない本編の絵（Godot の follow_viewport を切った CanvasLayer）。
/// withHudView と違い z を HUD の範囲へ持ち上げない — world の範囲（Transition の 100000 より奥）に置くので、
/// 画面の切り替え演出はこの絵の手前に出る。後処理の面（Pass を読み返す全面の shaderFill）はここに置く。
pub def withScreenView(v: (ViewCtx, w) -> List[Render.PlacedItem] \ ef, app: App[w, ef]): App[w, ef]

/// 描き出し（SceneRender・動画）が実機と同じ camera を使うための口。App が本編に掛ける値そのもの。
pub def cameraViewOf(app: App[w, ef], design: Vec2.Vec2, world: w): CameraRig.CameraView \ ef

/// 描き出しで Pass の計画を組むときの PassCtx（字は渡した ViewCtx・camera は cameraViewOf）。
pub def passCtxOf(app: App[w, ef], ctx: ViewCtx, world: w): PassCtx \ ef
```

- `App.Rec#passes` の型は `(PassCtx, w) -> Render.PassPlan`（内部の欄）。`App.Rec` に `screenView` の欄を足す（内部）。
- **camera を 1 回だけ求めるのは Pass と本編の分だけ**: `renderFrame` で `resolvedCamera` を 1 回呼び、その値を `renderPasses`（PassCtx に入れる）と
  `sceneItems`（引数で受ける形に替える）に渡す。`tileLayerCmds`・`staticLayerCmd`・`tilePausedItems`・`staticPausedItems` は今のまま自分で求める
  （同じ World から同じ値が出る。5 か所を全部引数で渡す形にすると、今回の範囲で関係の無いタイル層・静的層の道まで触ることになる）。
- `withScreenView` の絵は `composeScene` の world（camera 済み）の後ろ・hud の前に繋ぐ。

```flix
// engine_world/src/Light.flix

/// 光マップの Pass を world 座標の灯り・遮る物から組む。灯りと遮る物は cam で画面へ写し、環境光の全面の box は画面に固定のまま。
/// 見える範囲（visibleRectOf）と半径が重ならない灯りは落とす。
/// cfg#lights / cfg#occluders は world 座標で渡す（lightMapPass は画面座標のまま。どちらも同じ Pass の形を返す）。
pub def worldLightMapPass(cam: CameraRig.CameraView, cfg: LightMapConfig): Render.Pass
```

`Light.withUnlit` は §5。

### 4.4 触るファイル

| 段 | ファイル |
|---|---|
| A1 | `engine_world/src/CameraRig.flix`・`engine_world/test/TestCameraRig.flix` |
| A2 | `engine_world/src/App.flix`（`PassCtx`・`withPassPlanView`・`withScreenView`・`cameraViewOf`・`passCtxOf`・`renderFrame` と `renderPasses` と `sceneItems` の camera の受け渡し・`Rec#passes`・`Rec#screenView`）・`engine_world/src/Light.flix`（`worldLightMapPass`・§5 の `withUnlit`）・`engine_world/src/SortingLayer.flix`（冒頭の doc に「Pass の中は PassCtx#view」1 行）・`engine_world/test/TestPassPlan.flix`・`TestLight.flix`・docs（`docs/headless-render-recipe.md`・`docs/z-bands.md` に withScreenView の行） |

### 4.5 GL と CPU

camera を掛けるのは **PlacedItem の列の純粋な写し**だけなので、どちらの道でも同じ値になる。割れうるのは「描き出しが実機と違う camera を使う」時だけで、
これを `App.cameraViewOf`（実機と同じ `resolvedCamera`）と `App.passCtxOf` で 1 か所にする。

### 4.6 後方互換

- `withPassPlan` / `withPasses` の形は変わらない（中で `withPassPlanView` に包むだけ）。Pass の items に camera は今も掛からない（既定は画面座標）。
- `ViewCtx` の形は変えない（`App.viewCtxOf` や pickCtx を字で組んでいる所が止まらないように、camera は `PassCtx` の別の欄にした）。
- `sceneItems` の引数が増えるのは App の中だけ（pub でない）。値は同じ。
- `parallaxCenter` / `addParallaxLayer` は変えない。

### 4.7 テスト

| どこ | 確かめること |
|---|---|
| TestCameraRig | `follow(cam, items)`: center (300, 200)・zoom 1・design 480×270 で、(300, 200) に置いた箱が (240, 135) に来る。center = None・zoom 1 なら items のまま（タプルで 1 回） |
| 同 | `followParallax(cam, {x=0.5, y=1.0}, …)`: center (340, 135)・design 480×270・pixelSnap 0 → 点 (100, 100) が (50, 100)（横は (340−240)×0.5 = 50 だけずれ・縦は center の y = 135 = 画面の中央なので 0） |
| 同 | `followParallax` の丸め: center (345, 135)・scrollScale {0.37, 1.0}・pixelSnap 1 → 横のずれ (345−240)×0.37 = 38.85 → 39。点 (100, 100) が (61, 100) |
| 同 | `parallaxCenterScaled({0.5, 0.5}, c, d)` = `parallaxCenter(0.5, c, d)`・`parallaxCenterScaled({0.5, 1.0}, (340, 300), 480×270)` = (290, 300)（タプルで 1 回） |
| TestPassPlan（App） | `withPassPlanView` の f が受ける `camera` = 本編の `composeScene` に渡る値（`withCameraBounds` で端に寄せた後の値） |
| 同 | Pass の木が区画を越えたら、`pc#view#warnOnce` に知らせが届く（集める口に差し替えて文面の List を 1 回で比べる） |
| 同 | `withScreenView` の絵は camera が掛からず、z は持ち上がらない（置いた (0, 0) と z 0 のまま） |
| TestLight | `worldLightMapPass`: 見える範囲から半径以上離れた灯りは items に出ない・見える灯りの置き場所は `toScreen` の値・環境光の box は (0, 0) のまま（List で 1 回） |
| gl_parity | 既存の A 段階が全部差 0 px（`renderFrame` の受け渡しの組み替えで絵が変わらない証拠） |
| 描き出し | hd2d_lab の 7 場面を、§7 の置き換えの前後でバイト一致（hd2d_lab の担当が替えた時の合格線） |

### 4.8 リスク

- F8 の注釈のズーム・パン（`Annotate.applyInspectItems`）は本編の items にだけ掛かる。場面を Pass に描くゲームでは F8 でズームしても場面が動かない。
  今の hd2d_lab も同じ（新しく壊れる物ではない）。round2b 以降へ回す（決まった所）。
- `withScreenView` の絵は world の範囲に置くので、world の絵（camera 済み）と z で重なる。後処理の面は場面の Pass を読む全面の面なので、本編の world には普通は何も置かない。
- `Clipped` の clip 矩形を写さない決まりのため、Pass の中で world に付いた切り抜き（窓の中の小さな画面）を作ると、中身だけ動いて枠が残る。doc の注意で足りる（今の本編の withCamera と同じ）。

### 4.9 選ばなかった案

- **Pass ごとに camera を掛けるかの旗（`PassPlan#cameras: Map[String, Bool]`。Bevy の camera ごとの render target・Godot の SubViewport の考え方そのまま）**:
  1 つの Pass の中に割合の違う物が混ざるので、旗では書けない。Pass を割合ごとに分けると、全面のターゲットが 5〜6 枚増える。
- **`Render.Pass` に `camera` の欄を足す**: `{ name, clear, items }` を字で組んでいる所（hd2d_lab・`Light.lightMapPass`・bench）が全部止まる。
- **`ViewCtx` に camera の欄を足す**: `ViewCtx` を字で組んでいるテスト・描き出しが止まる。
- **後処理の面を `withHudView` に置く**: HUD は Transition（z 100000）より手前なので、画面の切り替え演出が後処理の面に隠れる。
- **木の節で camera を宣言する（`ZStack.followCamera(scrollScale, child)` を compose が解く）**: compose が camera を知る必要があり、`ZStack.Tree` に case が増える。
  `ZStack.mapItems(CameraRig.followParallax(cam, s), child)` で今の木のまま書ける。
- **`resolvedCamera` の呼び手 5 か所に全部同じ値を渡す**: 1 か所に揃うのは良いが、タイル層・静的層の GL の道を触ることになり、round2a の範囲（絵が変わる物）から外れる。値はもう同じなので、揃えるのは後でよい。

### 4.10 汎用性・判断

場面を Pass に描いて後処理を掛けるゲームなら全部使う（ピクセル化・CRT・色調補正・水中の歪み）。`followParallax` は横スクロール・見下ろしのどちらでも使う。
`worldLightMapPass` は光マップを使って camera が動くゲーム全部（rpg-starter の夜の場面・ダンジョン）。
**入れる。** 純粋な写しと配線だけで、GL・CPU の一致の検証が要らない。後方互換も保てる。

---

## 5. 光マップで光を落とさない範囲 — 段 A2

### 5.1 現状

`Light.lightMapPass` は「環境光の全面 box（z 0）→ 灯りの放射（Add・z 10）→ 影（z 20）」の Pass。これを本編か場面の Pass に Multiply で貼るので、
空のような自分で光っている面も環境光で沈む。hd2d_lab の `View.withSkyLight` は光マップの Pass の items に白い帯（上は不透明・地平の手前で透明へ）を z 5 で足している。

### 5.2 API

```flix
// engine_world/src/Light.flix
/// 光マップの Pass に、光を落とさない範囲（Unity 2D の Unlit と同じ考え方）を足す。
/// areas の形（Box・Poly・gradPolygon・Sprite）を、色を白に替えて環境光の上・灯りの放射の下（unlitZ = 5）に描く。
/// 形の alpha は残すので、gradPolygon の濃さで縁をぼかせる（地平の手前でなめらかに光マップへ戻す）。
/// areas は Pass と同じ座標で渡す（lightMapPass なら画面・worldLightMapPass なら CameraRig.follow / followParallax で写した後）。
pub def withUnlit(areas: List[Render.PlacedItem], pass: Render.Pass): Render.Pass
```

z の 5 は `radianceZ`（10）の下に名前付きで置く（`def unlitZ(): Int32 = 5`）。白の上に灯りを Add で足すと 1 で頭打ちになる（光マップは Multiply なので 1 が「そのまま」）。

### 5.3 触るファイル・GL と CPU・後方互換

`engine_world/src/Light.flix`（§1 の E の後・§4 の `worldLightMapPass` と同じ段）・`TestLight.flix`。
白の Box / Poly / gradPolygon を Normal で描くだけ（今の hd2d_lab と同じ描き物・今の多角形の一致の範囲）。足すだけ。

### 5.4 テスト

| 確かめること |
|---|
| `withUnlit` した Pass の items に、areas と同じ数の白い形が z 5 で足され、元の items は前と同じ並び（List の長さと z の List で 1 回） |
| gradPolygon の alpha（1.0 と 0.0 の頂点）が残り、色だけ白になる |
| 描き出し: 空の帯を `withUnlit` に替えた hd2d_lab の plaza の PNG が、今の `withSkyLight` の PNG とバイト一致（hd2d_lab の担当が替えた時の合格線） |

### 5.5 リスク・選ばなかった案

- areas に Sprite を渡すと、tint を白にしても絵の色が掛かる（tint は掛け算）。doc に「白い絵を渡す」と書く。
- **`LightMapConfig` に `unlit` の欄を足す**: hd2d_lab が `LightMapConfig` を字で組んでいる（`View.lightCfg`）ので止まる。
- **描き物ごとに光を受けない印（Godot の `light_mask`）**: 光マップは画面 1 枚を Multiply で貼る方式なので、外すには光マップを貼った後に描き直すことになる。空は一番奥なので描き直せない。

### 5.6 汎用性・判断

光マップを使って空・窓の外・光る看板を持つゲーム。**入れる。** 小さく、今の自前の書き方をそのまま engine に移せる。

---

## 6. 実装の順番（round2a）

各段の合格線: 触ったパッケージの `make test-<name>`・ほかは `flix check`・`make sync-engine-full` が通る・
hd2d_lab の lib に差して `make render` が通る（hd2d_lab は差した fpkg で**読むだけ**の確認。hd2d_lab のファイルは触らない — 置き換えは hd2d_lab の担当が §7 を見てやる）。
描画の道を触った段は `make gl-parity`（A 段階が差 0 px）。

| 順 | 段 | 中身 | 触るファイル | 合格線に足すもの |
|---|---|---|---|---|
| 1 | E | §1 輪郭光 | engine_world: PxShade・PxSprite・Light／test: TestPxShade・TestLight・TestPxSprite | 目視（松明の横の主人公） |
| 2 | G | §2 点の灯りの影 | engine_world: Shadow／test: TestShadow | — |
| 3 | F | §3 Param | engine: ShaderDoc・ShaderGen・ShaderEval・ShaderJson・ShaderEffect／engine_world: Render・App（zMapped 1 か所）・Annotate／engine_tools: SoftRaster・DrawHash／render_gl: Paint／schema・bench | gl_parity A 段階 `paramRead`・全テンプレートの `reference/SHA256SUMS.txt` が変わらない・全テンプレートの `make check` |
| 4 | A1 | §4.2 CameraRig | engine_world: CameraRig／test: TestCameraRig | — |
| 5 | A2 | §4.3 App・`worldLightMapPass`・§5 `withUnlit` | engine_world: App・Light・SortingLayer（doc 1 行）／test: TestPassPlan・TestLight／docs | gl_parity A 段階が全部差 0 px・全テンプレートの SHA256SUMS |
| 6 | L | 文書と網: `agents-pack/AGENTS.core.md` の早見表・`agents-pack/agent-eval/engine.json` のお題・`make api-digest`・docs（headless-render-recipe・z-bands・backend-parity・shader-doc の Param） | docs・agents-pack | ゲームの足元で `make agent-eval ONLY=<お題>` |

### 同じファイルを触る組

| ファイル | 触る段 |
|---|---|
| `engine_world/src/Light.flix` | E（`Rim`・`rimsFrom`）・A2（`worldLightMapPass`・`withUnlit`） |
| `engine_world/src/App.flix` | F（`zMapped` の 1 行）・A2 |
| `engine_world/src/Render.flix` | F |
| engine（ShaderDoc ほか）・engine_tools・render_gl | F（1 回目と同じ集合） |

E・G・A1・A2 と F の engine_world の部分は、どれも engine_world のパッケージを触る。AGENTS.md の「同じパッケージを 2 人に触らせない」により、**表の順に 1 人が持つ**。
並べられるのは F の engine / engine_tools / render_gl の部分（engine_world の Render を触る前まで）を、E・G と同時に別の人が進める組だけ。

段ごとにレビュー役を立てて 90 点を越えてから次へ（AGENTS.md・各段の終わりに `/critique-code`）。

---

## 7. hd2d_lab の自前の処理の置き換え（使用例）

下の Flix は形を示すための物（細かな名前は実装の時の hd2d_lab の View に合わせる）。**hd2d_lab のファイルはこの作業では触らない。**

### 7.1 Main（camera を App に渡し、場面は Pass・post は withScreenView）

```flix
Game.app(Controls.loadDocs())
    |> App.withCamera(Resources.read((res, w) -> World.cameraAt(w) |> Option.getWithDefault(View.plazaCenter(res))))
    |> App.withPixelSnap(Resources.read((_, _) -> 1.0))            // View.cameraPx の丸めの代わり
    |> App.withPassPlanView((pc, h) -> Resources.read((res, w) -> View.passPlanOf(pc, View.inputOf(res, w)), h))
    |> App.withScreenView((ctx, h) -> Resources.read((res, w) -> View.screenOf(ctx, View.inputOf(res, w)), h))
    …
```

`In#camera`・`View.cameraPx`・`View.viewOrigin`・`View.toView` は消える（`World.cameraClamped` の端で止める処理を `App.withCameraBounds` に移すかは hd2d_lab の担当が決める）。
SceneRender は `App.passCtxOf(app, ctx, world)` で同じ PassCtx を作り、`View.passPlanOf(pc, input)` を `Render.passSpecsOf` に渡す。

### 7.2 場面の Pass（§4・§5）

```flix
pub def passPlanOf(pc: App.PassCtx, w: In): Render.PassPlan =
    let cam = pc#camera;
    let far = (s, items) -> ZStack.mapItems(CameraRig.followParallax(cam, { x = s, y = 1.0 }), ZStack.leaf(items));
    let scene = ZStack.of(
        far(0.0, List.append(skyBands(), fogFar(w)))
            :: far(0.05, List.append(stars(w), moon()))
            :: far(0.15, rays(w))
            :: far(0.25, farRidge())
            :: far(0.4, nearRidge())
            :: ZStack.mapItems(CameraRig.follow(cam), ZStack.of(groundTree(w) :: ZStack.of(standing(w)) :: Nil))
            :: ZStack.leaf(foreground(w))                           // 画面に付いた手前（今のまま）
            :: ZStack.leaf(Light.lightMapOverlay(lightCfg(w)) :: Nil)
            :: ZStack.mapItems(CameraRig.follow(cam), ZStack.leaf(lampGlows(w)))
            :: Nil);
    // 空は光を落とさない（今の withSkyLight の白い帯を withUnlit へ）
    let light = Light.worldLightMapPass(cam, lightCfg(w))                // 灯りは world 座標のまま・画面外は engine が落とす
        |> Light.withUnlit(List.append(CameraRig.followParallax(cam, { x = 0.0, y = 1.0 }, skyBand()),
                                       CameraRig.follow(cam, windowPools(w))));
    Render.passPlan(
        light
            :: { name = "glow", clear = black(), items = CameraRig.follow(cam, emissive(w)) }
            :: { name = "scene", clear = RenderTarget.LoadOp.Clear(ThemeDoc.rec(w#theme)#bg),
                 items = SortingLayer.stack(pc#view, Layer.Scene, scene) }      // pickCtx を借りない
            :: Nil)
```

- `View.lights` の画面座標への直しと画面外の間引きは `Light.worldLightMapPass` が持つ。`lightCfg` の `lights` は world 座標の `LookDoc.Lamp` から作るだけになる。
- `View.farView` は `CameraRig.followParallax(cam, { x = factor, y = 1.0 }, …)`（横の丸めは `pixelSnap` で engine が持つ。丸め方は今と同じ `Float64.round`）。
- `View.visibleX` の間引きは `CameraRig.visibleRectOf(cam)` から出す。
- 光る物を glow と場面に 2 回書く形（`View.emissive`）は残る（round2b の K）。

### 7.3 post の面（§3）

```flix
pub def screenOf(ctx: App.ViewCtx, w: In): List[Render.PlacedItem] =
    SortingLayer.compose(ctx, (Layer.Scene, ZStack.leaf(post(w) :: Nil)) :: (Layer.Prompt, quitPrompt(ctx, w)) :: Nil)

def post(w: In): Render.PlacedItem =
    Render.shaderFill(postSpec(LookDoc.rec(w#look)), { position = Vec2.zero(), size = p(wd(), ht()) }, w#t, 0)
        |> Render.withShaderParams(Map#{ "focus" => focusV(w) })        // t にピントを入れる逃げをやめる

// postSpec の中: let focus = Field.Param({ name = "focus" });
```

### 7.4 輪郭光と影（§1・§2）

```flix
// Res を作る時に 1 度
let rimDoc = PxShade.rimMasks(ramp, heroOnly(sprites));
let rimBaked = PxSpriteAtlas.bake(rimDoc, _ -> Color.rgb(1.0, 1.0, 1.0));
// App.withSpriteAtlases に { texture = "hd2d_rim", key = …, baked = rimBaked } を足す

// heroSpriteAt の中（world 座標で組み、木の外側で follow が掛かる）
let rims = Light.rimsFrom(worldLights(w), p(c#x, c#y), 2);           // 光マップと同じ world 座標の灯り
let rimItems = PxSprite.drawRimQuad({ rimDoc = rimDoc, rimBaked = rimBaked, texture = "hd2d_rim", sprite = "hero", frame = "idle",
                                      topLeft = topLeft, flipH = false, scale = World.spriteScale(), rims = rims, z = 2 });

// castShadows の中の castQuad の代わり
Shadow.projectedRuns({ runs = PxSprite.runs(w#sprites, "hero", "idle", topLeft, false, World.spriteScale()), foot = footPoint,
                       light = lampFoot, reach = look#castReach, ink = shadowInk(), alpha = alphaOf(d), z = 1 })
// 家・木（多角形の絵）は Shadow.projectedBox({ foot, half, height, light, reach, ink, alpha, z })
```

近い灯り 2 つを選ぶ・遠いほど薄く・別の段へ出たら縮める（`View.castShadows` の filter / sortBy / fits）はゲームに残る。

---

## 8. 振る舞いが変わる所（後方互換の例外・round2a）

| 変わる所 | 誰に効くか |
|---|---|
| `Field` に `Param` の case（§3） | `Field` を網羅で match するゲーム（見つかっていない） |
| `Render.Item.Shader`・`ShaderSurface`・`SoftRaster.SurfaceCmd` に `params` の欄（§3） | これらをレコードの字で組む所（engine の中は bench の SurfaceCmd だけ。テンプレートは実装時に `make check`） |
| `App.Rec` の欄（`passes` の型・`screenView`）・`sceneItems` の引数 | App の内部。公開の形は変わらない |

---

## 9. レビュー（80 点）の指摘への直し方

| 指摘 | 直した所 |
|---|---|
| 1 Mirror.items の切り抜き | `Mirror.items` ごと round2b からも削った。代わりに `CameraRig.follow` / `followParallax` の doc に「Clipped の clip 矩形はスクリーン固定で写さない」を書いた（§4.2）。リスクにも 1 行（§4.8） |
| 2 frameOf がタイル層を二重に描く | round2b の一覧に残した（§10） |
| 4 resolvedCamera の呼び手は 5 か所 | 「1 コマに 1 回」を「Pass と本編の分だけ 1 回（renderPasses と sceneItems に渡す）」に狭めた。ほかの 4 か所は今のまま、と理由（同じ World から同じ値・タイル層と静的層の道を触らない）を書いた（§4.1・§4.3）。5 か所へ渡す案は選ばなかった案へ（§4.9） |
| 5 「@ はコマの名前に使えない」は誤り | 根拠を「縁の絵は別の Doc・別のアトラス（rimDoc / rimBaked）なので元の名前と混ざらない」に替えた（§1.2） |
| 7 動画の鍵が全 Pass を描かせる | round2b の一覧に残した（§10） |
| 9 予算の検査の口の名前 | round2b の一覧に「`bin/check-render-budget.py` は今 `bin/fge check-render-budget`」を残した（§10） |
| 10 テストの丸めの答えを 1 つに | `Float64.round` が `Math.rint`（半分は偶数へ）であることを確かめ、テストの数を半分に乗らない値（38.85 → 39）に替えた（§4.2・§4.7） |
| 11 rimFrom の打ち消し | `rimFrom` を `rimsFrom(lights, at, limit)` に替え、8 方向の同じ向きの灯りだけをまとめて強い順に limit 方向まで返す形にした。打ち消しの WhyNot を doc に書き、左右に灯りがあるテストを足した（§1.2・§1.6） |
| 範囲の決定 | round2a = E → G → F → A1 → A2。`addParallaxLayerScaled` と `Mirror.items` を削った。F の前提を「1 回目の変更の上に積む」に替えた（冒頭・§3.7） |

---

## 10. round2b（次の回）の一覧

| 項目 | 中身（改訂 1 の案） | 回す理由 | 残った指摘 |
|---|---|---|---|
| C 当たり | `Physics2D.moveAndSlideBox({ box, motion, solids, maxStep, canEnter })`（Godot の `move_and_slide`。軸ごと・刻み・段差はゲームが `canEnter` で差す） | 試作の絵が変わらない。hd2d_lab の自前の 50 行は動いている | — |
| D1・D2 動画の道 | `App.frameOf`（1 コマで描く物を 1 か所で組む）・`App.drawPassPlan`・`engine_full` の `HeadlessFrame.renderPngOfFrame`・`VideoOut.writeAppFrames` | App の中心（`renderFrame`）の組み直しで大きい。hd2d_lab は CPU の自前の道で動画を出せている | **指摘 2**: `frameOf` の items にタイル層・静的層を PlacedItem で入れると、GL の道では retained の命令と二重に描く。frameOf は「retained を含めるか」を引数で分けるか、retained を別の欄で返す。**指摘 7**: 動画の鍵が Pass の画像を全部描かないと作れない（鍵のために全 Pass を CPU で描くことになる）。Pass ごとに `PassSpec` から `DrawHash` の鍵を作り、画像の代わりに鍵を本編の鍵に混ぜる |
| H 段のグラデ | `Render.steppedGradQuad({ tl, tr, br, bl }, { top, bottom }, steps, z)`（帯の境の y を整数に丸める） | hd2d_lab の `steppedQuad` で絵は出ている（engine に移しても絵は同じ） | 境の丸めは `Float64.round`（半分は偶数へ）。テストの数は半分に乗らない値にする（round2a の指摘 10 と同じ） |
| ディザ | ShaderDoc の `Posterize` / `OrderedDither`（design の画素の座標で 4×4 の Bayer） | 縮んだ Pass の中の閾値の升目の扱いが決まっていない | — |
| J 予算の内訳 | 予算の知らせに Pass ごと・層ごと（withAnnotationContext の層）・種類ごと（丸い Box = glowAt の輪）・多い z を足す | 絵が変わらない | **指摘 9**: 改訂 1 は `bin/check-render-budget.py` と書いたが、今の口は `bin/fge check-render-budget`。知らせの 1 行目の字を変えないこと（この口が読んでいるかを実装の時に確かめる） |
| glowAt の案内 | `glowAt` の絵は変えない。doc と J の内訳から `lightAt` へ案内する | J と一緒に入れる | — |
| K render layer と名前 | `ZStack.renderLayers(Set[String], child)`・`SortingLayer.composeFor`（Bevy の RenderLayers）・`ZStack.named`・`SortingLayer.countsOf` | `ZStack.Tree` に case を足すので、今回はしない（決まった所） | — |
| 削った: `App.addParallaxLayerScaled` | 本編の視差レイヤの縦横別 | 要るゲームが出てから。Pass の中は round2a の `followParallax` で足りる | — |
| 削った: `Mirror.items` | 描き物の列を映す | 今の `Mirror.runs` の方が揺れまで描けて絵が上 | 指摘 1（切り抜き）は不要になった |
| 入れない: 見下ろしの段差 | hd2d_lab の `Terrain`（台地の矩形・縦にだけ傾く階段・段差 4px で止める） | 形が hd2d_lab の Doc そのもので、ほかに使う当てが無い。engine の口は C の `canEnter` で足りる。2 つ目のゲームで要った時に形を決める（engine には別の `Terrain` があるので、入れるなら別の名前） | — |

---

## 11. 実装で決まった所（round2a の実装の後）

| 所 | 決まり |
|---|---|
| `PxSprite.drawRimQuad` の欄 | 設計の `topLeft` / `flipH` は `drawQuad` に合わせて `at`（anchor セルの左上）/ `flipX` にした。`rimDoc` も欄で受ける |
| `Light.Rim` の置き場所 | Light に置いた（PxSprite → Light の参照。同じパッケージの中なので循環しても通る） |
| `Shadow.projectedRuns` | 横へ倒れる影の太さを決める `depth`（足元の楕円の縦 ÷ 横）を欄に足した（projectedBox の halfY / halfX と同じ意味）。走りの横の位置は倒す向きに直交する軸へ `|side.x| + depth × |side.y|` 倍して置く。濃さは影全体で `alpha × (1 − 高さ / いちばん上の高さ)` |
| `Shadow.projectedBox` | 根元の半幅 = `max(2, halfX·|side.x| + halfY·|side.y|)`（hd2d_lab の castQuad と同じ）。灯りが足元に重なる時は None を返すので戻りは `Option[PlacedItem]` |
| Param の描き出しの道 | `SoftRaster.SurfaceCmd` に欄を足さず、`Render.shaderSurfaces` が `ShaderDoc.bindParams` で Param を値の Const に置き換えた Spec を渡す。DrawHash の鍵には Spec の JSON（値の入った Const）がそのまま入る。GL だけが uniform `uParamN` で受ける |
| Param の知らせ | 実機は `App.noteSurfaceZ` の隣（本編と Pass の両方）で `warnOnce` に 1 回。描き出しは `Render.missingShaderParams(items)` を呼べば同じ物を引ける（HeadlessRender は items を持たないので自動では出さない） |
| `ShaderDoc.renameTex` | 名前の書き換えを、木を下から作り直す共通の `rewriteField` / `mapSpecFields` に寄せた（`bindParams` と共用） |
| gl_parity | 実行時に作るアトラス（`Scenes.bakedTextures`）を GL は `ensureTexture`・SoftRaster は PNG で読む口を足した。場面 `rimLight`（B: fade の丸めで ±2）・`castShadow`（B）・`paramRead`（A・0 px） |
| SoftRaster の不具合の直し | Add / Multiply の合成の範囲（`drawableAabb`）が regionRect 付きの sprite で region の割合を二重に掛けて小さくなり、アトラスの 1 コマを Add で貼ると描き出しで消えていた。表示の大きさと同じ「テクスチャ全寸 × scale」に直した |
| schema | `templates/*/assets/shader.schema.json` は out を生 JSON 行で持ち kind を列挙していないので、変えていない |

---

## 12. 外した口（試作が 3D の地形へ切り替えて、使う人がいなくなった）

round2a で HD-2D の 2D 版のために足した口のうち、次の物を外した。試作（港町 hd2d_lab・ダンジョン dungeon3d_lab）が
3D の地形へ切り替えたため、どちらからも使われなくなった。engine の中でも、使っていたのは engine のテストと
bench/gl_parity の場面だけだった。要るゲームが出たら、この節と §1・§2・§4・§5 の設計から足し直す。

| 外した物 | 節 | 一緒に外した物 |
|---|---|---|
| `PxShade.rimMasks`・`rimDirectionOf`・`rimFrameName`・`rimChar`・`rimKey`・`Light.Rim`・`Light.rimsFrom`・`PxSprite.drawRimQuad` | §1 | `PxShade` の `mapCells` / `isSolid` への切り出しを元の `shade` へ戻した・TestPxShade / TestLight / TestPxSprite の輪郭光の検査・gl_parity の場面 `rimLight` と実行時に作るアトラスの口（`Scenes.bakedTextures`・`Main.uploadBaked` / `bakedImages`） |
| `Shadow.projectedBox` | §2 | TestShadow の 2 本・gl_parity の `castShadow` の家の影 |
| `CameraRig.CameraView`・`screenView`・`follow`・`followParallax`・`parallaxCenterScaled`・`toScreen`・`visibleRectOf` | §4.2 | TestCameraRig の 5 本 |
| `App.PassCtx`・`withPassPlanView`・`withScreenView`・`cameraViewOf`・`passCtxOf` | §4.3 | `App.Rec#passes` を `w -> Render.PassPlan` へ戻した・`Rec#screenView` の欄・`renderFrame` で camera を 1 回だけ求める受け渡し（`sceneItemsAt`・`cameraViewIn`）・TestPassPlan の 2 本 |
| `Light.worldLightMapPass`・`Light.withUnlit` | §4.3・§5 | `lightMapPassOf` への切り出しを元の `lightMapPass` へ戻した・TestLight の 2 本 |

残した物（試作が使っている・round2a の前からある）: `Shadow.projectedRuns`・`ShaderDoc.Field.Param`・`Render.withShaderParams`・
`Render.missingShaderParams`・`App.withPassPlan`・`Render.passSpecsOf`・`Render.resolvePassReads`。
文書は `docs/api-digest`（作り直し）・`docs/z-bands.md`・`docs/backend-parity.md`・`docs/headless-render-recipe.md`・`docs/shader-doc.md`・
`agents-pack/AGENTS.core.md` の早見表・`agents-pack/agent-eval/engine.json` のお題（`pass-scene-camera`・`rim-light-sprite`）を直した。
