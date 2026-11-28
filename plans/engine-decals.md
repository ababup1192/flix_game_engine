# デカール（壁の汚れ・血・弾痕・道路の標示を、形を作らずに貼る）— 計画（相談用・未着手）

状態: 了承（2026-11-27・14 節の 8 つとも推す答えで）・D0 から実装中。計画書は git に入れない。engine は読んだだけで書き換えていない。engine の拡張なので、人の了承の後に段ごとに実装する。
書いた日: 2026-11-27。main 16cec8709（L5 SSAO・W1 は main に入り済み・水 G0〜G4 は了承済みで未着手）。
**事実** はソースか docs の引用（`bin/fge refactor` で引いた所を書く）。**推測** は「推測:」と書く。時間は実時間。
レビュー: 1 回目 74 点（必須 5・推奨 9・軽微 6）→ 2 回目 84 点（必須 3・推奨 4・軽微 3）→ この版で全部に手を入れた（末尾の「レビューへの答え」）。
重なる計画（二重に書かず指す）: `plans/engine-water.md`（「水の計画」）・`plans/engine-render-look-l5-l7.md`（「L 計画」）・`plans/engine-render-stage1.md`（「段 1 計画」）・`plans/engine-render-cpu-cache.md`（「CPU の直しの計画」）・`plans/engine-gpu-compute.md`（「compute の計画」）。

## 0. 結論

1. **v1 は「形の上に薄い板を貼る」デカール（mesh decal）にする**。デカールの箱の中に入る的の三角形を CPU で箱の 6 面で切り、その上に薄く浮かせた形を作って、普通の置いた物（`Instance3d`）として返す。Source エンジンの overlay・Unreal の mesh decal・Unity の Decal Projector を「前もって形にする」側で使う形と同じ考え。
   - **1 回の呼び出しで受けたデカールの列を、(的, 材質, lightmap) ごとに world の座標の 1 つの形へつないで返す**（world は単位行列）。半透明の物は staticGroup で持ち越されず、つながれもしない（`docs/scene3d.md` 534・540 行）ので、つなぐのは `buildInstances` の仕事にする。的（部屋・建物の part）ごとに分けるので、形の境界は的の境界の内に収まり、ほかの半透明の物（窓・水・煙の板）との遠い順の並びと視錐台の外し方は今の置いた物と同じに働く。draw は的の数 × 材質の数。つないだ形の中は列の順に描くので、**列の後ろのデカールが上**に決まる（Unity の Decal の Draw Order と同じ考え）。
   - 段ごとの描き手の変え方: **D1 は描き手（GL・WebGL2・WebGPU・CPU の SoftRaster）を何も変えない**（ふつうの半透明の物として描く。4 つの描き手で同じ絵の道を通り、gallery と agent-eval の絵（CPU）にもそのまま出る）。D2 は材質の内側の旗 1 つ（AO を受ける）で、GPU の材質の字の変種 1 つと CPU の半透明の塗りの条件 1 か所。D4（条件つき）は pipeline の深度のずらし。
   - 的の頂点の色（horror の校舎のベイクした明るさ）と 2 本目の uv（lightmap）を写すので、**ベイクした光の中でも汚れが浮かない**。
   - 画面の奥行き（L5 の `ps_depth_far`）を使う箱のデカールは v1 に採らない（2 節: PostStack の一番大きい場面・`Resolution.Native`・R32F の描き先が要り、retro3d-horror-starter の 320×240 の Design の場面では使えない。場面も 1 回多く描く）。
2. **ゲームが見る pub は 3**（9 節に「いつ使うか」を 1 行ずつ）: `Decal3d.Decal`（record）・`Decal3d.decal`（既定値つきで作る）・`Decal3d.buildInstances`（デカールの列を的に投げて、つないだ置いた物を作る・高い）。切る式・属性の写し・つなぎ・浮かせる量の決め・内側の旗は `Decal3d.Internal` と `Scene3d.Internal`（forbid の `app-internal` に `Decal3d`・`Scene3d` を足す）。
3. **段（実時間）**: D0 スパイク 0.5〜0.8・D1 本体 2.3〜3.3・D2 AO を受ける例外 1〜1.5（CPU の半透明の塗りを別ファイルへ出す下ごしらえを含む）・D3 docs と門 0.8〜1.2 = **4.6〜6.8 時間**、レビュー 1〜1.5・ゲームの側の確かめ 1〜1.5 を足して **6.6〜9.8 時間**。条件つき: D4 深度のずらし（描き手の pipeline）1〜1.5・後ろの段 D5 描き手の中のデカール（clustered decals）4〜6。
4. **wasm**: 描き手から届かない純粋な関数だけなので、使わないゲームには入らない（推測: TeaVM が呼ばれない関数を落とす。D0 で `wasm-size --diff` を取る）。使うゲームで推測 +3〜6 KB。
5. **既定の絵は 1 画素も変わらない**（`Decal3d` を呼ばない場面は形も字も同じ）。D2 の旗は既定 false で、立てない材質のプログラムの鍵と字は今と同じ。

## 1. 今の engine の事実（この計画で引いた所）

