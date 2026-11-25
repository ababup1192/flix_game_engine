// TestScene3dCheck — 置いた物の見た目と当たりの食い違いの検査（Scene3dCheck.check）:
// 食い違いの無い部屋は空・見た目の無い当たりの箱は InvisibleWall・当たりの無い柵は PassableVisual・壁の切れ目は EscapeHole（体より狭い切れ目は抜けない）。

mod TestScene3dCheck {
    use Scene3dCheck.{Problem}

    def body(): CharacterBody3d.Settings = CharacterBody3d.settings(0.3, 1.6)

    def v(x: Float64, y: Float64, z: Float64): Vec3.Vec3 = Vec3.v3(x, y, z)

    /// min〜max の箱の見た目（名前 name）。
    def visualBox(name: String, lo: Vec3.Vec3, hi: Vec3.Vec3): Scene3d.Instance3d =
        let p = (x: Float64, y: Float64, z: Float64) -> v(x, y, z);
        let c = Color.rgb(0.7, 0.7, 0.7);
        let mesh = Mesh3d.fromPolygons(
            { points = p(lo#x, lo#y, lo#z) :: p(lo#x, hi#y, lo#z) :: p(hi#x, hi#y, lo#z) :: p(hi#x, lo#y, lo#z) :: Nil, color = c } ::
            { points = p(hi#x, lo#y, hi#z) :: p(hi#x, hi#y, hi#z) :: p(lo#x, hi#y, hi#z) :: p(lo#x, lo#y, hi#z) :: Nil, color = c } ::
            { points = p(lo#x, hi#y, lo#z) :: p(lo#x, hi#y, hi#z) :: p(hi#x, hi#y, hi#z) :: p(hi#x, hi#y, lo#z) :: Nil, color = c } ::
            { points = p(lo#x, lo#y, hi#z) :: p(lo#x, lo#y, lo#z) :: p(hi#x, lo#y, lo#z) :: p(hi#x, lo#y, hi#z) :: Nil, color = c } :: Nil);
        Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withName(name)

    def solidBox(lo: Vec3.Vec3, hi: Vec3.Vec3): CollisionShape3d.Box3d =
        CollisionShape3d.box3d(Vec3.mul(Vec3.add(lo, hi), 0.5), Vec3.mul(Vec3.sub(hi, lo), 0.5))

    /// 床と、z = +5 の壁に door の幅の切れ目（0 なら切れ目なし）を開けた 4 枚の壁の部屋（見た目と当たりが同じ所）。
    def room(door: Float64): List[(String, Vec3.Vec3, Vec3.Vec3)] =
        let half = door / 2.0;
        let north = if (door > 0.0) ("northL", v(-5.0, 0.0, 4.9), v(0.0 - half, 3.0, 5.1)) :: ("northR", v(half, 0.0, 4.9), v(5.0, 3.0, 5.1)) :: Nil
                    else ("north", v(-5.0, 0.0, 4.9), v(5.0, 3.0, 5.1)) :: Nil;
        ("floor", v(-5.0, -0.2, -5.0), v(5.0, 0.0, 5.0)) :: ("south", v(-5.0, 0.0, -5.1), v(5.0, 3.0, -4.9)) ::
        ("west", v(-5.1, 0.0, -5.0), v(-4.9, 3.0, 5.0)) :: ("east", v(4.9, 0.0, -5.0), v(5.1, 3.0, 5.0)) :: north

    def visualsOf(parts: List[(String, Vec3.Vec3, Vec3.Vec3)]): List[Scene3d.Instance3d] = parts |> List.map(match (n, lo, hi) -> visualBox(n, lo, hi))

    def solidsOf(parts: List[(String, Vec3.Vec3, Vec3.Vec3)]): List[CollisionShape3d.Box3d] = parts |> List.map(match (_, lo, hi) -> solidBox(lo, hi))

    def checked(visible: List[Scene3d.Instance3d], solids: List[CollisionShape3d.Box3d]): List[Problem] =
        Scene3dCheck.check(visible, CollisionWorld3d.build(2.0, solids), body(), v(0.0, 0.0, 0.0))

    @Test
    def testMatchingClosedRoomHasNoProblem(): Unit \ Assert =
        Assert.assertEq(expected = Nil, checked(visualsOf(room(0.0)), solidsOf(room(0.0))))

    @Test
    def testBoxWithoutVisualIsInvisibleWall(): Unit \ Assert =
        let extra = solidBox(v(1.0, 0.0, 1.0), v(2.0, 1.0, 2.0));
        Assert.assertEq(expected = Problem.InvisibleWall(1.5, 0.5, 1.5) :: Nil, checked(visualsOf(room(0.0)), extra :: solidsOf(room(0.0))))

    @Test
    def testFenceWithoutBoxIsPassableVisual(): Unit \ Assert =
        let fence = visualBox("fence", v(-2.0, 0.0, 1.0), v(2.0, 1.0, 1.05));
        Assert.assertEq(expected = Problem.PassableVisual("fence") :: Nil, checked(fence :: visualsOf(room(0.0)), solidsOf(room(0.0))))

    @Test
    def testCupOnATableIsNotPassable(): Unit \ Assert =
        let table = ("table", v(1.0, 0.0, 1.0), v(2.0, 0.75, 2.0));
        let cup = visualBox("cup", v(1.4, 0.75, 1.4), v(1.5, 0.85, 1.5));
        let parts = table :: room(0.0);
        Assert.assertEq(expected = Nil, checked(cup :: visualsOf(parts), solidsOf(parts)))

    @Test
    def testLampAboveTheHeadIsNotPassable(): Unit \ Assert =
        let lamp = visualBox("lamp", v(-0.5, 2.2, -0.5), v(0.5, 2.9, 0.5));
        Assert.assertEq(expected = Nil, checked(lamp :: visualsOf(room(0.0)), solidsOf(room(0.0))))

    @Test
    def testWindowAboveANarrowSillIsNotPassable(): Unit \ Assert =
        let sill = ("sill", v(-1.0, 0.0, 1.0), v(1.0, 1.0, 1.15));
        let sash = visualBox("sash", v(-1.0, 1.0, 1.05), v(1.0, 2.2, 1.1));
        let parts = sill :: room(0.0);
        Assert.assertEq(expected = Nil, checked(sash :: visualsOf(parts), solidsOf(parts)))

    @Test
    def testSamePartNameIsReportedOnce(): Unit \ Assert =
        let left = visualBox("fence", v(-2.0, 0.0, 1.0), v(-1.0, 1.0, 1.05));
        let right = visualBox("fence", v(1.0, 0.0, 1.0), v(2.0, 1.0, 1.05));
        Assert.assertEq(expected = Problem.PassableVisual("fence") :: Nil, checked(left :: right :: visualsOf(room(0.0)), solidsOf(room(0.0))))

    @Test
    def testDoorGapIsEscapeHole(): Unit \ Assert =
        Assert.assertEq(expected = Problem.EscapeHole(0.08, 0.0, 5.17) :: Nil, checked(visualsOf(room(1.5)), solidsOf(room(1.5))))

    @Test
    def testGapABitWiderThanTheBodyIsEscapeHole(): Unit \ Assert =
        Assert.assertEq(expected = Problem.EscapeHole(0.08, 0.0, 5.17) :: Nil, checked(visualsOf(room(0.8)), solidsOf(room(0.8))))

    @Test
    def testNoBoxAtAllIsEscapeHoleAtStart(): Unit \ Assert =
        Assert.assertEq(expected = Problem.EscapeHole(0.0, 0.0, 0.0) :: Nil, checked(visualsOf(room(0.0)), Nil))

    @Test
    def testStartInsideABoxIsEscapeHoleAtStart(): Unit \ Assert =
        let pillar = ("pillar", v(-0.5, 0.0, -0.5), v(0.5, 3.0, 0.5));
        let parts = pillar :: room(0.0);
        Assert.assertEq(expected = Problem.EscapeHole(0.0, 0.0, 0.0) :: Nil, checked(visualsOf(parts), solidsOf(parts)))

    @Test
    def testTiledFloorOverASunkBoxWithoutVisualIsInvisibleWall(): Unit \ Assert =
        let tiles = List.range(0, 10) |> List.flatMap(ix -> List.range(0, 10) |> List.map(iz -> {
            let (x, z) = (Int32.toFloat64(ix) - 5.0, Int32.toFloat64(iz) - 5.0);
            let top = { points = v(x, 0.0, z) :: v(x, 0.0, z + 1.0) :: v(x + 1.0, 0.0, z + 1.0) :: v(x + 1.0, 0.0, z) :: Nil, color = Color.rgb(0.5, 0.5, 0.5) };
            Scene3d.meshInstance(Mesh3d.fromPolygons(top :: Nil), Mat4.identity()) |> Scene3d.withName("tile")
        }));
        let walls = room(0.0) |> List.drop(1);
        let sunk = solidBox(v(1.0, -0.1, 1.0), v(3.0, 1.0, 3.0));
        let solids = solidBox(v(-5.0, -0.2, -5.0), v(5.0, 0.0, 5.0)) :: sunk :: solidsOf(walls);
        Assert.assertEq(expected = Problem.InvisibleWall(2.0, 0.45, 2.0) :: Nil, checked(List.append(tiles, visualsOf(walls)), solids))

    @Test
    def testBoxSunkIntoTheFloorWithoutVisualIsInvisibleWall(): Unit \ Assert =
        let sunk = solidBox(v(1.0, -0.1, 1.0), v(2.0, 1.0, 2.0));
        Assert.assertEq(expected = Problem.InvisibleWall(1.5, 0.45, 1.5) :: Nil, checked(visualsOf(room(0.0)), sunk :: solidsOf(room(0.0))))

    @Test
    def testOneBigFloorOverSplitFloorBoxesIsVisible(): Unit \ Assert =
        let walls = room(0.0) |> List.drop(1);
        let floorBoxes = solidBox(v(-5.0, -0.2, -5.0), v(0.0, 0.0, 5.0)) :: solidBox(v(0.0, -0.2, -5.0), v(5.0, 0.0, 5.0)) :: Nil;
        let bigFloor = visualBox("floor", v(-5.0, -0.2, -5.0), v(5.0, 0.0, 5.0));
        Assert.assertEq(expected = Nil, checked(bigFloor :: visualsOf(walls), List.append(floorBoxes, solidsOf(walls))))

    @Test
    def testGapNarrowerThanTheBodyDoesNotEscape(): Unit \ Assert =
        Assert.assertEq(expected = Nil, checked(visualsOf(room(0.4)), solidsOf(room(0.4))))

    @Test
    def testPaintedDoorIsEscapeHoleAndNotAWall(): Unit \ Assert =
        let painted = visualBox("door", v(-0.75, 0.0, 4.9), v(0.75, 2.2, 5.1));
        let found = checked(painted :: visualsOf(room(1.5)), solidsOf(room(1.5)));
        Assert.assertEq(expected = (true, true), (List.exists(p -> p == Problem.PassableVisual("door"), found),
                                                 List.exists(p -> match p { case Problem.EscapeHole(_, _, _) => true case _ => false }, found)))
}
