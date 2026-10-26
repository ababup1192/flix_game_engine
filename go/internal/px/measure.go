package px

// measure: sprite.json（手描きや採用済みの絵）に技法帳の検査の「測る口」をかけ、code ごとの値の分布を出す
// （閾値を採用済みの絵で決め直すための道具。合否は出すが、終了コードはいつも 0）。
//
// ランプは legend の色キーの名前から推す（末尾の数字が段: stkSkl0・stkSkl1… → ランプ stkSkl）。地の色と光の向きは無いので、
// それを使う検査（ground-contrast の足し・pillow・light-dir）は測らない。

import (
	"fmt"
	"math"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flixlint/go/checkres"
)

// measureRow は code 1 つの分布。
type measureRow struct {
	Code  string        `json:"code"`
	N     int           `json:"n"`
	Fail  int           `json:"fail"` // 今の閾値で外れる数
	Want  checkres.Want `json:"want"`
	P10   float64       `json:"p10"`
	P50   float64       `json:"p50"`
	P90   float64       `json:"p90"`
	Worst []string      `json:"worst"` // 外れの悪い順 5 件（sprite/frame got）
}

var rampKeyRx = regexp.MustCompile(`^(.*?[^0-9])([0-9]+)$`)

// rampsFromKeys は色キーの名前からランプを推す（同じ頭で段が 3 つ以上ある物）。
func rampsFromKeys(keys []pxlib.Key) map[string][]pxlib.Key {
	steps := map[string]map[int]pxlib.Key{}
	for _, k := range keys {
		m := rampKeyRx.FindStringSubmatch(string(k))
		if m == nil {
			continue
		}
		n, _ := strconv.Atoi(m[2])
		if steps[m[1]] == nil {
			steps[m[1]] = map[int]pxlib.Key{}
		}
		steps[m[1]][n] = k
	}
	out := map[string][]pxlib.Key{}
	for name, s := range steps {
		if len(s) < 3 {
			continue
		}
		idx := make([]int, 0, len(s))
		for n := range s {
			idx = append(idx, n)
		}
		sort.Ints(idx)
		for _, n := range idx {
			out[name] = append(out[name], s[n])
		}
	}
	return out
}

