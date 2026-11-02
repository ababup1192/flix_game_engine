# engine round6 — 段 E: メッシュのテクスチャ・法線マップ・mipmap・glTF / OBJ のテクスチャ

改訂 3（2026-11-02。レビュー 61 → 83 点。残りの 5 点と小の指摘を反映）。ブランチ `feat/3d-textures`（worktree `fge-postfx`、main の v0.72.0 から）。
前提は段 A〜D（`plans/engine-round4-3d.md`・`plans/engine-round5-skinning.md`）。後ろに段 F（HDR・トーンマッピング・FXAA）が続く。

用語: uv（頂点ごとの絵の上の位置）・タンジェント（面の上で u が増える向き）・法線マップ・mipmap（縮めた絵の段）・lod（読む段の番号）・
REPEAT / CLAMP（uv が 0〜1 の外へ出た時に繰り返すか、端の色を伸ばすか）。「鍵」は DrawHash の鍵だけを指す。

## 0. 目的と範囲

今の 3D の質感は ShaderDoc の手続き的な模様と頂点の色だけで、絵を貼れない。Blender で塗った絵・写真の質感・でこぼこの陰を貼れるようにする。
出来上がりの判定は fps3d_lab の書斎と礼拝堂で、木目・石・布・番兵の服（材質スロットが分かれた glb）が「模様」から「物」に見えること。

| 入れる | 入れない（理由） |
|---|---|
| 頂点の uv 1 組と、そこから求めるタンジェント | uv2（光のベイクの段で） |
| 3D の材質で ShaderDoc の `Tex` / `TexBlur` / `Uv` を読む（今は 0 に潰している）。emission も絵を読める | PBR（段 F の後に別の計画） |
| ShaderDoc に `Field.VertexColor`（3D だけ値を持つ。2D では 1） | 視差マップ・ディスプレイスメント |
| 法線マップ（タンジェント空間・OpenGL 流＝緑が絵の上・強さつき・骨つきも） | 異方性フィルタ（CPU とそろえられない） |
| 材質ごとの wrap（REPEAT 既定・CLAMP） | MIRRORED_REPEAT（REPEAT で読み、読み込みで 1 行知らせる） |
| mipmap（段は CPU で作って GL へ全部上げる・lod の式は GL と CPU で自前に持つ） | ドライバの glGenerateMipmap（縮め方が実装任せで CPU とそろわない） |
| 絵を場面に値で持たせる `Texture3d`（中身のハッシュで名前と GPU の置き場を決める） | 実行中に描き換える 3D の絵（2D の ensureTexture と全体の登録の名前で読める） |
| glTF の TEXCOORD_0・TANGENT・baseColorTexture・normalTexture・sampler・glb に埋めた PNG / JPEG・primitive ごとの材質 | 外の uri・data URI・KHR_texture_transform・texCoord ≠ 0（読み飛ばして 1 行知らせる） |
| OBJ の vt | .mtl の map_*（E5 で要れば足す） |
| uv の無い形への箱投影の uv（`Mesh3d.withBoxUvs`） | 自動の uv 展開 |
| — | 影の地図での cutout（今の決まりのまま。葉や柵の影は抜けない。理由は SoftRaster3d.buildShadowMap の WhyNot） |

色: 絵の値はそのまま光の計算に入れる（sRGB を線形へ戻さない。今の頂点の色と同じ）。段の平均も同じ値のまま取る。
**段 F への申し送り**: ガンマを直す時、段の平均を線形で取り直す（今のままだと遠くの段がわずかに暗い）。

## 1. 型（engine/src/scene3d/）

### 1.1 Mesh3d に uv とタンジェント（fromArrays の引数は変えない）

