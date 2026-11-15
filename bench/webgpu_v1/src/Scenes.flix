// GL と WebGPU の両方で描く場面。WebGPU が描く物（スプライト・字・箱・Pass・生成の絵・多角形・タイルの層・static layer・Pass の history・MSAA・
// mask つきスプライト・面）だけで組む。3D の場面は、GL でも画素を変えない空の場面だけを置く（sceneBetween）。
// 箱・スプライト・幕・放射の 4 つは bench/gl_parity の同じ名前の場面と同じ中身（色は 8 bit で割り切れる k/255）。
// lint-view: 対象外 — GL と WebGPU の描き手の画素の一致を見る門の場面。丸めの差を混ぜないよう単色の箱を主にしている。画面に出す絵ではない。
mod V1Scenes {

    /// 1 場面。passes = 本編より先に描く Pass・items = 本編の描き物（生成の絵を上げる物は、ここで ensureTexture を呼ぶ）。
    /// tiles = 本編のタイルの層（ここで initTileBuffer を呼ぶ）・staticLayer = 本編の static layer。
    /// submits = 描いたコマの submit の数の期待（None = 見ない）。
    /// warmup = 比べるコマの前に描くコマ（コマごとに Pass と描き先の作り方を替える。本編は同じ物）。比べるのは最後のコマだけ。
    pub type alias Scene = {
        name = String,
        warmup = List[Step],
        tiles = Unit -> List[GameEngine.TileMapRenderCmd] \ Platform.GpuResources,
        staticLayer = Option[GameEngine.StaticLayerCmd],
        passes = List[Render.Pass],
        // Pass の名前 → 描き先の作り方（無い名前は既定の作り方）。
        targets = Map[String, RenderTarget.Descriptor],
        items = Unit -> List[Render.PlacedItem] \ Platform.GpuResources,
        submits = Option[Int32]
    }

    /// 比べるコマの前に描く 1 コマの Pass と、その描き先の作り方。
    pub type alias Step = { passes = List[Render.Pass], targets = Map[String, RenderTarget.Descriptor] }

    pub def designW(): Float64 = 320.0

    pub def designH(): Float64 = 180.0

    pub def all(): List[Scene] =
        boxes() :: spriteNearest() :: veil() :: radial() :: text() :: passPaste() :: passHalf() :: generated() :: passThenGenerated() ::
        polygons() :: polygonPass() :: tiles() :: staticLayer() :: polygonFlood() ::
        historyFade() :: historyLate() :: historyKeep() :: msaaPass() :: msaaTwo() :: msaaOff() :: msaaKeep() :: msaaToggle() ::
        maskBasic() :: maskNested() :: maskPass() :: maskMsaa() :: maskOverflow() :: sceneBetween() ::
        surfaceFill() :: surfaceBetween() :: surfaceTexture() :: surfaceMask() :: surfacePass() :: surfaceMsaa() ::
        surfaceAfterOverflow() :: surfaceHistory() :: Nil

    def c8(r: Int32, g: Int32, b: Int32): Color =
        { r = Int32.toFloat64(r) / 255.0, g = Int32.toFloat64(g) / 255.0, b = Int32.toFloat64(b) / 255.0 }

    def at(x: Float64, y: Float64, item: Render.Item): Render.PlacedItem =
        { at = { x = x, y = y }, item = item }

    def still(items: List[Render.PlacedItem]): Unit -> List[Render.PlacedItem] \ Platform.GpuResources =
        () -> checked_ecast(items)

    def noTiles(): Unit -> List[GameEngine.TileMapRenderCmd] \ Platform.GpuResources = () -> checked_ecast(Nil)

    // ── 箱（塗り・並び順・blend の式・軸に沿った縞・市松）──

