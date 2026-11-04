// SoftRaster.Internal.Texture — 描き物が読む絵を集める: ファイルのテクスチャ・組み込みの放射テクスチャ・
// 3D の場面の材質と lightmap の絵の段（Mip）と、その欠けの知らせ。SoftRaster の中身。
// ゲームからは呼ばない（SoftRaster の中身。ゲームが使う関数は SoftRaster にある）。
pub mod SoftRaster.Internal.Texture {
    import java.awt.image.BufferedImage
    import java.io.File
    use SoftRaster.{TexWarnLog, TextureCache, cachedTexture, loadTexture, texDataOf, warnMissingTexture}

    /// 3D の場面のビルボードと材質が引く絵（(名前, 段の平均の色空間) → 段の列。段 0 が元の絵）。無い名前は Drawable と同じ文面で 1 度だけ知らせ、
    /// そのビルボードは描かない（材質の Tex は 0 で読む）。"tex3d:" の名前は場面の textures から引く。
    /// 材質・法線マップ・lightmap の絵は Mip.build の段まで作る（描き出したばかりの絵 = レンダーターゲットは段を作らない。GL と同じ）。
    /// 色空間は使い方から Texture3d.mipSpaceOf で決める（同じ名前を色の絵と法線マップに使うと 2 本の段になる）。
    /// ビルボードだけが読む絵は段 0 だけ（材質の絵の鍵に入れる）。材質の絵の組が Scene3d.maxMaterialTextures() を超えたら、材質の名前ごとに 1 度だけ知らせる。
    // WhyNot: 画素の Vector を場面ごとに作り直さない — 同じ絵を何枚ものビルボードと場面が引くので、名前ごとに 1 回だけ写す。
    pub def sceneTexturesOf(textures: Map[String, BufferedImage], mipSource: MipSource, warnLog: TexWarnLog,
                        scenes: List[Scene3d.RenderCmd]): Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]] \ IO =
        let ownTextures = scenes |> List.flatMap(c -> c#scene#textures) |> List.map(t -> (Texture3d.name(t), t)) |> List.toMap;
        let materials = scenes
            |> List.flatMap(c -> c#scene#instances |> List.filterMap(i -> Scene3d.instanceFieldsOf(i)#material))
            |> List.map(Scene3d.materialFieldsOf);
        scenes |> List.flatMap(c -> c#scene#instances) |> List.map(Scene3d.instanceFieldsOf) |> List.forEach(warnNormalMapWithoutUv(warnLog));
        scenes |> List.flatMap(c -> c#scene#instances) |> List.forEach(warnUnusedLightmap(warnLog));
        scenes |> List.flatMap(c -> Scene3d.droppedLightsWarnings(c#scene)) |> List.forEach(kl -> warnSceneOnce(warnLog, fst(kl), snd(kl)));
        let keyOf = (name: String, textureUse: Texture3d.TextureUse) -> (name, Texture3d.mipSpaceOf(textureUse));
        let lightmapKeys = scenes |> List.flatMap(c -> c#scene#instances |> List.filterMap(Scene3d.lightmapOf))
            |> List.map(lm -> keyOf(lm#texture, Texture3d.TextureUse.Lightmap(lm#colorSpace)));
        let materialKeys = materials |> List.flatMap(f -> {
            let reads = ShaderDoc.materialTexReads(f#spec, f#emission);
            warnTooManyMaterialTextures(warnLog, f#spec#name, List.length(reads));
            List.append(List.take(Scene3d.maxMaterialTextures(), reads) |> List.map(r -> keyOf(fst(r), Texture3d.TextureUse.MaterialTexture)),
                        f#normalMap |> Option.toList |> List.map(n -> keyOf(n#texture, Texture3d.TextureUse.NormalMap)))
        });
        let mippedKeys = List.append(materialKeys, lightmapKeys) |> List.distinct;
        // WhyNot: 材質も読む名前を lightmap の絵と呼ばない — GL は名前ごとに 1 回だけ知らせ、材質の絵として先に引く。
        let lightmapOnly = Set.difference(List.toSet(List.map(fst, lightmapKeys)), List.toSet(List.map(fst, materialKeys)));
        let billboardKeys = scenes |> List.flatMap(c -> c#scene#billboards |> List.map(b -> keyOf(Scene3d.billboardFieldsOf(b)#texture, Texture3d.TextureUse.MaterialTexture)));
        let lookup = (name: String) ->
            if (String.startsWith(prefix = Texture3d.namePrefix(), name))
                Map.get(name, ownTextures) |> Option.map(t ->
                    ({ width = Texture3d.width(t), height = Texture3d.height(t), pixels = Texture3d.argb(t) }, Some("tex3d:" + Texture3d.contentHash(t))))
            else Map.get(name, textures) |> Option.map(img -> (texDataOf(img), fileMipKey(mipSource, name)));
        let mippedSet = List.toSet(mippedKeys);
        let withMaterials = mippedKeys |> List.foldLeft((acc, key) -> match lookup(fst(key)) {
            case Some((td, cacheKey)) =>
                let rendered = Set.memberOf(fst(key), mipSource#rendered);
                Map.insert(key, if (rendered) Vector#{ td } else mipChainOf(mipSource#cache, cacheKey, Texture3d.mipAverageOf(snd(key)), td), acc)
            case None => warnMissingSceneTexture(warnLog, if (Set.memberOf(fst(key), lightmapOnly)) "lightmap の絵" else "材質の絵", fst(key)); acc
        }, Map.empty());
        billboardKeys |> List.distinct |> List.filter(key -> not Set.memberOf(key, mippedSet)) |> List.foldLeft((acc, key) -> match lookup(fst(key)) {
            case Some((td, _)) => Map.insert(key, Vector#{ td }, acc)
            case None          => warnMissingTexture(warnLog, fst(key)); acc
        }, withMaterials)

    /// 段を作る元の絵の出どころ。paths = 名前 → ファイル・rendered = 描き出したばかりの絵の名前（段を作らない）・cache = 書き出し 1 回の間の控え。
    pub type alias MipSource = { paths = Map[String, String], rendered = Set[String], cache = Option[TextureCache] }

    /// ファイルの絵の段の控えの鍵（パスと更新時刻。保存し直した絵は別の鍵になる）。ファイルでない絵は None（控えない）。
    def fileMipKey(mipSource: MipSource, name: String): Option[String] \ IO =
        Map.get(name, mipSource#paths) |> Option.map(path -> "file:" + path + ":" + Int64.toString(new File(path).lastModified()))

    /// td の段の列（average で平均する。cache と key があれば控えから引き、無ければ作って控える）。
    def mipChainOf(cache: Option[TextureCache], key: Option[String], average: Mip.Average, td: ShaderEval.TexData): Vector[ShaderEval.TexData] \ IO =
        match (cache, key) {
            case (Some(TextureCache.TextureCache(_, _, _, mips)), Some(k)) =>
                let averagedKey = k + ":" + ToString.toString(average);
                let hit: Vector[ShaderEval.TexData] = mips.get(averagedKey);
                if (not Object.isNull(hit)) hit
                else {
                    let chain = List.toVector(Mip.build(average, td));
                    discard mips.putIfAbsent(averagedKey, chain);
                    chain
                }
            case _ => List.toVector(Mip.build(average, td))
        }

    /// 3D の場面の材質・法線マップ・lightmap の絵 name が無いことを、名前ごとに 1 度だけ知らせる（label = 何の絵か。GL と同じ文面）。
    def warnMissingSceneTexture(warnLog: TexWarnLog, label: String, name: String): Unit \ IO =
        warnSceneOnce(warnLog, "@material-texture:" + name, "scene3d: ${label} '${name}' が見つからない — 0（黒・透明）で読む"
            + "（tex3d: の名前は場面の textures に、ほかは project.json の textures に同名の宣言があるか確認）")

    /// 付けたのに使わない lightmap（Scene3d.lightmapWarning）を、理由と形ごとに 1 度だけ知らせる（lightmap を使わず今の式で描く。GL と同じ）。
    def warnUnusedLightmap(warnLog: TexWarnLog, i: Scene3d.Instance3d): Unit \ IO =
        Scene3d.lightmapWarning(i) |> Option.forEach(line ->
            warnSceneOnce(warnLog, "@lightmap:" + line + Mesh3d.contentHash(Scene3d.instanceFieldsOf(i)#mesh), line))

    /// uv の無い形に法線マップの材質が付いていたら、形ごとに 1 度だけ知らせる（法線マップは当てずに描く。GL と同じ）。
    def warnNormalMapWithoutUv(warnLog: TexWarnLog, f: Scene3d.InstanceFields): Unit \ IO =
        let wants = f#material |> Option.exists(m -> Option.nonEmpty(Scene3d.materialFieldsOf(m)#normalMap));
        if (not wants or Option.nonEmpty(Mesh3d.uvs(f#mesh))) ()
        else warnSceneOnce(warnLog, "@normal-map-uv:" + Mesh3d.contentHash(f#mesh),
            "scene3d: uv の無い形に法線マップの材質が付いている — 法線マップを当てずに描く（Mesh3d.withUvs か withBoxUvs で uv を付ける）")

    /// 鍵 key の知らせを 1 度だけ出す（文面は GL と同じ物を呼ぶ側が渡す）。3D の場面の知らせはどれもここを通す。
    def warnSceneOnce(warnLog: TexWarnLog, key: String, line: String): Unit \ IO =
        if (Set.memberOf(key, Ref.get(warnLog))) ()
        else {
            Ref.put(Set.insert(key, Ref.get(warnLog)), warnLog);
            Log.warn(line)
        }

    def warnTooManyMaterialTextures(warnLog: TexWarnLog, specName: String, count: Int32): Unit \ IO =
        if (count <= Scene3d.maxMaterialTextures()) ()
        else warnSceneOnce(warnLog, "@material-textures:" + specName,
            "scene3d: 材質 '${specName}' が読む絵の組が ${count} 組ある — ${Scene3d.maxMaterialTextures()} 組目より後ろは 0 で描く")

    /// 組み込みの放射テクスチャ（Render.lightAt / darkAt が引く）の表。作るのは
    /// drawables がその名前を実際に使うときだけ — 256×256 の画素計算を毎フレームの
    /// 描き出しに無条件で払わせない（描き出しの画素ループは既知の性能の池）。
    pub def builtinRadialImages(drawables: List[GameEngine.Drawable]): Map[String, BufferedImage] \ IO =
        let usedOf = name -> List.exists(d -> DrawCmd.textureOf(d) == name, drawables);
        let withEntry = (name: String, pixelsOf: Unit -> Vector[Int32],
                         acc: Map[String, BufferedImage]) ->
            if (usedOf(name)) Map.insert(name, imageOfArgb(RadialBuiltin.size(), pixelsOf()), acc)
            else acc;
        withEntry(RadialBuiltin.darkName(), _ -> RadialBuiltin.darkPixels(),
            withEntry(RadialBuiltin.lightName(), _ -> RadialBuiltin.lightPixels(), Map.empty()))

    /// ARGB 画素列（行優先・size×size）を BufferedImage へ敷き詰める。
    def imageOfArgb(size: Int32, pixels: Vector[Int32]): BufferedImage \ IO = region rc {
        let s = Int32.max(1i32, size);
        let image = new BufferedImage(s, s, 2i32);
        let buf: Array[Int32, rc] = Array.empty(rc, s * s);
        Array.forEachWithIndex((i, _) -> Array.put(Vector.get(i, pixels), i, buf), buf);
        image.setRGB(0i32, 0i32, s, s, buf, 0i32, s);
        image
    }

    /// texturePath の各エントリを ImageIO で読み込む。読めないものは飛ばす。
    /// indexed / grayscale 等の色モデルは RescaleOp（drawTextured の tint）が扱えないため、
    /// 一律 ARGB へ正規化する。
    pub def loadTextures(paths: Map[String, String]): Map[String, BufferedImage] \ IO =
        Map.foldLeftWithKey((acc, name, path) -> match loadTexture(path) {
            case Some(img) => Map.insert(name, img, acc)
            case None      => acc
        }, (Map.empty(): Map[String, BufferedImage]), paths)

    /// loadTextures のキャッシュ版。同じパスは 1 回だけ読む（読み方は loadTextures と同じ）。
    pub def loadTexturesCached(cache: TextureCache, paths: Map[String, String]): Map[String, BufferedImage] \ IO =
        Map.foldLeftWithKey((acc, name, path) -> match cachedTexture(cache, path) {
            case Some(img) => Map.insert(name, img, acc)
            case None      => acc
        }, (Map.empty(): Map[String, BufferedImage]), paths)
}
