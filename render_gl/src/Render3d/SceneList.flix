// Render3d.SceneList — 3D の場面 1 つの不透明の batch を描く行の列（RenderList の 3D の分。計画の側が作り、GL の backend は Render3d.GlRows が流す）。
// 1 行 = 形 1 つの集まりを 1 回の instanced draw で描く（頂点の色の物・骨つきの物・不透明の材質の物）。半透明・ビルボード・空・影の地図は行にしない。
// rows は 1 行 rowStride() 個: 0=種類（kind*） 1=材質の表の番号（MaterialBatch#handle。頂点の色と骨つきは 0） 2=材質の順の番号（MaterialBatch#order。同じく 0）
//   3=1 体ごとの値の先頭 4=描く物の数（0 なら描かず、形と絵を今のコマで使った物として数えるだけ） 5=1 つの draw call に分かれた理由（Render3d.Counts.breakSlotOf）
//   6=フラグ（flag*: 両面・alpha to coverage・法線マップ・前の材質の行と同じ付け方）。行の順が描く順（頂点の色 → 骨つき → 材質を順の番号で）。
// heads は行ごとの頭の物（形・lightmap・タンジェントを読む）・materials は行ごとの材質（頂点の色と骨つきの行は None）。
// WhyNot: 行ごとに MeshBatch の record を backend へ渡さない — backend 2 つが分かれ目に読む欄（種類・材質・範囲・理由・フラグ）を、GL の側で引き直さずに同じ物を読む。
// WhyNot: 材質の絵の組と draw ごとの値（uParamN・cutout）を行へ移さない — 並びは ShaderGen が決め、WebGPU の backend に材質を足す時に一緒に決める。それまで materials から引く。
mod Render3d.SceneList {
    use Render3d.{MeshDraw, isSkinned}
    use Render3d.Batch.{MaterialBatch, MeshBatch}
    use Render3d.Counts.{BatchBreak, breakSlotOf}
    use Render3d.ScenePlan.{SceneDraws}

    pub type alias SceneList = { rows = Array[Int32, Static], heads = Vector[MeshDraw], materials = Vector[Option[Scene3d.MaterialFields]] }

    /// 行の種類。
    pub def kindVertexColor(): Int32 = 1
    pub def kindSkinned(): Int32 = 2
    pub def kindMaterial(): Int32 = 3

    /// フラグの bit。
    pub def flagDoubleSided(): Int32 = 1
    pub def flagCoverage(): Int32 = 2
    pub def flagNormalMap(): Int32 = 4
    /// 前に描いた材質の行と同じプログラム・値・絵で描く（backend は付け直さずに draw だけ出してよい）。
    pub def flagSameBinding(): Int32 = 8

    def rowStride(): Int32 = 7

