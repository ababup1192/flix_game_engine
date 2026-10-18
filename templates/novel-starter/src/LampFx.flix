// LampFx — 疑って灯りがひとつ消える演出の時刻表。起点は World の lampOutAt（消えた物語の時刻）。
// 鳴らす側（Controls.sounds）は Timeline.soundsOnClock、描く側は flickerOf（Timeline.progressOn）で
// 同じ表を物語の時計で読む — メニューで物語の時計が止まると、音も炎の細りも一緒に止まる。
mod LampFx {
    use fge::{Clock, Timeline}
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
            |> Option.map(at -> Timeline.progressOn(w#storyClock, at, Beat.Flicker, timeline()))
            |> Option.getWithDefault(0.0)

    /// 消えた灯りがまだ細りながら残っているか（消えた時刻から Flicker の長さの間だけ）。
    /// 描き出しは物語の時計を置き直すので、消えた時刻より前の時刻は「もう消えた」と見る。
    pub def isFlickering(w: World.World): Bool =
        let length = Timeline.clipOf(Beat.Flicker, timeline()) |> Option.map(clip -> clip#dur) |> Option.getWithDefault(0.0);
        let now = Clock.nowOf(w#storyClock);
        Option.exists(at -> now >= at and now < Clock.after(length, at), w#lampOutAt)
}
