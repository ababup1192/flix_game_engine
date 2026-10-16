// Package pxkit はドット絵を「形の指定（spritesrc Doc）」から打ち起こして sprite.json に書く。
//
//	fge pxkit build <spec>   1 回描いて、書き出し・見本シート・検査まで
//	fge pxkit watch <spec>   spec を保存するたびに build（常駐しない。止めるまで見張るだけ）
//	fge pxkit snap  <spec>   今の見本を debug/history/<名前>/rN.png に積み、前の周と並べた比べ絵を作る
//
// 書き出し先は spec の "target"（atelier/ を指す。AI が作る素材は assets/ へ直接書かない）。
// "base" の sprite.json を読んで、spec にあるコマの rows だけを差し替える（ほかのスプライトは残す）。
package pxkit

import (
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flix_game_engine/go/internal/sprite"
)

// Frame は描き上がった 1 コマ。
type Frame struct {
	Sprite, Name string
	Rows         []string
	Same         bool // base の同じコマとバイトで同じか
	HadBase      bool
}

// Result は build 1 回の結果。
type Result struct {
	Target, Sheet string
	Frames        []Frame
	Elapsed       time.Duration
	Lint          LintDiff
}

// LintDiff は bin/fge sprite の注意を、描く前（base）と描いた後で比べた物。
// 増えた物だけを見せると、直したつもりで消えたかが分からないので 3 つに分ける。
type LintDiff struct {
	Added, Removed, Kept []string
	Ramp                 []string // ランプの並び（暗 → 明）の崩れ
}

// specKeys は spec の一番外に書ける鍵。知らない鍵は書き損じとして止める（黙って無視しない）。
var specKeys = map[string]bool{"version": true, "note": true, "target": true, "base": true,
	"gloss": true, "ramps": true, "shapes": true, "shared": true, "sprites": true, "preview": true,
	"legend": true, "palette": true}

