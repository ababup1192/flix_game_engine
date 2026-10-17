package px

// 検査。重さは 3 段: gate（色の門。外れたら書き出さず終了コード 1）・lint（報告だけ）・advice（報告だけ）。
// 違反は画素の Src から「どの部品の何番目の op」が原因かを引いて持つ。

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flix_game_engine/go/internal/sprite"
)

// Level は検査の重さ。
type Level int

const (
	Gate   Level = iota // 外れたら止める
	Lint                // 報告だけ
	Advice              // 報告だけ（技法の助言）
)

func (l Level) String() string {
	return [...]string{"gate", "lint", "advice"}[l]
}

// MarshalJSON は名前で書く。
func (l Level) MarshalJSON() ([]byte, error) { return json.Marshal(l.String()) }

// Violation は検査の違反 1 件。
type Violation struct {
	Check  string      `json:"check"`
	Level  Level       `json:"level"`
	Sprite string      `json:"sprite,omitempty"`
	Frame  string      `json:"frame,omitempty"`
	X      int         `json:"x"`
	Y      int         `json:"y"`
	HasAt  bool        `json:"hasAt"`
	Cells  []pxlib.Pt  `json:"cells,omitempty"`
	Op     pxlib.OpRef `json:"op"`
	Msg    string      `json:"msg"`
}

// String は 1 行の字面（例 slime/idle body.ops[1] shade_step: run-monotone (14,9): …）。
func (v Violation) String() string {
	var b strings.Builder
	if v.Sprite != "" {
		b.WriteString(v.Sprite)
		if v.Frame != "" {
			b.WriteString("/" + v.Frame)
		}
		b.WriteString(" ")
	}
	if s := v.Op.String(); s != "" {
		b.WriteString(s + ": ")
	}
	b.WriteString(v.Check)
	if v.HasAt {
		fmt.Fprintf(&b, " (%d,%d)", v.X, v.Y)
	}
	b.WriteString(": " + v.Msg)
	return b.String()
}

// CheckCtx は検査が読む物。
type CheckCtx struct {
	Rules       *Rules
	SpriteRules *sprite.Rules
	Ground      string               // 地の色 #rrggbb（無ければ ""）
	HexOf       map[pxlib.Key]string // 色キー → #rrggbb
}

// Check は検査 1 つ。
type Check struct {
	Name    string
	Summary string
	Level   Level
	Run     func(g *pxlib.Grid, c *CheckCtx) []Violation
}

var checks = map[string]*Check{}

func registerCheck(c *Check) { checks[c.Name] = c }

// Checks は登録した検査を名前の順で返す。
func Checks() []*Check {
	out := make([]*Check, 0, len(checks))
	for _, c := range checks {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// FrameChecks はコマを描き終えた後に回す検査（全体）。
var FrameChecks = []string{"sprite", "flat-run", "run-monotone", "ground-contrast"}

// runCheck は "名前" か "sprite:規則" の検査を回す。
func runCheck(name string, g *pxlib.Grid, c *CheckCtx) ([]Violation, error) {
	base, rule, _ := strings.Cut(name, ":")
	ck, ok := checks[base]
	if !ok {
		return nil, fmt.Errorf("知らない検査 %q", name)
	}
	vs := ck.Run(g, c)
	if rule != "" {
		var only []Violation
		for _, v := range vs {
			if v.Check == base+":"+rule {
				only = append(only, v)
			}
		}
		vs = only
	}
	for i := range vs {
		if vs[i].HasAt && g.In(vs[i].X, vs[i].Y) {
			vs[i].Op = g.Src[vs[i].Y][vs[i].X]
		}
	}
	return vs, nil
}

// Rules は検査の閾値（bin/lint-rules/px.json）。
type Rules struct {
	FlatRunRepeat     int     `json:"flatRunRepeat"`
	FlatRunStraight   int     `json:"flatRunStraight"`
	FlatRunPer        int     `json:"flatRunPer"`
	GroundContrastMin float64 `json:"groundContrastMin"`
}

// RulesPath は閾値の置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "px.json")

// LoadRules は閾値を読む。読めなければ止める（既定値へ倒すと、消しただけで検査が黙って緩む）。
func LoadRules(root string) (*Rules, error) {
	path := filepath.Join(root, RulesPath)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("検査の閾値を読めない: %v", err)
	}
	var r Rules
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("%s が JSON として壊れている: %v", path, err)
	}
	if r.FlatRunRepeat < 2 || r.FlatRunStraight < 1 || r.FlatRunPer < 1 || r.GroundContrastMin <= 0 {
		return nil, fmt.Errorf("%s に flatRunRepeat・flatRunStraight・flatRunPer・groundContrastMin を書く", path)
	}
	return &r, nil
}

