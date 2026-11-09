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
        let (atlases, registry, _) = List.foldLeft((acc, entry) -> {
            let (atlasesSoFar, registrySoFar, done) = acc;
            progress("loading font ${entry#name}...", done, total);
            match loadAtlas(gl, entry) {
                case Some((atlas, info)) =>
                    (Map.insert(entry#name, atlas, atlasesSoFar), Map.insert(atlas#textureName, info, registrySoFar), done + 1)
                case None => (atlasesSoFar, registrySoFar, done + 1)
            }
        }, (Map.empty(), request#registry, 0), request#manifest);
        let warned: Ref[Set[String], Static] = Ref.fresh(Static, Set.empty());
        { atlases = atlases, registry = registry, grow = (_, atlas, codepoints) -> noteMissing(warned, atlas, codepoints) }

    def loadAtlas(gl: GlContext, entry: RenderAsset.FontEntry): Option[(FontAtlas, RenderAsset.TextureInfo)] \ IO =
        let path = atlasPathOf(entry);
        let bytes = AssetTable.bytes(path);
        let baked = if (Object.isNull(bytes)) Err("束に無い") else RenderFontCache.decode(bytes, "font_${entry#name}") |> Option.toOk("形式が違うか壊れている");
        match baked {
            case Ok(font) =>
                println("  Font '${entry#name}' read from ${path} (${font#side}x${font#side})");
                Some((font#atlas, RenderTexture.uploadAlphaMask(gl, font#side, font#pixels)))
            case Err(why) =>
                Log.warnThen("font: '${entry#name}' のアトラス ${path} が${why} — 組み込みフォントで出す（bin/fge export-web で書き出し直す）", None)
        }

    // WhyNot: 足りない字を毎回言わない — App は字が欠けている間ずっと毎コマ足しに来る。
    /// 起動時に生成しなかった字はブラウザでは足せない。フォントごとに 1 度だけ字を並べて言い、アトラスはそのまま返す。
    def noteMissing(warned: Ref[Set[String], Static], atlas: FontAtlas, codepoints: Set[Int32]): FontAtlas \ IO =
        if (Set.isEmpty(codepoints) or Set.memberOf(atlas#textureName, Ref.get(warned))) atlas
        else {
            Ref.put(Set.insert(atlas#textureName, Ref.get(warned)), warned);
            let chars = textOf(codepoints);
            Log.warnThen("font: ${atlas#textureName} に無い字 ${Int32.toString(Set.size(codepoints))} 個（${chars}）— 書き出しで字を集め直す", atlas)
        }

    /// 字の番号の集まりを字の並びへ。
    def textOf(codepoints: Set[Int32]): String \ IO =
        let builder = new StringBuilder();
        Set.forEach(cp -> discard builder.appendCodePoint(cp), codepoints);
        builder.toString()
}
