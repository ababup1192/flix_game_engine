// TownScene — 組んだ町（TileMap3d）と読み込んだ絵（Images）から、毎コマ渡す 3D の場面を作る。
// 動かない面と足元の影は 1 回 staticGroup にまとめ、動かない板も 1 回作る。毎コマ差し替えるのは隊列と小物の板とカメラだけ。
mod TownScene {
    use fge::{Camera3d, Color, Mat4, Mesh3d, Num, PostStack, Rect2, Scene3d, Texture3d, Transform3d, Vec2, Vec3}
    use fge::ShaderDoc.FilterMode
    use Faces.{Quad, Rgb}
    use TileMap3d.{Board}
    use TownDecor.{Decor}
    use TownMap.{TownMap}

    /// 板の絵の引き方。SceneTextures = 場面の textures の Texture3d の名前（窓を開かない CPU の描き出し）・
    /// ProjectTextures = project.json の textures の名前（実機とブラウザの GPU の描き手）。
    pub enum TextureNames with Eq {
        case SceneTextures
        case ProjectTextures
    }

    /// 読み込んだ絵の表（assets からの相対のパス → 絵）。
    pub type alias Pictures = Map[String, Images.Loaded]

    /// 板と足元の影を作るのに要る物。pictures = 読み込んだ絵・names = 板の絵の引き方・boardTint = 板の明るさの掛け目（Look の boardTint）・
    /// contactMesh・contactMaterial = 足元の楕円の影の形と材質・charShadowScale = キャラの影の板の倍率。
    pub type alias Boards = { pictures = Pictures, names = TextureNames, boardTint = Float64, contactMesh = Mesh3d.Mesh3d,
                              contactMaterial = Scene3d.Material3d, charShadowScale = Vec2.Vec2 }

    /// 組んだ町。group = 動かない面と足元の影・boards = 動かない板（木・街灯・町の人・地図の外の森）・textures = 場面に渡す絵。
    pub type alias Built = { group = Scene3d.StaticGroup, boards = List[Scene3d.Billboard3d], textures = List[Texture3d.Texture3d] }

