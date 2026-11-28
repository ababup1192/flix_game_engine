# 場所ごとの映り込み（reflection probe）と、前もって計算した GI の irradiance volume — 計画（相談用・未着手）

状態: 計画（git に入れない）。engine は読んだだけで書き換えていない。engine の拡張なので、人の了承の後に段ごとに実装する。
書いた日: 2026-11-27。main 16cec8709（L5 SSAO・W1 は main に入り済み）。
レビュー: 1 回目 66 点（必須 11・推奨 13・軽微 6）→ この版で全部に手を入れた（末尾の「レビューへの答え」）。
**事実** はソースか docs・元の場面のファイルの引用（`bin/fge refactor` で引いた所を書く）。**推測** は「推測:」と書く。時間は実時間。
重なる計画（二重に書かず指す）: `plans/engine-environment-map.md`（環境マップ・済み）・`plans/engine-render-stage1.md`（「段 1 計画」・`2c の 1` は済み）・`plans/engine-render-look-l5-l7.md`（「L 計画」）・`plans/engine-round9-lightmap.md` と `docs/lightmap.md`（lightmap）・`plans/engine-sky.md`（空と時間・同時に書く）・`plans/engine-decals.md`（デカール）・`plans/engine-water.md`（「水の計画」）。
人の決め（2026-11-27・HANDOFF.md 3 節）: GI は **案 A（前もって計算した probe・3 つの GPU の描き手と CPU の描き手で同じ答え）を先に**、案 B（SSGI）は TAA と SSR の後の上乗せ、案 C（ボクセル・SDF の動く GI）は当面やらない。

## 0. 結論

1. **reflection probe を場面に並べ、画素ごとに箱で重みを付けて混ぜる**（Godot 4・Unity URP Forward+ の形）。1 つの probe = 箱（影響の範囲と box projection の箱）+ 撮った点 + 撮った景色の絵（画素を持つ絵）。撮った景色から求めた拡散の光（SH）を箱の中の環境光にも使える（Godot の ReflectionProbe の `ambient_mode` に当たる）。
   - 映り込みは今の環境マップの読み（`environmentColorAt`・box projection・roughness で段を選ぶ）を probe ごとに使い回し、箱の端の `blendDistance` でなめらかに切り替える。重みの残りは場面の環境マップ（無ければ今の空のグラデーションの映り込み）へ。
2. **probe の景色は、エンジンが前もって CPU の描き手（SoftRaster）で撮る**（bake・`bin/fge task probes`）。読み込みでは撮らない。撮った物（.hdr と JSON）を `assets/` に置き、4 つの描き手が同じ物を読む → **4 つの描き手で同じ答え**。Blender で撮ったパノラマを probe にする道もある。**撮る場面には lightmap の面がそのまま写るので、probe も volume も lightmap の間接光を受け継ぐ**（今ある lightmap の使い回しの本体・5.5）。
3. **HDR の環境マップを回す欄** `Scene3d.withEnvironmentRotation(ラジアン)`（Godot の `sky_rotation`・Unity の Skybox の Rotation）。0 の場面は字も絵も同じ（変種 `+er` は 0 でない時だけ）。
4. **後ろの段に GI の irradiance volume（案 A）**: 箱の中に格子で置いた点ごとに周りから来る光（SH の先頭 4 係数 = L1）を前もって計算し、画素ごとに近い 8 点を混ぜて環境光にする（Unity の Adaptive Probe Volumes・Godot の LightmapGI の probe と同じ考えを画素ごとの読みで）。**動く物もそこから光を受ける**。
5. **Material Testers の差は、まず光の組み方の違い**（2 節・元の場面のファイルで確かめた: Godot は太陽を消し、くぼみごとのスポットと空の環境光で照らす）。engine を触らない段 **R-1** で光を Godot に合わせて撮り直し、残った差（球の映り込み・球の下側の環境光）を R 段で埋める。
6. **ゲームが見る pub は 8**（9 節）: engine の `Scene3d.ReflectionProbe`・`reflectionProbe`・欄 `Scene3dCmd#reflectionProbes`・`withEnvironmentRotation`・欄 `Scene3dCmd#irradianceVolume`（G 段）、engine_world の `Probes3d.loadOr`・`Probes3d.applyTo`、engine_tools の `ProbeBake.bakeProject`。
7. **段（実時間）**: R-1 0.5〜0.8・R0〜R4 で **11.5〜16 時間**、G1〜G3 で **5.5〜8.5 時間**、レビュー 2〜3 時間。区切りのリリースは R4 の後と G3 の後。
8. **既定の絵は 1 画素も変わらない**: 欄の既定は `reflectionProbes = Nil`・`irradianceVolume = None`・回り 0 で、変種 `+rp`・`+gi`・`+er` は立たない。

## 1. 今の engine の事実（この計画で引いた所）

| 事実 | 根拠 |
|---|---|
| 環境マップは場面に 1 つ（`Scene3dCmd#environmentMap`）。中身は絵の名前・強さ・箱（`EnvironmentBox = { min, max, center }`）・背景に描くか・`colorSpace`・`skyContribution`・`irradiance`（外から渡す SH）・`textureIrradiance`（絵から求める SH・Lazy） | `refactor show Scene3d.EnvironmentMapFields / EnvironmentBox`（839〜848 行） |
| 映り込みの絵の読みは光の式の木の外。GPU は `Render3dShaders.environmentColorAt`（`textureLod`・段 = roughness × (段の数 − 1)・`environmentDirectionAt` が box projection）、CPU は `SoftRaster3d.Internal.environmentColorAt`（同じ式）。木の入力 `Vec3Input.EnvironmentColor` へ渡す | `refactor show Render3dShaders.environmentColorAt`（383 行）・`SoftRaster3d.Internal.environmentColorAt`（87 行）・`LightModel3d.Vec3Input`（154 行） |
| 段は微分でなく roughness から選ぶ。段は箱の平均の縮小（GGX で前もってぼかした物ではない） | `environmentColorAt` の WhyNot・`docs/scene3d.md` 390 行 |
| 環境光の SH は 9 係数 × rgb。木の入力 `IrradianceSh(i)` は**場面ごとの uniform に決め打ち**（`LightModel3d.Codegen.isPerPixel` が偽・GLSL は `uSh[i]`・CPU の生成した関数は 27 個を 1 つの引数 `Vector` で受ける・JIT の WhyNot つき）。値は「環境マップの強さを掛けた後」。光 = ambient + (景色の拡散の光 × 強さ − ambient) × k。lightmap の面には足さない | `refactor show LightModel3d.Vec3Input / LightModel3d.skyIrradiance`・レビューで `Codegen.isPerPixel`・`glslUniformOf`・`vec3InputCode` を確かめ・`docs/scene3d.md` 407〜430 行 |
| SH を絵から求めるのは画素を持つ絵だけ（`PlatformImage` は None・`withSkyContribution` の doc「機種の側の絵は求められない」） | `refactor show Scene3d.withSkyContribution`・レビューで `Texture3d.Internal.equirectangularIrradianceOf` |
| HDR の絵は `Texture3d.decodeHdr`・`fromRgba16Float`。RGBE を書く関数は無い。Blender・Poly Haven のパノラマは engine と左右が鏡 | `refactor outline engine/src/scene3d/Texture3d.flix`・`docs/scene3d.md` 381 行 |
| CPU の描き手は 3D の場面を線形の HDR のまま描ける（`SoftRaster3d.Targets.drawSceneHdr`） | `refactor outline engine_tools/src/SoftRaster3d/Targets.flix`（59 行） |
| engine に配列の絵・3D の絵は無い | `docs/lightmap.md` |
| lightmap は外（Blender・Godot の LightmapGI）で前もって計算して持ち込む。動く物を照らす probe（Godot の LightmapProbe）は無い。見本は `spaceship_lab` の `tools/hangar.gd` | `docs/lightmap.md` の「Godot の LightmapGI を持ち込む」 |
| engine に JSON を読む道がある（`ShaderJson.parse`・glTF の読み）。Doc の `DocJson.loadOr` は engine_world。engine_world と engine_tools は互いを見ない | `refactor search parse / Json`・`gates.json` |
| ゲームの task は project.json の `tasks` に `{"entry": "SfxRender.write"}` の形で書き、`bin/fge task <名前>` が流す | `templates/retro3d-horror-starter/project.json` 163〜167 行（JSON なので grep）・レビューで `go/cmd_launch.go` の `runTask` |
| WebGPU の場面の group 0 の binding は `Group0Binding = LightBuffer \| PointShadowAtlas \| AoMask` | `refactor show Render3d.ProgramKey.Group0Binding`（18 行） |
| 材質の frag の texture unit は 8 + 材質の絵 6 = 14。L5〜L7 で最大 18（WebGL2・WebGPU の最小 16 を超えうる・外す順は L 計画 9.4） | L 計画 9.4 |
| engine の角はラジアン（カメラも） | `Camera3d.camera` の yaw・pitch（`demo_repro_lab/src/MaterialsScene.flix` の呼び方） |
| `Scene3d.flix` 1,068 行・`SoftRaster3d.flix` 1,181 行・`Render3d.flix` 1,107 行・`WebGpuRenderer.flix` 1,147 行（上限 1,200）。水の計画も `SoftRaster3d.flix` の霧を外へ出してから書く前提 | `wc -l`・水の計画 3.3 |

