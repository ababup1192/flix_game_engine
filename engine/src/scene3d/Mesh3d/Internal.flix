// Mesh3d.Internal — 確かめ済みの形の中身を並びで取り出す口と、その並びから確かめずに作り直す口（メインの外で解いた glb を組み直す所）。

/// Mesh3d の中身。ゲームからは呼ばない。
pub mod Mesh3d.Internal {

    /// 形 1 つの中身。tangents = 外で求めたタンジェント（None なら uv から求める・uv の無い形は None）・
    /// low・high = 頂点の最小と最大・maxJoint = 重みのジョイントの番号の最大。
    pub type alias TrustedArrays = { positions = Vector[Float64], normals = Vector[Float64], colors = Vector[Float64], indices = Vector[Int32],
                                     skin = Option[Mesh3d.SkinWeights], uvs = Option[Vector[Float64]], tangents = Option[Vector[Float64]],
                                     uvs2 = Option[Vector[Float64]], low = Vec3.Vec3, high = Vec3.Vec3, maxJoint = Option[Int32] }

    /// m の中身。givenTangents = タンジェントを withTangents で付けた形か（偽なら tangents は None で、タンジェントを求めない。組み直す側が uv から求める）。
    pub def trustedPartsOf(givenTangents: Bool, m: Mesh3d.Mesh3d): TrustedArrays =
        let r = Mesh3d.recOf(m);
        let v = r#vertices;
        { positions = v#positions, normals = v#normals, colors = v#colors, indices = r#indices, skin = v#skin,
          uvs = v#uvSet |> Option.map(set -> set#uvs),
          tangents = if (givenTangents) v#uvSet |> Option.map(set -> force set#tangents) else None,
          uvs2 = v#uvs2, low = r#low, high = r#high, maxJoint = r#maxJoint }

    /// trustedPartsOf の逆。fromArrays → withUvs → withTangents → withUvs2 で作った形と、中身も中身の鍵も同じ形になる。
    // WhyNot: fromArrays を通さない — 範囲の確かめと bounds を求め直す分がメインのスレッドに残り、頂点の多い束で 4 倍の絞りの 40 ms を超える。
    pub def fromTrusted(a: TrustedArrays): Mesh3d.Mesh3d =
        let base = lazy Mesh3d.arraysHashOf(a#positions, a#normals, a#colors, a#indices, a#skin);
        let uvSet = a#uvs |> Option.map(uv -> match a#tangents {
            case Some(t) => { uvs = uv, tangents = lazy t }
            case None    => { uvs = uv, tangents = lazy Mesh3d.computeTangents(a#positions, a#normals, uv, a#indices) }
        });
        Mesh3d.Mesh3dData.Mesh3dData({
            vertices = { positions = a#positions, normals = a#normals, colors = a#colors, skin = a#skin, uvSet = uvSet, uvs2 = a#uvs2 },
            indices = a#indices,
            hash = Mesh3d.lazySurfaceHash(base, uvSet, a#uvs2),
            baseHash = base,
            low = a#low,
            high = a#high,
            maxJoint = a#maxJoint
        })

    /// parts をつないだ形（uv なし）。Gltf の meshOfParts が全部の primitive から作る形と同じ中身になる
    /// （parts はどれも同じ skinned で作った物・頂点の番号は 3 の倍数ずつ）。
    pub def concatTrusted(skinned: Bool, parts: List[TrustedArrays]): Mesh3d.Mesh3d =
        let joints = concatOf(p -> p#skin |> Option.map(sw -> sw#joints) |> Option.getWithDefault(Vector.empty()), parts);
        let skin = if (skinned) Some({ joints = joints, weights = concatOf(p -> p#skin |> Option.map(sw -> sw#weights) |> Option.getWithDefault(Vector.empty()), parts) }) else None;
        let filled = parts |> List.filter(p -> Vector.length(p#positions) > 0);
        let low = filled |> List.map(p -> p#low) |> List.reduceLeft((a, b) -> Vec3.v3(Float64.min(a#x, b#x), Float64.min(a#y, b#y), Float64.min(a#z, b#z)));
        let high = filled |> List.map(p -> p#high) |> List.reduceLeft((a, b) -> Vec3.v3(Float64.max(a#x, b#x), Float64.max(a#y, b#y), Float64.max(a#z, b#z)));
        fromTrusted({ positions = concatOf(p -> p#positions, parts), normals = concatOf(p -> p#normals, parts), colors = concatOf(p -> p#colors, parts),
                      indices = concatIndices(parts), skin = skin,
                      uvs = None, tangents = None, uvs2 = None,
                      low = Option.getWithDefault(Vec3.zero(), low), high = Option.getWithDefault(Vec3.zero(), high),
                      maxJoint = Option.map(_ -> Vector.foldLeft(Int32.max, 0, joints), skin) })

    /// parts の f の並びをつないだ物。
    // WhyNot: Vector.flatten でつながない — 1 つずつ写した後に Vector へもう 1 回写すので、頂点 5 万の束で 4 倍の絞りの 10 ms を超える。
    def concatOf(f: TrustedArrays -> Vector[t], parts: List[TrustedArrays]): Vector[t] = region rc {
        let total = List.foldLeft((acc, p) -> acc + Vector.length(f(p)), 0, parts);
        let out = Array.empty(rc, total);
        discard List.foldLeft((at, p) -> {
            let v = f(p);
            let src: Array[t, rc] = unchecked_cast(v as Array[t, rc]);
            Array.copyInto(srcPos = 0, dstPos = at, len = Vector.length(v), src = src, out);
            at + Vector.length(v)
        }, 0, parts);
        unchecked_cast(out as Vector[t])
    }

    /// parts の頂点の番号を、前の parts の頂点の数だけずらしてつないだ物。
    def concatIndices(parts: List[TrustedArrays]): Vector[Int32] = region rc {
        let total = List.foldLeft((acc, p) -> acc + Vector.length(p#indices), 0, parts);
        let out = Array.empty(rc, total);
        discard List.foldLeft((acc, p) -> {
            let (at, base) = acc;
            Vector.forEachWithIndex((i, x) -> Array.put(x + base, at + i, out), p#indices);
            (at + Vector.length(p#indices), base + Vector.length(p#positions) / 3)
        }, (0, 0), parts);
        unchecked_cast(out as Vector[Int32])
    }
}
