// Vec2 — 2D の位置や向きを表す (x, y) の組と、その足し引き・長さ・回転などの計算。
// 座標を1つの値として扱えるので、移動・距離・角度の計算をその場で書き下さずに済む。
// 利用例: キャラを速度ぶん動かす / 2点間の距離を測る / 狙う方向のベクトルを求める。

pub mod Vec2 {
    import java.lang.Math

    pub type alias Vec2 = {x = Float64, y = Float64}

    // Vec2i 関連は別 mod Vec2i に分離

    // ========================================================================
    // Math Helpers
    // ========================================================================

    /// 平方根（pure キャスト）
    pub def sqrt(v: Float64): Float64 =
        unchecked_cast(Math.sqrt(v) as _ \ {})

    /// 円周率（値の源は tau に一本化 — 2 で割るのは倍精度で正確）。
    pub def pi(): Float64 = tau() / 2.0

    /// 1 周ぶんの角（2π）。円周に点を置く計算の共通の源（リテラルの散在を防ぐ）。
    pub def tau(): Float64 = 6.283185307179586

    /// sin（pure キャスト）
    pub def sin(x: Float64): Float64 =
        unchecked_cast(Math.sin(x) as _ \ {})

    /// cos（pure キャスト）
    pub def cos(x: Float64): Float64 =
        unchecked_cast(Math.cos(x) as _ \ {})

    /// atan2（pure キャスト）
    pub def atan2(y: Float64, x: Float64): Float64 =
        unchecked_cast(Math.atan2(y, x) as _ \ {})


    // ========================================================================
    // Constants
    // ========================================================================

    /// (x, y) から Vec2 を作るリテラル短縮。`{x = …, y = …}` と同じ値だが、リスト内などで
    /// レコードリテラルの型が確定せず `({x = …, y = …}: Vec2.Vec2)` の型注釈が要る場面を消す。
    /// 引数の並びは x → y（数学・GL の正準順）。
    pub def v2(x: Float64, y: Float64): Vec2 = { x = x, y = y }

    pub def zero(): Vec2 = {x = 0.0, y = 0.0}

    pub def one(): Vec2 = {x = 1.0, y = 1.0}

    pub def up(): Vec2 = {x = 0.0, y = -1.0}

    pub def down(): Vec2 = {x = 0.0, y = 1.0}

    pub def left(): Vec2 = {x = -1.0, y = 0.0}

    pub def right(): Vec2 = {x = 1.0, y = 0.0}

    // ========================================================================
    // Arithmetic
    // ========================================================================

