// Shadow のテスト。具体値は Python で独立に手計算し pin する（テスト内で再計算ロジックを
// 組んで自己参照しない）。境界（光と辺が一直線）は「背面側として扱う」規約が一貫することを見る。

mod TestShadow {

    def at(x: Float64, y: Float64): Vec2.Vec2 = { x = x, y = y }

    def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 0.000001

    def vecNear(a: Vec2.Vec2, b: Vec2.Vec2): Bool =
        Float64.abs(a#x - b#x) < 0.000001 and Float64.abs(a#y - b#y) < 0.000001

    /// 2つの頂点列が同じ長さで、対応する頂点どうしがすべて近いか。
    def verticesNear(expected: List[Vec2.Vec2], actual: List[Vec2.Vec2]): Bool =
        List.length(expected) == List.length(actual) and
        (List.zip(expected, actual) |> List.forAll(pair -> {
            let (e, a) = pair;
            vecNear(e, a)
        }))

    /// 四角形の先頭頂点が (x, y) に近いものを1枚選ぶ（3辺以上返るケースから狙った辺を拾う近道）。
    def quadStartingAt(quads: List[List[Vec2.Vec2]], x: Float64, y: Float64): Option[List[Vec2.Vec2]] =
        quads |> List.find(q -> List.head(q) |> Option.map(v -> near(v#x, x) and near(v#y, y)) |> Option.getWithDefault(false))

    /// (quad, falloff) タプルから quad 部分だけ取り出す（rimQuads の戻り値を既存の
    /// quad リスト前提のヘルパーへ渡すための橋渡し）。
    def quadOf(pair: (List[Vec2.Vec2], Float64)): List[Vec2.Vec2] =
        let (quad, _) = pair;
        quad

    /// (quad, falloff) タプルから falloff 部分だけ取り出す。
    def falloffOf(pair: (List[Vec2.Vec2], Float64)): Float64 =
        let (_, falloff) = pair;
        falloff

    /// 中心 (0,0)・一辺10 の正方形（左上→右上→右下→左下＝画面上で時計回り）。
    def square(): List[Vec2.Vec2] =
        at(-5.0, -5.0) :: at(5.0, -5.0) :: at(5.0, 5.0) :: at(-5.0, 5.0) :: Nil

    /// 光が左遠くにあるとき、正方形の3辺（top/right/bottom）が影を落とし、left だけ前面。
    /// 「屋根が真横の太陽に照らされても背を向けている」のと同じで、点光源が有限距離にある限り
    /// 上下の辺も光に正対しない — 直感の「右の1辺だけ」より広い集合になるのが正しい幾何。
    @Test
    def testSquareLeftLightThreeBackFaces(): Unit \ Assert =
        let quads = Shadow.shadowQuads(at(-100.0, 0.0), square(), 100.0);
        Assert.assertEq(expected = 3, List.length(quads))

    /// 上の3枚のうち、right 辺（(5,-5)→(5,5)）由来の四角形の4頂点座標をpinする
    /// （v1=(5,-5), v2=(5,5) はそのまま、v1'/v2' は「光→頂点」方向へ100だけ伸ばした点）。
    @Test
    def testRightEdgeShadowQuadVertices(): Unit \ Assert =
        let quads = Shadow.shadowQuads(at(-100.0, 0.0), square(), 100.0);
        let rightQuad = quadStartingAt(quads, 5.0, -5.0);
        let expected = at(5.0, -5.0) :: at(5.0, 5.0) ::
                       at(104.88681377244376, 9.75651494154494) ::
                       at(104.88681377244376, -9.75651494154494) :: Nil;
        Assert.assertEq(expected = Some(true),
            Option.map(actual -> verticesNear(expected, actual), rightQuad))

    /// 光が正方形の中心にある縮退（内部光源）: 全4辺が背面になり、クラッシュせず4枚返る。
    @Test
    def testLightInsidePolygonReturnsAllFourFaces(): Unit \ Assert =
        let quads = Shadow.shadowQuads(at(0.0, 0.0), square(), 100.0);
        Assert.assertEq(expected = 4, List.length(quads))

    /// 光と辺が一直線（right 辺の中点 (5,0) の真上延長 (5,-100)）: 内積ちょうど0で
    /// 規約どおり背面側として扱われ、right 辺も影四角形に含まれる（top は明確に前面のまま）。
    @Test
    def testColinearLightBoundaryFallsToBackFace(): Unit \ Assert =
        let quads = Shadow.shadowQuads(at(5.0, -100.0), square(), 100.0);
        // colinear な配置では top(0,-1 法線)が最も光を向く前面、bottom/left/right寄りは背面
        // （3枚 = top だけが前面に残る）。
        // ここでは「right が背面判定に入っている（境界を律儀に背面として扱っている）」ことも見る。
        Assert.assertEq(expected = (3, true),
            (List.length(quads),
             quadStartingAt(quads, 5.0, -5.0) |> Option.map(_ -> true) |> Option.getWithDefault(false)))

    /// n=2（線分1本）の遮蔽物でも、往復2辺のうち光に背を向けた1本だけが影四角形になり
    /// 正しく1枚返る（薄い壁を多角形にせず線分で渡せることの証拠）。
    @Test
    def testTwoVertexSegmentOccluderReturnsOneQuad(): Unit \ Assert =
        let segment = at(0.0, -5.0) :: at(0.0, 5.0) :: Nil;
        let quads = Shadow.shadowQuads(at(-100.0, 0.0), segment, 100.0);
        let expected = at(0.0, -5.0) :: at(0.0, 5.0) ::
                       at(99.87523388778446, 9.993761694389224) ::
                       at(99.87523388778446, -9.993761694389224) :: Nil;
        Assert.assertEq(expected = (1, true),
            (List.length(quads),
             List.head(quads) |> Option.map(q -> verticesNear(expected, q)) |> Option.getWithDefault(false)))

    /// occluderOfCircle: segments 個の頂点、t=0 相当（真上 = center - (0, radius)）をpin。
    @Test
    def testOccluderOfCircleVertexCountAndTopPoint(): Unit \ Assert =
        let verts = Shadow.occluderOfCircle(at(10.0, 20.0), 4.0, 12);
        let top = List.head(verts);
        Assert.assertEq(expected = (12, Some(true)),
            (List.length(verts), Option.map(v -> vecNear(v, at(10.0, 16.0)), top)))

    /// occluderOfBox: 中心+サイズから左上→右上→右下→左下の4頂点。
    @Test
    def testOccluderOfBoxVertices(): Unit \ Assert =
        let verts = Shadow.occluderOfBox(at(10.0, 20.0), at(8.0, 4.0));
        let expected = at(6.0, 18.0) :: at(14.0, 18.0) :: at(14.0, 22.0) :: at(6.0, 22.0) :: Nil;
        Assert.assertEq(expected = true, verticesNear(expected, verts))

    /// occluderOf: Hit.HitShape からの変換が円・箱それぞれ正しい頂点数を作る
    /// （個々のオフセット反映は occluderOfCircle/occluderOfBox 側で確認済み）。
    @Test
    def testOccluderOfHitShape(): Unit \ Assert =
        let pos = at(100.0, 100.0);
        let circleShape = Hit.HitShape.CircleH({ dx = 5.0, dy = 0.0, r = 2.0 });
        let boxShape = Hit.HitShape.BoxH({ dx = 0.0, dy = 5.0, w = 6.0, h = 6.0 });
        let circleVerts = Shadow.occluderOf(pos, circleShape);
        let boxVerts = Shadow.occluderOf(pos, boxShape);
        Assert.assertEq(expected = (12, 4), (List.length(circleVerts), List.length(boxVerts)))

    // ── containsPoint: 影が壁を透過しないことの幾何検証 ──

    /// 光→壁→向こう側の点が一直線に近い配置で、その点が影四角形に含まれることを確認する
    /// （影が壁の向こうを覆えているかの最小限の証拠）。
    @Test
    def testShadowQuadContainsPointBehindWall(): Unit \ Assert =
        let quads = Shadow.shadowQuads(at(-100.0, 0.0), square(), 100.0);
        // right 辺(x=5)の影四角形は光の反対（+x）方向へ伸びる。その延長線上、
        // 壁のすぐ向こう (x=6, y=0) は right 由来の四角形の内側にあるはず。
        let rightQuad = quadStartingAt(quads, 5.0, -5.0);
        let behind = at(6.0, 0.0);
        Assert.assertEq(expected = Some(true),
            Option.map(q -> Shadow.containsPoint(q, behind), rightQuad))

    // ── itemsFor: Light との合成（blend/alpha/z の pin） ──

    /// フチ無し（rimWidth=0）の共通 cfg。互換確認や胴体/影四角形だけを見たいテストで使う。
    def cfgNoRim(): Shadow.ShadowConfig =
        { darkness = 0.6, z = 7, extrudeLength = 100.0, rimWidth = 0.0, rimStrength = 0.5 }

    /// itemsFor が返す PlacedItem が Multiply・alpha=darkness・cfg#z の黒 Poly になっていることを
    /// pin する（頂点そのものは shadowQuads 側で確認済みなので、ここでは合成の属性だけを見る）。
    /// n=2 の線分（占有物）は「胴体」を四角形にできない退化ケースなので、胴体 Poly の
    /// 頂点数=2（線分そのもの）・影四角形 Poly の頂点数=4 という 2 種の混在が pin される。
    @Test
    def testItemsForProducesMultiplyBlackPolyWithConfiguredAlphaAndZ(): Unit \ Assert =
        let light: Light.Light = { at = at(-100.0, 0.0), radius = 50.0, color = { r = 1.0, g = 1.0, b = 1.0 }, halo = 0.0 };
        let segment = at(0.0, -5.0) :: at(0.0, 5.0) :: Nil;
        let items = Shadow.itemsFor(light, segment :: Nil, cfgNoRim());
        let attrsOf = (placed: Render.PlacedItem) -> match placed#item {
            case Render.Item.Poly(p) => Some((p#blend, p#alpha, p#zIndex, p#color#r, List.length(p#vertices)))
            case _                   => None
        };
        // 2件: [0]=胴体(線分そのまま2頂点)、[1]=影四角形(4頂点)。
        Assert.assertEq(expected = (2,
                Some((DrawCmd.BlendMode.Multiply, 0.6, 7, 0.0, 2)),
                Some((DrawCmd.BlendMode.Multiply, 0.6, 7, 0.0, 4))),
            (List.length(items),
             List.head(items) |> Option.flatMap(attrsOf),
             List.drop(1, items) |> List.head |> Option.flatMap(attrsOf)))

    /// 遮蔽物自身の胴体（正方形）が itemsFor の出力に Multiply 黒 Poly として含まれることを
    /// 枚数と頂点集合の両方で pin する（「壁の胴体は影に含まれない＝ガラスの壁」の回帰防止）。
    /// square は3背面辺を持つので、items = 胴体1 + 影四角形3 = 4件になる。
    @Test
    def testItemsForIncludesOccluderBodyAsMultiplyPoly(): Unit \ Assert =
        let light: Light.Light = { at = at(-100.0, 0.0), radius = 50.0, color = { r = 1.0, g = 1.0, b = 1.0 }, halo = 0.0 };
        let items = Shadow.itemsFor(light, square() :: Nil, cfgNoRim());
        let bodyVertsOf = (placed: Render.PlacedItem) -> match placed#item {
            case Render.Item.Poly(p) => p#vertices
            case _                   => Nil
        };
        let body = List.head(items) |> Option.map(bodyVertsOf) |> Option.getWithDefault(Nil);
        Assert.assertEq(expected = (4, true), (List.length(items), sameVertexSet(square(), body)))

    /// 逆に、壁の手前（光と壁の間）の点は影四角形に含まれない。
    @Test
    def testShadowQuadExcludesPointInFrontOfWall(): Unit \ Assert =
        let quads = Shadow.shadowQuads(at(-100.0, 0.0), square(), 100.0);
        let rightQuad = quadStartingAt(quads, 5.0, -5.0);
        let inFront = at(-50.0, 0.0);
        Assert.assertEq(expected = Some(false),
            Option.map(q -> Shadow.containsPoint(q, inFront), rightQuad))

    // ── 凹ポリゴン・逆回り入力 ──

    /// L字（6頂点・右上を切り欠いた凹ポリゴン、画面上で時計回り）。
    /// 中心10四方の正方形から (0,-10)-(10,0) の角を欠けさせた形。
    def lShape(): List[Vec2.Vec2] =
        at(-10.0, -10.0) :: at(0.0, -10.0) :: at(0.0, 0.0) ::
        at(10.0, 0.0) :: at(10.0, 10.0) :: at(-10.0, 10.0) :: Nil

    /// 凹ポリゴン（L字）でも背面判定と四角形化が辺ごとに独立して働くことを枚数 pin で確認し、
    /// くぼみ（切り欠き）の内側の点が、凹の内側辺が落とす影四角形にちゃんと含まれる
    /// （凹形状でも壁の向こうを覆えている）ことを見る。正しさは総当たり幾何検証で確認済み。
    @Test
    def testConcavePolygonShadowCoversNotch(): Unit \ Assert =
        let quads = Shadow.shadowQuads(at(-150.0, -30.0), lShape(), 300.0);
        let notchPoint = at(5.0, -5.0);
        let anyContains = quads |> List.exists(q -> Shadow.containsPoint(q, notchPoint));
        Assert.assertEq(expected = (3, true), (List.length(quads), anyContains))

    /// quad の4頂点を「集合として」比較する（逆回り入力では各四角形の先頭頂点が
    /// v1↔v2 の入れ替わりで変わるため、開始点一致の verticesNear は使えない）。
    def sameVertexSet(a: List[Vec2.Vec2], b: List[Vec2.Vec2]): Bool =
        List.length(a) == List.length(b) and
        (a |> List.forAll(va -> b |> List.exists(vb -> vecNear(va, vb))))

    /// 頂点順を逆回り（List.reverse）にしても同じ3枚・同座標（頂点集合として同一）の
    /// 影四角形になる（signedArea の符号吸収がリファクタで一番壊れやすい箇所のため pin する）。
    @Test
    def testReversedWindingProducesSameQuads(): Unit \ Assert =
        let light = at(-100.0, 0.0);
        let forward = Shadow.shadowQuads(light, square(), 100.0);
        let reversed = Shadow.shadowQuads(light, List.reverse(square()), 100.0);
        let everyForwardQuadMatchedInReversed =
            forward |> List.forAll(qf -> reversed |> List.exists(qr -> sameVertexSet(qf, qr)));
        Assert.assertEq(expected = (3, true),
            (List.length(reversed), everyForwardQuadMatchedInReversed))

    // ── rimQuads: 光向き面（前面辺）のフチ ──

    /// 正方形+左からの光: 背面3辺(top/right/bottom)の逆で、前面はleft辺(-5,-5)-(-5,5)だけ。
    /// rimQuads はその1辺だけからストリップを1枚返す。他の遮蔽物なし(allShadowQuads=Nil)・
    /// radius=1000は辺までの距離(約95)より十分大きいので遮蔽/減衰の影響を受けない。
    @Test
    def testRimQuadsOfSquareLeftLightOnlyLeftEdgeIsFront(): Unit \ Assert =
        let rims = Shadow.rimQuads(at(-100.0, 0.0), square(), 2.5, 1000.0, Nil);
        Assert.assertEq(expected = 1, List.length(rims))

    /// left辺のストリップは「ポリゴンの内側（+x側）」へ寄る: 4頂点すべてが x=-5（辺そのもの）
    /// または x=-5+rimWidth（内側へ詰めた側）のどちらかになり、外側(x<-5)へは出ない。
    @Test
    def testRimQuadsHugInsideOfOccluder(): Unit \ Assert =
        let rimWidth = 2.5;
        let rims = Shadow.rimQuads(at(-100.0, 0.0), square(), rimWidth, 1000.0, Nil);
        let quads = List.map(quadOf, rims);
        let onEdgeOrInside = (v: Vec2.Vec2) -> near(v#x, -5.0) or near(v#x, -5.0 + rimWidth);
        let allInside = quads |> List.forAll(q -> q |> List.forAll(onEdgeOrInside));
        Assert.assertEq(expected = (1, true), (List.length(quads), allInside))

    /// rimWidth<=0 ではフチを作らない（既定 off = 互換の確認）。
    @Test
    def testRimQuadsEmptyWhenRimWidthZero(): Unit \ Assert =
        let rims = Shadow.rimQuads(at(-100.0, 0.0), square(), 0.0, 1000.0, Nil);
        Assert.assertEq(expected = 0, List.length(rims))

    /// itemsFor: rimWidth>0 のとき、light#color・Add・alpha=rimStrength の Poly が
    /// 胴体・影四角形の後ろに追加で並ぶことを pin する。
    /// n=2 の線分（1背面辺+1前面辺）: 胴体1 + 影四角形1 + フチ1 = 3件。
    /// radius=1000 は前面辺の中点(0,0)から光(-100,0)までの距離100より十分大きく、
    /// 遮蔽物も1個だけ(自己遮蔽なし)なので falloff=1.0・alpha=rimStrengthそのまま。
    @Test
    def testItemsForAddsAddBlendRimPolyWithLightColorAndStrength(): Unit \ Assert =
        let light: Light.Light = { at = at(-100.0, 0.0), radius = 1000.0,
                                     color = { r = 1.0, g = 0.75, b = 0.4 }, halo = 0.0 };
        let segment = at(0.0, -5.0) :: at(0.0, 5.0) :: Nil;
        let cfg = { darkness = 0.6, z = 7, extrudeLength = 100.0, rimWidth = 2.5, rimStrength = 0.5 };
        let items = Shadow.itemsFor(light, segment :: Nil, cfg);
        let attrsOf = (placed: Render.PlacedItem) -> match placed#item {
            case Render.Item.Poly(p) => Some((p#blend, p#alpha, p#zIndex, p#color#r, p#color#g, p#color#b))
            case _                   => None
        };
        let rim = List.drop(2, items) |> List.head |> Option.flatMap(attrsOf);
        Assert.assertEq(expected = (3, Some((DrawCmd.BlendMode.Add, 0.5, 7, 1.0, 0.75, 0.4))),
            (List.length(items), rim))

    // ── rimQuads: 遮蔽（修正D）・自己遮蔽（修正D）・距離減衰（修正E） ──

    /// 中心 (cx, 0)・一辺10 の正方形（square() と同じ形を任意の中心へ）。
    def squareAt(cx: Float64): List[Vec2.Vec2] =
        at(cx - 5.0, -5.0) :: at(cx + 5.0, -5.0) :: at(cx + 5.0, 5.0) :: at(cx - 5.0, 5.0) :: Nil

    /// 光・手前の正方形A(center=-50)・奥の正方形B(center=50)を一直線に並べる。
    /// A の right 辺(x=-45)が落とす影四角形が B の left 辺(前面, 中点(45,0))を覆うため、
    /// B のフチは出ない。A 自身の left 辺(前面, 中点(-55,0))は何にも遮られず出る（対照）。
    @Test
    def testRimQuadsBlockedByOtherOccludersShadow(): Unit \ Assert =
        let light = at(-100.0, 0.0);
        let a = squareAt(-50.0);
        let b = squareAt(50.0);
        let allShadowQuads = Shadow.shadowQuads(light, a, 200.0) ++ Shadow.shadowQuads(light, b, 200.0);
        let aRims = Shadow.rimQuads(light, a, 2.5, 1000.0, allShadowQuads);
        let bRims = Shadow.rimQuads(light, b, 2.5, 1000.0, allShadowQuads);
        // A: left辺(-55,-5)-(-55,5)由来のストリップが1枚出る。B: 前面辺が遮蔽されフチ0枚。
        Assert.assertEq(expected = (1, 0),
            (List.length(aRims), List.length(bRims)))

    /// A 自身のフチの中身も pin する: 内側(+x側)へ寄ったストリップの4頂点。
    @Test
    def testRimQuadsBlockedByOtherOccludersFrontEdgeVertices(): Unit \ Assert =
        let light = at(-100.0, 0.0);
        let a = squareAt(-50.0);
        let b = squareAt(50.0);
        let allShadowQuads = Shadow.shadowQuads(light, a, 200.0) ++ Shadow.shadowQuads(light, b, 200.0);
        let aRims = Shadow.rimQuads(light, a, 2.5, 1000.0, allShadowQuads);
        let expected = at(-55.0, 5.0) :: at(-55.0, -5.0) :: at(-52.5, -5.0) :: at(-52.5, 5.0) :: Nil;
        let actual = List.head(aRims) |> Option.map(quadOf);
        Assert.assertEq(expected = Some(true),
            Option.map(q -> verticesNear(expected, q), actual))

    /// L字（凹ポリゴン）の自己遮蔽: くぼみの奥の前面辺(v=(0,0)-(10,0)、中点(5,0))は
    /// 自分自身が落とす影四角形(自己遮蔽)に中点が含まれ、フチが消える。
    /// 他の2前面辺(top辺 (-10,-10)-(0,-10) 中点(-5,-10)、left辺 (-10,10)-(-10,-10) 中点(-10,0))
    /// は遮られず残る → rimQuads は3前面辺のうち2枚だけ返す。
    @Test
    def testRimQuadsSelfOcclusionOnConcavePolygon(): Unit \ Assert =
        let light = at(-150.0, -30.0);
        let occluder = lShape();
        let allShadowQuads = Shadow.shadowQuads(light, occluder, 300.0);
        let rims = Shadow.rimQuads(light, occluder, 2.5, 1000.0, allShadowQuads);
        let quads = List.map(quadOf, rims);
        let notchFrontStillLit = quads |> List.exists(q -> List.head(q) |> Option.map(v -> near(v#x, 0.0) and near(v#y, 0.0)) |> Option.getWithDefault(false));
        Assert.assertEq(expected = (2, false), (List.length(quads), notchFrontStillLit))

    /// 距離減衰: 光(0,0)・radius=100。正方形の中心 D を変えて前面辺(left辺)の中点までの
    /// 距離を作る。D=55→中点(50,0)距離50(radius内)→falloff=1.0。
    /// D=155→中点(150,0)距離150(=1.5*radius)→falloff=0.5。
    /// D=255→中点(250,0)距離250(>2*radius)→None(Polyごと省かれる)。
    @Test
    def testRimQuadsDistanceFalloff(): Unit \ Assert =
        let light = at(0.0, 0.0);
        let radius = 100.0;
        let withinRadius = Shadow.rimQuads(light, squareAt(55.0), 2.5, radius, Nil);
        let atOneAndHalfRadius = Shadow.rimQuads(light, squareAt(155.0), 2.5, radius, Nil);
        let beyondTwiceRadius = Shadow.rimQuads(light, squareAt(255.0), 2.5, radius, Nil);
        let falloffWithin = List.head(withinRadius) |> Option.map(falloffOf);
        let falloffHalf = List.head(atOneAndHalfRadius) |> Option.map(falloffOf);
        Assert.assertEq(expected = (Some(1.0), Some(0.5), 0),
            (falloffWithin, falloffHalf, List.length(beyondTwiceRadius)))

    /// itemsFor 経由でも falloff が rimStrength に乗算されて alpha に反映されることを pin する。
    /// D=155(1.5*radius)・rimStrength=0.5・falloff=0.5 → alpha=0.25。
    @Test
    def testItemsForAppliesFalloffToRimAlpha(): Unit \ Assert =
        let light: Light.Light = { at = at(0.0, 0.0), radius = 100.0,
                                     color = { r = 1.0, g = 1.0, b = 1.0 }, halo = 0.0 };
        let cfg = { darkness = 0.6, z = 7, extrudeLength = 400.0, rimWidth = 2.5, rimStrength = 0.5 };
        let items = Shadow.itemsFor(light, squareAt(155.0) :: Nil, cfg);
        let alphaOf = (placed: Render.PlacedItem) -> match placed#item {
            case Render.Item.Poly(p) => if (p#blend == DrawCmd.BlendMode.Add) Some(p#alpha) else None
            case _                   => None
        };
        let rimAlpha = items |> List.filterMap(alphaOf) |> List.head;
        Assert.assertEq(expected = Some(0.25), rimAlpha)


    // ── 立っている物を倒した影（projectedRuns） ──

    def runAt(x: Float64, y: Float64, w: Float64, h: Float64): PxSprite.Run = { x = x, y = y, w = w, h = h, key = "body" }

    def ink(): Color = { r = 0.1, g = 0.1, b = 0.2 }

    /// gradPolygon の頂点と濃さ（Poly でない物は bug!）。
    def polyOf(p: Render.PlacedItem): (List[Vec2.Vec2], List[Float64]) = match p#item {
        case Render.Item.Poly(poly) => (poly#vertices, poly#grad |> Option.getWithDefault(Nil) |> List.map(t -> t#alpha))
        case _                      => bug!("影は gradPolygon のはず")
    }

    def runsShadow(runs: List[PxSprite.Run], light: Vec2.Vec2): List[Render.PlacedItem] =
        Shadow.projectedRuns({ runs = runs, foot = at(100.0, 100.0), light = light, reach = 1.0, depth = 0.5,
                               ink = ink(), alpha = 0.8, z = 1 })

    /// 灯りが真左: 幅 2・高さ 10 の 1 列が右へ高さぶん倒れる。横へ倒れる影の太さは幅 × depth（2 × 0.5 = 1）。
    /// 濃さは根元 0.8 → 先 0。
    @Test
    def testProjectedRunsFallAwayFromTheLight(): Unit \ Assert =
        Assert.assertEq(expected = (((100.0, 99.5) :: (100.0, 100.5) :: (110.0, 100.5) :: (110.0, 99.5) :: Nil), (0.8 :: 0.8 :: 0.0 :: 0.0 :: Nil)) :: Nil,
                        runsShadow(runAt(99.0, 90.0, 2.0, 10.0) :: Nil, at(0.0, 100.0)) |> List.map(p -> {
                            let (vs, alphas) = polyOf(p);
                            (vs |> List.map(v -> (v#x, v#y)), alphas)
                        }))

    /// 同じ幅の 3 行は 1 枚に・幅の違う 2 行は 2 枚・灯りが足元に重なると何も出ない。
    @Test
    def testProjectedRunsMergeRowsOfTheSameWidth(): Unit \ Assert =
        let same = runAt(99.0, 97.0, 2.0, 1.0) :: runAt(99.0, 98.0, 2.0, 1.0) :: runAt(99.0, 99.0, 2.0, 1.0) :: Nil;
        let differ = runAt(99.0, 95.0, 2.0, 5.0) :: runAt(98.0, 90.0, 4.0, 5.0) :: Nil;
        Assert.assertEq(expected = (1, 2, 0),
            (List.length(runsShadow(same, at(0.0, 100.0))), List.length(runsShadow(differ, at(0.0, 100.0))),
             List.length(runsShadow(same, at(100.0, 100.0)))))

    /// 濃さは影全体で付く: 高さ 10 の影の真ん中（高さ 5）の境で、下の帯の先と上の帯の根元が同じ 0.8 × 0.5 = 0.4。
    @Test
    def testProjectedRunsFadeAcrossTheWholeShadow(): Unit \ Assert =
        let differ = runAt(99.0, 95.0, 2.0, 5.0) :: runAt(98.0, 90.0, 4.0, 5.0) :: Nil;
        Assert.assertEq(expected = (0.8 :: 0.8 :: 0.4 :: 0.4 :: Nil) :: (0.4 :: 0.4 :: 0.0 :: 0.0 :: Nil) :: Nil,
                        runsShadow(differ, at(0.0, 100.0)) |> List.map(p -> snd(polyOf(p))))
}
