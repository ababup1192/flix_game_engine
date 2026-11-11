# 3D の場面（Scene3d）の口の案内

3D の部屋や物を 1 つの描き物（`Render.scene3d`）にまとめる時に、どの口を使うかを引く所。型と引数は `make api Q=<名前>`、
座標の約束（左手系・表の面は時計回り）は `engine/src/scene3d/Scene3d.flix` の頭の doc。光・かすみ・空の式は `engine/src/scene3d/LightModel3d.flix` の木（GL のシェーダーは走る時に木から作り（`render_gl/src/Render3dGlsl.flix`）、CPU の描き手はその木から生成した `engine_tools/src/gen/SoftRaster3dLight.flix` を回す。木の外に残る影の地図の PCF・法線マップの TBN・lightmap の段つきの読みは、2 つの描き手が別々に書き、`make gl-parity` の式の行が値をそろえて確かめる。木の外の入力の作り方は `engine_tools/src/SoftRaster3d.flix` の頭）。
Blender でベイクした光は [lightmap.md](lightmap.md)。

GL（窓）と CPU（画面なしの描き出し・テスト・agent-eval）の 2 つの描き手が、同じ場面を同じ式で描く。

## 3D の色（線形の量で計算する）

- 書く値は 2D と同じ画面の値（sRGB の値）: 材質の Spec（albedo・emission）・`withTint`・頂点の色・光の `color`・`ambient`・かすみの色・空の 3 色・絵。
  描き手は 3D の中だけそれを線形の量へ戻してから光を足し掛けし、3D の色を作った直後に 1 回だけ画面の値へ戻す（Godot 4 の Compatibility と同じ形）。
- 線形の量のまま効く数: 光の `intensity`・`range`・`hemisphere`・lightmap の `intensity`・`Scene3d.withEmissionIntensity`。画面では約 1/2.2 乗で効くので、
  0.78 と同じ数を書くと光の届く端が広く明るくなる。同じ値の `ambient` と `hemisphere` では `hemisphere` の方が明るい。
- 1 を超える明るさ（光る看板・glb の emissive_strength 40）は Spec の emission に書かず `Scene3d.withEmissionIntensity(k, m)` で渡す
  （1 を超える画面の値を線形へ戻すと 1 次より強く伸びる: 2.0 → 約 4.95）。
- 変換しない物: 法線マップ・影の地図・`Output.Depth` の灰色・`background`。
- 半透明の混ぜと MSAA の平均は、画面の値へ戻した後の値どうし（2D と同じ）。材質の中の Mix などの足し算も画面の値の中で混ぜる。
- 材質の絵の段（mip）は線形の量で平均する（白と黒の市松の 1 段上が 188）。法線マップは値のまま・lightmap は `colorSpace` のとおり。
- 画素の値のまま計算する式（0.78 まで）へ戻す口は無い。0.78 の見え方に合わせるなら、`ambient`・光の `intensity` と `range` を線形の目盛りで
  合わせ直す（`docs/migrations/0.79.0.md`）。

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

`Gltf.load` / `loadTexturedUsing` は、glTF のノードを全部（mesh の無い empty・ライト・カメラも）`model#nodes` に入れる。
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

`Gltf.loadTexturedUsing` は材質の `emissiveFactor`・`KHR_materials_emissive_strength`・`emissiveTexture` を読み、材質の emission と emissionIntensity にする
（glTF の決まりどおり光る。Godot・Unity と同じ）。baseColorTexture の無い emissive だけの材質（炎など）も、頂点の色の材質に emission を付けて光る。

- 止めたい時は `Scene3d.withoutEmission(m)`
- emissive の付く材質の spec の名前は `gltf:` で始まり、木の形を変える物を全部入れる（`gltf:tex:<絵の読み方>:et<emissive の絵の読み方>(r,g,b)`・
  `gltf:vc:ec(r,g,b)`）。emissive の無い材質は今までどおり `scene3d:textured:<絵の読み方>`
- emission を差し替えた材質（点滅の mask を掛けるなど）は、名前を替えなくてよい。GL は材質のプログラムを spec と emission の中身の鍵
  （`ShaderGen.hashMaterial`・読む絵の名前は入れない）で引くので、名前が同じで木だけ違う材質が並んでも組み直さない。名前は知らせの文面と GL のプログラムの名前に
  出るだけ（替えるなら `Scene3d.withSpecName`）。毎コマ変わる数は木の `Const` に入れず、ShaderDoc の `param` + `Scene3d.withParams` で渡す（木の数が変わると組み直す）
