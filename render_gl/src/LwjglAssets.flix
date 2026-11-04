// LwjglAssets — デスクトップの素材の読み込み（RenderPaint.AssetLoader の LWJGL 版）。画像は stb で読み、字は stb で距離場を作って
// （RenderFont・RenderFontCache・RenderGlyphGrow）、GPU へ上げるのは本体の RenderTexture に任せる。
// 窓ありの描き手（LwjglLayer）も窓なしの描き手（GlOffscreen）も同じ物を渡す。
mod LwjglAssets {
    import fge.gl.GlContext
    import org.lwjgl.stb.STBImage
    import org.lwjgl.system.MemoryStack

    /// 塗りのコアへ渡す読み込みの口。
    pub def loader(): RenderPaint.AssetLoader =
        { loadTextures = loadTextureRegistry, loadFonts = loadFonts }

    /// PNG/JPG など stb が読める画像を読み、GPU へ上げる。NEAREST フィルタ + REPEAT ラップ (ピクセルアート前提)。
    pub def loadTexture(gl: GlContext, path: String, alpha: Bool): RenderAsset.TextureInfo \ IO =
        let stack = MemoryStack.stackPush();
        let w = stack.mallocInt(1);
        let h = stack.mallocInt(1);
        let c = stack.mallocInt(1);
        STBImage.stbi_set_flip_vertically_on_load(false);
        let channels = if (alpha) 4 else 3;
        let data = STBImage.stbi_load(path, w, h, c, channels);
        if (Object.isNull(data)) {
            discard MemoryStack.stackPop();
            bug!("Failed to load texture: ${path}")
        } else {
            let info = RenderTexture.uploadBytes(gl, { width = w.get(0), height = h.get(0), alpha = alpha }, data);
            STBImage.stbi_image_free(data);
            discard MemoryStack.stackPop();
            info
        }

    /// テクスチャマニフェストから全テクスチャを読み込み、論理名 → TextureInfo の
    /// マップを返す。onProgress には「読み終えた枚数 / 全枚数」を渡す（起動画面が進み具合を出す）。
    pub def loadTextureRegistry(gl: GlContext, manifest: List[RenderAsset.TextureEntry],
                                onProgress: (Int32, Int32) -> Unit \ IO): RenderAsset.TextureRegistry \ IO =
        let total = List.length(manifest);
        onProgress(0, total);
        let result = List.foldLeft((acc, entry) -> {
            let (registry, done) = acc;
            let texInfo = loadTexture(gl, entry#path, entry#hasAlpha);
            println("  ${entry#path} loaded (${texInfo#width}x${texInfo#height})");
            onProgress(done + 1, total);
            (Map.insert(entry#name, texInfo, registry), done + 1)
        }, (Map.empty(), 0), manifest);
        fst(result)

    /// ゲームのフォントのアトラスを作って上げ、registry に足す。起動時に用意しなかった字を後から足す関数も返す。
    pub def loadFonts(gl: GlContext, request: RenderPaint.FontRequest,
                      progress: (String, Int32, Int32) -> Unit \ IO): RenderPaint.FontsLoaded \ IO =
        // このゲームが出しうる字を先に集める（数十ミリ秒）。フォントが持つ字を全部用意すると
        // 日本語 1 本で数千〜2万字になり、起動が数十秒止まる。
        let wantedGlyphs = RenderFont.startupGlyphs(request#rootDir, request#glyphs);
        Option.forEach(cps -> println("[RenderFont] このゲームが出しうる字: ${Set.size(cps)} 字"),
                       wantedGlyphs);
        println("Baking font atlases...");
        // 文言はフォントごとに 1 回だけ組み立てる（進捗は字ごとに数千回来る）。
        let fontPhases: Ref[Map[String, String], Static] = Ref.fresh(Static, Map.empty());
        let fontPhaseOf = (name: String) -> match Map.get(name, Ref.get(fontPhases)) {
            case Some(text) => text
            case None =>
                let text = "loading font ${name}...";
                Ref.put(Map.insert(name, text, Ref.get(fontPhases)), fontPhases);
                text
        };
        let (atlases, registry) = RenderFont.bakeFontAtlases(gl, request#manifest, request#registry,
            wantedGlyphs, (name, done, total) -> progress(fontPhaseOf(name), done, total));
        let growTable = RenderGlyphGrow.newTable();
        List.forEach(entry -> registerGrowth(growTable, atlases, registry, entry), request#manifest);
        { atlases = atlases, registry = registry,
          grow = (g, atlas, cps) -> RenderGlyphGrow.ensure(g, growTable, atlas, cps) }

    /// 1 本のフォントを、後から字を足せるように登録する（アトラスか、その画像が無ければ 1 行言うだけ）。
    def registerGrowth(growTable: Ref[Map[String, RenderGlyphGrow.Font], Static], atlases: Map[String, FontAtlas],
                       registry: RenderAsset.TextureRegistry, entry: RenderAsset.FontEntry): Unit \ IO =
        match Map.get(entry#name, atlases) {
            case None =>
                Log.warn("font: フォント '${entry#name}' のアトラスが用意できていない"
                    + " — 起動時に用意しなかった字は後から足せない（project.json の fonts の path を確認）")
            case Some(atlas) => registerAtlas(growTable, registry, entry, atlas)
        }

    def registerAtlas(growTable: Ref[Map[String, RenderGlyphGrow.Font], Static], registry: RenderAsset.TextureRegistry,
                      entry: RenderAsset.FontEntry, atlas: FontAtlas): Unit \ IO =
        match Map.get(atlas#textureName, registry) {
            case None =>
                Log.warn("font: フォント '${entry#name}' のアトラス画像"
                    + " '${atlas#textureName}' が registry に無い"
                    + " — 起動時に用意しなかった字は後から足せない")
            case Some(texInfo) =>
                RenderGlyphGrow.register(growTable, atlas,
                    { path = entry#path, texId = GpuHandle.textureIdInt(texInfo#id) })
        }
}
