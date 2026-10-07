// Bezier — ベジエ曲線の平坦化と、曲線から作る描画部品（太さ付きのストリップ・塗りつぶし）。
// 角丸ボックスだけでは描けない、線の太さを端に向けて変えた形や曲線に沿った輪郭を
// 多角形として組み立てられる（塗りは描画側が耳切りで三角形化するので、凹んだ輪郭もよい）。
// 利用例: spine = quadratic(付け根, 制御点, 先端, 12);
//         stroke({ spine = spine, color = 緑, z = 2 }, t -> 5.0 - 3.0 * t)
pub mod Bezier {

    /// 2 次ベジエを steps 分割した折れ線にする（始点・終点を含む steps+1 点）。
    pub def quadratic(p0: Vec2.Vec2, ctrl: Vec2.Vec2, p1: Vec2.Vec2,
                      steps: Int32): List[Vec2.Vec2] =
        List.range(0, steps + 1) |> List.map(i -> {
            let t = Int32.toFloat64(i) / Int32.toFloat64(steps);
            let u = 1.0 - t;
            { x = u * u * p0#x + 2.0 * u * t * ctrl#x + t * t * p1#x,
              y = u * u * p0#y + 2.0 * u * t * ctrl#y + t * t * p1#y }
        })

    /// 3 次ベジエを steps 分割した折れ線にする。
    pub def cubic(p0: Vec2.Vec2, c1: Vec2.Vec2, c2: Vec2.Vec2, p1: Vec2.Vec2,
                  steps: Int32): List[Vec2.Vec2] =
        List.range(0, steps + 1) |> List.map(i -> {
            let t = Int32.toFloat64(i) / Int32.toFloat64(steps);
            let u = 1.0 - t;
            { x = u * u * u * p0#x + 3.0 * u * u * t * c1#x + 3.0 * u * t * t * c2#x + t * t * t * p1#x,
              y = u * u * u * p0#y + 3.0 * u * u * t * c1#y + 3.0 * u * t * t * c2#y + t * t * t * p1#y }
        })

    /// stroke の引数一式。spine = 背骨の折れ線（quadratic/cubic の出力）、color/z = 塗り。
    pub type alias Stroke = { spine = List[Vec2.Vec2], color = Color, z = Int32 }

    /// 背骨に太さを付けたストリップ。widthOf は背骨上の位置 t（0=始点..1=終点）→ その場所の太さで、
    /// 先細り・先太りが自由に作れる。ストリップは凸クアッド列 + 節ごとの丸い継ぎ目隠しで返す
    /// （クアッドの境界にアンチエイリアスの筋が出ないように、内側の点に円盤を重ねる）。
    pub def stroke(s: Stroke, widthOf: Float64 -> Float64): List[Render.PlacedItem] =
        let pts = List.toVector(s#spine);
        let n = Vector.length(pts);
        if (n < 2)
            Nil
        else {
            let rails = List.range(0, n) |> List.map(i -> {
                let p = pointAt(pts, i);
                let dir = tangentAt(pts, i);
                let half = widthOf(Int32.toFloat64(i) / Int32.toFloat64(n - 1)) / 2.0;
                let normal = { x = -1.0 * dir#y * half, y = dir#x * half };
                (Vec2.add(p, normal), { x = p#x - normal#x, y = p#y - normal#y })
            }) |> List.toVector;
            let quads = List.range(0, n - 1) |> List.map(i -> {
                let (l0, r0) = railAt(rails, i);
                let (l1, r1) = railAt(rails, i + 1);
                quadPiece(l0 :: l1 :: r1 :: r0 :: Nil, s#color, s#z)
            });
            let joints = List.range(1, n - 1) |> List.map(i -> {
                let half = widthOf(Int32.toFloat64(i) / Int32.toFloat64(n - 1)) / 2.0;
                convexFill(ellipse(pointAt(pts, i), half, half, 8), s#color, s#z)
            }) |> List.flatten;
            List.append(quads, joints)
        }

    /// fill の別名（旧呼び出し向け）。新規コードは fill を使う。
    pub def convexFill(outline: List[Vec2.Vec2], color: Color, z: Int32): List[Render.PlacedItem] =
        fill(outline, color, z)

    /// 閉じた輪郭を 1 枚の多角形として塗る。自己交差しない単純多角形なら深くえぐれた形
    /// でもよい — 描画側が耳切りで三角形化するので、分割の継ぎ目も出ない。
    pub def fill(outline: List[Vec2.Vec2], color: Color, z: Int32): List[Render.PlacedItem] =
        if (List.length(outline) < 3)
            Nil
        else
            quadPiece(outline, color, z) :: Nil

    /// 折れ線を一定幅のストリップで描く（節は丸い継ぎ目でつなぐ）。単発の線分 1 本だけなら
    /// RawDraw.lineSeg（quad 1 枚で軽い）が近道。
    pub def polyline(points: List[Vec2.Vec2], width: {width = Float64},
                     color: Color, z: Int32): List[Render.PlacedItem] =
        stroke({ spine = points, color = color, z = z }, _ -> width#width)

    /// 5 芒星の輪郭（上向き）。頂点列なので fill で塗る・stroke の背骨にする・加工する、が自由。
    /// Item として置くだけなら RawDraw.starAt が近道。
    pub def star(center: Vec2.Vec2, rOut: {rOut = Float64}, rIn: {rIn = Float64}): List[Vec2.Vec2] =
        List.range(0, 10) |> List.map(i -> {
            let a = -1.5707963267948966 + 3.141592653589793 * Int32.toFloat64(i) / 5.0;
            let r = if (Int32.modulo(i, 2) == 0) rOut#rOut else rIn#rIn;
            { x = center#x + r * RenderUtil.cosF(a), y = center#y + r * RenderUtil.sinF(a) }
        })

    /// 楕円の輪郭（segments は 16〜24 で十分丸い）。頂点列なので fill・stroke・加工が自由。
    /// Item として置くだけなら RawDraw.ellipseAt が近道。
    pub def ellipse(center: Vec2.Vec2, rx: Float64, ry: Float64,
                    segments: Int32): List[Vec2.Vec2] =
        ellipseRot(center, rx, ry, 0.0, segments)

    /// 回転つき楕円の輪郭（angle ラジアン。y 下向きの画面座標では正 = 時計回り）。
    pub def ellipseRot(center: Vec2.Vec2, rx: Float64, ry: Float64, angle: Float64,
                       segments: Int32): List[Vec2.Vec2] =
        let ca = RenderUtil.cosF(angle);
        let sa = RenderUtil.sinF(angle);
        List.range(0, segments) |> List.map(i -> {
            let a = Vec2.tau() * Int32.toFloat64(i) / Int32.toFloat64(segments);
            let ex = rx * RenderUtil.cosF(a);
            let ey = ry * RenderUtil.sinF(a);
            { x = center#x + ex * ca - ey * sa, y = center#y + ex * sa + ey * ca }
        })

    // ── 内部 ──

    def pointAt(pts: Vector[Vec2.Vec2], i: Int32): Vec2.Vec2 =
        Vector.get(i, pts)

    def railAt(rails: Vector[(Vec2.Vec2, Vec2.Vec2)], i: Int32): (Vec2.Vec2, Vec2.Vec2) =
        Vector.get(i, rails)

    /// 点 i の接線方向（両隣の差分を正規化。端は片側差分）。
    def tangentAt(pts: Vector[Vec2.Vec2], i: Int32): Vec2.Vec2 =
        let n = Vector.length(pts);
        let a = pointAt(pts, Int32.max(0, i - 1));
        let b = pointAt(pts, Int32.min(n - 1, i + 1));
        let dx = b#x - a#x;
        let dy = b#y - a#y;
        let len = Vec2.sqrt(dx * dx + dy * dy);
        if (len <= 0.000001) { x = 1.0, y = 0.0 } else { x = dx / len, y = dy / len }

    /// 輪郭 1 枚ぶんの Poly（頂点は絶対座標で渡し、置き場所は原点にする）。
    def quadPiece(vertices: List[Vec2.Vec2], color: Color, z: Int32): Render.PlacedItem =
        { at = Vec2.zero(), item = RawDraw.polygon(vertices, color, z) }
}
