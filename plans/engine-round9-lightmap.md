# 段階 H（小さな版）: lightmap を描く API（rev3）

rev2 → rev3: 再レビュー 87 点。名前の無い絵の扱い・G の後の colorSpace・頂点シェーダーの 2 通り・mip の上限と margin・GLSL の名前の頭・
sg_texMip の出す位置・CPU の表と DrawHash の引数・D7 のおすすめを直した。

rev1 → rev2: レビュー 78 点。G の前の露出の受け渡し・1/2.2 乗をやめて sRGB の区分の式の逆で戻す・色空間の欄を G1 と同じ `ColorSpace` に・
使うかどうかの判定を engine の 1 か所（`Scene3d.lightmapOf`）に・骨つきは使わない・上下の反転・mip とふちのにじみ（bake margin）・
CPU の隣の画素の uv2 を ShaderEval に手を入れずに求める・`sg_texMip` の二重の定義・書き出しの数字と絵の上限・テストの穴・L0 の take を直した。

rev0 → rev1: 段階 G（色の線形化）の後に回す下書きだったのを、**段階 G より先に入れる小さな版**に書き直した。
きっかけは `/Users/abab/Desktop/horror_apartment`（Blender で作った夜の 4 階建てアパート・一人称で歩く）。
実装は 0.74.0 のリリースの後（エンジン拡張はユーザー承認済み・今は設計まで）。

前提: 段階 E（`plans/engine-round6-textures.md`・`Texture3d`・`Mip`・`Gltf.loadTextured`）と段階 F（`plans/engine-round7-hdr.md`・HDR の Pass・トーンマップ）。
後に来る物: 段階 G（`plans/engine-round8-linear-color.md`）。この計画は G の前後どちらでも同じ API で動くように書く（§4）。

用語: lightmap ＝ 動かない物に当たる光（直接光と間接光）を前もって計算して絵にした物。ベイク ＝ その計算（Blender の Cycles でやる）。
2 本目の UV ＝ lightmap を貼るための UV（glTF の `TEXCOORD_1`）。動く光 ＝ 今の `PointLight` と `SpotLight`（実行中に毎コマ計算する光）。

## 0. 書き出しの中身（実測・2026-11-02）

`/Users/abab/Desktop/horror_apartment/export/` を python で読んだ（manifest.json は読むだけ）。**書き出しは別の作業が書き換え中で、glb と絵の数は読むたびに違う**
（読んだ時点で 4〜12 本の glb・1〜17 枚の lightmap。階ごとの `bld_F1`〜`F4`・`stairs`・2048 × 256 の `road` などが増えている）。下の数字はその日の値で、形式の主張だけを当てにする。

| 物 | 中身 |
|---|---|
| glb の属性 | 部屋と地面と小物（`bld_shell`・`site_ground`・`site_props` ほか）は `POSITION` `NORMAL` `TEXCOORD_0` `TEXCOORD_1`（どちらも float の VEC2）。`TANGENT` は無い（engine が uv から求める）。`alpha_*`・`collision` は `TEXCOORD_1` 無し |
| glb の形 | どの glb も node・mesh・primitive が 1 つずつ（part が 1 つに lightmap が 1 枚で済む） |
| glb の材質 | baseColorTexture・normalTexture・metallicRoughnessTexture。`site_props` は emissiveTexture と `KHR_materials_emissive_strength = 40`。**lightmap の絵は glb の中に無く、材質からも指されていない**（glTF に lightmap の決まった欄が無いため） |
| lightmap の PNG | `export/lightmaps/*_lightmap.png`。8bit の RGB。manifest の説明は「lightmap × 0.5 を sRGB で書いた物（読んだ後に 2 を掛ける）」 |
| lightmap の EXR | 同じ名前の `.exr`。**float32（manifest の「half-float」と違う）・圧縮無し**・チャンネル B G R・ヘッダの `colorInteropID = srgb_rec709_display` |
| 明るさ | `site_props` の EXR は値の 1.3% が 1 を超え、最大 2.63（灯りの近く）。`bld_shell` は最大 0.84 |
| UV の埋まり方 | manifest の lightmap の uv_fill は 0.03〜0.41（`site_props` は 2048² のほぼ全部が空き）。mip のにじみに関わる（§5.2） |

**EXR と manifest の食い違い**: PNG と EXR を画素ごとに突き合わせると、`PNG = sRGB へ変換(0.5 × sRGB から線形へ戻す(EXR))` が
8,707 画素で ±1 の外れ 0 件で成り立つ。つまり **EXR の float は線形ではなく sRGB の曲線を掛けた値**（ヘッダの colorInteropID と合う）で、
manifest の「linear」と合わない。PNG の側は manifest の式どおり（線形の光 L に対して `sRGB(0.5 L)`）。
この計画は PNG を正として読む（v1 は PNG だけを読む・§6 の L5）。書き出し側に「EXR を線形で書く（Save as Render を切る）か、manifest を直す」ことを頼む（§10 の論点 D6）。

PNG で失う物: 線形の光で 2 を超える所（EXR の値で 1.353 超え）は 255 に切れる。`site_props` で約 1% 未満・灯りのすぐそばだけ。
暗い所は 8bit の sRGB なので、線形 0.02 前後（このアパートの壁の平均くらい）で 1 階調が約 9% の明るさの差になる。露出を上げるとグラデーションにバンディングが見えうる（§6 の L5 で HDR を読む理由）。

## 1. ねらいと合格線

Blender でベイクした光（直接光 ＋ 間接光）を、材質の絵（base color）に掛けて描く。懐中電灯（スポット）や揺れる灯り（点光源）は、その上に今の式で足す。
柔らかい影・隅の暗がり・光の回り込みが、実行中の重さほぼ 0 で出る。

