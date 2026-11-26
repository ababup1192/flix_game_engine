// Scene3d.Internal.SunShadow — 太陽を使えるかの判定と、太陽の影の地図の箱の組み立て（Scene3d.directionalLightOf・directionalShadowOf の中身）。

/// 太陽の中身。ゲームは呼ばない（Scene3d.directionalLightOf・Scene3d.directionalShadowOf を呼ぶ）。
pub mod Scene3d.Internal.SunShadow {

    /// 太陽を使わない理由（1 行）。使える時は None。
    pub def problemOf(l: Scene3d.DirectionalLight): Option[String] =
        let d = l#direction;
        let length = Vec3.length(d);
        if (not (Float64.isFinite(length)) or length < 0.000001) Some("scene3d: 太陽の direction の長さが 0 か有限でない — 太陽なしで描く")
        else if (not (Float64.isFinite(l#intensity)) or l#intensity <= 0.0) Some("scene3d: 太陽の intensity が 0 以下か有限でない — 太陽なしで描く")
        else if (not (l#color#r > 0.0 or l#color#g > 0.0 or l#color#b > 0.0)) Some("scene3d: 太陽の色が黒 — 太陽なしで描く")
        else None

    /// 光の進む向き direction（長さ 1）と影の設定 s から、太陽の影の地図の材料（式は Scene3d.directionalShadowOf の doc）。distance が near 以下なら None。
    pub def setupOf(scene: Scene3d.Scene3dCmd, direction: Vec3.Vec3, s: Scene3d.DirectionalShadow): Option[Scene3d.SunShadowSetup] =
        let cam = scene#camera;
        let distance = Float64.min(s#distance, cam#far);
        if (not (Float64.isFinite(distance) and Float64.isFinite(cam#near) and cam#near > 0.0 and distance > cam#near)) None
        else {
            let (center, radius) = frustumSphereOf(cam, Scene3d.aspectOf(scene), distance);
            let size = Int32.min(s#mapSize, Scene3d.maxShadowMapSize());
            let texel = 2.0 * radius / Int32.toFloat64(size);
            let view = sunViewMatrix(direction);
            let c = Mat4.apply(view, center);
            let snappedX = Float64.floor(c#x / texel) * texel;
            let snappedY = Float64.floor(c#y / texel) * texel;
            let depth = 0.0 - c#z;
            let reach = Float64.max(0.0, s#casterReach);
            let proj = Mat4.orthographic({ left = snappedX - radius, right = snappedX + radius, bottom = snappedY - radius, top = snappedY + radius,
                                           near = depth - radius - reach, far = depth + radius });
            let matrix = Mat4.mul(proj, view);
            Some({ matrix = matrix, frustum = Frustum.ofClipMatrix(matrix), mapSize = size,
                   pcfRadius = Int32.max(0, Int32.min(s#pcfRadius, Scene3d.maxShadowPcfRadius())), strength = s#strength,
                   depthBias = Float64.max(0.0, s#bias) / (reach + 2.0 * radius), normalShift = Float64.max(0.0, s#normalBias) * texel,
                   forward = Camera3d.forward(cam), distance = distance, fadeWidth = Float64.max(distance * 0.1, 0.000001), radius = radius })
        }

    /// カメラの視錐台のうち、前の向きの奥行きが near..far の部分を囲む球（中心, 半径）。式は Scene3d.directionalShadowOf の doc。
    def frustumSphereOf(cam: Camera3d.Camera3d, aspect: Float64, far: Float64): (Vec3.Vec3, Float64) =
        if (Camera3d.hasLensShift(cam)) shiftedFrustumSphereOf(cam, aspect, far) else centeredFrustumSphereOf(cam, aspect, far)

    /// レンズシフトのある視錐台の near..far の 8 つの角を囲む球（角の平均を中心に、一番遠い角まで）。
    /// 半径はカメラの位置と向きによらない（角の並びは目から見て同じ形のまま回るだけ）ので、影の地図の画素は動いても揺れない。
    def shiftedFrustumSphereOf(cam: Camera3d.Camera3d, aspect: Float64, far: Float64): (Vec3.Vec3, Float64) =
        let half = cam#fovY / 2.0;
        let tanHalf = Num.sin(half) / Num.cos(half);
        let f = Camera3d.forward(cam);
        let r = Camera3d.right(cam);
        let u = Camera3d.up(cam);
        let sx = cam#lensShift#x;
        let sy = cam#lensShift#y;
        let cornerAt = (d, kx, ky) -> Vec3.add(cam#eye, Vec3.add(Vec3.mul(f, d),
            Vec3.add(Vec3.mul(r, (kx + 2.0 * sx) * tanHalf * aspect * d), Vec3.mul(u, (ky + 2.0 * sy) * tanHalf * d))));
        let corners = List.flatMap(d -> List.flatMap(kx -> List.map(ky -> cornerAt(d, kx, ky), -1.0 :: 1.0 :: Nil), -1.0 :: 1.0 :: Nil),
                                   cam#near :: far :: Nil);
        let center = Vec3.mul(List.foldLeft(Vec3.add, Vec3.zero(), corners), 1.0 / 8.0);
        let radius = List.foldLeft((acc, p) -> Float64.max(acc, Vec3.length(Vec3.sub(p, center))), 0.0, corners);
        (center, radius)

    def centeredFrustumSphereOf(cam: Camera3d.Camera3d, aspect: Float64, far: Float64): (Vec3.Vec3, Float64) =
        let half = cam#fovY / 2.0;
        let tanHalf = Num.sin(half) / Num.cos(half);
        let k2 = (1.0 + aspect * aspect) * tanHalf * tanHalf;
        let near = cam#near;
        let (reach, radius) = if (k2 >= (far - near) / (far + near)) (far, far * Num.sqrt(k2))
            else ((far + near) / 2.0 * (1.0 + k2),
                  Num.sqrt((far - near) * (far - near) + 2.0 * (far * far + near * near) * k2 + (far + near) * (far + near) * k2 * k2) / 2.0);
        (Vec3.add(cam#eye, Vec3.mul(Camera3d.forward(cam), reach)), radius)

    /// 光の進む向き direction（長さ 1）を前にした、原点の目の行列（world → 光の目の座標。回転だけ）。
    // WhyNot: 光の目を箱の中心に置かない — 中心が動くたびに目の座標の原点が動き、地図の画素の丸め（Scene3d.directionalShadowOf の doc）が効かなくなる。
    def sunViewMatrix(direction: Vec3.Vec3): Mat4.Mat4 =
        let flat = Num.sqrt(direction#x * direction#x + direction#z * direction#z);
        Camera3d.viewMatrix({ eye = Vec3.zero(), yaw = Num.atan2(direction#x, direction#z), pitch = Num.atan2(0.0 - direction#y, flat),
                              fovY = 1.0, near = 1.0, far = 2.0, lensShift = Vec2.zero() })
}