- 材質の情報（alphaMode・alphaCutoff・doubleSided・絵の名前・emissive の値）は `part#gltfMaterial`。alphaMode は材質に当たる
  （下の「半透明と両面」）。Blender の書き出しは全部の材質を `doubleSided: true` にするので、両面で描きたい物はゲームが材質の名前で選ぶ
- emissiveTexture を指しているのに読めない時（texCoord ≠ 0・画像が読めない・形に TEXCOORD_0 が無い）は光らせず、材質ごとに 1 行知らせる
- 絵の上限は `TextureLimits#baseColor`（emissive の絵も同じ色の絵）。`emissiveFactor` は emission の色（画面の値として読む）に、
  `KHR_materials_emissive_strength`（Blender の強さ 40 など）は線形の倍率として `emissionIntensity` に入る。spec の名前には factor だけが入る
  （強さだけ違う材質は同じプログラムを使う）。`Scene3d.withoutEmission` は `emissionIntensity` も 1 に戻す

## 金属っぽさと粗さ（鏡面ハイライトと空の映り込み）

材質に metallic（0 で絶縁体・1 で金属）と roughness（0 で鏡・1 でざらざら）を付けると、点光源とスポットの鏡面ハイライトと、空の映り込みが足される
（Unity の Standard・Godot の StandardMaterial3D と同じ 2 つの値）。付けない材質は今までどおり拡散光だけで、絵も GL のプログラムも変わらない。

```flix
let gold = Scene3d.material(spec) |> Scene3d.withMetallicRoughness(1.0, 0.25)   // 値は 0..1 に丸める
let matte = Scene3d.withoutMetallicRoughness(gold)                                   // glb の材質を今までの絵に戻す時
Scene3d.metallicRoughnessOf(gold)                                                    // Option[{ metallic, roughness, texture }]
Scene3d.withMetallicRoughnessTexture("tex3d:orm", gold)                              // 絵で決める（B = metallic・G = roughness。値は絵に掛ける係数）
```

- **glb は使う時だけ読む**: `Gltf.loadTexturedPbrUsing`（引数は `loadTexturedUsing` と同じ・バイトの版は `fromGlbTexturedPbrUsing`）が、`pbrMetallicRoughness` があり
  `metallicFactor`・`roughnessFactor`・`metallicRoughnessTexture` のどれかが書いてある材質に付ける（書いていない値は glTF の既定の 1。Blender は metallic 1 の時に
  `metallicFactor` を書かないので、この扱いで合う）。`pbrMetallicRoughness` が無い材質と baseColor だけの材質には付けない（色だけの古い glb が全部金属に見えるのを避ける）。
  絵が無く emissive も無い材質も、付く時は頂点の色の材質（`gltf:vc`）になる。既存の `loadTexturedUsing` は読まない（材質・鍵・絵は今までと同じ。
  `part#gltfMaterial` の `metallic`・`roughness` の値だけ載る）。
  PBR の口は `baseColorFactor` と `emissiveFactor` を glTF の決まりどおり線形の値として読む（`baseColorTexture` の画素は今までどおり sRGB の絵）。
  // WhyNot: 既存の口は線形として読まない — OBJ の Kd と同じく画面の値として読んでいて、変えると既存のゲームの色が変わる。PBR の口まで画面の値として読むと、
  //   金・赤が濃く、暗い色が黒く潰れて Blender の手本と合わない。
  // WhyNot: 既定で読まない — Blender の書き出しは絵も emissive も無い材質にも metallic 0・roughness 0.5 を書くので、読むと今まで頂点の色だけ（`part#material` が `None`）
  //   だった part が材質を持つ物になり、鏡面のプログラムを使い、part を束ねるゲームの条件も外れる（箱庭の町は 473 → 1283 draw/コマ・1 コマ 5.3 → 13 ms）。使うかはゲームが選ぶ。
- **絵**: `metallicRoughnessTexture` は texCoord が 0 で読めた時だけ付く（絵の上限は `TextureLimits#baseColor`）。読めない時は値だけにして材質ごとに 1 行知らせる。
  TEXCOORD_0 の無い形には絵を付けず値だけの材質を付ける。`part#gltfMaterial` に `metallic`・`roughness`（書いていなければ 1）と `metallicRoughnessTexture` が載る