**合格線**:
- **lightmap を付けない絵は 1 bit も変えない**: make gl-parity の A 段階の全部の行がバイト一致・B 段階の行は差の画素数が今と同じ・テンプレートの reference（SHA256SUMS）が一致。
  既存の材質のプログラムの GLSL の文字も 1 字も変えない（§5.2）。
- GL と CPU（SoftRaster3d）が同じ式で描き、gl-parity の新しい B 段階の行が上限の中に収まる。
- アパートの**主な 3 本（`bld_shell`・`site_ground`・`site_props`）**を PNG の lightmap つきで、一人称の場面に出せる（ゲーム側の試し・§6 の L4）。
  全部の階を一度に出すのは絵の上限（§2 の最後）を片づけてから。

## 2. 範囲

### v1 に入れる物
1. glb の `TEXCOORD_1` を読み、`Mesh3d` に 2 本目の UV（`uvs2`）を持たせる。
2. 置いた物（`Instance3d`）に lightmap（絵の名前・色空間・強さ）を持たせる: `Scene3d.withLightmap`。
3. GL と CPU の両方で、`色 = albedo × tint × toon(ベイクした光 + 動く光)`。lightmap を持つ物は環境光と hemisphere を足さない（ベイクした光に入っている）。
4. 動く光（点光源・スポット・スポットの影）と法線マップは、動く光の側にだけ掛かる。emission・fog・cutout・`Output.Depth` は今のまま。
5. 明るさの倍率（`intensity`）。G の前はベイクした光の露出もここに入れる（§3.3）。
6. 8bit の lightmap の色空間（`Srgb` / `Linear`）。

### v1 で使わない組み合わせ（どれも置いた物ごとに 1 回知らせ、lightmap を使わずに今の式で描く）
- uv2 の無い形（法線マップと uv の関係と同じ）。
- 材質の無い置いた物（頂点の色で描く物）。要るなら `Scene3d.material` で包む（論点 D4）。
- 骨つき（`Scene3d.skinningOf` が Some）。Unity も SkinnedMeshRenderer には lightmap を付けない。プログラムの形（skin × uv × 法線マップ × lightmap）を増やさない。
- 絵の名前が `tex3d:` で始まらない（場面の textures 以外。レンダーターゲットや project.json の登録の絵）。上下の反転と mip の写しの扱いを lightmap に持ち込まない。
ビルボードは lightmap を持たない（`Billboard3d` に欄を足さない）。

### 後に回す物
- lightmap をベイクする道具（engine では作らない。Blender の Cycles で作る流れは各ゲームの modeling に置く）。
- light probe（動く物に、ベイクした光を当てる仕組み。Unity の Light Probe・Godot の LightmapGI の probe・Bevy の irradiance volume）。
  v1 の動く物（人・扉）は今の環境光と hemisphere で照らす。
- 方向つき lightmap（Unity の Directional mode・Godot の `directional`）。v1 は法線マップがベイクした光に反応しない。
- GI の実行中の更新。lightmap の絵を 1 枚にまとめる atlas（Bevy の `uv_rect`・Unity の `lightmapScaleOffset`）。
- 光ごとに「lightmap を持つ物へは足さない」の指定（Godot の `light_bake_mode = Static`・Unity の Baked / Mixed）。
  ゲームは `PointLight` をレコードの字（`{ position = .., color = .., intensity = .., range = .. }`）で書いているので、欄を足すと全部止まる。
  v1 は「ベイクに入れた光は pointLights に入れない」を doc に書く。
- HDR の lightmap（EXR）。§6 の L5 に「入れるならこの形」を書き、v1 からは外す（論点 D3）。
- ShaderDoc の `Field` から lightmap を読む（材質の木で自由に混ぜる）。v1 は固定の掛け算だけで ShaderDoc を触らない（0.74.0 の ShaderDoc の比較の直しと当たらない）。

### アパートを歩くのに要るが、この計画の外の物（別の小さな作業として相談する）
- `site_props` の灯りの emissiveTexture と `KHR_materials_emissive_strength`（今の `Gltf.loadTextured` は読まない。ランプが光らない）。
- `alpha_chainlink`・`alpha_net` の `alphaMode: BLEND`（今の材質は cutout だけで、loadTextured は alphaMode を読まない）。
- **場面の絵の上限**（`Render3d.texture3dByteBudget` = 256 MB・枚数 64）: レビューの時点の manifest で数えると、base color・法線マップ・emission・lightmap を
  mip 込みで約 513 MB。**lightmap を除いても上限を超える**。上限を超えると知らせが出て、今と前のコマで使う絵は捨てられずに描画は続く。
  さらに `loadTextured` は使わない metallicRoughness の絵も decode するので Java のヒープにも乗る。
  → L4 の前提に「`plans/engine-asset-import.md` の最大サイズ（I1）で 1024 に縮める」か「上限の見直し」を置く（論点 D7）。

## 3. 他のエンジンとの比べ（短く）

| | Unity（Built-in / URP） | Godot 4 | Bevy | この計画 |
|---|---|---|---|---|
| UV | メッシュの `uv2`（import で自動生成もできる） | `UV2`（import の「Lightmap UV2」） | `Mesh::ATTRIBUTE_UV_1` | `Mesh3d.uvs2`（glTF の `TEXCOORD_1`） |
| どこに付けるか | Renderer（置いた物）の `lightmapIndex` と `lightmapScaleOffset` | `LightmapGI` ノードが置いた物ごとに持つ | **entity の `Lightmap` component**（`image`・`uv_rect`） | **置いた物**: `Scene3d.withLightmap(lm, instance)` |
| 明るさ | Lighting 設定の Indirect Intensity など | `LightmapGI` の energy 系 | **材質**の `lightmap_exposure`（線形の倍率。Bevy は物理の単位なので大きな値を入れる） | lightmap の `intensity`（線形の倍率） |
| 絵の形式 | dLDR / RGBM / HDR（機種ごと。Unity はこれを encoding と呼ぶ） | float の texture array | Image（多くは HDR の KTX2） | v1 は 8bit（sRGB か線形）。HDR は L5 |
| 環境光 | ベイクした物には足さない | 同じ | 同じ（おおよそ） | 足さない |
| 骨つき | 付けない（light probe で照らす） | 付けない | — | 付けない |

