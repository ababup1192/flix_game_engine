// Light の単体テスト: singleLightItems（穴あきオーバーレイ1+周囲黒帯4+ハロ1の6枚）と
// multiLightItems（全面オーバーレイ+ハロN枚の近似）の出力を、Render.draw に通した
// Drawable（record なので match 不要で読める）で個数・blend種別・zIndex・tint を pin する。
mod TestLight {

    def orange(): Color = { r = 1.0, g = 0.6, b = 0.2 }

    def sampleLight(): Light.Light =
        { at = { x = 100.0, y = 80.0 }, radius = 40.0, color = orange(), halo = 0.6 }

    /// テスト用 holeFrac。engine_world は engine_tools（RadialGlow の所属先）に依存できない
    /// ため直接参照できず、値を複製する。RadialGlow.defaultHoleFrac() と揃えておかないと
    /// 実際に生成するテクスチャと maskScale の前提がずれる — 変えたときは両方揃えて直すこと。
    def holeFrac(): Float64 = 0.5

    def sampleDarkness(): Float64 = 0.95

    def singleCfg(): Light.SingleLightConfig =
        { light = sampleLight(), viewport = { x = 320.0, y = 240.0 },
          maskSprite = "glow_mask", maskSourceSize = 512.0, maskHoleFrac = holeFrac(),
          haloSprite = "glow_halo", haloSourceSize = 256.0, darkness = sampleDarkness(), z = 10 }

    // singleLightItems は 7 枚（オーバーレイ1 → 周囲黒帯4 → ハロ1、の 6 枚のはずが実装順は
    // オーバーレイ :: 黒帯4 :: ハロ = 6 枚）。
    @Test
    def testSingleLightItemsHasMaskSurroundThenHalo(): Unit \ Assert =
        let (drawables, _) = Render.draw(Light.singleLightItems(singleCfg()));
        Assert.assertEq(expected = 6, List.length(drawables))

