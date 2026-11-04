// RenderTargetGl — レンダーターゲット（eff RenderTarget.Target）の GL 実体。FBO 1 枚 +
// カラーテクスチャ 1 枚。ターゲットのテクスチャは registry に登録され、以降は普通の
// スプライトとして貼られる。GL は行 0 が下なのでターゲットの中身は上下逆に格納される —
// 反転は貼るとき（RenderFrame.emitSprite の uv 反転）に吸収し、ここでは何もしない。
mod RenderTargetGl {
    import fge.gl.GlContext
    import fge.gl.GlContext
    import fge.gl.GlConst
    import fge.gl.GlContext

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
    pub def create(gl: GlContext, width: Int32, height: Int32, format: RenderTarget.Format): Entry \ IO =
        let (made, status) = createStored(gl, width, height, format);
        if (status == GlConst.FRAMEBUFFER_COMPLETE) made
        else if (format == RenderTarget.Format.Rgba8Unorm) { warnIncomplete(status); made }
        else {
            destroy(gl, made);
            let (fallback, fallbackStatus) = createStored(gl, width, height, RenderTarget.Format.Rgba8Unorm);
            if (fallbackStatus == GlConst.FRAMEBUFFER_COMPLETE) () else warnIncomplete(fallbackStatus);
            { format = format | fallback }
        }