### 3.1 置いた物に付ける（材質に付けない）
3 つのエンジンとも、lightmap は**置いた物ごと**に持つ。同じ形と材質を 2 か所に置けば、当たる光は場所ごとに違うから。
このエンジンでも、`Gltf.loadTextured` の材質は glb ごとに 1 つで、同じ家具の glb を部屋の別の場所に置けば lightmap は別の絵になる。
材質に付けると、置き場所ごとに材質を作り直すことになり、材質のプログラムの鍵（spec の名前）も同じまま中身だけ違う形になる。
→ `Instance3d` に付ける（論点 D1。依頼の文面は「材質に」だったので、ここは人に確かめる）。

### 3.2 名前を Bevy にそろえるか
- 型の名前は `Lightmap`（Bevy と同じ。Unity・Godot も lightmap の 1 語）。2D の `Light.lightMapPass`（2D の光を Pass に積む別の物）と大文字の位置で取り違えやすいので、
  doc の頭に「3D のベイクした光。2D の `Light.lightMapPass` とは別」と書く。gl-parity の既存の行 `lightMap`（2D の配管）とも別の名前（`lightmapBaked3d`）にする。
- 明るさは `exposure` ではなく `intensity` にする。このエンジンで exposure は `PostProcess` の **stop の数**（2^stops 倍）を指し、
  Bevy の `lightmap_exposure` は**線形の倍率**。同じ語に 2 つの意味を持たせない。`PointLight` と `SpotLight` の `intensity`（線形の倍率）と同じ意味になる。
- 絵の読み方の欄は `encoding` ではなく `colorSpace`。Unity で lightmap の encoding は dLDR / RGBM / HDR（L5 の RGBM 案と同じ軸）を指すので、Srgb / Linear と混ぜない。

### 3.3 露出との関係
- `intensity` はベイクした光だけに掛ける線形の倍率（書き出しの形式を戻す ×2・ベイクした光の露出・動く光との釣り合いの調整）。
- **段階 G の前**: エンジンはガンマのままの値で Pass を持ち、トーンマップもその値に掛ける。manifest の「exposure 2^0.6」は線形の値への倍率なので、
  `PostProcess.tonemappedWith(op, 0.6, ..)` へそのまま写すと、線形に直して約 2^(0.6 × 2.2) ≒ 2.5 倍になり明るすぎる。
  → G の前は**ベイクした光の露出を `intensity` に入れる**: アパートは `intensity = 2.0 × 2^0.6 ≒ 3.03`。§4 の式で sRGB へ戻す前に掛かるので、ベイクした光の分は正確に合う。
  トーンマップの exposureStops は画面全体の仕上げとして別に決める（写すなら 0.6 / 2.2 ≒ 0.27 が目安）。
- **段階 G の後**: Pass が線形になるので、露出は exposureStops へ戻す（`intensity = 2.0`・exposureStops 0.6）。移行メモに書く。
- manifest の AgX はこのエンジンに無い（AcesFitted と Reinhard だけ）。近い見た目は AcesFitted ＋ 露出で合わせる（AgX を足すかは別の相談）。

## 4. 色空間（段階 G の前後）

決まり: **`Lightmap` は線形の光の量として受け取る**（Blender・Unity・Bevy と同じ）。8bit の絵の読み方だけを `colorSpace` で指す。

- `Srgb`: 読んだ値 s（0..1）を sRGB の区分の式で線形へ戻す（s ≦ 0.04045 は s / 12.92、ほかは ((s + 0.055) / 1.055)^2.4）。Blender の PNG の既定。
- `Linear`: 読んだ値をそのまま線形の光として使う。
- その後に `intensity` を掛ける: `L = toLinear(s) × intensity`。アパートの PNG は `Srgb`・`intensity = 2.0` で元の光の量になる（G の前は露出も掛けて 3.03・§3.3）。

**段階 G の前（今のエンジン）**: 光の計算はガンマのままの値（画像の画素の値）で行っている。線形の L をそのまま albedo（ガンマの値）に掛けると、
暗い所が沈みすぎる（線形 0.2 の光は画面では約 0.48 の明るさに見えるべき）。そこで、ベイクした光を **sRGB の区分の式の逆で画面の値へ戻してから**足す:

```
baked = linearToSrgb(max(L, 0))     // L ≦ 0.0031308 は 12.92 L、ほかは 1.055 L^(1/2.4) − 0.055。1 を超えても同じ式（切らない）
light = toon(baked + 動く光)        // 環境光と hemisphere は足さない
色    = fog(albedo × tint × light) + emission
```

- `Srgb`・`intensity = 1` なら baked は読んだ値 s とぴったり同じになる（テストで確かめる性質）。暗い所が浮かない
  （1/2.2 乗で戻すと、線形 0.002 が 0.026 でなく 0.059 になり、夜の暗がりが 2 倍以上明るく浮く）。
- 動く光が無い所では、ほぼ「線形で掛けてから sRGB で画面へ出す」と同じ見た目になる（Blender の Standard に近い。AgX の曲線は入らない）。
  厳密な等しさは pure な冪の式でしか成り立たないが、sRGB の式は 2.2 の冪に近く、G の画面への変換（sRGB の区分の式の見込み）とも同じ曲線になる。
- 動く光は今までどおりガンマの値の目盛りで足す。

