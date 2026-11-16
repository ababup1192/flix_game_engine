// Render3d.SceneList — 3D の場面 1 つの batch を描く行の列（RenderList の 3D の分。計画の側が pass ごとに作り（buildScenePasses）、GL の backend は Render3d.GlRows・WebGPU の backend は Render3d.WebGpuRows が流す）。
// 1 行 = 形 1 つの集まりを 1 回の instanced draw で描く（頂点の色の物・骨つきの物・不透明の材質の物・半透明の材質の物）か、ビルボード 1 つを描く。空は行にしない。
// 影の地図の pass の行（buildShadowList・計画は Render3d.ShadowMaps）は頂点の色の行と骨つきの行だけで、backend は形だけを深度で描く。
// rows は 1 行 rowStride() 個: 0=種類（kind*） 1=材質の表の番号（MaterialBatch#handle。頂点の色と骨つきは 0） 2=材質の順の番号（MaterialBatch#order。同じく 0）
//   3=1 体ごとの値の先頭 4=描く物の数（0 なら描かず、形と絵を今のコマで使った物として数えるだけ） 5=1 つの draw call に分かれた理由（Render3d.Counts.breakSlotOf）
//   6=フラグ（flag*: 両面・alpha to coverage・法線マップ・前の材質の行と同じ付け方・lightmap） 7=形の番号（Render3d.MeshTable。backend は行を流す前にこの番号の形を作り、描く時にこの番号で引く）
//   8=材質の値の先頭（values の位置・材質の行で描く物がある時だけ。ほかは -1） 9=絵の組の先頭（reads の組の番号） 10=絵の組の数。
//   ビルボードの行（kindBillboard）は 1=全体の登録の絵の番号（RegisteredTexture#texId・見つからなければ -1） 4=視錐台の中なら 1（外なら 0）
//   5=分かれた理由（Billboard） 7=-1 8=ビルボードの値の先頭（視錐台の中で絵がある行だけ・billboardValueFloats() 個。ほかは -1） で、ほかの欄は 0。
//   GL は絵を描く時に引き（欄 4 だけを見る）、WebGPU は欄 8 の値のある行だけを描く。
//   行の順が描く順（頂点の色 → 骨つき → 不透明の材質を順の番号で → firstBillboard 行目からビルボードを場面の来た順で（1 行 1 つ）
//   → firstBlended 行目から半透明の材質を計画が並べた順（遠い物から・1 行 1 体））。
//   backend はこの順で 3 つに分けて流す: firstBillboard の前の行（深度を書く）→ ビルボードの行（深度を書く・α < 0.5 を捨てる）→ 残りの行（深度を読むが書かずに α で重ねる）。
// heads は行ごとの頭の物（形・lightmap・タンジェントを読む。ビルボードの行は無いので headAt を呼ばない）・materials は材質の行の材質（firstMaterial 行目からの並び・半透明の行も含む・
// ビルボードの行の所は空きで materialAt は None）・billboards はビルボードの行の中身（firstBillboard 行目からの並び）。
// values（Float32）と reads（Int32）は材質の行の draw ごとの値と絵の組（並びは Render3d.MaterialValues の頭）と、その後ろにビルボードの値（並びは billboardValueFloats）。
// GL は今も材質の uniform を materials から・ビルボードの uniform を billboards から差す（values と reads を使うのは WebGPU）。
// WhyNot: 行ごとに MeshBatch の record を backend へ渡さない — backend 2 つが分かれ目に読む欄（種類・材質・範囲・理由・フラグ）を、GL の側で引き直さずに同じ物を読む。
mod Render3d.SceneList {
    use Render3d.{MeshDraw, TextureSource}
    use Render3d.Batch.{MaterialBatch, MeshBatch}
    use Render3d.Counts.{BatchBreak, breakSlotOf}
    use Render3d.MaterialValues
    use Render3d.MeshTable
    use Render3d.ScenePlan.{BillboardDraw, SceneDraws, ScenePassSpec, ScenePlan, isSkinned}
    use Render3d.TextureTable3d

