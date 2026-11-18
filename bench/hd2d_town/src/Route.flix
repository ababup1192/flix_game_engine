// Route — 曲がり角のある道を歩く隊列（先頭が曲がり角の点を速さ v で順にたどり、点ごとの待ちで止まる）と、
// その道を追うカメラ（横と奥は歩く間は遅れ 0・止まる・曲がる所だけ stopSec かけて丸める）。座標は地図の座標（x = 東・y = 北）。
mod Route {
    use fge::{JsonCodec, Num}
    use Util.Json.Json

    /// 向き（地図の東西南北）。
    pub enum Dir with Eq, ToString {
        case North
        case East
        case South
        case West
    }

    /// 道の 1 区間。s0・s1 = 道のりの始まりと終わり（m）・start・finish = 端の点。
    pub type alias Segment = { s0 = Float64, s1 = Float64, start = (Float64, Float64), finish = (Float64, Float64), dir = Dir }

    /// 道。knots = (時刻, 道のり) の折れ線（待ちの間は道のりが止まる）・endAt = 先頭が止まる時刻。
    pub type alias Route = { segments = List[Segment], knots = List[(Float64, Float64)], length = Float64, endAt = Float64 }

    /// 曲がり角の点（マスの列・行・その点に着いた後の待ち秒）。
    pub type alias Waypoint = { col = Int32, row = Int32, wait = Float64 }

    /// 道の点の Doc の形 [列, 行] か [列, 行, 待ち秒] を読む（地図の walk.path・台本の path）。
    pub def waypointOf(j: Json): Option[Waypoint] =
        JsonCodec.decodeList(JsonCodec.expectFloat, j) |> Option.flatMap(xs -> match xs {
            case c :: r :: rest => Some({ col = Float64.round(c) |> Float64.tryToInt32 |> Option.getWithDefault(0),
                                          row = Float64.round(r) |> Float64.tryToInt32 |> Option.getWithDefault(0),
                                          wait = List.head(rest) |> Option.getWithDefault(0.0) })
            case _ => None
        })

    /// 向きの字（n・e・s・w）。知らない字は南（正面）。
    pub def dirOfLetter(letter: String): Dir = match letter {
        case "n" => Dir.North
        case "e" => Dir.East
        case "w" => Dir.West
        case _   => Dir.South
    }

    def dirOf(a: (Float64, Float64), b: (Float64, Float64)): Dir =
        if (fst(b) > fst(a) + 0.000001) Dir.East
        else if (fst(b) < fst(a) - 0.000001) Dir.West
        else if (snd(b) > snd(a)) Dir.North
        else Dir.South

    def unitOf(d: Dir): (Float64, Float64) = match d {
        case Dir.North => (0.0, 1.0)
        case Dir.East  => (1.0, 0.0)
        case Dir.South => (0.0, -1.0)
        case Dir.West  => (-1.0, 0.0)
    }

