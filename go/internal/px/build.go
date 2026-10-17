package px

// build: 指定（pxsrc）を描いて、target の sprite.json に書き、見本と report.json を作る。
//
// base の sprite.json を読み、指定にあるコマの rows だけを差し替える（ほかのスプライトは残す）。
// 字下げは base の字面に合わせる。legend に無い色キーは、色票にあれば空いている字を当てて足す。
// 色の門（spec の gate）を通らなければ target を書かない。

import (
	"encoding/json"
	"fmt"
	"image/color"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flix_game_engine/go/internal/sprite"
)

// Options は build の切り替え。
type Options struct {
	RulesRoot string // 検査の閾値を読むリポジトリのルート（bin/lint-rules/）
	NoCheck   bool   // lint と advice を回さない（色の門は回す）
	OutDir    string // 見本と report.json の置き場（省くと <root>/debug/px/<名前>/last）
}

// FrameResult は描き上がった 1 コマ。
type FrameResult struct {
	Sprite  string   `json:"sprite"`
	Name    string   `json:"frame"`
	Rows    []string `json:"rows"`
	Same    bool     `json:"same"`    // base の同じコマとバイトで同じか
	HadBase bool     `json:"hadBase"` // base に同じコマがあったか
	grid    *pxlib.Grid
}

// Result は build 1 回の結果。
type Result struct {
	Spec        string            `json:"spec"`
	Target      string            `json:"target"`
	Wrote       bool              `json:"wrote"`
	Frames      []FrameResult     `json:"frames"`
	Violations  []Violation       `json:"violations"`
	Known       []string          `json:"known,omitempty"`
	LegendAdded []string          `json:"legendAdded,omitempty"`
	Sheet       string            `json:"sheet"`
	Legend      map[string]string `json:"legend"` // 字 → 色キー（次の周の差の見本に使う）
	Elapsed     time.Duration     `json:"elapsedNs"`
	Prev        *Counts           `json:"-"`
}

// Counts は重さごとの違反の数。
type Counts struct{ Gate, Lint, Advice int }

// Count は重さごとの違反の数。
func (r *Result) Count() Counts {
	var c Counts
	for _, v := range r.Violations {
		switch v.Level {
		case Gate:
			c.Gate++
		case Lint:
			c.Lint++
		default:
			c.Advice++
		}
	}
	return c
}

const legendPool = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#@$%&*+=?!~^"