## 2. Material Testers で何が足りないか（元の場面で確かめた）

元の場面は `~/Documents/flix_ge_workspace/demo_repro_downloads/gdp/3d/material_testers/`（`material_tester.tscn`・`models/test_bed/test_bed.tscn`・`tester.gd`）。

| | Godot の元 | こちらの再現（`MaterialsScene`） |
|---|---|---|
| 太陽 | `DirectionalLight3D` は `visible = false`（消えている） | 太陽 1.2 が全部の壁を一様に照らす |
| くぼみの光 | くぼみごとに `SpotLight3D`（高さ 5.5 m・45 度下向き・energy 1.5・影あり・角 31.8 度・届く 15 m） | 無し |
| 空の環境光 | 空の環境光（Sky） | `withSkyContribution(1.0)`・hemisphere 0 |
| ReflectionProbe | 12 個とも `size = 256³`（場面全体）・球の 2.4 m 上・`box_projection` は既定の偽。**球ごとに自分の layer に置き、probe は `reflection_mask` でその球だけに効く**（壁には効かない）・`cull_mask` で自分の球は撮らない。`ambient_mode` は UI で切り替え | 無し |
| 霧・色 | 霧 0.002・AgX・壁は灰 0.78・metallic 0.1・roughness 0.6・裏面も描く・座面 (0.055, 0.33, 0.33) | 霧なし・AgX・壁 (0.78, 0.8, 0.86)・roughness 0.45・座面 (0.02, 0.13, 0.16) |

- **見立て**: 「平たく白っぽい」の一番の原因は、太陽が全部の壁を一様に照らしている事（推測）。Godot ではくぼみごとのスポットが光の溜まりと暗がりを作り、空の環境光が陰を青くする。**壁が染まるのは probe ではなく、空の環境光とスポットの照り返し**（照り返しは G 段か SSGI の受け持ち）。
- **probe が効くのは球だけ**: Godot はこのデモで「置いた物ごとの probe」を layer の mask で作っている。球は自分のくぼみの中の景色（暗い奥の壁・座面・開いた口の空）を映し、`ambient_mode` で球の下側に座面の色の環境光が回る。
- だから進め方は: **R-1（engine を触らない）** でゲームの側の光を Godot に合わせて撮り直す（太陽を消す・スポット 12 本・材質の色と霧）→ その絵で残った差（球の映り込み・球の下側の環境光）を R 段で埋める。
- こちらの R 段は画素ごとの重みの形なので、再現は**くぼみごとの 6 m の箱 + box projection** で置く（Godot の「場面全体の箱 + layer の mask」とは作りが違う）。壁にも probe が効く分、Godot より壁の映り込みが増えうる。R4 の比べにこの違いを書く。

## 3. reflection probe（R 段）

### 3.1 形（ゲームの書き方）

```flix
// 1) 撮る（開発の時に 1 回）: project.json の "tasks" に "probes": {"entry": "ProbeRender.write"} → bin/fge task probes
//    → assets/hall.probes/*.hdr と assets/hall.probes.baked.json ができる
// 2) 読む（読み込みで 1 回）
let probes = Probes3d.loadOr("assets/hall.probes.json")
// 3) 毎コマ: 場面に載せる
Probes3d.applyTo(probes, { environmentMap = Some(sky) | base })

// Blender で撮ったパノラマを手で probe にする時（撮る道具を使わない・左右を鏡にしてから渡す）
let room = { blendDistance = 0.5 | Scene3d.reflectionProbe(panorama, { min = Vec3.v3(-4.0, 0.0, -4.0), max = Vec3.v3(4.0, 3.0, 4.0), center = Vec3.v3(0.0, 1.4, 0.0) }) };
{ reflectionProbes = room :: Nil | base }
```

- `Scene3d.ReflectionProbe`（record・欄は既定値から `{ … | Scene3d.reflectionProbe(…) }` で替える）:
  - `texture`: 撮った景色の絵（`Texture3d.Texture3d` を値で持つ・正距円筒 2:1）。**画素を持つ絵だけ**（`decodeHdr`・`fromRgba16Float`・Argb）。機種の側の絵（`PlatformImage`）の probe は落として場面ごとに 1 回知らせる（atlas を CPU で組めないため）。場面の `textures` には載せない（atlas だけが GPU に上がる・場面の絵の予算を probe の数だけ食わない）。
  - `colorSpace`: `reflectionProbe` が絵の形式から決める（`environmentMap` と同じ）。
  - `box`: `EnvironmentBox`（min・max = 影響の範囲と box projection の箱・center = 撮った点）。
  - `boxProjection`: 箱で向きを直すか（既定 true）。Godot・Unity の既定は偽だが、この engine の probe は「部屋・くぼみの中で撮る」使い方が主で、箱なしで読むと壁の近くで景色がずれる（今の環境マップの箱の節と同じ理由）。屋外の大きな箱は false。
  - `blendDistance`: 箱の内側の端からこの距離で重みを 0 → 1（場面の長さ・既定 1.0）。
  - `intensity`: 撮った絵の線形の量に掛ける倍率（既定 1）。撮った絵には撮る時の場面の光（環境マップの強さを含む）がもう入っているので、既定 1 で 2 回掛けにはならない。
  - `irradianceFromCapture`: 撮った景色から求めた SH を箱の中の環境光に使うか（既定 true・Godot の `ambient_mode` の「映り込み + 環境光」）。SH は絵から engine が求める（`Texture3d.Internal` の Lazy・環境マップと同じ控え）。手で渡す時は `irradiance: Option[SphericalHarmonics]`（環境マップの欄と同じ名前）が先に使われる。
  - `priority`: 重なった時の順（Int32・既定 0・大きい方が先。Unity の Importance）。
- `Scene3dCmd#reflectionProbes: List[ReflectionProbe]`（既定 Nil）。
- `Scene3d.environmentMap` は場面の空（遠くの景色）として残り、probe の外と重みの残りを受け持つ（Godot の Sky と ReflectionProbe の分担と同じ）。