    /// create に、samples（RenderTarget.samplesOf の答え）が 1 より大きければ標本を持つ描き先を足した物。
    /// 標本の数は GPU の上限（GL_MAX_SAMPLES）で頭打ちにする。標本つきの FBO が完成しない時は MSAA なしで続け、
    /// msaa が None のまま返す（知らせるのは呼び手 — isMsaaFallback）。
    pub def createWithSamples(gl: GlContext, width: Int32, height: Int32, format: RenderTarget.Format, samples: Int32): Entry \ IO =
        let made = create(gl, width, height, format);
        if (samples <= 1) { samples = samples | made }
        else {
            let wanted = Int32.min(samples, RenderTarget.samplesAtMost(gl.getInteger(GlConst.MAX_SAMPLES)));
            if (wanted <= 1) { samples = samples | made }
            else { samples = samples, msaa = createMsaa(gl, width, height, made#storedFormat, wanted) | made }
        }

    /// 頼まれたのに標本を持つ描き先を作れなかったか（GPU が 1 標本しか持てない・FBO が完成しない）。
    pub def isMsaaFallback(e: Entry): Bool = e#samples > 1 and Option.isEmpty(e#msaa)

    /// 標本 samples 個の色（stored の形式）と深度・ステンシルの renderbuffer を付けた FBO。完成しなければ消して None（bind は 0 に戻す）。
    def createMsaa(gl: GlContext, width: Int32, height: Int32, stored: RenderTarget.Format, samples: Int32): Option[Msaa] \ IO =
        let internal = match stored {
            case RenderTarget.Format.Rgba8Unorm  => GlConst.RGBA8
            case RenderTarget.Format.Rgba16Float => GlConst.RGBA16F
        };
        let color = gl.createRenderbuffer();
        gl.bindRenderbuffer(GlConst.RENDERBUFFER, color);
        gl.renderbufferStorageMultisample(GlConst.RENDERBUFFER, samples, internal, width, height);
        let depthStencil = gl.createRenderbuffer();
        gl.bindRenderbuffer(GlConst.RENDERBUFFER, depthStencil);
        gl.renderbufferStorageMultisample(GlConst.RENDERBUFFER, samples, GlConst.DEPTH24_STENCIL8, width, height);
        gl.bindRenderbuffer(GlConst.RENDERBUFFER, 0);
        let fbo = gl.createFramebuffer();
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, fbo);
        gl.framebufferRenderbuffer(GlConst.FRAMEBUFFER, GlConst.COLOR_ATTACHMENT0, GlConst.RENDERBUFFER, color);
        gl.framebufferRenderbuffer(GlConst.FRAMEBUFFER, GlConst.DEPTH_STENCIL_ATTACHMENT, GlConst.RENDERBUFFER, depthStencil);
        let status = gl.checkFramebufferStatus(GlConst.FRAMEBUFFER);
        // 作った直後の中身は決まっていないので、透明で塗っておく（Keep の 1 コマ目にゴミが出ない）。
        if (status == GlConst.FRAMEBUFFER_COMPLETE) {
            gl.disable(GlConst.SCISSOR_TEST);
            gl.clearColor(0.0f32, 0.0f32, 0.0f32, 0.0f32);
            gl.clear(GlConst.COLOR_BUFFER_BIT)
        } else ();
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, 0);
        if (status == GlConst.FRAMEBUFFER_COMPLETE) Some({ fbo = fbo, color = color, depthStencil = depthStencil, samples = samples })
        else {
            gl.deleteFramebuffer(fbo);
            gl.deleteRenderbuffer(color);
            gl.deleteRenderbuffer(depthStencil);
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
    pub def resolve(gl: GlContext, e: Entry): Unit \ IO =
        e#msaa |> Option.forEach(m -> {
            gl.disable(GlConst.SCISSOR_TEST);
            gl.bindFramebuffer(GlConst.READ_FRAMEBUFFER, m#fbo);
            gl.bindFramebuffer(GlConst.DRAW_FRAMEBUFFER, e#fbo);
            gl.blitFramebuffer(0, 0, e#width, e#height, 0, 0, e#width, e#height, GlConst.COLOR_BUFFER_BIT, GlConst.NEAREST);
            gl.bindFramebuffer(GlConst.FRAMEBUFFER, e#fbo)
        })

    /// 実際に作れた形式が頼まれた形式と違うか（Rgba16Float に対応しない描き先で作り直した時）。
    pub def isFallback(e: Entry): Bool = e#format != e#storedFormat

    /// stored の形式で 1 枚作り、FBO の status（glCheckFramebufferStatus・完成なら GL_FRAMEBUFFER_COMPLETE）と一緒に返す（bind は 0 に戻す）。
    def createStored(gl: GlContext, width: Int32, height: Int32, stored: RenderTarget.Format): (Entry, Int32) \ IO =
        let tex = gl.createTexture();
        gl.bindTexture(GlConst.TEXTURE_2D, tex);
        uploadZeros(gl, width, height, stored);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_WRAP_S, GlConst.CLAMP_TO_EDGE);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_WRAP_T, GlConst.CLAMP_TO_EDGE);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MIN_FILTER, GlConst.NEAREST);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MAG_FILTER, GlConst.NEAREST);
        let depthStencil = gl.createRenderbuffer();
        gl.bindRenderbuffer(GlConst.RENDERBUFFER, depthStencil);
        gl.renderbufferStorage(GlConst.RENDERBUFFER, GlConst.DEPTH24_STENCIL8, width, height);
        gl.bindRenderbuffer(GlConst.RENDERBUFFER, 0);
        let fbo = gl.createFramebuffer();
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, fbo);
        gl.framebufferTexture2D(GlConst.FRAMEBUFFER, GlConst.COLOR_ATTACHMENT0,
                                    GlConst.TEXTURE_2D, tex, 0);
        gl.framebufferRenderbuffer(GlConst.FRAMEBUFFER, GlConst.DEPTH_STENCIL_ATTACHMENT,
                                       GlConst.RENDERBUFFER, depthStencil);
        let status = gl.checkFramebufferStatus(GlConst.FRAMEBUFFER);
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, 0);
        ({ fbo = fbo, tex = tex, depthStencil = depthStencil, width = width, height = height,
           format = stored, storedFormat = stored, samples = 1, msaa = None }, status)

    /// bind 中のテクスチャへ全画素 0（透明黒）の画素を stored の形式で載せる。
    def uploadZeros(gl: GlContext, width: Int32, height: Int32, stored: RenderTarget.Format): Unit \ IO =
        match stored {
            case RenderTarget.Format.Rgba8Unorm  => gl.texImageArgbZero(width, height)
            case RenderTarget.Format.Rgba16Float => gl.texImageRgba16fZero(width, height)
        }

    def warnIncomplete(status: Int32): Unit \ IO =
        println("[RenderTargetGl] レンダーターゲット (FBO) が完成しない status=${status} — ここへの描画は出ない")

    /// 以降の描画をこのターゲットに向ける（標本を持つ描き先があればそちら）。
    pub def bind(gl: GlContext, e: Entry): Unit \ IO =
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, drawFramebuffer(e))

    /// 描画先を画面へ戻す。screen = 画面のフレームバッファ（窓なら既定の 0、GlOffscreen なら動画のコマの FBO）。
    pub def unbind(gl: GlContext, screen: Int32): Unit \ IO =
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, screen)

    /// source の中身（resolve の後の tex）を dest へ等倍で写す（同じ寸法の前提・NEAREST）。描き先は source の描く FBO に戻す。
    pub def copyTo(gl: GlContext, source: Entry, dest: Entry): Unit \ IO =
        gl.bindFramebuffer(GlConst.READ_FRAMEBUFFER, source#fbo);
        gl.bindFramebuffer(GlConst.DRAW_FRAMEBUFFER, dest#fbo);
        gl.blitFramebuffer(0, 0, source#width, source#height, 0, 0, dest#width, dest#height,
                               GlConst.COLOR_BUFFER_BIT, GlConst.NEAREST);
        bind(gl, source)

    /// e を全画素透明で塗る。描き先は back の描く FBO に戻す。
    pub def clearTransparent(gl: GlContext, e: Entry, back: Entry): Unit \ IO =
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, e#fbo);
        gl.disable(GlConst.SCISSOR_TEST);
        gl.clearColor(0.0f32, 0.0f32, 0.0f32, 0.0f32);
        gl.clear(GlConst.COLOR_BUFFER_BIT);
        bind(gl, back)

    /// ターゲットを捨てる（寸法が変わって作り直すとき用。捨て忘れると GPU メモリが増え続ける）。
    pub def destroy(gl: GlContext, e: Entry): Unit \ IO =
        gl.deleteFramebuffer(e#fbo);
        gl.deleteRenderbuffer(e#depthStencil);
        gl.deleteTexture(e#tex);
        e#msaa |> Option.forEach(m -> {
            gl.deleteFramebuffer(m#fbo);
            gl.deleteRenderbuffer(m#color);
            gl.deleteRenderbuffer(m#depthStencil)
        })
}