**段階 G の後**: 光の計算が線形になるので `linearToSrgb` を外し、`light = toon(L + 動く光)` にする。`texture` と `intensity` の意味は変わらない。直すのは露出の置き場所（§3.3）と、`colorSpace` を書いた所だけ（下）。
- G1 は `Texture3d` に色空間を持たせる。この計画の `ColorSpace` は**G1 と同じ型**（`Texture3d.ColorSpace`）として今置く。G1 が入ったら色空間は絵の側（`Texture3d`）で持ち、
  `Lightmap.colorSpace` は外す（移行メモ。`{ colorSpace = .. | Scene3d.lightmap(n) }` と書いた所だけ止まる。既定の Srgb のまま使う所は止まらない）。同じ絵の色空間を 2 か所で指して食い違う形を残さない。
- G の計画書には「lightmap の `linearToSrgb` を外す」「`Lightmap.colorSpace` を `Texture3d` の側へ移す」「露出を exposureStops へ戻す」を足す（実装の時に足す。今は G の文書を触らない）。
- mip の平均はガンマの値のまま取る（今の `Mip.build`。G2 で線形の平均に替わる）。

## 5. API と中の作り

### 5.1 engine（`engine/src/scene3d/`）

**Mesh3d**（2 本目の UV）
- `Vertices` に `uvs2 = Option[Vector[Float64]]`（頂点ごとに 2 つ。uv と同じく (0, 0) が絵の左上）。
- `pub def withUvs2(uvs: Vector[Float64], m: Mesh3d): Result[String, Mesh3d]`（数が頂点の数 × 2 でない・NaN・無限は Err。`withUvs` と同じ形）。
  タンジェントは作らない（法線マップは 1 本目の UV で読む）。
- `pub def uvs2(m: Mesh3d): Option[Vector[Float64]]`。
- 中身の鍵: 2 本目の UV が無い形の鍵は今のまま（GL の頂点バッファ・描き出しの鍵を変えない）。有る形は `baseHash` に uv の欄と uv2 の欄を足して求める。
  今は `withUvs`・`withTangents`・`withBoxUvs` が全部 `withUvSet` を通るので、鍵は `withUvSet` と `withUvs2` が共に呼ぶ 1 つの関数（uvSet と uvs2 の両方を見る）で作る。
  `withUvs` と `withUvs2` をどちらの順で呼んでも同じ鍵になる。0.74.0 で Mesh3d のハッシュが ByteBuffer で SHA を取る形に替わるので、その関数に乗せる。
- `withBoxUvs` は頂点を面ごとに分ける（`pickRows`）。uv2 を持つ形では uv2 も同じ頂点の順で写す（落とさない）。
- 名前: `uvs2` は Unity の `uv2`・Godot の `UV2` にそろえた（Bevy は `UV_1`、glTF は `TEXCOORD_1`）。doc にこの 4 つを書く。

**Gltf**
- `readPrimitive` で `TEXCOORD_1` を `optionalAttribute`（壊れていれば 1 行知らせてその欄を使わない）で読み、`Part` に `uvs2`。
- `flatShaded` で uv2 も角ごとに写す。`partMeshOf` で `Mesh3d.withUvs2` を付ける（付けられなければ 1 行知らせて uv2 無しで続ける）。
- uv2 は X の反転の影響を受けない（uv と同じく絵の上の位置なので、そのまま）。
- `fromGlb`（絵を読まない方）も `loadTextured` も uv2 を読む。全部の primitive をつないだ `model#mesh` には付けない（parts だけ）。
- texCoord が 0 でない材質の絵を読み飛ばす今の知らせは変えない（lightmap は材質から指されないので関係しない）。

**Texture3d**（色空間と変換の式の置き場所）
```
/// 8bit の絵の値の意味。Srgb = sRGB の曲線で書いた値（Blender の PNG・色の絵）・Linear = 値がそのまま量（法線マップ・数値の絵）。段階 G の G1 と同じ型。
pub enum ColorSpace with Eq, ToString { case Srgb, case Linear }
pub def srgbToLinear(s: Float64): Float64
pub def linearToSrgb(l: Float64): Float64      // 1 を超えても同じ式・負は 0
```
- 変換の定数（0.04045・12.92・0.0031308・0.055・1.055・2.4）は Flix のこの 1 か所に置き、Render3d の GLSL の字（`r3d_srgbToLinear`・`r3d_linearToSrgb`。`sg_` は ShaderGen の名前の頭なので使わない — G5 で ShaderGen が同じ名前を出すと二重の定義になる）もここの値から組む。
  CPU と GPU で定数の打ち間違いが起きない。G5 も同じ関数を使う。

**Scene3d**
```
/// 3D のベイクした光（2D の Light.lightMapPass とは別）。texture = 絵の名前（Texture3d.name。場面の textures から引く）・
/// colorSpace = 絵の値の意味・intensity = 線形の光の量に戻した後に掛ける倍率（PointLight の intensity と同じ意味。露出の stop ではない）。
pub type alias Lightmap = { texture = String, colorSpace = Texture3d.ColorSpace, intensity = Float64 }

/// colorSpace = Srgb・intensity = 1。ほかの値は { intensity = 2.0 | Scene3d.lightmap(name) } の形で替える。
pub def lightmap(texture: String): Lightmap

/// 置いた物にベイクした光を付ける（2 本目の UV で読む）。付けた物は環境光と hemisphere を足さず、動く光は足す。
pub def withLightmap(lm: Lightmap, i: Instance3d): Instance3d

/// 描く時に使う lightmap（使える時だけ Some。intensity の負・NaN は 0 に直す）。GL・CPU・鍵はこれだけを読む。
pub def lightmapOf(i: Instance3d): Option[Lightmap]

/// 付けたのに使わない理由（1 行）。理由が重なる時は 1 行だけ（材質が無い → 骨つき → uv2 が無い → tex3d: でない の順）。
pub def lightmapWarning(i: Instance3d): Option[String]
```
- `InstanceFields` に `lightmap = Option[Lightmap]`（`meshInstance` は None）。
- 名前が場面の textures に無い時は `lightmapOf` の範囲の外（lightmapOf は場面を知らない）。材質の絵と同じく **0（黒）で読む**: その物は環境光を足さず動く光だけで照らされ、
  名前ごとに 1 回知らせる（GL は `warnTextureOnce` の missing の鍵・CPU は `warnMissingMaterialTexture`。今ある知らせの道に乗せ、GL と CPU で新しい判定を書かない）。`lightmapOf` / `lightmapWarning` は既存の `skinningOf` / `skinningWarning` と同じ形。
  使うかどうかの判定（§2 の「v1 で使わない組み合わせ」）を engine の 1 か所に置き、GL と CPU で別々に書かない。全部の分岐を engine のテストで押さえる。
