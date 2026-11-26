// Scene3d.Internal.ScreenInputs — 画面の上の技（Scene3d.ScreenInputs）の奥行きの範囲と、奥行きの画素から点を戻す向きの基底。
// PostStack と 3 つの描き手が同じ値を読む（GPU は uniform の値・CPU は Flix の式）。

/// 画面の上の技の奥行きと向きの中身。ゲームは呼ばない。
pub mod Scene3d.Internal.ScreenInputs {

    /// 奥行きの絵の range（目からの距離 / range を 0..1 で書く）。far の面の一番遠い隅までの距離（lens shift で隅が外へ出る分を含む）。
    // WhyNot: range を far にしない — 奥行きの絵は目からの距離で、far の面は目の向きの奥行きなので、画面の隅の物が far の手前で 1.0 に切られ、何も無い画素と見分けがつかない。
    pub def depthRangeOf(camera: Camera3d.Camera3d, size: Vec2.Vec2): Float64 =
        let (tanX, tanY) = tangentsOf(camera, size);
        let ex = (1.0 + 2.0 * Float64.abs(camera#lensShift#x)) * tanX;
        let ey = (1.0 + 2.0 * Float64.abs(camera#lensShift#y)) * tanY;
        camera#far * Num.sqrt(1.0 + ex * ex + ey * ey)

    /// 縦と横の画角の半分の tan（横 = 縦 × 幅 / 高さ）。
    def tangentsOf(camera: Camera3d.Camera3d, size: Vec2.Vec2): (Float64, Float64) =
        let tanY = Num.sin(camera#fovY / 2.0) / Num.cos(camera#fovY / 2.0);
        let aspect = if (size#y > 0.0) size#x / size#y else 1.0;
        (tanY * aspect, tanY)

    /// 画素の向きの基底 (F', X', U')。場面の矩形の中の画素の NDC (x, y)（上が +1）の向きは normalize(F' + X' × x + U' × y)
    /// （X' = right × 横の tan・U' = up × 縦の tan・F' = forward + X' × 2 lensShift.x + U' × 2 lensShift.y。Camera3d.projectionMatrix の逆）。
    pub def rayBasisOf(camera: Camera3d.Camera3d, size: Vec2.Vec2): (Vec3.Vec3, Vec3.Vec3, Vec3.Vec3) =
        let (tanX, tanY) = tangentsOf(camera, size);
        let right = Vec3.mul(Camera3d.right(camera), tanX);
        let up = Vec3.mul(Camera3d.up(camera), tanY);
        let forward = Vec3.add(Camera3d.forward(camera), Vec3.add(Vec3.mul(right, 2.0 * camera#lensShift#x), Vec3.mul(up, 2.0 * camera#lensShift#y)));
        (forward, right, up)

    /// 奥行きの Pass name が見つからない時の知らせの 1 行（GL と WebGPU で同じ文面）。
    pub def missingDepthLine(name: String): String =
        "scene3d: 画面の上の技の奥行きの Pass '${name}' が見つからない（作れなかった・R32Float で作れず落ちた）— SSAO を掛けずに描く"

    /// 場面の矩形の高さ height 画素で、目から距離 1 の所の 1 の長さが何画素か（SSAO の半径を画素へ写す）。
    pub def projScaleOf(camera: Camera3d.Camera3d, height: Int32): Float64 =
        let (_, tanY) = tangentsOf(camera, { x = 1.0, y = 1.0 });
        Int32.toFloat64(height) / (2.0 * tanY)
}
