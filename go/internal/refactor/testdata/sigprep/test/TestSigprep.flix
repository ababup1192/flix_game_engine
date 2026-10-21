mod TestSigprep {
    pub def uses(): Int32 =
        let w = { theme = 1, script = 2, clock = 3, dialog = 4 };
        Talk.boxes({ atlas = 1 }, w) + Talk.tags({ atlas = 1 }, w) + Stand.stand(w, 1) + Plain.stand(w, 2)
            + Wrap.standIn(1, 2) + Wrap.blank(1) + Wrap.kept(1)
}