- `Lightmap` は閉じたレコードの alias。ゲームが `{ intensity = 2.0 | Scene3d.lightmap(n) }`（レコードの更新）で書けば、後から欄（atlas の `uvRect` など）を足しても止まらない
  （`RenderTarget.Descriptor` と同じ作法。早見表と doc の例もこの形で書く）。
- 絵の名前の一覧を 1 か所に: 場面が読む絵の名前（材質の Tex・法線マップ・lightmap）を数える所が今 3 か所ある
  （`SoftRaster.argbReadNames`・`SoftRaster.sceneTexturesOf`・`DrawHash` の絵の一覧）。
  `pub def Scene3d.textureNamesOf(i: Instance3d): List[String]`（**上限で切らずに全部**。lightmap は `lightmapOf` が Some の時だけ）を足し、
  `argbReadNames` と `DrawHash` はこれに置き換える。`sceneTexturesOf` は材質の reads にだけ今の `List.take(Scene3d.maxMaterialTextures(), ..)` と上限の知らせを残し、
  法線マップと lightmap は take の外で mip を作る組に入れる（上限を超えた絵まで mip を作らない・知らせの場所を変えない）。

### 5.2 GL（`render_gl/src/Render3d.flix`）
- 頂点: uv2 は位置・法線・色の VBO にも surface（uv とタンジェント）の VBO にも混ぜず、**別の VBO を location 7** に上げる（uv2 の無い形の頂点バッファの中身を変えない）。
  `MeshEntry` に `uv2: Option[Int32]`、`deleteMesh` で消す。
- プログラムの形: `VertexKind` に `lightmap: Bool`（`Scene3d.lightmapOf(i)` が Some の時だけ真。骨つきは lightmapOf が None なので skin と lm の組は出ない）。鍵に `+lm`。
  `materialVertexSource` は `out vec2 vUv2` を足した版（骨なし × 1 本目の uv あり / なし の 2 通り。`withUvs2` だけを付けた形に Solid の材質、の組がある）、`materialFragmentSource` の surface に `lightmap = Bool`。
- 絵の unit: **8**（`lightmapTextureUnit()`。0〜5 は材質・6 は法線マップ・7 は影の地図。GL 3.3 の frag の unit は 16 以上が約束されている）。
  名前は場面の textures（`texture3dBound`）からだけ引くので、上下の反転は無い（flip は 0 の定数）。wrap は Clamp・読み方は mip つきの Linear（`sg_texMip`・法線マップと同じ）。
  描いた後に unit 8 の sampler を外す（`releaseMaterialUnits` に lightmap の分を足す）。
- uniform は**置いた物ごとに毎回入れ直す**（同じ形・同じ材質で lightmap だけ違う物は、プログラムが同じなので並べ替えで続けて描かれる。前の物の絵と intensity を引き継がない）。
- **`sg_texMip` を 1 回だけ足す**: 今は `normalMapSource` が「functions に `vec4 sg_texMip(` が無ければ足す」を自分で決めている。
  `materialFragmentSource` の頭で「要るか（法線マップ ∨ lightmap）∧ functions に無いか」を 1 回だけ決め、**出す位置は今と同じ `glsl#functions` の直後**にする。`normalMapSource` からは判定を外す
  （法線マップだけの版の字は今と同じになる並びにする。法線マップ ＋ lightmap ＋ mip つきの Tex を読まない材質の組で、関数が 2 回出ないことをテストする）。
- frag（lightmap つきの版だけに足す）:
  ```
  uniform sampler2D uLightmap; uniform float uLightmapLevels; uniform int uLightmapSrgb; uniform float uLightmapIntensity;
  vec3 bakedLight() { vec3 s = sg_texMip(uLightmap, 0.0, uLightmapLevels, vUv2).rgb;
                      vec3 l = (uLightmapSrgb == 1 ? r3d_srgbToLinear(s) : s) * uLightmapIntensity;
                      return r3d_linearToSrgb(max(l, vec3(0.0))); }        // 段階 G で r3d_linearToSrgb を外す
  vec3 lightBakedAt(vec3 p, vec3 n, vec3 baked)   // lightAt の点光源とスポットの足し算 ＋ toon。環境光と hemisphere は足さない
  ```
  main の光の行だけ `lightBakedAt(vWorld, n, bakedLight())` に替える（n は法線マップで傾けた n'）。
- **今のプログラムの GLSL の字を変えない**: `lightAt` の点光源とスポットの足し算の行は、Flix の側で 1 つの文字列の関数（例 `dynamicLightLoops()`）にまとめ、
  `lightSource()` と `lightBakedAt` の両方がそれをつなぐ。出来上がる `lightSource()` の字は今と 1 字も違わない。`lightBakedAt` と `bakedLight` は lightmap つきの版にだけ出る。
- **mip とふちのにじみ**: Clamp は絵の端にしか効かず、UV のアイランドの間の空き（黒）は mip のレベルが上がるほど混ざり、継ぎ目が暗くなる。
  - 正の対策は書き出し側: Blender の bake の margin を広く取る（2048² で 16 px 以上・margin の型は Extend）。doc の「ベイクの時の注意」と書き出し側への頼み（D6 の隣）に書く。
  - engine の側は lightmap の mip のレベルに上限を置く: `lightmapMaxLevels()` = 4（レベル 0〜3）。決め方は「2^(上限のレベル + 1) ≦ margin」— レベル k の 1 texel は元の 2^k px で、Linear は隣の texel も読むので、margin 16 px ならレベル 3 まで。`uLightmapLevels` は min(mip のレベルの数, 4)。margin を 32 px にできれば 5。
    CPU も同じ上限で lod を切る。上限の値は L4 でアパートを歩いて確かめる。

