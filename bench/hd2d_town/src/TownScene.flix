// TownScene — 組んだ町（TileMap3d）と絵（Images）から、毎コマ渡す 3D の場面を作る。
// 動かない面と足元の影は読み込みで 1 回 staticGroup にまとめ、毎コマは隊列の板とカメラだけを差し替える。
mod TownScene {
    use fge::{Camera3d, Color, Mat4, Mesh3d, Num, PostStack, Rect2, Render, Scene3d, ShaderDoc, Texture3d, Transform3d, Vec2, Vec3}
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
    /// 色の掛け目を boardNightBase に、近くの街灯の色を距離で足した物にする・強さの倍率）・bloomThreshold・bloomSize = ブルームの閾値と大きさ。
    pub type alias Look = { topDeg = Float64, bottomDeg = Float64, far = Float64, shadowDistance = Float64, shadowMapSize = Int32, shadowStrength = Float64, shadowPcf = Int32,
                            sunElevation = Float64, sunAzimuth = Float64, sunIntensity = Float64,
                            ambient = Color, hemisphere = Float64, boardTint = Float64, snapToTexels = Bool,
                            fogNear = Float64, fogFar = Float64, fog = Color, sky = Color,
                            exposure = Float64, bloomStrength = Float64, fStop = Float64, saturation = Float64, lift = Color, gamma = Color, gain = Color, vignette = Float64, fxaa = Bool,
                            billboardTextures = BillboardTextures,
                            sunColor = Color, lampIntensity = Float64, lampRange = Float64, lampColor = Color, lampGlow = Float64,
                            extraLamps = Int32, groundFog = Float64, groundFogColor = Color, charShadow = CharShadow,
                            heightFog = Option[PostStack.HeightFog], boardLamplight = Float64, boardNightBase = Color,
                            bloomThreshold = Float64, bloomSize = Float64 }

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

    /// 読み込みで 1 回作る物。group = 動かない面と足元の影・boards = 動かない板・textures = 場面に渡す絵・
    /// strips = 隊列の歩きの絵（4 コマを横に並べた物）・contact = 足元の影の形と材質・
    /// town = 組んだ町の面と板（出来ていく演出が部品に分け直す）・materials = 材質の名前 → (材質, 色の掛け目)・sprites = 板の絵。
    pub type alias Res = { map = TownMap, look = Look, group = Scene3d.StaticGroup, boards = List[Scene3d.Billboard3d],
                           textures = List[Texture3d.Texture3d], strips = Map[String, Images.Loaded],
                           contactMesh = Mesh3d.Mesh3d, contactMaterial = Scene3d.Material3d,
                           town = TileMap3d.Town, materials = Map[String, (Scene3d.Material3d, Rgb)], sprites = Map[String, Images.Loaded],
                           denseMaterial = Scene3d.Material3d, lanternTexture = String, haloTexture = String }

