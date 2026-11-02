// DrawHash — 1 コマの「描く命令」と、命令に出ない描き出しの入力を、1 本の SHA-256 に畳む（純粋）。
//
// 鍵が同じなら SoftRaster が書く PNG は 1 バイトも違わない、を約束する物。RenderCache がこの鍵で
// 塗った PNG をキャッシュに入れ、同じ鍵のコマは塗らずに写す。鍵の中身の一覧は docs/render-cache.md。
//
// 命令（Drawable・PolygonRenderCmd・SurfaceCmd）が持つテクスチャやフォントは名前とパスだけなので、
// 命令だけを畳むと「画像を描き直したのに同じ」と言う。命令の外の入力は `Inputs`（ファイルの中身・
// pass の画像の画素・エンジンの fpkg・JVM と OS の指紋）として RenderCache が読んで渡す。
pub mod DrawHash {
    import java.io.BufferedOutputStream
    import java.io.ByteArrayOutputStream
    import java.io.DataOutputStream
    import java.io.OutputStream
    import java.lang.{Double => JDouble}
    import java.lang.{Object => JObject}
    import java.security.DigestOutputStream
    import java.security.MessageDigest
    import java.util.Collections
    import java.util.HexFormat
    import java.util.IdentityHashMap
    import java.util.{Map => JMap}

    /// 鍵の中身（SHA-256 の 16 進 64 字）。外から作らせない — 作れるのは computeKey だけ。
    enum Digest(String)

    /// 1 コマの鍵。比べるときは `toHex` の字で比べる。
    pub type alias Key = Digest

    /// 鍵を 16 進の字へ（キャッシュのファイル名・知らせに使う）。
    pub def toHex(key: Key): String = match key {
        case Digest.Digest(hex) => hex
    }

    /// PNG の書き方。同じ画素でも書き方でバイト列が違うので鍵に入れる。
    pub enum PngEncoding with Eq, ToString {
        /// SoftRaster.render* の書き方（いつもフルカラー）。
        case Plain
        /// Filmstrip.renderFrame の書き方（256 色以下なら PNG-8）。動画のコマ・GIF のコマ。
        case Filmstrip
    }

    /// 命令に出ない入力の指紋。RenderCache が IO で読んで渡す（ここでは読まない）。
    /// - engine: エンジンの fpkg の SHA-256。空なら鍵を作らない（SoftRaster の版が分からない）
    /// - runtime: JVM と OS（Java2D の文字と縁の塗りは JDK・OS で変わりうる）
    /// - files: パス → ファイルの中身の SHA-256（無いファイルは "missing"）。`filesOf` の全部が要る
    /// - images: pass などの描き出し済み画像（extraImages）の名前 → 画素の SHA-256
    pub type alias Inputs = {
        engine = String,
        runtime = String,
        files = Map[String, String],
        images = Map[String, String]
    }

    /// 1 コマの描き出しに入る、ファイル以外の全部（SoftRaster.renderToImageCached の引数と同じ物）。
    pub type alias Frame = {
        req = SoftRaster.RasterReq,
        surfaces = List[SoftRaster.SurfaceCmd],
        extraFonts = Map[String, SoftRaster.FontEntry],
        fontAntialias = SoftRaster.FontAntialias
    }

