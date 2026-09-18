// GifRender — README のショーケース用 GIF を画面なしで生成する（スナップショットの外・debug/ 行き）。
// 実行: flix run --entrypoint GifRender.all → debug/showcase.gif
// 積み上げた盤の 1 列だけを空けておき、そこへ I ミノを縦に落として 4 行消し（テトリス）を
// 実演する決定的な台本。SceneRender.flix の静止画とは別に、動きを見せたい GIF だけをここに分ける
// （gallery/reference は静止画の比較専用なので、ここでは触らない）。
mod GifRender {
    import java.io.File

    def design(): Vec2.Vec2 = { x = 256.0, y = 352.0 }
    def ttf(): String = "assets/Xolonium-Regular.ttf"

    /// シミュレーションの1フレーム（30fps）。stride 2 で間引くので GIF は 15fps・66ms（SceneRender.flix と対）。
    def dt(): Float64 = 1.0 / 30.0

    def cfg(atlas: FontAtlas, bg: Color): HeadlessRender.RenderConfig =
        { design = design(), scale = 2, background = bg,
          fontTtf = ttf(), fontAtlas = atlas,
          outDir = "debug", frameW = 512, frameH = 704 | HeadlessRender.defaults() }

    def loadWorld(): World.World \ IO =
        run { World.initial(Controls.loadDocs()) } with Fs.FileRead.runWithIO

    /// 本番と同じ絵の合成（View.frame + View.hud → App.composeScene → Render.draw）。
    /// 生成の仕方が2通りだと絵がずれるので、SceneRender.flix の静止画もこの GIF も同じ式を通す。
    pub def worldCmds(ctx: App.ViewCtx, w: World.World):
            (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd]) =
        Render.draw(App.composeScene(None, 1.0, design(),
            { world = View.frame(ctx, w), hud = View.hud(ctx, w) }))

    pub def all(): Unit \ IO =
        discard (new File("debug")).mkdirs();
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let w0 = loadWorld();
        let bcfg = cfg(atlas, ThemeDoc.rec(w0#theme)#bg);
        let ctx = App.viewCtxOf(atlas, design());
        discard HeadlessRender.renderGif(bcfg, script(w0), 2, w -> worldCmds(ctx, w), "showcase");
        println("rendered: debug/showcase.gif")

    // ── 台本（純粋な World.step を畳み込んで World の列を作る）──

    /// current を挿げ替えてから hardDrop に落とす（spawn は row = -1 の空中なので
    /// rot/col をどう据えても衝突しない = 本物の落下・接地・固定と同じ経路を通る）。
    /// 盤のセルを直接 Map.insert するのはやめ、実際に置ける並びだけを作る。
    def placePiece(kind: World.Kind, rot: Int32, col: Int32, w: World.World): World.World =
        World.hardDrop({ current = { kind = kind, rot = rot, col = col, row = -1 } | w })

    /// 下 4 行・右端の 1 列（col 9）だけを空けて積む台本。
    /// 下 4 行（col 0-8 の 36 マス）は J/L/S/Z/T を主役に隙間なく敷き詰める
    /// （I・O は使わない・厳密な exact-cover 探索で「実際に hardDrop で積める順」まで
    /// 割り出した並び — 同じ形・同じ向きの反復が見えないよう検証済み）。
    /// その上に T/S/Z/J/L を色々な向きで積んで表面をでこぼこにする（I/O だけの
    /// 機械的な縦帯 x 横帯の反復にしない）。
    def stackScript(): List[(World.Kind, Int32, Int32)] =
        // 下 4 行（col 0-8 を J/L/S/Z/T だけで平らに埋める・col 9 は最後まで空けておく）。
        // J(逆さ)を右端の足場に、L を左端の足場に、J を中央に噛ませて土台を作り、
        // T で凹みを均し、S を縦向き 1 個混ぜて高さの差を作り、Z で右肩を埋め、
        // もう 1 個の T で右上の凸を作り、最後に S と L で左側の残りを詰める。
        (World.Kind.J, 3, 7) :: (World.Kind.L, 0, 0) :: (World.Kind.J, 0, 3) ::
        (World.Kind.T, 2, 5) :: (World.Kind.S, 3, 3) :: (World.Kind.Z, 0, 4) ::
        (World.Kind.T, 2, 6) :: (World.Kind.S, 0, 0) :: (World.Kind.L, 2, 0) ::
        // 上乗せ（でこぼこ）: T を列 0-2 に、L を列 3-5 に、S を列 6-8 に、
        // Z を列 2-4 にまたがせて（尖った側が浮いて穴が 1 つできる）、
        // J を縦向きで列 7-8 に重ねて一番高い山にする。
        (World.Kind.T, 0, 0) :: (World.Kind.L, 0, 3) :: (World.Kind.S, 0, 6) ::
        (World.Kind.Z, 0, 2) :: (World.Kind.J, 3, 7) :: Nil

    /// stackScript を順に hardDrop して積み上げた World（col 9 はまだ空）。
    def buildStackedWorld(w0: World.World): World.World =
        stackScript() |> List.foldLeft((w, step) -> {
            let (kind, rot, col) = step;
            placePiece(kind, rot, col, w)
        }, w0)

    /// 積み上がった盤 + 空いた列の真上に構えた I ミノ（縦向き・rot 1）から始める。
    def scriptWorld(w0: World.World): World.World =
        let stacked = buildStackedWorld(w0);
        { current = { kind = World.Kind.I, rot = 1, col = 7, row = -1 },
          nextKind = World.Kind.O,
          phase = World.Phase.Playing,
          gravityTimer = 0.0, lockTimer = 0.0, grounded = false, lockResets = 0,
          score = 0, lines = 0 | stacked }

    /// World.step を n フレーム畳み込んで列を作る（純粋）。softDrop = true で終始加速し、
    /// 短い GIF の中で「落下 → 接地 → 固定 → 消去 → 次のミノ」まで収める。
    def unfold(n: Int32, w0: World.World): List[World.World] =
        let (revWs, _last) = List.range(0, n) |> List.foldLeft((acc, _i) -> {
            let (ws, w) = acc;
            let w1 = World.step(true, dt(), w);
            (w1 :: ws, w1)
        }, (w0 :: Nil, w0));
        List.reverse(revWs)

    /// 台本本体: 80 フレーム（約 2.7 秒分のシミュレーション）で、落下→接地→4 行消し→
    /// 次のミノの涌きまでを収める。
    def script(w0: World.World): List[World.World] =
        unfold(80, scriptWorld(w0))
}
