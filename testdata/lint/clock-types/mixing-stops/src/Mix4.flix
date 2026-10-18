// 時刻表の起点（物語の時刻）と、区間を持つ時計（遊び）が違う。
mod Mix4 {
    pub def sounds(w: Shapes.World): List[String] = Timeline.soundsOnClock(w#play, w#lineAt, Shapes.cue())
}
