# K — 光の単位と色の道筋: 今のエンジンと外の基準の突き合わせ（2026-11-14・読み取りと web 調査のみ）

印: 【確】= コードか一次情報で確かめた / 【推】= 推測・手計算 / 【不明】。パスは engine の根（/Users/abab/Desktop/flix_game_engine/engine）から。ビルド・テスト・描き出しは流していない。

## 要約
**今のエンジンが標準と違う所の上位 5 つ**
1. **HDR の Pass の値は線形でなく「画面の値（sRGB の曲線で縮めた値）」で、tonemap はその上に掛かる**（標準は 線形のシーン参照 → tonemap → 画面の曲線）。`defaultExposure()` +0.4 が白っぽく、−0.6 が勧められる理由もここ（A4）。
2. **拡散に 1/π が無く、鏡面にはある → 拡散と鏡面で光の単位が π 倍ずれる**（`intensity` を照度 E と読むと拡散が π 倍明るい・E/π と読むと鏡面が 1/π に弱い）。
3. **光の減り方が逆二乗でなく (1 − d²/range²)²**（近くが平らで 1 が上限）。glTF・Filament は 逆二乗 × 窓。絶対の強さを物理の単位から写せない最大の理由（A1）。
4. **環境マップは 8bit の sRGB 絵だけ**。HDR（.hdr / .exr）を読む口が無く、太陽は 1 で頭打ち、拡散の照り返し（irradiance）が無く、粗さは box 平均の mip を粗さに比例で引くだけ（GGX の前計算でない）。
5. **鏡面の G が相関なしの Schlick-GGX（k = α/2）・材質の拡張が少ない**（glTF の高さ相関 Smith と違う。`KHR_materials_*` は emissive_strength だけ・occlusion・ior・specular・transmission・光の `KHR_lights_punctual` は読まない）。F・D・F0 は標準と同じ。
**今でも外から持ってこられる物**: 光や色の「比」・色温度・material の値（base color・metallic・roughness。D・F・F0 が同じなので。拡散の 1/π と G の差は残る）・tonemap の曲線の形（Narkowicz の式と同じ）。**持ってこられない物**: 絶対の強さ（lux・cd・EV100）— 単位の口が無いため。
**推す単位の持たせ方**: 案 (i) — 新しい口（`PostStack` と光の物理の単位のコンストラクタ）だけ lux / candela / EV100 / Kelvin を別の型で受け、**光の側へ露出を先に掛ける（pre-exposure。Filament と同じ）**。GL・CPU の式は触らず gl-parity も動かない。古い口は据え置き、後で (iii) へ寄せる。同時に「HDR の Pass を線形にする」を別の段で（2D との境目が要る）。
**評価の最初の 1 歩**: 外の画像を使わない解析テスト（白い拡散球・白い furnace・鏡面のピーク値を式と比べる）を engine の `bench/gl_parity` の形で 1 本。次に `~/Documents/flix_ge_workspace/pbr_room/modeling/render_ref.py`（Cycles で同じ構図を描く既存の型）を、光を 1 本・bounce 0・世界を一様色にして単位の換算を実測する。
**広い題材への拡張（D 節）**: 正解の絵は Blender 5.2.3（nix store にある）の Cycles で、線形の EXR を作って比べる（tonemap を通さない）。基準の場面は CC0 / CC-BY の物だけを使う（Bistro CC-BY 4.0・Intel Sponza CC-BY・Poly Haven と ambientCG は CC0。Emerald Square と Sun Temple は NC、Moana は研究用のみ → 公開物に入れない）。草原に足りない物: 頂点を動かす口（風）・葉の透け・遠景の溶かし方・大量配置の入口（instancing は物の行列だけ）。写実でない絵（ドット絵・トゥーン）はこの物差しの対象外で、目標の絵を人が選ぶ。

## A. 今のエンジンの光と色の道筋（コードから）

### A1. 光 1 つが画素になるまで【確: LightModel3d.flix:5-37・198-229・423-453】
| 光 | 画素への寄与（線形の量。木の順） |
|---|---|
| ambient / hemisphere | `ambient（sRGB→線形）+ hemisphere × max(0, n.y)`（白の ambient が既定）。向きに依らない。**どちらも「入る放射輝度」扱いで、albedo に掛ける**（1/π を含まない形） |
| 点光源 | `color × intensity × att × facing`。`att = (max(0, 1 − d²/range²))²`・`facing = clamp01(n·l)`（wrap は 0 固定）。**逆二乗の項 1/d² が無い**。d = 0 で att = 1（有限）・d = range で 0 |
| スポット | 点光源 × `cone × shadowLit`。`cone = smoothstep(outerCos, innerCos, −l·dir)`・内の角の既定 = fovY × 0.8（`Scene3d.spotConeOf`・Scene3d.flix:42-54） |
| 太陽 | `color × intensity × facing × sunLit`（`SunColor = color × intensity`）。向きだけ（距離なし）。影は PCF の地図（木の外） |
| lightmap | `max(0, toLinear(s) × lightmapIntensity)`。拡散の面は ambient・hemisphere・太陽の拡散を足さない |
| 材質への掛け方 | `色 = albedo(線形) × tint × light`（`Render3dGlsl.surfaceOutSource` 184-196）→ かすみ（距離の線形 mix）→ `+ emission(線形) × emissionIntensity` → **`linearToSrgb`**（unclamped） |
- 物理の量との対応: **付かない**。足りない物 3 つ — (1) 距離の逆二乗（range 内の形が違う。ある 1 距離でしか合わせられない）、(2) 光の単位の約束（intensity は無単位。拡散に 1/π が無いので 「E/π」と読むのが整合的）、(3) カメラの露出（EV100）が場面に無い（露出は後の Pass の stop だけ）。
- 角度: glTF は `saturate((cosθ − cosOuter) × scale)` を 2 乗、エンジンは smoothstep。形は似るが同じではない。

### A2. PBR の式【確: LightModel3d.flix:21-32・237-267・369-388】と標準との項ごとの比べ
| 項 | エンジン | glTF 2.0 付録 B | Filament | 同じか |
|---|---|---|---|---|
| 拡散 | `albedo × (1 − metallic) × light`（1/π なし） | `(1/π) × color`、`(1 − metallic)` で混ぜる | Lambert `σ/π` | **違う（π）**。metallic の混ぜは同じ |
| 拡散の (1 − F) | 掛けない（拡散 + 鏡面を足す） | `fresnel_mix`: `mix(拡散, 鏡面, F)`（拡散に (1−F)） | 掛けない（足す） | Filament と同じ・glTF と違う（垂直で 4%、すれすれで大） |
| D | GGX `α²/(π((n·h)²(α²−1)+1)²)`・α = roughness²（下限 0.002） | 同じ | 同じ | 同じ |
| G / V | Schlick-GGX の G1(n·l)G1(n·v)・k = α/2・`/(4 n·v)` に畳む | **高さ相関 Smith**（V = G/(4 n·l n·v)） | 高さ相関 Smith | **違う**（粗いほど差が大。方向は鏡面が強め/弱めのどちらかは未計算【不明】） |
| F | Schlick・F0 = mix(0.04, albedo, metallic)・F90 = 1 | 同じ（ior 1.5 → 0.04） | 同じ（0.16 × reflectance² = 0.04） | 同じ |
| 鏡面にかかる光 | `color × intensity × att`（**π を掛けない**） | `E`（照度）× n·l | `E` | 拡散との比が π ずれる（上の要約 2） |
| エネルギー保存・多重散乱 | 無し | 付録 B は「保存を破る」と明記 | `energyCompensation` あり（DFG LUT） | 違う（粗い金属が暗い） |
| 映り込み | `空 or 環境(normalize(mix(r, n, rough²))) × (F0 + (max(1−rough, F0) − F0)(1−n·v)^5)`（roughness を見る Fresnel の近似。split-sum の DFG LUT なし） | — | split-sum（`LD × (F0·DFG1 + F90·DFG2)`） | 違う（簡略） |
| occlusion・specular occlusion | 無し（`occlusionTexture` を読まない・scene3d.md「やらない事」） | あり | あり | 違う |
- toon は拡散だけ段にする（標準に無い）。**1/π の件の根拠**: 鏡面の `dScale = α²/π`（D の 1/π）はあるが、拡散の `Mul(Albedo, Light)` に 1/π が無い（LightModel3d.flix:239・267）。`facing × color × intensity` が直接 albedo に掛かる。

