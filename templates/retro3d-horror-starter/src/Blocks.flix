// Blocks — 箱と坂を、絵を貼った形（Mesh3d）にする（純粋）。校舎の glb が届くまでの仮の建物と、
// どの階にも置く非常口のプレートが使う。絵の座標は world の長さを tile で割った物で、隣り合う箱の木目がつながる。
mod Blocks {
    use fge::{Color, Mesh3d, Vec2, Vec3}
    use fge::CollisionShape3d.Box3d

    /// 箱の面 1 枚を貼るのに要る値。tileU・tileV = 絵 1 枚が覆う長さ（m。横・縦）。
    pub type alias Tiling = { tileU = Float64, tileV = Float64 }

    def axisBox(min: Vec3.Vec3, max: Vec3.Vec3): Box3d =
        { center = Vec3.v3((min#x + max#x) / 2.0, (min#y + max#y) / 2.0, (min#z + max#z) / 2.0),
          ax = Vec3.v3(1.0, 0.0, 0.0), ay = Vec3.v3(0.0, 1.0, 0.0), az = Vec3.v3(0.0, 0.0, 1.0),
          half = Vec3.v3((max#x - min#x) / 2.0, (max#y - min#y) / 2.0, (max#z - min#z) / 2.0) }

    /// 軸にそろった箱の 6 面。
    pub def boxFaces(t: Tiling, min: Vec3.Vec3, max: Vec3.Vec3): List[Mesh3d.TexturedPolygon] =
        orientedFaces(t, axisBox(min, max))

    /// 向きのある箱の 6 面（坂の板）。縦の面の絵の縦は ay の向き、上下の面は ax と az の向き。
    pub def orientedFaces(t: Tiling, b: Box3d): List[Mesh3d.TexturedPolygon] =
        let corner = (sx: Float64, sy: Float64, sz: Float64) ->
            Vec3.add(b#center, Vec3.add(Vec3.mul(b#ax, sx * b#half#x), Vec3.add(Vec3.mul(b#ay, sy * b#half#y), Vec3.mul(b#az, sz * b#half#z))));
        // (外への向き, 面の 4 隅, 絵の横の軸, 絵の縦の軸)
        let faces =
            (b#ay, corner(-1.0, 1.0, -1.0) :: corner(1.0, 1.0, -1.0) :: corner(1.0, 1.0, 1.0) :: corner(-1.0, 1.0, 1.0) :: Nil, b#ax, b#az) ::
            (Vec3.mul(b#ay, -1.0), corner(-1.0, -1.0, -1.0) :: corner(1.0, -1.0, -1.0) :: corner(1.0, -1.0, 1.0) :: corner(-1.0, -1.0, 1.0) :: Nil, b#ax, b#az) ::
            (b#ax, corner(1.0, -1.0, -1.0) :: corner(1.0, 1.0, -1.0) :: corner(1.0, 1.0, 1.0) :: corner(1.0, -1.0, 1.0) :: Nil, b#az, b#ay) ::
            (Vec3.mul(b#ax, -1.0), corner(-1.0, -1.0, -1.0) :: corner(-1.0, 1.0, -1.0) :: corner(-1.0, 1.0, 1.0) :: corner(-1.0, -1.0, 1.0) :: Nil, b#az, b#ay) ::
            (b#az, corner(-1.0, -1.0, 1.0) :: corner(-1.0, 1.0, 1.0) :: corner(1.0, 1.0, 1.0) :: corner(1.0, -1.0, 1.0) :: Nil, b#ax, b#ay) ::
            (Vec3.mul(b#az, -1.0), corner(-1.0, -1.0, -1.0) :: corner(-1.0, 1.0, -1.0) :: corner(1.0, 1.0, -1.0) :: corner(1.0, -1.0, -1.0) :: Nil, b#ax, b#ay) :: Nil;
        faces |> List.map(f -> {
            let (outward, points, uAxis, vAxis) = f;
            let ordered = facingOut(outward, points);
            { points = ordered, uvs = ordered |> List.map(p -> uvOf(t, uAxis, vAxis, p)), color = Color.rgb(1.0, 1.0, 1.0) }
        })

    /// 絵の座標: 横は uAxis の向きの長さ・縦は vAxis の向きの長さを上が 0 になるよう反転して tile で割る。
    def uvOf(t: Tiling, uAxis: Vec3.Vec3, vAxis: Vec3.Vec3, p: Vec3.Vec3): Vec2.Vec2 =
        { x = Vec3.dot(p, uAxis) / t#tileU, y = 0.0 - Vec3.dot(p, vAxis) / t#tileV }

    /// 表の面は外から見て時計回り（engine の約束: cross(b − a, c − a) が外を向く）。逆なら並びを返す。
    def facingOut(outward: Vec3.Vec3, points: List[Vec3.Vec3]): List[Vec3.Vec3] = match points {
        case a :: b :: c :: _ =>
            if (Vec3.dot(Vec3.cross(Vec3.sub(b, a), Vec3.sub(c, a)), outward) >= 0.0) points else List.reverse(points)
        case _ => points
    }

    /// 面の列を 1 つの形にする（面が無ければ None）。
    pub def meshOf(faces: List[Mesh3d.TexturedPolygon]): Option[Mesh3d.Mesh3d] =
        if (List.isEmpty(faces)) None else Mesh3d.fromTexturedPolygons(faces) |> Result.toOption
}
