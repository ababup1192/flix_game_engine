// WebAssets — ブラウザの素材の読み込み（RenderPaint.AssetLoader のブラウザ版）。画像は fge-web.js が createImageBitmap で解いた物を
// JS の中で上げ、字は書き出しの道具が事前生成したアトラス（RenderFontCache の形式）を素材の表から読んで上げる。
// ブラウザに stb は無いので、起動時に用意しなかった字は足せない（足りない字はフォントごとに 1 度だけ知らせる）。
mod WebAssets {
    import fge.gl.GlConst
    import fge.gl.GlContext
    import fge.web.AssetTable
    import fge.web.Deferred
    import fge.web.WebImages
    import java.lang.StringBuilder

    /// 塗りのコアへ渡す読み込みの API。
    pub def loader(): RenderPaint.AssetLoader =
        { loadTextures = loadTextures, loadFonts = loadFonts }

    /// 事前生成したアトラスを素材の表に置く道（project.json からの相対）。書き出しの道具も同じ道へ置く。
    pub def atlasPathOf(entry: RenderAsset.FontEntry): String = "font-atlas/${entry#name}.fontatlas"

    /// 絵を全部上げる。表に無い絵は起動時に要る素材なので止める（デスクトップの stb と同じ扱い）。
    /// 後回しの絵（web.deferred）は、もう届いていれば上げ、まだなら飛ばす（届いた時に WebLayer が登録する）。
    def loadTextures(gl: GlContext, manifest: List[RenderAsset.TextureEntry],
                     onProgress: (Int32, Int32) -> Unit \ IO): RenderAsset.TextureRegistry \ IO =
        let total = List.length(manifest);
        onProgress(0, total);
        let registry = List.zipWithIndex(manifest) |> List.foldLeft((acc, indexed) -> {
            let (index, entry) = indexed;
            let next = if (Deferred.isDeferred(entry#path) and not WebImages.has(entry#path)) acc
                else Map.insert(entry#name, uploadImageOf(gl, entry), acc);
            onProgress(index + 1, total);
            next
        }, Map.empty());
        markDeferredLoaded(manifest |> List.filter(e -> Map.memberOf(e#name, registry)));
        registry

    /// 登録した絵のうち後回しの道を、道ごとに 1 回 fge-web.js に知らせる。
    // WhyNot: 名前ごとに知らせない — 知らせた後に fge-web.js が ImageBitmap を捨てるので、同じ道の 2 つ目の名前が上げられなくなる。
    def markDeferredLoaded(entries: List[RenderAsset.TextureEntry]): Unit \ IO =
        entries |> List.map(e -> e#path) |> List.distinct |> List.filter(path -> Deferred.isDeferred(path)) |> List.forEach(path -> Deferred.markLoaded(path))

    /// 解いておいた絵 1 枚を、宣言の hasAlpha で上げる。
    pub def uploadImageOf(gl: GlContext, entry: RenderAsset.TextureEntry): RenderAsset.TextureInfo \ IO =
        uploadImage(gl, entry#path, entry#hasAlpha)

    /// 解いておいた画像 1 枚を上げる。NEAREST フィルタ + REPEAT（RenderTexture.uploadBytes と同じ）。
    def uploadImage(gl: GlContext, path: String, alpha: Bool): RenderAsset.TextureInfo \ IO =
        if (not WebImages.has(path)) bug!("Failed to load texture: ${path}（書き出しの束に無い）")
        else {
            let texId = gl.createTexture();
            gl.bindTexture(GlConst.TEXTURE_2D, texId);
            WebImages.texImage(path, alpha);
            gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_WRAP_S, GlConst.REPEAT);
            gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_WRAP_T, GlConst.REPEAT);
            gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MIN_FILTER, GlConst.NEAREST);
            gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MAG_FILTER, GlConst.NEAREST);
            { id = GpuHandle.wrapTextureId(texId), width = Int32.toFloat64(WebImages.width(path)),
              height = Int32.toFloat64(WebImages.height(path)) }
        }

    /// 事前生成したアトラスを読んで上げる。読めないフォントは 1 行言って飛ばす（RenderPaint.fontAtlas が組み込みフォントで代わりに出す）。
    // WhyNot: 無いアトラスで止めない — デスクトップ（LwjglAssets）も字を作れないフォントは知らせて組み込みフォントで続ける。漏れは書き出しの門で止める。
    def loadFonts(gl: GlContext, request: RenderPaint.FontRequest,
                  progress: (String, Int32, Int32) -> Unit \ IO): RenderPaint.FontsLoaded \ IO =
        let total = List.length(request#manifest);
        let pending = pendingFontsOf(request#manifest);
        let (atlases, registry, _) = List.foldLeft((acc, entry) -> {
            let (atlasesSoFar, registrySoFar, done) = acc;
            progress("loading font ${entry#name}...", done, total);
            match (if (List.exists(p -> p#name == entry#name, pending)) None else loadAtlas(gl, entry)) {
                case Some((atlas, info)) =>
                    (Map.insert(entry#name, atlas, atlasesSoFar), Map.insert(atlas#textureName, info, registrySoFar), done + 1)
                case None => (atlasesSoFar, registrySoFar, done + 1)
            }
        }, (Map.empty(), request#registry, 0), request#manifest);
        let warned: Ref[Set[String], Static] = Ref.fresh(Static, Set.empty());
        let aliased = placeholderTextures(request#manifest, pending, atlases, name -> Map.get(name, registry))
            |> List.foldLeft((acc, pair) -> { let (name, info) = pair; Map.insert(name, info, acc) }, registry);
        { atlases = withPlaceholderFonts(request#manifest, pending, atlases), registry = aliased,
          grow = (atlas, codepoints) -> noteMissing(warned, atlas, codepoints) }

    /// フォントのアトラスの texture の名前（字の描き物が持つ名前。App のループはこの名前で届いていないフォントを照らす）。
    pub def fontTextureNameOf(entry: RenderAsset.FontEntry): String = "font_${entry#name}"

    /// 後回しのフォント（web.deferredFonts）のうち、まだ上げていない物（届いていても上げるのは WebLayer の毎コマの登録）。
    // WhyNot: 起動の前に届いていたアトラスをここで上げない — 上げた印（Deferred.markLoaded）を付ける所が 1 か所に要り、
    // 付け損ねると届いていない名前の一覧にフォントが残り続け、それを待つゲームが先へ進まない。
    pub def pendingFontsOf(manifest: List[RenderAsset.FontEntry]): List[RenderAsset.FontEntry] \ IO =
        manifest |> List.filter(entry -> {
            let path = atlasPathOf(entry);
            Deferred.isDeferred(path) and Deferred.state(path) != "loaded"
        })

    /// 届いていないフォントの名前に、起動時に読めた最初のフォントの写し（字の表は最初のフォント・texture の名前は本物の
    /// fontTextureNameOf）を代わり（placeholder）に当てる（届いたら WebLayer が本物に差し替える）。代わりのフォントのアトラスに無い字は、届くまで出ない。
    /// texture の名前に本物の名前を持たせるのは、App のループが描く物の名前から届いていないフォントを照らすため（絵は placeholderTextures で同じ物を当てる）。
    // WhyNot: 組み込みフォントへ落とさない — 組み込みは英数だけの小さな字なので、届くまでの間に日本語の文が消える。
    // WhyNot: 名前を空けたままにしない — RenderPaint.fontAtlas が「project.json に無い」と言って組み込みフォントで出す。
    pub def withPlaceholderFonts(manifest: List[RenderAsset.FontEntry], pending: List[RenderAsset.FontEntry],
                             atlases: Map[String, FontAtlas]): Map[String, FontAtlas] =
        firstLoaded(manifest, atlases)
            |> Option.map(placeholder -> pending |> List.foldLeft((acc, entry) -> Map.insert(entry#name, { textureName = fontTextureNameOf(entry) | placeholder }, acc), atlases))
            |> Option.getWithDefault(atlases)

    /// 代わりのフォントの写しの texture の名前に、最初のフォントの絵を当てる組（名前, 絵）。infoOf = texture の名前 → 上げた絵。
    pub def placeholderTextures(manifest: List[RenderAsset.FontEntry], pending: List[RenderAsset.FontEntry], atlases: Map[String, FontAtlas],
                                infoOf: String -> Option[RenderAsset.TextureInfo] \ ef): List[(String, RenderAsset.TextureInfo)] \ ef =
        match firstLoaded(manifest, atlases) |> Option.map(a -> a#textureName) {
            case None       => Nil
            case Some(name) => infoOf(name) |> Option.map(info -> List.map(entry -> (fontTextureNameOf(entry), info), pending)) |> Option.getWithDefault(Nil)
        }

    /// manifest の並びで最初に読めたフォントのアトラス。
    def firstLoaded(manifest: List[RenderAsset.FontEntry], atlases: Map[String, FontAtlas]): Option[FontAtlas] =
        manifest |> List.findMap(entry -> Map.get(entry#name, atlases))

    pub def loadAtlas(gl: GlContext, entry: RenderAsset.FontEntry): Option[(FontAtlas, RenderAsset.TextureInfo)] \ IO =
        let path = atlasPathOf(entry);
        let bytes = AssetTable.bytes(path);
        let baked = if (Object.isNull(bytes)) Err("束に無い") else RenderFontCache.decode(bytes, fontTextureNameOf(entry)) |> Option.toOk("形式が違うか壊れている");
        match baked {
            case Ok(font) =>
                println("  Font '${entry#name}' read from ${path} (${font#side}x${font#side})");
                Some((font#atlas, RenderTexture.uploadAlphaMask(gl, font#side, font#pixels)))
            case Err(why) =>
                Log.warnThen("font: '${entry#name}' のアトラス ${path} が${why} — 組み込みフォントで出す（bin/fge export-web で書き出し直す）", None)
        }

    // WhyNot: 足りない字を毎回言わない — App は字が欠けている間ずっと毎コマ足しに来る。
    /// 起動時に生成しなかった字はブラウザでは足せない。フォントごとに 1 度だけ字を並べて言い、アトラスはそのまま返す。
    // WhyNot: 代わりのフォント（届いていない後回しのフォントの写し）の欠けを言わない — 字の表は別のフォントの物で、書き出しの漏れではない。
    def noteMissing(warned: Ref[Set[String], Static], atlas: FontAtlas, codepoints: Set[Int32]): FontAtlas \ IO =
        if (Set.isEmpty(codepoints) or Set.memberOf(atlas#textureName, Ref.get(warned)) or isPlaceholderTexture(atlas#textureName)) atlas
        else {
            Ref.put(Set.insert(atlas#textureName, Ref.get(warned)), warned);
            let chars = textOf(codepoints);
            Log.warnThen("font: ${atlas#textureName} に無い字 ${Int32.toString(Set.size(codepoints))} 個（${chars}）— 書き出しで字を集め直す", atlas)
        }

    /// texture の名前が、まだ届いていない後回しのフォントの物か（その間は代わりのフォントの写しが持つ）。
    def isPlaceholderTexture(textureName: String): Bool \ IO =
        if (not String.startsWith(prefix = "font_", textureName)) false
        else {
            let path = "font-atlas/${String.dropLeft(5, textureName)}.fontatlas";
            Deferred.isDeferred(path) and Deferred.state(path) != "loaded"
        }

    /// 字の番号の集まりを字の並びへ。
    def textOf(codepoints: Set[Int32]): String \ IO =
        let builder = new StringBuilder();
        Set.forEach(cp -> discard builder.appendCodePoint(cp), codepoints);
        builder.toString()
}
