package snd

// op の登録。op の説明（何をするか・機種のどの部品か・引数・例）は、この opDef の構造体だけに書く。
// `fge snd ops`・`fge snd ops --md`（docs/snd-ops.md）・`fge snd schema --write`（docs/sndsrc.schema.json）は全部ここから作る。
//
// 声（voices の 1 つ）の ops は「音源の op 1 つ → 効果の op を順に」。post は声を混ぜた後に順に掛ける効果の op。
// 決まった数の計算（掛けて足す所）は float64(...) で包む: arm64 では a*b+c が FMA にまとまり、amd64 と結果が変わるため。

import (
	"sort"

	"github.com/ababup1192/flix_game_engine/go/internal/opreg"
)

// part は機種の部品（style の voices の鍵）。
type part string

const (
	partPulse    part = "pulse"
	partNoise    part = "noise"
	partWave     part = "wave"
	partTriangle part = "triangle"
)

// sourceOut は音源の op が作った物。
type sourceOut struct {
	s         []float64
	loopStart int    // ループの頭（無ければ -1）
	tempo     *tempo // 拍の速さ（譜面の曲だけ）
	clamped   int    // 音源の中で ±1 に切ったサンプルの数（譜面の仕上げ）
	parts     []part // 鳴らした部品（譜面は使ったチャンネル。ほかは op の Part）
}

// rctx は書き出しの設定。
type rctx struct {
	rate     float64
	workRoot string
}

// opDef は op 1 つ。
type opDef struct {
	Name    string
	Summary string // 何をするか（1 行）
	Machine string // 機種の部品として何に当たるか（docs に載せる）
	Example string // 書き方の例（{"名前": {…}}。テストで実際に鳴らす）
	Part    part   // 機種の部品（音源だけ。譜面は使ったチャンネルから）
	Params  []opreg.Param
	Gen     func(c *rctx, a opreg.Args) (sourceOut, error)              // 音源
	Fx      func(c *rctx, x []float64, a opreg.Args) ([]float64, error) // 効果
}

func (d *opDef) source() bool { return d.Gen != nil }

var registry = map[string]*opDef{}

func register(d *opDef) {
	if _, dup := registry[d.Name]; dup {
		panic("snd: op の名前が重複している: " + d.Name)
	}
	if (d.Gen == nil) == (d.Fx == nil) {
		panic("snd: op は音源（Gen）か効果（Fx）のどちらか 1 つ: " + d.Name)
	}
	registry[d.Name] = d
}

func allOps() []*opDef {
	out := make([]*opDef, 0, len(registry))
	for _, d := range registry {
		out = append(out, d)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].source() != out[j].source() {
			return out[i].source()
		}
		return out[i].Name < out[j].Name
	})
	return out
}

func lookupParams(name string) ([]opreg.Param, bool) {
	d, ok := registry[name]
	if !ok {
		return nil, false
	}
	return d.Params, true
}

var (
	bound = opreg.Bound
	msP   = func(summary string) opreg.Param {
		return opreg.Param{Name: "ms", Type: opreg.Number, Required: true, Summary: summary, Lo: bound(0), Hi: bound(600000)}
	}
	ampP = opreg.Param{Name: "amp", Type: opreg.Number, Default: 0.5, Summary: "振幅（0〜1）", Lo: bound(0), Hi: bound(4)}
)

// frames は ms ミリ秒ぶんのサンプル数（最低 1。Dsp.frames と同じ）。
func (c *rctx) frames(ms float64) int {
	return max(1, int(float64(ms*c.rate)/1000))
}

// offset は at ミリ秒の位置（0 以下は 0）。
func (c *rctx) offset(ms float64) int {
	if ms <= 0 {
		return 0
	}
	return c.frames(ms)
}
