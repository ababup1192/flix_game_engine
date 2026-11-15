// GL と WebGPU の両方で 1 コマずつ描く場面。WebGPU が描く物（スプライト・字・箱・Pass・生成の絵・多角形・タイルの層・static layer）だけで組む。
// 箱・スプライト・幕・放射の 4 つは bench/gl_parity の同じ名前の場面と同じ中身（色は 8 bit で割り切れる k/255）。
// lint-view: 対象外 — GL と WebGPU の描き手の画素の一致を見る門の場面。丸めの差を混ぜないよう単色の箱を主にしている。画面に出す絵ではない。
mod V1Scenes {

    /// 1 場面。passes = 本編より先に描く Pass・items = 本編の描き物（生成の絵を上げる物は、ここで ensureTexture を呼ぶ）。
    /// tiles = 本編のタイルの層（ここで initTileBuffer を呼ぶ）・staticLayer = 本編の static layer。
    /// submits = 描いたコマの submit の数の期待（None = 見ない）。
    pub type alias Scene = {
        name = String,
        tiles = Unit -> List[GameEngine.TileMapRenderCmd] \ Platform.GpuResources,
        staticLayer = Option[GameEngine.StaticLayerCmd],
        passes = List[Render.Pass],
        // Pass の名前 → 描き先の作り方（無い名前は既定の作り方）。
        targets = Map[String, RenderTarget.Descriptor],
        items = Unit -> List[Render.PlacedItem] \ Platform.GpuResources,
        submits = Option[Int32]
    }

    pub def designW(): Float64 = 320.0

    pub def designH(): Float64 = 180.0

    pub def all(): List[Scene] =
        boxes() :: spriteNearest() :: veil() :: radial() :: text() :: passPaste() :: passHalf() :: generated() :: passThenGenerated() ::
        polygons() :: polygonPass() :: tiles() :: staticLayer() :: Nil

    def c8(r: Int32, g: Int32, b: Int32): Color =
        { r = Int32.toFloat64(r) / 255.0, g = Int32.toFloat64(g) / 255.0, b = Int32.toFloat64(b) / 255.0 }

    def at(x: Float64, y: Float64, item: Render.Item): Render.PlacedItem =
        { at = { x = x, y = y }, item = item }

    def still(items: List[Render.PlacedItem]): Unit -> List[Render.PlacedItem] \ Platform.GpuResources =
        () -> checked_ecast(items)

    def noTiles(): Unit -> List[GameEngine.TileMapRenderCmd] \ Platform.GpuResources = () -> checked_ecast(Nil)

    // ── 箱（塗り・並び順・blend の式・軸に沿った縞・市松）──

    def boxes(): Scene =
        { name = "boxes", tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
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
        { name = "spriteNearest", tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
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
        { name = "veil", tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(20.0, 20.0, RawDraw.box({ x = 120.0, y = 80.0 }, c8(200, 120, 60), 1)) ::
            at(160.0, 40.0, RawDraw.box({ x = 100.0, y = 100.0 }, c8(40, 160, 220), 1)) ::
            at(60.0, 110.0, atlasSprite("atlas", { srcPos = origin(), srcSize = full(), sx = 4.0, fH = false, fV = false })) ::
            at(0.0, 0.0, RawDraw.box({ x = designW(), y = designH() }, c8(40, 20, 60), 10) |> Render.fade(0.5)) ::
            Nil) }

    // ── 組み込みの放射の絵（Render.lightAt の Add・darkAt の Multiply）──

    def radial(): Scene =
        { name = "radial", tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(192.0, 0.0, RawDraw.box({ x = 128.0, y = 180.0 }, c8(255, 255, 255), 2)) ::
            Render.darkAt({ at = { x = 256.0, y = 128.0 }, radius = 128.0, strength = 1.0, z = 3 }) ::
            Render.lightAt({ at = { x = 128.0, y = 128.0 }, radius = 128.0, color = c8(255, 255, 255), strength = 1.0, z = 4 }) ::
            Render.lightAt({ at = { x = 174.0, y = 158.0 }, radius = 128.0, color = c8(255, 255, 255), strength = 1.0, z = 5 }) ::
            Nil) }

    // ── 字（ゲームのフォントの距離場・組み込みの字のビットマップ・切り抜き）──

    def text(): Scene =
        { name = "text", tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = () -> {
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
        { name = "passPaste", tiles = noTiles(), staticLayer = None, passes = p3() :: Nil, targets = Map.empty(), submits = Some(1), items = still(
            at(4.0, 4.0, RawDraw.box({ x = 60.0, y = 30.0 }, c8(90, 90, 90), 1)) :: pastedP3() :: Nil) }

    /// 同じ Pass を Rgba16Float の描き先で（pipeline はその Pass で初めて作る）。8 bit で割り切れる色なので読む値は Rgba8 と同じ。
    def passHalf(): Scene =
        { name = "passHalf", tiles = noTiles(), staticLayer = None, passes = p3() :: Nil, targets = Map#{"p3" => RenderTarget.withHdr(RenderTarget.defaultDescriptor())},
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
        { name = "generated", tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1), items = () -> {
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
        { name = "passThenGenerated", tiles = noTiles(), staticLayer = None, passes = pg :: Nil, targets = Map.empty(), submits = Some(2), items = () -> {
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
        { name = "polygons", tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = Some(1),
          items = still(polygonItems()) }

    /// 多角形を Pass に描いて本編へ貼る（Pass の描き先へも多角形の行が流れる）。
    def polygonPass(): Scene =
        let pp: Render.Pass = { name = "pp", clear = RenderTarget.LoadOp.Clear(c8(16, 24, 40)), items = polygonItems() };
        { name = "polygonPass", tiles = noTiles(), staticLayer = None, passes = pp :: Nil, targets = Map.empty(), submits = Some(1), items = still(
            Render.blitRegion({ name = "pp", design = { x = designW(), y = designH() },
                                src = { position = v(0.0, 0.0), size = v(160.0, 90.0) },
                                at = v(80.0, 45.0), size = v(160.0, 90.0), z = 2 }) :: Nil) }

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
        { name = "tiles", passes = Nil, targets = Map.empty(), submits = Some(1), staticLayer = None,
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
        { name = "staticLayer", passes = Nil, targets = Map.empty(), submits = Some(1), tiles = noTiles(),
          staticLayer = Some({ key = "v1-static", polys = () -> staticPolys(),
                               viewOffset = v(20.0, 10.0), viewScale = v(1.5, 1.5), halfDesign = v(designW() / 2.0, designH() / 2.0) }),
          items = still(
              at(0.0, 0.0, RawDraw.box({ x = designW(), y = designH() }, c8(24, 24, 24), 0)) ::
              at(150.0, 90.0, RawDraw.box({ x = 40.0, y = 40.0 }, c8(200, 60, 200), 2)) ::
              Nil) }

    /// WebGPU がまだ描かない物だけの場面（mask つきスプライト）。GL とは比べない。
    pub def unsupported(): Scene =
        { name = "unsupported", tiles = noTiles(), staticLayer = None, passes = Nil, targets = Map.empty(), submits = None, items = still(
            at(120.0, 60.0, Render.Item.Sprite({ texture = "atlas", tint = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0,
                scale = { x = 2.0, y = 2.0 }, rotation = 0.0, centered = true, flipH = false, flipV = false, regionRect = None,
                zIndex = 1, blend = DrawCmd.BlendMode.Normal,
                maskPolys = ({ x = 0.0, y = 0.0 } :: { x = 8.0, y = 0.0 } :: { x = 0.0, y = 8.0 } :: Nil) :: Nil })) ::
            Nil) }
}