| 事実 | 根拠 |
|---|---|
| `Mesh3d` は閉じた型で、`positions`・`normals`・`colors`・`indices`・`uvs`・`uvs2`・`tangents` を pub で読める。作るのは `fromArrays`・`withUvs`・`withUvs2`。タンジェントは uv から Lazy で求める | `refactor outline engine/src/scene3d/Mesh3d.flix`（561〜589 行・85・133・277 行） |
| 置いた物の中身は `{ mesh, world, tint, material, pose, lightmap, name }`。tint は頂点の色に掛ける色 | `refactor show Scene3d.InstanceFields`（447 行） |
| 材質の `blend` は「深度は読むが書かない」半透明。半透明の物は world の境界の真ん中が目から遠い順に描き、物の中の三角形は並べ替えない | `refactor show Scene3d.MaterialFields`（232 行）・`docs/scene3d.md` 586〜600 行 |
| 絵つきの材質は「絵 × 頂点の色」。horror の校舎は明るさを頂点の色にベイクしてある（`scaleVertexColors(2.0)` の形） | `docs/scene3d.md` 307〜335 行・`templates/retro3d-horror-starter/AGENTS.local.md` |
| lightmap は置いた物ごとに付き、2 本目の uv で読む（`withLightmap`・`uvRect` で atlas の矩形） | `refactor show Scene3d.withLightmap / Scene3d.Lightmap`（454・588 行） |
| 当たりは `Ray3d.hitInstance`（骨つきは境界の箱だけ）。`RayHit` は距離・点・面の向き | `docs/scene3d.md` 943〜962 行 |
| 描き手の pipeline に深度のずらし（polygon offset・depth bias）は無い。WebGPU の Dawn は `setDepthBias(0)` の固定 | `refactor search depthBias / PolygonOffset`（材質の欄に無し）・`render_gl/java/fge/webgpu/dawn/DawnWebGpu.java` 503〜505 行（Java なので grep） |
| L5 の奥行きの絵（`ScreenInputs#depth` = R32Float・赤が目からの距離 / depthRange）は PostStack が一番大きい 3D の場面 1 つにだけ描き、`Resolution.Native` の場面だけ（Design は `Issue.AmbientOcclusionNeedsNative`）。R32F の描き先を作れない WebGL2 は技を切る | `refactor show Scene3d.ScreenInputsFields`（757 行）・`refactor search Resolution`（`PostStack.Issue.AmbientOcclusionNeedsNative`）・`docs/scene3d.md` 699〜720 行 |
| retro3d-horror-starter の場面は `Scene3d.Resolution.Design`（320×240） | `cd templates/retro3d-horror-starter && refactor usages Scene3d.Resolution.Design`（`SchoolView.sceneOf`・`overlayOf`） |
| AO は「環境の光と lightmap」に掛かり、「環境マップの映り込みと半透明の物には掛からない」 | `docs/scene3d.md` 710 行 |
| 半透明の物は staticGroup で持ち越さず毎コマ instances と同じに計画し、形のつなぎ（同じ材質の物を 1 つの形にする）からも外れる。lightmap つき・法線マップの材質もつながない | `docs/scene3d.md` 534・540 行（レビューで確かめ） |
| GPU で半透明が AO を受けない条件は `Render3dShaders.flix` 651 行の `screenAo = not surface#blend`（材質の字が変わる）。CPU は `SoftRaster3d.flix` 523 行で半透明の物を全部 1 つの env（`ao = None`）で塗る | レビューで `refactor show` と grep（record の欄）で確かめ |
| `Scene3d.flix` は 1,068 行・`SoftRaster3d.flix` は 1,181 行（上限 1,200） | `wc -l` |
| 動かない物は `Scene3d.staticGroup` で 1 回作り Resources に持つ決まり（毎コマ作り直さない） | `docs/scene3d.md` 514〜530 行 |
| デカールに当たる名前（`Decal`）は engine に 0 件 | `refactor search Decal` |

## 2. 作り方の候補と比べ

| 案 | 形 | 光の正しさ | 4 つの描き手 | 動く物・骨つき | 重さ | 他の作業とのぶつかり |
|---|---|---|---|---|---|---|
| **A. 形の上に薄い板（mesh decal）** ← 推す | 箱の中の的の三角形を CPU で切り、少し浮かせた形を作って半透明の置いた物で描く | 板が自分で光を受ける。的の頂点の色と uv2（lightmap）を写すので、ベイクした光も同じ | **D1 は描き手を変えない**。CPU も同じ道 | v1 は動かない的だけ（動く的は 13 節）。骨つきは黙って飛ばす | 作る時: 的の三角形の数に比例（推測: 10 万三角形で JVM 1〜3 ms・wasm 5〜15 ms）。描く時: (的, 材質, lightmap) の組の数だけ draw（つないで返すので。staticGroup ではまとまらない） | ほぼ無し（engine だけ） |
| B. 画面の奥行きを読む箱（screen-space / deferred 風） | 箱を描き、画素ごとに `ps_depth_far` から位置を戻して箱の中なら絵を重ねる（Unity URP の Screen Space Decal） | 暗くする掛け算（血・すす・しみ）は照らした後の色に掛けるので、ベイクした光も灯りもそのまま入る。**色を置き換える物（白い標示・張り紙）**は forward の描き手では下の面の光が分からず、奥行きから法線を作って光を引き直す（縁が崩れ、頂点の色と lightmap のベイクした光は入らない） | 色の pass と半透明の間に新しい段を 3 つの描き手と CPU に足す | 動く物にも骨つきにも乗る（奥行きの上なので） | 描く時だけ（画素 × 箱） | 奥行きの絵が無い場面（Design・2 つ目からの場面・R32F の無い WebGL2）で使えない。奥行きの場面が無いと場面を 1 回多く描く。L 計画・段 1 の `ScreenPasses` の表と同じ所を触る |
| C. 材質の絵に描き込む（texture painting） | 的の uv2 の空間に置いた物ごとの絵を持ち、そこへ描き込む | 正しい（材質の一部になる） | 材質の絵が 1 枚増える（texture unit の予算 18 の問題に乗る） | uv2 を持つ物だけ | 描く時 0・描き込む時に絵の上げ直し。置いた物ごとに絵（場面の絵の予算 64 枚・256 MB） | staticGroup の束ねが絵ごとに割れる |
| D. 描き手の中のデカール（forward / clustered decals） | 材質の frag が画素の world の位置で箱の列を回し、光の前に albedo・法線・roughness を書き替える（Godot 4 の Decal・Bevy の ClusteredDecal） | 一番正しい（光の前に材質を変える） | 全部の材質の frag に変種 `+dc`・atlas の絵 +1（予算 18 → 19）・CPU の材質の式にも同じ式 | 乗る（world の位置で読む）。歩く人物にも乗るので層の mask が要る | 画素 × 箱の数。8 枚を超えると L6 の cluster の表が要る | L6・CPU の直しの計画・段 1 と同じ所を触る |

**推す: A を v1 に**。理由:
1. 手本の 3 つ（PS1 風ホラー・HD-2D・夜の町）の汚れ・血・標示・弾痕は、どれも**動かない壁と床**に貼る物。
2. horror の場面は Design の 320×240 で、B の奥行きの絵が無い。A は場面の作りに依らない。
3. 色を置き換える物（白線・張り紙・落書き）も正しく照らせる。horror の明るさは頂点の色にベイクしてあり、A は頂点の色を写すので、暗い廊下の奥の張り紙は暗く、灯りの下は明るい。B は掛け算の物にしか正しくない。
4. D1 は描き手を変えないので、CPU の直し・水・L6・L7・段 1 の作業とぶつからない（11 節）。
5. D（描き手の中のデカール）は「動く物・骨つきにも乗る・数百枚」の需要が出た時の後ろの段 D5 に置く。L6 の cluster の表を使い回す（Godot 4 は灯りとデカールを同じ cluster に入れる）。

**L5 の奥行きの絵を使い回せるか**: B なら使えるが、上の 2・3 で v1 の主の道にしない。A は奥行きの絵を読まない。ただし AO の mask は、A の板の真下の不透明な面の値なので、**デカールの板は AO を受けてよい**（水の板と違う）。これを D2 で入れる（4 節）。

## 3. 形（ゲームの書き方）

