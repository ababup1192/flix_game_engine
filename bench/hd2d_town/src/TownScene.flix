// TownScene — 組んだ町（TileMap3d）と絵（Images）から、毎コマ渡す 3D の場面を作る。
// 動かない面と足元の影は読み込みで 1 回 staticGroup にまとめ、毎コマは隊列の板とカメラだけを差し替える。
mod TownScene {
    use fge::{Camera3d, Color, Mat4, Mesh3d, Num, PostStack, Rect2, Render, Scene3d, Texture3d, Transform3d, Vec2, Vec3}
    use fge::ShaderDoc.FilterMode
    use Faces.{Quad, Rgb}
    use TileMap3d.{Board}
    use TownMap.{TownMap}

    /// 見た目のつまみ（Doc assets/town.json）。
    /// topDeg・bottomDeg = 画面の上の端・下の端で地面を見下ろす角度・far = カメラの奥の端（m）・shadowDistance = 太陽の影を描く奥行き（m）・
    /// sunElevation・sunAzimuth = 太陽の高さと方位（度。方位は南 = 手前から東へ）・sunIntensity = 太陽の強さ・
    /// ambient = どこにでも当たる光（画面の値）・hemisphere = 上を向く面ほど明るくする量・
    /// boardTint = 板（木・街灯・キャラ）の明るさの掛け目・snapToTexels = 板とカメラの位置を 1 テクセルに丸めるか・
    /// fogNear・fogFar・fog = かすみ（目からの距離と色）・exposure・bloom・fStop・saturation・gain（色の掛け目）・vignette = 後がけ。
    pub type alias Look = { topDeg = Float64, bottomDeg = Float64, far = Float64, shadowDistance = Float64, shadowMapSize = Int32,
                            sunElevation = Float64, sunAzimuth = Float64, sunIntensity = Float64,
                            ambient = Color, hemisphere = Float64, boardTint = Float64, snapToTexels = Bool,
                            fogNear = Float64, fogFar = Float64, fog = Color, sky = Color,
                            exposure = Float64, bloomStrength = Float64, fStop = Float64, saturation = Float64, gain = Color, vignette = Float64 }

    /// 読み込みで 1 回作る物。group = 動かない面と足元の影・boards = 動かない板・textures = 場面に渡す絵・
    /// strips = 隊列の歩きの絵（4 コマを横に並べた物）・contact = 足元の影の形と材質。
    pub type alias Res = { map = TownMap, look = Look, group = Scene3d.StaticGroup, boards = List[Scene3d.Billboard3d],
                           textures = List[Texture3d.Texture3d], strips = Map[String, Images.Loaded],
                           contactMesh = Mesh3d.Mesh3d, contactMaterial = Scene3d.Material3d }

