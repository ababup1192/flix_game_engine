// Timeline — 区間(名前+長さ)の列を「時刻の純関数」でサンプルする。
// 履歴・巻き戻し・リプレイは Worldline（別物）。
// 進行の状態は持たない: 開始からの経過秒 t だけ渡せば「いまどの区間の何秒目か」が
// 式で決まる。区間は逐次に並ぶので、閾値の if 連鎖で起きがちな「区間の重なり」が
// 構造的に起きない。範囲外(全区間を過ぎた・負の時刻)は None = 終わり(Done)。
// 利用例: 歩く→しゃがむ→戻る、のような一続きの振り付けの現在地を引く。

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
}