```flix
// 読み込みで 1 回（動かない汚れ・標示）: staticGroup に入れる「前」の置いた物の列を的に渡し、結果を Res に持つ
let walls = Model3d.partInstances(world, school)                  // この列を staticGroup にも渡す
let stains = Decal3d.buildInstances(
    { size = Vec3.v3(0.8, 0.6, 0.3) | Decal3d.decal(grime, Vec3.v3(3.2, 1.1, -7.0), Vec3.v3(-1.0, 0.0, 0.0)) } ::
    { size = Vec3.v3(1.2, 0.4, 0.3), uvRect = crackRect | Decal3d.decal(grime, Vec3.v3(5.0, 0.0, -6.0), Vec3.v3(0.0, 1.0, 0.0)) } :: Nil,
    walls)                                                        // List[Instance3d]（貼れた的ごと × 材質の数）
{ groups = res#school :: Nil, instances = res#stains ::: movers | base }

// 当たった時に 1 回（弾痕）: 的の列は pickNearest に渡した鍵から引く
match Ray3d.pickNearest(ray, 50.0, rayTargets) {                 // rayTargets: List[(WallId, RayTarget)]
    case Some((wallId, hit)) =>
        let hole = { size = Vec3.v3(0.12, 0.12, 0.1), rotation = rand * 360.0 | Decal3d.decal(holeMaterial, hit#point, hit#normal) };
        Decal3d.buildInstances(hole :: Nil, instancesNear(wallId))  // instancesNear はゲームの側の関数。結果を Resources の控えに足す（毎コマ呼ばない）
    case None => …
}
```

- `Decal3d.Decal`（record・欄は既定値から `{ … | Decal3d.decal(…) }` で替える。水の `Water3d.Settings` と同じ決まり）:
  - `material`: ふつうの `Scene3d.Material3d`（絵・法線マップ・metallic と roughness・emission もそのまま効く）。`blend` も `cutout` も偽なら `buildInstances` が `withAlphaBlend(true)` にする。
  - `center`・`normal`: 貼る点と、貼る面の向き（箱は −normal の向きへ投げる）。`RayHit` の点と面の向きをそのまま渡せる。
  - `size`: 箱の幅・高さ・奥行き（場面の長さ・既定 1 × 1 × 0.5）。**箱は center から前後へ奥行きの半分ずつ延びる**（Unity の Decal Projector と同じく前後対称）。奥行きは面のでこぼこを拾う厚み。
  - `rotation`: normal を軸にした回り（度・既定 0）。同じ弾痕を回して並べ違える（同じ物を並べない決まり）。
  - `uvRect`: 絵の中で読む矩形（0..1・既定は全部・`Lightmap#uvRect` と同じ意味）。1 枚の atlas に血・すす・ひびを並べ、材質を 1 つにすると 1 回の呼び出しが draw 1 本になり、重なりの順も列の順に決まる。
  - `angleCutoff`: 投げる向きと面の向きの角がこれを超える三角形は貼らない（度・既定 70）。床に投げた血が壁を這い上がらない。
  - `offset`: 面から浮かせる量（場面の長さ・既定 None = 幅と高さの短い方の 1%）。
  - `decal(material, center, normal)` は Vec3 を 2 つだけ受け、大きさは欄で替える（同じ型を 3 つ並べると AI が取り違える。AGENTS の「取り違えは型で止める」の手前の工夫）。
- `Decal3d.buildInstances(decals: List[Decal], targets: List[Instance3d]): List[Instance3d]`:
  - デカールごと・的ごとに、境界の箱が当たる物だけ切る。切った三角形を **(的, 材質の鍵, lightmap の鍵) の組ごとに 1 つの形へつなぎ**、world の座標のまま（置いた物の world は単位行列）返す。形の中の三角形は**デカールの列の順**に並べる（後ろが上）。名前（`withName`）は `<的の名前>:decal`（材質が 2 つ以上なら `:decal<番号>`。的に名前が無ければ `decal`）。
  - **材質の鍵**（`Material3d` は Eq を持たない閉じた型なので、`Decal3d.Internal.Merge` が字の鍵を作る）: `Scene3d.StaticBatch.materialKeyOf` の字（shaderHash・wrap・cutout・doubleSided・emissionIntensity・maxMipLevels・絵・params）に、**blend・normalMap（絵と強さ）・metallicRoughness・emission の色・`screenAoOnBlend`** を足した物。`materialKeyOf` は staticGroup がつながない材質（法線マップ・半透明）の欄を見ないので、そのまま使うと法線マップの有る血と無いしみが 1 つの形になって先頭の材質で描かれる。足した鍵を `Scene3d.Internal` の `fullMaterialKeyOf` に置き、`materialKeyOf` を土台にする（2 本の鍵がずれないよう、テストで「欄を 1 つずつ替えた材質は全部違う鍵」を回す）。
  - **lightmap の鍵**: `uvRect` を全部に直した後の `Lightmap` の値まるごと（絵・colorSpace・強さ・段の上限。型の doc に「欄は後から増えうる」とあるので、欄を並べず record の ToString か Eq で）。
  - 的の頂点の色に的の tint を掛けた物を、切った点へ写す（三角形の中は重心の割合でつなぐ）。uv2 も同じく写し、的の `Lightmap#uvRect` を uv2 に先に掛けてから、矩形を全部にした同じ絵の `Lightmap` を付ける（違う矩形の的どうしを 1 つの形につなげる）。
  - 骨つきの的（`pose` が Some か形に skin がある）・MultiMesh3d・ビルボードは的にならない。`List[Instance3d]` の骨つきは飛ばし、`Log.warnThen`（純粋な関数の中で知らせる道・`docs/error-handling.md`）で 1 行言う（`@decal-skinned-target`・的の名前つき）。docs と早見表にも「骨つきには貼らない」を書く。
  - 1 つの的にも貼れなかった（箱が当たらない・全部 `angleCutoff` で落ちた）時は空の列。
  - 半透明の的（ガラス）は飛ばして同じく 1 行言う（`@decal-blended-target`。板と的の境界の真ん中がほぼ同じで、並びが決まらない。v1 の範囲の外）。弾が何にも当たらない時（箱が当たる的が無い）は黙る。
- 動詞は `build*`（AGENTS の命名: 計算して作る・高い）。**毎コマ呼ばない**（staticGroup と同じ決まり。docs と早見表に書く）。弾痕は「当たった時に 1 枚ずつ作って控えに足す」か「上限 64 枚の列を当たるたびに全部作り直す」のどちらかで、手本の形は D0 で決める（13 節）。
- **cutout の材質の板**は不透明の道を通るので、staticGroup に入れて持ち越せる（ただし lightmap つきの的から写した板はつながらない・`docs/scene3d.md` 540 行）。重なりの順を気にしない汚れ（PS1 風のディザの汚れ）はこちらが軽い。docs と早見表で blend と cutout を分けて書く。

## 4. 中でする事

### 4.1 切る（`Decal3d.Internal.Clip`）

