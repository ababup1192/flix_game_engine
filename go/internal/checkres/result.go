package checkres

// checkres — 道具の検査（px・snd ほか）の結果 1 件と、1 回の検査のまとめの形（共有）。
//
// 1 件は「何を測り（metric）・いくつで（got）・基準はいくつか（want）・あといくつ動かせば合うか（gap）」を数で持つ。
// AI が周回の次の手を選べるよう、直し方は文（hint）に加えて「どの op のどの引数を、今いくつから、いくつに」
// の候補（fix.try）を持つ。
//
// 組み立ては New の 1 か所（status・ratio・gap はここで計算する。検査の側は測った値と基準だけを渡す）。
// code は表（codes.go の Register）に載った物だけを使える。

import (
	"encoding/json"
	"fmt"
	"math"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/checklevel"
)

// Status は基準に対する結果。
type Status int

const (
	_    Status = iota
	Pass        // 基準を満たす
	Near        // 外れているが許容の帯の中（終了コードは 0。gate の near は止める）
	Fail        // 外れている
)

var statusNames = map[Status]string{Pass: "pass", Near: "near", Fail: "fail"}

func (s Status) String() string {
	if n, ok := statusNames[s]; ok {
		return n
	}
	return fmt.Sprintf("status(%d)", int(s))
}

func (s Status) MarshalJSON() ([]byte, error) {
	n, ok := statusNames[s]
	if !ok {
		return nil, fmt.Errorf("不正な status %d", int(s))
	}
	return json.Marshal(n)
}

func (s *Status) UnmarshalJSON(b []byte) error {
	var n string
	if err := json.Unmarshal(b, &n); err != nil {
		return err
	}
	for v, name := range statusNames {
		if name == n {
			*s = v
			return nil
		}
	}
	return fmt.Errorf("知らない status %q（pass・near・fail）", n)
}

// Op は基準の向き。
type Op string

const (
	AtLeast Op = ">="    // got が Value 以上
	AtMost  Op = "<="    // got が Value 以下
	Equal   Op = "=="    // got が Value と同じ
	InRange Op = "range" // got が Min 以上 Max 以下
)

// Want は基準（向きと値）。
type Want struct {
	Op    Op      `json:"op"`
	Value float64 `json:"value"`
	Min   float64 `json:"min,omitempty"` // range だけ
	Max   float64 `json:"max,omitempty"` // range だけ
}

func (w Want) String() string {
	if w.Op == InRange {
		return fmt.Sprintf("%s〜%s", num(w.Min), num(w.Max))
	}
	return fmt.Sprintf("%s %s", w.Op, num(w.Value))
}

// AtLeastOf などは Want を短く書く口。
func WantAtLeast(v float64) Want { return Want{Op: AtLeast, Value: v} }
func WantAtMost(v float64) Want  { return Want{Op: AtMost, Value: v} }
func WantEqual(v float64) Want   { return Want{Op: Equal, Value: v} }
func WantRange(lo, hi float64) Want {
	return Want{Op: InRange, Value: (lo + hi) / 2, Min: lo, Max: hi}
}

// Measure は検査が測った物（metric の名前・値・基準・単位）。単位と metric の名前は code の表から入る。
type Measure struct {
	Got  float64
	Want Want
}

// Pt は画素の座標。
type Pt struct {
	X int `json:"x"`
	Y int `json:"y"`
}

// Where は外れた場所。絵なら sprite・frame・x・y・画素（上限つき）、音なら時刻 ms と区間。
type Where struct {
	Sprite     string   `json:"sprite,omitempty"`
	Frame      string   `json:"frame,omitempty"`
	X          *int     `json:"x,omitempty"`
	Y          *int     `json:"y,omitempty"`
	Cells      []Pt     `json:"cells,omitempty"`      // 上限 MaxCells まで
	CellsTotal int      `json:"cellsTotal,omitempty"` // 切る前の数（切った時だけ）
	Ms         *float64 `json:"ms,omitempty"`
	FromMs     *float64 `json:"fromMs,omitempty"`
	ToMs       *float64 `json:"toMs,omitempty"`
	Channel    string   `json:"channel,omitempty"` // 左・右（ステレオで片方だけの時）
}

// Cause は外れの原因（描いた・鳴らした op と台本の行）。
type Cause struct {
	Op     string `json:"op,omitempty"`     // 例 body.ops[1] shade_step・voices[0].ops[2] pulse
	Script string `json:"script,omitempty"` // 台本の行（例 slime.px.star:42。分かる時だけ）
}

// Try は直し方の数の候補 1 つ: op の arg を now から try にすると、got が expect になる見込み。
// Expect は見込めない時に書かない（nil）。
type Try struct {
	Op     string   `json:"op"`
	Arg    string   `json:"arg"`
	Now    any      `json:"now,omitempty"`
	Try    any      `json:"try"`
	Expect *float64 `json:"expect,omitempty"`
}

// String は人向けの字面（例 "body.ops[1] directional の from を 1 → 0"・今の値が無ければ「足す」）。
func (t Try) String() string {
	if strings.HasPrefix(t.Op, "set ") { // 宣言を直す疑似の op（set kind・set material）
		return fmt.Sprintf("%s %s → %v", t.Op, t.Arg, t.Try)
	}
	if t.Now == nil {
		return fmt.Sprintf("%s に %s = %v を足す", t.Op, t.Arg, t.Try)
	}
	return fmt.Sprintf("%s の %s を %v → %v", t.Op, t.Arg, t.Now, t.Try)
}

