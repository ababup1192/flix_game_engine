// RenderSplash — 起動画面を「いつ描くか」を決めて、実際に 1 枚出す。
//
// 絵そのものは Splash（engine 側・純粋）が組む。ここが持つのは GLFW の都合だけ —
// 間引き・画面交換の待ち・イベントの汲み上げ。
mod RenderSplash {
    import org.lwjgl.glfw.GLFW
    import java.lang.System

    /// 起動画面を動かすのに要る、書き換わる値だけの入れ物。
    pub type alias State = {
        startNanos = Int64,
        lastNanos = Array[Int64, Static]
    }

    pub def newState(): State \ IO =
        { startNanos = System.nanoTime(), lastNanos = Array#{0i64} @ Static }

    /// 組み込みフォントとロゴを GPU へ載せ、名前で引ける表にして返す。
    /// ゲームのテクスチャを 1 枚も読む前に呼べる（画素はソースに埋め込んである）。
    pub def install(): RenderAsset.TextureRegistry \ IO =
        let side = BootFontData.side();
        let fontTex = RenderTexture.loadTextureFromPixels(side, side, BootFont.pixelsArgb());
        let logoSide = BootFont.logoSide();
        let logoTex = RenderTexture.loadTextureFromPixels(logoSide, logoSide, BootFont.logoArgb());
        Map.empty()
            |> Map.insert(BootFont.textureName(), fontTex)
            |> Map.insert(BootFont.logoTextureName(), logoTex)

    /// 進み具合を伝える。前に描いてから間が空いていなければ何もしない。
    /// done / total は「何本目 / 全何本」。total が 0 以下なら本数不明として流れるバーになる。
    /// phase は**その場で組み立てない**で渡す。ここは字 1 つごとに数千回呼ばれるので、
    /// 出さないと決めた回でも文言を作る手間だけが積み上がる。
    pub def tick(st: State, draw: List[GameEngine.Drawable] -> Unit \ IO, design: Vec2.Vec2,
                 phase: String, done: Int32, total: Int32): Unit \ IO =
        let now = System.nanoTime();
        if (not due(st, now) or disabled()) ()
        else render(st, draw, design, phase, done, total, now)

    /// 間隔をあけずに 1 枚出す。読み込みの区切りで「次はこれをやっている」を確実に
    /// 見せたいときに使う。ただし起動直後の見合わせ時間は守る — 取ってあった焼き上がりで
    /// 一瞬で終わる起動のときに、画面をちらっと光らせないため。
    pub def show(st: State, draw: List[GameEngine.Drawable] -> Unit \ IO, design: Vec2.Vec2,
                 phase: String, done: Int32, total: Int32): Unit \ IO =
        let now = System.nanoTime();
        if (disabled() or not pastGrace(st, now)) ()
        else render(st, draw, design, phase, done, total, now)

    /// FLIX_GE_NO_SPLASH=1 で起動画面を丸ごと止める（従来どおりの起動と見比べる用）。
    pub def disabled(): Bool \ IO =
        let value = System.getenv("FLIX_GE_NO_SPLASH");
        not Object.isNull(value) and value != "0"

    // ── 内部 ──────────────────────────────────────────────────

    /// 起動画面を出し直す間隔（ミリ秒）。字 1 つごとに出し直すと画面交換の待ちで
    /// 読み込みそのものが遅くなる。描かない回に poll だけする間隔（LwjglLayer の LoadProgress）も同じ値を使う。
    pub def intervalMillis(): Int64 = 80i64

    /// 起動から これ以下 の間は描かない。読み込みが一瞬で終わる起動
    /// （フォントの焼き上がりが取ってある 2 回目以降）で画面をちらつかせないため。
    def graceMillis(): Int64 = 120i64

    def pastGrace(st: State, now: Int64): Bool =
        (now - st#startNanos) / 1000000i64 >= graceMillis()

    def due(st: State, now: Int64): Bool \ IO =
        let sinceLast = (now - Array.get(0, st#lastNanos)) / 1000000i64;
        pastGrace(st, now) and sinceLast >= intervalMillis()

    def render(st: State, draw: List[GameEngine.Drawable] -> Unit \ IO, design: Vec2.Vec2,
               phase: String, done: Int32, total: Int32, now: Int64): Unit \ IO =
        Array.put(now, 0, st#lastNanos);
        let elapsed = Int64.toFloat64(now - st#startNanos) / 1000000000.0;
        draw(Splash.drawables(Splash.bootView(design, phase,
                                              Splash.clampRatio(done, total),
                                              Splash.turnsOf(elapsed))))
}