1. 箱の行列 B（center・normal・rotation・size から。normal に平行でない up を決めて組む。normal が真上・真下に近い（|normal.y| > 0.999）時は −Z を up に）を作る。
2. 的ごとに: 的の world の境界の箱と B の箱が交わらなければ飛ばす。
3. 三角形ごとに: 頂点を **world へ写し**（`world × p`）、さらに箱の中の座標（`B⁻¹ × p`。B は center・向き・size から組む行列で、size の各辺が 0 より大きい事を `decal` の既定と丸めで保つ）にする。箱の中の座標の三角形の箱が [−0.5, 0.5]³ と交わらなければ外す → world の面の向き（三角形の幾何の向き）と投げる向きの角で `angleCutoff` → [−0.5, 0.5]³ の 6 面で Sutherland–Hodgman で切る（多角形は最大 9 点）→ 扇に分けて三角形にする。的の world の逆行列は使わない（大きさ 0 の三角形は面積 0 で外す）。
4. 切った点の属性: 位置（箱の中の座標から uv = (x + 0.5, 0.5 − y) を `uvRect` へ写す・world の位置は B で戻す）・法線（的の法線を world の 3×3 の**余因子行列**（cofactor・逆行列の転置に行列式を掛けた物）で写して重心でつなぎ、長さ 1。割り算が無く、大きさ 0 の的でも壊れない。長さ 0 になった法線は三角形の幾何の向きで代える）・頂点の色（的の色 × tint）・uv2（4 節の 3 の `uvRect` を掛けた後）。位置を **world の法線の向きへ `offset`（場面の長さ）**だけ浮かせる。world の座標で出すので、的の world の大きさ（cm の glb を 0.01 倍で置く・一様でない大きさ）で浮く量と角が変わらない。
5. `Mesh3d.fromArrays` → `withUvs` → uv2 があれば `withUvs2`。法線マップ用のタンジェントは `Mesh3d` が uv から求める。
- 数値は Float64 の四則と `sqrt` だけ（三角関数は `rotation` から箱の行列を作る所の 1 回の sin・cos。JVM と wasm で最後の bit が違いうるが、形の 1e-15 の差で絵は変わらない）。同じ入力で同じ形（headless の決定性）。
- 的の三角形の数に比例する。推測: 10 万三角形の的で 1 枚 JVM 1〜3 ms・wasm 5〜15 ms（三角形の箱で外す所が主）。D0 で Bistro の建物の 1 つで測る。重ければ段 1 の外の候補の BVH（K8 の pick の BVH）が入った時に使い回す（13 節）。
- **頂点の色の色空間**: 絵つきの板は「絵 × 頂点の色」を画面の値どうしで掛ける（`docs/scene3d.md` 330 行）ので、材質のある的から写した色は的と同じ明るさになる。材質の無い的（頂点の色だけ）は「頂点の色を線形へ戻してから光」なので、そこに絵つきの板を貼ると板の方が少し明るく見える（2 倍のベイクで目立つ）。docs に 1 行書き、テストの期待値もこの式で取る。

### 4.2 描き手の側（D2・材質の旗 1 つ）

- 返す材質に内側の欄 `screenAoOnBlend = true`（振る舞いで名付ける。水の G3 の「半透明は受けない」と同じ所の例外。`Scene3d.Internal` の API で立てる・ゲームの API にしない）を立てる。
- **AO**: 今は半透明の物は AO を受けない（GPU は `Render3dShaders.flix` 651 行の `screenAo = not surface#blend`）。デカールの板は奥行きの絵に入らないが、その真下の不透明な面は入っているので、AO の mask の値はちょうど下の面の値になる。だから旗の立った材質だけ受ける（受けないと、隅の暗がりの上の血だけ明るく浮く）。
  - GPU: 条件を `not surface#blend or surface#screenAoOnBlend` にする。材質の欄で GLSL・WGSL の字が変わるので、`ProgramKind` に旗 1 つ（今の `+bl`・`+ds` と同じ扱い）と材質の鍵の字（`+ab`）に入れる。**旗を鍵に入れるのは場面の変種が `+ao` の時だけ**（`variant#ambientOcclusion and screenAoOnBlend`）。AO の無い場面で同じ字のプログラムを 2 回組まず、W1 の記録も増やさない。
  - CPU: `SoftRaster3d.flix` 523 行で半透明の物は全部 1 つの env（`ao = None`）で塗っている。**D2 の頭で半透明の塗りの道を `SoftRaster3d/Blended.flix` へ出し（絵は変わらない・1,181 行の本体は呼ぶ 1 行）**、そこで材質ごとに env を選ぶ。
  - 水の計画の G3 も同じ所に「半透明の材質は受けない」を書くので、文は「半透明は受けない・ただし `screenAoOnBlend` は受ける」に 1 本でそろえる（11 節）。
- 鍵: `ProgramKind` と `DrawHash` に入る。旗を立てない材質と AO の無い場面は字も絵も同じ。
- **W1（ブラウザ版のシェーダーの字を書き出しの時に作る）**: `+ab` は新しい材質の鍵なので、デカールを使うゲームは PC で遊んで `web/shader-variants.json` に記録してから書き出す（記録に無い鍵は fail-open で頂点の色で描かれる。agent-eval の `web-shader-variants-missing` と同じ症状）。docs と早見表に 1 行。門は 2 つ: (1) render_gl の単体テストで、記録に `+ab` の行がある時に書き出しの時の生成がその変種を作る事、(2) 6 節のゲームの側の試しを書き出して fail-open を数える（`make web-load-check` はデカールの無い retro3d-horror-starter を書き出すので、そこでは確かめられない）。D4 も pipeline の鍵が増えるので同じ。

### 4.3 並びと半透明

- 結果は (的, 材質, lightmap) ごとに 1 つの形で、中は列の順（後ろが上）。**同じ的の上で違う材質のデカールどうしを重ねると、形の境界の真ん中で並ぶので歩くと前後が入れ替わりうる**。重ねる物は同じ材質（atlas の `uvRect`）にまとめる、と docs と早見表に書く。
- 形は的ごとなので境界は的の内に収まる。壁の板の手前のガラス窓は、窓の方が近ければ後に描かれて正しく重なる（今の置いた物どうしの並びと同じ条件。的が大きな 1 枚の床なら、その床の板の形も大きくなる。docs に「大きな的は部屋・区画ごとの part に分けてあると並びが崩れにくい」を 1 行）。
- 水の計画の `withDepthPrepass` の水は「水の下の半透明の物は隠れる」。**川底・池の底に貼った blend の板は水の下で消える**（docs に 1 行。見せたい時は `cutout` の材質にする: cutout の板は不透明の物と一緒に深度を書くので水の下でも見える）。
- PS1 風（`withPsx`）: 板の頂点も画面の画素へ寄せるので、壁の頂点とは別の点で寄る。推測: 320×240 で板が壁に対して半画素ほど泳ぐ・寄った板が壁の後ろへ半画素もぐって欠ける所が出うる・アフィンの uv の歪みは板と壁で別に出る（PS1 の実機の貼り物と同じ崩れ）。D0 で horror の廊下で見る。もぐりが目立てば psx の場面だけ `offset` の既定を上げる。

## 5. 浮かせ方と、深度のずらし（D4・条件つき）

