// Quad — 四角形（回転した矩形や、太さのある線）の四隅の座標を計算する。
// 頂点を出すことだけに徹するので、同じ四隅を色や不透明度を変えて何にでも描き回せる。
// 利用例: 回転する箱や紙片を描く / 太線や針を描く / 輪郭の縁取りを片側ずつ作る。
// 注意: 作るのは点だけ。色・不透明度・重なり順の指定は呼び側の仕事。

pub mod Quad {

    /// 幅 `2*halfW`・高さ `2*halfH` の矩形を `center` を中心に `angle` ラジアン回した
    /// 四隅。`angle = 0` は軸並行の箱で、ローカル +x 軸（halfW 方向）が `angle` の向きへ
    /// 回る。隅は (-halfW, -halfH) の角から巻いて返す。
    pub def rotated(center: Vec2.Vec2, halfW: Float64, halfH: Float64, angle: Float64): List[Vec2.Vec2] =
        let u = { x = RenderUtil.cosF(angle), y = RenderUtil.sinF(angle) };  // 回転後のローカル +x 軸
        let v = { x = -u#y, y = u#x };                                       // 回転後のローカル +y 軸
        let corner = (sx, sy) -> Vec2.add(center, Vec2.add(Vec2.mul(u, sx * halfW), Vec2.mul(v, sy * halfH)));
        corner(-1.0, -1.0) :: corner(1.0, -1.0) :: corner(1.0, 1.0) :: corner(-1.0, 1.0) :: Nil

    /// 向きを角度でなく単位軸ベクトル `axis` で与える `rotated`。`axis` は箱のローカル +x
    /// 軸（`halfLen` を測る向き）を指す単位ベクトルで、`halfThick` はそれに直交する半厚。
    /// すでに正規化した向き（進行方向や法線）が手元にあるとき、角度への atan2 と cos/sin の
    /// 往復を挟まずに四隅を出せる。`axis = {x = cos angle, y = sin angle}` のとき
    /// `rotated(center, halfLen, halfThick, angle)` と同一。隅は `rotated`・`strip` と同じ
    /// 巻き順で、ローカル (-halfLen, -halfThick) の角から (+,-)→(+,+)→(-,+) と回して返す。
    /// `axis` は単位長を前提とする（長さが 1 でないと箱が伸縮する）。
    pub def orientedByAxis(center: Vec2.Vec2, axis: Vec2.Vec2, halfLen: Float64, halfThick: Float64): List[Vec2.Vec2] =
        let u = axis;                          // ローカル +x 軸（halfLen 方向）
        let v = { x = -u#y, y = u#x };         // ローカル +y 軸（halfThick 方向）
        let corner = (sx, sy) -> Vec2.add(center, Vec2.add(Vec2.mul(u, sx * halfLen), Vec2.mul(v, sy * halfThick)));
        corner(-1.0, -1.0) :: corner(1.0, -1.0) :: corner(1.0, 1.0) :: corner(-1.0, 1.0) :: Nil

    /// `p0` から `p1` への線分に沿った一定幅のストリップで、中心線の両側の符号つき法線オフセット
    /// `o1..o2` を覆う。ストリップの長辺は p0->p1 に平行に走り、厚み (o2 - o1) はどこでも同じ
    /// （両縁とも線分の法線に沿って作るため）。太線・針・輪郭の片側レール（o1..o2 を片側に
    /// 詰めて取る）に使う。`p0` と `p1` は異なる必要がある。
    pub def strip(p0: Vec2.Vec2, p1: Vec2.Vec2, o1: Float64, o2: Float64): List[Vec2.Vec2] =
        let along = Vec2.normalized(Vec2.sub(p1, p0));
        let normal = { x = -along#y, y = along#x };
        Vec2.add(p0, Vec2.mul(normal, o1)) :: Vec2.add(p1, Vec2.mul(normal, o1)) ::
        Vec2.add(p1, Vec2.mul(normal, o2)) :: Vec2.add(p0, Vec2.mul(normal, o2)) :: Nil
}