    pub def add(a: Vec2, b: Vec2): Vec2 =
        {x = a#x + b#x, y = a#y + b#y}

    pub def sub(a: Vec2, b: Vec2): Vec2 =
        {x = a#x - b#x, y = a#y - b#y}

    pub def mul(v: Vec2, s: Float64): Vec2 =
        {x = v#x * s, y = v#y * s}

    pub def div(v: Vec2, s: Float64): Vec2 =
        {x = v#x / s, y = v#y / s}

    pub def neg(v: Vec2): Vec2 =
        {x = -1.0 * v#x, y = -1.0 * v#y}

    // ========================================================================
    // Length & Distance
    // ========================================================================

    pub def lengthSquared(v: Vec2): Float64 =
        v#x * v#x + v#y * v#y

    pub def length(v: Vec2): Float64 =
        sqrt(lengthSquared(v))

    pub def distanceSquaredTo(a: Vec2, b: Vec2): Float64 =
        lengthSquared(sub(a, b))

    pub def distanceTo(a: Vec2, b: Vec2): Float64 =
        length(sub(a, b))

    // ========================================================================
    // Normalization & Dot/Cross
    // ========================================================================

    pub def normalized(v: Vec2): Vec2 =
        let len = length(v);
        if (len > 0.0) div(v, len) else zero()

    pub def dot(a: Vec2, b: Vec2): Float64 =
        a#x * b#x + a#y * b#y

    pub def cross(a: Vec2, b: Vec2): Float64 =
        a#x * b#y - a#y * b#x

    // ========================================================================
    // Reflect & Bounce
    // ========================================================================

    /// 向き `n` の壁に `v` を映した向き（鏡写し。壁に沿う成分はそのまま、垂直成分だけ反転）。
    pub def reflect(v: Vec2, n: Vec2): Vec2 =
        let d = dot(v, n);
        sub(v, mul(n, 2.0 * d))

    /// 向き `n` の壁で `v` を跳ね返した向き（reflect の逆向き）。
    pub def bounce(v: Vec2, n: Vec2): Vec2 =
        neg(reflect(v, n))

    // ========================================================================
    // Angle & Rotation
    // ========================================================================

    pub def angle(v: Vec2): Float64 =
        atan2(v#y, v#x)

    pub def angleTo(a: Vec2, b: Vec2): Float64 =
        atan2(cross(a, b), dot(a, b))

    pub def rotated(v: Vec2, phi: Float64): Vec2 =
        let c = cos(phi);
        let s = sin(phi);
        {x = v#x * c - v#y * s, y = v#x * s + v#y * c}

    pub def directionTo(a: Vec2, b: Vec2): Vec2 =
        normalized(sub(b, a))

    // ========================================================================
    // Clamp & Interpolation
    // ========================================================================

    pub def clamp(v: Vec2, minV: Vec2, maxV: Vec2): Vec2 =
        {x = Float64.max(minV#x, Float64.min(maxV#x, v#x)),
         y = Float64.max(minV#y, Float64.min(maxV#y, v#y))}

    pub def clampSymmetric(v: Vec2, halfExtents: Vec2): Vec2 =
        clamp(v, neg(halfExtents), halfExtents)

    pub def moveToward(origin: Vec2, target: Vec2, delta: Float64): Vec2 =
        let diff = sub(target, origin);
        let dist = length(diff);
        if (dist <= delta or dist <= 0.0) target
        else add(origin, mul(div(diff, dist), delta))

    pub def lerp(a: Vec2, b: Vec2, t: Float64): Vec2 =
        {x = a#x + (b#x - a#x) * t, y = a#y + (b#y - a#y) * t}

    // ========================================================================
    // Component Operations
    // ========================================================================

    pub def abs(v: Vec2): Vec2 =
        {x = Float64.abs(v#x), y = Float64.abs(v#y)}

    pub def sign(v: Vec2): Vec2 =
        let sx = if (v#x > 0.0) 1.0 else if (v#x < 0.0) -1.0 else 0.0;
        let sy = if (v#y > 0.0) 1.0 else if (v#y < 0.0) -1.0 else 0.0;
        {x = sx, y = sy}

    pub def min(a: Vec2, b: Vec2): Vec2 =
        {x = Float64.min(a#x, b#x), y = Float64.min(a#y, b#y)}

    pub def max(a: Vec2, b: Vec2): Vec2 =
        {x = Float64.max(a#x, b#x), y = Float64.max(a#y, b#y)}

    pub def floor(v: Vec2): Vec2 =
        {x = Math.floor(v#x), y = Math.floor(v#y)}

    pub def ceil(v: Vec2): Vec2 =
        {x = Math.ceil(v#x), y = Math.ceil(v#y)}

    pub def round(v: Vec2): Vec2 =
        {x = Math.rint(v#x), y = Math.rint(v#y)}

    // ========================================================================
    // Utility
    // ========================================================================

    pub def isNormalized(v: Vec2): Bool =
        let lsq = lengthSquared(v);
        Float64.abs(lsq - 1.0) < 0.0001

    pub def isZeroApprox(v: Vec2): Bool =
        Float64.abs(v#x) < 0.0001 and Float64.abs(v#y) < 0.0001

    pub def limitLength(v: Vec2, maxLen: Float64): Vec2 =
        let lsq = lengthSquared(v);
        if (lsq > maxLen * maxLen)
            mul(normalized(v), maxLen)
        else v

    pub def projected(v: Vec2, onto: Vec2): Vec2 =
        let d = dot(onto, onto);
        if (d > 0.0) mul(onto, dot(v, onto) / d) else zero()

    pub def slide(v: Vec2, n: Vec2): Vec2 =
        sub(v, mul(n, dot(v, n)))

    /// 楕円周上の点（radii は x/y の半径。t は 1 周 = 1.0・t = 0 が真上・時計回り =
    /// y 下向きの画面の見た目どおり）。円は radii の x = y で渡す。
    /// 新規コードの「円周に点を置く」計算はこれを使う（既存の自前 cos/sin は描き出しの
    /// バイト一致を守るため据え置き — 移行は絵の差分を許容するリリースで行う）。
    pub def onEllipse(radii: Vec2, t: Float64): Vec2 =
        { x = radii#x * cos(tau() * (t - 0.25)), y = radii#y * sin(tau() * (t - 0.25)) }
}
