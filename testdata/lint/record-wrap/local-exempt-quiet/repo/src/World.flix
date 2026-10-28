mod ThemeDoc {
    pub type alias Doc = { bg = Int32 }
}
mod World {
    pub type alias World = {
        theme = ThemeDoc.Doc,
        t = Float64
    }
}
