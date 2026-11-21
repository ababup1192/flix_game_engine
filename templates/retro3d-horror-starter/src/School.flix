// School — 配置の表（Layout）と読み込んだ形から、歩く当たり判定の箱と、階ごとの動かない物の集まりを 1 回だけ組む（純粋）。
//
// 当たり判定: 表の colliders に、階段の坂（向きのある箱）・踊り場・坂の間の仕切りと上の階の手すりを足す。
// 上の階の床の板は階段の所を抜く（抜かないと坂を上る頭が上の階の床の板に当たる）。
// 絵: 階ごとに 1 つの staticGroup（建物の glb の部品・小物の glb・非常口のプレート）。仮の表（glb の無い校舎）の階は、
// 当たり判定の箱をそのまま絵の箱にする（床・腰板・漆喰・家具・天井・坂を大きさで見分けて貼る）。
// 建物の形がまだ無い階（ブラウザ版で束が届く前）は建物を描かない。
// WhyNot: 届く前の階に仮の箱を描かない — 階段の吹き抜けから覗いた上の階が、一瞬だけ別の色の箱になって見える。
mod School {
    use fge::{CollisionWorld3d, Color, Mat4, Model3d, Num, Scene3d, Sort, Texture3d, Vec3}
    use fge::CollisionShape3d
    use fge::CollisionShape3d.Box3d
    use fge::ShaderDoc.{FilterMode, Shade}
    use Layout.{Box, Floor, Stair}
    use Textures.Surface

    /// 読み込んだ形と絵。floors = 階の番号 → 建物の形（読めた階だけ）・props = 小物の名前 → 形・surfaces = コードで作った絵。
    pub type alias Assets = { floors = Map[Int32, Model3d.Model3d], props = Map[String, Model3d.Model3d], surfaces = Map[Surface, Texture3d.Texture3d] }

    /// 組んだ校舎。collision = 全部の階の箱・groups = 階の番号 → 動かない物の集まり・textures = 場面に渡す絵（同じ絵は 1 枚: 束の小物はどれも束の絵の全部を持つ）。
    pub type alias School = { collision = CollisionWorld3d.CollisionWorld3d, groups = Map[Int32, Scene3d.StaticGroup], textures = List[Texture3d.Texture3d] }

    /// 非常口のプレートの光り方（色と、線形の量の倍率）。
    pub type alias SignGlow = { color = Color, intensity = Float64 }

