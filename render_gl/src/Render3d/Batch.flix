// Render3d.Batch — 3D の描き手（Render3d）の、同じ形・同じ材質の物を 1 回の instanced draw へまとめる所。GL を呼ばずに決まる。約束は Render3d.flix の頭。
// tint・emissionIntensity・world・姿勢は 1 体ごとの値（Render3d.Instancing）なので、batch を分けない。
mod Render3d.Batch {
    import java.lang.Object
    import java.util.HashMap
    import java.util.Objects
    use Render3d.{DrawMode, MaterialEntry, MeshDraw, ProgramKind, isSkinned}

    /// 1 体ごとの値の番号を振る前の batch。head = 頭の物（間引いた物のこともある。形と lightmap を読む）・draws = 描く物（間引いた物を除く・来た順）・
    /// count = 描く物の数（0 なら、形と絵を今のコマで使った物として数えるだけ）。
    pub type alias PlannedBatch = { head = MeshDraw, draws = List[MeshDraw], count = Int32 }

    /// 1 体ごとの値の番号を振った batch。first = 頭の物の番号。
    pub type alias MeshBatch = { head = MeshDraw, count = Int32, first = Int32 }

    /// 材質のある物の batch（プログラムは組めた物だけ）。material = 頭の物の材質。emissionIntensity だけは 1 体ごとに draws の物の材質から読む。
    pub type alias MaterialBatch[b] = { entry = MaterialEntry, material = Scene3d.MaterialFields, batch = b }

    /// 同じ形の中で、同じ batch へ入れてよい物の鍵。Shape = 材質の無い物（骨つきか）・Surface = 材質のある物。
    /// 材質の絵の名前は鍵に入れない（読むのに材質の木を辿るので、groupByTextures で batch の中を分ける）。
    pub enum BatchKey with Eq, Order {
        case Shape(Bool)
        case Surface(SurfaceKey)
    }

    /// プログラムの版（kindBits）・木の鍵（MaterialFields#shaderHash）・wrap が Clamp か・cutout・params・法線マップの (絵の名前, 強さ)。
    // WhyNot: 同じ shaderHash の木を比べて確かめない — 比べるのは物の数だけ木を辿る手間で、batch の分だけ材質の解決を減らした意味が消える。64 ビットの鍵の衝突は、batch の頭の木で描く絵の誤りになるだけで止まらない。
    pub type alias SurfaceKey = (Int32, Int64, Bool, Bool, Map[String, Float64], Option[(String, Float64)])

