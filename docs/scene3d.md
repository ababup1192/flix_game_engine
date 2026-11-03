# 3D の場面（Scene3d）の口の案内

3D の部屋や物を 1 つの描き物（`Render.scene3d`）にまとめる時に、どの口を使うかを引く所。型と引数は `make api Q=<名前>`、
座標の約束（左手系・表の面は時計回り）と光の式は `engine/src/scene3d/Scene3d.flix` と `engine_tools/src/SoftRaster3d.flix` の頭の doc。
Blender でベイクした光は [lightmap.md](lightmap.md)。

GL（窓）と CPU（画面なしの描き出し・テスト・agent-eval）の 2 つの描き手が、同じ場面を同じ式で描く。

## 動く光

### スポットライト（懐中電灯）

```flix
let flashlight = { color = Color.rgb(1.0, 0.95, 0.85), intensity = 3.0, range = 12.0, innerFovY = Some(0.35)
                   | Scene3d.spotLight(eye, Vec3.add(eye, forward), 0.9) };
{ spotLights = flashlight :: Nil | scene }
```

- `fovY` = 円錐の全体の角（ラジアン）。`innerFovY` = 縁で暗くなり始める角（全体の角）。その内側は縁による減りが無く、`fovY` まで暗くなる
  （Unity の Inner Spot Angle・Bevy の `inner_angle`）。小さくするほど輪の縁が広くぼける
- `innerFovY = None` は `fovY × Scene3d.spotInnerRatio()`（0.8）。`fovY` より大きい値は `fovY` に、負と NaN は 0 に直る（`Scene3d.spotConeOf`）
- 字で全部の欄を書かず、`Scene3d.spotLight(position, target, fovY)`（白・intensity 1・range 10・影なし）を `{ .. | }` で替える。欄が増えても止まらない
- 円錐の縁が床に輪として映るのを、円錐を広げて range で消す形で隠さない。`innerFovY` で縁をぼかす
- 1 つの場面で計算するのは 2 本まで（目に近い順）。影を落とすのは `shadow` が Some の最初の 1 本

### 点光源

- 1 つの場面で計算するのは 8 本まで（`Scene3d.maxPointLights()`）。**8 本を超えても `pointLights` に全部入れてよい** —
  描き手が `Scene3d.pickLights` で目に近い 8 本を選ぶ（同じ距離なら並びの前）。ゲームの側で近い順に選び直さない
- 8 番目と 9 番目の境をまたぐと、遠い光が点いたり消えたりする。気になる時は、離れた小さな光をまとめる・減らす

## 場面の絵の予算

場面の絵（Texture3d）を GPU に持つ量は 256 MB・64 枚まで（project.json の `scene3dTextureBudgetMB`・`scene3dTextureBudgetCount`）。
超えた時の縮め方は [lightmap.md](lightmap.md) の「場面の絵の予算」。

## 一人称の視点

マウスで視点を回す（カーソルを窓にキャプチャする）のは 2D と 3D で共通の入力の口: `App.withMouseCapture` + `frame#mouseDelta`。
慣習（クリックでキャプチャ・Esc で放す）とフォーカスの扱いは [modules/input.md](modules/input.md) の「一人称の視点」。

## 重さを測る

GPU と CPU の 1 コマの時間・3D の置いた物と draw call の数は、2D と 3D で共通の診断で見る:
`App.withDiagnostics()` → `frame#diagnostics` → `FrameDiagnostics.summaryLines`（[performance.md](performance.md) の §11）。