### 3.2 画素ごとの混ぜ方（GPU は AST・CPU は Flix で同じ式）

1. **選ぶ（場面ごと・コマの純粋な関数）**: 箱が「少し広げた視錐台」（near..far を 10% 広げ、横と縦の角を 1.1 倍）に当たる probe を集め、8 つを超えたら目に近い方（箱の真ん中との距離）から 8 つ（`Scene3d.Internal.ReflectionProbes.selectOf`）。落とした時は場面ごとに 1 回知らせる（`@reflection-probe-overflow`）。GPU も CPU も同じ関数で選ぶ。コマをまたぐ状態を持たない（headless の 1 枚と遊んでいる途中で同じ答え）。
2. **積む順（目に依らない）**: 選んだ 8 つを `priority` の大きい順 → 箱の体積の小さい順 → 列の順に並べる（Unity と同じく小さい箱が先）。目の近さは「何を落とすか」だけに使い、重なった所の色がカメラで入れ替わらないようにする。
3. **重み（画素ごと）**: 点 p の probe i の重み `wᵢ = smoothstep(0, blendDistanceᵢ, 箱の面までの一番近い距離)`（箱の外は 0）。積む順に `wᵢ' = wᵢ × (1 − Σ前の wⱼ')`。残り `w_sky = 1 − Σwᵢ'`。
4. **映り込み**: `EnvironmentColor = Σ wᵢ' · intensityᵢ · atlasᵢ(dirᵢ, lod) + w_sky · 今の映り込み`。dirᵢ は今の `environmentDirectionAt`（`boxProjection` が偽なら箱なし）。今の映り込みは、場面に環境マップがあれば今の `environmentColorAt`（強さと回りを掛けた物）、無ければ今の空のグラデーションの映り込み（`uEnvOn = 0` の道）。重み 0 の probe は読まない。
5. 半透明の物も同じ（映り込みは半透明にも掛かる・今と同じ）。
6. 差し替える所: `EnvironmentColor` を作る木の外の所（GPU の `environmentColorAt` の呼び手・CPU の呼び手）だけ。映り込みの側は光の式の木を変えない。環境光の側（3.4）は木の入力の読み方を変える。

### 3.3 atlas と、絵 1 枚にまとめる形

- engine に配列の絵が無いので、選んだ probe の景色を **1 枚の RGBA16F の atlas** に並べる。枠の大きさは全部の probe で同じ（既定 256 × 128・Doc の `resolution`）。8 枠を 2 列 × 4 行 + 下に volume の行（5.2）。
- **段は枠ごとに CPU で作り、枠ごと・段ごとに 1 texel の縁を付けてから並べる**。縁: 左右には反対側の列を写す（正距円筒の u = 0 と 1 がつながる）・上下は端の行を写す。これで枠の中を丸めずに双線形が自然につながり、粗い段の縦の線も出ない。段は枠が 8 × 4 になった所で止める（それ以下は縁が枠を食う）。
- **段の選び方を場面の環境マップとそろえる**: 今は `roughness × (段の数 − 1)` で、段の数は絵ごとに違う。probe と空の境でぼけ方が合うよう、atlas の段を「一番細かい段の 1 画素の角の広がり」で空と同じ角に当たる段を読む式（`lod = roughness × (log₂(空の幅) − 1) − (log₂(空の幅) − log₂(枠の幅))` を 0..止めた段に切る）にし、`LightModel3d.Internal` に 1 つ置いて GPU と CPU が読む。場面に環境マップが無い時は枠の段の数で今の式。
- 段の間を混ぜて読む所は、粗い段の縁の内で読む（縁が 1 texel あるので丸め不要）。
- **atlas の控えの鍵は選んだ probe の絵の中身の hash の並び**（`Texture3d.contentHash`・名前ではない。撮り直して同じ名前で読み直しても古い atlas を描かない）。組が変わった時だけ作り直す（推測: 8 枠の段と縁つきの作り直しは JVM 3〜6 ms・wasm 15〜30 ms）。どの枠に置いても読む値は同じなので、控えは並べ替えの速さのためだけで、絵は控えに依らない。歩いて選びが替わる所で 1 コマ重いのが目立てば、読み込みで全部の probe を 1 枚にする形（16 枠・1024 × 512 で約 6 MB）へ R0 で寄せる。
- **probe の値（箱・`blendDistance`・`intensity`・枠の位置・L1 の SH）は uniform の配列**（8 × 7 vec4 = 56 vec4）。R0 で今の frag の uniform の使用量を数え、WebGL2 の最小 224 vec4 に収まるかを見る。収まらなければ RGBA32F の表の絵（+1 枚）。
- **texture unit と標本の数え（R0 で L5-0 の実数で数え直す）**:

| 組 | 絵 | 標本 |
|---|---|---|
| 今の材質の frag（8 + 材質の絵 6） | 14 | 推測 12〜14（`texelFetch` で読む物は標本なし） |
| L5〜L7 の足し（`+ao` 1・`+vf` 1・`+cl` 2） | +4 → 18 | +2（`+cl` は `texelFetch`） |
| 段 1 の `+ssr` | +1 → 19 | +1 |
| この計画（atlas に volume の行も入れる・uniform に収まる時） | **+1 → 20**（`+rp` と `+gi` で合わせて 1 枚） | **+1**（atlas は Clamp。空の Repeat とは別） |
| uniform に収まらない時 | +2 → 21 | +1 |
| 半透明の最悪（水の `+db` 1 が `+ao` の代わり・`+ssr` 無し） | 14 + 1 + 1 + 2 + 1 = 19 | — |

  外す順（L 計画 9.4 の文とテストを R2 で直す）: `+ssr` → `+ao` → `+gi`（volume を読まず probe と空の SH へ戻る）→ 材質の絵を後ろから → `bug!`。`+rp`（atlas）は外さない（外すと部屋の中で空が映り、一番目立つ）。不透明の最悪 20 は 3 手で 16 に収まる（`+ssr` 1・`+ao` 1・材質の絵 2）。全部の組を回すテストで「外した後に 16 を超える組が出ない」と標本も 16 以下を保つ。

### 3.4 環境光（probe と空の SH の混ぜ）

- 式（`+rp` で `irradianceFromCapture` が真の probe がある時）:
  `SH_mix[0..3] = Σ wᵢ' · intensityᵢ · SHᵢ[0..3] + w_sky · env.intensity · SH_sky[0..3]`
  `SH_mix[4..8] = w_sky · env.intensity · SH_sky[4..8]`
  光 = ambient + (irradianceAt(SH_mix, n) − ambient) × k（k = 場面の環境マップの `skyContribution`）。
- **L1（先頭 4 係数）だけ probe から混ぜる**: 畳み込みの係数は今と同じなので 9 係数の先頭を取るだけ。2 次の 5 係数は空の分だけ残す。WhyNot: 8 probe × 9 係数は 72 vec4 で 3.3 の uniform の予算を超える。拡散の光は L1 で大半が出る（Unity の APV の既定も L1）。
- **場面に環境マップが無い・k = 0 の時は probe の環境光を使わない**（今の ambient の場面の絵を変えない）。docs に「probe の環境光は、場面の環境マップに `withSkyContribution` を付けた時に入る」。
- **光の式の木の変更（必須）**: 今の `IrradianceSh(i)` は場面の uniform に決め打ち。`LightVariant` に旗 `perPixelIrradiance` を 1 つ足し、真の時は Codegen が `IrradianceSh(i)` を画素ごとの局所の値（GLSL・WGSL は `beforeLight` で求めた `shMix[i]`）として読む。CPU の生成した関数は今どおり `Vector` 1 つで受け、呼び手（`SoftRaster3d/Probes.flix`）が**画素ごとに作らず、場面ごとに 1 本の配列を使い回して上書き**する（GC を増やさない）。`make gen-light3d` の生成物の差は「旗が真の版の読み方」だけで、偽の版の字は同じ事を確かめる。前後で `javap -c` のバイト数を測る（8,000 バイトの JIT の上限）。`ProgramKind` と変種のテストに旗が 1 つ増える。
- lightmap の面には足さない（今と同じ）。