// Build は spec を読んで描き、target に書き、見本と report.json を作る。
func Build(root, specPath string, opt Options) (*Result, error) {
	t0 := time.Now()
	full := specPath
	if !filepath.IsAbs(full) {
		full = filepath.Join(root, specPath)
	}
	spec, err := Load(full)
	if err != nil {
		return nil, err
	}
	base := spec.Base
	if base == "" {
		base = spec.Target
	}
	baseData, err := os.ReadFile(filepath.Join(root, base))
	var doc *pxlib.Obj
	indent := "\t"
	if err != nil {
		if spec.Palette == "" {
			return nil, fmt.Errorf("base %s が読めない（新しく作るなら spec に palette を書く）: %w", base, err)
		}
		doc = pxlib.NewObj()
		doc.Set("version", json.Number("1"))
		doc.Set("note", "fge px が "+filepath.Base(specPath)+" から描いた絵。直すのは指定（pxsrc）")
		doc.Set("paletteFile", spec.Palette)
		doc.Set("legend", pxlib.NewObj())
		doc.Set("sprites", pxlib.NewObj())
	} else {
		v, err := pxlib.DecodeOrdered(baseData)
		if err != nil {
			return nil, fmt.Errorf("%s: JSON として読めない: %w", base, err)
		}
		var ok bool
		if doc, ok = v.(*pxlib.Obj); !ok {
			return nil, fmt.Errorf("%s: 一番外はオブジェクトで書く", base)
		}
		indent = pxlib.DetectIndent(baseData)
	}
	legend, _ := doc.GetOr("legend", nil).(*pxlib.Obj)
	sprites, _ := doc.GetOr("sprites", nil).(*pxlib.Obj)
	if legend == nil || sprites == nil {
		return nil, fmt.Errorf("%s: legend と sprites が要る", base)
	}
	keyOf := map[string]pxlib.Key{}
	charOf := map[pxlib.Key]string{}
	lchars, lvals := legend.Items()
	for i, ch := range lchars {
		if k, ok := lvals[i].(string); ok {
			keyOf[ch] = pxlib.Key(k)
			if _, dup := charOf[pxlib.Key(k)]; !dup {
				charOf[pxlib.Key(k)] = ch
			}
		}
	}
	pal := PaletteOf(root, doc)
	if spec.Palette != "" {
		if po, err := pxlib.ReadOrdered(filepath.Join(root, spec.Palette)); err == nil {
			tmp := pxlib.NewObj()
			tmp.Set("palette", po)
			for k, h := range PaletteOf(root, tmp) {
				if _, ok := pal[k]; !ok {
					pal[k] = h
				}
			}
		}
	}
	hasKey := func(k pxlib.Key) bool {
		if _, ok := charOf[k]; ok {
			return true
		}
		_, ok := pal[string(k)]
		return ok
	}
	var rules *Rules
	var spriteRules *sprite.Rules
	if !opt.NoCheck {
		if rules, err = LoadRules(opt.RulesRoot); err != nil {
			return nil, err
		}
		if spriteRules, err = sprite.LoadRules(opt.RulesRoot); err != nil {
			return nil, err
		}
	}
	hexOf := map[pxlib.Key]string{}
	for k, h := range pal {
		hexOf[pxlib.Key(k)] = h
	}
	cc := &CheckCtx{Rules: rules, SpriteRules: spriteRules, HexOf: hexOf, Ground: groundHex(spec.Light.Ground, pal)}

	res := &Result{Spec: specPath, Target: spec.Target}
	addViolations := func(vs []Violation, sp, frame string) {
		for _, v := range vs {
			v.Sprite, v.Frame = sp, frame
			res.Violations = append(res.Violations, v)
		}
	}
	for _, sp := range spec.Sprites {
		entry, _ := sprites.GetOr(sp.Name, nil).(*pxlib.Obj)
		if entry == nil {
			entry = pxlib.NewObj()
			if sp.Note != "" {
				entry.Set("note", sp.Note)
			}
			anchor := pxlib.NewObj()
			anchor.Set("x", json.Number("0"))
			anchor.Set("y", json.Number("0"))
			entry.Set("anchor", anchor)
			entry.Set("frames", pxlib.NewObj())
			sprites.Set(sp.Name, entry)
		}
		if sp.Anchor != nil {
			anchor := pxlib.NewObj()
			anchor.Set("x", json.Number(fmt.Sprint(sp.Anchor[0])))
			anchor.Set("y", json.Number(fmt.Sprint(sp.Anchor[1])))
			entry.Set("anchor", anchor)
		}
		frames, _ := entry.GetOr("frames", nil).(*pxlib.Obj)
		if frames == nil {
			frames = pxlib.NewObj()
			entry.Set("frames", frames)
		}
		for _, f := range sp.Frames {
			r := &reader{}
			parts := sp.partsOf(r, spec, f)
			if len(r.probs) > 0 {
				return nil, r.probs
			}
			c := &Ctx{G: pxlib.NewGrid(sp.Size[0], sp.Size[1]), Spec: spec, Sprite: sp, Frame: f.Name, hasKey: hasKey, keyOf: keyOf}
			var after func(*PartState, []string) error
			if !opt.NoCheck {
				after = func(ps *PartState, names []string) error {
					if len(names) == 0 {
						return nil
					}
					sub := c.G.Only(ps.written.Union(ps.Region()))
					for _, n := range names {
						vs, err := runCheck(n, sub, cc)
						if err != nil {
							return fmt.Errorf("%s: %w", ps.Part.Where, err)
						}
						addViolations(vs, sp.Name, f.Name)
					}
					return nil
				}
			}
			if err := drawFrame(c, parts, sp.Post, after); err != nil {
				return nil, fmt.Errorf("%s/%s: %w", sp.Name, f.Name, err)
			}
			// legend に無い色キー: 色票にあれば空いている字を当てる
			for _, k := range c.G.Keys() {
				if _, ok := charOf[k]; ok {
					continue
				}
				if _, ok := pal[string(k)]; !ok {
					return nil, fmt.Errorf("%s/%s: 色キー %q が legend にも色票にも無い", sp.Name, f.Name, string(k))
				}
				ch := freeChar(legend)
				if ch == "" {
					return nil, fmt.Errorf("legend に当てる字が残っていない")
				}
				legend.Set(ch, string(k))
				keyOf[ch], charOf[k] = k, ch
				res.LegendAdded = append(res.LegendAdded, ch+"="+string(k))
			}
			rows, err := c.G.Rows(charOf)
			if err != nil {
				return nil, fmt.Errorf("%s/%s: %w", sp.Name, f.Name, err)
			}
			old, had := frames.Get(f.Name)
			fr := FrameResult{Sprite: sp.Name, Name: f.Name, Rows: rows, HadBase: had, grid: c.G}
			if had {
				fr.Same = pxlib.DumpPy(old, indent) == pxlib.DumpPy(rows, indent)
			}
			frames.Set(f.Name, rowsAny(rows))
			res.Frames = append(res.Frames, fr)
			if !opt.NoCheck {
				for _, n := range FrameChecks {
					vs, err := runCheck(n, c.G, cc)
					if err != nil {
						return nil, err
					}
					addViolations(vs, sp.Name, f.Name)
				}
			}
		}
	}
	res.Violations = dedupeViolations(res.Violations)
	if spec.Gate != "" {
		gate, err := LoadColorGate(root, spec.Gate)
		if err != nil {
			return nil, err
		}
		bad, known := gate.CheckDoc(root, doc, filepath.Base(spec.Target))
		res.Known = known
		for _, b := range bad {
			res.Violations = append(res.Violations, gateViolation(b, res.Frames, keyOf, legend))
		}
	}
	res.Legend = map[string]string{}
	lchars, lvals = legend.Items()
	for i, ch := range lchars {
		if s, ok := lvals[i].(string); ok {
			res.Legend[ch] = s
		}
	}
	if res.Count().Gate == 0 {
		out := filepath.Join(root, spec.Target)
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			return nil, err
		}
		if err := os.WriteFile(out, []byte(pxlib.DumpPy(doc, indent)), 0o644); err != nil {
			return nil, err
		}
		res.Wrote = true
	}
	dir := opt.OutDir
	if dir == "" {
		dir = filepath.Join(root, "debug", "px", specName(specPath), "last")
	}
	prev := readPrev(filepath.Join(dir, "report.json"))
	if prev != nil {
		c := prev.Count()
		res.Prev = &c
	}
	if err := writeSheets(dir, res, prev, hexOf, groundColor(cc.Ground)); err != nil {
		return nil, err
	}
	res.Sheet = filepath.Join(dir, "sheet.png")
	res.Elapsed = time.Since(t0)
	data, _ := json.MarshalIndent(res, "", "  ")
	if err := os.WriteFile(filepath.Join(dir, "report.json"), append(data, '\n'), 0o644); err != nil {
		return nil, err
	}
	return res, nil
}