### A3. ambient・hemisphere・lightmap・環境マップ【確】
- ambient（color, sRGB→線形）・hemisphere（スカラー・線形のまま）・lightmap（既定 Srgb の絵 → 線形・`intensity` は線形の倍率）はすべて **線形の量**として足す。`withEmissionIntensity` も線形の倍率。`withTint`・頂点の色・光の `color`・ambient・かすみの色・空の 3 色は **書く値が画面の値**で、中で線形へ戻す（`docs/scene3d.md` 9-21）。
- 空（`gradientSky`）の 3 色: 見える空の画素は式の値をそのまま出す【推: `skyAt` が uniform の値を混ぜるだけ】。映り込みに使う時だけ線形へ戻す（`reflectionSkyOf` 403-414）。空が無ければ ambient + hemisphere を映す。
- 環境マップ（`Scene3d.environmentMap`・Scene3d.flix:626-635）: **正距円筒の 8bit sRGB の絵**（`Texture3d` の `Source` は `Argb(Vector[Int32])` か `PlatformImage` のみ・Texture3d.flix:10-14）。`.hdr`・`.exr`・RGBE を読む口は **見つからない**（`refactor search hdr|rgbe|exr` の hdr の 27 件は全部 HDR の Pass の話）【確】。1 を超える明るさは頭打ち（`withEnvironmentIntensity` で倍にする）。mip は CPU の `Mip.build`（線形で 2×2 平均）・段 = `roughness × (段の数 − 1)`（`environmentLodOf`）— **GGX の前計算ではない**。拡散の照り返し（irradiance / SH）は無い（「やらない事」）。箱の補正（Box Projection）はある。
- 結果: 環境の「色の分布」は映り込みにだけ効き、拡散には ambient / hemisphere / lightmap を手で合わせる。HDRI の太陽は 8bit で切れる。

### A4. 色が画面に出るまでの順（コードで確認）【確】
1. 材質の Spec の色（sRGB 値）→ `srgbToLinear` → `× tint × light` → かすみ（線形）→ `+ srgbToLinear(emission) × k`。
2. **`r3d_linearToSrgb3(c)`**（`Render3dGlsl.flix:195`・`Texture3d.linearToSrgb` は「1 を超えても同じ式で返し、負は 0」Texture3d.flix:134）。つまり出口は **sRGB の曲線で縮めた値**で、1 を超えうる（線形 4.0 → 約 1.83・線形 40 → 約 4.85。`docs/migrations/0.79.0.md:46`）。
3. その値が `Rgba16Float` の Pass に **そのまま** 書かれる（`RenderTarget.Format` の doc・`withHdr`）。**HDR の Pass の値は線形ではなく画面の値（の 1 超え版）** — 文書（`docs/shader-doc.md:281`「ガンマのままの値をトーンマップする」）と一致。
4. `PostProcess.tonemapped`: `x = max(0, v × 2^stops)` → `ACES(x)`（Narkowicz 2.51/0.03/2.43/0.59/0.14）を `acesAt(whitePoint)`（W = 4 で 0.973）で割って `sat`。Reinhard は拡張形。**露出は tonemap の入力（画面の値）へ掛かる**。出力は Rgba8Unorm の Pass へそのまま（OETF を掛け直さない）。
5. 2D は画面の値のまま混ぜる（`docs/scene3d.md:18`）。HUD・UI は tonemap の後の層に置く。
- **−0.6 の理由（手計算【推】）**: 灰 0.18（線形）→ encode 0.461。露出 +0.4（×1.32）→ ACES → 約 0.70（白っぽい）。−0.6（×0.66）→ 約 0.455 ≒ 入力の 0.461 に戻る。つまり −0.6 は「ACES が中間を持ち上げる分と 1/0.973 を打ち消して、中間をほぼ恒等にする値」。標準（線形 0.18 → Narkowicz 約 0.27 → OETF 約 0.56）とは中間の明るさが違う。**暗部は標準より明るく（線形 0.02: 標準 約 0.10・エンジン −0.6 で 約 0.13）、高輝度は早く潰れる（線形 4.0: 標準 約 0.99・エンジン −0.6 で 約 0.86）**。
- `defaultExposure()` が +0.4 のままの理由（コメント）: 「正規化で落ちる白を持ち上げる」— 8bit の 1.0 を ACES で 0.83〜0.9 に戻すため。つまり 8bit 画面の値を入れる前提の既定で、3D の HDR の Pass の既定とは噛み合っていない。
- bloom のしきい値（`reference-3d.md`）も画面の値の目盛り上の数。

### A5. 2D との境目【確】
- 2D は画面の値のまま blend（Add・Multiply・alpha）。3D の場面は `Render.scene3d` の PlacedItem で、z が同じなら面と 3D が必ず手前。HDR の Pass に 2D の物を描くと **画面の値どうし**を足す。HDR の Pass を線形にすると、この 2D の物の色を「線形へ戻してから」書くか、2D の物を tonemap の後の層へ逃がすかが要る（D 節ではなく C の案で扱う）。
- 数字で見る違い: 白 50% の半透明を黒の上に重ねると、画面の値の blend は 0.5・線形の blend は 0.735（OETF 後）。**半透明の光や影の 2D 重ね（Daylight・グロー）の見えが変わる**【推・手計算】。

### A6. CPU の描き手（SoftRaster）【確: docs/backend-parity.md・scene3d.md 冒頭】
- 光・かすみ・空・PBR の式は `LightModel3d` の木 1 本から GLSL と Flix（`SoftRaster3dLight`）を生成。木の外（影の PCF・法線マップの TBN・lightmap の段つきの読み・環境マップの絵・裏面の法線）は 2 本が別々に書き、`make gl-parity` が式の行で値をそろえて確認。tonemap は `ShaderEval`（同じ ShaderDoc の木を CPU で評価）。MSAA と WebGPU 固有の物は CPU に出さない（backend-parity の決まり 2）。
- 単位の口を足す時は **木の入力の係数だけを変える**なら CPU は自動で追随する（木の外に式を足すと 2 本に書く代金が出る — `analysis-render-structure.md` A4）。