### 3.5 CPU の描き手

- 選び・積む順・重み・atlas の組み方・段の選び・L1 の混ぜを、GPU と同じ式で Flix に書く（新しい `SoftRaster3d/Probes.flix`・`SoftRaster3d.flix` は呼ぶ 1 行）。重みが 0 の probe は早く抜ける。
- gallery と agent-eval の絵（CPU）にも probe の映り込みと環境光が出る。CPU の重さ（画素ごとに箱 8 つ・atlas を最大 8 回）は R0 で gallery の 1 枚と `make gl-parity-cpu` の時間で測る。

### 3.6 回す欄（R1）`Scene3d.withEnvironmentRotation(ラジアン, env)`

- 縦の軸（Y）まわりに場面の環境マップを回す（映り込み・背景・SH の 3 つ）。engine の角はラジアンなので受けるのもラジアン（docs に度からの例）。
- GPU: 向き → 座標の手前で向きを回す（uniform の cos・sin）。**回りが 0 でない場面だけ**変種 `+er`。空の背景の frag も `+er` を受ける。CPU も同じ式。
- SH は CPU で回す（Y 軸まわりは 9 係数を m = ±1・±2 の組ごとに cos(mθ)・sin(mθ) で混ぜる閉じた式・`SphericalHarmonics.Internal`）。
- probe は world で撮った物なので回さない。
- 別案（取らない）: 絵の列を横へずらした新しい絵を作る（回すたびに絵の予算を食う）。

## 4. 撮る道具（R3）

### 4.1 形と層

- 置き場所の Doc `assets/<名前>.probes.json`（schema `docs/probes.schema.json`）:
  ```json
  { "version": 1, "resolution": 256, "clampSky": 8.0,
    "reflectionProbes": [ { "name": "bay03", "min": [-21,0,-7], "max": [-15,6,0], "capture": [-18,1.5,-3.9],
                            "blendDistance": 1.0, "boxProjection": true, "exclude": ["ball03"] } ],
    "irradianceVolume": { "min": [-72,0,-8], "max": [6,7,1], "spacing": 1.5 } }
  ```
- **層**: Doc の型と読み（文字列 → 値・`Result`）は engine の `Scene3d.Internal.ProbeDoc`（engine に JSON を読む道がある）。ファイルを読むのは呼び手: engine_world の `Probes3d.loadOr`（遊ぶ時）と engine_tools の `ProbeBake.bakeProject`（撮る時）。engine_world と engine_tools は互いを見ない（`gates.json`）。
- ゲームは `src/render/ProbeRender.flix` に撮る入口を 1 つ書き（効果音の `SfxRender.write` と同じ形）、project.json の `tasks` に `"probes": {"entry": "ProbeRender.write", "about": "…"}` を書く。入口は場面（動かない物と光だけ）を作って `ProbeBake.bakeProject("assets/hall.probes.json", scene)` を呼ぶ。
- 出す物: `assets/<名前>.probes/<probe の名前>.hdr`（RGBE・正距円筒）と `assets/<名前>.probes.baked.json`（Doc の中身の鍵・G 段は格子の L1 と確かさ）。reflection probe の SH は baked.json に持たない（読んだ絵から engine が求める・2 つの答えを持たない）。**撮った物は git に入れる**。

### 4.2 中でする事（`ProbeBake.Internal`・engine_tools）

1. **撮る場面の決まり**: `reflectionProbes = Nil`（撮る順で答えが変わらない）・G 段の 2 回目だけ 1 回目の volume を載せる・後がけ・露出・トーンマップ・**霧（DistanceFog と PostStack の霧）を切る**（映り込みに 2 回霧が掛からない）・場面の太陽・空・環境マップ・lightmap はそのまま。空の画素は `clampSky` で頭打ち（太陽の円盤を SH に 2 回入れない・`docs/scene3d.md` 427 行と同じ）。
2. **自分を撮らない**: probe ごとの `exclude`（置いた物の名前の頭）を撮る場面から外す。撮る点が置いた物の境界の箱の中にあれば、その物の名前を挙げて `Err`（撮る点を物の外へずらす）。
3. probe ごとに撮った点から 6 面（90 度の正方形・一辺 = resolution / 4）を `SoftRaster3d.Targets.drawSceneHdr` で描き、正距円筒へ写し直す（画素の向きで面と面の中の座標を選んで双線形）。
4. RGBE で書く（`ProbeBake.Internal.Rgbe`・新しい。今の `decodeHdr` と往復のテスト）。
5. **撮り直しの判定**: baked.json に Doc の中身の鍵を書く。`Probes3d.loadOr` は今の Doc と鍵が違えば「`bin/fge task probes` を流す」と 1 行言う（絵は古いまま描く）。場面（壁や光）を変えた事は読み込みでは分からない（`DrawHash` は engine_tools にあり、読み込みに場面も無い）ので、`bin/fge task probes --check`（撮り直した結果と今の撮った物が同じか）で見る。docs に「壁や光を替えたら撮り直す」。
- **決定性**: 同じ機械なら 2 回撮りでバイト一致（テスト）。機械をまたぐと `Math.sin` などの組み込みの最後の bit で撮り直しのたびに .hdr がずれうる（git の差分が出る）。docs に書き、気になれば StrictMath に寄せるかを R3 で決める。
- **撮る時間は R0 で必ず測る**: 重さは画素の数より、場面を 1 回描く固定の重さ（三角形の準備・影の地図）で決まる（推測）。reflection probe は 12 個 × 6 面 = 72 回描く。最初から入れる手: (a) 影の地図を 1 回作って 6 面と全部の probe で使い回す（光は動かない）、(b) 撮る点の周りの距離（Doc の `range`・既定は箱の対角の 2 倍）より遠い物は撮る場面から外す。
- **撮る側を GPU の headless にする案**: 速いが、撮り直しのバイトが機械と GPU で変わる。読む側は撮った物を読むので 4 つの描き手の答えは同じ。13 節の決め 10。

### 4.3 読み込み（`Probes3d`・engine_world）

- `Probes3d.loadOr(path): Probes3d.Baked \ Fs.FileRead + IO + LoadProgress`: Doc と撮った物を読む（絵は `Texture3d.decodeHdr`）。**Doc が無ければ黙って空**（`PostStack.loadOr`・`PhysicsDoc2d.loadOr` と同じ「無いのは正常」）。Doc はあるのに撮った物が無い・古い・壊れている時は空か古いままで続けて 1 行（`bin/fge task probes` を流す）。中は `Probes3d.Internal.load` が `Result`（`docs/error-handling.md`）。
- `Probes3d.applyTo(baked, scene): Scene3dCmd`: `reflectionProbes` と（G 段）`irradianceVolume` を入れる。絵は probe の値が持つので `textures` には足さない。毎コマ呼んでよい（値を入れるだけ）。

## 5. 後ろの段: GI の irradiance volume（G 段・案 A）

### 5.1 形

