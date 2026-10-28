mod World {
    pub type alias World = {
        enemies = List[Enemy.Enemy],
        boss = Option[EnemyDoc.Rec],
        t = Float64
    }
}
