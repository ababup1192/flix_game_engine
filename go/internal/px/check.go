package px

// 検査。重さは 3 段: gate（色の門。外れたら書き出さず終了コード 1）・lint（報告だけ）・advice（報告だけ）。
// 違反は画素の書き手（Grid.SrcAt）から「どの部品の何番目の op」が原因かを引いて持つ。

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

// level は検査の重さ。0 は不正な値（書き忘れを通さない）。
type level int

const (
	_           level = iota
	levelGate         // 外れたら止める
	levelLint         // 報告だけ
	levelAdvice       // 報告だけ（技法の助言）
)

var levelNames = map[level]string{levelGate: "gate", levelLint: "lint", levelAdvice: "advice"}

func (l level) String() string {
	if n, ok := levelNames[l]; ok {
		return n
	}
	return fmt.Sprintf("level(%d)", int(l))
}

// MarshalJSON は名前で書く。不正な値は書かない。
func (l level) MarshalJSON() ([]byte, error) {
	n, ok := levelNames[l]
	if !ok {
		return nil, fmt.Errorf("不正な level %d", int(l))
	}
	return json.Marshal(n)
}

// UnmarshalJSON は名前から戻す。読めない名前は誤り。
func (l *level) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	for v, n := range levelNames {
		if n == s {
			*l = v
			return nil
		}
	}
	return fmt.Errorf("知らない level %q（gate・lint・advice）", s)
}

// checkName は検査の名前。
type checkName string

const (
	checkSprite         checkName = "sprite"          // bin/fge sprite の形の規則
	checkFlatRun        checkName = "flat-run"        // 段が同じ長さで続く・長い直線
	checkRunMonotone    checkName = "run-monotone"    // 曲線の段の長さが単調でない
	checkGroundContrast checkName = "ground-contrast" // 外周と地の明るさの差
	checkGate           checkName = "gate"            // 色の門
)

// checkRef は検査 1 つ（Rule は sprite の規則か門の種類で絞るとき）。
type checkRef struct {
	Check checkName
	Rule  string
}

func (r checkRef) String() string {
	if r.Rule == "" {
		return string(r.Check)
	}
	return string(r.Check) + ":" + r.Rule
}

// violation は検査の違反 1 件。
type violation struct {
	Check  checkName   `json:"check"`
	Rule   string      `json:"rule,omitempty"`
	Level  level       `json:"level"`
	Sprite string      `json:"sprite,omitempty"`
	Frame  string      `json:"frame,omitempty"`
	X      int         `json:"x"`
	Y      int         `json:"y"`
	HasAt  bool        `json:"hasAt"`
	Cells  []pxlib.Pt  `json:"cells,omitempty"`
	Op     pxlib.OpRef `json:"op"`
	Msg    string      `json:"msg"`
}

func (v violation) ref() checkRef { return checkRef{v.Check, v.Rule} }

// key は前の周と同じ違反かを見分ける鍵。
func (v violation) key() string {
	return fmt.Sprintf("%s|%s|%s|%d|%d|%s", v.ref(), v.Sprite, v.Frame, v.X, v.Y, v.Msg)
}

// String は 1 行の字面（例 slime/idle body.ops[1] shade_step: run-monotone (14,9): …）。
func (v violation) String() string {
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
	b.WriteString(v.ref().String())
	if v.HasAt {
		fmt.Fprintf(&b, " (%d,%d)", v.X, v.Y)
	}
	b.WriteString(": " + v.Msg)
	return b.String()
}

// checkCtx は検査が読む物。
type checkCtx struct {
	Rules       *pxRules
	SpriteRules *sprite.Rules
	Ground      string               // 地の色 #rrggbb（無ければ ""）
	HexOf       map[pxlib.Key]string // 色キー → #rrggbb
}

// checkDef は検査 1 つ。
type checkDef struct {
	Name    checkName
	Summary string
	Level   level
	Run     func(g *pxlib.Grid, c *checkCtx) []violation
}

var checks = map[checkName]*checkDef{}

func registerCheck(c *checkDef) { checks[c.Name] = c }

