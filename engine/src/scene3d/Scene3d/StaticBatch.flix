// Scene3d.StaticBatch — 3D の場面（Scene3d）の部品。動かない物の集まり（Scene3d.staticGroup）の中で 1 回しか使わない形を、world を頂点へ掛けておいて 1 つの形につなぐ（static batching）。
// 2 回以上使う形は描き手の instancing（同じ形・同じ材質を 1 回の draw）のまま残す。
// つなぐ単位: 材質の無い物は 1 つ（tint は頂点の色へ掛けておいて白に・uv は捨てる）・材質のある物は uv の有無・材質の値・tint ごと（tint は置いた物に残す）。
// WhyNot: 絵つきの材質の tint を頂点の色へ掛けておかない — 絵つきの材質は「絵 × 頂点の色」を sRGB の値で掛けてから線形に直して tint を掛けるので、
//   掛けておくと曲線をまたいで色が変わる（測った差は画素の 1 割・8 bit で 7〜9 段）。材質の無い物は頂点の色と tint を別々に線形に直して掛けるので掛けておいても同じ。

/// 動かない物の集まりを描き手（GL・WebGPU）がつなぐための材料。CPU の描き手はつながない（同じ絵の答え合わせの相手）。ゲームは呼ばない。
pub mod Scene3d.StaticBatch {

    /// つなぐ計画の 1 つ。Single = そのまま描く物・Combine = 1 つの形につなぐ物（2 つ以上・来た順）。
    pub enum PlanEntry {
        case Single(Scene3d.Instance3d)
        case Combine(List[Scene3d.Instance3d])
    }

    /// 置いた物 1 つの鍵（keysOf）。shape = 形の中身の鍵（1 回しか使わないかを数える）・unit = つなぐ単位の鍵（つながない物は None）。
    pub type alias ItemKeys = { shape = String, unit = Option[String] }

    /// つないだ 1 つの形の頂点の数の上限（超える分は次の形へ分ける）。
    // WhyNot: 鍵 1 つを上限なしで 1 つの形にしない — 描き手は 1 つの形を 1 コマの中で作るので、大きな集まりほど 1 コマが長く止まる。
    def maxVertices(): Int32 = 8192

