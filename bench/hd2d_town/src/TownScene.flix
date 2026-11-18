// TownScene — 組んだ町（TileMap3d）と絵（Images）から、毎コマ渡す 3D の場面を作る。
// 動かない面と足元の影は読み込みで 1 回 staticGroup にまとめ、毎コマは隊列の板とカメラだけを差し替える。
mod TownScene {
    use fge::{Camera3d, Color, ImageData, Mat4, Mesh3d, Num, PostStack, Rect2, Render, Scene3d, ShaderDoc, Texture3d, Transform3d, Vec2, Vec3}
    use fge::ShaderDoc.FilterMode
    use Faces.{Quad, Rgb}
    use TileMap3d.{Board}
    use TownMap.{TownMap}

    /// 見た目のつまみ（Doc assets/town.json）。
    /// topDeg・bottomDeg = 画面の上の端・下の端で地面を見下ろす角度・far = カメラの奥の端（m）・shadowDistance・shadowMapSize・shadowStrength・shadowPcf = 太陽の影を描く奥行き（m）・地図の一辺の画素・影の濃さ（0〜1）・縁をならす幅（画素）・
    /// sunElevation・sunAzimuth = 太陽の高さと方位（度。方位は南 = 手前から東へ）・sunIntensity = 太陽の強さ・
    /// ambient = どこにでも当たる光（画面の値）・hemisphere = 上を向く面ほど明るくする量・
    /// boardTint = 板（木・街灯・キャラ）の明るさの掛け目・snapToTexels = 板とカメラの位置を 1 テクセルに丸めるか・
    /// fogNear・fogFar・fog = かすみ（目からの距離と色）・sky = 背景の色・exposure・bloom・fStop・saturation・lift・gamma・gain（暗い所・中間・明るい所の持ち上げ。1 で何もしない）・vignette・fxaa = 後がけ・
    /// billboardTextures = 板の絵の引き方・sunColor = 太陽（夜は月）の色・
    /// lampIntensity・lampRange・lampColor = 街灯の点光源（強さ 0 で灯さない）・lampGlow = 街灯の火袋の光る板の強さ（ブルームでにじむ・0 で置かない）・
    /// extraLamps = 重さを測るために足す点光源の数（広場に並べる）・groundFog・groundFogColor = 地面を這う低い霧の板の濃さ（0 で置かない）と色・
    /// charShadow = 隊列のキャラの影の付け方・heightFog = 地面を這う高さの霧（engine の PostStack.HeightFog・長さは m）・
    /// boardLamplight・boardNightBase = 夜の板（キャラ・木）の明るさ（0 なら光の計算のまま。正なら光を当てない板にして、
    /// 色の掛け目を boardNightBase に、近くの街灯の色を距離で足した物にする・強さの倍率）・bloomThreshold・bloomSize = ブルームの閾値と大きさ・
    /// lanternCore・lanternEdge = 火袋の芯と縁の色・haloColor・haloSize・haloGlow・haloFalloff = 火袋ごとの淡いハローの丸い板の色・直径（m）・強さ・落ち方（乗数）・
    /// charShadowScale = 隊列のキャラの影の板の幅と高さの倍率（見えている板は変えない・太陽と点光源の影の両方）・
    /// charNightBase = 夜のキャラ（隊列と町の人）の板の地の明るさ（夜の露出で暗くなる分を 1 より大きい値で戻す）・charNightFar = 街灯から遠い暗がりのキャラの明るさの割合・
    /// charGain = 光を当てるキャラの板の色の掛け目（景色はそのままでキャラだけ明るくする・夕方）・
    /// charToNight = 夕方 → 夜の間に、キャラの板を光を当てた明るさから夜の掛け目へ先に移す割合（0 で移さない・太陽が落ちる間に上げる）・
    /// lightUnits = 光の量の読み方（Physical は逆二乗・拡散に 1/π）・pointShadows = 街灯の点光源の影（None で落とさない・街灯の強さが 0 の間も落とさない）・
    /// boardLight = 板（キャラ・木・小物）に光を当てるか（Unlit は boardNightBase・charNightBase の掛け目で塗る。Doc では boardLamplight が正なら Unlit）・
    /// glowAlpha = 火袋とハローの光る板の濃さ（0〜1・歩きながら街灯が点く間に 0 から上げる）・
    /// litToUnlit = 光を当てない板の色の掛け目を、光を当てた時の明るさ（0）から夜の掛け目（1）へ移す割合（光を当てない板へ切り替えた直後に 0 から上げる）・
    /// view = 後がけの曲線（View Transform）・heatHaze = 溶岩の上の陽炎（None で掛けない）・
    /// stageLightScale・stageGlowScale = 地図の見た目の欄の点光源の強さと、自分で光る強さに掛ける倍率。
    pub type alias Look = { topDeg = Float64, bottomDeg = Float64, far = Float64, shadowDistance = Float64, shadowMapSize = Int32, shadowStrength = Float64, shadowPcf = Int32,
                            sunElevation = Float64, sunAzimuth = Float64, sunIntensity = Float64,
                            ambient = Color, hemisphere = Float64, boardTint = Float64, snapToTexels = Bool,
                            fogNear = Float64, fogFar = Float64, fog = Color, sky = Color,
                            exposure = Float64, bloomStrength = Float64, fStop = Float64, saturation = Float64, lift = Color, gamma = Color, gain = Color, vignette = Float64, fxaa = Bool,
                            billboardTextures = BillboardTextures,
                            sunColor = Color, lampIntensity = Float64, lampRange = Float64, lampColor = Color, lampGlow = Float64,
                            extraLamps = Int32, groundFog = Float64, groundFogColor = Color, charShadow = CharShadow,
                            heightFog = Option[PostStack.HeightFog], boardLamplight = Float64, boardNightBase = Color,
                            bloomThreshold = Float64, bloomSize = Float64,
                            lanternCore = Color, lanternEdge = Color, haloColor = Color, haloSize = Float64, haloGlow = Float64, haloFalloff = Float64,
                            charShadowScale = Vec2.Vec2, charNightBase = Color, charNightFar = Float64, charGain = Float64, charToNight = Float64, lightUnits = Scene3d.LightUnits, pointShadows = Option[Scene3d.PointShadowMap],
                            boardLight = BoardLight, glowAlpha = Float64, litToUnlit = Float64,
                            view = PostStack.ViewTransform, heatHaze = Option[HeatHaze], stageLightScale = Float64, stageGlowScale = Float64 }

    /// 陽炎（長さは 1280 × 720 の画面の px）。amplitude = ずらす最大の量・wavelength = 縦の波の長さ・rate = 揺れの速さ（Hz）・
    /// rise = 赤く明るい所から上へ広げる長さ。
    pub type alias HeatHaze = { amplitude = Float64, wavelength = Float64, rate = Float64, rise = Float64 }

    /// 板の明るさの決め方。Lit = 場面の光で照らす・Unlit = 光を当てず、色の掛け目で明るさを決める（夜）。
    pub enum BoardLight with Eq, ToString {
        case Lit
        case Unlit
    }

