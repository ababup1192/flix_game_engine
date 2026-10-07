/// Vec2i — 整数の (x, y) の組に対する足し引きなどの計算。
/// マス目やピクセルのように「割り切れる整数」で位置を扱いたい場面で、丸め誤差なく計算できる。
/// 利用例: タイルの列・行を足し引きする / グリッド上の隣を求める / 整数ピクセルのオフセット。
///
/// **設計**: データ構造を提供せず、`{x = Int32, y = Int32}` の structural record を
/// 直接 consumer が持つ。このモジュールは `add`, `sub`, `zero`, `up` 等の計算 API だけ提供する。
///
/// **設計理由** (Flix 0.72.0 の fpkg cross-package 可視性 bug 回避):
///   - `pub type alias Vec2i` を `mod Vec2` 内に置くと fpkg 越しに見えない (Y ≠ X)
///   - `pub def` 関数は fpkg 越しに確実に export される
///   - 型を consumer が直接持つ structural record にすれば cross-package OK
///
/// 使い方:
///   - 構築: `Vec2i.make(3, 4)` または `{x = 3, y = 4}` (record literal)
///   - 取得: `v#x`, `v#y` (record syntax)
///   - 演算: `Vec2i.add(a, b)` / `Vec2i.sub(a, b)`
///   - 定数: `Vec2i.zero()` / `Vec2i.up()` 等
///   - 同値比較: `Vec2i.eq(a, b)` (record の `==` は使えないので helper 経由)
pub mod Vec2i {

    pub def make(x: Int32, y: Int32): {x = Int32, y = Int32} = {x = x, y = y}

    pub def zero(): {x = Int32, y = Int32} = {x = 0, y = 0}
    pub def one(): {x = Int32, y = Int32}  = {x = 1, y = 1}

    pub def up(): {x = Int32, y = Int32}    = {x =  0, y = -1}
    pub def down(): {x = Int32, y = Int32}  = {x =  0, y =  1}
    pub def left(): {x = Int32, y = Int32}  = {x = -1, y =  0}
    pub def right(): {x = Int32, y = Int32} = {x =  1, y =  0}

    pub def add(a: {x = Int32, y = Int32}, b: {x = Int32, y = Int32}): {x = Int32, y = Int32} =
        {x = a#x + b#x, y = a#y + b#y}

    pub def sub(a: {x = Int32, y = Int32}, b: {x = Int32, y = Int32}): {x = Int32, y = Int32} =
        {x = a#x - b#x, y = a#y - b#y}

    /// record の structural 同値比較
    pub def eq(a: {x = Int32, y = Int32}, b: {x = Int32, y = Int32}): Bool =
        a#x == b#x and a#y == b#y

    /// Int 座標 → Float64 座標
    pub def toVec2(v: {x = Int32, y = Int32}): Vec2.Vec2 =
        {x = Int32.toFloat64(v#x), y = Int32.toFloat64(v#y)}

    /// Float64 座標 → Int 座標 (floor 切り捨て)
    pub def fromVec2Floor(v: Vec2.Vec2): {x = Int32, y = Int32} =
        {x = Num.floorInt(v#x), y = Num.floorInt(v#y)}
}
