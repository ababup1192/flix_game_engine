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

	"github.com/ababup1192/flix_game_engine/go/internal/anim"
	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flix_game_engine/go/internal/sprite"
)

// techFrameChecks は段 3 でコマごとに足した全体の検査（value-sep は contrast を書いた時だけ・style は spec に style がある時だけ鳴る）。
var techFrameChecks = []checkRef{{Check: checkValueSep}, {Check: checkStyle}}

// buildOptions は build の切り替え。
type buildOptions struct {
	RulesRoot string            // 検査の閾値を読むリポジトリのルート（bin/lint-rules/）
	NoCheck   bool              // lint と advice を回さない（色の門は回す）
	OutDir    string            // 見本と report.json の置き場（省くと <root>/debug/px/<名前>/last）
	Sheet     bool              // 見比べのシート（PNG）も書く（--sheet・px snap。PNG の圧縮が描く時間より重いので既定は書かない）
	Overlay   map[string][]byte // 台本がメモリの中で書いた物（絶対パス → 中身）。spec と palette はディスクより先にここを見る
}

// buildTiming は build の中の時間の内訳（--time で出す）。
type buildTiming struct {
	Draw  time.Duration `json:"drawNs"`  // spec を読んでコマを描く（検査を除く）
	Check time.Duration `json:"checkNs"` // lint・advice の検査
	Gate  time.Duration `json:"gateNs"`  // 色の門と sprite.json の書き出し
	Sheet time.Duration `json:"sheetNs"` // 見比べのシート（--sheet の時だけ）
}

