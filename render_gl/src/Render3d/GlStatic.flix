// Render3d.GlStatic — 動かない物の集まりの持ち越した行（Render3d.StaticRows）を GPU に置いて毎コマ描く所（GL の backend）。
// 集まりごとに 1 体ごとの値の RGBA32F のテクスチャを 1 回だけ作って上げ、毎コマはその絵を 1 体ごとの値の unit に貼り替えて行を描く（頂点シェーダーは uInstanceBase + gl_InstanceID で引く）。
// 材質のプログラムは毎コマ引き直す（置き場の LRU から外さない・組み直したら番号が替わる）。番号が作った時と違えば作り直す。
// 描くのは場面の pass の空の後・場面の行の前（WebGPU の backend と同じ順）と、場面の影の地図の pass の場面の行の後。
// WhyNot: 作り直した時に前のテクスチャをその場で消さない — 同じコマの先の場面（Design の描き先・影の地図）が前に引いた物を描き終えていない事がある。コマの終わり（endFrame）に消す。
mod Render3d.GlStatic {
    import fge.gl.GlConst
    import fge.gl.GlContext
    use Render3d.{State, instanceTextureUnit}
    use Render3d.Material.{MaterialTable, resolveMaterials}
    use Render3d.ScenePlan.{MaterialRequest}
    use Render3d.StaticRows
    use Render3d.StaticRows.{CarriedRows}

    /// 持ち越した集まり 1 つを GPU に置いた物。rows = 前半の行・orders = 作った時の材質の問い合わせへの答え（プログラムの番号）・texture = 1 体ごとの値のテクスチャ。
    pub type alias Carried = { rows = CarriedRows, orders = Vector[Int32], texture = Int32 }

    /// 場面を描く時に使う、持ち越した集まり 1 つ。materials = このコマに引き直した材質の表（行の欄 1 で引く）。
    pub type alias CarriedDraw = { carried = Carried, materials = MaterialTable }

    /// 状態。cache = 集まりの持ち越しの控え・retired = コマの終わりに消すテクスチャ。
    pub type alias StaticCache = { cache = StaticRows.Cache[Carried], retired = Ref[List[Int32], Static] }

    pub def fresh(): StaticCache \ IO = { cache = StaticRows.freshCache(), retired = Ref.fresh(Static, Nil) }

    /// この数のコマ描かなかった集まりの持ち越しは手放す（描き先の Render3d.idleTargetFrames と同じ）。
    def idleFrames(): Int64 = 128i64

    /// 場面 scene の持ち越す集まりの物（同じ集まりが続くコマは作らずに前の物）。coverage = cutout を alpha to coverage の版にするか（Render3d.ScenePlan.coverageOf）。
    /// テクスチャを上げる時に 1 体ごとの値の unit を使うので、その prepare の 1 体ごとの値を上げる前に呼ぶ。
    pub def carriedOf(gl: GlContext, state: State, gen: Int64, tables: Render3d.SceneList.Tables, coverage: Bool, scene: Scene3d.Scene3dCmd): List[CarriedDraw] \ IO =
        let variant = StaticRows.carriedKeyOf(coverage, scene);
        scene#groups |> List.map(g -> drawOf(gl, state, gen, tables, coverage, scene, variant, g))

