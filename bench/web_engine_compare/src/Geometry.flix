// Geometry — 比べる相手のベンチの場面が使う形（箱・球・円柱・円錐・円環・正二十面体・正八面体）を同じ頂点の並びで作る。
// 座標は比べる相手と同じ右手系・Y が上・表は外から見て反時計回り。engine の左手系へは Draw が Z を裏返して渡す。
mod Geometry {
    use fge::Num

    /// 形 1 つ。positions・normals は頂点ごとに 3 つ、uvs は 2 つ、indices は 3 つで三角 1 枚。
    pub type alias Shape = { name = String, positions = Vector[Float64], normals = Vector[Float64], uvs = Vector[Float64], indices = Vector[Int32] }

    /// 頂点 1 つ（位置・法線・uv）。
    type alias Vertex = { p = (Float64, Float64, Float64), n = (Float64, Float64, Float64), uv = (Float64, Float64) }

    def shapeOf(name: String, vertices: List[Vertex], indices: List[Int32]): Shape =
        { name = name,
          positions = vertices |> List.flatMap(v -> { let (x, y, z) = v#p; x :: y :: z :: Nil }) |> List.toVector,
          normals = vertices |> List.flatMap(v -> { let (x, y, z) = v#n; x :: y :: z :: Nil }) |> List.toVector,
          uvs = vertices |> List.flatMap(v -> { let (u, w) = v#uv; u :: w :: Nil }) |> List.toVector,
          indices = List.toVector(indices) }

    def length3(x: Float64, y: Float64, z: Float64): Float64 = Num.sqrt(x * x + y * y + z * z)

    def i2f(i: Int32): Float64 = Int32.toFloat64(i)

    /// 一辺 size の箱（面ごとに 4 頂点）。
    pub def box(size: Float64): Shape =
        let h = size / 2.0;
        let faces = ((1.0, 0.0, 0.0), (0.0, 0.0, -1.0), (0.0, 1.0, 0.0)) ::
                    ((-1.0, 0.0, 0.0), (0.0, 0.0, 1.0), (0.0, 1.0, 0.0)) ::
                    ((0.0, 1.0, 0.0), (1.0, 0.0, 0.0), (0.0, 0.0, -1.0)) ::
                    ((0.0, -1.0, 0.0), (1.0, 0.0, 0.0), (0.0, 0.0, 1.0)) ::
                    ((0.0, 0.0, 1.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)) ::
                    ((0.0, 0.0, -1.0), (-1.0, 0.0, 0.0), (0.0, 1.0, 0.0)) :: Nil;
        let corners = (-1.0, -1.0) :: (1.0, -1.0) :: (1.0, 1.0) :: (-1.0, 1.0) :: Nil;
        let vertices = faces |> List.flatMap(face -> {
            let ((nx, ny, nz), (ux, uy, uz), (vx, vy, vz)) = face;
            corners |> List.map(c -> {
                let (su, sv) = c;
                { p = (h * (nx + su * ux + sv * vx), h * (ny + su * uy + sv * vy), h * (nz + su * uz + sv * vz)),
                  n = (nx, ny, nz), uv = ((su + 1.0) / 2.0, (sv + 1.0) / 2.0) }
            })
        });
        let indices = List.range(0, 6) |> List.flatMap(f -> { let b = f * 4; b :: b + 1 :: b + 2 :: b :: b + 2 :: b + 3 :: Nil });
        shapeOf("box", vertices, indices)

    /// 半径 radius の球（経度 widthSegments・緯度 heightSegments に割る）。
    pub def sphere(radius: Float64, widthSegments: Int32, heightSegments: Int32): Shape =
        let vertices = List.range(0, heightSegments + 1) |> List.flatMap(iy -> List.range(0, widthSegments + 1) |> List.map(ix -> {
            let u = i2f(ix) / i2f(widthSegments);
            let v = i2f(iy) / i2f(heightSegments);
            let x = 0.0 - radius * Num.cos(u * Num.pi() * 2.0) * Num.sin(v * Num.pi());
            let y = radius * Num.cos(v * Num.pi());
            let z = radius * Num.sin(u * Num.pi() * 2.0) * Num.sin(v * Num.pi());
            let l = length3(x, y, z);
            let l1 = if (l == 0.0) 1.0 else l;
            { p = (x, y, z), n = (x / l1, y / l1, z / l1), uv = (u, 1.0 - v) }
        }));
        let at = (iy, ix) -> iy * (widthSegments + 1) + ix;
        let indices = List.range(0, heightSegments) |> List.flatMap(iy -> List.range(0, widthSegments) |> List.flatMap(ix -> {
            let a = at(iy, ix + 1);
            let b = at(iy, ix);
            let c = at(iy + 1, ix);
            let d = at(iy + 1, ix + 1);
            let top = if (iy != 0) a :: b :: d :: Nil else Nil;
            let bottom = if (iy != heightSegments - 1) b :: c :: d :: Nil else Nil;
            List.append(top, bottom)
        }));
        shapeOf("sphere${widthSegments}x${heightSegments}", vertices, indices)

    /// 円柱（radiusTop が 0 なら円錐）。高さ height・周りを radialSegments に割る・上と下にふた。
    pub def cylinder(dims: { radiusTop = Float64, radiusBottom = Float64, height = Float64, radialSegments = Int32 }, name: String): Shape =
        let n = dims#radialSegments;
        let halfH = dims#height / 2.0;
        let slope = (dims#radiusBottom - dims#radiusTop) / dims#height;
        let side = List.range(0, 2) |> List.flatMap(y -> {
            let radius = i2f(y) * (dims#radiusBottom - dims#radiusTop) + dims#radiusTop;
            List.range(0, n + 1) |> List.map(x -> {
                let u = i2f(x) / i2f(n);
                let theta = u * Num.pi() * 2.0;
                let s = Num.sin(theta);
                let c = Num.cos(theta);
                let l = length3(s, slope, c);
                { p = (radius * s, 0.0 - i2f(y) * dims#height + halfH, radius * c), n = (s / l, slope / l, c / l), uv = (u, 1.0 - i2f(y)) }
            })
        });
        let row = (y, x) -> y * (n + 1) + x;
        let sideIndices = List.range(0, n) |> List.flatMap(x -> {
            let a = row(0, x);
            let b = row(1, x);
            let c = row(1, x + 1);
            let d = row(0, x + 1);
            List.append(if (dims#radiusTop > 0.0) a :: b :: d :: Nil else Nil, if (dims#radiusBottom > 0.0) b :: c :: d :: Nil else Nil)
        });
        let sideCount = 2 * (n + 1);
        let topCap = if (dims#radiusTop > 0.0) Some(cap(n, halfH, dims#radiusTop, true, sideCount)) else None;
        let topCount = topCap |> Option.map(cv -> List.length(fst(cv))) |> Option.getWithDefault(0);
        let bottomCap = if (dims#radiusBottom > 0.0) Some(cap(n, halfH, dims#radiusBottom, false, sideCount + topCount)) else None;
        let caps = (topCap :: bottomCap :: Nil) |> List.filterMap(identity);
        shapeOf(name, List.append(side, caps |> List.flatMap(fst)), List.append(sideIndices, caps |> List.flatMap(snd)))

    /// 円柱のふた（中心の頂点を n 個・縁の頂点を n + 1 個）。first = ふたの最初の頂点の番号。
    def cap(n: Int32, halfH: Float64, radius: Float64, top: Bool, first: Int32): (List[Vertex], List[Int32]) =
        let sign = if (top) 1.0 else -1.0;
        let centers = List.range(0, n) |> List.map(_ -> { p = (0.0, halfH * sign, 0.0), n = (0.0, sign, 0.0), uv = (0.5, 0.5) });
        let rim = List.range(0, n + 1) |> List.map(x -> {
            let theta = i2f(x) / i2f(n) * Num.pi() * 2.0;
            let s = Num.sin(theta);
            let c = Num.cos(theta);
            { p = (radius * s, halfH * sign, radius * c), n = (0.0, sign, 0.0), uv = (c * 0.5 + 0.5, s * 0.5 * sign + 0.5) }
        });
        let rimStart = first + n;
        let indices = List.range(0, n) |> List.flatMap(x -> {
            let c = first + x;
            let i = rimStart + x;
            if (top) i :: i + 1 :: c :: Nil else i + 1 :: i :: c :: Nil
        });
        (List.append(centers, rim), indices)

    /// 円環（中心の輪の半径 radius・管の半径 tube）。
    pub def torus(dims: { radius = Float64, tube = Float64, radialSegments = Int32, tubularSegments = Int32 }): Shape =
        let rs = dims#radialSegments;
        let ts = dims#tubularSegments;
        let vertices = List.range(0, rs + 1) |> List.flatMap(j -> List.range(0, ts + 1) |> List.map(i -> {
            let u = i2f(i) / i2f(ts) * Num.pi() * 2.0;
            let v = i2f(j) / i2f(rs) * Num.pi() * 2.0;
            let x = (dims#radius + dims#tube * Num.cos(v)) * Num.cos(u);
            let y = (dims#radius + dims#tube * Num.cos(v)) * Num.sin(u);
            let z = dims#tube * Num.sin(v);
            let nx = x - dims#radius * Num.cos(u);
            let ny = y - dims#radius * Num.sin(u);
            let l = length3(nx, ny, z);
            let l1 = if (l == 0.0) 1.0 else l;
            { p = (x, y, z), n = (nx / l1, ny / l1, z / l1), uv = (i2f(i) / i2f(ts), i2f(j) / i2f(rs)) }
        }));
        let indices = List.range(1, rs + 1) |> List.flatMap(j -> List.range(1, ts + 1) |> List.flatMap(i -> {
            let a = (ts + 1) * j + i - 1;
            let b = (ts + 1) * (j - 1) + i - 1;
            let c = (ts + 1) * (j - 1) + i;
            let d = (ts + 1) * j + i;
            a :: b :: d :: b :: c :: d :: Nil
        }));
        shapeOf("torus", vertices, indices)

    /// 面ごとに平らな多面体（単位球の上の頂点と、反時計回りの面の番号から。半径 radius に広げる）。
    def polyhedron(name: String, verts: Vector[Float64], faces: List[(Int32, Int32, Int32)], radius: Float64): Shape =
        let vertexAt = i -> {
            let x = Vector.get(i * 3, verts);
            let y = Vector.get(i * 3 + 1, verts);
            let z = Vector.get(i * 3 + 2, verts);
            let l = length3(x, y, z);
            (x / l * radius, y / l * radius, z / l * radius)
        };
        let vertices = faces |> List.flatMap(f -> {
            let (ia, ib, ic) = f;
            let (ax, ay, az) = vertexAt(ia);
            let (bx, by, bz) = vertexAt(ib);
            let (cx, cy, cz) = vertexAt(ic);
            let (e1x, e1y, e1z) = (bx - ax, by - ay, bz - az);
            let (e2x, e2y, e2z) = (cx - ax, cy - ay, cz - az);
            let (nx, ny, nz) = (e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x);
            let l = length3(nx, ny, nz);
            let l1 = if (l == 0.0) 1.0 else l;
            let n = (nx / l1, ny / l1, nz / l1);
            { p = (ax, ay, az), n = n, uv = (0.0, 0.0) } :: { p = (bx, by, bz), n = n, uv = (1.0, 0.0) } :: { p = (cx, cy, cz), n = n, uv = (0.5, 1.0) } :: Nil
        });
        shapeOf(name, vertices, List.range(0, List.length(vertices)))

    def triples(xs: List[Int32]): List[(Int32, Int32, Int32)] = match xs {
        case a :: b :: c :: rest => (a, b, c) :: triples(rest)
        case _                   => Nil
    }

    pub def icosahedron(radius: Float64): Shape =
        let t = (1.0 + Num.sqrt(5.0)) / 2.0;
        let verts = Vector#{-1.0, t, 0.0, 1.0, t, 0.0, -1.0, 0.0 - t, 0.0, 1.0, 0.0 - t, 0.0, 0.0, -1.0, t, 0.0, 1.0, t, 0.0, -1.0, 0.0 - t, 0.0, 1.0, 0.0 - t,
                            t, 0.0, -1.0, t, 0.0, 1.0, 0.0 - t, 0.0, -1.0, 0.0 - t, 0.0, 1.0};
        let faces = 0 :: 11 :: 5 :: 0 :: 5 :: 1 :: 0 :: 1 :: 7 :: 0 :: 7 :: 10 :: 0 :: 10 :: 11 :: 1 :: 5 :: 9 :: 5 :: 11 :: 4 :: 11 :: 10 :: 2 :: 10 :: 7 :: 6 ::
                    7 :: 1 :: 8 :: 3 :: 9 :: 4 :: 3 :: 4 :: 2 :: 3 :: 2 :: 6 :: 3 :: 6 :: 8 :: 3 :: 8 :: 9 :: 4 :: 9 :: 5 :: 2 :: 4 :: 11 :: 6 :: 2 :: 10 ::
                    8 :: 6 :: 7 :: 9 :: 8 :: 1 :: Nil;
        polyhedron("icosahedron", verts, triples(faces), radius)

    pub def octahedron(radius: Float64): Shape =
        let verts = Vector#{1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0};
        let faces = 0 :: 2 :: 4 :: 0 :: 4 :: 3 :: 0 :: 3 :: 5 :: 0 :: 5 :: 2 :: 1 :: 2 :: 5 :: 1 :: 5 :: 3 :: 1 :: 3 :: 4 :: 1 :: 4 :: 2 :: Nil;
        polyhedron("octahedron", verts, triples(faces), radius)

    /// 物をたくさん置く場面の 8 つの形（並びは比べる相手と同じ。物の geom の番号はこの並びの番号）。
    pub def fieldShapes(): Vector[Shape] =
        Vector#{
            box(1.0),
            sphere(0.5, 24, 16),
            cylinder({ radiusTop = 0.5, radiusBottom = 0.5, height = 1.0, radialSegments = 24 }, "cylinder"),
            cylinder({ radiusTop = 0.0, radiusBottom = 0.5, height = 1.0, radialSegments = 24 }, "cone"),
            torus({ radius = 0.35, tube = 0.15, radialSegments = 16, tubularSegments = 32 }),
            icosahedron(0.5),
            octahedron(0.5),
            sphere(0.5, 8, 6)
        }

    pub def triangleCount(s: Shape): Int32 = Vector.length(s#indices) / 3
}
