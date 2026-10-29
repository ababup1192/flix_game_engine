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
    /// depthStencil = mask 付きの面・sprite を抜くためのステンシル（テクセル寸法の renderbuffer）。
    pub type alias Entry = { fbo = Int32, tex = Int32, depthStencil = Int32, width = Int32, height = Int32 }

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
        let depthStencil = GL30.glGenRenderbuffers();
        GL30.glBindRenderbuffer(GL30.GL_RENDERBUFFER, depthStencil);
        GL30.glRenderbufferStorage(GL30.GL_RENDERBUFFER, GL30.GL_DEPTH24_STENCIL8, width, height);
        GL30.glBindRenderbuffer(GL30.GL_RENDERBUFFER, 0);
        let fbo = GL30.glGenFramebuffers();
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, fbo);
        GL30.glFramebufferTexture2D(GL30.GL_FRAMEBUFFER, GL30.GL_COLOR_ATTACHMENT0,
                                    GL11.GL_TEXTURE_2D, tex, 0);
        GL30.glFramebufferRenderbuffer(GL30.GL_FRAMEBUFFER, GL30.GL_DEPTH_STENCIL_ATTACHMENT,
                                       GL30.GL_RENDERBUFFER, depthStencil);
        let status = GL30.glCheckFramebufferStatus(GL30.GL_FRAMEBUFFER);
        if (status != GL30.GL_FRAMEBUFFER_COMPLETE)
            println("[RenderTargetGl] レンダーターゲット (FBO) が完成しない status=${status} — ここへの描画は出ない")
        else ();
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, 0);
        { fbo = fbo, tex = tex, depthStencil = depthStencil, width = width, height = height }

    /// 以降の描画をこのターゲットに向ける。
    pub def bind(e: Entry): Unit \ IO =
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, e#fbo)

    /// 描画先を画面へ戻す。screen = 画面のフレームバッファ（窓なら既定の 0、GlOffscreen なら動画のコマの FBO）。
    pub def unbind(screen: Int32): Unit \ IO =
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, screen)

    /// source の中身を dest へ等倍で写す（同じ寸法の前提・NEAREST）。描き先は source に戻す。
    pub def copyTo(source: Entry, dest: Entry): Unit \ IO =
        GL30.glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER, source#fbo);
        GL30.glBindFramebuffer(GL30.GL_DRAW_FRAMEBUFFER, dest#fbo);
        GL30.glBlitFramebuffer(0, 0, source#width, source#height, 0, 0, dest#width, dest#height,
                               GL11.GL_COLOR_BUFFER_BIT, GL11.GL_NEAREST);
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, source#fbo)

    /// e を全画素透明で塗る。描き先は back に戻す。
    pub def clearTransparent(e: Entry, back: Entry): Unit \ IO =
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, e#fbo);
        GL11.glDisable(GL11.GL_SCISSOR_TEST);
        GL11.glClearColor(0.0f32, 0.0f32, 0.0f32, 0.0f32);
        GL11.glClear(GL11.GL_COLOR_BUFFER_BIT);
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, back#fbo)

    /// ターゲットを捨てる（寸法が変わって作り直すとき用。捨て忘れると GPU メモリが増え続ける）。
    pub def destroy(e: Entry): Unit \ IO =
        GL30.glDeleteFramebuffers(e#fbo);
        GL30.glDeleteRenderbuffers(e#depthStencil);
        GL11.glDeleteTextures(e#tex)
}