    /// 地図のタイルと板・小物 decor・隊列のストリップ strips を描くのに読む絵のパス（重ならない）。
    pub def picturePaths(decor: List[Decor], strips: List[String]): List[String] =
        let tiles = TileMap3d.materialTable() |> Map.valuesOf |> List.map(fst);
        List.flatten(tiles :: TileMap3d.boardSprites() :: List.map(d -> d#sprite, decor) :: strips :: Nil) |> List.distinct

    /// 板を作る道具をそろえる。
    pub def boardsOf(pictures: Pictures, names: TextureNames, look: TownLook.Look, contact: Texture3d.Texture3d,
                     contactMesh: Mesh3d.Mesh3d): Boards =
        let l = TownLook.rec(look);
        { pictures = pictures, names = names, boardTint = l#boardTint, contactMesh = contactMesh,
          contactMaterial = Scene3d.texturedMaterial(Texture3d.name(contact), FilterMode.Linear) |> Scene3d.withAlphaBlend(true),
          charShadowScale = l#charShadowScale }

    /// 町を組む（絵は読み直さない。地図に書いた絵が pictures に無ければ、その面と板は出ない）。
    pub def build(b: Boards, contact: Texture3d.Texture3d, m: TownMap): Built =
        let sizes = b#pictures |> Map.map(l -> (l#width, l#height));
        let town = TileMap3d.build(m, sizes);
        let materials = materialsOf(TileMap3d.materialTable(), b#pictures);
        let items = List.append(groupItems(materials, town#quads), contactItems(b, town#boards));
        { group = Scene3d.staticGroup("town", items),
          boards = town#boards |> List.filterMap(staticBoard(b)),
          textures = contact :: (b#pictures |> Map.valuesOf |> List.map(l -> l#texture)) }

    /// 材質の名前 → (置いた物の材質, 色の掛け目)。
    def materialsOf(table: Map[String, (String, Rgb)], pictures: Pictures): Map[String, (Scene3d.Material3d, Rgb)] =
        table |> Map.toList |> List.filterMap(entry -> {
            let (name, (path, tint)) = entry;
            Map.get(path, pictures) |> Option.map(tex ->
                (name, (Scene3d.texturedMaterial(Texture3d.name(tex#texture), FilterMode.Nearest) |> Scene3d.withDoubleSided(true), tint)))
        }) |> List.toMap

    /// 材質ごとに 1 つの形（色の掛け目は頂点の色に焼き込み、絵ごとの材質は 1 つ）。
    // WhyNot: 裏の面を捨てる材質にしない — 妻壁や軒の裏の面の巡りが面ごとに揃っていない。
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
    pub def unitContactMesh(): Result[String, Mesh3d.Mesh3d] =
        Faces.toMesh(Faces.white(), Faces.quad("contact",
            Faces.p3(-0.5, -0.5, 0.0) :: Faces.p3(0.5, -0.5, 0.0) :: Faces.p3(0.5, 0.5, 0.0) :: Faces.p3(-0.5, 0.5, 0.0) :: Nil, Faces.fullUv(), Nil) :: Nil)

    /// 板の足元の楕円の影 1 つ（幅 min(w × 0.8, 1.6)・奥行き min(0.5, w × 0.4)）。k = 大きさの倍率。
    def contactInstance(b: Boards, x: Float64, y: Float64, z: Float64, boardWidth: Float64, k: Float64): Scene3d.Instance3d =
        let w = Float64.abs(boardWidth);
        let place = { scale = Vec3.v3(Float64.min(w * 0.8, 1.6) * k, 1.0, Float64.min(0.5, w * 0.4) * k) | Transform3d.of(Vec3.v3(x, z + 0.015, y)) };
        Scene3d.meshInstance(b#contactMesh, Transform3d.toMat4(place)) |> Scene3d.withMaterial(b#contactMaterial)

    def contactItems(b: Boards, boards: List[Board]): List[(String, Scene3d.Instance3d)] =
        boards |> List.filter(bd -> bd#shadow == TileMap3d.BoardShadow.Grounded) |> List.mapWithIndex((i, bd) ->
            ("contact:${Int32.toString(i)}", contactInstance(b, bd#x, bd#y, bd#z, bd#width, 1.0)))

    /// 線形の掛け目 t に明るさ k を掛けて、場面の色（画面の値）にする。
    def tintColor(k: Float64, t: Rgb): Color =
        Color.rgb(Faces.linearToSrgb(t#r * k), Faces.linearToSrgb(t#g * k), Faces.linearToSrgb(t#b * k))

    def boardTint(b: Boards, t: Rgb): Color = tintColor(b#boardTint, t)

    /// 板の絵の名前（project.json の textures の名前は、assets/sprites/<名前>.png の <名前>）。
    // WhyNot: GPU でも場面の textures の名前で引かない — GPU の描き手のビルボードは project.json の textures だけを引き、Texture3d の名前は見つからないとして描かない。
    pub def textureNameOf(names: TextureNames, l: Images.Loaded): String =
        if (names == TextureNames.ProjectTextures) projectTextureName(l#path) else Texture3d.name(l#texture)

    /// assets からの相対のパス → project.json の textures の名前。
    pub def projectTextureName(path: String): String =
        let stem = String.stripPrefix(substr = "sprites/", path) |> Option.getWithDefault(path);
        String.stripSuffix(substr = ".png", stem) |> Option.getWithDefault(stem)

    /// 動かない板 1 枚。カメラが水平なので、カメラへ向く板は地面に垂直に立つ（高さを伸ばす補正は要らない）。
    def staticBoard(b: Boards, bd: Board): Option[Scene3d.Billboard3d] =
        Map.get(bd#sprite, b#pictures) |> Option.map(l ->
            standing(textureNameOf(b#names, l), { position = Vec2.zero(), size = { x = Int32.toFloat64(l#width), y = Int32.toFloat64(l#height) } },
                     Vec3.v3(bd#x, bd#z, bd#y), if (bd#flip) 0.0 - bd#width else bd#width, bd#height, boardTint(b, bd#tint),
                     bd#shadow == TileMap3d.BoardShadow.Grounded))

    def standing(texture: String, source: Rect2.Rect2, at: Vec3.Vec3, width: Float64, height: Float64, tint: Color, cast: Bool): Scene3d.Billboard3d =
        Scene3d.billboard(texture, source, at, { x = width, y = height })
            |> Scene3d.withBillboardTint(tint)
            |> Scene3d.withCastShadows(cast)
            |> Scene3d.withReceiveShadows(true)

    /// 隊列の 1 人の板と足元の影。cell = 帯の中の 1 コマ（Walkers.cellOf）・flip = 左右反転。
    /// 影は板の絵の形の太陽の影（withShadowCasterScale で倍率）と、足元の薄い小さな楕円。
    pub def walkerBoard(b: Boards, strip: String, cell: Walkers.Cell, flip: Bool,
                        x: Float64, y: Float64, z: Float64): Option[(Scene3d.Billboard3d, Scene3d.Instance3d)] =
        Map.get(strip, b#pictures) |> Option.map(l -> {
            let source = Walkers.sourceOf(l, cell);
            let w = source#size#x / Images.texelsPerMeter();
            let h = source#size#y / Images.texelsPerMeter();
            (standing(textureNameOf(b#names, l), source, Vec3.v3(x, z, y), if (flip) 0.0 - w else w, h, boardTint(b, Faces.white()), true)
                |> Scene3d.withShadowCasterScale(b#charShadowScale),
             contactInstance(b, x, y, z, w, 0.6))
        })

    /// 小物の板と足元の影（時刻 t のコマと揺れ）。
    pub def decorBoards(b: Boards, m: TownMap, decor: List[Decor], t: Float64): List[(Scene3d.Billboard3d, Option[Scene3d.Instance3d])] =
        decor |> List.filterMap(d -> Map.get(d#sprite, b#pictures) |> Option.map(l -> decorBoard(b, m, d, l, t)))

    def decorBoard(b: Boards, m: TownMap, d: Decor, l: Images.Loaded, t: Float64): (Scene3d.Billboard3d, Option[Scene3d.Instance3d]) =
        let nf = Int32.max(1, d#frames);
        let cellW = l#width / nf;
        let k = decorFrame(d, nf, t);
        let source = { position = { x = Int32.toFloat64(cellW * k), y = 0.0 }, size = { x = Int32.toFloat64(cellW), y = Int32.toFloat64(l#height) } };
        let w = Int32.toFloat64(cellW) / Images.texelsPerMeter();
        let h = d#height |> Option.getWithDefault(Int32.toFloat64(l#height) / Images.texelsPerMeter());
        let (swayX, swayZ) = d#sway |> Option.map(sw -> {
            let (amp, per) = sw;
            (amp * Num.sin(2.0 * Num.pi() * t / per + d#phase * 6.28), 0.5 * amp * Num.sin(4.0 * Num.pi() * t / per + d#phase * 6.28))
        }) |> Option.getWithDefault((0.0, 0.0));
        let (cx, cy) = TownMap.centerOf(m, d#col, d#row);
        let x = cx + d#offX + swayX;
        let y = cy + d#offY;
        let ground = TownMap.topAt(m, d#col, d#row);
        let board = standing(textureNameOf(b#names, l), source, Vec3.v3(x, ground + d#z + swayZ, y), if (d#flip) 0.0 - w else w, h,
                             boardTint(b, Faces.white()), TownDecor.castsShadow(d#shadow));
        (board, if (TownDecor.hasFootShadow(d#shadow) and d#sway == None) Some(contactInstance(b, x, y, ground, w, 1.0)) else None)

    /// 板のコマ（seq があれば seq の並び・無ければ 0, 1, 2, …）。
    def decorFrame(d: Decor, nf: Int32, t: Float64): Int32 =
        let step = (count: Int32) -> Int32.modulo(Float64.floor(t / d#frameSec + d#phase * Int32.toFloat64(count)) |> Float64.tryToInt32 |> Option.getWithDefault(0), Int32.max(1, count));
        if (nf <= 1) 0
        else if (List.isEmpty(d#seq)) step(nf)
        else List.drop(step(List.length(d#seq)), d#seq) |> List.head |> Option.getWithDefault(0) |> Num.clampInt(0, nf - 1)

    /// 太陽（光の進む向き）。方位は南（手前）から東へ・高さは地平から。shadowMapSize = 影の地図の一辺（0 で影なし）。
    pub def sunOf(look: TownLook.Look, shadowMapSize: Int32): Scene3d.DirectionalLight =
        let l = TownLook.rec(look);
        let el = l#sunElevation * Num.pi() / 180.0;
        let az = l#sunAzimuth * Num.pi() / 180.0;
        let toward = Vec3.v3(Num.cos(el) * Num.sin(az), Num.sin(el), 0.0 - Num.cos(el) * Num.cos(az));
        { intensity = l#sunIntensity, color = l#sunColor,
          shadow = if (shadowMapSize <= 0) None
                   else Some({ distance = l#shadowDistance, mapSize = shadowMapSize, strength = l#shadowStrength, pcfRadius = l#shadowPcf,
                               bias = 0.03, normalBias = 1.0 | Scene3d.directionalShadow() })
          | Scene3d.directionalLight(Vec3.mul(toward, -1.0)) }

    /// 1 コマの場面。billboards・instances = 毎コマ変わる板と置いた物（隊列と小物）。
    pub def sceneOf(built: Built, look: TownLook.Look, shadowMapSize: Int32, camera: Camera3d.Camera3d, size: Vec2.Vec2,
                    billboards: List[Scene3d.Billboard3d], instances: List[Scene3d.Instance3d]): Scene3d.Scene3dCmd =
        let l = TownLook.rec(look);
        { groups = built#group :: Nil, instances = instances, billboards = List.append(built#boards, billboards),
          directionalLight = Some(sunOf(look, shadowMapSize)), textures = built#textures,
          environment = { ambient = l#ambient, hemisphere = l#hemisphere, toonSteps = 0,
                          fog = Some({ color = l#fog, near = l#fogNear, far = l#fogFar }), background = Some(l#sky) }
          | Scene3d.scene(camera, size) }
            |> Scene3d.withLightUnits(l#lightUnits)

    /// ポストプロセス（曲線・露出・ピントの奥行きでぼかす・色の掛け目・周りを暗く・縁のならし）。focus = ピントの合う奥行き（m）・
    /// depthOfField = ぼかすか（描き方の重さのつまみ）。
    pub def postOf(look: TownLook.Look, focus: Float64, depthOfField: Bool): PostStack.Stack =
        let l = TownLook.rec(look);
        PostStack.preset(PostStack.Preset.Neutral)
            |> PostStack.withViewTransform(l#view)
            |> PostStack.withExposure(l#exposure)
            |> PostStack.withDepthOfField(if (depthOfField and l#fStop > 0.0) Some(PostStack.DepthOfField.Physical({ focusDistance = focus, fStop = l#fStop })) else None)
            |> PostStack.withColorGrade(Some({ lift = l#lift, gamma = l#gamma, gain = l#gain, saturation = l#saturation }))
            |> PostStack.withVignette(Some({ strength = l#vignette, inner = 0.45, outer = 1.1, center = { x = 0.5, y = 0.5 } }))
            |> PostStack.withFxaa(l#fxaa)
}
