// TestMesh3dUv — Mesh3d の uv とタンジェント（withUvs・withTangents・fromTexturedPolygons・withBoxUvs・鍵）。
// 向きの約束（uv の (0, 0) が絵の左上・cross(法線, タンジェント) × w が絵の上）を、鏡写しで値が変わる問いで確かめる。
mod TestMesh3dUv {

    // ── 素材 ──────────────────────────────────────────────

    /// z = 5 の平面に立つ 1 辺 2 の四角（原点から +Z を見て時計回り = 原点の側（−Z）が表）。
    def plate(): Mesh3d.Mesh3d =
        Mesh3d.fromPolygons({ points = Vec3.v3(-1.0, -1.0, 5.0) :: Vec3.v3(-1.0, 1.0, 5.0) :: Vec3.v3(1.0, 1.0, 5.0) :: Vec3.v3(1.0, -1.0, 5.0) :: Nil,
                              color = Color.rgb(1.0, 1.0, 1.0) } :: Nil)

    /// 原点から見て u が右（+X）へ・v が下（−Y）へ増える plate の uv（左上の頂点 (−1, 1) が (0, 0)）。
    def plateUvs(): Vector[Float64] = Vector#{ 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0 }

    def texturedPlate(): Mesh3d.Mesh3d =
        match Mesh3d.withUvs(plateUvs(), plate()) {
            case Ok(m)  => m
            case Err(e) => bug!(e)
        }

    /// 1 辺 2 の立方体（6 面とも外から見て時計回り）。
    def cube(): Mesh3d.Mesh3d =
        let p = (x: Float64, y: Float64, z: Float64) -> Vec3.v3(x, y, z);
        let white = Color.rgb(1.0, 1.0, 1.0);
        let face = (pts: List[Vec3.Vec3]) -> { points = pts, color = white };
        Mesh3d.fromPolygons(
            face(p(1.0, -1.0, -1.0) :: p(1.0, 1.0, -1.0) :: p(1.0, 1.0, 1.0) :: p(1.0, -1.0, 1.0) :: Nil) ::      // +X
            face(p(-1.0, -1.0, 1.0) :: p(-1.0, 1.0, 1.0) :: p(-1.0, 1.0, -1.0) :: p(-1.0, -1.0, -1.0) :: Nil) ::  // −X
            face(p(-1.0, 1.0, -1.0) :: p(-1.0, 1.0, 1.0) :: p(1.0, 1.0, 1.0) :: p(1.0, 1.0, -1.0) :: Nil) ::      // +Y
            face(p(-1.0, -1.0, 1.0) :: p(-1.0, -1.0, -1.0) :: p(1.0, -1.0, -1.0) :: p(1.0, -1.0, 1.0) :: Nil) ::  // −Y
            face(p(1.0, -1.0, 1.0) :: p(1.0, 1.0, 1.0) :: p(-1.0, 1.0, 1.0) :: p(-1.0, -1.0, 1.0) :: Nil) ::      // +Z
            face(p(-1.0, -1.0, -1.0) :: p(-1.0, 1.0, -1.0) :: p(1.0, 1.0, -1.0) :: p(1.0, -1.0, -1.0) :: Nil) ::  // −Z
            Nil)

    def at3(v: Vector[Float64], k: Int32): Vec3.Vec3 = Vec3.v3(Vector.get(k * 3, v), Vector.get(k * 3 + 1, v), Vector.get(k * 3 + 2, v))

    def round3(x: Float64): Float64 = Float64.round(x * 1000.0) / 1000.0