    /// 隊列のキャラの影。Silhouette = 板の絵の形の太陽の影（斜めに伸びる人形の影・足元は薄い小さな楕円だけ）・Soft = 薄い足元の楕円（前の版）・Dense = 濃く少し大きい楕円（案 1）・
    /// DenseCast = 案 1 に、太陽の向きへ薄く短く伸びる影の板を足す（案 2）・SmallBlob = 小さく濃い柔らかい塊を太陽の影の側へ少しずらす（案 3）。
    pub enum CharShadow with Eq {
        case Silhouette
        case Soft
        case Dense
        case DenseCast
        case SmallBlob
    }

    /// 板の絵の引き方。SceneTextures = 場面の textures の Texture3d の名前（CPU の描き出し）・ProjectTextures = project.json の textures の名前（GPU の描き手）。
    pub enum BillboardTextures with Eq {
        case SceneTextures
        case ProjectTextures
    }

    /// 読み込みで 1 回作る物。group = 動かない面と足元の影・textures = 場面に渡す絵・
    /// strips = 隊列の歩きの絵（4 コマを横に並べた物）・contact = 足元の影の形と材質・
    /// town = 組んだ町の面と板（出来ていく演出が部品に分け直す）・materials = 材質の名前 → (材質, 色の掛け目)・sprites = 板の絵・
    /// litLights = そのコマで描き手が選ぶ街灯の点光源（withCamera で入れる・読み込みでは空）。
    pub type alias Res = { map = TownMap, look = Look, group = Scene3d.StaticGroup,
                           textures = List[Texture3d.Texture3d], strips = Map[String, Images.Loaded],
                           contactMesh = Mesh3d.Mesh3d, contactMaterial = Scene3d.Material3d,
                           town = TileMap3d.Town, materials = Map[String, (Scene3d.Material3d, Rgb)], sprites = Map[String, Images.Loaded],
                           denseMaterial = Scene3d.Material3d, lanternTexture = String, haloTexture = String,
                           litLights = List[Scene3d.PointLight], fx = StageFx.Fx, environmentMap = Option[Scene3d.EnvironmentMap],
                           spriteGlows = Map[String, Float64], particleMaterials = Option[Vector[Scene3d.Material3d]] }

    /// 地図と絵を読み、町を組む。skipNpcColumn = 地図の 1・2・3 を置かない列（隊列で歩かせる列）。
    pub def load(m: TownMap, look: Look, skipNpcColumn: Option[Int32], extraStrips: List[String]): Result[String, Res] \ IO =
        loadWithFx(m, StageFx.none(), look, skipNpcColumn, extraStrips)

    /// load に地図の見た目の欄 fx（炎・氷の材質・熱の地図・崖の根元の光る縁・点光源・粒・空の映り込み）を渡す形。
    pub def loadWithFx(m: TownMap, fx: StageFx.Fx, look: Look, skipNpcColumn: Option[Int32], extraStrips: List[String]): Result[String, Res] \ IO =
        loadWithFxUsing(Images.readImageIo, m, fx, look, skipNpcColumn, extraStrips)