- `Scene3dCmd#irradianceVolume: Option[IrradianceVolume]`（既定 None・場面に 1 つ）。`IrradianceVolume` は閉じた型で、作るのは `Probes3d`（撮った物から）だけ。
- 中身（Internal）: 箱・格子の数 (nx, ny, nz)・点ごとの L1 の 4 係数 × rgb と確かさ（0..1）。

### 5.2 画素ごとの読み（GPU は AST・CPU は Flix で同じ式）

1. 点 p を法線の向きへ半格子だけずらしてから格子の座標にする（Unity APV の normal bias と同じ考え）。
2. 囲む 8 点の三線形の重みに、確かさと「点から p への向きと法線の内積を 0..1 へ写した物」を掛ける。和 s が 0.05 を下回る分は空の SH へなめらかに混ぜる（`a = smoothstep(0, 0.05, s)`・`SH = a · Σ(wᵢ SHᵢ)/s + (1 − a) · 空`）。小さい和で割って値が揺れない。
3. 混ぜた L1 を 3.4 の `shMix[0..3]` に（`shMix[4..8]` は空の分）。**優先: volume → probe の環境光 → 場面の空の SH → ambient**。volume の箱の端は `blendDistance`（Doc・既定は格子 1 つ分）で 3.4 の混ぜへ寄せる。**k（`skyContribution`）の式を同じく通す**（k = 0・環境マップ無しなら volume も使わない。ambient だけの場面の絵を変えない）。
4. 値の置き場: **atlas の下の行**（RGBA16F・`texelFetch` / `textureLoad` で段 0 を読む・標本なし）。1 点 4 texel（L0 の rgb と確かさ／L1x の rgb／L1y の rgb／L1z の rgb）。8 点 × 4 = 32 回の読み。texture unit は atlas と同じ 1 枚。
   - 別案（取らない）: 確かさを別の R8 の絵に分ける（unit +1）・3D の絵で GPU の三線形に任せる（確かさの重みが掛けられず壁の向こうの光が漏れる・engine に 3D の絵が無い）。
5. 半透明・lit のビルボードも同じく読む（6 節の表）。lightmap の面には足さない。
6. 確かさの誤り: 両面の材質（裏面も見える板・Godot の Material Testers の壁は裏面を描く）は「裏の面が見えた」を誤って数える。撮る時は両面の材質の裏の面を数えない（裏の面の印は片面の材質だけ）。

### 5.3 撮る（G2）

- 点ごとに 6 面（一辺 16 px）。**1 回目は描いて撮る**（直接の光と空）。**2 回目は描き直さず、1 回目の結果から跳ね返りを足す**: 1 回目の 6 面の画素ごとに「その面の点の albedo と、その点の位置で 1 回目の volume を読んだ環境光」を足し込む（6 面の albedo と位置と法線を 1 回目に一緒に控える）。描く回数は点の数 × 6 面 × 1 回。
- 確かさ: 1 回目の 6 面で、片面の材質の裏の面が見えた画素の割合が 1 割を超えた点は確かさ 0。CPU の描き手に「albedo・位置・法線・裏の面の印」を返す内側の口が要る（`SoftRaster3d.Internal`・R0 で形を決める）。
- 間引き: 置いた物の境界の箱の中で、6 面の全部が裏の面の点は 2 回目と保存を飛ばす。
- 点の数の上限 32³。Material Testers の 78 × 7 × 9 m を 1.5 m で約 1,900 点 × 6 面 = 約 11,400 回描く。**1 回 50 ms でも 10 分**（推測）。R0 の測りで 1 回の値を見て、重ければ (a) 影の地図の使い回し、(b) 近い物だけの場面、(c) 格子を粗く（3 m で約 250 点）、(d) 撮る側を GPU（決め 10）を選ぶ。

### 5.4 動く物

- 人物・動く箱は world の位置で読むので、くぼみに入ると暗く・青くなる。置いた物ごとの SH は持たない（instance buffer の 32 float に空きが無い・staticGroup の束ねが割れる）。

### 5.5 lightmap と、外で前もって計算した物との関係

- **使い回しの本体**: 撮る場面の lightmap の面はそのまま撮られる（ベイクした直接光と間接光が絵に入る）ので、probe の映り込みも volume の環境光も、lightmap の間接光を受け継ぐ。lightmap のある部屋では、動く物が volume から lightmap と同じ色の光を受ける（Godot の LightmapGI の probe が担う役と同じ）。
- **lightmap の面には volume も probe の環境光も足さない**（ベイクした光が環境光を含む・今の決まりと同じ）。
- **別案: 外の道具の probe を持ち込む**（Godot の LightmapGI の probe（L2 の SH・四面体で混ぜる）・Blender の Light Probe Volume を書き出して読む）。撮る道具が要らない代わりに、(1) 四面体の混ぜは画素ごとの読みに向かず置いた物ごとになる、(2) 書き出しの台本をゲームごとに持つ（`spaceship_lab` の `tools/hangar.gd` のように）、(3) lightmap を使わない場面（Material Testers・空と灯りだけの町）には外の道具の bake が無い。**推す: engine で撮る道具を主にし、外の probe の持ち込みは「格子にそろえた点の L1 の JSON」を `Probes3d` が読める形にしておく**（書き出しの台本の見本は G3 の後に要るゲームが出てから）。

## 6. 変種の旗ごとの受け方（L 計画 9.1 の形）

| 旗 | 材質の frag | lit の frag | ビルボード（lit） | ビルボード（光なし） | 空の frag | 奥行きの frag | 影の地図 | 骨つき |
|---|---|---|---|---|---|---|---|---|
| `+rp`（映り込みと環境光） | 受ける | 受ける（環境光だけ・映り込みは metallic と roughness の材質だけ） | 環境光だけ受ける | 受けない | 受けない | 受けない | 受けない | 受ける（材質の frag と同じ） |
| `+gi`（volume） | 受ける | 受ける | 受ける | 受けない | 受けない | 受けない | 受けない | 受ける |
| `+er`（回り） | 受ける（場面の環境マップの読み） | 受ける | 受ける | 受けない | **受ける**（背景） | 受けない | 受けない | 受ける |

差し込む点: `+rp` の映り込みは `EnvironmentColor` を作る所（木の外）、環境光は `beforeLight`（`shMix`）。`+gi` は `beforeLight`。`+er` は向き → 座標の手前。

## 7. 3 つの GPU の描き手と CPU の描き手

| 物 | GL・WebGL2 | WebGPU | CPU（SoftRaster） |
|---|---|---|---|
| probe の映り込みと環境光 | AST（`+rp`）・atlas は RGBA16F | AST・group 0 に atlas | Flix（`SoftRaster3d/Probes.flix`）・同じ atlas の配列 |
| 回す欄 | AST（`+er`） | 同じ | Flix |
| volume | AST（`+gi`）・`texelFetch` | AST・`textureLoad` | Flix（同じ配列） |
| 撮る | — | — | `ProbeBake`（CPU。GPU の撮りは決め 10） |

- 撮った物は 4 つで同じ物。読みの式は GPU が同じ AST・CPU が同じ式の Flix（L 計画の案 2）。gl-parity で GL と CPU のずれを見る。

## 8. 決まりと門

