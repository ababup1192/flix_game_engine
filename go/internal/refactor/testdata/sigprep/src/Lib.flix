/// change-signature の下ごしらえ・改行の形・use を足すのお手本（testdata/sigprep）の土台。
mod Lib {
    pub type alias Ctx = { atlas = Int32 }
    pub type alias World = { theme = Int32, script = Int32, clock = Int32, dialog = Int32 }

    pub def tick(w: World): Int32 \ IO = w#clock
}