    /// 先に上げる宣言の集まり g を、場面 scene の行で描かずに作る（作り終えていれば真）。coverage は carriedOf と同じ。
    pub def prepareAhead(gl: GlContext, state: State, gen: Int64, tables: Render3d.SceneList.Tables, coverage: Bool, scene: Scene3d.Scene3dCmd,
                         g: Scene3d.StaticGroup): Bool \ IO =
        StaticRows.prepareAhead(state#planner, state#statics#cache, gen, g, StaticRows.carriedKeyOf(coverage, scene), coverage, scene, stepsOf(gl, state, gen, tables))

    /// 集まり g の持ち越した物と、このコマの材質の表。表の番号が作った時と違えば（組み直した材質がある）控えを全部捨てて作り直す。
    def drawOf(gl: GlContext, state: State, gen: Int64, tables: Render3d.SceneList.Tables, coverage: Bool, scene: Scene3d.Scene3dCmd,
               variant: String, g: Scene3d.StaticGroup): CarriedDraw \ IO =
        let st = state#statics;
        let ensure = () -> StaticRows.ensure(state#planner, st#cache, gen, g, variant, coverage, scene, stepsOf(gl, state, gen, tables));
        let held = ensure();
        let table = resolveMaterials(gl, state, gen, held#rows#requests);
        if (table#orders == held#orders) { carried = held, materials = table }
        else {
            StaticRows.clear(st#cache, retire(st));
            let made = ensure();
            { carried = made, materials = resolveMaterials(gl, state, gen, made#rows#requests) }
        }

    /// 集まりを作る仕事（StaticRows.BuildSteps）: 形を作る・材質のプログラムを組む・1 体ごとの値のテクスチャを上げる。
    // WhyNot: 材質の絵を先に上げない — GL は絵を描く時に引き（Render3d.Material）、上げた絵を持ち越した行が持たない。
    def stepsOf(gl: GlContext, state: State, gen: Int64, tables: Render3d.SceneList.Tables): StaticRows.BuildSteps[Carried] \ IO =
        let st = state#statics;
        let orders = Ref.fresh(Static, Vector.empty());
        let resolve = (requests: Vector[MaterialRequest]) -> {
            let found = resolveMaterials(gl, state, gen, requests)#orders;
            Ref.put(found, orders);
            found
        };
        { tables = tables, resolve = resolve,
          prepareMesh = mesh -> discard Render3d.meshEntry(gl, state, gen, mesh),
          prepareMaterial = request -> discard resolveMaterials(gl, state, gen, Vector#{request}),
          place = rows -> { rows = rows, orders = Ref.get(orders), texture = uploadValues(gl, state, rows) },
          uploadCount = _ -> 0, uploadAt = (_, _) -> (), retire = retire(st) }

    /// rows の 1 体ごとの値を新しいテクスチャへ上げて番号を返す（1 体ごとの値の unit を使い、unit 0 へ戻す）。
    def uploadValues(gl: GlContext, state: State, rows: CarriedRows): Int32 \ IO =
        let count = Int32.max(1, rows#instanceCount);
        let height = Render3d.GlRows.Instancing.rowsFor(count);
        let width = Render3d.GlRows.DataTexture.textureWidth();
        let out = Render3d.GlRows.DataTexture.bufferFor(gl, state#instances, height * width * 4);
        discard out.clear();
        discard out.put(rows#instances.asFloatBuffer());
        discard out.position(0);
        discard out.limit(height * width * 4);
        gl.activeTexture(GlConst.TEXTURE0 + instanceTextureUnit());
        let texture = Render3d.GlRows.DataTexture.createTexture(gl, 0i64, height);
        gl.texSubImageRgba32f(0, 0, width, height, out);
        gl.activeTexture(GlConst.TEXTURE0);
        texture#texId

    def retire(st: StaticCache): Carried -> Unit \ IO = c -> Ref.put(c#texture :: Ref.get(st#retired), st#retired)

    /// 持ち越した集まり c の行を、c のテクスチャを 1 体ごとの値の unit に貼って f で描き、終えたらその prepare のテクスチャ restore を貼り直す。
    pub def withValues(gl: GlContext, restore: Option[Int32], f: CarriedDraw -> Unit \ IO, carried: List[CarriedDraw]): Unit \ IO =
        if (List.isEmpty(carried)) ()
        else {
            carried |> List.forEach(c -> {
                Render3d.GlRows.DataTexture.bind(gl, instanceTextureUnit(), Some(c#carried#texture));
                f(c)
            });
            Render3d.GlRows.DataTexture.bind(gl, instanceTextureUnit(), restore)
        }

    /// 場面の inputs の pass と材質の表を、持ち越した集まり c の行と表にした物（行の形と絵を上げ、行を描く時に渡す）。
    pub def inputsOf(inputs: Render3d.GlRows.SceneInputs, c: CarriedDraw): Render3d.GlRows.SceneInputs =
        { passes = List.map(match (spec, _) -> (spec, c#carried#rows#list), inputs#passes), materials = c#materials,
          instanceTexture = Some(c#carried#texture), carried = Nil | inputs }

    /// 場面の時刻 time を持ち越した行の values へ書く（材質の uTime を行の値から読む）。
    pub def setTime(time: Float64, carried: List[CarriedDraw]): Unit \ IO =
        carried |> List.forEach(c -> discard StaticRows.setTime(c#carried#rows, time))

    /// 画面のコマの終わりに呼ぶ。evicted = 形の置き場がこのコマに形を捨てた（持ち越した行の形の番号が別の物を指しうるので全部を作り直す）。
    /// そうでなければ、しばらく描かなかった集まりを手放す。手放したテクスチャはここで消す。
    pub def endFrame(gl: GlContext, st: StaticCache, gen: Int64, evicted: Bool): Unit \ IO =
        if (evicted) StaticRows.clear(st#cache, retire(st)) else StaticRows.sweep(st#cache, gen, idleFrames(), retire(st));
        Ref.get(st#retired) |> List.forEach(tex -> gl.deleteTexture(tex));
        Ref.put(Nil, st#retired)

    /// 控えにある集まりの物の数（テストが使い回しを見る）。
    pub def sizeOf(st: StaticCache): Int32 \ IO = StaticRows.sizeOf(st#cache)
}
