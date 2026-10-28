mod EnemyDoc {
    pub type alias Rec = { hp = Int32 }
}
mod Enemy {
    // 遊びの状態の敵が Doc の Rec を持つのは World の外へ出す物ではない
    pub type alias Enemy = { spec = EnemyDoc.Rec, x = Float64 }
}