    /// 置いた物 d の鍵（batch にしない物は None）。surface = 描く材質とプログラムの版（無ければ頂点の色で描く）。
    /// DrawMode.OneByOne は全部の物を batch にしない。
    // WhyNot: 半透明を batch にしない — 物ごとに遠い順に描く。lightmap つきは物ごとに絵が違う。
    pub def batchKeyOf(mode: DrawMode, d: MeshDraw, surface: Option[(Scene3d.MaterialFields, ProgramKind)]): Option[BatchKey] =
        match surface {
            case _ if mode == DrawMode.OneByOne              => None
            case None                                        => Some(BatchKey.Shape(isSkinned(d)))
            case Some((m, kind)) if m#blend or kind#lightmap => None
            case Some((m, kind))                             =>
                Some(BatchKey.Surface((kindBits(kind), force m#shaderHash, m#wrap == Scene3d.Wrap.Clamp, m#cutout, m#params,
                                       m#normalMap |> Option.map(n -> (n#texture, n#strength)))))
        }

    /// 鍵に入るプログラムの版（lightmap と blend は batch にしないので入らない）。
    def kindBits(kind: ProgramKind): Int32 =
        let bit = (on, value) -> if (on) value else 0;
        bit(kind#skinned, 1) + bit(kind#uv, 2) + bit(kind#normalMap, 4) + bit(kind#doubleSided, 8) + bit(kind#coverage, 16)

    /// xs を同じ bucketOf の字で同じ keyOf の物ごとにまとめる。keyOf が None の物は 1 体の batch。batch の中は来た順・batch どうしは頭の物が来た順。bucketOf = 形の鍵の字。
    // WhyNot: 鍵を Flix の Map だけで引かない — batch にならない物の多い場面で、物ごとに木の節を作り直す代金が prepare に出る。形の鍵の字は Java の String で hashCode を覚えている。
    pub def groupInOrder(bucketOf: a -> String, keyOf: a -> Option[k], xs: List[a]): List[List[a]] \ IO with Order[k] =
        let buckets: HashMap[String, Object] = new HashMap();
        let cells = xs |> List.foldLeft((order, x) -> match keyOf(x) {
            case None      => Ref.fresh(Static, x :: Nil) :: order
            case Some(key) => addToCell(bucketIn(buckets, bucketOf(x)), key, x, order)
        }, Nil);
        cells |> List.foldLeft((groups, cell) -> List.reverse(Ref.get(cell)) :: groups, Nil)

    /// 字 name の鍵の表（無ければ空の表を置いて返す）。
    def bucketIn(buckets: HashMap[String, Object], name: String): Ref[Map[k, Ref[List[a], Static]], Static] \ IO =
        let found = buckets.get(name);
        if (Objects.isNull(found)) {
            let made: Ref[Map[k, Ref[List[a], Static]], Static] = Ref.fresh(Static, Map.empty());
            discard buckets.put(name, unchecked_cast(made as Object));
            made
        } else unchecked_cast(found as Ref[Map[k, Ref[List[a], Static]], Static])

    /// x を held の key の batch へ足す。新しい batch なら order の頭へ足した並びを返す。
    def addToCell(held: Ref[Map[k, Ref[List[a], Static]], Static], key: k, x: a, order: List[Ref[List[a], Static]]): List[Ref[List[a], Static]] \ IO with Order[k] =
        match Map.get(key, Ref.get(held)) {
            case Some(cell) =>
                Ref.put(x :: Ref.get(cell), cell);
                order
            case None =>
                let cell = Ref.fresh(Static, x :: Nil);
                Ref.put(Map.insert(key, cell, Ref.get(held)), held);
                cell :: order
        }

    /// 同じ鍵の xs を、材質の絵の名前の並びが同じ物ごとにまとめる（材質の無い物は 1 つの batch）。材質の木が同じ 1 つの値なら木を辿らない。
    pub def groupByTextures(materialOf: a -> Option[Scene3d.MaterialFields], xs: List[a]): List[List[a]] \ IO =
        match xs {
            case Nil      => Nil
            case _ :: Nil => xs :: Nil
            case x :: _   =>
                let first = materialOf(x);
                if (List.forAll(y -> hasSameTree(first, materialOf(y)), xs)) xs :: Nil
                else groupInOrder(_ -> "", y -> Some(textureNamesOf(materialOf(y))), xs)
        }

    def hasSameTree(a: Option[Scene3d.MaterialFields], b: Option[Scene3d.MaterialFields]): Bool = match (a, b) {
        case (Some(x), Some(y)) => ShaderGen.isSameSpec(x#spec, y#spec) and ShaderGen.isSameEmission(x#emission, y#emission)
        case (None, None)       => true
        case _                  => false
    }

    def textureNamesOf(material: Option[Scene3d.MaterialFields]): List[String] =
        material |> Option.toList |> List.flatMap(m -> ShaderDoc.materialTexReads(m#spec, m#emission) |> List.map(fst))

    /// members（来た順）の batch。間引いた物は描かない。
    pub def batchOf(head: MeshDraw, members: List[MeshDraw]): PlannedBatch =
        let visible = List.filter(d -> not d#culled, members);
        { head = head, draws = visible, count = List.length(visible) }

    /// 材質の無い物の batch（形と骨つきかで分ける）。影の地図の道が使う。
    pub def shapeBatches(mode: DrawMode, draws: List[MeshDraw]): List[PlannedBatch] \ IO =
        groupInOrder(d -> Mesh3d.contentHash(d#fields#mesh), d -> batchKeyOf(mode, d, None), draws)
            |> List.filterMap(members -> List.head(members) |> Option.map(head -> batchOf(head, members)))
}
