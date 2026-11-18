// Faces — 町の面（四角）を材質ごとに集めて Mesh3d にする。
// 四角は地図の座標で書く: (x = 東, y = 北, z = 上)・外から見て反時計回り・uv の v は絵の上へ増える。
// Mesh3d へ写す時に (x, 上, 北) へ入れ替え、巡りを逆にし（engine は外から見て時計回りが表）、v を 1 − v にする（engine の v は絵の下へ増える）。
mod Faces {
    use fge::{Mesh3d, Num, Vec3}

    /// 地図の座標の点（x = 東・y = 北・z = 上。m）。
    pub type alias P3 = { x = Float64, y = Float64, z = Float64 }

    /// 線形の色（掛け目）。
    pub type alias Rgb = { r = Float64, g = Float64, b = Float64 }

    /// 四角 1 枚。material = 材質の名前（TileMap3d.materialTable の鍵）・ao = 頂点ごとの暗さ（1 で明るいまま）。
    pub type alias Quad = { points = List[P3], uvs = List[(Float64, Float64)], ao = List[Float64], material = String }

    pub def p3(x: Float64, y: Float64, z: Float64): P3 = { x = x, y = y, z = z }

    pub def white(): Rgb = { r = 1.0, g = 1.0, b = 1.0 }

    /// 四角を作る（ao は 4 つ・渡さない所は 1）。
    pub def quad(material: String, points: List[P3], uvs: List[(Float64, Float64)], ao: List[Float64]): Quad =
        { points = points, uvs = uvs, ao = if (List.length(ao) == List.length(points)) ao else List.map(_ -> 1.0, points), material = material }

    /// 0..1 の uv を貼る四角（面ごとに絵 1 枚）。
    pub def fullUv(): List[(Float64, Float64)] = (0.0, 0.0) :: (1.0, 0.0) :: (1.0, 1.0) :: (0.0, 1.0) :: Nil

    /// 線形の値を画面の値（sRGB）へ戻す。engine の頂点の色は画面の値で書き、描き手が線形へ戻して掛ける。
    pub def linearToSrgb(v: Float64): Float64 =
        let c = Num.clamp(0.0, 1.0, v);
        if (c <= 0.0031308) c * 12.92 else 1.055 * Float64.pow(base = c, 1.0 / 2.4) - 0.055

    /// 同じ材質の四角の列を 1 つの形にする。tint = 材質の色の掛け目（線形）。四角は AO の値で対角線を選んで 2 枚の三角形に割る。
    pub def toMesh(tint: Rgb, quads: List[Quad]): Result[String, Mesh3d.Mesh3d] =
        let flipped = quads |> List.map(engineCorners);
        let positions = flipped |> List.flatMap(cs -> cs |> List.flatMap(c -> c#p#x :: c#p#z :: c#p#y :: Nil)) |> List.toVector;
        let normals = flipped |> List.flatMap(cs -> { let n = normalOf(cs); List.flatMap(_ -> n#x :: n#y :: n#z :: Nil, cs) }) |> List.toVector;
        let colors = flipped |> List.flatMap(cs -> cs |> List.flatMap(c ->
            linearToSrgb(tint#r * c#ao) :: linearToSrgb(tint#g * c#ao) :: linearToSrgb(tint#b * c#ao) :: Nil)) |> List.toVector;
        let uvs = flipped |> List.flatMap(cs -> cs |> List.flatMap(c -> fst(c#uv) :: 1.0 - snd(c#uv) :: Nil)) |> List.toVector;
        let indices = flipped |> List.mapWithIndex((i, cs) -> trianglesOf(i * 4, cs)) |> List.flatten |> List.toVector;
        Mesh3d.fromArrays({ positions = positions, normals = normals, colors = colors, indices = indices, skin = None })
            |> Result.flatMap(Mesh3d.withUvs(uvs))

    /// 四角を engine の座標へ写した時の面の向き（長さ 1）。
    pub def engineNormal(q: Quad): Vec3.Vec3 = normalOf(engineCorners(q))

    /// 四角を engine へ写した時の頂点の (位置, uv) の列（巡りは engine の順・v は絵の下へ増える）。
    pub def engineVertices(q: Quad): List[(Vec3.Vec3, (Float64, Float64))] =
        engineCorners(q) |> List.map(c -> (Vec3.v3(c#p#x, c#p#z, c#p#y), (fst(c#uv), 1.0 - snd(c#uv))))

    /// 頂点 1 つ（engine の巡りに並べ替えた後）。p は地図の座標のまま（Mesh3d へ書く時に軸を入れ替える）。
    type alias Corner = { p = P3, uv = (Float64, Float64), ao = Float64 }

    /// 地図の座標の反時計回り [0, 1, 2, 3] を [0, 3, 2, 1] にする（軸の入れ替えで表と裏の約束が逆になるため）。
    def engineCorners(q: Quad): List[Corner] =
        let cs = List.zip(List.zip(q#points, q#uvs), q#ao) |> List.map(t -> { let ((p, uv), a) = t; { p = p, uv = uv, ao = a } });
        match cs {
            case c0 :: rest => c0 :: List.reverse(rest)
            case Nil        => Nil
        }

    /// engine の座標の面の向き（Newell の式・長さ 1。3 点なら cross(b − a, c − a) と同じ向き）。点が重なった四角（妻壁の三角）でも残りの点で向きが決まる。
    def normalOf(cs: List[Corner]): Vec3.Vec3 =
        let ps = cs |> List.map(c -> Vec3.v3(c#p#x, c#p#z, c#p#y));
        let next = List.append(List.drop(1, ps), List.take(1, ps));
        let sum = List.zip(ps, next) |> List.foldLeft((acc, pair) -> {
            let (a, b) = pair;
            Vec3.v3(acc#x + (a#y - b#y) * (a#z + b#z), acc#y + (a#z - b#z) * (a#x + b#x), acc#z + (a#x - b#x) * (a#y + b#y))
        }, Vec3.zero());
        if (Vec3.length(sum) > 0.0) Vec3.normalized(sum) else Vec3.v3(0.0, 1.0, 0.0)

    /// 四角を 2 枚の三角形に割る番号。対角線は AO の明るい組を結ぶ側（Minecraft の頂点 AO の決まり）。
    def trianglesOf(base: Int32, cs: List[Corner]): List[Int32] =
        let ao = cs |> List.map(c -> c#ao) |> List.toVector;
        let at = (i: Int32) -> Vector.nth(i, ao) |> Option.getWithDefault(1.0);
        if (List.length(cs) != 4) List.range(1, List.length(cs) - 1) |> List.flatMap(k -> base :: base + k :: base + k + 1 :: Nil)
        else if (at(1) + at(3) > at(0) + at(2)) base + 1 :: base + 2 :: base + 3 :: base + 1 :: base + 3 :: base :: Nil
        else base :: base + 1 :: base + 2 :: base :: base + 2 :: base + 3 :: Nil
}