```flix
pub mod Mesh3d {
    // Vertices に uvs = Option[Vector[Float64]]（[2i, 2i+2)）・tangents = Option[Vector[Float64]]（[4i, 4i+4)。xyz・w = ±1）を足す（非 pub）。
    // uvs が Some なら tangents も必ず Some。

    /// uv を付ける（タンジェントは §1.2 で求める）。数が頂点の数 × 2 でない・NaN・無限は Err。
    pub def withUvs(uvs: Vector[Float64], m: Mesh3d): Result[String, Mesh3d]
    /// 外で求めたタンジェント（glTF の TANGENT）で置き換える。uv が無い・数の食い違い・w が ±1 でない・xyz の長さ 0 は Err。
    pub def withTangents(tangents: Vector[Float64], m: Mesh3d): Result[String, Mesh3d]
    /// uv つきの多角形（points と同じ数の uv）。
    pub type alias TexturedPolygon = { points = List[Vec3.Vec3], uvs = List[Vec2.Vec2], color = Color }
    pub def fromTexturedPolygons(polys: List[TexturedPolygon]): Result[String, Mesh3d]
    /// 箱投影の uv（§1.3）。
    pub def withBoxUvs(scale: Float64, m: Mesh3d): Mesh3d
    pub def uvs(m: Mesh3d): Option[Vector[Float64]]
    pub def tangents(m: Mesh3d): Option[Vector[Float64]]
}
```

- contentHash: uv の無い形は今の字のまま（既存の鍵を変えない）。uv つきは今の字に uv とタンジェントを足して SHA を取る。
- **作るのは読み込みの時に 1 回**（docs に書く）。毎コマの View で withUvs・withBoxUvs を呼ぶと毎コマ SHA が走る。

### 1.2 タンジェントの求め方（作る時に 1 回・GL と CPU は同じ値を読む）

uv の決まり: (0, 0) が絵の左上・v は絵の下へ増える（glTF と同じ。2D の面の Uv とも同じ）。

1. 三角形ごとに e1 = p1 − p0・e2 = p2 − p0・(du1, dv1)・(du2, dv2)・det = du1·dv2 − du2·dv1。|det| < 1e−12 の三角形は足さない。
   t = (e1·dv2 − e2·dv1) / det（u が増える向き）・b = (e2·du1 − e1·du2) / det（v が増える向き＝絵の下）。
