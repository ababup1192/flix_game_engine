// Render3d.GlRows — 3D の場面の行（Render3d.SceneList）を GL で流す所（GL の backend）と、場面を描く時に場面の外から渡す物。約束は Render3d.flix の頭。
// 1 つの場面は uploadRows（形と絵を上げる）→ drawRows（ビルボードの行の前までを描く）→（ビルボードの行・Render3d.drawBillboards が drawBillboardRuns で）→ drawBlendedRows（半透明の行を重ねる）の順に通る。
// 行の欄の意味は Render3d.SceneList の頭。
mod Render3d.GlRows {
    import fge.gl.GlConst
    import fge.gl.GlContext
    use Render3d.{CameraData, DepthLocs, LitLocs, MaterialEntry, MaterialPass, MeshDraw, MeshLocs, SceneShadows, ShaderVariant, State, TextureSource,
                  Programs, drawMeshRange, ensureTangents, materialTextureNames, meshEntry, meshEntryAt, programsOf, putDepthRange, skinnedProgramsOf, useMeshProgram, warnMissingTexture}
    use Render3d.Batch.{MaterialBatch, MeshBatch}
    use Render3d.Counts.{BatchBreak, countDrawCall, countInstances}
    use Render3d.Light.{putLights}
    use Render3d.Material.{MaterialTable, bindMaterial, drawWithLook, entryAt, freshBound, releaseBound, resolveTextureAs, useMaterial}
    use Render3d.SceneList.{SceneList, ScenePasses, billboardAt, valuesAt, firstBillboardRowOf, firstBlendedRowOf, flagCoverage, flagDoubleSided, flagNormalMap, flagSameBinding, hasFlag, headAt, kindBillboard, kindMaterial, kindSkinned, materialAt, meshAt, rowAt, rowCountOf}
    use Render3d.Shadow.{putPointShadow, putShadow, putSunShadow}
    use Render3d.VariantPrograms.{litLocsOfVariant}

    /// 場面を描く時に場面の外から渡す物。passes = 場面の pass と、その行（計画の答え・列の順に描く）・materials = その prepare の材質の表・
    /// shadows = 先に描いておいた影の地図（スポットと太陽。無ければ None）・jointTexture = その prepare の joint texture（姿勢が無ければ None）・
    /// instanceTexture = その prepare の 1 体ごとの値のテクスチャ（描く物が無ければ None）。
    pub type alias SceneInputs = {
        passes = ScenePasses, materials = MaterialTable, shadows = SceneShadows,
        jointTexture = Option[Int32], instanceTexture = Option[Int32]
    }

    /// 場面をどう 2D の並びへ出すか。Native = その場で描く・Design = 先に描いておいた描き先を貼る（大きさの無い場面は None で、何も出さない）。
    pub enum SceneTarget {
        case Native(SceneInputs)
        case Design(Option[RenderTargetGl.Entry])
    }

    /// 2D の並びへ渡す場面 1 つ。
    pub type alias SceneItem = { cmd = Scene3d.RenderCmd, target = SceneTarget }

    /// pass ごとの行の形を置き場へ上げる（無ければ。描く時は行の形の番号で引く・ビルボードの行は飛ばす）。材質の行（半透明の行も）の絵（材質の絵・法線マップ・lightmap）と
    /// タンジェントも上げる（間引いた物も今のコマで使った物として数える）。置いた物 total 個と描く物の数を足す。
    /// 描き始める前に呼ぶ（初めての絵は引く時に今の unit へ貼るので、絵を引いたら unit 0 へ戻す）。
    // WhyNot: 間引いた物を置き場で古いままにしない — 振り向くたびに形と絵を上げ直して止まり、毎コマ作り直しの知らせも鳴る。
    // WhyNot: 描く途中で上げない — WebGPU の backend は render pass の中で物を作れない。GL でも draw の間に bufferData と mip の生成が挟まる。
    pub def uploadRows(gl: GlContext, state: State, gen: Int64, source: TextureSource, inputs: SceneInputs, total: Int32): Unit \ IO =
        let touched = Array#{0, 0} @ Static;
        inputs#passes |> List.forEach(pl -> uploadRowsFrom(gl, state, gen, source, inputs, snd(pl), touched, 0, rowCountOf(snd(pl))));
        if (Array.get(0, touched) == 1) gl.activeTexture(GlConst.TEXTURE0) else ();
        countInstances(state, total, Array.get(1, touched))

