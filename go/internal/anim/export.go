package anim

// fge px build から、描いたコマ列に同じ検査をかける口。

// SequenceRules は fge px がコマ列にかける規則（palette と 4 方向の view は外す。
// palette_cycle は色を回すだけで色を足さないが、コマごとの色の入れ替えを palette は違反と読むため）。
var SequenceRules = []string{"pop", "area", "ground", "bob", "loop"}

// CheckSequence はコマ列（並び順）に pop・area・ground・bob・loop をかけ、違反の文を返す。
// rows の透明は Rules.Transparent の字（'.' と ' '）。
func (r *Rules) CheckSequence(spriteName string, names []string, rows [][]string) []string {
	fs := make([]frame, len(names))
	for i := range names {
		fs[i] = frame{name: names[i], rows: rows[i]}
	}
	return r.checkFrames(spriteName, fs, skipSet("palette"))
}