- v1 は**法線の向きへ浮かせるだけ**（描き手を変えない）。推測: 1 cm 浮かせると、near 0.1・far 200・24 bit の奥行きで 50 m 先まではちらつかない（その距離の奥行きの 1 段 ≈ 1.5 mm）。HD-2D の町（far 60）と horror の廊下は届く。
- 遠くの道路の標示（Bistro の通り・far 1000 の場面）でちらつくなら D4 を入れる: 材質の内側の欄 `depthBias`（傾きに比例する分と定数の分）を pipeline に渡す（GL の `glPolygonOffset`・WebGPU の `depthBias`・`depthBiasSlopeScale` を **Dawn と、ブラウザの WebGPU の pipeline を作る JS の側の両方**・CPU の深度の比べで同じ式）。名前は Bevy の `StandardMaterial::depth_bias`・Unity の `Offset`。pipeline の鍵に入る。CPU の直しの計画の W-1（`WebGpuMaterials` の bind group の控え）と同じファイルなので、その後に。
- D0 で HD-2D の町の通りと Bistro の通りを PC の GL・WebGPU で歩いて見て、ちらつきの距離を測ってから D4 の要否を決める。

## 6. 3 つの手本の場面で効くか

| 手本 | 貼る物 | A で効く理由 |
|---|---|---|
| PS1 風ホラー（retro3d-horror-starter） | 廊下の壁の血の跡・床のしみ・黒板の落書き | 頂点の色のベイクした明るさを写す。Design の場面でも使える。cutout にすればディザの段と合わせやすい |
| HD-2D（hd2d-starter） | 石畳のひび・苔・道の白線・屋台の前の水のしみ | `uvRect` の atlas で材質 1 つ → 読み込みの時の 1 回の呼び出しで draw 1 本（lightmap の絵が違う的があればその数だけ）。太陽の影も板の光の式に入る |
| 夜の町（lamplighter・bench/hd2d_town） | 壁の張り紙・落書き・濡れた路面のしみ | 点光源の光を板が受ける。濡れた所の映り込みは映り込みの計画（`plans/engine-reflection-probes.md`）の probe と組む |

ゲームの側の確かめ（D3 の後）: horror の作例に血の跡 3 枚・HD-2D の町に石畳のひびと苔の atlas 1 枚を、**ゲームの側の試し**（テンプレートは触らない）で貼って CPU の描き出しと GL・WebGPU で並べる。テンプレートに入れるか（入れると reference の撮り直し）は 13 節の決め 4。

## 7. 決まりと門

- **既定の絵**: `Decal3d` を呼ばない場面は形も GLSL・WGSL の字も同じ。D2 の `screenAoOnBlend` の欄は既定 false で、立てない材質のプログラムの鍵と字は今と同じ。`make gl-capture-check`（既定の絵）・gl-parity の既存の全行・テンプレートの reference（SHA256SUMS）が一致する事。
- **撮り直しの範囲**: 新しい gl-parity の場面 `decal3d`（壁と床の角・atlas の 3 枚・頂点の色つきの的・lightmap つきの的・cutout の 1 枚）と `decalAmbientOcclusion3d`（AO の隅の上の血・D2）だけ。上限は L 計画 3.4 の決め方（差の出うる画素は板の縁の画素として結果と独立に数える）。テンプレートは 13 節の決め 4 で入れる時だけ、その 2 本の reference を `make reference-update`。
- **CPU の描き手**: 板はふつうの半透明の置いた物なので、CPU は今の道のまま描く（新しい式なし）。D2 の AO の条件は、先に `SoftRaster3d/Blended.flix` へ出した半透明の塗りの道の中で材質ごとに env を選ぶ所（出す段で絵が変わらない事を gallery の SHA で確かめる）。D4 を入れる時は CPU の深度の比べに同じずらしの式。
- **決定性**: 切る式は入力だけで決まる（コマをまたいで積まない）。headless の 2 回撮りでバイト一致。
- テスト（engine・1 テスト 1 アサート）: 箱の外の三角形は残らない／平らな的に正面から投げると 4 点の四角になる／角の的で `angleCutoff` が壁の側を落とす／uv が `uvRect` に収まる／頂点の色が重心でつながる（的の tint が掛かる）／uv2 と lightmap が写る（的の `uvRect` が uv2 に掛かる）／骨つきと半透明の的は飛ばす（1 行言う）／`offset` の分だけ浮く／0.01 倍の的でも浮く量は場面の長さで `offset`／同じ的・同じ材質の 2 枚は 1 つの形になり、列の後ろの三角形が後ろに並ぶ／離れた 2 つの的の板は別の置いた物／法線マップだけ違う 2 枚は別の置いた物／colorSpace だけ違う lightmap の的は別の置いた物／材質の欄を 1 つずつ替えると `fullMaterialKeyOf` が全部違う／骨つきの的を飛ばすと `LogCapture` で 1 行出る／同じ入力で同じ形（`contentHash` が同じ）／返す物の world が単位行列。
- `bin/lint-rules/forbid.json` の `app-internal` の pattern に `Decal3d` と `Scene3d` を足す（`Scene3d` は水の計画も足す。先に入った方が足し、後の方は確かめるだけ）。
- **W1**: D2・D4 で増える鍵は `web/shader-variants.json` に記録が要る（4.2）。D3 の門に、decal の場面を書き出して記録に無い鍵の fail-open が 0 件（`make web-load-check` の数え方）を足す。
- 1,200 行に近いファイル（`Scene3d.flix`・`SoftRaster3d.flix`）には触らない（D2 は `Scene3d.Internal` に関数 1 つと欄 1 つ。欄は `MaterialFields` に 1 つ足す所だけ `Scene3d.flix` に 1 行。`SoftRaster3d.flix` は半透明の塗りを `SoftRaster3d/Blended.flix` へ出して呼ぶ 1 行にする）。

## 8. 触るファイル

- engine: 新しい `scene3d/Decal3d.flix`（pub 3）・`scene3d/Decal3d/Internal/Clip.flix`（箱の行列・切る・属性の写し）・`scene3d/Decal3d/Internal/Merge.flix`（材質と lightmap の組ごとのつなぎ）・`scene3d/Scene3d.flix`（`MaterialFields#screenAoOnBlend` の 1 行・D2）・`scene3d/Scene3d/Internal/` に旗を立てる関数・engine_full の symlink。
- render_gl（D2）: `Render3dShaders.flix`（651 行の `screenAo` の条件）・`Render3d/ProgramKey.flix`（`ProgramKind` の旗 1 つと材質の鍵の字 `+ab`）。（D4）`WebGpuMaterials.flix`・GL の材質の状態・Java の `DepthStencilState` の depthBias（Dawn）・engine_web のブラウザの WebGPU の pipeline。
- engine_tools（D2）: 新しい `SoftRaster3d/Blended.flix`（半透明の塗りを出す）・`SoftRaster3d.flix`（呼ぶ 1 行）・`DrawHash.flix`。
- bench/gl_parity: `Scenes.flix`（2 場面）。
- bin: `forbid.json`。docs: `docs/scene3d.md`（デカールの節）・`docs/backend-parity.md`・`agents-pack/AGENTS.core.md`・`agents-pack/agent-eval/engine.json`・`docs/migrations/<版>.md`（`MaterialFields` の欄 1 つ）・`make api-digest`。

## 9. AI が迷わない形

**ゲームが見る pub（3）**:

