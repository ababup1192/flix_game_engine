/// Rect2 — 2D の矩形を「左上の座標」と「幅・高さ」で表し、当たり・包含・膨張などを計算する。
/// 矩形の交差や内外判定を毎回書き下さずに済むので、UI の領域やクリック判定を素直に扱える。
/// 利用例: ボタンの当たり範囲を決める / 点が枠の中か調べる / 枠を少し広げて余白を作る。
///
/// position は左上座標、size は幅と高さを表す。
///
///   position
///     +----------+
///     |          | size.y
///     +----------+
///       size.x

pub mod Rect2 {

    /// 矩形: position = 左上座標、size = 幅と高さ
    pub type alias Rect2 = {position = Vec2.Vec2, size = Vec2.Vec2}

    // ========================================================================
    // コンストラクタ
    // ========================================================================

    /// 原点 (0, 0) から指定サイズの矩形を作成する
    pub def fromSize(size: Vec2.Vec2): Rect2 =
        {position = Vec2.zero(), size = size}

    // ========================================================================
    // プロパティ
    // ========================================================================

    /// 矩形の終端（右下）座標を返す
    pub def end(rect: Rect2): Vec2.Vec2 =
        Vec2.add(rect#position, rect#size)

    /// 矩形の面積を返す
    pub def area(rect: Rect2): Float64 =
        rect#size#x * rect#size#y

    /// 矩形の中心座標を返す
    pub def center(rect: Rect2): Vec2.Vec2 =
        Vec2.add(rect#position, Vec2.div(rect#size, 2.0))

    // ========================================================================
    // 判定
    // ========================================================================

    /// 指定した点が矩形に含まれるか判定する
    pub def hasPoint(point: Vec2.Vec2, rect: Rect2): Bool =
        let e = end(rect);
        point#x >= rect#position#x and point#x <= e#x and
        point#y >= rect#position#y and point#y <= e#y

    /// 2 つの矩形の交差（重なっている部分）。重なりが無ければ size が 0 以下の矩形を返す —
    /// 「空」を Option にせず負サイズで表すのは、描画側の「幅か高さが 0 以下なら何も描かない」
    /// 規約にそのまま接続するため。面積が要る呼び側は size の正負で先に判定する。
    pub def intersect(a: Rect2, b: Rect2): Rect2 =
        let x0 = Float64.max(a#position#x, b#position#x);
        let y0 = Float64.max(a#position#y, b#position#y);
        let x1 = Float64.min(a#position#x + a#size#x, b#position#x + b#size#x);
        let y1 = Float64.min(a#position#y + a#size#y, b#position#y + b#size#y);
        { position = { x = x0, y = y0 }, size = { x = x1 - x0, y = y1 - y0 } }

    // ========================================================================
    // サイズ変更
    // ========================================================================

    /// 全方向に amount 分だけ広げた矩形を返す。負の値なら縮む（内側の余白）。
    pub def grow(amount: Float64, rect: Rect2): Rect2 =
        {position = {x = rect#position#x - amount,
                     y = rect#position#y - amount},
         size     = {x = rect#size#x + 2.0 * amount,
                     y = rect#size#y + 2.0 * amount}}
}
