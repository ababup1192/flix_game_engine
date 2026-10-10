// UiTooltip — 説明の窓（ツールチップ）を、見ている物の脇の「画面からはみ出さず、
// 大事な物に重ならない」所へ置く。置き方を画面ごとに書き分けずに済む。
// 利用例: カードの脇に効果の説明を出す / マウスの指の脇に用語の説明を出す / 状態アイコンの説明を出す。
//
// 置き方（web の Floating UI の flip + shift と同じ考え）:
//   1. sides の順に、見ている物（anchor）の右・左・下・上へ gap だけ離して置いてみる。
//   2. 横に出すときは上下、縦に出すときは左右だけを画面（bounds）の内側へずらす
//      （出す向きそのものはずらさない —— ずらすと見ている物に被る）。
//   3. 画面に収まり、anchor と avoid のどれにも重ならない最初の向きを採る。
//      どの向きもだめなら「はみ出す量 → 重なる面積」が一番小さい向きを、画面の内側へ押し込んで採る。
// 窓の大きさは呼ぶ側が決める（字を折るのは RichText.wrapLinesBy）。ここは置き場所だけを返す純粋な関数。

pub mod UiTooltip {

    /// 窓を出す向き（見ている物から見て）。
    pub enum Side with Eq, ToString {
        case Right
        case Left
        case Bottom
        case Top
    }

    /// 置き場所の注文。anchor = 見ている物の枠（マウスの指なら大きさ 0 の枠）、size = 窓の大きさ、
    /// bounds = 収める範囲（ふつうは画面）、avoid = 重ねたくない物（隣のカード・HP の棒など）、
    /// gap = anchor から離す間、sides = 試す向きの順。
    pub type alias Request = {
        anchor = Rect2.Rect2,
        size   = Vec2.Vec2,
        bounds = Rect2.Rect2,
        avoid  = List[Rect2.Rect2],
        gap    = Float64,
        sides  = List[Side]
    }

    /// 窓の左上と大きさ（Request の決まりで選んだ 1 か所）。
    pub def computePlacement(req: Request): Rect2.Rect2 =
        let sides = if (List.isEmpty(req#sides)) defaultSides() else req#sides;
        let tried = sides |> List.map(side -> {
            let rect = candidate(side, req);
            (overflow(rect, req#bounds), overlap(rect, req#anchor :: req#avoid), rect)
        });
        let pick = match List.find(t -> { let (out, hit, _) = t; out <= 0.0 and hit <= 0.0 }, tried) {
            case Some((_, _, rect)) => rect
            case None               =>
                tried
                    |> List.minimumBy((a, b) -> {
                        let (outA, hitA, _) = a;
                        let (outB, hitB, _) = b;
                        (outA, hitA) <=> (outB, hitB)
                    })
                    |> Option.map(t -> { let (_, _, rect) = t; rect })
                    |> Option.getWithDefault({ position = req#anchor#position, size = req#size })
        };
        clampInto(req#bounds, pick)

    /// 既定の向きの順（右 → 左 → 下 → 上。横書きの画面で、読んでいる物の続きに出る順）。
    pub def defaultSides(): List[Side] = Side.Right :: Side.Left :: Side.Bottom :: Side.Top :: Nil

    /// 画面の真ん中から遠ざかる向きを先に試す順（左半分の物は右 → 左、右半分の物は左 → 右。
    /// 縦も同じ）。真ん中に寄った窓は画面の中身を覆いやすいので、外側へ逃がしたいときに使う。
    pub def sidesAwayFromCenter(anchor: Rect2.Rect2, bounds: Rect2.Rect2): List[Side] =
        let a = Rect2.center(anchor);
        let b = Rect2.center(bounds);
        let (h1, h2) = if (a#x <= b#x) (Side.Right, Side.Left) else (Side.Left, Side.Right);
        let (v1, v2) = if (a#y <= b#y) (Side.Bottom, Side.Top) else (Side.Top, Side.Bottom);
        h1 :: h2 :: v1 :: v2 :: Nil

    /// 1 つの向きに置いた窓（出す向きと直角の方向だけ bounds の内側へずらしてある）。
    def candidate(side: Side, req: Request): Rect2.Rect2 =
        let a = req#anchor;
        let s = req#size;
        let b = req#bounds;
        let crossX = clampAxis(a#position#x, s#x, b#position#x, b#size#x);
        let crossY = clampAxis(a#position#y, s#y, b#position#y, b#size#y);
        let at = match side {
            case Side.Right  => { x = a#position#x + a#size#x + req#gap, y = crossY }
            case Side.Left   => { x = a#position#x - req#gap - s#x,      y = crossY }
            case Side.Bottom => { x = crossX, y = a#position#y + a#size#y + req#gap }
            case Side.Top    => { x = crossX, y = a#position#y - req#gap - s#y }
        };
        { position = at, size = s }

    /// 窓が bounds からはみ出す長さ（上下左右の合計。収まっていれば 0）。
    def overflow(rect: Rect2.Rect2, bounds: Rect2.Rect2): Float64 =
        let e = Rect2.end(rect);
        let be = Rect2.end(bounds);
        Float64.max(0.0, bounds#position#x - rect#position#x)
            + Float64.max(0.0, bounds#position#y - rect#position#y)
            + Float64.max(0.0, e#x - be#x)
            + Float64.max(0.0, e#y - be#y)

    /// 窓が rects に重なる面積の合計（接しているだけなら 0）。
    def overlap(rect: Rect2.Rect2, rects: List[Rect2.Rect2]): Float64 =
        rects |> List.foldLeft((sum, other) -> {
            let cut = Rect2.intersect(rect, other);
            if (cut#size#x > 0.0 and cut#size#y > 0.0) sum + Rect2.area(cut) else sum
        }, 0.0)

    /// 1 本の軸で、start から長さ len の物を [lo, lo+room] へ収める（入り切らなければ lo に寄せる）。
    def clampAxis(start: Float64, len: Float64, lo: Float64, room: Float64): Float64 =
        Float64.max(lo, Float64.min(lo + room - len, start))

    /// 窓全体を bounds の内側へ押し込む（どの向きもはみ出したときの最後の手）。
    def clampInto(bounds: Rect2.Rect2, rect: Rect2.Rect2): Rect2.Rect2 =
        { position = { x = clampAxis(rect#position#x, rect#size#x, bounds#position#x, bounds#size#x),
                       y = clampAxis(rect#position#y, rect#size#y, bounds#position#y, bounds#size#y) },
          size = rect#size }
}