// Build は spec を読んで描き、target に書き、見本シートを作る。
func Build(root, specPath string, lint bool) (res *Result, err error) {
	// 書き損じた spec で落ちない（watch ごと止まらない）。どこで何が起きたかを返す。
	defer func() {
		if r := recover(); r != nil {
			res, err = nil, fmt.Errorf("%s: 描いている途中で止まった（spec の形を確かめる）: %v", specPath, r)
		}
	}()
	t0 := time.Now()
	data, err := os.ReadFile(specPath)
	if err != nil {
		return nil, err
	}
	specAny, err := decodeOrdered(data)
	if err != nil {
		return nil, fmt.Errorf("%s: JSON として読めない: %w", specPath, err)
	}
	spec, ok := specAny.(*Obj)
	if !ok {
		return nil, fmt.Errorf("%s: 一番外はオブジェクト", specPath)
	}
	for _, k := range spec.Keys {
		if !specKeys[k] {
			return nil, fmt.Errorf("%s: 知らない鍵 %q（書ける鍵: target base gloss ramps shapes shared sprites preview note version）", specPath, k)
		}
	}
	str := func(k string) string { s, _ := spec.Get(k).(string); return s }
	target, base := str("target"), str("base")
	if target == "" {
		return nil, fmt.Errorf("%s: target（書き出す sprite.json。atelier/ の下）が無い", specPath)
	}
	if isUnderAssets(target) {
		return nil, fmt.Errorf("%s: target が assets/ を指している — 候補は atelier/ に書く（採用は swap）", specPath)
	}
	if base == "" {
		base = target
	}
	baseData, err := os.ReadFile(filepath.Join(root, base))
	if err != nil {
		// base がまだ無い新しい絵: spec の legend と palette から sprite.json を起こす
		lg, okL := spec.Get("legend").(*Obj)
		pl, okP := spec.Get("palette").(*Obj)
		if !okL || !okP {
			return nil, fmt.Errorf("base %s が読めない（新しく作るなら spec に legend と palette を書く）: %w", base, err)
		}
		fresh := newObj()
		fresh.Set("version", json.Number("1"))
		fresh.Set("note", "fge pxkit が "+filepath.Base(specPath)+" から描いた絵。直すのは spec")
		fresh.Set("legend", lg)
		fresh.Set("palette", pl)
		fresh.Set("sprites", newObj())
		baseData = []byte(dumpPy(fresh))
	}
	docAny, err := decodeOrdered(baseData)
	if err != nil {
		return nil, err
	}
	doc := docAny.(*Obj)
	legend, _ := doc.Get("legend").(*Obj)
	charOf := map[string]string{}
	keyOf := map[string]string{}
	for _, ch := range legend.Keys {
		if key, ok := legend.Vals[ch].(string); ok {
			keyOf[ch] = key
			if _, dup := charOf[key]; !dup {
				charOf[key] = ch
			}
		}
	}
	plainSpec := plain(spec).(map[string]any)
	ramps, _ := plainSpec["ramps"].(map[string]any)
	shapes, _ := plainSpec["shapes"].(map[string]any)
	layers, _ := plainSpec["shared"].(map[string]any)
	gloss, _ := plainSpec["gloss"].(string)

	sprites, _ := doc.Get("sprites").(*Obj)
	specSprites, ok := spec.Get("sprites").(*Obj)
	if !ok || sprites == nil || legend == nil {
		return nil, fmt.Errorf("%s: sprites は名前 → 指定のオブジェクトで書く（base にも legend と sprites が要る）", specPath)
	}
	var before map[string]bool
	names := map[string]bool{}
	for _, n := range specSprites.Keys {
		names[n] = true
	}
	if lint {
		before = lintLines(root, base, names) // 書く前に測る（target と base が同じファイルでも比べられる）
	}
	res = &Result{Target: target}
	for _, name := range specSprites.Keys {
		ss, ok := plain(specSprites.Vals[name]).(map[string]any)
		if !ok {
			return nil, fmt.Errorf("%s: スプライトの指定はオブジェクトで書く", name)
		}
		size := nums(ss["size"])
		if len(size) != 2 {
			return nil, fmt.Errorf("%s: size [w, h] が無い", name)
		}
		rampName, _ := ss["ramp"].(string)
		ramp := strs(ramps[rampName])
		framesSpec, ok := specSprites.Vals[name].(*Obj).Get("frames").(*Obj)
		if !ok {
			return nil, fmt.Errorf("%s: frames（コマ名 → op の列）が無い", name)
		}
		entry, _ := sprites.Get(name).(*Obj)
		if entry == nil {
			entry = newObj()
			if n, ok := ss["note"].(string); ok {
				entry.Set("note", n)
			}
			anchor := newObj()
			anchor.Set("x", 0.0)
			anchor.Set("y", 0.0)
			entry.Set("anchor", anchor)
			entry.Set("frames", newObj())
			sprites.Set(name, entry)
		}
		frames, _ := entry.Get("frames").(*Obj)
		for _, fname := range framesSpec.Keys {
			ops, _ := plain(framesSpec.Vals[fname]).([]any)
			c := &ctx{g: NewGrid(int(size[0]), int(size[1])), ramp: ramp, gloss: gloss,
				masks: map[string]Mask{}, shapes: shapes, layers: layers, ramps: ramps, keyOf: keyOf}
			if err := c.run(ops); err != nil {
				return nil, fmt.Errorf("%s/%s: %w", name, fname, err)
			}
			rows, err := c.g.Rows(charOf)
			if err != nil {
				return nil, fmt.Errorf("%s/%s: %w（base の legend に足す）", name, fname, err)
			}
			old, had := frames.Vals[fname]
			fr := Frame{Sprite: name, Name: fname, Rows: rows, HadBase: had}
			if had {
				fr.Same = dumpPy(old) == dumpPy(rows)
			}
			frames.Set(fname, rows)
			res.Frames = append(res.Frames, fr)
		}
	}
	out := filepath.Join(root, target)
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		return nil, err
	}
	if err := os.WriteFile(out, []byte(dumpPy(doc)), 0o644); err != nil {
		return nil, err
	}
	sheet, err := writeSheet(root, specPath, doc, plainSpec, res.Frames)
	if err != nil {
		return nil, err
	}
	res.Sheet = sheet
	if lint {
		res.Lint = diffLint(before, lintLines(root, target, names))
		res.Lint.Ramp = rampOrder(paletteOf(root, doc), ramps)
	}
	res.Elapsed = time.Since(t0)
	return res, nil
}

func strs(v any) []string {
	arr, _ := v.([]any)
	out := make([]string, 0, len(arr))
	for _, e := range arr {
		s, _ := e.(string)
		out = append(out, s)
	}
	return out
}

// specName は spec のファイル名から種類の拡張子を外した物（見本・履歴の置き場の名前）。
func specName(specPath string) string {
	b := filepath.Base(specPath)
	return strings.TrimSuffix(b, ".spritesrc.json")
}

// paletteOf は Doc の paletteFile（無ければ直下の palette）から 色キー → 実色。
func paletteOf(root string, doc *Obj) map[string]pxlib.RGBA {
	if pf, ok := doc.Get("paletteFile").(string); ok {
		if v := pxlib.ReadJSON(filepath.Join(root, pf)); v != nil {
			return pxlib.ColorMapOf(v)
		}
	}
	return pxlib.ColorMapOf(plain(doc.Get("palette")))
}