    def rounded(v: Vec3.Vec3): (Float64, Float64, Float64) = (round3(v#x), round3(v#y), round3(v#z))

    /// 三角形 t の外向きの法線（cross(b − a, c − a)）・∂p/∂u・∂p/∂v。
    def triangleFrame(m: Mesh3d.Mesh3d, t: Int32): (Vec3.Vec3, Vec3.Vec3, Vec3.Vec3) =
        let ps = Mesh3d.positions(m);
        let uvs = Option.getWithDefault(Vector.empty(), Mesh3d.uvs(m));
        let idx = Mesh3d.indices(m);
        let (i0, i1, i2) = (Vector.get(t * 3, idx), Vector.get(t * 3 + 1, idx), Vector.get(t * 3 + 2, idx));
        let e1 = Vec3.sub(at3(ps, i1), at3(ps, i0));
        let e2 = Vec3.sub(at3(ps, i2), at3(ps, i0));
        let uv = (k: Int32) -> (Vector.get(k * 2, uvs), Vector.get(k * 2 + 1, uvs));
        let (u0, v0) = uv(i0);
        let (u1, v1) = uv(i1);
        let (u2, v2) = uv(i2);
        let (du1, dv1, du2, dv2) = (u1 - u0, v1 - v0, u2 - u0, v2 - v0);
        let det = du1 * dv2 - du2 * dv1;
        (Vec3.cross(e1, e2), Vec3.mul(Vec3.sub(Vec3.mul(e1, dv2), Vec3.mul(e2, dv1)), 1.0 / det),
         Vec3.mul(Vec3.sub(Vec3.mul(e2, du1), Vec3.mul(e1, du2)), 1.0 / det))

    // ── withUvs・withTangents ───────────────────────────────

    /// uv の数が頂点の数 × 2 でなければ Err。
    @Test
    def testWithUvsRejectsWrongCount(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(Mesh3d.withUvs(Vector#{ 0.0, 0.0 }, plate())))

    /// NaN の uv は Err。
    @Test
    def testWithUvsRejectsNan(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(Mesh3d.withUvs(Vector#{ 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0, Float64.nan() }, plate())))

    /// 板のタンジェントは u が増える +X で、cross(法線, タンジェント) × w が絵の上（+Y）を向く。
    @Test
    def testPlateTangentPointsAlongUAndBitangentUp(): Unit \ Assert =
        let m = texturedPlate();
        let t = Option.getWithDefault(Vector.empty(), Mesh3d.tangents(m));
        let tangent = Vec3.v3(Vector.get(0, t), Vector.get(1, t), Vector.get(2, t));
        let up = Vec3.mul(Vec3.cross(at3(Mesh3d.normals(m), 0), tangent), Vector.get(3, t));
        Assert.assertEq(expected = ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0)), (rounded(tangent), rounded(up)))

    /// uv の無い形にタンジェントは付けられない。
    @Test
    def testWithTangentsNeedsUvs(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(Mesh3d.withTangents(Vector#{ 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0 }, plate())))

    /// w が ±1 でないタンジェントは Err。
    @Test
    def testWithTangentsRejectsBadW(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(Mesh3d.withTangents(Vector#{ 1.0, 0.0, 0.0, 0.5, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0 },
                                                           texturedPlate())))

    /// 外のタンジェントは xyz を長さ 1 にそろえて持つ。
    @Test
    def testWithTangentsNormalizesXyz(): Unit \ Assert =
        let given = Vector#{ 0.0, 2.0, 0.0, -1.0, 0.0, 2.0, 0.0, -1.0, 0.0, 2.0, 0.0, -1.0, 0.0, 2.0, 0.0, -1.0 };
        let got = Mesh3d.withTangents(given, texturedPlate()) |> Result.toOption |> Option.flatMap(Mesh3d.tangents)
            |> Option.map(Vector.take(4));
        Assert.assertEq(expected = Some(Vector#{ 0.0, 1.0, 0.0, -1.0 }), got)

    /// uv つきの多角形は points と uvs の数が違えば Err。
    @Test
    def testFromTexturedPolygonsRejectsCountMismatch(): Unit \ Assert =
        let poly = { points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(0.0, 1.0, 0.0) :: Vec3.v3(1.0, 0.0, 0.0) :: Nil,
                     uvs = { x = 0.0, y = 0.0 } :: Nil, color = Color.rgb(1.0, 1.0, 1.0) };
        Assert.assertTrue(Result.isErr(Mesh3d.fromTexturedPolygons(poly :: Nil)))

    /// uv つきの多角形は頂点の並びのまま uv を持つ。
    @Test
    def testFromTexturedPolygonsKeepsUvOrder(): Unit \ Assert =
        let poly = { points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(0.0, 1.0, 0.0) :: Vec3.v3(1.0, 0.0, 0.0) :: Nil,
                     uvs = { x = 0.0, y = 1.0 } :: { x = 0.0, y = 0.0 } :: { x = 1.0, y = 1.0 } :: Nil, color = Color.rgb(1.0, 1.0, 1.0) };
        Assert.assertEq(expected = Some(Vector#{ 0.0, 1.0, 0.0, 0.0, 1.0, 1.0 }),
            Mesh3d.fromTexturedPolygons(poly :: Nil) |> Result.toOption |> Option.flatMap(Mesh3d.uvs))

    // ── 鍵 ────────────────────────────────────────────────

    /// uv の無い形の鍵は前と同じ字（位置・色・番号を | でつないだ字の SHA-256）。
    @Test
    def testHashWithoutUvIsUnchanged(): Unit \ Assert =
        let tri = Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(0.0, 1.0, 0.0) :: Vec3.v3(1.0, 0.0, 0.0) :: Nil,
                                        color = Color.rgb(1.0, 1.0, 1.0) } :: Nil);
        Assert.assertEq(expected = "553f4f4453f20c96f3b5077c15f4317ba9e69654eadc3a6f07cf57fac71272cd", Mesh3d.contentHash(tri))

    /// uv を付けると鍵が変わり、uv が違えば鍵も違う。
    @Test
    def testHashChangesWithUvs(): Unit \ Assert =
        let flipped = Mesh3d.withUvs(Vector#{ 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0 }, plate()) |> Result.toOption |> Option.map(Mesh3d.contentHash);
        let plain = Mesh3d.contentHash(plate());
        let textured = Mesh3d.contentHash(texturedPlate());
        Assert.assertEq(expected = (true, true), (plain != textured, Some(textured) != flipped))

    // ── withBoxUvs ─────────────────────────────────────────

    /// 立方体の 12 枚の三角形はどれも cross(∂p/∂u, ∂p/∂v) が外を向く（6 面とも外から見て鏡写しにならない）。
    @Test
    def testBoxUvsAreNotMirroredOnAnyFace(): Unit \ Assert =
        let m = Mesh3d.withBoxUvs(1.0, cube());
        let outward = List.range(0, Mesh3d.triangleCount(m)) |> List.count(t -> {
            let (n, dpdu, dpdv) = triangleFrame(m, t);
            Vec3.dot(Vec3.cross(dpdu, dpdv), n) > 0.0
        });
        Assert.assertEq(expected = 12, outward)

    /// 上を向く面（+Y）は北（+Z）が絵の上（v が減る向き）。
    @Test
    def testBoxUvsTopFaceHasNorthUp(): Unit \ Assert =
        let m = Mesh3d.withBoxUvs(1.0, cube());
        let (_, _, dpdv) = triangleFrame(m, 4);
        Assert.assertEq(expected = (0.0, 0.0, -1.0), rounded(dpdv))

    /// uv は形の座標 × scale（+X の面の頂点 (1, −1, −1) は (z, −y) × 0.5 = (−0.5, 0.5)）。
    @Test
    def testBoxUvsScaleShapeCoordinates(): Unit \ Assert =
        let m = Mesh3d.withBoxUvs(0.5, cube());
        Assert.assertEq(expected = Some(Vector#{ -0.5, 0.5 }), Mesh3d.uvs(m) |> Option.map(Vector.take(2)))

    /// 面ごとに頂点を分けてある形（fromPolygons）は頂点の数が変わらない。
    @Test
    def testBoxUvsKeepsSeparateFaceVertices(): Unit \ Assert =
        Assert.assertEq(expected = 24, Mesh3d.vertexCount(Mesh3d.withBoxUvs(1.0, cube())))

    /// 軸の違う面（+Y と +X）が共有する 2 頂点は面ごとに分かれる（4 頂点 → 6 頂点）。
    @Test
    def testBoxUvsSplitsVerticesSharedAcrossFaces(): Unit \ Assert =
        let shared = Mesh3d.fromArrays({
            positions = Vector#{ 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0 },
            normals = Vector#{ 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0 },
            colors = Vector#{ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 },
            indices = Vector#{ 0, 1, 2, 0, 3, 1 }, skin = None });
        Assert.assertEq(expected = Ok((4, 6)), Result.map(m -> (Mesh3d.vertexCount(m), Mesh3d.vertexCount(Mesh3d.withBoxUvs(1.0, m))), shared))

    // ── OBJ の vt ───────────────────────────────────────────

    /// 全部の面に vt があれば uv つきで、v は 1 − v（OBJ は絵の左下が 0）。
    @Test
    def testObjVtFlipsV(): Unit \ Assert =
        let obj = "v 0 0 0\nv 0 1 0\nv 1 0 0\nvt 0 0\nvt 0 1\nvt 1 0.25\nf 1/1 2/2 3/3\n";
        Assert.assertEq(expected = Ok(Some(Vector#{ 0.0, 1.0, 0.0, 0.0, 1.0, 0.75 })), Mesh3d.fromObj(obj, "") |> Result.map(Mesh3d.uvs))

    /// v/vt/vn の形でも 2 番目の番号を uv に使う。
    @Test
    def testObjVtWithNormalIndex(): Unit \ Assert =
        let obj = "v 0 0 0\nv 0 1 0\nv 1 0 0\nvt 0.5 0.5\nvn 0 0 1\nf 1/1/1 2/1/1 3/1/1\n";
        Assert.assertEq(expected = Ok(Some(Vector#{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 })), Mesh3d.fromObj(obj, "") |> Result.map(Mesh3d.uvs))

    /// 1 つの面でも vt が欠ければ uv なし。
    @Test
    def testObjMissingVtMeansNoUv(): Unit \ Assert =
        let obj = "v 0 0 0\nv 0 1 0\nv 1 0 0\nv 1 1 0\nvt 0 0\nf 1/1 2/1 3/1\nf 2 4 3\n";
        Assert.assertEq(expected = Ok(None), Mesh3d.fromObj(obj, "") |> Result.map(Mesh3d.uvs))
}
