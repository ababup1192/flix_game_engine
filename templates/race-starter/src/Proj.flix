// Proj — 疑似遠近の投影（純粋な数学だけの小モジュール）。
// 見下ろしではなく「前を向いて走る」絵にするため、コースの 1 行を画面のセグメント
// 1 本（横長の台形）に写す。
// セグメントの高さと横幅は奥の行ほど等比（shrink 倍）で縮む — 割り算 1 回と累乗 1 回で
// 「近くは速く・遠くはゆっくり」流れる遠近が出る。3D の行列は持ち込まない
// （この画面に必要なのは縦 1 軸の収束だけで、行列は保守の重さに見合わない）。
//
// 物差しは u = 「自機の見かけ基準（w#distance）から何行先か」の実数 1 本。
// View の各層はまず u を出し、yOf / scaleOf / screenX で画面座標へ写す —
// 投影の式をここ以外に書かない（2 か所に書くとセグメントと立ち物が静かにずれる）。
mod Proj {

    /// 一番手前のセグメント（u=0..1）の画面上の高さ（px）。
    pub def h0(): Float64 = 46.0

    /// 1 行奥へ進むごとにセグメントが縮む比率。1 に近いほど地平線が高く遠くなる。
    pub def shrink(): Float64 = 0.83

    /// u 行先のセグメントの手前端が画面のどの高さに来るか。
    /// 等比数列の和（h0 + h0*s + h0*s^2 + …）を閉じた式で書いたもの —
    /// セグメントを 1 本ずつ足し上げるループを回さずに、任意の実数 u で一発で引ける。
    pub def yOf(u: Float64): Float64 =
        World.designH() - h0() * (1.0 - Float64.pow(base = shrink(), u)) / (1.0 - shrink())

    /// u 行先での縮み（手前 1.0 → 遠くほど 0 へ）。横幅・立ち物の大きさ・線の太さに共通で掛ける。
    pub def scaleOf(u: Float64): Float64 =
        Float64.pow(base = shrink(), u)

    /// セグメントが収束する地平線の y（≈ 89.4）。空と海はこれより上、道はこれより下。
    pub def horizonY(): Float64 =
        World.designH() - h0() / (1.0 - shrink())

    /// 自機が描かれる u（World.playerAheadPx と対 — 絵と当たりの物差しを分けない）。
    pub def playerU(): Float64 =
        World.playerAheadPx() / World.rowPitch()

    /// カメラが「その先を見ている」u。ここの曲がりぶんだけ画面を振る。
    def lookU(): Float64 = 4.0

    /// カメラを振れる上限（px）。ここで止めないと、急カーブで自機ごと画面の外へ流れる。
    /// 画面の幅の 1/5 まで。これ以上振ると、コーナーの先は見えるが自機が縁に貼り付く。
    def yawMax(): Float64 = World.designW() / 5.0

    /// 振りを上限へ滑らかに近づける。硬く切ると急カーブでは常に上限へ貼り付き、
    /// 自機が画面の縁に固定されてしまう（コーナーの先は見えるが、自分がどこにいるか読めない）。
    /// x / (1 + |x|/上限) は小さい振りをほぼそのまま通し、大きい振りだけを上限へ近づける。
    def softYaw(x: Float64): Float64 =
        x / (1.0 + Float64.abs(x) / yawMax())

    /// 曲がりと坂は「1 行ごとの強さを 2 回足し上げる」まったく同じ数式なので、
    /// 表も引き方も 1 組の型で共有する（横に効くか縦に効くかだけが違う）。
    ///   c1 … 強さを 1 回足し上げた表（= その行での向き・傾き）。
    ///   c2 … c1 をもう 1 回足し上げた表（= その行までに動いた量）。
    pub type alias Ramp = { c1 = Vector[Float64], c2 = Vector[Float64] }

