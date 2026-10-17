// Bench — render_gl の描画提出コストを before/after で比べるための負荷世界。
// 位置は (i, t) の純関数にしてある: 乱数や可変状態を混ぜると計測のたびに
// 描画量が揺れて、エンジン改修の差分と見分けが付かなくなるため。

mod Bench {
    use fge::{App, Color, FontAtlas, RawDraw, Render, RenderUtil}

    import java.lang.System
    import org.lwjgl.glfw.GLFW

    /// 環境変数 HUD が空でない値なら HUD あり構成で走る（例: `HUD=1 make run`）。
    pub def hudEnabled(): Bool \ IO =
        let value = System.getenv("HUD");
        not Object.isNull(value) and value != ""

    pub type alias World = {
        t = Float64,
        segment = Int32,
        frameInSegment = Int32,
        samples = List[Float64],
        done = Bool
    }

    pub def initialWorld(): World =
        { t = 0.0, segment = 0, frameInSegment = 0, samples = Nil, done = false }

    // ── 区間の台本 ──

    def segmentCount(): Int32 = 4

    def countOf(segment: Int32): Int32 =
        match segment {
            case 0 => 500
            case 1 => 2000
            case 2 => 5000
            case _ => 10000
        }

    def framesPerSegment(): Int32 = 150

    /// 起動直後は JIT とアセット準備で dt が荒れるため、最初の区間だけ長めに捨てる。
    def warmupOf(segment: Int32): Int32 =
        if (segment == 0) 60 else 30

    // ── 毎フレームのシステム（区間末の統計 println があるので \ IO）──

    /// エンジンには手を入れない決まりなので、垂直同期はゲーム側から GLFW を直接叩いて切る。
    /// 起動直後（描画ループ前）に 1 回呼ぶだけでは macOS で 60fps に張り付いたままだったので、
    /// 捨てる前提のウォームアップ中に毎フレーム呼んで確実に効かせる。
    def vsyncOff(): Unit \ IO =
        GLFW.glfwSwapInterval(0)