## B. 外の基準（一次情報）

### B1. 各エンジンの単位（利用者に書かせる単位・既定）
| エンジン | 点・スポット | 太陽 | カメラ・露出 | 既定と切り替え | 一次 |
|---|---|---|---|---|---|
| glTF `KHR_lights_punctual` | candela（lm/sr） | lux | — | `range` 省略 = 無限・逆二乗。窓 `max(min(1−(d/range)^4,1),0)/d²` が推奨 | github.com/KhronosGroup/glTF/blob/main/extensions/2.0/Khronos/KHR_lights_punctual/README.md |
| `KHR_materials_emissive_strength` | — | — | 無単位の倍率（1 超え可）。`emissive × sRGB→線形(texture) × strength` | 既定 1 | …/KHR_materials_emissive_strength/README.md |
| Filament | 光束 lm（点: I = Φ/4π・スポット: Φ = 2π(1−cos(θ/2))I）か cd | lux | 露出 = `1/(2^EV100 × 1.2)`・`L = 2^(EV100−3)`・光に pre-exposure | 物理の単位が既定（無単位の口なし）。IBL は cd/m²（較正の倍率が要る・文書は TODO） | google.github.io/filament/Filament.md.html |
| Unity HDRP | lumen / candela / lux / nits / EV100 を選べる | lux | physical camera・Exposure Volume | 1 Unity 単位 = 1 m が前提と明記。HDRP の cheat sheet: 晴れの太陽 100000 lux・曇り 20000・EV 14 = 日なた・EV 4 = 室内 | docs.unity3d.com/Packages/com.unity.render-pipelines.high-definition@17.0/manual/Physical-Light-Units.html |
| Unreal | Candela（既定）・Lumens・EV・Nits・Unitless（`1 cd = 625 unitless`） | lux（Direct Normal Illuminance） | Post Process の EV100・Histogram Min/Max EV100 | プロジェクト設定 Light Units（既定 Candelas） | dev.epicgames.com/documentation/en-us/unreal-engine/using-physical-lighting-units-in-unreal-engine |
| Godot 4 | lumen（Omni・Spot）。**既定は無効で任意の単位** | lux | `CameraAttributesPhysical`（絞り f/16 が既定・シャッター・ISO・EV100 で自動露出の幅） | Project Settings > Rendering > Lights And Shadows > Use Physical Light Units（要再起動・Advanced）。切ると意味が変わる（型は同じ） | docs.godotengine.org/en/stable/tutorials/3d/physical_light_and_camera_units.html |
| Bevy | lumens（`PointLight`）| lux（既定 `AMBIENT_DAYLIGHT` = 10000） | `Exposure { ev100 }`・`SUNLIGHT` 15・`OVERCAST` 12・`INDOOR` 7・`BLENDER` 9.7（Blender の既定と合わせた値） | 物理の単位が既定。`light_consts::lux` の定数表あり | docs.rs/bevy/latest/bevy/camera/struct.Exposure.html・raw.githubusercontent.com/bevyengine/bevy/main/crates/bevy_light/src/lib.rs |
- 読み取れる事: **物理の単位を既定にしている**のは Filament・Bevy・Unreal（cd）。**切り替え式**は Godot（設定 1 つ。同じ欄の意味が変わる）と Unity HDRP（単位の選択）。いずれも露出（EV100）とセットで、光だけに単位を付けない。
- 代表の照度の出どころは割れる: 満月 = 0.05（Bevy）・0.32（physicallybased.info）・約 1（Filament）・0.5（Unity の図）・1 未満（Unity 文書）。**値は 1 桁の幅がある**。

### B2. 定数の表として持ってこられる物（出どころ・ライセンス）
| 物 | 値 | 出どころ | ライセンス |
|---|---|---|---|
| 太陽（midday） | 100000 lx・5778 K・線形 sRGB (1.0, 0.877, 0.822)・見かけの直径 0.5332° | physicallybased.info `lightsources.json` | CC0 1.0（リポジトリの README「All data is released under CC0 1.0」・github.com/AntonPalmqvist/physically-based-api） |
| 太陽（sunset） | 3000 lx・2600 K・(1.0, 0.394, 0.083) | 同上 | 同上 |
| 空・曇り・月・夜 | 晴れの空 6000 lx・曇り 100〜2000 lx・満月 0.32 lx・月なし 0.002 lx | 同上 | 同上 |
| Filament の太陽 | 10 時 太陽⊥ 100000 / 空⊥ 20000・12 時 105000 / 25000・17:30 81000 / 9000 | Filament.md | Apache-2.0【推。文書のライセンスは未確認】 |
| Bevy の定数 | 月なし 0.0001・満月 0.05・薄明 3.4・居間 50・廊下 80・曇り（暗）100・事務所 320・日の出 400・曇り 1000・日陰 10000・晴れ日陰 20000・直射 100000・大気外 130000 | bevy_light/src/lib.rs | MIT / Apache-2.0【推】 |
| EV100 | 晴れ 15・曇り 12・室内 7（Bevy）。Unity の図: 日なた 14・曇り 10・室内 4・月夜 1 | 上の表 | — |
| 色温度 → 色 | Filament の表（蝋燭 1850〜1930 K など）。換算の式は Planckian locus の近似（Krystek など）【推】。**式の出どころは未確認** | Filament.md | 【不明】 |
| 金属の F0（sRGB の base color） | 銀 (0.97, 0.96, 0.91)・アルミ (0.91, 0.92, 0.92)・金 (1.00, 0.85, 0.57)・銅 (0.97, 0.74, 0.62)・鉄 (0.77, 0.78, 0.78)・チタン (0.76, 0.73, 0.69)・白金 (0.83, 0.81, 0.78)・真鍮 (0.98, 0.90, 0.59) | Filament.md 「Table fNormalMetals」 | 文書の表。引用なら出典つき【ライセンス不明】 |
| 絶縁体の base color の範囲 | sRGB 50〜240（厳格）・30〜240（寛容）。127 sRGB ≒ 反射率 0.5（線形）。90 未満にしない | Filament.md | 同上 |
| 代表の base color（線形） | 草 (0.105, 0.133, 0.041)・コンクリート (0.51, 0.51, 0.51)・雪 (0.85, 0.85, 0.85)・砂 (0.44, 0.386, 0.231)・新しいアスファルト (0.043, 0.041, 0.040)・roughness 0.5〜1.0 | physicallybased.info `materials.json`（`references` に論文・Wikipedia を持つ） | CC0 1.0。土・葉・木は 300 KB の json の前半で見つからず【不明】 |
- 注意: physicallybased.info の色は `colorSpace: "srgb-linear"`。**エンジンの Spec は sRGB の hex なので、`linearToSrgb` を通してから書く**（そのまま入れると暗い）。

