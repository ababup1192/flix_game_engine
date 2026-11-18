// Render3d.WebGpuRows — 3D の場面の行（Render3d.SceneList）を WebGPU で流す所（WebGPU の backend。GL の Render3d.GlRows と対）と、形の buffer の置き場。
// 1 つの場面は uploadRows（形を上げる）→ drawRows（行を描く）の順に通る。行の欄の意味は Render3d.SceneList の頭。
// 形の番号と上限は前半の表（Render3d.MeshTable）が持ち、ここは番号 → buffer の置き場と、作る・捨てる関数の組（meshAllocator）だけを持つ。
// 形の頂点は版ごとに 1 本の buffer へ交互に並べる: 位置・法線・色（9 float）の後に、uv つきの形は uv（2）とタンジェント（4）、2 本目の uv つきの形は 2 本目の uv（2）、
// ジョイントの重みつきの形はジョイントの番号（4・float）と重み（4）。
// 描くのは頂点の色の行・骨つきの行・材質の行（pipeline と group は RowDrawer が付ける）と、ビルボードの行（形を持たず、RowDrawer が描く）。
// WhyNot: uv・タンジェント・2 本目の uv を別の buffer にしない — 頂点の buffer は 8 本が上限で、骨と instance を storage へ移した後も版ごとに 1 本で足りる形にする（P8 の WGSL の決まり）。
mod Render3d.WebGpuRows {
    import fge.webgpu.Buffer
    import fge.webgpu.BufferUsage
    import fge.webgpu.IndexFormat
    import fge.webgpu.RenderCommands
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    use Render3d.MeshTable
    use Render3d.SceneList.{SceneList, SceneRowKind, breakSlotAt, countAt, firstInstanceAt, headAt, kindAt, meshAt, rowCountOf, valuesAt}

    /// GPU に置いた形 1 つ。vertices = 頂点を交互に並べた buffer（並びはこのファイルの頭）・stride = 頂点 1 つのバイト数・
    /// hasUv = uv とタンジェントを持つ（36 バイト目から）・uv2At = 2 本目の uv の位置（バイト・2 本目の uv つきの形だけ）・
    /// skinAt = ジョイントの番号と重みの位置（バイト・重みつきの形だけ）・indices = 添え字（u32）。
    pub type alias MeshBuffers = { vertices = Buffer, indices = Buffer, indexCount = Int32, vertexCount = Int32, stride = Int32, hasUv = Bool,
                                   uv2At = Option[Int32], skinAt = Option[Int32] }

    /// 形の表の番号 → GPU に置いた形。
    pub type alias MeshStore = Ref[Map[Int32, MeshBuffers], Static]

    /// 行を描く時に pipeline と group を付ける関数の組。shape(pass, 形) = 頂点の色の pipeline・skinned(pass, 形) = 骨つきの頂点の色の pipeline と group 1（空）・
    /// material(pass, 行, 行の番号, 形) = 材質の pipeline と group 1。どれも描けない時は偽（その行を飛ばす）。姿勢の group 2 は呼ぶ側が pass の頭で付ける。
    /// billboard(pass, 行, 行の番号) = ビルボードの行を描く（描けない時は偽）。unbound(描く物の数) = 付けられずに飛ばした行を知らせる。
    pub type alias RowDrawer = {
        shape = (RenderCommands, MeshBuffers) -> Bool \ IO,
        skinned = (RenderCommands, MeshBuffers) -> Bool \ IO,
        material = (RenderCommands, SceneList, Int32, MeshBuffers) -> Bool \ IO,
        billboard = (RenderCommands, SceneList, Int32) -> Bool \ IO,
        unbound = Int32 -> Unit \ IO
    }

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

    /// 形 mesh の頂点 1 つの float の数（並びはこのファイルの頭）。
    pub def floatsPerVertex(mesh: Mesh3d.Mesh3d): Int32 =
        skinFloatAt(mesh) + (if (Option.isEmpty(Mesh3d.skinJoints(mesh))) 0 else 8)

    /// 形 mesh の頂点の中の 2 本目の uv の位置（float）。
    def uv2FloatAt(mesh: Mesh3d.Mesh3d): Int32 = if (Option.isEmpty(Mesh3d.uvs(mesh))) 9 else 15

