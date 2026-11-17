// HazeMoments — make haze が撮る決まった瞬間（24 コマ / 秒で 2 秒）。
mod HazeMoments {
    use fge::Clock

    pub def frames(): List[Clock.Time[Clock.Real]] =
        List.range(0, 48) |> List.map(i -> Clock.after(Int32.toFloat64(i) / 24.0, Clock.zero()))
}
