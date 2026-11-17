// ShotClock — 決まった瞬間を撮る描き出しの時刻（動画のコマの秒 → 後がけの霧のむらを流す時刻）。
mod ShotClock {
    use fge::{Clock}

    /// 撮るコマの秒 t の時刻。
    pub def at(t: Float64): Clock.Time[Clock.Real] = Clock.after(t, Clock.zero())
}