    /// 形 mesh の頂点の中のジョイントの番号の位置（float。重みはその 4 つ後）。
    def skinFloatAt(mesh: Mesh3d.Mesh3d): Int32 =
        9 + (if (Option.isEmpty(Mesh3d.uvs(mesh))) 0 else 6) + (if (Option.isEmpty(Mesh3d.uvs2(mesh))) 0 else 2)

    /// 形の頂点を版の並びで交互に詰める（タンジェントの無い uv つきの形は 0 のタンジェント）。
    pub def interleaveVersion(mesh: Mesh3d.Mesh3d): Array[Float32, Static] \ IO =
        let n = Mesh3d.vertexCount(mesh);
        let width = floatsPerVertex(mesh);
        let out = Array.repeat(Static, Int32.max(1, n * width), 0.0f32);
        let put = (offset: Int32, per: Int32, values: Vector[Float64]) ->
            values |> Vector.forEachWithIndex((i, v) -> Array.put(RenderUtil.f32(v), (i / per) * width + offset + Int32.remainder(i, per), out));
        put(0, 3, Mesh3d.positions(mesh));
        put(3, 3, Mesh3d.normals(mesh));
        put(6, 3, Mesh3d.colors(mesh));
        Mesh3d.uvs(mesh) |> Option.forEach(uvs -> {
            put(9, 2, uvs);
            Mesh3d.tangents(mesh) |> Option.forEach(put(11, 4))
        });
        Mesh3d.uvs2(mesh) |> Option.forEach(put(uv2FloatAt(mesh), 2));
        let skinAt = skinFloatAt(mesh);
        Mesh3d.skinJoints(mesh) |> Option.forEach(joints ->
            joints |> Vector.forEachWithIndex((i, j) -> Array.put(Int32.toFloat32(j), (i / 4) * width + skinAt + Int32.remainder(i, 4), out)));
        Mesh3d.skinWeights(mesh) |> Option.forEach(put(skinAt + 4, 4));
        out

    /// 形を GPU へ上げる。
    // WhyNot: 添え字を 1 つずつ詰めない — Flix の Vector は JVM の int[] のままで、1 回で写せる（WebGpuPaint.argbBytes と同じ）。
    def uploadMesh(gpu: WebGpu, mesh: Mesh3d.Mesh3d): MeshBuffers \ IO =
        let n = Mesh3d.vertexCount(mesh);
        let vertices = interleaveVersion(mesh);
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
        { vertices = vertexBuffer, indices = indexBuffer, indexCount = indexCount, vertexCount = n, stride = 4 * floatsPerVertex(mesh),
          hasUv = Option.nonEmpty(Mesh3d.uvs(mesh)), uv2At = Mesh3d.uvs2(mesh) |> Option.map(_ -> 4 * uv2FloatAt(mesh)), skinAt = Mesh3d.skinJoints(mesh) |> Option.map(_ -> 4 * skinFloatAt(mesh)) }

    def destroyMesh(e: MeshBuffers): Unit \ IO =
        e#vertices.destroy();
        e#indices.destroy()

    /// 頂点の色の行・骨つきの行・材質の行の形を作る（無ければ）。間引いた物だけの行の形も今のコマで使った物として数える（番号を振った時に lastUsed は進んでいる）。
    /// 描き始める前に呼ぶ。
    // WhyNot: 描く途中で上げない — render pass の中では buffer を作れない（GL の Render3d.GlRows.uploadRows と同じ並び）。
    /// allocator = 形を作る・捨てる関数の組（meshAllocator か、それを包んで数える物）。
    pub def uploadRows(table: MeshTable.Table, allocator: MeshTable.MeshAllocator, gen: Int64, list: SceneList): Unit \ IO =
        uploadRowsFrom({ table = table, allocator = allocator, gen = gen }, list, 0, rowCountOf(list))

    /// uploadRows の 1 回で行をまたいで変わらない物。
    type alias Uploads = { table = MeshTable.Table, allocator = MeshTable.MeshAllocator, gen = Int64 }

    def uploadRowsFrom(up: Uploads, list: SceneList, row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            uploadRow(up, list, row);
            uploadRowsFrom(up, list, row + 1, n)
        }

