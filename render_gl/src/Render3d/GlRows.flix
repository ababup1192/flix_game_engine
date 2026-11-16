// Render3d.GlRows — 3D の場面の行（Render3d.SceneList）を GL で流す所（GL の backend）と、場面を描く時に場面の外から渡す物。約束は Render3d.flix の頭。
// 1 つの場面は uploadRows（形と絵を上げる）→ drawRows（行を描く）の順に通る。行の欄の意味は Render3d.SceneList の頭。
mod Render3d.GlRows {
    import fge.gl.GlConst
    import fge.gl.GlContext
    use Render3d.{CameraData, DepthLocs, LitLocs, MaterialEntry, MaterialPass, MeshDraw, MeshLocs, SceneShadows, State, TextureSource,
                  drawMeshRange, ensureTangents, materialTextureNames, meshEntry, meshEntryAt, programsOf, putDepthRange, skinnedProgramsOf, useMeshProgram}
    use Render3d.Batch.{MaterialBatch, MeshBatch}
    use Render3d.Counts.{countInstances}
    use Render3d.Light.{putLights}
    use Render3d.Material.{MaterialTable, bindMaterial, drawWithLook, entryAt, freshBound, releaseBound, resolveTextureAs, useMaterial}
    use Render3d.SceneList.{SceneList, ScenePasses, blendedRowOf, flagCoverage, flagDoubleSided, flagNormalMap, flagSameBinding, hasFlag, headAt, kindMaterial, kindSkinned, materialAt, meshAt, rowAt, rowCountOf}
    use Render3d.Shadow.{putShadow, putSunShadow}

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

    /// pass ごとの行の形を置き場へ上げる（無ければ。描く時は行の形の番号で引く）。材質の行（半透明の行も）の絵（材質の絵・法線マップ・lightmap）と
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
        let head = headAt(list, row);
        discard meshEntry(gl, state, gen, head#fields#mesh);
        Array.put(Array.get(1, touched) + rowAt(list, row, 4), 1, touched);
        materialAt(list, row) |> Option.forEach(m -> {
            let material = entryAt(inputs#materials, rowAt(list, row, 1));
            uploadTextures(gl, state, gen, source, touched, material, m, head);
            if (hasFlag(list, row, flagNormalMap())) ensureTangents(gl, state, gen, head#fields#mesh) else ()
        });
        // WhyNot: 末尾を呼び出しで終えない — 行が物の数だけある場面で uploadRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
        ()

    def uploadTextures(gl: GlContext, state: State, gen: Int64, source: TextureSource, touched: Array[Int32, Static], entry: MaterialEntry,
                       m: Scene3d.MaterialFields, head: MeshDraw): Unit \ IO =
        materialTextureNames(entry, m, head) |> List.forEach(read -> {
            let (label, name, textureUse) = read;
            Array.put(1, 0, touched);
            discard resolveTextureAs(gl, state, gen, source, label, name, textureUse)
        })

    /// pass 1 つの行 list のうち半透明でない行（blendedRowOf の前）を順に描く（形は uploadRows で上げてある）。頂点の色と骨つきの行は、プログラムが替わる所でプログラムと場面の値（目・光・影か、奥行きの範囲）を付ける。
    /// 材質の行は材質のプログラムが替わる所で付け替え、描く物の無い材質の行は飛ばす。描き終えたら材質の絵を貼った unit の sampler を外す。
    pub def drawRows(gl: GlContext, state: State, gen: Int64, camera: CameraData, pass: MaterialPass, eye: Vec3.Vec3, source: TextureSource,
                     inputs: SceneInputs, list: SceneList): Unit \ IO =
        drawRowsBetween(gl, state, gen, { camera = camera, pass = pass, eye = eye, source = source, inputs = inputs, list = list, bound = freshBound() },
                        0, blendedRowOf(list))

    /// 行 list の半透明の行（blendedRowOf から・計画が遠い物から並べた）を、深度を読むが書かずに α で重ねて描く（色の pass だけ）。無ければ何もしない。
    /// 混ぜ方は glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA)。描き終えたら blend を切り深度の書き込みを戻す。
    pub def drawBlendedRows(gl: GlContext, state: State, gen: Int64, camera: CameraData, eye: Vec3.Vec3, source: TextureSource,
                            inputs: SceneInputs, list: SceneList): Unit \ IO =
        let first = blendedRowOf(list);
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
        let mesh = shapeMeshLocs(gl, state, frame#pass, skinned);
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

    def shapeMeshLocs(gl: GlContext, state: State, pass: MaterialPass, skinned: Bool): MeshLocs \ IO = match pass {
        case MaterialPass.Color    => litLocsFor(gl, state, skinned)#mesh
        case MaterialPass.Depth(_) => depthLocsFor(gl, state, skinned)#mesh
    }

    /// 頂点の色の（骨つきなら骨つきの版の）プログラムを付けて、場面の値を入れる。
    def useShapeProgram(gl: GlContext, state: State, frame: RowFrame, skinned: Bool): Unit \ IO =
        let camera = frame#camera;
        match frame#pass {
            case MaterialPass.Color =>
                let locs = litLocsFor(gl, state, skinned);
                useMeshProgram(gl, locs#mesh, camera#view, camera#proj);
                putLights(gl, locs#light, camera#lights);
                putShadow(gl, locs#shadow, camera#shadows#spot);
                putSunShadow(gl, locs#sunShadow, camera#shadows#sun)
            case MaterialPass.Depth(dr) =>
                let locs = depthLocsFor(gl, state, skinned);
                useMeshProgram(gl, locs#mesh, camera#view, camera#proj);
                gl.uniform3f(locs#eye, RenderUtil.f32(frame#eye#x), RenderUtil.f32(frame#eye#y), RenderUtil.f32(frame#eye#z));
                putDepthRange(gl, locs#depthRange, dr)
        }

    /// 骨つきの版は骨つきの行がある時だけ組む。
    def litLocsFor(gl: GlContext, state: State, skinned: Bool): LitLocs \ IO =
        if (skinned) skinnedProgramsOf(gl, state)#lit else programsOf(gl, state)#lit

    def depthLocsFor(gl: GlContext, state: State, skinned: Bool): DepthLocs \ IO =
        if (skinned) skinnedProgramsOf(gl, state)#depth else programsOf(gl, state)#depth
}
