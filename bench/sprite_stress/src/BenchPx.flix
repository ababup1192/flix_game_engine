// BenchPx — PxSprite の「box 列(既定)」vs「アトラス 1 クアッド(opt-in)」を
// 同数・同 sprite・同軌道で A/B する負荷世界。区間ごとにモードを交互に切り替えるので、
// 1 回の実行で背中合わせのペアが取れる(RESULTS.md の計測の流儀)。
// 実行:
//   ../../bin/flix run --entrypoint BenchPx.bakeAtlas   … アトラス PNG を作る(1 回だけ)
//   ../../bin/flix run --entrypoint BenchPx.bench          … ベンチ本体(6 区間・自動終了)
// アトラスは project.json の "px_atlas"(assets/sprites/px_atlas.png)として起動時に
// 読み込まれる — GL 実行時とヘッドレス(bakeAtlas の PNG)が同一ソース(PxSpriteAtlas.bake)。
mod BenchPx {
    use fge::{
        App, Color, GameEngine, LwjglLayer, PxSprite, PxSpriteAtlas, PxSpriteDoc, Render,
        RenderUtil, SoftRaster, Vec2
    }

    import org.lwjgl.glfw.GLFW

    pub type alias World = {
        t = Float64,
        segment = Int32,
        frameInSegment = Int32,
        samples = List[Float64],
        done = Bool,
        doc = PxSpriteDoc.Doc,
        baked = PxSpriteAtlas.Baked
    }

    def spritePath(): String = "assets/bench.sprite.json"

    def atlasPng(): String = "assets/sprites/px_atlas.png"

    /// 村の themeResolver 相当(固定色 — 計測なので色は何でもよいが、両モードで同一にする)。
    def resolver(key: String): Color =
        match key {
            case "hair" => { r = 0.18, g = 0.14, b = 0.12 }
            case "skin" => { r = 0.91, g = 0.76, b = 0.63 }
            case _      => { r = 0.24, g = 0.36, b = 0.60 }
        }

    /// アトラス PNG を作る(決定的)。project.json がこれを起動時に読む。
    pub def bakeAtlas(): Unit \ IO =
        let doc = run { PxSpriteDoc.load(spritePath()) } with Fs.FileRead.runWithIO;
        let baked = PxSpriteAtlas.bake(doc, resolver);
        SoftRaster.writeRadialPng(baked#side, (x, y) -> PxSpriteAtlas.pixelAt(baked, x, y), atlasPng());
        println("baked: ${atlasPng()} (${baked#side}x${baked#side}, ${Map.size(baked#regions)} frames)")

    pub def bench(): Unit \ IO =
        if (GameEngine.ensureMainThread()) ()
        else {
            let doc = run { PxSpriteDoc.load(spritePath()) } with Fs.FileRead.runWithIO;
            let baked = PxSpriteAtlas.bake(doc, resolver);
            run {
                App.make(initialWorld(doc, baked))
                    |> App.addSystem(step)
                    |> App.withView((ctx, w) -> checked_ecast(view(ctx, w)))
                    |> App.quitWhen((_frame, w) -> checked_ecast(w#done))
                    |> App.launch
            } with LwjglLayer.withProject(".")
              with Fs.FileRead.runWithIO
              with Fs.FileWrite.runWithIO
              with Fs.Glob.runWithIO
              with Fs.ModificationTime.runWithFileTime
              with Fs.FileTime.runWithIO
        }

    pub def initialWorld(doc: PxSpriteDoc.Doc, baked: PxSpriteAtlas.Baked): World =
        { t = 0.0, segment = 0, frameInSegment = 0, samples = Nil, done = false,
          doc = doc, baked = baked }

    // ── 区間の台本: (体数, 1 クアッドか) — box/quad を背中合わせに並べる ──

    def segments(): List[(Int32, Bool)] =
        (500, false) :: (500, true) ::
        (1900, false) :: (1900, true) ::
        (5000, false) :: (5000, true) :: Nil

    def segmentCount(): Int32 = List.length(segments())

    def segmentOf(i: Int32): (Int32, Bool) =
        segments() |> List.drop(i) |> List.head |> Option.getWithDefault((0, false))

    def framesPerSegment(): Int32 = 150

    def warmupOf(segment: Int32): Int32 =
        if (segment == 0) 60 else 30

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
                let (n, quad) = segmentOf(w#segment);
                report(n, quad, sampled);
                let next = w#segment + 1;
                { t = t, segment = next, frameInSegment = 0, samples = Nil,
                  done = next >= segmentCount() | w }
            } else {
                { t = t, frameInSegment = w#frameInSegment + 1, samples = sampled | w }
            }
        }

    def report(n: Int32, quad: Bool, samples: List[Float64]): Unit \ IO =
        let mode = if (quad) "quad" else "box";
        match List.length(samples) {
            case 0     => println("N=${n} mode=${mode} samples=0")
            case count =>
                let avg = List.foldLeft((acc, x) -> acc + x, 0.0, samples) / Int32.toFloat64(count);
                let p99 = List.sort(samples)
                    |> List.drop(Int32.min(count - 1, count * 99 / 100))
                    |> List.head
                    |> Option.getWithDefault(avg);
                println("N=${n} mode=${mode} avg=${fmt2(avg * 1000.0)}ms p99=${fmt2(p99 * 1000.0)}ms fps=${RenderUtil.floatToInt32(1.0 / avg)}")
        }

    def fmt2(x: Float64): String =
        let cents = RenderUtil.floatToInt32(x * 100.0);
        let frac = Int32.modulo(cents, 100);
        let fracText = if (frac < 10) "0${frac}" else "${frac}";
        "${cents / 100}.${fracText}"

    // ── World → 絵(Bench.movers と同じ黄金比軌道・全部スプライト)──

    def fract(x: Float64): Float64 = x - Float64.floor(x)

    pub def view(_ctx: App.ViewCtx, w: World): List[Render.PlacedItem] =
        let (n, quad) = segmentOf(w#segment);
        List.range(0, n) |> List.flatMap(i -> {
            let fi = Int32.toFloat64(i);
            let radius = 14.0 + 96.0 * fract(fi * 0.61803);
            let angle = fi * 2.39996 + w#t * (0.4 + 1.6 * fract(fi * 0.2716));
            let at: Vec2.Vec2 = { x = 160.0 + RenderUtil.cosF(angle) * radius,
                                  y = 120.0 + RenderUtil.sinF(angle) * radius * 0.72 };
            let frame = if (Int32.modulo(i, 2) == 0) "walk0" else "walk1";
            let flip = Int32.modulo(i, 3) == 0;
            if (quad)
                PxSprite.drawQuad(w#doc, w#baked, "px_atlas", "villager", frame, at, flip, 1, 10)
            else
                PxSprite.draw(w#doc, "villager", frame, at, flip, 1, resolver, 10)
        })
}