    /// 地図の高さ mapHeight の地図の上で、点の列 points を速さ speed（m/秒）で、startAt 秒に歩き出す道。
    pub def make(mapHeight: Int32, points: List[Waypoint], speed: Float64, startAt: Float64): Route =
        let centers = points |> List.map(w -> (Int32.toFloat64(w#col) + 0.5, Int32.toFloat64(mapHeight - 1 - w#row) + 0.5));
        let pairs = List.zip(centers, List.drop(1, centers));
        let lengths = pairs |> List.map(ab -> { let (a, b) = ab; Num.sqrt((fst(b) - fst(a)) * (fst(b) - fst(a)) + (snd(b) - snd(a)) * (snd(b) - snd(a))) });
        let starts = List.scanLeft((acc, l) -> acc + l, 0.0, lengths);
        let segments = List.zip(List.zip(pairs, lengths), starts) |> List.map(t -> {
            let (((a, b), l), s0) = t;
            { s0 = s0, s1 = s0 + l, start = a, finish = b, dir = dirOf(a, b) }
        });
        let waits = points |> List.drop(1) |> List.map(w -> w#wait);
        let knots = List.zip(segments, waits) |> List.foldLeft((acc, sw) -> {
            let (seg, wait) = sw;
            let (t, _) = List.head(acc) |> Option.getWithDefault((startAt, 0.0));
            let arrive = t + (seg#s1 - seg#s0) / speed;
            if (wait > 0.0) (arrive + wait, seg#s1) :: (arrive, seg#s1) :: acc else (arrive, seg#s1) :: acc
        }, (startAt, 0.0) :: Nil) |> List.reverse;
        let lastWait = List.last(waits) |> Option.getWithDefault(0.0);
        let endAt = (List.last(knots) |> Option.map(fst) |> Option.getWithDefault(startAt)) - lastWait;
        { segments = segments, knots = knots, length = List.foldLeft((a, l) -> a + l, 0.0, lengths), endAt = endAt }

    /// 時刻 t の先頭の道のり。
    pub def distanceAt(r: Route, t: Float64): Float64 =
        let pairs = List.zip(r#knots, List.drop(1, r#knots));
        match List.find(p -> t <= fst(snd(p)), pairs) {
            case Some(((ta, sa), (tb, sb))) =>
                if (t <= ta) sa else sa + (sb - sa) * (t - ta) / Float64.max(tb - ta, 0.000000001)
            case None => r#length
        }

    /// 時刻 t に先頭が歩いているか。
    pub def isMoving(r: Route, t: Float64): Bool = Float64.abs(distanceAt(r, t + 0.001) - distanceAt(r, t - 0.001)) > 0.000001

    /// 道のり s の点と向き。s が 0 より前は最初の区間を後ろへ延ばした所（隊列の後ろの人）。
    pub def pointAt(r: Route, s: Float64): ((Float64, Float64), Dir) =
        List.find(seg -> s <= seg#s1 + 0.000000001, r#segments)
            |> Option.map(seg -> {
                let (ux, uy) = unitOf(seg#dir);
                let k = s - seg#s0;
                ((fst(seg#start) + ux * k, snd(seg#start) + uy * k), seg#dir)
            })
            |> Option.withDefault(default = List.last(r#segments) |> Option.map(seg -> (seg#finish, seg#dir)))
            |> Option.getWithDefault(((0.0, 0.0), Dir.North))

    /// 値の列をそろえた Hann 窓でならす（真ん中をそろえるので等速の所はそのまま＝遅れ 0、止まる・曲がる所だけ丸くなる）。
    /// half = 窓の半分の幅（コマ数）。
    pub def hannSmooth(half: Int32, xs: Vector[Float64]): Vector[Float64] =
        let n = Vector.length(xs);
        let weights = List.range(0, 2 * half + 1) |> List.map(k -> 0.5 - 0.5 * Num.cos(2.0 * Num.pi() * Int32.toFloat64(k + 1) / Int32.toFloat64(2 * half + 2)));
        let total = List.foldLeft((a, w) -> a + w, 0.0, weights);
        let at = (i: Int32) -> Vector.get(Num.clampInt(0, n - 1, i), xs);
        Vector.range(0, n) |> Vector.map(i ->
            List.zipWithIndex(weights) |> List.foldLeft((acc, kw) -> { let (k, w) = kw; acc + w * at(i + k - half) }, 0.0) / total)

    /// 高さを指数で遅れて追わせる（毎コマ 1 − exp(−k·dt) だけ近づく）。
    pub def lagged(k: Float64, dt: Float64, xs: Vector[Float64]): Vector[Float64] =
        let a = 1.0 - Float64.pow(base = 2.718281828459045, 0.0 - k * dt);
        Vector.foldLeft((acc, x) -> match List.head(acc) {
            case Some(prev) => (prev + (x - prev) * a) :: acc
            case None       => x :: acc
        }, Nil, xs) |> List.reverse |> List.toVector
}
