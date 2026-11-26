// Scene3d.Internal.SpotLights — スポットライトの円錐の縁と、影の地図を描く目と行列（Scene3d.spotConeOf・shadowCamera・spotShadowDepthBiasOf・shadowMatrix の中身）。

/// スポットライトの中身。ゲームは呼ばない（Scene3d の同じ名前の関数を呼ぶ）。
pub mod Scene3d.Internal.SpotLights {

    /// 円錐の縁の cos（約束は Scene3d.spotConeOf の doc）。
    pub def coneOf(spot: Scene3d.SpotLight): { outerCos = Float64, innerCos = Float64 } =
        let half = spot#fovY / 2.0;
        let innerHalf = match spot#innerFovY {
            case None    => half * Scene3d.spotInnerRatio()
            case Some(a) => (if (Float64.isNan(a) or a < 0.0) 0.0 else Float64.min(a, spot#fovY)) / 2.0
        };
        let outerCos = Num.cos(half);
        let innerCos = Num.cos(innerHalf);
        { outerCos = outerCos, innerCos = if (innerCos == outerCos) innerCos + 0.000001 else innerCos }

    /// 影の地図を描く目（far = max(2, range)・near = min(1, far / 100)・target が位置と同じ所なら真下）。
    // WhyNot: near を 1 に決め打ちしない — 1 = 1 m の部屋の卓上の灯り（光から 1 m 以内に物がある）では、影を落とす物も受ける面も near の手前で切れて影が出ない。
    // WhyNot: near を range に依らず小さく決めない — 奥行きの値の細かさは far / near で決まり、range の長い光（街の灯り）の影の地図が粗くなる。
    pub def cameraOf(spot: Scene3d.SpotLight): Camera3d.Camera3d =
        let d = Vec3.sub(spot#target, spot#position);
        let len = Vec3.length(d);
        let dir = if (len < 0.000001) { x = 0.0, y = -1.0, z = 0.0 } else Vec3.mul(d, 1.0 / len);
        let flat = Num.sqrt(dir#x * dir#x + dir#z * dir#z);
        let far = Float64.max(2.0, spot#range);
        { eye = spot#position, yaw = Num.atan2(dir#x, dir#z), pitch = Num.atan2(0.0 - dir#y, flat),
          fovY = spot#fovY, near = Float64.min(1.0, far / 100.0), far = far, lensShift = Vec2.zero() }

    /// bias × near × (far − 1) / (far − near)（cameraOf の near と far）。
    // WhyNot: bias をそのまま引かない — 透視の奥行きの値の傾きは near に比例し、同じ bias が world で表す長さは near に反比例する。
    //   near を 1 から下げた分そのまま引くと、range の短いスポットの影が物の根元から浮く（range 8 で約 12 倍）。
    pub def depthBiasOf(spot: Scene3d.SpotLight, bias: Float64): Float64 =
        let c = cameraOf(spot);
        bias * c#near * (c#far - 1.0) / (c#far - c#near)

    /// world → 光の clip 空間（縦横の比 1）。
    pub def matrixOf(spot: Scene3d.SpotLight): Mat4.Mat4 =
        let c = cameraOf(spot);
        Mat4.mul(Camera3d.projectionMatrix(c, 1.0), Camera3d.viewMatrix(c))
}