    /// i をつないでよいか: lightmap・骨の重み・法線マップの無い物。
    // WhyNot: 法線マップの材質をつながない — glb のタンジェントはつなぐと捨てることになり、三角形から求め直すと軸ごとに違う scale の物でずれる。
    // WhyNot: 骨の重みのある形をつながない — 姿勢を渡せば曲がる形で、集まりに入れても姿勢を付け替えるゲームがある。
    pub def isCombinable(i: Scene3d.Instance3d): Bool =
        let f = Scene3d.instanceFieldsOf(i);
        Option.isEmpty(Scene3d.lightmapOf(i)) and Option.isEmpty(Scene3d.skinningOf(i)) and Option.isEmpty(Mesh3d.skinJoints(f#mesh))
            and not Scene3d.isBlendedFields(f)
            and not (f#material |> Option.exists(m -> Option.nonEmpty(Scene3d.materialFieldsOf(m)#normalMap)))

    /// i の鍵（形の中身の鍵を初めて読む形は、ここで SHA-256 を取る。描き手は 1 つずつ前もって取る）。
    pub def keysOf(i: Scene3d.Instance3d): ItemKeys =
        { shape = Mesh3d.contentHash(Scene3d.instanceFieldsOf(i)#mesh), unit = if (isCombinable(i)) Some(unitKeyOf(i)) else None }

    /// items（持ち越す物・来た順）をつなぐ計画（planFromKeys に keysOf の鍵を渡す形）。
    pub def planOf(items: List[Scene3d.Instance3d]): Vector[PlanEntry] =
        let all = List.toVector(items);
        planFromKeys(Vector.map(keysOf, all), all)

    /// items をつなぐ計画。keys = items と同じ並びの keysOf の鍵。1 回しか使わない形でつないでよい物を、
    /// つなぐ単位ごとに Combine へまとめ（頂点の数の上限で分ける）、頭の物の場所に置く。ほかの物と、単位に 1 つしか無い物は Single で元の場所に置く。
    pub def planFromKeys(keys: Vector[ItemKeys], items: Vector[Scene3d.Instance3d]): Vector[PlanEntry] = region rc {
        let counts = Vector.foldLeft((acc, k) -> Map.insertWith((a, b) -> a + b, k#shape, 1, acc), Map.empty(), keys);
        let chunks: MutList[(List[Scene3d.Instance3d], Int32), rc] = MutList.empty(rc);
        let open: MutMap[String, Int32, rc] = MutMap.empty(rc);
        let slots: MutList[Slot, rc] = MutList.empty(rc);
        Vector.zip(keys, items) |> Vector.forEach(match (k, i) -> placeOne(chunks, open, slots, onceUnitOf(counts, k), i));
        MutList.toList(slots) |> List.toVector |> Vector.map(slot -> entryOf(chunks, slot))
    }

    /// i を、つなぐ単位 unit があればその形へ、無ければそのまま描く物として slots に置く。
    def placeOne(chunks: MutList[(List[Scene3d.Instance3d], Int32), r], open: MutMap[String, Int32, r], slots: MutList[Slot, r],
                 unit: Option[String], i: Scene3d.Instance3d): Unit \ r = match unit {
        case Some(u) => addToChunk(chunks, open, slots, u, i)
        case None    => MutList.push(Slot.Keep(i), slots)
    }

    /// k の形を 1 回しか使わず、つないでよい物なら、その単位の鍵。
    def onceUnitOf(counts: Map[String, Int32], k: ItemKeys): Option[String] =
        if (Map.getWithDefault(k#shape, 0, counts) == 1) k#unit else None

    /// 計画の作りかけの 1 つ。Keep = そのまま描く物・Chunk = つなぐ形の番号（その形の頭の物の場所に置く）。
    enum Slot {
        case Keep(Scene3d.Instance3d)
        case Chunk(Int32)
    }

    /// i を単位 unit の開いている形へ足す（頂点の数が上限を超えるなら新しい形を開き、その頭として slots に置く）。
    def addToChunk(chunks: MutList[(List[Scene3d.Instance3d], Int32), r], open: MutMap[String, Int32, r], slots: MutList[Slot, r],
                   unit: String, i: Scene3d.Instance3d): Unit \ r =
        let verts = Mesh3d.vertexCount(Scene3d.instanceFieldsOf(i)#mesh);
        let fits = (at: Int32) -> {
            let (_, n) = MutList.get(at, chunks);
            n + verts <= maxVertices()
        };
        match MutMap.get(unit, open) |> Option.filter(fits) {
            case Some(at) =>
                let (members, n) = MutList.get(at, chunks);
                MutList.put((i :: members, n + verts), at, chunks)
            case None =>
                let at = MutList.length(chunks);
                MutList.push((i :: Nil, verts), chunks);
                MutMap.put(unit, at, open);
                MutList.push(Slot.Chunk(at), slots)
        }

    def entryOf(chunks: MutList[(List[Scene3d.Instance3d], Int32), r], slot: Slot): PlanEntry \ r = match slot {
        case Slot.Keep(i)   => PlanEntry.Single(i)
        case Slot.Chunk(at) => entryOfMembers(List.reverse(fst(MutList.get(at, chunks))))
    }

    def entryOfMembers(members: List[Scene3d.Instance3d]): PlanEntry = match members {
        case i :: Nil => PlanEntry.Single(i)
        case _        => PlanEntry.Combine(members)
    }

    /// 計画の 1 つの描く物（Combine はここでつなぐ）。
    pub def instanceOf(e: PlanEntry): Scene3d.Instance3d = match e {
        case PlanEntry.Single(i)     => i
        case PlanEntry.Combine(list) => combine(list)
    }

    /// items をつないだ物（planOf の並びのまま instanceOf を当てる。1 回で全部作る形）。
    pub def combineAll(items: List[Scene3d.Instance3d]): List[Scene3d.Instance3d] =
        planOf(items) |> Vector.map(instanceOf) |> Vector.toList

    /// つなぐ単位の鍵（材質の無い物は 1 つ・材質のある物は uv の有無・材質の値・tint）。
    // WhyNot: 材質の無い物を uv の有無で分けない — 頂点の色で描く道は uv を読まず、描き手の batch も uv で分けない。
    def unitKeyOf(i: Scene3d.Instance3d): String =
        let f = Scene3d.instanceFieldsOf(i);
        let uv = if (Option.nonEmpty(Mesh3d.uvs(f#mesh))) "uv" else "-";
        match f#material {
            case None    => "plain"
            case Some(m) => "mat|${uv}|${materialKeyOf(Scene3d.materialFieldsOf(m))}|${f#tint#r},${f#tint#g},${f#tint#b}"
        }

    /// 材質の値の鍵（描き手の batch の鍵と、絵の名前と、emissionIntensity）。
    // WhyNot: 木を比べて同じ材質か確かめない — 描き手の batch も shaderHash で同じ木と見なしていて、つないだ形はその batch の頭の木で描かれる。
    def materialKeyOf(m: Scene3d.MaterialFields): String =
        let wrap = if (m#wrap == Scene3d.Wrap.Clamp) "clamp" else "repeat";
        let reads = Scene3d.materialTexReadsOf(m) |> List.map(match (name, filter) -> "${name}:${filter}") |> String.intercalate(",");
        let params = Map.toList(m#params) |> List.map(match (k, v) -> "${k}=${v}") |> String.intercalate(",");
        "${force m#shaderHash}|${wrap}|${m#cutout}|${m#doubleSided}|${m#emissionIntensity}|${m#maxMipLevels}|${reads}|${params}"


    /// group（同じ単位の物・2 つ以上）を 1 つの形につないで置いた物。world は単位行列。
    /// 材質の無い物は tint を頂点の色へ掛けておき（線形の量で掛けて sRGB の値へ戻す）、置いた物の tint は白。材質のある物は頂点の色のまま、頭の物の材質と tint を付ける。
    /// uv は材質のある物で、全部の物にある時だけ付ける。中身の鍵は元の形の鍵と world（材質の無い物は tint も）から作る。
    pub def combine(group: List[Scene3d.Instance3d]): Scene3d.Instance3d =
        let fs = List.map(Scene3d.instanceFieldsOf, group);
        let head = List.head(fs);
        let material = head |> Option.flatMap(f -> f#material);
        let bakeTint = Option.isEmpty(material);
        let mesh = combinedMesh(bakeTint, fs);
        let placed = Scene3d.meshInstance(mesh, Mat4.identity());
        match (material, head) {
            case (Some(m), Some(f)) => placed |> Scene3d.withMaterial(m) |> Scene3d.withTint(f#tint)
            case _                  => placed
        }

    def combinedMesh(bakeTint: Bool, fs: List[Scene3d.InstanceFields]): Mesh3d.Mesh3d =
        let vertexTotal = List.sumWith(f -> Mesh3d.vertexCount(f#mesh), fs);
        let indexTotal = List.sumWith(f -> Vector.length(Mesh3d.indices(f#mesh)), fs);
        let allUv = not bakeTint and List.forAll(f -> Option.nonEmpty(Mesh3d.uvs(f#mesh)), fs);
        let arrays: Arrays = region rc {
            let out: Out[rc] = { positions = Array.empty(rc, vertexTotal * 3), normals = Array.empty(rc, vertexTotal * 3), colors = Array.empty(rc, vertexTotal * 3),
                        uvs = Array.empty(rc, if (allUv) vertexTotal * 2 else 0), indices = Array.empty(rc, indexTotal) };
            discard List.foldLeft((cursor, f) -> writeOne(bakeTint, allUv, out, cursor, f), (0, 0), fs);
            { positions = Array.toVector(out#positions), normals = Array.toVector(out#normals), colors = Array.toVector(out#colors),
              uvs = Array.toVector(out#uvs), indices = Array.toVector(out#indices) }
        };
        let base = meshOrBug(arrays);
        let withUv = if (allUv) uvsOrBug(arrays#uvs, base) else base;
        Mesh3d.withContentKey(contentKeyOf(bakeTint, fs), withUv)

    /// 元の形の頂点を写しただけの並びから作るので、数と番号の範囲は食い違わない（食い違えば作る所の誤り）。
    def meshOrBug(arrays: Arrays): Mesh3d.Mesh3d =
        match Mesh3d.fromArrays({ positions = arrays#positions, normals = arrays#normals, colors = arrays#colors, indices = arrays#indices, skin = None }) {
            case Ok(m)  => m
            case Err(e) => bug!("Scene3d.StaticBatch.combine: ${e}")
        }

    def uvsOrBug(uvs: Vector[Float64], m: Mesh3d.Mesh3d): Mesh3d.Mesh3d = match Mesh3d.withUvs(uvs, m) {
        case Ok(withUv) => withUv
        case Err(e)     => bug!("Scene3d.StaticBatch.combine: ${e}")
    }

    /// つないだ形の中身の鍵の元: 物ごとの (元の形の鍵, world の 16 の値, 掛けた tint)。
    // WhyNot: つないだ頂点から SHA-256 を取らない — 頂点の数だけ数を辿り、集まりの作り直しのたびに 1 コマが延びる。元の形の鍵と world で中身は決まる。
    def contentKeyOf(bakeTint: Bool, fs: List[Scene3d.InstanceFields]): String =
        let one = (f: Scene3d.InstanceFields) -> {
            let world = Mat4.asRows(f#world) |> Vector.map(x -> "${x}") |> Vector.join(",");
            let tint = if (bakeTint) "${f#tint#r},${f#tint#g},${f#tint#b}" else "";
            "${Mesh3d.contentHash(f#mesh)}/${world}/${tint}"
        };
        "static-batch|" + (List.map(one, fs) |> String.intercalate(";"))

    type alias Arrays = { positions = Vector[Float64], normals = Vector[Float64], colors = Vector[Float64], uvs = Vector[Float64], indices = Vector[Int32] }

    type alias Out[r: Region] = { positions = Array[Float64, r], normals = Array[Float64, r], colors = Array[Float64, r], uvs = Array[Float64, r], indices = Array[Int32, r] }

    /// f の頂点を world で写して out の cursor（頂点の頭, 番号の頭）から書き、次の cursor を返す。
    // WhyNot: Mat4.apply と Vec3 で頂点ごとに写さない — 頂点ごとに record を 2 つ作り、集まりの全部の頂点（十数万）で初めて描くコマが倍に延びる。
    def writeOne(bakeTint: Bool, allUv: Bool, out: Out[r], cursor: (Int32, Int32), f: Scene3d.InstanceFields): (Int32, Int32) \ r =
        let (vBase, iBase) = cursor;
        let p = Mesh3d.positions(f#mesh);
        let n = Mesh3d.normals(f#mesh);
        let c = Mesh3d.colors(f#mesh);
        let count = Vector.length(p) / 3;
        let w = Mat4.asRows(f#world);
        let nm = Mat4.asRows(Mat4.normalMatrix(f#world));
        let t = Texture3d.srgbToLinearColor(f#tint);
        foreach (k <- Vector.range(0, count)) {
            let o = (vBase + k) * 3;
            let (px, py, pz) = (Vector.get(k * 3, p), Vector.get(k * 3 + 1, p), Vector.get(k * 3 + 2, p));
            Array.put(rowDot(w, 0, px, py, pz) + Vector.get(3, w), o, out#positions);
            Array.put(rowDot(w, 1, px, py, pz) + Vector.get(7, w), o + 1, out#positions);
            Array.put(rowDot(w, 2, px, py, pz) + Vector.get(11, w), o + 2, out#positions);
            let (nx, ny, nz) = (Vector.get(k * 3, n), Vector.get(k * 3 + 1, n), Vector.get(k * 3 + 2, n));
            let (wx, wy, wz) = (rowDot(nm, 0, nx, ny, nz), rowDot(nm, 1, nx, ny, nz), rowDot(nm, 2, nx, ny, nz));
            let len = Num.sqrt(wx * wx + wy * wy + wz * wz);
            let inv = if (len < 1.0e-12) 0.0 else 1.0 / len;
            Array.put(wx * inv, o, out#normals); Array.put(wy * inv, o + 1, out#normals); Array.put(wz * inv, o + 2, out#normals);
            Array.put(tinted(bakeTint, Vector.get(k * 3, c), t#r), o, out#colors);
            Array.put(tinted(bakeTint, Vector.get(k * 3 + 1, c), t#g), o + 1, out#colors);
            Array.put(tinted(bakeTint, Vector.get(k * 3 + 2, c), t#b), o + 2, out#colors)
        };
        if (allUv) {
            let u = Mesh3d.uvs(f#mesh) |> Option.getWithDefault(Vector.empty());
            foreach (k <- Vector.range(0, count * 2)) Array.put(Vector.get(k, u), vBase * 2 + k, out#uvs)
        } else ();
        let ix = Mesh3d.indices(f#mesh);
        foreach (k <- Vector.range(0, Vector.length(ix))) Array.put(Vector.get(k, ix) + vBase, iBase + k, out#indices);
        (vBase + count, iBase + Vector.length(ix))

    /// 行優先の行列 m の row 行の左 3 列と (x, y, z) の内積。
    def rowDot(m: Vector[Float64], row: Int32, x: Float64, y: Float64, z: Float64): Float64 =
        Vector.get(row * 4, m) * x + Vector.get(row * 4 + 1, m) * y + Vector.get(row * 4 + 2, m) * z

    /// 頂点の色の 1 成分 v に線形の tint の成分 tl を掛けた値（掛けない時と tl が 1 の時は v のまま）。
    def tinted(bakeTint: Bool, v: Float64, tl: Float64): Float64 =
        if (not bakeTint or tl == 1.0) v else Texture3d.linearToSrgb(Texture3d.srgbToLinear(v) * tl)
}