    /// 1 フレームぶんのカメラ。
    ///   off  … カメラが道の中心からどれだけ横にずれて構えているか（px）。
    ///   bend … 画面の真ん中に置く「道の折れ」の量（px）。
    ///   lift … 画面の真ん中に置く「道の高さ」の量（px）。
    ///   turnRamp / hillRamp … 曲がりと坂の足し上げ表。
    ///   frac … カメラが乗っている行の中のどこにいるか（0..1）。
    pub type alias Cam = { off = Float64, bend = Float64, lift = Float64,
                           turnRamp = Ramp, hillRamp = Ramp, frac = Float64 }

    /// カメラを 1 回だけ決める。横は自機に 0.72 だけ付いていき（残り 0.28 は道の中心に残す）、
    /// 振りは lookU 行先の折れへ yawGain ぶん向ける — コーナーの入口で画面が先に内側を向き、
    /// 頂点が画面に残ったまま出口だけが外へ流れる。
    /// 坂は自機の足元をいつも同じ高さに保つ（lift）— そうしないと登り坂で画面ごと沈む。
    pub def camOf(w: World.World): Cam =
        let rowF = w#distance / World.rowPitch();
        let base = Num.floorInt(rowF);
        let frac = rowF - Int32.toFloat64(base);
        let turnRamp = rampOf(n -> World.curveAt(n, w#course), base);
        let hillRamp = rampOf(n -> CourseDoc.hillAt(n, w#course), base);
        let half = { off = 0.0, bend = 0.0, lift = 0.0,
                     turnRamp = turnRamp, hillRamp = hillRamp, frac = frac };
        let atMe = bendAt(half, playerU());
        let ahead = bendAt(half, lookU());
        let yaw = softYaw(RulesDoc.rec(w#rules)#yawGain * (ahead - atMe));
        { off = 0.72 * w#playerOff, bend = atMe + yaw,
          lift = hillAt(half, playerU()) | half }

    /// 1 行ごとの強さ strength を 2 回足し上げた表。添字 i は行位置 s = i-1 の所。
    /// 画面の下へはみ出すセグメントが 1 本あるので、1 行手前から積む。
    /// 1 行の中では向きが直線に変わるので、2 回目の足し上げはその台形の面積を足す。
    def rampOf(strength: Int32 -> Float64, base: Int32): Ramp =
        let len = rowsVisible() + 3;
        let c1 = runningSum(len, j -> strength(base - 1 + j));
        let c2 = runningSum(len, j -> {
            let lo = Vector.get(j, c1);
            let hi = Vector.get(Int32.min(j + 1, len - 1), c1);
            (lo + hi) / 2.0
        });
        { c1 = c1, c2 = c2 }

    /// 表 f(0), f(1), … を頭から足し上げた表（先頭は 0・長さ len）。
    /// 添字ごとに 0 から数え直すと、表 1 枚に len^2 / 2 回の足し算がかかる —
    /// セグメントを 37 本ぶん・曲がりと坂の 2 組・二重に足し上げるので、毎フレームでは効いてくる。
    def runningSum(len: Int32, f: Int32 -> Float64): Vector[Float64] =
        let (_, rev) = List.range(0, len) |> List.foldLeft((acc, i) -> {
            let (sum, out) = acc;
            if (i == 0) (0.0, 0.0 :: out)
            else { let s = sum + f(i - 1); (s, s :: out) }
        }, (0.0, Nil));
        List.reverse(rev) |> List.toVector

    /// 行位置 s（-1 が表の先頭）での向き。表の外は端で止める。
    def headingOf(ramp: Ramp, s: Float64): Float64 =
        let (i, f) = cell(ramp#c1, s);
        let lo = Vector.get(i, ramp#c1);
        lo + f * (Vector.get(i + 1, ramp#c1) - lo)

    /// 行位置 s での動きの累積。行の中は向きが直線に変わるので二次式で継ぐ。
    def sweepOf(ramp: Ramp, s: Float64): Float64 =
        let (i, f) = cell(ramp#c1, s);
        let lo = Vector.get(i, ramp#c1);
        let k = Vector.get(i + 1, ramp#c1) - lo;
        Vector.get(i, ramp#c2) + f * lo + f * f * k / 2.0

    /// 行位置 s が表のどの升のどこか（升の添字, 升の中の 0..1）。表の外は端で止める。
    def cell(cum: Vector[Float64], s: Float64): (Int32, Float64) =
        let last = Int32.toFloat64(Vector.length(cum) - 3);
        let clamped = Num.clamp(-1.0, last, s);
        let a = Num.floorInt(clamped);
        (a + 1, clamped - Int32.toFloat64(a))

    /// カメラから u 行先の「足し上げた量」（px）。カメラの向きでまっすぐ伸ばした分を引く —
    /// カメラは常に「いま向いている方向」を正面に構えるので、通り過ぎたコーナーや
    /// 登りきった坂は後ろに置いていける。
    def rampAt(ramp: Ramp, frac: Float64, u: Float64): Float64 =
        sweepOf(ramp, frac + u) - sweepOf(ramp, frac) - u * headingOf(ramp, frac)

    /// カメラから u 行先の道の折れ（px）。
    /// ここに縮み（scaleOf）を掛けないのが肝。掛けると遠いセグメントほど横ずれが消えて、
    /// 道はどう曲げても消失点へ収束してしまう（45 度より急なカーブが描けなくなる）。
    pub def bendAt(cam: Cam, u: Float64): Float64 =
        rampAt(cam#turnRamp, cam#frac, u)

    /// カメラから u 行先の道の高さ（px・+ が高い）。曲がりとまったく同じ数式で、
    /// 効く先が横から縦へ変わっただけ。
    pub def hillAt(cam: Cam, u: Float64): Float64 =
        rampAt(cam#hillRamp, cam#frac, u)

    /// u 行先のセグメントの手前端が画面のどの高さに来るか（坂ぶんを差し引いた本番の値）。
    /// 高い所ほど画面の上へ来るので引き算。自機の足元の高さ（cam#lift）を戻すのは、
    /// 坂の途中でも自機が画面の同じ高さに座り続けるようにするため。
    pub def yAt(cam: Cam, u: Float64): Float64 =
        yOf(u) - hillAt(cam, u) + cam#lift

    /// 坂で上下する地平線（空と海の境）。遠くの道が消えていく高さに合わせて動かす —
    /// 動かさないと、登りで道が水平線を突き抜けて海の上を走ることになる。
    /// 振れ幅を止めるのは、急な坂で空か海のどちらかが画面から消えないようにするため。
    pub def horizonYAt(cam: Cam): Float64 =
        horizonY() - Num.clamp(-26.0, 26.0, hillAt(cam, horizonU()) - cam#lift)

    /// 地平線の高さを決めるときに覗く先の行。ここより奥はセグメントが 1px を切ってつぶれる。
    def horizonU(): Float64 = 13.0

    /// 道の中心からの横ずれ off（px）を u 行先の画面 x へ。
    /// 道の中の位置は遠くほど中央へすぼまり（縮みを掛ける）、道そのものの折れはそのまま乗る。
    pub def screenX(cam: Cam, off: Float64, u: Float64): Float64 =
        World.designW() / 2.0 + (off - cam#off) * scaleOf(u) + bendAt(cam, u) - cam#bend

    /// セグメント 1 本の辺（ある u）で共通の投影の値。縮み・高さ・道の折れは、その u の上なら
    /// どの点でも同じ答えになる。
    pub type alias Edge = { k = Float64, y = Float64, bend = Float64,
                            camBend = Float64, camOff = Float64 }

    /// u の辺を 1 回だけ引く。折れ（bendAt）は表を 2 度足し上げて引くので、
    /// 1 本の辺に何十個も点を写す層（路面の轍・草の縦筋）で点ごとに引き直すと、
    /// 同じ足し上げが点の数だけ走る。
    pub def edgeOf(cam: Cam, u: Float64): Edge =
        { k = scaleOf(u), y = yAt(cam, u), bend = bendAt(cam, u),
          camBend = cam#bend, camOff = cam#off }

    /// 道の中心からの横ずれ off を、この辺の画面 x へ（式は screenX と同じ）。
    pub def edgeX(e: Edge, off: Float64): Float64 =
        World.designW() / 2.0 + (off - e#camOff) * e#k + e#bend - e#camBend

    /// 前進距離 dist（世界 px）が自機の見かけ基準から何行先か。
    /// 自機自身は World.playerAheadPx() だけ先にいるので u ≈ 1.35 に描かれる。
    pub def uOf(w: World.World, dist: Float64): Float64 =
        (dist - w#distance) / World.rowPitch()

    /// コースに沿った 1 点（x = 道の中心からの横ずれ px, y = 前進距離 px）を画面へ。
    /// k はその距離での縮み — タイヤ痕や煙の大きさをここから導く。
    pub def projectPoint(cam: Cam, w: World.World, pt: Vec2.Vec2): { x = Float64, y = Float64, k = Float64 } =
        let u = uOf(w, pt#y);
        { x = screenX(cam, pt#x, u), y = yAt(cam, u), k = scaleOf(u) }

    /// u 行先の物を「空の低いほうの色」へどれだけ近づけるか（0 = そのまま, 1 = 空の色）。
    /// 効かせるのは地平線ぎわ（hazeNear 行より奥）だけ。縮み 1-scale から引くと画面の
    /// 半分より手前で既に 3 割混ざり、真夏の日向なのに草の緑と路面の灰が同じ薄色へ寄る。
    /// 路面・草・ヤシ・コーンに同じ強さで掛ける — 掛ける物を選ぶと遠近が食い違う。
    pub def hazeAt(u: Float64): Float64 =
        let t = Num.clamp01((Float64.max(0.0, u) - hazeNear()) / hazeSpan());
        0.9 * t * t * (3.0 - 2.0 * t)

    /// 霞みが効き始める行数。画面の半分は u ≈ 6 なので、そこまでは彩度をそのまま残す。
    def hazeNear(): Float64 = 9.0

    /// 霞みが 0 から満杯になるまでの行数。地平線に届く手前で飽和させて、
    /// 最奥のセグメントが空の色に溶けて閉じるようにする。
    def hazeSpan(): Float64 = 16.0

    /// 立ち物（ヤシ・コーン・アイテム・車・煙）の z。近い（u が小さい）ほど手前。
    /// セグメント 1 本を z 4 刻みに割るので、同じセグメントの中の前後（u0+0.25 と u0+0.75）も正しく重なる。
    pub def zOf(u: Float64): Int32 =
        Int32.max(20, Int32.min(76, 76 - Num.floorInt(u * 4.0)))

    /// セグメント 1 本ぶんの割り当て。
    ///   n    … そのセグメントが写すコースの通し行（周回しても増え続ける）。
    ///   u0   … そのセグメントの手前端の u（先頭は -1.0 近くまで下がり、画面下へはみ出す）。
    ///   du   … 何行ぶんの厚みか（セグメントを細かく割ったときは 1 未満になる）。
    ///   head … その行の先頭の切れ端か（行に 1 回だけ置く物の目印）。
    pub type alias Segment = { n = Int32, u0 = Float64, du = Float64, head = Bool }

    /// 画面に見えているセグメントの並び（奥から手前へ rowsVisible 本）。
    /// セグメントの行割りをここに 1 本化する — ViewRoad と ViewScene（ヤシ）が同じ行を見る。
    /// 奥から積むのは、坂があるとセグメントどうしが画面の上で重なるため —— 後から積んだ手前が
    /// 奥を隠して、丘の向こうの道が見えなくなる（平らな道では並び順で絵は変わらない）。
    pub def segments(w: World.World): List[Segment] =
        let rowF = w#distance / World.rowPitch();
        let base = Num.floorInt(rowF);
        let frac = rowF - Int32.toFloat64(base);
        List.range(0, rowsVisible()) |> List.map(i -> {
            let seg = rowsVisible() - 1 - i;
            ({ n = base + seg, u0 = Int32.toFloat64(seg) - frac, du = 1.0, head = true }: Segment)
        })

    /// セグメントの本数。34 本まで積むと最奥のセグメントの残り高さが 0.5px を切り、
    /// 道が地平線に触れて閉じる。ここを減らすと道が宙で途切れて草が覗く。
    pub def rowsVisible(): Int32 = 34
}
