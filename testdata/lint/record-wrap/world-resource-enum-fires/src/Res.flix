mod Res {
    pub type alias Docs = { theme = ThemeDoc.Doc, atlas = PxSpriteAtlas.Baked }
    // 1 case の enum で包んでも、中の Doc は World に残ったまま
    pub enum Boxed(Docs)
}
mod ThemeDoc {
    pub type alias Doc = { bg = Int32 }
}
