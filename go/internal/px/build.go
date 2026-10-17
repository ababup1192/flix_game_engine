package px

// build: 指定（pxsrc）を描いて、target の sprite.json に書き、見本と report.json を作る。
//
// base の sprite.json を読み、指定にあるコマの rows だけを差し替える（ほかのスプライトは残す）。
// 字下げは spec の indent、無ければ base の字面に合わせる。legend に無い色キーは、色票にあれば空いている字を当てて足す。
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

// buildOptions は build の切り替え。
type buildOptions struct {
	RulesRoot string // 検査の閾値を読むリポジトリのルート（bin/lint-rules/）
	NoCheck   bool   // lint と advice を回さない（色の門は回す）
	OutDir    string // 見本と report.json の置き場（省くと <root>/debug/px/<名前>/last）
}

// frameResult は描き上がった 1 コマ。
type frameResult struct {
	Sprite  string   `json:"sprite"`
	Name    string   `json:"frame"`
	Rows    []string `json:"rows"`
	Same    bool     `json:"same"`    // base の同じコマとバイトで同じか
	HadBase bool     `json:"hadBase"` // base に同じコマがあったか
	grid    *pxlib.Grid
}

// buildResult は build 1 回の結果。
type buildResult struct {
	Spec        string            `json:"spec"`
	Target      string            `json:"target"`
	Wrote       bool              `json:"wrote"`
	Frames      []frameResult     `json:"frames"`
	Violations  []violation       `json:"violations"`
	Known       []string          `json:"known,omitempty"`
	LegendAdded []string          `json:"legendAdded,omitempty"`
	Sheet       string            `json:"sheet"`
	Legend      map[string]string `json:"legend"` // 字 → 色キー（次の周の差の見本に使う）
	Elapsed     time.Duration     `json:"elapsedNs"`
	Prev        *levelCounts      `json:"-"`
	prevKeys    map[string]bool   // 前の周の違反（上位の件を「新しい物から」出すため）
}

// levelCounts は重さごとの違反の数。
type levelCounts struct{ Gate, Lint, Advice int }

// Count は重さごとの違反の数。
func (r *buildResult) Count() levelCounts {
	var c levelCounts
	for _, v := range r.Violations {
		switch v.Level {
		case levelGate:
			c.Gate++
		case levelLint:
			c.Lint++
		default:
			c.Advice++
		}
	}
	return c
}

const legendPool = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#@$%&*+=?!~^"

