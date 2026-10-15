mod Track {
    pub type alias Beat = { at = Float64, z = Int32, label = String, weight = Float64, side = Int32, hit = Bool, note = String }
    pub type alias Track = { beats = List[Beat], scenes = List[Beat], name = String, total = Float64 }
}
