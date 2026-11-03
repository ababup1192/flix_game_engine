// glTF のノードの一覧（Model3d.nodes）: 名前・親・局所と world の行列（X の反転の後）・局所の境界・parts の番号・
// mesh の無いノード・mesh の無い glb・名前で引く口（findNode・nodesByName・nodesWithPrefix・partsOfNode・nodeOrigin・partLocalToNode）。
mod TestGltf.Nodes {

    /// 4 つのノードの .glb:
    ///   0 "parent" = translation (1, 0, 0)・Y まわり 90°（glTF の +Z が +X へ回る）・children [1]
    ///   1 "child"  = translation (0, 0, 2)・mesh 0（三角 1 枚。glTF の座標で (1, 0, 0)・(3, 0, 0)・(1, 2, 0)。accessor に min / max なし）
    ///   2 "COL_box" = translation (0, 3, 0)（mesh なし）
    ///   3 "child"  = translation (5, 0, 0)（mesh なし・名前が 1 と同じ）
    def treeGlb(): Vector[Int8] =
        let half = "0.7071067811865476";
        let json = "{\"asset\":{\"version\":\"2.0\"},\"nodes\":[" +
            "{\"name\":\"parent\",\"translation\":[1,0,0],\"rotation\":[0,${half},0,${half}],\"children\":[1]}," +
            "{\"name\":\"child\",\"translation\":[0,0,2],\"mesh\":0}," +
            "{\"name\":\"COL_box\",\"translation\":[0,3,0]}," +
            "{\"name\":\"child\",\"translation\":[5,0,0]}]," +
            "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1}}]}]," +
            "\"accessors\":[{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
            "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}]," +
            "\"bufferViews\":[{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36}]," +
            "\"buffers\":[{\"byteLength\":72}]}";
        TestGltf.glb(json, List.append(TestGltf.f32s(1.0 :: 0.0 :: 0.0 :: 3.0 :: 0.0 :: 0.0 :: 1.0 :: 2.0 :: 0.0 :: Nil),
                                       TestGltf.f32s(0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: Nil)))

    /// mesh の無いノード 1 つだけの .glb（バッファも無い）。"tip" = translation (0.5, 1, 0)。
    def markerOnlyGlb(): Vector[Int8] =
        TestGltf.glb("{\"asset\":{\"version\":\"2.0\"},\"nodes\":[{\"name\":\"tip\",\"translation\":[0.5,1,0]}]}", Nil)

    def tree(): Model3d.Model3d = TestGltf.okOrBug(Gltf.fromGlb(treeGlb()))

    def nodeAt(k: Int32, m: Model3d.Model3d): Model3d.ModelNode = match List.nth(k, m#nodes) {
        case Some(n) => n
        case None    => bug!("nodes[${k}] が無い")
    }

