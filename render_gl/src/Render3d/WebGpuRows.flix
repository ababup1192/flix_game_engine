// Render3d.WebGpuRows — 3D の場面の不透明の行（Render3d.SceneList）を WebGPU で流す所（WebGPU の backend。GL の Render3d.GlRows と対）と、形の buffer の置き場。
// 1 つの場面は uploadRows（形を上げる）→ drawRows（行を描く）の順に通る。行の欄の意味は Render3d.SceneList の頭。
// 形の番号と上限は前半の表（Render3d.MeshTable）が持ち、ここは番号 → buffer の置き場と、作る・捨てる関数の組（meshAllocator）だけを持つ。
// 描くのは頂点の色の行だけ。骨つきの行と材質の行は形を上げずに飛ばす（知らせるのは Render3d.WebGpuRenderer）。
mod Render3d.WebGpuRows {
    import fge.webgpu.Buffer
    import fge.webgpu.BufferUsage
    import fge.webgpu.IndexFormat
    import fge.webgpu.RenderPass
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    use Render3d.{interleave}
    use Render3d.MeshTable
    use Render3d.SceneList.{SceneList, headAt, kindVertexColor, meshAt, rowAt, rowCountOf}

    /// GPU に置いた形 1 つ。vertices = 位置・法線・色の 9 float を交互に並べた buffer（36 バイトずつ・GL の Render3d.uploadMesh の vbo と同じ並び）・
    /// indices = 添え字（u32）。
    pub type alias MeshBuffers = { vertices = Buffer, indices = Buffer, indexCount = Int32, vertexCount = Int32 }

    /// 形の表の番号 → GPU に置いた形。
    pub type alias MeshStore = Ref[Map[Int32, MeshBuffers], Static]

    pub def freshStore(): MeshStore \ IO = Ref.fresh(Static, Map.empty())

    /// 形の表（Render3d.MeshTable）へ渡す、WebGPU の形を作る・捨てる関数の組。
    pub def meshAllocator(gpu: WebGpu, store: MeshStore): MeshTable.MeshAllocator =
        { create = (handle, mesh) -> {
              let made = uploadMesh(gpu, mesh);
              Ref.put(Map.insert(handle, made, Ref.get(store)), store);
              made#vertexCount
          },
          destroy = handle -> {
              Map.get(handle, Ref.get(store)) |> Option.forEach(destroyMesh);
              Ref.put(Map.remove(handle, Ref.get(store)), store)
          } }

    /// 形を GPU へ上げる。
    // WhyNot: 添え字を 1 つずつ詰めない — Flix の Vector は JVM の int[] のままで、1 回で写せる（WebGpuPaint.argbBytes と同じ）。
    def uploadMesh(gpu: WebGpu, mesh: Mesh3d.Mesh3d): MeshBuffers \ IO =
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
        { vertices = vertexBuffer, indices = indexBuffer, indexCount = indexCount, vertexCount = n }

    def destroyMesh(e: MeshBuffers): Unit \ IO =
        e#vertices.destroy();
        e#indices.destroy()

    /// 頂点の色の行の形を作る（無ければ）。間引いた物だけの行の形も今のコマで使った物として数える（番号を振った時に lastUsed は進んでいる）。
    /// 描き始める前に呼ぶ。
    // WhyNot: 描く途中で上げない — render pass の中では buffer を作れない（GL の Render3d.GlRows.uploadRows と同じ並び）。
    pub def uploadRows(gpu: WebGpu, table: MeshTable.Table, store: MeshStore, gen: Int64, list: SceneList): Unit \ IO =
        uploadRowsFrom({ table = table, allocator = meshAllocator(gpu, store), gen = gen }, list, 0, rowCountOf(list))

    /// uploadRows の 1 回で行をまたいで変わらない物。
    type alias Uploads = { table = MeshTable.Table, allocator = MeshTable.MeshAllocator, gen = Int64 }

    def uploadRowsFrom(up: Uploads, list: SceneList, row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            uploadRow(up, list, row);
            uploadRowsFrom(up, list, row + 1, n)
        }

    def uploadRow(up: Uploads, list: SceneList, row: Int32): Unit \ IO =
        if (rowAt(list, row, 0) == kindVertexColor()) discard MeshTable.ensure(up#table, up#allocator, up#gen, headAt(list, row)#fields#mesh) else ();
        // WhyNot: 末尾を呼び出しで終えない — 行が物の数だけある場面で uploadRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
        ()

    /// 行を順に描く。pipeline・group 0・頂点の buffer の 1 番（1 体ごとの値）は呼ぶ側が積んでおく。形は行の形の番号で store から引く・
    /// instanceBase = この場面の 1 体ごとの値を送った位置（体の番号）。描く物の無い行と、頂点の色でない行は飛ばす。
    pub def drawRows(pass: RenderPass, store: MeshStore, list: SceneList, instanceBase: Int32): Unit \ IO =
        drawRowsFrom(pass, Ref.get(store), list, instanceBase, 0, rowCountOf(list))

    def drawRowsFrom(pass: RenderPass, meshes: Map[Int32, MeshBuffers], list: SceneList, instanceBase: Int32, row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            drawRow(pass, meshes, list, instanceBase, row);
            drawRowsFrom(pass, meshes, list, instanceBase, row + 1, n)
        }

    def drawRow(pass: RenderPass, meshes: Map[Int32, MeshBuffers], list: SceneList, instanceBase: Int32, row: Int32): Unit \ IO =
        let count = rowAt(list, row, 4);
        if (count <= 0 or rowAt(list, row, 0) != kindVertexColor()) ()
        else Map.get(meshAt(list, row), meshes) |> Option.forEach(mesh -> {
            if (mesh#indexCount <= 0) ()
            else {
                pass.setVertexBuffer(0, mesh#vertices, 0i64, mesh#vertices.size());
                pass.setIndexBuffer(mesh#indices, IndexFormat.UINT32, 0i64, mesh#indices.size());
                pass.drawIndexed(mesh#indexCount, count, 0, 0, instanceBase + rowAt(list, row, 3))
            }
        });
        // WhyNot: 末尾を呼び出しで終えない — 行が物の数だけある場面で drawRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
        ()
}
