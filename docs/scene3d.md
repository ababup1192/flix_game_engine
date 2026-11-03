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

## glb のノードを名前で引く

`Gltf.load` / `loadTextured` は、glTF のノードを全部（mesh の無い empty・ライト・カメラも）`model#nodes` に入れる。
Blender で付けた名前で引けば、扉・調べる物・当たり判定の箱・印の点（炎の芯の先など）を、位置や大きさから探さずに済む。

```flix
let door = Model3d.findNode("door_202", doors);                 // 同じ名前が複数あれば並びの前
let hinge = door |> Option.map(Model3d.nodeOrigin);              // 原点 = Blender のオブジェクトの原点（engine の座標）
let colliders = Model3d.nodesWithPrefix("COL_", collision);      // 書き出しの名前の決まりで集める
let byName = Model3d.nodesByName(collision);                     // たくさん引く時は 1 回作って Map で引く（findNode を繰り返さない）
```

- `node#world` / `node#local` = engine の座標（X の反転を済ませた）行列。`node#localBounds` = world を掛ける前の形の min / max
  （mesh の無いノードは None）。向きのある箱は `localBounds` × `world` でそのまま作れる（焼き込まれた頂点から推し量らない）
- 部品の形（`model#parts`）は今までどおり world を焼き込んである。回す扉は、そのノードの部品（`Model3d.partsOfNode`。
  たくさんのノードに回すなら `Model3d.partsByNode` を 1 回作って引く）を `node#world × 回転 × Model3d.partLocalToNode(node, model)` の行列で置く
  （ノードの原点のまわりで回る）。skin のある glb は None
- ジョイントのノードの `world` もノードの TRS（休みの姿勢）から作った行列（逆バインド行列からは作らない・アニメーションでは動かない）
- mesh の無い glb（印の点だけ）も読める（形は頂点 0・parts は空）

## glb の emissive

`Gltf.loadTextured` は材質の `emissiveFactor` × `KHR_materials_emissive_strength` と `emissiveTexture` を読み、材質の emission にする
（glTF の決まりどおり光る。Godot・Unity と同じ）。baseColorTexture の無い emissive だけの材質（炎など）も、頂点の色の材質に emission を付けて光る。

- 止めたい時は `Scene3d.withoutEmission(m)`
- emissive の付く材質の spec の名前は `gltf:` で始まり、木の形を変える物を全部入れる（`gltf:tex:<絵の読み方>:et<emissive の絵の読み方>(r,g,b)`・
  `gltf:vc:ec(r,g,b)`）。emissive の無い材質は今までどおり `scene3d:textured:<絵の読み方>`
- emission を差し替えた材質（点滅の mask を掛けるなど）は `Scene3d.withSpecName(名前, m)` で名前も替える。
  GL は材質のプログラムを spec の名前と emission の有無で引くので、名前が同じで木だけ違う材質が並ぶと毎コマ組み直す。部品ごとに木が違うなら部品ごとの名前
- 材質の情報（alphaMode・alphaCutoff・doubleSided・絵の名前・emissive の値）は `part#gltfMaterial`。描き方はまだ変えない（読むだけ）。
  Blender の書き出しは全部の材質を `doubleSided: true` にするので、両面で描きたい物はゲームが材質の名前で選ぶ
- emissiveTexture を指しているのに読めない時（texCoord ≠ 0・画像が読めない・形に TEXCOORD_0 が無い）は光らせず、材質ごとに 1 行知らせる
- 絵の上限は `TextureLimits#baseColor`（emissive の絵も同じ色の絵）。emissive の値（Blender の強さ 40 など）は線形の量で、
  今の式（色の値をそのまま足す）では明るすぎることがある（色の線形化で合わせ直す予定）

## 描く量（視錐台の外を間引く）

GL と CPU の描き手は、場面のカメラの視錐台の外の置いた物とビルボードを描かない（ゲームは何も書かなくてよい）。
判定は外れる側に倒してある（画素を 1 つも出さない物だけを間引く）ので、絵は間引かない時と同じ。

