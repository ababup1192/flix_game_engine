// RenderTexture — テクスチャ読み込み (STBImage + OpenGL アップロード)
//
// LwjglLayer.flix の loadTexture / loadTextureRegistry を移植。

pub mod RenderTexture {
    import org.lwjgl.opengl.GL11
    import org.lwjgl.opengl.GL12
    import org.lwjgl.stb.STBImage
    import org.lwjgl.system.MemoryStack
    import org.lwjgl.system.MemoryUtil
    import java.nio.IntBuffer

    /// PNG/JPG など STBImage がサポートする画像をロードし、OpenGL テクスチャとして
    /// アップロードする。NEAREST フィルタ + REPEAT ラップ (ピクセルアート前提)。
    pub def loadTexture(path: String, alpha: Bool): RenderAsset.TextureInfo \ IO =
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
            let texWidth = w.get(0);
            let texHeight = h.get(0);
            let textureID = GL11.glGenTextures();
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, textureID);
            let format = if (alpha) GL11.GL_RGBA else GL11.GL_RGB;
            GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, format, texWidth, texHeight, 0, format, GL11.GL_UNSIGNED_BYTE, data);
            GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_WRAP_S, GL11.GL_REPEAT);
            GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_WRAP_T, GL11.GL_REPEAT);
            GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MIN_FILTER, GL11.GL_NEAREST);
            GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MAG_FILTER, GL11.GL_NEAREST);
            STBImage.stbi_image_free(data);
            discard MemoryStack.stackPop();
            { id = GpuHandle.wrapTextureId(textureID), width = Int32.toFloat64(texWidth), height = Int32.toFloat64(texHeight) }
        }

    /// メモリ上の ARGB 画素(行優先 width×height — PxSpriteAtlas.bake の出力そのまま)を
    /// OpenGL テクスチャとしてアップロードする(実行時アトラス焼きの GL 側出口)。
    /// GL_BGRA + UNSIGNED_INT_8_8_8_8_REV は ARGB int 列をそのまま食う組み合わせ。
    /// フィルタは loadTexture と同じ NEAREST(ドット絵前提)。
    pub def loadTextureFromPixels(width: Int32, height: Int32, argb: Vector[Int32]): RenderAsset.TextureInfo \ IO =
        let textureID = GL11.glGenTextures();
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, textureID);
        withArgbBuffer(argb, buf -> texImage(width, height, buf));
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_WRAP_S, GL11.GL_REPEAT);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_WRAP_T, GL11.GL_REPEAT);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MIN_FILTER, GL11.GL_NEAREST);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MAG_FILTER, GL11.GL_NEAREST);
        { id = GpuHandle.wrapTextureId(textureID), width = Int32.toFloat64(width), height = Int32.toFloat64(height) }

    /// 既存テクスチャの画素を丸ごと差し替える(watchFile での再ベイク差し替え用 —
    /// フレーム先頭で呼ぶ。fontAtlas と同じライフサイクル)。registry の TextureInfo は
    /// 寸法を持つので、辺長が変わったときは呼び手が registry も差し替えること。
    ///
    /// WhyNot: 辺長が同じときに glTexSubImage2D へ分けない — 置き場を確保し直さない分だけ
    /// 速くなるはずだが、320x240 を毎フレーム 2 枚上げる背中合わせで測って差が出なかった
    /// (bench/texture_upload の RESULTS.md)。
    pub def updateTexturePixels(info: RenderAsset.TextureInfo, width: Int32, height: Int32,
                                argb: Vector[Int32]): Unit \ IO =
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, GpuHandle.textureIdInt(info#id));
        withArgbBuffer(argb, buf -> texImage(width, height, buf))

    /// GPU からテクスチャを捨てる。辺長が変わって作り直すときは、古い方を必ずこれで捨てる —
    /// 捨て忘れると差し替えるたびに GPU のメモリが増え続ける。
    pub def deleteTexture(info: RenderAsset.TextureInfo): Unit \ IO =
        GL11.glDeleteTextures(GpuHandle.textureIdInt(info#id))

    /// テクスチャの置き場を確保しつつ画素を送る。
    def texImage(width: Int32, height: Int32, buf: IntBuffer): Unit \ IO =
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL11.GL_RGBA, width, height, 0,
                          GL12.GL_BGRA, GL12.GL_UNSIGNED_INT_8_8_8_8_REV, buf)

    /// ARGB int 列を direct buffer へ写して f に渡す。buffer は f を抜けたら返す
    /// (glTexImage2D は戻るまでに中身を読み切るので、その後は持っていなくてよい)。
    ///
    /// WhyNot: 1 要素ずつ put しない — Flix の Vector と Array は同じ JVM 配列で
    /// (stdlib の `Array.toVector` も同じ向きの cast をする)、int[] のまま 1 回で写せる。
    /// 320x240 1 枚で 1 要素ずつは 1.2〜2.2ms、一括は 0.02ms(この Mac の実測)。
    ///
    /// WhyNot: BufferUtils.createIntBuffer を使わない — 中身は ByteBuffer.allocateDirect で、
    /// 300KB を 0 で埋め直すのと Cleaner の登録に 1 枚 0.1〜0.5ms 払う。memAlloc/memFree は
    /// malloc/free そのままなので、毎フレーム同じ大きさを取る限り実質は使い回しになる
    /// (0.02ms。RenderBuf のように持ち回さないのは、置き場を持てる呼び手が
    /// LwjglLayer 側にしか無く、渡すには pub の形を変えることになるため)。
    def withArgbBuffer(argb: Vector[Int32], f: IntBuffer -> Unit \ IO): Unit \ IO =
        let arr = unchecked_cast(argb as Array[Int32, Static]);
        let buf = MemoryUtil.memAllocInt(Int32.max(1, Vector.length(argb)));
        discard buf.put(arr);
        discard buf.flip();
        f(buf);
        MemoryUtil.memFree(buf)

    /// テクスチャマニフェストから全テクスチャを読み込み、論理名 → TextureInfo の
    /// マップを返す。onProgress には「読み終えた枚数 / 全枚数」を渡す（起動画面が進み具合を出す）。
    pub def loadTextureRegistry(manifest: List[RenderAsset.TextureEntry],
                                onProgress: (Int32, Int32) -> Unit \ IO): RenderAsset.TextureRegistry \ IO =
        let total = List.length(manifest);
        onProgress(0, total);
        let result = List.foldLeft((acc, entry) -> {
            let (registry, done) = acc;
            let texInfo = loadTexture(entry#path, entry#hasAlpha);
            println("  ${entry#path} loaded (${texInfo#width}x${texInfo#height})");
            onProgress(done + 1, total);
            (Map.insert(entry#name, texInfo, registry), done + 1)
        }, (Map.empty(), 0), manifest);
        fst(result)

}