// Fix は直し方（文の hint と数の候補）。
type Fix struct {
	Hint string `json:"hint,omitempty"`
	Try  []Try  `json:"try,omitempty"`
}

// Result は検査の結果 1 件。
type Result struct {
	Code   string           `json:"code"`
	Level  checklevel.Level `json:"level"`
	Status Status           `json:"status"`
	Metric string           `json:"metric"`
	Got    float64          `json:"got"`
	Want   Want             `json:"want"`
	Unit   string           `json:"unit"`
	Ratio  float64          `json:"ratio"`           // 基準に対する割合（1 で合格・小さいほど遠い）
	Gap    float64          `json:"gap"`             // あといくつ動かせば合格か（符号つき。合格なら 0）
	Scope  string           `json:"scope,omitempty"` // spec・sequence・frame・part・file（next の順）
	Where  Where            `json:"where"`
	Cause  Cause            `json:"cause"`
	Fix    Fix              `json:"fix"`
	Msg    string           `json:"msg"`
}

// New は結果 1 件を組み立てる唯一の口。code は表に載った物（無ければ panic: 書き忘れをテストで止める）。
// level は表の既定と違う時だけ渡す（0 なら表の既定）。status・ratio・gap はここで決める（帯は rules）。
func New(code string, lv checklevel.Level, m Measure, rules *Rules, msg string) Result {
	c, ok := Lookup(code)
	if !ok {
		panic(fmt.Sprintf("checkres: 表に無い code %q（checkres.Register で表に載せる）", code))
	}
	if lv == 0 {
		lv = c.Level
	}
	if m.Want.Op != c.Op {
		panic(fmt.Sprintf("checkres: %s の基準の向きが表（%s）と違う: %s", code, c.Op, m.Want.Op))
	}
	r := Result{Code: code, Level: lv, Metric: c.Metric, Unit: c.Unit, Got: round(m.Got), Want: m.Want, Msg: msg}
	r.Gap = round(gapOf(m.Got, m.Want))
	r.Ratio = round(ratioOf(m.Got, m.Want, c.Unit))
	switch {
	case r.Gap == 0:
		r.Status = Pass
	case rules.near(code, r.Ratio, r.Gap):
		r.Status = Near
	default:
		r.Status = Fail
	}
	return r
}

// gapOf は got を基準の一番近い合格の値まで動かす量（符号つき）。
func gapOf(got float64, w Want) float64 {
	switch w.Op {
	case AtLeast:
		return math.Max(0, w.Value-got)
	case AtMost:
		return math.Min(0, w.Value-got)
	case Equal:
		return w.Value - got
	case InRange:
		switch {
		case got < w.Min:
			return w.Min - got
		case got > w.Max:
			return w.Max - got
		}
	}
	return 0
}

// logUnits は対数の単位（dB 系）。割合は振幅の比（10^(-|gap|/20)）で出す。
var logUnits = map[string]bool{"dB": true, "dBFS": true, "dBTP": true, "LUFS": true}

// ratioOf は基準に対する割合（合格は 1・遠いほど 0 に近い）。
// 対数の単位は振幅の比・基準が 0 の数（外れの数など）は 1/(1+|gap|)・ほかは got と基準の比。
func ratioOf(got float64, w Want, unit string) float64 {
	gap := gapOf(got, w)
	if gap == 0 {
		return 1
	}
	if logUnits[unit] {
		return math.Pow(10, -math.Abs(gap)/20)
	}
	target := got + gap // 一番近い合格の値
	switch {
	case target == 0:
		return 1 / (1 + math.Abs(gap))
	case gap > 0: // 足りない（上へ動かす）
		return math.Max(0, got/target)
	default: // 多すぎる（下へ動かす）
		if got <= 0 {
			return 0
		}
		return math.Max(0, target/got)
	}
}

func round(v float64) float64 {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return v
	}
	return math.Round(v*10000) / 10000
}

func num(v float64) string {
	s := fmt.Sprintf("%.4f", v)
	s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	if s == "-0" {
		return "0"
	}
	return s
}

// Short は人向けの数の部分（例 "got 0.06 / want >= 0.1 (L)・あと +0.04"）。
func (r Result) Short() string {
	s := fmt.Sprintf("%s %s / want %s", r.Metric, num(r.Got), r.Want)
	if r.Unit != "" {
		s += " " + r.Unit
	}
	if r.Gap != 0 {
		s += fmt.Sprintf("・あと %+g", r.Gap)
	}
	return s
}

// SetAt は場所の x・y を入れる。
func (w *Where) SetAt(x, y int) { w.X, w.Y = &x, &y }

// SetCells は画素を上限つきで入れる（切ったら元の数を CellsTotal に）。
func (w *Where) SetCells(cells []Pt, limit int) {
	if limit > 0 && len(cells) > limit {
		w.CellsTotal = len(cells)
		cells = cells[:limit]
	}
	w.Cells = cells
}

// Ptr は数の参照を作る（Where の ms・Try の expect）。
func Ptr(v float64) *float64 { return &v }

// Compact は字下げしない JSON（--json の標準出力。周ごとに読むトークンを減らす）。末尾に改行。
func Compact(v any) []byte {
	var b strings.Builder
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		panic(err)
	}
	return []byte(b.String())
}

// JSON は 2 字下げの JSON（>= や <= を > にしない。AI と人が読む形のまま）。末尾に改行。
func JSON(v any) []byte {
	var b strings.Builder
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		panic(err)
	}
	return []byte(b.String())
}
