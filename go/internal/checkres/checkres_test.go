package checkres

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/checklevel"
)

func init() {
	// テストだけの表（px・snd の表は各 package が載せる）
	Register(Code{Name: "t.atleast", Level: checklevel.Lint, Metric: "dL", Unit: "L", Op: AtLeast})
	Register(Code{Name: "t.count", Level: checklevel.Lint, Metric: "n", Unit: "count", Op: AtMost})
	Register(Code{Name: "t.db", Level: checklevel.Lint, Metric: "tp", Unit: "dBTP", Op: AtMost})
	Register(Code{Name: "t.range", Level: checklevel.Lint, Metric: "lufs", Unit: "LUFS", Op: InRange})
	Register(Code{Name: "t.gate", Level: checklevel.Gate, Metric: "n", Unit: "count", Op: AtMost})
	Register(Code{Name: "t.advice", Level: checklevel.Advice, Metric: "n", Unit: "count", Op: AtMost})
}

func rules(t *testing.T) *Rules {
	t.Helper()
	r, err := LoadRules("../../..")
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// 帯（near）は bin/lint-rules/checkfmt.json の nearRatio から導く。
func TestStatusGapRatio(t *testing.T) {
	r := rules(t)
	cases := []struct {
		name, code string
		got        float64
		want       Want
		status     Status
		gap        float64
	}{
		{"足りる", "t.atleast", 0.12, WantAtLeast(0.1), Pass, 0},
		{"帯の中", "t.atleast", 0.1 * r.NearRatio, WantAtLeast(0.1), Near, 0.1 - 0.1*r.NearRatio},
		{"帯の外", "t.atleast", 0.1*r.NearRatio - 0.01, WantAtLeast(0.1), Fail, 0.1 - (0.1*r.NearRatio - 0.01)},
		{"数は 0 が基準", "t.count", 1, WantAtMost(0), Fail, -1},
		{"範囲の上", "t.range", -12, WantRange(-18, -14), Fail, -2},
		{"範囲の中", "t.range", -16, WantRange(-18, -14), Pass, 0},
	}
	for _, c := range cases {
		res := New(c.code, 0, Measure{Got: c.got, Want: c.want}, r, "")
		if res.Status != c.status || res.Gap != round(c.gap) {
			t.Errorf("%s: status %s gap %v（%s・%v のはず）", c.name, res.Status, res.Gap, c.status, round(c.gap))
		}
	}
}

// 対数の単位の割合は振幅の比: 6 dB の外れは約 0.5。
func TestRatioOfDecibels(t *testing.T) {
	res := New("t.db", 0, Measure{Got: 5, Want: WantAtMost(-1)}, rules(t), "")
	if res.Ratio < 0.49 || res.Ratio > 0.51 {
		t.Errorf("ratio %v（0.5 前後のはず）", res.Ratio)
	}
}

func TestTableRejectsUnknownCodeAndWrongOp(t *testing.T) {
	for _, f := range []func(){
		func() { New("t.nope", 0, Measure{Want: WantAtMost(0)}, nil, "") },
		func() { New("t.count", 0, Measure{Want: WantAtLeast(0)}, nil, "") },
	} {
		func() {
			defer func() {
				if recover() == nil {
					t.Error("panic しなかった")
				}
			}()
			f()
		}()
	}
}

func TestExitCode(t *testing.T) {
	r := rules(t)
	lintNear := New("t.atleast", 0, Measure{Got: 0.09, Want: WantAtLeast(0.1)}, r, "")
	lintFail := New("t.count", 0, Measure{Got: 3, Want: WantAtMost(0)}, r, "")
	advice := New("t.advice", 0, Measure{Got: 3, Want: WantAtMost(0)}, r, "")
	gate := New("t.gate", 0, Measure{Got: 1, Want: WantAtMost(0)}, r, "")
	for _, c := range []struct {
		rs   []Result
		want int
	}{{nil, 0}, {[]Result{lintNear, advice}, 0}, {[]Result{lintFail, advice}, 2}, {[]Result{lintFail, gate}, 1}} {
		if got := ExitCode(c.rs); got != c.want {
			t.Errorf("exit %d（%d のはず）", got, c.want)
		}
	}
}

// gate の外れがあれば score は gateCap まで。
func TestScoreCapsOnGate(t *testing.T) {
	r := rules(t)
	gate := New("t.gate", 0, Measure{Got: 1, Want: WantAtMost(0)}, r, "")
	if s := Score([]Result{gate}, r); s > int(r.Score.GateCap) {
		t.Errorf("score %d（%v まで）", s, r.Score.GateCap)
	}
}

func TestNextIsWorst(t *testing.T) {
	r := rules(t)
	near := New("t.atleast", 0, Measure{Got: 0.09, Want: WantAtLeast(0.1)}, r, "")
	fail := New("t.count", 0, Measure{Got: 3, Want: WantAtMost(0)}, r, "")
	s := Summarize([]Result{near, fail}, r, nil)
	if len(s.Next) != 1 || s.Next[0].Code != "t.count" || s.Near == nil || s.Near.Count != 1 {
		t.Errorf("next %+v（t.count のはず）", s.Next)
	}
}

func TestCompareOrdersWorseFirst(t *testing.T) {
	r := rules(t)
	prev := []Result{New("t.count", 0, Measure{Got: 1, Want: WantAtMost(0)}, r, ""), New("t.db", 0, Measure{Got: 0, Want: WantAtMost(-1)}, r, "")}
	cur := []Result{New("t.count", 0, Measure{Got: 4, Want: WantAtMost(0)}, r, ""), New("t.advice", 0, Measure{Got: 1, Want: WantAtMost(0)}, r, "")}
	ds := Compare(prev, cur)
	var order []string
	for _, d := range ds {
		order = append(order, d.Change+":"+d.Code)
	}
	want := []string{"worse:t.count", "new:t.advice", "gone:t.db"}
	if len(order) != len(want) {
		t.Fatalf("%v（%v のはず）", order, want)
	}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("%v（%v のはず）", order, want)
		}
	}
}

