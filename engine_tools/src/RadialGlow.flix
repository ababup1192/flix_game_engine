// RadialGlow — 中心から縁へ薄れる小さな絵を画素単位の純関数として計算する。
//
// 光の「グロー」と「暗くするオーバーレイの穴」は Multiply/Add の合成式が正反対の性質を持つため、
// 同じ絵（白が中心・縁が透明）を両方に使い回すと片方が壊れる（DrawCmd.BlendMode の
// doc の通り Multiply は「白は素通し」なので alpha だけの絵は掛けても何も変わらない）。
// そのため rgb で暗さを表す版（maskPixel）と alpha で濃さを表す版（haloPixel）を
// 別関数として分けてある — 呼び違えると効果が出ない事故になるため名前で区別する。
// PNG 化（Array 敷き詰め・BufferedImage 化）は SoftRaster.writeRadialPng に任せ、
// ここは画素の値だけを決める（AWT に触れない）。
pub mod RadialGlow {

    /// Addハロ用の1画素: rgb=白固定、alpha=中心で高く縁で0（straight alpha）。
    /// Multiplyに使うと白は素通しの式で恒等に潰れて何も起きない — Add専用。
    pub def haloPixel(curve: Float64 -> Float64, t: Float64): Int32 =
        argb(toByte(curve(t)), 255, 255, 255)

    /// Multiply穴あきオーバーレイ用の1画素: alpha=255固定（不透明）、
    /// rgb=中心で白(素通し=穴)→縁で黒(暗く沈める)。
    /// Addに使うと常に最大加算（白）になる — Multiply専用。
    pub def maskPixel(curve: Float64 -> Float64, t: Float64): Int32 =
        let v = toByte(curve(t));
        argb(255, v, v, v)

    /// 0(中心)→1(縁)を素通しする既定カーブ（直線減衰）。
    pub def linearCurve(t: Float64): Float64 = Num.clamp01(1.0 - t)

    /// smoothstep(3t²-2t³) で減衰する既定カーブ。縁の階調がなめらかで、
    /// linear よりバンディングが出にくい。
    pub def smoothstepCurve(t: Float64): Float64 =
        let x = Num.clamp01(1.0 - t);
        x * x * (3.0 - 2.0 * x)

    /// maskPixel が「穴」として使う既定の平坦部の広さ（0..1、画像半径に対する比率）。
    /// Light.singleLightItems のスケール計算がこの値を前提に「穴の実寸半径 = light#radius」
    /// を逆算するため、maskTexture を描き出す側とスケールを計算する側が同じ値を見る必要がある。
    /// 0.5（黒到達点=2×radius）: holeFrac が小さいほど画像の外周に対する「黒までの距離」が
    /// 相対的に伸び、オーバーレイの拡大時に黒到達点が radius から大きく離れる
    /// （旧 0.15 では 6.67×radius まで伸びて隅の減衰がほぼ消えていた）。
    pub def defaultHoleFrac(): Float64 = 0.5

    /// t が holeFrac 以下なら完全に素通し（1.0 固定）、それ以降は残り区間へ curve を
    /// 再マップして減衰させる。素通しの「平坦な穴」を持つことで、テクスチャを拡大した
    /// ときの穴の実寸半径がスケールに対して線形に決まる（平坦部が無いと、どれだけ
    /// 拡大しても「ほぼ白」とみなせる範囲が曖昧になり、光の半径と噛み合わなくなる）。
    pub def maskCurveWithHole(holeFrac: Float64, curve: Float64 -> Float64, t: Float64): Float64 =
        if (t <= holeFrac) 1.0
        else curve((t - holeFrac) / (1.0 - holeFrac))

    /// size×size の正方形の中で、画素 (x, y) の中心から 0(中心)→1(縁) に正規化した距離。
    /// haloPixel/maskPixel の curve にそのまま渡す t を、敷き詰め側（SoftRaster）が
    /// 画素ごとに計算するための共通式。
    pub def normalizedRadius(size: Int32, x: Int32, y: Int32): Float64 =
        let half = Int32.toFloat64(size) / 2.0;
        let dx = Int32.toFloat64(x) + 0.5 - half;
        let dy = Int32.toFloat64(y) + 0.5 - half;
        Num.clamp01(Vec2.length({ x = dx, y = dy }) / half)

    /// ARGB 1 画素を組む（SoftRaster.blendPixel と同じビット配置: shift 24/16/8/0 = A/R/G/B）。
    def argb(a: Int32, r: Int32, g: Int32, b: Int32): Int32 =
        Int32.leftShift(a, 24)
            |> Int32.bitwiseOr(Int32.leftShift(r, 16))
            |> Int32.bitwiseOr(Int32.leftShift(g, 8))
            |> Int32.bitwiseOr(b)

    /// 0..1 を 0..255 の Int32 へ丸めてクランプする。
    def toByte(x: Float64): Int32 =
        let v = Float64.tryToInt32(Num.clamp01(x) * 255.0 + 0.5) |> Option.getWithDefault(0);
        Int32.max(0, Int32.min(255, v))
}
