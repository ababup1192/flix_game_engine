// RenderTargetGl — レンダーターゲット（eff RenderTarget.Target）の GL 実体。FBO 1 枚 +
// カラーテクスチャ 1 枚。ターゲットのテクスチャは registry に登録され、以降は普通の
// スプライトとして貼られる。GL は行 0 が下なのでターゲットの中身は上下逆に格納される —
// 反転は貼るとき（Frame.emitSprite の uv 反転）に吸収し、ここでは何もしない。
mod RenderTargetGl {
    import org.lwjgl.opengl.GL11
    import org.lwjgl.opengl.GL12
    import org.lwjgl.opengl.GL30
    import org.lwjgl.BufferUtils

    /// レンダーターゲット 1 枚の GL 実体。tex が registry へ TextureInfo として渡る。
    pub type alias Entry = { fbo = Int32, tex = Int32, width = Int32, height = Int32 }

    /// レンダーターゲットを 1 枚作る。テクスチャは全画素透明から始まる（clearColor = None の
    /// 初回でもゴミが出ない）。ラップが CLAMP_TO_EDGE なのは、貼るときの縁の標本が反対側の行へ
    /// 回り込まないように（REPEAT だと v=0/1 ちょうどで滲む）。フィルタは他のテクスチャと
    /// 同じ NEAREST（ドット絵前提）。
    pub def create(width: Int32, height: Int32): Entry \ IO =
        let tex = GL11.glGenTextures();
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, tex);
        // 直接確保の IntBuffer はゼロ初期化 = 透明黒。これで作成直後の中身が未定義にならない。
        let zeros = BufferUtils.createIntBuffer(Int32.max(1, width * height));
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL11.GL_RGBA, width, height, 0,
                          GL12.GL_BGRA, GL12.GL_UNSIGNED_INT_8_8_8_8_REV, zeros);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_WRAP_S, GL12.GL_CLAMP_TO_EDGE);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_WRAP_T, GL12.GL_CLAMP_TO_EDGE);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MIN_FILTER, GL11.GL_NEAREST);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MAG_FILTER, GL11.GL_NEAREST);
        let fbo = GL30.glGenFramebuffers();
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, fbo);
        GL30.glFramebufferTexture2D(GL30.GL_FRAMEBUFFER, GL30.GL_COLOR_ATTACHMENT0,
                                    GL11.GL_TEXTURE_2D, tex, 0);
        let status = GL30.glCheckFramebufferStatus(GL30.GL_FRAMEBUFFER);
        if (status != GL30.GL_FRAMEBUFFER_COMPLETE)
            println("[RenderTargetGl] レンダーターゲット (FBO) が完成しない status=${status} — ここへの描画は出ない")
        else ();
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, 0);
        { fbo = fbo, tex = tex, width = width, height = height }

    /// 以降の描画をこのターゲットに向ける。
    pub def bind(e: Entry): Unit \ IO =
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, e#fbo)

    /// 描画先を画面へ戻す。screen = 画面のフレームバッファ（窓なら既定の 0、GlOffscreen なら動画のコマの FBO）。
    pub def unbind(screen: Int32): Unit \ IO =
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, screen)

    /// ターゲットを捨てる（寸法が変わって作り直すとき用。捨て忘れると GPU メモリが増え続ける）。
    pub def destroy(e: Entry): Unit \ IO =
        GL30.glDeleteFramebuffers(e#fbo);
        GL11.glDeleteTextures(e#tex)
}