    /// 小数 3 桁で丸めた (x, y, z)。
    def rounded(v: Vec3.Vec3): (Float64, Float64, Float64) =
        let r = (x: Float64) -> Float64.round(x * 1000.0) / 1000.0 + 0.0;
        (r(v#x), r(v#y), r(v#z))

    // ════════════════════════════════════════════════════════════════════
    // 名前・親・行列
    // ════════════════════════════════════════════════════════════════════

    /// 全部のノード（mesh の無いノードも）が glTF の並びで入り、名前と親が glTF のまま。
    @Test
    def testNodesKeepNamesAndParents(): Unit \ Assert =
        Assert.assertEq(expected = ("parent", None) :: ("child", Some(0)) :: ("COL_box", None) :: ("child", None) :: Nil,
            tree()#nodes |> List.map(n -> (n#name, n#parent)))

    /// 子の world は親の回転が掛かる: glTF で (1, 0, 0) + Y 90° × (0, 0, 2) = (3, 0, 0)。engine では X が反転して (−3, 0, 0)。
    @Test
    def testChildWorldHasParentRotationAndMirror(): Unit \ Assert =
        Assert.assertEq(expected = (-3.0, 0.0, 0.0), rounded(Model3d.nodeOrigin(nodeAt(1, tree()))))

    /// local は親から見た行列（子の local の原点は glTF の (0, 0, 2) のまま。z は反転しない）。
    @Test
    def testLocalIsRelativeToParent(): Unit \ Assert =
        Assert.assertEq(expected = (0.0, 0.0, 2.0), rounded(Mat4.apply(nodeAt(1, tree())#local, Vec3.zero())))

    /// 子の world の X 軸（glTF の +X を Y 90° で回すと −Z）は、engine でも −Z（S·M·S の写しは z を反転しない）。
    @Test
    def testWorldRotationIsMirrored(): Unit \ Assert =
        let child = nodeAt(1, tree());
        Assert.assertEq(expected = (0.0, 0.0, -1.0), rounded(Vec3.sub(Mat4.apply(child#world, Vec3.v3(-1.0, 0.0, 0.0)), Model3d.nodeOrigin(child))))

    // ════════════════════════════════════════════════════════════════════
    // 局所の境界と parts
    // ════════════════════════════════════════════════════════════════════

    /// localBounds は焼き込む前の形の座標で、X の反転の後に min ≦ max: glTF の x 1..3 → engine の −3..−1。
    @Test
    def testLocalBoundsAreMirroredAndOrdered(): Unit \ Assert =
        Assert.assertEq(expected = Some(((-3.0, 0.0, 0.0), (-1.0, 2.0, 0.0))),
            nodeAt(1, tree())#localBounds |> Option.map(b -> (rounded(b#min), rounded(b#max))))

    /// mesh の無いノードは localBounds も parts も無い。
    @Test
    def testEmptyNodeHasNoBoundsNorParts(): Unit \ Assert =
        let marker = nodeAt(2, tree());
        Assert.assertEq(expected = (None, Nil), (marker#localBounds |> Option.map(b -> rounded(b#min)), marker#parts))

    /// mesh のノードの parts は、そのノードから出た part の番号。part の node はノードの番号。
    @Test
    def testNodePartsPointBothWays(): Unit \ Assert =
        let m = tree();
        Assert.assertEq(expected = (0 :: Nil, Some(1) :: Nil), (nodeAt(1, m)#parts, m#parts |> List.map(p -> p#node)))

    /// partLocalToNode は焼き込んだ頂点を局所へ戻す: 頂点 0 は glTF の局所 (1, 0, 0) = engine の (−1, 0, 0)。
    @Test
    def testPartLocalToNodeUndoesTheBake(): Unit \ Assert =
        let m = tree();
        let baked = m#parts |> List.head |> Option.map(p -> TestGltf.positionOf(p#mesh, 0)) |> Option.getWithDefault(Vec3.zero());
        Assert.assertEq(expected = Some((-1.0, 0.0, 0.0)), Model3d.partLocalToNode(nodeAt(1, m), m) |> Option.map(inv -> rounded(Mat4.apply(inv, baked))))

    /// skin のある glb の part は、ノードの world と焼いた行列が違いうるので None。
    @Test
    def testPartLocalToNodeIsNoneWithSkin(): Unit \ {Assert, IO} =
        let (skinned, _) = TestGltf.loadSkinned();
        Assert.assertEq(expected = None, Model3d.partLocalToNode(nodeAt(2, skinned), skinned) |> Option.map(_ -> ()))

    // ════════════════════════════════════════════════════════════════════
    // 名前で引く
    // ════════════════════════════════════════════════════════════════════

    /// 同じ名前が 2 つあれば並びの前（mesh のある 1 番）。findNode と nodesByName は同じ答え。
    @Test
    def testSameNameFindsTheFirstInBothWays(): Unit \ Assert =
        let m = tree();
        let viaFind = Model3d.findNode("child", m) |> Option.map(n -> n#parts);
        let viaMap = Map.get("child", Model3d.nodesByName(m)) |> Option.map(n -> n#parts);
        Assert.assertEq(expected = (Some(0 :: Nil), Some(0 :: Nil)), (viaFind, viaMap))

    /// nodesWithPrefix は名前の頭で集める。
    @Test
    def testNodesWithPrefixCollectsByHead(): Unit \ Assert =
        Assert.assertEq(expected = "COL_box" :: Nil, Model3d.nodesWithPrefix("COL_", tree()) |> List.map(n -> n#name))

    /// partsOfNode と partsByNode は同じノードの part を返す（頂点 3 つの三角 1 枚）。mesh の無いノードは partsByNode に無い。
    @Test
    def testPartsOfNodeAndPartsByNodeAgree(): Unit \ Assert =
        let m = tree();
        let count = (ps: List[Model3d.ModelPart]) -> List.map(p -> Mesh3d.vertexCount(p#mesh), ps);
        Assert.assertEq(expected = (3 :: Nil, Some(3 :: Nil), None),
            (count(Model3d.partsOfNode(nodeAt(1, m), m)), Map.get(1, Model3d.partsByNode(m)) |> Option.map(count),
             Map.get(2, Model3d.partsByNode(m)) |> Option.map(count)))

    /// 部品の形の焼き込みはノードの一覧を足す前と同じ: 骨つきの two_joints.glb の部品の contentHash はノードの一覧を足す前のコードで取った字のまま。
    @Test
    def testSkinnedPartHashIsPinned(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = "aefde75a5ab7292b284f15fb1a10cb8e011056adc6aebf2cc06202f5394aab40" :: Nil,
            TestGltf.twoJoints()#parts |> List.map(p -> Mesh3d.contentHash(p#mesh)))

    // ════════════════════════════════════════════════════════════════════
    // mesh の無い glb
    // ════════════════════════════════════════════════════════════════════

    /// 印の点だけの glb も読め、形は頂点 0・parts は空・印の点の原点は X が反転する。
    @Test
    def testMarkerOnlyGlbReadsNodes(): Unit \ Assert =
        Assert.assertEq(expected = Ok((0, 0, Some((-0.5, 1.0, 0.0)))),
            Gltf.fromGlb(markerOnlyGlb()) |> Result.map(m ->
                (Mesh3d.vertexCount(m#mesh), List.length(m#parts), Model3d.findNode("tip", m) |> Option.map(n -> rounded(Model3d.nodeOrigin(n))))))
}
