// Render3d.GlShadowCache — 影の地図に動かない物（staticGroup の持ち越した行）だけを描いた深度の控え（GL の backend。WebGPU は Render3d.WebGpuShadowCache）。
// 控えは地図 1 枚か atlas の面 1 つの大きさの深度の FBO で、鍵（Render3d.ShadowMaps.cacheKeyOf）が同じなら描き直さない。
// 毎コマ、影の地図の面へ控えを glBlitFramebuffer（深度・NEAREST）で写し、その上に動く物だけを描く。
// WhyNot: 控えを読んで frag depth を書く三角形で写さない — 深度は 24 bit で、float を経て書くと丸めが 1 段ずれうる。blit は値をそのまま写す。
mod Render3d.GlShadowCache {
    import fge.gl.GlConst
    import fge.gl.GlContext
    use Render3d.{ShadowTarget}

    /// 控え 1 つ。target = 深度だけの FBO・lastUsed = 最後に使った世代。
    pub type alias Entry = { target = ShadowTarget, lastUsed = Ref[Int64, Static] }

    /// 状態。entries = 鍵 → 控え・usedThisFrame = 今のコマに使った控えの数（残す数の目安）・
    /// redrawnThisFrame = 今のコマに描き直したか・missStreak と missWarned = 描き直しが続いた数と知らせたか（Render3d.ShadowMaps.noteCacheMisses）。
    pub type alias Cache = { entries = Ref[Map[String, Entry], Static], usedThisFrame = Ref[Int32, Static],
                             redrawnThisFrame = Ref[Bool, Static], missStreak = Ref[Int32, Static], missWarned = Ref[Bool, Static] }

    /// 控えを残す数の下限（点光源 2 本の 6 面と太陽が入る）。
    def minKept(): Int32 = 16

    pub def fresh(): Cache \ IO =
        { entries = Ref.fresh(Static, Map.empty()), usedThisFrame = Ref.fresh(Static, 0),
          redrawnThisFrame = Ref.fresh(Static, false), missStreak = Ref.fresh(Static, 0), missWarned = Ref.fresh(Static, false) }

    /// 鍵 key・一辺 size の控え（無ければ作る）と、今作ったか。作った控えは中身が無いので、呼ぶ側が動かない物を描く。作った FBO は bind したまま。
    pub def ensure(gl: GlContext, c: Cache, gen: Int64, key: String, size: Int32): (Entry, Bool) \ IO =
        Ref.put(Ref.get(c#usedThisFrame) + 1, c#usedThisFrame);
        match Map.get(key, Ref.get(c#entries)) {
            case Some(e) =>
                Ref.put(gen, e#lastUsed);
                (e, false)
            case None =>
                Ref.put(true, c#redrawnThisFrame);
                let made = { target = Render3d.Shadow.createShadowTarget(gl, (size, size)), lastUsed = Ref.fresh(Static, gen) };
                Ref.put(Map.insert(key, made, Ref.get(c#entries)), c#entries);
                (made, true)
        }

    /// 控え e の深度を、描き先 dest の (x, y) から一辺 e の大きさへ写す（GL の左下が原点）。終えたら描き先 dest を FRAMEBUFFER に bind する。
    /// scissor は呼ぶ側が面の塊に置いたままでよい（写す矩形は面の塊と同じ）。
    pub def copyInto(gl: GlContext, e: Entry, dest: ShadowTarget, x: Int32, y: Int32): Unit \ IO =
        let size = e#target#width;
        gl.bindFramebuffer(GlConst.READ_FRAMEBUFFER, e#target#fbo);
        gl.bindFramebuffer(GlConst.DRAW_FRAMEBUFFER, dest#fbo);
        gl.blitFramebuffer(0, 0, size, size, x, y, x + size, y + size, GlConst.DEPTH_BUFFER_BIT, GlConst.NEAREST);
        gl.bindFramebuffer(GlConst.FRAMEBUFFER, dest#fbo)

    /// 画面のコマの終わりに 1 回: 使った数の 2 倍（下限 minKept()）を超える控えを、古く使った物から消す（このコマの描きは GL の命令の順で済んでいる）。
    pub def endFrame(gl: GlContext, c: Cache): Unit \ IO =
        if (Ref.get(c#usedThisFrame) > 0) Render3d.ShadowMaps.noteCacheMisses(c#missStreak, c#missWarned, Ref.get(c#redrawnThisFrame)) else ();
        Ref.put(false, c#redrawnThisFrame);
        let kept = Int32.max(minKept(), 2 * Ref.get(c#usedThisFrame));
        Ref.put(0, c#usedThisFrame);
        let all = Ref.get(c#entries);
        let over = Map.size(all) - kept;
        if (over <= 0) ()
        else {
            let byAge = Map.toList(all) |> List.map(kv -> (Ref.get(snd(kv)#lastUsed), kv)) |> Sort.sortStableBy(fst);
            let dropped = List.take(over, byAge) |> List.map(snd);
            dropped |> List.forEach(kv -> destroy(gl, snd(kv)));
            Ref.put(List.foldLeft((m, kv) -> Map.remove(fst(kv), m), all, dropped), c#entries)
        }

    def destroy(gl: GlContext, e: Entry): Unit \ IO =
        gl.deleteFramebuffer(e#target#fbo);
        gl.deleteTexture(e#target#tex)

    /// 控えの数（テスト）。
    pub def sizeOf(c: Cache): Int32 \ IO = Map.size(Ref.get(c#entries))
}
