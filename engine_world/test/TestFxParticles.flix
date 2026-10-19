// TestFxParticles — Fx.particles（粒の番号と中心）が、絵（Fx.sample）と同じ粒を同じ所に出すことを固定する。
// 当たり判定を絵とずらさないための口なので、絵の位置と比べる。
mod TestFxParticles {

    def emitter(): FxDoc.Emitter =
        { name = "sparks", count = 4, shape = FxDoc.Shape.Circle, size = 2.0,
          color = { r = 1.0, g = 1.0, b = 1.0 } :: Nil,
          life = { base = 1.0, vary = 0.0 },
          speed = { base = 10.0, vary = 0.0, over = FxDoc.CurveSpec.Constant },
          dir = { base = 90.0, spread = 0.0, mode = FxDoc.DirMode.Random },
          turn = { base = 0.0, spread = 0.0, spin = 0.0, spinSpread = 0.0 },
          mode = FxDoc.Mode.Burst, spawnArea = { w = 0.0, h = 0.0 }, accel = Vec2.zero(),
          wobble = { amp = Vec2.zero(), freq = Vec2.zero(), vary = 0.0 }, stretch = 0.05, seed = 0,
          sizeOver = FxDoc.CurveSpec.Constant, alphaOver = FxDoc.CurveSpec.Constant,
          blend = DrawCmd.BlendMode.Normal, zIndex = 3 }

    /// ばらつきのある spec（粒ごとに位置も大きさも違う）。
    def scattered(): FxDoc.Spec =
        { name = "test", duration = 1.0, note = None, emitters =
            { life = { base = 0.8, vary = 0.3 }, speed = { base = 140.0, vary = 0.4, over = FxDoc.CurveSpec.EaseOut({ power = 2.0 }) },
              dir = { base = 0.0, spread = 360.0, mode = FxDoc.DirMode.Random }, spawnArea = { w = 12.0, h = 6.0 },
              sizeOver = FxDoc.CurveSpec.Linear({ fromV = 1.0, toV = 0.2 }), count = 9 | emitter() } :: Nil }

    /// 円の粒の描き物の中心（circleAt は左上に置くので、半径ぶん戻す）。
    def drawnCenters(items: List[Render.PlacedItem]): List[(Float64, Float64)] =
        let (drawables, _) = Render.draw(items);
        drawables |> List.map(dd -> { let d = DrawCmd.toSpec(dd); (d#position#x + d#scale#x / 2.0, d#position#y + d#scale#y / 2.0) })

    def round(x: Float64): Float64 = Float64.round(x * 1000.0) / 1000.0

    /// 粒の中心は、絵の中心と同じ所（ばらつきのある spec の 0.3 秒・seed 7）。
    @Test
    def testCentersMatchTheDrawing(): Unit \ Assert =
        let spec = scattered();
        let fromParticles = Fx.particlesAt(spec, 7i64, 0.3, { x = 50.0, y = 20.0 })
            |> List.map(p -> (round(p#center#x), round(p#center#y)));
        let fromDrawing = drawnCenters(Fx.sampleAt(spec, 7i64, 0.3, { x = 50.0, y = 20.0 }))
            |> List.map(match (x, y) -> (round(x), round(y)));
        Assert.assertEq(expected = fromDrawing, fromParticles)

    /// 番号は emitter の中の粒の番号で、burst の周回は 0。中心は 速さ × 経過 だけ右（dir 90 度）。
    @Test
    def testIndexAndCenter(): Unit \ Assert =
        let spec = { name = "test", duration = 1.0, note = None, emitters = emitter() :: Nil };
        Assert.assertEq(expected = List#{(0, 0i64, 5.0, 0.0), (1, 0i64, 5.0, 0.0), (2, 0i64, 5.0, 0.0), (3, 0i64, 5.0, 0.0)},
            Fx.particles(spec, 0i64, 0.5) |> List.map(p -> (p#index, p#cycle, round(p#center#x), round(p#center#y))))

    /// 寿命の外は粒が無い（絵も無い）。
    @Test
    def testNoParticlesOutsideTheDuration(): Unit \ Assert =
        Assert.assertEq(expected = (0, 0), (List.length(Fx.particles(scattered(), 7i64, 1.5)), List.length(Fx.sample(scattered(), 7i64, 1.5))))

    /// touches は粒の半径ぶん広く当たる（中心 5 の粒・直径 2 に、4 から半径 0 は当たり、3.9 からは外れる）。
    @Test
    def testTouchesUsesTheParticleRadius(): Unit \ Assert =
        let spec = { name = "test", duration = 1.0, note = None, emitters = { count = 1 | emitter() } :: Nil };
        let particle = Fx.particles(spec, 0i64, 0.5) |> List.head;
        let hit = x -> particle |> Option.exists(Fx.touches({ center = { x = x, y = 0.0 }, radius = 0.0 }));
        Assert.assertEq(expected = (true, false), (hit(4.0), hit(3.9)))

    /// burst 全部の粒は drawAll と同じ時刻の取り方で出る（生まれた時刻 1.0・今 1.5 → 経過 0.5）。
    @Test
    def testParticlesOfAllUsesEachBurstsAge(): Unit \ Assert =
        let spec = { name = "test", duration = 1.0, note = None, emitters = { count = 1 | emitter() } :: Nil };
        let bursts = Fx.burst(spec, 0, { x = 100.0, y = 0.0 }, 1.0) :: Nil;
        Assert.assertEq(expected = List#{(105.0, 0.0)},
            Fx.particlesOfAll(1.5, bursts) |> List.map(p -> (round(p#center#x), round(p#center#y))))
}