### B3. HDRI
- Poly Haven: **CC0**（polyhaven.com/license「Our assets are all licensed as CC0」・帰属不要・商用可）。公式 API（`api.polyhaven.com/files/<id>`）で `hdr` と `exr`・1k / 2k / 4k / 8k / 16k。例 `kloofendal_48d_partly_cloudy_puresky`: 1k hdr 約 1.4 MB・exr 約 5.5 MB・4k hdr 約 20.7 MB【確】。API の利用は「Powered by Poly Haven」の帰属の依頼あり（資産でなく API の側）。
- 明るさ: Poly Haven の FAQ は「unclipped（太陽まで切れていない）が条件・clipped は平らな光になる」と書く（polyhaven.com/faq の要約のみ）。**絶対輝度（cd/m²）に較正されているかは確かめられず**【不明】。Filament も IBL の較正（グレーカードか色票・カメラ設定が要る）を TODO としている。使うなら「太陽の円を lux の太陽と二重に数えない」「全体に倍率 1 つを掛けて合わせる」と決める。
- 標準の手順: 拡散 = 球面調和 2 バンド（4×4 の行列・Filament）か irradiance の cubemap・鏡面 = split-sum（`LD(n, α)` を mip に・`α = roughness²`・`lod = perceptualRoughness × (段数−1)`・DFG の 2D LUT）【確: Filament】。Khronos の `glTF-IBL-Sampler` がこの前計算をする（github.com/KhronosGroup/glTF-IBL-Sampler。ライセンスは未確認）。
- ブラウザ向けの軽い形式【推】: RGBE（8bit 4 成分・`.hdr` と同じ）・RGBM・RGB9_E5（WebGL2 の core の共有指数・32bit/画素）・`KTX2` + BC6H（`EXT_texture_compression_bptc`・デスクトップ寄りで対応が揃わない）・RGBA16F（WebGL2 の `EXT_color_buffer_float` 系）。**どれがエンジンの Texture3d（ARGB の Int32）に入るかは別の仕事**【確: 今は入らない】。
- Khronos の `glTF-Sample-Environments`: 10 個（`.hdr` と `.jpg`・ennis・pisa・doge2・field・footprint_court・helipad・papermill など）。元の出どころは USC ICT・hdrlabs など。**リポジトリにライセンス表記なし → 公開物へ入れない**【不明】。

### B4. 基準のモデルと正解の絵
| 物 | 何を確かめられるか | ライセンス（個別 README） |
|---|---|---|
| MetalRoughSpheres（絵あり・なし） | metallic × roughness の格子 | CC BY 4.0（Analytical Graphics, 2017）【確】 |
| EnvironmentTest | 金属・白の絶縁体・黒の絶縁体 × roughness 0〜1 の球（環境光の見え） | **Adobe Stock License**（再配布不可の恐れ）→ ローカルの確認だけ【確】 |
| DamagedHelmet | PBR 全部入りの実物（絵 5 枚） | CC BY 4.0（ctxwing の再構成）。元の版は CC BY-NC【確】 |
| Sponza（glTF-Sample-Assets 版） | PBR の室内 | **Cryengine Limited License**（Crytek）→ 公開物に入れない【確】 |
| ToyCar | clearcoat・transmission・sheen（このエンジンは読まない） | CC0【確】 |
| DirectionalLight・PointLightIntensityTest・LightsPunctualLamp・AttenuationTest・EmissiveStrengthTest・NormalTangentTest | 光の単位・減衰・emissive の確認用の最小の glTF | 一覧は github.com/KhronosGroup/glTF-Sample-Assets/blob/main/Models/Models-testing.md。個別の README を見る【確: 名前と一行説明のみ】 |
- リポジトリ全体は「CC-BY-4.0・モデルごとに README が個別」。
- **Khronos の glTF Sample Renderer**（github.com/KhronosGroup/glTF-Sample-Renderer・Apache-2.0・WebGL2）: 回帰の画像は **Cannon Exterior の環境 + Khronos PBR Neutral** で撮る。
- **比べの頁**: `github.khronos.org/glTF-Render-Fidelity/`（モデルは glTF 見本・「gltf-sample-viewer-golden」の画像・Side-by-side / Slider / Difference の表示）。**指標・基準の path tracer・光の環境は頁から読めず**【不明】。`modelviewer.dev/fidelity/` は公式の頁へ移ったとだけ書く。
- Filament の検証: 文書の「Validation」と付録「Sample validation scene for Mitsuba」— Mitsuba（path integrator）を基準に、球・`roughplastic`・GGX・envmap `office.exr`（scale 35000）・太陽の照度 (120000, 115200, 114000)・FOV 45・camera (0, 0, −3.1)・256 サンプル・LDR 2048×1440 で比べ、**一番の差はすれすれの Lambert**（Disney 拡散なら近づくと推測）と書く【確】。**このエンジンの比べの手本に一番近い**（同じ形で再現できる）。

### B5. tonemap の標準
| 曲線 | 入力の前提 | ライセンス |
|---|---|---|
| Narkowicz ACES fit `saturate(x(2.51x+0.03)/(x(2.43x+0.59)+0.14))` | 線形のシーン参照。入力が 1 で出力 約 0.8（事前露出が入っている）。出力は線形で「あとで ガンマ」。原曲に使う時は x × 0.6 | **CC0 または MIT**（knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/ のコメント）【確】 |
| Hill / MJP の `ACESFitted`（sRGB → AP1 の行列 + `RRTAndODTFit` + 出力の行列） | 線形 sRGB の入力。出力は線形（OETF は後）| **MIT**（TheRealMJP/BakingLab の ACES.hlsl）【確】 |
| Khronos PBR Neutral | **線形の Rec.709 の入力**・sRGB 出力のみ。0.8−0.04 以下の色は 0.04 引くだけでほぼ素通し（base color が出力に残る）・`K_s = 0.76`・`K_d = 0.15`。**露出の決まりは書かれていない** | **ライセンス表記を頁で確認できず**【不明】。github.com/KhronosGroup/ToneMapping |
| AgX（Sobotka） | シーン参照の線形・Blender の既定（4.0 以降は AgX。Filmic は非推奨）【推】 | 【不明】 |
| Reinhard（拡張） | 線形のシーン参照・白の点 W | 式は公知（拡張形 `x(1 + x/W²)/(1 + x)`） |
- **エンジンの食い違い**: 式は Narkowicz と同じ（W で割る点だけ追加）だが、**入力が画面の値**（A4）。標準では 灰 0.18 が約 0.56 に出る所がエンジンの −0.6 では約 0.455。**標準の曲線を借りる時は、先に HDR の Pass を線形にしてからにする**（そうしないと露出の stop の数が標準と別の物になる）。
- 白の点で割る（`acesAt(W)`）のは標準の Narkowicz に無い。W = 4 では 0.973 で割る。

### B6. 色の管理の基本
- Filament（`Filament.md`「Physically based camera / Tone mapping」）: 流れは **シーン輝度 → 正規化（露出）→ ホワイトバランス → 色の調整 → tonemap → OETF → 画素**。後処理は tonemap の前（シーン参照の線形）で行うよう勧める。
- Khronos PBR Neutral: 入力は「非負の線形 Rec.709」（上の表）。
- glTF: `baseColorFactor`・`emissiveFactor` は線形・テクスチャの baseColor / emissive は sRGB（`KHR_materials_emissive_strength` の式 `emissiveFactor × sRGB_to_Linear(texture) × strength`）。
- ACES の公式文書は読んでいない【不明】。

## C. 突き合わせ