- **既定の絵**: 欄の既定の場面は字も絵も同じ。`make gl-capture-check`・gl-parity の既存の全行・テンプレートの reference が一致。
- **撮り直しの範囲**: 新しい gl-parity の場面 `reflectionProbes3d`（箱 2 つが重なる廊下・鏡の球と粗い球・box projection あり/なし・`blendDistance` の境・`priority` の違う 2 つ）・`probeAmbient3d`（くぼみ 1 つ・空と probe の SH）・`environmentRotation3d`・`irradianceVolume3d`（床と壁と動く箱・確かさ 0 の点）。上限は L 計画 3.4 の決め方。テンプレートは触らない。
- **CPU の描き手**: 7 節のとおり全部描く（`SoftRaster.dropped` に足す物は無い）。
- **決定性**: 読みはコマをまたいで積まない（選びはコマの純粋な関数・atlas の控えは速さのためだけ）。撮る道具は同じ機械で 2 回撮りでバイト一致。
- テスト（1 テスト 1 アサート）: 箱の外で重み 0／端から `blendDistance` で 1／積む順が `priority` → 体積 → 列の順で、目の位置を動かしても同じ／8 つを超えると目から遠い物が落ち、GPU と CPU で同じ選び／機種の側の絵の probe は落ちて 1 回知らせる／atlas の縁が反対側の列を写す・段 k の枠が隣の枠を読まない／段の選びが空と同じ角で同じ段／L1 の混ぜで重み 1 の probe の SH の先頭 4 係数と一致・強さが 1 回だけ掛かる／k = 0 で probe と volume の環境光が入らない／環境マップの無い場面の重みの残りが今の空のグラデーションの映り込み／回り 0 で字が同じ・90 度（128 列の絵で 32 列）回した SH が列をずらした絵の SH と 1e-6 以内／RGBE の往復／撮る場面で `reflectionProbes` が Nil・霧が切れる／撮る点が物の中なら `Err`／2 回撮りが同じバイト／volume の重みの和が 1・確かさ 0 の点を使わない・和が小さい所で空へなめらかに寄る／volume の箱の外は 3.4 の混ぜ／`perPixelIrradiance` が偽の版の生成物の字が同じ。
- forbid の `app-internal` に `Probes3d`・`ProbeBake` を足す（`Scene3d` は水の計画も足す。どちらが先でも足す）。
- 1,200 行に近いファイルには呼ぶ 1〜2 行だけ。`SoftRaster3d.flix` は水の計画（霧を `SoftRaster3d/Fog.flix` へ出す）とこの計画（`Probes.flix` を呼ぶ 1 行）が残りを分け合うので、先に入った方が霧を出す。
- **W1**: `+rp`・`+gi`・`+er` は新しい鍵。使うゲームは PC で遊んで `web/shader-variants.json` に記録してから書き出す。R4・G3 の門は「記録に `+rp` の行がある時、書き出しの生成がその変種を作る」の render_gl の単体テストと、R4 の Material Testers の書き出しで fail-open 0 件。

## 9. AI が迷わない形

**ゲームが見る pub（8）**:

| API | いつ使うか（1 行） |
|---|---|
| `Scene3d.ReflectionProbe`（record） | 場所ごとの映り込みの値（絵・箱・混ぜる幅・撮った景色を環境光に使うか）を書く時 |
| `Scene3d.reflectionProbe` | Blender などで撮ったパノラマを、箱の中だけの映り込みにしたい時 |
| 欄 `Scene3dCmd#reflectionProbes` | 場面に probe を載せる時（ふつうは `Probes3d.applyTo` が入れる） |
| `Scene3d.withEnvironmentRotation` | HDR の空の向き（太陽のある方角）を回したい時 |
| 欄 `Scene3dCmd#irradianceVolume`（G 段） | 前もって計算した GI を場面に載せる時（ふつうは `Probes3d.applyTo` が入れる） |
| `Probes3d.loadOr` | 撮った probe（映り込みと GI）を読み込みで読む時 |
| `Probes3d.applyTo` | 読んだ probe を毎コマの場面に載せる時 |
| `ProbeBake.bakeProject` | ゲームの `src/render/ProbeRender.flix` で場面の probe を撮る時（project.json の `tasks` から `bin/fge task probes`） |

`Probes3d.Baked`・`Scene3d.IrradianceVolume` は型の名前（作る関数は持たない）。数に入れれば 10。欄 2 つを `probes: Option[ProbeSet]` 1 つにまとめる案は、手で `reflectionProbe` を置く道で `ProbeSet` を組ませることになるので取らない。

**早見表（`agents-pack/AGENTS.core.md`）の行の案**:

| したいこと | 使う API | 使わない物 |
|---|---|---|
| 部屋・くぼみ・建物の中の金属や床が、その場の景色を映す（外の空を映さない） | `assets/<名前>.probes.json` に箱を書く → project.json の `tasks` に `probes` → `bin/fge task probes` → `Probes3d.loadOr` → 毎コマ `Probes3d.applyTo` | 場所ごとに `environmentMap` を差し替えない・空の SH を手で暗くしない |
| 部屋の中の陰が、窓から入る空の青や壁の照り返しの色を拾う・動く人物が暗い所で暗くなる | 同上 + Doc の `irradianceVolume`（場面の環境マップに `withSkyContribution` を付けた時に入る） | ambient を場所ごとに手で替えない・点光源で照り返しを真似しない |
| HDR の空の太陽の方角を回す | `Scene3d.withEnvironmentRotation(ラジアン, env)` | 絵を外の道具で回し直さない |
| Blender で撮った部屋のパノラマを、その部屋の中だけに映す | `Scene3d.reflectionProbe(絵, 箱)` を `reflectionProbes` に（画素を持つ絵・左右を鏡にしてから） | 場面の `environmentMap` の箱で全部の部屋を賄わない |
| 壁や光を替えた | `bin/fge task probes` で撮り直す（`--check` で古いかを見る） | — |

**agent-eval のお題の案（`expect` と `avoid`・書く形に絞る）**:
1. `reflection-probes`「美術館の展示室が 3 つ並ぶ。どの部屋の金の像も外の空を映して白っぽい。部屋ごとの景色を映したい」 — expect `re: "Probes3d\\.(loadOr|applyTo)\\("`・`re: "task probes|probes\\.json"`・avoid `re: "(Probes3d|Scene3d)\\.Internal\\.\\w+\\("`
2. `environment-rotation`「HDR の空の太陽が建物の裏になっている。空を 90 度回したい」 — expect `re: "withEnvironmentRotation\\("`
3. `baked-gi-volume`「洞窟の奥へ歩く人物が、入口の明るさのまま奥でも明るい。奥では暗く、入口の光の色を受けたい」 — expect `re: "irradianceVolume"`・`re: "Probes3d\\.loadOr\\("`

## 10. 段と見積もり（実時間）