    /// このコマの命令が名前で引く絵（Drawable のテクスチャ名・シェーダー面の tex 場・3D の場面のビルボードと材質の tex 場）。
    /// texturePath と extraImages のうち、鍵に入れるのはこの名前の物だけ。
    // WhyNot: texturePath の全部を入れない — 画像 1 枚を描き直すと、その画像を使わない絵まで
    // 全部塗り直しになる。引かない絵は SoftRaster が読んでも画素に出ない。
    pub def usedTextures(frame: Frame): Set[String] =
        let fromDrawables = frame#req#drawables |> List.map(DrawCmd.textureOf) |> List.toSet;
        let fromSurfaces = frame#surfaces |> List.flatMap(sc -> ShaderDoc.texNames(sc#spec)) |> List.toSet;
        let fromBillboards = frame#req#scenes
            |> List.flatMap(c -> c#scene#billboards |> List.map(b -> Scene3d.billboardFieldsOf(b)#texture))
            |> List.toSet;
        let fromMaterials = frame#req#scenes |> List.flatMap(c -> c#scene#instances |> List.flatMap(Scene3d.textureNamesOf)) |> List.toSet;
        Set.union(fromDrawables, Set.union(fromSurfaces, Set.union(fromBillboards, fromMaterials)))

    /// 鍵を作るのに中身の指紋が要るファイル（引く絵・既定の TTF・追加の TTF）。
    pub def filesOf(frame: Frame): List[String] =
        let used = usedTextures(frame);
        let textures = frame#req#texturePath |> Map.filterWithKey((name, _) -> Set.memberOf(name, used)) |> Map.valuesOf;
        let fonts = frame#extraFonts |> Map.valuesOf |> List.map(e -> e#ttf);
        (frame#req#fontTtf :: textures ::: fonts) |> List.distinct

    /// 字のアトラスを畳んだバイト列の覚え（同じアトラスの値 → そのバイト列）。1 回の描き出しの間だけ持ち、
    /// コマごとに同じアトラスを畳み直さない。中身は外から作らせない（freshAtlasCache だけ）。
    // WhyNot: アトラスの中身（グリフの表）で引かない — 引くための比較が畳むのと同じだけかかる。値は変わらない
    // （Flix の record と Map）ので、同じ参照なら同じバイト列になる。参照が違えば畳み直すだけで鍵は変わらない。
    enum AtlasMemo(JMap[JObject, Array[Int8, Static]])

    /// 字のアトラスを畳んだバイト列の覚え。RenderCache の Session が 1 つ持つ。
    pub type alias AtlasCache = AtlasMemo

    /// 空の覚え（糸をまたいで使ってよい）。
    pub def freshAtlasCache(): AtlasCache \ IO =
        AtlasMemo.AtlasMemo(Collections.synchronizedMap(new IdentityHashMap()))

    /// 覚えておくアトラスの数の上限。超えたら空にしてから入れる（コマごとにアトラスを作り直す呼び側で膨らませない）。
    def atlasCacheLimit(): Int32 = 64

    /// 1 コマの鍵。`inputs` に要るファイルの指紋が欠けている・エンジンの指紋が空なら None（塗るしかない）。
    // WhyNot: パスそのものは畳まない — compare の基準は別の場所の worktree で描くので、パスを
    // 入れると同じ絵でも鍵が揃わない。絵に効くのは中身なので、中身の指紋だけを入れる。
    // WhyNot: 座標を丸めない — 丸めた幅の中で画素が動いても同じ鍵になり、偽の緑になる。
    pub def computeKey(inputs: Inputs, encoding: PngEncoding, frame: Frame): Option[Key] =
        unsafe IO { keyWith(None, inputs, encoding, frame) }

    /// computeKey と同じ鍵（ビット単位で同じ）を、アトラスを畳んだバイト列を `cache` から引いて作る。
    pub def computeKeyCached(cache: AtlasCache, inputs: Inputs, encoding: PngEncoding, frame: Frame): Option[Key] \ IO =
        keyWith(Some(cache), inputs, encoding, frame)

    def keyWith(cache: Option[AtlasCache], inputs: Inputs, encoding: PngEncoding, frame: Frame): Option[Key] \ IO =
        let missing = filesOf(frame) |> List.exists(p -> not Map.memberOf(p, inputs#files));
        if (String.isEmpty(inputs#engine) or missing) None
        else Some(Digest.Digest(digestOf(cache, inputs, encoding, frame)))

    // ── 畳む ─────────────────────────────────────────────
    // 型ごとに全部の欄を名前つきで受ける（閉じた record の match・enum の全引数）。描き出しの入力に
    // 欄が増えるとここがコンパイルで止まり、鍵に入れ忘れたまま偽の緑になるのを防ぐ。

    def digestOf(cache: Option[AtlasCache], inputs: Inputs, encoding: PngEncoding, frame: Frame): String \ IO =
        let md = MessageDigest.getInstance("SHA-256");
        let buffered = new BufferedOutputStream(new DigestOutputStream(OutputStream.nullOutputStream(), md), 65536i32);
        let out = new DataOutputStream(buffered);
        putStr(out, "fge-drawhash/1");
        putStr(out, encodingName(encoding));
        putStr(out, inputs#engine);
        putStr(out, inputs#runtime);
        let used = usedTextures(frame);
        putFrame(out, cache, inputs, used, frame);
        let images = inputs#images |> Map.filterWithKey((name, _) -> Set.memberOf(name, used));
        putSize(out, Map.size(images));
        images |> Map.forEach((name, sha) -> { putStr(out, name); putStr(out, sha) });
        out.flush();
        HexFormat.of().formatHex(md.digest())

    def encodingName(encoding: PngEncoding): String = match encoding {
        case PngEncoding.Plain     => "plain"
        case PngEncoding.Filmstrip => "filmstrip"
    }

    def putFrame(out: DataOutputStream, cache: Option[AtlasCache], inputs: Inputs, used: Set[String], frame: Frame): Unit \ IO = match frame {
        case { req = req, surfaces = surfaces, extraFonts = extraFonts, fontAntialias = fontAntialias } =>
            putReq(out, cache, inputs, used, req);
            putSize(out, List.length(surfaces));
            surfaces |> List.forEach(putSurface(out));
            putSize(out, Map.size(extraFonts));
            extraFonts |> Map.forEach((name, entry) -> { putStr(out, name); putFontEntry(out, cache, inputs, entry) });
            // 本ごとの縁の表は空でない時だけ鍵に入れる（表を使わない絵の鍵は表を足す前と同じ）。
            if (Map.isEmpty(fontAntialias)) ()
            else {
                putStr(out, "fontAntialias");
                putSize(out, Map.size(fontAntialias));
                fontAntialias |> Map.forEach((name, smooth) -> { putStr(out, name); putBool(out, smooth) })
            }
    }

    def putReq(out: DataOutputStream, cache: Option[AtlasCache], inputs: Inputs, used: Set[String], req: SoftRaster.RasterReq): Unit \ IO = match req {
        case { drawables = drawables, polygons = polygons, design = design, scale = scale,
               background = background, texturePath = texturePath, fontTtf = fontTtf,
               fontAtlas = fontAtlas, outPath = _outPath, shapeAntialias = shapeAntialias,
               textAntialias = textAntialias, scenes = scenes } =>
            putVec2(out, design);
            out.writeInt(scale);
            putColor(out, background);
            let textures = texturePath |> Map.filterWithKey((name, _) -> Set.memberOf(name, used));
            putSize(out, Map.size(textures));
            textures |> Map.forEach((name, path) -> { putStr(out, name); putFile(out, inputs, path) });
            putFile(out, inputs, fontTtf);
            putAtlasCached(out, cache, fontAtlas);
            putBool(out, shapeAntialias);
            putBool(out, textAntialias);
            putSize(out, List.length(drawables));
            drawables |> List.forEach(putDrawable(out));
            putSize(out, List.length(polygons));
            polygons |> List.forEach(putPolygon(out));
            // 3D の場面は空でない時だけ鍵に入れる（場面の無い絵の鍵は場面の欄を足す前と同じ）。
            if (List.isEmpty(scenes)) ()
            else {
                putStr(out, "scenes");
                putSize(out, List.length(scenes));
                scenes |> List.forEach(putScene3d(out))
            }
    }

    def putScene3d(out: DataOutputStream, cmd: Scene3d.RenderCmd): Unit \ IO = match cmd {
        case { at = at, clip = clip, scene = scene } =>
            putVec2(out, at);
            putClip(out, clip);
            putSceneCmd(out, scene)
    }

    def putSceneCmd(out: DataOutputStream, scene: Scene3d.Scene3dCmd): Unit \ IO = match scene {
        case { size = size, camera = camera, instances = instances, billboards = billboards,
               pointLights = pointLights, spotLights = spotLights, environment = environment,
               resolution = resolution, output = output, zIndex = zIndex, time = time, textures = textures } =>
            out.writeDouble(time);
            putVec2(out, size);
            putCamera(out, camera);
            putSize(out, List.length(instances));
            instances |> List.forEach(i -> putInstance(out, Scene3d.instanceFieldsOf(i)));
            putSize(out, List.length(billboards));
            billboards |> List.forEach(b -> putBillboard(out, Scene3d.billboardFieldsOf(b)));
            putSize(out, List.length(pointLights));
            pointLights |> List.forEach(putPointLight(out));
            putSize(out, List.length(spotLights));
            spotLights |> List.forEach(putSpotLight(out));
            putEnvironment(out, environment);
            match resolution {
                case Scene3d.Resolution.Native => out.writeByte(0i32)
                case Scene3d.Resolution.Design => out.writeByte(1i32)
            };
            match output {
                case Scene3d.Output.Color    => out.writeByte(0i32)
                case Scene3d.Output.Depth(d) => out.writeByte(1i32); putF(out, d#near); putF(out, d#range)
            };
            out.writeInt(zIndex);
            putSceneTextures(out, textures)
    }

    // WhyNot: 絵の無い場面にも数を書かない — textures の欄を足す前の鍵の字を保ち、絵の無い場面のキャッシュの PNG を塗り直させない。
    // WhyNot: 画素を畳まない — 作る時に中身から求めた contentHash が中身の代わりになる（GL が絵を上げる鍵と同じ）。
    def putSceneTextures(out: DataOutputStream, textures: List[Texture3d.Texture3d]): Unit \ IO =
        if (List.isEmpty(textures)) ()
        else {
            out.writeByte(0x54);
            putSize(out, List.length(textures));
            textures |> List.forEach(t -> putStr(out, Texture3d.contentHash(t)))
        }

    def putCamera(out: DataOutputStream, c: Camera3d.Camera3d): Unit \ IO = match c {
        case { eye = eye, yaw = yaw, pitch = pitch, fovY = fovY, near = near, far = far } =>
            putVec3(out, eye);
            (yaw :: pitch :: fovY :: near :: far :: Nil) |> List.forEach(putF(out))
    }

    // WhyNot: メッシュの頂点を畳まない — 作る時に中身から求めた contentHash が中身の代わりになる（GL が頂点バッファを引く鍵と同じ）。
    def putInstance(out: DataOutputStream, i: Scene3d.InstanceFields): Unit \ IO = match i {
        case { mesh = mesh, world = world, tint = tint, material = material, pose = pose, lightmap = _ } =>
            putStr(out, Mesh3d.contentHash(mesh));
            Mat4.toColumns(world) |> Vector.forEach(putF(out));
            putColor(out, tint);
            match material {
                case None    => out.writeByte(0i32)
                case Some(m) => out.writeByte(1i32); putMaterial(out, m)
            };
            putPose(out, pose);
            putLightmap(out, Scene3d.lightmapOfFields(i))
    }

    // WhyNot: None にも印のバイトを書かない — lightmap の欄を足す前の鍵の字を保ち、lightmap の無い場面のキャッシュの PNG を塗り直させない。
    // WhyNot: 付けた lightmap の欄でなく lightmapOfFields を書く — 使わない lightmap（骨つき・2 本目の uv 無し）は絵に出ないので鍵も変えない。
    def putLightmap(out: DataOutputStream, lightmap: Option[Scene3d.Lightmap]): Unit \ IO = match lightmap {
        case None => ()
        case Some({ texture = texture, colorSpace = colorSpace, intensity = intensity, maxLevels = maxLevels }) =>
            out.writeByte(0x4c);
            putStr(out, texture);
            putStr(out, ToString.toString(colorSpace));
            putF(out, intensity);
            out.writeInt(maxLevels)
    }

    // WhyNot: None にも印のバイトを書かない — pose の欄を足す前の鍵の字を保ち、ジョイントの無い場面のキャッシュの PNG を塗り直させない。
    // WhyNot: skinningOf で落とす（バインドポーズで描く）pose も行列のまま書く — 落とすかは形と照らす判定で、鍵が別になるだけで絵は誤らない。
    def putPose(out: DataOutputStream, pose: Option[Pose3d.Pose3d]): Unit \ IO = match pose {
        case None => ()
        case Some(p) =>
            out.writeByte(1i32);
            putSize(out, Pose3d.jointCount(p));
            Pose3d.jointMatrices(p) |> Vector.forEach(m -> Mat4.toColumns(m) |> Vector.forEach(putF(out)))
    }

    // WhyNot: 法線マップの無い材質と Repeat にも印を書かない — 欄を足す前の鍵の字を保ち、前からある材質のキャッシュの PNG を塗り直させない。
    def putMaterial(out: DataOutputStream, m: Scene3d.Material3d): Unit \ IO = match Scene3d.materialFieldsOf(m) {
        case { spec = spec, params = params, cutout = cutout, emission = emission, normalMap = normalMap, wrap = wrap } =>
            putStr(out, ToString.toString(ShaderJson.toJson(spec)));
            putSize(out, Map.size(params));
            params |> Map.forEach((name, v) -> { putStr(out, name); putF(out, v) });
            putBool(out, cutout);
            match emission {
                case None        => out.writeByte(0i32)
                case Some(shade) => out.writeByte(1i32); putStr(out, ToString.toString(ShaderJson.toJson(shadeSpec(shade))))
            };
            normalMap |> Option.forEach(n -> { out.writeByte(0x4e); putStr(out, n#texture); putF(out, n#strength) });
            if (wrap == Scene3d.Wrap.Clamp) out.writeByte(0x43) else ()
    }

    /// Shade を 1 枚の Spec の Out に包む（JSON に書く口が Spec にしか無いため）。
    def shadeSpec(shade: ShaderDoc.Shade): ShaderDoc.Spec =
        { name = "emission", cycleRate = 0.0, bindings = Nil,
          out = ShaderDoc.Out.Fill({ shade = shade, alpha = ShaderDoc.Field.Const(1.0) }) }

    def putBillboard(out: DataOutputStream, b: Scene3d.BillboardFields): Unit \ IO = match b {
        case { texture = texture, regionRect = regionRect, position = position, size = size,
               anchor = anchor, tint = tint, lit = lit } =>
            putStr(out, texture);
            putRect(out, regionRect);
            putVec3(out, position);
            putVec2(out, size);
            putVec2(out, anchor);
            putColor(out, tint);
            putBool(out, lit)
    }

    def putPointLight(out: DataOutputStream, l: Scene3d.PointLight): Unit \ IO = match l {
        case { position = position, color = color, intensity = intensity, range = range } =>
            putVec3(out, position);
            putColor(out, color);
            putF(out, intensity);
            putF(out, range)
    }

    def putSpotLight(out: DataOutputStream, l: Scene3d.SpotLight): Unit \ IO = match l {
        case { position = position, target = target, fovY = fovY, color = color, intensity = intensity,
               range = range, shadow = shadow } =>
            putVec3(out, position);
            putVec3(out, target);
            putF(out, fovY);
            putColor(out, color);
            putF(out, intensity);
            putF(out, range);
            match shadow {
                case None => out.writeByte(0i32)
                case Some({ mapSize = mapSize, bias = bias, pcfRadius = pcfRadius, strength = strength }) =>
                    out.writeByte(1i32);
                    out.writeInt(mapSize);
                    putF(out, bias);
                    out.writeInt(pcfRadius);
                    putF(out, strength)
            }
    }

    def putEnvironment(out: DataOutputStream, e: Scene3d.Environment3d): Unit \ IO = match e {
        case { ambient = ambient, hemisphere = hemisphere, toonSteps = toonSteps, fog = fog, background = background } =>
            putColor(out, ambient);
            putF(out, hemisphere);
            out.writeInt(toonSteps);
            match fog {
                case None    => out.writeByte(0i32)
                case Some({ color = color, near = near, far = far }) =>
                    out.writeByte(1i32); putColor(out, color); putF(out, near); putF(out, far)
            };
            match background {
                case None    => out.writeByte(0i32)
                case Some(c) => out.writeByte(1i32); putColor(out, c)
            }
    }

    def putVec3(out: DataOutputStream, v: Vec3.Vec3): Unit \ IO = match v {
        case { x = x, y = y, z = z } => putF(out, x); putF(out, y); putF(out, z)
    }

    def putFile(out: DataOutputStream, inputs: Inputs, path: String): Unit \ IO =
        putStr(out, Map.get(path, inputs#files) |> Option.getWithDefault("missing"))

    def putDrawable(out: DataOutputStream, d: GameEngine.Drawable): Unit \ IO =
        let DrawCmd.Drawable.Drawable(tex, px, py, sx, sy, rot,
                                      cr, cg, cb, a, cen,
                                      uox, uoy, usx, usy, z,
                                      style, clip, blend, mask) = d;
        putStr(out, tex);
        (px :: py :: sx :: sy :: rot :: cr :: cg :: cb :: a :: uox :: uoy :: usx :: usy :: Nil)
            |> List.forEach(putF(out));
        putBool(out, cen);
        out.writeInt(z);
        putStyle(out, style);
        putClip(out, clip);
        putBlend(out, blend);
        putPaths(out, mask)

    def putStyle(out: DataOutputStream, style: Option[DrawCmd.BoxStyle]): Unit \ IO = match style {
        case None => out.writeByte(0i32)
        case Some(DrawCmd.BoxStyle.BoxStyle(rad, bw, br, bg, bb, ba,
                                            sr, sg, sb, sa, sw, sp, sd,
                                            kr, kg, kb, ka, kc)) =>
            out.writeByte(1i32);
            (rad :: bw :: br :: bg :: bb :: ba :: sr :: sg :: sb :: sa :: sw :: sp :: kr :: kg :: kb :: ka :: kc :: Nil)
                |> List.forEach(putF(out));
            out.writeInt(sd)
    }

    def putPolygon(out: DataOutputStream, p: GameEngine.PolygonRenderCmd): Unit \ IO = match p {
        case { vertices = vertices, color = color, alpha = alpha, zIndex = zIndex,
               clip = clip, blend = blend, grad = grad } =>
            putPath(out, vertices);
            putColor(out, color);
            putF(out, alpha);
            out.writeInt(zIndex);
            putClip(out, clip);
            putBlend(out, blend);
            // Some(Nil) と None は SoftRaster で縁の写りが違うので、別の字にする。
            match grad {
                case None        => out.writeByte(0i32)
                case Some(tints) =>
                    out.writeByte(1i32);
                    putSize(out, List.length(tints));
                    tints |> List.forEach(t -> match t {
                        case { color = c, alpha = ta } => putColor(out, c); putF(out, ta)
                    })
            }
    }

    def putSurface(out: DataOutputStream, s: SoftRaster.SurfaceCmd): Unit \ IO = match s {
        case { rect = rect, spec = spec, time = time, mask = mask, zIndex = zIndex, blend = blend } =>
            putRect(out, rect);
            // WhyNot: Spec を自前で畳まない — Field は 40 近い case の再帰 enum で、写しを持つと
            // case が増えた時に鍵だけ置き去りになる。往復テストのある正規の JSON に任せる。
            putStr(out, ToString.toString(ShaderJson.toJson(spec)));
            putF(out, time);
            putPaths(out, mask);
            out.writeInt(zIndex);
            putBlend(out, blend)
    }

    def putFontEntry(out: DataOutputStream, cache: Option[AtlasCache], inputs: Inputs, entry: SoftRaster.FontEntry): Unit \ IO = match entry {
        case { ttf = ttf, atlas = atlas } => putFile(out, inputs, ttf); putAtlasCached(out, cache, atlas)
    }

    /// putAtlas と同じバイト列を書く。覚えにあればそのバイト列を、無ければ畳んでから覚えて書く。
    def putAtlasCached(out: DataOutputStream, cache: Option[AtlasCache], atlas: FontAtlas): Unit \ IO = match cache {
        case None                         => putAtlas(out, atlas)
        case Some(AtlasMemo.AtlasMemo(m)) =>
            let ref: JObject = unchecked_cast(atlas as JObject);
            let hit: Array[Int8, Static] = m.get(ref);
            let bytes = if (not Object.isNull(hit)) hit else {
                let buf = new ByteArrayOutputStream();
                let tmp = new DataOutputStream(buf);
                putAtlas(tmp, atlas);
                tmp.flush();
                let fresh = buf.toByteArray();
                if (m.size() >= atlasCacheLimit()) m.clear() else ();
                discard m.put(ref, fresh);
                fresh
            };
            out.write(bytes, 0, Array.length(bytes))
    }

    def putAtlas(out: DataOutputStream, atlas: FontAtlas): Unit \ IO = match atlas {
        case { textureName = textureName, fontSize = fontSize, textureSize = textureSize,
               ascent = ascent, descent = descent, lineGap = lineGap, glyphs = glyphs } =>
            putStr(out, textureName);
            (fontSize :: textureSize :: ascent :: descent :: lineGap :: Nil) |> List.forEach(putF(out));
            putSize(out, Map.size(glyphs));
            glyphs |> Map.forEach((codepoint, g) -> { out.writeInt(codepoint); putGlyph(out, g) })
    }

    def putGlyph(out: DataOutputStream, g: TextLayout.GlyphMetrics): Unit \ IO = match g {
        case { xOff = xOff, yOff = yOff, glyphW = glyphW, glyphH = glyphH, advance = advance,
               s0 = s0, t0 = t0, s1 = s1, t1 = t1 } =>
            (xOff :: yOff :: glyphW :: glyphH :: advance :: s0 :: t0 :: s1 :: t1 :: Nil) |> List.forEach(putF(out))
    }

    def putBlend(out: DataOutputStream, blend: DrawCmd.BlendMode): Unit \ IO = match blend {
        case DrawCmd.BlendMode.Normal   => out.writeByte(0i32)
        case DrawCmd.BlendMode.Add      => out.writeByte(1i32)
        case DrawCmd.BlendMode.Multiply => out.writeByte(2i32)
    }

    def putClip(out: DataOutputStream, clip: Option[Rect2.Rect2]): Unit \ IO = match clip {
        case None    => out.writeByte(0i32)
        case Some(r) => out.writeByte(1i32); putRect(out, r)
    }

    def putRect(out: DataOutputStream, r: Rect2.Rect2): Unit \ IO = match r {
        case { position = position, size = size } => putVec2(out, position); putVec2(out, size)
    }

    def putPaths(out: DataOutputStream, paths: List[List[Vec2.Vec2]]): Unit \ IO =
        putSize(out, List.length(paths));
        paths |> List.forEach(putPath(out))

    def putPath(out: DataOutputStream, path: List[Vec2.Vec2]): Unit \ IO =
        putSize(out, List.length(path));
        path |> List.forEach(putVec2(out))

    def putVec2(out: DataOutputStream, v: Vec2.Vec2): Unit \ IO = match v {
        case { x = x, y = y } => putF(out, x); putF(out, y)
    }

    def putColor(out: DataOutputStream, c: Color): Unit \ IO = match c {
        case { r = r, g = g, b = b } => putF(out, r); putF(out, g); putF(out, b)
    }

    // ── 基本の値 ─────────────────────────────────────────
    // 字と列は長さを先に書く（"ab"+"c" と "a"+"bc" を別の鍵にする）。

    def putF(out: DataOutputStream, x: Float64): Unit \ IO = out.writeLong(JDouble.doubleToLongBits(x))

    def putBool(out: DataOutputStream, b: Bool): Unit \ IO = out.writeByte(if (b) 1i32 else 0i32)

    def putSize(out: DataOutputStream, n: Int32): Unit \ IO = out.writeInt(n)

    def putStr(out: DataOutputStream, s: String): Unit \ IO =
        let bytes = s.getBytes("UTF-8");
        out.writeInt(Array.length(bytes));
        out.write(bytes, 0, Array.length(bytes))
}