    def uploadRowsFrom(gl: GlContext, state: State, gen: Int64, source: TextureSource, inputs: SceneInputs, list: SceneList,
                       touched: Array[Int32, Static], row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            uploadRow(gl, state, gen, source, inputs, list, touched, row);
            uploadRowsFrom(gl, state, gen, source, inputs, list, touched, row + 1, n)
        }

    /// touched = [絵を引いたら 1, 行の描く物の数の合計]。
    def uploadRow(gl: GlContext, state: State, gen: Int64, source: TextureSource, inputs: SceneInputs, list: SceneList,
                  touched: Array[Int32, Static], row: Int32): Unit \ IO =
        if (rowAt(list, row, 0) == kindBillboard()) () else uploadMeshRow(gl, state, gen, source, inputs, list, touched, row);
        // WhyNot: 末尾を呼び出しで終えない — 行が物の数だけある場面で uploadRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
        ()

    def uploadMeshRow(gl: GlContext, state: State, gen: Int64, source: TextureSource, inputs: SceneInputs, list: SceneList,
                      touched: Array[Int32, Static], row: Int32): Unit \ IO =
        let head = headAt(list, row);
        discard meshEntry(gl, state, gen, head#fields#mesh);
        Array.put(Array.get(1, touched) + rowAt(list, row, 4), 1, touched);
        materialAt(list, row) |> Option.forEach(m -> {
            let material = entryAt(inputs#materials, rowAt(list, row, 1));
            uploadTextures(gl, state, gen, source, touched, material, m, head);
            if (hasFlag(list, row, flagNormalMap())) ensureTangents(gl, state, gen, head#fields#mesh) else ()
        })

    def uploadTextures(gl: GlContext, state: State, gen: Int64, source: TextureSource, touched: Array[Int32, Static], entry: MaterialEntry,
                       m: Scene3d.MaterialFields, head: MeshDraw): Unit \ IO =
        materialTextureNames(entry, m, head) |> List.forEach(read -> {
            let (label, name, textureUse) = read;
            Array.put(1, 0, touched);
            discard resolveTextureAs(gl, state, gen, source, label, name, textureUse)
        })

    /// pass 1 つの行 list のうちビルボードの行の前（firstBillboardRowOf の前）を順に描く（形は uploadRows で上げてある）。頂点の色と骨つきの行は、プログラムが替わる所でプログラムと場面の値（目・光・影か、奥行きの範囲）を付ける。
    /// 材質の行は材質のプログラムが替わる所で付け替え、描く物の無い材質の行は飛ばす。描き終えたら材質の絵を貼った unit の sampler を外す。
    pub def drawRows(gl: GlContext, state: State, gen: Int64, camera: CameraData, pass: MaterialPass, eye: Vec3.Vec3, source: TextureSource,
                     inputs: SceneInputs, list: SceneList): Unit \ IO =
        drawRowsBetween(gl, state, gen, { camera = camera, pass = pass, eye = eye, source = source, inputs = inputs, list = list, bound = freshBound() },
                        0, firstBillboardRowOf(list))

    /// 行 list の半透明の行（firstBlendedRowOf から・計画が遠い物から並べた）を、深度を読むが書かずに α で重ねて描く（色の pass だけ）。無ければ何もしない。
    /// 混ぜ方は glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA)。描き終えたら blend を切り深度の書き込みを戻す。
    pub def drawBlendedRows(gl: GlContext, state: State, gen: Int64, camera: CameraData, eye: Vec3.Vec3, source: TextureSource,
                            inputs: SceneInputs, list: SceneList): Unit \ IO =
        let first = firstBlendedRowOf(list);
        if (first >= rowCountOf(list)) ()
        else {
            gl.depthMask(false);
            gl.enable(GlConst.BLEND);
            gl.blendFuncSeparate(GlConst.SRC_ALPHA, GlConst.ONE_MINUS_SRC_ALPHA, GlConst.ONE, GlConst.ONE_MINUS_SRC_ALPHA);
            drawRowsBetween(gl, state, gen, { camera = camera, pass = MaterialPass.Color, eye = eye, source = source, inputs = inputs, list = list, bound = freshBound() },
                            first, rowCountOf(list));
            gl.disable(GlConst.BLEND);
            gl.depthMask(true)
        }

    /// frame#list の row から n の前までの行を描き、描き終えたら材質の絵を貼った unit の sampler を外す。
    def drawRowsBetween(gl: GlContext, state: State, gen: Int64, frame: RowFrame, row: Int32, n: Int32): Unit \ IO =
        drawRowsFrom(gl, state, gen, frame, row, n);
        releaseBound(gl, frame#bound)

    def drawRowsFrom(gl: GlContext, state: State, gen: Int64, frame: RowFrame, row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            drawRow(gl, state, gen, frame, row);
            drawRowsFrom(gl, state, gen, frame, row + 1, n)
        }

    /// drawRows の 1 回で行をまたいで変わらない物。list = 描く pass の行・bound = 今付いているプログラムと貼った unit（Render3d.Material.freshBound）。
    type alias RowFrame = {
        camera = CameraData, pass = MaterialPass, eye = Vec3.Vec3, source = TextureSource, inputs = SceneInputs, list = SceneList, bound = Array[Int32, Static]
    }

    def drawRow(gl: GlContext, state: State, gen: Int64, frame: RowFrame, row: Int32): Unit \ IO =
        let kind = rowAt(frame#list, row, 0);
        if (kind == kindMaterial()) drawMaterialRow(gl, state, gen, frame, row)
        else drawShapeRow(gl, state, frame, kind == kindSkinned(), row);
        // WhyNot: 末尾を呼び出しで終えない — 行が物の数だけある場面で drawRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
        ()

    // WhyNot: 描く物の無い行でプログラムを引く前に飛ばさない — 骨つきの版は骨つきの行が来たコマに組む決まりで、全部が間引かれている間に組まずにおくと、振り向いたコマで GLSL を組んで止まる。
    def drawShapeRow(gl: GlContext, state: State, frame: RowFrame, skinned: Bool, row: Int32): Unit \ IO =
        let mesh = shapeMeshLocs(gl, state, frame#camera#variant, frame#pass, skinned);
        if (mesh#program == 0) ()
        else {
            if (mesh#program == Array.get(0, frame#bound)) ()
            else {
                Array.put(mesh#program, 0, frame#bound);
                useShapeProgram(gl, state, frame, skinned)
            };
            drawRowRange(gl, state, mesh, frame, row)
        }

    def drawMaterialRow(gl: GlContext, state: State, gen: Int64, frame: RowFrame, row: Int32): Unit \ IO =
        let list = frame#list;
        if (rowAt(list, row, 4) == 0) ()
        else materialAt(list, row) |> Option.forEach(m -> {
            let entry = entryAt(frame#inputs#materials, rowAt(list, row, 1));
            let look = { coverage = hasFlag(list, row, flagCoverage()), doubleSided = hasFlag(list, row, flagDoubleSided()) };
            if (hasFlag(list, row, flagSameBinding())) ()
            else {
                useMaterial(gl, state, frame#camera, frame#pass, frame#bound, entry);
                bindMaterial(gl, state, gen, frame#source, frame#bound, entry, m, headAt(list, row))
            };
            drawWithLook(gl, look, () -> drawRowRange(gl, state, entry#locs#mesh, frame, row))
        })

    def drawRowRange(gl: GlContext, state: State, mesh: MeshLocs, frame: RowFrame, row: Int32): Unit \ IO =
        let list = frame#list;
        let entry = meshEntryAt(state, meshAt(list, row));
        drawMeshRange(gl, state, mesh, rowAt(list, row, 5), (entry#vao, entry#indexCount), rowAt(list, row, 3), rowAt(list, row, 4))

    def shapeMeshLocs(gl: GlContext, state: State, frameVariant: ShaderVariant, pass: MaterialPass, skinned: Bool): MeshLocs \ IO = match pass {
        case MaterialPass.Color    => litLocsOfVariant(gl, state, frameVariant, skinned)#mesh
        case MaterialPass.Depth(_) => depthLocsFor(gl, state, skinned)#mesh
    }

    /// 頂点の色の（骨つきなら骨つきの版の）プログラムを付けて、場面の値を入れる。
    def useShapeProgram(gl: GlContext, state: State, frame: RowFrame, skinned: Bool): Unit \ IO =
        let camera = frame#camera;
        match frame#pass {
            case MaterialPass.Color =>
                let locs = litLocsOfVariant(gl, state, camera#variant, skinned);
                useMeshProgram(gl, locs#mesh, camera#view, camera#proj);
                putLights(gl, locs#light, camera#lights);
                putShadow(gl, locs#shadow, camera#shadows#spot);
                putSunShadow(gl, locs#sunShadow, camera#shadows#sun);
                putPointShadow(gl, locs#pointShadow, camera#shadows#point)
            case MaterialPass.Depth(dr) =>
                let locs = depthLocsFor(gl, state, skinned);
                useMeshProgram(gl, locs#mesh, camera#view, camera#proj);
                gl.uniform3f(locs#eye, RenderUtil.f32(frame#eye#x), RenderUtil.f32(frame#eye#y), RenderUtil.f32(frame#eye#z));
                putDepthRange(gl, locs#depthRange, dr)
        }

    def depthLocsFor(gl: GlContext, state: State, skinned: Bool): DepthLocs \ IO =
        if (skinned) skinnedProgramsOf(gl, state)#depth else programsOf(gl, state)#depth

    // ── ビルボードの行 ──

    /// 行 list のビルボードの行を、行ごとに欄 1 の絵を unit 0 に貼り、欄 4 の数の instance で描く（板ごとの値は list の values を板専用の VBO へ 1 回送って読む）。
    /// 絵の見つからない行は名前ごとに 1 回知らせて描かない。draw 1 回を why として数える。プログラムと uniform は呼ぶ側が付けておく。
    pub def drawBillboardRuns(gl: GlContext, state: State, list: SceneList, why: BatchBreak): Unit \ IO =
        let programs = programsOf(gl, state);
        let first = firstBillboardRowOf(list);
        let end = firstBlendedRowOf(list);
        let start = firstBillboardValueOf(list, first, end);
        if (start >= 0) uploadBillboardValues(gl, programs, list, start) else ();
        gl.activeTexture(GlConst.TEXTURE0);
        gl.bindVertexArray(programs#billboardVao);
        drawBillboardRunsFrom(gl, state, { list = list, start = start, why = why, vbo = programs#billboardVbo }, first, end);
        gl.bindVertexArray(0)

    /// drawBillboardRunsFrom の 1 回で行をまたいで変わらない物。start = VBO の頭に送った values の位置・vbo = 板専用の VBO。
    type alias BillboardRunDraw = { list = SceneList, start = Int32, why = BatchBreak, vbo = Int32 }

    def drawBillboardRunsFrom(gl: GlContext, state: State, d: BillboardRunDraw, row: Int32, end: Int32): Unit \ IO =
        if (row >= end) ()
        else {
            drawBillboardRun(gl, state, d, row);
            drawBillboardRunsFrom(gl, state, d, row + 1, end)
        }

    def drawBillboardRun(gl: GlContext, state: State, d: BillboardRunDraw, row: Int32): Unit \ IO =
        let list = d#list;
        let texId = rowAt(list, row, 1);
        let values = valuesAt(list, row);
        if (texId < 0) warnMissingTexture(state, billboardAt(list, row)#texture)
        else if (values < 0) ()
        else {
            gl.bindTexture(GlConst.TEXTURE_2D, texId);
            pointBillboardValues(gl, d#vbo, 4 * (values - d#start));
            gl.drawArraysInstanced(GlConst.TRIANGLES, 0, 6, rowAt(list, row, 4));
            countDrawCall(state, d#why)
        };
        // WhyNot: 末尾を呼び出しで終えない — ビルボードが多い場面で drawBillboardRunsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
        ()

    /// 行 first から end の前までで、値のある最初の行の値の位置（無ければ −1）。値は行の順に続いて values の末尾まで並ぶ。
    def firstBillboardValueOf(list: SceneList, row: Int32, end: Int32): Int32 \ IO =
        if (row >= end) -1
        else if (valuesAt(list, row) >= 0) valuesAt(list, row)
        else firstBillboardValueOf(list, row + 1, end)

    /// list の values の start から末尾までを、板専用の VBO へ送る（中身は毎回差し替える）。
    def uploadBillboardValues(gl: GlContext, programs: Programs, list: SceneList, start: Int32): Unit \ IO =
        let n = Array.length(list#values) - start;
        let buf = programs#billboardBuf;
        RenderBuf.ensure(gl, buf, n);
        let fb = RenderBuf.buffer(buf);
        discard fb.clear();
        discard fb.put(list#values, start, n);
        discard fb.flip();
        gl.bindBuffer(GlConst.ARRAY_BUFFER, programs#billboardVbo);
        gl.bufferData(GlConst.ARRAY_BUFFER, fb, GlConst.DYNAMIC_DRAW);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, 0)

    /// 板専用の VAO（bind してある物）の location 1〜4 を、VBO の byteOffset から始まる板の値（stride = 値 1 つ・instance ごと）へ向ける。
    // WhyNot: 並びごとに base instance で頭を選ばない — GL 3.3 と WebGL2 に glDrawArraysInstancedBaseInstance が無い。
    def pointBillboardValues(gl: GlContext, vbo: Int32, byteOffset: Int32): Unit \ IO =
        let stride = 4 * Render3d.SceneList.billboardValueFloats();
        gl.bindBuffer(GlConst.ARRAY_BUFFER, vbo);
        gl.vertexAttribPointer(1, 4, GlConst.FLOAT, false, stride, byteOffset);
        gl.vertexAttribPointer(2, 4, GlConst.FLOAT, false, stride, byteOffset + 16);
        gl.vertexAttribPointer(3, 4, GlConst.FLOAT, false, stride, byteOffset + 32);
        gl.vertexAttribPointer(4, 4, GlConst.FLOAT, false, stride, byteOffset + 48);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, 0)

    /// 板の VAO と、板ごとの値の VBO（中身は描く時に送る）。location 0 = quadVbo の四角の角・1〜4 = 板ごとの値（instance ごと・向ける位置は pointBillboardValues）。
    pub def buildBillboardVao(gl: GlContext, quadVbo: Int32): (Int32, Int32) \ IO =
        let vao = gl.createVertexArray();
        let vbo = gl.createBuffer();
        gl.bindVertexArray(vao);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, quadVbo);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, GlConst.FLOAT, false, 8, 0);
        List.range(1, 5) |> List.forEach(i -> {
            gl.enableVertexAttribArray(i);
            gl.vertexAttribDivisor(i, 1)
        });
        pointBillboardValues(gl, vbo, 0);
        gl.bindVertexArray(0);
        (vao, vbo)
}