    pub def step(frame: App.Frame, w: World): World \ IO =
        if (w#done) w
        else {
            if (w#frameInSegment < warmupOf(w#segment)) vsyncOff() else ();
            let sampled =
                if (w#frameInSegment >= warmupOf(w#segment)) frame#dt :: w#samples
                else w#samples;
            let t = w#t + frame#dt;
            if (w#frameInSegment + 1 >= framesPerSegment()) {
                report(countOf(w#segment), sampled);
                let next = w#segment + 1;
                { t = t, segment = next, frameInSegment = 0, samples = Nil,
                  done = next >= segmentCount() }
            } else {
                { t = t, frameInSegment = w#frameInSegment + 1, samples = sampled | w }
            }
        }

    def report(n: Int32, samples: List[Float64]): Unit \ IO =
        match List.length(samples) {
            case 0     => println("N=${n} samples=0")
            case count =>
                let avg = List.foldLeft((acc, x) -> acc + x, 0.0, samples) / Int32.toFloat64(count);
                let p99 = List.sort(samples)
                    |> List.drop(Int32.min(count - 1, count * 99 / 100))
                    |> List.head
                    |> Option.getWithDefault(avg);
                println("N=${n} avg=${fmt2(avg * 1000.0)}ms p99=${fmt2(p99 * 1000.0)}ms fps=${RenderUtil.floatToInt32(1.0 / avg)}")
        }

    /// Float64 をそのまま補間すると桁が長すぎてログが読めないため、小数 2 桁で切る。
    def fmt2(x: Float64): String =
        let cents = RenderUtil.floatToInt32(x * 100.0);
        let frac = Int32.modulo(cents, 100);
        let fracText = if (frac < 10) "0${frac}" else "${frac}";
        "${cents / 100}.${fracText}"

    // ── World → 絵 ──

    def zBox(): Int32 = 5
    def zSprite(): Int32 = 10
    def zText(): Int32 = 100

    pub def view(ctx: App.ViewCtx, w: World): List[Render.PlacedItem] =
        List.append(movers(countOf(w#segment), w#t), texts(ctx#atlas, w))

    def movers(n: Int32, t: Float64): List[Render.PlacedItem] =
        List.range(0, n) |> List.map(i -> placedOf(i, t))

    def fract(x: Float64): Float64 = x - Float64.floor(x)

    /// 軌道の半径・速さ・位相は黄金比の端数で i ごとにばらす。規則的な格子だと
    /// 同じ場所に重なって描画の仕事量が偏り、負荷として当てにならないため。
    def placedOf(i: Int32, t: Float64): Render.PlacedItem =
        let fi = Int32.toFloat64(i);
        let radius = 14.0 + 128.0 * fract(fi * 0.61803);
        let angle = fi * 2.39996 + t * (0.4 + 1.6 * fract(fi * 0.2716));
        let center = { x = 160.0 + RenderUtil.cosF(angle) * radius,
                       y = 120.0 + RenderUtil.sinF(angle) * radius * 0.72 };
        if (Int32.modulo(i, 2) == 0)
            RawDraw.boxAt(center, { x = 4.0, y = 4.0 }, colorOf(i / 2), zBox())
        else
            { at = center, item = Render.sprite("flag", zSprite()) }

    def colorOf(k: Int32): Color =
        match Int32.modulo(k, 4) {
            case 0 => { r = 0.86, g = 0.30, b = 0.29 }
            case 1 => { r = 0.42, g = 0.72, b = 0.34 }
            case 2 => { r = 0.35, g = 0.55, b = 0.87 }
            case _ => { r = 0.91, g = 0.75, b = 0.32 }
        }

    /// HUD あり構成（HUD=1 で有効）の絵。withHudView 経由なので z は HUD の範囲
    /// （ZBand.hudBase 以上）へ持ち上がり、mergedByZ が範囲別 2 段階ソートに入る —
    /// 範囲が混ざってもスロット方式（counting sort）に乗り続けるかを HUD 無しとの A/B で見る。
    pub def hud(ctx: App.ViewCtx, w: World): List[Render.PlacedItem] =
        RawDraw.boxAt({ x = 160.0, y = 228.0 }, { x = 300.0, y = 16.0 },
            { r = 0.10, g = 0.10, b = 0.14 }, 0)
        :: { at = { x = 14.0, y = 222.0 },
             item = Render.textTinted("HUD SEG=${w#segment + 1} N=${countOf(w#segment)}",
                 ctx#atlas, 9.0, { r = 0.95, g = 0.85, b = 0.40 }, 1) }
        :: { at = { x = 200.0, y = 222.0 },
             item = Render.textTinted("BAND CHECK", ctx#atlas, 9.0,
                 { r = 0.60, g = 0.90, b = 0.60 }, 1) }
        :: Nil

    /// SDF テキストの負荷は文字数で決まるので、毎フレームほぼ一定（約 300 文字）に固定する。
    def texts(atlas: FontAtlas, w: World): List[Render.PlacedItem] =
        let lines =
            "N=${countOf(w#segment)} SEG=${w#segment + 1}/${segmentCount()} F=${w#frameInSegment}" ::
            "T=${fmt2(w#t)}S SAMPLES=${List.length(w#samples)}" ::
            "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG 01" ::
            "PACK MY BOX WITH FIVE DOZEN LIQUOR JUGS 23456" ::
            "SPHINX OF BLACK QUARTZ JUDGE MY VOW 7890 ABCD" ::
            "HOW VEXINGLY QUICK DAFT ZEBRAS JUMP 4321 EFGH" ::
            "WALTZ BAD NYMPH FOR QUICK JIGS VEX 5678 IJKLM" ::
            "JACKDAWS LOVE MY BIG SPHINX OF QUARTZ 90 NOPQ" :: Nil;
        lines |> List.mapWithIndex((k, line) ->
            { at = { x = 4.0, y = 12.0 + 11.0 * Int32.toFloat64(k) },
              item = Render.textTinted(line, atlas, 9.0,
                                       { r = 0.92, g = 0.92, b = 0.95 }, zText()) })
}
