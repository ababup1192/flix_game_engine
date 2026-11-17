// Party — 台本で歩く隊列と追従カメラ（地図の walk 欄）。
// 先頭が col 列を fromRow 行から toRow 行まで北へ歩いて止まり、仲間は 1 マスずつ後ろの道をなぞる。
// カメラは歩く間は先頭と同じだけ動き（遅れ 0）、止まる時だけ stopSec かけてなめらかに止まる（先頭が止まる前後に半分ずつ）。
mod Party {
    use fge::{Num}
    use TownMap.{TownMap, Walk}

    /// 台本の時刻の決まり。speed = 歩く速さ（m/秒）・length = 歩く道のり（m）・
    /// startAt・stopAt = 先頭が歩き出す・止まる時刻（秒）・total = 撮る長さ（秒）。
    pub type alias Timeline = { speed = Float64, length = Float64, startAt = Float64, stopAt = Float64, settle = Float64, total = Float64 }

    /// 歩く速さ speed の台本の時刻を決める。
    pub def timelineOf(w: Walk, speed: Float64): Timeline =
        let length = Int32.toFloat64(w#fromRow - w#toRow);
        let startAt = w#idleSec;
        let stopAt = startAt + length / speed;
        { speed = speed, length = length, startAt = startAt, stopAt = stopAt, settle = w#stopSec, total = stopAt + w#stopSec / 2.0 + w#holdSec }

    /// 時刻 t の先頭の道のり（m・0..length）。
    pub def leaderAt(tl: Timeline, t: Float64): Float64 =
        Num.clamp(0.0, tl#length, (t - tl#startAt) * tl#speed)

    /// 時刻 t のカメラの道のり。先頭が止まる settle/2 前から速さを smoothstep で 0 へ落とす
    /// （落とす間に進む量は speed × settle / 2 なので、止まった所で先頭に追いつく）。カメラは後ろへ戻らない。
    // WhyNot: CameraRig.followDelta で先頭を追わない — 等速の間ずっと speed / k の遅れが残り、歩く間に先頭が画面の上へずれていく。
    pub def cameraAt(tl: Timeline, t: Float64): Float64 =
        let a = tl#stopAt - tl#settle / 2.0;
        if (t <= a) leaderAt(tl, t)
        else {
            let u = Float64.min((t - a) / tl#settle, 1.0);
            // ∫(1 − smoothstep) du = u − u³ + u⁴/2
            leaderAt(tl, a) + tl#speed * tl#settle * (u - u * u * u + 0.5 * u * u * u * u)
        }

    /// 先頭が歩いている間か。
    pub def isWalking(tl: Timeline, t: Float64): Bool = t >= tl#startAt and t < tl#stopAt

    /// i 番目（0 = 先頭）の歩きのコマ。歩いた距離で替え、止まっている間はコマ 1（足をそろえた絵）。
    pub def frameOf(w: Walk, tl: Timeline, t: Float64, i: Int32): Int32 =
        if (not isWalking(tl, t)) 1
        else {
            let s = leaderAt(tl, t) - Int32.toFloat64(i);
            let step = w#cycleTiles / Int32.toFloat64(w#frames);
            Int32.modulo(Float64.floor(s / step) |> Float64.tryToInt32 |> Option.getWithDefault(0), w#frames)
        }

    /// 隊列の 1 人の位置（地図の座標: x = 東・y = 北）。道はまっすぐ北なので、i 番目は道のり s − i の点（最初の区間を後ろへ延ばした所）。
    pub def memberAt(m: TownMap, tl: Timeline, t: Float64, i: Int32): (Float64, Float64) =
        let w = m#walk;
        let yEnd = Int32.toFloat64(m#height - 1 - w#toRow) + 0.5;
        (Int32.toFloat64(w#col) + 0.5, yEnd - tl#length + leaderAt(tl, t) - Int32.toFloat64(i))

    /// 時刻 t のカメラが追う点の北の座標（先頭が止まるマスの真ん中から、カメラの道のりだけ戻した所）。
    pub def cameraTargetY(m: TownMap, tl: Timeline, t: Float64): Float64 =
        let w = m#walk;
        let yEnd = Int32.toFloat64(m#height - 1 - w#toRow) + 0.5;
        yEnd - tl#length + cameraAt(tl, t)

    /// コマ数（30 fps）。
    pub def frameCount(tl: Timeline, fps: Int32): Int32 =
        Float64.round(tl#total * Int32.toFloat64(fps)) |> Float64.tryToInt32 |> Option.getWithDefault(0)
}
