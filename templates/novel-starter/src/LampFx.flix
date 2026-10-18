// LampFx — 疑って灯りがひとつ消える演出の時刻表。起点は World の lampOutAt（消えた時刻）。
// 鳴らす側（Controls.sounds）は Timeline.soundsSince、描く側は flickerOf（progressSince）で同じ表を読む。
mod LampFx {
    use fge::Timeline
    use fge::Timeline.Duration

    /// 演出の拍。Flicker = 炎が揺らいで細る・Dark = 消えて部屋が一段暗くなる。
    pub enum Beat with Eq, Order, ToString {
        case Flicker
        case Dark
    }

    /// 炎が細る 0.5 秒（頭で揺らぐ音）→ 消えて暗くなる 0.4 秒（頭で消える音）。
    pub def timeline(): Timeline.Timeline[Beat] =
        Timeline.buildOrPanic("LampFx", Timeline.noTempo(), List#{
            Timeline.append(Beat.Flicker, Duration.Seconds(0.5)) |> Timeline.withSound("lamp_flicker"),
            Timeline.append(Beat.Dark, Duration.Seconds(0.4))    |> Timeline.withSound("lamp_out")
        })

    /// いまの炎の細り具合 0..1（灯りが消えていなければ 0）。
    pub def flickerOf(w: World.World): Float64 =
        w#lampOutAt
            |> Option.map(at -> Timeline.progressSince(at, w#t, Beat.Flicker, timeline()))
            |> Option.getWithDefault(0.0)
}