func rowsAny(rows []string) []any {
	out := make([]any, len(rows))
	for i, r := range rows {
		out[i] = r
	}
	return out
}

func freeChar(legend *pxlib.Obj) string {
	for _, r := range legendPool {
		if !legend.Has(string(r)) {
			return string(r)
		}
	}
	return ""
}

// dedupeViolations は部品の範囲と全体で同じ物を 2 度数えない（先に出た方を残す）。
func dedupeViolations(vs []Violation) []Violation {
	seen := map[string]bool{}
	var out []Violation
	for _, v := range vs {
		k := fmt.Sprintf("%s|%s|%s|%d|%d|%s", v.Sprite, v.Frame, v.Check, v.X, v.Y, v.Msg)
		if !seen[k] {
			seen[k] = true
			out = append(out, v)
		}
	}
	return out
}

// gateViolation は門の違反に、その色を最初に使った画素と、そこを描いた op を付ける。
func gateViolation(b GateViolation, frames []FrameResult, keyOf map[string]pxlib.Key, legend *pxlib.Obj) Violation {
	v := Violation{Check: "gate:" + b.Kind, Level: Gate, Sprite: b.Sprite, Msg: b.Msg}
	for _, f := range frames {
		if f.Sprite != b.Sprite || f.grid == nil {
			continue
		}
		for y := 0; y < f.grid.H; y++ {
			for x := 0; x < f.grid.W; x++ {
				if string(f.grid.Px[y][x]) == b.Key {
					v.Frame, v.X, v.Y, v.HasAt, v.Op = f.Name, x, y, true, f.grid.Src[y][x]
					return v
				}
			}
		}
	}
	return v
}