| 段 | 中身 | 実時間 | 前に要る物 |
|---|---|---|---|
| R-1 光を合わせる（ゲームの側） | `demo_repro_lab` の `MaterialsScene` で太陽を消し、くぼみごとのスポット 12 本・壁と座面の色・霧 0.002 を Godot に合わせて撮り直し、Godot と並べて残った差を書く。engine は触らない | 0.5〜0.8 | 無し |
| R0 スパイク | **撮る時間（6 面を 1 組描く時間・Material Testers と Bistro）**・atlas の縁と段の選び（鏡と粗い球）・uniform の今の使用量・texture unit と標本の実数（3.3 の表）・WebGPU の group 0 に atlas・CPU の重さ（gallery の 1 枚と `gl-parity-cpu`）・裏の面の印の口・wasm の前 | 1〜1.5 | R-1 |
| R1 回す欄 | `withEnvironmentRotation`・`+er`（空の frag も）・SH の回り・CPU・gl-parity `environmentRotation3d`・テスト | 0.7〜1.0 | R0 |
| R2 probe を読む | 型と欄・選び・積む順・重み・atlas（縁・段・控え）・AST の読み・`LightVariant#perPixelIrradiance` と Codegen・L1 の混ぜ・`+rp`・group 0・CPU の `SoftRaster3d/Probes.flix`・`preloadVariantOf`・`DrawHash`・9.4 の外す順の直し・gl-parity 2 場面・テスト | 5〜7 | R0 |
| R3 撮る道具 | `Scene3d.Internal.ProbeDoc`・`ProbeBake`（撮る場面の決まり・exclude・6 面・写し直し・RGBE・中身の鍵・`--check`）・project.json の task の手本・`Probes3d`（`loadOr`・`applyTo`）・schema・テスト | 2.8〜3.8 | R2 |
| R4 確かめと docs | Material Testers の再現に probe を置いて Godot と並べる（ゲームの側）・docs・早見表・お題・migrations・W1 の門・wasm の後 | 1.5〜2 | R3 |
| G1 volume を読む | 型・atlas の下の行・AST の 8 点 × 4 texel の読み（確かさ・法線・小さい和）・`+gi`・優先の順と k・CPU・gl-parity `irradianceVolume3d`・テスト | 2.5〜3.5 | R4 |
| G2 volume を撮る | 格子の撮り・2 回目は描き直さず足す・確かさ（片面の裏の面）・間引き・baked.json | 2〜3.5 | G1 |
| G3 確かめと docs | Material Testers のくぼみの奥と動く箱・docs・早見表・お題・wasm | 1〜1.5 | G2 |
| レビュー | R2 の後・R4 の後・G3 の後 | 2〜3 | — |

- 和: R-1 で 0.5〜0.8、R0〜R4 で **11〜15.3 時間**、G1〜G3 で **5.5〜8.5 時間**、レビューを足して **19〜27.6 時間**。L5 SSAO（計画 4.5〜6.5 時間で済んだ）の 4 倍前後。見込みの 2 倍を超えたら止めて相談する。
- 区切りのリリースは R4 の後と G3 の後。G 段は R4 の絵を見てから始めるか決める（決め 9）。

## 11. 順と依存・ぶつかる所

```
R-1（ゲームの側）─→ R0 ─→ R1（回す欄・独立に先に入れてよい）
                    R0 ─→ R2 ─→ R3 ─→ R4 ─→ G1 ─→ G2 ─→ G3
空の計画の S 段（空の色から環境マップ）─→ 空の計画の「probe と空」の段（14 節）
```

| 相手 | ぶつかる所 | どうするか |
|---|---|---|
| 描き手の CPU の直し（`WebGpuMaterials`・`SceneList`・`ScenePlan`・`StaticRows`） | probe の値は場面の値（group 0）で渡すので `WebGpuMaterials` は触らない。`ProgramKey` の変種の鍵が増え、材質の pipeline の鍵の作り方に流れる | R2 は W-1 の後を推す（同じ render_gl を 2 人で触らない）。先に入った方に rebase |
| compute | 無し（撮るのは CPU・読みは frag） | — |
| 水（G3 の `SceneDepthDifference`・`withDepthPrepass`・`fresnelAlpha`・`SoftRaster3d.flix` の霧の切り出し） | 水の映り込みは環境マップを読むので `+rp` の場面では probe を読む（同じ差し替えの所）。texture unit の半透明の最悪の組（3.3 の表）。`SoftRaster3d.flix` の残りの行 | 9.4 の数えを直す時に水の組も一緒に。霧の切り出しは先に入った方が |
| L6 多数の点光源 | 変種の旗と group 0 の一覧（`+cl`）・texture unit | v1 は 8 probe で L6 と独立。8 を超える probe を cluster に入れるのは後 |
| L7 volumetric fog | 無し。霧の ambient の項に probe と volume の環境光を入れるかは後 | — |
| 段 1 の残り | **SSR（4a）**: 当たらない画素と粗い面の戻る先が「環境マップ」→ `+rp` の場面では probe の映り込みへ（戻る先の関数を `EnvironmentColor` を作る所 1 つに）。**2c の `occlusionTexture`**: 環境の光に掛かるので probe の環境光と volume にも掛ける。**TAA・contact shadows・カスケード**: 無し | 4a の担当へ戻る先の関数を伝える。順は R2 → 4a を推す |
| デカールの計画 | 無し（板は probe と volume をふつうに受ける） | — |
| 空の計画（`plans/engine-sky.md`） | 空が時刻で変わると、撮った probe の空の画素と環境光が古くなる | 14 節の段（空の画素を印で抜いて撮り、読む時に今の空を足す）を空の計画の後ろの段に。v1 の probe は「光が決まった場面」用と docs に |

## 12. 重さ・スマホ・wasm

| 物 | PC（M4 Pro・1080p） | S24（WebGPU） | wasm（brotli） |
|---|---|---|---|
| probe の映り込み（画素ごとに箱 8 つ・読み 2〜3 回） | GPU +0.2〜0.5 ms（推測） | +0.6〜1.5 ms（推測） | R 段で推測 +8〜14 KB |
| probe の環境光（L1 の混ぜ） | +0.05 ms 未満 | +0.1〜0.2 ms | 上に含む |
| atlas の作り直し（選びが替わった時） | CPU 3〜6 ms（推測） | wasm 15〜30 ms（推測・数秒に 1 回） | — |
| volume（32 回の読み） | GPU +0.25〜0.5 ms | +1〜2 ms | G 段で推測 +3〜5 KB |
| 回す欄 | 0 に近い | 0 に近い | +0.5 KB |
| CPU の描き手（gallery の 1 枚） | 推測 +5〜15%（R0 で測る） | — | — |

- **Low で切る所**: (1) probe は**近い 2 つまで**（選びの数を Low で 2）。(2) volume は**切って** probe と空の SH へ戻る（S24 で 32 回の読みは重い）。(3) atlas の枠を 128 × 64 に。場面の値なので、ゲームが `PostStack.resolveQuality` を見て書く形（L6 と同じ決め・決め 8）。
- **使わないゲームの wasm**: probe と volume の読みは描き手の中にあるので、使わないゲームにも選び・atlas の Flix が届く（推測 +4〜7 KB・W2 の門 +3% の内）。R0 で測り、気になれば compute の計画と同じく入口を分けるかを決める。

## 13. 人に決めてほしい事（推す答えつき）

1. **reflection probe を画素ごとの重みで混ぜる形（Godot 4・Unity URP Forward+）にするか** → する。Godot の Material Testers は layer の mask で「置いた物ごとの probe」を作っているが、置いた物ごとの形は床のような大きな物で切り替えが見え、staticGroup の束ねも割れる。置いた物に probe を指す欄（Godot の `reflection_mask`・Unity の Anchor Override）は要るゲームが出てから。
2. **probe の景色は engine が CPU の描き手で前もって撮り、読み込みでは撮らないか** → そうする。撮った物は git に入れる。
3. **probe が撮った景色の SH（L1）を箱の中の環境光に使うか（`irradianceFromCapture`・既定 true）** → 使う。場面の環境マップに `withSkyContribution` が無い場面では使わない（今の絵を変えない）。
4. **atlas を 1 枚にし、volume の値も atlas の下の行に入れ、場面の環境マップは別に読むか（texture unit +1・標本 +1）** → そうする。
5. **回す欄はラジアンで受け、変種 `+er` の uniform で入れ、SH は CPU で回すか** → そうする。
6. **texture unit の外す順を `+ssr` → `+ao` → `+gi` → 材質の絵 → `bug!` にし、`+rp` は外さないか** → そうする（L 計画 9.4 の文とテストを R2 で直す）。
7. **環境光を画素ごとに混ぜるため、`LightVariant` に旗 `perPixelIrradiance` を足し、`IrradianceSh` を画素ごとの値で読めるようにするか** → する（光の式の木の読み方の変更・偽の版の字は同じ）。
8. **Low の切り方（probe 2 つ・volume を切る・枠 128）をゲームが `resolveQuality` を見て書く形にするか** → する。S24 の測りで足りなければ engine で切る API を相談する。
9. **G 段は R4 の絵を見てから始めるか** → そうする。R で差が埋まれば G は動く物と奥の隅のための段として後へ回してよい。
10. **撮る側は CPU の描き手で始め、R0 の測りで重ければ GPU の headless の撮りを足すか** → そうする。GPU で撮ると撮り直しのバイトが機械で変わるが、読む側の 4 つの描き手の答えは同じ。
11. **R-1（ゲームの側で光の組み方を Godot に合わせて撮り直す）を R0 の前に入れるか** → 入れる。差の原因を分けてから R 段の大きさを決める。
12. **外の道具の probe（Godot の LightmapGI・Blender）の持ち込みは、格子の L1 の JSON を読める形だけ用意し、書き出しの台本は要るゲームが出てからにするか** → そうする。
13. **新しい pub 8（型を数えて 10）を了承するか** → 了承を。

