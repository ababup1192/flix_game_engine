package migrate

import "sort"

// anchor は前と後で組になった出来事の時刻の組。音・画面の物の区間・バスの音量を、新しい版の時刻から
// 「直前に組になった出来事のずれ」を引いて比べるのに使う（--times の時だけ）。
// WhyNot: 頭からの時刻のまま比べない — 承認した 1 か所の遅れ（0.633 秒など）が後ろの音と区間と音量の全部に伝わり、
// 同じ遅れが何百件の迷った差に見える。ずれの出元は eventTime が出来事 1 件ずつの間で見ている。
// WhyNot: --times の無い時は合わせ直さない — 出来事の間を誰も見ていないので、合わせ直すとずれの出元がどこにも出ない。
type anchor struct {
	byNew []anchorPoint // 新しい版の時刻の順
	byOld []anchorPoint // 前の版の時刻の順
}

type anchorPoint struct{ a, b float64 }

// buildAnchor は並びの同じ 2 本の出来事から組を作る。待ちは明けた所（t + 秒）も組にする。
func buildAnchor(ea, eb []Event) *anchor {
	var pts []anchorPoint
	for i := 0; i < len(ea) && i < len(eb); i++ {
		pts = append(pts, anchorPoint{ea[i].T, eb[i].T})
		if ea[i].Kind == "wait" && ea[i].Seconds != nil && eb[i].Seconds != nil {
			pts = append(pts, anchorPoint{ea[i].T + *ea[i].Seconds, eb[i].T + *eb[i].Seconds})
		}
	}
	an := &anchor{byNew: append([]anchorPoint(nil), pts...), byOld: pts}
	sort.SliceStable(an.byNew, func(i, j int) bool { return an.byNew[i].b < an.byNew[j].b })
	sort.SliceStable(an.byOld, func(i, j int) bool { return an.byOld[i].a < an.byOld[j].a })
	return an
}

// offsetAtNew は新しい版の秒 t の時のずれ（後 - 前。t より前に組が無ければ 0）。nil の anchor は 0。
func (an *anchor) offsetAtNew(t float64) float64 {
	if an == nil {
		return 0
	}
	i := sort.Search(len(an.byNew), func(i int) bool { return an.byNew[i].b > t+1e-9 }) - 1
	if i < 0 {
		return 0
	}
	return an.byNew[i].b - an.byNew[i].a
}

// offsetAtOld は前の版の秒 t の時のずれ（後 - 前）。
func (an *anchor) offsetAtOld(t float64) float64 {
	if an == nil {
		return 0
	}
	i := sort.Search(len(an.byOld), func(i int) bool { return an.byOld[i].a > t+1e-9 }) - 1
	if i < 0 {
		return 0
	}
	return an.byOld[i].b - an.byOld[i].a
}

// toOld は新しい版の秒を、前の版の時刻の物差しに直す。
func (an *anchor) toOld(t float64) float64 { return t - an.offsetAtNew(t) }

// toNew は前の版の秒を、新しい版の時刻の物差しに直す。
func (an *anchor) toNew(t float64) float64 { return t + an.offsetAtOld(t) }
