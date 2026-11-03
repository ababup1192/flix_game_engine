// 突き合わせに使う場面（scene）の宣言。GL と SoftRaster の両方が同じこの列を描き出す。
//
// A 段階（バイト一致を主張する層）の scene 規約:
//   1. 整数座標・整数寸法・整数倍率のみ（小数の丸めの差を測るのは B 段階の仕事）。
//      倍率 = texel→画素の拡大率が整数、の意味（sprite の scale 値そのものではない —
//      blitRegion の scale が 0.5 でも、貼り先/切り出し元の比が整数なら規約内）
//   2. 色は k/255 で表せる値のみ・alpha は 1.0（8bit に落ちない中間値は正規化で ±1 が出うる）
//   3. 縞は軸平行（dir=1/2）と市松だけ。45° 縞・角丸・枠は GL だけ AA が掛かるので入れない
//   4. 時刻は固定値（アニメ無し — 2 回描き出して同じ絵になることが決定性検証の前提）
mod Scenes {

    use fge::{Camera3d, Color, DrawCmd, Gltf, Light, Mat4, Mesh3d, Model3d, Pose3d, PostProcess, PxSprite, PxSpriteDoc, RawDraw, Render, RenderTarget, RenderUtil, Scene3d, ShaderDoc, Shadow, Skin3d, Texture3d, Num, Vec2, Vec3}

    // 寸法の権威は整数側 — Float 側を権威にすると Int へ戻す丸めが要る。
    pub def designWi(): Int32 = 320
    pub def designHi(): Int32 = 180

    pub def designW(): Float64 = Int32.toFloat64(designWi())
    pub def designH(): Float64 = Int32.toFloat64(designHi())