### C1. 項ごとの表
| 項 | 標準 | 今のエンジン | 判定 | 外の値を使うとどうずれるか |
|---|---|---|---|---|
| 光の単位 | lux / cd / lm・露出と対 | 無単位・露出なし | 違う | 写せない。換算式は C3 |
| 距離の減り | 逆二乗 × 窓 | `(1−d²/r²)²`（逆二乗なし） | 違う | 近くが暗すぎず、遠くで急に落ちる。同じ cd を入れると 1 距離でしか合わない |
| 角度の減り | `saturate((cosθ−cosO)×scale)²` | smoothstep | 近い | 縁の幅が少し違う |
| 太陽 | lux・距離なし | 同じ形（無単位） | 形は同じ・単位が違う | lux ÷ (π × 露出の分母)（C3） |
| 拡散 | 1/π | 1/π なし | 違う | 値をそのまま入れると π 倍明るい（lux 由来の値を入れた時） |
| 鏡面の D・F・F0 | GGX・Schlick・0.04 | 同じ | **同じ** | — |
| 鏡面の G | 高さ相関 Smith | Schlick-GGX（k=α/2） | 違う | 粗い面のハイライトの縁の強さ・すれすれ |
| 鏡面と拡散の比 | E と E/π で整合 | 鏡面だけ π 倍相当で弱い | 違う | 同じ lux 由来の値で光らせるとハイライトが 1/π に弱い |
| 多重散乱・(1−F) | Filament: 補正あり・glTF: (1−F) | 無し | 違う | 粗い金属が暗い |
| 環境マップ | HDR・cd/m²・拡散は SH・鏡面は split-sum | 8bit sRGB・拡散なし・box 平均の mip | 大きく違う | 太陽の反射が出ない・粗い面の色の広がりが違う・拡散の空の光が無い（ambient で手合わせ） |
| 色の空間（材質・光） | 線形 | 書く値は sRGB・中は線形 | 同じ（約束が別） | 外の線形値は `linearToSrgb` してから入れる（B2 の注意） |
| HDR の Pass の値 | 線形 | 画面の値（sRGB の曲線） | **違う** | tonemap・bloom のしきい・露出の stop の数が標準と別物（A4） |
| tonemap の曲線 | Narkowicz | 同じ式 + W で割る | 曲線は同じ・入力が違う | A4 の数字 |
| 露出 | EV100・`1/(1.2×2^EV)` | stop（任意）・既定 +0.4 | 違う | EV から stop へは `stops = −EV100 + c` の定数ずらし【推・C3】 |
| glTF の材質 | base・metal・rough・emissive・occlusion・ior・specular・clearcoat・transmission… | 前 4 つ + emissive_strength | 一部 | 後ろは読まれない（絵が変わる） |
| glTF の光 | `KHR_lights_punctual` | 読まない（ノードだけ） | 不足 | 光はゲームが手で置く |
| 2D との境目 | — | 画面の値で blend | 独自 | A5 |

### C2. 今のまま外から持ってこられる物 / 持ってこられない物
- **持ってこられる**: (a) 光の色の比・色温度と色（Kelvin → 線形 sRGB → `linearToSrgb` で hex）(b) material の base color・metallic・roughness（D・F・F0 が同じ。拡散の 1/π と G の差は残るが、**値が同じなら絵が大きく外れない**範囲）(c) tonemap の曲線の形 (d) 太陽と空の明るさの **比**（直射 : 空 = 100000 : 20000 = 5 : 1）(e) 室内外の差を「何 stop」で言う（例: 晴れ 15 と室内 7 は 8 stop）。
- **持ってこられない**: (a) 絶対の強さ（lux・cd・EV100）— 逆二乗がなく、露出の口が無い (b) 環境マップの明るさ（8bit・較正なし）(c) 拡散の空の光 (d) 標準 tonemap にそのまま通す HDR の値（A4）。
- 実用の換算（太陽だけは近似が成り立つ）【推・手計算】: 太陽 E lux を、露出 EV100 のカメラで、白い拡散面に垂直に当てた時の 画素の線形値 = `E / π × 1/(1.2 × 2^EV100)`。例: 100000 lx・EV100 15 → 約 0.81（Filament の `L_max` から）。エンジンの `intensity`（拡散に 1/π なし）はこの値に当たる。**同じ式で鏡面の側は π 倍する必要がある**（A2）。点光源はこの換算が距離ごとにずれる（A1）。

### C3. 単位を持たせる案（見本は型検査していない。（新）= 今は無い名前）
**型で止める形（3 案共通）**: `Lux`・`Candela`・`Ev100`・`Kelvin` を、既存の `Texture3d` と同じ形（非 pub の `enum LuxData { case LuxData(Float64) }` + `pub type alias Lux = LuxData`。`Texture3d.flix:9-22` と `Scene3d.MaterialData` の写し）で別の型にする。`Lux.of(100000.0)`・`Lux.toFloat64`。Float64 を 2 つ並べて渡す形にしない。**書き方の細部（opaque の宣言）は `/flix-docs` を読んで決める**【未読】。

**案 (i) 新しい口だけ物理（推す）**
```flix
// 型検査していない。（新）
let eye = Exposure.ev100(Ev100.of(15.0));                                         // （新）晴れ。後の Pass にも渡す
let sun = Scene3d.sunLux(eye, Lux.of(100000.0), Kelvin.of(5778.0), Vec3.v3(-0.4, -1.0, -0.3));   // （新）DirectionalLight を返す
let lamp = Scene3d.pointCandela(eye, Candela.of(80.0), Kelvin.of(2700.0), pos, 8.0);              // （新）PointLight を返す
let post = PostStack.of(                                                           // （新）Pass の列。案 1 の `PostStack`
    PostStack.Effect.Tonemap(PostProcess.Tonemap.AcesFitted, { exposure = Exposure.asStops(eye), whitePoint = 4.0 }) :: Nil)
// 中身: intensity = lux / π × 1/(1.2 × 2^ev100)（pre-exposure。Filament の「光に露出を掛ける」と同じ）。古い intensity の口は据え置き
```
- 今のゲームの絵: **変わらない**（古い口をそのまま使う）。CPU・gl-parity: **式を変えないので波及なし**（木の入力の値が変わるだけ）。取り違え: 新しい口は型で止まる。
- 弱点: 逆二乗が無いので `pointCandela` の見た目の距離感は物理と違う（近い所が平ら）。ここは別の仕事（減衰を逆二乗にする口 = `range` の式の差し替え）で、先に決める。鏡面の π は新しい口の中で補正するか、木に係数を足して全体で直すかを決める（後者は既存の絵が変わる）。

**案 (ii) 場面ごとの切り替え（Godot 型）**
```flix
// 型検査していない
let scene = { physicalUnits = Some({ exposure = Ev100.of(15.0) }) | Scene3d.scene(camera, size) }   // （新）Scene3dCmd の欄
// pointLights の intensity は同じ Float64 のまま、physicalUnits が Some なら cd と読む
```
- 絵: 欄を使う場面だけ変わる。CPU・gl-parity: 木の入力の係数を場面で変えるので、**GL と CPU の両方に「場面の欄」を通す配線**が要る（`Scene3dCmd` の欄は GL・CPU・`DrawHash` の鍵・`WorldHash` に出る）。取り違え: **型は同じ Float64 なので止まらない**（Godot の弱点そのまま）。
- 長所: 同じ API のまま移せる。短所: 本方針（取り違えは型で止める）に合わない。