    /// loadWithFx の、絵を画素にする口 readImage（assets からの相対の道 → 画素）を渡す形（ブラウザは Fs と decoder で読む）。
    pub def loadWithFxUsing(readImage: String -> Result[String, ImageData.ImageData] \ ef, m: TownMap, fx: StageFx.Fx, look: Look, skipNpcColumn: Option[Int32],
                            extraStrips: List[String]): Result[String, Res] \ ef =
        let loadImage = (path: String) -> readImage(path) |> Result.flatMap(Images.loadedOf(path));
        let sprites = "sprites/tree_broadleaf.png" :: "sprites/tree_cypress.png" :: "sprites/street_lamp_ornate.png" ::
                      "sprites/traveler_td.png" :: "sprites/merchant_td.png" ::
                      (m#objectSprites |> Map.valuesOf |> List.map(o -> o#sprite) |> List.distinct);
        let stripPaths = List.flatten(m#walk#party |> List.map(p -> p#strip) :: ("sprites/traveler_walk4.png" :: "sprites/merchant_walk4.png" :: Nil) :: extraStrips ::
                                      List.map(d -> d#sprite, m#decor) :: Nil) |> List.distinct;
        let table = TileMap3d.materialTableOf(m);
        let tilePaths = List.append(table |> Map.valuesOf |> List.map(fst), StageFx.extraTiles(fx)) |> List.distinct;
        forM (
            tiles <- Result.traverse(loadImage, tilePaths);
            boards <- Result.traverse(loadImage, sprites);
            strips <- Result.traverse(loadImage, stripPaths);
            shadow <- Images.contactShadow();
            dense <- Images.denseShadow();
            lantern <- readImage("sprites/street_lamp_ornate.png") |> Result.flatMap(Images.lanternGlowOf(lanternCenters(), 7.5, 0.42, 0.68, look#lanternCore, look#lanternEdge));
            halo <- Images.halo(look#haloFalloff);
            contactMesh <- unitContactMesh();
            heat <- fx#heat |> Option.map(h -> StageFx.heatTexture(m, h) |> Result.map(Some)) |> Option.getWithDefault(Ok(None));
            sky <- if (fx#reflections) StageFx.skyPanorama(look#sky, look#fog, look#fog) |> Result.map(Some) else Ok(None)
        ) yield {
            let byPath = List.append(tiles, boards) |> List.map(l -> (l#path, l)) |> List.toMap;
            let sizes = byPath |> Map.map(l -> (l#width, l#height));
            let town0 = TileMap3d.build(m, sizes, skipNpcColumn);
            let town = { quads = List.append(town0#quads, StageFx.rimQuads(m, fx)) | town0 };
            let contactMaterial = Scene3d.texturedMaterial(Texture3d.name(shadow), FilterMode.Linear) |> Scene3d.withAlphaBlend(true);
            let texOf = (path: String) -> Map.get(path, byPath) |> Option.map(l -> Texture3d.name(l#texture));
            let overrides = StageFx.materialsOf(m, fx, look#stageGlowScale, table, texOf, heat |> Option.map(Texture3d.name));
            let materials = overrides |> Map.toList |> List.foldLeft((acc, kv) -> {
                let (name, mat) = kv;
                let tint = Map.get(name, acc) |> Option.map(snd) |> Option.getWithDefault(Faces.white());
                Map.insert(name, (mat, tint), acc)
            }, materialsOf(table, byPath));
            let items = List.append(groupItems(materials, town#quads), contactItems(contactMesh, contactMaterial, town#boards));
            { map = m, look = look, group = Scene3d.staticGroup("town", items),
              textures = List.flatten((shadow :: dense :: lantern :: halo :: Nil) :: Option.toList(heat) :: Option.toList(sky) ::
                                      List.map(l -> l#texture, List.append(tiles, boards)) :: List.map(l -> l#texture, strips) :: Nil),
              strips = strips |> List.map(l -> (l#path, l)) |> List.toMap,
              contactMesh = contactMesh, contactMaterial = contactMaterial,
              town = town, materials = materials, sprites = byPath,
              denseMaterial = Scene3d.texturedMaterial(Texture3d.name(dense), FilterMode.Linear) |> Scene3d.withAlphaBlend(true),
              lanternTexture = Texture3d.name(lantern), haloTexture = Texture3d.name(halo), litLights = Nil,
              fx = fx, environmentMap = sky |> Option.map(Scene3d.environmentMap), spriteGlows = StageFx.spriteGlows(m, fx),
              particleMaterials = fx#particles |> Option.map(StageFx.particleMaterials) }
        }

    /// 材質の名前 → (置いた物の材質, 色の掛け目)。
    def materialsOf(table: Map[String, (String, Rgb)], byPath: Map[String, Images.Loaded]): Map[String, (Scene3d.Material3d, Rgb)] =
        table |> Map.toList |> List.filterMap(entry -> {
            let (name, (path, tint)) = entry;
            Map.get(path, byPath) |> Option.map(tex ->
                (name, (Scene3d.texturedMaterial(Texture3d.name(tex#texture), FilterMode.Nearest) |> Scene3d.withDoubleSided(true), tint)))
        }) |> List.toMap

    /// 板 1 枚のビルボード（演出が板の出し方を決める時に使う）。
    pub def boardBillboard(res: Res, b: Board): Option[Scene3d.Billboard3d] = billboardOf(res#sprites, res#look, lampsOf(res), b)

    /// 動かない板（木・街灯・町の人）。look の板の明るさで毎コマ作る。
    // WhyNot: 読み込みで 1 回作って持たない — 歩きながら Look が替わり、行 29 で光を当てない板へ切り替わる。
    pub def staticBoards(res: Res): List[Scene3d.Billboard3d] =
        let lamps = lampsOf(res);
        res#town#boards |> List.filterMap(b -> billboardOf(res#sprites, res#look, lamps, b) |> Option.map(bb ->
            Map.get(b#sprite, res#spriteGlows) |> Option.map(g -> Scene3d.unlit(bb) |> Scene3d.withBillboardTint(Color.rgb(1.0 + g, 1.0 + g, 1.0 + g)))
                |> Option.getWithDefault(bb)))

    /// 場面 scene に地図の見た目の欄の時刻 t の物（溶岩と結晶の点光源・粒・空の映り込み）を足す。
    /// center = カメラの追う点（地図の座標の x・y と床の高さ z・雪の箱の真ん中）。
    pub def withStageFx(res: Res, t: Float64, center: (Float64, Float64, Float64), scene: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        let particles = forM (p <- res#fx#particles; mats <- res#particleMaterials) yield StageFx.particleInstances(res#contactMesh, mats, res#map, p, t, center);
        { pointLights = List.append(scene#pointLights, StageFx.lightsAt(res#map, res#fx, res#look#stageLightScale, t)),
          instances = List.append(scene#instances, particles |> Option.getWithDefault(Nil)),
          environmentMap = match res#environmentMap {
              case Some(e) => Some(e)
              case None    => scene#environmentMap
          } | scene }

    /// res の見た目のつまみを look に替える（読み込みで作った絵と形はそのまま）。
    pub def withLook(res: Res, look: Look): Res = { look = look | res }

    /// res に、カメラ camera・描き物の大きさ size で描き手が選ぶ街灯の点光源を持たせる（光を当てない板へ移る間の明るさに使う）。
    // WhyNot: 街灯の点光源を全部足して明るさを見積もらない — 描き手は画面の真ん中に近い 8 本だけを選んで重みを掛け、画面の外の街灯の光は板に届かない
    pub def withCamera(res: Res, camera: Camera3d.Camera3d, size: Vec2.Vec2): Res =
        { litLights = Scene3d.pickLights({ pointLights = lampLights(res) | Scene3d.scene(camera, size) })#pointLights | res }

    /// 街灯の足元（夜の板の寄り具合）と、描き手が選んだ街灯の点光源（光を当てた時の明るさの見積もり）。
    type alias Lamps = { feet = List[Board], lights = List[Scene3d.PointLight] }

    def lampsOf(res: Res): Lamps = { feet = lampBoards(res#town), lights = res#litLights }

    /// 街灯の板（夜の板の明るさを決める）。
    def lampBoards(town: TileMap3d.Town): List[Board] = town#boards |> List.filter(b -> b#sprite == "sprites/street_lamp_ornate.png")

    /// 背中・右・正面の 4 コマずつを横に並べた帯（dirs "nes"）の 1 人の板と足元の影。dirIndex = 0 背中・1 右・2 正面・
    /// flip = 左右反転（左向きは右の反転）・影は足元の楕円だけ（太陽の影は落とさない）。
    pub def walkerBoard(res: Res, strip: String, tint: Rgb, dirIndex: Int32, frame: Int32, flip: Bool, x: Float64, y: Float64, z: Float64): Option[(Scene3d.Billboard3d, List[Scene3d.Instance3d])] =
        walkerBoardScaled(res, strip, tint, dirIndex, frame, flip, 1.0, x, y, z)

    /// walkerBoard の板の縦の倍率 stretch を渡す形（息遣い。足元はそのまま）。
    pub def walkerBoardScaled(res: Res, strip: String, tint: Rgb, dirIndex: Int32, frame: Int32, flip: Bool, stretch: Float64, x: Float64, y: Float64, z: Float64): Option[(Scene3d.Billboard3d, List[Scene3d.Instance3d])] =
        walkerBoardFrames(res, strip, tint, dirIndex, 4, frame, flip, stretch, x, y, z)

    /// walkerBoardScaled の 1 つの向きのコマ数 perDir を渡す形（息遣いの帯は 2 コマずつ）。
    pub def walkerBoardFrames(res: Res, strip: String, tint: Rgb, dirIndex: Int32, perDir: Int32, frame: Int32, flip: Bool, stretch: Float64, x: Float64, y: Float64, z: Float64): Option[(Scene3d.Billboard3d, List[Scene3d.Instance3d])] =
        Map.get(strip, res#strips) |> Option.map(l -> {
            let cellW = l#width / (3 * Int32.max(1, perDir));
            let source = { position = { x = Int32.toFloat64(cellW * (dirIndex * perDir + frame)), y = 0.0 }, size = { x = Int32.toFloat64(cellW), y = Int32.toFloat64(l#height) } };
            let w = Int32.toFloat64(cellW) / 32.0;
            let h = Int32.toFloat64(l#height) / 32.0 * stretch;
            (standing(billboardName(res#look, l), source, Vec3.v3(x, z, y), if (flip) 0.0 - w else w, h, tintColor(res#look, tint),
                      res#look#charShadow == CharShadow.Silhouette) |> Scene3d.withShadowCasterScale(res#look#charShadowScale)
                |> charLit(res#look, lampsOf(res), x, y, tint),
             characterShadows(res, x, y, z, w))
        })

    /// 太陽の影が伸びる地面の向き（地図の座標・長さ 1）。
    def shadowDirection(look: Look): (Float64, Float64) =
        let az = look#sunAzimuth * Num.pi() / 180.0;
        (0.0 - Num.sin(az), Num.cos(az))

    /// 隊列のキャラ 1 人の影（Look の charShadow で替える）。w = 板の幅（m）。
    pub def characterShadows(res: Res, x: Float64, y: Float64, z: Float64, w: Float64): List[Scene3d.Instance3d] =
        let (dx, dy) = shadowDirection(res#look);
        let ellipse = (mat: Scene3d.Material3d, cx: Float64, cy: Float64, sx: Float64, sz: Float64) ->
            Scene3d.meshInstance(res#contactMesh, Transform3d.toMat4({ scale = Vec3.v3(sx, 1.0, sz) | Transform3d.of(Vec3.v3(cx, z + 0.015, cy)) }))
                |> Scene3d.withMaterial(mat);
        let (soft, softDepth) = (Float64.min(w * 0.8, 1.6), Float64.min(0.5, w * 0.4));
        match res#look#charShadow {
            case CharShadow.Silhouette => ellipse(res#contactMaterial, x, y, soft * 0.6, softDepth * 0.6) :: Nil
            case CharShadow.Soft      => ellipse(res#contactMaterial, x, y, soft, softDepth) :: Nil
            case CharShadow.Dense     => ellipse(res#denseMaterial, x, y, soft * 1.2, softDepth * 1.2) :: Nil
            case CharShadow.DenseCast =>
                let len = 0.7;
                let cast = Scene3d.meshInstance(res#contactMesh,
                    Mat4.mul(Mat4.translate(Vec3.v3(x + dx * len / 2.0, z + 0.012, y + dy * len / 2.0)),
                             Mat4.mul(Mat4.rotateY(Num.atan2(dx, dy)), Mat4.scale(Vec3.v3(soft * 0.55, 1.0, len)))))
                    |> Scene3d.withMaterial(res#contactMaterial);
                ellipse(res#denseMaterial, x, y, soft * 1.2, softDepth * 1.2) :: cast :: Nil
            case CharShadow.SmallBlob => ellipse(res#denseMaterial, x + dx * 0.12, y + dy * 0.12, soft * 0.75, softDepth * 0.85) :: Nil
        }

    /// 材質ごとに 1 つの形（色の掛け目は頂点の色に焼き込み、絵ごとの材質は 1 つ）。
    // WhyNot: 裏の面を捨てる材質にしない — 写した決まり（Blender の試作）は両面で描いており、妻壁や軒の裏の巡りが面ごとに揃っていない。
    def groupItems(materials: Map[String, (Scene3d.Material3d, Rgb)], quads: List[Quad]): List[(String, Scene3d.Instance3d)] =
        let grouped = quads |> List.foldLeft((acc, q) -> Map.insertWith((fresh, old) -> List.append(fresh, old), q#material, q :: Nil, acc), Map.empty());
        grouped |> Map.toList |> List.filterMap(entry -> {
            let (name, qs) = entry;
            forM (
                (material, tint) <- Map.get(name, materials);
                mesh <- Faces.toMesh(tint, qs) |> Result.toOption
            ) yield ("terrain:${name}", Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(material) |> Scene3d.withName(name))
        })

    /// 1 × 1 m の上を向く四角（足元の影を置く時に大きさと位置を行列で掛ける）。
    def unitContactMesh(): Result[String, Mesh3d.Mesh3d] =
        Faces.toMesh(Faces.white(), Faces.quad("contact",
            Faces.p3(-0.5, -0.5, 0.0) :: Faces.p3(0.5, -0.5, 0.0) :: Faces.p3(0.5, 0.5, 0.0) :: Faces.p3(-0.5, 0.5, 0.0) :: Nil, Faces.fullUv(), Nil) :: Nil)

    /// 板の足元の楕円の影 1 つ（Blender の試作と同じ大きさ: 幅 min(w × 0.8, 1.6)・奥行き min(0.5, w × 0.4)）。
    pub def contactInstance(mesh: Mesh3d.Mesh3d, material: Scene3d.Material3d, x: Float64, y: Float64, z: Float64, boardWidth: Float64): Scene3d.Instance3d =
        let w = Float64.abs(boardWidth);
        let place = { scale = Vec3.v3(Float64.min(w * 0.8, 1.6), 1.0, Float64.min(0.5, w * 0.4)) | Transform3d.of(Vec3.v3(x, z + 0.015, y)) };
        Scene3d.meshInstance(mesh, Transform3d.toMat4(place)) |> Scene3d.withMaterial(material)

    def contactItems(mesh: Mesh3d.Mesh3d, material: Scene3d.Material3d, boards: List[Board]): List[(String, Scene3d.Instance3d)] =
        boards |> List.filter(b -> b#shadow == TileMap3d.BoardShadow.Grounded) |> List.mapWithIndex((i, b) ->
            ("contact:${Int32.toString(i)}", contactInstance(mesh, material, b#x, b#y, b#z, b#width)))

    /// キャラの板の色の掛け目: tintColor に charGain（線形）を掛けた物。
    // WhyNot: charGain を線形の掛け目へ掛けてから tintColor に渡さない — tintColor は 1 で頭打ちにするので、白い板が明るくならない。
    def gainedTint(look: Look, t: Rgb): Color =
        let c = tintColor(look, t);
        let k = Float64.pow(base = Float64.max(0.0, look#charGain), 1.0 / 2.4);
        Color.rgb(c#r * k, c#g * k, c#b * k)

    /// 線形の掛け目を、場面の色（画面の値）にする。
    def tintColor(look: Look, t: Rgb): Color =
        Color.rgb(Faces.linearToSrgb(t#r * look#boardTint), Faces.linearToSrgb(t#g * look#boardTint), Faces.linearToSrgb(t#b * look#boardTint))

    /// 板の絵の名前（project.json の textures の名前は、assets/sprites/<名前>.png の <名前>）。
    // WhyNot: GPU でも場面の textures の名前で引かない — GPU の描き手のビルボードは project.json の textures だけを引き、Texture3d の名前は見つからないとして描かない。
    def billboardName(look: Look, l: Images.Loaded): String =
        if (look#billboardTextures == BillboardTextures.ProjectTextures) {
            let stem = String.stripPrefix(substr = "sprites/", l#path) |> Option.getWithDefault(l#path);
            String.stripSuffix(substr = ".png", stem) |> Option.getWithDefault(stem)
        }
        else Texture3d.name(l#texture)

    /// 板 1 枚。カメラが水平なので、カメラへ向く板は地面に垂直に立つ（高さを伸ばす補正は要らない）。
    def billboardOf(byPath: Map[String, Images.Loaded], look: Look, lamps: Lamps, b: Board): Option[Scene3d.Billboard3d] =
        Map.get(b#sprite, byPath) |> Option.map(l ->
            standing(billboardName(look, l), { position = Vec2.zero(), size = { x = Int32.toFloat64(l#width), y = Int32.toFloat64(l#height) } },
                     Vec3.v3(b#x, b#z, b#y), if (b#flip) 0.0 - b#width else b#width, b#height, tintColor(look, b#tint), b#shadow == TileMap3d.BoardShadow.Grounded)
                |> (bb -> if (b#sprite == "sprites/street_lamp_ornate.png") bb
                          else if (isCharacterSprite(b#sprite)) charLit(look, lamps, b#x, b#y, b#tint, bb)
                          else lampLit(look, lamps, b#x, b#y, b#tint, bb)))

    /// 町の人と隊列の絵か（木と街灯でない板）。
    def isCharacterSprite(sprite: String): Bool =
        String.contains(substr = "_td", sprite) or String.contains(substr = "_walk", sprite) or String.contains(substr = "_idle", sprite)

    /// 近くの街灯の寄り具合（街灯ごとに、届く距離の 1.2 倍で 0 になる重みの 2 乗の和）。
    def lampNearness(look: Look, lamps: Lamps, x: Float64, y: Float64): Float64 =
        let reach = look#lampRange * 1.2;
        lamps#feet |> List.foldLeft((acc, lamp) -> {
            let d = Num.sqrt((lamp#x - x) * (lamp#x - x) + (lamp#y - y) * (lamp#y - y));
            let k = Num.clamp(0.0, 1.0, 1.0 - d / reach);
            acc + k * k
        }, 0.0)

    /// 夜の板の明るさ（boardLight が Unlit の時だけ）: 光を当てない板にして、色の掛け目を夜の地の明るさに近くの街灯の色を足した物にする。
    // WhyNot: 光の計算のまま夜の板を照らさない — 板の光の法線はいつもカメラ向きで、キャラの北に立つ街灯の光は板の裏から当たり、真っ黒な影絵になる。
    def lampLit(look: Look, lamps: Lamps, x: Float64, y: Float64, t: Rgb, bb: Scene3d.Billboard3d): Scene3d.Billboard3d =
        if (look#boardLight == BoardLight.Lit) bb
        else {
            let glow = lampNearness(look, lamps, x, y) * look#boardLamplight;
            let c = (floor: Float64, lamp: Float64, tint: Float64) -> Num.clamp(0.0, 1.0, (floor + lamp * glow) * tint);
            let night = Color.rgb(c(look#boardNightBase#r, look#lampColor#r, t#r), c(look#boardNightBase#g, look#lampColor#g, t#g), c(look#boardNightBase#b, look#lampColor#b, t#b));
            Scene3d.unlit(bb) |> Scene3d.withBillboardTint(fromLitTint(look, lamps, bb, t, night))
        }

    /// 夜のキャラ（隊列と町の人）の板の明るさ: 光を当てない板にして、色の掛け目を charNightBase × （溜まりの中は 1・遠い暗がりは charNightFar）にする。
    // WhyNot: 掛け目を 1 で頭打ちにしない — 夜の露出（−2 段）で光を当てない板も 1/4 に暗くなり、溜まりの中のキャラの顔と服が読めない
    def charLit(look: Look, lamps: Lamps, x: Float64, y: Float64, t0: Rgb, bb: Scene3d.Billboard3d): Scene3d.Billboard3d =
        let t = { r = t0#r * look#charGain, g = t0#g * look#charGain, b = t0#b * look#charGain };
        let near = Float64.min(1.0, lampNearness(look, lamps, x, y));
        let k = look#charNightFar + (1.0 - look#charNightFar) * near;
        let night = Color.rgb(look#charNightBase#r * k * t0#r, look#charNightBase#g * k * t0#g, look#charNightBase#b * k * t0#b);
        // WhyNot: 光を当てるキャラの板を、太陽が落ちきるまで光の計算のままにしない — 太陽が 0 に近づくと、裏から街灯を受けるキャラが黒い影絵に沈む。
        if (look#boardLight == BoardLight.Lit and look#charToNight <= 0.0) bb |> Scene3d.withBillboardTint(gainedTint(look, t0))
        else Scene3d.unlit(bb) |> Scene3d.withBillboardTint(litToNightTint(look, lamps, bb, t, night, Float64.max(look#charToNight, unlitShare(look))))

    /// 光を当てない板の色の掛け目: 光を当てた時の明るさから、夜の掛け目 night へ litToUnlit の割合で移した物。
    // WhyNot: 切り替えの瞬間の掛け目を場面に 1 つの値にしない — 街灯が点いた後で切り替えるので、街灯の手前の板と遠い板で明るさが違い、1 つの値ではどちらかが跳ねる
    def fromLitTint(look: Look, lamps: Lamps, bb: Scene3d.Billboard3d, t: Rgb, night: Color): Color =
        litToNightTint(look, lamps, bb, t, night, look#litToUnlit)

    /// 光を当てない板の割合（光を当てる板は 0・光を当てない板は litToUnlit）。
    def unlitShare(look: Look): Float64 = if (look#boardLight == BoardLight.Lit) 0.0 else look#litToUnlit

    /// fromLitTint の、夜の掛け目へ移す割合 share を渡す形。
    def litToNightTint(look: Look, lamps: Lamps, bb: Scene3d.Billboard3d, t: Rgb, night: Color, share: Float64): Color =
        if (share >= 1.0) night
        else {
            let f = Scene3d.billboardFieldsOf(bb);
            let e = litLightAt(look, lamps, f#position#x, f#position#y + Float64.abs(f#size#y) * 0.5, f#position#z);
            let w = Num.clamp(0.0, 1.0, share);
            let k = (lin: Float64, nightC: Float64) -> { let lit = Texture3d.linearToSrgb(lin); lit + (nightC - lit) * w };
            Color.rgb(k(t#r * e#r, night#r), k(t#g * e#g, night#g), k(t#b * e#b, night#b))
        }

    /// 光を当てる板が world の点 (px, py, pz) で受ける光（線形の量）: どこにでも当たる光・描き手が選んだ街灯（lamps#lights）・太陽（月）。
    /// 板の向きはカメラ（南）・光の量の読み方は Physical（逆二乗 × 届く範囲の窓・拡散に 1/π）。影は見ない。
    def litLightAt(look: Look, lamps: Lamps, px: Float64, py: Float64, pz: Float64): Rgb =
        let amb = Texture3d.srgbToLinearColor(look#ambient);
        let sunLin = Texture3d.srgbToLinearColor(look#sunColor);
        let el = look#sunElevation * Num.pi() / 180.0;
        let az = look#sunAzimuth * Num.pi() / 180.0;
        let sun = look#sunIntensity * Float64.max(0.0, Num.cos(el) * Num.cos(az)) / Num.pi();
        let start = { r = amb#r + sunLin#r * sun, g = amb#g + sunLin#g * sun, b = amb#b + sunLin#b * sun };
        lamps#lights |> List.foldLeft((acc, l) -> {
            let (dx, dy, dz) = (l#position#x - px, l#position#y - py, l#position#z - pz);
            let d2 = dx * dx + dy * dy + dz * dz;
            let facing = Float64.max(0.0, 0.0 - dz / Num.sqrt(Float64.max(d2, 0.000001)));
            let r2 = Float64.max(0.000001, l#range * l#range);
            let q = Num.clamp(0.0, 1.0, 1.0 - (d2 / r2) * (d2 / r2));
            let e = l#intensity * q * q / Float64.max(d2, 0.0001) * facing / Num.pi();
            let c = Texture3d.srgbToLinearColor(l#color);
            { r = acc#r + c#r * e, g = acc#g + c#g * e, b = acc#b + c#b * e }
        }, start)

    def standing(texture: String, source: Rect2.Rect2, at: Vec3.Vec3, width: Float64, height: Float64, tint: Color, cast: Bool): Scene3d.Billboard3d =
        Scene3d.billboard(texture, source, at, { x = width, y = height })
            |> Scene3d.withBillboardTint(tint)
            |> Scene3d.withCastShadows(cast)
            |> Scene3d.withReceiveShadows(true)

    /// 隊列の 1 人の板（4 コマの帯から frame 番目を切る）と足元の影。
    pub def memberBoard(res: Res, member: TownMap.Member, frame: Int32, x: Float64, y: Float64, z: Float64): Option[(Scene3d.Billboard3d, Scene3d.Instance3d)] =
        Map.get(member#strip, res#strips) |> Option.map(l -> {
            let frames = res#map#walk#frames;
            let cellW = l#width / Int32.max(1, frames);
            let source = { position = { x = Int32.toFloat64(cellW * frame), y = 0.0 }, size = { x = Int32.toFloat64(cellW), y = Int32.toFloat64(l#height) } };
            let w = Int32.toFloat64(cellW) / 32.0;
            let h = Int32.toFloat64(l#height) / 32.0;
            let tint = member#tint |> Option.map(t -> { let (r, g, b) = t; { r = r, g = g, b = b } }) |> Option.getWithDefault(Faces.white());
            (standing(billboardName(res#look, l), source, Vec3.v3(x, z, y), w, h, tintColor(res#look, tint), true)
                |> Scene3d.withShadowCasterScale(res#look#charShadowScale)
                |> charLit(res#look, lampsOf(res), x, y, tint),
             contactInstance(res#contactMesh, res#contactMaterial, x, y, z, w))
        })

    /// 太陽（光の進む向き）。方位は南（手前）から東へ・高さは地平から。
    pub def sunOf(look: Look): Scene3d.DirectionalLight =
        let el = look#sunElevation * Num.pi() / 180.0;
        let az = look#sunAzimuth * Num.pi() / 180.0;
        let toward = Vec3.v3(Num.cos(el) * Num.sin(az), Num.sin(el), 0.0 - Num.cos(el) * Num.cos(az));
        { intensity = look#sunIntensity, color = look#sunColor,
          shadow = Some({ distance = look#shadowDistance, mapSize = look#shadowMapSize, strength = look#shadowStrength, pcfRadius = look#shadowPcf,
                          bias = 0.03, normalBias = 1.0 | Scene3d.directionalShadow() })
          | Scene3d.directionalLight(Vec3.mul(toward, -1.0)) }

    /// 1 コマの場面（動かない物の集まりと板を渡す形・町が出来ていく間）。
    pub def sceneWith(res: Res, camera: Camera3d.Camera3d, size: Vec2.Vec2, groups: List[Scene3d.StaticGroup], billboards: List[Scene3d.Billboard3d],
                      instances: List[Scene3d.Instance3d], textures: List[Texture3d.Texture3d]): Scene3d.Scene3dCmd =
        { groups = groups, billboards = billboards, textures = textures | sceneOf(res, camera, size, Nil, instances) }

    /// 1 コマの場面。billboards・instances = 毎コマ変わる板と置いた物（隊列）。
    pub def sceneOf(res: Res, camera: Camera3d.Camera3d, size: Vec2.Vec2, billboards: List[Scene3d.Billboard3d], instances: List[Scene3d.Instance3d]): Scene3d.Scene3dCmd =
        sceneOfBoards(res, staticBoards(res), camera, size, billboards, instances)

    /// sceneOf の、動かない板 boards（staticBoards）を先に作って渡す形（Look が替わらない場面は読み込みで 1 回作れば足りる）。
    pub def sceneOfBoards(res: Res, boards: List[Scene3d.Billboard3d], camera: Camera3d.Camera3d, size: Vec2.Vec2, billboards: List[Scene3d.Billboard3d],
                          instances: List[Scene3d.Instance3d]): Scene3d.Scene3dCmd =
        let look = res#look;
        { groups = res#group :: Nil, instances = List.append(nightInstances(res), instances), billboards = List.append(boards, billboards),
          directionalLight = Some(sunOf(look)), textures = res#textures, pointLights = lampLights(res),
          environment = { ambient = look#ambient, hemisphere = look#hemisphere, toonSteps = 0,
                          fog = Some({ color = look#fog, near = look#fogNear, far = look#fogFar }), background = Some(look#sky) }
          | Scene3d.scene(camera, size) }
            |> Scene3d.withLightUnits(look#lightUnits)
            |> (sc -> if (look#lampIntensity <= 0.0) sc else look#pointShadows |> Option.map(m -> Scene3d.withPointShadows(m, sc)) |> Option.getWithDefault(sc))

    /// 広場のにぎやかしの板と足元の影。t = 時刻（コマと揺れ）・drop = i 番目の板の (上からの高さ m, 縦の倍率, 横の倍率)（None はまだ出ていない）。
    pub def decorBoards(res: Res, t: Float64, drop: Int32 -> Option[(Float64, Float64, Float64)]): List[(Scene3d.Billboard3d, Option[Scene3d.Instance3d])] =
        let m = res#map;
        m#decor |> List.zipWithIndex |> List.filterMap(entry -> {
            let (i, d) = entry;
            forM (
                (dy, sy, sxz) <- drop(i);
                l <- Map.get(d#sprite, res#strips)
            ) yield {
                let nf = Int32.max(1, d#frames);
                let cellW = l#width / nf;
                let k = decorFrame(d, nf, t);
                let source = { position = { x = Int32.toFloat64(cellW * k), y = 0.0 }, size = { x = Int32.toFloat64(cellW), y = Int32.toFloat64(l#height) } };
                let w = Int32.toFloat64(cellW) / 32.0;
                let h = d#height |> Option.getWithDefault(Int32.toFloat64(l#height) / 32.0);
                let (swayX, swayZ) = d#sway |> Option.map(sw -> {
                    let (amp, per) = sw;
                    (amp * Num.sin(2.0 * Num.pi() * t / per + d#phase * 6.28), 0.5 * amp * Num.sin(4.0 * Num.pi() * t / per + d#phase * 6.28))
                }) |> Option.getWithDefault((0.0, 0.0));
                let x = Int32.toFloat64(d#col) + 0.5 + d#offX + swayX;
                let y = Int32.toFloat64(m#height - 1 - d#row) + 0.5 + d#offY;
                let ground = TownMap.topAt(m, d#col, d#row);
                // WhyNot: 降りている間の板に太陽の影を落とさせない — 宙の板は自分の影を受けて、着地まで黒い人形に見える
                let board = standing(billboardName(res#look, l), source, Vec3.v3(x, ground + d#z + swayZ + dy, y), (if (d#flip) 0.0 - w else w) * sxz, h * sy,
                                     tintColor(res#look, Faces.white()), TownMap.castsShadow(d#shadow) and dy <= 0.0)
                    |> (bb -> if (isCharacterSprite(d#sprite)) charLit(res#look, lampsOf(res), x, y, Faces.white(), bb)
                              else lampLit(res#look, lampsOf(res), x, y, Faces.white(), bb));
                (board, if (TownMap.hasFootShadow(d#shadow) and d#sway == None) Some(contactInstance(res#contactMesh, res#contactMaterial, x, y, ground, w)) else None)
            }
        })

    /// 板のコマ（seq があれば seq の並び・無ければ 0, 1, 2, …）。
    def decorFrame(d: TownMap.Decor, nf: Int32, t: Float64): Int32 =
        let step = (count: Int32) -> Int32.modulo(Float64.floor(t / d#frameSec + d#phase * Int32.toFloat64(count)) |> Float64.tryToInt32 |> Option.getWithDefault(0), Int32.max(1, count));
        if (nf <= 1) 0
        else if (List.isEmpty(d#seq)) step(nf)
        else List.drop(step(List.length(d#seq)), d#seq) |> List.head |> Option.getWithDefault(0) |> Num.clampInt(0, nf - 1)

    /// 街灯の足元（地図の座標）。
    def lampFeet(res: Res): List[Board] = res#town#boards |> List.filter(b -> b#sprite == "sprites/street_lamp_ornate.png")

    /// 3 灯の街灯の火袋の真ん中（uv・左下が 0,0。street_lamp_ornate.json の写し）。
    def lanternCenters(): List[(Float64, Float64)] = (0.158, 0.64) :: (0.51, 0.76) :: (0.853, 0.647) :: Nil

    /// 街灯の絵の大きさ（m・43×104 px）。
    def lampSize(): (Float64, Float64) = (43.0 / 32.0, 104.0 / 32.0)

    /// 点光源の高さ（足元から m・真ん中の火袋の高さ）。
    def lampHeadHeight(): Float64 = 2.47

    /// 街灯の点光源（火袋の少し手前）と、重さを測るために足す点光源（広場の 2 行に並べる）。
    pub def lampLights(res: Res): List[Scene3d.PointLight] =
        let look = res#look;
        if (look#lampIntensity <= 0.0) Nil
        else {
            let light = (x: Float64, y: Float64, z: Float64) ->
                { position = Vec3.v3(x, z + lampHeadHeight(), y - 0.7), color = look#lampColor, intensity = look#lampIntensity, range = look#lampRange };
            let lamps = lampFeet(res) |> List.map(b -> light(b#x, b#y, b#z));
            let extra = List.range(0, look#extraLamps) |> List.map(i -> light(2.5 + Int32.toFloat64(Int32.modulo(i, 12)) * 2.0, 3.5 + Int32.toFloat64(i / 12) * 4.0, 1.0));
            List.append(lamps, extra)
        }

    /// 夜の置いた物（街灯の火袋の光る板・地面を這う霧の板）。読み込みで作った形を毎コマ置くだけ。
    def nightInstances(res: Res): List[Scene3d.Instance3d] =
        let look = res#look;
        let (lw, lh) = lampSize();
        let upright = (cx: Float64, cy: Float64, cz: Float64, sx: Float64, sz: Float64) ->
            Mat4.mul(Mat4.translate(Vec3.v3(cx, cz, cy)), Mat4.mul(Mat4.rotateX(0.0 - Num.pi() / 2.0), Mat4.scale(Vec3.v3(sx, 1.0, sz))));
        let glows = if (look#lampGlow <= 0.0) Nil else lampFeet(res) |> List.flatMap(b ->
            (Scene3d.meshInstance(res#contactMesh, upright(b#x, b#y - 0.03, b#z + lh / 2.0, lw, lh))
                |> Scene3d.withMaterial(glowMaterial(res#lanternTexture, Color.rgb(1.0, 1.0, 1.0), look#lampGlow, look#glowAlpha))) ::
            (lanternCenters() |> List.map(uv ->
                Scene3d.meshInstance(res#contactMesh, upright(b#x + (fst(uv) - 0.5) * lw, b#y - 0.06, b#z + snd(uv) * lh, look#haloSize, look#haloSize))
                    |> Scene3d.withMaterial(glowMaterial(res#haloTexture, look#haloColor, look#haloGlow, look#glowAlpha)))));
        let fogs = if (look#groundFog <= 0.0) Nil else (0.35 :: 0.8 :: Nil) |> List.mapWithIndex((i, h) ->
            Scene3d.meshInstance(res#contactMesh, Mat4.mul(Mat4.translate(Vec3.v3(13.5, 1.0 + h, 13.0)), Mat4.scale(Vec3.v3(60.0, 1.0, 60.0))))
                |> Scene3d.withMaterial(fogMaterial(look, i)));
        List.append(glows, fogs)

    /// 光る板の材質（絵 texture の色 × tint を、絵の α の所だけ光らせる・半透明で重ねる・ブルームが拾う明るさ）。k = 光の強さ。
    def glowMaterial(texture: String, tint: Color, k: Float64, opacity: Float64): Scene3d.Material3d =
        let sample = (ch: ShaderDoc.TexChan) -> ShaderDoc.Field.Sampler({ filter = ShaderDoc.FilterMode.Nearest, of = ShaderDoc.Field.Tex({ name = texture, chan = ch }) });
        let mul = (a: ShaderDoc.Field, b: ShaderDoc.Field) -> ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, a = a, b = b });
        // WhyNot: 光の強さだけを 0 から上げない — 地の色は黒の半透明なので、光が弱い間は板が黒い輪になって街灯の周りが暗く跳ねる
        let alpha = mul(ShaderDoc.Field.Const(opacity), sample(ShaderDoc.TexChan.A));
        let lit = (v: Float64, ch: ShaderDoc.TexChan) -> mul(ShaderDoc.Field.Const(v), sample(ch));
        let rgb = ShaderDoc.Shade.Rgb({ r = lit(tint#r, ShaderDoc.TexChan.R), g = lit(tint#g, ShaderDoc.TexChan.G), b = lit(tint#b, ShaderDoc.TexChan.B) });
        let dark = ShaderDoc.Shade.Rgb({ r = ShaderDoc.Field.Const(0.0), g = ShaderDoc.Field.Const(0.0), b = ShaderDoc.Field.Const(0.0) });
        // WhyNot: 地の色を絵の色にしない — 板は点光源の 0.7 m 先にあり、Physical の逆二乗で地の色が白く飛んで火袋の黄色が消える
        Scene3d.material({ name = "hd2d:lamp-glow", cycleRate = 0.0, bindings = Nil, out = ShaderDoc.Out.Fill({ shade = dark, alpha = alpha }) })
            |> Scene3d.withEmission(rgb)
            |> Scene3d.withEmissionIntensity(k)
            |> Scene3d.withAlphaBlend(true)
            |> Scene3d.withDoubleSided(true)

    /// 地面を這う霧の板の材質（周期つきの雲状ノイズを時刻でゆっくり流し、濃い所だけ半透明で残す）。layer = 板の段（段ごとに模様と流れを替える）。
    def fogMaterial(look: Look, layer: Int32): Scene3d.Material3d =
        let c = (v: Float64) -> ShaderDoc.Field.Const(v);
        let speed = if (layer == 0) { x = 0.004, y = 0.0015 } else { x = -0.003, y = 0.0025 };
        let noise = ShaderDoc.Field.Scaled({ factor = 1.0, scroll = speed,
                                             of = ShaderDoc.Field.FbmTile({ octaves = 3, scale = 8.0, period = { x = 8.0, y = 8.0 }, seed = 11 + layer }) });
        let alpha = ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, a = ShaderDoc.Field.Smoothstep({ lo = 0.4, hi = 0.75, of = noise }), b = c(look#groundFog) });
        Scene3d.material({ name = "hd2d:ground-fog", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = c(look#groundFogColor#r), g = c(look#groundFogColor#g), b = c(look#groundFogColor#b) }),
                                                      alpha = alpha }) })
            |> Scene3d.withAlphaBlend(true)
            |> Scene3d.withDoubleSided(true)

    /// 後がけ（Look の曲線・露出・ブルーム・ピントの奥行きでぼかす・彩度・周りを暗く・陽炎）。focus = ピントの合う奥行き（m）・t = 時刻（秒・霧のむらと陽炎を流す）・
    /// width = 描き物の横の大きさ（design px・陽炎の長さを 1280 の画面から直す）。
    pub def postAt(look: Look, focus: Float64, t: Float64, width: Float64): PostStack.Stack = postFlashAt(look, focus, t, 0.0, width)

    /// postAt に、露出へ足す段 flash（着地の光）を渡す形。
    pub def postFlashAt(look: Look, focus: Float64, t: Float64, flash: Float64, width: Float64): PostStack.Stack =
        PostStack.preset(PostStack.Preset.Neutral)
            |> PostStack.withHeightFog(look#heightFog)
            |> PostStack.withTime(ShotClock.at(t))
            |> PostStack.withViewTransform(look#view)
            |> withHeatHaze(look#heatHaze, width / 1280.0)
            |> PostStack.withExposure(look#exposure + flash)
            |> PostStack.withBloom(Some({ threshold = look#bloomThreshold, smoothness = 0.5, size = look#bloomSize, strength = look#bloomStrength }))
            |> PostStack.withDepthOfField(if (look#fStop > 0.0) Some(PostStack.DepthOfField.Physical({ focusDistance = focus, fStop = look#fStop })) else None)
            |> PostStack.withColorGrade(Some({ lift = look#lift, gamma = look#gamma, gain = look#gain, saturation = look#saturation }))
            |> PostStack.withVignette(Some({ strength = look#vignette, inner = 0.45, outer = 1.1, center = { x = 0.5, y = 0.5 } }))
            |> PostStack.withFxaa(look#fxaa)

    /// 陽炎の型紙の Pass の名前（場面の色の赤く明るい所と、その上 rise の所を r に書く）。
    def hazeMaskPass(): String = "haze_mask"

    /// 陽炎の後に場面として読ませる Pass の名前（場面の写し）。
    // WhyNot: 型紙の Pass を最後の BeforeBloom の Pass にしない — 後の効果は最後の Pass を場面として読み、型紙の赤が画面に出る。
    def hazeScenePass(): String = "haze_scene"

    /// 陽炎を掛ける（型紙の Pass と場面の写しの Pass を足し、Distortion の範囲を型紙の r にする）。k = 1280 の画面の px → design px の倍率。
    def withHeatHaze(haze: Option[HeatHaze], k: Float64, s: PostStack.Stack): PostStack.Stack = match haze {
        case None    => s
        case Some(h) =>
            let scene = (ch: ShaderDoc.TexChan) -> ShaderDoc.Field.Sampler({ filter = ShaderDoc.FilterMode.Linear, of = ShaderDoc.Field.Tex({ name = PostStack.sceneName(), chan = ch }) });
            // WhyNot: 型紙のぼかしを小さくしない — 1 マスの火の結晶や橙に照らされたキャラも熱い所に数えられ、そばのキャラの顔が揺れる。広い溶岩だけがぼかしの後も熱く残る。
            let blurred = (ch: ShaderDoc.TexChan) -> ShaderDoc.Field.TexBlur({ name = PostStack.sceneName(), chan = ch, radius = { x = 0.045, y = 0.08 }, taps = 9, amount = ShaderDoc.Field.Const(1.0) });
            let bin = (op: ShaderDoc.BinOp, a: ShaderDoc.Field, b: ShaderDoc.Field) -> ShaderDoc.Field.Bin({ op = op, a = a, b = b });
            let hot = bin(ShaderDoc.BinOp.Mul, ShaderDoc.Field.Smoothstep({ lo = 0.45, hi = 0.85, of = blurred(ShaderDoc.TexChan.R) }),
                          ShaderDoc.Field.Smoothstep({ lo = 0.2, hi = 0.45, of = bin(ShaderDoc.BinOp.Sub, blurred(ShaderDoc.TexChan.R), blurred(ShaderDoc.TexChan.B)) }));
            let rise = h#rise / 720.0;
            let lifted = (part: Float64, weight: Float64) ->
                bin(ShaderDoc.BinOp.Mul, ShaderDoc.Field.Const(weight), ShaderDoc.Field.Shift({ dx = ShaderDoc.Field.Const(0.0), dy = ShaderDoc.Field.Const(rise * part), of = hot }));
            // WhyNot: 持ち上げた写しを 1 枚にしない — 溶岩の上の空気が途中で切れ、崖のふちの 1 本の帯だけが揺れる。
            let above = bin(ShaderDoc.BinOp.Max, lifted(0.33, 0.9), bin(ShaderDoc.BinOp.Max, lifted(0.66, 0.7), lifted(1.0, 0.5)));
            let mask = ShaderDoc.Field.Un({ op = ShaderDoc.UnOp.Sat, of = bin(ShaderDoc.BinOp.Mul, ShaderDoc.Field.Const(4.0), bin(ShaderDoc.BinOp.Max, hot, above)) });
            let fill = (r: ShaderDoc.Field, g: ShaderDoc.Field, b: ShaderDoc.Field) -> ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = r, g = g, b = b }), alpha = ShaderDoc.Field.Const(1.0) });
            let maskSpec = { name = "hd2d:haze-mask", cycleRate = 0.0, bindings = Nil, out = fill(mask, mask, mask) };
            let copySpec = { name = "hd2d:haze-scene", cycleRate = 0.0, bindings = Nil, out = fill(scene(ShaderDoc.TexChan.R), scene(ShaderDoc.TexChan.G), scene(ShaderDoc.TexChan.B)) };
            s |> PostStack.withCustom({ name = hazeMaskPass(), at = PostStack.CustomAt.BeforeBloom, spec = maskSpec, reads = PostStack.Read.SceneColor :: Nil, scale = 0.5 } ::
                                      { name = hazeScenePass(), at = PostStack.CustomAt.BeforeBloom, spec = copySpec, reads = PostStack.Read.SceneColor :: Nil, scale = 1.0 } :: Nil)
              |> PostStack.withDistortion(Some({ strength = { x = h#amplitude * k, y = 0.4 * h#amplitude * k }, noiseSize = h#wavelength / 2.0 * k,
                                                 speed = { x = 0.0, y = 0.0 - h#wavelength * h#rate * k }, mask = PostStack.DistortionMask.Texture(hazeMaskPass()) }))
    }

    /// 描き物の列（画面いっぱいに場面を 1 つ）。
    pub def items(scene: Scene3d.Scene3dCmd): List[Render.PlacedItem] = Render.scene3d(Vec2.zero(), scene) :: Nil
}