## 14. 範囲の外

| 物 | 順 |
|---|---|
| 実行中に probe を撮り直す（時刻・動く扉） | 空の計画の後ろの段（空の画素を印で抜いて撮り、今の空を足す）が先。全部を撮り直すのは compute の後に相談 |
| GGX で前もってぼかした段 | 環境マップと probe を一緒に直す（撮る道具の中で前もってぼかせる。R3 の後に相談） |
| 8 を超える probe（cluster） | L6 の後に相談 |
| 置いた物ごとに probe を指す欄（`reflection_mask`・Anchor Override） | 要るゲームが出てから |
| SSGI（案 B） | TAA・SSR の後の上乗せ（人の決め） |
| ボクセル・SDF の動く GI（案 C） | 当面やらない（人の決め） |
| 平面の鏡 | 取らない（水の計画と同じ） |

## 出典にした場所

- engine: `scene3d/Scene3d.flix`（`EnvironmentBox` 839・`EnvironmentMapFields` 842・`environmentMap` 856・`withSkyContribution` 864・`withIrradiance` 874・`Scene3dCmd` 736 行）・`scene3d/SphericalHarmonics.flix`・`scene3d/LightModel3d.flix`（`Vec3Input` 154・`skyIrradiance` 268・`environmentLodOf` 407 行）・`LightModel3d/Codegen.flix`（`isPerPixel`・`glslUniformOf`・`vec3InputCode`）・`Scene3d/Internal/SkyIrradiance.flix`・`scene3d/Texture3d.flix`・`shader/ShaderJson.flix`
- render_gl: `Render3dShaders.flix`（`environmentColorAt` 383 行）・`Render3d/ProgramKey.flix`（`Group0Binding` 18 行）
- engine_tools: `SoftRaster3d/Internal.flix`（`EnvironmentLookup` 14・`environmentColorAt` 87 行）・`SoftRaster3d/Targets.flix`（`drawSceneHdr` 59 行）
- `gates.json`（層の向き）・`go/cmd_launch.go`（`runTask`）・`templates/retro3d-horror-starter/project.json`（`tasks`）
- docs: `docs/scene3d.md`（373〜430 行）・`docs/lightmap.md`・`docs/error-handling.md`
- 計画: `plans/engine-environment-map.md`・段 1 計画（4a・2c）・L 計画（9.1・9.4・3.4・5 節）・`plans/engine-round9-lightmap.md`・水の計画（3.3）
- ゲーム: `~/Documents/flix_ge_workspace/demo_repro_lab`（`src/MaterialsScene.flix`・`tools/perf/SUMMARY-2026-11-27.md`）・元の場面 `~/Documents/flix_ge_workspace/demo_repro_downloads/gdp/3d/material_testers/`（`material_tester.tscn`・`models/test_bed/test_bed.tscn`・`tester.gd`）
- 他のエンジン（考え方だけ）: Godot 4 の ReflectionProbe（`box_projection`・`blend_distance`・`ambient_mode`・`reflection_mask`）と LightmapGI の probe・Unity の Reflection Probe（Blend Distance・Importance・Box Projection・Anchor Override）と Adaptive Probe Volumes（L1・normal bias・validity）・Unreal の Reflection Capture

## レビューへの答え（1 回目 66 点）

- 必須 1（Godot の作りの見立て）: 元の場面のファイルで 2 節を書き直した（太陽は消え・くぼみごとのスポット・probe は球だけに layer の mask で効く）。engine を触らない R-1 を足し、0 節の太字の主張を外し、決め 1 に Godot の作りを正直に書いた。
- 必須 2（層の向き）: Doc の型と読みを engine の `Scene3d.Internal.ProbeDoc` に置き、ファイルは呼び手が読む形に。読み込みの判定は Doc の中身の鍵だけ、場面の変化は `--check` で（4.1・4.2）。
- 必須 3（光の式の木を変えないは誤り）: `LightVariant#perPixelIrradiance` と Codegen の読み方の変更、CPU は配列 1 本の使い回しを書き、R2 を +1.5〜2 時間（3.4・決め 7）。
- 必須 4（texture unit の数え漏れ）: atlas に volume の行を入れて `+rp` と `+gi` で 1 枚に。不透明・半透明の組ごとの表と標本の数（3.3）・外す順（決め 6）。
- 必須 5（13 個が 3 texel に入らない）: 1 点 4 texel・32 回の読みに直し、重さの表も（5.2・12 節）。
- 必須 6（機種の側の絵）: probe は画素を持つ絵だけ・機種の側は落として知らせる・`colorSpace` は絵から（3.1）。
- 必須 7（撮る時の自己遮蔽とほかの probe）: 撮る場面は `reflectionProbes = Nil`・`exclude`・撮る点が物の中なら `Err`（4.2）。
- 必須 8（目に依る順・コマをまたぐ控え）: 積む順は priority → 体積 → 列の順。選びはコマの純粋な関数で、余白は広げた視錐台で（3.2）。
- 必須 9（環境マップの無い場面・k・強さ）: 3.2 の 4 と 3.4 に式を全部書いた。volume も k を通す（5.2）。
- 必須 10（継ぎ目と段）: 枠ごと・段ごとの 1 texel の縁（左右は反対の列）・8 × 4 で止める・空と同じ角の段を読む式（3.3）。
- 必須 11（撮る時間）: R0 の測りを太字に、影の地図の使い回し・近い物だけ・2 回目は描き直さず足す・格子を粗く・GPU の撮り（決め 10）を書いた（4.2・5.3）。
- 推奨: 1 lightmap の使い回しの節 5.5 と外の probe の持ち込みの比べ（決め 12）／2 欄を `irradianceFromCapture` と `irradiance` に・SH は絵から Lazy・baked.json に持たない／3 probe の絵を `textures` に足さない／4 project.json の `tasks` の形に／5 `loadOr` は Doc が無ければ黙る／6 変種の旗の表（6 節）／7 撮る時は霧を切る／8 小さい和の混ぜと両面の材質／9 機械をまたぐバイト／10 atlas の鍵は中身の hash／11 CPU の重さを R0 で／12 時間の和を出し直した／13 `SoftRaster3d.flix` の行を水と分け合う。
- 軽微: ラジアンで受ける・テストは列の境に乗る角で／`boxProjection` の既定 true の理由／左右の鏡／お題の正規表現を書く形に絞り、お題 1 に撮る手順・お題 3 に `irradianceVolume` を必須に／行数は今の 1,181（水の計画を書いた時は 1,184）／欄を 1 つにまとめる案を 9 節に。

## 測った値（各段の後にここへ足す）

（未）