2. 頂点ごとに、その頂点を使う三角形の t と b を足す（扇に割った多角形・fromArrays の共有頂点とも同じ）。
3. t' = normalize(t − n·(n·t))。長さ 0 なら n に直交する決まった向き（|n.y| < 0.9 なら normalize(cross(上, n))、でなければ normalize(cross(東, n))）。
4. **w は「絵の上（−v）の向き」で決める**: w = sign(dot(cross(n, t'), −b))（0 なら +1）。シェーダーでは B = cross(N, T)·w が絵の上を向く。

法線マップの読み（§2・§3 で共通）: c = 絵の rgb（0..1）・m = ((c.x·2 − 1)·s, (c.y·2 − 1)·s, c.z·2 − 1)・n' = normalize(T·m.x + B·m.y + N·m.z)。
緑が大きい（c.y > 0.5）画素は法線を絵の上へ傾ける（OpenGL 流・Blender と glTF と同じ）。

### 1.3 箱投影の uv

面（三角形）の法線の一番大きい軸で写す（頂点の法線では選ばない。1 枚の中で軸が混ざって絵が伸びるため）。軸が違う面と共有している頂点は分ける
（スキンの欄も一緒に分ける）。座標は**形の座標**（置き場所を動かしても絵が付いて動く）× scale。

| 面の軸 | u | v |
|---|---|---|
| +X / −X | +z / −z | −y |
| +Y / −Y | +x / +x | −z / +z |
| +Z / −Z | −x / +x | −y |

鏡写しにならない条件は cross(u の向き, v の向き) = 外向きの法線（Scene3d の座標の決まりで、画面の右 = cross(上, 見る向き)）。
テストは表から書かず、この条件（cross(∂p/∂u, ∂p/∂v) が外を向く）で 6 面とも確かめる。+Y 面は北が絵の上。
頂点を分ける条件は「6 面のうち別の面と共有している」（+X と −X も u の符号が違うので分ける）。

### 1.4 Texture3d（閉じた型）

```flix
pub mod Texture3d {
    pub type alias Texture3d = Texture3dData
    /// ARGB・行優先・行 0 が絵の上。数の食い違い・辺 0・辺 > 8192 は Err。
    pub def fromArgb(width: Int32, height: Int32, argb: Vector[Int32]): Result[String, Texture3d]
    /// PNG / JPEG のバイトを画素に戻す（javax.imageio）。読めなければ Err。
    pub def decode(bytes: Vector[Int8]): Result[String, Texture3d] \ IO
    pub def width(t: Texture3d): Int32
    pub def height(t: Texture3d): Int32
    pub def argb(t: Texture3d): Vector[Int32]
    pub def contentHash(t: Texture3d): String
    /// 材質の Tex が読む名前（"tex3d:" + contentHash の頭 16 字）。場面の textures に入れた絵はこの名前で引く。
    pub def name(t: Texture3d): String
}
```

- contentHash は寸法と画素の**バイトを直に** MessageDigest へ流す（文字列につながない）。作る時に 1 回だけ。
- decode は engine に初めて java.desktop を持ち込む。Studio の同梱 JRE の `JRE_MODULES` に java.desktop が入っていることを E1 の初めに確かめる
  （SoftRaster が同じ JRE で ImageIO を使っているので入っている見込み）。

### 1.5 Material3d を閉じた型にする（この段で一度だけ壊す）

```flix
pub mod Scene3d {
    pub enum Wrap with Eq { case Repeat  case Clamp }
    pub type alias NormalMap = { texture = String, strength = Float64 }
    pub type alias Material3d = MaterialData                       // 閉じた型（Instance3d・Billboard3d と同じ形）
    pub type alias MaterialFields = { spec, params, cutout, emission, normalMap = Option[NormalMap], wrap = Wrap }
    pub def material(spec: ShaderDoc.Spec): Material3d             // params 空・cutout なし・emission なし・normalMap なし・Repeat
    pub def withParams(p: Map[String, Float64], m: Material3d): Material3d
    pub def withCutout(on: Bool, m: Material3d): Material3d
    pub def withEmission(s: ShaderDoc.Shade, m: Material3d): Material3d
    pub def withNormalMap(n: NormalMap, m: Material3d): Material3d
    pub def withWrap(w: Wrap, m: Material3d): Material3d
    pub def materialFieldsOf(m: Material3d): MaterialFields
    /// 絵 1 枚 × 頂点の色（Tex を r・g・b に、VertexColor を掛ける）。filter は絵の読み方（ドット絵なら Nearest）。
    pub def texturedMaterial(texture: String, filter: ShaderDoc.FilterMode): Material3d
    pub def maxMaterialTextures(): Int32 = 6
    // Scene3dCmd に textures = List[Texture3d.Texture3d] を足す（scene() は Nil）。
}
```

- 材質の絵の数え方: `ShaderDoc.materialTexReads(spec, emission)`（`materialParamNames` と同じ作りの正典の並び）が返す (名前, 補間) の組の数。
  **描く時に** 7 組目からを 0 にして、材質ごとに 1 回だけ知らせる（GL と CPU で同じ。作る関数は Result にしない）。法線マップは別枠（unit 6）。
- `ShaderDoc.Field.VertexColor({ chan = TexChan })`: 3D の材質では**頂点の色だけ**の chan（tint は今どおり材質の色の後で掛かるので入れない）、2D の面では 1。
  GL の材質の frag に `in vec3 vColor` を足す（頂点シェーダーは今も出している）。Kd の無い OBJ の材質は灰色 0.6 なので、texturedMaterial の絵が暗くなる（docs に書く）。材質のある物が頂点の色を失う問題
  （OBJ の Kd・glTF の baseColorFactor）をこれで書ける。
- Spec の `Normal` が読むのは**法線マップを当てる前**の法線（材質の色を先に求めるため）。光の計算は当てた後の法線。

### 1.6 名前の引き方（GL と CPU で同じ）

① `tex3d:` で始まる名前は場面の `textures` から（無ければ 0・1 回知らせる）。② ほかは全体の登録（project.json・ensureTexture）。
③ 無ければ 0（黒・透明）・名前ごとに 1 回知らせる。名前がぶつかる決まりは無い（中身のハッシュの名前と、人が付けた名前は字の形で分かれる）。

### 1.7 Model3d と Gltf

```flix
pub type alias ModelPart = { mesh = Mesh3d.Mesh3d, material = Option[Scene3d.Material3d] }
pub type alias Model3d = { mesh, skin, clips, parts = List[ModelPart], textures = List[Texture3d.Texture3d] }

pub mod Gltf {
    pub def fromGlb(bytes): Result[String, Model3d]                   // parts は primitive ごと（材質 None）・textures は空
    pub def loadTextured(path: String): Result[String, Model3d] \ Fs.FileRead + IO   // parts に材質・textures に画像
}
```

- `mesh` は今と同じ「全部の primitive をつないで baseColorFactor を頂点の色に掛けた物」（今の呼び手を壊さない）。
- `parts` は primitive ごとの形。同じ `skin` と `Pose` を全部の part に渡せば曲がりはそろう。uv を持つ primitive だけ uv つき（混ざってよい）。
  `flatShaded`（法線の無い primitive で頂点を分ける）は uv とタンジェントも分ける。
- 材質（loadTextured）: baseColorTexture → `texturedMaterial(Texture3d.name, sampler の magFilter が NEAREST なら Nearest・他は Linear)`、
  baseColorFactor は頂点の色に入れる（VertexColor で掛かる）。wrapS/T が CLAMP_TO_EDGE なら Clamp。normalTexture → NormalMap（strength = scale・既定 1）。
  絵の無い材質の primitive は材質 None（頂点の色）。
- TANGENT: ノードの world 行列を頂点に掛ける時、xyz にも同じ行列の左上 3×3 を掛けて正規化し、行列式が負なら w に −1 を掛ける。
  そのあと座標の x 反転に合わせて x を反転し w の符号も反転する。無ければ §1.2 で求める。
- 知らせて読み飛ばす物（1 行ずつ）: texCoord ≠ 0・KHR_texture_transform・MIRRORED_REPEAT・外の uri。

### 1.8 OBJ

`fromObj` が vt を読み、f の `v/vt/vn` の 2 番目を使う。**v' = 1 − v**（OBJ は左下が 0）。全部の面に vt があれば uv つき、1 つでも欠ければ uv なし。
OBJ は今 Z の鏡写しで読む（fromObj の WhyNot）ので、形と一緒に絵も鏡写しになる。u は反転しない（形と絵がそろって鏡写しのままの方が、
左右非対称の家具と絵の位置が食い違わない）。文字の入った絵を OBJ に貼るなら glb を使う、と docs に書く。

## 2. GL（render_gl/src/Render3d.flix ほか）

- 頂点: uv つきの形は別の VBO で loc5 = uv・loc6 = タンジェント。無い形は今の VAO（属性の既定値）。骨つき（loc3・loc4）と並べて持てる。
- 頂点シェーダー: `vUv`・`vTangent`。タンジェントの xyz は `uModel` の左上 3×3 で写す（法線の uNormal ではない）。w に sign(det(uModel の 3×3)) を掛ける。
  骨つきは法線と同じくジョイントの行列の回転を掛ける。
- フラグメント: T を画素ごとに N で直交させ直す（Gram–Schmidt）。
- 材質のシェーダー（`ShaderGen.compile3d`）: `withoutTextures` をやめ、`materialTexReads` で `uTex{i}`（unit 0〜5）を宣言・`sg_uv = vUv`。
  法線マップは unit 6・影は unit 7（今のまま）。材質の wrap は法線マップにも掛かる。法線マップは Linear の mip つきで読む。プログラムの鍵に「uv あり」「法線マップあり」を足す（頂点シェーダーは骨の有無と合わせて 4 通り）。
- **lod（GL と CPU で同じ式）**: 絵を読む座標 c（Spec の変換の後・REPEAT で 0〜1 に戻す前）について、d = (∂c/∂x, ∂c/∂y)。
  d の各成分から floor(d + 0.5) を引く（`fract` の継ぎ目で 1 跳ぶ所を消す。GLSL の round は 0.5 の向きが実装任せなので使わない）。
  ρ = max(length(vec2(∂u/∂x·w, ∂v/∂x·h)), length(vec2(∂u/∂y·w, ∂v/∂y·h)))（w・h は段 0 の寸法）・lod = clamp(log2(ρ), 0, 段の数 − 1)。
  1 画素で 0.5 以上動く本当の微分（遠くの細かいタイル）は差し引きで小さく化けて lod が 1 段ほど低くなる。最後の 2 段あたりの話なので許す。
  GL は `textureLod(uTex{i}, c, lod)` を使い、∂ は dFdx / dFdy。CPU は §3。残る差は dFdx が 2×2 の区画で取る粒度だけ（gl-parity は B）。
- 段の中身: 3D の材質に使う絵は、**CPU で段を作り**（§3 と同じ関数）`glTexImage2D(level = k)` で全部上げる。GL の自動生成は使わない。
  - 場面の `Texture3d`: Render3d が contentHash ごとに上げて持つ（メッシュと同じ LRU。今のコマで使った物は追い出さない・上限は 64 枚と段込み 256 MB の小さい方・超えたら 1 回知らせる）。
  - 全体の登録の絵: Paint の登録簿に版の番号を持たせ（作り直すたびに +1）、Render3d は (texId, 版) が変わったら段を作り直す。
    画素は Java 側に持っていない（STB で直に上げている）ので、3D の材質で初めて使う時と版が変わった時に `glGetTexImage(level 0)` で読み戻して段を作る（登録の絵を全部ヒープに二重に持たない）。
  - 段は 1×1 まで作る（GL の完全性）。段を作る `Mip.build` は engine に置く（render_gl は engine_tools を参照しないため）。
  - レンダーターゲットの名前: 3D の材質からは mipmap なしで読む（毎コマ書き換わるため）。
- sampler object: wrap 2 × filter 2 × mip の有無 2 = 8 個。Nearest の mip は NEAREST_MIPMAP_LINEAR（段の切り替わりの筋を出さない）、Linear は LINEAR_MIPMAP_LINEAR。
- **後始末**: 材質を描いた後、使った unit 0〜6 の sampler を `glBindSampler(unit, 0)` で外し、`glActiveTexture(GL_TEXTURE0)` に戻す
  （ビルボードと 2D の面が unit 0 で読むため。`Sprite.drawShaderSurface` と同じ決まり）。
- TexBlur は `textureLod(…, 0.0)` に替える（`blurSource` の WhyNot のとおり）。
- 2D の面の Tex（CLAMP・mipmap なし）は変えない。

## 3. CPU（engine_tools/src/SoftRaster3d.flix・engine/src/ShaderEval.flix）

- 三角形の頂点の欄を 13 → 19（uv 2・タンジェント 4）。材質の tint は三角形ごとの Mat へ移す。ビルボードの uv は新しい uv の欄。
- `bendVertices` はタンジェントの xyz も法線と同じに曲げる。`clipNear` は新しい欄も補間する。
- `perspectiveWeights` で uv・タンジェントを補間し、`evalMaterial3` へ uv・頂点の色を渡す。`isCutAway`（coverRow の中）にも uv を渡す。
- `ShaderEval.compileMaterial` に texEnv を渡す。3D の `Node.Tex` は wrap を持つ: Repeat は座標を 0〜1 に戻し、LINEAR の 4 テクセルも
  `wrapTexel`（反対の端へ回る）で引く（GL の REPEAT と同じ）。Clamp は今の `clampTexel`。
- lod: 絵を読む材質の画素では、右隣・下隣の画素の入力（world・uv・法線・頂点の色）も同じ遠近補正で求め（隣が三角形の外でも重みをそのまま外へ延ばす。
  GL の helper の画素と同じ）、**隣の入力では `env3` の shared（Field.Ref）の評価からやり直して**、Tex の座標の式を 3 つの入力で評価して差を取る
  （§2 の式・floor(d + 0.5) の差し引きも同じ）。atWorld は shared に書く決まりなので、ここを使い回すと world に貼る絵の lod が 0 に落ちる。
  座標の式の中にある入れ子の Tex（Shift を Tex で動かす形）は、隣の入力では中心の lod で読む（B の許容に入る）。絵を読まない材質は今の 1 回の評価のまま。
- 段の読み方（§2 の sampler の組と同じ）: lod ≤ 0 は mag の filter で段 0 を読む。Nearest は隣り合う 2 段をそれぞれ NEAREST で読み lod の小数で混ぜる
  （NEAREST_MIPMAP_LINEAR）。Linear は 2 段をそれぞれ LINEAR で読んで混ぜる（LINEAR_MIPMAP_LINEAR）。
- cutout の α（`isCutAway`）は lod 0 で読む（隣の画素の評価を繰り返さない。GL も cutout の判定は `textureLod(…, 0.0)` で同じにする）。
- 段: 2×2 の平均（辺が奇数なら次の段の辺は floor(n/2)、はみ出す列と行は端のテクセルを繰り返して平均）。`Mip.build(TexData): List[TexData]`。
  置き場は `TexData` の欄を増やさず、書き出し 1 回の間持つキャッシュ（鍵は Texture3d の contentHash・ファイルの絵は名前と更新時刻）。
  `sceneTexturesOf` がコマごとに写し直している今の形も、同じキャッシュに乗せる。
- 法線マップは §1.2 の式。

## 4. 描き出しの経路で絵を届ける

- GL: 全体の登録の絵は `RenderPaint.billboardTexture` と同じ closure を `drawScene`・`splitByMaterial`・`drawMaterialInstance` に通す。
- CPU: `sceneTexturesOf` が材質の Tex・emission の Tex・法線マップの名前も集める。場面の `textures` は `Texture3d.argb` から直に作る。
- 鍵（DrawHash）を直す所: `putMaterial`（閉じた型になった Material3d・normalMap・wrap）、Scene3dCmd のパターン（textures の contentHash）、
  Mesh3d の uv の有無（contentHash に入る）。

## 5. 段取り（各段で緑・gl-parity・自分の検証。レビューは E2 の後と E5 の後）

| 段 | 中身 | 出来上がりの判定 |
|---|---|---|
| E1 | Mesh3d の uv・タンジェント・withBoxUvs・Texture3d・Material3d を閉じた型に・VertexColor・材質の Tex（GL / CPU・wrap・sampler の後始末） | テクセルの中心の色の単体テスト・`texturedBox` が gl-parity B・既存の gl-parity と reference の SHA が変わらない |
| E2 | 法線マップ（GL / CPU・骨つき） | 錨のテスト（(128,255,128) が絵の上へ傾く）・`normalBump`・`skinNormal` が B |
| E3 | mipmap（段は CPU・lod の式は両方） | `mipFloor`・`mipFloorScaled`（Scaled で包む）・`mipFloorWorld`（shared に書いた atWorld）が B・遠い床がちらつかない動画・fps3d_lab の部屋の CPU 書き出しの時間を前後で比べ、2 倍を超えたら直す（docs/performance.md の門） |
| E4 | glTF（parts・材質・sampler・TANGENT・画像）と OBJ の vt | Blender で作った 2 材質・絵つき・法線マップつきの glb が正しい向きで出る・TANGENT 一致のテスト |
| E5 | fps3d_lab に絵を貼る（Blender で絵を作る・番兵の服・床・壁・本棚） | 前後の絵を並べて見せる・GPU 動画 |

## 6. テスト

- engine:
  - `TestMesh3dUv`: 数の食い違いは Err・板のタンジェントが +X で w が絵の上の向き・uv で鍵が変わり uv 無しは今の字・withBoxUvs の 6 面の向き・共有頂点が分かれる。
  - `TestTexture3d`: 寸法の Err・decode が 2×2 の PNG を戻す・contentHash が同じ画素で同じ。
  - `TestShaderWorld3d`: REPEAT（u = 1.25 と 0.25 が同じ）・LINEAR で u = 0 が端の 2 テクセルの平均・Clamp・VertexColor（2D では 1）・lod の式（round の差し引き）。
  - `TestGltf`: Blender で作った `textured_two_materials.glb`（数 KB・作る .py も置く）で parts が 2・uv・画像の寸法・sampler の NEAREST・
    **TANGENT と、同じ形から §1.2 で求めたタンジェントが一致**。
- engine_tools: `TestSoftRaster3d` に「左上が赤の絵の板で左上の画素が赤」「法線マップの錨（緑の画素で上の灯りの側が明るい）」「Mip.build の奇数の辺」。
- render_gl: `TestRender3dMaterial` に Tex・emission の Tex・法線マップつきの材質のシェーダーが通る・7 組目が 0 になる。
- gl-parity（全部 B）: `texturedBox`・`normalBump`・`skinNormal`・`mipFloor`・`mipFloorScaled`・`mipFloorWorld`・`gltfTextured`・
  `afterScene3d` に「絵つきの材質の後のビルボードと 2D の Tex の面」を足す（sampler の後始末の退行を捕まえる）。
- 退行: 既存の gl-parity と全テンプレートの reference の SHA が変わらない。

## 7. 移行（0.73.0）

- `Scene3d.Material3d` をレコードで書いている所は `Scene3d.material(spec) |> withParams(…) |> withCutout(true) …` に替える（閉じた型になった）。
  レコードを読んでいる所は `materialFieldsOf`。`withCutout(on: Bool, m)` は Bool を取る（テストが真偽で切り替えるため）。
  直す所: fps3d_lab `src/Res.flix`（2 か所）・`bench/gl_parity/src/Scenes.flix`・`engine_tools/test/TestSoftRaster3d.flix`・
  `DrawHash.putMaterial`・`SoftRaster3d.matOf`・Render3d（`splitByMaterial`・`materialKey`・`sameMaterial` ほか）。
- `Field.VertexColor` で ShaderDoc の enum を網羅する所が全部動く: ShaderDoc の fold / rewrite・ShaderGen の `eqField` / `fieldExpr`・
  ShaderEval の `compileFieldIn`・ShaderJson（読み書きとスキーマ）・Studio の Shader エディタのフォーム（Studio の側で 1 行）。
- 新しい仕組みの手順（AGENTS.md）: `bin/lint-rules/forbid.json` に Material3d のレコードのリテラルを止めて `Scene3d.material` へ導く 1 行・
  `agents-pack/AGENTS.core.md` の早見表に 1 行（絵を貼る）・`agent-eval/engine.json` にお題 1 本・api-digest と API 索引。
- `Model3d` をレコードで組んでいる所は `parts = Nil, textures = Nil` を足す（engine の外には無い見込み）。
- `Mesh3d.fromArrays` は変えない。

## 8. 決めたこと（改訂 1 の未決）

1. wrap は材質の欄（Repeat 既定・Clamp）。glTF の sampler からも引く。
2. 絵は場面に値で持たせる（Texture3d・名前は中身のハッシュ）。App の ensureTexture の配線は足さない。
3. 段の中身は CPU で作って GL へ上げ、lod の式は両方に自前で持つ。許容幅は今の 3D の場面と同じ B。
4. 法線マップは材質の欄。頂点の色は `Field.VertexColor` で材質の中から読む。
