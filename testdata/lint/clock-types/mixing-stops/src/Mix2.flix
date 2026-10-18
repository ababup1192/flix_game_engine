// 遊びの時刻と実時間の今を比べる。
mod Mix2 {
    pub def hitIsOver(w: Shapes.World): Bool = Clock.after(0.5, w#hitAt) < w#realNow
}
