mod Res {
    pub type alias Res = { tutorialDoc = Doc.TutorialDoc, theme = Int32 }

    pub def defaults(): Res = { tutorialDoc = { pen = 1, label = "a" }, theme = 0 }
}
