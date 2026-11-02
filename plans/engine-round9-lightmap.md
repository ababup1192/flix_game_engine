# 段 H: ベイクしたライティングの口（lightmap）（rev0・下書き）

段 G（`plans/engine-round8-linear-color.md`）の後に詰める。lightmap の値を最初から線形で扱うため。
この下書きは範囲と論点の置き場で、レビューは段 G の後に回す。

## ねらい

動かない部屋と家具の光と影を Blender で時間をかけて計算して 1 枚の絵（lightmap）にベイク、ゲームはそれを貼るだけにする。
柔らかい影・隅の暗がり・光の回り込みが、実行中の重さほぼ 0 で手に入る（インディーの 3D の多くが取るやり方）。
今の家具の AO の試作（`fps3d_lab/modeling/bake_ao.py`）は UV が 1 本しか無いので、木目の絵へ AO をベイク込んで 1 枚に詰め直した。
そのため木目がぼやけ、動く光とも二重になる。UV の 2 本目と lightmap の口があれば両方を細かいまま持てる。

## 決めたいこと（論点）

### H1. UV の 2 本目
- `Mesh3d` に `uvs2 = Option[Vector[Float64]]`。`Mesh3d.withUvs2` と、Mesh3d の箱・面の組み立ての口はそのまま（2 本目は無し）。
- glTF: `TEXCOORD_1` を読む（今は TEXCOORD_0 だけ・texCoord が 0 でない絵は読み飛ばして知らせている）。
- Unity の「UV2 = lightmap UV」・Godot の `UV2` と同じ役。

### H2. 材質の lightmap
- `Material3d.withLightmap(lightmap: Lightmap, m)`。`Lightmap = { texture = Texture3d, intensity = Float64 }`（Texture3d は段 G の色の空間で HDR を持てるか — 8bit の sRGB で足りるか、RGBM などで明るい所を持つかを決める）。
- 色 = テクスチャ（UV 1）× lightmap（UV 2）× intensity + 動く光（今の点光源・スポット）+ emission。
- 二重に光らない決まり: lightmap を持つ材質は、環境光と hemisphere を足さない（ベイクした光に入っている）。動く光は足す。
  ベイクした光源（壁の松明の平均の明るさ）と、実行中の松明の揺らぎを分ける方法: 実行中の松明は「揺らぎの分だけ」足す（intensity × 揺らぎ − 平均）か、ベイクする時に松明を弱めにベイクして実行中にも足すか。
- lightmap の無い材質（人・扉・動く物）は今のまま。動く物の接地感は SSAO（後の段）で補う。

### H3. Shader の材質（ShaderDoc の spec）との関係
- `Field` に lightmap を読む口（`Field.Lightmap(chan)`）を足すか、材質の固定の掛け算だけにするか。まずは固定の掛け算（spec の色 × lightmap）にし、ShaderDoc は触らない案を勧める。

### H4. CPU の描き出しと parity
- SoftRaster3d の頂点の補間に uv2 を足し、同じ式で掛ける。
- gl-parity: lightmap の 1 行（市松の lightmap を貼った床と、動く光 1 つ）。

### H5. 作る流れ（ゲーム側）
- 今の fps3d_lab の部屋の床と壁は Flix のコード（`Res.flix`）で組んでいる。ベイクするには次のどちらかを選ぶ:
  - A. 部屋の形を JSON か OBJ で書き出し、Blender で読み込んでベイク、lightmap の PNG と UV2 を返す（形はゲームが正のまま）。
  - B. 部屋の床と壁も Blender で組み、glb にする（家具と同じ流れ。形の正は Blender）。
  - 家具は既に Blender なので、`bake_ao.py` を「UV2 を作り、部屋に置いた状態で光をベイクする」形へ広げる。ベイクする時は Cycles と AI のノイズ取り（OpenImageDenoise）でサンプルを減らす。
- 部屋に置いた家具は、部屋ごとにベイクする（家具の glb は共有しているので、ベイクした lightmap は置き場所ごとの別の絵になる）。

## テスト（案）
- uvs2 の往復・glTF の TEXCOORD_1。
- lightmap を持つ材質で環境光が足されない。動く光は足される。
- CPU と GPU の parity の 1 行。

## 段取り（案）
1. H1（UV2・glTF）→ 2. H2（材質・GL・CPU）→ 3. H4（parity）→ 4. H5（fps3d_lab の部屋をベイクする流れ）→ 5. 文書
