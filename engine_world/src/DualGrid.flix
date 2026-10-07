// DualGrid — 「セル4つが接する角」を見て、半セルずらしたタイル(16ケースの多角形)を組む
// 純粋な幾何。色も z も持たない(質感は Material が決める)。Corner は呼び側が注入するため、
// マップの型に依存せず、壁でも水でもマグマでも同じ幾何が使い回せる。
// resolve は角1個ぶんの純関数(全マップ一括の関数はない — キャッシュや遅延評価は呼び側の方針)。
// 初学者向けの概念説明は docs/dual-grid.md。

pub mod DualGrid {

    /// 角のまわり4セルの埋まり方。tl=左上 tr=右上 bl=左下 br=右下。
    pub type alias Corner = { tl = Bool, tr = Bool, bl = Bool, br = Bool }

    /// 角の形。1種類に統一すると「作られた構造物」に見えるため、場所ごとに混ぜる。
    pub enum CornerStyle with Eq, ToString {
        case Round
        case Square
        case Diamond
    }

    /// 角スタイルの混ぜ具合。round/square の割合(残りがひし形)。
    pub type alias StyleMix = { round = Float64, square = Float64 }

    /// 輪郭の1辺。points = スタイル適用後の折れ線(丸=曲線の折れ線化・揺らぎ=中点をずらした
    /// 3点)、normal = 外向き法線(フチの色とストリップの向きはこれで選ぶ)、border = タイル境界上の辺か
    /// (隣のタイルと必ず同じ埋まり方になる辺 — 縁取りすると塊の内部に継ぎ目が走る)。
    pub type alias Edge = { points = List[Vec2.Vec2], normal = Vec2.Vec2, border = Bool }

    /// 解決済みのタイル1枚(ローカル座標 0..size)。polys = 塗れる輪郭(スタイル適用済み)、
    /// edges = polys と同じ並びの「多角形ごとの辺のリスト」。対角2セルのケースは2枚に
    /// なるため平らにしない — 描画が「塗り→縁」を1枚ごとに交互に並べる順を保つ。
    pub type alias Tile = {
        caseIndex = Int32,
        style = CornerStyle,
        size = Float64,
        polys = List[List[Vec2.Vec2]],
        edges = List[List[Edge]]
    }