**案 (iii) 全部を物理へ移し、古い値を換算の関数で受ける**
```flix
// 型検査していない
let legacy = Scene3d.fromLegacyIntensity(Ev100.of(15.0), 1.5);   // （新）古い intensity → Candela/Lux に換算（絵が同じになる露出を逆算）
```
- 絵: 古い値を換算しても **逆二乗が無い・拡散の 1/π が無い**ため、完全には同じにならない。反対に換算を厳密にすると既存の全部の絵が変わる（`docs/migrations/0.79.0.md` のように「3D の絵は全部変わる」版上げになる）。CPU・gl-parity: reference の SHA が全部入れ替わる。取り違え: 型で止まる。HDR の Pass を線形にすると、2D との blend の見えが変わる（A5）。
- 長所: 終点がきれい。短所: 代金が大きい。

**HDR の Pass を線形にする時の 2D との境目（どの案でも別に要る）**
- 案 a: 3D の場面を線形の Pass に書き、tonemap の後の LDR の層で 2D を足す（HUD・UI は既にそう）。場面の中の 2D（空の背景・ビルボードでない 2D の光）は tonemap の前へ入れられなくなる。
- 案 b: 線形の Pass に 2D の物を書く時、色を線形へ戻して書く（2D のシェーダーに target の色空間を渡す）。blend が線形で行われるので、半透明の見えが変わる（A5 の 0.5 → 0.735）。
- 推す: まず a。`PostStack` の入口で「scene の Pass は線形・出口は LDR」と決める。
- 小さい足し方【推】: `r3d_surfaceOut` の最後の `linearToSrgb` を、書き先が「線形の HDR」の Pass なら外す 1 か所（`Render3dGlsl.flix:195` と CPU の同じ式）。**既定は今のまま**、`Scene3dCmd` か Pass の欄で選ぶと、gl-parity は「選んだ時」の 1 場面を足せば足りる。

**推す案**: (i)。理由 — (1) 絵が変わらず、CPU・gl-parity・Studio を壊さない。(2) 型で取り違えを止める方針に合う。(3) 逆二乗と鏡面の π という **別の宿題**を、新しい口の側だけで先に解ける。(iii) へは、(i) で使った値が揃ってから `fromLegacyIntensity` を足して寄せる。

### C4. 外からの評価の手順（Khronos のモデルを使う版。実行はしていない）
1. **解析テスト（外の画像なし・手間 小）**: (a) 白の拡散球 + 太陽 1 本 → 垂直の画素 = `albedo × intensity`（A2 の 1/π なしを固定）(b) 白の furnace（一様な環境 + 白）→ 拡散と鏡面の和の上限 (c) 鏡面のピーク値 = `D·G·F/(4 n·v) × power`（式の値を `bench/gl_parity` の「式の行」に足す）(d) tonemap の曲線を Narkowicz の式の表と数値で比べる。
2. **Khronos の見本 + Cycles（手間 中）**: `MetalRoughSpheres（絵なし）` と `DamagedHelmet` を、エンジンは `Gltf.loadTexturedPbrUsing`（今ある）で読み、光は太陽 1 本 + ambient、**環境マップは使わない**。Blender 5.2.3 の Cycles は bounce 0・世界を一様色・同じ光で描く（D1 の手順）。比べる前に「単位の換算」を白い拡散面 1 枚で実測してから。
3. **環境を足す版（手間 大）**: 先に要る物 — HDR の画像を読む口（`.hdr` の RGBE 読み・Texture3d に浮動小数か RGBE の形）・環境マップの前計算（拡散用 SH・粗さごとの鏡面）・`KHR_materials_*`（ior・specular は材質の見えに直結）。HDRI は Poly Haven の 1k（CC0）。
4. **合否の言い方**: 「同じ場面・同じ光で、線形の輝度の相対差の中央値と 95 パーセンタイル」と「FLIP の平均」。基準の線は **自分たちで決める**（Khronos の頁は指標を出していない）。
- かかる手間の見立て【推】: 手順 1 = 小・手順 2 = 中・手順 3 = 大（HDR 読み + 前計算 + 拡張）。

## D. 広い題材（草原・町・室内）の評価の手順（追加の節）

