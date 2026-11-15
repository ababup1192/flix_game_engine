// Render3d.WebGpuRows — 3D の場面の不透明の行（Render3d.SceneList）を WebGPU で流す所（WebGPU の backend。GL の Render3d.GlRows と対）と、形の buffer の置き場。
// 1 つの場面は uploadRows（形を上げる）→ drawRows（行を描く）の順に通る。行の欄の意味は Render3d.SceneList の頭。
// 描くのは頂点の色の行だけ。骨つきの行と材質の行は形を上げずに飛ばす（知らせるのは Render3d.WebGpuRenderer）。
mod Render3d.WebGpuRows {
    import fge.webgpu.Buffer
    import fge.webgpu.BufferUsage
    import fge.webgpu.IndexFormat
    import fge.webgpu.RenderPass
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    use Render3d.{interleave, meshEvictions, vertexBudget}
    use Render3d.SceneList.{SceneList, headAt, kindVertexColor, rowAt, rowCountOf}

    /// GPU に置いた形 1 つ。vertices = 位置・法線・色の 9 float を交互に並べた buffer（36 バイトずつ・GL の Render3d.uploadMesh の vbo と同じ並び）・
    /// indices = 添え字（u32）・lastUsed = 最後に描いたコマの世代（要素 1 つ）。
    pub type alias MeshBuffers = { vertices = Buffer, indices = Buffer, indexCount = Int32, vertexCount = Int32, lastUsed = Array[Int64, Static] }

    /// 形の置き場（Mesh3d.contentHash → 形）と、置き場の頂点の合計（要素 1 つ）。
    pub type alias MeshTable = { meshes = Ref[Map[String, MeshBuffers], Static], vertexTotal = Array[Int32, Static] }