func TestJudgeStop(t *testing.T) {
	r := rules(t)
	fail := New("t.count", 0, Measure{Got: 3, Want: WantAtMost(0)}, r, "")
	round := func(score int, rs ...Result) Round {
		s := Summarize(rs, r, nil)
		s.Score = score
		return Round{Summary: s, Results: rs}
	}
	if st := JudgeStop(nil, round(100), r); !st.Stop || st.Rule != "clear" {
		t.Errorf("外れ無し: %+v", st)
	}
	hist := []Round{}
	for i := 0; i < r.Stop.NoGainRounds; i++ {
		hist = append(hist, round(50, fail))
	}
	if st := JudgeStop(hist, round(50, fail), r); !st.Stop || st.Rule != "no-gain" {
		t.Errorf("上がらない: %+v", st)
	}
	cur := round(60, fail)
	cur.Tokens = &Tokens{Used: 95, Budget: 100}
	if st := JudgeStop(nil, cur, r); !st.Stop || st.Rule != "budget" {
		t.Errorf("予算: %+v", st)
	}
	if st := JudgeStop([]Round{round(40, fail)}, round(60, fail), r); st.Stop {
		t.Errorf("上がっている: %+v", st)
	}
}

// JSON の形の golden（AI が読む形を変えたら testdata/golden.json を見直す。書き直すのは UPDATE_GOLDEN=1）。
func TestJSONGolden(t *testing.T) {
	r := rules(t)
	res := New("t.atleast", 0, Measure{Got: 0.06, Want: WantAtLeast(0.1)}, r, "外周と地の明るさの差が平均 0.060（0.10 以上にする）")
	res.Where.Sprite, res.Where.Frame = "slime", "idle"
	res.Where.SetAt(3, 9)
	res.Cause = Cause{Op: "body.ops[1] directional", Script: "sprites[0].parts[0].ops[1]"}
	res.Fix = Fix{Hint: "外周をランプのもっと暗い段にする", Try: []Try{{Op: "body.ops[1] directional", Arg: "from", Now: 1.0, Try: 0.0}}}
	res.Scope = ScopeFrame
	sum := Summarize([]Result{res}, r, nil)
	d := 4
	sum.Exempt = &Exempt{Px: 12, Pct: 3.1, D: &d, Units: &ExemptUnits{Pixels: map[string]int{"bevel_box": 12}}}
	sum.Applied = map[string]checklevel.Applied{"slime": AppliedOf(checklevel.AppliedFull{Style: "nes", Checks: []string{"sprite", "ground-contrast"}}, "", false)}
	got := JSON(Round{Summary: sum, Results: []Result{res}})
	path := filepath.Join("testdata", "golden.json")
	if os.Getenv("UPDATE_GOLDEN") == "1" {
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(want) != string(got) {
		t.Errorf("JSON の形が golden と違う:\n%s", got)
	}
}

// next は 宣言 → gate → fail（広い範囲から）の順で 3 件まで・同じ直し方は 1 件。
func TestNextOrderAndMerge(t *testing.T) {
	r := rules(t)
	mk := func(code, scope, op string) Result {
		x := New(code, 0, Measure{Got: 1, Want: WantAtMost(0)}, r, code+scope+op)
		x.Scope = scope
		x.Cause.Op = op
		return x
	}
	part := mk("t.count", ScopePart, "a")
	spec := mk("t.count", ScopeSpec, "b")
	same := mk("t.count", ScopeFrame, "b") // spec と同じ op で直る
	gate := mk("t.gate", ScopeFrame, "c")
	adv := mk("t.advice", ScopeSpec, "d")
	next, _ := NextOf([]Result{part, adv, spec, same, gate}, nil)
	var got []string
	for _, n := range next {
		got = append(got, n.Code+":"+n.Scope)
	}
	want := []string{"t.gate:frame", "t.count:spec", "t.advice:spec"}
	if len(got) != 3 || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
		t.Errorf("next %v（%v のはず）", got, want)
	}
}

// applied は組が前の周と同じなら id だけ。
func TestAppliedIDOnlyWhenSame(t *testing.T) {
	full := checklevel.AppliedFull{Checks: []string{"seam", "sprite"}}
	first := AppliedOf(full, "", false)
	again := AppliedOf(full, first.ID, false)
	if first.Full == nil || again.Full != nil || again.Changed {
		t.Errorf("first %+v again %+v", first, again)
	}
}
