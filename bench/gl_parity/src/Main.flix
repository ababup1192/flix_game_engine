// 入口。同じ scene 宣言（Scenes）を GL と SoftRaster の両方で 1 コマ描き出し、画素を突き合わせて
// 1 行 1 scene の表を出す。A 段階（バイト一致層）に不一致があれば exit 1。
//
// GL の絵はリファレンス画像化しない — 基準は「もう片方の経路」であって過去の絵ではない
// （過去の絵との突き合わせは templates の reference-check / reference-update の役目）。
use fge::GameEngine

mod ParityMain {
    use fge::{
        Color, FontAtlas, GameEngine, GlReadback, GpuHandle, HeadlessFont, HeadlessRender,
        LwjglLayer, Render, RenderTarget, ShaderEffect
    }

    import java.io.File
    import java.lang.System

    def ttf(): String = "assets/Xolonium-Regular.ttf"

    def black(): Color = { r = 0.0, g = 0.0, b = 0.0 }

    /// 投影の共通 1 関数。GL / SoftRaster の両側が必ずここを通る — withoutShaders を
    /// 通し忘れた側だけ代表色ベタ塗りが二重に乗り、harness 自身のバグが「経路差」に
    /// 化けるので、外す場所を 2 つに増やさない。
    def toDraw(texInfoOf: String -> Option[GameEngine.TextureInfo] \ ef,
               items: List[Render.PlacedItem]):
            (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd]) \ ef =
        Render.drawWith(texInfoOf, Render.withoutShaders(items))

    // ── GL 側（隠しウィンドウの中で 1 scene = 1 コマ）──

    def glShoot(sc: Scenes.Scene): Unit \ IO + GameEngine.Game + ShaderEffect.Shader + RenderTarget.Target =
        let texInfoOf = name -> GameEngine.Game.getTextureInfo(name);
        List.forEach(p -> {
            RenderTarget.Target.beginTarget(p#name, Scenes.designWi(), Scenes.designHi(), p#clear);
            let (pds, pps) = toDraw(texInfoOf, p#items);
            GameEngine.Game.renderCommands(pds, Nil, pps, None);
            RenderTarget.Target.endTarget()
        }, sc#passes);
        match sc#via {
            case Scenes.ShotVia.ViaTarget =>
                // target 分岐は swap しないので、endTarget の前に bind 中の FBO を読める。
                RenderTarget.Target.beginTarget("parityShot", Scenes.designWi(), Scenes.designHi(),
                    RenderTarget.LoadOp.Clear(black()));
                let (ds, ps) = toDraw(texInfoOf, sc#items);
                GameEngine.Game.renderCommands(ds, Nil, ps, None);
                GlReadback.readBoundPng(Scenes.designWi(), Scenes.designHi(), "debug/gl/${sc#name}.png");
                RenderTarget.Target.endTarget()
            case Scenes.ShotVia.ViaScreen =>
                // 画面の絵は swap 後に読めないため、FLIX_GE_FRAME_SHOT（swap 直前のフック）が
                // debug/gl/frame-<n>.png へ落とす。名前への対応は renameFrames が引き受ける。
                let cmds = Render.drawShaders(spec -> ShaderEffect.Shader.buildProgram(spec), sc#items);
                List.forEach(c -> ShaderEffect.Shader.drawSurface(c), cmds);
                let (ds, ps) = toDraw(texInfoOf, sc#items);
                GameEngine.Game.renderCommands(ds, Nil, ps, None)
        }

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
        // （pass は常に design 寸なので、名前さえ分かれば寸法は決まる）。
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

    def softShoot(cfg: HeadlessRender.RenderConfig, sc: Scenes.Scene): Unit \ IO =
        match sc#via {
            case Scenes.ShotVia.ViaTarget =>
                let (ds, ps) = toDraw(softTexInfo, sc#items);
                let spec: HeadlessRender.PassSpec =
                    { name = sc#name, clear = RenderTarget.LoadOp.Clear(black()),
                      drawables = ds, polygons = ps };
                PixelDiff.writePng(HeadlessRender.renderPassImage(cfg, spec, None), "debug/soft/${sc#name}.png")
            case Scenes.ShotVia.ViaScreen =>
                let passSpecs = sc#passes |> List.map(p -> Render.passSpecOf(softTexInfo, p));
                let surfaces = Render.shaderSurfaces(sc#items);
                let (ds, ps) = toDraw(softTexInfo, sc#items);
                HeadlessRender.renderPngWithPasses(cfg, passSpecs, ds, ps, surfaces, sc#name)
        }

    // ── 表と exit code ──

    /// 表の 1 行。行頭タグ・列順は回帰の grep が読むので変えない（pin）。
    def line(o: PixelDiff.Outcome): String =
        let padded = pad(o#name, 14);
        if (o#diffPx == 0) "[parity] ${padded} A  一致 (0 px)"
        else if (o#diffPx < 0) "[parity] ${padded} A  比較不能"
        else "[parity] ${padded} A  差 ${o#diffPx} px, max ±${o#maxDelta}"

    def pad(s: String, n: Int32): String =
        if (String.length(s) >= n) s else pad(s + " ", n)

    pub def go(): Unit \ IO =
        run {
            Scenes.all() |> List.forEach(sc -> glShoot(sc))
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO;
        renameFrames();
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let cfg = cfgOf(atlas);
        Scenes.all() |> List.forEach(sc -> softShoot(cfg, sc));
        let outcomes = Scenes.all() |> List.map(sc ->
            PixelDiff.compare(sc#name, "debug/gl/${sc#name}.png",
                "debug/soft/${sc#name}.png", "debug/diff/${sc#name}.png"));
        List.forEach(o -> println(line(o)), outcomes);
        if (List.exists(o -> o#diffPx != 0, outcomes)) System.exit(1) else ()
}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else ParityMain.go()
