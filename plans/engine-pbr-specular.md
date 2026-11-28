# 金属っぽさと粗さ（鏡面ハイライトと空の映り込み）— 計画

## なぜ

今の 3D の光は拡散光だけ（環境光＋空からの光＋点光源とスポットの拡散。`LightModel3d.lightingModel`）。
鏡面ハイライトと周りの映り込みが無いので、金属・磨いた石・濡れた床・樹脂の違いが出ない。
glb（Blender・Tripo などの生成 AI の書き出し）の `pbrMetallicRoughness` も読み飛ばしていて、どの材質もマットに見える。
Unity（Standard / URP Lit）・Unreal・Godot（StandardMaterial3D）はどれも metallic と roughness の 2 つの値で材質を決める。同じ 2 つの値をこのエンジンにも持たせる。

人の判断（2026-11-11）: 案「鏡面ハイライト＋空の映り込み」で進める。キューブマップの映り込み（IBL）はやらない。
見本の場面は `~/Documents/flix_ge_workspace/pbr_room`（白い部屋・球 2 列×5 個・クロムの球・銃）。before の写真は `debug/pbr/before/` にある。

## ゲームから見た形

```flix
// コードで作る材質
let gold = Scene3d.colorMaterial(...) |> Scene3d.withMetallicRoughness(1.0, 0.25)

// glb の材質は、metallicFactor・roughnessFactor・metallicRoughnessTexture を読んで自動で付く（glTF の決まりどおり）
// 付けたくない材質は外す
let matte = Scene3d.withoutMetallicRoughness(mat)
```

- 名前は glTF と Godot にそろえる（metallic・roughness）。値は 0..1 に丸める。
- **metallicRoughness を持たない材質は、今と 1 bit も違わない絵**（GL のプログラムも今と同じ物）。既存のゲームのコードの材質はこれ。
- glb は既定で読む（Godot・Unity と同じ）。決め方:
  - 材質に `pbrMetallicRoughness` が無い → metallicRoughness 無し（今の絵のまま）。glTF の決まりでは metallic 1 になるが、色だけの古い glb が全部金属に見えるのを避ける
  - `pbrMetallicRoughness` があり、`metallicFactor` か `roughnessFactor` か `metallicRoughnessTexture` のどれかが書いてある → 付ける。
    書いていない値は glTF の既定（metallic 1・roughness 1）。Blender は metallic 1.0 の時に `metallicFactor` を書かないので、この扱いで合う
  - `pbrMetallicRoughness` があっても上の 3 つがどれも無い（baseColor だけ）→ metallicRoughness 無し
- 名前の最終決定は実装者に任せるが、上の 2 つ（付ける・外す）より増やさない。値を読む口が要るなら `Scene3d.metallicRoughnessOf(mat): Option[...]`。

## 光の式（`LightModel3d` の木に書く。GL と CPU で 1 回だけ）

業界の標準の形（Unreal の「Real Shading in UE4」・Godot の既定）に合わせる:

- 拡散: 今の light をそのまま使い、色に掛ける所で `albedo × (1 − metallic)` にする
- 鏡面（点光源・スポットごと）: GGX の分布 D・Smith（Schlick-GGX）の G・Schlick の Fresnel F。
  `spec = D × G × F / (4 × n·l × n·v)` に `光の色 × intensity × att × n·l`（スポットは cone と shadowLit も）を掛ける。
  F0 = mix(0.04, albedo, metallic)。roughness は二乗して α に（α は 0.002 より小さくしない）。
- 空の映り込み: 跳ね返りの向き r = reflect(−v, n) の空の色（今の `skyModel` をそのまま使う）と、空の平均の色（zenith・horizon・ground の平均）を
  roughness で混ぜた色に、roughness 込みの Fresnel（`F0 + (max(1 − roughness, F0) − F0) × (1 − n·v)^5`）を掛けて足す。
  場面に空が無い時は、ambient ＋ hemisphere の色を映り込みの色にする（真っ黒にしない）。
- 足す順: `色 = albedo × (1 − metallic) × light + Σ 鏡面 + 映り込み`、その後に今どおりかすみ → emission。
- lightmap つきの面も鏡面と映り込みは同じに足す（ベイクした光は拡散の側）。
- toon（段付け）は拡散の light だけに掛け、鏡面は段付けしない（決めた事として doc に書く）。
- 木の外にある「光を色に掛ける所」を木の中へ寄せる必要があれば寄せてよい（GL と CPU の 2 か所に式を書かないための変更は歓迎）。

## glb

- `Gltf.loadTexturedUsing` が `pbrMetallicRoughness.metallicFactor`・`roughnessFactor`・`metallicRoughnessTexture`（B = metallic・G = roughness。
  glTF の決まり）を読む。絵は今の baseColor と同じ読み方・同じ上限の仕組み（`Gltf.TextureLimits` に欄を足すなら、追随メモの非互換に載る）。
- 絵が読めない時（texCoord ≠ 0 など）は今の emissive と同じく、値だけにして材質ごとに 1 行知らせる。
- `part#gltfMaterial` に metallic・roughness も載せる。

## 決まりと門

- **既存の絵は変えない**: metallicRoughness を持たない材質の絵が 1 bit も変わらないこと。`make gl-parity` の既存の全場面が 0 px のまま。
  `templates/*` の reference も変わらないこと（`make reference-check`）。
- GL と CPU（SoftRaster3d）が同じ絵: `bench/gl_parity` に、球を metallic × roughness で並べた場面と、空ありと空なしの対を足す。
  式の行（`ExprRows`）に鏡面と映り込みの行を足し、今の `exprLight` と同じ上限（1e-5）で一致させる。
- 重さ: metallicRoughness を持つ材質だけが新しい式のプログラムを使う。持たない材質の GLSL は今と同じ字。
  `bench/scene3d` か箱庭（`~/Documents/flix_ge_workspace/lamplighter`）で 1 コマの時間を前後で出す（箱庭は glb の Blender の材質が metallic 0・roughness 0.5 を書くので、
  既定で読むと鏡面が付き、絵と時間が変わる。その差を報告する）。
- テスト: engine・engine_world・render_gl・engine_tools の当たるパッケージ。値の丸め・glb の既定値の扱い・付ける／外すで材質の鍵が変わる・持たない材質の鍵が今と同じ。
- 文書: `docs/scene3d.md` に節を 1 つ（付け方・glb の読み方・式・toon との関係）、`docs/modules/` の逆引きに 1 行、`make api-digest`、
  `agents-pack/AGENTS.core.md` の早見表に 1 行・`agents-pack/agent-eval/engine.json` にお題 1 本。
- コメントは WhyNot。経緯は書かない。コミット・push・版上げ・リリースはしない。

## やらない事

- キューブマップ・反射プローブ・IBL の前計算・スクリーン空間の反射
- 異方性・クリアコート・シーン（布の光沢）・透過
- ambient occlusion の絵（glTF の occlusionTexture）

## 報告に書く事

- 足した pub・触ったファイル・式を木の中へ寄せたか（寄せた範囲）
- テストの本数と結果・`make gl-parity`・`make reference-check`・`make sync-engine-full`
- 箱庭と bench の 1 コマの時間の前後
- 迷って決めた所（toon・空なしの映り込み・glb の既定値）