    pub def freshMeshes(): MeshTable \ IO = { meshes = Ref.fresh(Static, Map.empty()), vertexTotal = Array#{0} @ Static }

    /// 形 mesh の buffer（無ければ上げる）。どちらでも lastUsed を gen にする。
    pub def meshBuffersOf(gpu: WebGpu, table: MeshTable, gen: Int64, mesh: Mesh3d.Mesh3d): MeshBuffers \ IO =
        let key = Mesh3d.contentHash(mesh);
        match Map.get(key, Ref.get(table#meshes)) {
            case Some(found) =>
                Array.put(gen, 0, found#lastUsed);
                found
            case None =>
                let made = uploadMesh(gpu, gen, mesh);
                Array.put(Array.get(0, table#vertexTotal) + made#vertexCount, 0, table#vertexTotal);
                Ref.put(Map.insert(key, made, Ref.get(table#meshes)), table#meshes);
                made
        }

    /// 形を GPU へ上げる。
    // WhyNot: 添え字を 1 つずつ詰めない — Flix の Vector は JVM の int[] のままで、1 回で写せる（WebGpuPaint.argbBytes と同じ）。
    def uploadMesh(gpu: WebGpu, gen: Int64, mesh: Mesh3d.Mesh3d): MeshBuffers \ IO =
        let n = Mesh3d.vertexCount(mesh);
        let vertices = interleave(mesh, n);
        let indices = Mesh3d.indices(mesh);
        let indexCount = Vector.length(indices);
        let vertexBytes = 4 * Array.length(vertices);
        let vertexData = ByteBuffer.allocateDirect(vertexBytes).order(ByteOrder.LITTLE_ENDIAN);
        discard vertexData.asFloatBuffer().put(vertices);
        let indexBytes = 4 * Int32.max(1, indexCount);
        let indexData = ByteBuffer.allocateDirect(indexBytes).order(ByteOrder.LITTLE_ENDIAN);
        discard indexData.asIntBuffer().put(unchecked_cast(indices as Array[Int32, Static]));
        let vertexBuffer = gpu.createBuffer("fge mesh3d vertices", Int32.toInt64(vertexBytes), Int32.bitwiseOr(BufferUsage.VERTEX, BufferUsage.COPY_DST));
        gpu.writeBuffer(vertexBuffer, 0i64, vertexData, 0, vertexBytes);
        let indexBuffer = gpu.createBuffer("fge mesh3d indices", Int32.toInt64(indexBytes), Int32.bitwiseOr(BufferUsage.INDEX, BufferUsage.COPY_DST));
        gpu.writeBuffer(indexBuffer, 0i64, indexData, 0, indexBytes);
        { vertices = vertexBuffer, indices = indexBuffer, indexCount = indexCount, vertexCount = n, lastUsed = Array#{gen} @ Static }

    /// 頂点の合計が GL と同じ上限（Render3d.vertexBudget）を超えていたら、GL と同じ順（Render3d.meshEvictions）で形を捨てる。submit の後に呼ぶ。
    /// 捨てた数を返す。
    pub def trimMeshes(table: MeshTable, gen: Int64): Int32 \ IO =
        if (Array.get(0, table#vertexTotal) <= vertexBudget()) 0
        else {
            let meshes = Ref.get(table#meshes);
            let victims = meshEvictions(vertexBudget(), gen, Set.empty(),
                                        Map.toList(meshes) |> List.map(ke -> (fst(ke), snd(ke)#vertexCount, Array.get(0, snd(ke)#lastUsed))));
            let dropped = victims |> List.filterMap(key -> Map.get(key, meshes) |> Option.map(e -> (key, e))) |> List.toMap;
            Map.forEach((_, e) -> destroyMesh(e), dropped);
            Array.put(Array.get(0, table#vertexTotal) - Map.foldLeft((acc, e) -> acc + e#vertexCount, 0, dropped), 0, table#vertexTotal);
            Ref.put(Map.difference(meshes, dropped), table#meshes);
            Map.size(dropped)
        }

    def destroyMesh(e: MeshBuffers): Unit \ IO =
        e#vertices.destroy();
        e#indices.destroy()

    /// 置き場の形を全部捨てる。
    pub def releaseMeshes(table: MeshTable): Unit \ IO =
        Map.forEach((_, e) -> destroyMesh(e), Ref.get(table#meshes));
        Ref.put(Map.empty(), table#meshes);
        Array.put(0, 0, table#vertexTotal)

    /// 頂点の色の行の形を置き場へ上げ（無ければ）、行ごとの形を返す（ほかの種類の行は None）。間引いた物だけの行の形も今のコマで使った物として数える。
    /// 描き始める前に呼ぶ。
    // WhyNot: 描く途中で上げない — render pass の中では buffer を作れない（GL の Render3d.GlRows.uploadRows と同じ並び）。
    // WhyNot: 間引いた物だけの行の形を置き場で古いままにしない — 振り向くたびに形を上げ直す（GL と同じ）。
    pub def uploadRows(gpu: WebGpu, table: MeshTable, gen: Int64, list: SceneList): Array[Option[MeshBuffers], Static] \ IO =
        let n = rowCountOf(list);
        let meshes = Array.repeat(Static, n, None);
        uploadRowsFrom(gpu, table, gen, list, meshes, 0, n);
        meshes

    def uploadRowsFrom(gpu: WebGpu, table: MeshTable, gen: Int64, list: SceneList, meshes: Array[Option[MeshBuffers], Static], row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            uploadRow(gpu, table, gen, list, meshes, row);
            uploadRowsFrom(gpu, table, gen, list, meshes, row + 1, n)
        }

    def uploadRow(gpu: WebGpu, table: MeshTable, gen: Int64, list: SceneList, meshes: Array[Option[MeshBuffers], Static], row: Int32): Unit \ IO =
        if (rowAt(list, row, 0) == kindVertexColor()) Array.put(Some(meshBuffersOf(gpu, table, gen, headAt(list, row)#fields#mesh)), row, meshes) else ();
        // WhyNot: 末尾を呼び出しで終えない — 行が物の数だけある場面で uploadRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
        ()

    /// 行を順に描く。pipeline・group 0・頂点の buffer の 1 番（1 体ごとの値）は呼ぶ側が積んでおく。meshes = uploadRows の答え・
    /// instanceBase = この場面の 1 体ごとの値を送った位置（体の番号）。描く物の無い行と形の無い行は飛ばす。
    pub def drawRows(pass: RenderPass, list: SceneList, meshes: Array[Option[MeshBuffers], Static], instanceBase: Int32): Unit \ IO =
        drawRowsFrom(pass, list, meshes, instanceBase, 0, rowCountOf(list))

    def drawRowsFrom(pass: RenderPass, list: SceneList, meshes: Array[Option[MeshBuffers], Static], instanceBase: Int32, row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            drawRow(pass, list, meshes, instanceBase, row);
            drawRowsFrom(pass, list, meshes, instanceBase, row + 1, n)
        }

    def drawRow(pass: RenderPass, list: SceneList, meshes: Array[Option[MeshBuffers], Static], instanceBase: Int32, row: Int32): Unit \ IO =
        let count = rowAt(list, row, 4);
        Array.get(row, meshes) |> Option.forEach(mesh -> {
            if (count <= 0 or mesh#indexCount <= 0) ()
            else {
                pass.setVertexBuffer(0, mesh#vertices, 0i64, mesh#vertices.size());
                pass.setIndexBuffer(mesh#indices, IndexFormat.UINT32, 0i64, mesh#indices.size());
                pass.drawIndexed(mesh#indexCount, count, 0, 0, instanceBase + rowAt(list, row, 3))
            }
        });
        // WhyNot: 末尾を呼び出しで終えない — 行が物の数だけある場面で drawRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
        ()
}
