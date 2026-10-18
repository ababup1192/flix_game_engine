package px

import (
	"math"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// px.ramp の既定は、どの基準の色でも ramp-order・ramp-hue・ramp-chroma をはじめから満たす（灰色は色相を見ない）。
func TestRampDefaultsPassChecks(t *testing.T) {
	rules, err := loadRules(engineRoot)
	if err != nil {
		t.Fatal(err)
	}
	for _, base := range []string{"#7a5a3a", "#3a6a9a", "#a03030", "#40a050", "#806090", "#c0a020"} {
		for _, n := range []int{3, 4, 5, 7, 9} {
			hex := map[pxlib.Key]string{}
			var ks []pxlib.Key
			hs := rampFromBase(t, base, n)
			for i, h := range hs {
				k := pxlib.Key(string(rune('a' + i)))
				hex[k] = h
				ks = append(ks, k)
			}
			cc := &checkCtx{Rules: rules, HexOf: hex, Ramps: map[string][]pxlib.Key{"r": ks}}
			for _, ck := range []checkName{checkRampOrder, checkRampHue, checkRampChroma} {
				if vs := checks[ck].Run(nil, cc); len(vs) > 0 {
					t.Errorf("px.ramp(%s, n=%d) %v が %s に当たる: %s", base, n, hs, ck, vs[0].Msg)
				}
			}
		}
	}
}

func rampFromBase(t *testing.T, base string, n int) []string {
	t.Helper()
	lab, ok := pxlib.OklabOfHex(base)
	if !ok {
		t.Fatal(base)
	}
	return rampOklch(math.Atan2(lab[2], lab[1])*180/math.Pi, math.Hypot(lab[1], lab[2]), n, 12, 0.25, 0.95)
}