func groundHex(ground string, pal map[string]string) string {
	if h, ok := pal[ground]; ok {
		return h
	}
	return pxlib.HexOfValue(ground)
}

func groundColor(hex string) color.RGBA {
	if c, ok := pxlib.RGBAOfValue(hex); ok {
		return color.RGBA{c[0], c[1], c[2], 0xff}
	}
	return color.RGBA{0x2a, 0x2a, 0x33, 0xff}
}

func readPrev(path string) *Result {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var r Result
	if json.Unmarshal(data, &r) != nil {
		return nil
	}
	return &r
}

// UnmarshalJSON は report.json の level を名前から戻す。
func (l *Level) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	for i, n := range []string{"gate", "lint", "advice"} {
		if s == n {
			*l = Level(i)
		}
	}
	return nil
}

func colorsOf(rows []string, legend map[string]string, hexOf map[pxlib.Key]string) [][]color.RGBA {
	out := make([][]color.RGBA, len(rows))
	for y, row := range rows {
		for _, ch := range row {
			c := color.RGBA{}
			if ch != '.' {
				c = color.RGBA{0xff, 0x00, 0xff, 0xff} // 色票に無い = 仮色（Studio と同じ症状）
				if h, ok := hexOf[pxlib.Key(legend[string(ch)])]; ok {
					if rgba, ok := pxlib.RGBAOfValue(h); ok {
						c = color.RGBA{rgba[0], rgba[1], rgba[2], 0xff}
					}
				}
			}
			out[y] = append(out[y], c)
		}
	}
	return out
}

// writeSheets は sheet.png（全コマ）と <スプライト>.png（そのスプライトのコマを実寸で横に）を書く。
func writeSheets(dir string, res *Result, prev *Result, hexOf map[pxlib.Key]string, ground color.RGBA) error {
	prevRows := map[string][]string{}
	if prev != nil {
		for _, f := range prev.Frames {
			prevRows[f.Sprite+"/"+f.Name] = f.Rows
		}
	}
	var sheet []pxlib.SheetFrame
	bySprite := map[string][][][]color.RGBA{}
	var order []string
	for _, f := range res.Frames {
		px := colorsOf(f.Rows, res.Legend, hexOf)
		sf := pxlib.SheetFrame{Px: px}
		if rows, ok := prevRows[f.Sprite+"/"+f.Name]; ok {
			sf.Prev = colorsOf(rows, prev.Legend, hexOf)
		}
		sheet = append(sheet, sf)
		if _, ok := bySprite[f.Sprite]; !ok {
			order = append(order, f.Sprite)
		}
		bySprite[f.Sprite] = append(bySprite[f.Sprite], px)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := pxlib.WritePNG(filepath.Join(dir, "sheet.png"), pxlib.Sheet(sheet, ground, 4)); err != nil {
		return err
	}
	sort.Strings(order)
	for _, name := range order {
		if err := pxlib.WritePNG(filepath.Join(dir, safeName(name)+".png"), pxlib.Strip(bySprite[name])); err != nil {
			return err
		}
	}
	return nil
}

func safeName(s string) string {
	return strings.Map(func(r rune) rune {
		if r == '/' || r == '\\' || r == ':' {
			return '_'
		}
		return r
	}, s)
}
