# 段 G: 色の線形化（rev0・下書き）

段 F（`plans/engine-round7-hdr.md`）が入ってから詰める。この下書きは範囲と論点の置き場で、レビューは段 F の実装の後に回す。

## ねらい

今は画像の画素の値（sRGB のガンマの値）のまま光を足し掛けしている。0.5 と書かれた画素の実際の光の量は約 0.21 で、
光の落ち方・重なり・影の境が硬く、重なった所が急に白くなる（fps3d_lab の礼拝堂で「円形の光源の重なりが不自然」の一因）。
テクスチャを読む時に線形へ戻し、計算は実際の光の量で行い、画面へ出す時に 1 回だけ sRGB へ戻す。光の式そのものは変えない。

## 決めたいこと（論点）

### G1. テクスチャの色の空間
- `Texture3d` に色の空間を持たせる: `pub enum ColorSpace { case Srgb, case Linear }`（wgpu の `Rgba8UnormSrgb` / `Rgba8Unorm` の分け方）。
  色の絵（base color・emission の絵）は Srgb、法線マップ・lightmap の外の数値の絵（粗さ・AO を数値で持つ物）は Linear。
- 既定をどちらにするか: `Scene3d.texturedMaterial` で付けた絵は Srgb、`withNormalMap` の絵は Linear と、付ける口で決める案（使い手が考えなくて済む）。
- GL: Srgb は `GL_SRGB8_ALPHA8` で上げ、読む時に GPU が線形へ戻す。mip も同じ形式。
- glTF: baseColorTexture は Srgb・normalTexture は Linear（glTF 2.0 の決まり）。baseColorFactor は glTF の決まりで線形の値（今は sRGB の値として頂点の色に掛けている — AO の試作で「本の色が褪せる」として見えた）。

### G2. mip の平均を線形で
- `Mip.build` の 2×2 の平均を、Srgb の絵では線形へ戻してから取り、sRGB へ戻して持つ。細かい模様が遠くで暗く沈むのが直る。
- 段 E の申し送り（線形の mip の平均）をここで片づける。

### G3. 画面へ出す時に sRGB へ戻す
- 段 F の `RenderTarget.Format` に `Rgba8UnormSrgb` を足す。書く時に GPU が線形 → sRGB に直し、読む時に線形へ戻す。
- 3D の場面を描く Pass を Rgba16Float（線形のまま持つ）にし、最後のトーンマップの面が sRGB へ戻して画面へ出す。
  `GL_FRAMEBUFFER_SRGB` を既定の画面で使うか、トーンマップの面の式の最後で `pow(1/2.2)`（正確には sRGB の区分の式）を掛けるか。
  ShaderDoc には定数の `Pow` があるので、`PostProcess.toSrgb(x)` を足せば木で書ける（CPU と GPU の一致の心配が少ない）。

### G4. 2D の扱い
- 2D の sprite・UI・ShaderDoc の面は今の見た目のまま（ガンマの値で混ぜる）にするのが既定。全部のゲームとテンプレートの 2D の絵を変えない。
- 線形で扱うのは、3D の場面と、それを読む後処理の Pass だけ。2D と 3D が同じ Pass に混ざる時の決まり（3D の場面の Pass は線形・2D の Pass はガンマ）を doc に書く。
- これで「段 G で変わるのは 3D を使うゲームだけ」になる（今の使い手は fps3d_lab と dungeon3d_lab・hd2d_lab）。

### G5. CPU の描き出しと parity
- SoftRaster3d の絵の読み（ShaderEval の tex の 3D 版・MipTex）に同じ sRGB → 線形を入れる。GL の sRGB のテクスチャの変換は 8bit の表引きなので、CPU も同じ 256 段の表で行う（bit の一致に近づける）。
- gl-parity: Srgb の絵の 3D・mip の平均・Rgba8UnormSrgb の Pass の 3 行。

### G6. 合わせ直し
- 3D の光の値（LookDoc の torch / brazier / lantern / ambient・spot の intensity・emission）は線形の目盛りで合わせ直す。fps3d_lab の look.json 4 本と RoomView の定数。
- 移行メモ（0.74.0 になる見込み）: 3D の明るさが変わる・光の値の合わせ直しの目安。

## テスト（案）
- sRGB ↔ 線形の表（0・1・0.5 → 0.214）・往復。
- Mip の平均が線形（白と黒の市松の 1 段上が 0.5 の灰ではなく約 0.735）。
- Texture3d の色の空間の既定（付ける口ごと）。
- glTF の baseColorTexture / normalTexture の色の空間。

## 段取り（案）
1. G1 + G2（絵の色の空間・mip）→ 2. G3（Pass の形式・最後の変換）→ 3. G5（CPU・parity）→ 4. G6（fps3d_lab の合わせ直し）→ 5. 文書