### 5.3 CPU（`engine_tools/src/SoftRaster3d.flix`）
- 頂点の欄の末尾に uv2 を 2 つ足す（`stride` 19 → 21・`uv2Slot() = 19`）。今の欄の位置は変えない。uv2 の無い形は (0, 0)。
- `Mat` は今のまま（材質ごと）。lightmap は置いた物ごとだが、lightmap を使うのは材質のある物だけなので、`numberMaterials` が付ける材質の番号（材質のある置いた物ごとに 1 つ）を鍵にした表（絵の mip の列・colorSpace・intensity）を `renderLayer` で組む。`Tri` は触らない。
  条件は `Scene3d.lightmapOf` だけを見る。
- 画素: `evalLightBaked(lights, baked, p, n)` ＝ `evalLight` から環境光と hemisphere を抜き、`baked` を足してから toon。
  baked は `ShaderEval.sampleMipRgb`（Linear・Clamp）で uv2 を読み、`Texture3d.srgbToLinear` → × intensity → `Texture3d.linearToSrgb`。
- lod は uv2 の右隣と下隣から求める。**ShaderEval の `SurfacePoint` は触らない**: 隣の画素の重みの計算だけを `neighborWeights(tri, pixel, l0, l1)` に切り出し、
  今の `neighborPoints` と新しい `neighborUv2` の両方がそれを使う（lightmap の無い物の計算は 1 字も変わらない）。lod は `lightmapMaxLevels()` で切る。
- 先頭の光の式のコメントと、Render3d の頭のコメントに lightmap の行を足す（式を変える時は両方を直す、の決まりのまま）。

### 5.4 描き出しの鍵（`engine_tools/src/DrawHash.flix`）
- `putInstance` は `InstanceFields` を受けるので、判定の本体を `Scene3d.lightmapOfFields(f: InstanceFields)` に置き、`lightmapOf(i)` はそれを呼ぶ形にする。`putInstance` は `lightmapOfFields` が Some の時だけ 1 バイトの目印と欄を書く（None の物の鍵のバイトは今と同じ・TestDrawHash の固定値は変わらない）。
  使わない lightmap（骨つき・uv2 無し）は絵に出ないので鍵にも入れない。
- 絵の一覧は `Scene3d.textureNamesOf` から（lightmap の絵の中身の鍵も入る）。uv2 は `Mesh3d.contentHash` に入るので別に書かない。

## 6. 段階分けと工数

0.74.0 の作業（Render3d の `putJoints`・ShaderDoc の比較・Mesh3d と Gltf の書き方の直し）が main に入ってから始める。
L1 は 0.74.0 の Mesh3d / Gltf の直し（`rowsOf`・新しいハッシュ）の上に書くので、先に始めると必ず当たる。

| 段階 | 中身 | 工数 | 終わりの確かめ |
|---|---|---|---|
| L0 | 今の GLSL の字（`lightSource()`・材質の frag の 4 通り）と gl-parity の B 段階の差の数を固定値として控える。`Scene3d.textureNamesOf` を足し、置き換える（絵は変わらない） | 0.5 日 | `make test-engine_tools`・gl-parity が今と同じ |
| L1 | Mesh3d の uv2（鍵・withBoxUvs）・Gltf の TEXCOORD_1 | 1 日 | engine の Mesh3d・Gltf のテスト |
| L2 | `Texture3d.ColorSpace` と変換の式・Scene3d の `Lightmap`・`withLightmap`・`lightmapOf`・`lightmapWarning`・Render3d（location 7・unit 8・frag・sg_texMip の 1 回化） | 2 日 | GLSL の字のテスト・テンプレートの reference |
| L3 | SoftRaster3d（neighborWeights・置いた物ごとの表）・DrawHash・gl-parity の新しい 2 行 | 1.5 日 | `make gl-parity`（既存の行が今と同じ・新しい行が上限の中） |
| L4 | 前提: 絵の上限を片づける（D7）。アパートの主な 3 本を lightmap つきで出す（ゲーム側。engine には入れない）・文書・早見表・お題・移行メモ | 1.5 日 | 実機で歩く・`make agent-eval ONLY=lightmap-baked` |
| L5（任意） | HDR の lightmap（下の形） | 2〜3 日 | 論点 D3 で決める |

計 6.5 日（L5 と D7 の作業を除く）。L2 の後と L3 の後にレビュー役を立てる。

### L5（任意）: HDR の lightmap
- 形: `Lightmap` の `texture` の引き先に HDR の絵を足す（`Scene3dCmd` に `hdrTextures`、または `Texture3d` に float の case を足す — どちらにするかは L5 の時に決める）。
  GL は `GL_RGBA16F`、CPU は `ShaderEval.HdrTexture`（half に丸める・段階 F の Pass と同じ持ち方）。
- 読む形式: Blender の EXR（圧縮無しと ZIP。ZIP は `java.util.zip.Inflater` で戻せる）。PIZ・DWA は読まず Err。外部のライブラリは入れない。
- 重さ: 2048² の half の RGBA は 32 MB（mip 込み 43 MB）。CPU の HdrTexture は Float64 の Vector なら 1 枚 130 MB になるので、Float32 で持つ形が要る。
- 代わりの案: 書き出しで RGBM（8bit の PNG の α に倍率）にする。読むのは安いが、Blender の側に書き出しの手間が増える。

## 7. テスト