// measureFiles は sprite.json の並びを測る。
func measureFiles(engineRoot, workRoot string, paths []string) ([]measureRow, error) {
	rules, err := loadRules(engineRoot)
	if err != nil {
		return nil, err
	}
	type val struct {
		got   float64
		where string
		bad   bool
	}
	vals := map[string][]val{}
	wants := map[string]checkres.Want{}
	add := func(code string, want checkres.Want, got float64, where string) {
		bad := checkres.New(code, 0, checkres.Measure{Got: got, Want: want}, nil, "").Status != checkres.Pass
		vals[code] = append(vals[code], val{got, where, bad})
		wants[code] = want
	}
	wantOf := func(check checkName, sub string) checkres.Want {
		r := rules
		switch string(check) + "." + sub {
		case "highlight-reserve.area":
			return checkres.WantAtMost(r.HighlightMaxShare)
		case "highlight-reserve.inside":
			return checkres.WantAtMost(r.HighlightInsideMax)
		case "value-blobs.count":
			return checkres.WantRange(float64(r.ValueBlobsMin), float64(r.ValueBlobsMax))
		case "value-blobs.cover":
			return checkres.WantAtLeast(r.ValueBlobsCoverMin)
		case "outer-aa.":
			return checkres.WantAtMost(float64(r.OuterAAMax))
		case "ramp-hue.step":
			return checkres.WantAtMost(r.RampHueMaxStep)
		case "ramp-hue.turn":
			return checkres.WantAtMost(0)
		case "ramp-hue.flat":
			return checkres.WantAtLeast(r.RampHueMinTotal)
		case "ramp-chroma.peak":
			return checkres.WantAtMost(r.RampChromaPeakSlack)
		case "ramp-chroma.bright":
			return checkres.WantAtMost(r.RampBrightSMax)
		}
		return checkres.Want{}
	}
	codeOf := func(check checkName, sub string) string {
		if sub == "" {
			return "px." + string(check)
		}
		return "px." + string(check) + "." + sub
	}
	for _, p := range paths {
		full := p
		if !filepath.IsAbs(full) {
			full = filepath.Join(workRoot, p)
		}
		doc, err := pxlib.LoadOrdered(full)
		if err != nil {
			return nil, fmt.Errorf("%s: %v", p, err)
		}
		plain, _ := pxlib.Plain(doc).(map[string]any)
		hexByName := pxlib.DocPalette(workRoot, plain, nil, pxlib.AnyColor)
		lv, _ := doc.Get("legend")
		lg := pxlib.LegendOf(lv)
		hexOf := map[pxlib.Key]string{}
		var keys []pxlib.Key
		for _, k := range lg.KeyOf {
			if h, ok := hexByName[string(k)]; ok {
				hexOf[k] = h
				keys = append(keys, k)
			}
		}
		base := filepath.Base(p)
		c := &checkCtx{Rules: rules, HexOf: hexOf, Ramps: rampsFromKeys(keys)}
		for _, check := range []checkName{checkRampHue, checkRampChroma} {
			for _, s := range measures[check](nil, c) {
				add(codeOf(check, s.Sub), wantOf(check, s.Sub), s.Got, base+" "+strings.SplitN(s.Note, "（", 2)[0])
			}
		}
		sprites, _ := doc.GetOr("sprites", nil).(*pxlib.Obj)
		if sprites == nil {
			continue
		}
		snames, svals := sprites.Items()
		for i, sn := range snames {
			so, _ := svals[i].(*pxlib.Obj)
			if so == nil || strings.HasPrefix(sn, "//") {
				continue
			}
			frames, _ := so.GetOr("frames", nil).(*pxlib.Obj)
			if frames == nil {
				continue
			}
			fnames, fvals := frames.Items()
			for j, fn := range fnames {
				g, _ := pxlib.GridFromRows(strs(fvals[j]), lg.KeyOf) // 2 つ目は legend に無い字（'.' の透明も入る）
				for _, check := range []checkName{checkHighlightReserve, checkValueBlobs, checkOuterAA} {
					for _, s := range measures[check](g, c) {
						add(codeOf(check, s.Sub), wantOf(check, s.Sub), s.Got, sn+"/"+fn)
					}
				}
			}
		}
	}
	var rows []measureRow
	for code, vs := range vals {
		got := make([]float64, len(vs))
		for i, v := range vs {
			got[i] = v.got
		}
		sort.Float64s(got)
		q := func(p float64) float64 { return math.Round(got[int(p*float64(len(got)-1))]*1000) / 1000 }
		row := measureRow{Code: code, N: len(vs), Want: wants[code], P10: q(0.1), P50: q(0.5), P90: q(0.9)}
		var bad []val
		for _, v := range vs {
			if v.bad {
				row.Fail++
				bad = append(bad, v)
			}
		}
		w := wants[code]
		sort.SliceStable(bad, func(a, b int) bool {
			if w.Op == checkres.AtLeast {
				return bad[a].got < bad[b].got
			}
			return math.Abs(bad[a].got-w.Value) > math.Abs(bad[b].got-w.Value)
		})
		for i, v := range bad {
			if i == 5 {
				break
			}
			row.Worst = append(row.Worst, fmt.Sprintf("%s %s", v.where, num3(v.got)))
		}
		rows = append(rows, row)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Code < rows[j].Code })
	return rows, nil
}

func num3(v float64) string { return strconv.FormatFloat(math.Round(v*1000)/1000, 'f', -1, 64) }

func cmdMeasure(out, errOut *strings.Builder, engineRoot, workRoot string, paths []string, asJSON bool) int {
	rows, err := measureFiles(engineRoot, workRoot, paths)
	if err != nil {
		fmt.Fprintf(errOut, "px measure: %v\n", err)
		return 1
	}
	if asJSON {
		out.Write(checkres.Compact(rows))
		return 0
	}
	fmt.Fprintf(out, "%-28s %5s %5s  %-14s %8s %8s %8s  悪い順\n", "code", "n", "外れ", "want", "p10", "p50", "p90")
	for _, r := range rows {
		fmt.Fprintf(out, "%-28s %5d %5d  %-14s %8s %8s %8s  %s\n", r.Code, r.N, r.Fail, r.Want.String(), num3(r.P10), num3(r.P50), num3(r.P90), strings.Join(r.Worst, "・"))
	}
	return 0
}