| API | いつ使うか（1 行） |
|---|---|
| `Decal3d.Decal`（record） | 貼る絵・点・向き・大きさ・回り・atlas の矩形を書く時の値 |
| `Decal3d.decal` | デカールの値を既定値から作る時（材質・点・面の向き。大きさは `{ size = … \| Decal3d.decal(…) }` で替える） |
| `Decal3d.buildInstances` | 壁・床・道に汚れ・血・弾痕・標示を貼る時（デカールの列をまとめて 1 回。読み込みか当たった時に呼び、結果を Res か控えに持つ） |

**早見表（`agents-pack/AGENTS.core.md`）の行の案**:

| したいこと | 使う API | 使わない物 |
|---|---|---|
| 壁・床に血・汚れ・落書き・ひびを貼る | `Decal3d.buildInstances(デカールの列, staticGroup に入れる前の的の列)` を読み込みで 1 回 → 結果を `instances` に（重ねる物は同じ材質の atlas に・cutout の板は staticGroup に入れてよい） | 板の形を手で組んで壁の前に置かない・壁の絵を描き替えない・骨つきの物に貼らない |
| 撃った所に弾痕を残す | `Ray3d.pickNearest` の `RayHit` の点と向きを `Decal3d.decal` へ → `buildInstances` を当たった時に 1 回 | 毎コマ `buildInstances` を呼ばない |
| 道路の白線・横断歩道 | 同上（`uvRect` で 1 枚の atlas から） | 道の形を線の分だけ切り分けない |

**agent-eval のお題の案（`agents-pack/agent-eval/engine.json`・欄は `expect` と `avoid`）**:
1. `decal-blood`「夜の校舎の廊下の壁に血の跡を 2 つ貼る」 — expect `re: "Decal3d\\.buildInstances"`（why: デカールの API を選ぶ）・avoid `re: "Decal3d\\.Internal|Scene3d\\.Internal"`（why: Internal を書いた）
2. `decal-bullet-hole`「撃った所の壁に弾痕を残す」 — expect `re: "Decal3d\\.decal"` と `re: "RayHit|pickNearest|hitInstance"`・avoid `re: "Mesh3d\\.fromArrays\\("`（why: 板を手で組んだ。呼び出しの形まで含めて、答えの文の言及では当たらないように）
3. `decal-road-marking`「石畳の道に白線を引く」 — expect `re: "Decal3d\\.buildInstances"`・avoid `re: "Decal3d\\.Internal"`

ゲームの足元で `make agent-eval ONLY=<お題>` が当たるのを D3 の後に確かめる。

## 10. 段と見積もり（実時間）

| 段 | 中身 | 実時間 | 前に要る物 |
|---|---|---|---|
| D0 スパイク | 切る式の仮（平らな板と角）・Bistro の建物 1 つで 1 枚の時間（JVM と wasm）・浮かせる量のちらつきの距離（HD-2D の町と Bistro の通り・GL と WebGPU）・horror の廊下で PS1 風の泳ぎともぐり・使わないゲームの wasm が増えないか（`wasm-size --diff`）・弾痕の手本の形（1 枚ずつ控えに足すか、64 枚を作り直すか）・弾痕を入れ替えた時に GL と WebGPU の形の控え（`MeshTable.trim`）が古い形を手放すか（数をメモ） | 0.5〜0.8 | 無し |
| D1 本体 | `Decal3d`（pub 3）・`Internal.Clip`・`Internal.Merge`（材質と lightmap の組ごとのつなぎ・列の順）・属性の写し・lightmap の矩形・テスト 13 本・forbid | 2.3〜3.3 | D0 |
| D2 AO を受ける例外 | 半透明の塗りを `SoftRaster3d/Blended.flix` へ出す（絵は同じ・0.5）・`MaterialFields#screenAoOnBlend`・GPU の `screenAo` の条件と `ProgramKind` の旗・CPU の env の選び・鍵・gl-parity の `decalAmbientOcclusion3d`・W1 の記録 | 1〜1.5 | D1・L5（main 済み）。水の G3 と同じ行（11 節） |
| D3 docs と門 | gl-parity の `decal3d`・docs の節・backend-parity・早見表 3 行・お題 3 本・migrations・api-digest | 0.8〜1.2 | D1 |
| レビュー | D1 の後・D3 の後 | 1〜1.5 | — |
| ゲームの側の確かめ | 6 節（horror と HD-2D の試し・CPU と GL・WebGPU） | 1〜1.5 | D3 |
| （条件つき）D4 深度のずらし | 5 節（pipeline・CPU・鍵） | 1〜1.5 | D0 の測り・CPU の直しの計画の W-1 の後 |
| （後ろ）D5 描き手の中のデカール | 2 節の D・動く物と骨つきと数百枚。L6 の cluster の表に入れる・atlas・`+dc`・CPU の材質の式・層の mask | 4〜6 | L6・需要が出てから |

- 和: D0〜D3 で 4.6〜6.8 時間、レビューと確かめを足して **6.6〜9.8 時間**。物差し（L5 SSAO が計画 4.5〜6.5 時間で済んだ）に照らして、描き手を変えない分 L5 より小さく見た。見込みの 2 倍を超えたら止めて相談する。
- 区切りのリリースは D3 の後（他の計画の区切りに相乗りしてよい）。

## 11. 今進んでいる別の作業とぶつかる所

| 相手 | ぶつかる所 | どうするか |
|---|---|---|
| 描き手の CPU の直し（`WebGpuMaterials`・`SceneList`・`ScenePlan`・`StaticRows`） | D1・D3 は無し（描き手を変えない）。D2 は `ProgramKind` の旗 1 つ（`WebGpuMaterials` の pipeline の鍵に流れる）。D4 は `WebGpuMaterials` の pipeline の鍵 | D2・D4 は W-1 の後に rebase。デカールが増やす draw（材質の数だけ）は W-1 の bind group の控えで軽くなる側 |
| W1（書き出しの時に作るシェーダーの字・main 済み） | D2 の `+ab`・D4 の depthBias が新しい鍵になる | 記録（`web/shader-variants.json`）を取ってから書き出す決まりを docs に。D3 の門で fail-open 0 件 |
| compute（`plans/engine-gpu-compute.md`） | 無し | — |
| 水（`SceneDepthDifference`・depth prepass・G3 の `+ao` の行） | D2 の `+ao` の条件と G3 の「半透明は受けない」が同じ 1 か所。水の深度を先に描く物の下のデカールは消える（4.3） | 先に入った方に合わせ、文を「半透明は受けない・`screenAoOnBlend` は受ける」に 1 本で。水が先なら D2 は 1 行足すだけ |
| L6 多数の点光源 | 無し（板は灯りの列をそのまま受ける）。D5 は L6 の cluster の表に乗る | D5 は L6 の後 |
| L7 volumetric fog | 無し（板は半透明の物として霧を受ける） | — |
| 段 1 の残り（contact shadows・TAA・SSR・カスケード） | TAA: 板は奥行きの絵に入らないが真下の面と同じ深さなので、前の位置の求めがずれない（推測・2d の確かめの部屋に 1 枚置く）。SSR: 映り込みの中に板は映らない（奥行きと前のコマの色の上では映る・推測）。contact shadows・カスケード: 無し | 2d・4a の担当へ「デカールの板 1 枚を確かめの部屋に置く」を伝える |
| 映り込みと GI の probe・空（同時に書く 2 本の計画） | 無し（板は probe の映り込みと環境光をふつうに受ける） | — |