**1 bit も変わらない（合格線の柱）**
- make gl-parity: A 段階の全部の行がバイト一致・B 段階の行の差の画素数が L0 で控えた数と同じ。
- テンプレートの reference（`templates/*/reference/SHA256SUMS.txt`）が一致。
- `Render3d.materialFragmentSource(glsl, { uv, normalMap, lightmap = false })` の字が、L0 で控えた今の字と同じ（uv・法線マップの 4 通り）。`lightSource()` の字も同じ。
  （今の render_gl のテストには比べる元が無いので、L0 で今の字を固定値のファイルとして取っておく。）
- TestDrawHash の固定値が変わらない。uv2 の無い Mesh3d の `contentHash` が今と同じ。

**engine（`make test-engine`）**
- Mesh3d: `withUvs2` の数の食い違い・NaN は Err／uv2 で鍵が変わる／`withUvs` と `withUvs2` の順を替えても同じ鍵／`withBoxUvs` で頂点を分けた後も uv2 が元の頂点の値。
- Gltf（テストの中で組む小さな glb。`TestGltf.triangleWithUvsGlb` と同じ作り）: `TEXCOORD_1` の値がそのまま `uvs2` に入る（X の反転を受けない）／
  NORMAL の無い glb（`flatShaded` を通る）でも uv2 が角ごとに写る／`TEXCOORD_1` の数が頂点の数と違うと uv2 無しで読める／`TEXCOORD_1` の無い glb は `uvs2` が None。
- Texture3d: `srgbToLinear` の 0・1・0.5（→ 0.2140）・0.04045 の境／`linearToSrgb(srgbToLinear(k/255))` が 256 通りの k で k/255 に戻る／1 を超える値も続いた式で返る・負は 0。
  Blender の PNG（`sRGB`・`gAMA`・`cHRM` の chunk つき）を `Texture3d.decode`（ImageIO）が chunk を掛けずに生の値で返すこと（アパートの lightmap の PNG と同じ chunk を持つ 4 × 4 の小さな PNG を資材に置く）。
- Scene3d: `lightmap(name)` の既定（Srgb・1）／`lightmapOf` の分岐（使える・材質が無い・骨つき・uv2 が無い・`tex3d:` でない）／intensity の負と NaN が 0 に直る／
  `lightmapWarning` が理由の重なりで 1 行だけ返す。

**engine_tools（`make sync-layers` → `.layers/engine_tools` で `flix test`）**
- 同じ点・同じ光で、lightmap を付けた物は環境光（白）と hemisphere を足さない（ベイクした光が 0 なら、動く光の無い画素は黒）。
- 点光源 1 本を足すと、その分だけ明るくなる（ベイクした光 ＋ 動く光）。
- `Srgb`・`intensity = 1` の baked が読んだ値 s と同じ（式の性質）。`Srgb`・s = 0.5・`intensity = 2.0` の baked が `linearToSrgb(0.2140 × 2)` ≒ 0.686。
- 骨つき・uv2 の無い形・材質の無い物は、今の式で描き 1 回だけ知らせる。名前が場面の textures に無い絵は 0（黒）で読み（環境光は足さず動く光だけ）、名前ごとに 1 回知らせる。
- 期待値は式から導く（`/quality-assurance` の決まり。描いた絵を正解として貼らない）。

**render_gl（GLSL の字）**
- 法線マップ ＋ lightmap ＋ mip つきの Tex を読まない材質（Solid）の frag で、`vec4 sg_texMip(` が 1 回だけ出る。

**gl-parity の新しい行（B 段階）**
- `lightmapBaked3d`: 正面を向いた 2 枚の板。**左右は同じ形・同じ材質**（`texturedMaterial`）で、lightmap の絵と intensity だけを替える（uniform の入れ直しの漏れが絵に出る）。
  lightmap は 8 × 8 の市松（明 200・暗 40・Srgb）を `Texture3d.fromArgb` で作る。右の板にだけ点光源 1 本。環境光は白（足されないことが絵に出る）。
- `lightmapNormal3d`: 既存の `normalBump` と同じ形を lightmap つきで。動く光にだけ凹凸が出る。
- 上限: 市松を Linear で引き伸ばすと、明暗の境のグラデーションで ±1 の丸めが出うるので、**L3 で 1 回流してふちと境の画素の数から決める**（目安は mip の 3 行と同じ 800 px 以下。
  式を取り違えると板の中が丸ごと違って桁が変わる）。

## 8. 文書・早見表・お題・forbid・移行メモ

- **早見表**（`agents-pack/AGENTS.core.md`）の 1 行:
  `| Blender でベイクした光（lightmap と 2 本目の UV）を 3D の部屋に貼る | glb は Gltf.loadTextured（TEXCOORD_1 → part の uvs2）→ lightmap の PNG は Texture3d.decode で場面の textures へ → Scene3d.meshInstance(..) |> Scene3d.withLightmap({ intensity = .. | Scene3d.lightmap(Texture3d.name(t)) })（光を材質の絵に混ぜ込まない・ベイクに入れた光は pointLights に入れない・骨つきには付かない） |`
- **agent-eval のお題**（`agents-pack/agent-eval/engine.json`）`lightmap-baked`:
  - prompt: 「Blender で部屋の光と影を計算して絵に書き出した（2 本目の UV つきの glb と、光の PNG）。この部屋を 3D の場面で表示し、懐中電灯の光も足したい」
  - expect: `withLightmap` ／ `Scene3d\.lightmap\(` ／ `SpotLight|spotLights`（早見表どおりの答えはゲームのコードに uvs2 も TEXCOORD_1 も書かないので、expect に入れない）
  - avoid: `Field\.Tex\(\s*\{\s*name\s*=[^}]*[Ll]ightmap`（材質の木で lightmap を掛ける形）
- **forbid.json の候補**（入れるかは L4 で決める）: ゲームの .flix の `Field\.Tex\(\s*\{\s*name\s*=[^}]*[Ll]ightmap` → hint「`Scene3d.withLightmap`（2 本目の UV で読み、環境光の二重を止める）」。
  名前に lightmap を含まない書き方は拾えないので、弱い候補。
