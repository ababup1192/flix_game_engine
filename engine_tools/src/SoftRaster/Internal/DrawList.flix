// SoftRaster.Internal.DrawList — 1 枚に描く物（Drawable・多角形・シェーダー面・3D の場面）を (z, 追加順) の 1 列に並べ、
// 読む絵とフォントを引いてから、種類ごとの描き手へ順に渡す（Rgba8Unorm と Rgba16Float の描き先の 2 本）。SoftRaster の中身。
// ゲームからは呼ばない（SoftRaster の中身。ゲームが使う関数は SoftRaster にある）。
pub mod SoftRaster.Internal.DrawList {
    import java.awt.image.BufferedImage
    import java.awt.Graphics2D
    import java.lang.System
    use SoftRaster.{FontAntialias, FontEntry, FontTable, HdrCanvas, PassImage, RItem, RasterReq, SurfaceCmd, TexWarnLog, TextureCache, hintsOf, texDataOf, texelsName, toArgbImage}
    use SoftRaster.Internal.Texture.{builtinRadialImages, loadTextures, loadTexturesCached, sceneTexturesOf}
    use SoftRaster.Internal.Text.{buildFontTable}
    use SoftRaster.Internal.Sprite.{applyQualityHints, drawDrawable, drawPolygon, withClip}
    use SoftRaster.Internal.Blend.{blendedDraw, drawableAabb, polygonAabb}
    use SoftRaster.Internal.Hdr.{blendedDrawHdr}
    use SoftRaster.Internal.Surface.{drawSurface, drawSurfaceHdr}
    use SoftRaster.Internal.Gradient.{drawGradPolygon, drawGradPolygonHdr}

