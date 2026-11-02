# engine/test/data

テストの資材（生成した絵ではない・小さいので git に入れる）。

| ファイル | 作り方 | 中身 |
|---|---|---|
| `two_joints.glb` | Blender 5.2.2 LTS で `blender -b --factory-startup --python two_joints.py` | ジョイント 3 本（root・tip・Blender の −X に置いた side.R）・三角 2 枚の板（縦 1 m）・クリップ `bend`（1 秒で tip を 90 度倒す） |
| `textured_two_materials.glb` | Blender 5.2.2 LTS で `blender -b --factory-startup --python textured_two_materials.py` | 材質スロット 2 つの板 2 枚（A = 4 × 4 の絵・左上が赤・Closest と (128, 255, 128) の法線マップ scale 0.5・B = baseColorFactor だけ）・uv と TANGENT つき |