    pub type alias SceneList = {
        rows = Array[Int32, Static], heads = Array[MeshDraw, Static], materials = Array[Scene3d.MaterialFields, Static], firstMaterial = Int32, firstBillboard = Int32,
        firstBlended = Int32, billboards = Array[Scene3d.BillboardFields, Static], count = Int32, values = Array[Float32, Static], reads = Array[Int32, Static]
    }

    /// 場面 1 つの pass と、その pass で流す行の列（列の順に pass を積む）。
    pub type alias ScenePasses = List[(ScenePassSpec, SceneList)]

    /// 行を作る時に番号を振る表（backend が持ち、計画が育てる）。meshes = 形の表・textures = 絵の表・layouts = 材質の値の並びの元・
    /// gen = 番号を振る時の世代・gpuMip = 段を GPU に作らせる backend か（絵の表の鍵）・textureOf = 全体の登録の絵。
    pub type alias Tables = {
        meshes = MeshTable.Table, textures = TextureTable3d.Table, layouts = MaterialValues.Layouts, gen = Int64, gpuMip = Bool,
        textureOf = String -> Option[Scene3dRenderer.RegisteredTexture] \ IO
    }

    /// 行を作る 1 回の材料。naming = 絵の名前を番号へ引く元・time = 場面の時刻（材質の uTime）。
    pub type alias Context = { meshes = MeshTable.Table, layouts = MaterialValues.Layouts, naming = MaterialValues.Naming, time = Float64 }

