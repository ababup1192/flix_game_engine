// 実時間の今を、遊びの時刻の欄にしまう。
mod Mix6 {
    pub def markHit(w: Shapes.World): Shapes.World = { hitAt = w#realNow | w }
}
