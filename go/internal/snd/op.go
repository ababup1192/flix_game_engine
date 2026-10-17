package snd

// op の登録。op の説明（何をするか・機種のどの部品か・引数・例）は、この opDef の構造体だけに書く。
// `fge snd ops`・`fge snd ops --md`（docs/snd-ops.md）・`fge snd schema --write`（docs/sndsrc.schema.json）は全部ここから作る。
//
// 声（voices の 1 つ）の ops は「音源の op 1 つ → 効果の op を順に」。post は声を混ぜた後に順に掛ける効果の op。
// 決まった数の計算（掛けて足す所）は float64(...) で包む: arm64 では a*b+c が FMA にまとまり、amd64 と結果が変わるため。

import (
	"os"
	"path/filepath"
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
	partSaw      part = "saw"  // ノコギリ（機種の外の音色。neo の breaks の saw）
	partSine     part = "sine" // サイン（機種の外の音色。neo の breaks の sine）
)

// sig は鳴らした音（ch が 1 本ならモノラル・2 本なら左右）とループの頭（無ければ -1）。
type sig struct {
	ch        [][]float64
	loopStart int
}

func (x sig) frames() int {
	if len(x.ch) == 0 {
		return 0
	}
	return len(x.ch[0])
}

// sourceOut は音源の op が作った物。
type sourceOut struct {
	ch        [][]float64 // 1 本 = モノラル・2 本 = 左右（song は左右）
	loopStart int         // ループの頭（無ければ -1）
	tempo     *tempo      // 拍の速さ（譜面の曲だけ）
	clamped   int         // 音源の中で ±1 に切ったサンプルの数（譜面の仕上げ）
	parts     []part      // 鳴らした部品（譜面は使ったチャンネル。ほかは op の Part）
	breaks    []string    // 機種の外の手（song の reverb・sidechain…。style の breaks で許す物だけ書ける）
	pans      []float64   // song のチャンネルを振った左右（style の pans で見る）
	drones    []drone     // song の鳴りっぱなしの音（検査の drone）
}

// rctx は書き出しの設定。
type rctx struct {
	rate     float64
	workRoot string
	files    map[string][]byte // 台本が書いた物（write_chip の譜面）。ディスクより先に引く
	kindLUFS float64           // kind の音量の目安（normalize の既定）
	truePeak float64           // true peak の上限（dBTP。normalize の既定）
}

// readFile は作業場の根からのパスを読む（台本が書いた物を先に）。
func (c *rctx) readFile(p string) ([]byte, error) {
	if d, ok := c.files[filepath.ToSlash(filepath.Clean(p))]; ok {
		return d, nil
	}
	return os.ReadFile(filepath.Join(c.workRoot, p))
}

// opDef は op 1 つ。
type opDef struct {
	Name    string
	Summary string // 何をするか（1 行）
	Machine string // 機種の部品として何に当たるか（docs に載せる）
	Example string // 書き方の例（{"名前": {…}}。テストで実際に鳴らす）
	Part    part   // 機種の部品（音源だけ。譜面は使ったチャンネルから）
	Break   string // 機種の外の手の名前（reverb・delay。style の breaks に無ければ gate）
	Params  []opreg.Param
	Gen     func(c *rctx, a opreg.Args) (sourceOut, error)              // 音源
	Fx      func(c *rctx, x []float64, a opreg.Args) ([]float64, error) // 効果（左右は 1 本ずつ同じ式で）
	Mix     func(c *rctx, x sig, a opreg.Args) (sig, error)             // 効果（左右を一緒に見る。ループの頭も渡る）
}

func (d *opDef) source() bool { return d.Gen != nil }

var registry = map[string]*opDef{}

func register(d *opDef) {
	if _, dup := registry[d.Name]; dup {
		panic("snd: op の名前が重複している: " + d.Name)
	}
	n := 0
	for _, f := range []bool{d.Gen != nil, d.Fx != nil, d.Mix != nil} {
		if f {
			n++
		}
	}
	if n != 1 {
		panic("snd: op は音源（Gen）か効果（Fx・Mix）のどれか 1 つ: " + d.Name)
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

// applyFx は効果の op を掛ける。Fx は 1 本ずつ（長さが違えば短い方に無音を足す）・Mix は左右を一緒に。
func applyFx(d *opDef, c *rctx, x sig, a opreg.Args) (sig, error) {
	if d.Mix != nil {
		return d.Mix(c, x, a)
	}
	out := sig{loopStart: x.loopStart}
	n := 0
	for _, ch := range x.ch {
		y, err := d.Fx(c, ch, a)
		if err != nil {
			return sig{}, err
		}
		out.ch = append(out.ch, y)
		n = max(n, len(y))
	}
	for i, y := range out.ch {
		if len(y) < n {
			out.ch[i] = append(y, make([]float64, n-len(y))...)
		}
	}
	if out.loopStart >= n {
		out.loopStart = -1
	}
	return out, nil
}