    /// 1 体ごとの値の番号を振り終えた場面の計画 plan を、pass ごとの行の列にする（今は場面の置いた物を描く pass 1 つ）。
    /// 行の形と材質の絵の番号は tables で振る（GPU には作らない・lastUsed は tables#gen）。
    pub def buildScenePasses(tables: Tables, plan: ScenePlan[MeshBatch]): ScenePasses \ IO =
        (plan#mainPass, buildSceneList(contextOf(tables, plan#cmd#scene), plan#draws)) :: Nil

    /// 場面 scene の行を tables で作る材料。
    pub def contextOf(tables: Tables, scene: Scene3d.Scene3dCmd): Context =
        let source: TextureSource = { textureOf = tables#textureOf, own = scene#textures |> List.map(t -> (Texture3d.name(t), t)) |> List.toMap };
        { meshes = tables#meshes, layouts = tables#layouts, time = scene#time,
          naming = { source = source, gpuMip = tables#gpuMip, textures = tables#textures, gen = tables#gen } }

    /// 行の種類。
    pub def kindVertexColor(): Int32 = 1
    pub def kindSkinned(): Int32 = 2
    pub def kindMaterial(): Int32 = 3
    pub def kindBillboard(): Int32 = 4

    /// ビルボードの行の値の float の数: 立てる点の xyz と lit（1 か 0）・anchor の xy と size の xy・貼る範囲の uv（左上 u・v と幅・高さ。上の行が v = 0）・線形へ戻した tint の rgb と 0。
    // WhyNot: 貼る範囲の v をレンダーターゲットで上下に返さない — 値を読む WebGPU の描き先は上の行が先（GL は行 0 が下なので、GL は billboards から自分で返す）。
    pub def billboardValueFloats(): Int32 = 16

    /// フラグの bit。
    pub def flagDoubleSided(): Int32 = 1
    pub def flagCoverage(): Int32 = 2
    pub def flagNormalMap(): Int32 = 4
    /// 前に描いた材質の行と同じプログラム・値・絵で描く（backend は付け直さずに draw だけ出してよい）。
    pub def flagSameBinding(): Int32 = 8
    /// lightmap の版（絵の組の末尾が行の頭の物の lightmap）。
    pub def flagLightmap(): Int32 = 16

    def rowStride(): Int32 = 11

    pub def rowCountOf(list: SceneList): Int32 = list#count

    /// ビルボードの行の頭（無ければ firstBlendedRowOf と同じ）。
    pub def firstBillboardRowOf(list: SceneList): Int32 = list#firstBillboard

    /// 半透明の材質の行の頭（無ければ rowCountOf と同じ）。
    pub def firstBlendedRowOf(list: SceneList): Int32 = list#firstBlended

    /// 絵が見つからなかったビルボードの行の絵の名前（行の順）。
    pub def missingBillboardTexturesOf(list: SceneList): List[String] \ IO =
        List.range(list#firstBillboard, list#firstBlended) |> List.filter(row -> rowAt(list, row, 1) < 0) |> List.map(row -> billboardAt(list, row)#texture)

    /// ビルボードの行 row の中身。
    pub def billboardAt(list: SceneList, row: Int32): Scene3d.BillboardFields \ IO = Array.get(row - list#firstBillboard, list#billboards)

    /// 行 row の欄 col（並びはこのファイルの頭のコメント）。
    pub def rowAt(list: SceneList, row: Int32, col: Int32): Int32 \ IO = Array.get(row * rowStride() + col, list#rows)

    pub def headAt(list: SceneList, row: Int32): MeshDraw \ IO = Array.get(row, list#heads)

    /// 行 row の形の番号（Render3d.MeshTable）。
    pub def meshAt(list: SceneList, row: Int32): Int32 \ IO = rowAt(list, row, 7)

    /// 材質の行 row の材質（頂点の色と骨つきとビルボードの行は None）。
    pub def materialAt(list: SceneList, row: Int32): Option[Scene3d.MaterialFields] \ IO =
        if (row < list#firstMaterial or (row >= list#firstBillboard and row < list#firstBlended)) None else Some(Array.get(row - list#firstMaterial, list#materials))

    /// 行 row の材質の値の先頭（values の位置。値の無い行は -1）。
    pub def valuesAt(list: SceneList, row: Int32): Int32 \ IO = rowAt(list, row, 8)

    /// 材質の行 row の値の位置を at にする（同じ中身の値を前の行と分け合う時・Render3d.StaticRows）。
    pub def setValuesAt(list: SceneList, row: Int32, at: Int32): Unit \ IO = Array.put(at, row * rowStride() + 8, list#rows)

    /// 行 row の絵の組の k 番目の欄 col（並びは Render3d.MaterialValues の頭）。
    pub def readAt(list: SceneList, row: Int32, k: Int32, col: Int32): Int32 \ IO =
        Array.get((rowAt(list, row, 9) + k) * MaterialValues.readStride() + col, list#reads)

    /// 行 row のフラグに flag が立っているか。
    pub def hasFlag(list: SceneList, row: Int32, flag: Int32): Bool \ IO = Int32.bitwiseAnd(rowAt(list, row, 6), flag) != 0

    /// 場面の batch とビルボードを描く順の行にする（ビルボードは不透明の行の後に来た順・半透明の blended は計画が並べた順のまま末尾へ）。形と材質の絵の番号は ctx の表で振る。
    // WhyNot: 半透明の頭の行の「前の材質の行と同じ付け方」を不透明の最後の行から続けて見ない — 間にビルボードの行が来て、GL の drawBlendedRows は
    //   付けた物の控えを新しく作って始めるので、頭の行に同じ付け方のフラグがあるとプログラムを付けずに描く。
    pub def buildSceneList(ctx: Context, draws: SceneDraws[MeshBatch]): SceneList \ IO =
        let shapes = List.length(draws#plain) + List.length(draws#skinned);
        let firstBillboard = shapes + List.length(draws#opaque);
        let billboards = draws#billboards |> List.map(b -> (b, textureOfBillboard(ctx, b)));
        let firstBlended = firstBillboard + List.length(billboards);
        let count = firstBlended + List.length(draws#blended);
        let opaque = layoutPairsOf(ctx, draws#opaque);
        let blended = layoutPairsOf(ctx, draws#blended);
        let both = List.append(opaque, blended);
        let materialTotal = List.sumWith(dl -> Option.getWithDefault(0, Option.map(MaterialValues.valueSizeOf, snd(dl))), both);
        let billboardTotal = billboardValueFloats() * List.count(isDrawnBillboard, billboards);
        let readTotal = both |> List.sumWith(match (d, l) -> Option.getWithDefault(0, Option.map(x -> MaterialValues.readCountOf(x, d#kind), l)));
        let list = { rows = Array.repeat(Static, Int32.max(1, count * rowStride()), 0), heads = Array.empty(Static, count),
                     materials = Array.empty(Static, count - shapes), firstMaterial = shapes, firstBillboard = firstBillboard, firstBlended = firstBlended,
                     billboards = billboards |> List.map(bt -> fst(bt)#fields) |> List.toArray(Static), count = count,
                     values = Array.repeat(Static, Int32.max(1, materialTotal + billboardTotal), 0.0f32),
                     reads = Array.repeat(Static, Int32.max(1, readTotal * MaterialValues.readStride()), 0) };
        let next = Array#{0, 0, 0} @ Static;
        draws#plain |> List.forEach(b -> putShapeRow(list, next, ctx, kindVertexColor(), BatchBreak.Mesh, b));
        draws#skinned |> List.forEach(b -> putShapeRow(list, next, ctx, kindSkinned(), BatchBreak.Skinned, b));
        discard List.foldLeft(putMaterialRow(list, next, ctx), None, opaque);
        let valueCursor = Array#{materialTotal} @ Static;
        billboards |> List.forEach(putBillboardRow(list, next, valueCursor));
        discard List.foldLeft(putMaterialRow(list, next, ctx), None, blended);
        list

    /// ビルボード b の絵（全体の登録の絵。見つからなければ None）。
    def textureOfBillboard(ctx: Context, b: BillboardDraw): Option[Scene3dRenderer.RegisteredTexture] \ IO = (ctx#naming#source#textureOf)(b#fields#texture)

    def isDrawnBillboard(bt: (BillboardDraw, Option[Scene3dRenderer.RegisteredTexture])): Bool =
        let (b, texture) = bt;
        not b#culled and Option.nonEmpty(texture)

    /// ビルボードの行を足す。視錐台の中で絵がある行は values の at[0] からビルボードの値を書いて at[0] を進める。
    def putBillboardRow(list: SceneList, next: Array[Int32, Static], at: Array[Int32, Static],
                        bt: (BillboardDraw, Option[Scene3dRenderer.RegisteredTexture])): Unit \ IO =
        let (b, texture) = bt;
        let row = Array.get(0, next);
        let base = row * rowStride();
        let rows = list#rows;
        Array.put(kindBillboard(), base, rows);
        Array.put(texture |> Option.map(t -> t#texId) |> Option.getWithDefault(-1), base + 1, rows);
        Array.put(if (b#culled) 0 else 1, base + 4, rows);
        Array.put(breakSlotOf(BatchBreak.Billboard), base + 5, rows);
        Array.put(-1, base + 7, rows);
        Array.put(-1, base + 8, rows);
        texture |> Option.filter(_ -> isDrawnBillboard(bt)) |> Option.forEach(t -> {
            let v = Array.get(0, at);
            Array.put(v, base + 8, rows);
            putBillboardValues(list#values, v, b#fields, t);
            Array.put(v + billboardValueFloats(), 0, at)
        });
        Array.put(row + 1, 0, next)

    /// ビルボード f の値を values の at から書く（並びは billboardValueFloats）。t = 貼る絵（uv を絵の大きさで割る）。
    def putBillboardValues(values: Array[Float32, Static], at: Int32, f: Scene3d.BillboardFields, t: Scene3dRenderer.RegisteredTexture): Unit \ IO =
        let w = Float64.max(1.0, t#width);
        let h = Float64.max(1.0, t#height);
        let tint = Texture3d.srgbToLinearColor(f#tint);
        let r = f#regionRect;
        let floats = f#position#x :: f#position#y :: f#position#z :: (if (f#lit) 1.0 else 0.0) ::
                     f#anchor#x :: f#anchor#y :: f#size#x :: f#size#y ::
                     r#position#x / w :: r#position#y / h :: r#size#x / w :: r#size#y / h ::
                     tint#r :: tint#g :: tint#b :: 0.0 :: Nil;
        floats |> List.forEachWithIndex((i, x) -> Array.put(RenderUtil.f32(x), at + i, values))

    /// 材質の batch ごとの値の並びの元（描く物の無い batch は None で、値を書かない）。
    def layoutPairsOf(ctx: Context, ds: List[MaterialBatch[MeshBatch]]): List[(MaterialBatch[MeshBatch], Option[MaterialValues.Layout])] \ IO =
        ds |> List.map(d -> (d, if (d#batch#count > 0) Some(MaterialValues.layoutOf(ctx#layouts, d#material)) else None))

    /// 影の地図の pass の行（骨の無い物 plain → 骨つきの物 skinned の順。どれも分かれた理由は影の pass）。形の番号は ctx の表で振る。
    pub def buildShadowList(ctx: Context, plain: List[MeshBatch], skinned: List[MeshBatch]): SceneList \ IO =
        let count = List.length(plain) + List.length(skinned);
        let list = { rows = Array.repeat(Static, Int32.max(1, count * rowStride()), 0), heads = Array.empty(Static, count),
                     materials = Array.empty(Static, 0), firstMaterial = count, firstBillboard = count, firstBlended = count, billboards = Array.empty(Static, 0), count = count,
                     values = Array.repeat(Static, 1, 0.0f32), reads = Array.repeat(Static, 1, 0) };
        let next = Array#{0, 0, 0} @ Static;
        plain |> List.forEach(b -> putShapeRow(list, next, ctx, kindVertexColor(), BatchBreak.ShadowPass, b));
        skinned |> List.forEach(b -> putShapeRow(list, next, ctx, kindSkinned(), BatchBreak.ShadowPass, b));
        list

    def putShapeRow(list: SceneList, next: Array[Int32, Static], ctx: Context, kind: Int32, why: BatchBreak, b: MeshBatch): Unit \ IO =
        putRow(list, next, ctx, kind, (0, 0), b, breakSlotOf(why), 0)

    /// d の行を足し、前に描いた材質の batch を返す（描く物の無い batch は前の物を替えない）。layout = d の値の並びの元（描く物の無い batch は None で、値を書かない）。
    /// next = [次の行, 次の値の位置, 次の絵の組]。
    def putMaterialRow(list: SceneList, next: Array[Int32, Static], ctx: Context, previous: Option[MaterialBatch[MeshBatch]],
                       dl: (MaterialBatch[MeshBatch], Option[MaterialValues.Layout])): Option[MaterialBatch[MeshBatch]] \ IO =
        let (d, layout) = dl;
        let drawn = d#batch#count > 0;
        let why = if (drawn) batchBreakOf(previous, d) else BatchBreak.Material;
        let same = if (drawn and Option.exists(p -> isSameBinding(p, d), previous)) flagSameBinding() else 0;
        let row = Array.get(0, next);
        Array.put(d#material, row - list#firstMaterial, list#materials);
        putRow(list, next, ctx, kindMaterial(), (d#handle, d#order), d#batch, breakSlotOf(why), flagsOf(d) + same);
        layout |> Option.forEach(l -> putMaterialValues(list, next, ctx, row, d, l));
        if (drawn) Some(d) else previous

    /// 材質の行 row の値と絵の組を書き、欄 8〜10 に位置を入れる。
    def putMaterialValues(list: SceneList, next: Array[Int32, Static], ctx: Context, row: Int32, d: MaterialBatch[MeshBatch], layout: MaterialValues.Layout): Unit \ IO =
        let at = Array.get(1, next);
        let readAt = Array.get(2, next);
        let readCount = MaterialValues.readCountOf(layout, d#kind);
        MaterialValues.put(ctx#naming, layout, d, ctx#time, list#values, at, list#reads, readAt * MaterialValues.readStride());
        let base = row * rowStride();
        Array.put(at, base + 8, list#rows);
        Array.put(readAt, base + 9, list#rows);
        Array.put(readCount, base + 10, list#rows);
        Array.put(at + MaterialValues.valueSizeOf(layout), 1, next);
        Array.put(readAt + readCount, 2, next)

    /// b を a の後に、プログラムと値と絵を付け直さずに描けるか（lightmap は物ごとに絵が違うので付け直す）。
    def isSameBinding(a: MaterialBatch[MeshBatch], b: MaterialBatch[MeshBatch]): Bool =
        not b#kind#lightmap and isSameMaterial(a, b) and a#material#cutout == b#material#cutout and a#material#wrap == b#material#wrap
            and normalMapKeyOf(a#material) == normalMapKeyOf(b#material) and textureReadsOf(a#material) == textureReadsOf(b#material)

    def normalMapKeyOf(m: Scene3d.MaterialFields): Option[(String, Float64)] = m#normalMap |> Option.map(n -> (n#texture, n#strength))

    /// 材質の絵の組（名前と補間。補間は sampler を決める）。
    def textureReadsOf(m: Scene3d.MaterialFields): List[(String, ShaderDoc.FilterMode)] =
        ShaderDoc.materialTexReads(m#spec, m#emission, m#metallicRoughnessShade)

    def putRow(list: SceneList, next: Array[Int32, Static], ctx: Context, kind: Int32, material: (Int32, Int32), b: MeshBatch, why: Int32,
               flags: Int32): Unit \ IO =
        let row = Array.get(0, next);
        let rows = list#rows;
        let at = row * rowStride();
        let (handle, order) = material;
        Array.put(kind, at, rows);
        Array.put(handle, at + 1, rows);
        Array.put(order, at + 2, rows);
        Array.put(b#first, at + 3, rows);
        Array.put(b#count, at + 4, rows);
        Array.put(why, at + 5, rows);
        Array.put(flags, at + 6, rows);
        Array.put(MeshTable.numberOf(ctx#meshes, ctx#naming#gen, b#head#fields#mesh), at + 7, rows);
        Array.put(-1, at + 8, rows);
        Array.put(b#head, row, list#heads);
        Array.put(row + 1, 0, next)

    def flagsOf(d: MaterialBatch[MeshBatch]): Int32 =
        let bit = (on, value) -> if (on) value else 0;
        bit(d#material#doubleSided, flagDoubleSided()) + bit(d#kind#coverage, flagCoverage()) + bit(d#kind#normalMap, flagNormalMap()) + bit(d#kind#lightmap, flagLightmap())

    /// 材質の batch d が 1 つの draw call に分かれた理由（優先の順は FrameDiagnostics.Scene3dBatchBreaks）。previous = 同じ並びで前に描いた batch。
    /// 形が前と違って材質が同じ時だけ Mesh（形も材質も同じで分かれたのは、材質の絵の組が違う時）。
    def batchBreakOf(previous: Option[MaterialBatch[MeshBatch]], d: MaterialBatch[MeshBatch]): BatchBreak =
        if (d#material#blend) BatchBreak.Transparent
        else if (d#kind#lightmap) BatchBreak.Lightmap
        else if (isSkinned(d#batch#head)) BatchBreak.Skinned
        else if (Option.exists(p -> isSameMaterial(p, d) and not isSameMesh(p, d), previous)) BatchBreak.Mesh
        else BatchBreak.Material

    /// 順の番号・材質の木の鍵・params が同じか。
    def isSameMaterial(a: MaterialBatch[MeshBatch], b: MaterialBatch[MeshBatch]): Bool =
        a#order == b#order
            and force a#material#shaderHash == force b#material#shaderHash
            and a#material#params == b#material#params

    def isSameMesh(a: MaterialBatch[MeshBatch], b: MaterialBatch[MeshBatch]): Bool =
        Mesh3d.contentHash(a#batch#head#fields#mesh) == Mesh3d.contentHash(b#batch#head#fields#mesh)
}
