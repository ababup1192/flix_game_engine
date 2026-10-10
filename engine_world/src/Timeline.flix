// Timeline — 区間(名前+長さ)の列を「時刻の純関数」でサンプルする。
// 履歴・巻き戻し・リプレイは Worldline（別物）。
// 進行の状態は持たない: 開始からの経過秒 t だけ渡せば「いまどの区間の何秒目か」が
// 式で決まる。区間は逐次に並ぶので、閾値の if 連鎖で起きがちな「区間の重なり」が
// 構造的に起きない。範囲外(全区間を過ぎた・負の時刻)は None = 終わり(Done)。
// 利用例: 歩く→しゃがむ→戻る、のような一続きの振り付けの現在地を引く。
//
// 演出の時刻表にはクリップ（Clip: 開始の時刻 + 長さ。重なってよい）を使う。秒は Doc から読み、
// 絵・音・曲が同じクリップの列を読むので、「縮み切った拍」と「コト」の音がずれない。
// 音は startedBetween（前のフレームから今までに始まったクリップ）で鳴らし、決定キーの
// 「次の区切りへ」は nextEdge、全体の尺は length で引く。tag に出来事の型を入れれば、
// ルールが出した出来事の列をそのまま再生できる（pendingAt で「まだ当たっていない」ぶんを引ける）。

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
    // clip と同じ考え方）。tag にはクリップの名前（String）か、再生したい出来事（ゲームの型）を入れる。

    /// クリップ: at 秒に始まり dur 秒続く。tag = 名前か出来事（純データ）。
    pub type alias Clip[a] = { tag = a, at = Float64, dur = Float64 }

    pub def clip(tag: a, at: Float64, dur: Float64): Clip[a] = { tag = tag, at = at, dur = Float64.max(0.0, dur) }

    /// 「何秒から何秒まで」の書き方（Doc に start と end で書いてある値をそのまま渡す）。
    pub def span(tag: a, start: Float64, end: Float64): Clip[a] = clip(tag, start, end - start)

    /// 頭から順に並ぶ区間（Seg）を、開始の時刻つきのクリップへ直す。
    pub def sequence(segs: List[Seg]): List[Clip[String]] =
        segs |> List.foldLeft((acc, s) -> {
            let (at, out) = acc;
            (at + s#dur, clip(s#name, at, s#dur) :: out)
        }, (0.0, Nil)) |> snd |> List.reverse

    /// 終わりの時刻。
    pub def endOf(c: Clip[a]): Float64 = c#at + c#dur

    /// 全部のクリップが終わる時刻（空なら 0）。
    pub def length(clips: List[Clip[a]]): Float64 =
        clips |> List.foldLeft((acc, c) -> Float64.max(acc, endOf(c)), 0.0)

    /// クリップの中の進み（0..1）。始まる前は 0、終わった後は 1。長さ 0 のクリップは at を過ぎたら 1。
    pub def progressOf(c: Clip[a], t: Float64): Float64 =
        if (c#dur <= 0.0) (if (t >= c#at) 1.0 else 0.0)
        else Num.clamp01((t - c#at) / c#dur)

    /// t がクリップの中か（at <= t < 終わり）。
    pub def isActive(c: Clip[a], t: Float64): Bool = t >= c#at and t < endOf(c)

    /// 名前でクリップを引く（同じ名前が複数あれば先頭）。
    pub def find(tag: a, clips: List[Clip[a]]): Option[Clip[a]] with Eq[a] =
        List.find(c -> c#tag == tag, clips)

    /// 名前で引いたクリップの進み（0..1）。名前が無ければ 0（fail-open: 動かない）。
    pub def progress(tag: a, clips: List[Clip[a]], t: Float64): Float64 with Eq[a] =
        find(tag, clips) |> Option.map(c -> progressOf(c, t)) |> Option.getWithDefault(0.0)

    /// 名前で引いたクリップの開始の時刻（無ければ None）。
    pub def startOf(tag: a, clips: List[Clip[a]]): Option[Float64] with Eq[a] =
        find(tag, clips) |> Option.map(c -> c#at)

    /// t に再生中のクリップ。
    pub def activeAt(clips: List[Clip[a]], t: Float64): List[Clip[a]] =
        List.filter(c -> isActive(c, t), clips)

    /// t にまだ始まっていないクリップ（画面に出す値を「まだ当たっていない出来事」のぶん戻すときに使う）。
    pub def pendingAt(clips: List[Clip[a]], t: Float64): List[Clip[a]] =
        List.filter(c -> t < c#at, clips)

    /// 前のフレームの時刻 t0 から今の t1 までの間に始まったクリップ（t0 < at <= t1）。
    /// 音を鳴らす・粒を出すのはこの拍。巻き戻し（t1 < t0）では何も返さない。
    pub def startedBetween(t0: Float64, t1: Float64, clips: List[Clip[a]]): List[Clip[a]] =
        List.filter(c -> t0 < c#at and c#at <= t1, clips)

    /// 全部の時刻を k 倍する（「はやさ」の設定で演出全体を縮める・伸ばす）。
    pub def scaled(k: Float64, clips: List[Clip[a]]): List[Clip[a]] =
        List.map(c -> { at = c#at * k, dur = c#dur * k | c }, clips)

    /// 全部の時刻を dt 秒ずらす（出来事の列を「この拍の頭」へ置く）。
    pub def shifted(dt: Float64, clips: List[Clip[a]]): List[Clip[a]] =
        List.map(c -> { at = c#at + dt | c }, clips)

    /// 決定キーで「次の区切りへ飛ぶ」ときの行き先: t より後にある一番近いクリップの端
    /// （始まりか終わり）。もう端が無ければ全体の終わり。
    pub def nextEdge(clips: List[Clip[a]], t: Float64): Float64 =
        clips |> List.flatMap(c -> c#at :: endOf(c) :: Nil)
              |> List.filter(e -> e > t)
              |> List.minimum
              |> Option.getWithDefault(Float64.max(t, length(clips)))
}