### D1. Cycles で正解の絵を作る手順（実行はしていない）
**(a) glTF を書き出せるか**: **読むだけ**。`Gltf` に export の口は無い（`refactor search export` で `Gltf` の物は 0・pub は `load`・`fromGlb*`・`loadTextured*Using` のみ）【確】。したがって向きは **Blender で場面を作り → glb にしてエンジンが読む**（`lamplighter` の `modeling/town.py` と `pbr_room` の `modeling/room.py` と同じ）。エンジンの手で組んだ場面は Blender へ戻せない。
**(b) このリポジトリの Blender の使い方**【確】
- 場所: `/nix/store/2rqcqsp3ww61r0qw46izbppssz3bnqxg-blender-5.2.3/bin/blender`（もう 1 つ 5.2.2 が `6c6rcyw1…-blender-5.2.2`）。engine の `devbox.json` には Blender が無く、ゲーム（`~/Documents/flix_ge_workspace/lamplighter/Makefile:32-39`）が `BLENDER ?= …`（別の機械では `local.mk`）で持つ。実行は `blender -b --factory-startup --python town.py -- --bake`。
- lightmap のベイク（`docs/lightmap.md`）・`COL_*` のノード名の当たり判定の箱。
- **既に Cycles でエンジンの構図を描く型がある**: `~/Documents/flix_ge_workspace/pbr_room/modeling/render_ref.py`（`CYCLES`・CPU・128 サンプル・denoise・960×540・`ep(x,y,z) = (−x, −z, y)` の座標変換・`sensor_fit = VERTICAL` で縦の画角を合わせる・点光源は W で指定・世界は一様色）。出力は `debug/pbr/blender/`。**この型を土台にする**。
**(c) 合わせる項目と、A の差がずれとして出る所**
| 項目 | Blender（Cycles）の側 | エンジンの側 | A の差がどう出るか |
|---|---|---|---|
| カメラ | `sensor_fit = VERTICAL`・`angle = 縦の画角`・解像度・near/far | `Camera3d`（縦の画角 `fovY`・左手系で X を反転）| 座標変換 `ep` を使う。合わなければ画の全体がずれる |
| 光の単位 | 点: W（放射束・Cycles では光束の 1/π の約束があるはずで【推】・**実測で較正**）。太陽: Strength（W/m²）。スポット: `spot_size`・`spot_blend` | 無単位 `intensity`・`range`・smoothstep | **A1 の逆二乗の差**: 近くはエンジンが暗く（上限 1）、遠くは窓で落ちる。比べは **同じ距離の面** に限る |
| 太陽の影 | 光源の角度の直径（柔らかい影） | PCF（`pcfRadius`・`mapSize`） | 影の縁の幅が違う |
| 環境・空 | World の背景（一様色 or HDRI）。**Cycles は拡散の空の光も計算** | ambient + hemisphere（手合わせ）。環境は映り込みだけ | **A3**: 影の側がエンジンは暗い。World 無しと有りの 2 枚を Cycles で撮り、差が「足りない拡散の空」 |
| 間接光（バウンス） | `max_bounces = 0` で直接光だけ（エンジンに GI が無いため）。別に既定の bounce も撮る | 無し（lightmap か ambient で手合わせ） | 直接光だけの比べと、バウンスありの比べを分ける |
| 材質 | Principled BSDF（Blender 4 以降: 拡散は Lambert・多重散乱 GGX・拡散を鏡面の反射率分だけ減らす層）【推: 版による】 | 拡散 + 鏡面（保存なし・多重散乱なし） | **粗い金属はエンジンが暗く**、絶縁体の拡散はエンジンが少し明るい（(1−F) なし） |
| emission | Strength（glTF の `emissive_strength` と対応して取り込まれる） | `emissionIntensity` | 同じ向き（線形の倍率） |
| view transform | 比べるのは **線形の EXR**（tonemap を通さない）。見せ用だけ Standard / AgX / Filmic。Blender 4 以降の既定は AgX【推】で、Standard = OETF のみ | HDR の Pass の値は画面の値 → 比べる前に `srgbToLinear` で線形へ戻す（A4 の逆変換）| **tonemap を通した後の比べは、A4 の入力の違いがそのままずれになる**ので、tonemap は別に（曲線だけ）比べる |
| 縁 | フィルター幅 1.5 px の Blackman-Harris | MSAA か無し | 縁の画素は比べから外す |
| 乱数 | サンプル数・denoise（OpenImageDenoise） | 決定的 | 基準の絵のノイズの分だけ下限がある（128 サンプル + denoise の絵の自己ノイズを測る） |
**HDR の値の取り出し**: エンジンの描き出しは `HeadlessRender.renderPassImage`（途中の Pass の絵）で HDR の Pass を取れる。ただし `SoftRaster.toArgbImage` は 0..1 に切る（`reference-3d.md`）。**浮動小数のまま書き出す口があるかは確かめていない**【不明】→ 無ければ露出を下げて 1 以下に収めた 8bit で比べる（精度は落ちる）。EXR・float の書き出しの口は先に要る【推】。
**(d) 比べる指標**
- **FLIP**（NVIDIA）: **BSD-3-Clause**（コード）。入手: `pip install flip-evaluator`（Python 3.10 以上）・C++ / CUDA の `FLIP.h`・PyTorch。**LDR-FLIP と HDR-FLIP（EXR を受ける）**がある（github.com/NVlabs/flip）【確】。HDR-FLIP は線形の EXR をそのまま比べられる。viewing の条件（画素/度）は頁から読めず【不明】。
- SSIM（`scikit-image` など）・画素の差（線形の相対誤差の中央値と 95 パーセンタイル）・明るさの分布（輝度のパーセンタイル・白飛び / 黒つぶれの割合）。
- 道具は engine のリポジトリの外（Python）で回し、`.gitignore` の外へ絵を入れない（AGENTS.md の「生成した絵は git に入れない」）。
**(e) 大手の「リアルタイムを path tracer と比べる」一次**
- Unreal: Path Tracer は「ground truth の参照画像を作る道具」（UE4.26 文書・docs.unrealengine.com/4.26/RenderingAndGraphics/RayTracing/PathTracer と dev.epicgames.com/documentation/en-us/unreal-engine/path-tracer-in-unreal-engine）。
- Unity: HDRP の path tracing（docs.unity3d.com/Packages/com.unity.render-pipelines.high-definition@17.0/manual/reference-path-tracing.html）。**「基準にする」とは公式文書に書かれていない**（フォーラムの言と 2020 年の blog が「参照画像を作るのに便利」）。
- Filament: Mitsuba との比べ（B4）。glTF: Render Fidelity（B4）。Khronos は Sample Viewer の golden を基準にしている形跡のみ。

### D2. 公開されている基準の場面（広い題材向け）
| 場面 | 題材 | ライセンス | 形式・大きさ | このエンジンで読めそうか |
|---|---|---|---|---|
| Intel Sponza（Base） | 室内の中庭・PBR・4K テクスチャ | **CC BY（「Creative Commons Attribution」。版は頁に無し）** — 商用可・表示が要る（intel.com の Samples Library） | glTF・USD・FBX・3ds Max。**3.71 GB** | 大きい。絵を 1024 へ縮め、部位を絞るなら試せる（`Gltf.TextureLimits`）。**印: △** |
| Intel Sponza の追加（Curtains 750 MB・Ivy 1.29 GB・Trees 907 MB） | カーテン・ツタ・糸杉（葉は alpha の板） | 同上 | glTF あり | Trees は alpha の板で草原の葉の試験に向く。**印: △〜○（Trees）** |
| Sponza（Crytek・glTF-Sample-Assets 版） | 室内（PBR 化） | **Cryengine Limited License**（Crytek）【確】 | glTF | 公開物に入れない。ローカルの比べだけ |
| Amazon Lumberyard Bistro | 街角の店（内外）・植物・透け | **CC BY 4.0**・帰属要（ORCA の頁の推奨の引用）【確】 | FBX + Falcor。内 約 105 万・内（ワイン付き）約 129 万・外 約 283 万三角形。**glTF は無い → Blender で変換** | 内側（約 105 万）は試せる可能性。**印: △** |
| NVIDIA Emerald Square | 屋外の街・SpeedTree の植物 | **CC BY-NC-SA 3.0**（非商用）【確】。約 1005 万三角形 | FBX | 重い・NC。**印: ×**（公開物に入れない） |
| UE4 Sun Temple | 屋外の遺跡・植物 | **CC BY-NC-SA 4.0**（非商用）【確】。頂点 約 164 万 | FBX + Falcor | **印: ×**（公開物に入れない）。ローカルの検証のみ |
| San Miguel（Guillermo Leal Laguno） | 屋外の中庭・植物 | 【不明】（McGuire Archive の頁が JS で読めず） | OBJ【推】 | — |
| Moana Island Scene | 巨大な島・植生 | **Disney の独自ライセンス: 研究・ソフト開発（ベンチマーク含む）のみ・商用の言及なし・名前を使う制限あり**（License.txt）【確】 | USD 15 GB・PBRT 6 GB | **印: ×**（大きさも用途も） |
| Blender の公式デモファイル | 各種 | 頁が 403 で読めず【不明】 | .blend | ライセンスを確かめてから |
| McGuire Computer Graphics Archive（casual-effects.com/data） | 多数 | 頁が JS で読めず【不明】 | 多数 | 個別に確認 |
- 方針【推】: **公開物（gallery・docs）に出す比べには CC BY 以上（Bistro・Intel Sponza・Poly Haven・ambientCG）だけ**。NC・研究用のみは、手元の確認だけで絵を `docs/gallery/` へ入れない。