    /// 地図と絵を読み、町を組む。skipNpcColumn = 地図の 1・2・3 を置かない列（隊列で歩かせる列）。
    pub def load(m: TownMap, look: Look, skipNpcColumn: Option[Int32]): Result[String, Res] \ IO =
        let sprites = "sprites/tree_broadleaf.png" :: "sprites/tree_cypress.png" :: "sprites/street_lamp.png" ::
                      "sprites/traveler_td.png" :: "sprites/merchant_td.png" :: Nil;
        let stripPaths = m#walk#party |> List.map(p -> p#strip) |> List.distinct;
        let tilePaths = TileMap3d.materialTable() |> Map.valuesOf |> List.map(fst) |> List.distinct;
        forM (
            tiles <- Result.traverse(Images.load, tilePaths);
            boards <- Result.traverse(Images.load, sprites);
            strips <- Result.traverse(Images.load, stripPaths);
            shadow <- Images.contactShadow();
            contactMesh <- unitContactMesh()
        ) yield {
            let byPath = List.append(tiles, boards) |> List.map(l -> (l#path, l)) |> List.toMap;
            let sizes = byPath |> Map.map(l -> (l#width, l#height));
            let town = TileMap3d.build(m, sizes, skipNpcColumn);
            let contactMaterial = Scene3d.texturedMaterial(Texture3d.name(shadow), FilterMode.Linear) |> Scene3d.withAlphaBlend(true);
            let items = List.append(groupItems(byPath, town#quads), contactItems(contactMesh, contactMaterial, town#boards));
            { map = m, look = look, group = Scene3d.staticGroup("town", items),
              boards = town#boards |> List.filterMap(billboardOf(byPath, look)),
              textures = shadow :: List.append(List.map(l -> l#texture, List.append(tiles, boards)), List.map(l -> l#texture, strips)),
              strips = strips |> List.map(l -> (l#path, l)) |> List.toMap,
              contactMesh = contactMesh, contactMaterial = contactMaterial }
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

    /// 板 1 枚。カメラが水平なので、カメラへ向く板は地面に垂直に立つ（高さを伸ばす補正は要らない）。
    def billboardOf(byPath: Map[String, Images.Loaded], look: Look, b: Board): Option[Scene3d.Billboard3d] =
        Map.get(b#sprite, byPath) |> Option.map(l ->
            standing(Texture3d.name(l#texture), { position = Vec2.zero(), size = { x = Int32.toFloat64(l#width), y = Int32.toFloat64(l#height) } },
                     Vec3.v3(b#x, b#z, b#y), if (b#flip) 0.0 - b#width else b#width, b#height, tintColor(look, b#tint), b#shadow == TileMap3d.BoardShadow.Grounded))

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
            (standing(Texture3d.name(l#texture), source, Vec3.v3(x, z, y), w, h, tintColor(res#look, tint), true),
             contactInstance(res#contactMesh, res#contactMaterial, x, y, z, w))
        })

    /// 太陽（光の進む向き）。方位は南（手前）から東へ・高さは地平から。
    pub def sunOf(look: Look): Scene3d.DirectionalLight =
        let el = look#sunElevation * Num.pi() / 180.0;
        let az = look#sunAzimuth * Num.pi() / 180.0;
        let toward = Vec3.v3(Num.cos(el) * Num.sin(az), Num.sin(el), 0.0 - Num.cos(el) * Num.cos(az));
        { intensity = look#sunIntensity, color = Color.rgb(1.0, 0.95, 0.86),
          shadow = Some({ distance = look#shadowDistance, mapSize = look#shadowMapSize, bias = 0.03, normalBias = 1.0 | Scene3d.directionalShadow() })
          | Scene3d.directionalLight(Vec3.mul(toward, -1.0)) }

    /// 1 コマの場面。billboards・instances = 毎コマ変わる板と置いた物（隊列）。
    pub def sceneOf(res: Res, camera: Camera3d.Camera3d, size: Vec2.Vec2, billboards: List[Scene3d.Billboard3d], instances: List[Scene3d.Instance3d]): Scene3d.Scene3dCmd =
        let look = res#look;
        { groups = res#group :: Nil, instances = instances, billboards = List.append(res#boards, billboards),
          directionalLight = Some(sunOf(look)), textures = res#textures,
          environment = { ambient = look#ambient, hemisphere = look#hemisphere, toonSteps = 0,
                          fog = Some({ color = look#fog, near = look#fogNear, far = look#fogFar }), background = Some(look#sky) }
          | Scene3d.scene(camera, size) }

    /// 後がけ（AgX・露出・ブルーム・ピントの奥行きでぼかす・彩度・周りを暗く）。focus = ピントの合う奥行き（m）。
    pub def postOf(look: Look, focus: Float64): PostStack.Stack =
        PostStack.preset(PostStack.Preset.Neutral)
            |> PostStack.withViewTransform(PostStack.ViewTransform.AgX)
            |> PostStack.withExposure(look#exposure)
            |> PostStack.withBloom(Some({ threshold = 0.8, smoothness = 0.5, size = 0.6, strength = look#bloomStrength }))
            |> PostStack.withDepthOfField(if (look#fStop > 0.0) Some(PostStack.DepthOfField.Physical({ focusDistance = focus, fStop = look#fStop })) else None)
            |> PostStack.withColorGrade(Some({ lift = Color.rgb(0.0, 0.0, 0.0), gamma = Color.rgb(1.0, 1.0, 1.0), gain = look#gain, saturation = look#saturation }))
            |> PostStack.withVignette(Some({ strength = look#vignette, inner = 0.45, outer = 1.1, center = { x = 0.5, y = 0.5 } }))

    /// 描き物の列（画面いっぱいに場面を 1 つ）。
    pub def items(scene: Scene3d.Scene3dCmd): List[Render.PlacedItem] = Render.scene3d(Vec2.zero(), scene) :: Nil
}
