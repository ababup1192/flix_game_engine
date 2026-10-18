// 実時間で生んだ寿命を、遊びの時計の寿命の列に足す。
mod Mix7 {
    pub def spark(w: Shapes.World): Shapes.World =
        { sparks = Lifetime.fireOn(w#realNow, 0.5) :: w#sparks | w }
}
