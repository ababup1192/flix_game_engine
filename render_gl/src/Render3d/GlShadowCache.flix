// Render3d.GlShadowCache — 影の地図に動かない物（staticGroup の持ち越した行）だけを描いた深度の控え（GL の backend。WebGPU は Render3d.WebGpuShadowCache）。
// 控えは地図 1 枚か atlas の面 1 つの大きさの深度の FBO で、鍵（Render3d.ShadowMaps.cacheKeyOf）が同じなら描き直さない。
// 毎コマ、影の地図の面へ控えを glBlitFramebuffer（深度・NEAREST）で写し、その上に動く物だけを描く。
// WhyNot: 控えを読んで frag depth を書く三角形で写さない — 深度は 24 bit で、float を経て書くと丸めが 1 段ずれうる。blit は値をそのまま写す。
mod Render3d.GlShadowCache {
    import fge.gl.GlConst
    import fge.gl.GlContext
    use Render3d.{ShadowTarget}
    use Render3d.ShadowCacheTable

    /// 控え 1 つ。target = 深度だけの FBO。
    pub type alias Entry = { target = ShadowTarget }

    /// 状態（鍵 → 控えの表と、描き直しの数え。Render3d.ShadowCacheTable）。
    pub type alias Cache = ShadowCacheTable.Table[Entry]

    pub def fresh(): Cache \ IO = ShadowCacheTable.fresh()

    /// 鍵 key・一辺 size の控え（無ければ作る）と、今作ったか。作った控えは中身が無いので、呼ぶ側が動かない物を描く。作った FBO は bind したまま。
    pub def ensure(gl: GlContext, c: Cache, gen: Int64, key: String, size: Int32): (Entry, Bool) \ IO =
        ShadowCacheTable.ensure(c, gen, key, () -> { target = Render3d.Shadow.createShadowTarget(gl, (size, size)) })

    /// 控え e の深度を、描き先 dest の (x, y) から一辺 e の大きさへ写す（GL の左下が原点）。終えたら描き先 dest を FRAMEBUFFER に bind する。
    /// scissor は呼ぶ側が面の塊に置いたままでよい（写す矩形は面の塊と同じ）。
    pub def copyInto(gl: GlContext, e: Entry, dest: ShadowTarget, x: Int32, y: Int32): Unit \ IO =
        let size = e#target#width;
        gl.bindFramebuffer(GlConst.READ_FRAMEBUFFER, e#target#fbo);
        gl.bindFramebuffer(GlConst.DRAW_FRAMEBUFFER, dest#fbo);
        gl.blitFramebuffer(0, 0, size, size, x, y, x + size, y + size, GlConst.DEPTH_BUFFER_BIT, GlConst.NEAREST);
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, dest#fbo)

    /// 画面のコマの終わりに 1 回: 残す数（Render3d.ShadowCacheTable.endFrame）を超える控えを、古く使った物から消す（このコマの描きは GL の命令の順で済んでいる）。
    pub def endFrame(gl: GlContext, c: Cache): Unit \ IO =
        ShadowCacheTable.endFrame(c) |> List.forEach(destroy(gl))

    def destroy(gl: GlContext, e: Entry): Unit \ IO =
        gl.deleteFramebuffer(e#target#fbo);
        gl.deleteTexture(e#target#tex)

    /// 控えの数（テスト）。
    pub def sizeOf(c: Cache): Int32 \ IO = ShadowCacheTable.sizeOf(c)
}
