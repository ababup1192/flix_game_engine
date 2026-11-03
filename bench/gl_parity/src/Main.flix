// 入口。同じ scene 宣言（Scenes）を GL と SoftRaster の両方で 1 コマ描き出し、画素を突き合わせて
// 1 行 1 scene の表を出す。A 段階（バイト一致層）に不一致があるか、許容差のある B 段階（Scenes.toleranceOf）が上限を超えれば exit 1。
//
// GL の絵はリファレンス画像化しない — 基準は「もう片方の経路」であって過去の絵ではない
// （過去の絵との突き合わせは templates の reference-check / reference-update の役目）。
use fge::GameEngine

mod ParityMain {
    use fge::{
        App, Color, CpuTiming, FontAtlas, GameEngine, GlReadback, GpuHandle, HeadlessFont, HeadlessRender,
        LwjglLayer, Render, RenderTarget, ShaderEffect, SoftRaster
    }

    import java.io.File
    import java.lang.System
    import java.io.FileWriter

    def ttf(): String = "assets/Xolonium-Regular.ttf"

    def black(): Color = { r = 0.0, g = 0.0, b = 0.0 }

    /// ターゲット口の投影（面と 3D の場面を描かない口）。GL / SoftRaster の両側が必ずここを通る — 外し忘れた側だけ
    /// 代わりの矩形が乗り、harness 自身のバグが「経路差」に化けるので、外す場所を 2 つに増やさない。
    /// 画面口は外す所を engine の App.submitGpuItems（GL）と Render.softSceneOf（CPU）に任せる。
    def toDraw(texInfoOf: String -> Option[GameEngine.TextureInfo] \ ef,
               items: List[Render.PlacedItem]):
            (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd]) \ ef =
        Render.drawWith(texInfoOf, Render.withoutScenes3d(Render.withoutShaders(items)))

    // ── GL 側（隠しウィンドウの中で 1 scene = 1 コマ）──

    def glShoot(sc: Scenes.Scene): Unit \ IO + GameEngine.Game + ShaderEffect.Shader + RenderTarget.Target =
        let texInfoOf = name -> GameEngine.Game.getTextureInfo(name);
        // Pass は実機の毎コマと同じ App.drawPassPlan で描く（手順を写すと、実機と違う道を突き合わせることになる）。
        let design = { x = Scenes.designW(), y = Scenes.designH() };
        discard List.range(0, sc#repeats) |> List.foldLeft((known, _) ->
            App.drawPassPlan(_ -> (), design, known, planOf(sc)), Set.empty());
        match sc#via {
            case Scenes.ShotVia.ViaTarget =>
                // target 分岐は swap しないので、endTarget の前に bind 中の FBO を読める。
                RenderTarget.Target.beginTarget({ name = "parityShot", width = Scenes.designWi(), height = Scenes.designHi(),
                                                  format = RenderTarget.Format.Rgba8Unorm, clear = RenderTarget.LoadOp.Clear(black()), samples = 1 });
                let (ds, ps) = toDraw(texInfoOf, sc#items);
                GameEngine.Game.renderCommands(ds, Nil, ps, None);
                GlReadback.readBoundPng(Scenes.designWi(), Scenes.designHi(), "debug/gl/${sc#name}.png");
                RenderTarget.Target.endTarget()
            case Scenes.ShotVia.ViaScreen =>
                // 画面の絵は swap 後に読めないため、FLIX_GE_FRAME_SHOT（swap 直前のフック）が
                // debug/gl/frame-<n>.png へ落とす。名前への対応は renameFrames が引き受ける。
                App.submitGpuItems(_ -> (), sc#items, Nil, None)
        }

    def planOf(sc: Scenes.Scene): Render.PassPlan = { targets = sc#targets | Render.passPlan(sc#passes) }

    /// frame-<n>.png（FRAME_SHOT の通し番号）を scene 名へ付け替える。番号は
    /// 「画面口 scene の宣言順 = 画面フレームの順」で決まる（他に画面へ描く物は無い）。
    def renameFrames(): Unit \ IO =
        Scenes.all()
            |> List.filter(sc -> sc#via == Scenes.ShotVia.ViaScreen)
            |> List.forEachWithIndex((i, sc) -> {
                let src = new File("debug/gl/frame-${i + 1}.png");
                let dst = new File("debug/gl/${sc#name}.png");
                if (src.exists()) discard src.renameTo(dst)
                else println("[parity] 画面口の絵が無い: debug/gl/frame-${i + 1}.png (${sc#name})")
            })

    // ── SoftRaster 側（headless。GL と同じ scene 宣言から描き出す）──

    /// SoftRaster 側の寸法引き（実機の getTextureInfo に当たる口の headless 版）。
    def softTexInfo(name: String): Option[GameEngine.TextureInfo] =
        if (name == "atlas")
            Some({ id = GpuHandle.wrapTextureId(0),
                   width = Scenes.atlasSide(), height = Scenes.atlasSide() })
        // pass 名は Scenes の宣言から引く — ここに名前を書き足す二重管理をしない
        // （pass は縮んでいても registry に design 寸で載るので、名前さえ分かれば寸法は決まる）。
        else if (List.memberOf(name, Scenes.passNames()))
            Some({ id = GpuHandle.wrapTextureId(0),
                   width = Scenes.designW(), height = Scenes.designH() })
        else None

    /// 縁のつまみ（shapeAntialias / textAntialias）は既定のまま。ここは GL と SoftRaster の
    /// 差だけを見る場なので、片方だけ切ると差がどちら由来か読めなくなる。
    def cfgOf(atlas: FontAtlas): HeadlessRender.RenderConfig =
        { design = { x = Scenes.designW(), y = Scenes.designH() }, scale = 1,
          background = black(),
          texturePath = Map#{"atlas" => "assets/atlas.png"},
          fontTtf = ttf(), fontAtlas = atlas, outDir = "debug/soft",
          frameW = Scenes.designWi(), frameH = Scenes.designHi() | HeadlessRender.defaults() }

    /// ターゲット口の scene を 1 枚の pass として描く指定。
    def targetSpecOf(sc: Scenes.Scene): HeadlessRender.PassSpec =
        let (ds, ps) = toDraw(softTexInfo, sc#items);
        { name = sc#name, clear = RenderTarget.LoadOp.Clear(black()),
          drawables = ds, polygons = ps, surfaces = Nil, scenes = Nil, target = RenderTarget.defaultDescriptor() }

    /// 画面口の scene を、pass と 3D の場面ごと描き出しの 1 枚にした物。
    def screenSceneOf(sc: Scenes.Scene): HeadlessRender.Scene =
        let passSpecs = Render.passSpecsOf(softTexInfo, planOf(sc))#specs;
        let soft = Render.softSceneOf(softTexInfo, sc#items);
        { passes = passSpecs, drawables = soft#drawables, polygons = soft#polygons,
          surfaces = soft#surfaces, scenes = soft#scenes, fonts = Map.empty(), fontAntialias = Map.empty() }

    def softShoot(cfg: HeadlessRender.RenderConfig, sc: Scenes.Scene): Unit \ IO =
        match sc#via {
            case Scenes.ShotVia.ViaTarget =>
                PixelDiff.writePng(SoftRaster.toArgbImage(HeadlessRender.renderPassImage(cfg, targetSpecOf(sc), None)), "debug/soft/${sc#name}.png")
            case Scenes.ShotVia.ViaScreen =>
                HeadlessRender.renderPngFull(cfg, screenSceneOf(sc), sc#name)
        }

    /// scene を CPU で 1 枚描く（書き出さない・描き出しのキャッシュを通さない）。返すのは描いた絵の幅（測った仕事を捨てないため）。
    def softPaint(cfg: HeadlessRender.RenderConfig, sc: Scenes.Scene): Int32 \ IO =
        match sc#via {
            case Scenes.ShotVia.ViaTarget => fst(SoftRaster.passImageSize(HeadlessRender.renderPassImage(cfg, targetSpecOf(sc), None)))
            case Scenes.ShotVia.ViaScreen => HeadlessRender.renderImageFull(cfg, screenSceneOf(sc)).getWidth()
        }

    /// 速さの測り方。温めの 3 回で JIT を温め、9 回の中央値を取る（1 回ごとに絵の読み込みも入る。描き出しの 1 枚と同じ仕事）。
    def timingPlan(): CpuTiming.Plan = { warmup = 3, runs = 9 }

    /// 全部の scene の CPU の描く時間（中央値・最小・最大のミリ秒）を 1 行ずつ出し、build/cpu-time.tsv にも書く（build/ は git に入れない）。窓は開かない。
    pub def timeSoft(): Unit \ IO =
        let cfg = cfgOf(HeadlessFont.buildUiAtlas(ttf(), ttf()));
        let rows = Scenes.all() |> List.map(sc -> {
            let (summary, _) = CpuTiming.measure(timingPlan(), () -> softPaint(cfg, sc));
            "${sc#name}\t${ms(summary#median)}\t${ms(summary#min)}\t${ms(summary#max)}"
        });
        List.forEach(row -> println("[cpu] ${row}"), rows);
        let out = new FileWriter("build/cpu-time.tsv");
        out.write(String.intercalate("\n", "# scene\t中央値 ms\t最小\t最大" :: rows) + "\n");
        out.close()

    /// ミリ秒を小数 2 桁の字にする（そのまま文字列に埋めると桁が長すぎて読めない）。
    def ms(v: Float64): String = Float64.toString(Float64.round(v * 100.0) / 100.0)

    // ── 表と exit code ──

    /// 表の 1 行。行頭タグ・列順は回帰の grep が読むので変えない（pin）。許容差のある scene は末尾に上限を添える。
    def line(exact: Bool, o: PixelDiff.Outcome): String =
        let padded = pad(o#name, 14);
        let stage = if (exact) "A" else "B";
        let atMost = Scenes.toleranceOf(o#name) |> Option.map(n -> " (許容 ${n} px)") |> Option.getWithDefault("");
        let atLeast = Scenes.minDiffOf(o#name) |> Option.map(n -> " (最小 ${n} px)") |> Option.getWithDefault("");
        let limit = atMost + atLeast;
        if (o#diffPx == 0) "[parity] ${padded} ${stage}  一致 (0 px)${limit}"
        else if (o#diffPx < 0) "[parity] ${padded} ${stage}  比較不能${limit}"
        else "[parity] ${padded} ${stage}  差 ${o#diffPx} px, max ±${o#maxDelta}${limit}"

    /// 落とす scene か: A 段階は 1 px でも違えば・許容差のある B 段階は上限を超えるか比べられなければ・
    /// 最小の差を持つ scene は差がそれに届かなければ（GL の側だけの効き目が出ていない）。
    def failed(exact: Bool, o: PixelDiff.Outcome): Bool =
        let tooFew = Scenes.minDiffOf(o#name) |> Option.exists(least -> o#diffPx < least);
        tooFew or (match Scenes.toleranceOf(o#name) {
            case Some(limit) => o#diffPx < 0 or o#diffPx > limit
            case None        => exact and o#diffPx != 0
        })

    def pad(s: String, n: Int32): String =
        if (String.length(s) >= n) s else pad(s + " ", n)

    /// sc を GL で撮り、描いた置いた物の数の期待値（Scenes.expectedDrawnOf）がある scene だけ、その数を確かめた 1 行を返す。
    def glShootCounted(sc: Scenes.Scene): Option[(String, Bool)] \ IO + GameEngine.Game + ShaderEffect.Shader + RenderTarget.Target =
        discard GameEngine.Game.consumeDiagnostics();
        glShoot(sc);
        Scenes.expectedDrawnOf(sc#name) |> Option.map(expected -> {
            let drawn = GameEngine.Game.consumeDiagnostics()#scene3dCounts#drawn;
            let ok = drawn == expected;
            let verdict = if (ok) "一致" else "違う";
            ("[parity] ${pad(sc#name, 14)} 描いた数 ${Int32.toString(drawn)}（期待 ${Int32.toString(expected)}）${verdict}", ok)
        })

    pub def go(): Unit \ IO =
        let counted = run {
            GameEngine.Game.setDiagnosticsEnabled(true);
            Scenes.all() |> List.filterMap(sc -> glShootCounted(sc))
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO;
        renameFrames();
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let cfg = cfgOf(atlas);
        Scenes.all() |> List.forEach(sc -> softShoot(cfg, sc));
        let outcomes = Scenes.all() |> List.map(sc ->
            (sc#exact, PixelDiff.compare(sc#name, "debug/gl/${sc#name}.png",
                "debug/soft/${sc#name}.png", "debug/diff/${sc#name}.png")));
        List.forEach(eo -> { let (exact, o) = eo; println(line(exact, o)) }, outcomes);
        List.forEach(c -> println(fst(c)), counted);
        if (List.exists(eo -> { let (exact, o) = eo; failed(exact, o) }, outcomes) or List.exists(c -> not snd(c), counted)) System.exit(1) else ()
}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else ParityMain.go()