// frameResult は描き上がった 1 コマ。
type frameResult struct {
	Sprite  string   `json:"sprite"`
	Name    string   `json:"frame"`
	Rows    []string `json:"rows"`
	Same    bool     `json:"same"`           // base の同じコマとバイトで同じか
	HadBase bool     `json:"hadBase"`        // base に同じコマがあったか
	Tile    bool     `json:"tile,omitempty"` // tile_preview がある（3×3 の見本を書く）
	Anim    bool     `json:"anim,omitempty"` // コマ列（玉ねぎの皮の列を足す）
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
	Hex         map[string]string `json:"hex"`    // 色キー → #rrggbb（fge px diff が周の絵を描き直すのに使う）
	Elapsed     time.Duration     `json:"elapsedNs"`
	Timing      buildTiming       `json:"timing"`
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
	var checkDur time.Duration
	runCheck := func(ref checkRef, g *pxlib.Grid, c *checkCtx) ([]violation, error) {
		t := time.Now()
		defer func() { checkDur += time.Since(t) }()
		return runCheck(ref, g, c)
	}
	full := specPath
	if !filepath.IsAbs(full) {
		full = filepath.Join(root, specPath)
	}
	var spec *specDoc
	var err error
	if data, ok := opt.Overlay[filepath.Clean(full)]; ok {
		spec, err = loadSpecData(full, data)
	} else {
		spec, err = loadSpec(full)
	}
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
		palPath := filepath.Join(root, spec.Palette)
		if data, ok := opt.Overlay[filepath.Clean(palPath)]; ok {
			// 台本が書いた色票はディスクの古い色票より先に効かせる
			var v any
			if err := json.Unmarshal(data, &v); err != nil {
				return nil, fmt.Errorf("%s: JSON として読めない: %w", spec.Palette, err)
			}
			for k, h := range pxlib.ColorTable(v, pxlib.AnyColor) {
				pal[k] = h
			}
		} else {
			for k, h := range pxlib.ColorTable(pxlib.LoadJSON(palPath), pxlib.AnyColor) {
				if _, ok := pal[k]; !ok {
					pal[k] = h
				}
			}
		}
	}
	// spec の style は機種の決まり（px.json の styles か *.pxstyle.json）。色の門の画風は門が決め、機種は上乗せの縛り
	var gate *colorGate
	if spec.Gate != "" {
		if gate, err = loadColorGate(root, spec.Gate); err != nil {
			return nil, err
		}
	}
	style, err := loadStyle(root, opt.RulesRoot, spec.Style)
	if err != nil {
		return nil, err
	}
	if style != nil {
		for k, h := range style.Colors {
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
	cc := &checkCtx{Rules: rules, SpriteRules: spriteRules, HexOf: hexOf, Ground: groundHex(spec.Light.Ground, pal),
		Light: spec.Light.Dir, Ramps: map[string][]pxlib.Key{}, Style: style, RampOwner: map[string]string{}}
	for k, r := range spec.Ramps {
		cc.Ramps[k] = r
	}
	var animRules *anim.Rules
	if !opt.NoCheck {
		if animRules, err = anim.LoadRules(opt.RulesRoot); err != nil {
			return nil, err
		}
	}

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
		seeds := sp.Seeds
		if len(seeds) == 0 {
			seeds = []int{0}
		}
		for _, seed := range seeds {
			var seqNames []string
			var seqRows [][]string
			var seqGrids []*pxlib.Grid
			for fi, f := range sp.Frames {
				r := &reader{}
				parts := sp.partsOf(r, spec, f)
				if len(r.probs) > 0 {
					return nil, r.probs
				}
				fname := f.Name
				if len(sp.Seeds) > 0 {
					fname = fmt.Sprintf("%s_v%d", f.Name, seed)
				}
				c := &ctx{G: pxlib.NewGrid(sp.Size.W, sp.Size.H), Spec: spec, Sprite: sp, Frame: fname, hasKey: hasKey, keyOf: lg.KeyOf,
					FrameIndex: fi, FrameCount: len(sp.Frames), Seed: seed, hexOf: hexOf, style: style}
				var after func(*partState, []checkRef) error
				if !opt.NoCheck {
					after = func(ps *partState, names []checkRef) error {
						for id, r := range c.picked {
							cc.Ramps[sp.Name+"."+id] = r
							cc.RampOwner[sp.Name+"."+id] = sp.Name
						}
						if len(names) == 0 {
							return nil
						}
						sub := c.G.Only(ps.written.Union(ps.Region()))
						cc.Measures, cc.Wrap = c.measures, c.wrap
						for _, n := range names {
							vs, err := runCheck(n, sub, cc)
							if err != nil {
								return fmt.Errorf("%s: %w", ps.Part.Where, err)
							}
							addViolations(vs, sp.Name, fname)
						}
						return nil
					}
				}
				if err := drawFrame(c, parts, sp.Post, after); err != nil {
					return nil, fmt.Errorf("%s/%s: %w", sp.Name, fname, err)
				}
				// legend に無い色キー: 色票にあれば空いている字を当てる
				for _, k := range c.G.Keys() {
					if _, ok := lg.CharOf[k]; ok {
						continue
					}
					if _, ok := pal[string(k)]; !ok {
						return nil, fmt.Errorf("%s/%s: 色キー %q が legend にも色票にも無い", sp.Name, fname, string(k))
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
					return nil, fmt.Errorf("%s/%s: %w", sp.Name, fname, err)
				}
				old, had := frames.Get(fname)
				fr := frameResult{Sprite: sp.Name, Name: fname, Rows: rows, HadBase: had, Tile: c.tile, grid: c.G,
					Anim: len(sp.Frames) >= 2 && (sp.Anim == nil && sp.animated || sp.Anim != nil && *sp.Anim)}
				if had {
					fr.Same = pxlib.ToJSON(old, indent) == pxlib.ToJSON(rows, indent)
				}
				frames.Set(fname, rowsAny(rows))
				res.Frames = append(res.Frames, fr)
				seqNames, seqRows, seqGrids = append(seqNames, fname), append(seqRows, rows), append(seqGrids, c.G)
				if !opt.NoCheck {
					cc.Measures, cc.Wrap = c.measures, c.wrap
					for _, n := range append(frameChecks, techFrameChecks...) {
						vs, err := runCheck(n, c.G, cc)
						if err != nil {
							return nil, err
						}
						addViolations(vs, sp.Name, fname)
					}
				}
			}
			if animRules != nil && len(seqNames) >= 2 && (sp.Anim == nil && sp.animated || sp.Anim != nil && *sp.Anim) {
				for _, note := range animRules.CheckSequence(sp.Name, seqNames, seqRows) {
					addViolations([]violation{{Check: checkAnim, Level: levelLint, Msg: note, Fix: checks[checkAnim].Fix}}, sp.Name, "")
				}
				t := time.Now()
				for _, v := range sequenceChecks(seqNames, seqGrids, spriteLoops(sp, spec)) {
					addViolations([]violation{v}, sp.Name, v.Frame)
				}
				checkDur += time.Since(t)
			}
		}
	}
	if !opt.NoCheck {
		vs, err := runCheck(checkRef{Check: checkRampOrder}, pxlib.NewGrid(1, 1), cc)
		if err != nil {
			return nil, err
		}
		res.Violations = append(res.Violations, vs...)
	}
	res.Violations = dedupeViolations(res.Violations)
	res.Timing.Check = checkDur
	res.Timing.Draw = time.Since(t0) - checkDur
	tGate := time.Now()
	if gate != nil {
		bad, known := gate.CheckDoc(root, doc, filepath.Base(spec.Target))
		res.Known = known
		for _, b := range bad {
			res.Violations = append(res.Violations, gateViolation(b, res.Frames))
		}
	}
	res.Legend = map[string]string{}
	res.Hex = map[string]string{}
	for ch, k := range lg.KeyOf {
		res.Legend[ch] = string(k)
		if h, ok := hexOf[k]; ok {
			res.Hex[string(k)] = h
		}
	}
	if res.Count().Gate == 0 {
		out := filepath.Join(root, spec.Target)
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			return nil, err
		}
		if err := os.WriteFile(out, []byte(pxlib.ToJSON(doc, indent)), 0o644); err != nil {
			return nil, err
		}
		res.Wrote = true
	}
	res.Timing.Gate = time.Since(tGate)
	dir := opt.OutDir
	if dir == "" {
		dir = filepath.Join(root, "debug", "px", specName(specPath), "last")
	}
	prev := loadPrev(filepath.Join(dir, "report.json"))
	if prev != nil {
		c := prev.Count()
		res.Prev = &c
		res.prevKeys = map[string]bool{}
		for _, v := range prev.Violations {
			res.prevKeys[v.key()] = true
		}
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	if !opt.Sheet {
		// 前の --sheet の見本を消す（今の report.json と食い違う古い sheet.png を見せない）
		if old, err := filepath.Glob(filepath.Join(dir, "*.png")); err == nil {
			for _, p := range old {
				if err := os.Remove(p); err != nil {
					return nil, err
				}
			}
		}
	}
	if opt.Sheet {
		tSheet := time.Now()
		if err := writeSheets(dir, res, prev, hexOf, groundColor(cc.Ground)); err != nil {
			return nil, err
		}
		res.Sheet = filepath.Join(dir, "sheet.png")
		res.Timing.Sheet = time.Since(tSheet)
	}
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

// spriteLoops はスプライトのコマ列が輪になるか（sin で回る動きの op を使う。pose だけの列は輪と見ない）。
func spriteLoops(sp *spriteSpec, spec *specDoc) bool {
	for _, call := range sp.Post {
		if animOps[call.Name] {
			return true
		}
	}
	if len(sp.Frames) == 0 {
		return false
	}
	for _, p := range sp.partsOf(&reader{}, spec, sp.Frames[0]) {
		for _, call := range p.Ops {
			if animOps[call.Name] {
				return true
			}
		}
	}
	return false
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

func loadPrev(path string) *buildResult {
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
	pxOf := make([][][]color.RGBA, len(res.Frames))
	for i, f := range res.Frames {
		pxOf[i] = colorsOf(f.Rows, res.Legend, hexOf)
	}
	// コマ列の前後（同じスプライトの並びの中で輪にする）
	seq := map[string][]int{}
	for i, f := range res.Frames {
		seq[f.Sprite] = append(seq[f.Sprite], i)
	}
	tiles := map[string][][]color.RGBA{}
	for i, f := range res.Frames {
		px := pxOf[i]
		sf := pxlib.SheetFrame{Px: px}
		if rows, ok := prevRows[f.Sprite+"/"+f.Name]; ok {
			sf.Prev = colorsOf(rows, prev.Legend, hexOf)
		}
		if f.Anim {
			idx := seq[f.Sprite]
			at := 0
			for j, k := range idx {
				if k == i {
					at = j
				}
			}
			n := len(idx)
			sf.Onion = pxlib.Onion(px, pxOf[idx[(at+n-1)%n]], pxOf[idx[(at+1)%n]], ground)
		}
		if f.Tile {
			if _, ok := tiles[f.Sprite]; !ok {
				tiles[f.Sprite] = px
			}
		}
		sheet = append(sheet, sf)
		if _, ok := bySprite[f.Sprite]; !ok {
			order = append(order, f.Sprite)
		}
		bySprite[f.Sprite] = append(bySprite[f.Sprite], px)
	}
	// 前の周の PNG を消してから書く（tile_preview を外した後の .tile.png が rN に写らないように）
	if old, err := filepath.Glob(filepath.Join(dir, "*.png")); err == nil {
		for _, p := range old {
			if err := os.Remove(p); err != nil {
				return err
			}
		}
	}
	if err := pxlib.WritePNG(filepath.Join(dir, "sheet.png"), pxlib.Sheet(sheet, ground, 4)); err != nil {
		return err
	}
	sort.Strings(order)
	for name, px := range tiles {
		if err := pxlib.WritePNG(filepath.Join(dir, safeName(name)+".tile.png"), pxlib.Tile3x3(px, ground, 4)); err != nil {
			return err
		}
	}
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
