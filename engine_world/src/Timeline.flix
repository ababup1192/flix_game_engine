// Timeline — 区間(名前+長さ)の列を「時刻の純関数」でサンプルする。
// 履歴・巻き戻し・リプレイは Worldline（別物）。
// 進行の状態は持たない: 開始からの経過秒 t だけ渡せば「いまどの区間の何秒目か」が
// 式で決まる。区間は逐次に並ぶので、閾値の if 連鎖で起きがちな「区間の重なり」が
// 構造的に起きない。範囲外(全区間を過ぎた・負の時刻)は None = 終わり(Done)。
// 利用例: 歩く→しゃがむ→戻る、のような一続きの振り付けの現在地を引く。
//
// 演出の時刻表にはクリップ（Clip: 開始の時刻 + 長さ。重なってよい）を使う。秒は Doc から読み、
// 絵と効果音が同じクリップの列を読むので、動きの拍と音がずれない。音は startedBetween
// （前のフレームから今までに始まったクリップ）で鳴らし、全体の秒は totalOfClips で引く。

pub mod Timeline {

    /// 区間: 名前と長さ(秒)。列の順に頭から消化される(純データ)。
    pub type alias Seg = { name = String, dur = Float64 }

    pub def seg(name: String, dur: Float64): Seg = { name = name, dur = dur }

    /// 合計の尺(秒)。t がこれ以上なら at は None(終わり)。
    pub def total(segs: List[Seg]): Float64 =
        segs |> List.foldLeft((acc, s) -> acc + s#dur, 0.0)

    /// t 秒時点の区間。u は区間の頭からの経過秒(0 <= u < dur)。
    /// u を 0..1 に正規化しない — 割るか・何で割るかは呼び手の流儀に残す
    /// (既存コードからの移行で浮動小数の演算順を変えないため)。
    pub def at(segs: List[Seg], t: Float64): Option[{ name = String, u = Float64 }] =
        if (t < 0.0) None
        else match segs {
            case s :: rest =>
                if (t < s#dur) Some({ name = s#name, u = t })
                else at(rest, t - s#dur)
            case Nil => None
        }

    // ── クリップ（重なってよい区間）──
    // Seg は頭から順に並ぶ区間。演出では「縮む」と「消灯」が半分重なる、のように区間が
    // 重なることが多いので、開始の時刻と長さを直接持つクリップも置く（Unity の Timeline の
    // clip と同じ start / duration）。tag にはゲームの enum（拍の名前や、ルールが出した出来事）を
    // 入れる —— 文字列にしないのは、match の網羅の検査で書き損じに気づけるようにするため。
    // 1 つのクリップの中の進み（0..1）は Lifetime.progressOf(t, Lifetime.fire(c#start, c#dur)) で引く。

    /// クリップ: start 秒に始まり dur 秒続く。tag = 拍の名前か出来事（純データ）。
    pub type alias Clip[a] = { tag = a, start = Float64, dur = Float64 }

    pub def clip(tag: a, start: Float64, dur: Float64): Clip[a] =
        { tag = tag, start = start, dur = Float64.max(0.0, dur) }

    /// 頭から順に並ぶ (tag, 長さ) の列を、開始の時刻つきのクリップへ直す。開始の時刻は
    /// 前の長さを頭から足し上げた値（Doc の秒を足し並べるのと同じ順で足すので、手で足した時刻と
    /// ビットまで一致する）。
    pub def toClips(steps: List[(a, Float64)]): List[Clip[a]] =
        steps |> List.foldLeft((acc, step) -> {
            let (at, out) = acc;
            let (tag, dur) = step;
            (at + dur, clip(tag, at, dur) :: out)
        }, (0.0, Nil)) |> snd |> List.reverse

    /// 全部のクリップが終わる時刻（空なら 0）。演出の全体の秒・決定キーで「最後まで飛ばす」先。
    pub def totalOfClips(clips: List[Clip[a]]): Float64 =
        clips |> List.foldLeft((acc, c) -> Float64.max(acc, c#start + c#dur), 0.0)

    /// tag のクリップの開始の時刻（無ければ None。同じ tag が複数あれば先頭）。
    pub def startOf(tag: a, clips: List[Clip[a]]): Option[Float64] with Eq[a] =
        List.find(c -> c#tag == tag, clips) |> Option.map(c -> c#start)

    /// 前のフレームの時刻 t0 から今の t1 までの間に始まったクリップ（t0 < start <= t1）。
    /// 音を鳴らす・粒を出すのはこの拍。巻き戻し（t1 < t0）では何も返さない。
    /// start = 0 のクリップは、時計が 0 より前（負の t0）から回り始めたときだけ拾う。
    pub def startedBetween(t0: Float64, t1: Float64, clips: List[Clip[a]]): List[Clip[a]] =
        List.filter(c -> t0 < c#start and c#start <= t1, clips)
}