    /// moved = 集まりに入れない小物（毎コマ別に描く物。鍵のかかった部屋の戸）。
    pub def build(layout: Layout.Layout, assets: Assets, glow: SignGlow, moved: Layout.Prop -> Bool): School =
        let solids = solidsOf(layout);
        let materials = materialsOf(assets#surfaces, glow);
        { collision = CollisionWorld3d.build(2.0, solids |> List.flatMap(s -> s#boxes)),
          groups = layout#floors |> List.map(f -> (f#index, groupOf(layout, assets, materials, solids, moved, f))) |> List.toMap,
          textures = List.append(Map.valuesOf(assets#surfaces),
                                 List.append(Map.valuesOf(assets#floors), Map.valuesOf(assets#props)) |> List.flatMap(m -> m#textures))
              |> List.map(t -> (Texture3d.name(t), t)) |> List.toMap |> Map.valuesOf }

    // ── 当たり判定の箱 ──

    /// 階 1 つ分の固い物。walls = 表の箱（床の板は階段の所を抜いた後）・stairs = この階から上る階段の坂・踊り場・仕切り・手すり。
    type alias Solids = { floor = Int32, walls = List[Box], stairs = List[Box3d], boxes = List[Box3d] }

    def solidsOf(layout: Layout.Layout): List[Solids] =
        layout#floors |> List.map(f -> {
            let holes = layout#floors |> List.flatMap(g -> g#stairs) |> List.filter(s -> s#toFloor == f#index) |> List.flatMap(stairFootprints);
            let walls = f#colliders |> List.flatMap(b -> if (Layout.isSlab(f, b)) carveAll(holes, b) else b :: Nil);
            let stairs = f#stairs |> List.flatMap(s -> stairBoxes(layout, s));
            { floor = f#index, walls = walls, stairs = stairs, boxes = List.append(walls |> List.map(toBox3d), stairs) }
        })

    def toBox3d(b: Box): Box3d =
        CollisionShape3d.box3d(Vec3.v3((b#min#x + b#max#x) / 2.0, (b#min#y + b#max#y) / 2.0, (b#min#z + b#max#z) / 2.0),
                               Vec3.v3((b#max#x - b#min#x) / 2.0, (b#max#y - b#min#y) / 2.0, (b#max#z - b#min#z) / 2.0))

    /// 平らな四角（x と z の範囲）。
    type alias Rect = { x0 = Float64, z0 = Float64, x1 = Float64, z1 = Float64 }

    /// 上の階の床の板から抜く所: 坂を全部囲む四角と踊り場の四角（少し広げる）。踊り場の上も抜かないと、踊り場に立つ頭が上の階の床の板に当たる。
    def stairFootprints(s: Stair): List[Rect] =
        let pad = (r: Rect) -> { x0 = r#x0 - 0.05, z0 = r#z0 - 0.05, x1 = r#x1 + 0.05, z1 = r#z1 + 0.05 };
        let landingRect = match s#ramps {
            case first :: second :: _ => landingOf(first, second) |> Option.map(fst) |> Option.toList
            case _                    => Nil
        };
        (rectOf(List.flatten(s#ramps), 0.0) :: landingRect) |> List.map(pad)

    def rectOf(pts: List[Vec3.Vec3], pad: Float64): Rect =
        let xs = pts |> List.map(p -> p#x);
        let zs = pts |> List.map(p -> p#z);
        { x0 = List.minimum(xs) |> Option.getWithDefault(0.0) - pad, x1 = List.maximum(xs) |> Option.getWithDefault(0.0) + pad,
          z0 = List.minimum(zs) |> Option.getWithDefault(0.0) - pad, z1 = List.maximum(zs) |> Option.getWithDefault(0.0) + pad }

    def carveAll(holes: List[Rect], b: Box): List[Box] =
        holes |> List.foldLeft((pieces, hole) -> pieces |> List.flatMap(carve(hole)), b :: Nil)

    /// 箱から四角 h の所を抜いた残り（重ならなければそのまま・残りは最大 4 つ）。
    def carve(h: Rect, b: Box): List[Box] =
        let overlaps = h#x0 < b#max#x and h#x1 > b#min#x and h#z0 < b#max#z and h#z1 > b#min#z;
        if (not overlaps) b :: Nil
        else {
            let piece = (x0: Float64, x1: Float64, z0: Float64, z1: Float64) ->
                if (x1 - x0 > 0.01 and z1 - z0 > 0.01) { min = Vec3.v3(x0, b#min#y, z0), max = Vec3.v3(x1, b#max#y, z1) } :: Nil else Nil;
            let mx0 = Float64.max(b#min#x, h#x0);
            let mx1 = Float64.min(b#max#x, h#x1);
            List.flatten(piece(b#min#x, mx0, b#min#z, b#max#z) :: piece(mx1, b#max#x, b#min#z, b#max#z)
                         :: piece(mx0, mx1, b#min#z, Float64.max(b#min#z, h#z0)) :: piece(mx0, mx1, Float64.min(b#max#z, h#z1), b#max#z) :: Nil)
        }

    /// 坂の板の厚さ（m）。
    def rampThickness(): Float64 = 0.25

    /// 階段 1 つの固い物: 坂ごとの板・踊り場・2 本の坂の間の仕切り・上の階の床の穴の手すり。
    def stairBoxes(layout: Layout.Layout, s: Stair): List[Box3d] =
        let topY = Layout.floorAt(s#toFloor, layout) |> Option.map(f -> f#y)
            |> Option.getWithDefault(List.flatten(s#ramps) |> List.map(p -> p#y) |> List.maximum |> Option.getWithDefault(0.0));
        let bottomY = Layout.floorAt(s#fromFloor, layout) |> Option.map(f -> f#y) |> Option.getWithDefault(0.0);
        let ramps = s#ramps |> List.filterMap(rampBox);
        // 上の階から同じ所で次の階段が上り始めるなら、手すりを置かない（置くと次の坂の上り口を塞ぐ）。
        let continues = (first: List[Vec3.Vec3]) -> layout#floors |> List.flatMap(f -> f#stairs) |> List.filter(n -> n#fromFloor == s#toFloor)
            |> List.exists(n -> List.head(n#ramps) |> Option.exists(r -> overlaps(rectOf(lowEdge(first), 0.3), rectOf(lowEdge(r), 0.3))));
        let rail = (first: List[Vec3.Vec3]) -> if (continues(first)) Nil else railing(first, topY);
        let extras = match s#ramps {
            case first :: second :: _ => List.flatten(landing(first, second) :: divider(first, second, bottomY, topY) :: rail(first) :: Nil)
            case first :: Nil         => rail(first)
            case Nil                  => Nil
        };
        List.append(ramps, extras)

    /// 坂の 4 隅を低い 2 つと高い 2 つに分ける（低い方の 1 つ目・2 つ目、それに向き合う高い方）。
    def edgesOf(corners: List[Vec3.Vec3]): Option[(Vec3.Vec3, Vec3.Vec3, Vec3.Vec3, Vec3.Vec3)] =
        let sorted = corners |> Sort.sortStableBy(p -> p#y);
        match sorted {
            case a :: b :: c :: d :: Nil =>
                let flat = (p: Vec3.Vec3, q: Vec3.Vec3) -> (p#x - q#x) * (p#x - q#x) + (p#z - q#z) * (p#z - q#z);
                if (flat(a, c) <= flat(a, d)) Some((a, b, c, d)) else Some((a, b, d, c))
            case _ => None
        }

    /// 坂の低い端の 2 隅。
    def lowEdge(corners: List[Vec3.Vec3]): List[Vec3.Vec3] =
        edgesOf(corners) |> Option.map(e -> { let (p0, p1, _, _) = e; p0 :: p1 :: Nil }) |> Option.getWithDefault(Nil)

    def overlaps(a: Rect, b: Rect): Bool = a#x0 < b#x1 and b#x0 < a#x1 and a#z0 < b#z1 and b#z0 < a#z1

    /// 坂 1 本を、上の面が 4 隅を通る向きのある板にする。
    def rampBox(corners: List[Vec3.Vec3]): Option[Box3d] =
        edgesOf(corners) |> Option.flatMap(e -> {
            let (p0, p1, p3, _) = e;
            let u = Vec3.sub(p1, p0);
            let v = Vec3.sub(p3, p0);
            let ax = Vec3.normalized(u);
            let along = Vec3.sub(v, Vec3.mul(ax, Vec3.dot(v, ax)));
            let az = Vec3.normalized(along);
            let n0 = Vec3.cross(ax, az);
            let ay = if (n0#y < 0.0) Vec3.mul(n0, -1.0) else n0;
            let top = Vec3.mul(corners |> List.foldLeft(Vec3.add, Vec3.zero()), 0.25);
            let t = rampThickness();
            if (Vec3.length(u) < 0.01 or Vec3.length(along) < 0.01) None
            else Some({ center = Vec3.sub(top, Vec3.mul(ay, t / 2.0)), ax = ax, ay = ay, az = az,
                        half = Vec3.v3(Vec3.length(u) / 2.0, t / 2.0, Vec3.length(along) / 2.0 + 0.05) })
        })

    /// 踊り場: 1 本目の坂の高い端と 2 本目の坂の低い端を囲み、上る向きへ 1.2 m 延ばした板。
    def landing(first: List[Vec3.Vec3], second: List[Vec3.Vec3]): List[Box3d] =
        landingOf(first, second) |> Option.map(e -> {
            let (r, h) = e;
            toBox3d({ min = Vec3.v3(r#x0, h - rampThickness(), r#z0), max = Vec3.v3(r#x1, h, r#z1) })
        }) |> Option.toList

    /// 踊り場の四角と高さ。
    def landingOf(first: List[Vec3.Vec3], second: List[Vec3.Vec3]): Option[(Rect, Float64)] =
        match (edgesOf(first), edgesOf(second)) {
            case (Some((a0, a1, a3, a2)), Some((b0, b1, _, _))) =>
                let h = (a2#y + a3#y) / 2.0;
                let r = rectOf(a2 :: a3 :: b0 :: b1 :: Nil, 0.0);
                let dx = (a2#x + a3#x) / 2.0 - (a0#x + a1#x) / 2.0;
                let dz = (a2#z + a3#z) / 2.0 - (a0#z + a1#z) / 2.0;
                let reach = 1.2;
                let grown =
                    if (Float64.abs(dz) >= Float64.abs(dx))
                        (if (dz > 0.0) { z1 = r#z1 + reach | r } else { z0 = r#z0 - reach | r })
                    else (if (dx > 0.0) { x1 = r#x1 + reach | r } else { x0 = r#x0 - reach | r });
                Some((grown, h))
            case _ => None
        }

    /// 2 本の坂の間の仕切り（横に並んだ坂の隙間を、下の階の床から上の階の床の 1 m 上まで塞ぐ）。
    def divider(first: List[Vec3.Vec3], second: List[Vec3.Vec3], bottomY: Float64, topY: Float64): List[Box3d] =
        let a = rectOf(first, 0.0);
        let b = rectOf(second, 0.0);
        let z0 = Float64.max(a#z0, b#z0);
        let z1 = Float64.min(a#z1, b#z1);
        let x0 = Float64.min(a#x1, b#x1);
        let x1 = Float64.max(a#x0, b#x0);
        if (x1 - x0 < 0.01 or z1 - z0 < 0.5) Nil
        else toBox3d({ min = Vec3.v3(x0, bottomY, z0), max = Vec3.v3(x1, topY + 1.0, z1) }) :: Nil

    /// 上の階の床の穴の縁の手すり（1 本目の坂の低い端の真上）。上の階の廊下から穴へ落ちない。
    def railing(first: List[Vec3.Vec3], topY: Float64): List[Box3d] =
        edgesOf(first) |> Option.map(e -> {
            let (p0, p1, _, _) = e;
            let r = rectOf(p0 :: p1 :: Nil, 0.05);
            toBox3d({ min = Vec3.v3(r#x0, topY, r#z0), max = Vec3.v3(r#x1, topY + 1.0, r#z1) })
        }) |> Option.toList

    // ── 絵 ──

    def materialsOf(surfaces: Map[Surface, Texture3d.Texture3d], glow: SignGlow): Map[Surface, Scene3d.Material3d] =
        surfaces |> Map.mapWithKey((k, t) -> {
            let m = Scene3d.texturedMaterial(Texture3d.name(t), FilterMode.Nearest);
            if (k == Surface.ExitSign) m |> Scene3d.withEmission(Shade.Solid(glow#color)) |> Scene3d.withEmissionIntensity(glow#intensity)
            else m
        })

    def groupOf(layout: Layout.Layout, assets: Assets, materials: Map[Surface, Scene3d.Material3d], solids: List[Solids], moved: Layout.Prop -> Bool, f: Floor): Scene3d.StaticGroup =
        let tag = "f${Int32.toString(f#index)}";
        let building = match Map.get(f#index, assets#floors) {
            case Some(model) => Model3d.partInstances(Mat4.identity(), model)
            case None        => if (layout#placeholder) placeholderOf(materials, solids, f) else Nil
        };
        let props = layout#props |> List.filter(p -> p#floor == f#index and not moved(p))
            |> List.flatMap(p -> Map.get(p#prop, assets#props) |> Option.map(m -> Model3d.partInstances(propMatrix(p), m) |> List.map(Scene3d.withTint(p#shade))) |> Option.getWithDefault(Nil));
        let signs = layout#lights |> List.filter(l -> l#floor == f#index and l#kind == Layout.LightKind.ExitGreen)
            |> List.filterMap(l -> exitSignOf(materials, l#pos));
        let keyed = (name: String, items: List[Scene3d.Instance3d]) -> items |> List.mapWithIndex((i, it) -> ("${tag}:${name}:${Int32.toString(i)}", it));
        Scene3d.staticGroup(tag, List.flatten(keyed("building", building) :: keyed("prop", props) :: keyed("exit", signs) :: Nil))

    /// 小物を置く行列。Blender の書き出しは Blender の Z まわりに −yaw 回して置く（glTF の +Y まわりに −yaw）。
    /// X を反転した engine の座標では回る向きが逆になるので +yaw。
    def propMatrix(p: Layout.Prop): Mat4.Mat4 = matrixAt(p#pos, p#yaw)

    /// 小物と同じ回りで pos に yaw 向けて置く行列。
    pub def matrixAt(pos: Vec3.Vec3, yaw: Float64): Mat4.Mat4 = Mat4.mul(Mat4.translate(pos), Mat4.rotateY(yaw))

    /// 非常口のプレート（灯りの少し下に吊る、光る板）。
    def exitSignOf(materials: Map[Surface, Scene3d.Material3d], at: Vec3.Vec3): Option[Scene3d.Instance3d] =
        forM (
            m <- Map.get(Surface.ExitSign, materials);
            mesh <- Blocks.meshOf(Blocks.boxFaces({ tileU = 0.4, tileV = 0.2 }, Vec3.v3(at#x - 0.2, at#y - 0.25, at#z - 0.02), Vec3.v3(at#x + 0.2, at#y - 0.05, at#z + 0.02)))
        ) yield Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(m) |> Scene3d.withName("exit sign")

    /// 仮の建物: 階の箱を大きさで見分けて材質ごとに 1 つの形にまとめる。天井は床の板を 3 m 上げた板・坂は階段の板。
    def placeholderOf(materials: Map[Surface, Scene3d.Material3d], solids: List[Solids], f: Floor): List[Scene3d.Instance3d] =
        let mine = solids |> List.find(s -> s#floor == f#index);
        let walls = mine |> Option.map(s -> s#walls) |> Option.getWithDefault(Nil);
        let stairs = mine |> Option.map(s -> s#stairs) |> Option.getWithDefault(Nil);
        let faces = (s: Surface, b: Box) -> Blocks.boxFaces(tilingOf(s), b#min, b#max) |> List.map(face -> (s, face));
        let wallFaces = walls |> List.flatMap(b -> faces(surfaceOf(f, b), b));
        let ceilings = walls |> List.filter(Layout.isSlab(f)) |> List.flatMap(b ->
            faces(Surface.Ceiling, { min = Vec3.v3(b#min#x, f#y + 3.0, b#min#z), max = Vec3.v3(b#max#x, f#y + 3.1, b#max#z) }));
        let stairFaces = stairs |> List.flatMap(b -> Blocks.orientedFaces(tilingOf(Surface.Stairs), b) |> List.map(face -> (Surface.Stairs, face)));
        let all = List.flatten(wallFaces :: ceilings :: stairFaces :: Nil);
        Textures.surfaces() |> List.filterMap(s -> forM (
            m <- Map.get(s, materials);
            mesh <- Blocks.meshOf(all |> List.filter(e -> fst(e) == s) |> List.map(snd))
        ) yield Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(m) |> Scene3d.withName("${s}"))

    /// 仮の建物の箱の材質: 床の板・薄く高い壁（下 1 m までなら腰板・それより上は漆喰）・それ以外は家具。
    def surfaceOf(f: Floor, b: Box): Surface =
        let dx = b#max#x - b#min#x;
        let dz = b#max#z - b#min#z;
        let h = b#max#y - b#min#y;
        if (Layout.isSlab(f, b)) Surface.FloorWood
        else if (h >= 0.85 and Float64.min(dx, dz) <= 0.3 and Float64.max(dx, dz) >= 0.9)
            (if (b#max#y <= f#y + 1.05) Surface.Wainscot else Surface.Plaster)
        else if (Float64.min(dx, dz) <= 0.3 and h > 0.3) Surface.Plaster
        else Surface.Furniture

    /// 絵 1 枚が覆う長さ（腰板は横 2 m・縦 1 m）。
    def tilingOf(s: Surface): Blocks.Tiling = match s {
        case Surface.Wainscot  => { tileU = 2.0, tileV = 1.0 }
        case Surface.Furniture => { tileU = 1.0, tileV = 1.0 }
        case Surface.Stairs    => { tileU = 1.0, tileV = 1.0 }
        case _                 => { tileU = 2.0, tileV = 2.0 }
    }

    // ── 描く階（毎コマ引く） ──

    /// 描く階の番号: 今の階と、階段室の近く（坂と踊り場の四角から stairReach m の内）にいる間だけ、その階段がつなぐ上下の階。
    /// 床と天井で上下の階は見えないので、階段室の吹き抜けから覗ける所でだけ描く（スマホで 3 階分を描かない）。
    pub def visibleFloors(layout: Layout.Layout, feet: Vec3.Vec3): List[Int32] =
        let here = Layout.floorIndexAt(feet#y, layout);
        let near = (r: Rect) -> feet#x > r#x0 - stairReach() and feet#x < r#x1 + stairReach() and feet#z > r#z0 - stairReach() and feet#z < r#z1 + stairReach();
        let linked = layout#floors |> List.flatMap(f -> f#stairs)
            |> List.filter(s -> (s#fromFloor == here or s#toFloor == here) and List.exists(near, stairFootprints(s)))
            |> List.flatMap(s -> s#fromFloor :: s#toFloor :: Nil);
        (here :: linked) |> List.distinct

    /// 上下の階を描き始める、階段室からの距離（m）。
    def stairReach(): Float64 = 4.0
}