- **doc**: `docs/modules/engine.md` の 3D（Scene3d・Gltf）の節に lightmap の節（§4 の色空間・§3.3 の露出の置き場所・ベイクの時の注意: Blender の UV マップの 2 本目を lightmap 用にし、
  glTF の書き出しで UV を全部出す・bake の margin を広く取る・ベイクした光源は pointLights に入れない・lightmap の PNG は sRGB）。`docs/api-digest` は生成物なので `make api-digest` で作り直す。
- **移行メモ**（0.75.0 になる見込み・`docs/migrations/0.75.0.md`）:
  - `Scene3d.InstanceFields` に `lightmap` が増えた（`instanceFieldsOf` で読んでいるだけなら止まらない。レコードの形で開いて match している所は欄を足す）。
  - `TEXCOORD_1` を持つ glb の part の `Mesh3d.contentHash` が変わる（絵は変わらない。鍵を固定値で比べているテストだけ直す）。
  - `Render3d.materialFragmentSource` の surface に `lightmap` が増えた（GLSL の字を比べるテストだけ）。`Render3d.MeshEntry` に `uv2` が増えた（今の使い手は Render3d の中だけ）。
  - 段階 G の時の予告: `Lightmap.colorSpace` は `Texture3d` の側へ移る・ベイクした光の露出は `intensity` から exposureStops へ戻す。

## 9. 0.74.0 の作業と当たらないための決まり

- 実装は 0.74.0 のリリースの後に main から切る。計画書だけを今置く（コードは触らない）。
- 当たりうる所と順番:
  - Mesh3d・Gltf: 0.74.0 の I0（`rowsOf`・`gather`・ByteBuffer の SHA）の上に書く。uv2 の写しもその関数で書く。
  - Render3d: 0.74.0 は `putJoints`（骨の行列の UBO・SkinnedPrograms を取る形）を直す。この計画は `uploadMesh`・`materialVertexSource`・`materialFragmentSource`・
    `normalMapSource`・`bindNormalMap` の隣・`releaseMaterialUnits` を触る。lightmap は骨つきに付かないので、骨つきのプログラムの道には入らない。
    `jointsBinding()` の UBO の binding と、テクスチャの unit 8 は別の番号の空間なので当たらない。
  - ShaderGen・ShaderDoc・ShaderEval: 触らない（0.74.0 の ShaderDoc の比べの直しと当たらない。CPU の隣の画素も ShaderEval の型に手を入れない・§5.3）。
  - `plans/engine-asset-import.md` の `.fgetex`（取り込みのキャッシュ）: lightmap の PNG も同じ `Texture3d` なので、I8（登録の絵）より前は取り込みに通らない。lightmap を取り込みに通すかは I8 の時に決める。
    最大サイズ（I1）は D7 で使う。

## 10. 人に決めてほしいこと（おすすめ付き）

- **D1. lightmap をどこに付けるか** — おすすめ: **置いた物（`Scene3d.withLightmap(lm, instance)`）**。Unity・Godot・Bevy と同じで、
  同じ glb を 2 か所に置いた時に材質を作り直さずに済む。代わりの案は依頼の文面どおり材質（`Material3d`）に付ける形（材質のプログラムの鍵と中身が食い違いやすい）。
- **D2. 段階 G の前の色の扱い** — おすすめ: **`Lightmap` は線形の光として受け取り、G の前は sRGB の区分の式の逆で画面の値へ戻してから足す**（§4）。
  G の後に直すのは露出の置き場所（§3.3）と、`colorSpace` を書いた所だけ（§4）。代わりの案は「今は読んだ値をそのまま掛ける」
  （`intensity = 1` なら今の案と同じ絵だが、intensity が線形の倍率にならず、G の時に全部の lightmap の intensity を合わせ直すことになる）。
- **D3. HDR の lightmap（EXR）を v1 に入れるか** — おすすめ: **入れない（L5 として後に回す）**。PNG で切れるのは site_props の約 1% 未満・灯りのすぐそばだけ。
  暗い所のグラデーションのバンディングが実機で見えたら L5 に進む（または書き出しを RGBM にする）。
- **D4. 材質の無い置いた物（頂点の色の物）に lightmap を使うか** — おすすめ: **v1 は使わない（1 回知らせる）**。アパートの部品は全部絵つきの材質。
  頂点の色のプログラムにも lightmap の版を足すと、プログラムの形が 2 倍になる。骨つきも同じく使わない（§2）。
- **D5. 名前** — おすすめ: 型 `Lightmap`・関数 `withLightmap` / `lightmapOf`・明るさ `intensity`・色空間 `colorSpace`（`Texture3d.ColorSpace`）・UV `uvs2`（§3.2・§5.1）。
  Bevy の `lightmap_exposure` にはそろえない（このエンジンの exposure は stop の数）。
- **D6. 書き出し側への頼み**（アパートの書き出しの作業へ）— おすすめ: **EXR を線形で書き直し、manifest の「half-float」も実際の形式（float32・圧縮無し、または half・ZIP）に合わせてもらう。
  あわせて bake の margin を 2048² で 16 px 以上（Extend）にしてもらう**。v1 は PNG しか読まないので EXR は急がないが、margin は v1 の継ぎ目に出る。
- **D7. 場面の絵の上限をどう片づけるか**（L4 の前提）— おすすめ: **`plans/engine-asset-import.md` の最大サイズ（I1）で、まず lightmap と法線マップを 1024 に縮める**（lightmap はなめらかなので目立たない）。
  base color は縮めると site_ground で 32 → 16 px/m（1 texel 約 6 cm）になり一人称の足元がぼけるので、上限の見直しと天秤にかける。代わりの案は `texture3dByteBudget` を 512 MB に上げる（VRAM の少ない機械で重くなる）。
  どちらも、`loadTextured` が使わない metallicRoughness の絵を decode しない直し（小さな別の作業）と組にする。