## 12. 重さとスマホ

| 物 | PC（M4 Pro） | S24（WebGPU・Low） | wasm（brotli） |
|---|---|---|---|
| 作る（1 枚・10 万三角形の的） | JVM 1〜3 ms（推測） | wasm 5〜15 ms（推測・当たったコマだけ） | 使うゲームで +3〜6 KB |
| 描く（読み込みの汚れ・atlas の材質 1 つ） | 1 回の呼び出しで draw +1（lightmap の絵の数だけ増える）・画素は板の分の重ね | draw +1〜数本 | — |
| 弾痕 64 枚（1 枚ずつ作って控えに足す時） | draw +64（半透明なので staticGroup でもまとまらない・CPU の直しの後で 1 本あたり推測 5〜10 µs） | draw +64（推測 S24 で CPU +0.5〜1 ms） | — |
| 弾痕 64 枚（当たるたびに 64 枚を 1 回で作り直す時） | draw は的の数（同じ壁なら 1）・作り直しは当たったコマに 64 枚分（推測 wasm 数十 ms）。64 か所ぶんの的の列が要る（近くの物だけでは足りない）ので、的が散らばるゲームは 1 枚ずつ足す形 | draw +的の数 | — |

- **Low で切る所**: 描き手の側に技が無いので切る所は無い。弾痕が多いゲームは古い物から消す上限（推測 64 枚）と、S24 では 1 回で作り直す形（draw 1 本）を docs の手本に書く（Unity・Godot の弾痕の手本と同じ）。
- 画素の重さは板の面積だけで、S24 の GPU の予算（L 計画 8.3）にほぼ乗らない。

## 13. 範囲の外

| 物 | 順 |
|---|---|
| 動く的（扉・車）に貼る | D5 か、的のモデルの空間で持つ `buildInstances` の版（需要が出てから） |
| 骨つきの的（人物の服の血） | D5（描き手の中のデカール）で |
| MultiMesh3d・ビルボードの的・半透明の的（ガラス） | 需要が出てから（MultiMesh は 1 体ずつの行列で切る形・ガラスは並びの決め方と一緒に） |
| 角度・奥行きでなめらかに消す（angle fade・depth fade） | 板の頂点に α を持たせる道が無い（頂点の色の α は読まない）。要るゲームが出たら、`VertexColor` の別の channel を使う形と一緒に相談 |
| 濡れた所の映り込み（水たまり） | 映り込みの計画の probe と、水の計画の `fresnelAlpha` の API 化の後に相談 |
| 描き込んで増えていく汚れ（塗りのゲーム） | 2 節の C。需要が出てから |
| 画面の奥行きの箱（2 節の B） | 採らない（D5 の方が光が正しく、場面の作りに依らない） |

## 14. 人に決めてほしい事（推す答えつき）

1. **v1 を「形の上に薄い板」（案 A・D1 は描き手を変えない）にするか** → する。B（奥行きの箱）は horror の Design の場面と R32F の無い WebGL2 で使えず、場面を 1 回多く描き、色を置き換える物（白線・張り紙）が正しく照らせないので採らない。D（描き手の中のデカール）は動く物・骨つき・数百枚の需要が出たら L6 の後に D5 で。
2. **ゲームが見る pub を 3（`Decal3d.Decal`・`decal`・`buildInstances`）にし、切る式と属性の写しを `Decal3d.Internal` に置いて forbid に足すか** → そうする。
3. **デカールの板だけ、半透明でも AO を受ける例外を入れるか（D2・内側の欄 `screenAoOnBlend`）** → 入れる。隅の暗がりの上の汚れが浮かない。水の計画の G3 の行と 1 本の文にする。CPU の半透明の塗りを先に別ファイルへ出す（+0.5 時間）。
4. **テンプレート（retro3d-horror-starter・hd2d-starter）にデカールを入れるか** → v1 では入れず、ゲームの側の試しで確かめる（入れると reference の撮り直しとテンプレートの追随が要る）。入れるなら horror の血の跡 2 枚から。
5. **深度のずらし（D4・描き手の pipeline）は D0 でちらつきを測ってから決めるか** → そうする。50 m を超える標示がちらつく時だけ、CPU の直しの計画の W-1 の後に入れる。
6. **v1 は動かない的だけにし、骨つき・半透明の的は飛ばして `Log.warnThen` で 1 行言う（docs と早見表にも書く）か** → そうする。pub の形は変えずに知らせられる。
7. **`buildInstances` は毎コマ呼ばない決まりにし（staticGroup と同じ）、弾痕の手本の形（Resources の控え）は D0 で決めるか** → そうする。engine に内側の控え（memo）は作らない（純粋な関数の外に状態を持つ仕組みが engine に無く、作る理由が弱い）。
8. **`buildInstances` がデカールの列を受け、(的, 材質の完全な鍵, lightmap) ごとに world の座標の 1 つの形へつないで返すか（列の後ろが上）** → そうする。半透明は staticGroup でまとまらないので、つながないと 1 枚ごとに draw が増え、重なりの順もカメラで入れ替わる。的ごとに分ける（町じゅうを 1 つにしない）のは、ほかの半透明の物との並びと視錐台の外し方を今の置いた物と同じに保つため（別案: 区画ごとに呼ぶ決まりと大きすぎる形の知らせ。書き忘れで崩れるので取らない）。

## 出典にした engine の場所

- engine: `scene3d/Mesh3d.flix`（`fromArrays` 85・`withUvs2` 277・読む関数 561〜589 行）・`scene3d/Scene3d.flix`（`MaterialFields` 232・`InstanceFields` 447・`Lightmap` 454・`withLightmap` 588・`ScreenInputsFields` 757 行）・`scene3d/Ray3d.flix`
- engine_world: `PostStack.flix`（`Issue.AmbientOcclusionNeedsNative`）
- render_gl: `Render3dShaders.flix`（651 行 `screenAo`）・`Render3d/ProgramKey.flix`（`ProgramKind`）・`java/fge/webgpu/dawn/DawnWebGpu.java`（503〜505 行）
- engine_tools: `SoftRaster3d.flix`（1,181 行・523 行の `glassEnv`）・`SoftRaster3d/ScreenEffects.flix`
- templates: `retro3d-horror-starter/src/SchoolView.flix`（Design）・`AGENTS.local.md`・`hd2d-starter/AGENTS.local.md`・`assets/town.look.json`
- docs: `docs/scene3d.md`（307・514・534・540・586・699・943 行の節）
- 計画: 水の計画（G1・G3）・L 計画（9.1・9.4・3.4）・段 1 計画（2d・4a）・CPU の直しの計画（W-1）・`plans/engine-city-scale.md`（各エンジンの深度のずらしの表）
- 他のエンジン（考え方だけ）: Godot 4 の Decal（clustered）・Unity URP の Decal Projector（Screen Space・DBuffer）・Unreal の Deferred Decal と mesh decal・Bevy の ForwardDecal と ClusteredDecal・Source エンジンの overlay