// build は spec を読んで描き、target に書き、見本と report.json を作る。
func build(root, specPath string, opt buildOptions) (*buildResult, error) {
	t0 := time.Now()
	full := specPath
	if !filepath.IsAbs(full) {
		full = filepath.Join(root, specPath)
	}
	spec, err := loadSpec(full)
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
	if spec.Indent != "" {
		indent = spec.Indent
	}
	legend, _ := doc.GetOr("legend", nil).(*pxlib.Obj)
	sprites, _ := doc.GetOr("sprites", nil).(*pxlib.Obj)
	if legend == nil || sprites == nil {
		return nil, fmt.Errorf("%s: legend と sprites が要る", base)
	}
	lg := pxlib.LegendOf(legend)
	plainDoc := pxlib.Plain(doc).(map[string]any)
	pal := pxlib.DocPalette(root, plainDoc, nil, pxlib.AnyColor)
	if spec.Palette != "" {
		for k, h := range pxlib.ColorTable(pxlib.ReadJSON(filepath.Join(root, spec.Palette)), pxlib.AnyColor) {
			if _, ok := pal[k]; !ok {
				pal[k] = h
			}
		}
	}
	hasKey := func(k pxlib.Key) bool {
		if _, ok := lg.CharOf[k]; ok {
			return true
		}
		_, ok := pal[string(k)]
		return ok
	}
	var rules *pxRules
	var spriteRules *sprite.Rules
	if !opt.NoCheck {
		if rules, err = loadRules(opt.RulesRoot); err != nil {
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
	cc := &checkCtx{Rules: rules, SpriteRules: spriteRules, HexOf: hexOf, Ground: groundHex(spec.Light.Ground, pal)}

	res := &buildResult{Spec: specPath, Target: spec.Target}
	addViolations := func(vs []violation, sp, frame string) {
		exempt := map[string]bool{}
		if spriteRules != nil {
			exempt = spriteRules.ExemptRules(plainDoc, sp)
		}
		for _, v := range vs {
			if v.Check == checkSprite && exempt[v.Rule] {
				continue // base の lint-sprite が対象外にした規則
			}
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
			anchor.Set("x", json.Number(fmt.Sprint(sp.Anchor.X)))
			anchor.Set("y", json.Number(fmt.Sprint(sp.Anchor.Y)))
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
			c := &ctx{G: pxlib.NewGrid(sp.Size.W, sp.Size.H), Spec: spec, Sprite: sp, Frame: f.Name, hasKey: hasKey, keyOf: lg.KeyOf}
			var after func(*partState, []checkRef) error
			if !opt.NoCheck {
				after = func(ps *partState, names []checkRef) error {
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
				if _, ok := lg.CharOf[k]; ok {
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
				lg.Set(ch, k)
				res.LegendAdded = append(res.LegendAdded, ch+"="+string(k))
			}
			rows, err := c.G.Rows(lg.CharOf)
			if err != nil {
				return nil, fmt.Errorf("%s/%s: %w", sp.Name, f.Name, err)
			}
			old, had := frames.Get(f.Name)
			fr := frameResult{Sprite: sp.Name, Name: f.Name, Rows: rows, HadBase: had, grid: c.G}
			if had {
				fr.Same = pxlib.DumpPy(old, indent) == pxlib.DumpPy(rows, indent)
			}
			frames.Set(f.Name, rowsAny(rows))
			res.Frames = append(res.Frames, fr)
			if !opt.NoCheck {
				for _, n := range frameChecks {
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
		gate, err := loadColorGate(root, spec.Gate)
		if err != nil {
			return nil, err
		}
		bad, known := gate.CheckDoc(root, doc, filepath.Base(spec.Target))
		res.Known = known
		for _, b := range bad {
			res.Violations = append(res.Violations, gateViolation(b, res.Frames))
		}
	}
	res.Legend = map[string]string{}
	for ch, k := range lg.KeyOf {
		res.Legend[ch] = string(k)
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
		res.prevKeys = map[string]bool{}
		for _, v := range prev.Violations {
			res.prevKeys[v.key()] = true
		}
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
func dedupeViolations(vs []violation) []violation {
	seen := map[string]bool{}
	var out []violation
	for _, v := range vs {
		k := v.key()
		if !seen[k] {
			seen[k] = true
			out = append(out, v)
		}
	}
	return out
}

// gateViolation は門の違反に、その色を最初に使った画素と、そこを描いた op を付ける。
func gateViolation(b gateFinding, frames []frameResult) violation {
	v := violation{Check: checkGate, Rule: string(b.Kind), Level: levelGate, Sprite: b.Sprite, Msg: b.Msg}
	for _, f := range frames {
		if f.Sprite != b.Sprite || f.grid == nil {
			continue
		}
		for y := 0; y < f.grid.H; y++ {
			for x := 0; x < f.grid.W; x++ {
				if string(f.grid.At(x, y)) == b.Key {
					v.Frame, v.X, v.Y, v.HasAt, v.Op = f.Name, x, y, true, f.grid.SrcAt(x, y)
					return v
				}
			}
		}
	}
	return v
}

func groundHex(ground colorRef, pal map[string]string) string {
	if h, ok := pal[string(ground)]; ok {
		return h
	}
	return pxlib.HexOfValue(string(ground))
}

func groundColor(hex string) color.RGBA {
	if c, ok := pxlib.RGBAOfValue(hex); ok {
		return color.RGBA{c[0], c[1], c[2], 0xff}
	}
	return color.RGBA{0x2a, 0x2a, 0x33, 0xff}
}

func readPrev(path string) *buildResult {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var r buildResult
	if json.Unmarshal(data, &r) != nil {
		return nil
	}
	return &r
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
func writeSheets(dir string, res *buildResult, prev *buildResult, hexOf map[pxlib.Key]string, ground color.RGBA) error {
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