    def boxes(): Scene =
        { name = "boxes", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(8.0, 8.0, RawDraw.box({ x = 16.0, y = 16.0 }, c8(255, 64, 64), 10)) ::
            at(40.0, 30.0, RawDraw.box({ x = 80.0, y = 60.0 }, c8(40, 80, 200), 1)) ::
            at(80.0, 60.0, RawDraw.box({ x = 80.0, y = 60.0 }, c8(40, 180, 90), 2)) ::
            at(180.0, 20.0, RawDraw.box({ x = 60.0, y = 40.0 }, c8(60, 60, 60), 1)) ::
            at(200.0, 30.0, RawDraw.box({ x = 60.0, y = 40.0 }, c8(120, 80, 40), 2) |> Render.blended(DrawCmd.BlendMode.Add)) ::
            at(180.0, 90.0, RawDraw.box({ x = 60.0, y = 40.0 }, c8(255, 255, 255), 1)) ::
            at(200.0, 100.0, RawDraw.box({ x = 60.0, y = 40.0 }, c8(100, 100, 100), 2) |> Render.blended(DrawCmd.BlendMode.Multiply)) ::
            at(20.0, 130.0, RawDraw.box({ x = 48.0, y = 40.0 }, c8(200, 60, 140), 3)
                |> Render.striped({ color = c8(255, 255, 255), alpha = 1.0, width = 4.0, period = 8.0, dir = 1 })) ::
            at(80.0, 130.0, RawDraw.box({ x = 48.0, y = 40.0 }, c8(60, 140, 200), 3)
                |> Render.striped({ color = c8(255, 255, 255), alpha = 1.0, width = 4.0, period = 8.0, dir = 2 })) ::
            at(140.0, 130.0, RawDraw.box({ x = 48.0, y = 40.0 }, c8(220, 180, 60), 3)
                |> Render.checker({ color = c8(0, 0, 0), alpha = 1.0, cell = 4.0 })) ::
            at(260.0, 130.0, Render.Item.Clipped({ rect = { position = { x = 0.0, y = 0.0 }, size = { x = 20.0, y = 20.0 } },
                                                  inner = RawDraw.box({ x = 48.0, y = 40.0 }, c8(250, 250, 120), 3) })) ::
            Nil) }

    // ── 市松のアトラス（uv・NEAREST・反転・整数倍率・hasAlpha が偽の絵）──

    def atlasSprite(texture: String, spec: { srcPos = Vec2.Vec2, srcSize = Vec2.Vec2, sx = Float64, fH = Bool, fV = Bool }): Render.Item =
        Render.Item.Sprite({ texture = texture, tint = { r = 1.0, g = 1.0, b = 1.0 },
            alpha = 1.0, scale = { x = spec#sx, y = spec#sx }, rotation = 0.0, centered = true,
            flipH = spec#fH, flipV = spec#fV,
            regionRect = Some({ position = spec#srcPos, size = spec#srcSize }),
            zIndex = 1, blend = DrawCmd.BlendMode.Normal, maskPolys = Nil })

    def full(): Vec2.Vec2 = { x = 16.0, y = 16.0 }

    def origin(): Vec2.Vec2 = { x = 0.0, y = 0.0 }

    def spriteNearest(): Scene =
        { name = "spriteNearest", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(40.0, 40.0, atlasSprite("atlas", { srcPos = origin(), srcSize = full(), sx = 1.0, fH = false, fV = false })) ::
            at(80.0, 40.0, atlasSprite("atlas", { srcPos = origin(), srcSize = { x = 8.0, y = 8.0 }, sx = 2.0, fH = false, fV = false })) ::
            at(120.0, 40.0, atlasSprite("atlas", { srcPos = { x = 8.0, y = 0.0 }, srcSize = { x = 8.0, y = 8.0 }, sx = 3.0, fH = false, fV = false })) ::
            at(170.0, 40.0, atlasSprite("atlas", { srcPos = origin(), srcSize = full(), sx = 2.0, fH = true, fV = false })) ::
            at(220.0, 40.0, atlasSprite("atlas", { srcPos = origin(), srcSize = full(), sx = 2.0, fH = false, fV = true })) ::
            at(270.0, 40.0, atlasSprite("atlas", { srcPos = origin(), srcSize = full(), sx = 2.0, fH = true, fV = true })) ::
            at(80.0, 120.0, atlasSprite("atlas", { srcPos = { x = 8.0, y = 8.0 }, srcSize = { x = 8.0, y = 8.0 }, sx = 4.0, fH = false, fV = false })) ::
            at(170.0, 120.0, atlasSprite("atlas", { srcPos = { x = 4.0, y = 4.0 }, srcSize = { x = 8.0, y = 8.0 }, sx = 2.0, fH = false, fV = false })) ::
            at(250.0, 120.0, atlasSprite("atlasOpaque", { srcPos = origin(), srcSize = full(), sx = 3.0, fH = false, fV = false })) ::
            Nil) }

    // ── 半透明の幕（α 0.5）──

    def veil(): Scene =
        { name = "veil", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(20.0, 20.0, RawDraw.box({ x = 120.0, y = 80.0 }, c8(200, 120, 60), 1)) ::
            at(160.0, 40.0, RawDraw.box({ x = 100.0, y = 100.0 }, c8(40, 160, 220), 1)) ::
            at(60.0, 110.0, atlasSprite("atlas", { srcPos = origin(), srcSize = full(), sx = 4.0, fH = false, fV = false })) ::
            at(0.0, 0.0, RawDraw.box({ x = designW(), y = designH() }, c8(40, 20, 60), 10) |> Render.fade(0.5)) ::
            Nil) }

    // ── 組み込みの放射の絵（Render.lightAt の Add・darkAt の Multiply）──

    def radial(): Scene =
        { name = "radial", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(192.0, 0.0, RawDraw.box({ x = 128.0, y = 180.0 }, c8(255, 255, 255), 2)) ::
            Render.darkAt({ at = { x = 256.0, y = 128.0 }, radius = 128.0, strength = 1.0, z = 3 }) ::
            Render.lightAt({ at = { x = 128.0, y = 128.0 }, radius = 128.0, color = c8(255, 255, 255), strength = 1.0, z = 4 }) ::
            Render.lightAt({ at = { x = 174.0, y = 158.0 }, radius = 128.0, color = c8(255, 255, 255), strength = 1.0, z = 5 }) ::
            Nil) }

    // ── 字（ゲームのフォントの距離場・組み込みの字のビットマップ・切り抜き）──

    def text(): Scene =
        { name = "text", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = () -> {
            let ui = Platform.GpuResources.getFontAtlas("ui");
            let boot = Platform.GpuResources.getFontAtlas(BootFont.name());
            at(0.0, 0.0, RawDraw.box({ x = designW(), y = designH() }, c8(24, 28, 40), 0)) ::
            at(12.0, 16.0, Render.text("WebGPU V1 parity 0123", ui, 24.0, 1)) ::
            at(12.0, 56.0, Render.textTinted("Glyph edges: Ag Wq", ui, 16.0, c8(250, 200, 80), 1)) ::
            at(12.0, 96.0, Render.textTinted("BOOT FONT 12345", boot, 8.0, c8(120, 220, 160), 1)) ::
            at(12.0, 130.0, Render.Item.Clipped({ rect = { position = { x = 12.0, y = 130.0 }, size = { x = 90.0, y = 20.0 } },
                                                 inner = Render.text("Clipped words here", ui, 20.0, 2) })) ::
            Nil
        } }

    // ── Pass に描いて本編へ NEAREST の 2 倍で貼る ──

    def p3(): Render.Pass =
        { name = "p3", clear = RenderTarget.LoadOp.Clear(c8(16, 24, 40)), items =
            at(0.0, 0.0, RawDraw.box({ x = 40.0, y = 20.0 }, c8(200, 60, 60), 1)) ::
            at(40.0, 0.0, RawDraw.box({ x = 40.0, y = 20.0 }, c8(60, 200, 60), 1)) ::
            at(0.0, 20.0, RawDraw.box({ x = 80.0, y = 25.0 }, c8(60, 60, 200), 1)) ::
            at(10.0, 5.0, RawDraw.box({ x = 8.0, y = 8.0 }, c8(255, 255, 255), 2)) ::
            at(50.0, 25.0, atlasSprite("atlas", { srcPos = origin(), srcSize = full(), sx = 1.0, fH = false, fV = false })) ::
            Nil }

    def pastedP3(): Render.PlacedItem =
        Render.blitRegion({ name = "p3", design = { x = designW(), y = designH() },
                            src = { position = { x = 0.0, y = 0.0 }, size = { x = 80.0, y = 45.0 } },
                            at = { x = 160.0, y = 90.0 }, size = { x = 160.0, y = 90.0 }, z = 2 })

    def passPaste(): Scene =
        { name = "passPaste", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = p3() :: Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(4.0, 4.0, RawDraw.box({ x = 60.0, y = 30.0 }, c8(90, 90, 90), 1)) :: pastedP3() :: Nil) }

    /// 同じ Pass を Rgba16Float の描き先で（pipeline はその Pass で初めて作る）。8 bit で割り切れる色なので読む値は Rgba8 と同じ。
    def passHalf(): Scene =
        { name = "passHalf", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = p3() :: Nil, targets = Map#{"p3" => RenderTarget.withHdr(RenderTarget.defaultDescriptor())},
          submits = Some(1), items = still(pastedP3() :: Nil) }


    // ── 生成の絵（ensureTexture の ARGB・大きさが同じ書き替え）──

    /// 成分（0〜255）を ARGB の int に並べる。
    def argb(a: Int32, r: Int32, g: Int32, b: Int32): Int32 = a * 16777216 + r * 65536 + g * 256 + b

    /// side × side の 2 色の市松（ARGB）。
    def checkerArgb(side: Int32, first: Int32, second: Int32): Vector[Int32] =
        Vector.range(0, side * side) |> Vector.map(i -> if (Int32.remainder(i / side + Int32.remainder(i, side), 2) == 0) first else second)

    def generatedSprite(name: String, sx: Float64): Render.Item =
        Render.Item.Sprite({ texture = name, tint = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0, scale = { x = sx, y = sx },
            rotation = 0.0, centered = false, flipH = false, flipV = false, regionRect = None,
            zIndex = 3, blend = DrawCmd.BlendMode.Normal, maskPolys = Nil })

    /// 同じコマで 2 回上げる（2 回目は大きさが同じなので書き替え）。半透明の画素も持つ。
    def generated(): Scene =
        { name = "generated", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = () -> {
            Platform.GpuResources.ensureTexture("gen", "first", 8, 8, checkerArgb(8, argb(255, 255, 64, 64), argb(128, 32, 32, 128)));
            Platform.GpuResources.ensureTexture("gen", "second", 8, 8, checkerArgb(8, argb(255, 64, 255, 64), argb(128, 255, 255, 255)));
            at(0.0, 0.0, RawDraw.box({ x = designW(), y = designH() }, c8(60, 60, 60), 0)) ::
            at(20.0, 20.0, generatedSprite("gen", 6.0)) ::
            at(100.0, 20.0, generatedSprite("gen", 12.0)) ::
            Nil
        } }

    /// Pass で生成の絵 gen を描いた後に、同じ大きさで gen を書き替える（コマの途中の submit が 1 回増える）。
    /// GL と同じく、Pass の中は書き替える前の絵・本編は書き替えた後の絵で描かれる。前の場面（generated）が gen を上げてある。
    def passThenGenerated(): Scene =
        let pg: Render.Pass = { name = "pg", clear = RenderTarget.LoadOp.Clear(c8(30, 30, 30)), items =
            at(10.0, 10.0, generatedSprite("gen", 8.0)) :: Nil };
        { name = "passThenGenerated", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = pg :: Nil, targets = Map.empty(), submits = Some(2), items = () -> {
            Platform.GpuResources.ensureTexture("gen", "third", 8, 8, checkerArgb(8, argb(255, 64, 128, 255), argb(255, 255, 208, 64)));
            Render.blitRegion({ name = "pg", design = { x = designW(), y = designH() },
                                src = { position = { x = 0.0, y = 0.0 }, size = { x = 160.0, y = 90.0 } },
                                at = { x = 80.0, y = 45.0 }, size = { x = 160.0, y = 90.0 }, z = 1 }) ::
            at(200.0, 60.0, generatedSprite("gen", 8.0)) ::
            Nil
        } }

    // ── 多角形（単色・頂点色・凹の形・blend・切り抜き・スプライトとの重なり順）──

    def v(x: Float64, y: Float64): Vec2.Vec2 = { x = x, y = y }

    def tint(x: Float64, y: Float64, color: Color, alpha: Float64): DrawCmd.GradVertex = { pos = v(x, y), color = color, alpha = alpha }

    /// 凹の矢印（耳切りで割る形）。
    def arrow(): List[Vec2.Vec2] = v(0.0, 10.0) :: v(30.0, 10.0) :: v(30.0, 0.0) :: v(50.0, 20.0) :: v(30.0, 40.0) :: v(30.0, 30.0) :: v(0.0, 30.0) :: Nil

    def polygonItems(): List[Render.PlacedItem] =
        at(10.0, 10.0, RawDraw.polygon(v(0.0, 0.0) :: v(40.0, 0.0) :: v(20.0, 34.0) :: Nil, c8(200, 200, 40), 1)) ::
        at(60.0, 10.0, RawDraw.polygon(arrow(), c8(40, 160, 220), 1)) ::
        at(120.0, 10.0, Render.gradPolygon(tint(0.0, 0.0, c8(255, 0, 0), 1.0) :: tint(48.0, 0.0, c8(0, 255, 0), 1.0) ::
                                            tint(48.0, 40.0, c8(0, 0, 255), 1.0) :: tint(0.0, 40.0, c8(255, 255, 255), 0.5) :: Nil, 1)) ::
        at(180.0, 10.0, RawDraw.box({ x = 60.0, y = 40.0 }, c8(60, 60, 60), 1)) ::
        at(190.0, 20.0, RawDraw.ngon(6, 18.0, c8(120, 80, 40), 2) |> Render.blended(DrawCmd.BlendMode.Add)) ::
        at(230.0, 20.0, RawDraw.ngon(5, 18.0, c8(100, 100, 100), 2) |> Render.blended(DrawCmd.BlendMode.Multiply)) ::
        at(260.0, 10.0, Render.Item.Clipped({ rect = { position = v(260.0, 10.0), size = v(30.0, 25.0) },
                                             inner = RawDraw.ellipse(v(24.0, 18.0), c8(250, 250, 120), 2) })) ::
        // 重なり順: 箱 z1 → 多角形 z2 → 箱 z3 → 多角形 z4（列の順のまま、スプライトと多角形の行が交互に並ぶ）。
        at(20.0, 90.0, RawDraw.box({ x = 60.0, y = 60.0 }, c8(200, 60, 60), 1)) ::
        at(40.0, 100.0, RawDraw.polygon(v(0.0, 0.0) :: v(60.0, 10.0) :: v(10.0, 60.0) :: Nil, c8(60, 200, 60), 2)) ::
        at(60.0, 110.0, RawDraw.box({ x = 40.0, y = 40.0 }, c8(60, 60, 200), 3)) ::
        at(70.0, 120.0, RawDraw.ellipse(v(14.0, 10.0), c8(255, 255, 255), 4) |> Render.fade(0.5)) ::
        at(150.0, 90.0, RawDraw.ngon(8, 30.0, c8(220, 120, 200), 1)) ::
        Nil

    def polygons(): Scene =
        { name = "polygons", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1),
          items = still(polygonItems()) }

    /// 多角形を Pass に描いて本編へ貼る（Pass の描き先へも多角形の行が流れる）。
    def polygonPass(): Scene =
        let pp: Render.Pass = { name = "pp", clear = RenderTarget.LoadOp.Clear(c8(16, 24, 40)), items = polygonItems() };
        { name = "polygonPass", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = pp :: Nil, targets = Map.empty(), submits = Some(1), items = still(
            Render.blitRegion({ name = "pp", design = { x = designW(), y = designH() },
                                src = { position = v(0.0, 0.0), size = v(160.0, 90.0) },
                                at = v(80.0, 45.0), size = v(160.0, 90.0), z = 2 }) :: Nil) }

    /// 16 角形を 20 × 15 に並べた 300 個（三角形にほどくと 12,600 頂点）。色は場所ごとに替える。
    def ngonGrid(z: Int32): List[Render.PlacedItem] =
        List.range(0, 300) |> List.map(i -> {
            let col = Int32.remainder(i, 20);
            let row = i / 20;
            at(Int32.toFloat64(col * 16 + 8), Int32.toFloat64(row * 12 + 6),
               RawDraw.ngon(16, 6.0, c8(40 + col * 10, 60 + row * 12, 200 - col * 5), z))
        })

    /// Pass と本編の両方に多角形を 12,600 頂点ずつ置く。頂点の Stream（初めは 4,096 頂点）を Pass が伸ばし、
    /// 本編はその後ろに入らないので submit してから頭から送る（submit は本編の前の 1 回と、コマの終わりの 1 回）。
    def polygonFlood(): Scene =
        let pf: Render.Pass = { name = "pf", clear = RenderTarget.LoadOp.Clear(c8(16, 24, 40)), items = ngonGrid(1) };
        { name = "polygonFlood", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = pf :: Nil, targets = Map.empty(), submits = Some(2), items = still(
            List.append(ngonGrid(1),
                Render.blitRegion({ name = "pf", design = { x = designW(), y = designH() },
                                    src = { position = v(0.0, 0.0), size = v(160.0, 90.0) },
                                    at = v(160.0, 90.0), size = v(160.0, 90.0), z = 2 }) :: Nil)) }

    // ── タイルの層（市松のアトラス 16 × 16 を 8 × 8 のタイル 4 種に割る・層の色・タイルの tint と alpha・倍率・スプライトとの重なり順）──

    def tileAt(col: Int32, row: Int32, kind: Int32, alpha: Float64, tint1: Color): GameEngine.TileInstance =
        { px = v(Int32.toFloat64(col * 8), Int32.toFloat64(row * 8)),
          uvOff = v(Int32.toFloat64(Int32.remainder(kind, 2)) * 0.5, Int32.toFloat64(kind / 2) * 0.5), uvSc = v(0.5, 0.5),
          alpha = alpha, tint = tint1 }

    def tileGrid(cols: Int32, rows: Int32): List[GameEngine.TileInstance] =
        List.range(0, cols * rows) |> List.map(i -> {
            let col = Int32.remainder(i, cols);
            let row = i / cols;
            let alpha = if (Int32.remainder(i, 7) == 3) 0.5 else 1.0;
            let tint1 = if (Int32.remainder(i, 5) == 1) c8(255, 128, 128) else c8(255, 255, 255);
            tileAt(col, row, Int32.remainder(col + row, 4), alpha, tint1)
        })

    def tileLayer(handle: (GpuHandle.TileVao, Int32), pos: Vec2.Vec2, scale: Float64, color: Color, z: Int32): GameEngine.TileMapRenderCmd =
        { textureName = "atlas", tileSize = 8.0, position = pos, tileScale = { x = scale, y = scale }, color = color, zIndex = z,
          tileVaoId = fst(handle), tileCount = snd(handle) }

    def tiles(): Scene =
        { name = "tiles", warmup = Nil, passes = Nil, targets = Map.empty(), submits = Some(1), staticLayer = None,
          tiles = () -> {
              let ground = Platform.GpuResources.initTileBuffer(tileGrid(12, 6));
              let small = Platform.GpuResources.initTileBuffer(tileGrid(3, 2));
              // 入れ直し（同じ番号のまま、枚数を増やす）。
              let grown = Platform.GpuResources.updateTileBuffer(fst(small), tileGrid(5, 3));
              tileLayer(ground, v(8.0, 8.0), 2.0, c8(255, 255, 255), 1) ::
              tileLayer(grown, v(210.0, 100.0), 1.0, c8(128, 255, 128), 3) ::
              Nil
          },
          items = still(
              at(0.0, 0.0, RawDraw.box({ x = designW(), y = designH() }, c8(30, 30, 50), 0)) ::
              at(40.0, 40.0, RawDraw.box({ x = 40.0, y = 30.0 }, c8(200, 60, 60), 2)) ::
              at(220.0, 105.0, RawDraw.box({ x = 20.0, y = 20.0 }, c8(60, 60, 200), 2)) ::
              Nil) }

    // ── static layer（世界の座標の多角形を view で画面へ写す・blend・切り抜き・動く物との重なり順）──

    def staticPolys(): List[DrawCmd.PolygonRenderCmd] =
        let solid = (verts: List[Vec2.Vec2], color: Color, z: Int32) ->
            ({ vertices = verts, color = color, alpha = 1.0, zIndex = z, clip = None, blend = DrawCmd.BlendMode.Normal, grad = None, triangles = None }: DrawCmd.PolygonRenderCmd);
        solid(v(0.0, 0.0) :: v(80.0, 0.0) :: v(80.0, 40.0) :: v(0.0, 40.0) :: Nil, c8(80, 120, 60), 1) ::
        solid(v(10.0, 10.0) :: v(60.0, 5.0) :: v(40.0, 50.0) :: Nil, c8(200, 180, 60), 1) ::
        { blend = DrawCmd.BlendMode.Add | solid(v(50.0, 20.0) :: v(100.0, 20.0) :: v(75.0, 60.0) :: Nil, c8(120, 40, 40), 3) } ::
        { clip = Some({ position = v(150.0, 120.0), size = v(40.0, 30.0) }) | solid(v(-20.0, -10.0) :: v(30.0, -10.0) :: v(30.0, 30.0) :: Nil, c8(60, 160, 220), 3) } ::
        Nil

    def staticLayer(): Scene =
        { name = "staticLayer", warmup = Nil, passes = Nil, targets = Map.empty(), submits = Some(1), tiles = noTiles(),
          staticLayer = Some({ key = "v1-static", polys = () -> staticPolys(),
                               viewOffset = v(20.0, 10.0), viewScale = v(1.5, 1.5), halfDesign = v(designW() / 2.0, designH() / 2.0) }),
          items = still(
              at(0.0, 0.0, RawDraw.box({ x = designW(), y = designH() }, c8(24, 24, 24), 0)) ::
              at(150.0, 90.0, RawDraw.box({ x = 40.0, y = 40.0 }, c8(200, 60, 200), 2)) ::
              Nil) }

    // ── Pass の history（前のコマの描き先の絵）と MSAA ──
    // history の場面はコマを続けて描き、窓と同じく前のコマの絵を写す（GL は GlOffscreen.withHistoryKept）。
    // history の写しが 1 コマずれる（前の前のコマを読む・今のコマの途中を読む）と、重ねた箱の濃さが変わる。

    def designSize(): Vec2.Vec2 = v(designW(), designH())

    /// Pass name の history を (x, y) から等倍で、alpha で重ねる。
    def historyOf(name: String, x: Float64, y: Float64, alpha: Float64, z: Int32): Render.PlacedItem =
        at(x, y, Render.Item.Sprite({ texture = RenderTarget.historyName(name), tint = { r = 1.0, g = 1.0, b = 1.0 }, alpha = alpha,
            scale = { x = 1.0, y = 1.0 }, rotation = 0.0, centered = false, flipH = false, flipV = false, regionRect = None,
            zIndex = z, blend = DrawCmd.BlendMode.Normal, maskPolys = Nil }))

    /// Pass（か history）name の左上 160 × 90 を、本編の (x, y) を左上にして等倍で貼る（blitRegion の at は貼る先の中心）。
    def pasteQuarter(name: String, x: Float64, y: Float64, z: Int32): Render.PlacedItem =
        Render.blitRegion({ name = name, design = designSize(), src = { position = v(0.0, 0.0), size = v(160.0, 90.0) },
                            at = v(x + 80.0, y + 45.0), size = v(160.0, 90.0), z = z })

    def boxAt(x: Float64, y: Float64, color: Color, z: Int32): Render.PlacedItem = at(x, y, RawDraw.box(v(30.0, 30.0), color, z))

    def step(passes: List[Render.Pass]): Step = { passes = passes, targets = Map.empty() }

    /// 3 コマとも自分の history を半分の濃さで重ねてから箱を 1 つ足す（1 コマ目は history を作った直後で透明）。
    /// 最後のコマの赤は 1/4・緑は 1/2・青はそのままの濃さになる。本編の右に history（= 2 コマ目の絵）を並べる。
    def historyFade(): Scene =
        let pass = (color, x) -> ({ name = "hfade", clear = RenderTarget.LoadOp.Clear(c8(0, 0, 0)),
                                    items = historyOf("hfade", 0.0, 0.0, 0.5, 1) :: boxAt(x, 20.0, color, 2) :: Nil }: Render.Pass);
        { name = "historyFade", warmup = step(pass(c8(240, 40, 40), 10.0) :: Nil) :: step(pass(c8(40, 240, 40), 50.0) :: Nil) :: Nil,
          tiles = noTiles(), staticLayer = None, passes = pass(c8(40, 40, 240), 90.0) :: Nil, targets = Map.empty(), submits = Some(1),
          items = still(pasteQuarter("hfade", 0.0, 0.0, 1) :: pasteQuarter(RenderTarget.historyName("hfade"), 160.0, 0.0, 1) :: Nil) }

    /// 1 コマ目は history を読まず（history はまだ無い）、2 コマ目で初めて読む: 作った history へ 1 コマ目の絵を写してから描く。
    def historyLate(): Scene =
        let first: Render.Pass = { name = "hlate", clear = RenderTarget.LoadOp.Clear(c8(20, 40, 60)),
                                   items = boxAt(10.0, 10.0, c8(240, 200, 40), 1) :: Nil };
        let second: Render.Pass = { name = "hlate", clear = RenderTarget.LoadOp.Clear(c8(20, 40, 60)),
                                    items = historyOf("hlate", 40.0, 30.0, 1.0, 1) :: boxAt(100.0, 10.0, c8(40, 200, 240), 2) :: Nil };
        { name = "historyLate", warmup = step(first :: Nil) :: Nil, tiles = noTiles(), staticLayer = None, passes = second :: Nil,
          targets = Map.empty(), submits = Some(1),
          items = still(pasteQuarter("hlate", 0.0, 0.0, 1) :: pasteQuarter(RenderTarget.historyName("hlate"), 160.0, 90.0, 1) :: Nil) }

    /// LoadOp.Keep の描き先が自分の history を読む: 前のコマの絵に、history を右へ 40 px ずらして重ねて足していく。
    def historyKeep(): Scene =
        let pass = (color, y) -> ({ name = "hkeep", clear = RenderTarget.LoadOp.Keep,
                                    items = historyOf("hkeep", 40.0, 0.0, 1.0, 1) :: boxAt(0.0, y, color, 2) :: Nil }: Render.Pass);
        { name = "historyKeep", warmup = step(pass(c8(240, 40, 40), 0.0) :: Nil) :: step(pass(c8(40, 240, 40), 30.0) :: Nil) :: Nil,
          tiles = noTiles(), staticLayer = None, passes = pass(c8(40, 40, 240), 60.0) :: Nil, targets = Map.empty(), submits = Some(1),
          items = still(pasteQuarter("hkeep", 0.0, 0.0, 1) :: Nil) }

    // MSAA の場面は、縁を軸に沿った端数の位置に置く（縁の画素は標本の数ぶんの段の濃さ）。端数は画素の中心（0.5）と標本の位置（1/8 の奇数倍）を避ける
    // （ちょうど乗ると、覆うかどうかを決める規則が上下に返した描き先で逆の側を取る）。
    // WhyNot: 斜めの縁で GL と比べない — GL の描き先は上下逆に格納され、標本の位置が中身に対して上下に返る（標準の 4 標本の並びは
    //   上下に返すと別の並びになる）ので、斜めの縁の画素は 1〜2 標本ずれる（試した多角形で 89 px・最大 ±51）。軸に沿った縁は、
    //   標本の x の組と y の組が上下に返しても同じなので、覆う標本の数が GL と WebGPU で同じになる。

    def targetsWith(name: String, samples: Int32): Map[String, RenderTarget.Descriptor] =
        Map#{name => RenderTarget.withMsaa(samples, RenderTarget.defaultDescriptor())}

    /// 端数の位置と大きさの箱と、同じく端数の頂点の四角形の多角形（スプライトの行と多角形の行の両方の縁）。
    def fractionalItems(dx: Float64, color: Color): List[Render.PlacedItem] =
        at(dx + 10.3, 5.2, RawDraw.box(v(30.4, 20.6), color, 2)) ::
        at(dx + 12.7, 35.3, RawDraw.polygon(v(0.0, 0.0) :: v(26.2, 0.0) :: v(26.2, 15.4) :: v(0.0, 15.4) :: Nil, color, 2)) ::
        Nil

    def msaaItems(): List[Render.PlacedItem] =
        List.append(fractionalItems(0.0, c8(240, 200, 40)), List.append(fractionalItems(50.0, c8(40, 200, 240)), fractionalItems(100.0, c8(240, 80, 200))))

    def msaaPassWith(name: String, samples: Int32): Scene =
        let pass: Render.Pass = { name = name, clear = RenderTarget.LoadOp.Clear(c8(16, 24, 40)), items = msaaItems() };
        { name = name, warmup = Nil, tiles = noTiles(), staticLayer = None, passes = pass :: Nil, targets = targetsWith(name, samples), submits = Some(1),
          items = still(pasteQuarter(name, 0.0, 0.0, 1) :: Nil) }

    /// 端数の縁を標本 4 の Pass へ描いて本編へ貼る（縁の画素は標本の平均）。
    def msaaPass(): Scene = msaaPassWith("msaaPass", 4)

    /// msaaPass と同じ物を標本 2 で（GL は 2 標本・WebGPU は 1 と 4 しか描けないので 4 標本。縁の画素の濃さの段が違う — tolerance.tsv）。
    def msaaTwo(): Scene = msaaPassWith("msaaTwo", 2)

    /// msaaPass と同じ物を標本 1 で（Main がこの 2 つの絵が違う事を見る — 両方の描き手が MSAA を掛けずに同じ絵になる誤りを拾う）。
    def msaaOff(): Scene = msaaPassWith("msaaOff", 1)

    /// 標本 4 の LoadOp.Keep の描き先へ 3 コマ描き足し、2 コマ目からは自分の history（resolve 済みの絵）を半分の濃さで下へずらして重ねる。
    /// 標本を持つ描き先の中身がコマをまたいで残る事と、history が resolve の後の絵から写る事を見る。
    def msaaKeep(): Scene =
        let pass = items -> ({ name = "mkeep", clear = RenderTarget.LoadOp.Keep, items = items }: Render.Pass);
        let targets = targetsWith("mkeep", 4);
        { name = "msaaKeep",
          warmup = { passes = pass(fractionalItems(0.0, c8(240, 200, 40))) :: Nil, targets = targets } ::
                   { passes = pass(historyOf("mkeep", 0.0, 45.0, 0.5, 1) :: fractionalItems(50.0, c8(40, 200, 240))) :: Nil, targets = targets } :: Nil,
          tiles = noTiles(), staticLayer = None, passes = pass(historyOf("mkeep", 0.0, 45.0, 0.5, 1) :: fractionalItems(100.0, c8(240, 80, 200))) :: Nil,
          targets = targets, submits = Some(1), items = still(pasteQuarter("mkeep", 0.0, 0.0, 1) :: pasteQuarter(RenderTarget.historyName("mkeep"), 160.0, 0.0, 1) :: Nil) }

    /// 同じ名前の描き先の標本を 4 → 1 → 4 と替える（替わるたびに作り直し、中身と history は捨てる）。LoadOp.Keep と history の読みを混ぜる。
    def msaaToggle(): Scene =
        let pass = items -> ({ name = "mtog", clear = RenderTarget.LoadOp.Keep, items = items }: Render.Pass);
        { name = "msaaToggle",
          warmup = { passes = pass(fractionalItems(0.0, c8(240, 200, 40))) :: Nil, targets = targetsWith("mtog", 4) } ::
                   { passes = pass(historyOf("mtog", 0.0, 45.0, 1.0, 1) :: fractionalItems(50.0, c8(40, 200, 240))) :: Nil, targets = Map.empty() } :: Nil,
          tiles = noTiles(), staticLayer = None, passes = pass(historyOf("mtog", 0.0, 45.0, 1.0, 1) :: fractionalItems(100.0, c8(240, 80, 200))) :: Nil,
          targets = targetsWith("mtog", 4), submits = Some(1),
          items = still(pasteQuarter("mtog", 0.0, 0.0, 1) :: pasteQuarter(RenderTarget.historyName("mtog"), 160.0, 90.0, 1) :: Nil) }

    /// 3D の場面を貼る行が 2D の並びの途中に入る場面: 同じ色・同じ blend の 2 つの箱の間に、何も置かず地の色も無い 3D の場面（GL でも画素を変えない）。
    /// 2 つの箱の run が切れる理由は場面だけで、GL と WebGPU の draw の数が同じ所で切れる事を Main が見る（期待は Main.expectedDraws）。
    /// 場面の行の後の箱と市松の絵が、場面の前と同じ状態（blend・scissor・viewport）で描かれる事も見る。WebGPU は場面を描かずに知らせる。
    def sceneBetween(): Scene =
        let camera: Camera3d.Camera3d = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 1.0, far = 100.0 };
        { name = "sceneBetween", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(20.0, 20.0, RawDraw.box({ x = 120.0, y = 80.0 }, c8(40, 80, 200), 1)) ::
            Render.scene3d(v(60.0, 40.0), { zIndex = 2 | Scene3d.scene(camera, v(160.0, 100.0)) }) ::
            at(100.0, 60.0, RawDraw.box({ x = 120.0, y = 80.0 }, c8(40, 80, 200), 3)) ::
            at(240.0, 100.0, maskedSprite({ tint = c8(255, 255, 255), rotation = 0.0, flipH = false, blend = DrawCmd.BlendMode.Normal, z = 3, mask = Nil })) ::
            Nil) }

    /// WebGPU がまだ描かない物だけの場面（3D の場面）。GL とは比べない。
    pub def unsupported(): Scene =
        let camera: Camera3d.Camera3d = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 1.0, far = 100.0 };
        { name = "unsupported", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = None, items = still(
            Render.scene3d(v(120.0, 60.0), { zIndex = 2 | Scene3d.scene(camera, v(100.0, 50.0)) }) ::
            Nil) }

    // ── 面（ShaderDoc の面: 面の値（rect・time・alpha・params）・blend・絵の読み・mask・Pass・MSAA）──
    // 面は箱と同じ z の列に混ざり、z の位置で溜めた run を閉じる。Spec の名前は場面をまたいで中身ごとに別にする（同じ名前で中身が違うと組み直しになる）。

    def fillSpec(name: String, shade: ShaderDoc.Shade, alpha: ShaderDoc.Field): ShaderDoc.Spec =
        { name = name, cycleRate = 0.0, bindings = Nil, out = ShaderDoc.Out.Fill({ shade = shade, alpha = alpha }) }

    def solidSpec(name: String, color: Color): ShaderDoc.Spec = fillSpec(name, ShaderDoc.Shade.Solid(color), ShaderDoc.Field.Const(1.0))

    /// 左から右へ 2 色の間をなめらかにつなぐ面（uv の u）。
    def rampSpec(): ShaderDoc.Spec =
        fillSpec("v1_ramp", ShaderDoc.Shade.Ramp({ lo = c8(240, 60, 40), hi = c8(40, 80, 240), field = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }) }),
                 ShaderDoc.Field.Const(1.0))

    /// params の red と green を赤と緑にする面。
    def paramSpec(): ShaderDoc.Spec =
        fillSpec("v1_param", ShaderDoc.Shade.Rgb({ r = ShaderDoc.Field.Param({ name = "red" }), g = ShaderDoc.Field.Param({ name = "green" }),
                                                   b = ShaderDoc.Field.Const(0.0) }), ShaderDoc.Field.Const(1.0))

    /// time × 0.25 を赤にする面。
    def timeSpec(): ShaderDoc.Spec =
        fillSpec("v1_time", ShaderDoc.Shade.Rgb({ r = ShaderDoc.Field.Time({ scale = 0.25, offset = ShaderDoc.Field.Const(0.0) }),
                                                  g = ShaderDoc.Field.Const(0.5), b = ShaderDoc.Field.Const(0.25) }), ShaderDoc.Field.Const(1.0))

    /// 絵 texName を filter で読む面（色と alpha をそのまま）。
    def readSpec(name: String, texName: String, filter: ShaderDoc.FilterMode): ShaderDoc.Spec =
        let read = chan -> ShaderDoc.Field.Sampler({ filter = filter, of = ShaderDoc.Field.Tex({ name = texName, chan = chan }) });
        fillSpec(name, ShaderDoc.Shade.Rgb({ r = read(ShaderDoc.TexChan.R), g = read(ShaderDoc.TexChan.G), b = read(ShaderDoc.TexChan.B) }),
                 read(ShaderDoc.TexChan.A))

    def rectAt(x: Float64, y: Float64, w: Float64, h: Float64): Rect2.Rect2 = { position = v(x, y), size = v(w, h) }

    def surfaceAt(spec: ShaderDoc.Spec, r: Rect2.Rect2, z: Int32): Render.PlacedItem = Render.shaderFill(spec, r, 0.0, z)

    def withItem(f: Render.Item -> Render.Item, placed: Render.PlacedItem): Render.PlacedItem = { item = f(placed#item) | placed }

    /// 単色・箱との重なり順・uv・params・time・Add・Multiply・α 0.5。
    def surfaceFill(): Scene =
        { name = "surfaceFill", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(0.0, 0.0, RawDraw.box(designSize(), c8(24, 28, 40), 0)) ::
            surfaceAt(solidSpec("v1_red", c8(220, 60, 60)), rectAt(10.0, 10.0, 60.0, 40.0), 1) ::
            at(40.0, 30.0, RawDraw.box(v(40.0, 30.0), c8(60, 200, 120), 2)) ::
            surfaceAt(solidSpec("v1_blue", c8(60, 80, 220)), rectAt(50.0, 40.0, 40.0, 30.0), 3) ::
            surfaceAt(rampSpec(), rectAt(110.0, 10.0, 80.0, 40.0), 1) ::
            (surfaceAt(paramSpec(), rectAt(200.0, 10.0, 50.0, 40.0), 1) |> Render.withShaderParams(Map#{"red" => 0.6, "green" => 0.2})) ::
            Render.shaderFill(timeSpec(), rectAt(260.0, 10.0, 50.0, 40.0), 2.0, 1) ::
            at(10.0, 80.0, RawDraw.box(v(220.0, 60.0), c8(200, 200, 200), 1)) ::
            withItem(Render.blended(DrawCmd.BlendMode.Add), surfaceAt(solidSpec("v1_add", c8(40, 40, 120)), rectAt(20.0, 90.0, 50.0, 40.0), 2)) ::
            withItem(Render.blended(DrawCmd.BlendMode.Multiply), surfaceAt(solidSpec("v1_mul", c8(128, 64, 255)), rectAt(80.0, 90.0, 50.0, 40.0), 2)) ::
            withItem(Render.fade(0.5), surfaceAt(solidSpec("v1_half", c8(255, 255, 0)), rectAt(160.0, 90.0, 60.0, 40.0), 2)) ::
            Nil) }

    /// 同じ色・同じ blend の 2 つの箱の間に面が 1 枚（2 つの箱の run が切れる理由は面だけ。期待は Main.expectedDraws）。
    def surfaceBetween(): Scene =
        { name = "surfaceBetween", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(20.0, 20.0, RawDraw.box(v(120.0, 80.0), c8(40, 80, 200), 1)) ::
            surfaceAt(solidSpec("v1_between", c8(240, 200, 40)), rectAt(60.0, 40.0, 60.0, 40.0), 2) ::
            at(100.0, 60.0, RawDraw.box(v(120.0, 80.0), c8(40, 80, 200), 3)) ::
            Nil) }

    /// 絵の読み: アトラスを Nearest と Linear で・Pass（GL では上下逆に格納される描き先）を Nearest で・無い名前（不透明な黒）。
    def surfaceTexture(): Scene =
        { name = "surfaceTexture", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = p3() :: Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(0.0, 0.0, RawDraw.box(designSize(), c8(60, 60, 60), 0)) ::
            surfaceAt(readSpec("v1_read_nearest", "atlas", ShaderDoc.FilterMode.Nearest), rectAt(10.0, 10.0, 64.0, 64.0), 1) ::
            surfaceAt(readSpec("v1_read_linear", "atlas", ShaderDoc.FilterMode.Linear), rectAt(90.0, 10.0, 64.0, 64.0), 1) ::
            surfaceAt(readSpec("v1_read_pass", "p3", ShaderDoc.FilterMode.Nearest), rectAt(170.0, 10.0, 140.0, 80.0), 1) ::
            surfaceAt(readSpec("v1_read_missing", "v1_no_such_texture", ShaderDoc.FilterMode.Nearest), rectAt(10.0, 100.0, 60.0, 40.0), 1) ::
            Nil) }

    /// mask つきの面: mask つきスプライトとの交互（比べる値の続き）・前の面の mask の内側に小さい mask のスプライト・三角形にならない mask・
    /// 2 つの矩形の mask で絵を読む面。
    def surfaceMask(): Scene =
        let tri = (x, y) -> (v(x + 2.0, y + 2.0) :: v(x + 62.0, y + 6.0) :: v(x + 10.0, y + 58.0) :: Nil) :: Nil;
        { name = "surfaceMask", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(0.0, 0.0, RawDraw.box(designSize(), c8(24, 28, 40), 0)) ::
            at(8.0, 8.0, plainMask(white(), 1, triangleMask())) ::
            Render.shaderFillMasked(solidSpec("v1_mask_green", c8(60, 200, 120)), rectAt(80.0, 8.0, 64.0, 64.0), tri(80.0, 8.0), 0.0, 1) ::
            at(80.0, 8.0, plainMask(c8(255, 160, 80), 2, rectMask(20.0, 20.0, 30.0, 30.0) :: Nil)) ::
            at(160.0, 8.0, plainMask(white(), 1, triangleMask())) ::
            Render.shaderFillMasked(solidSpec("v1_mask_red", c8(220, 60, 60)), rectAt(232.0, 8.0, 64.0, 64.0),
                                    (v(232.0, 8.0) :: v(290.0, 8.0) :: Nil) :: Nil, 0.0, 1) ::
            Render.shaderFillMasked(readSpec("v1_mask_read", "atlas", ShaderDoc.FilterMode.Nearest), rectAt(8.0, 100.0, 128.0, 64.0),
                                    rectMask(12.0, 104.0, 40.0, 30.0) :: rectMask(70.0, 120.0, 50.0, 40.0) :: Nil, 0.0, 1) ::
            Nil) }

    /// 面を Pass に描いて本編へ貼る（Pass の pass も面の mask の stencil を持つ）。
    def surfacePass(): Scene =
        let ps: Render.Pass = { name = "ps", clear = RenderTarget.LoadOp.Clear(c8(16, 24, 40)), items =
            surfaceAt(solidSpec("v1_pass_solid", c8(200, 60, 140)), rectAt(10.0, 10.0, 60.0, 40.0), 1) ::
            at(40.0, 30.0, RawDraw.box(v(40.0, 30.0), c8(60, 200, 120), 2)) ::
            surfaceAt(rampSpec(), rectAt(90.0, 10.0, 60.0, 30.0), 1) ::
            Render.shaderFillMasked(solidSpec("v1_pass_mask", c8(240, 200, 40)), rectAt(10.0, 50.0, 140.0, 35.0),
                                    rectMask(20.0, 55.0, 30.0, 20.0) :: rectMask(100.0, 60.0, 40.0, 20.0) :: Nil, 0.0, 1) ::
            Nil };
        { name = "surfacePass", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = ps :: Nil, targets = Map.empty(), submits = Some(1), items = still(
            pasteQuarter("ps", 0.0, 0.0, 1) ::
            surfaceAt(solidSpec("v1_pass_main", c8(40, 160, 220)), rectAt(200.0, 100.0, 80.0, 50.0), 2) ::
            Nil) }

    /// 端数の位置の面と、端数の矩形の mask の面を標本 4 の Pass へ描いて貼る（面の pipeline の標本 4・mask の stencil も標本 4。MSAA の場面の WhyNot と同じく軸に沿った縁）。
    def surfaceMsaa(): Scene =
        let pm: Render.Pass = { name = "psmsaa", clear = RenderTarget.LoadOp.Clear(c8(16, 24, 40)), items =
            surfaceAt(solidSpec("v1_msaa_solid", c8(240, 200, 40)), rectAt(10.3, 5.2, 30.4, 20.6), 1) ::
            Render.shaderFillMasked(solidSpec("v1_msaa_mask", c8(40, 200, 240)), rectAt(50.0, 0.0, 100.0, 80.0),
                                    rectMask(60.3, 5.2, 40.4, 30.6) :: rectMask(102.7, 40.3, 20.2, 30.4) :: Nil, 0.0, 1) ::
            Nil };
        { name = "surfaceMsaa", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = pm :: Nil, targets = targetsWith("psmsaa", 4), submits = Some(1),
          items = still(pasteQuarter("psmsaa", 0.0, 0.0, 1) :: Nil) }

    // ── mask つきスプライト（stencil の比べる値を 1 ずつ進める・RenderList.nextMaskRef）──
    // mask の形は絵の大きさのローカル座標（左上が原点・回転と反転は絵と同じに掛かる）。絵は市松のアトラス（16 × 16）を 4 倍の 64 × 64 で。

    def maskedSprite(spec: { tint = Color, rotation = Float64, flipH = Bool, blend = DrawCmd.BlendMode, z = Int32, mask = List[List[Vec2.Vec2]] }): Render.Item =
        Render.Item.Sprite({ texture = "atlas", tint = spec#tint, alpha = 1.0, scale = { x = 4.0, y = 4.0 }, rotation = spec#rotation,
            centered = false, flipH = spec#flipH, flipV = false, regionRect = None, zIndex = spec#z, blend = spec#blend, maskPolys = spec#mask })

    def plainMask(tint: Color, z: Int32, mask: List[List[Vec2.Vec2]]): Render.Item =
        maskedSprite({ tint = tint, rotation = 0.0, flipH = false, blend = DrawCmd.BlendMode.Normal, z = z, mask = mask })

    def white(): Color = c8(255, 255, 255)

    def triangleMask(): List[List[Vec2.Vec2]] = (v(2.0, 2.0) :: v(62.0, 6.0) :: v(10.0, 58.0) :: Nil) :: Nil

    /// 軸に沿った矩形の mask（x, y から w × h）。
    def rectMask(x: Float64, y: Float64, w: Float64, h: Float64): List[Vec2.Vec2] = v(x, y) :: v(x + w, y) :: v(x + w, y + h) :: v(x, y + h) :: Nil

    /// 三角形・凹の矢印・回転・左右の反転・Add・切り抜き・三角形にならない mask（そのまま描く）。
    def maskBasic(): Scene =
        { name = "maskBasic", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(0.0, 0.0, RawDraw.box(designSize(), c8(24, 28, 40), 0)) ::
            at(8.0, 8.0, plainMask(white(), 1, triangleMask())) ::
            at(80.0, 8.0, plainMask(c8(128, 255, 128), 1, arrow() :: Nil)) ::
            at(152.0, 8.0, maskedSprite({ tint = white(), rotation = 0.5, flipH = false, blend = DrawCmd.BlendMode.Normal, z = 1, mask = triangleMask() })) ::
            at(224.0, 8.0, maskedSprite({ tint = white(), rotation = 0.0, flipH = true, blend = DrawCmd.BlendMode.Normal, z = 1, mask = triangleMask() })) ::
            at(8.0, 100.0, RawDraw.box(v(64.0, 64.0), c8(60, 60, 140), 1)) ::
            at(8.0, 100.0, maskedSprite({ tint = c8(160, 80, 40), rotation = 0.0, flipH = false, blend = DrawCmd.BlendMode.Add, z = 2, mask = triangleMask() })) ::
            at(80.0, 100.0, Render.Item.Clipped({ rect = { position = v(80.0, 100.0), size = v(40.0, 64.0) }, inner = plainMask(white(), 1, triangleMask()) })) ::
            at(152.0, 100.0, plainMask(c8(255, 200, 120), 1, (v(0.0, 0.0) :: v(60.0, 0.0) :: Nil) :: Nil)) ::
            Nil) }

    /// 2 つの多角形を重ねた mask（内側の三角形も四角の内側なので、合わせた形は四角）・前の mask の内側に次の mask・
    /// mask の後に mask の無いスプライト（stencil で切られずに全部出る）・箱と mask つきの交互。
    def maskNested(): Scene =
        let square = rectMask(4.0, 4.0, 56.0, 56.0);
        let inner = v(16.0, 16.0) :: v(48.0, 16.0) :: v(16.0, 48.0) :: Nil;
        { name = "maskNested", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(0.0, 0.0, RawDraw.box(designSize(), c8(24, 28, 40), 0)) ::
            at(8.0, 8.0, plainMask(c8(255, 128, 128), 1, square :: inner :: Nil)) ::
            at(80.0, 8.0, plainMask(c8(128, 128, 255), 1, square :: Nil)) ::
            at(80.0, 8.0, plainMask(c8(255, 255, 128), 2, inner :: Nil)) ::
            at(96.0, 24.0, plainMask(c8(128, 255, 128), 3, (v(4.0, 4.0) :: v(30.0, 4.0) :: v(4.0, 30.0) :: Nil) :: Nil)) ::
            at(160.0, 8.0, plainMask(white(), 1, triangleMask())) ::
            at(176.0, 24.0, atlasSprite("atlas", { srcPos = origin(), srcSize = full(), sx = 3.0, fH = false, fV = false })) ::
            at(240.0, 8.0, plainMask(white(), 1, triangleMask())) ::
            at(244.0, 60.0, RawDraw.box(v(40.0, 20.0), c8(200, 60, 140), 2)) ::
            at(240.0, 70.0, plainMask(c8(128, 255, 255), 3, rectMask(10.0, 10.0, 30.0, 40.0) :: Nil)) ::
            Nil) }

    /// mask つきスプライトを Pass に描いて本編へ貼り、本編にも mask つきを置く（Pass と本編の pass が別々に stencil を持つ）。
    def maskPass(): Scene =
        let pm: Render.Pass = { name = "pm", clear = RenderTarget.LoadOp.Clear(c8(16, 24, 40)), items =
            at(8.0, 8.0, plainMask(white(), 1, triangleMask())) ::
            at(60.0, 20.0, plainMask(c8(255, 160, 80), 2, arrow() :: Nil)) ::
            at(100.0, 10.0, atlasSprite("atlas", { srcPos = origin(), srcSize = full(), sx = 2.0, fH = false, fV = false })) ::
            Nil };
        { name = "maskPass", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = pm :: Nil, targets = Map.empty(), submits = Some(1), items = still(
            pasteQuarter("pm", 0.0, 0.0, 1) ::
            at(200.0, 100.0, plainMask(c8(128, 255, 128), 2, triangleMask())) ::
            Nil) }

    /// 標本 4 の Pass に mask つきを描く（stencil も標本 4）。mask は端数の位置の軸に沿った矩形（斜めの縁は GL と標本の位置が違う — MSAA の場面の WhyNot）。
    def maskMsaa(): Scene =
        let pm: Render.Pass = { name = "pmsaa", clear = RenderTarget.LoadOp.Clear(c8(16, 24, 40)), items =
            at(8.0, 8.0, plainMask(white(), 1, rectMask(3.3, 5.2, 40.4, 30.6) :: Nil)) ::
            at(60.0, 12.0, plainMask(c8(255, 160, 80), 2, rectMask(2.7, 1.3, 20.2, 50.4) :: rectMask(20.3, 30.2, 30.4, 10.6) :: Nil)) ::
            Nil };
        { name = "maskMsaa", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = pm :: Nil, targets = targetsWith("pmsaa", 4), submits = Some(1),
          items = still(pasteQuarter("pmsaa", 0.0, 0.0, 1) :: Nil) }

    /// 1 つの pass に mask つきを 300 個（比べる値の上限 255 を超える）。どれも同じ 64 × 64 の場所に置き、mask は 20 × 15 のセルの 1 つずつ（セルごとに色を替える）。
    /// 256 個目（値 1 に戻る）の前に stencil を 0 に戻さないと、1 個目の mask のセルにも 256 個目の色が出る。
    def maskOverflow(): Scene =
        { name = "maskOverflow", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(0.0, 0.0, RawDraw.box(designSize(), c8(24, 28, 40), 0)) :: overflowMasks(300)) }

    /// (40, 40) の 64 × 64 に重ねた mask つき n 体（mask は 20 × 15 のセルの i 番目・セルごとに色を替える）。
    def overflowMasks(n: Int32): List[Render.PlacedItem] =
        List.range(0, n) |> List.map(i -> at(40.0, 40.0, plainMask(overflowTint(i), 1, overflowCell(i))))

    def overflowCell(i: Int32): List[List[Vec2.Vec2]] =
        let col = Int32.remainder(i, 20);
        let row = i / 20;
        rectMask(Int32.toFloat64(col) * 3.0 + 2.0, Int32.toFloat64(row) * 4.0 + 2.0, 3.0, 4.0) :: Nil

    def overflowTint(i: Int32): Color = c8(55 + Int32.remainder(i * 37, 200), 55 + Int32.remainder(i * 91, 200), 55 + Int32.remainder(i * 53, 200))

    /// mask つきスプライト 255 体（比べる値を使い切る）の後に、同じ 64 × 64 を塗る mask つきの面（値 1 に戻る）と、その後の mask つきスプライト（値 2）。
    /// 面の mask は 1 体目のセルを含まない右下の矩形。面の前に stencil を 0 に戻さないと、1 体目のセル（値 1 のまま）にも面の色が出る。期待は Main.expectedDraws。
    def surfaceAfterOverflow(): Scene =
        { name = "surfaceAfterOverflow", warmup = Nil, tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(0.0, 0.0, RawDraw.box(designSize(), c8(24, 28, 40), 0)) ::
            List.append(overflowMasks(255),
                Render.shaderFillMasked(solidSpec("v1_overflow", c8(240, 240, 240)), rectAt(40.0, 40.0, 64.0, 64.0),
                                        rectMask(70.0, 70.0, 30.0, 30.0) :: Nil, 0.0, 1) ::
                at(40.0, 40.0, plainMask(c8(255, 80, 80), 2, rectMask(50.0, 2.0, 12.0, 12.0) :: Nil)) :: Nil)) }

    /// Pass の面が自分の history（前のコマの描き先の絵）を半分の濃さで読み、箱を 1 つ足す（historyFade の面の版）。3 コマ描いて、最後のコマの赤は 1/4・緑は 1/2。
    /// 面が history を読む事でも、pass を開く前に前のコマの絵を写す（TargetTable.isHistoryRead）。
    def surfaceHistory(): Scene =
        let pass = (color, x) -> ({ name = "shist", clear = RenderTarget.LoadOp.Clear(c8(0, 0, 0)),
                                    items = withItem(Render.fade(0.5), surfaceAt(readSpec("v1_history", RenderTarget.historyName("shist"), ShaderDoc.FilterMode.Nearest),
                                                                                 rectAt(0.0, 0.0, designW(), designH()), 1)) ::
                                            boxAt(x, 20.0, color, 2) :: Nil }: Render.Pass);
        { name = "surfaceHistory", warmup = step(pass(c8(240, 40, 40), 10.0) :: Nil) :: step(pass(c8(40, 240, 40), 50.0) :: Nil) :: Nil,
          tiles = noTiles(), staticLayer = None, passes = pass(c8(40, 40, 240), 90.0) :: Nil, targets = Map.empty(), submits = Some(1),
          items = still(pasteQuarter("shist", 0.0, 0.0, 1) :: Nil) }
}