- 骨つきの物（Pose で形が境界の外へ出うる）と頂点の無い形は間引かない。ビルボードは外接球で見る
- 影の地図は光の視錐台で別に間引く（目に見えない物も影は落とす）
- 間引いた物の形・絵・材質のプログラムは、今のコマで使った物として GPU に残す（振り向いても上げ直さない）
- 間引くのは視錐台の外だけ。壁の向こう（部屋ごとに描くか）はゲームが決める
- 効き目は `FrameDiagnostics.Diagnostics.scene3dCounts`（`instances` = 置いた物・`drawn` = そのうち描いた物）で見る
- 光や羽虫をゲームの側で間引く・数える時は `Camera3d.frustum(camera, aspect)` → `Frustum.intersectsSphere` / `intersectsBox`。
  場面と同じ判定は `Scene3d.frustumOf(scene)` + `Scene3d.isOutsideFrustum`・置いた物の world の境界は `Scene3d.worldBoundsOf`

## 場面の絵の予算

場面の絵（Texture3d）を GPU に持つ量は 256 MB・64 枚まで（project.json の `scene3dTextureBudgetMB`・`scene3dTextureBudgetCount`）。
超えた時の縮め方は [lightmap.md](lightmap.md) の「場面の絵の予算」。

## 一人称の視点

マウスで視点を回す（カーソルを窓にキャプチャする）のは 2D と 3D で共通の入力の口: `App.withMouseCapture` + `frame#mouseDelta`。
慣習（クリックでキャプチャ・Esc で放す）とフォーカスの扱いは [modules/input.md](modules/input.md) の「一人称の視点」。

## 一人称で歩く（当たり判定の箱・段差・坂・落ちる）

壁で止まる・段差を上る・坂を上る・床が無ければ落ちる、は engine_world の `CharacterBody3d.moveAndSlide` が受け持つ
（Godot の `CharacterBody3D.move_and_slide`・Unity の `CharacterController.Move`）。押し出しや床探しをゲームで書かない。
描き手とは独立した純粋な計算（場面に何を描いたかに関わらず、箱の並びだけで決まる）。

```flix
// 読み込み: Blender で "COL_" の名前を付けた箱を集める（向きと大きさはノードの行列と局所の境界からそのまま）
let statics = Model3d.nodesWithPrefix("COL_", collision) |> CollisionShape3d.boxesOfNodes;
let world = CollisionWorld3d.build(2.0, List.append(statics, groundAndBounds));  // 1 マス 2 m の xz の格子
let s = { stepHeight = 0.35 | CharacterBody3d.settings(0.22, 1.7) };              // 半径・高さ
let body = CharacterBody3d.snapToFloor(world, Nil, s, CharacterBody3d.bodyAt(start)); // 始まりは床に合わせる

// 毎コマ: 向きはゲームが持ち、水平の速さ（m/秒）だけ渡す。扉の板など動く箱は moving へ毎コマ
let motion = Vec3.v3(speed * Vec2.sin(yaw), 0.0, speed * Vec2.cos(yaw));
let next = CharacterBody3d.moveAndSlide(world, doorLeaves, s, motion, Clock.dtOf(clock), body);
```

- 体は足元の点（`body#feet`）と足の着き方（`Footing.OnFloor(floor)` / `Airborne(縦の速さ)`）だけ。目の高さ・向き・足音・頭の上下はゲームが持つ。
  足音の種類は `floor#sloped`（床の箱が傾いている）で分けられる
- 体は縦に並べた球（間は半径以下）で、足元から `stepHeight` より上だけを壁として扱う。`stepHeight` より低い箱は上に乗る
- **坂**: 床の面の向きと真上の角が `floorMaxAngleDeg`（既定 45°・Godot と同じ）以下なら床、超えたら壁。
  傾いた箱を全部床として扱いたい（Blender の階段の段板が 45° を少し超える）時は 90
- 立っている間は `snapLength`（0.45 m）の中で下の床に吸い付く（階段を下りても浮かない）。床が消えたら落ち、下の床で止まる
- 1 回に進む水平の距離が `maxSubstep`（半径の半分・5 cm まで）を超えないよう区切って押し出す。速く走っても薄い壁を抜けない。
  1 回の `moveAndSlide` で進める秒は 0.25 まで（ヒッチの時に区切りの数が膨らまない）