    // オーバーレイは Multiply・zIndex=cfg#z・texture=maskSprite・光の位置が中心（centered sprite）・
    // alpha=darkness。
    @Test
    def testSingleLightMaskIsMultiplyAtCfgZ(): Unit \ Assert =
        let (drawables, _) = Render.draw(Light.singleLightItems(singleCfg()));
        let mask = List.head(drawables);
        Assert.assertEq(
            expected = Some((DrawCmd.BlendMode.Multiply, 10, "glow_mask", 100.0, 80.0, 0.95)),
            mask |> Option.map(d -> (DrawCmd.blendOf(d), DrawCmd.zIndexOf(d), DrawCmd.textureOf(d), DrawCmd.positionOf(d)#x, DrawCmd.positionOf(d)#y, DrawCmd.alphaOf(d))))

    // ハロは末尾・Add・zIndex=cfg#z+1・texture=haloSprite・tint=light#color・alpha=light#halo。
    // Color はレコードで Eq/ToString を持たないため r/g/b を個別に比較する。
    @Test
    def testSingleLightHaloIsAddWithLightTint(): Unit \ Assert =
        let (drawables, _) = Render.draw(Light.singleLightItems(singleCfg()));
        let halo = List.last(drawables);
        Assert.assertEq(
            expected = Some((DrawCmd.BlendMode.Add, 11, "glow_halo", 1.0, 0.6, 0.2, 0.6)),
            halo |> Option.map(d -> (DrawCmd.blendOf(d), DrawCmd.zIndexOf(d), DrawCmd.textureOf(d), DrawCmd.colorOf(d)#r, DrawCmd.colorOf(d)#g, DrawCmd.colorOf(d)#b, DrawCmd.alphaOf(d))))

    // オーバーレイのスケールは「穴の実寸半径=radius」から逆算した倍率のみ（coverage 下限は廃止）。
    // radius=40, holeFrac=0.5, maskSourceSize=512 → 40/(0.5*512/2) = 0.3125。
    // radius が小さくても、この倍率で穴半径がちゃんと radius になる（下の pin テストで確認）。
    @Test
    def testSingleLightMaskScalesFromRadiusOnly(): Unit \ Assert =
        let (drawables, _) = Render.draw(Light.singleLightItems(singleCfg()));
        let mask = List.head(drawables);
        Assert.assertEq(expected = Some(0.3125), mask |> Option.map(d -> DrawCmd.scaleOf(d)#x))

    // radius を大きくしても（200）同じ式で線形に伸びる（200/(0.5*512/2) = 1.5625）。
    // coverage 下限が無いので、viewport の大小に関わらず穴半径=radius が常に守られる。
    @Test
    def testSingleLightMaskScalesLinearlyWithRadius(): Unit \ Assert =
        let bigLight = { radius = 200.0 | sampleLight() };
        let cfg = { light = bigLight | singleCfg() };
        let (drawables, _) = Render.draw(Light.singleLightItems(cfg));
        let mask = List.head(drawables);
        Assert.assertEq(expected = Some(1.5625), mask |> Option.map(d -> DrawCmd.scaleOf(d)#x))

    // 穴の実寸半径 = maskSourceSize × scale × holeFrac / 2 が、どの radius でも radius 自身に
    // 一致する（設計の核心の pin）。
    @Test
    def testSingleLightHoleRadiusMatchesLightRadius(): Unit \ Assert =
        let radii = 10.0 :: 40.0 :: 200.0 :: Nil;
        let holeRadiusOf = r -> {
            let cfg = { light = { radius = r | sampleLight() } | singleCfg() };
            let (drawables, _) = Render.draw(Light.singleLightItems(cfg));
            let scale = List.head(drawables) |> Option.map(d -> DrawCmd.scaleOf(d)#x) |> Option.getWithDefault(0.0);
            scale * cfg#maskSourceSize * holeFrac() / 2.0
        };
        Assert.assertEq(expected = radii, List.map(holeRadiusOf, radii))

    // 周囲の黒帯4枚（オーバーレイの次〜ハロの前）は Multiply・cfg#z・alpha=darkness で、
    // mask 正方形と同じ z-index の範囲に隙間なく敷かれる。
    @Test
    def testSingleLightSurroundBoxesAreMultiplyAtCfgZWithDarkness(): Unit \ Assert =
        let (drawables, _) = Render.draw(Light.singleLightItems(singleCfg()));
        let surround = drawables |> List.drop(1) |> List.take(4);
        let props = surround |> List.map(d -> (DrawCmd.blendOf(d), DrawCmd.zIndexOf(d), DrawCmd.alphaOf(d)));
        Assert.assertEq(
            expected = (DrawCmd.BlendMode.Multiply, 10, 0.95) :: (DrawCmd.BlendMode.Multiply, 10, 0.95)
                :: (DrawCmd.BlendMode.Multiply, 10, 0.95) :: (DrawCmd.BlendMode.Multiply, 10, 0.95) :: Nil,
            props)

    // ハロのスケールは「光の直径 / haloSourceSize」= 80/256 = 0.3125。
    @Test
    def testSingleLightHaloScalesToLightDiameter(): Unit \ Assert =
        let (drawables, _) = Render.draw(Light.singleLightItems(singleCfg()));
        let halo = List.last(drawables);
        Assert.assertEq(expected = Some(0.3125), halo |> Option.map(d -> DrawCmd.scaleOf(d)#x))

    // ── multiLightItems ──

    def twoLights(): List[Light.Light] =
        sampleLight() :: { at = { x = 200.0, y = 150.0 }, radius = 20.0, color = orange(), halo = 0.4 } :: Nil

    def multiCfg(): Light.MultiLightConfig =
        { lights = twoLights(), darkness = 0.8, viewport = { x = 320.0, y = 240.0 },
          haloSprite = "glow_halo", haloSourceSize = 256.0, z = 5 }

    // 全面オーバーレイ1枚 + 光の数ぶんのハロ（2 光源なら 3 枚）。
    @Test
    def testMultiLightItemsCountsCoverPlusHaloes(): Unit \ Assert =
        let (drawables, _) = Render.draw(Light.multiLightItems(multiCfg()));
        Assert.assertEq(expected = 3, List.length(drawables))

    // 全面オーバーレイは Multiply・zIndex=cfg#z・alpha=darkness・画面全体を覆う矩形（左上が原点）。
    @Test
    def testMultiLightCoverIsMultiplyFullScreen(): Unit \ Assert =
        let (drawables, _) = Render.draw(Light.multiLightItems(multiCfg()));
        let cover = List.head(drawables);
        Assert.assertEq(
            expected = Some((DrawCmd.BlendMode.Multiply, 5, 0.8, 0.0, 0.0, 320.0, 240.0)),
            cover |> Option.map(d -> (DrawCmd.blendOf(d), DrawCmd.zIndexOf(d), DrawCmd.alphaOf(d), DrawCmd.positionOf(d)#x, DrawCmd.positionOf(d)#y, DrawCmd.scaleOf(d)#x, DrawCmd.scaleOf(d)#y)))

    // ハロは全て zIndex=cfg#z+1（重なり順に依らず Add で足し合わさるため同じ高さでよい）。
    @Test
    def testMultiLightHaloesShareSameZIndex(): Unit \ Assert =
        let (drawables, _) = Render.draw(Light.multiLightItems(multiCfg()));
        let haloZs = List.drop(1, drawables) |> List.map(d -> DrawCmd.zIndexOf(d));
        Assert.assertEq(expected = 6 :: 6 :: Nil, haloZs)

    // 2 つ目のハロは 2 つ目の光の色・強さ・位置を反映する。
    @Test
    def testMultiLightSecondHaloUsesSecondLight(): Unit \ Assert =
        let (drawables, _) = Render.draw(Light.multiLightItems(multiCfg()));
        let second = List.drop(2, drawables) |> List.head;
        Assert.assertEq(
            expected = Some((DrawCmd.BlendMode.Add, 200.0, 150.0, 0.4)),
            second |> Option.map(d -> (DrawCmd.blendOf(d), DrawCmd.positionOf(d)#x, DrawCmd.positionOf(d)#y, DrawCmd.alphaOf(d))))

    // ── items（唯一の入口。単一/複数の振り分け + haloDiameterFactor + occluders 合成）──

    def sceneCfg(lights: List[Light.Light], occluders: List[List[Vec2.Vec2]]): Light.SceneLightConfig =
        { lights = lights, occluders = occluders,
          viewport = { x = 320.0, y = 240.0 }, glow = Light.defaultGlowAssets(),
          darkness = sampleDarkness(), z = 10,
          rimWidth = Shadow.defaultRimWidth(), rimStrength = Shadow.defaultRimStrength(),
          haloDiameterFactor = 1.0 }

    // lights=0 個は multiLightItems を lights=Nil で呼ぶのと同じ枚数（全面オーバーレイ1枚のみ）。
    @Test
    def testItemsZeroLightsIsCoverOnly(): Unit \ Assert =
        let (drawables, _) = Render.draw(Light.items(sceneCfg(Nil, Nil)));
        Assert.assertEq(expected = 1, List.length(drawables))

    // lights=1 個・occludersなしは singleLightItems と同じ 6 枚（haloDiameterFactor=1.0 なら
    // ハロの scale も singleLightItems 直呼びと同じ値になる）。
    @Test
    def testItemsOneLightMatchesSingleLightItems(): Unit \ Assert =
        let cfg = sceneCfg(sampleLight() :: Nil, Nil);
        let (drawables, _) = Render.draw(Light.items(cfg));
        let (directDrawables, _) = Render.draw(Light.singleLightItems({
            light = sampleLight(), viewport = cfg#viewport,
            maskSprite = cfg#glow#maskSprite, maskSourceSize = cfg#glow#maskSourceSize,
            maskHoleFrac = cfg#glow#maskHoleFrac,
            haloSprite = cfg#glow#haloSprite, haloSourceSize = cfg#glow#haloSourceSize,
            darkness = cfg#darkness, z = cfg#z }));
        Assert.assertEq(
            expected = (6, List.map(d -> DrawCmd.scaleOf(d)#x, directDrawables)),
            (List.length(drawables), List.map(d -> DrawCmd.scaleOf(d)#x, drawables)))

    // haloDiameterFactor はハロ（末尾）だけを拡大する。オーバーレイ（先頭）の scale は変わらない。
    @Test
    def testItemsHaloDiameterFactorGrowsOnlyHalo(): Unit \ Assert =
        let cfg = { haloDiameterFactor = 2.0 | sceneCfg(sampleLight() :: Nil, Nil) };
        let (drawables, _) = Render.draw(Light.items(cfg));
        let maskScale = List.head(drawables) |> Option.map(d -> DrawCmd.scaleOf(d)#x);
        let haloScale = List.last(drawables) |> Option.map(d -> DrawCmd.scaleOf(d)#x);
        Assert.assertEq(
            expected = (Some(0.3125), Some(0.3125 * 2.0)),
            (maskScale, haloScale))

    // lights=1 個・occludersありは Shadow.itemsFor の結果が末尾に合流する
    // （singleLightItems の 6 枚 + 遮蔽物1個ぶんの itemsFor 出力）。
    @Test
    def testItemsOneLightWithOccludersAppendsShadow(): Unit \ Assert =
        let occluder = Shadow.occluderOfBox({ x = 100.0, y = 80.0 }, { x = 20.0, y = 20.0 });
        let cfg = sceneCfg(sampleLight() :: Nil, occluder :: Nil);
        let (withShadow, _) = Render.draw(Light.items(cfg));
        let (withoutShadow, _) = Render.draw(Light.items({ occluders = Nil | cfg }));
        let expectedShadowItems = Shadow.itemsFor(sampleLight(), occluder :: Nil,
            { darkness = cfg#darkness, z = cfg#z, extrudeLength = Shadow.infiniteExtrude(),
              rimWidth = cfg#rimWidth, rimStrength = cfg#rimStrength });
        let (shadowOnly, _) = Render.draw(expectedShadowItems);
        Assert.assertEq(
            expected = List.length(withoutShadow) + List.length(shadowOnly),
            List.length(withShadow))

    // lights=2 個以上は occluders を渡しても影が増えない（multiLightItems と同じ枚数）
    // — 複数光源では影が出ない制約の pin。
    @Test
    def testItemsMultiLightsIgnoreOccluders(): Unit \ Assert =
        let occluder = Shadow.occluderOfBox({ x = 100.0, y = 80.0 }, { x = 20.0, y = 20.0 });
        let cfg = sceneCfg(twoLights(), occluder :: Nil);
        let (drawables, _) = Render.draw(Light.items(cfg));
        Assert.assertEq(expected = 3, List.length(drawables))

    // ── lightMapPass / lightMapOverlay（光マップ方式: 複数光源＋影つき）──

    def mapOccluder(): List[Vec2.Vec2] =
        Shadow.occluderOfBox({ x = 150.0, y = 110.0 }, { x = 20.0, y = 30.0 })

    def lightMapCfg(lights: List[Light.Light], occluders: List[List[Vec2.Vec2]]): Light.LightMapConfig =
        { lights = lights, occluders = occluders,
          viewport = { x = 320.0, y = 240.0 },
          ambient = Light.defaultAmbient(), shadowStrength = Light.defaultShadowStrength(),
          extrudeLength = Shadow.infiniteExtrude(),
          passName = "light", z = 90 }

    // pass の name/clear は cfg#passName と黒 Clear（環境光は clear でなく先頭の box が担う）。
    @Test
    def testLightMapPassNameAndClear(): Unit \ Assert =
        let p = Light.lightMapPass(lightMapCfg(twoLights(), Nil));
        let clearIsBlack = match p#clear {
            case RenderTarget.LoadOp.Clear(c) => c#r == 0.0 and c#g == 0.0 and c#b == 0.0
            case _                            => false
        };
        Assert.assertEq(expected = ("light", true), (p#name, clearIsBlack))

    // 先頭は環境光の全面 box（viewport いっぱい・ambient 色・z=0・Normal）。
    @Test
    def testLightMapPassAmbientIsFirst(): Unit \ Assert =
        let (drawables, _) = Render.draw(Light.lightMapPass(lightMapCfg(twoLights(), Nil))#items);
        let ambientBox = List.head(drawables);
        Assert.assertEq(
            expected = Some((DrawCmd.BlendMode.Normal, 0, 0.0, 0.0, 320.0, 240.0,
                             Light.defaultAmbient()#r, Light.defaultAmbient()#g, Light.defaultAmbient()#b)),
            ambientBox |> Option.map(d -> (DrawCmd.blendOf(d), DrawCmd.zIndexOf(d), DrawCmd.positionOf(d)#x, DrawCmd.positionOf(d)#y,
                                           DrawCmd.scaleOf(d)#x, DrawCmd.scaleOf(d)#y, DrawCmd.colorOf(d)#r, DrawCmd.colorOf(d)#g, DrawCmd.colorOf(d)#b)))

    // 放射は光の数ぶん（2 光源なら sprite 2 枚）。全て組み込み放射テクスチャの Add。
    @Test
    def testLightMapPassRadiancePerLight(): Unit \ Assert =
        let (drawables, _) = Render.draw(Light.lightMapPass(lightMapCfg(twoLights(), Nil))#items);
        let radiance = List.drop(1, drawables);
        Assert.assertEq(
            expected = (2, true),
            (List.length(radiance),
             radiance |> List.forAll(d -> DrawCmd.blendOf(d) == DrawCmd.BlendMode.Add and DrawCmd.textureOf(d) == RadialBuiltin.lightName())))

    // 放射の alpha は light#halo の写し・位置は light#at（halo → strength の橋渡しの pin）。
    @Test
    def testLightMapPassRadianceCarriesHaloAndAt(): Unit \ Assert =
        let (drawables, _) = Render.draw(Light.lightMapPass(lightMapCfg(twoLights(), Nil))#items);
        let second = List.drop(2, drawables) |> List.head;
        Assert.assertEq(
            expected = Some((200.0, 150.0, 0.4)),
            second |> Option.map(d -> (DrawCmd.positionOf(d)#x, DrawCmd.positionOf(d)#y, DrawCmd.alphaOf(d))))

    // 影四角形の枚数 = 光ごとの背面辺の合計（2 光源 × 箱 1 個。Shadow.shadowQuads と同じ数）。
    @Test
    def testLightMapPassShadowCountMatchesBackEdges(): Unit \ Assert =
        let cfg = lightMapCfg(twoLights(), mapOccluder() :: Nil);
        let (_, polys) = Render.draw(Light.lightMapPass(cfg)#items);
        let expectedCount = twoLights()
            |> List.map(light -> List.length(Shadow.shadowQuads(light#at, mapOccluder(), cfg#extrudeLength)))
            |> List.sum;
        Assert.assertEq(expected = expectedCount, List.length(polys))

    // 影は環境光色・Normal・alpha=shadowStrength で、z は放射（10）より上の 20
    // （灯りを打ち消して環境光へ戻す並びの pin）。
    @Test
    def testLightMapPassShadowIsAmbientNormalAboveRadiance(): Unit \ Assert =
        let cfg = lightMapCfg(twoLights(), mapOccluder() :: Nil);
        let (_, polys) = Render.draw(Light.lightMapPass(cfg)#items);
        let strength = cfg#shadowStrength;
        Assert.assertEq(
            expected = true,
            polys |> List.forAll(p -> p#blend == DrawCmd.BlendMode.Normal and p#zIndex == 20
                and p#alpha == strength and p#color#r == Light.defaultAmbient()#r))

    // 影は occluders が空なら 1 枚も出ない（放射と環境光だけ）。
    @Test
    def testLightMapPassNoOccludersNoShadows(): Unit \ Assert =
        let (_, polys) = Render.draw(Light.lightMapPass(lightMapCfg(twoLights(), Nil))#items);
        Assert.assertEq(expected = 0, List.length(polys))

    // overlay は passName の sprite 1 枚を Multiply・z=cfg#z・viewport 中心に置く。
    @Test
    def testLightMapOverlayIsMultiplyAtCfgZ(): Unit \ Assert =
        let (drawables, _) = Render.draw(Light.lightMapOverlay(lightMapCfg(twoLights(), Nil)) :: Nil);
        Assert.assertEq(
            expected = Some((DrawCmd.BlendMode.Multiply, 90, "light", 160.0, 120.0)),
            List.head(drawables) |> Option.map(d -> (DrawCmd.blendOf(d), DrawCmd.zIndexOf(d), DrawCmd.textureOf(d), DrawCmd.positionOf(d)#x, DrawCmd.positionOf(d)#y)))
}