- **式**（`LightModel3d.pbrModel`・GL のシェーダーと CPU の描き手は同じ木から作る）: `色 = albedo × (1 − metallic) × light + Σ 鏡面 + 映り込み`、その後に今までどおりかすみ → emission。
  鏡面は GGX の分布・Smith（Schlick-GGX）・Schlick の Fresnel（F0 = mix(0.04, albedo, metallic)・α = roughness²・0.002 より小さくしない）で、
  光の color × intensity × 減衰（スポットは cone と影も）を掛ける。映り込みは `reflect(−目への向き, 法線)` の向きを roughness² で法線の側へ寄せ
  （粗いほど面の向きに応じた明暗になる）、その向きの空の色に roughness 込みの Fresnel を掛ける。ベイクした光（lightmap）は拡散の側で、鏡面と映り込みは同じに足す
- **空が無い場面**: 映り込みの色は ambient + hemisphere（真っ黒にしない）。`LightModel3d.reflectionSkyOf` が GL と CPU の入力を決める
- **toon**（`toonSteps`）は拡散の光だけを段にし、鏡面と映り込みは段付けしない（決めた事）
- **重さ**: 持つ材質だけが別のプログラム（`+mr`）を使い、光に届く 1 本ごとに鏡面の式が増える（届かない光と背を向けた面は式を飛ばす）。値（metallic・roughness）は
  params で渡すので、値だけ違う材質は同じプログラムを使い回す（batch は値ごとに分かれる）。絵の有無は別のプログラム
- **`loadTexturedPbrUsing` を使うゲームの注意**: 上のとおり `None` だった part が材質を持つ。`None` を目印に part を束ねているなら、束ねる条件を `part#material` が `None` か
  spec の名前が `gltf:vc` の材質まで広げ、`Scene3d.metallicRoughnessOf` の値ごとに束ねる。鏡面が要らない材質は `Scene3d.withoutMetallicRoughness`
- やらない事: キューブマップ・反射プローブ・スクリーン空間の反射・異方性・クリアコート・occlusionTexture

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

## 空（グラデーション）

何も描かれない画素に、上下のグラデーションの空を描く（Godot の ProceduralSkyMaterial の空の部分と同じ考え）。

```flix
let sky = Scene3d.gradientSky(Color.rgb(0.05, 0.07, 0.2), Color.rgb(0.9, 0.6, 0.4), Color.rgb(0.2, 0.15, 0.1)); // 天頂・地平・地面
{ sky = Some(sky |> Scene3d.withSkyCurve(0.7)) | Scene3d.scene(camera, size) }
```

- 色は目から見た向き d で決まる: 上を向けば地平から天頂へ `d.y ^ curve` だけ寄せ、下を向けば地平から地面へ `(−d.y) ^ curve`。
  向きは画素ごとにカメラの pitch・yaw・画角から出すので、**見上げても振り向いても地平は合う**（2D の面を場面の下に敷いて地平の高さを毎コマ手で計算しない）
- `curve`（既定 1）を小さくすると地平の色の帯が細く、大きくすると広くなる。0 以下・NaN は 1
- 空にはかすみを掛けない（距離が無い）。**地平の色をかすみの色にそろえると、遠くの物と空の継ぎ目が消える**
- `sky` が Some なら `environment.background` は使わない（両方 Some なら窓の描き手が 1 回知らせる。`Scene3d.skyWarning`）。Output.Depth では空は白（一番奥）
- 既定は None（今までどおり background の単色か、下の 2D が見える）

## 半透明と両面（窓ガラス・網・水面）

```flix
let glass = Scene3d.material(spec) |> Scene3d.withAlphaBlend(true) |> Scene3d.withDoubleSided(true);  // spec の α が透け具合
```

- `withAlphaBlend(true, m)`: 色 = 材質の色 × α + 下の色 × (1 − α)。深度は読むが書かない（ガラスの向こうのガラスも見える）
- 描く順: 不透明の物 → ビルボード → 半透明の物を **world の境界の真ん中が目から遠い順**（同じ距離なら並びの前。`Scene3d.blendOrderOf`）。
  **1 つの物の中の三角形は並べ替えない**（Unity・Godot と同じ）。入り組んだ半透明（水面と網が交わる）は物を分けて置く
