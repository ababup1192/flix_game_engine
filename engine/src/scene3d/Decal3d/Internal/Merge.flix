// Decal3d.Internal.Merge — 的ごとに切った板を、(的, 材質) ごとに world の座標の 1 つの形へつなぐ。

/// デカールの列を的の列に貼る本体。ゲームは呼ばない（Decal3d.buildInstances）。
pub mod Decal3d.Internal.Merge {

    use Decal3d.Internal.Clip

    /// 前もって求めておくデカールの値（切る決まり・板の材質・材質の鍵・箱の world の AABB）。
    type alias PreparedDecal = { rule = Clip.ClipSettings, material = Scene3d.Material3d, key = String, bounds = Mesh3d.Bounds }

    /// 貼った板の置いた物の列と、飛ばした的の知らせ（1 的 1 行）。
    pub def build(decals: List[Decal3d.Decal], targets: List[Scene3d.Instance3d]): (List[Scene3d.Instance3d], List[String]) =
        let prepared = List.map(prepare, decals);
        let perTarget = List.map(t -> placeOnTarget(prepared, Scene3d.instanceFieldsOf(t)), targets);
        (List.flatMap(fst, perTarget), List.filterMap(snd, perTarget))

    /// blend も cutout も偽の材質は半透明にする（不透明の板は下の面と同じ深さで奥行きを奪い合う）。
    def prepare(d: Decal3d.Decal): PreparedDecal =
        let given = Scene3d.materialFieldsOf(d#material);
        let material = if (given#blend or given#cutout) d#material else Scene3d.withAlphaBlend(true, d#material);
        let rule = Clip.settingsOf(d);
        { rule = rule, material = material, key = Scene3d.Internal.MaterialKey.fullMaterialKeyOf(Scene3d.materialFieldsOf(material)),
          bounds = Clip.boundsOf(rule#box) }

    def placeOnTarget(ds: List[PreparedDecal], f: Scene3d.InstanceFields): (List[Scene3d.Instance3d], Option[String]) =
        match skipReasonOf(f) {
            case Some(reason) => (Nil, skipWarningOf(ds, f, reason))
            case None         => (bindBoundsOf(f) |> Option.map(tb -> instancesOn(ds, f, tb)) |> Option.getWithDefault(Nil), None)
        }

    /// 貼らない的の知らせの鍵と、その言い方。
    def skipReasonOf(f: Scene3d.InstanceFields): Option[(String, String)] =
        if (Option.nonEmpty(f#pose) or Option.nonEmpty(Mesh3d.skinJoints(f#mesh))) Some(("decal-skinned-target", "骨つきの的"))
        else if (Scene3d.isBlendedFields(f)) Some(("decal-blended-target", "半透明の的"))
        else None

    /// 箱が的のバインドポーズの境界に掛かる時だけ言う（弾が骨つきの物の近くを通っただけでは黙る）。
    def skipWarningOf(ds: List[PreparedDecal], f: Scene3d.InstanceFields, reason: (String, String)): Option[String] =
        let (tag, what) = reason;
        let name = if (f#name == "") "(名前なし)" else f#name;
        bindBoundsOf(f)
            |> Option.filter(tb -> List.exists(d -> Clip.overlaps(d#bounds, tb), ds))
            |> Option.map(_ -> "@${tag} decal3d: ${what} ${name} には貼らない — 飛ばす")

    /// 的の形の境界を world で写した AABB（骨つきは曲げる前の形で。頂点の無い形は None）。
    def bindBoundsOf(f: Scene3d.InstanceFields): Option[Mesh3d.Bounds] =
        if (Mesh3d.vertexCount(f#mesh) == 0) None
        else Some(Mesh3d.bounds(f#mesh) |> Mesh3d.cornersOf |> List.map(Mat4.apply(f#world)) |> Mesh3d.boundsOfPoints)

    /// 的 1 つに貼った板（材質の初めて出た順・形の中はデカールの列の順）。
    def instancesOn(ds: List[PreparedDecal], f: Scene3d.InstanceFields, tb: Mesh3d.Bounds): List[Scene3d.Instance3d] =
        let hits = List.filter(d -> Clip.overlaps(d#bounds, tb), ds);
        if (List.isEmpty(hits)) Nil else instancesOfHits(hits, f)

    def instancesOfHits(hits: List[PreparedDecal], f: Scene3d.InstanceFields): List[Scene3d.Instance3d] =
        let target = Clip.targetOf(f);
        let pieces = hits
            |> List.map(d -> (d, Clip.clipTarget(d#rule, d#bounds, target)))
            |> List.filter(match (_, polys) -> not List.isEmpty(polys));
        let groups = groupByKey(pieces);
        let count = List.length(groups);
        groups |> List.mapWithIndex((k, g) -> {
            let (material, polys) = g;
            instanceOf(f, nameOf(f#name, count, k), material, polys)
        })

    /// 材質の鍵ごとに多角形を集める（鍵の初めて出た順・鍵の中は pieces の順）。
    def groupByKey(pieces: List[(PreparedDecal, List[List[Clip.Vertex]])]): List[(Scene3d.Material3d, List[List[Clip.Vertex]])] =
        let step = (acc, piece) -> {
            let (order, chunks) = acc;
            let (d, polys) = piece;
            let seen = Map.memberOf(d#key, chunks);
            let nextOrder = if (seen) order else (d#key, d#material) :: order;
            (nextOrder, Map.insertWith((fresh, old) -> fresh ::: old, d#key, polys :: Nil, chunks))
        };
        let (orderRev, chunks) = List.foldLeft(step, (Nil, Map.empty()), pieces);
        List.reverse(orderRev) |> List.map(match (key, material) ->
            (material, Map.getWithDefault(key, Nil, chunks) |> List.reverse |> List.flatten))

    def nameOf(target: String, count: Int32, k: Int32): String =
        let base = if (target == "") "decal" else "${target}:decal";
        if (count >= 2) "${base}${k + 1}" else base

    def instanceOf(f: Scene3d.InstanceFields, name: String, material: Scene3d.Material3d, polys: List[List[Clip.Vertex]]): Scene3d.Instance3d =
        let lightmap = Scene3d.lightmapOfFields(f) |> Option.filter(_ -> Option.nonEmpty(Mesh3d.uvs2(f#mesh)));
        let placed = Scene3d.meshInstance(meshOrBug(Option.nonEmpty(lightmap), polys), Mat4.identity())
            |> Scene3d.withMaterial(material)
            |> Scene3d.withTint(f#tint)
            |> Scene3d.withName(name);
        // WhyNot: 的の矩形のまま付けない — 矩形は uv2 へ先に掛けてあり、もう 1 度掛けると atlas の別の場所を読む。
        lightmap |> Option.map(lm -> Scene3d.withLightmap({ uvRect = Scene3d.Internal.LightmapRect.whole() | lm }, placed))
                 |> Option.getWithDefault(placed)

    /// 多角形の列から形を作る（多角形ごとに頂点 0 を要に扇に割る・巻き方は多角形のまま）。
    def meshOrBug(withUv2: Bool, polys: List[List[Clip.Vertex]]): Mesh3d.Mesh3d =
        let verts = List.flatten(polys) |> List.toVector;
        let positions = verts |> Vector.flatMap(v -> Vector#{v#position#x, v#position#y, v#position#z});
        let normals = verts |> Vector.flatMap(v -> Vector#{v#normal#x, v#normal#y, v#normal#z});
        let colors = verts |> Vector.flatMap(v -> Vector#{v#color#x, v#color#y, v#color#z});
        let uvs = verts |> Vector.flatMap(v -> Vector#{v#uv#x, v#uv#y});
        let (_, indexChunks) = List.foldLeft((acc, poly) -> {
            let (base, out) = acc;
            let size = List.length(poly);
            let fan = Vector.range(1, size - 1) |> Vector.flatMap(i -> Vector#{base, base + i, base + i + 1});
            (base + size, fan :: out)
        }, (0, Nil), polys);
        let indices = List.reverse(indexChunks) |> List.toVector |> Vector.flatten;
        let built = Mesh3d.fromArrays({ positions = positions, normals = normals, colors = colors, indices = indices, skin = None })
            |> Result.flatMap(Mesh3d.withUvs(uvs))
            |> Result.flatMap(m -> if (withUv2) Mesh3d.withUvs2(verts |> Vector.flatMap(v -> Vector#{v#uv2#x, v#uv2#y}), m) else Ok(m));
        match built {
            case Ok(m)  => m
            case Err(e) => bug!("Decal3d.buildInstances: 切った頂点から作る形の数が食い違う — ${e}")
        }
}
