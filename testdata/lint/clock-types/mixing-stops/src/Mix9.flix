// 遊びの時計の欄に、物語の時計を書き戻す。
mod Mix9 {
    pub def swap(w: Shapes.World): Shapes.World = { play = w#story | w }
}