    def uploadRow(up: Uploads, list: SceneList, row: Int32): Unit \ IO =
        if (kindAt(list, row) == SceneRowKind.Billboard) () else discard MeshTable.ensure(up#table, up#allocator, up#gen, headAt(list, row)#fields#mesh);
        // WhyNot: 末尾を呼び出しで終えない — 行が物の数だけある場面で uploadRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
        ()

    /// 行を順に描く。group 0・頂点の buffer の 1 番（1 体ごとの値）は呼ぶ側が積んでおく。pipeline と材質の group は drawer が付ける。
    /// 形は行の形の番号で store から引く・instanceBase = この場面の 1 体ごとの値を送った位置（体の番号）。描く物の無い行は飛ばす。
    pub def drawRows(pass: RenderCommands, store: MeshStore, drawer: RowDrawer, list: SceneList, instanceBase: Int32): Unit \ IO =
        drawRowsFrom(pass, { meshes = Ref.get(store), drawer = drawer, list = list, instanceBase = instanceBase }, 0, rowCountOf(list))

    /// drawRows の 1 回で行をまたいで変わらない物。
    type alias Draws = { meshes = Map[Int32, MeshBuffers], drawer = RowDrawer, list = SceneList, instanceBase = Int32 }

    def drawRowsFrom(pass: RenderCommands, ds: Draws, row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            drawRow(pass, ds, row);
            drawRowsFrom(pass, ds, row + 1, n)
        }

    def drawRow(pass: RenderCommands, ds: Draws, row: Int32): Unit \ IO =
        let list = ds#list;
        let count = countAt(list, row);
        if (count <= 0) ()
        else if (kindAt(list, row) == SceneRowKind.Billboard) { if ((ds#drawer#billboard)(pass, list, row)) () else (ds#drawer#unbound)(count) }
        else Map.get(meshAt(list, row), ds#meshes) |> Option.forEach(mesh -> {
            if (mesh#indexCount <= 0) ()
            else if (isBound(pass, ds, row, mesh)) {
                pass.setVertexBuffer(0, mesh#vertices, 0i64, mesh#vertices.size());
                pass.setIndexBuffer(mesh#indices, IndexFormat.UINT32, 0i64, mesh#indices.size());
                pass.drawIndexed(mesh#indexCount, count, 0, 0, ds#instanceBase + firstInstanceAt(list, row))
            } else (ds#drawer#unbound)(count)
        });
        // WhyNot: 末尾を呼び出しで終えない — 行が物の数だけある場面で drawRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
        ()

    /// list の描く行の draw call と分かれた理由を holder に数え、描く物の数を返す（並びと数え方は Render3d.WebGpuRenderer.countRows）。
    pub def countRowsOf(holder: { countsHolder = Array[Int32, Static] | r }, list: SceneList): Int32 \ IO = countRowsFrom(holder, list, 0, rowCountOf(list), 0)

    def countRowsFrom(holder: { countsHolder = Array[Int32, Static] | r }, list: SceneList, row: Int32, n: Int32, acc: Int32): Int32 \ IO =
        if (row >= n) acc
        else countRowsFrom(holder, list, row + 1, n, acc + countRow(holder, list, row))

    /// 行 row を数え、描く物の数を返す: draw call は描く行（形の行・値のある材質の行・値のあるビルボードの行）で 1 つ、物の数はビルボードの行を足さない。
    def countRow(holder: { countsHolder = Array[Int32, Static] | r }, list: SceneList, row: Int32): Int32 \ IO =
        let count = countAt(list, row);
        let (drawn, instances) = match kindAt(list, row) {
            case SceneRowKind.VertexColor => (true, count)
            case SceneRowKind.Skinned     => (true, count)
            case SceneRowKind.Material    => if (valuesAt(list, row) >= 0) (true, count) else (false, 0)
            case SceneRowKind.Billboard   => (valuesAt(list, row) >= 0, 0)
        };
        if (count <= 0 or not drawn) 0
        else {
            Render3d.Counts.countDrawCallAt(holder, breakSlotAt(list, row));
            instances
        }

    /// 行 row の pipeline（と group）を付けたか（付けられない行は偽）。
    def isBound(pass: RenderCommands, ds: Draws, row: Int32, mesh: MeshBuffers): Bool \ IO =
        match kindAt(ds#list, row) {
            case SceneRowKind.VertexColor => (ds#drawer#shape)(pass, mesh)
            case SceneRowKind.Skinned     => (ds#drawer#skinned)(pass, mesh)
            case SceneRowKind.Material    => (ds#drawer#material)(pass, ds#list, row, mesh)
            case SceneRowKind.Billboard   => bug!("Render3d.WebGpuRows.isBound: ビルボードの行は drawRow が drawer#billboard へ渡す（形を引かない）")
        }
}
