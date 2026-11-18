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
- [金属っぽさと粗さ（鏡面ハイライトと空の映り込み）](#金属っぽさと粗さ鏡面ハイライトと空の映り込み)
- [周りの景色を映す（環境マップと箱の補正）](#周りの景色を映す環境マップと箱の補正)
- [描く量（視錐台の外を間引く）](#描く量視錐台の外を間引く)
  - [ビルボードの draw の数（同じ絵の板をまとめる）](#ビルボードの-draw-の数同じ絵の板をまとめる)
  - [動かない物をまとめる（staticGroup）](#動かない物をまとめるstaticgroup)
- [空（グラデーション）](#空グラデーション)
- [半透明と両面（窓ガラス・網・水面）](#半透明と両面窓ガラス網水面)
- [細い物の欠けを抑える（MSAA）](#細い物の欠けを抑えるmsaa)
- [画面の歪み（熱のゆらぎ・水の中・魔法）](#画面の歪み熱のゆらぎ水の中魔法)
- [地面を這う霧（高さの霧・街灯のにじみ）](#地面を這う霧高さの霧街灯のにじみ)
  - [明るい所へ入った直後の白飛び（ExposureAdaptation）](#明るい所へ入った直後の白飛びexposureadaptation)
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
  スマホは `{ maxShadowedLights = 1, mapSize = 256 | Scene3d.pointShadowMap() }`（atlas 768 × 512）を勧める
- 既定（`pointShadows = None`）は今までの絵と同じ（GPU のシェーダーの字も同じ）。影つきの場面だけ別のプログラム（`+ps`）を組む
- 先に上げる物（`App.withPreload3d`）は既定のプログラムだけを組む。点光源の影と `Physical` の場面は、その場面が初めて出たコマに変種のプログラム（`+ps`・`+pu`）を組む（そのコマが重い）

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
  映したくない物（映る側の球・銃）は隠して描く。8bit の sRGB の絵として読み、段（mipmap）を作る。1 を超える明るさ（光る板）は 1 に頭打ちになるので、
  足りなければ `withEnvironmentIntensity` で倍にする。Blender は engine と左右が鏡なので、描いた絵の左右を反転して書く
- **向き**: 座標の約束（X = 東・Y = 上・Z = 北）のまま。向き d（長さ 1）の絵の座標は `u = 0.5 + atan2(d.x, −d.z) / 2π`・`v = 0.5 − asin(d.y) / π`
  （`LightModel3d.environmentUvOf`）。絵の真ん中が −Z・u = 0.75 が +X・u = 0.25 が −X・継ぎ目（u = 0 と 1）が +Z・上の行が真上
- **段**: roughness × (段の数 − 1) の段を、段どうしを混ぜて読む（`LightModel3d.environmentLodOf`）。roughness 0 の鏡は一番細かい絵・1 は 1 × 1 の平均。
  段は微分でなく roughness から決めるので、向きの継ぎ目（atan2 が 1 跳ぶ所）で段が跳ねて縦の筋が出ることは無い。
  絵は横も縦も Repeat で読む（横の継ぎ目は回り込んで混ざる。縦は真上・真下の 1 画素が反対の極と少し混ざる）
- **箱の補正**（`withEnvironmentBox`）: 無限に遠い景色として読むと、部屋の中の物が壁の近くでも景色の位置がずれない。箱があれば、点から跳ね返りの向きへ伸ばした線が
  箱の内側の面と交わる点を求め、`その点 − center` の向きで絵を読む（Unity の Box Projection と同じ）。center は絵を撮った点。
  部屋の中の物にだけ付ける（屋外の空には要らない）。点が箱の外にある時は、点から見た向きになる
- **映すもの**: metallic と roughness を持つ材質の映り込み（`Fresnel` を掛けた色）だけ。拡散の光（ambient と hemisphere）は変わらず、鏡面ハイライト（光源の映り）も今まで通り。
  環境マップの無い場面（`environmentMap = None`）は今までと同じ（空のグラデーションを映す・絵も GL のプログラムの字も同じ）
- **重さ**: 絵を 1 回読む（画素 × 1 回）と、箱があれば向きの計算が少し増える。環境マップの無い場面は何も増えない
- やらない事: 環境マップから拡散の光を作る（放射照度の前計算）・エンジン自身で景色を撮る（反射プローブ・キューブマップ）・複数の環境マップの切り替えと混ぜ
- `Scene3dCmd` に欄 `environmentMap = Option[EnvironmentMap]` が増えた（`Scene3d.scene` は None）。場面のレコードを全部の欄で書いている所は `environmentMap = None` を足す
- **背景**（`Scene3d.withEnvironmentAsBackground(true, env)`）: 何も描かれない画素にも景色の絵を空として描く（屋外の景色の絵向き・室内の見本の部屋では使わない）。
  向きは画素の NDC を通る向き（空と同じ）・絵は段 0 で読み、強さも掛かる。`sky` があれば `sky` が勝つ（環境マップの背景は描かず、映り込みだけに使う）

## 描く量（視錐台の外を間引く）

GL・WebGPU・CPU の描き手は、場面のカメラの視錐台の外の置いた物とビルボードを描かない（ゲームは何も書かなくてよい）。
判定は外れる側に倒してある（画素を 1 つも出さない物だけを間引く）ので、絵は間引かない時と同じ。

- 骨つきの物（Pose で形が境界の外へ出うる）と頂点の無い形は間引かない。ビルボードは外接球で見る
- 影の地図は光の視錐台で別に間引く（目に見えない物も影は落とす）
- 間引いた物の形・絵・材質のプログラムは、今のコマで使った物として GPU に残す（振り向いても上げ直さない）
- 間引くのは視錐台の外だけ。壁の向こう（部屋ごとに描くか）はゲームが決める
- 効き目は `FrameDiagnostics.Diagnostics.scene3dCounts`（`instances` = 置いた物・`drawn` = そのうち描いた物）で見る
- 光や羽虫をゲームの側で間引く・数える時は `Camera3d.frustum(camera, aspect)` → `Frustum.intersectsSphere` / `intersectsBox`。
  場面と同じ判定は `Scene3d.frustumOf(scene)` + `Scene3d.isOutsideFrustum`・置いた物の world の境界は `Scene3d.worldBoundsOf`

### ビルボードの draw の数（同じ絵の板をまとめる）

GL と WebGPU の描き手は、`scene#billboards` の**来た順で続く同じ絵の板**を 1 回の instanced draw で描く（Unity の GPU Instancing・Godot の MultiMesh と同じ考え。ゲームは何も書かなくてよい）。
板ごとの位置・大きさ・anchor・tint・貼る範囲・光の当て方は instance の値で渡るので、まとまりを切らない。まとまりが切れるのは絵が替わった時だけ。

- 視錐台の外の板はまとまりを切らない（間の外の板を飛ばして前後がつながる）
- 来た順は崩さない。カメラを向く板はどの画素も同じ深度で、目からの奥行きが同じ板どうし（格子に並べた木の列）が重なると先に描いた方が勝つため、
  描き手が絵ごとに並べ替えると絵が変わる。**draw を減らしたいゲームは、同じ絵の板を続けて `billboards` に並べる**（森の木を絵ごとに出す・人を絵ごとに出す。
  重なる板の前後を来た順で決めている所は崩さない）
- 影の地図（太陽・点光源の 6 面）は深度だけなので、描き手が絵ごとに並べ替えてからまとめる（ゲームの並べ方に依らない）
- 効き目は `drawCalls` の `billboard`・`shadowPass`（まとまり 1 つで 1）。bench/hd2d_town の立ち始め（WebGPU・1280×720）で 3D の draw 584 → 250・
  billboard 318 → 100・shadowPass 155 → 39（絵は 0 差）

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
- 中の 1 個だけ動かす・色を変える物は `Scene3d.withoutItems(鍵の Set, 集まり)` で外して `instances` に置く。外す物を変えたコマは持ち越しを作り直す
- 遠くを描かないなら、区画ごとの集まりに分けて載せ外しする
- 効き目: スマホのブラウザ（WebGPU）で 12,000 個が 1.6 fps → 60 fps（[performance.md](performance.md) の §12）
- `Scene3dCmd` を字で組み立てているゲームは `groups = Nil` を足す（`Scene3d.scene` は空）

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
- 色の α は材質の spec の α（絵の α）。baseColorFactor の α は読まない（頂点の色に色だけ書き込んである）
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

## 画面の歪み（熱のゆらぎ・水の中・魔法）

火山の陽炎のように、時間で流れるノイズで画面の絵を読む位置をずらす。PostStack の欄の 1 つで、3D の場面にも 2D の View にも掛かる（HUD には掛からない）:

```flix
App.withPostStack(w -> PostStack.preset(PostStack.Preset.DuskOutdoor)
    |> PostStack.withDistortion(Some({ strength = { x = 2.0, y = 1.0 }, noiseSize = 24.0, speed = { x = 0.0, y = -20.0 },
                                       mask = PostStack.DistortionMask.BottomBand({ top = 0.5, soft = 0.3 }) }))
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
    |> PostStack.withHeightFog(Some({ color = Color.rgb(0.42, 0.46, 0.56), density = 0.05, baseHeight = 0.0, heightFalloff = 0.15,
                                      startDistance = 0.0, maxOpacity = 0.92,
                                      noise = Some({ size = 40.0, amount = 0.6, speed = { x = 10.0, y = 4.0 } }), lightGlow = 0.5 }))
    |> PostStack.withTime(Clock.nowOf(w#playClock)))
```

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
