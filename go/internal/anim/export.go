package anim

// fge px build から、描いたコマ列に同じ検査をかける口。

// CheckSequence はコマ列（並び順）に pop・area・ground・bob・loop をかけ、違反の文を返す。
// palette と 4 方向の view は外す（palette_cycle は色を回すだけで色を足さないが、コマごとの色の入れ替えを palette は違反と読むため）。
// rows の透明は Rules.Transparent の字（'.' と ' '）。
func (r *Rules) CheckSequence(spriteName string, names []string, rows [][]string) []string {
	fs := make([]frame, len(names))
	for i := range names {
		fs[i] = frame{name: names[i], rows: rows[i]}
	}
	return r.checkFrames(spriteName, fs, skipSet("palette"))
}

// MeasureSequence は CheckSequence と同じ検査を、測った値つきで返す（fge px の結果の形に写す）。
func (r *Rules) MeasureSequence(spriteName string, names []string, rows [][]string) []Note {
	fs := make([]frame, len(names))
	for i := range names {
		fs[i] = frame{name: names[i], rows: rows[i]}
	}
	return r.measureFrames(spriteName, fs, skipSet("palette"))
}