## レビューへの答え（1 回目 74 点）

- 必須 1（半透明は staticGroup で持ち越されず、つながれもしない）: `buildInstances` がデカールの列を受け、(材質, lightmap の絵) ごとに world の座標の 1 つの形へつないで返す形にした。lightmap の矩形は uv2 に先に掛ける。cutout の板は staticGroup に入れてよいと分けて書いた。3・6・12 節の draw の数を直し、14 節に決め 8 を足した。
- 必須 2（重なりの順がカメラで入れ替わる）: つないだ形の中は列の順（後ろが上）。違う材質を重ねると入れ替わりうるので atlas でまとめる決まりを docs・早見表に。半透明の的は飛ばす。テスト 1 本（4.3・7 節）。
- 必須 3（浮かせる量が world の大きさで変わる）: 頂点を world へ写してから箱の中の座標で切り、角と浮かせる量を world で求める形にした（world の逆行列も使わない）。テスト「0.01 倍の的」（4.1・7 節）。
- 必須 4（D2 の差し込み先）: GPU は `Render3dShaders.flix` 651 行の `screenAo` と `ProgramKind` の旗、CPU は 523 行の `glassEnv` の道を先に `SoftRaster3d/Blended.flix` へ出してから選ぶ形にし、8 節と見積もり（D2 1〜1.5）を直した。
- 必須 5（W1）: 4.2・7・11 節に記録の決まりと fail-open 0 件の門を足した。
- 推奨: 1 知らせをやめ黙って飛ばす（決め 6）／2 `decal(material, center, normal)` にして大きさは欄で／3 B の比べを「掛け算の物は正しい・置き換える物が正しくない」に直した／4 staticGroup に入れる前の列を渡す例・MultiMesh は範囲の外／5 欄を `screenAoOnBlend` に・forbid に `Scene3d` も／6 D0 で形の控えの手放しを見る／7 頂点の色の色空間を 4.1 に／8 0 節を段ごとに・D4 はブラウザの JS の側も／9 箱は前後対称。
- 軽微: お題の正規表現（`Decal3d\.Internal` を avoid に・`Mesh3d\.fromArrays\(`・欄の名前 `expect`/`avoid`）・例の `pickNearest` の鍵のつながり・名前を組の番号に・PS1 のもぐり・S24 の draw の数・見積もりを直した。

## レビューへの答え（2 回目 84 点）

- 必須 1（町じゅうを 1 つにつなぐと並びと視錐台の外しが壊れる）: つなぐ鍵に的を足し、(的, 材質, lightmap) ごとの形にした（案 a）。名前を `<的の名前>:decal` に戻し、テスト「離れた 2 つの的の板は別の置いた物」を足した（0・3・4.3・12・14 節）。
- 必須 2（材質の鍵）: `materialKeyOf` に blend・normalMap・metallicRoughness・emission の色・`screenAoOnBlend` を足した `fullMaterialKeyOf`（`Scene3d.Internal`）を鍵に。lightmap は uvRect を直した後の値まるごと。テスト 3 本（3・7 節）。
- 必須 3（純粋な関数でも `Log.warnThen` で知らせられる）: 骨つき・半透明の的を飛ばした時に 1 行言う形に戻し、決め 6 の理由を直した。
- 推奨: 1 W1 の門を render_gl の単体テストとゲームの側の試しの書き出しに／2 `+ab` は場面が `+ao` の時だけ鍵に／3 法線は余因子行列で写す／4 1 回目の版の置き場所の行を消した。
- 軽微: 名前・64 枚を作り直す形に的の列の条件・`instancesNear` はゲームの側と注記。

## 測った値（各段の後にここへ足す）

- 2026-11-27 D0・D1（枝 worktree-agent-a973042947d4fea0d の b3c99ffd3・JVM・M4 Pro）: 10 万三角形の平らな的に 1 枚 3.65 ms（world への写し約 2 ms 込み・最初の形は 65 ms で三角形の world の AABB を先に外す形に直した）。64 枚の作り直し 96 ms → 弾痕の手本は「当たった時に 1 枚ずつ作って控えに足す」。使わないゲームの wasm: retro3d-horror-starter で Decal3d の関数 0・classes.wasm.br 1,452,639 B（増え無し）。省いた測り: ちらつきの距離・PS1 風の泳ぎ・MeshTable.trim・wasm の 1 枚の時間。engine のテスト 1,258 緑（TestDecal3d 32）・レビュー 76 → 91 点。
- 実装で計画から変えた所: 的の tint は板の置いた物の tint へ写す／法線は `Mat4.normalMatrix` で写す（余因子は反転した world で向きが逆）／面の向きは巻き方の外積を頂点法線の和に合わせる／つなぐ鍵は (的, 材質) で lightmap は入れない／LogCapture が engine に無いので知らせは `Merge.build` の戻り値の文で試す。
- 2026-11-27 D2・D3（枝 worktree-agent-a481e18ac9e6ff039・M4 Pro・GL）: gl-parity の decal3d 183 px（±1 は lightmap の板の texel の境 176 px・±108 は浅い角の床の板の Nearest の texel の境の 1 列 7 px）→ 許容 300・
  decalAmbientOcclusion3d 214 px ±1 → 許容 320。板の旗を外した場面（`withMaterial` で旗の無い材質に戻す）を一時的に撮ると、旗あり・なしの差は GL 521 px・CPU 537 px（max ±17）、
  GL の旗ありと CPU の旗なしは 642 px → 片方だけ受けないのは許容で止まる。2 回撮りでバイト一致。
- W1 の門 (2)（デカールの場面を書き出して fail-open 0 件）は 6 節のゲームの側の試しへ送った（D3 では render_gl の単体テストの (1) だけ）。
- レビュー 84 → 93 点。残したもの: agent-eval のお題 3 本の当たり（claude -p のログインが切れて流せなかった・人が /login した後に流してここへ足す）・
  gl-capture-check（画面を開く門・release の前に GUI=1 で）・`SoftRaster3d/Blended.flix` の `aoOnBlend` を `mats` と同じ並びの別の Vector で持つ形
  （次に触る時に `Mat` へ寄せる候補）。verify を 6 本並べた時だけ赤になった 2 本（render_gl の TestStaticRows.testRebuildStreakWarnsOnce・horror の TestBackgroundLoads）は
  2 本だけで流すと緑。stderr を取り合う疑いがあるので別の件として扱う。
- 水の計画が入る時: docs/scene3d.md のデカールの節に「`withDepthPrepass` の下の半透明の板は隠れる・見せたい板は cutout」の 1 行を戻す（API が無い間は消した）。