- `withCutout(true)` と両方なら、α が 0.5 未満の画素を捨ててから重ねる
- 半透明の物は影を落とさない・Output.Depth（ピントの Pass）には描かない（ピントはガラスの奥に合う）。lightmap は付けられる
- `withDoubleSided(true, m)`: 裏の面も描く。裏の面は光の計算の法線を裏返す（spec の Normal は裏返さない）。網・葉・ガラスの板に
- glb: `Gltf.loadTexturedUsing` は `alphaMode: BLEND` を `withAlphaBlend(true)`・`MASK` を `withCutout(true)`（`alphaCutoff` は 0.5 の固定。
  ほかの値は 1 回知らせる）にする。**`doubleSided` は当てない**（Blender の書き出しは全部の材質を真にするので、要る物だけゲームが当てる）:

  ```flix
  let m = part#material |> Option.map(mat ->
      if (part#gltfMaterial |> Option.exists(g -> g#doubleSided and String.startsWith(prefix = "net_", g#name))) Scene3d.withDoubleSided(true, mat) else mat);
  ```
- 色の α は材質の spec の α（絵の α）。baseColorFactor の α は読まない（頂点の色に色だけ焼いている）
- 半透明の物が 1 つも無い場面は、今までと 1 bit も同じ絵（描く順も GLSL の字も変わらない）

## 細い物の欠けを抑える（MSAA）

手すり・金網・電線のような細い物は、画素の真ん中に掛からないと抜け、歩くとちらつく。場面を描く Pass に標本を持たせる:

```flix
let plan = { targets = Map#{ "scene" => RenderTarget.withMsaa(4, RenderTarget.windowDescriptor() |> RenderTarget.withHdr) }
           | Render.passPlan(scenePass :: Nil) };
```

- `RenderTarget.withMsaa(n, d)`: n は 1・2・4・8（ほかは近い下の値。GPU の上限 `GL_MAX_SAMPLES` でも頭打ち）。Pass を読む前に標本の平均へ
  まとめる（resolve）ので、読む側は今までどおり Pass の名前で読む。2D と 3D の両方に効く（その Pass に描く物の全部の縁）
- cutout の材質は、その Pass では discard でなく **alpha to coverage** で抜く（金網・葉の縁が 1 画素の幅でなめらかになる）。
  Output.Depth（ピントの Pass）と影の地図は今の discard のまま
- **画面なしの描き出し（CPU）は MSAA をしない**（絵は MSAA の無い絵のまま。agent-eval と render-loop の絵は縁が固い）。FXAA の Pass は CPU でも効く
- 窓そのもの（Pass を使わない 3D）には掛けない。窓の MSAA は 2D の縁も変えるので口を作っていない
- Design の解像度の場面（`Resolution.Design`）には掛からない（ドット絵と画素をそろえる場面に縁のならしは要らない）
- 重さ: 色と深度の置き場が標本の数の倍（1920 × 1080 の Rgba16Float で 4 標本なら色 約 63 MB・深度 約 32 MB）。塗りは縁の分だけ増える。
  効き目と GPU の時間は `App.withDiagnostics()` の `gpuPasses`（Pass ごと）で見比べ、切れるようにしておく
- 既定は 1（今までどおり）

## 場面の絵の予算

場面の絵（Texture3d）を GPU に持つ量は 256 MB・64 枚まで（project.json の `scene3dTextureBudgetMB`・`scene3dTextureBudgetCount`）。
超えた時の縮め方は [lightmap.md](lightmap.md) の「場面の絵の予算」。

## 初めて出る物を先に上げる

`App.withPreload3d({ key, instances, textures })` は、遊びの途中で初めて出る物の形・絵・材質のプログラムを GPU へ上げる。`key` は毎コマ読み、`instances` と `textures` は `key` が変わった時と Doc の読み直しの時だけ読む。3D の場面が 1 つも出ていないタイトルの間でも上がる。

- 描かないので、置く場所は何でもよい。骨つきの物は姿勢を付けたまま渡すと、骨つきの版のプログラムも組める。
- `Instance3d` は `tex3d:` の絵の名前しか持たないので、中身は `textures` で渡す（無い絵は 1 回知らせる）。描く時は今まで通り場面の `textures` にも載せる。
- `key` には中身を決める入力だけを入れる。300 コマの内に 30 回変わると、組み直してばかりだと知らせる。
- 上げた形と絵は、置き場の上限でほかの物より後に捨てる。足りなければそれらも捨てて 1 回知らせる。材質のプログラムは捨てない。

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
let motion = Vec3.v3(speed * Num.sin(yaw), 0.0, speed * Num.cos(yaw));
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