    /// 地図と絵を読み、町を組む。skipNpcColumn = 地図の 1・2・3 を置かない列（隊列で歩かせる列）。
    pub def load(m: TownMap, look: Look, skipNpcColumn: Option[Int32], extraStrips: List[String]): Result[String, Res] \ IO =
        let sprites = "sprites/tree_broadleaf.png" :: "sprites/tree_cypress.png" :: "sprites/street_lamp_ornate.png" ::
                      "sprites/traveler_td.png" :: "sprites/merchant_td.png" :: Nil;
        let stripPaths = List.flatten(m#walk#party |> List.map(p -> p#strip) :: ("sprites/traveler_walk4.png" :: "sprites/merchant_walk4.png" :: Nil) :: extraStrips :: Nil) |> List.distinct;
        let tilePaths = TileMap3d.materialTable() |> Map.valuesOf |> List.map(fst) |> List.distinct;
        forM (
            tiles <- Result.traverse(Images.load, tilePaths);
            boards <- Result.traverse(Images.load, sprites);
            strips <- Result.traverse(Images.load, stripPaths);
            shadow <- Images.contactShadow();
            dense <- Images.denseShadow();
            lantern <- Images.lanternGlow("sprites/street_lamp_ornate.png", lanternCenters(), 6.0);
            halo <- Images.halo();
            contactMesh <- unitContactMesh()
        ) yield {
            let byPath = List.append(tiles, boards) |> List.map(l -> (l#path, l)) |> List.toMap;
            let sizes = byPath |> Map.map(l -> (l#width, l#height));
            let town = TileMap3d.build(m, sizes, skipNpcColumn);
            let contactMaterial = Scene3d.texturedMaterial(Texture3d.name(shadow), FilterMode.Linear) |> Scene3d.withAlphaBlend(true);
            let items = List.append(groupItems(byPath, town#quads), contactItems(contactMesh, contactMaterial, town#boards));
            { map = m, look = look, group = Scene3d.staticGroup("town", items),
              boards = town#boards |> List.filterMap(billboardOf(byPath, look, lampBoards(town))),
              textures = shadow :: dense :: lantern :: halo :: List.append(List.map(l -> l#texture, List.append(tiles, boards)), List.map(l -> l#texture, strips)),
              strips = strips |> List.map(l -> (l#path, l)) |> List.toMap,
              contactMesh = contactMesh, contactMaterial = contactMaterial,
              town = town, materials = materialsOf(byPath), sprites = byPath,
              denseMaterial = Scene3d.texturedMaterial(Texture3d.name(dense), FilterMode.Linear) |> Scene3d.withAlphaBlend(true),
              lanternTexture = Texture3d.name(lantern), haloTexture = Texture3d.name(halo) }
        }

    /// 材質の名前 → (置いた物の材質, 色の掛け目)。
    def materialsOf(byPath: Map[String, Images.Loaded]): Map[String, (Scene3d.Material3d, Rgb)] =
        TileMap3d.materialTable() |> Map.toList |> List.filterMap(entry -> {
            let (name, (path, tint)) = entry;
            Map.get(path, byPath) |> Option.map(tex ->
                (name, (Scene3d.texturedMaterial(Texture3d.name(tex#texture), FilterMode.Nearest) |> Scene3d.withDoubleSided(true), tint)))
        }) |> List.toMap

    /// 板 1 枚のビルボード（演出が板の出し方を決める時に使う）。
    pub def boardBillboard(res: Res, b: Board): Option[Scene3d.Billboard3d] = billboardOf(res#sprites, res#look, lampBoards(res#town), b)

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
                      res#look#charShadow == CharShadow.Silhouette) |> lampLit(res#look, lampBoards(res#town), x, y, tint),
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
    def groupItems(byPath: Map[String, Images.Loaded], quads: List[Quad]): List[(String, Scene3d.Instance3d)] =
        let table = TileMap3d.materialTable();
        let grouped = quads |> List.foldLeft((acc, q) -> Map.insertWith((fresh, old) -> List.append(fresh, old), q#material, q :: Nil, acc), Map.empty());
        grouped |> Map.toList |> List.filterMap(entry -> {
            let (name, qs) = entry;
            forM (
                (path, tint) <- Map.get(name, table);
                tex <- Map.get(path, byPath);
                mesh <- Faces.toMesh(tint, qs) |> Result.toOption
            ) yield {
                let material = Scene3d.texturedMaterial(Texture3d.name(tex#texture), FilterMode.Nearest) |> Scene3d.withDoubleSided(true);
                ("terrain:${name}", Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(material) |> Scene3d.withName(name))
            }
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
    def billboardOf(byPath: Map[String, Images.Loaded], look: Look, lamps: List[Board], b: Board): Option[Scene3d.Billboard3d] =
        Map.get(b#sprite, byPath) |> Option.map(l ->
            standing(billboardName(look, l), { position = Vec2.zero(), size = { x = Int32.toFloat64(l#width), y = Int32.toFloat64(l#height) } },
                     Vec3.v3(b#x, b#z, b#y), if (b#flip) 0.0 - b#width else b#width, b#height, tintColor(look, b#tint), b#shadow == TileMap3d.BoardShadow.Grounded)
                |> (bb -> if (b#sprite == "sprites/street_lamp_ornate.png") bb else lampLit(look, lamps, b#x, b#y, b#tint, bb)))

    /// 夜の板の明るさ（boardLamplight が正の時だけ）: 光を当てない板にして、色の掛け目を夜の地の明るさに近くの街灯の色を足した物にする。
    // WhyNot: 光の計算のまま夜の板を照らさない — 板の光の法線はいつもカメラ向きで、キャラの北に立つ街灯の光は板の裏から当たり、真っ黒な影絵になる。
    def lampLit(look: Look, lamps: List[Board], x: Float64, y: Float64, t: Rgb, bb: Scene3d.Billboard3d): Scene3d.Billboard3d =
        if (look#boardLamplight <= 0.0) bb
        else {
            let reach = look#lampRange * 1.2;
            let glow = lamps |> List.foldLeft((acc, lamp) -> {
                let d = Num.sqrt((lamp#x - x) * (lamp#x - x) + (lamp#y - y) * (lamp#y - y));
                let k = Num.clamp(0.0, 1.0, 1.0 - d / reach);
                acc + k * k * look#boardLamplight
            }, 0.0);
            let c = (base: Float64, lamp: Float64, tint: Float64) -> Num.clamp(0.0, 1.0, (base + lamp * glow) * tint);
            Scene3d.unlit(bb) |> Scene3d.withBillboardTint(Color.rgb(c(look#boardNightBase#r, look#lampColor#r, t#r),
                                                                     c(look#boardNightBase#g, look#lampColor#g, t#g),
                                                                     c(look#boardNightBase#b, look#lampColor#b, t#b)))
        }

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
            (standing(billboardName(res#look, l), source, Vec3.v3(x, z, y), w, h, tintColor(res#look, tint), true),
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
        let look = res#look;
        { groups = res#group :: Nil, instances = List.append(nightInstances(res), instances), billboards = List.append(res#boards, billboards),
          directionalLight = Some(sunOf(look)), textures = res#textures, pointLights = lampLights(res),
          environment = { ambient = look#ambient, hemisphere = look#hemisphere, toonSteps = 0,
                          fog = Some({ color = look#fog, near = look#fogNear, far = look#fogFar }), background = Some(look#sky) }
          | Scene3d.scene(camera, size) }

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
                |> Scene3d.withMaterial(glowMaterial(look, res#lanternTexture, look#lampGlow))) ::
            (lanternCenters() |> List.map(uv ->
                Scene3d.meshInstance(res#contactMesh, upright(b#x + (fst(uv) - 0.5) * lw, b#y - 0.06, b#z + snd(uv) * lh, 1.1, 1.1))
                    |> Scene3d.withMaterial(glowMaterial(look, res#haloTexture, look#lampGlow * 0.04)))));
        let fogs = if (look#groundFog <= 0.0) Nil else (0.35 :: 0.8 :: Nil) |> List.mapWithIndex((i, h) ->
            Scene3d.meshInstance(res#contactMesh, Mat4.mul(Mat4.translate(Vec3.v3(13.5, 1.0 + h, 13.0)), Mat4.scale(Vec3.v3(60.0, 1.0, 60.0))))
                |> Scene3d.withMaterial(fogMaterial(look, i)));
        List.append(glows, fogs)

    /// 光る板の材質（絵 texture の α の所だけ、街灯の色で光る・半透明で重ねる・ブルームが拾う明るさ）。k = 光の強さ。
    def glowMaterial(look: Look, texture: String, k: Float64): Scene3d.Material3d =
        let c = (v: Float64) -> ShaderDoc.Field.Const(v);
        let alpha = ShaderDoc.Field.Sampler({ filter = ShaderDoc.FilterMode.Nearest, of = ShaderDoc.Field.Tex({ name = texture, chan = ShaderDoc.TexChan.A }) });
        let tinted = (v: Float64) -> ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, a = c(v), b = alpha });
        let rgb = ShaderDoc.Shade.Rgb({ r = tinted(look#lampColor#r), g = tinted(look#lampColor#g), b = tinted(look#lampColor#b) });
        Scene3d.material({ name = "hd2d:lamp-glow", cycleRate = 0.0, bindings = Nil, out = ShaderDoc.Out.Fill({ shade = rgb, alpha = alpha }) })
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

    /// 後がけ（AgX・露出・ブルーム・ピントの奥行きでぼかす・彩度・周りを暗く）。focus = ピントの合う奥行き（m）。
    pub def postOf(look: Look, focus: Float64): PostStack.Stack = postAt(look, focus, 0.0)

    /// postOf に時刻 t（秒・霧のむらを流す）を渡す形。
    pub def postAt(look: Look, focus: Float64, t: Float64): PostStack.Stack =
        PostStack.preset(PostStack.Preset.Neutral)
            |> PostStack.withHeightFog(look#heightFog)
            |> PostStack.withTime(ShotClock.at(t))
            |> PostStack.withViewTransform(PostStack.ViewTransform.AgX)
            |> PostStack.withExposure(look#exposure)
            |> PostStack.withBloom(Some({ threshold = look#bloomThreshold, smoothness = 0.5, size = look#bloomSize, strength = look#bloomStrength }))
            |> PostStack.withDepthOfField(if (look#fStop > 0.0) Some(PostStack.DepthOfField.Physical({ focusDistance = focus, fStop = look#fStop })) else None)
            |> PostStack.withColorGrade(Some({ lift = look#lift, gamma = look#gamma, gain = look#gain, saturation = look#saturation }))
            |> PostStack.withVignette(Some({ strength = look#vignette, inner = 0.45, outer = 1.1, center = { x = 0.5, y = 0.5 } }))
            |> PostStack.withFxaa(look#fxaa)

    /// 描き物の列（画面いっぱいに場面を 1 つ）。
    pub def items(scene: Scene3d.Scene3dCmd): List[Render.PlacedItem] = Render.scene3d(Vec2.zero(), scene) :: Nil
}
