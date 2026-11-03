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
    /// format = 頼まれた形式（作り直しの鍵）・storedFormat = 実際に作れた形式（描き先が Rgba16Float に対応しない時だけ Rgba8Unorm に替わる）。
    /// samples = 頼まれた標本の数（作り直しの鍵）・msaa = 標本を持つ描き先（samples が 1 か、作れなかった時は None）。
    /// msaa が Some なら描くのは msaa の FBO で、tex（fbo）は resolve で写した後の絵（読む側は今までどおり tex を読む）。
    pub type alias Entry = { fbo = Int32, tex = Int32, depthStencil = Int32, width = Int32, height = Int32,
                             format = RenderTarget.Format, storedFormat = RenderTarget.Format, samples = Int32, msaa = Option[Msaa] }

    /// 標本を持つ描き先。fbo = 描く FBO・color と depthStencil = 標本つきの renderbuffer・samples = 実際の標本の数。
    pub type alias Msaa = { fbo = Int32, color = Int32, depthStencil = Int32, samples = Int32 }

    /// レンダーターゲットを 1 枚作る。テクスチャは全画素透明から始まる（clearColor = None の
    /// 初回でもゴミが出ない）。ラップが CLAMP_TO_EDGE なのは、貼るときの縁の標本が反対側の行へ
    /// 回り込まないように（REPEAT だと v=0/1 ちょうどで滲む）。フィルタは他のテクスチャと
    /// 同じ NEAREST（ドット絵前提）。
    /// Rgba16Float の FBO が完成しない描き先では Rgba8Unorm で作り直す（storedFormat に残る。知らせるのは呼び手）。
    pub def create(width: Int32, height: Int32, format: RenderTarget.Format): Entry \ IO =
        let (made, status) = createStored(width, height, format);
        if (status == GL30.GL_FRAMEBUFFER_COMPLETE) made
        else if (format == RenderTarget.Format.Rgba8Unorm) { warnIncomplete(status); made }
        else {
            destroy(made);
            let (fallback, fallbackStatus) = createStored(width, height, RenderTarget.Format.Rgba8Unorm);
            if (fallbackStatus == GL30.GL_FRAMEBUFFER_COMPLETE) () else warnIncomplete(fallbackStatus);
            { format = format | fallback }
        }

    /// create に、samples（RenderTarget.samplesOf の答え）が 1 より大きければ標本を持つ描き先を足した物。
    /// 標本の数は GPU の上限（GL_MAX_SAMPLES）で頭打ちにする。標本つきの FBO が完成しない時は MSAA なしで続け、
    /// msaa が None のまま返す（知らせるのは呼び手 — isMsaaFallback）。
    pub def createWithSamples(width: Int32, height: Int32, format: RenderTarget.Format, samples: Int32): Entry \ IO =
        let made = create(width, height, format);
        if (samples <= 1) { samples = samples | made }
        else {
            let wanted = Int32.min(samples, RenderTarget.samplesAtMost(GL11.glGetInteger(GL30.GL_MAX_SAMPLES)));
            if (wanted <= 1) { samples = samples | made }
            else { samples = samples, msaa = createMsaa(width, height, made#storedFormat, wanted) | made }
        }

    /// 頼まれたのに標本を持つ描き先を作れなかったか（GPU が 1 標本しか持てない・FBO が完成しない）。
    pub def isMsaaFallback(e: Entry): Bool = e#samples > 1 and Option.isEmpty(e#msaa)

    /// 標本 samples 個の色（stored の形式）と深度・ステンシルの renderbuffer を付けた FBO。完成しなければ消して None（bind は 0 に戻す）。
    def createMsaa(width: Int32, height: Int32, stored: RenderTarget.Format, samples: Int32): Option[Msaa] \ IO =
        let internal = match stored {
            case RenderTarget.Format.Rgba8Unorm  => GL11.GL_RGBA8
            case RenderTarget.Format.Rgba16Float => GL30.GL_RGBA16F
        };
        let color = GL30.glGenRenderbuffers();
        GL30.glBindRenderbuffer(GL30.GL_RENDERBUFFER, color);
        GL30.glRenderbufferStorageMultisample(GL30.GL_RENDERBUFFER, samples, internal, width, height);
        let depthStencil = GL30.glGenRenderbuffers();
        GL30.glBindRenderbuffer(GL30.GL_RENDERBUFFER, depthStencil);
        GL30.glRenderbufferStorageMultisample(GL30.GL_RENDERBUFFER, samples, GL30.GL_DEPTH24_STENCIL8, width, height);
        GL30.glBindRenderbuffer(GL30.GL_RENDERBUFFER, 0);
        let fbo = GL30.glGenFramebuffers();
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, fbo);
        GL30.glFramebufferRenderbuffer(GL30.GL_FRAMEBUFFER, GL30.GL_COLOR_ATTACHMENT0, GL30.GL_RENDERBUFFER, color);
        GL30.glFramebufferRenderbuffer(GL30.GL_FRAMEBUFFER, GL30.GL_DEPTH_STENCIL_ATTACHMENT, GL30.GL_RENDERBUFFER, depthStencil);
        let status = GL30.glCheckFramebufferStatus(GL30.GL_FRAMEBUFFER);
        // 作った直後の中身は決まっていないので、透明で塗っておく（Keep の 1 コマ目にゴミが出ない）。
        if (status == GL30.GL_FRAMEBUFFER_COMPLETE) {
            GL11.glDisable(GL11.GL_SCISSOR_TEST);
            GL11.glClearColor(0.0f32, 0.0f32, 0.0f32, 0.0f32);
            GL11.glClear(GL11.GL_COLOR_BUFFER_BIT)
        } else ();
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, 0);
        if (status == GL30.GL_FRAMEBUFFER_COMPLETE) Some({ fbo = fbo, color = color, depthStencil = depthStencil, samples = samples })
        else {
            GL30.glDeleteFramebuffers(fbo);
            GL30.glDeleteRenderbuffers(color);
            GL30.glDeleteRenderbuffers(depthStencil);
            None
        }

    /// 描く時に bind する FBO（標本を持つ描き先があればそれ・無ければ tex の FBO）。
    pub def drawFramebuffer(e: Entry): Int32 =
        e#msaa |> Option.map(m -> m#fbo) |> Option.getWithDefault(e#fbo)

    /// 描く時の標本の数（MSAA が無ければ 1）。
    pub def drawSamples(e: Entry): Int32 =
        e#msaa |> Option.map(m -> m#samples) |> Option.getWithDefault(1)

    /// 標本を持つ描き先の中身を tex へ写す（標本の平均。読む前に 1 回）。MSAA の無いターゲットは何もしない。
    /// 描き先は画面へは戻さず、tex の FBO を bind したまま返す（呼び手が描き先を決め直す）。
    // WhyNot: scissor を残したまま写さない — glBlitFramebuffer は scissor に切られ、絵が四角く欠ける。
    pub def resolve(e: Entry): Unit \ IO =
        e#msaa |> Option.forEach(m -> {
            GL11.glDisable(GL11.GL_SCISSOR_TEST);
            GL30.glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER, m#fbo);
            GL30.glBindFramebuffer(GL30.GL_DRAW_FRAMEBUFFER, e#fbo);
            GL30.glBlitFramebuffer(0, 0, e#width, e#height, 0, 0, e#width, e#height, GL11.GL_COLOR_BUFFER_BIT, GL11.GL_NEAREST);
            GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, e#fbo)
        })

    /// 実際に作れた形式が頼まれた形式と違うか（Rgba16Float に対応しない描き先で作り直した時）。
    pub def isFallback(e: Entry): Bool = e#format != e#storedFormat

    /// stored の形式で 1 枚作り、FBO の status（glCheckFramebufferStatus・完成なら GL_FRAMEBUFFER_COMPLETE）と一緒に返す（bind は 0 に戻す）。
    def createStored(width: Int32, height: Int32, stored: RenderTarget.Format): (Entry, Int32) \ IO =
        let tex = GL11.glGenTextures();
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, tex);
        uploadZeros(width, height, stored);
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
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, 0);
        ({ fbo = fbo, tex = tex, depthStencil = depthStencil, width = width, height = height,
           format = stored, storedFormat = stored, samples = 1, msaa = None }, status)

    /// bind 中のテクスチャへ全画素 0（透明黒）の画素を stored の形式で載せる。直接確保のバッファはゼロ初期化。
    def uploadZeros(width: Int32, height: Int32, stored: RenderTarget.Format): Unit \ IO =
        let n = Int32.max(1, width * height);
        match stored {
            case RenderTarget.Format.Rgba8Unorm =>
                GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL11.GL_RGBA, width, height, 0,
                                  GL12.GL_BGRA, GL12.GL_UNSIGNED_INT_8_8_8_8_REV, BufferUtils.createIntBuffer(n))
            case RenderTarget.Format.Rgba16Float =>
                GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL30.GL_RGBA16F, width, height, 0,
                                  GL11.GL_RGBA, GL30.GL_HALF_FLOAT, BufferUtils.createShortBuffer(n * 4))
        }

    def warnIncomplete(status: Int32): Unit \ IO =
        println("[RenderTargetGl] レンダーターゲット (FBO) が完成しない status=${status} — ここへの描画は出ない")

    /// 以降の描画をこのターゲットに向ける（標本を持つ描き先があればそちら）。
    pub def bind(e: Entry): Unit \ IO =
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, drawFramebuffer(e))

    /// 描画先を画面へ戻す。screen = 画面のフレームバッファ（窓なら既定の 0、GlOffscreen なら動画のコマの FBO）。
    pub def unbind(screen: Int32): Unit \ IO =
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, screen)

    /// source の中身（resolve の後の tex）を dest へ等倍で写す（同じ寸法の前提・NEAREST）。描き先は source の描く FBO に戻す。
    pub def copyTo(source: Entry, dest: Entry): Unit \ IO =
        GL30.glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER, source#fbo);
        GL30.glBindFramebuffer(GL30.GL_DRAW_FRAMEBUFFER, dest#fbo);
        GL30.glBlitFramebuffer(0, 0, source#width, source#height, 0, 0, dest#width, dest#height,
                               GL11.GL_COLOR_BUFFER_BIT, GL11.GL_NEAREST);
        bind(source)

    /// e を全画素透明で塗る。描き先は back の描く FBO に戻す。
    pub def clearTransparent(e: Entry, back: Entry): Unit \ IO =
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, e#fbo);
        GL11.glDisable(GL11.GL_SCISSOR_TEST);
        GL11.glClearColor(0.0f32, 0.0f32, 0.0f32, 0.0f32);
        GL11.glClear(GL11.GL_COLOR_BUFFER_BIT);
        bind(back)

    /// ターゲットを捨てる（寸法が変わって作り直すとき用。捨て忘れると GPU メモリが増え続ける）。
    pub def destroy(e: Entry): Unit \ IO =
        GL30.glDeleteFramebuffers(e#fbo);
        GL30.glDeleteRenderbuffers(e#depthStencil);
        GL11.glDeleteTextures(e#tex);
        e#msaa |> Option.forEach(m -> {
            GL30.glDeleteFramebuffers(m#fbo);
            GL30.glDeleteRenderbuffers(m#color);
            GL30.glDeleteRenderbuffers(m#depthStencil)
        })
}
