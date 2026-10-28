mod ThemeDoc {
    pub type alias Doc = { bg = Int32 }
}
mod World {
    // World そのものを 1 case の enum で包んでも、中の record の Doc は見つける
    pub type alias World = WorldOf
    enum WorldOf(WorldRec)
    type alias WorldRec = {
        theme = ThemeDoc.Doc,
        t = Float64
    }
}