- 立っていて速さが 0 なら体は 1 bit も動かない（動く箱が食い込んだ時だけ押し出す）。足元の床が消えた時（箱を外した・動く箱に縁の外へ押し出された）は止まっていても落ち始める。
  動く床に乗っても体は床を追わない
- 押し出しは `world` の箱を `build` に渡した並びの順に、その後に `moving` の並びの順に足し込む。角で 2 枚に挟まれた時の答えは並びで決まる
- **地面と歩ける範囲は箱で入れる**: 当たり判定の箱の無い所の地面は大きな薄い箱、歩ける範囲は外側の厚い箱（1 m 以上・頭より高く）。
  範囲の箱の上面が「足元 + stepHeight」より低いと床として拾って乗り上げる
- **扉**: 閉じた時の板の箱を `CollisionShape3d.transformBox(蝶番のまわりの回転, 板)` で毎コマ回し、`moving` に渡す。
  回している扉が体を押し込まないよう、回す前と後で `CollisionShape3d.penetration(板, CharacterBody3d.capsuleOf(s, body))` を比べ、深くなるならそのコマは回さない
- 1 マスの幅は体の直径から部屋の幅くらい（1〜4 m）。64 マスより多くに掛かる大きな箱（地面）は格子に入れず毎回見る
- 当たり判定の箱を場面に重ねて見る時は `CollisionShape3d.debugMesh(boxes, color)` を `Scene3d.meshInstance(m, Mat4.identity())` で置く
- 形は箱だけで歩く（三角形の壁・正確なカプセル × 箱は無い）。跳ぶ口も無い（`motion` の y は使わない）

## 見ている物を調べる（レイ）

クロスヘアの先の物は `Camera3d.forwardRay(camera)` → `Ray3d.pickNearest(ray, 届く距離, 的の列)` で引く。
的の鍵はゲームが決める（調べる物の enum・ノードの名前）。**壁も「壁」の鍵で同じ列に入れる** — 一番近い物が壁なら、その向こうの物は選ばれない。

```flix
// 読み込みで 1 回作って描く元（Resources）に持つ
let props = Ray3d.boxTargetsOf(n -> Look.Prop(n#name), Model3d.nodesWithPrefix("COL_PRP_", collision));
let walls = statics |> List.map(b -> (Look.Wall, Ray3d.RayTarget.Shape(CollisionShape3d.BoxShape3d(b))));
// 毎コマ: 持っている的の列にレイを当てる（扉の板の的だけ今の角で作り直して足す）
match Ray3d.pickNearest(Camera3d.forwardRay(camera), 2.5, List.append(props, walls)) {
    case Some((Look.Prop(name), _)) => // 照準を明るくして名前を出す・E で調べた文言（文言は Doc へ）
    case _                          => // 何も見ていない（壁を見ている）
}
```

- 同じ距離なら並びの前。始まりが形の中なら、その形には当たらない（Unity の Raycast・Godot の intersect_ray と同じ）
- 距離と向きの内積（「近くて前にある物」）で代わりにしない — 壁の向こうの物を選び、細長い物の端を外す
- 画面の点（マウスの位置）からは `Camera3d.screenPointToRay(camera, 描き物の大きさ, 点)`（`worldToScreen` の逆。始まりは目）
- 形ごとの問い: `Ray3d.hitBox` / `hitSphere` / `hitCapsule` / `hitTriangle`（表裏とも）/ `hitMesh`（境界の箱で先に外す）/ `hitInstance`
  （骨つきの物は境界の箱だけ）。`RayHit` は距離・点・面の向き（レイの来た側）
- 扉を E で動かすのも、足元からの距離と向きではなく、レイが当たった扉の板にする（扉の板の箱を的に入れる）

## 重さを測る

GPU と CPU の 1 コマの時間・3D の置いた物と draw call の数は、2D と 3D で共通の診断で見る:
`App.withDiagnostics()` → `frame#diagnostics` → `FrameDiagnostics.summaryLines`（[performance.md](performance.md) の §11）。