    /// pass 名の一覧。pass は常に design 寸なので、寸法引きはこの名前だけで足りる。
    pub def passNames(): List[String] =
        all() |> List.flatMap(sc -> sc#passes) |> List.map(p -> p#name)

    /// 画面口（FLIX_GE_FRAME_SHOT）で撮るか、ターゲット口（GlReadback 直呼び）で撮るか。
    pub enum ShotVia with Eq {
        case ViaTarget
        case ViaScreen
    }

    pub type alias Scene = {
        name = String,
        via = ShotVia,
        passes = List[Render.Pass],
        // GL で Pass の列を何コマ描いてから撮るか（2 以上 = 前のコマの中身が見えていないことを確かめる場面）。
        repeats = Int32,
        // Pass の名前 → ターゲットの作り方（倍率）。
        targets = Map[String, RenderTarget.Descriptor],
        // A 段階（バイト一致を主張する）か。false は B 段階（差の数だけ報告し、落とさない）。
        exact = Bool,
        items = List[Render.PlacedItem]
    }

    pub def all(): List[Scene] =
        boxes() :: spriteNearest() :: passPaste() :: texField() :: lightMap() :: radial() :: veil()
            :: passChain() :: passLaterRead() :: passMask() :: passHalf() :: passQuarterOdd() :: linearRead()
            :: castShadow() :: paramRead() :: depthRed() :: afterScene3d() :: materialStripes() :: spotShadow() :: skinBend()
            :: texturedBox() :: normalBump() :: skinNormal()
            :: mipFloor() :: mipFloorScaled() :: mipFloorWorld() :: gltfTextured() :: windowPass3d()
            :: hdrPass() :: hdrWindowHalf() :: hdrMultiply() :: texSizeScaled() :: tonemap() :: fxaa()
            :: lightmapBaked3d() :: lightmapNormal3d() :: spotSoftEdge3d() :: gltfEmissive3d() :: cullOffscreen3d()
            :: skyGradient3d() :: glassPane3d() :: doubleSided3d() :: msaaEdges()
            :: linearOverlap3d() :: mipSrgbAverage3d() :: emissionIntensity3d() :: Nil

    /// B 段階の scene のうち、違う画素の数に上限を置く物（名前 → 許す画素数）。3D の場面は GL と CPU で三角形の縁の
    /// 画素の取り方と浮動小数の丸めが違い、バイトでは一致しない（docs/backend-parity.md の Shader 面と同じ扱い）。
    /// 上限は縁の画素の数から決める（この 2 つは軸にそろった縁で、Apple Silicon では 0 px だった）— 前後や状態の漏れが
    /// 崩れると、面の中が丸ごと違って桁が変わる。mip の 3 つは、段の境目の帯で GPU が lod の小数と混ぜる重みを丸める ±1 が
    /// 数百 px 出る（段を 1 つ取り違えると ±40 の差が千 px を超える）。
    /// HDR の Pass を補間で読む 2 つ（hdrWindowHalf・tonemap）は、half と float32 / float64 の丸めが 8bit の境目に落ちた平らな面が
    /// まとめて ±1 になり千 px の桁が出る（式を取り違えると ±10 を超える差が面ごとに出る）。fxaa は斜めの縁の画素だけが割れる
    /// （FXAA が効かないと縁の全部が割れて数百 px を超える）。texSizeScaled は寸法を取り違えると縁が 1 画素ずれて百 px を超える。
    /// lightmap の 2 つは、GPU の補間の重みの丸めの ±1 が段差の縁に出る（lightmapBaked3d は約 400 px で、全部が市松の升の境・
    /// 材質の絵の texel の境・板のふちの 1 px 以内。lightmapNormal3d は約 260 px で、ほぼ同じ）。環境光か hemisphere を足す・
    /// 色空間や intensity を取り違えると、板（約 4,700 px と 7,700 px）の中が丸ごと違い、差も ±1 を超える。
    /// spotSoftEdge3d は床の輪の縁のなめらかな坂で丸めの ±1 が約 20 px 出る。内側の角を取り違えると左の輪の縁の帯（数千 px）が丸ごと違う。
    /// 段 4 の 4 つ（Apple Silicon で skyGradient3d 0 px・glassPane3d 0 px・doubleSided3d 4 px・msaaEdges 652 px）: 空は向きの丸めの ±1 が
    /// 坂に散る。半透明と両面は縁の 1 px 以内。msaaEdges は GL だけが縁を標本で混ぜるので、差は棒と縞の縁の画素の数（minDiffOf も見る）。
    /// 線形の色の 3 つ（Apple Silicon で linearOverlap3d 23 px・mipSrgbAverage3d 1,591 px・emissionIntensity3d 0 px）: 光の重なりは暗い坂の丸めの ±1 が
    /// 散る。白黒の市松の床は段の境目の帯で GPU の混ぜる重みの丸めが ±3 まで出る（灰の市松の mipFloor より濃淡が倍なので差も倍）。
    /// 片方だけ線形へ戻し忘れると、板・ビルボード・遠くの床・光る板の面が丸ごと違い、差は面の画素の数（千 px の桁）になる。
    /// 3D の色を線形の量で計算すると、mipFloor の 3 つは約 720 px・skinNormal は約 330 px（暗い所の丸めの ±1 が sRGB の曲線の傾きで増える）。
    pub def toleranceOf(name: String): Option[Int32] = match name {
        case "depthRed"        => Some(300)
        case "afterScene3d"    => Some(200)
        case "materialStripes" => Some(300)
        case "spotShadow"      => Some(300)
        case "skinBend"        => Some(400)
        case "texturedBox"     => Some(400)
        case "normalBump"      => Some(400)
        case "skinNormal"      => Some(450)
        case "mipFloor"        => Some(950)
        case "mipFloorScaled"  => Some(950)
        case "mipFloorWorld"   => Some(950)
        case "gltfTextured"    => Some(400)
        case "windowPass3d"    => Some(300)
        case "hdrWindowHalf"   => Some(3500)
        case "texSizeScaled"   => Some(100)
        case "tonemap"         => Some(7000)
        case "fxaa"            => Some(300)
        case "lightmapBaked3d" => Some(600)
        case "lightmapNormal3d" => Some(400)
        case "spotSoftEdge3d"  => Some(100)
        case "gltfEmissive3d"  => Some(200)
        case "cullOffscreen3d" => Some(100)
        case "skyGradient3d"   => Some(300)
        case "glassPane3d"     => Some(200)
        case "doubleSided3d"   => Some(100)
        case "msaaEdges"       => Some(1200)
        case "linearOverlap3d" => Some(100)
        case "mipSrgbAverage3d" => Some(2100)
        case "emissionIntensity3d" => Some(100)
        case _                 => None
    }

    /// 差が少なくともこの数の画素に出るはずの scene（名前 → 画素数）。GL の側だけが持つ物（MSAA）が効いているかを、CPU との差で見る。
    /// msaaEdges は GL だけが縁を標本で混ぜるので、縁の画素が CPU（MSAA なし・既存の 3D の行と同じ絵）と違う。差が 0 なら MSAA が効いていない。
    pub def minDiffOf(name: String): Option[Int32] = match name {
        case "msaaEdges" => Some(300)
        case _           => None
    }

    /// GL の描き手が描いた置いた物の数（FrameDiagnostics の scene3dCounts#drawn）の期待値を持つ scene（名前 → 数）。
    /// 視錐台の外の物を間引けていなければ数が増え、中の物まで間引くと減る（絵の差では間引きの効き目が見えない）。
    pub def expectedDrawnOf(name: String): Option[Int32] = match name {
        case "cullOffscreen3d" => Some(2)
        case _                 => None
    }

    /// 8bit の値そのままの色（k/255）。A 段階の規約 2 をこの入口で守る。
    def c8(r: Int32, g: Int32, b: Int32): Color =
        { r = f255(r), g = f255(g), b = f255(b) }

    def f255(k: Int32): Float64 =
        Int32.toFloat64(k) / 255.0

    def at(x: Float64, y: Float64, item: Render.Item): Render.PlacedItem =
        { at = { x = x, y = y }, item = item }

    // ── scene 1: 単色 box の重なり（塗り・並び順・ブレンド式・軸平行縞・市松）──

    def boxes(): Scene =
        { name = "boxes", via = ShotVia.ViaTarget, repeats = 1, targets = Map.empty(), exact = true, passes = Nil, items =
            // 左上の白枠なし赤箱 = 向きの目印（gl/soft で同じ隅に出なければ上下反転を疑う）
            at(8.0, 8.0, RawDraw.box({ x = 16.0, y = 16.0 }, c8(255, 64, 64), 10)) ::
            // zIndex 交差: 青(z1) の上に 緑(z2)
            at(40.0, 30.0, RawDraw.box({ x = 80.0, y = 60.0 }, c8(40, 80, 200), 1)) ::
            at(80.0, 60.0, RawDraw.box({ x = 80.0, y = 60.0 }, c8(40, 180, 90), 2)) ::
            // Add: 暗色ベース + 加算（飽和しない値で式そのものを見る）
            at(180.0, 20.0, RawDraw.box({ x = 60.0, y = 40.0 }, c8(60, 60, 60), 1)) ::
            at(200.0, 30.0, RawDraw.box({ x = 60.0, y = 40.0 }, c8(120, 80, 40), 2)
                |> Render.blended(DrawCmd.BlendMode.Add)) ::
            // Multiply: 白ベース × 灰（積が 8bit で割り切れる組）
            at(180.0, 90.0, RawDraw.box({ x = 60.0, y = 40.0 }, c8(255, 255, 255), 1)) ::
            at(200.0, 100.0, RawDraw.box({ x = 60.0, y = 40.0 }, c8(100, 100, 100), 2)
                |> Render.blended(DrawCmd.BlendMode.Multiply)) ::
            // 軸平行の縞（横 dir=1・縦 dir=2）と市松
            at(20.0, 130.0, RawDraw.box({ x = 48.0, y = 40.0 }, c8(200, 60, 140), 3)
                |> Render.striped({ color = c8(255, 255, 255), alpha = 1.0,
                                    width = 4.0, period = 8.0, dir = 1 })) ::
            at(80.0, 130.0, RawDraw.box({ x = 48.0, y = 40.0 }, c8(60, 140, 200), 3)
                |> Render.striped({ color = c8(255, 255, 255), alpha = 1.0,
                                    width = 4.0, period = 8.0, dir = 2 })) ::
            at(140.0, 130.0, RawDraw.box({ x = 48.0, y = 40.0 }, c8(220, 180, 60), 3)
                |> Render.checker({ color = c8(0, 0, 0), alpha = 1.0, cell = 4.0 })) ::
            Nil }

    // ── scene 2: 市松アトラスの sprite（UV 解決と NEAREST・反転・整数倍率）──

    /// アトラスの辺長（assets/atlas.png と対で決める）。
    pub def atlasSide(): Float64 = 16.0

    def atlasSprite(spec: { srcPos = Vec2.Vec2, srcSize = Vec2.Vec2, sx = Float64, sy = Float64,
                            fH = Bool, fV = Bool, z = Int32 }): Render.Item =
        Render.Item.Sprite({ texture = "atlas", tint = { r = 1.0, g = 1.0, b = 1.0 },
            alpha = 1.0, scale = { x = spec#sx, y = spec#sy }, rotation = 0.0, centered = true,
            flipH = spec#fH, flipV = spec#fV,
            regionRect = Some({ position = spec#srcPos, size = spec#srcSize }),
            zIndex = spec#z, blend = DrawCmd.BlendMode.Normal, maskPolys = Nil })

    def fullAtlas(sx: Float64, fH: Bool, fV: Bool, z: Int32): Render.Item =
        atlasSprite({ srcPos = { x = 0.0, y = 0.0 }, srcSize = { x = 16.0, y = 16.0 },
                      sx = sx, sy = sx, fH = fH, fV = fV, z = z })

    def spriteNearest(): Scene =
        { name = "spriteNearest", via = ShotVia.ViaTarget, repeats = 1, targets = Map.empty(), exact = true, passes = Nil, items =
            // 等倍の全面（regionRect = 全面）
            at(40.0, 40.0, fullAtlas(1.0, false, false, 1)) ::
            // 左上 8x8 の区画を 2 倍
            at(80.0, 40.0, atlasSprite({ srcPos = { x = 0.0, y = 0.0 }, srcSize = { x = 8.0, y = 8.0 },
                                         sx = 2.0, sy = 2.0, fH = false, fV = false, z = 1 })) ::
            // 右上 8x8 の区画を 3 倍
            at(120.0, 40.0, atlasSprite({ srcPos = { x = 8.0, y = 0.0 }, srcSize = { x = 8.0, y = 8.0 },
                                          sx = 3.0, sy = 3.0, fH = false, fV = false, z = 1 })) ::
            // 反転 3 種（白 texel の目印が移る隅で判別できる）
            at(170.0, 40.0, fullAtlas(2.0, true, false, 1)) ::
            at(220.0, 40.0, fullAtlas(2.0, false, true, 1)) ::
            at(270.0, 40.0, fullAtlas(2.0, true, true, 1)) ::
            // 右下区画 4 倍と、角に掛からない途中区画（uvOffset が端でない値）
            at(80.0, 120.0, atlasSprite({ srcPos = { x = 8.0, y = 8.0 }, srcSize = { x = 8.0, y = 8.0 },
                                          sx = 4.0, sy = 4.0, fH = false, fV = false, z = 1 })) ::
            at(170.0, 120.0, atlasSprite({ srcPos = { x = 4.0, y = 4.0 }, srcSize = { x = 8.0, y = 8.0 },
                                           sx = 2.0, sy = 2.0, fH = false, fV = false, z = 1 })) ::
            Nil }

    // ── scene 3: ターゲットに描いて本編へ NEAREST 拡大で貼る ──

    def passPaste(): Scene =
        let p3: Render.Pass = { name = "p3", clear = RenderTarget.LoadOp.Clear(c8(16, 24, 40)), items =
            at(0.0, 0.0, RawDraw.box({ x = 40.0, y = 20.0 }, c8(200, 60, 60), 1)) ::
            at(40.0, 0.0, RawDraw.box({ x = 40.0, y = 20.0 }, c8(60, 200, 60), 1)) ::
            at(0.0, 20.0, RawDraw.box({ x = 80.0, y = 25.0 }, c8(60, 60, 200), 1)) ::
            at(10.0, 5.0, RawDraw.box({ x = 8.0, y = 8.0 }, c8(255, 255, 255), 2)) ::
            Nil };
        { name = "passPaste", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = true, passes = p3 :: Nil, items =
            // 左上 80x45 を 2 倍（整数倍）で画面中央へ
            Render.blitRegion({ name = "p3", design = { x = designW(), y = designH() },
                                src = { position = { x = 0.0, y = 0.0 }, size = { x = 80.0, y = 45.0 } },
                                at = { x = 160.0, y = 90.0 }, size = { x = 160.0, y = 90.0 }, z = 2 }) ::
            Nil }

    // ── scene 4: pass に模様を描き出し、シェーダー面の tex 場が素通しで読む（Wave D の主役）──

    /// pass を r/g/b 素通しで読む Spec。テクスチャ値以降の float 合成をほぼ無くし、
    /// 標本の量子化 4 点（NEAREST・CLAMP・8bit 正規化・上下逆の吸収）だけを見る。
    def passthroughSpec(texName: String): ShaderDoc.Spec =
        { name = "parity_passthrough",
          cycleRate = 0.0,
          bindings = Nil,
          out = ShaderDoc.Out.Fill({
              shade = ShaderDoc.Shade.Rgb({
                  r = ShaderDoc.Field.Tex({ name = texName, chan = ShaderDoc.TexChan.R }),
                  g = ShaderDoc.Field.Tex({ name = texName, chan = ShaderDoc.TexChan.G }),
                  b = ShaderDoc.Field.Tex({ name = texName, chan = ShaderDoc.TexChan.B }) }),
              alpha = ShaderDoc.Field.Const(1.0) }) }

    def texField(): Scene =
        let p4: Render.Pass = { name = "p4", clear = RenderTarget.LoadOp.Clear(c8(0, 0, 0)), items =
            at(0.0, 0.0, RawDraw.box({ x = 160.0, y = 90.0 }, c8(200, 40, 40), 1)) ::
            at(160.0, 0.0, RawDraw.box({ x = 160.0, y = 90.0 }, c8(40, 200, 40), 1)) ::
            at(0.0, 90.0, RawDraw.box({ x = 160.0, y = 90.0 }, c8(40, 40, 200), 1)) ::
            at(160.0, 90.0, RawDraw.box({ x = 160.0, y = 90.0 }, c8(200, 200, 40), 1)) ::
            // 白の目印（左上）と市松（texel が細かく変わる領域）
            at(8.0, 8.0, RawDraw.box({ x = 16.0, y = 16.0 }, c8(255, 255, 255), 2)) ::
            at(120.0, 60.0, RawDraw.box({ x = 80.0, y = 60.0 }, c8(90, 90, 90), 2)
                |> Render.checker({ color = c8(30, 30, 30), alpha = 1.0, cell = 4.0 })) ::
            Nil };
        { name = "texField", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = true, passes = p4 :: Nil, items =
            Render.shaderFill(passthroughSpec("p4"),
                { position = { x = 0.0, y = 0.0 }, size = { x = designW(), y = designH() } },
                0.0, 1) ::
            Nil }

    // ── scene 5: 光マップの配管（Light.lightMapPass → Multiply blit。Wave F の主役）──
    //
    // A 段階に載せるのは配管（環境光 → pass 内 Add → Multiply 貼り）だけ:
    //   - 影ポリゴンは載せない（斜め縁は GL だけ AA が掛かる — 規約 3）
    //   - 放射（Render.lightAt の組み込み放射テクスチャ）はここでは Add の単色 box で
    //     代役し、放射そのものは radial scene が単体で見る（配管と放射で不一致の源を
    //     切り分けたまま保つ）
    //   - Multiply 貼りの下地は白 1 面（Multiply が恒等になり光マップ値がそのまま画面へ通る）
    // 影の正しさは純関数テスト（TestLight）と feature_lab の目視が担う。

    def lightMap(): Scene =
        let white = c8(255, 255, 255);
        let cfg: Light.LightMapConfig = {
            lights = Nil,
            occluders = Nil,
            viewport = { x = designW(), y = designH() },
            ambient = c8(16, 16, 24),
            shadowStrength = 1.0,
            extrudeLength = 2000.0,
            passName = "lm",
            z = 5 };
        // 灯りの代役 = Add の単色 box 2 枚（重なりの領域で Add の積み上がりも見る）。
        // lightMapPass の items へ追記できることは公式の拡張口（Pass はただのレコード）。
        let base = Light.lightMapPass(cfg);
        let lamps =
            at(48.0, 45.0, RawDraw.box({ x = 128.0, y = 90.0 }, c8(96, 96, 64), 10)
                |> Render.blended(DrawCmd.BlendMode.Add)) ::
            at(144.0, 45.0, RawDraw.box({ x = 128.0, y = 90.0 }, c8(64, 80, 96), 10)
                |> Render.blended(DrawCmd.BlendMode.Add)) ::
            Nil;
        let p = { items = List.append(base#items, lamps) | base };
        { name = "lightmap", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = true,
          passes = p :: Nil,
          items =
            at(0.0, 0.0, RawDraw.box({ x = designW(), y = designH() }, white, 1)) ::
            Light.lightMapOverlay(cfg) ::
            Nil }

    // ── scene 6: 組み込み放射テクスチャ（Render.lightAt / darkAt）──
    //
    // 一致が成り立つ土台 = 放射テクスチャの alpha が常に 255（RadialBuiltin）。
    //   - lightAt（Add）は d+s の整数の足し算になり、下地が何色でも一致する。
    //     重ね置き（Add の積み上がり）と飽和クランプもここで一緒に見る
    //   - darkAt（Multiply）の d×s/255 が割り切れるのは下地が白か黒のときだけ。
    //     下地をその 2 色に限り、光の当たった画素へ掛からないよう z 順を
    //     darkAt → lightAt にする（Add は何にでも exact に乗るが、逆は成り立たない）
    //   - radius = 128 で拡大率 1.0（texel→画素が等倍）。tint 白・strength 1.0 のみ
    //     （中間の tint / strength は float 乗算が入り 8bit に落ちない — 規約 2）
    //   - 四角の左上は画面内（負にしない）。SoftRaster の出力矩形の丸め
    //     （SoftRaster.ri = 0 方向切り捨て）が負座標で 1px 内側にずれ、貼りが等倍で
    //     なくなる — 右下への はみ出しは正の座標のままなので等倍が保たれる

    def radial(): Scene =
        { name = "radial", via = ShotVia.ViaTarget, repeats = 1, targets = Map.empty(), exact = true, passes = Nil, items =
            // 右側の白下地（darkAt の Multiply が exact になる面）
            at(192.0, 0.0, RawDraw.box({ x = 128.0, y = 180.0 }, c8(255, 255, 255), 2)) ::
            // 翳り: 白と黒の下地にだけ掛かる
            Render.darkAt({ at = { x = 256.0, y = 128.0 }, radius = 128.0,
                            strength = 1.0, z = 3 }) ::
            // 明かり 2 枚（重なりで Add の積み上がり・白下地に掛かる所で飽和クランプ）
            Render.lightAt({ at = { x = 128.0, y = 128.0 }, radius = 128.0,
                             color = c8(255, 255, 255), strength = 1.0, z = 4 }) ::
            Render.lightAt({ at = { x = 174.0, y = 158.0 }, radius = 128.0,
                             color = c8(255, 255, 255), strength = 1.0, z = 5 }) ::
            Nil }

    // ── scene 7: 窓の後ろを薄める半透明の幕（Render.fade・α 0.5）──
    // 画面いっぱいの幕を、色の箱と sprite の上に重ねる（ゲームの「確認の窓の後ろを暗くする」と同じ形）。
    // 規約 2 の例外: α は 0.5 だけ使い、色は偶数の k/255 にして、重ねた答えが 8bit で割り切れるようにする
    // （0.5·src + 0.5·dst が整数になる組 —— 丸めの差を出さずに、重ね方そのものの違いだけを見る）。
    def veil(): Scene =
        { name = "veil", via = ShotVia.ViaTarget, repeats = 1, targets = Map.empty(), exact = true, passes = Nil, items =
            at(20.0, 20.0, RawDraw.box({ x = 120.0, y = 80.0 }, c8(200, 120, 60), 1)) ::
            at(160.0, 40.0, RawDraw.box({ x = 100.0, y = 100.0 }, c8(40, 160, 220), 1)) ::
            at(60.0, 110.0, atlasSprite({ srcPos = { x = 0.0, y = 0.0 }, srcSize = { x = 16.0, y = 16.0 },
                                          sx = 4.0, sy = 4.0, fH = false, fV = false, z = 2 })) ::
            at(0.0, 0.0, RawDraw.box({ x = designW(), y = designH() }, c8(40, 20, 60), 10) |> Render.fade(0.5)) ::
            Nil }

    // ── scene 8: Pass の連鎖（前の Pass を次の Pass の面が tex で素通しに読む・3 段）──
    // 素通しの tex 場は A 段階（texField）と同じ標本の量子化だけを見る。段を重ねても 1 段ごとに同じ texel を写すこと。

    def passChain(): Scene =
        let c1: Render.Pass = { name = "c1", clear = RenderTarget.LoadOp.Clear(c8(0, 0, 0)), items =
            at(0.0, 0.0, RawDraw.box({ x = 160.0, y = 90.0 }, c8(200, 40, 40), 1)) ::
            at(160.0, 90.0, RawDraw.box({ x = 160.0, y = 90.0 }, c8(40, 200, 40), 1)) ::
            at(8.0, 8.0, RawDraw.box({ x = 16.0, y = 16.0 }, c8(255, 255, 255), 2)) ::
            at(120.0, 60.0, RawDraw.box({ x = 80.0, y = 60.0 }, c8(90, 90, 90), 2)
                |> Render.checker({ color = c8(30, 30, 30), alpha = 1.0, cell = 4.0 })) ::
            Nil };
        let full = { position = { x = 0.0, y = 0.0 }, size = { x = designW(), y = designH() } };
        let copyOf = (name, src) -> ({ name = name, clear = RenderTarget.LoadOp.Clear(c8(0, 0, 0)), items =
            Render.shaderFill(passthroughSpec(src), full, 0.0, 1) :: Nil }: Render.Pass);
        { name = "passChain", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = true,
          passes = c1 :: copyOf("c2", "c1") :: copyOf("c3", "c2") :: Nil, items =
            Render.shaderFill(passthroughSpec("c3"), full, 0.0, 1) :: Nil }

    // ── scene 9: まだ描いていない Pass を読む（forward reference）は、面は黒・sprite は貼らない ──
    // GL は Pass の列を 2 コマ描いてから撮る。前のコマの lb の中身が見えていたら右半分・左半分に赤が出て割れる。

    def passLaterRead(): Scene =
        let la: Render.Pass = { name = "la", clear = RenderTarget.LoadOp.Clear(c8(40, 40, 40)), items =
            Render.shaderFill(passthroughSpec("lb"), { position = { x = 0.0, y = 0.0 }, size = { x = 160.0, y = designH() } }, 0.0, 1) ::
            Render.blitRegion({ name = "lb", design = { x = designW(), y = designH() },
                                src = { position = { x = 0.0, y = 0.0 }, size = { x = designW(), y = designH() } },
                                at = { x = 240.0, y = 90.0 }, size = { x = 160.0, y = designH() }, z = 2 }) ::
            Nil };
        let lb: Render.Pass = { name = "lb", clear = RenderTarget.LoadOp.Clear(c8(200, 60, 60)), items = Nil };
        { name = "passLaterRead", via = ShotVia.ViaScreen, repeats = 2, targets = Map.empty(), exact = true, passes = la :: lb :: Nil, items =
            Render.blit("la", { x = designW(), y = designH() }, 1) :: Nil }

    // ── scene 10: Pass の中の mask 付きの面（ターゲットにもステンシルがある）──
    // 整数座標の矩形 2 枚で抜く（斜めの縁は GL だけ AA が掛かる — 規約 3）。

    def passMask(): Scene =
        let solid: ShaderDoc.Spec = { name = "parity_solid", cycleRate = 0.0, bindings = Nil,
            out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c8(60, 200, 120)), alpha = ShaderDoc.Field.Const(1.0) }) };
        let rect = (x, y, w, h) -> { x = x, y = y } :: { x = x + w, y = y } :: { x = x + w, y = y + h } :: { x = x, y = y + h } :: Nil;
        let pm: Render.Pass = { name = "pm", clear = RenderTarget.LoadOp.Clear(c8(20, 20, 40)), items =
            Render.shaderFillMasked(solid, { position = { x = 0.0, y = 0.0 }, size = { x = designW(), y = designH() } },
                rect(20.0, 20.0, 100.0, 60.0) :: rect(180.0, 100.0, 80.0, 50.0) :: Nil, 0.0, 1) :: Nil };
        { name = "passMask", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = true, passes = pm :: Nil, items =
            Render.blit("pm", { x = designW(), y = designH() }, 1) :: Nil }

    // ── scene 11: 半分の解像度の Pass（RenderTarget.Descriptor の scale = 0.5）──
    // 整数座標の箱と市松を半分のターゲットに描き、左半分は面の tex 場（Nearest）で・右半分は sprite で貼る。
    // GL はテクセル i を design の点 2i+1 で塗り、描き出しは design で描いてその点を拾う — 整数の縁なら同じテクセルになる。

    def halfItems(): List[Render.PlacedItem] =
        at(0.0, 0.0, RawDraw.box({ x = 160.0, y = 90.0 }, c8(200, 40, 40), 1)) ::
        at(160.0, 90.0, RawDraw.box({ x = 160.0, y = 90.0 }, c8(40, 200, 40), 1)) ::
        at(9.0, 7.0, RawDraw.box({ x = 15.0, y = 13.0 }, c8(255, 255, 255), 2)) ::
        // 市松の升目の境（箱の中心から cell ごと）は偶数にそろえる — 縁が標本点 2i+1 にちょうど乗ると、
        // 升目の色が GL の式の浮動小数の端で決まって割れる（箱の縁は pickedPixel で合わせてあるが、升目は面の中の式）。
        at(122.0, 62.0, RawDraw.box({ x = 80.0, y = 56.0 }, c8(90, 90, 90), 2)
            |> Render.checker({ color = c8(30, 30, 30), alpha = 1.0, cell = 4.0 })) ::
        Nil

    def scaledScene(name: String, scale: Float64, exact: Bool): Scene =
        let pass: Render.Pass = { name = name + "T", clear = RenderTarget.LoadOp.Clear(c8(16, 24, 40)), items = halfItems() };
        { name = name, via = ShotVia.ViaScreen, repeats = 1,
          targets = Map#{ name + "T" => { scale = scale | RenderTarget.defaultDescriptor() } }, exact = exact,
          passes = pass :: Nil, items =
            Render.shaderFill(passthroughSpec(name + "T"), { position = { x = 0.0, y = 0.0 }, size = { x = 160.0, y = designH() } }, 0.0, 1) ::
            Render.blitRegion({ name = name + "T", design = { x = designW(), y = designH() },
                                src = { position = { x = 160.0, y = 0.0 }, size = { x = 160.0, y = designH() } },
                                at = { x = 240.0, y = 90.0 }, size = { x = 160.0, y = designH() }, z = 1 }) ::
            Nil }

    def passHalf(): Scene = scaledScene("passHalf", 0.5, true)

    // ── scene 12: 割り切れない倍率（320 × 0.33 → 106・180 × 0.33 → 60）。B 段階（縦横の倍率が少し違い、整数の縁でも割れうる）──

    def passQuarterOdd(): Scene = scaledScene("passQuarterOdd", 0.33, false)

    // ── scene 13: 半分の Pass を Linear で全面へ読む（sampler 節）。B 段階 — 読む点は同じだが、GPU は補間の重みを
    // 固定小数に丸めるので ±1/255 程度ずれうる ──

    def linearRead(): Scene =
        let lin = chan -> ShaderDoc.Field.Sampler({ filter = ShaderDoc.FilterMode.Linear,
                                                    of = ShaderDoc.Field.Tex({ name = "lrT", chan = chan }) });
        let spec: ShaderDoc.Spec = { name = "parity_linear", cycleRate = 0.0, bindings = Nil,
            out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = lin(ShaderDoc.TexChan.R), g = lin(ShaderDoc.TexChan.G),
                                                                     b = lin(ShaderDoc.TexChan.B) }),
                                       alpha = ShaderDoc.Field.Const(1.0) }) };
        let pass: Render.Pass = { name = "lrT", clear = RenderTarget.LoadOp.Clear(c8(16, 24, 40)), items = halfItems() };
        { name = "linearRead", via = ShotVia.ViaScreen, repeats = 1,
          targets = Map#{ "lrT" => { scale = 0.5 | RenderTarget.defaultDescriptor() } }, exact = false,
          passes = pass :: Nil, items =
            Render.shaderFill(spec, { position = { x = 0.0, y = 0.0 }, size = { x = designW(), y = designH() } }, 0.0, 1) :: Nil }

    // ── scene: 灯りの反対へ倒した影（Shadow.projectedRuns）──
    // 影の帯は斜めの縁と頂点ごとの濃さ（gradPolygon）なので B 段階（差の数だけ報告）。

    /// 人の形（8×12）。'h' 髪・'s' 肌・'c' 服・'p' 脚。
    def heroDoc(): PxSpriteDoc.Doc =
        { version = 1, note = None,
          legend = Map#{ 'h' => "hair", 's' => "skin", 'c' => "cloth", 'p' => "leg" },
          sprites = Map#{ "hero" => { anchor = Vec2.zero(), clips = Map.empty(), frames = Map#{ "idle" =>
              ("..hhhh.." :: ".hhhhhh." :: ".hssssh." :: ".ssssss." :: "..ssss.." :: ".cccccc." ::
               "cccccccc" :: "cccccccc" :: "s.cccc.s" :: "..cccc.." :: "..pp.pp." :: "..pp.pp." :: Nil) } } } }

    def heroColor(key: String): Color = match key {
        case "hair"  => c8(60, 40, 40)
        case "skin"  => c8(200, 150, 120)
        case "cloth" => c8(80, 90, 140)
        case "leg"   => c8(60, 50, 60)
        case _       => c8(255, 255, 255)
    }

    def castShadow(): Scene =
        let foot = { x = 160.0, y = 130.0 };
        let heroAt = { x = 144.0, y = 82.0 };
        let runs = PxSprite.runs(heroDoc(), "hero", "idle", heroAt, false, 4);
        let shadowOf = light -> Shadow.projectedRuns({ runs = runs, foot = foot, light = light, reach = 0.8, depth = 0.3,
                                                       ink = c8(40, 30, 60), alpha = 0.7, z = 1 });
        { name = "castShadow", via = ShotVia.ViaTarget, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            at(0.0, 0.0, RawDraw.box({ x = designW(), y = designH() }, c8(150, 140, 120), 0))
                :: List.flatten(shadowOf({ x = 100.0, y = 110.0 }) :: shadowOf({ x = 230.0, y = 100.0 })
                    :: PxSprite.draw(heroDoc(), "hero", "idle", heroAt, false, 4, heroColor, 2) :: Nil) }

    // ── scene: 面に渡す数（Field.Param / Render.withShaderParams）──
    // 同じ Spec（同じ program）の面 3 枚に別の値を渡す: GL は uniform を描く直前に差し、描き出しは Const に置き換える。
    // 値は 8bit で半分に乗らない数（0.6 → 153・0.2 → 51・0.25 → 64）。右端は値を渡さない（0 で描く）。

    def paramSpec(): ShaderDoc.Spec =
        { name = "parity_param", cycleRate = 0.0, bindings = Nil,
          out = ShaderDoc.Out.Fill({
              shade = ShaderDoc.Shade.Rgb({ r = ShaderDoc.Field.Param({ name = "red" }),
                                            g = ShaderDoc.Field.Param({ name = "green" }),
                                            b = ShaderDoc.Field.Const(0.0) }),
              alpha = ShaderDoc.Field.Const(1.0) }) }

    def paramFill(x: Float64, params: Map[String, Float64]): Render.PlacedItem =
        Render.shaderFill(paramSpec(), { position = { x = x, y = 40.0 }, size = { x = 80.0, y = 100.0 } }, 0.0, 1)
            |> Render.withShaderParams(params)

    def paramRead(): Scene =
        { name = "paramRead", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = true, passes = Nil, items =
            paramFill(20.0, Map#{ "red" => 0.6, "green" => 0.2 })
                :: paramFill(120.0, Map#{ "red" => 0.25, "green" => 0.6 })
                :: paramFill(220.0, Map.empty()) :: Nil }

    // ── scene 16 / 17: 3D の場面（Render.scene3d → GL は Platform.Draw3d.drawScene3d・CPU は SoftRaster3d）。B 段階（toleranceOf）──
    // 光は白の環境光だけ（光の式の差を持ち込まず、前後と状態だけを見る）。目は原点で +Z を向く。

    /// z（world）の平面に立つ、目の側（−Z）を向く四角。x0..x1・y0..y1 は world の範囲。
    def facingQuad(x0: Float64, x1: Float64, y0: Float64, y1: Float64, z: Float64, color: Color): Mesh3d.Polygon =
        { points = Vec3.v3(x0, y0, z) :: Vec3.v3(x0, y1, z) :: Vec3.v3(x1, y1, z) :: Vec3.v3(x1, y0, z) :: Nil, color = color }

    def flatCamera(): Camera3d.Camera3d =
        { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 1.0, far = 100.0 }

    def flatScene(size: Vec2.Vec2, z: Int32, instances: List[Scene3d.Instance3d], billboards: List[Scene3d.Billboard3d]): Scene3d.Scene3dCmd =
        { instances = instances, billboards = billboards, zIndex = z,
          environment = { ambient = c8(255, 255, 255), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(c8(10, 10, 30)) }
          | Scene3d.scene(flatCamera(), size) }

    def shape(polys: List[Mesh3d.Polygon]): Scene3d.Instance3d =
        Scene3d.meshInstance(Mesh3d.fromPolygons(polys), Mat4.identity())

    // 手前（z = 10）の赤い板の後に、奥（z = 20）の青い板を渡す — 渡した順に塗ると青が勝つ。深度で赤が勝てば真ん中は赤。
    // 赤と青の間（z = 15）に市松アトラスのビルボードを立てる（青より手前・赤より奥）。
    def depthRed(): Scene =
        let red = shape(facingQuad(-3.0, 1.0, -2.0, 2.0, 10.0, c8(220, 30, 30)) :: Nil);
        let blue = shape(facingQuad(-8.0, 8.0, -6.0, 6.0, 20.0, c8(30, 60, 220)) :: Nil);
        let board = Scene3d.billboard("atlas", { position = { x = 0.0, y = 0.0 }, size = { x = 16.0, y = 16.0 } },
                                      Vec3.v3(1.5, -2.0, 15.0), { x = 3.0, y = 3.0 }) |> Scene3d.unlit;
        { name = "depthRed", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, flatScene({ x = 240.0, y = 140.0 }, 1, red :: blue :: Nil, board :: Nil)) :: Nil }

    // 3D の場面の後に、同じコマで場面に重なる箱・sprite・mask 付きの面・tex を読む面を描く。深度判定・面の向きでの間引き・blend・
    // ステンシルが場面の後に残っていると、2D が欠けるか色が変わる。場面の中では Linear で読む絵つきの材質（unit 0）の後に
    // NEAREST のビルボードを立てる — 材質の sampler が unit 0 に残ると、ビルボードと sprite の市松がにじむ。
    def afterScene3d(): Scene =
        let solid: ShaderDoc.Spec = { name = "parity_after3d", cycleRate = 0.0, bindings = Nil,
            out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c8(60, 200, 120)), alpha = ShaderDoc.Field.Const(1.0) }) };
        let rect = (x, y, w, h) -> { x = x, y = y } :: { x = x + w, y = y } :: { x = x + w, y = y + h } :: { x = x, y = y + h } :: Nil;
        let plate = shape(facingQuad(-4.0, 4.0, -3.0, 3.0, 10.0, c8(200, 120, 40)) :: Nil);
        let painted = Scene3d.meshInstance(texturedQuad(-5.8, -4.4, 3.4, 4.8, 10.0, 0.0, 1.0), Mat4.identity())
            |> Scene3d.withMaterial(Scene3d.texturedMaterial("atlas", ShaderDoc.FilterMode.Linear));
        let board = Scene3d.billboard("atlas", { position = { x = 0.0, y = 0.0 }, size = { x = 16.0, y = 16.0 } },
                                      Vec3.v3(4.6, -5.0, 9.0), { x = 1.6, y = 1.6 }) |> Scene3d.unlit;
        { name = "afterScene3d", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 0.0, y = 0.0 }, flatScene({ x = 200.0, y = 180.0 }, 1, plate :: painted :: Nil, board :: Nil)) ::
            at(60.0, 60.0, RawDraw.box({ x = 40.0, y = 40.0 }, c8(240, 240, 240), 2)) ::
            at(150.0, 90.0, fullAtlas(4.0, false, false, 2)) ::
            Render.shaderFillMasked(solid, { position = { x = 120.0, y = 20.0 }, size = { x = 180.0, y = 140.0 } },
                rect(130.0, 30.0, 60.0, 40.0) :: rect(220.0, 100.0, 60.0, 50.0) :: Nil, 0.0, 3) ::
            Render.shaderFill(passthroughSpec("atlas"), { position = { x = 208.0, y = 152.0 }, size = { x = 48.0, y = 24.0 } }, 0.0, 3) ::
            Nil }

    /// z の平面に立つ、目の側（−Z）を向く uv つきの四角。左上の角が uv (lo, lo)・右下の角が (hi, hi)（0..1 の外は wrap で読む）。
    def texturedQuad(x0: Float64, x1: Float64, y0: Float64, y1: Float64, z: Float64, lo: Float64, hi: Float64): Mesh3d.Mesh3d =
        let quad = { points = Vec3.v3(x0, y0, z) :: Vec3.v3(x0, y1, z) :: Vec3.v3(x1, y1, z) :: Vec3.v3(x1, y0, z) :: Nil,
                     uvs = { x = lo, y = hi } :: { x = lo, y = lo } :: { x = hi, y = lo } :: { x = hi, y = hi } :: Nil,
                     color = c8(255, 255, 255) };
        match Mesh3d.fromTexturedPolygons(quad :: Nil) {
            case Ok(mesh) => mesh
            case Err(e)   => bug!(e)
        }

    // ── scene 18: 3D の材質（Scene3d.withMaterial → GL は材質のプログラム・CPU は ShaderEval の材質）。B 段階 ──
    // 左の板は World.x の 1 単位ごとの縞（赤と黄）。右の板は cutout で World.y の縞の半分を抜き、色は Param で渡す。
    // 抜けた所から奥の青い板（頂点の色）が見える。光は白の環境光だけなので、色は albedo そのまま。

    /// World の軸 axis の 1 単位ごとに 0 と 1 が入れ替わる縞。
    def worldStripe(axis: ShaderDoc.Axis3): ShaderDoc.Field =
        ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Step, a = ShaderDoc.Field.Const(0.5),
                              b = ShaderDoc.Field.Un({ op = ShaderDoc.UnOp.Fract, of = ShaderDoc.Field.World({ axis = axis }) }) })

    def stripeMaterial(): Scene3d.Material3d =
        Scene3d.material({ name = "parity_stripe3d", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Ramp({ lo = c8(220, 40, 40), hi = c8(240, 220, 60),
                                                                                     field = worldStripe(ShaderDoc.Axis3.X) }),
                                                      alpha = ShaderDoc.Field.Const(1.0) }) })

    def cutoutMaterial(): Scene3d.Material3d =
        Scene3d.material({ name = "parity_cutout3d", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = ShaderDoc.Field.Param({ name = "red" }),
                                                                                    g = ShaderDoc.Field.Const(0.2),
                                                                                    b = ShaderDoc.Field.Const(0.8) }),
                                                      alpha = worldStripe(ShaderDoc.Axis3.Y) }) })
            |> Scene3d.withParams(Map#{ "red" => 0.6 })
            |> Scene3d.withCutout(true)

    def materialStripes(): Scene =
        let back = shape(facingQuad(-8.0, 8.0, -6.0, 6.0, 20.0, c8(30, 60, 220)) :: Nil);
        let stripes = shape(facingQuad(-4.5, -0.5, -2.5, 2.5, 10.0, c8(255, 255, 255)) :: Nil) |> Scene3d.withMaterial(stripeMaterial());
        let cut = shape(facingQuad(0.5, 4.5, -2.5, 2.5, 10.0, c8(255, 255, 255)) :: Nil) |> Scene3d.withMaterial(cutoutMaterial());
        { name = "materialStripes", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, flatScene({ x = 240.0, y = 140.0 }, 1, back :: stripes :: cut :: Nil, Nil)) :: Nil }

    // ── scene 19: スポットライトの影（SpotLight.shadow → GL は影の地図・CPU は SoftRaster3d）。B 段階 ──
    // 真上から下を向くスポットの下に床を敷き、左の場面だけ光と床の間に板を置く。左の床の板の真下は暗く、右は明るい。
    // 左右とも同じ mapSize の影を持つ — 同じコマの 2 つの場面が地図を取り違えると、左の影が消える。

    /// 高さ y の水平な四角（上を向く。x0..x1・z0..z1 は world の範囲）。
    def upQuad(x0: Float64, x1: Float64, z0: Float64, z1: Float64, y: Float64, color: Color): Mesh3d.Polygon =
        { points = Vec3.v3(x0, y, z0) :: Vec3.v3(x0, y, z1) :: Vec3.v3(x1, y, z1) :: Vec3.v3(x1, y, z0) :: Nil, color = color }

    def shadowSpot(): Scene3d.SpotLight =
        { position = Vec3.v3(0.0, 8.0, 10.0), target = Vec3.v3(0.0, -2.0, 10.0), fovY = 1.4, innerFovY = None, color = c8(255, 255, 255),
          intensity = 1.0, range = 20.0, shadow = Some({ mapSize = 512, bias = 0.0015, pcfRadius = 1, strength = 0.8 }) }

    def shadowScene(withBoard: Bool): Scene3d.Scene3dCmd =
        let camera = { eye = Vec3.v3(0.0, 7.0, 0.0), yaw = 0.0, pitch = 0.73, fovY = 1.0, near = 1.0, far = 100.0 };
        let floor = shape(upQuad(-8.0, 8.0, 2.0, 18.0, -2.0, c8(200, 200, 200)) :: Nil);
        let board = shape(upQuad(-1.5, 1.5, 8.5, 11.5, 2.0, c8(200, 80, 60)) :: Nil);
        { instances = if (withBoard) floor :: board :: Nil else floor :: Nil, spotLights = shadowSpot() :: Nil, zIndex = 1,
          environment = { ambient = c8(40, 40, 40), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(c8(10, 10, 30)) }
          | Scene3d.scene(camera, { x = 160.0, y = 180.0 }) }

    def spotShadow(): Scene =
        { name = "spotShadow", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 0.0, y = 0.0 }, shadowScene(true)) ::
            Render.scene3d({ x = 160.0, y = 0.0 }, shadowScene(false)) :: Nil }

    // ── scene 20: ジョイントで曲げた板（Scene3d.withPose → GL は骨つきの版のプログラム・CPU は SoftRaster3d のスキニング）。B 段階 ──
    // 縦に長い板 2 枚を、根のジョイント（下の端）と上のジョイント（真ん中）で曲げる。左は頂点の色・右は材質（縞）で、
    // 上のジョイントを左は反時計回り・右は時計回りに回す。影を落とすスポットを目の上に置き、曲がった影を奥の板に落とす。
    // 曲げずに描くと板はまっすぐ立ち、影もまっすぐになる。

    /// 板の行の高さ（形の座標の y）。真ん中の行だけ 2 つのジョイントに半分ずつ掛かる。
    def skinRows(): List[Float64] = -3.0 :: -1.5 :: 0.0 :: 1.5 :: 3.0 :: Nil

    def skinWeightOfRow(y: Float64): (Float64, Float64) =
        if (y < -0.5) (1.0, 0.0) else if (y > 0.5) (0.0, 1.0) else (0.5, 0.5)

    /// 幅 2.4・高さ 6 の、目の側（−Z）を向く板（z = 10）。行ごとに左右 2 頂点・色は下の橙から上の水色へ。
    def skinPlate(): Mesh3d.Mesh3d =
        let rows = skinRows();
        let count = List.length(rows);
        let positions = rows |> List.flatMap(y -> -1.2 :: y :: 10.0 :: 1.2 :: y :: 10.0 :: Nil) |> List.toVector;
        let normals = rows |> List.flatMap(_ -> 0.0 :: 0.0 :: -1.0 :: 0.0 :: 0.0 :: -1.0 :: Nil) |> List.toVector;
        let colors = rows |> List.mapWithIndex((i, _) -> {
            let t = Int32.toFloat64(i) / Int32.toFloat64(count - 1);
            let c = (0.86 - 0.7 * t) :: (0.47 + 0.24 * t) :: (0.16 + 0.62 * t) :: Nil;
            List.append(c, c)
        }) |> List.flatten |> List.toVector;
        let indices = List.range(0, count - 1)
            |> List.flatMap(r -> { let a = 2 * r; a :: a + 2 :: a + 3 :: a :: a + 3 :: a + 1 :: Nil })
            |> List.toVector;
        let joints = rows |> List.flatMap(_ -> 0 :: 1 :: 0 :: 0 :: 0 :: 1 :: 0 :: 0 :: Nil) |> List.toVector;
        let weights = rows |> List.flatMap(y -> {
            let (w0, w1) = skinWeightOfRow(y);
            w0 :: w1 :: 0.0 :: 0.0 :: w0 :: w1 :: 0.0 :: 0.0 :: Nil
        }) |> List.toVector;
        match Mesh3d.fromArrays({ positions = positions, normals = normals, colors = colors, indices = indices,
                                  skin = Some({ joints = joints, weights = weights }) }) {
            case Ok(mesh) => mesh
            case Err(e)   => bug!(e)
        }

    /// 根（板の下の端）と、その 3 上のジョイント（板の真ん中）。逆バインド行列はレストポーズから求めさせる。
    def skinPlateSkin(): Skin3d.Skin3d =
        let still = { x = 0.0, y = 0.0, z = 0.0, w = 1.0 };
        let one = Vec3.v3(1.0, 1.0, 1.0);
        match Skin3d.make({ names = Vector#{"root", "upper"}, parents = Vector#{-1, 0},
                            rest = Vector#{ { translation = Vec3.v3(0.0, -3.0, 10.0), rotation = still, scale = one },
                                            { translation = Vec3.v3(0.0, 3.0, 0.0), rotation = still, scale = one } },
                            inverseBinds = None, rootTransform = Mat4.identity() }) {
            case Ok(skin) => skin
            case Err(e)   => bug!(e)
        }

    /// 上のジョイントだけを z 軸まわりに angle（ラジアン）回した Pose（bend の途中）。
    def skinBendPose(angle: Float64): Pose3d.Pose3d =
        let skin = skinPlateSkin();
        let half = angle / 2.0;
        let bent = Skin3d.restPose(skin) |> Vector.mapWithIndex((i, rest) ->
            if (i == 1) { rotation = { x = 0.0, y = 0.0, z = RenderUtil.sinF(half), w = RenderUtil.cosF(half) } | rest } else rest);
        Pose3d.compute(skin, bent)

    def skinBendSpot(): Scene3d.SpotLight =
        { position = Vec3.v3(0.0, 3.0, 0.0), target = Vec3.v3(0.0, 0.0, 20.0), fovY = 1.2, innerFovY = None, color = c8(255, 255, 255),
          intensity = 1.0, range = 40.0, shadow = Some({ mapSize = 512, bias = 0.0015, pcfRadius = 1, strength = 0.8 }) }

    def skinBend(): Scene =
        let back = shape(facingQuad(-8.0, 8.0, -6.0, 6.0, 20.0, c8(200, 200, 200)) :: Nil);
        let left = Scene3d.meshInstance(skinPlate(), Mat4.translate(Vec3.v3(-2.5, 0.0, 0.0))) |> Scene3d.withPose(skinBendPose(0.7));
        let right = Scene3d.meshInstance(skinPlate(), Mat4.translate(Vec3.v3(2.5, 0.0, 0.0)))
            |> Scene3d.withMaterial(stripeMaterial()) |> Scene3d.withPose(skinBendPose(-0.7));
        let scene = { instances = back :: left :: right :: Nil, spotLights = skinBendSpot() :: Nil, zIndex = 1,
                      environment = { ambient = c8(90, 90, 90), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(c8(10, 10, 30)) }
                      | Scene3d.scene(flatCamera(), { x = 240.0, y = 140.0 }) };
        { name = "skinBend", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, scene) :: Nil }

    // ── scene 21: 絵つきの材質（Scene3d.texturedMaterial → GL は uTexN と sampler・CPU は ShaderEval の 3D の Tex）。B 段階 ──
    // 左は箱投影の uv（Mesh3d.withBoxUvs。uv が −0.5..0.5 なので REPEAT で回り込む）の箱を NEAREST で、
    // 右は uv が −0.25..1.25 の板を Linear + Clamp で読む。絵は場面の textures（Texture3d）から。
    // 左上の象限が赤・対角が白なので、uv の上下・左右の取り違えと鏡写しは色の位置で分かる。

    /// 8 × 8 の絵。象限ごとに赤・黄・青・緑で、対角（x = y）が白。
    def parityTexture(): Texture3d.Texture3d =
        let argbOf = (c: Color) -> {
            let k = (x: Float64) -> Float64.round(x * 255.0) |> Float64.tryToInt32 |> Option.getWithDefault(0);
            Int32.bitwiseOr(Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.leftShift(k(c#r), 16)),
                            Int32.bitwiseOr(Int32.leftShift(k(c#g), 8), k(c#b)))
        };
        let texel = (x: Int32, y: Int32) ->
            if (x == y) c8(255, 255, 255)
            else if (y < 4) (if (x < 4) c8(220, 40, 40) else c8(240, 220, 60))
            else if (x < 4) c8(40, 80, 220) else c8(60, 200, 90);
        let pixels = Vector.range(0, 64) |> Vector.map(k -> argbOf(texel(Int32.remainder(k, 8), k / 8)));
        match Texture3d.fromArgb(8, 8, pixels) {
            case Ok(t)  => t
            case Err(e) => bug!(e)
        }

    /// 1 辺 2 の箱（6 面とも外から見て時計回り）。
    def boxMesh(): Mesh3d.Mesh3d =
        let p = (x: Float64, y: Float64, z: Float64) -> Vec3.v3(x, y, z);
        let face = (pts: List[Vec3.Vec3]) -> { points = pts, color = c8(255, 255, 255) };
        Mesh3d.fromPolygons(
            face(p(1.0, -1.0, -1.0) :: p(1.0, 1.0, -1.0) :: p(1.0, 1.0, 1.0) :: p(1.0, -1.0, 1.0) :: Nil) ::
            face(p(-1.0, -1.0, 1.0) :: p(-1.0, 1.0, 1.0) :: p(-1.0, 1.0, -1.0) :: p(-1.0, -1.0, -1.0) :: Nil) ::
            face(p(-1.0, 1.0, -1.0) :: p(-1.0, 1.0, 1.0) :: p(1.0, 1.0, 1.0) :: p(1.0, 1.0, -1.0) :: Nil) ::
            face(p(-1.0, -1.0, 1.0) :: p(-1.0, -1.0, -1.0) :: p(1.0, -1.0, -1.0) :: p(1.0, -1.0, 1.0) :: Nil) ::
            face(p(1.0, -1.0, 1.0) :: p(1.0, 1.0, 1.0) :: p(-1.0, 1.0, 1.0) :: p(-1.0, -1.0, 1.0) :: Nil) ::
            face(p(-1.0, -1.0, -1.0) :: p(-1.0, 1.0, -1.0) :: p(1.0, 1.0, -1.0) :: p(1.0, -1.0, -1.0) :: Nil) ::
            Nil)

    def texturedBox(): Scene =
        let tex = parityTexture();
        let world = Mat4.mul(Mat4.translate(Vec3.v3(-2.3, 0.0, 10.0)), Mat4.mul(Mat4.rotateX(0.45), Mat4.rotateY(0.6)));
        let box = Scene3d.meshInstance(Mesh3d.withBoxUvs(0.5, boxMesh()), world)
            |> Scene3d.withMaterial(Scene3d.texturedMaterial(Texture3d.name(tex), ShaderDoc.FilterMode.Nearest));
        let plate = Scene3d.meshInstance(texturedQuad(0.8, 4.6, -2.4, 2.4, 10.0, -0.25, 1.25), Mat4.identity())
            |> Scene3d.withMaterial(Scene3d.texturedMaterial(Texture3d.name(tex), ShaderDoc.FilterMode.Linear) |> Scene3d.withWrap(Scene3d.Wrap.Clamp));
        let scene = { textures = tex :: Nil, environment = { hemisphere = 0.3, ambient = c8(180, 180, 180) | flatScene({ x = 240.0, y = 140.0 }, 1, Nil, Nil)#environment }
                      | flatScene({ x = 240.0, y = 140.0 }, 1, box :: plate :: Nil, Nil) };
        { name = "texturedBox", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, scene) :: Nil }

    // ── scene 22: 法線マップ（Scene3d.withNormalMap → GL は unit 6 と frag の傾け・CPU は SoftRaster3d の同じ式）。B 段階 ──
    // 半球の出っ張りを並べた法線マップを、uv 0..2（REPEAT で 2 × 2 個）の板に貼り、左から点光源を当てる。
    // 出っ張りは灯りの側（左）が明るく、反対の側（右）が暗い。向きを取り違えると明暗が逆になる。

    /// 32 × 32 の、真ん中に半径 0.8 の半球の出っ張りがある法線マップ（タンジェント空間・緑が絵の上）。
    def bumpTexture(): Texture3d.Texture3d =
        let channel = (x: Float64) -> Float64.round((x * 0.5 + 0.5) * 255.0) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        let texel = (k: Int32) -> {
            let fx = (Int32.toFloat64(Int32.remainder(k, 32)) + 0.5) / 32.0 * 2.0 - 1.0;
            let fy = 0.0 - ((Int32.toFloat64(k / 32) + 0.5) / 32.0 * 2.0 - 1.0);
            let (px, py) = (fx / 0.8, fy / 0.8);
            let inside = px * px + py * py < 1.0;
            let (nx, ny, nz) = if (inside) (px, py, Num.sqrt(1.0 - px * px - py * py)) else (0.0, 0.0, 1.0);
            Int32.bitwiseOr(Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.leftShift(channel(nx), 16)),
                            Int32.bitwiseOr(Int32.leftShift(channel(ny), 8), channel(nz)))
        };
        match Texture3d.fromArgb(32, 32, Vector.range(0, 1024) |> Vector.map(texel)) {
            case Ok(t)  => t
            case Err(e) => bug!(e)
        }

    def bumpMaterial(texture: Texture3d.Texture3d): Scene3d.Material3d =
        Scene3d.material({ name = "parity_bump3d", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c8(220, 220, 220)), alpha = ShaderDoc.Field.Const(1.0) }) })
            |> Scene3d.withNormalMap({ texture = Texture3d.name(texture), strength = 1.0 })

    def normalBump(): Scene =
        let tex = bumpTexture();
        let plate = Scene3d.meshInstance(texturedQuad(-4.0, 4.0, -3.0, 3.0, 10.0, 0.0, 2.0), Mat4.identity())
            |> Scene3d.withMaterial(bumpMaterial(tex));
        let light = { position = Vec3.v3(-7.0, 1.0, 8.0), color = c8(255, 255, 255), intensity = 1.2, range = 20.0 };
        let base = flatScene({ x = 240.0, y = 140.0 }, 1, plate :: Nil, Nil);
        let scene = { textures = tex :: Nil, pointLights = light :: Nil, environment = { ambient = c8(40, 40, 40) | base#environment } | base };
        { name = "normalBump", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, scene) :: Nil }

    // ── scene 23: 骨で曲げた板の法線マップ（skinBend の板に uv と法線マップ）。B 段階 ──
    // タンジェントがジョイントの回転で曲がらないと、曲げた上半分の出っ張りの明暗の向きがずれる。

    /// skinPlate に uv を付けた物（左の辺が u = 0・右の辺が u = 1・上の端が v = 0 で、下へ 2.5 まで）。
    def skinPlateWithUvs(): Mesh3d.Mesh3d =
        let uvs = skinRows() |> List.flatMap(y -> { let v = (3.0 - y) / 6.0 * 2.5; 0.0 :: v :: 1.0 :: v :: Nil }) |> List.toVector;
        match Mesh3d.withUvs(uvs, skinPlate()) {
            case Ok(mesh) => mesh
            case Err(e)   => bug!(e)
        }

    def skinNormal(): Scene =
        let tex = bumpTexture();
        let back = shape(facingQuad(-8.0, 8.0, -6.0, 6.0, 20.0, c8(200, 200, 200)) :: Nil);
        let left = Scene3d.meshInstance(skinPlateWithUvs(), Mat4.translate(Vec3.v3(-2.5, 0.0, 0.0)))
            |> Scene3d.withMaterial(bumpMaterial(tex)) |> Scene3d.withPose(skinBendPose(0.7));
        let right = Scene3d.meshInstance(skinPlateWithUvs(), Mat4.translate(Vec3.v3(2.5, 0.0, 0.0)))
            |> Scene3d.withMaterial(stripeMaterial() |> Scene3d.withNormalMap({ texture = Texture3d.name(tex), strength = 1.0 }))
            |> Scene3d.withPose(skinBendPose(-0.7));
        let light = { position = Vec3.v3(-6.0, 2.0, 6.0), color = c8(255, 255, 255), intensity = 1.0, range = 20.0 };
        let scene = { instances = back :: left :: right :: Nil, spotLights = skinBendSpot() :: Nil, pointLights = light :: Nil,
                      textures = tex :: Nil, zIndex = 1,
                      environment = { ambient = c8(60, 60, 60), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(c8(10, 10, 30)) }
                      | Scene3d.scene(flatCamera(), { x = 240.0, y = 140.0 }) };
        { name = "skinNormal", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, scene) :: Nil }

    // ── scene 24〜26: 段つきの絵（mipmap。GL は sg_texMip と段つきの sampler・CPU は ShaderEval.evalMaterial3Mip）。B 段階 ──
    // 遠くまで伸びる床に、1 テクセルごとの濃淡の市松を貼る。段が効けば遠くは中間の灰に落ち着き、効かなければ市松がざらつく。
    // 素の uv（mipFloor）・Scaled で uv を何倍にもした座標（mipFloorScaled）・shared に書いた atWorld の world の座標（mipFloorWorld）の 3 通りで、
    // GL の dFdx と CPU の隣の画素の評価が同じ段を選ぶかを見る。

    /// 32 × 32 の、1 テクセルごとの明るい灰（170）と暗い灰（90）の市松。
    // WhyNot: 白黒の市松にしない — GPU は lod の小数と混ぜる重みを 8 bit ほどに丸めるので、段の境目の帯の画素が ±2 ずつ食い違い、
    //   段を 1 つ取り違えた時の差（灰の差の半分 ≈ ±40）との見分けが px の数でつかなくなる。濃淡を半分にすると丸めの差は ±1 以下に沈む。
    def checkerTexture(): Texture3d.Texture3d =
        let light = Int32.bitwiseOr(Int32.leftShift(255, 24), 170 * 65793);
        let dark = Int32.bitwiseOr(Int32.leftShift(255, 24), 90 * 65793);
        let pixels = Vector.range(0, 1024) |> Vector.map(k -> if (Int32.remainder(Int32.remainder(k, 32) + k / 32, 2) == 0) light else dark);
        match Texture3d.fromArgb(32, 32, pixels) {
            case Ok(t)  => t
            case Err(e) => bug!(e)
        }

    /// 目の少し下（y = −1.5）を奥へ伸びる床（x −8..8・z 1.5..60）。uvRepeat = Some(n) なら uv を x 方向に n・z 方向に n × 4 まで振る。
    def floorMesh(uvRepeat: Option[Float64]): Mesh3d.Mesh3d =
        let points = Vec3.v3(-8.0, -1.5, 1.5) :: Vec3.v3(-8.0, -1.5, 60.0) :: Vec3.v3(8.0, -1.5, 60.0) :: Vec3.v3(8.0, -1.5, 1.5) :: Nil;
        match uvRepeat {
            case None => Mesh3d.fromPolygons({ points = points, color = c8(255, 255, 255) } :: Nil)
            case Some(n) =>
                let uvs = { x = 0.0, y = n * 4.0 } :: { x = 0.0, y = 0.0 } :: { x = n, y = 0.0 } :: { x = n, y = n * 4.0 } :: Nil;
                match Mesh3d.fromTexturedPolygons({ points = points, uvs = uvs, color = c8(255, 255, 255) } :: Nil) {
                    case Ok(mesh) => mesh
                    case Err(e)   => bug!(e)
                }
        }

    def floorScene(name: String, mesh: Mesh3d.Mesh3d, material: Scene3d.Material3d, tex: Texture3d.Texture3d): Scene =
        let camera = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.2, fovY = 1.0, near = 1.0, far = 100.0 };
        let floor = Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(material);
        let scene = { instances = floor :: Nil, textures = tex :: Nil, zIndex = 1,
                      environment = { ambient = c8(255, 255, 255), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(c8(10, 10, 30)) }
                      | Scene3d.scene(camera, { x = 240.0, y = 140.0 }) };
        { name = name, via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, scene) :: Nil }

    /// 絵の r・g・b を f で包んで読む材質（f = 読む座標を変える場）。
    def checkerMaterial(name: String, wrapRead: ShaderDoc.Field -> ShaderDoc.Field, tex: Texture3d.Texture3d): Scene3d.Material3d =
        let read = (c: ShaderDoc.TexChan) -> wrapRead(ShaderDoc.Field.Tex({ name = Texture3d.name(tex), chan = c }));
        Scene3d.material({ name = name, cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = read(ShaderDoc.TexChan.R), g = read(ShaderDoc.TexChan.G),
                                                                                    b = read(ShaderDoc.TexChan.B) }),
                                                      alpha = ShaderDoc.Field.Const(1.0) }) })

    def mipFloor(): Scene =
        let tex = checkerTexture();
        floorScene("mipFloor", floorMesh(Some(4.0)), Scene3d.texturedMaterial(Texture3d.name(tex), ShaderDoc.FilterMode.Nearest), tex)

    def mipFloorScaled(): Scene =
        let tex = checkerTexture();
        let scaled = (f: ShaderDoc.Field) -> ShaderDoc.Field.Scaled({ factor = 4.0, scroll = { x = 0.0, y = 0.0 }, of = f });
        floorScene("mipFloorScaled", floorMesh(Some(1.0)), checkerMaterial("parity_mipScaled", scaled, tex), tex)

    def mipFloorWorld(): Scene =
        let tex = checkerTexture();
        let lit = ShaderDoc.atWorld((ShaderDoc.Axis3.X, ShaderDoc.Axis3.Z),
            ShaderDoc.Field.Scaled({ factor = 0.25, scroll = { x = 0.0, y = 0.0 }, of = ShaderDoc.Field.Tex({ name = Texture3d.name(tex), chan = ShaderDoc.TexChan.R }) }));
        let material = Scene3d.material({ name = "parity_mipWorld", cycleRate = 0.0, bindings = ("lit", lit) :: Nil,
                                          out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = ShaderDoc.Field.Ref("lit"), g = ShaderDoc.Field.Ref("lit"),
                                                                                                   b = ShaderDoc.Field.Ref("lit") }),
                                                                     alpha = ShaderDoc.Field.Const(1.0) }) });
        floorScene("mipFloorWorld", floorMesh(None), material, tex)

    // ── scene 27: Blender で書き出した絵つきの glb（Gltf.loadTextured → parts の材質と textures）。B 段階 ──
    // 板 A（4 × 4 の絵・左上が赤・NEAREST・法線マップ）と板 B（baseColorFactor の水色・材質なし）。glb の板の表は engine の +Z を向くので、
    // Y 軸まわりに半周させて目へ向ける。絵の左上の赤が画面の左上に来れば、uv の向きと X の反転がそろっている。

    /// assets の glb（engine/test/data と同じ物）を loadTextured で読む。
    // WhyNot: Scenes.all を IO にしない — 場面の宣言は GL と SoftRaster と名前の付け替えの 3 か所から何度も引く純粋な列で、
    //   1 枚の資材を読むために全部の呼び手の効果を広げることになる。読むのは小さな glb 1 つで、何度読んでも同じ物になる。
    def texturedModel(path: String): Model3d.Model3d =
        let loaded = unsafe IO { run Gltf.loadTextured(path) with Fs.FileRead.runWithIO };
        match loaded {
            case Ok(m)  => m
            case Err(e) => bug!(e)
        }

    /// model の parts を world で置き、材質のある part に材質を付ける。
    def placedParts(model: Model3d.Model3d, world: Mat4.Mat4): List[Scene3d.Instance3d] =
        model#parts |> List.map(part -> {
            let placed = Scene3d.meshInstance(part#mesh, world);
            match part#material {
                case Some(m) => Scene3d.withMaterial(m, placed)
                case None    => placed
            }
        })

    def gltfTextured(): Scene =
        let model = texturedModel("assets/textured_two_materials.glb");
        let world = Mat4.mul(Mat4.translate(Vec3.v3(0.0, -0.5, 4.0)), Mat4.rotateY(Num.pi()));
        let instances = placedParts(model, world);
        let light = { position = Vec3.v3(0.0, 2.0, 1.0), color = c8(255, 255, 255), intensity = 0.6, range = 10.0 };
        let base = flatScene({ x = 240.0, y = 140.0 }, 1, instances, Nil);
        let scene = { textures = model#textures, pointLights = light :: Nil,
                      environment = { ambient = c8(170, 170, 170) | base#environment } | base };
        { name = "gltfTextured", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, scene) :: Nil }

    // ── scene 28: 描き先の画素を基準にした Pass（RenderTarget.windowDescriptor）の中に 3D の場面を描き、後処理の面で画面に出す。B 段階 ──
    // GL は Target.pixelScale・CPU は RenderConfig#scale で寸法を決める（この harness はどちらも 1 なので design と同じ寸法）。
    // 基準の欄が描き出しの側（Render.passSpecsOf → HeadlessRender）と実機の側（renderPasses）の両方に届くかを、同じ絵で見る。
    def windowPass3d(): Scene =
        let red = shape(facingQuad(-3.0, 1.0, -2.0, 2.0, 10.0, c8(220, 30, 30)) :: Nil);
        let blue = shape(facingQuad(-8.0, 8.0, -6.0, 6.0, 20.0, c8(30, 60, 220)) :: Nil);
        let p: Render.Pass = { name = "w3d", clear = RenderTarget.LoadOp.Clear(c8(0, 0, 0)), items =
            Render.scene3d({ x = 40.0, y = 20.0 }, flatScene({ x = 240.0, y = 140.0 }, 1, red :: blue :: Nil, Nil)) :: Nil };
        { name = "windowPass3d", via = ShotVia.ViaScreen, repeats = 1, targets = Map#{ "w3d" => RenderTarget.windowDescriptor() },
          exact = false, passes = p :: Nil, items =
            Render.shaderFill(passthroughSpec("w3d"), { position = { x = 0.0, y = 0.0 }, size = { x = designW(), y = designH() } }, 0.0, 1) :: Nil }

    // ── scene 29: Rgba16Float の Pass（RenderTarget.withHdr）。A 段階 ──
    // Pass に Add の箱を重ね（180/255 × 2 ≈ 1.41・200/255 × 3 ≈ 2.35）、1 を超える色の面（1.5, 2.0, 0.25）を置き、本編の面が
    // 0.5 倍して読む。Rgba8Unorm なら 1 に切られて 128 になる所が 180・255 などになる（切っていないことを絵で示す）。
    // 値は half の丸めと 8bit の丸めがどちらの経路でも同じ側に落ちる数（×255 が .5 から離れる）にしてある。
    def hdrPassItems(): List[Render.PlacedItem] =
        let add = (x, y, w, h, c) -> at(x, y, RawDraw.box({ x = w, y = h }, c, 1) |> Render.blended(DrawCmd.BlendMode.Add));
        let bright: ShaderDoc.Spec = { name = "parity_bright", cycleRate = 0.0, bindings = Nil,
            out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = 1.5, g = 2.0, b = 0.25 }), alpha = ShaderDoc.Field.Const(1.0) }) };
        add(20.0, 20.0, 120.0, 60.0, c8(180, 90, 30)) ::
        add(20.0, 20.0, 120.0, 60.0, c8(180, 90, 30)) ::
        add(80.0, 50.0, 100.0, 80.0, c8(200, 200, 200)) ::
        add(80.0, 50.0, 100.0, 80.0, c8(200, 200, 200)) ::
        add(80.0, 50.0, 100.0, 80.0, c8(200, 200, 200)) ::
        at(220.0, 30.0, RawDraw.box({ x = 60.0, y = 40.0 }, c8(40, 120, 220), 1)) ::
        Render.shaderFill(bright, { position = { x = 200.0, y = 100.0 }, size = { x = 100.0, y = 60.0 } }, 0.0, 2) ::
        Nil

    /// name の絵の rgb を 0.5 倍して出す面（読み方は filter）。
    def halfReadSpec(name: String, filter: ShaderDoc.FilterMode): ShaderDoc.Spec =
        let read = chan -> ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, b = ShaderDoc.Field.Const(0.5),
            a = ShaderDoc.Field.Sampler({ filter = filter, of = ShaderDoc.Field.Tex({ name = name, chan = chan }) }) });
        { name = "parity_half_read", cycleRate = 0.0, bindings = Nil,
          out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = read(ShaderDoc.TexChan.R), g = read(ShaderDoc.TexChan.G),
                                                                   b = read(ShaderDoc.TexChan.B) }),
                                     alpha = ShaderDoc.Field.Const(1.0) }) }

    def hdrPass(): Scene =
        let p: Render.Pass = { name = "hdrP", clear = RenderTarget.LoadOp.Clear(c8(0, 0, 0)), items = hdrPassItems() };
        { name = "hdrPass", via = ShotVia.ViaScreen, repeats = 1,
          targets = Map#{ "hdrP" => RenderTarget.withHdr(RenderTarget.defaultDescriptor()) }, exact = true, passes = p :: Nil, items =
            Render.shaderFill(halfReadSpec("hdrP", ShaderDoc.FilterMode.Nearest),
                              { position = { x = 0.0, y = 0.0 }, size = { x = designW(), y = designH() } }, 0.0, 1) :: Nil }

    // ── scene 30: Window の基準・scale 0.5 の Rgba16Float の Pass を Linear と TexBlur で読む。B 段階（補間の重みの丸め）──
    def hdrWindowHalf(): Scene =
        let p: Render.Pass = { name = "hdrW", clear = RenderTarget.LoadOp.Clear(c8(0, 0, 0)), items = hdrPassItems() };
        let blurred = chan -> ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, b = ShaderDoc.Field.Const(0.5),
            a = ShaderDoc.Field.TexBlur({ name = "hdrW", chan = chan, radius = { x = 0.02, y = 0.035 }, taps = 8,
                                          amount = ShaderDoc.Field.Const(1.0) }) });
        let blurSpec: ShaderDoc.Spec = { name = "parity_hdr_blur", cycleRate = 0.0, bindings = Nil,
            out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = blurred(ShaderDoc.TexChan.R), g = blurred(ShaderDoc.TexChan.G),
                                                                     b = blurred(ShaderDoc.TexChan.B) }),
                                       alpha = ShaderDoc.Field.Const(1.0) }) };
        { name = "hdrWindowHalf", via = ShotVia.ViaScreen, repeats = 1,
          targets = Map#{ "hdrW" => RenderTarget.withHdr({ scale = 0.5 | RenderTarget.windowDescriptor() }) }, exact = false,
          passes = p :: Nil, items =
            Render.shaderFill(halfReadSpec("hdrW", ShaderDoc.FilterMode.Linear),
                              { position = { x = 0.0, y = 0.0 }, size = { x = 160.0, y = designH() } }, 0.0, 1) ::
            Render.shaderFill(blurSpec, { position = { x = 160.0, y = 0.0 }, size = { x = 160.0, y = designH() } }, 0.0, 1) :: Nil }

    // ── scene 31: 1 を超えた dst へ Multiply（Rgba16Float の Pass）。B 段階 ──
    // Add で ≈ 1.41 にした所へ 128/255 の箱を Multiply すると ≈ 0.71 が残る（Rgba8Unorm なら 1 に切られてから掛けて ≈ 0.5）。
    def hdrMultiply(): Scene =
        let add = at(20.0, 20.0, RawDraw.box({ x = 280.0, y = 140.0 }, c8(180, 180, 180), 1) |> Render.blended(DrawCmd.BlendMode.Add));
        let p: Render.Pass = { name = "hdrM", clear = RenderTarget.LoadOp.Clear(c8(0, 0, 0)), items =
            add :: add ::
            at(60.0, 40.0, RawDraw.box({ x = 120.0, y = 100.0 }, c8(128, 64, 255), 2) |> Render.blended(DrawCmd.BlendMode.Multiply)) :: Nil };
        { name = "hdrMultiply", via = ShotVia.ViaScreen, repeats = 1,
          targets = Map#{ "hdrM" => RenderTarget.withHdr(RenderTarget.defaultDescriptor()) }, exact = false, passes = p :: Nil, items =
            Render.shaderFill(halfReadSpec("hdrM", ShaderDoc.FilterMode.Nearest),
                              { position = { x = 0.0, y = 0.0 }, size = { x = designW(), y = designH() } }, 0.0, 1) :: Nil }

    // ── scene 32: 縮んだ Pass（scale 0.5 → 160 × 90 テクセル）を TexSize で 1 テクセルずつずらして読む。B 段階 ──
    // r は右へ 1 テクセル・g はそのまま・b は下へ 1 テクセルずらして読む。寸法を design（320 × 180）で取り違えると、ずらしが半分になって縁が 1 画素ずれる。
    def texSizeScaled(): Scene =
        let pass: Render.Pass = { name = "tszT", clear = RenderTarget.LoadOp.Clear(c8(16, 24, 40)), items = halfItems() };
        let texel = axis -> ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Div, a = ShaderDoc.Field.Const(1.0),
                                                   b = ShaderDoc.Field.TexSize({ name = "tszT", axis = axis }) });
        let read = (dx, dy, chan) -> ShaderDoc.Field.Shift({ dx = dx, dy = dy, of = ShaderDoc.Field.Tex({ name = "tszT", chan = chan }) });
        let zero = ShaderDoc.Field.Const(0.0);
        let spec: ShaderDoc.Spec = { name = "parity_texsize", cycleRate = 0.0, bindings = Nil,
            out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = read(texel(ShaderDoc.Axis.U), zero, ShaderDoc.TexChan.R),
                                                                     g = read(zero, zero, ShaderDoc.TexChan.G),
                                                                     b = read(zero, texel(ShaderDoc.Axis.V), ShaderDoc.TexChan.B) }),
                                       alpha = ShaderDoc.Field.Const(1.0) }) };
        { name = "texSizeScaled", via = ShotVia.ViaScreen, repeats = 1,
          targets = Map#{ "tszT" => { scale = 0.5 | RenderTarget.defaultDescriptor() } }, exact = false, passes = pass :: Nil, items =
            Render.shaderFill(spec, { position = { x = 0.0, y = 0.0 }, size = { x = designW(), y = designH() } }, 0.0, 1) :: Nil }

    // ── scene 33: Rgba16Float の Pass を AcesFitted（既定の露出・白の点）でトーンマップして画面へ。B 段階（曲線の式の float32 と float64 の丸め）──
    def tonemap(): Scene =
        let p: Render.Pass = { name = "tmP", clear = RenderTarget.LoadOp.Clear(c8(0, 0, 0)), items = hdrPassItems() };
        let spec = PostProcess.tonemapped(PostProcess.Tonemap.AcesFitted, PostProcess.defaultExposure(), PostProcess.defaultWhitePoint(),
                                          passthroughSpec("tmP"));
        { name = "tonemap", via = ShotVia.ViaScreen, repeats = 1,
          targets = Map#{ "tmP" => RenderTarget.withHdr(RenderTarget.defaultDescriptor()) }, exact = false, passes = p :: Nil, items =
            Render.shaderFill(spec, { position = { x = 0.0, y = 0.0 }, size = { x = designW(), y = designH() } }, 0.0, 1) :: Nil }

    // ── scene 34: 斜めの縁（Step の段々）を窓の画素の Pass に描き、FXAA の面で画面へ。B 段階（Linear の重みの丸め・明るさの比べの境目）──
    def fxaa(): Scene =
        let u = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U });
        let v = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.V });
        let lin = (cu, cv, k) -> ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Add, a = ShaderDoc.Field.Const(k),
            b = ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Add,
                a = ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, a = ShaderDoc.Field.Const(cu), b = u }),
                b = ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, a = ShaderDoc.Field.Const(cv), b = v }) }) });
        let edge = (field) -> ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Step, a = ShaderDoc.Field.Const(0.5), b = field });
        let jaggy: ShaderDoc.Spec = { name = "parity_jaggy", cycleRate = 0.0, bindings = Nil,
            out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = edge(lin(0.8, 0.35, 0.0)), g = edge(lin(-0.25, 0.9, 0.2)),
                                                                     b = ShaderDoc.Field.Const(0.3) }),
                                       alpha = ShaderDoc.Field.Const(1.0) }) };
        let p: Render.Pass = { name = "fxP", clear = RenderTarget.LoadOp.Clear(c8(0, 0, 0)), items =
            Render.shaderFill(jaggy, { position = { x = 0.0, y = 0.0 }, size = { x = designW(), y = designH() } }, 0.0, 1) :: Nil };
        { name = "fxaa", via = ShotVia.ViaScreen, repeats = 1,
          targets = Map#{ "fxP" => RenderTarget.windowDescriptor() }, exact = false, passes = p :: Nil, items =
            Render.shaderFill(PostProcess.fxaaSpec("fxP"), { position = { x = 0.0, y = 0.0 }, size = { x = designW(), y = designH() } }, 0.0, 1) :: Nil }

    // ── scene 35: ベイクした光（Scene3d.withLightmap → GL は unit 8 と frag の bakedLight・CPU は SoftRaster3d の同じ式）。B 段階 ──
    // 左右は同じ形・同じ材質で、lightmap の絵と intensity だけが違う（置いた物ごとの uniform の入れ直しが漏れると右が左の絵で出る）。
    // 環境光は白・hemisphere は 1 だが、lightmap つきの物には足さない（足すと板が白く飛ぶ）。点光源は右の板にだけ届く。
    // 板は 0.5 rad 上へ向けて法線の y を正にする（正面向きのままだと hemisphere × max(0, n.y) が 0 で、足しても絵に出ない）。

    /// 8 × 8 升の市松（明 200・暗 40 の灰。1 升 = 4 × 4 texel の 32 × 32）。brightFirst なら左上の升が明るい。
    // WhyNot: 1 升 = 1 texel の 8 × 8 にしない — 板（約 46 px）へ引き伸ばすと板の全部が Linear の明暗の坂になり、GPU の補間の重みの
    //   丸めの ±1 が板じゅうに散って、式の取り違えとの差が 4 倍ほどしか開かない。升の中を平らにして、±1 を升の境の帯に寄せる。
    def bakedChecker(brightFirst: Bool): Texture3d.Texture3d =
        let gray = (v: Int32) -> Int32.bitwiseOr(Int32.leftShift(255, 24), v * 65536 + v * 256 + v);
        let texel = (k: Int32) -> {
            let even = Int32.remainder(Int32.remainder(k, 32) / 4 + k / 128, 2) == 0;
            if (even == brightFirst) gray(200) else gray(40)
        };
        match Texture3d.fromArgb(32, 32, Vector.range(0, 1024) |> Vector.map(texel)) {
            case Ok(t)  => t
            case Err(e) => bug!(e)
        }

    /// mesh の 1 本目の uv に k を掛けた値を、2 本目の uv として付けた形。
    def withScaledUvs2(k: Float64, mesh: Mesh3d.Mesh3d): Mesh3d.Mesh3d =
        let uvs = Mesh3d.uvs(mesh) |> Option.getWithDefault(Vector.empty()) |> Vector.map(x -> x * k);
        match Mesh3d.withUvs2(uvs, mesh) {
            case Ok(m)  => m
            case Err(e) => bug!(e)
        }

    def lightmapBaked3d(): Scene =
        let tex = parityTexture();
        let left = bakedChecker(true);
        let right = bakedChecker(false);
        let mesh = withScaledUvs2(1.0, texturedQuad(-1.8, 1.8, -2.2, 2.2, 0.0, 0.0, 1.0));
        // WhyNot: 材質の絵を Linear で読まない — 板じゅうが albedo の坂になり、補間の丸めの ±1 が lightmap の差に混ざって見分けにくい。
        let material = Scene3d.texturedMaterial(Texture3d.name(tex), ShaderDoc.FilterMode.Nearest);
        let plateAt = (x: Float64, lm: Scene3d.Lightmap) ->
            Scene3d.meshInstance(mesh, Mat4.mul(Mat4.translate(Vec3.v3(x, 0.0, 10.0)), Mat4.rotateX(0.5)))
                |> Scene3d.withMaterial(material) |> Scene3d.withLightmap(lm);
        let plates = plateAt(-2.2, Scene3d.lightmap(Texture3d.name(left)))
            :: plateAt(2.2, { intensity = 1.6 | Scene3d.lightmap(Texture3d.name(right)) }) :: Nil;
        let light = { position = Vec3.v3(2.2, 0.5, 8.5), color = c8(255, 200, 150), intensity = 0.8, range = 3.0 };
        let base = flatScene({ x = 240.0, y = 140.0 }, 1, plates, Nil);
        let scene = { textures = tex :: left :: right :: Nil, pointLights = light :: Nil,
                      environment = { hemisphere = 1.0 | base#environment } | base };
        { name = "lightmapBaked3d", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, scene) :: Nil }

    // ── scene 36: 法線マップとベイクした光（normalBump の板に lightmap）。B 段階 ──
    // 法線マップは動く光（左の点光源）にだけ効くので、出っ張りの明暗は灯りの側だけに出て、市松のベイクした光は平らなまま足される。
    def lightmapNormal3d(): Scene =
        let tex = bumpTexture();
        let checker = bakedChecker(true);
        let plate = Scene3d.meshInstance(withScaledUvs2(0.5, texturedQuad(-4.0, 4.0, -3.0, 3.0, 10.0, 0.0, 2.0)), Mat4.identity())
            |> Scene3d.withMaterial(bumpMaterial(tex))
            |> Scene3d.withLightmap({ intensity = 0.5 | Scene3d.lightmap(Texture3d.name(checker)) });
        let light = { position = Vec3.v3(-7.0, 1.0, 8.0), color = c8(255, 255, 255), intensity = 1.2, range = 20.0 };
        let base = flatScene({ x = 240.0, y = 140.0 }, 1, plate :: Nil, Nil);
        let scene = { textures = tex :: checker :: Nil, pointLights = light :: Nil, environment = { ambient = c8(40, 40, 40) | base#environment } | base };
        { name = "lightmapNormal3d", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, scene) :: Nil }

    // ── scene 37: スポットの内側の角（SpotLight.innerFovY → GL は uSpotCone の y・CPU は SoftRaster3d の cone）。B 段階 ──
    // 真上から床を照らすスポット 2 本。左は innerFovY = fovY × 0.3（輪の縁が広くぼける）・右は None（fovY × 0.8 の今の縁）。
    // 内側の角を読み落とすと、左の輪が右と同じ狭い縁になる。

    def softEdgeSpot(x: Float64, innerFovY: Option[Float64]): Scene3d.SpotLight =
        { range = 20.0, innerFovY = innerFovY | Scene3d.spotLight(Vec3.v3(x, 6.0, 10.0), Vec3.v3(x, -2.0, 10.0), 1.0) }

    def spotSoftEdge3d(): Scene =
        let camera = { eye = Vec3.v3(0.0, 9.0, 1.0), yaw = 0.0, pitch = 0.9, fovY = 1.0, near = 1.0, far = 100.0 };
        let floor = shape(upQuad(-12.0, 12.0, 0.0, 22.0, -2.0, c8(200, 200, 200)) :: Nil);
        let scene = { instances = floor :: Nil, spotLights = softEdgeSpot(-4.0, Some(0.3)) :: softEdgeSpot(4.0, None) :: Nil, zIndex = 1,
                      environment = { ambient = c8(30, 30, 30), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(c8(10, 10, 30)) }
                      | Scene3d.scene(camera, { x = 320.0, y = 180.0 }) };
        { name = "spotSoftEdge3d", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 0.0, y = 0.0 }, scene) :: Nil }

    // ── scene 38: glb の emissive（loadTextured が emissive を emission にする）。B 段階 ──
    // assets の emissive_plates.glb（engine/test/data/testdata と同じ物）: 左は灰色の絵 × emissiveTexture（上の行が橙）× 強さ 2・
    // 右は uv の無い emissive だけの材質（頂点の色の材質 + 定数の emission）。環境光を暗くして、光るのが emission だけで見えるようにする。
    // emissive を読み落とすと、左の上の行と右の板が暗い灰色の面になる。
    def gltfEmissive3d(): Scene =
        let model = texturedModel("assets/emissive_plates.glb");
        let world = Mat4.mul(Mat4.translate(Vec3.v3(0.0, 0.0, 4.0)), Mat4.rotateY(Num.pi()));
        let base = flatScene({ x = 240.0, y = 140.0 }, 1, placedParts(model, world), Nil);
        let scene = { textures = model#textures, environment = { ambient = c8(40, 40, 40) | base#environment } | base };
        { name = "gltfEmissive3d", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, scene) :: Nil }

    // ── scene 39: 視錐台の外の置いた物を間引く（Scene3d.isOutsideFrustum）。B 段階 ──
    // 画面の中に同じ材質（同じプログラム）・同じ形の板 2 枚をぴったり重ねる（赤が先・青が後。深度が同じなので先に描いた赤が勝ち、青は見えない）。
    // 外（後ろ・左右・上・far の向こう）に同じ材質の板 200 枚を、中の 2 枚の前・間・後ろに挟む。GL が描いた数は 2（expectedDrawnOf）。
    // GL は材質の物をプログラムで並べ替えてから描く（安定でない並べ替え）。間引く物を並べる前に除くと、赤と青の順が入れ替わりうり、板が青くなる。
    def cullOffscreen3d(): Scene =
        let spec: ShaderDoc.Spec = { name = "parity:cull", cycleRate = 0.0, bindings = Nil, out = ShaderDoc.Out.Fill({
            shade = ShaderDoc.Shade.Rgb({ r = ShaderDoc.Field.VertexColor({ chan = ShaderDoc.TexChan.R }),
                                          g = ShaderDoc.Field.VertexColor({ chan = ShaderDoc.TexChan.G }),
                                          b = ShaderDoc.Field.VertexColor({ chan = ShaderDoc.TexChan.B }) }),
            alpha = ShaderDoc.Field.Const(1.0) }) };
        let painted = (quad: Mesh3d.Polygon) -> shape(quad :: Nil) |> Scene3d.withMaterial(Scene3d.material(spec));
        let red = painted(facingQuad(-3.0, 1.0, -1.5, 1.5, 10.0, c8(220, 30, 30)));
        let blue = painted(facingQuad(-3.0, 1.0, -1.5, 1.5, 10.0, c8(30, 60, 220)));
        let outside = List.range(0, 200) |> List.map(k -> {
            let offset = Int32.toFloat64(k);
            painted(match Int32.remainder(k, 5) {
                case 0 => facingQuad(-1.0, 1.0, -1.0, 1.0, -5.0 - offset, c8(30, 200, 30))
                case 1 => facingQuad(40.0 + offset, 42.0 + offset, -1.0, 1.0, 10.0, c8(30, 200, 30))
                case 2 => facingQuad(-42.0 - offset, -40.0 - offset, -1.0, 1.0, 10.0, c8(30, 200, 30))
                case 3 => facingQuad(-1.0, 1.0, 30.0 + offset, 32.0 + offset, 10.0, c8(30, 200, 30))
                case _ => facingQuad(-1.0, 1.0, -1.0, 1.0, 150.0 + offset, c8(30, 200, 30))
            })
        });
        let instances = List.flatten(List.take(70, outside) :: (red :: Nil) :: List.take(60, List.drop(70, outside)) :: (blue :: Nil) :: List.drop(130, outside) :: Nil);
        { name = "cullOffscreen3d", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, flatScene({ x = 240.0, y = 140.0 }, 1, instances, Nil)) :: Nil }

    // ── scene 40: 空のグラデーション（Scene3dCmd.sky → GL は空のプログラム・CPU は SoftRaster3d の skyFill）。B 段階 ──
    // 見下ろし 20°・天頂は濃い藍・地平は明るい橙・地面は暗い茶。地平（向きの y = 0）は画面の真ん中より上の
    // NDC の y = tan(20°) / tan(0.7)（場面の上から約 32 % の行）に来る。画角を広く取り、上の端で天頂の色へ寄る所まで写す。手前に赤い箱を 1 つ置き、空が物の後ろだけに出ることも見る。
    // 空の向きを取り違える（pitch の符号・縦横の比）と地平の行がずれ、天頂と地面の色の帯（数千 px）が丸ごと違う。
    def skyGradient3d(): Scene =
        let camera = { eye = Vec3.v3(0.0, 2.0, 0.0), yaw = 0.3, pitch = 20.0 * Num.pi() / 180.0, fovY = 1.4, near = 0.5, far = 100.0 };
        let box = shape(facingQuad(-1.0, 1.0, 0.5, 2.5, 8.0, c8(200, 40, 40)) :: Nil);
        let sky = Scene3d.gradientSky(c8(20, 30, 90), c8(240, 180, 120), c8(60, 40, 30)) |> Scene3d.withSkyCurve(0.7);
        let scene = { instances = box :: Nil, sky = Some(sky), zIndex = 1 | Scene3d.scene(camera, { x = 320.0, y = 180.0 }) };
        { name = "skyGradient3d", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 0.0, y = 0.0 }, scene) :: Nil }

    /// 色 c・α a の半透明の材質。
    def glassMaterial(name: String, c: Color, a: Float64): Scene3d.Material3d =
        Scene3d.material({ name = name, cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c), alpha = ShaderDoc.Field.Const(a) }) })
            |> Scene3d.withAlphaBlend(true)

    // ── scene 41: 窓ガラス（Scene3d.withAlphaBlend → GL は深度を書かない混ぜ・CPU は 2 段目）。B 段階 ──
    // 奥に不透明の緑の箱（の面）・その手前に青いガラス（α 0.5）・さらに手前に一部が重なる赤いガラス（α 0.4）。赤いガラスを先に渡す
    // （遠い順に並べ替えないと、赤の後に青を重ねて重なりの色が変わる）。左の半分は地の色の上（background）・右の半分は緑の面の上。
    // 深度を書くと、赤の後ろの青が欠ける。重ね方を取り違えると重なりの帯（数千 px）が丸ごと違う。
    // 右下の小さな場面は Design の解像度・地の色なしで、半分が 2D の白い箱に、半分が何も無い所に重なる赤いガラス
    // （GL は透明から描いた FBO を α を掛けた色として重ねる。Normal で重ねると何も無い所の赤が 2 回 α を掛けて暗くなる）。
    def glassPane3d(): Scene =
        let back = shape(facingQuad(0.0, 6.0, -3.0, 3.0, 20.0, c8(40, 200, 80)) :: Nil);
        let blue = shape(facingQuad(-4.0, 3.0, -2.5, 2.0, 14.0, c8(255, 255, 255)) :: Nil)
            |> Scene3d.withMaterial(glassMaterial("parity:glass:blue", c8(60, 100, 240), 0.5));
        let red = shape(facingQuad(-2.0, 1.0, -1.5, 2.5, 10.0, c8(255, 255, 255)) :: Nil)
            |> Scene3d.withMaterial(glassMaterial("parity:glass:red", c8(230, 60, 40), 0.4));
        let smallRed = shape(facingQuad(-3.0, 3.0, -3.0, 3.0, 10.0, c8(255, 255, 255)) :: Nil)
            |> Scene3d.withMaterial(glassMaterial("parity:glass:red", c8(230, 60, 40), 0.4));
        let small = flatScene({ x = 40.0, y = 40.0 }, 2, smallRed :: Nil, Nil);
        let designScene = { resolution = Scene3d.Resolution.Design, environment = { background = None | small#environment } | small };
        { name = "glassPane3d", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, flatScene({ x = 240.0, y = 140.0 }, 1, red :: back :: blue :: Nil, Nil)) ::
            at(270.0, 130.0, RawDraw.box({ x = 20.0, y = 40.0 }, c8(240, 240, 240), 1)) ::
            Render.scene3d({ x = 270.0, y = 130.0 }, designScene) :: Nil }

    // ── scene 42: 両面（Scene3d.withDoubleSided → GL は GL_CULL_FACE を切る・裏の面の法線を裏返す）。B 段階 ──
    // 裏をカメラへ向けた板 2 枚（左は両面・右は表だけ）。環境光は暗く、目の所に点光源。左の板は裏の面の法線を裏返すので照らされ、
    // 右の板は捨てられて地の色。裏返さないと左の板が環境光だけの暗い色になる。
    def doubleSided3d(): Scene =
        let backQuad = (x0: Float64, x1: Float64) -> { points = Vec3.v3(x1, -2.0, 10.0) :: Vec3.v3(x1, 2.0, 10.0) :: Vec3.v3(x0, 2.0, 10.0) :: Vec3.v3(x0, -2.0, 10.0) :: Nil,
                                                       color = c8(255, 255, 255) };
        let plateMaterial = (sides: Bool) -> Scene3d.material({ name = "parity:sides", cycleRate = 0.0, bindings = Nil,
            out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c8(220, 180, 60)), alpha = ShaderDoc.Field.Const(1.0) }) })
            |> Scene3d.withDoubleSided(sides);
        let left = shape(backQuad(-5.0, -0.5) :: Nil) |> Scene3d.withMaterial(plateMaterial(true));
        let right = shape(backQuad(0.5, 5.0) :: Nil) |> Scene3d.withMaterial(plateMaterial(false));
        let base = flatScene({ x = 240.0, y = 140.0 }, 1, left :: right :: Nil, Nil);
        let scene = { environment = { ambient = c8(30, 30, 30) | base#environment },
                      pointLights = { position = Vec3.zero(), color = c8(255, 255, 255), intensity = 1.0, range = 30.0 } :: Nil | base };
        { name = "doubleSided3d", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, scene) :: Nil }

    // ── scene 43: MSAA（RenderTarget.withMsaa(4) の Pass）。B 段階・GL の側だけが縁をならす ──
    // 窓の画素の Pass に、斜めの細い棒 3 本（手すり）と cutout の縞の板（金網・alpha to coverage）を描き、面で画面へ写す。
    // CPU は MSAA をしない（既存の 3D の行と同じ固い縁）ので、差は縁の画素だけに出る（minDiffOf と toleranceOf の間）。
    // withMsaa を外すと差は 0 px（Apple Silicon で測った）なので、下限 300 は MSAA が効いていない時を確実に拾う
    // （resolve し忘れ・標本の FBO を作れていない）。面の中まで違えば resolve の写し方か alpha to coverage の α が違う。
    def msaaEdges(): Scene =
        let bar = (x: Float64, tilt: Float64) -> { points = Vec3.v3(x, -4.0, 12.0) :: Vec3.v3(x + tilt, 4.0, 12.0)
                                                            :: Vec3.v3(x + tilt + 0.15, 4.0, 12.0) :: Vec3.v3(x + 0.15, -4.0, 12.0) :: Nil,
                                                   color = c8(230, 230, 230) };
        let rails = shape(bar(-6.0, 3.0) :: bar(-4.0, 2.0) :: bar(-2.0, 1.2) :: Nil);
        let net = shape(facingQuad(1.0, 7.0, -3.0, 3.0, 12.0, c8(255, 255, 255)) :: Nil) |> Scene3d.withMaterial(cutoutMaterial());
        let p: Render.Pass = { name = "msaaP", clear = RenderTarget.LoadOp.Clear(c8(0, 0, 0)), items =
            Render.scene3d({ x = 0.0, y = 0.0 }, flatScene({ x = 320.0, y = 180.0 }, 1, rails :: net :: Nil, Nil)) :: Nil };
        { name = "msaaEdges", via = ShotVia.ViaScreen, repeats = 1, targets = Map#{ "msaaP" => RenderTarget.withMsaa(4, RenderTarget.windowDescriptor()) },
          exact = false, passes = p :: Nil, items =
            Render.shaderFill(passthroughSpec("msaaP"), { position = { x = 0.0, y = 0.0 }, size = { x = designW(), y = designH() } }, 0.0, 1) :: Nil }

    // ── scene 44: 線形の光の重なり（色の絵の材質・点光源 2 本・光を当てるビルボード）。B 段階 ──
    // 象限ごとに色の違う絵（parityTexture）を貼った板を、左右から暖色と寒色の点光源で照らし、真ん中で 2 本の光を重ねる。
    // 手前に光を当てるビルボード（市松のアトラス）を 1 枚立てる。GL と CPU の片方だけ絵・光・ビルボードの色を線形へ戻し忘れると、
    // 板かビルボードの面が丸ごと違う（重なりの帯は線形と sRGB で明るさが一番違う所）。
    def linearOverlap3d(): Scene =
        let tex = parityTexture();
        let plate = Scene3d.meshInstance(texturedQuad(-6.0, 6.0, -4.0, 4.0, 14.0, 0.0, 1.0), Mat4.identity())
            |> Scene3d.withMaterial(Scene3d.texturedMaterial(Texture3d.name(tex), ShaderDoc.FilterMode.Nearest));
        let board = Scene3d.billboard("atlas", { position = { x = 0.0, y = 0.0 }, size = { x = 16.0, y = 16.0 } },
                                      Vec3.v3(0.0, -1.5, 11.0), { x = 2.4, y = 2.4 });
        let warm = { position = Vec3.v3(-1.8, 0.5, 12.2), color = c8(255, 190, 120), intensity = 1.4, range = 6.0 };
        let cool = { position = Vec3.v3(1.8, 0.5, 12.2), color = c8(120, 170, 255), intensity = 1.4, range = 6.0 };
        let base = flatScene({ x = 240.0, y = 140.0 }, 1, plate :: Nil, board :: Nil);
        let scene = { textures = tex :: Nil, pointLights = warm :: cool :: Nil,
                      environment = { ambient = c8(40, 40, 40) | base#environment } | base };
        { name = "linearOverlap3d", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, scene) :: Nil }

    /// 32 × 32 の、1 テクセルごとの白と黒の市松。
    def blackWhiteChecker(): Texture3d.Texture3d =
        let white = Int32.bitwiseOr(Int32.leftShift(255, 24), 255 * 65793);
        let black = Int32.leftShift(255, 24);
        let pixels = Vector.range(0, 1024) |> Vector.map(k -> if (Int32.remainder(Int32.remainder(k, 32) + k / 32, 2) == 0) white else black);
        match Texture3d.fromArgb(32, 32, pixels) {
            case Ok(t)  => t
            case Err(e) => bug!(e)
        }

    // ── scene 45: 白黒の市松の床を遠くまで（色の絵の mip の段を線形で平均する）。B 段階 ──
    // 遠くの段は白と黒の平均になる。線形で平均すると灰は 188（sRGB で平均すると 128）なので、GL と CPU の片方だけ
    // 平均の仕方が違うと、遠くの床の帯（数千 px）が ±60 ほど違う。白黒なので段の境目の帯の丸めの差は mipFloor より大きく出る。
    def mipSrgbAverage3d(): Scene =
        let tex = blackWhiteChecker();
        floorScene("mipSrgbAverage3d", floorMesh(Some(4.0)), Scene3d.texturedMaterial(Texture3d.name(tex), ShaderDoc.FilterMode.Nearest), tex)

    // ── scene 46: emission の強さ（Scene3d.withEmissionIntensity）。B 段階 ──
    // 暗い環境光の中に、同じ暗い橙の emission の板を 2 枚。左は強さ 40（glTF の emissive_strength 40 と同じ）・右は 1。
    // 線形へ戻した emission に強さを掛けるので、左は明るい橙（1 に切られない）・右はほぼ地の板の色。強さを読み落とすと左右が同じになり、
    // 線形へ戻す前に掛けると左が白く飛ぶ。
    def emissionIntensity3d(): Scene =
        let glow = (k: Float64) -> Scene3d.material({ name = "parity:emission", cycleRate = 0.0, bindings = Nil,
            out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c8(60, 60, 60)), alpha = ShaderDoc.Field.Const(1.0) }) })
            |> Scene3d.withEmission(ShaderDoc.Shade.Solid(c8(30, 12, 4)))
            |> Scene3d.withEmissionIntensity(k);
        let left = shape(facingQuad(-5.0, -0.5, -2.5, 2.5, 10.0, c8(255, 255, 255)) :: Nil) |> Scene3d.withMaterial(glow(40.0));
        let right = shape(facingQuad(0.5, 5.0, -2.5, 2.5, 10.0, c8(255, 255, 255)) :: Nil) |> Scene3d.withMaterial(glow(1.0));
        let base = flatScene({ x = 240.0, y = 140.0 }, 1, left :: right :: Nil, Nil);
        let scene = { environment = { ambient = c8(40, 40, 40) | base#environment } | base };
        { name = "emissionIntensity3d", via = ShotVia.ViaScreen, repeats = 1, targets = Map.empty(), exact = false, passes = Nil, items =
            Render.scene3d({ x = 40.0, y = 20.0 }, scene) :: Nil }
}
