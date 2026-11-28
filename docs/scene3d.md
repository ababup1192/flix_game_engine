# 3D の場面（Scene3d）の口の案内

3D の部屋や物を 1 つの描き物（`Render.scene3d`）にまとめる時に、どの口を使うかを引く所。型と引数は `make api Q=<名前>`、
座標の約束（左手系・表の面は時計回り）は `engine/src/scene3d/Scene3d.flix` の頭の doc。光・かすみ・空の式は `engine/src/scene3d/LightModel3d.flix` の木（GL のシェーダーは走る時に木から作り（`render_gl/src/Render3dGlsl.flix`）、CPU の描き手はその木から生成した `engine_tools/src/gen/SoftRaster3dLight.flix` を回す。木の外に残る影の地図の PCF・法線マップの TBN・lightmap の段つきの読みは、2 つの描き手が別々に書き、`make gl-parity` の式の行が値をそろえて確かめる。木の外の入力の作り方は `engine_tools/src/SoftRaster3d.flix` の頭）。
Blender でベイクした光は [lightmap.md](lightmap.md)。

GL と WebGPU（窓・ブラウザ）と CPU（画面なしの描き出し・テスト・agent-eval）の描き手が、同じ場面を同じ式で描く。

## 目次

- [3D の色（線形の量で計算する）](#3d-の色線形の量で計算する)
- [動く光](#動く光)
  - [スポットライト（懐中電灯）](#スポットライト懐中電灯)
  - [点光源（8 本を超えた時の選び方）](#点光源8-本を超えた時の選び方)
  - [点光源の影（街灯・たいまつの放射状の影）](#点光源の影街灯たいまつの放射状の影)
  - [光の量の読み方（Legacy / Physical）](#光の量の読み方legacy--physical)
  - [太陽（平行光源）と、その影](#太陽平行光源とその影)
  - [ビルボードの影（太陽・点光源）](#ビルボードの影太陽点光源)
  - [ドット絵のアトラスを貼る（mip のレベルの上限）](#ドット絵のアトラスを貼るmip-のレベルの上限)
  - [ビルボードを画素にそろえる（ゲームの側の手本）](#ビルボードを画素にそろえるゲームの側の手本)
  - [縦の線を平行のまま見下ろす（レンズシフト・HD-2D のカメラ）](#縦の線を平行のまま見下ろすレンズシフトhd-2d-のカメラ)
- [glb のノードを名前で引く](#glb-のノードを名前で引く)
- [glb の emissive](#glb-の-emissive)
- [glb の頂点の色（COLOR_0・Blender でベイクした明るさ）](#glb-の頂点の色color_0blender-でベイクした明るさ)
- [金属っぽさと粗さ（鏡面ハイライトと空の映り込み）](#金属っぽさと粗さ鏡面ハイライトと空の映り込み)
- [周りの景色を映す（環境マップと箱の補正）](#周りの景色を映す環境マップと箱の補正)
- [環境マップから拡散の光（SH）](#環境マップから拡散の光sh)
- [頂点の色で地面の絵を混ぜる](#頂点の色で地面の絵を混ぜる)
- [描く量（視錐台の外を間引く）](#描く量視錐台の外を間引く)
  - [物の置き方を選ぶ（instances / staticGroup / MultiMesh3d）](#物の置き方を選ぶinstances--staticgroup--multimesh3d)
  - [同じ形の動く物をたくさん（MultiMesh3d）](#同じ形の動く物をたくさんmultimesh3d)
  - [視錐台の外を間引く](#視錐台の外を間引く)
  - [ビルボードの draw の数（同じ絵の板をまとめる）](#ビルボードの-draw-の数同じ絵の板をまとめる)
  - [動かない物をまとめる（staticGroup）](#動かない物をまとめるstaticgroup)
- [空（グラデーション）](#空グラデーション)
- [半透明と両面（窓ガラス・網・水面）](#半透明と両面窓ガラス網水面)
- [デカール（壁・床に血・汚れ・弾痕・標示を貼る）](#デカール壁床に血汚れ弾痕標示を貼る)
- [細い物の欠けを抑える（MSAA）](#細い物の欠けを抑えるmsaa)
- [画面の歪み（熱のゆらぎ・水の中・魔法）](#画面の歪み熱のゆらぎ水の中魔法)
- [地面を這う霧（高さの霧・街灯のにじみ）](#地面を這う霧高さの霧街灯のにじみ)
  - [明るい所へ入った直後の白飛び（ExposureAdaptation）](#明るい所へ入った直後の白飛びexposureadaptation)
- [画面の上の技（SSAO）](#画面の上の技ssao)
- [PS1 風の描き方（色の丸めとディザ・頂点の揺れ・アフィンの uv）](#ps1-風の描き方色の丸めとディザ頂点の揺れアフィンの-uv)
  - [テレビのにじみ（CRT・コンポジット映像）](#テレビのにじみcrtコンポジット映像)
  - [3 つの描き手の違い](#3-つの描き手の違い)
  - [見送った物（頂点ごとの光）](#見送った物頂点ごとの光)
- [ブラウザ版のシェーダー（書き出しの時に作る）](#ブラウザ版のシェーダー書き出しの時に作る)
- [場面の絵の予算](#場面の絵の予算)
- [初めて出る物を先に上げる](#初めて出る物を先に上げる)
- [一人称の視点](#一人称の視点)
- [一人称で歩く（当たり判定の箱・段差・坂・落ちる）](#一人称で歩く当たり判定の箱段差坂落ちる)
- [見ている物を調べる（レイ）](#見ている物を調べるレイ)
- [重さを測る](#重さを測る)

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
- 1 つの場面で計算するのは 2 本まで（目に近い順。点光源と違って境をまたぐとぱっと切り替わる）。影を落とすのは `shadow` が Some の最初の 1 本
- スポットの影の地図の目は光から `min(1, max(2, range) / 100)` より手前を切る（`Scene3d.shadowCamera` はスポットの影の地図のカメラ。太陽と点光源の影は使わない）。卓上の灯り（range 3）なら 3 cm から影が入る。
  スポットの `bias` は near が 1 の時の地図の奥行きの値（0..1）で書く（太陽の `bias` は m で単位が違う）。near が 1 より小さい光は描き手が
  `Scene3d.spotShadowDepthBiasOf` で縮めて引くので、world で表す長さは range に依らずそろう

### 点光源（8 本を超えた時の選び方）

点光源の数の上限と選び方の説明はこの節だけに置く（ほかの所はここへのリンク）。

- 作るのは `{ color = .., intensity = 2.0 | Scene3d.pointLight(position, range) }`（白・intensity 1 から書き替える。字で全部の欄を書かない）。
  intensity の意味は下の「光の量の読み方」で替わる（Legacy は光の所の明るさの倍率・Physical は 1 m の所の照度）
- 1 つの場面で計算するのは 8 本まで（`Scene3d.maxPointLights()`）。**8 本を超えても `pointLights` に全部入れてよい** —
  描き手（GL・WebGPU・CPU）が `Scene3d.pickLights` で選ぶ。ゲームの側で選び直さない
- 選び方（8 本を超えた時だけ。8 本以下は並びも強さもそのまま）:
  1. range の球が視錐台に掛からない光（画面に光が届かない）と、range か intensity が 0 以下の光を落とす
  2. 残りを点数の小さい順に 8 本選ぶ（同じ点数なら並びの前）。点数は「見ている向き（画面の真ん中）から光の球のふちまでの角」。
     球が画面の真ん中に掛かる光ほど小さい。球が画面の端から半分出ている光は点数が大きくなる（`Frustum.sphereInsideRatio` で割る）。
     目が球の中にある光（手に持つ灯り・目の周りの灯り）は、目が球の中心に近いほど小さく、向きに依らず先に選ばれる
  3. 選んだ光の強さに重みを掛ける: 選ばれない最初の光（9 番目）の点数で 0、6 番目の点数より小さければ 1、その間はまっすぐつなぐ。
     7・8 番目は 9 番目に近いほど暗くなるので、カメラや光が動いて入れ替わっても、ぱっと点いたり消えたりしない
- 目からの距離では選ばない。見下ろしの遠いカメラでは、画面の真ん中（キャラの周り）の光が先に選ばれる。
  画面に入る光が 8 本より多いと、画面の端と奥の端の光の溜まりは出ない（bench/webgpu_v2 の `lampsMany`・24 本で画面の真ん中の 2 列が手前から 3〜4 行目まで照らされ、その先と両脇は暗い。`lampsSweep` はカメラを 0.2 m ずつずらした入れ替わり）。
  動かない街灯の地面の光の溜まりを全部出したいなら、頂点の色か lightmap（ベイク）に入れる
- 8 本を超える場面は、7・8 番目の光が元の強さより暗く描かれる。全部の光を元の強さで出したいなら 8 本以下にまとめる。
  光を 8 本から 9 本へ増やしたコマでは、7・8 番目がその場で暗くなる（光そのものが増えるので、つなぎはしない）
- F3 の診断の `droppedPointLights` と `Scene3d.droppedLightsOf` は「渡した本数 − 8」。画面の外で落とした光も数える（カメラを回すたびに数が揺れないように）。画面なしのテストで 1 コマの合計を見るのは `Scene3d.droppedLightsOfScenes(Render.drawScenes3d(items))`

### 点光源の影（街灯・たいまつの放射状の影）

```flix
let scene = { pointLights = lamps | Scene3d.scene(camera, size) }
    |> Scene3d.withPointShadows({ maxShadowedLights = 2 | Scene3d.pointShadowMap() });
```

光から見た 6 方向（+X・−X・+Y・−Y・+Z・−Z）の深度を 1 枚の絵（atlas）に並べ、受ける点が落ちる方向の面を引く（Unity・Unreal の Shadow Atlas・Bevy の PointLightShadowMap）。
GL・WebGPU・CPU が同じ約束（`Scene3d.PointShadows.atlasOf` の doc）で描く。

| 欄 | 既定 | 意味 |
|---|---|---|
| `maxShadowedLights` | 4 | 影を落とす灯りの数の上限（0 以下で影なし・8 まで） |
| `mapSize` | 512 | 面 1 つの一辺の画素（16 以上。atlas が 4096 に収まるよう縮める: 8 本で 512・4 本で 682・1 本で 1365） |
| `bias` | 0.05 | world の長さ。比べる奥行きから引く量（太陽の `bias` と同じ単位） |
| `normalBias` | 1.0 | 受ける点を形の法線の向きに「面 1 画素の world の幅 × normalBias × (pcfRadius + 1)」ずらす（すれすれに光を受ける床が自分の影を拾う縞を消す） |
| `pcfRadius` | 1 | 周りを平均する幅（画素）。大きいほど影の縁が柔らかい |
| `strength` | 0.8 | 影の濃さ（0〜1） |

- 影を落とす灯り: `pickLights` で選んだ光（「[点光源](#点光源8-本を超えた時の選び方)」）のうち、画面の真ん中に近い順に `maxShadowedLights` 本。候補が上限より多い時は最後の 1 本の影の濃さを次の候補との点数の差でなめらかに 0 へ寄せ、入れ替わる瞬間に影がぱっと出たり消えたりしない（上限 1 本の時は寄せない）
- 灯り 1 本ごとの影の切り替えは無い（`PointLight` の欄は増やさない）。影を落とさない灯りを混ぜたいなら上限で絞る
- 影を落とす物: 不透明の置いた物（骨つきも曲がった形で）と `withCastShadows(true)` のビルボード（「[ビルボードの影](#ビルボードの影太陽点光源)」）。半透明は落とさない
- 影を受ける物: 頂点の色の物と材質の物（lightmap の面も。点光源はベイクの上に足す光なので影も掛かる）
- 影の割合は木の外で画素ごとに 1 回求め、点光源の拡散と鏡面の両方に掛ける。光が届かない点（range の外）と面が光に背を向けた点は地図を引かない
- 面の継ぎ目は guard band（面の角を 90° より少し広く取り、PCF の周りの画素が隣の面へはみ出さない）で筋を出さない
- 重さ: 影の地図の draw は面 6 × 灯り × 範囲に入る物（`drawCalls` の `shadowPass`・時間は `Phase.Shadows`）。PCF は (2r+1)² 回を光が届く画素だけ。
  端末で重さを替えるなら `Scene3d.pointShadowMapFor(ctx#display#sizeClass)`（Small = 1 本・256（atlas 768 × 512）・Medium = 2 本・512・Large = 4 本・512 = `pointShadowMap()`）。
  太陽の影も `Scene3d.directionalShadowFor(ctx#display#sizeClass)`（Small = 1024・Medium と Large = 2048 = `directionalShadow()`）。どちらも `{ .. | }` で欄を替えてよい
- 既定（`pointShadows = None`）は今までの絵と同じ（GPU のシェーダーの字も同じ）。影つきの場面だけ別のプログラム（`+ps`）を組む
- 点光源の影と `Physical` の場面は、その場面が初めて出たコマに変種のプログラム（`+ps`・`+pu`）を組む（そのコマが重い）。先に組むなら `App.withPreload3d` の `variants` に `Scene3d.preloadVariantOf(場面)` を渡す（「初めて出る物を先に上げる」）

### 光の量の読み方（Legacy / Physical）

```flix
let scene = Scene3d.scene(camera, size) |> Scene3d.withLightUnits(Scene3d.LightUnits.Physical) |> Scene3d.withUnitsPerMeter(16.0);
```

| 項 | `Legacy`（既定） | `Physical` |
|---|---|---|
| 点・スポットの落ち方 | (1 − d² / range²)² | 逆二乗 × range の窓 clamp01(1 − (d² / range²)²)² / max(d_m², 1e−4)（d_m = d / unitsPerMeter。Filament・UE4 と同じ形） |
| 点・スポット・太陽の拡散 | albedo × E × facing | albedo / π × E × facing |
| 鏡面・ambient・hemisphere・lightmap・emission | — | 同じ（ambient と hemisphere は入る放射輝度の意味で、一様な空の拡散は albedo × L と 1/π が相殺する） |

- `Physical` の intensity は点・スポットが 1 m の所の照度（cd に当たる）・太陽が照度（lux に当たる）。単位の型（lux・cd・EV100）はまだ無い
- 今の値のまま切り替えると拡散が 1/π に暗く、光の近くが明るく遠くが暗くなる。intensity（拡散を同じ明るさにするなら π 倍）と ambient を決め直す
- 場面の長さが m でない時は `Scene3d.withUnitsPerMeter`（逆二乗を m で測る）。`Legacy` では unitsPerMeter は描き方を変えない

### 太陽（平行光源）と、その影

屋外の町・都市・野原の光は、遠くの 1 つの光（太陽）で足りる。Unity・Unreal の Directional Light・Godot の DirectionalLight3D に当たる。

```flix
let sun = { intensity = 1.2, color = Color.rgb(1.0, 0.96, 0.88),
            shadow = Some({ distance = 600.0 | Scene3d.directionalShadow() })
          | Scene3d.directionalLight(Vec3.v3(-0.4, -1.0, -0.3)) };
let base = Scene3d.scene(camera, size);
{ directionalLight = Some(sun), environment = { ambient = Color.rgb(0.35, 0.37, 0.42) | base#environment } | base }
```

- `direction` = 光が進む向き（長さは問わない。描く時に長さ 1 にする）。場面に 1 つまで（`directionalLight`。既定は `None`）
- **`Scene3d.scene()` の `ambient` は白なので、太陽を足すと白く飛ぶ。** 上の例のように `ambient` を下げる
- 拡散は 点光源と同じ `facing`（面が光へ向く度合い）に `color × intensity` を掛ける。`metallic` と `roughness` を持つ材質には鏡面も足す
- **lightmap の面には拡散を足さない**（ベイクに太陽を含めるのが普通で二重になる）。鏡面は足す（ベイクに入るのは拡散だけ）
- ビルボード（lit）は点光源と同じく法線をカメラへ向けて光を受ける。影は既定では落とさず受けない（「[ビルボードの影](#ビルボードの影太陽点光源)」）
- 向きの長さが 0・`intensity` が 0 以下・色が黒の太陽は、太陽なしと同じに描く（影の地図も描かない。理由は 1 回だけ知らせる）。
  描き手が使う太陽は `Scene3d.directionalLightOf(scene)` 1 つで決まる

影（`shadow = Some(..)`。`Scene3d.directionalShadow()` の既定値を `{ .. | }` で替える）はカスケード 1 段の影の地図で、スポットの影と並べて使える:

| 欄 | 既定 | 意味 |
|---|---|---|
| `mapSize` | 2048 | 地図の一辺の画素（0 以下で影なし。4096 まで） |
| `bias` | 0.05 | **world の長さ（m）**。自分の面に影を落とさないための奥行きのずらし（描く時に `bias / 奥行きの幅` の値へ直す） |
| `normalBias` | 1.0 | 受ける点を、法線の向きに `normalBias × 地図の 1 画素の world の幅` だけずらしてから地図を引く（法線マップを当てる前の法線で） |
| `pcfRadius` | 1 | 周りを平均する幅（画素。8 まで） |
| `strength` | 0.8 | 影の濃さ（0〜1） |
| `distance` | 150 | カメラからどこまでに影を落とすか（Unity の Shadow Distance）。`min(distance, カメラの far)`。手前の 1 割で影を薄める |
| `casterReach` | 200 | 光の側へ、影を落とす物を拾う箱をどこまで延ばすか（画面の外の高い建物の影を拾う） |

- 地図の箱は、カメラの視錐台の `near..distance` の部分を囲む球から決める（半径はカメラの向きで変わらない）。地図の 1 画素の幅
  （`2r / mapSize`）に丸めるので、カメラを動かしても影の縁が画素の中で動かない。**太陽の向きを毎コマ変える場面（日没の動画）は軸が回るのでちらつく**
  （向きを変えながら撮る時は `mapSize` を大きくして `pcfRadius` で縁をならす）。式は `Scene3d.directionalShadowOf` の doc
- 半透明の物は影を落とさない。cutout の穴の影は埋まる（スポットの影と同じ）
- 影の地図の draw は `drawCalls`・時間は `Phase.Shadows` に入る。1 つの場面にスポットの影と太陽の影があれば地図は 2 枚
- `Scene3dCmd` を丸ごと書いているゲームは、欄 `directionalLight = None` を足す（`{ .. | Scene3d.scene(..) }` で替えているゲームは何も要らない）

### ビルボードの影（太陽・点光源）

ドット絵のキャラや木の板が影を落とす・受ける。ビルボードの影の説明はこの節だけに置く。

```flix
let hero = Scene3d.billboard("chars", frame, at, { x = 0.9, y = 1.6 })
    |> Scene3d.withCastShadows(true)      // 太陽と点光源の影の地図に描く（Unity の Cast Shadows・Godot の cast_shadow）
    |> Scene3d.withReceiveShadows(true)   // 太陽の影を受ける（Unity の Receive Shadows。lit の時だけ）
    |> Scene3d.withShadowCasterScale(Vec2.v2(0.6, 0.7))   // 影に描く板だけ細く・短く（既定 (1, 1)）
```

| 何が | 太陽の影 | 点光源の影（`withPointShadows`） | スポットの影 |
|---|---|---|---|
| 落とす（`withCastShadows(true)`） | する | する（板を灯りの方へ向けて立てる） | しない（地図に描かない） |
| 受ける（`withReceiveShadows(true)`） | する | しない | しない |

- **影を落とす**: 影の地図の中では、同じ大きさの板を地面に垂直に立てて光の方へ向け（太陽は `Scene3d.billboardShadowRightOf`）、絵の α < 0.5 を捨てて描く。
  影は絵の形で光の向きに伸び、太陽が横でも細らない。見えている板（カメラへ向く）とは別の向きの板。光が前（逆光）だと、光の側から見た絵なので影の絵は左右が返る
- **影の板の大きさ**（`withShadowCasterScale`）: 影の地図に描く板だけ幅（x）と高さ（y）に倍率を掛ける（見えている板は変えない）。ドット絵のキャラの影が
  「人形がそのまま大きくなった」ように太く長い時に、幅を 0.5〜0.7・高さを 0.6〜0.8 に絞る。板は anchor を中心に縮む（anchor が足元なら影の根元は足元のまま）。
  太陽と点光源の影の両方に効く。成分が 0 以下なら影を描かない。既定 (1, 1) は今までの絵と同じ（描き出しの鍵も同じ）
- **影を受ける**: 絵の中の高さごとに、影の地図の板の真ん中の縦の線の上の点を、板から水平に幅の半分だけ離れるまで太陽の方へ進めた点で影を引く（`Scene3d.billboardShadowPointOf`）。
  建物の影に入ると絵の行ごとに暗くなる。太陽の高さ約 75° までは自分の影を受けない（それより高い太陽では足元から自分の影を拾い始める）。
  幅の広い板（看板・木）は点が板から遠くへ出るので、軒の影の縁では明るさの切り替わりが板の幅の半分ずれる
- カメラへ向いた板なので、太陽がカメラの正面（板の裏）にあると板は太陽の光を受けず、影を受けても見え方は変わらない
- 影の地図の無い場面（置いた物が 1 つも無い・Output.Depth）では何もしない。既定はどちらも偽で、今までの絵のまま
- 重さ: 影の地図の draw は、地図 1 枚（点光源は面 1 つ）ごとに影を落とすビルボードの絵 1 種類につき 1 つ増える（`drawCalls` の `shadowPass`・同じ絵の板は 1 回の instanced draw）。地図の画素の数は変わらない

### ドット絵のアトラスを貼る（mip のレベルの上限）

`Scene3d.texturedMaterial(atlas, Nearest)` で、タイルを詰めたアトラスを貼った床や壁が、遠くや斜めで 1 つのタイルが 1 画素より小さく縮むと、
mip の上のレベルで隣のタイルの色が混ざる（地面すれすれの画角の地平線に赤紫の帯が出た。見下ろしの HD-2D の画角では出なかった）。
材質に `Scene3d.withMaxMipLevels(Scene3d.atlasMipLevelsFor(タイルの一辺 px))` を付けると、1 つのタイルの中だけを平均するレベルまでしか読まない（16 px のタイルで 5・48 px で 5・24 px で 4。タイルは一辺の倍数の位置に詰め、アトラスの幅と高さも 2^(レベルの数 − 1) で割り切れる大きさにする）。
Lightmap の `maxLevels` と同じ考え。法線マップの絵には掛けない。
タイルのふちの 1 画素で隣のタイルを読む線は mip と関係なく出るので、アトラスのタイルのふちを外へ 1〜2 px 伸ばす（ゲームの側）。

### ビルボードを画素にそろえる（ゲームの側の手本）

ドット絵のキャラを 1 テクセルより細かく動かすと、絵のテクセルの境が毎コマ画面の画素の上で動いて揺れる（ドットの太さが揺れる）。
置く位置と**カメラの位置の両方**を world の 1 テクセル（1 / 密度 m）に丸める。engine の口は要らない。

```flix
let texelsPerMeter = 32.0;
let snap = (v: Float64) -> Float64.floor(v * texelsPerMeter + 0.5) / texelsPerMeter;
let at = Vec3.v3(snap(hero#x), hero#y, snap(hero#z));           // 位置は遊びの値のまま持ち、描く時だけ丸める
let camera = { eye = Vec3.v3(snap(eyeX), eyeY, snap(eyeZ)) | camera0 };
```

- CPU の描き手で 1/8 テクセルずつ 16 コマ動かして比べた: 丸めないと 15 回中 13 回絵が変わり、丸めると 2 回（テクセルの境をまたいだ時だけ）。
  カメラがキャラを追う時はカメラも丸めないと 15 回とも変わる（地面が揺れる）
- 1 テクセルが画面の 3 px 前後の拡大（`Resolution.Native`）では、丸めた後もテクセルの幅が ±1 px 揺れる。気になれば `Resolution.Design` で描く

### 縦の線を平行のまま見下ろす（レンズシフト・HD-2D のカメラ）

カメラを水平（`pitch = 0`）に向けたまま、写す範囲だけを下へずらす。建物の縦の線は平行のまま、地面だけが奥へ強くすぼまる
（建築写真のあおり補正と同じ見え方）。Unity の Physical Camera の Lens Shift・Blender の Shift X/Y・Godot の Camera3D の frustum offset と同じ物。

```flix
// 画面の上の端で地面を 15°、下の端で 50° 見下ろす（目の高さ h・水平に向ける）
let tanOf = (deg: Float64) -> Num.sin(deg * Num.pi() / 180.0) / Num.cos(deg * Num.pi() / 180.0);
let ta = tanOf(15.0); let tb = tanOf(50.0);
let tanHalf = (tb - ta) / 2.0;                       // 縦の画角の半分の tan
let camera = { far = 60.0, lensShift = Vec2.v2(0.0, 0.0 - (ta + tb) / 2.0 / (2.0 * tanHalf))
             | Camera3d.camera(Vec3.v3(x, h, z), 0.0, 0.0, 2.0 * Num.atan2(tanHalf, 1.0)) };
```

- `lensShift` の単位は画面の幅（x）と高さ（y）に対する比。y = −0.5 で画面の高さの半分だけ下を写す。向き（`pitch`・`yaw`）は変えない。既定は `Vec2.zero()`（今までの絵とバイトまで同じ）
- `Camera3d.projectionMatrix`・`frustum`・`worldToScreen`・`screenPointToRay`・空の向き（`Scene3d.skyBasisOf`）・太陽の影の範囲・点光源の選び方（画面の真ん中 = `Camera3d.centerRayDirection`）が同じ値を読む。GL・WebGPU・CPU の描き手は `projectionMatrix` を使うので、描き手ごとの設定は要らない
- カメラが水平なので、カメラへ向くビルボードは地面に垂直に立つ。板の高さを `1 / cos(pitch)` 倍に伸ばす補正は要らない
- `pitch` を傾けてシフトで縦を直す形にはしない（縦の線が平行になるのは pitch 0 の時だけ）
- 下へ大きくずらすと視錐台が横と下へ広がり、太陽の影の地図がその全部を覆おうとして粗くなる。`far` と `directionalShadow` の `distance` を、画面の上の端の地面までの距離の少し先（見下ろしの町なら 40〜60 m）に絞る
- カメラは欄を全部字で書かず `Camera3d.camera(eye, yaw, pitch, fovY)` から `{ .. | }` で替える

## glb のノードを名前で引く

glb の読み込み（`Model3d.load` / `decode`）は、glTF のノードを全部（mesh の無い empty・ライト・カメラも）`model#nodes` に入れる。
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

glb の読み込みは材質の `emissiveFactor`・`KHR_materials_emissive_strength`・`emissiveTexture` を読み、材質の emission と emissionIntensity にする
（glTF の決まりどおり光る。Godot・Unity と同じ）。baseColorTexture の無い emissive だけの材質（炎など）も、頂点の色の材質に emission を付けて光る。

- 止めたい時は `Scene3d.withoutEmission(m)`
- emissive の付く材質の spec の名前は `gltf:` で始まり、木の形を変える物を全部入れる（`gltf:tex:<絵の読み方>:et<emissive の絵の読み方>(r,g,b)`・
  `gltf:vc:ec(r,g,b)`）。emissive の無い材質は今までどおり `scene3d:textured:<絵の読み方>`
- emission を差し替えた材質（点滅の mask を掛けるなど）は、名前を替えなくてよい。GL は材質のプログラムを spec と emission の中身の鍵
  （`ShaderGen.hashMaterial`・読む絵の名前は入れない）で引くので、名前が同じで木だけ違う材質が並んでも組み直さない。名前は知らせの文面と GL のプログラムの名前に
  出るだけ（替えるなら `Scene3d.withSpecName`）。毎コマ変わる数は木の `Const` に入れず、ShaderDoc の `param` + `Scene3d.withParams` で渡す（木の数が変わると組み直す）
- 材質の情報（alphaMode・alphaCutoff・doubleSided・絵の名前・emissive の値）は `part#gltfMaterial`。alphaMode と doubleSided は材質に当たる
  （下の「半透明と両面」）。Blender の書き出しは全部の材質を `doubleSided: true` にするので、片面で描きたい物（壁越しに部屋の中を覗かせる壁など）はゲームが材質の名前で選んで `withDoubleSided(false, ..)` に替える
- emissiveTexture を指しているのに読めない時（texCoord ≠ 0・画像が読めない・形に TEXCOORD_0 が無い）は光らせず、材質ごとに 1 行知らせる
- 絵の上限は `TextureLimits#baseColor`（emissive の絵も同じ色の絵）。`emissiveFactor` は emission の色（画面の値として読む）に、
  `KHR_materials_emissive_strength`（Blender の強さ 40 など）は線形の倍率として `emissionIntensity` に入る。spec の名前には factor だけが入る
  （強さだけ違う材質は同じプログラムを使う）。`Scene3d.withoutEmission` は `emissionIntensity` も 1 に戻す

## glb の頂点の色（COLOR_0・Blender でベイクした明るさ）

project.json に `"gltf": { "vertexColors": true }` を書くと、`Model3d.load` / `decode` が primitive の `COLOR_0` を頂点の色として読み、baseColorFactor と頂点ごとに掛けて
形の頂点の色にする。書かなければ COLOR_0 は読まない。絵つきの材質は「絵 × 頂点の色」なので、Blender で部屋の明るさを頂点の色にベイクした glb は、ベイクした明るさで描かれる（GL・WebGPU・CPU とも同じ式）。

```flix
// 読み込みの時に 1 回。PS1 の GPU と同じく頂点の色の 0.5 を 1 倍として扱う（0.5 より明るくベイクした所が絵より明るくなる）
// project.json に "gltf": { "vertexColors": true }
let model = Model3d.load(Model3d.loader(), "assets/room.glb") |> Result.map(Model3d.scaleVertexColors(2.0));
// ベイクした明るさだけで見せる場面: 環境光を白・光なし（かすみは掛かる）
{ environment = { ambient = Color.rgb(1.0, 1.0, 1.0), hemisphere = 0.0 | s#environment } | s }
```

- 読める形: `VEC3` と `VEC4`（α は読まない）。型: `FLOAT`・正規化した `UNSIGNED_BYTE`（÷255）・`UNSIGNED_SHORT`（÷65535）。ほかの型・正規化していない整数・
  数が頂点の数と違う・NaN は、COLOR_0 を使わずに読んで 1 行知らせる（形は描ける）
- 色の空間: glTF の決まりどおり線形の値として読み、0..1 に切ってから画面の値（sRGB の値）へ戻す（`Gltf.Internal.colorsOf`）
  - WhyNot（ベイクの道具が画面の値を書く時）: 決まりは線形。画面の値（sRGB の値）を線形に直さずに COLOR_0 へ書くと、読む時にもう一度画面の値へ戻すので、
    暗い所が持ち上がって明るく白っぽく出る（0.5 → 約 0.74）。書き出す前に線形へ直す（スクリプトで数を直に入れる時は sRGB → 線形の式を通す）
- 選ばなければ COLOR_0 は読まない（今までと同じ。baseColorFactor だけ）。`COLOR_0` の無い glb は選んでも baseColorFactor だけ
  - WhyNot（既定で読まない）: Blender の書き出しは頂点の色の層があると COLOR_0 を書くので、白でない COLOR_0 を持つ既存のゲームの glb の色が engine を上げただけで変わる
- `"gltf"` のほかの欄: `maxTextureSide`・`maxNormalSide` = 絵の大きさの上限・`pbr` = metallic・roughness も読む・`occlusion` = AO の絵も読む（欄の意味は `Gltf.LoadOptions`）
- `Model3d.scaleVertexColors(k, model)` = 形と全部の parts の頂点の色に k を掛ける（`Mesh3d.scaleColors`。既定の読み込みは 1 倍・中身の鍵も変わる）。
  今の色に掛けるので 2 回呼ぶと k × k 倍。k が NaN・負・無限の時は 1 として扱い、1 行知らせる。
  頂点の色の 1 を超える値はそのまま描き手へ渡り、絵 × 頂点の色の後に画面の値で切れる（PS1 の 2 倍の掛け算と同じ）
- WhyNot（Blender の見た目とのずれ）: 描き手は「絵 × 頂点の色」を画面の値どうしで掛け、その後で線形へ戻して光を掛ける。Blender は線形の値どうしで掛けるので、
  暗くベイクした所（頂点の色が 0.2 前後）は engine の方が少し明るく、絵の色の差も少し大きく見える。線形どうしで掛けると、絵つきの材質を使う今までの全部の glb の色が変わるので掛け方は変えていない。
  合わせるなら Blender の側でベイクした色を少し下げるか、`scaleVertexColors` で寄せる
- 材質の無い part（頂点の色だけの形）は頂点の色を線形へ戻してから光を掛ける。`scaleVertexColors(2.0)` の 1 を超える色は線形へ戻すと 2 倍より強く伸びる（2.0 → 約 4.95）
- gl-parity の `vertexColorTexture3d` が、絵 × 頂点の色（1 倍と 2 倍）の GL と CPU のそろいを見る（32 px・±1）

## 金属っぽさと粗さ（鏡面ハイライトと空の映り込み）

材質に metallic（0 で絶縁体・1 で金属）と roughness（0 で鏡・1 でざらざら）を付けると、点光源とスポットの鏡面ハイライトと、空の映り込みが足される
（Unity の Standard・Godot の StandardMaterial3D と同じ 2 つの値）。付けない材質は今までどおり拡散光だけで、絵も GL のプログラムも変わらない。

```flix
let gold = Scene3d.material(spec) |> Scene3d.withMetallicRoughness(1.0, 0.25)   // 値は 0..1 に丸める
let matte = Scene3d.withoutMetallicRoughness(gold)                                   // glb の材質を今までの絵に戻す時
Scene3d.metallicRoughnessOf(gold)                                                    // Option[{ metallic, roughness, texture }]
Scene3d.withMetallicRoughnessTexture("tex3d:orm", gold)                              // 絵で決める（B = metallic・G = roughness。値は絵に掛ける係数）
```

- **glb は使う時だけ読む**: project.json に `"gltf": { "pbr": true }` を書くと、`Model3d.load` / `decode` が、`pbrMetallicRoughness` があり
  `metallicFactor`・`roughnessFactor`・`metallicRoughnessTexture` のどれかが書いてある材質に付ける（書いていない値は glTF の既定の 1。Blender は metallic 1 の時に
  `metallicFactor` を書かないので、この扱いで合う）。`pbrMetallicRoughness` が無い材質と baseColor だけの材質には付けない（色だけの古い glb が全部金属に見えるのを避ける）。
  絵が無く emissive も無い材質も、付く時は頂点の色の材質（`gltf:vc`）になる。書かなければ読まない（材質・鍵・絵は今までと同じ。
  `part#gltfMaterial` の `metallic`・`roughness` の値だけ載る）。
  `pbr` が真の時は `baseColorFactor` と `emissiveFactor` を glTF の決まりどおり線形の値として読む（`baseColorTexture` の画素は今までどおり sRGB の絵）。
  // WhyNot: `pbr` が偽の時は線形として読まない — OBJ の Kd と同じく画面の値として読んでいて、変えると既存のゲームの色が変わる。`pbr` が真の時まで画面の値として読むと、
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
- **`"pbr": true` にするゲームの注意**: 上のとおり `None` だった part が材質を持つ。`None` を目印に part を束ねているなら、束ねる条件を `part#material` が `None` か
  spec の名前が `gltf:vc` の材質まで広げ、`Scene3d.metallicRoughnessOf` の値ごとに束ねる。鏡面が要らない材質は `Scene3d.withoutMetallicRoughness`
- やらない事: キューブマップ・反射プローブ・スクリーン空間の反射・異方性・クリアコート

### 材質の AO の絵（glTF の occlusionTexture）

隙間・角・くぼみの暗さを絵で持つ材質（glTF の `occlusionTexture`・Blender の Ambient Occlusion のベイク・ORM / ARM の絵の R）を、環境から来る光にだけ掛ける
（Unity の Occlusion Map・Godot の AO と同じ扱い）。

```flix
// project.json に "gltf": { "occlusion": true, "pbr": true }
let model = Model3d.load(Model3d.loader(), "assets/helmet.glb");     // 材質に AO が付く（part#gltfMaterial の occlusionTexture・occlusionStrength）
let m = Scene3d.texturedMaterial("tex3d:base", ShaderDoc.FilterMode.Linear)
    |> Scene3d.withMetallicRoughnessTexture("tex3d:arm")
    |> Scene3d.withOcclusionTexture("tex3d:arm", 1.0)                  // R = 光の届く割合・strength は 0..1
Scene3d.occlusionOf(m)                                                 // Option[{ texture, strength }]
```

- **既定は読まない**: `"occlusion"` を書かなければ AO の絵は decode もせず、材質・プログラム・絵は今までと 1 字も同じ。`pbr` と一緒に書く
- **掛かる所**: 環境の光（ambient・hemisphere・景色の拡散の光・lightmap にベイクした光）と映り込み（空・環境マップ）に `1 + strength × (R − 1)` を掛ける（glTF の勧め）。
  直接光（太陽・点光源・スポット）とその鏡面ハイライトには掛けない。SSAO（`ambientOcclusion`）とも重ねて掛かる（SSAO の後に掛ける）
- **lightmap と重ねる時の注意**: ベイクした光に AO が入っている（Blender の Combined のベイクなど）と、AO が 2 回効いて隅が暗くなりすぎる。その時は `occlusion` を入れない
- **metallic・roughness を持つ材質だけ**: AO の値は metallic・roughness の色の b で運ぶので、`withMetallicRoughness`・`withMetallicRoughnessTexture` の付いた材質だけが描く
  （`Scene3d.hasMaterialOcclusion`）。glb で metallic・roughness の付かない材質（`pbrMetallicRoughness` が無い・baseColor だけ）は AO の絵も読まない。
  Blender の書き出しはどの材質にも roughness を書くので、Blender の glb の材質はいつも描く側に入る。`withMetallicRoughnessShade` で色の場を書いた材質は AO を描かない
- **ARM / ORM の 1 枚**: AO と metallicRoughness が同じ画像なら、decode 1 回・sampler 1 つ・絵の読み 1 回（材質の絵の上限の 1 組）。別の画像なら 1 組増える
- **重さ**: AO の付いた材質は別のプログラム（`+occ`）。strength は params なので値だけ違う材質はプログラムを使い回す
- **読まない物**: occlusionTexture が TEXCOORD_1 を読む glb（AO を 2 本目の uv に置く書き出しは多い）は読まずに知らせる。TEXCOORD_0 の無い形にも AO を付けず 1 行知らせる。`"occlusion"` だけで `"pbr"` の無い project.json も読まずに 1 行知らせる
- **絵の上限を超えた材質**: 読む絵の組が上限（`Scene3d.maxMaterialTextures()`）を超えて AO の絵が落ちると、AO は `1 − strength` の暗さになる（知らせの行に書く）
- 3 つの描き手（GL・WebGPU・CPU）は同じ光の木（`LightModel3d` の変種 `materialOcclusion`）から作る

### glb の KHR_texture_transform

材質の index のある絵（baseColor・normal・emissive・metallicRoughness・occlusion）が全部同じ `KHR_texture_transform` で、実際に読む uv（transform の `texCoord` の上書き、無ければ textureInfo の `texCoord`）が全部 0 番なら、
読み込みの時に TEXCOORD_0 へ焼き込む（シェーダーは変えない）。回転の向きは KHR_texture_transform の README の行列（Khronos の TextureTransformTest で確かめた向き）。

- 絵ごとに違う transform・TEXCOORD_1 を読む transform は書き込まずに今までどおり読み飛ばし、1 行知らせる（uv は 1 本なので、どれか 1 枚の絵がずれる）
- project.json の旗は無い（読み飛ばすのは作者の置いた絵と違う絵を出す誤りで、`pbr`・`vertexColors` のような見た目の選択ではない）
- 回転のある・倍率が 0 以下の transform を書き込んだ形は、ファイルの `TANGENT` を使わず書き込んだ uv からタンジェントを求め直す（法線マップの傾く向きを合わせる）。ずらすだけ・正の倍率は `TANGENT` のまま
- 同じメッシュを別の transform の材質で使っても壊れない（primitive ごとに書き込む）

## 周りの景色を映す（環境マップと箱の補正）

空のグラデーション 3 色だけでは、鏡のような金属（クロム）が「のっぺりした球」になる。周りの景色のパノラマの絵を 1 枚渡すと、metallic と roughness を持つ材質の映り込みが
その絵を読む（Unity の Skybox（Panoramic）と Reflection Probe の Box Projection・Godot の PanoramaSkyMaterial と ReflectionProbe の box_projection に当たる）。

```flix
let env = Scene3d.environmentMap(panorama)                      // Texture3d の絵（正距円筒・横 2：縦 1）
            |> Scene3d.withEnvironmentIntensity(1.0)              // 線形の量に戻した後に掛ける倍率（0 で映り込み無し）
            |> Scene3d.withEnvironmentBox({ min = Vec3.v3(-4.0, 0.0, -4.0), max = Vec3.v3(4.0, 4.0, 4.0), center = Vec3.v3(0.0, 1.4, 2.0) })  // 室内だけ
{ environmentMap = Some(env), textures = panorama :: Nil | Scene3d.scene(camera, size) }   // 絵は textures にも載せる（"tex3d:" の名前）
```

- **絵の作り方**: 部屋の中の 1 点から全方向を、正距円筒（equirectangular）で描く（Blender は Cycles のカメラを Panoramic → Equirectangular）。
  映したくない物（映る側の球・銃）は隠して描く。PNG / JPEG は 8bit の sRGB の絵として読み、1 を超える明るさ（光る板・太陽）は 1 に頭打ちになる。
  **.hdr は 1 を超える明るさのまま読む**（`Texture3d.decodeHdr(bytes)`・Radiance の RGBE・half で持つ・段も half のまま CPU で作る）。EXR は読まないので
  `oiiotool in.exr -o out.hdr` か Blender で .hdr に替える。Blender・Poly Haven のパノラマは engine と左右が鏡なので、渡す前に左右を反転する
  （`oiiotool in.hdr --flop -o out.hdr`・Blender は Compositor の Flip X で書き出す）。half の絵は 1 画素 8 バイト（2048 × 1024 で段込み約 22 MB）。
  half の絵を材質の `Tex` で読むと 0（黒）で読んで 1 回知らせる（HDR の絵は環境マップと lightmap だけ）
- **向き**: 座標の約束（X = 東・Y = 上・Z = 北）のまま。向き d（長さ 1）の絵の座標は `u = 0.5 + atan2(d.x, −d.z) / 2π`・`v = 0.5 − asin(d.y) / π`
  （`LightModel3d.environmentUvOf`）。絵の真ん中が −Z・u = 0.75 が +X・u = 0.25 が −X・継ぎ目（u = 0 と 1）が +Z・上の行が真上
- **段**: roughness × (段の数 − 1) の段を、段どうしを混ぜて読む（`LightModel3d.environmentLodOf`）。roughness 0 の鏡は一番細かい絵・1 は 1 × 1 の平均。
  段は微分でなく roughness から決めるので、向きの継ぎ目（atan2 が 1 跳ぶ所）で段が跳ねて縦の筋が出ることは無い。
  絵は横も縦も Repeat で読む（横の継ぎ目は回り込んで混ざる。縦は真上・真下の 1 画素が反対の極と少し混ざる）
- **箱の補正**（`withEnvironmentBox`）: 無限に遠い景色として読むと、部屋の中の物が壁の近くでも景色の位置がずれない。箱があれば、点から跳ね返りの向きへ伸ばした線が
  箱の内側の面と交わる点を求め、`その点 − center` の向きで絵を読む（Unity の Box Projection と同じ）。center は絵を撮った点。
  部屋の中の物にだけ付ける（屋外の空には要らない）。点が箱の外にある時は、点から見た向きになる
- **映すもの**: metallic と roughness を持つ材質の映り込み（`Fresnel` を掛けた色）だけ。拡散の光（ambient と hemisphere）は変わらず（変えるのは次の節の `withSkyContribution`）、鏡面ハイライト（光源の映り）も今まで通り。
  環境マップの無い場面（`environmentMap = None`）は今までと同じ（空のグラデーションを映す・絵も GL のプログラムの字も同じ）
- **重さ**: 絵を 1 回読む（画素 × 1 回）と、箱があれば向きの計算が少し増える。環境マップの無い場面は何も増えない
- やらない事: エンジン自身で景色を撮る（反射プローブ・キューブマップ）・複数の環境マップの切り替えと混ぜ
- `Scene3dCmd` に欄 `environmentMap = Option[EnvironmentMap]` が増えた（`Scene3d.scene` は None）。場面のレコードを全部の欄で書いている所は `environmentMap = None` を足す
- **背景**（`Scene3d.withEnvironmentAsBackground(true, env)`）: 何も描かれない画素にも景色の絵を空として描く（屋外の景色の絵向き・室内の見本の部屋では使わない）。
  向きは画素の NDC を通る向き（空と同じ）・絵は段 0 で読み、強さも掛かる。`sky` があれば `sky` が勝つ（環境マップの背景は描かず、映り込みだけに使う）

## 環境マップから拡散の光（SH）

陰の中が灰色に平たい屋外の場面で、空の青と地面の照り返しの色を陰にも拾わせる。環境マップの絵から 2 次までの球面調和 9 個（SH）を求め、
拡散の光（ambient）をその光へ混ぜる（Godot の `ambient_light_sky_contribution`・Filament の `IndirectLight.irradiance`・three.js の `LightProbe` と同じ）。

```flix
let sky = Texture3d.decodeHdr(bytes)                               // .hdr（太陽の明るさまで SH に入る）か decodeUsing の画素を持つ絵
discard SphericalHarmonics.fromEquirectangular(sky);               // 読み込みで 1 回求めておく（初めて描くコマで止まらない）
let env = Scene3d.environmentMap(sky) |> Scene3d.withSkyContribution(1.0);
{ environmentMap = Some(env), environment = { hemisphere = 0.0 | base#environment } | base }   // hemisphere は 0（同じ空の光を 2 回足さない）
```

- **式**: 光 = ambient + (景色の拡散の光 × 環境マップの強さ − ambient) × k（k = `withSkyContribution`・0..1・既定 0）。hemisphere・点光源・スポット・太陽はそのまま足す。
  lightmap の面には足さない（ベイクした光が空の光を含む）。明るさ 1 の一様な景色で、拡散の光は ambient 1.0 と同じ明るさ
- **求め方**: 絵を 128 × 64 へ線形の量で縮めて足し込む（2048 × 1024 で 50〜150 ms）。絵ごとに 1 回だけ求め、2 回目からは控えを返す。
  環境マップは毎コマ作り直してよい（控えは絵の側にある）
- **外から渡す**: 前に求めた係数を持つ・空の色から作る時は `SphericalHarmonics.fromCoefficients(9 個の Vec3)` → `Scene3d.withIrradiance(sh, env)`（絵から求める物より先に使う）
- **向き**: 環境マップと同じ（Blender・Poly Haven のパノラマは左右を反転してから渡す。渡さないと東西の色が逆になる）
- **太陽を 2 回足さない**: 太陽を `DirectionalLight` で照らす場面では、.hdr のパノラマの太陽の円盤を頭打ちにしてから渡す（空の明るさの 99.9 % 点ほど・
  `oiiotool in.hdr --clamp:max=8 -o out.hdr` か書き出しの台本で）。円盤を残すと太陽の光が拡散の光にもう 1 回入り、影が持ち上がる
  （Bistro の通りで木の影の暗さ（影と日なたの比）が 0.70 → 0.78 に薄まり、頭打ち 8 で 0.70 に戻った）。映り込みの太陽の光りは `DirectionalLight` の鏡面が描く
- **知らせ**: 機種の側の絵で求められない時は ambient のまま描いて `@sky-irradiance-unavailable`・hemisphere も 0 より大きいと `@sky-irradiance-double`（どちらも 1 回）
- **重さ**: k > 0 の場面だけシェーダーの変種 `+sh`（uniform 28 個）。k = 0 の場面はプログラムの字も CPU の絵も今と同じ

## 頂点の色で地面の絵を混ぜる

Blender で頂点の色を塗った地面の glb を、土・草・石の絵に塗り分ける（Godot の地面の ShaderMaterial で COLOR を割合に使うのと同じ）。
形を色ごとに分けて材質を替えない。材質の Spec の中で、頂点の色を割合にして絵を混ぜる（project.json に `"gltf": { "vertexColors": true }`）。

```flix
let tex = (name: String, chan: ShaderDoc.TexChan) -> ShaderDoc.Field.Sampler({ filter = ShaderDoc.FilterMode.Linear, of = ShaderDoc.Field.Tex({ name = name, chan = chan }) });
let mix = (chan: ShaderDoc.TexChan) -> ShaderDoc.Field.Blend({ a = tex(dirt, chan), b = tex(grass, chan), by = ShaderDoc.Field.VertexColor({ chan = ShaderDoc.TexChan.G }) });
let ground = Scene3d.material({ name = "ground", cycleRate = 0.0, bindings = Nil,
                                out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = mix(ShaderDoc.TexChan.R), g = mix(ShaderDoc.TexChan.G), b = mix(ShaderDoc.TexChan.B) }),
                                                           alpha = ShaderDoc.Field.Const(1.0) }) })
    |> Scene3d.withMetallicRoughnessShade(ShaderDoc.Shade.Rgb({ r = ShaderDoc.Field.Const(0.0),
                                                               g = ShaderDoc.Field.Blend({ a = tex(dirtOrm, ShaderDoc.TexChan.G), b = tex(grassOrm, ShaderDoc.TexChan.G),
                                                                                           by = ShaderDoc.Field.VertexColor({ chan = ShaderDoc.TexChan.G }) }),
                                                               b = ShaderDoc.Field.Const(0.0) }))
```

- **metallic と roughness**: `Scene3d.withMetallicRoughnessShade(shade, m)` の shade の r = metallic・g = roughness（b は使わない）。
  `withMetallicRoughness`・`withMetallicRoughnessTexture` とは後に呼んだ物が勝つ（どれも同じ欄を書き替える）
- **3 枚**: `Blend` は入れ子にできる（R・G・B の割合で 3 枚）。絵の組は (名前, 補間) で数え、albedo 3 枚 + ORM 3 枚の 6 組が上限（`Scene3d.maxMaterialTextures()`）
- **高さで境目を尖らせる**: 高さは albedo の α に詰めて `Tex({ chan = A })` で読む（組の数が増えない）。式は `Smoothstep`・`Bin(Max)`・`Bin(Sub)` で書ける
- **割合の値**: engine は頂点の色（COLOR_0）を画面の値（sRGB）へ戻して持つので、線形 0.5 の割合は 0.735 として読む。線形の割合にそろえるなら `Pow({ p = 2.2 })` を挟む
- **混ぜる空間**: Spec の中の足し算は画面の値で混ぜる（Godot は線形）。境目の帯がわずかに明るくなる
- **法線マップ**: 材質に 1 枚だけで、割合では混ぜられない。(a) 付けない（地面は lightmap の陰影で足りる）・(b) 一番広い層の法線マップだけ付ける・(c) 外の道具で混ぜた法線マップを作る

## 描く量（視錐台の外を間引く）

### 物の置き方を選ぶ（instances / staticGroup / MultiMesh3d）

数が多い物は、次の質問の木で置き方を決める（葉 3 つ = 口 3 つ）。

1. **動くか** → 動かない → `Scene3d.staticGroup`（下の「動かない物をまとめる」。形が同じ物は描き手が 1 回の draw にまとめて持ち越す）
2. 動く → **同じ形と材質の物が 2,000 体以上か**（ブラウザの測りで MultiMesh3d が 1 コマ 1 ms 以上縮める境目） → いいえ → 場面の `instances`（1 体ずつ色・材質・名前・骨を変えられる）
3. はい → `MultiMesh3d.build`（下の「同じ形の動く物をたくさん」）

一部だけ動く物は、動く物を MultiMesh・残りを staticGroup に分ける。

| 口 | 目安 | 向かない物 |
|---|---|---|
| `instances` | 同じ形が 2,000 体未満・1 体ずつ違う物 | 同じ形の動く物が 2,000 体以上（`@same-shape-hint` が知らせる） |
| `staticGroup` | 動かない物（数の上限は無い） | 毎コマ動く物（毎コマ作り直しになる） |
| `MultiMesh3d` | 同じ形の動く物が 2,000 体以上（群れ・弾・草・雨・火の粉） | 1 体ずつ選ぶ・光らせる・材質を変える物（番号でしか呼べない）・透けて重なる大きな板（不透明で描く）・骨で動く物（バインドポーズで描く）・マップ全体に散らばった 1 つ（区画に分ける）・遠近で細かさ（LOD）を変えたい物 |

置き方を誤ると、描き手が場面の様子から 1 回だけ知らせる（どれも 120 場面続いたら・散らばりは 600 場面）:
`@static-group-hint`（置いた物が 2,000 超で staticGroup が無い → 動かないなら staticGroup・同じ形で動くなら MultiMesh3d）・
`@same-shape-hint`（instances に同じ形と材質の物が 2,000 体以上）・`@multimesh-spread-hint`（MultiMesh の境界が far の 2 倍超）・
半透明の材質と骨つきの形を MultiMesh3d に渡した時（初めて描くコマ）。

### 同じ形の動く物をたくさん（MultiMesh3d）

Godot の MultiMesh・three.js の InstancedMesh に当たる。形 1 つと i 体目の行列を返す関数を渡し、場面の `multiMeshes` に載せる。
GL と WebGPU は 1 体ずつの計画と詰めをせず、並びを直に上げて 1 回の instanced draw で描く（ブラウザで 1 万個の箱が 1 コマの CPU 20 ms → 5 ms・M4 Pro の Chrome）。

```flix
let fish = MultiMesh3d.build(fishMesh, n, i -> Mat4.mul(Mat4.translate(posOf(i)), Mat4.rotateY(yawOf(i))))
    |> MultiMesh3d.withMaterial(scales)               // 材質は全部の体で 1 つ
    |> MultiMesh3d.withColors(i -> teamColorOf(i));   // 頂点の色に掛ける（instances の withTint と同じ）
{ multiMeshes = fish :: Nil | Scene3d.scene(camera, size) }
```

- 毎コマ作り直してよい（参照が同じ値を続けて渡すコマは、描き手が詰めた並びを持ち越す。ポーズ中は詰めない）
- 群れ全体の境界で視錐台の外を間引く（1 体ずつは間引かない）。マップ全体に散らばる物（草・木）は区画（数十 m 角）ごとに分け、弾は届かない距離で消す
- 影は落とす（スポット・太陽・点光源。並びは 1 回だけ詰めて影の pass と共有する）。奥行きの書き出し（`Output.Depth`）にも書く
- 半透明の材質は不透明として描く（中の 1 体ずつを奥から手前に並べられないため。細い粒は cutout の材質にする）
- 骨の重みを持つ形はバインドポーズで描く（骨で動く物は instances に `withPose` で置く）
- 名前を持たない（F8 の注釈に出ない）・`Scene3dCheck.check` は見ない（当たりはゲームが持つ）
- 先に用意する時は、形を 1 つ置いた物を `App.preload3d(key, Scene3d.meshInstance(形, Mat4.identity()) |> Scene3d.withMaterial(材質) :: Nil)` に渡す
  （`MultiMesh3d.toInstances` は全部の体を作るので使わない）
- CPU の描き手（描き出し）は 1 体ずつに開いて描く（絵は instances に置いた時と同じ）

### 視錐台の外を間引く

GL・WebGPU・CPU の描き手は、場面のカメラの視錐台の外の置いた物とビルボードを描かない（ゲームは何も書かなくてよい）。
判定は外れる側に倒してある（画素を 1 つも出さない物だけを間引く）ので、絵は間引かない時と同じ。

- 骨つきの物（Pose で形が境界の外へ出うる）と頂点の無い形は間引かない。ビルボードは外接球で見る
- 影の地図は光の視錐台で別に間引く（目に見えない物も影は落とす）
- 間引いた物の形・絵・材質のプログラムは、今のコマで使った物として GPU に残す（振り向いても上げ直さない）
- 間引くのは視錐台の外だけ。壁の向こう（部屋ごとに描くか）はゲームが決める
- 効き目は `FrameDiagnostics.Diagnostics.scene3dCounts`（`instances` = 置いた物・`drawn` = そのうち描いた物）で見る
- 光や羽虫をゲームの側で間引く・数える時は `Camera3d.frustum(camera, aspect)` → `Frustum.intersectsSphere` / `intersectsBox`。
  場面と同じ判定は `Scene3d.frustumOf(scene)` + `Scene3d.isOutsideFrustum`・置いた物の world の境界は `Scene3d.worldBoundsOf`

### 動かない物をまとめる（staticGroup）

町の建物・木・家具のように動かない物が数千〜1 万個ある場面は、読み込みで 1 回 `Scene3d.staticGroup` で集まりを作り、毎コマ `groups` に載せる
（Unity の Static・Unreal の Mobility = Static に当たる）。中の物は `instances` に置いた時と同じ絵で描かれる。

```flix
// 読み込み: 鍵は集まりの中で重ならない名前にする（withoutItems が鍵で外す）
let town = Scene3d.staticGroup("town", buildings |> List.map(b -> (b#id, b#instance)));
// 毎コマ: Resources に持った同じ値を載せる
{ groups = res#town :: Nil, instances = movers | Scene3d.scene(camera, size) }
```

- 描き手は、同じ集まりが続くコマで計画と描く命令を持ち越す。同じ集まりかは、`staticGroup` で作った items の値そのもの・外した鍵・tint で見る
- **毎コマ `staticGroup` を呼ばない**（絵は同じだが毎コマ作り直しになって遅い）。集まりは Resources に持つ
- 中の 1 個だけ動かす・色を変える物は `Scene3d.withoutItems(鍵の Set, 集まり)` で外して `instances` に置く。外す物を変えたコマは持ち越しを作り直す（そのコマで全部作る）
- 読み込みの後に `staticGroup` で作り直した集まり（後から届いた束を足した階など）は、同じ名前の前の集まりを描き続けながら 1 コマ数 ms ずつ作り、作り終えたコマで替わる（作り直しで 1 コマが止まらない）。
  初めて描く集まり（前の物が無い）はそのコマで全部作るので、遊んでいる最中に初めて見せる集まりは先に払う
- 遠くを描かないなら、区画ごとの集まりに分けて載せ外しする
- 効き目: スマホのブラウザ（WebGPU）で 12,000 個が 1.6 fps → 60 fps（[performance.md](performance.md) の §12）
- 奥行きの書き出しの場面（`Output.Depth`。DoF・HeightFog・SceneDepth の Pass が描き直す場面）も持ち越す。色の場面とは別の行を控えるので、同じ集まりを両方で描くと控えは 2 つ
- 半透明の物と骨つきの物は持ち越さず、毎コマ instances と同じに計画する
- **集まりの中で 1 回しか使わない形は、GPU の描き手（GL・WebGPU）が 1 つの形につなぐ**（Unity の static batching に当たる。書き方は変えない）。
  glb の part（`Model3d.partInstances`。world を頂点に掛けた違う形）を数百個置いた部屋でも、draw call は「つなぐ単位の数 + 2 回以上使う形の数」まで減る
  （bench/scene3d の違う形 777 個・材質 20 種で 778 → 21）。2 回以上使う形は今までどおり同じ形をまとめて 1 回の instanced draw で描く
  - つなぐ単位: 材質の無い物は 1 つ（tint は頂点の色へ掛けておく）・材質のある物は材質の値（絵の名前・emissionIntensity を含む）と **tint** ごと。
    **集まりの中の絵つきの小物は tint を数種にそろえるとまとまる**（tint が物ごとに違うと 1 個ずつの draw に戻る）
  - つながない物: lightmap つき・骨の重みのある形・法線マップの材質・半透明。CPU の描き手（描き出し・gallery）はつながない（絵は同じ・`make gl-parity` の `staticBatch3d` と `staticBatchInstances3d`）
  - F8 の注釈が指す物の名前（`withName`）は、つないでも場面の値から引くので変わらない
  - 集まりの tint（`withGroupTint`）を毎コマ変えない。替えたコマは、材質の無い物の頂点の色を掛け直して形を上げ直す
  - 初めて描く集まりを 1 コマで作る時（前の控えが無い時）は、つなぐ分だけそのコマが延びる（違う形 777 個・17 万頂点で 100 → 110〜125 ms）。遊ぶ最中に初めて見せる集まりは engine が黒の間に先に作る（「動かない物の集まりを先に作る」）
- **影の地図も持ち越す**（Unity HDRP の cached shadow・Unreal の動く光の影の持ち越しと同じ形。書き方は変えない）。GPU の描き手（GL・WebGPU）は、影の地図ごと（太陽・スポットの地図 1 枚・点光源の atlas の面 1 つ）に
  集まりの物だけを描いた深度を控え、毎コマ控えを地図へ写してから、動く物（instances・MultiMesh・影を落とすビルボード）だけを上に描く。
  控えを描き直すのは光の行列か集まりが替わったコマだけ（点光源が動いた・太陽の向きを変えた・集まりを作り直した）。深度は小さい方が残るので絵は控えない時と同じ。
  CPU の描き手（描き出し）は控えない。効き目と描き直しの数は `scene3dCounts#shadowMapsReused`・`shadowMapsRedrawn`（[performance.md](performance.md) の §11）
- 置いた物が 2,000 個を超え groups の無い場面が約 2 秒（120 場面）続くと、1 回だけ「動かない物は staticGroup に」と知らせる
- 場面の draw call が 300 を超え、その半分超が形の違い（`batchBreaks#mesh`）で分かれた場面が約 2 秒（120 場面）続くと、1 回だけ「動かない物は staticGroup に・絵つきの小物は tint をそろえる」と知らせる
- **点光源の影と使う時は、集まりを区画（街区・部屋）ごとに分ける。** 持ち越した集まりの影の行は光の視錐台で間引かず、影を落とす灯り 1 本 × 面 6 つごとに集まりの全部の物を描く。
  町 1 つを 1 つの集まりにすると、街灯 4 本の影で 24 回町の全部を描く。灯りの届く区画だけの集まりなら、その区画の分だけで済む
- **材質は読み込みで 1 回作って持ち、毎コマ `Scene3d.material` を呼ばない。** 描き手は材質の値（参照）でまとめ描きの分け方を控えるので、毎コマ作った材質は控えに当たらず、物ごとに材質の中身を比べ直す
- `Scene3dCmd` を字で組み立てているゲームは `groups = Nil` を足す（`Scene3d.scene` は空）

### ビルボードの draw の数（同じ絵の板をまとめる）

GL と WebGPU の描き手は、`scene#billboards` の**来た順で続く同じ絵の板**を 1 回の instanced draw で描く（Unity の GPU Instancing・Godot の MultiMesh と同じ考え。ゲームは何も書かなくてよい）。
板ごとの位置・大きさ・anchor・tint・貼る範囲・光の当て方は instance の値で渡るので、まとまりを切らない。まとまりが切れるのは絵が替わった時だけ。

- 視錐台の外の板はまとまりを切らない（間の外の板を飛ばして前後がつながる）
- 来た順は崩さない。カメラを向く板はどの画素も同じ深度で、目からの奥行きが同じ板どうし（格子に並べた木の列）が重なると先に描いた方が勝つため、
  描き手が絵ごとに並べ替えると絵が変わる。**draw を減らしたいゲームは、同じ絵の板を続けて `billboards` に並べる**（森の木を絵ごとに出す・人を絵ごとに出す。
  重なる板の前後を来た順で決めている所は崩さない）
- 影の地図（太陽・点光源の 6 面）は深度だけなので、描き手が絵ごとに並べ替えてからまとめる（ゲームの並べ方に依らない）
- まとまりの数と絵の種類の数は `scene3dCounts#billboardRuns`・`billboardImages`（F3 の 3D の行の「billboard runs 100 / images 12」）。
  runs が images よりずっと多いなら、違う絵の板が交互に来ている
- 効き目は `drawCalls` の `billboard`・`shadowPass`（まとまり 1 つで 1）。bench/hd2d_town の立ち始め（WebGPU・1280×720）で 3D の draw 584 → 250・
  billboard 318 → 100・shadowPass 155 → 39（絵は 0 差）

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
- glb: 読み込み（`Model3d.load` / `decode`）は `alphaMode: BLEND` を `withAlphaBlend(true)`・`MASK` を `withCutout(true)`（`alphaCutoff` は 0.5 の固定。
  ほかの値は 1 回知らせる）にする。**`doubleSided` も材質のある部品にそのまま当てる**（材質の無い・頂点の色で描く部品は片面のまま。`"pbr": true` で metallic・roughness を読んだ頂点の色の材質（`gltf:vc`）は材質があるので両面になる）。
  Blender の書き出しは全部の材質を真にするので、閉じた形の裏は表に隠れて見えないが、部屋の外から壁越しに中を覗かせる作り
  （裏の面を描かないで中を見せる壁）は、その壁だけ片面に戻す:

  ```flix
  let m = part#material |> Option.map(mat ->
      if (part#gltfMaterial |> Option.exists(g -> String.startsWith(prefix = "cutaway_", g#name))) Scene3d.withDoubleSided(false, mat) else mat);
  ```
- 色の α は材質の spec の α（絵の α）。baseColorFactor の α は読まない（頂点の色に色だけ書き込んである）
- 半透明の物が 1 つも無い場面は、今までと 1 bit も同じ絵（描く順も GLSL の字も変わらない）

## デカール（壁・床に血・汚れ・弾痕・標示を貼る）

形を作り直さずに、壁・床・道の上へ薄い板（mesh decal）を貼る（Unreal の mesh decal・Bevy の ForwardDecal と同じ考え）。ゲームが見るのは 3 つ:

| API | いつ使うか |
|---|---|
| `Decal3d.Decal`（record） | 貼る材質・点・面の向き・大きさ・回り・atlas の矩形・角の上限・浮かせる量 |
| `Decal3d.decal(材質, 点, 面の向き)` | 既定値から作る（大きさは `{ size = … \| Decal3d.decal(…) }` で替える） |
| `Decal3d.buildInstances(デカールの列, 的の列)` | 的の三角形を箱で切って、板の置いた物の列を返す。**読み込みか当たった時に 1 回**呼び、結果を Resources に持って `instances` に足す |

```flix
// 読み込みで 1 回: 壁と床（staticGroup に入れる前の置いた物）に、1 枚の atlas から血と汚れを貼る
// atlas は読み込んだ絵（Texture3d）。名前は字で書かず Texture3d.name で引く（"tex3d:" の後ろは絵の中身の hash）
let blood = Scene3d.texturedMaterial(Texture3d.name(atlas), ShaderDoc.FilterMode.Linear);
let decals = { size = Vec3.v3(0.8, 0.8, 0.4), uvRect = { position = Vec2.v2(0.0, 0.0), size = Vec2.v2(0.5, 0.5) } | Decal3d.decal(blood, point, Vec3.v3(0.0, 0.0, -1.0)) }
    :: { rotation = 30.0, uvRect = { position = Vec2.v2(0.5, 0.0), size = Vec2.v2(0.5, 0.5) } | Decal3d.decal(blood, floorPoint, Vec3.v3(0.0, 1.0, 0.0)) } :: Nil;
let plates = Decal3d.buildInstances(decals, wallsAndFloor);   // Resources に持つ
// 毎コマ: 板を instances に足し、絵を場面の textures に載せる（載せない名前は 0 で読まれ、半透明の板は消える）
{ instances = wallsAndFloor ::: plates, textures = atlas :: Nil | Scene3d.scene(camera, size) }
// 撃った所: Ray3d の RayHit の点と面の向きをそのまま渡し、当たった時に 1 枚ずつ作って控えに足す
let hole = Ray3d.pickNearest(ray, 50.0, targets) |> Option.map(match (_, hit) -> Decal3d.decal(bulletHole, hit#point, hit#normal));
```

- 箱は `center` から `−normal` の向きへ投げ、奥行き（`size#z`）の半分ずつ前後へ延びる。`angleCutoff`（度）を超えて斜めの面には貼らない
  （床に投げた血が壁を這い上がらない）。板は面の向きへ `offset`（既定は幅と高さの短い方の 1%・場面の長さ）だけ浮かせる
- 板は (的, 材質) ごとに world の座標の 1 つの形へつなぎ、形の中はデカールの列の順（**列の後ろが上**）。名前は `<的の名前>:decal`。
  **重ねる物は同じ材質（atlas の `uvRect`）にまとめる** — 違う材質の板どうしは物の境界の真ん中で並ぶので、歩くと前後が入れ替わりうる
- `blend` も `cutout` も偽の材質は半透明にする（不透明の板は下の面と奥行きを奪い合う）。cutout の板は不透明の物と一緒に描くので
  `staticGroup` に入れてよい。半透明の板は staticGroup でまとまらないので `instances` へ
- 骨つきの的と半透明の的には貼らずに 1 行言う（動く物に貼るのは範囲の外）。大きな 1 枚の床は、板の形も大きくなってほかの半透明の物との並びが
  崩れやすいので、的を部屋・区画ごとの part に分けておく
- 重さは「箱が掛かる的の三角形の数 × デカールの数」（10 万三角形の的に 1 枚で JVM 約 3.7 ms）。**毎コマ呼ばない**
- 板は的の tint・頂点の色・lightmap（uv2 に的の矩形を掛けた物）を写すので、ベイクした明るさの壁に貼っても同じ明るさに見える。
  材質の無い的（頂点の色だけ）に絵つきの板を貼ると、頂点の色を線形へ戻す前に掛けるぶん板の方が少し明るく見える
- 半透明の板も **画面の上の SSAO を受ける**（ほかの半透明の物は受けない。板は真下の不透明な面に貼りつくので、mask の値がちょうどその面の値）。
  隅の暗がりの上の血だけが明るく浮かない
- ブラウザ版: SSAO を掛ける場面の板は材質の版の鍵 `+ab` を使う。PC で遊んで `web/shader-variants.json` に記録してから書き出す
  （記録に無い鍵は頂点の色で描かれる。「[ブラウザ版のシェーダー](#ブラウザ版のシェーダー書き出しの時に作る)」）
- gl-parity の `decal3d`（壁と床の角・atlas の 3 枚・頂点の色の的・lightmap の的・cutout の板）と `decalAmbientOcclusion3d`（SSAO の隅の上の板）で
  GL と CPU の違う画素の数を見る

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

## 画面の歪み（熱のゆらぎ・水の中・魔法）

火山の陽炎のように、時間で流れるノイズで画面の絵を読む位置をずらす。PostStack の欄の 1 つで、3D の場面にも 2D の View にも掛かる（HUD には掛からない）:

```flix
App.withPostStack(w -> PostStack.preset(PostStack.Preset.DuskOutdoor)
    |> PostStack.withDistortion(Some({ mask = PostStack.DistortionMask.BottomBand({ top = 0.5, soft = 0.3 }) | PostStack.distortion() }))
    |> PostStack.withTime(Clock.nowOf(w#playClock)))
```

- `strength` = ずらす最大の量（design の px・x と y 別）・`noiseSize` = ノイズの粒（design の px・縦横比を直した丸い粒）・
  `speed` = 模様が流れる速さ（px / 秒・y は下が +。陽炎は上へ流すので負）
- `mask`: `Full`（画面全体）・`BottomBand({ top, soft })`（上から top で 0、top + soft で 1。地面から立つ陽炎）・`Texture(名前)`（project.json の絵か Pass の r を重みに。
  画面いっぱいに引き伸ばして読む。無い名前は歪まない）
- 時刻は `withTime` で渡す（渡さなければ止まった模様）。遊びの時計を渡せばポーズで止まり、描き出しは決まった時刻で同じ絵になる
- 毎コマ動かしてよいのは `strength` と時刻（Param で渡る。溶岩に近づくほど強める、など）。`noiseSize`・`mask` を動かすと描き手が program を作り直す
- 掛かる順は後がけの一番先（自分の BeforeBloom の Pass の後・奥行きのぼかしとブルームの前）。ぼかしの奥行きの絵は歪めないので、ぼけの縁が strength px ほどずれる
- `strength` が x・y とも 0 か `noiseSize` ≤ 0 なら Pass を足さない（使わない時の絵と DrawHash は前と同じ）
- 3 つの描き手（GL・WebGPU・CPU）は同じ Spec を読む（新しい式は無い）。揺らぎの模様は向きと長さの違う波を 4 本ずつ重ねた物で、hash のノイズ（Fbm）を使わないので
  GPU の float32 と CPU の Float64 でも同じ模様になる（bench/scene3d の部屋で GL・WebGPU・CPU の絵の PSNR は 61〜67 dB。歪みなしの描き手どうしの差は 60 dB）。
  流した位相は CPU で 2π に折り返して渡すので、長く遊んでも崩れない
- 重さ: 960×540 の窓（M4 Pro・GL の GPU 時間の query）で後がけ全体が 0.71〜0.77 ms → 0.78〜0.86 ms（+0.1 ms ほど）。スマホは【未測定】
- 確かめの入口: bench/scene3d の `make haze-video`（`FGE_GPU=on` で GL・`FGE_PNG_PAINTER=webgpu` で WebGPU・`FGE_GPU=off` で CPU）・`make run POST=haze`
- 値は post.json の `distortion` でも書ける（schema は [post.schema.json](post.schema.json)）
- Unity の Lens Distortion（樽型の歪み）とは別物。Unreal・Unity HDRP の Distortion（読む位置をずらす屈折）と同じ系統

## 地面を這う霧（高さの霧・街灯のにじみ）

夜の町の低い霧。地面の近くほど濃く、遠いほど濃くなり、むらがゆっくり流れ、点光源のまわりの霧が明るくなる。PostStack の欄の 1 つ:

```flix
App.withPostStack(w -> PostStack.preset(PostStack.Preset.NightOutdoor)
    |> PostStack.withHeightFog(Some({ color = Color.rgb(0.42, 0.46, 0.56), density = 0.05, heightFalloff = 0.15, maxOpacity = 0.92,
                                      noise = Some({ size = 40.0, amount = 0.6, speed = { x = 10.0, y = 4.0 } | PostStack.fogNoise() }), lightGlow = 0.5
                                      | PostStack.heightFog() }))
    |> PostStack.withTime(Clock.nowOf(w#playClock)))
```

効果の値は既定値の関数から欄を書き替えて作る（`PostStack.bloom()`・`vignette()`・`colorGrade()`・`distortion()`・`heightFog()`・`fogNoise()`。
post.json で効果の欄を書いた時の出発点も同じ値）。字で全部の欄を書かないので、欄が増えても書き直さなくてよい。

- 式は Unreal の Exponential Height Fog と同じ（名前もそろえた）: 高さ y の濃さ = `density × e^(−heightFalloff × (y − baseHeight))`。目から面までその濃さを積み、
  `1 − e^(−積んだ量)` だけ `color` に寄せる（`maxOpacity` で上限）。`startDistance` までは積まない
- 長さは Scene3d の場面の長さ（Blender の 1 m を 16 にした場面なら、地面から 0.4 m で e 分の 1 に薄くするには `heightFalloff = 1 / (0.4 × 16)`）
- `noise`: むらの大きさ（場面の長さ）・揺らす割合・流れる速さ（x と z）。遠くでは細かい波がちらつかないよう、粒の 24 倍の距離で消える
- `lightGlow`: 場面の `pointLights` の目に近い 8 つのまわりの霧を明るくする（届く距離の 0.2 倍を画面へ写した半径のにじみ・灯りの高さの霧の濃さで強さが決まる・
  灯りより手前に面があればにじまない・目の前の灯りを先に選ぶ）。Unreal の体積の霧（Volumetric Fog）の光の散らしの、安い代わり
- 3D の場面の奥行きの絵（目からの距離・窓の画素）を PostStack が作って読む。奥行きの絵のために場面がもう 1 回描かれる（bench/scene3d の部屋で draw call 10 → 20）。奥行きのぼかし（`withDepthOfField`）と同じ奥行きの絵を使うので、両方掛けても 1 回。DoF が `DepthBand` の時だけ、霧は目からの距離の絵をもう 1 回描く。
  奥行きの絵に入らない半透明の物はその奥の面の霧が掛かる。3D の場面の矩形の中の 2D の絵は、その下の 3D の奥行きで霧が掛かる（字の窓は `App.withHudView` に置く）。矩形の外には掛からない
- 何も描かれない空の画素は camera の far まで積む（Unreal と同じく地平の近くの空が霧の色に染まる）。far を大きくすると空が霧の色ばかりになる
- 掛かる順は後がけの一番先（自分の BeforeBloom の後・画面の歪みの前）。霧の中の明るい灯りにもブルームが掛かる
- 毎コマ動かしてよいのは色・濃さ・高さの落ち方・`startDistance`・`maxOpacity`・`noise.amount`・`lightGlow` とカメラと灯り（Param で渡る）。`noise.size` を動かすと program を作り直す
- `density` か `maxOpacity` が 0 以下なら Pass を足さない（使わない時の絵と DrawHash は前と同じ）
- 3 つの描き手は同じ Spec を読む（e^x は `(1 + x/32)^−32` で近づける・むらは歪みと同じ波の和）。bench/scene3d の部屋で GL・WebGPU・CPU の絵の PSNR は 59〜66 dB（霧なしの描き手どうしの差と同じ）
- 重さ: 960×540（M4 Pro・GL）で GPU +0.04〜0.09 ms・1 コマの CPU +0.3〜0.5 ms（奥行きの絵の分）。スマホは【未測定】
- 確かめの入口: bench/scene3d の `make haze-video LOOK=fog`・`make run POST=fog`
- 材質の式の中の霧（`Environment3d.fog` の DistanceFog）とは別物で、両方掛けてもよい（DistanceFog は物ごと・HeightFog は画面全体の後がけ）

### 明るい所へ入った直後の白飛び（ExposureAdaptation）

```flix
// World に ev を持つ。dt は実時間（ポーズ中も目は慣れる）。
let ev = ExposureAdaptation.step(ExposureAdaptation.defaults(), dt, ExposureAdaptation.evOf(placeBrightness), w#ev);
PostStack.withExposure(ExposureAdaptation.computeExposure(ExposureAdaptation.defaults(), ev), stack)
```

- 絵を測らない（ゲームが場所ごとの狙いの明るさを持つ）。3 つの描き手と描き出しで同じ値。明るくなる時は `speedUp`（既定 3/秒）、暗くなる時は `speedDown`（1/秒）で寄る
- 露出はブルームの後に掛かるので、白飛びの間もブルームが光り始める明るさは変わらない

## 画面の上の技（SSAO）

家具の足元・部屋の隅・物の接する所を暗くする（Godot の Environment の SSAO・Unity URP の SSAO と同じ物）。PostStack の欄の 1 つ:

```flix
App.withPostStack(w -> PostStack.preset(PostStack.Preset.NightOutdoor)
    |> PostStack.withAmbientOcclusion(Some({ radius = 0.5, intensity = 2.0 | PostStack.ambientOcclusion() })))
```

post.json なら `"ambientOcclusion": { "radius": 0.5 }`（null で外す）。値は `ScreenEffects3d.AmbientOcclusion`（PostStack.AmbientOcclusion は同じ型）:

- `radius`（m）・`thickness`（m・これより離れた点は数えない）は場面の `unitsPerMeter` を掛けて使う。`intensity`・`power` で暗さ、`taps`（4〜16）で 1 画素の点の数、
  `scale`（0.25〜1）で mask の解像度、`lightAffect`（0..1）で直接光（点光源・スポット・太陽）にも掛ける割合
- 掛かるのは環境の光（ambient・hemisphere・景色の拡散の光）と lightmap にベイクした光。環境マップの映り込みと半透明の物には掛からない（デカールの板だけは半透明でも受ける。「[デカール](#デカール壁床に血汚れ弾痕標示を貼る)」）
- PostStack が場面の色より先に奥行きを R32Float の Pass（`ps_depth_far`・目からの距離 / far の面の遠い隅までの距離）へ描き、3D の描き手が場面の色を描く前に
  mask → 横のぼかし → 縦のぼかしを描いて、材質の frag が画面の位置で読む。霧と Physical の奥行きのぼかしも同じ 1 枚を読む（場面を 3 回描かない）
- View の絵の一番大きい 3D の場面 1 つにだけ掛かり、`Resolution.Native` の場面だけ（Design の場面は掛けずに `Issue.AmbientOcclusionNeedsNative`）
- `PostStack.withDebugView(PostStack.DebugView.AmbientOcclusion)` で mask だけを灰色で見る（白 = 暗くしない）
- 3 つの描き手: GPU（GL・WebGPU）は render_gl の `Render3d.ScreenPasses` の AST・CPU は `SoftRaster3d.ScreenEffects` の同じ式の Flix。式と表の値は `ScreenEffects3d` の頭。
  gl-parity の `ambientOcclusionMask3d`（mask だけ）・`ambientOcclusion3d` と、霧・奥行きのぼかしとの組 3 つで違う画素の数を見る
- R32Float の Pass を作れない WebGL2（`EXT_color_buffer_float` が無い）は技を切って `@screen-effects-no-float-target` を 1 回知らせる
- 重さ: 奥行きの場面の draw が 1 回増え（霧かぼかしがあれば増えない）、mask の 3 回の全画面の三角形が増える（docs/performance.md）。Low の画質は mask を半分・6 点に抑える

## PS1 風の描き方（色の丸めとディザ・頂点の揺れ・アフィンの uv）

PSX 風シェーダーの界隈の手を、場面ごとに選んで掛ける（`Scene3d.withPsx`）。どれも既定は切で、切っている時は今までと同じプログラムと同じ絵になる。

```flix
// 15 ビットの色 + PS1 の表のディザ（まずはこれだけ）
{ resolution = Scene3d.Resolution.Design | Scene3d.scene(camera, size) } |> Scene3d.withPsx({ colorDepth = 5 | Scene3d.psxOff() })
// 頂点の揺れと弱いアフィンも足す
|> Scene3d.withPsx({ colorDepth = 5, vertexSnap = 1.0, affineTextureMapping = 0.35 | Scene3d.psxOff() })
// PS1 の GPU に近い値（大きな床と壁は流れが強い）
|> Scene3d.withPsx(Scene3d.psxPreset())
```

| 欄 | 値 | 効き方 |
|---|---|---|
| `colorDepth` | 0（切る）・1〜8（PS1 は 5） | 色の 1 成分を何ビットに丸めるか。5 で 15 ビットの色 |
| `dither` | `Psx`（既定）・`Bayer4x4`・`Off` | 丸める前に足すディザの表（4×4 の格子）。`Psx` は PS1 の GPU の表（8 bit の値に −4〜3） |
| `ditherStrength` | 0 以上（既定 1） | ディザの量に掛ける数。0 でディザなし |
| `vertexSnap` | 0（切る）・格子の画素（1 = 1 画素） | 投影した頂点の x・y を描き先の画素の格子に丸める。2 で 2 画素の格子（揺れが大きい）。奥行きは丸めない |
| `affineTextureMapping` | 0（遠近の補正どおり）〜 1（アフィン） | 材質の uv を画面の上でまっすぐつなぐ割合。間は 2 つの uv を混ぜる |

- **格子は場面の描き先の画素**。`Resolution.Design` の場面なら design の画素（320×240 で描いて拡げるなら 320×240 の画素）にそろうので、拡げた後もディザの粒と頂点の揺れが大きな画素のまま見える。
  `Native` の場面は窓の画素（場面の矩形の左上が格子の原点）
- 色の式（3 つの描き手が同じ式・`Scene3d.Psx.quantize`）: 画面の値の色を 8 bit の値 `v = floor(c × 255 + 0.5)` にし、ディザの量 × 2^(8 − bits) を足して 0..255 に切り、
  2^(8 − bits) で割って切り捨てた段 q を `q ÷ (2^bits − 1)` へ戻す。丸めるのは 3D の色を作った直後（emission・かすみの後）で、半透明の物は丸めた色を下に重ねる
- 掛かる物: 置いた物（頂点の色・材質・骨つき・staticGroup で持ち越した物）・ビルボード（角も丸める）。アフィンは材質の 1 本目の uv だけ（lightmap の 2 本目の uv は遠近の補正のまま）
- 掛からない物: 空（`sky`）と地の色（`background`）・奥行きの書き出し（`Output.Depth`。DoF と HeightFog が読む奥行きの絵は丸めない頂点で描く）・影の地図・2D・PostStack の後がけ
- **頂点の揺れは T 字の継ぎ目に隙間を開ける**（辺の途中に別の面の頂点が乗る所。タイルを別々の面で並べた壁・天井と壁の境）。地の色が透けて黒い線になる。PS1 と同じ壊れ方で、
  気になる所は面を共有の頂点でつなぐか、地の色を壁の色に寄せるか、`vertexSnap` を切る
- **アフィンは大きな面ほど強く流れる**（1 枚の床や壁の三角形が画面の大半を覆うと、模様が対角線で折れる）。0.2〜0.4 の弱めから。PS1 のゲームは大きな面を細かく割っていた（割るのはゲームの側の形）
- 1 を超える明るさは丸める時に 1 に切れる（HDR の Pass に描いても、丸めた場面の emission はブルームの元にならない）
- 霧は今の `Environment3d.fog`（DistanceFog）で足りる: 色を黒にすると目から near〜far で黒へまっすぐ溶ける（PS1 の depth cue と同じ形）。far より先は真っ黒で描かれる
  （描く量を減らすなら camera の `far` も縮める）。emission は霧に沈まない（非常口の灯りは遠くでも光る）。地の色を黒にすると継ぎ目がそろう
- 入れていない物: Z バッファを外して奥から塗る形（ordering table）・テクスチャの色数を減らす CLUT・GTE の固定小数点の精度落ち・頂点ごとの光（グーロー。下の「見送った物」）

### テレビのにじみ（CRT・コンポジット映像）

PS1 の頃はテレビに映していたので、画素の境目とディザの網目が横ににじんで柔らかく見えた。PostStack の欄の 1 つで、仕上がりの一番後（FXAA の後）に掛かる:

```flix
App.withPostStack(_ -> PostStack.preset(PostStack.Preset.Neutral)
    |> PostStack.withCrt(Some({ compositeBlur = 1.5, scanlines = 0.3, chromaBleed = 1.5 | PostStack.crt() })))
```

- `compositeBlur` = 横だけのぼかしの半径（design の px。1〜2 でコンポジットの帯域の狭さ。縦はにじませない）。横の 5 点（重み 1・4・6・4・1）を Linear で読む
- `scanlines` = 走査線の濃さ（0..1。design の画素の行の境目を `1 − scanlines` まで暗くする。平均の明るさは `scanlines ÷ 2` だけ下がる）。
  窓の画素で読むので、窓が design の 2 倍以上の時だけ見える（gl-parity の 320×180 の窓では効かない）
- `chromaBleed` = 色の信号だけを足す横のにじみ（design の px）。明るさ（Rec.601 の重み）は `compositeBlur` の半径のまま、色（rgb − 明るさ）を `compositeBlur + chromaBleed` の半径で広げる
- PS1 風の色の丸めとディザ（`Scene3d.withPsx`）は場面の中で掛かるので、にじみはその後: ディザの網目が横に溶けて中間色に見える
- 掛かる範囲は View の絵の全部（2D も）。HUD（`App.withHudView`）には掛からない（字幕をにじませたくなければ HUD に置く）
- どれも 0 以下なら Pass を足さない（使わない時の絵は前と同じ）。`Neutral` の preset だけで掛ける時も、場面を Pass へ描いて写し直す分だけ絵が変わりうるので、
  にじみを使わないゲームは `App.withPostStack` を付けない
- 3 つの描き手は同じ Spec を読む（新しい式は無い・`PostStack.Internal.Crt`）。bench/scene3d の部屋（`make psx-video LOOK=crt`・960×540）の PSNR: GL と CPU 51.6 dB・WebGPU と GL 67.8 dB・WebGPU と CPU 51.7 dB。
  gl-parity の `postStackCrt`（54 px・元の psxBox3d の縁の割れを横のぼかしが広げた物）
- 値は post.json の `crt` でも書ける（schema は [post.schema.json](post.schema.json)）
- 重さ: 本編の面を ps_post へ描いて、画面へ 15 回（横の 5 点 × r・g・b。chromaBleed があれば 30 回）読む面を 1 枚

### 3 つの描き手の違い

GL・WebGPU・CPU は同じ式を書く（GLSL の `r3d_colorDepth`・`r3d_vertexSnap`・WGSL の同じ名前・CPU の `SoftRaster3d.Psx` の `quantized`・`snapVertex`・`affineUv`）。
変種は Unity の shader variant と同じ考えで、場面の psx が `Scene3d.Psx.isOn` の時だけ `+psx` のプログラムを組む（既定の変種（`+ps`・`+pu`・`+psx` のどれも無い場面）の GLSL・WGSL の字は変わらない。`+ps`・`+pu` の WGSL は `R3dLight` の欄が 1 つ増える）。

- 色の丸めは 8 bit の ±1 の差を段の境目で 1 段（5 ビットで ±8）に広げる。頂点の丸めは Float32 と Float64 の丸めが格子の真ん中に落ちた頂点を 1 画素ずらす（縁の 1 列が割れる）
- アフィンの uv: GPU は `noperspective`（WGSL は `@interpolate(linear)`）の補間、CPU は画面の上の重みでつなぐ。手前の面（near）で切った三角形は、GPU の切り方と CPU の切り方（clip 空間でつなぐ）が違い、
  切った所の近くの uv がずれる。Nearest の絵の texel の境が画面の上で長い斜めの線になり、その線の上の画素が隣の texel を読む
- 門の許す差: `make gl-parity` の `psxFloor3d`（アフィン 1 の床・800 px）・`psxBox3d`（Design・staticGroup・ビルボード・20 px）・`psxSkin3d`（骨つき・60 px）。
  bench/scene3d の部屋（`make psx-video`・Design 320×180・960×540 に拡げた絵）の PSNR: 切った時の GL と CPU 50.3 dB・`dither` 49.8 dB・`full` 45.5 dB。WebGPU と GL は切った時 94.5 dB・`full` 61.5 dB

### 重さ

- GL（M4 Pro）の部屋（Design 320×180・16 物・11 draw）で GPU の時間 0.19 ms → 0.20 ms。1 コマの CPU は変わらない（uniform 3 つ）。スマホと Native の大きな窓は【未測定】
- CPU の描き手（bench/scene3d の `make cpu-time`・960×540・`FGE_SOFT_SERIAL=1`・M4 Pro）の切った部屋: 入れる前 中央値 165〜166 ms → 入れた後 166〜167 ms（揺れの幅 ±2 ms の中）。切った場面は頂点の欄が 2 つ（u × w・v × w。中身は 0）増えるだけで、画素ごとの丸めとアフィンの計算は通らない
- 変種の分だけプログラムが増える（場面に初めて `+psx` が出た時に組む）。遊びの途中で初めて出すなら `App.withPreload3d` の `variants` に `Scene3d.preloadVariantOf(その場面)` を渡す

### 確かめの入口

- bench/scene3d: `make psx-video LOOK=off|dither|full`（`FGE_GPU=on` で GL・`FGE_PNG_PAINTER=webgpu` で WebGPU・`FGE_GPU=off` で CPU）・`make run PSX=off|dither|full`（重さ）
- `make gl-parity` の `psx*` の 3 場面

### 見送った物（頂点ごとの光）

頂点ごとに光を計算して面の中をつなぐ形（グーロー）は入れていない。光の式の木（`LightModel3d`）は今は frag で 1 回評価する前提で、頂点の段で評価するには
影の地図の読み（PCF）・点光源の影・lightmap・法線マップの入力を頂点の段に持ち込むか、それらを外した木を別に作ることになり、GLSL・WGSL・CPU の 3 か所で頂点の出口を足す。
大きな面では懐中電灯の丸い光が出ない（三角形の頂点にしか光が乗らない）ので、懐中電灯を主役にする場面では使いにくい。入れるなら
`LightModel3d.Codegen` に頂点の段へ出す口（`toGlslVertex`）を足し、影を引かない光だけの木（`lightingModelFor` の影なしの変種）を頂点で評価して `vLight` で frag へ渡す形が近い。

## ブラウザ版のシェーダー（書き出しの時に作る）

3D の描き手はシェーダーの字を鍵（`Render3d.ShaderSourceKey`）で引く（`Render3d.ShaderSourceProvider`）。PC は `Render3dShaders.makeRuntimeProvider` がその場で木から作り、
ブラウザは書き出し（`bin/fge export-web`）の時に `tools/shader-bake` が記録（`web/shader-variants.json`）から作って wasm に埋めた表を引く。ゲームの側の手順は [web-export.md](web-export.md) の「3D のシェーダーの記録」。

- 材質の frag は部品の所が空いた字（`Render3dGlsl.materialFragmentTemplate`）を作っておき、描き手が ShaderGen の字を `Render3d.ShaderLibrary.withMaterialPart` で入れる。
  cutout の α は名前・呼び出しの形（`ShaderText.isAtomText`）だけを受ける（ShaderGen のテストが止める）
- **新しい pass のシェーダーは `ShaderSourceKey` に case を足し、`makeRuntimeProvider` の match と `Render3d.ShaderLibrary.requiredKeysOf` の広げ方に足す。**
  描き手から `Render3dGlsl`・`Render3dWgsl` の字の関数や `ShaderAst.Glsl`・`ShaderAst.Wgsl` の print を直に呼ばない（lint-forbid の `render3d-shader-source-direct`）。
  漏れは make web-load-check が wasm の中の字を作るコードの関数の数（0 本のはず）で止める
- 既定の一式（既定の変種の頂点の色とビルボード・空・奥行き・blit・置いた物の頂点・ビルボードの影）が表に無いのは `bug!`。
  記録に依る鍵（既定でない変種・材質の形・+ao の pass）が無い時は描かずに鍵ごとに 1 回知らせる
- デカールの板（SSAO を受ける半透明の材質）は +ao の場面でだけ材質の版の鍵に `+ab` が付き、記録の形の行に `"screenAoOnBlend": true` が出る（偽の欄は書かない）

## 場面の絵の予算

場面の絵（Texture3d）を GPU に持つ量は 256 MB・64 枚まで（project.json の `scene3dTextureBudgetMB`・`scene3dTextureBudgetCount`）。
超えた時の縮め方は [lightmap.md](lightmap.md) の「場面の絵の予算」。

## 初めて出る物を先に上げる

`App.withPreload3d({ textures = .., variants = .. | App.preload3d(key, instances) })` は、遊びの途中で初めて出る物の形・絵・材質のプログラムを GPU へ上げる。`key` と `variants` は毎コマ読み、`instances` と `textures` は `key` か `variants` が変わった時と Doc の読み直しの時だけ読む。3D の場面が 1 つも出ていないタイトルの間でも上がる。

- `variants` = 既定の版に足して組むシェーダーの変種。点光源の影（`withPointShadows`）か `Physical` の光の場面を出すなら `Scene3d.preloadVariantOf(その場面)` を渡す（`+ps`・`+pu` の材質と頂点の色のプログラムも先に組む）。空なら既定の版だけ

- 描かないので、置く場所は何でもよい。骨つきの物は姿勢を付けたまま渡すと、骨つきの版のプログラムも組める。
- `Instance3d` は `tex3d:` の絵の名前しか持たないので、中身は `textures` で渡す（無い絵は 1 回知らせる）。描く時は今まで通り場面の `textures` にも載せる。
- `key` には中身を決める入力だけを入れる。300 コマの内に 30 回変わると、組み直してばかりだと知らせる。
- 上げた形と絵は、置き場の上限でほかの物より後に捨てる。足りなければそれらも捨てて 1 回知らせる。材質のプログラムは捨てない。

### 動かない物の集まりを先に作る（engine が自動で暗転する）

`staticGroup` の集まりは、初めて描くコマに計画・形の作成・材質のプログラムをまとめて払う（遊んでいる最中に初めて見せると、そのコマが数十 ms 止まる）。
**ゲームは何も書かなくてよい。** engine が毎コマ View の答えに載った `staticGroup` を名前で集め、まだ作り終えていない名前があれば、
描き手に 1 コマ約 8 ms ずつ先に作らせ、済むまでその集まりを場面（本編と Pass・`Clipped` の中も）から外して design 全体を黒で覆う。

| 間 | 画面 |
|---|---|
| 作っている（描き手が返した進み具合が済んでいない） | その集まりを外した場面と 2D を描き、上に黒（z は `ZBand.autoPreloadCover()`。HUD より手前・待ちの表示より奥・余りの letterbox には出さない） |
| 黒だった次のコマで済んだ | 集まりを載せて描き、黒はこのコマまで残す（明けた後の初めてのコマの draw の仕事を黒の下で済ませる）。次のコマで明ける |
| 黒が無かったコマで済んだ（小さな集まり） | 黒を出さない |

- 遊ぶ最中に初めて見せる階の暗転を起動の 1 回にまとめたい時だけ、`withPreload3d` の `groups` と `scenes`（描く時と同じ Output・変種の場面）で先に宣言する。宣言の名前も、一度済むまでは同じに外して黒にする（View で `isPreloaded` を読んで外す分岐と黒の板を書かない）:

```flix
App.withPreload3d({ groups = w -> floorsOf(w#res), scenes = w -> SchoolView.sceneOf(w) :: Nil | App.preload3d(w -> keyOf(w#res), _ -> Nil) })
```

- 断る口: `App.withAutoPreload3d(App.AutoPreload3d.PopIn)` = 外すだけで黒は出さない（作り終えたコマで現れる。区画を順に載せる場面向け）・`Off` = 先に作らず、描いたコマで作る（今までの止まり）。既定は `Cover`
- 中身が無い間（束が届く前）は、その名前の `staticGroup` を View に出さない（仮の物を出すと、それが作り終えた名前になり、届いた後は仮の物を描きながら作り直すので数コマ欠けて見える）
- 版の違う場面（点光源の影・`Physical`・psx・奥行きの書き出し）でも描くなら、宣言の `scenes` にもその版の場面を入れる（宣言の場面に無い版は engine が足し、宣言の集まりのその版まで作る）
- 黒が明けるのは、宣言と自動の物の全部が済んだ時（進み具合が 1 つの数のため）。全部の階を宣言するゲームで宣言が済む前に新しい名前が出ると、その分も暗転が延びる
- 黒くなるのは本当に初めて出た名前だけ（PC で 5〜7 コマ・CPU が 4〜6 倍遅い機械で約 0.5 秒）。Pass（鏡・ミニマップ）だけに出る集まりでも design 全体が黒くなる
- 作っている名前は View から消えても済むまで黒が続く（境目を行き来しても点滅しない代わりに、すぐ引き返しても作り終えるまで黒い）
- 作り終えた名前で値が替わった時は、新しい値を自動の宣言に載せ、描き手が作り終えるまで前の値を描き続ける（外さない・黒にしない・PopIn も同じ）
- 作り終えた名前は View から消えても 1,800 コマ（60 コマで 30 秒）自動の宣言に載せ続け、描き手に控えを手放させない（階段から覗く階に戻っても外れず黒くならない）。それより長く出なかった名前と、載せ続ける名前が 64 を超えた分（出なくなって長い物から）は忘れ、また出た時は黒にせず作り終えるまで外すだけ
- 置き場の上限で作り終えた自動の物が捨てられると、次に描くコマでそのコマに全部作って止まる（黒にしない）
- 名前に時刻を混ぜる・作り終える前に毎コマ値を作り直す、で名前か値が 300 コマに 20 回替わると、自動をやめて 1 回知らせる（Doc の読み直しのコマは数えない）。止めた後も宣言は有効なまま
- 撮る文脈（1 枚撮り・gallery・dt を固定したウィンドウ・`FLIX_GE_FRAME_SHOT`・ブラウザの撮る頁 `capture:<n>`）の描き手は先に作らないので、黒は出ず、集まりは描いたコマで作る（撮る絵が揃う）
- 止まりの見張り（`Hitch`）は黒のコマも 1 コマに数える。F8 の注釈を黒の間に書き出すと黒い絵になる
- `MultiMesh3d`・instances・骨つきの人物は対象にしない（黒の間も描くので、黒の下で組まれる。遊ぶ最中に初めて出すなら `App.preload3d` の instances で先に上げる）
- 進み具合は View の `ctx#preload3d`（`{ done, total }`・前のコマの値）でも読める（タイトルの「読み込み中」の字など）。View だけで読む（`Frame` に無い）。描き手の実時間で決まる値で、World を変えると遊んだ記録と再生がずれる
- 宣言で作った集まりは宣言にある間は手放さず、描かないコマでもその形（WebGPU は材質の絵も）を使っている物として扱う（置き場の上限で捨てない）。GL は材質の絵を描くコマに名前で引くので、上限を超えたゲームでは初めて描くコマに絵を上げ直す
- 計画を持たない描き手（CPU の描き出し・ウィンドウの無い描き手）は `{ done = 0, total = 0 }`（済んでいる）を返すので黒にならない
- 宣言の最初のコマと `key` が替わったコマの `ctx#preload3d` は、まだ済んでいない値（0 / 1）。後から届いた束で集まりを作り直したら `key` も替える（groups と scenes は key が替わった時だけ読む）
- `groups` の集まりの名前は別々にする（同じ名前の物は作りかけを捨て合う。宣言の時に 1 回知らせる）
- Doc の読み直しでも宣言の `key` が替わる（一度済んだ名前は、key が替わっても黒にしない）

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

## 置いた物と当たりの食い違いを調べる（Scene3dCheck）

見た目（`Instance3d` の列）と当たり（`CollisionWorld3d`）は別の値なので、置き直すたびに食い違いが出る。ゲームのテストに 1 本書いておくと止まる
（配置は Doc の値からコードで作るので、lint には見えない）:

```flix
@Test
def testRoomHasNoProblem(): Unit \ Assert =
    Assert.assertEq(expected = Nil, Scene3dCheck.check(visible, world, bodySettings, start))   // bodySettings は歩く時に moveAndSlide へ渡す値
```

| `Problem` | 拾う物 |
|---|---|
| `InvisibleWall(x, y, z)` | 見た目の三角形がどれも掛からない当たりの箱（見えない壁。座標は箱の真ん中） |
| `PassableVisual(名前)` | 立つ床の上で体の高さ（段の上から頭まで）に掛かる見た目なのに、体の高さに三角形がある所のどこかに体が当たりに掛からずに立てる物（見えるのに通れる柵。名前は `withName`・無ければ `#<番号>`・同じ名前は 1 つ） |
| `EscapeHole(x, y, z)` | `start` から体の半径の升で歩いて、当たりの箱の集まりの外へ出られる所（絵だけの戸。座標は外へ出る手前） |

- 体は `CharacterBody3d.Settings` をそのまま渡す（歩く時と同じ値）。体が当たりに掛かるかは歩く時と同じ `CharacterBody3d.overlapDepth` で見る
- 抜け穴は `start` の高さの 1 階分を見る（段の高さを超える所は上らない）。上の階は、階ごとの立ち位置で `check` を呼び直す。`start` が箱に埋まっていると `EscapeHole(start)`（遊び始めに動けない）
- 机の上の背の高い物（花瓶・地球儀）は、机の箱の上を床とみなして `PassableVisual` に出ることがある。机の上に置く物は `visible` から外す
- 通り抜けてよい物（カーテン・当たりを置かない小物）と、当たりを `moveAndSlide` の `moving` で持つ物（回る戸の板）は、`visible` から外して渡す
  （手本は retro3d-horror-starter の `World.collisionProblems`）
- 屋外の端に見えない壁を置く作りは `InvisibleWall` が必ず出る。その箱だけ結果から外す
- 当たりの箱が 1 つも無い時は `EscapeHole(start)`（渡し忘れを緑にしない）
- 重なり・浮きは拾わない（見た目の磨き）

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