    /// 角1個ぶんのタイルを解決する。style は呼び側が決めて渡す(混ぜたいなら styleAt)。
    /// jitter は対角辺の岩肌の揺らぎ(丸スタイルには掛からない — 曲線の柔らかさと揺らぎは
    /// 両立しないため)。
    pub def resolve(spec: { tile = Float64, corner = (Int32, Int32),
                            style = CornerStyle, jitter = Float64 },
                    flags: Corner): Tile =
        let t = spec#tile;
        let parts = dualCase(t, flags) |> List.map(base -> {
            let squared = if (spec#style == CornerStyle.Square) squareOff(t, base) else base;
            let edges = edgesOf(squared) |> List.zipWithIndex
                |> List.map(match (k, (a, b)) -> {
                    let border = onTileBorder(t, a, b);
                    let points =
                        if (border or not isDiagonal(a, b)) a :: b :: Nil
                        else if (spec#style == CornerStyle.Round) roundEdge(t, a, b)
                        else if (spec#jitter > 0.001) jitteredEdge(spec#corner, spec#jitter, k, a, b)
                        else a :: b :: Nil;
                    { points = points, normal = outwardNormal(squared, a, b), border = border }
                });
            (edges |> List.flatMap(e -> initOf(e#points)), edges)
        });
        { caseIndex = caseIndex(flags),
          style = spec#style,
          size = t,
          polys = parts |> List.map(match (poly, _) -> poly),
          edges = parts |> List.map(match (_, es) -> es) }

    /// タイルの「輪郭の小さな辺」の列(ローカル座標・タイル境界の辺は除く)。
    /// 光の遮蔽・照り返しがこの列をなぞれば、光の線が描画とぴったり同じ形になる。
    pub def segmentsOf(tile: Tile): List[(Vec2.Vec2, Vec2.Vec2)] =
        tile#edges |> List.flatMap(edgeList -> edgeList |> List.flatMap(edge ->
            if (edge#border) Nil
            else List.zip(edge#points, List.drop(1, edge#points))))

    /// 角 (i, j) のタイルの置き場所(ワールド座標の左上)。デュアルタイルはセル境界を
    /// またぐので、角から半タイル戻す。
    pub def originOf(tile: Float64, corner: (Int32, Int32)): Vec2.Vec2 =
        let (i, j) = corner;
        { x = Int32.toFloat64(i) * tile - tile / 2.0,
          y = Int32.toFloat64(j) * tile - tile / 2.0 }

    // ════════════════════════════════════════════════════════
    // 16ケースの多角形(デュアルタイルの部品)
    // ════════════════════════════════════════════════════════

    /// corner の4ビット表現(tl=8, tr=4, bl=2, br=1)。検証ステージの網羅チェックも同じ値を見る。
    pub def caseIndex(corner: Corner): Int32 =
        (if (corner#tl) 8 else 0) + (if (corner#tr) 4 else 0) +
        (if (corner#bl) 2 else 0) + (if (corner#br) 1 else 0)

    /// デュアルタイル1枚の多角形(ローカル座標 0..tile・ひし形の素の形)。
    /// 対角2セル(ケース 9/6)だけ三角2枚になるので、戻り値は多角形のリスト。
    pub def dualCase(tile: Float64, corner: Corner): List[List[Vec2.Vec2]] =
        let t = tile;
        let h = tile / 2.0;
        let p = (x, y) -> ({ x = x, y = y }: Vec2.Vec2);
        match caseIndex(corner) {
            case 0  => Nil
            case 15 => (p(0.0, 0.0) :: p(t, 0.0) :: p(t, t) :: p(0.0, t) :: Nil) :: Nil
            case 8  => (p(0.0, 0.0) :: p(h, 0.0) :: p(0.0, h) :: Nil) :: Nil
            case 4  => (p(h, 0.0) :: p(t, 0.0) :: p(t, h) :: Nil) :: Nil
            case 2  => (p(0.0, h) :: p(h, t) :: p(0.0, t) :: Nil) :: Nil
            case 1  => (p(t, h) :: p(t, t) :: p(h, t) :: Nil) :: Nil
            case 12 => (p(0.0, 0.0) :: p(t, 0.0) :: p(t, h) :: p(0.0, h) :: Nil) :: Nil
            case 3  => (p(0.0, h) :: p(t, h) :: p(t, t) :: p(0.0, t) :: Nil) :: Nil
            case 10 => (p(0.0, 0.0) :: p(h, 0.0) :: p(h, t) :: p(0.0, t) :: Nil) :: Nil
            case 5  => (p(h, 0.0) :: p(t, 0.0) :: p(t, t) :: p(h, t) :: Nil) :: Nil
            case 9  => (p(0.0, 0.0) :: p(h, 0.0) :: p(0.0, h) :: Nil)
                    :: (p(t, h) :: p(t, t) :: p(h, t) :: Nil) :: Nil
            case 6  => (p(h, 0.0) :: p(t, 0.0) :: p(t, h) :: Nil)
                    :: (p(0.0, h) :: p(h, t) :: p(0.0, t) :: Nil) :: Nil
            case 14 => (p(0.0, 0.0) :: p(t, 0.0) :: p(t, h) :: p(h, t) :: p(0.0, t) :: Nil) :: Nil
            case 13 => (p(0.0, 0.0) :: p(t, 0.0) :: p(t, t) :: p(h, t) :: p(0.0, h) :: Nil) :: Nil
            case 11 => (p(0.0, 0.0) :: p(h, 0.0) :: p(t, h) :: p(t, t) :: p(0.0, t) :: Nil) :: Nil
            case 7  => (p(h, 0.0) :: p(t, 0.0) :: p(t, t) :: p(0.0, t) :: p(0.0, h) :: Nil) :: Nil
            case _  => Nil
        }

    // ════════════════════════════════════════════════════════
    // 決定論ハッシュと角スタイルの選択
    // ════════════════════════════════════════════════════════

    /// セル座標から 0 以上 1 未満のばらついた数を1つ決める。同じ入力は毎回同じ値 —
    /// 保存なしで「場所ごとの個性」を引くため(engine の Hash01 でなくこの式なのは、
    /// すり合わせ済みモックと同じ配置・同じ絵を再現するため)。
    pub def hash(x: Int32, y: Int32, channel: Int32): Float64 =
        let h0 = x * 374761393 + y * 668265263 + channel * 974637 + 1013904223;
        let h1 = Int32.bitwiseXor(h0, Int32.logicalRightShift(dist = 13, h0)) * 1274126177;
        let h2 = Int32.bitwiseXor(h1, Int32.logicalRightShift(dist = 16, h1));
        Int64.toFloat64(Int64.bitwiseAnd(4294967295i64, Int32.toInt64(h2))) / 4294967296.0

    /// 角 (i, j) の形を丸/四角/ひし形から選ぶ。比率は mix のノブ、選択は座標ハッシュで
    /// 決定論(毎回同じ絵)。
    pub def styleAt(mix: StyleMix, corner: (Int32, Int32)): CornerStyle =
        let (i, j) = corner;
        let r = hash(i, j, 81);
        if (r < mix#round) CornerStyle.Round
        else if (r < mix#round + mix#square) CornerStyle.Square
        else CornerStyle.Diamond

    // ════════════════════════════════════════════════════════
    // 輪郭の変形(四角=中心点を差す・丸=二次曲線の折れ線化・揺らぎ=中点ずらし)
    // ════════════════════════════════════════════════════════

    /// 対角辺にタイル中心を実頂点として差す(四角スタイル)。直角の角になる。
    pub def squareOff(tile: Float64, poly: List[Vec2.Vec2]): List[Vec2.Vec2] =
        let center = { x = tile / 2.0, y = tile / 2.0 };
        edgesOf(poly) |> List.flatMap(match (a, b) ->
            if (isDiagonal(a, b) and not onTileBorder(tile, a, b)) a :: center :: Nil
            else a :: Nil)

    /// 対角辺を「タイル中心を制御点にした二次曲線」として4分割した折れ線(端点含む5点)。
    /// 凸の角は丸柱の弧に、凹の角(内角)は滑らかなくぼみになる。
    pub def roundEdge(tile: Float64, a: Vec2.Vec2, b: Vec2.Vec2): List[Vec2.Vec2] =
        Bezier.quadratic(a, { x = tile / 2.0, y = tile / 2.0 }, b, 4)

    /// 丸スタイルの輪郭。対角辺だけを折れ線に差し替える(タイル境界の辺は直線のまま)。
    pub def roundOff(tile: Float64, poly: List[Vec2.Vec2]): List[Vec2.Vec2] =
        edgesOf(poly) |> List.flatMap(match (a, b) ->
            if (isDiagonal(a, b) and not onTileBorder(tile, a, b))
                roundEdge(tile, a, b) |> List.take(4)
            else a :: Nil)

    /// 対角辺の中点を法線方向に座標ハッシュでずらした3点の折れ線(洞窟の岩肌)。
    /// 丸スタイルには掛けない — 曲線の柔らかさと揺らぎは両立しないため呼び側で分ける。
    pub def jitteredEdge(corner: (Int32, Int32), amount: Float64, k: Int32,
                         a: Vec2.Vec2, b: Vec2.Vec2): List[Vec2.Vec2] =
        let (i, j) = corner;
        let offset = (hash(i, j, 51 + k) - 0.5) * 4.5 * amount;
        let n = Vec2.normalized({ x = b#y - a#y, y = 0.0 - (b#x - a#x) });
        a :: Vec2.add(Vec2.mul(Vec2.add(a, b), 0.5), Vec2.mul(n, offset)) :: b :: Nil

    // ════════════════════════════════════════════════════════
    // 純粋な幾何の小道具
    // ════════════════════════════════════════════════════════

    def feq(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 0.001

    /// タイル境界(ローカル座標の外周)上の辺か。隣のデュアルタイルと必ず同じ埋まり方に
    /// なるので、この辺には陰影を描かない。
    pub def onTileBorder(tile: Float64, a: Vec2.Vec2, b: Vec2.Vec2): Bool =
        (feq(a#x, b#x) and (feq(a#x, 0.0) or feq(a#x, tile))) or
        (feq(a#y, b#y) and (feq(a#y, 0.0) or feq(a#y, tile)))

    /// 縦横どちらにも動く辺(=ひし形の対角辺)か。スタイル変形はこの辺にだけ掛かる。
    pub def isDiagonal(a: Vec2.Vec2, b: Vec2.Vec2): Bool =
        not feq(a#x, b#x) and not feq(a#y, b#y)

    /// 多角形の辺の列(最後の頂点から先頭へ戻る辺を含む)。
    pub def edgesOf(poly: List[Vec2.Vec2]): List[(Vec2.Vec2, Vec2.Vec2)] =
        match poly {
            case Nil        => Nil
            case first :: _ => List.zip(poly, List.append(List.drop(1, poly), first :: Nil))
        }

    /// 点が多角形の中にあるか(半直線との交差数の偶奇)。フチの外向き判定に使う。
    def pointIn(pt: Vec2.Vec2, poly: List[Vec2.Vec2]): Bool =
        edgesOf(poly) |> List.foldLeft((inside, edge) -> {
            let (a, b) = edge;
            let crosses = ((a#y > pt#y) != (b#y > pt#y))
                and (pt#x < (b#x - a#x) * (pt#y - a#y) / (b#y - a#y) + a#x);
            if (crosses) not inside else inside
        }, false)

    /// 辺 a→b の外向き(多角形の外を指す)単位法線。中点を少し押した点の内外で機械的に決める。
    pub def outwardNormal(poly: List[Vec2.Vec2], a: Vec2.Vec2, b: Vec2.Vec2): Vec2.Vec2 =
        let n = Vec2.normalized({ x = b#y - a#y, y = 0.0 - (b#x - a#x) });
        let mid = Vec2.mul(Vec2.add(a, b), 0.5);
        if (pointIn(Vec2.add(mid, n), poly)) Vec2.neg(n) else n

    /// 折れ線に沿う内側向きの stroke(輪郭のフチ取り)。小辺ごとに自分の法線で
    /// width ぶん内側へ押し込んだ四角形を作る。向きは refNormal(辺全体の外向き)にそろえる。
    pub def strokeQuads(points: List[Vec2.Vec2], refNormal: Vec2.Vec2,
                      width: Float64): List[List[Vec2.Vec2]] =
        List.zip(points, List.drop(1, points)) |> List.map(match (a, b) -> {
            let raw = Vec2.normalized({ x = b#y - a#y, y = 0.0 - (b#x - a#x) });
            let n = if (Vec2.dot(raw, refNormal) < 0.0) Vec2.neg(raw) else raw;
            a :: b :: Vec2.sub(b, Vec2.mul(n, width)) :: Vec2.sub(a, Vec2.mul(n, width)) :: Nil
        })

    /// 折れ線の最後の点を落とす(輪郭を辺ごとにつなぐとき、次の辺の先頭と重複するため)。
    pub def initOf(points: List[Vec2.Vec2]): List[Vec2.Vec2] =
        List.take(List.length(points) - 1, points)

    // ════════════════════════════════════════════════════════
    // 多角形クリップ(持ち上げた壁の食み込みを切るなどの道具)
    // ════════════════════════════════════════════════════════

    /// 多角形を軸平行矩形で切り取る(Sutherland–Hodgman)。完全に外なら空。
    pub def clipPolyRect(rect: Rect2.Rect2, poly: List[Vec2.Vec2]): List[Vec2.Vec2] =
        let x0 = rect#position#x;
        let y0 = rect#position#y;
        let x1 = x0 + rect#size#x;
        let y1 = y0 + rect#size#y;
        let cutPoly = poly
            |> clipHalfPlane(v -> v#x - x0)
            |> clipHalfPlane(v -> x1 - v#x)
            |> clipHalfPlane(v -> v#y - y0)
            |> clipHalfPlane(v -> y1 - v#y);
        if (List.length(cutPoly) >= 3) cutPoly else Nil

    /// inside(v) >= 0 の側だけを残す半平面切り。境界をまたぐ辺には交点を差す。
    def clipHalfPlane(inside: Vec2.Vec2 -> Float64, poly: List[Vec2.Vec2]): List[Vec2.Vec2] =
        edgesOf(poly) |> List.flatMap(match (a, b) -> {
            let da = inside(a);
            let db = inside(b);
            if (da >= 0.0 and db >= 0.0) a :: Nil
            else if (da >= 0.0) a :: Vec2.lerp(a, b, da / (da - db)) :: Nil
            else if (db >= 0.0) Vec2.lerp(a, b, da / (da - db)) :: Nil
            else Nil
        })

    /// 多角形の面積(靴ひも公式の絶対値)。クリップの検算と潰れた切れ端の間引きに使う。
    pub def polygonArea(poly: List[Vec2.Vec2]): Float64 =
        edgesOf(poly)
            |> List.map(match (a, b) -> a#x * b#y - b#x * a#y)
            |> List.foldLeft((acc, v) -> acc + v, 0.0)
            |> Float64.abs
            |> (s -> s / 2.0)
}
