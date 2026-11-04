// RenderTexture — 画素を GPU のテクスチャへ上げる所（ARGB の int 列・画像のバイト列・字の距離場）。
// 画像のデコードと字の生成は機種ごとの読み込み（RenderPaint.AssetLoader）が受け持つ。

pub mod RenderTexture {
    import fge.gl.GlContext
    import fge.gl.GlConst
    import java.nio.ByteBuffer
    import java.nio.IntBuffer

    /// 画像のバイト列（1 画素 4 バイトの RGBA か、alpha が偽なら 3 バイトの RGB・行優先・上の行から）を GPU へ上げる。
    /// NEAREST フィルタ + REPEAT ラップ (ピクセルアート前提)。
    pub def uploadBytes(gl: GlContext, image: { width = Int32, height = Int32, alpha = Bool }, data: ByteBuffer): RenderAsset.TextureInfo \ IO =
        let textureID = gl.createTexture();
        gl.bindTexture(GlConst.TEXTURE_2D, textureID);
        let format = if (image#alpha) GlConst.RGBA else GlConst.RGB;
        gl.texImageBytes(format, image#width, image#height, data);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_WRAP_S, GlConst.REPEAT);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_WRAP_T, GlConst.REPEAT);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MIN_FILTER, GlConst.NEAREST);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MAG_FILTER, GlConst.NEAREST);
        { id = GpuHandle.wrapTextureId(textureID), width = Int32.toFloat64(image#width), height = Int32.toFloat64(image#height) }

    /// 字の距離場（side × side・1 画素 1 バイト）を GPU へ上げる。距離場は滑らかに補間して読ませる — 拡大しても輪郭が
    /// 階段にならず、1 枚のアトラスからどの大きさの字もくっきり出せる。pixels は頭から読む。
    pub def uploadAlphaMask(gl: GlContext, side: Int32, pixels: ByteBuffer): RenderAsset.TextureInfo \ IO =
        discard pixels.position(0);
        let texId = gl.createTexture();
        gl.bindTexture(GlConst.TEXTURE_2D, texId);
        gl.texImageAlphaMask(side, side, pixels);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MIN_FILTER, GlConst.LINEAR);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MAG_FILTER, GlConst.LINEAR);
        let sideF = Int32.toFloat64(side);
        { id = GpuHandle.wrapTextureId(texId), width = sideF, height = sideF }

    /// メモリ上の ARGB 画素(行優先 width×height — PxSpriteAtlas.bake の出力そのまま)を
    /// OpenGL テクスチャとしてアップロードする(実行時アトラス焼きの GL 側出口)。
    /// GL_BGRA + UNSIGNED_INT_8_8_8_8_REV は ARGB int 列をそのまま食う組み合わせ。
    /// フィルタは uploadBytes と同じ NEAREST(ドット絵前提)。
    pub def loadTextureFromPixels(gl: GlContext, width: Int32, height: Int32, argb: Vector[Int32]): RenderAsset.TextureInfo \ IO =
        let textureID = gl.createTexture();
        gl.bindTexture(GlConst.TEXTURE_2D, textureID);
        withArgbBuffer(gl, argb, buf -> texImage(gl, width, height, buf));
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_WRAP_S, GlConst.REPEAT);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_WRAP_T, GlConst.REPEAT);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MIN_FILTER, GlConst.NEAREST);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MAG_FILTER, GlConst.NEAREST);
        { id = GpuHandle.wrapTextureId(textureID), width = Int32.toFloat64(width), height = Int32.toFloat64(height) }

    /// 既存テクスチャの画素を丸ごと差し替える(watchFile での再ベイク差し替え用 —
    /// フレーム先頭で呼ぶ。fontAtlas と同じライフサイクル)。registry の TextureInfo は
    /// 寸法を持つので、辺長が変わったときは呼び手が registry も差し替えること。
    ///
    /// WhyNot: 辺長が同じときに glTexSubImage2D へ分けない — 置き場を確保し直さない分だけ
    /// 速くなるはずだが、320x240 を毎フレーム 2 枚上げる背中合わせで測って差が出なかった
    /// (bench/texture_upload の RESULTS.md)。
    pub def updateTexturePixels(gl: GlContext, info: RenderAsset.TextureInfo, width: Int32, height: Int32,
                                argb: Vector[Int32]): Unit \ IO =
        gl.bindTexture(GlConst.TEXTURE_2D, GpuHandle.textureIdInt(info#id));
        withArgbBuffer(gl, argb, buf -> texImage(gl, width, height, buf))

    /// GPU からテクスチャを捨てる。辺長が変わって作り直すときは、古い方を必ずこれで捨てる —
    /// 捨て忘れると差し替えるたびに GPU のメモリが増え続ける。
    pub def deleteTexture(gl: GlContext, info: RenderAsset.TextureInfo): Unit \ IO =
        gl.deleteTexture(GpuHandle.textureIdInt(info#id))

    /// テクスチャの置き場を確保しつつ画素を送る。
    def texImage(gl: GlContext, width: Int32, height: Int32, buf: IntBuffer): Unit \ IO =
        gl.texImageArgb(width, height, buf)

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
    def withArgbBuffer(gl: GlContext, argb: Vector[Int32], f: IntBuffer -> Unit \ IO): Unit \ IO =
        let arr = unchecked_cast(argb as Array[Int32, Static]);
        let buf = gl.allocInts(Int32.max(1, Vector.length(argb)));
        discard buf.put(arr);
        discard buf.flip();
        f(buf);
        gl.freeInts(buf)


}