### D3. 測って作られた素材
| 出どころ | ライセンス | 中身と手に入る形 |
|---|---|---|
| **Poly Haven** | **CC0**（polyhaven.com/license）【確】 | テクスチャ（`api.polyhaven.com/files/<id>`: `Diffuse`・`nor_gl`・`nor_dx`・`Rough`・`AO`・`Displacement`・`arm`・`spec`・`Mask`・`blend`・`gltf`・`mtlx`。1k〜8k・jpg / png / exr）。モデル（植物・岩・倒木。例 `anthurium_botany_01` 約 4,100 ポリ・`fern_02` 約 6,200・`dandelion_01` 約 64,000・`grass_bermuda_01` 約 224,000・`grass_medium_01` 約 160 万・`celandine_01` 約 175 万・`fir_tree_01` 約 785 万）。**スキャン由来で草・木は重い**。軽い物（シダ・熱帯の草）だけエンジンの規模に合う |
| **ambientCG** | **CC0 1.0**（docs.ambientcg.com/license・帰属不要・商用可）【確】 | PBR の材質（地面・土・岩・木の板）。地面の素材は base color・法線・roughness・AO・displacement の組がある【推。頁にはマップの一覧が出ていなかった】 |
| physicallybased.info | CC0 1.0 | 値の表（B2）。草・コンクリート・雪・砂・アスファルトの代表の色 |
| Khronos glTF-Sample-Assets | CC BY 4.0 他（モデル別） | PBR の見本 |
- 草・土・岩・木で **glTF か PBR テクスチャの組で手に入るか**: 岩・土・木の面は Poly Haven / ambientCG のテクスチャ（Diffuse・nor_gl・Rough・AO）で入る。草は Poly Haven のモデル（scan・重い）か、Intel Sponza の Trees のような **alpha の板**。透けの絵（`Mask`）は Poly Haven が持つ。
- **代表の反射率**（線形 base color）は B2（草 0.105/0.133/0.041・砂・雪・コンクリート・アスファルト）。土・木・葉は【不明】（physicallybased の json の前半を読み切れず）。

### D4. 草原を題材にした時に、エンジンに足りない物
| 欲しい物 | 今 | 足りない点 |
|---|---|---|
| 同じ形を大量に描く | **インスタンス描きはある**（`Render3d.DrawMode.Instanced`・1 体 8 texel の行列と色を texture で渡す・`Render3dGlsl.instancePrelude`）。入口は `Scene3dCmd#instances: List[Instance3d]`（1 個ずつのレコード） | 数十万本の草は `List` の組み立てが重い（`analysis-render-structure.md` A8: 857 個で 14.1 ms）。**GPU の側で置く / 間引く口（Horizon Zero Dawn 型）は無い** |
| GPU で風に揺らす | **頂点を動かす口が無い**（`refactor search displace` = 0・材質の Spec は fragment だけ。頂点シェーダーは `meshVertexSourceOf` の固定） | 頂点の位置を時間・高さで動かす入口（`Param` と時刻を頂点側で読む）。Crysis の三角波 + cubic（GPU Gems 3 第 16 章）のような式を載せる場所 |
| 葉の透け（subsurface） | 無い（半透明は alpha blend か cutout のみ・拡散の透過なし） | `KHR_materials_diffuse_transmission`（**Release Candidate**・`diffuseTransmissionFactor` と色）と `KHR_materials_transmission`（透過・clearcoat と同じ系統）を読んで、裏から当たる光を拡散で足す項。草・葉は薄い面なので diffuse_transmission が近い |
| 遠くを描かない / 色に溶かす | かすみ（距離の線形 mix）・視錐台の外の間引きはある・**距離で消す LOD や、遠景の草を地面の色へ溶かす口は無い** | 距離で本数を減らす・遠景を地面の材質へ寄せる |
| 切り抜きの縁（alpha to coverage） | **ある**（MSAA の Pass で cutout は alpha to coverage・`scene3d.md` 252） | CPU には出ない（MSAA 非対応）。Web では近似（discard）【確: backend-parity】 |
| 影を受ける | 太陽の影（PCF・カスケード 1 段）・スポットの影はある。ビルボードは影を受けない（`scene3d.md`） | 草の板（ビルボード）が影を受けない・草が地面に落とす影の安い形（接触影）が無い |
| 空からの光 | hemisphere（上向きの面に一様）・ambient・環境マップは映り込みだけ | **空から草の葉への拡散光（irradiance）が無い**。草の色が実物より沈む（A3） |
- 作り方の一次（題・年・URL・中身 1〜2 行）:
  - **Procedural Grass in 'Ghost of Tsushima'**（Eric Wohllaib・Sucker Punch・GDC 2021 / SIGGRAPH Advances in Real-Time Rendering 2021）— 広い草地を少ないメモリで描くため、1 本ずつの葉の置き方と動かし方を工夫する発表。gdcvault.com/play/1027214（ほか advances.realtimerendering.com/s2021/）【確: 題と所属。中身はスライドを読んでいない】
  - **GPU-Based Run-Time Procedural Placement in Horizon: Zero Dawn**（Jaap van Muijden・Guerrilla・GDC 2017）— 植生をすべて GPU で実行時に置く仕組み（置き場所の地図・生態の分類）。スライド: guerrilla-games.com/media/News/Files/GDC2017_VanMuijden_GPUBasedProceduralPlacementInHorizonZeroDawn.pdf【確: 題と要旨。スライド本文は未読】
  - **Vegetation Procedural Animation and Shading in Crysis**（Tiago Sousa・GPU Gems 3 第 16 章・2008）— sin でなく三角波を cubic で丸めた風・葉のシェーディング。developer.nvidia.com/gpugems/GPUGems3/gpugems3_ch16.html【確: 概要。本文は未読】
  - **Anti-aliased Alpha Test: The Esoteric Alpha To Coverage**（Ben Golus・2017）— 葉の cutout を MSAA の coverage で抜く話。bgolus.medium.com/anti-aliased-alpha-test-the-esoteric-alpha-to-coverage-8b177335ae4f【確】

### D5. 写実を目指さない絵（ドット絵・トゥーン）
この物差し（物理の単位・基準の絵との差・path tracer）は当てはまらない。光の強さを単位で言う意味が無く、`toonSteps` や `PxShade` のように **段や色数を絵の目標が決める**。代わりの基準は「**目標の絵を人が選び（`/style-interview`・`docs/art-ref/`）、同じ構図の絵と並べて 5 性質（`docs/drawing-floor.md`）と、目標の絵への近さを人が採点する**」。機械の指標は「階調の段・格子」（lint-style）まで。

## 確かめられなかった事
- 拡散の 1/π の欠落の影響の大きさ（鏡面が 1/π に弱い）は、式の読みと手計算だけ。**描いて比べていない**【推】。G の差の向き・大きさも未計算。
- A4 の数値（0.70 / 0.455 / 0.56 / 0.10 / 0.13 / 0.86 / 0.99・50% 白の 0.5 と 0.735）は電卓なしの手計算。±0.01 は動く。
- `Gltf` の KHR 拡張の網羅（emissive_strength と texture_transform 以外が無い）は `Gltf.flix` の grep だけ（`src/engine` 全体の KHR_ 検索は 0 件出力で、コマンドの形の誤りの可能性）【推】。
- Cycles の点光源 W と放射強度の換算・Principled BSDF の細部・Blender の既定の view transform（AgX）は文書で確認できず【推】。実測で較正する。
- 浮動小数のまま HDR の Pass を書き出す口、EXR の書き出しの有無。
- Poly Haven の HDRI の絶対輝度の較正・Khronos Sample Environments・ToneMapping・glTF-IBL-Sampler・AgX のライセンス・Filament 文書の表のライセンス。McGuire Archive と Blender デモの頁（JS・403 で読めず）。
- Khronos の Render Fidelity の指標。Filament の IBL の節の続き（`Filament.md` の後半 4 万字）。
- 色温度 → 色の換算式の一次（Krystek など）。