    pub def rowCountOf(list: SceneList): Int32 = Vector.length(list#heads)

    /// 行 row の欄 col（並びはこのファイルの頭のコメント）。
    pub def rowAt(list: SceneList, row: Int32, col: Int32): Int32 \ IO = Array.get(row * rowStride() + col, list#rows)

    pub def headAt(list: SceneList, row: Int32): MeshDraw = Vector.get(row, list#heads)

    pub def materialAt(list: SceneList, row: Int32): Option[Scene3d.MaterialFields] = Vector.get(row, list#materials)

    /// 行 row のフラグに flag が立っているか。
    pub def hasFlag(list: SceneList, row: Int32, flag: Int32): Bool \ IO = Int32.bitwiseAnd(rowAt(list, row, 6), flag) != 0

    /// 場面の不透明の batch を描く順の行にする（半透明の blended は入れない）。
    pub def buildSceneList(draws: SceneDraws[MeshBatch]): SceneList \ IO =
        let count = List.length(draws#plain) + List.length(draws#skinned) + List.length(draws#opaque);
        let rows = Array.repeat(Static, Int32.max(1, count * rowStride()), 0);
        let next = Array#{0} @ Static;
        draws#plain |> List.forEach(b -> putShapeRow(rows, next, kindVertexColor(), BatchBreak.Mesh, b));
        draws#skinned |> List.forEach(b -> putShapeRow(rows, next, kindSkinned(), BatchBreak.Skinned, b));
        discard draws#opaque |> List.foldLeft(putMaterialRow(rows, next), None);
        let materials = (List.map(_ -> None, draws#plain) ::: List.map(_ -> None, draws#skinned)) ::: List.map(d -> Some(d#material), draws#opaque);
        let heads = (List.map(b -> b#head, draws#plain) ::: List.map(b -> b#head, draws#skinned)) ::: List.map(d -> d#batch#head, draws#opaque);
        { rows = rows, heads = List.toVector(heads), materials = List.toVector(materials) }

    def putShapeRow(rows: Array[Int32, Static], next: Array[Int32, Static], kind: Int32, why: BatchBreak, b: MeshBatch): Unit \ IO =
        putRow(rows, next, kind, (0, 0), b, breakSlotOf(why), 0)

    /// d の行を足し、前に描いた材質の batch を返す（描く物の無い batch は前の物を替えない）。
    def putMaterialRow(rows: Array[Int32, Static], next: Array[Int32, Static], previous: Option[MaterialBatch[MeshBatch]],
                       d: MaterialBatch[MeshBatch]): Option[MaterialBatch[MeshBatch]] \ IO =
        let drawn = d#batch#count > 0;
        let why = if (drawn) batchBreakOf(previous, d) else BatchBreak.Material;
        let same = if (drawn and Option.exists(p -> isSameBinding(p, d), previous)) flagSameBinding() else 0;
        putRow(rows, next, kindMaterial(), (d#handle, d#order), d#batch, breakSlotOf(why), flagsOf(d) + same);
        if (drawn) Some(d) else previous

    /// b を a の後に、プログラムと値と絵を付け直さずに描けるか（lightmap は物ごとに絵が違うので付け直す）。
    def isSameBinding(a: MaterialBatch[MeshBatch], b: MaterialBatch[MeshBatch]): Bool =
        not b#kind#lightmap and isSameMaterial(a, b) and a#material#cutout == b#material#cutout and a#material#wrap == b#material#wrap
            and normalMapKeyOf(a#material) == normalMapKeyOf(b#material) and textureNamesOf(a#material) == textureNamesOf(b#material)

    def normalMapKeyOf(m: Scene3d.MaterialFields): Option[(String, Float64)] = m#normalMap |> Option.map(n -> (n#texture, n#strength))

    def textureNamesOf(m: Scene3d.MaterialFields): List[String] =
        ShaderDoc.materialTexReads(m#spec, m#emission, m#metallicRoughnessShade) |> List.map(fst)

    def putRow(rows: Array[Int32, Static], next: Array[Int32, Static], kind: Int32, material: (Int32, Int32), b: MeshBatch, why: Int32, flags: Int32): Unit \ IO =
        let row = Array.get(0, next);
        let at = row * rowStride();
        let (handle, order) = material;
        Array.put(kind, at, rows);
        Array.put(handle, at + 1, rows);
        Array.put(order, at + 2, rows);
        Array.put(b#first, at + 3, rows);
        Array.put(b#count, at + 4, rows);
        Array.put(why, at + 5, rows);
        Array.put(flags, at + 6, rows);
        Array.put(row + 1, 0, next)

    def flagsOf(d: MaterialBatch[MeshBatch]): Int32 =
        let bit = (on, value) -> if (on) value else 0;
        bit(d#material#doubleSided, flagDoubleSided()) + bit(d#kind#coverage, flagCoverage()) + bit(d#kind#normalMap, flagNormalMap())

    /// 材質の batch d が 1 つの draw call に分かれた理由（優先の順は FrameDiagnostics.Scene3dBatchBreaks）。previous = 同じ並びで前に描いた batch。
    /// 形が前と違って材質が同じ時だけ Mesh（形も材質も同じで分かれたのは、材質の絵の組が違う時）。
    pub def batchBreakOf(previous: Option[MaterialBatch[MeshBatch]], d: MaterialBatch[MeshBatch]): BatchBreak =
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
