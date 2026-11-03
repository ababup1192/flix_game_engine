# lightmap — Blender でベイクした光を 3D の部屋に貼る

lightmap ＝ 動かない物に当たる光（直接光と間接光）を前もって計算して絵にした物。柔らかい影・隅の暗がり・光の回り込みが、実行中の重さほぼ 0 で出る。
2D の `Light.lightMapPass`（2D の光を Pass に積む物）とは別。

## 使い方

```flix
let model = Gltf.loadTexturedWith({ normal = 1024 | Gltf.noTextureLimits() }, "assets/room.glb");   // TEXCOORD_1 → part の uvs2
let lightmap = Texture3d.decode(bytesOf("assets/room_lightmap.png")) |> Result.map(Texture3d.limitSize(1024));
// 場面の textures に model#textures と lightmap の絵を入れ、置いた物に付ける:
Scene3d.meshInstance(part#mesh, world)
    |> Scene3d.withMaterial(material)
    |> Scene3d.withLightmap({ intensity = 2.0 | Scene3d.lightmap(Texture3d.name(lm)) })
```

- 付けた物は、環境光と hemisphere を足さず、ベイクした光に動く光（点光源・スポット・スポットの影）を足す。法線マップは動く光にだけ効く。
- **ベイクに入れた光は pointLights に入れない**（同じ光で二重に照らす）。場面に足すのは動く光だけ: 懐中電灯は `spotLights` の `SpotLight`（向きと円錐を持つ）、揺れる灯りは `pointLights`。
- 使われない組み合わせ（置いた物ごとに 1 回知らせて、今の光で描く）: 材質の無い物（`Scene3d.material` で包む）・骨つき・2 本目の uv の無い形・名前が場面の textures の絵（`tex3d:`）でない物。理由は `Scene3d.lightmapWarning`。
- `Scene3d.Lightmap` は欄が増えうるので、`{ intensity = .. | Scene3d.lightmap(name) }` のレコードの更新で書く。

## 色空間と明るさ

- `Lightmap` は**線形の光の量**として受け取る（Blender・Unity・Bevy と同じ）。`colorSpace` は 8bit の絵の読み方だけを指す: `Srgb`（既定・Blender の PNG）は sRGB の区分の式で線形へ戻し、`Linear` はそのまま。
- `intensity` は線形に戻した後に掛ける倍率（`PointLight` の intensity と同じ意味。`PostProcess` の露出の stop の数ではない）。
- 今のエンジンは光の計算をガンマのままの値（画像の画素の値）で行うので、ベイクした光は sRGB の区分の式の逆で画面の値へ戻してから動く光と足す（暗い所が沈まない）。`Srgb`・`intensity = 1` なら読んだ値がそのまま光になる。
- 露出の置き場所: 書き出しの「lightmap × 0.5 を sRGB で書いた PNG（読んだ後に 2 を掛ける）」と「exposure 2^0.6」は、両方とも `intensity` に入れる（2.0 × 2^0.6 ≒ 3.03）。
  `PostProcess.tonemappedWith` の exposureStops へ 0.6 をそのまま写すと、ガンマのままの値に掛かって明るすぎる（写すなら 0.6 / 2.2 ≒ 0.27 が目安）。
  色の線形化（段階 G）が入ったら、露出は exposureStops へ戻し、`intensity` は 2.0 にする（移行メモで知らせる）。

## ベイクの時の注意（Blender）

- UV マップの 2 本目を lightmap 用にし、glTF の書き出しで UV を全部出す（`TEXCOORD_1` になる）。
- bake の margin を広く取る（2048² で 16 px 以上・margin の型は Extend）。mip のレベルが上がると、UV のアイランドの間の空き（黒）が混ざって継ぎ目が暗くなる。
  エンジンは lightmap の mip を既定で 4 レベル（0〜3）までしか読まない（2^(上限のレベル + 1) ≦ UV の島の間の px）。
  島の間が狭い lightmap（島が数千ある小物の部品で 7 px など）は、`{ maxLevels = Scene3d.lightmapLevelsForGap(7) | Scene3d.lightmap(name) }` で読むレベルを減らす（7 px で 2）。
  `Texture3d.limitSize` で lightmap を半分にしたら、島の間も半分になる（2048 で 16 px なら 1024 で 8 px → 3）。
- lightmap の PNG は sRGB で書く（Blender の既定）。

## 場面の絵の予算

場面の絵（Texture3d）は GPU に持つ量に上限がある（既定 256 MB・64 枚）。超えると今と前のコマで使っていない古い絵から捨て、次に要る時に上げ直す（知らせが 1 回出る）。
2048² の RGBA8 の絵は mip 込みで 1 枚約 21 MB で、12 枚で 256 MB に届く。

- `Gltf.loadTextured` は描くのに使う絵（baseColorTexture・normalTexture）だけを読む（metallicRoughness・occlusion・emissive は読まない）。
- `Gltf.loadTexturedWith(limits, path)` で、材質の絵の長い辺に上限を掛ける（mip を作るのと同じ縮め方で半分にしていく）。lightmap の PNG は `Texture3d.limitSize`。
  lightmap はなめらかなので 1024 に縮めても目立ちにくい。法線マップも近くで見ない物は 1024 で足りる。
- それでも足りない時は、project.json の `scene3dTextureBudgetMB` で上限を上げる（例 512）。VRAM の少ない機械では重くなる。
- 小さな絵がたくさんある場面（部品ごとの絵・lightmap を物ごとに分けた場面）で枚数の 64 に先に届くなら、project.json の `scene3dTextureBudgetCount` で枚数の上限を上げる（例 128。texture unit の数ではなく、GPU に持っておく絵の枚数）。