// writeSheet は描いたコマを 実寸 と 4 倍 で並べた見本を debug/pxkit/<名前>/sheet.png に書く。
// 地は spec の preview.background（色キーか #rrggbb）。その絵が実際に置かれる面の色にする
// （昼の駒は紙の上、夜のアイコンは基板の上で見ないと、輪郭が地に溶けるかを判断できない）。
func writeSheet(root, specPath string, doc *Obj, spec map[string]any, frames []Frame) (string, error) {
	pal := paletteOf(root, doc)
	legend, _ := doc.Get("legend").(*Obj)
	const zoom, gap = 4, 6
	// 1 マス = 実寸 + 4 倍。マスは横に cols 個ずつ並べる（縦に長い 1 列にすると見比べられない）。
	cw, ch := 0, 0
	for _, f := range frames {
		fw, fh := len([]rune(f.Rows[0])), len(f.Rows)
		cw = max(cw, fw+gap+fw*zoom)
		ch = max(ch, fh*zoom)
	}
	cols := max(1, min(len(frames), 1600/(cw+gap)))
	rowsN := (len(frames) + cols - 1) / cols
	w, h := gap+cols*(cw+gap), gap+rowsN*(ch+gap)
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	bg := backgroundOf(pal, spec)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, bg)
		}
	}
	for i, f := range frames {
		ox, oy := gap+(i%cols)*(cw+gap), gap+(i/cols)*(ch+gap)
		fw := len([]rune(f.Rows[0]))
		for y, row := range f.Rows {
			for x, r := range []rune(row) {
				if r == '.' {
					continue
				}
				key, _ := legend.Get(string(r)).(string)
				c, ok := pal[key]
				if !ok {
					c = pxlib.RGBA{0xff, 0x00, 0xff, 0xff} // 色票に無い = 仮色（Studio と同じ症状）
				}
				rgba := color.RGBA{c[0], c[1], c[2], 0xff}
				img.Set(ox+x, oy+y, rgba)
				for dy := 0; dy < zoom; dy++ {
					for dx := 0; dx < zoom; dx++ {
						img.Set(ox+fw+gap+x*zoom+dx, oy+y*zoom+dy, rgba)
					}
				}
			}
		}
	}
	dir := filepath.Join(root, "debug", "pxkit", specName(specPath))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(dir, "sheet.png")
	fh, err := os.Create(path)
	if err != nil {
		return "", err
	}
	defer fh.Close()
	return path, png.Encode(fh, img)
}

func diffLint(before, after map[string]bool) LintDiff {
	var d LintDiff
	for l := range after {
		if before[l] {
			d.Kept = append(d.Kept, l)
		} else {
			d.Added = append(d.Added, l)
		}
	}
	for l := range before {
		if !after[l] {
			d.Removed = append(d.Removed, l)
		}
	}
	sort.Strings(d.Added)
	sort.Strings(d.Removed)
	sort.Strings(d.Kept)
	return d
}

// isUnderAssets は path が（./ や ../ で回り道しても）ゲームの assets/ の下を指すか。
func isUnderAssets(path string) bool {
	clean := filepath.ToSlash(filepath.Clean(path))
	return clean == "assets" || strings.HasPrefix(clean, "assets/") || strings.Contains(clean, "/assets/") || strings.HasPrefix(clean, "../")
}

// backgroundOf は見本の地の色。
func backgroundOf(pal map[string]pxlib.RGBA, spec map[string]any) color.RGBA {
	p, _ := spec["preview"].(map[string]any)
	v, _ := p["background"].(string)
	if c, ok := pal[v]; ok {
		return color.RGBA{c[0], c[1], c[2], 0xff}
	}
	if pxlib.IsHexColor(v) {
		if c, ok := pxlib.RGBAOfValue(v); ok {
			return color.RGBA{c[0], c[1], c[2], 0xff}
		}
	}
	return color.RGBA{0x2a, 0x2a, 0x33, 0xff} // 指定が無ければ中くらいの暗い灰
}

// lintLines は 1 冊の検査の行から、描いたスプライトの行だけを「スプライト: 中身」の形で集める。
func lintLines(root, doc string, names map[string]bool) map[string]bool {
	var out, errOut strings.Builder
	path := filepath.Join(root, doc)
	_, _ = sprite.Run(&out, &errOut, root, []string{path})
	got := map[string]bool{}
	for _, line := range strings.Split(out.String()+errOut.String(), "\n") {
		i := strings.Index(line, path+": ")
		if i < 0 {
			continue
		}
		body := line[i+len(path)+2:]
		name := body
		if j := strings.IndexAny(body, "/:"); j >= 0 {
			name = body[:j]
		}
		if names[name] {
			got[body] = true
		}
	}
	return got
}

// rampOrder は ramps が暗 → 明の順に並んでいるかを色票の明るさで確かめる
// （輪郭・影 = ramp[0] という作法は、この並びが崩れると黙って破れる）。
func rampOrder(pal map[string]pxlib.RGBA, ramps map[string]any) []string {
	var out []string
	for _, name := range keysOf(ramps) {
		prev, prevKey := -1.0, ""
		for _, key := range strs(ramps[name]) {
			c, ok := pal[key]
			if !ok {
				out = append(out, fmt.Sprintf("ramp %s: %s が色票に無い（Studio は仮色で塗る）", name, key))
				continue
			}
			l := 0.2126*float64(c[0]) + 0.7152*float64(c[1]) + 0.0722*float64(c[2])
			if l < prev {
				out = append(out, fmt.Sprintf("ramp %s: %s が %s より暗い（暗 → 明の順に並べる）", name, key, prevKey))
			}
			prev, prevKey = l, key
		}
	}
	return out
}