func init() {
	registerCheck(&Check{
		Name: "sprite", Summary: "bin/fge sprite の形の規則（orphan・connect・jaggy・banding・corner・silhouette）", Level: Lint,
		Run: func(g *pxlib.Grid, c *CheckCtx) []Violation {
			var out []Violation
			for _, f := range c.SpriteRules.CheckFrame(g) {
				out = append(out, Violation{Check: "sprite:" + f.Rule, Level: Lint, X: f.At.X, Y: f.At.Y, HasAt: f.HasAt, Cells: f.Cells, Msg: f.Msg})
			}
			return out
		},
	})
	registerCheck(&Check{
		Name: "flat-run", Summary: "輪郭の段: 同じ長さの段が続く（直線に読まれる）・長すぎる直線（16px で 4px・32px で 6px を超える）", Level: Advice,
		Run: func(g *pxlib.Grid, c *CheckCtx) []Violation {
			limit := c.Rules.FlatRunStraight + max(g.W, g.H)/c.Rules.FlatRunPer
			var out []Violation
			eachStair(g.Opaque(), func(runs []stairRun) {
				same := 1
				for i, r := range runs {
					if i > 0 && r.N == runs[i-1].N {
						same++
					} else {
						same = 1
					}
					if same == c.Rules.FlatRunRepeat {
						out = append(out, Violation{Check: "flat-run", Level: Advice, X: r.At.X, Y: r.At.Y, HasAt: true,
							Msg: fmt.Sprintf("長さ %d の段が %d 回続く（直線に読まれる。段の長さを変える）", r.N, same)})
					}
					inner := i > 0 && i < len(runs)-1
					if inner && r.N > limit {
						out = append(out, Violation{Check: "flat-run", Level: Advice, X: r.At.X, Y: r.At.Y, HasAt: true,
							Msg: fmt.Sprintf("曲線の中に %dpx の直線（%dx%d の絵では %dpx まで）", r.N, g.W, g.H, limit)})
					}
				}
			})
			return out
		},
	})
	registerCheck(&Check{
		Name: "run-monotone", Summary: "曲線の段の長さが単調でない（3-2-1 は良い・1-2-1-2 と 3-2-1-4 は不可）", Level: Lint,
		Run: func(g *pxlib.Grid, c *CheckCtx) []Violation {
			var out []Violation
			eachStair(g.Opaque(), func(runs []stairRun) {
				// 両端の段は輪郭の直線へつながる所なので見ない
				if len(runs) < 4 {
					return
				}
				inner := runs[1 : len(runs)-1]
				dir := 0
				for i := 1; i < len(inner); i++ {
					d := sgn(inner[i].N - inner[i-1].N)
					if d == 0 {
						continue
					}
					if dir != 0 && d != dir {
						r := inner[i]
						out = append(out, Violation{Check: "run-monotone", Level: Lint, X: r.At.X, Y: r.At.Y, HasAt: true,
							Msg: fmt.Sprintf("曲線の段の長さが %s と増減する（長さは一方向に変える）", runLengths(inner))})
						return
					}
					dir = d
				}
			})
			return out
		},
	})
	registerCheck(&Check{
		Name: "ground-contrast", Summary: "外周の画素と地の色の明るさ（Oklab の L）の差が小さく、輪郭が地に溶ける", Level: Lint,
		Run: func(g *pxlib.Grid, c *CheckCtx) []Violation {
			gl, ok := pxlib.Lightness(c.Ground)
			if !ok {
				return nil
			}
			opaque := g.Opaque()
			d := opaque.DistFromEdge()
			sum, n := 0.0, 0
			worst, worstAt := math.Inf(1), pxlib.Pt{}
			for _, p := range opaque.Points() {
				if d[p.Y][p.X] != 1 {
					continue
				}
				l, ok := pxlib.Lightness(c.HexOf[g.Px[p.Y][p.X]])
				if !ok {
					continue
				}
				diff := math.Abs(l - gl)
				sum += diff
				n++
				if diff < worst {
					worst, worstAt = diff, p
				}
			}
			if n == 0 || sum/float64(n) >= c.Rules.GroundContrastMin {
				return nil
			}
			return []Violation{{Check: "ground-contrast", Level: Lint, X: worstAt.X, Y: worstAt.Y, HasAt: true,
				Msg: fmt.Sprintf("外周と地 %s の明るさの差が平均 %.3f（%.2f 以上にする。外周を暗い段か明るい段へ）", c.Ground, sum/float64(n), c.Rules.GroundContrastMin)}}
		},
	})
}

type stairRun struct {
	N  int
	At pxlib.Pt
}

// eachStair は 4 方向の輪郭の高さ列から、段差が ±1 で同じ向きに続く所（階段）を取り出して f に渡す。
func eachStair(m pxlib.Mask, f func([]stairRun)) {
	for side, seq := range m.Profiles() {
		var cur []stairRun
		dir := 0
		flush := func() {
			if len(cur) >= 3 {
				f(cur)
			}
			cur, dir = nil, 0
		}
		o := 0
		for o < len(seq) {
			if !seq[o].OK {
				flush()
				o++
				continue
			}
			start, v := o, seq[o].V
			for o < len(seq) && seq[o].OK && seq[o].V == v {
				o++
			}
			at := pxlib.Pt{X: start, Y: v}
			if side >= 2 {
				at = pxlib.Pt{X: v, Y: start}
			}
			run := stairRun{N: o - start, At: at}
			if len(cur) > 0 {
				prevV := seq[start-1].V
				step := v - prevV
				switch {
				case step != 1 && step != -1:
					flush()
				case dir != 0 && step != dir:
					// 向きが変わった: 折り返しの段は前後の両方の階段に入る
					last := cur[len(cur)-1]
					flush()
					cur, dir = []stairRun{last}, step
				default:
					dir = step
				}
			}
			cur = append(cur, run)
		}
		flush()
	}
}

func sgn(v int) int {
	switch {
	case v < 0:
		return -1
	case v > 0:
		return 1
	}
	return 0
}

func runLengths(runs []stairRun) string {
	parts := make([]string, len(runs))
	for i, r := range runs {
		parts[i] = fmt.Sprint(r.N)
	}
	return strings.Join(parts, "-")
}