// allChecks は登録した検査を名前の順で返す。
func allChecks() []*checkDef {
	out := make([]*checkDef, 0, len(checks))
	for _, c := range checks {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// frameChecks はコマを描き終えた後に回す検査（全体）。
var frameChecks = []checkRef{{Check: checkSprite}, {Check: checkFlatRun}, {Check: checkRunMonotone}, {Check: checkGroundContrast}}

// runCheck は検査を回し、違反に書き手の op を付ける。
// 書き手の op が Exempt にその検査を挙げている画素は除く（作法として置く形。例 bevel_box の角）。
func runCheck(ref checkRef, g *pxlib.Grid, c *checkCtx) ([]violation, error) {
	ck, ok := checks[ref.Check]
	if !ok {
		return nil, fmt.Errorf("知らない検査 %q", ref)
	}
	var out []violation
	for _, v := range ck.Run(g, c) {
		if ref.Rule != "" && v.Rule != ref.Rule {
			continue
		}
		if v, keep := dropExempt(v, g); keep {
			out = append(out, v)
		}
	}
	return out, nil
}

// exempts は op が v の検査の対象外か。
func exempts(op pxlib.OpRef, ref checkRef) bool {
	name, _, _ := strings.Cut(op.Op, ">")
	if strings.Contains(op.Op, ">") {
		name = op.Op[strings.LastIndex(op.Op, ">")+1:]
	}
	def, ok := lookupOp(name)
	if !ok {
		return false
	}
	for _, e := range def.Exempt {
		if e.Check == ref.Check && (e.Rule == "" || e.Rule == ref.Rule) {
			return true
		}
	}
	return false
}

func dropExempt(v violation, g *pxlib.Grid) (violation, bool) {
	if len(v.Cells) > 0 {
		var kept []pxlib.Pt
		dropped, by := 0, ""
		for _, p := range v.Cells {
			if op := g.SrcAt(p.X, p.Y); exempts(op, v.ref()) {
				dropped++
				by = op.Op
				continue
			}
			kept = append(kept, p)
		}
		if len(kept) == 0 {
			return v, false
		}
		if dropped > 0 {
			v.Cells = kept
			v.X, v.Y, v.HasAt = kept[0].X, kept[0].Y, true
			if v.Check == checkSprite {
				if msg, ok := sprite.FindingMsg(v.Rule, kept); ok {
					v.Msg = msg
				}
			}
			v.Msg += fmt.Sprintf("（ほかに %d 箇所は %s の作法として除いた）", dropped, by)
		}
	} else if v.HasAt && exempts(g.SrcAt(v.X, v.Y), v.ref()) {
		return v, false
	}
	if v.HasAt {
		v.Op = g.SrcAt(v.X, v.Y)
	}
	return v, true
}

// pxRules は検査の閾値（bin/lint-rules/px.json）。
type pxRules struct {
	FlatRunRepeat     int     `json:"flatRunRepeat"`
	FlatRunStraight   int     `json:"flatRunStraight"`
	FlatRunPer        int     `json:"flatRunPer"`
	GroundContrastMin float64 `json:"groundContrastMin"`
}

// loadRules は閾値を読む。読めなければ止める（既定値へ倒すと、消しただけで検査が黙って緩む）。
func loadRules(root string) (*pxRules, error) {
	path := filepath.Join(root, "bin", "lint-rules", "px.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("検査の閾値を読めない: %v", err)
	}
	var r pxRules
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("%s が JSON として壊れている: %v", path, err)
	}
	if r.FlatRunRepeat < 2 || r.FlatRunStraight < 1 || r.FlatRunPer < 1 || r.GroundContrastMin <= 0 {
		return nil, fmt.Errorf("%s に flatRunRepeat・flatRunStraight・flatRunPer・groundContrastMin を書く", path)
	}
	return &r, nil
}

func init() {
	registerCheck(&checkDef{
		Name: checkSprite, Summary: "bin/fge sprite の形の規則（orphan・connect・jaggy・banding・corner・silhouette）", Level: levelLint,
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			var out []violation
			for _, f := range c.SpriteRules.CheckFrame(g) {
				out = append(out, fromFinding(f))
			}
			return out
		},
	})
	registerCheck(&checkDef{
		Name: checkFlatRun, Summary: "輪郭の段: 同じ長さの段が続く（直線に読まれる）・長すぎる直線（16px で 4px・32px で 6px を超える）", Level: levelAdvice,
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			limit := c.Rules.FlatRunStraight + max(g.W, g.H)/c.Rules.FlatRunPer
			var out []violation
			eachStair(g.Opaque(), func(runs []stairRun) {
				same := 1
				for i, r := range runs {
					if i > 0 && r.N == runs[i-1].N {
						same++
					} else {
						same = 1
					}
					if same == c.Rules.FlatRunRepeat {
						out = append(out, violation{Check: checkFlatRun, Level: levelAdvice, X: r.At.X, Y: r.At.Y, HasAt: true,
							Msg: fmt.Sprintf("長さ %d の段が %d 回続く（直線に読まれる。段の長さを変える）", r.N, same)})
					}
					inner := i > 0 && i < len(runs)-1
					if inner && r.N > limit {
						out = append(out, violation{Check: checkFlatRun, Level: levelAdvice, X: r.At.X, Y: r.At.Y, HasAt: true,
							Msg: fmt.Sprintf("曲線の中に %dpx の直線（%dx%d の絵では %dpx まで）", r.N, g.W, g.H, limit)})
					}
				}
			})
			return out
		},
	})
	registerCheck(&checkDef{
		Name: checkRunMonotone, Summary: "曲線の段の長さが単調でない（3-2-1 は良い・1-2-1-2 と 3-2-1-4 は不可）", Level: levelLint,
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			var out []violation
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
						out = append(out, violation{Check: checkRunMonotone, Level: levelLint, X: r.At.X, Y: r.At.Y, HasAt: true,
							Msg: fmt.Sprintf("曲線の段の長さが %s と増減する（長さは一方向に変える）", runLengths(inner))})
						return
					}
					dir = d
				}
			})
			return out
		},
	})
	registerCheck(&checkDef{
		Name: checkGroundContrast, Summary: "外周の画素と地の色の明るさ（Oklab の L）の差が小さく、輪郭が地に溶ける", Level: levelLint,
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
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
				l, ok := pxlib.Lightness(c.HexOf[g.At(p.X, p.Y)])
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
			return []violation{{Check: checkGroundContrast, Level: levelLint, X: worstAt.X, Y: worstAt.Y, HasAt: true,
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

// fromFinding は sprite の形の規則の 1 件を違反にする。fge sprite が NG にする件（Problem）は
// gate（止める）、注意の件は lint に写す（precommit を fge px check へ移しても止まる所を変えない）。
func fromFinding(f sprite.Finding) violation {
	lv := levelLint
	if f.Problem {
		lv = levelGate
	}
	return violation{Check: checkSprite, Rule: f.Rule, Level: lv, X: f.At.X, Y: f.At.Y, HasAt: f.HasAt, Cells: f.Cells, Msg: f.Msg}
}
