// Journey — 脚(出発点・行き先・速さ)の列を「時刻の純関数」で歩く。
// 状態は出発時刻だけ持てばよく、進行は経過秒 t から式で導く(Anim/Fx と同じ原則)。
// 到着の判定(done)と絵の位置(pos)を同じ戻り値で返すのが肝 —
// ルールと絵が別々の計算を持つと「絵はまだ歩いているのに判定は着いている」型の
// ワープが生まれる。両方が同じ Sample を読めばその食い違いは構造的に消える。
// walking は歩き始めからの累計 px(歩きコマ = floor(walking / 歩幅) の種)。

pub mod Journey {

    /// 脚: src から dst へ speed(px/秒)で歩く(純データ)。
    pub type alias Leg = { src = Vec2.Vec2, dst = Vec2.Vec2, speed = Float64 }

    /// 時刻 t の見本。pos は現在地、walking は歩いた累計 px、done は全脚を歩き終えたか。
    pub type alias Sample = { pos = Vec2.Vec2, walking = Float64, done = Bool }

    /// 脚 1 本の所要秒(距離 / 速さ)。速さ 0 以下は 0 秒(その場に着いている扱い)。
    pub def legDur(leg: Leg): Float64 =
        if (leg#speed <= 0.0) 0.0
        else Vec2.distanceTo(leg#dst, leg#src) / leg#speed

    /// 全脚の合計秒。t がこれ以上なら done。
    pub def total(legs: List[Leg]): Float64 =
        legs |> List.foldLeft((acc, leg) -> acc + legDur(leg), 0.0)

    /// t 秒時点の現在地。脚の途中なら src→dst の直線補間、全脚を過ぎたら
    /// 最後の dst に立って done。脚が無ければ原点で done(fail-open)。
    pub def at(legs: List[Leg], t: Float64): Sample =
        atWalked(legs, t, 0.0, { x = 0.0, y = 0.0 })

    def atWalked(legs: List[Leg], t: Float64, walked: Float64, last: Vec2.Vec2): Sample =
        match legs {
            case leg :: rest => {
                let dur = legDur(leg);
                if (t < dur) {
                    let k = Float64.max(0.0, Float64.min(1.0, t / dur));
                    { pos = { x = leg#src#x + (leg#dst#x - leg#src#x) * k,
                              y = leg#src#y + (leg#dst#y - leg#src#y) * k },
                      walking = walked + Float64.max(0.0, t) * leg#speed,
                      done = false }
                }
                else atWalked(rest, t - dur,
                    walked + Vec2.distanceTo(leg#dst, leg#src), leg#dst)
            }
            case Nil => { pos = last, walking = walked, done = true }
        }
}