    /// 1 枚を描くのに要る物（描き先の形式によらない）。textures = sprite・ビルボード・材質が読む 8bit の絵（Rgba16Float の Pass は 0..1 に切った物）・
    /// texEnv = 面の tex / blur の読み先の絵（Rgba16Float の Pass は切らない）・items = (z, 追加順) に並べた描き物。
    type alias DrawPlan = {
        textures = Map[String, BufferedImage],
        fonts = FontTable,
        texEnv = Map[String, ShaderEval.TexImage],
        sceneTextures = Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]],
        items = List[RItem]
    }

    /// 描く物を 1 列に並べ、読む絵を引いておく（drawAllInto と drawAllIntoHdr が同じこれを使う）。
    def planDraw(req: RasterReq, surfaces: List[SurfaceCmd],
                 extraFonts: Map[String, FontEntry], fontAntialias: FontAntialias,
                 extraImages: Map[String, PassImage],
                 warnLog: TexWarnLog, cache: Option[TextureCache]): DrawPlan \ IO =
        // 組み込みの放射テクスチャを土台に、ゲームのテクスチャ → extraImages の順で重ねる
        //（後から入れた方が勝つ。名前は `__` 予約なので実際に潰し合うことはない）。
        // GL 側は起動時に必ず GPU へ上げるため、描き出し側も配線ゼロで同じ名前が引けないと
        // 実機と描き出しの絵がずれる。
        let fileTextures = Map.foldLeftWithKey((acc, name, img) -> Map.insert(name, img, acc),
            builtinRadialImages(req#drawables),
            match cache {
                case Some(c) => loadTexturesCached(c, req#texturePath)
                case None    => loadTextures(req#texturePath)
            });
        let textures = Map.foldLeftWithKey((acc, name, img) -> Map.insert(name, img, acc),
            fileTextures, argbPassImages(argbReadNames(req), extraImages));
        let fctx = buildFontTable(cache, req, extraFonts, fontAntialias);
        // tex 場（Field.Tex）が読む画素表。surfaces が実際に使う名前だけ 1 回で Vector 化する —
        // 画素ループの中で BufferedImage を触らない（getRGB を毎画素呼ぶと桁で遅い）。
        // 無い名前は warnLog に控えて一度だけ知らせる（eval は純関数のまま黒 0.0 を返す）。
        let usedTexNames = surfaces
            |> List.flatMap(sc -> ShaderDoc.texNames(sc#spec))
            |> List.distinct;
        let texEnv = usedTexNames |> List.foldLeft((acc, name) -> {
            match texImageOf(fileTextures, extraImages, name) {
                case Some(img) => Map.insert(name, img, acc)
                case None =>
                    let warned = Ref.get(warnLog);
                    if (Set.memberOf(name, warned)) ()
                    else {
                        System.err.println("shader tex '${name}' が見つからない — 黒(0)で描く"
                            + "（pass なら passes に同名の宣言があるか確認）");
                        Ref.put(Set.insert(name, warned), warnLog)
                    };
                    acc
            }
        }, (Map.empty(): Map[String, ShaderEval.TexImage]));
        let sceneTextures = sceneTexturesOf(textures, { paths = req#texturePath, rendered = Map.keysOf(extraImages), cache = cache },
                                            warnLog, req#scenes);
        // Drawable / Polygon / シェーダー面を 1 列にまとめ、(z, 追加順) で安定ソートする。
        // Drawable は入口で 1 回だけ名前付きレコードへ展開する（描き出しは 1 枚きりの経路
        // なので、以降の細かな読み出しをフィールド名のまま書けるほうを取る）。
        let tagged = List.append(
            List.map(d -> RItem.RDraw(DrawCmd.toSpec(d)), req#drawables),
            List.append(
                List.map(p -> RItem.RPoly(p), req#polygons),
                List.append(
                    List.map(s -> RItem.RSurf(s), surfaces),
                    List.map(c -> RItem.RScene(c), req#scenes))));
        let sorted = tagged
            |> List.zipWithIndex
            |> List.sortBy(ix -> let (idx, item) = ix; (zOf(item), idx))
            |> List.map(ix -> let (_, item) = ix; item);
        { textures = textures, fonts = fctx, texEnv = texEnv, sceneTextures = sceneTextures, items = sorted }

    /// 面の tex / blur の読み先 name の絵。縮んだ Pass のテクセルの絵（texelsName）→ Pass の絵 → ファイルの絵の順に探す。
    def texImageOf(fileTextures: Map[String, BufferedImage], extraImages: Map[String, PassImage], name: String): Option[ShaderEval.TexImage] \ IO =
        let fromPass = Map.get(texelsName(name), extraImages) |> Option.withDefault(default = Map.get(name, extraImages));
        match fromPass {
            case Some(PassImage.Rgba8Unorm(img))  => Some(ShaderEval.TexImage.Rgba8Unorm(texDataOf(img)))
            case Some(PassImage.Rgba16Float(hdr)) => Some(ShaderEval.TexImage.Rgba16Float(hdr))
            case None => Map.get(name, fileTextures) |> Option.map(img -> ShaderEval.TexImage.Rgba8Unorm(texDataOf(img)))
        }

    /// 8bit の絵として読まれる名前（Drawable のテクスチャ・3D の場面のビルボードと材質の tex 場・法線マップ）。
    def argbReadNames(req: RasterReq): Set[String] =
        let fromDrawables = req#drawables |> List.map(DrawCmd.textureOf);
        let fromBillboards = req#scenes |> List.flatMap(c -> c#scene#billboards |> List.map(b -> Scene3d.billboardFieldsOf(b)#texture));
        let fromMaterials = req#scenes |> List.flatMap(c -> c#scene#instances |> List.flatMap(Scene3d.textureNamesOf));
        List.toSet(List.append(fromDrawables, List.append(fromBillboards, fromMaterials)))

    /// Pass の絵の 8bit の形（Rgba8Unorm はそのまま・Rgba16Float は names にある物だけ 0..1 に切って写す）。
    /// WhyNot: Rgba16Float の Pass を全部写さない — 1 枚の写しは全画素ぶんで、sprite で貼らない Pass（面だけが読む）にまで払うと桁で遅い。
    def argbPassImages(names: Set[String], extraImages: Map[String, PassImage]): Map[String, BufferedImage] \ IO =
        Map.foldLeftWithKey((acc, name, img) -> match img {
            case PassImage.Rgba8Unorm(argb) => Map.insert(name, argb, acc)
            case PassImage.Rgba16Float(_)  => if (Set.memberOf(name, names)) Map.insert(name, toArgbImage(img), acc) else acc
        }, Map.empty(), extraImages)

    /// 描画本体（z 合流 + 種類ごとの分岐）。背景を塗る/塗らないの違いは入口関数側に置き、
    /// ここを二重実装しない — 分岐の式が 2 か所に割れると、片方だけ直して絵が食い違う。
    /// texels = 縮んだターゲットへ拾う時のテクセル寸法（Some なら面は「その画素を拾うテクセルの点」で評価し、拾われない画素は飛ばす）。
    pub def drawAllInto(image: BufferedImage, req: RasterReq, surfaces: List[SurfaceCmd],
                    extraFonts: Map[String, FontEntry], fontAntialias: FontAntialias,
                    extraImages: Map[String, PassImage],
                    warnLog: TexWarnLog, cache: Option[TextureCache],
                    texels: Option[(Int32, Int32)]): Unit \ IO = region rc {
        let sf = Int32.toFloat64(req#scale);
        let plan = planDraw(req, surfaces, extraFonts, fontAntialias, extraImages, warnLog, cache);
        let textures = plan#textures;
        let fctx = plan#fonts;
        let g: Graphics2D = image.createGraphics();
        applyQualityHints(g, hintsOf(req));
        // blend=Normal は従来どおり Graphics2D（SrcOver）で直接描く。Add / Multiply は
        // Java2D の標準 Composite に無い重ね方なので、下書きへ描いてから自前の式で合成する。
        // シェーダー面は Graphics2D を使わず、ShaderEval の画素評価 + blendPixel で直接混ぜる。
        List.forEach(item -> match item {
            case RItem.RDraw(d)  =>
                if (d#blend == DrawCmd.BlendMode.Normal)
                    withClip(g, sf, d#clip, () -> drawDrawable(g, sf, textures, fctx, d, warnLog))
                else
                    blendedDraw(image, sf, hintsOf(req), d#blend, d#clip, drawableAabb(req#design, textures, d),
                                gs -> drawDrawable(gs, sf, textures, fctx, d, warnLog))
            case RItem.RPoly(p) =>
                if (not Option.isEmpty(p#grad))
                    drawGradPolygon(image, sf, req#design, p)
                else if (p#blend == DrawCmd.BlendMode.Normal)
                    withClip(g, sf, p#clip, () -> drawPolygon(rc, g, sf, p))
                else
                    blendedDraw(image, sf, hintsOf(req), p#blend, p#clip, polygonAabb(req#design, p),
                                gs -> drawPolygon(rc, gs, sf, p))
            case RItem.RSurf(s) => drawSurface(image, sf, plan#texEnv, texels, s)
            case RItem.RScene(c) => SoftRaster3d.drawScene(image, sf, plan#sceneTextures, c#scene#time, c)
        }, plan#items);
        g.dispose()
    }

    /// drawAllInto の Rgba16Float の描き先版。字・箱・多角形・sprite は Normal も含めて 1 つずつ 8bit の下書きに描き、
    /// blendPixelF で混ぜる（Graphics2D は描き先の float の値を触らない）。面と 3D は値を切らずに書き込みの決まり（writeRule）で混ぜる。
    /// 下書きは 0..1 なので、色が 1 を超える sprite は切られ、1 つの描き物の中の重なりは 8bit に丸めてから混ぜる（GL との近似）。
    pub def drawAllIntoHdr(canvas: HdrCanvas, req: RasterReq, surfaces: List[SurfaceCmd],
                       extraFonts: Map[String, FontEntry], fontAntialias: FontAntialias,
                       extraImages: Map[String, PassImage],
                       warnLog: TexWarnLog, texels: Option[(Int32, Int32)]): Unit \ IO = region rc {
        let sf = Int32.toFloat64(req#scale);
        let plan = planDraw(req, surfaces, extraFonts, fontAntialias, extraImages, warnLog, None);
        let textures = plan#textures;
        let fctx = plan#fonts;
        let hints = hintsOf(req);
        List.forEach(item -> match item {
            case RItem.RDraw(d)  =>
                blendedDrawHdr(canvas, sf, hints, d#blend, d#clip, drawableAabb(req#design, textures, d),
                               gs -> drawDrawable(gs, sf, textures, fctx, d, warnLog))
            case RItem.RPoly(p) =>
                if (not Option.isEmpty(p#grad))
                    drawGradPolygonHdr(canvas, sf, req#design, p)
                else
                    blendedDrawHdr(canvas, sf, hints, p#blend, p#clip, polygonAabb(req#design, p),
                                   gs -> drawPolygon(rc, gs, sf, p))
            case RItem.RSurf(s) => drawSurfaceHdr(canvas, sf, plan#texEnv, texels, s)
            case RItem.RScene(c) => SoftRaster3d.drawSceneHdr(canvas#rgba, (canvas#width, canvas#height), sf, plan#sceneTextures, c#scene#time, c)
        }, plan#items)
    }

    /// z 値取り出し（Drawable / Polygon / シェーダー面 / 3D の場面）。
    def zOf(item: RItem): Int32 =
        match item {
            case RItem.RDraw(d) => d#zIndex
            case RItem.RPoly(p) => p#zIndex
            case RItem.RSurf(s) => s#zIndex
            case RItem.RScene(c) => c#scene#zIndex
        }
}
