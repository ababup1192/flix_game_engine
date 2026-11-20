package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	_ "image/png"
	"os"
	"path"
	"path/filepath"
	"slices"
	"sort"
	"strings"
)

// webAutoLossyRules は写真寄りの png を既定で lossy にする判定の数（bin/lint-rules/export-web.json の autoLossy）。
type webAutoLossyRules struct {
	MinLosslessBytes       int64             `json:"minLosslessBytes"`
	MinOpaqueColors        int               `json:"minOpaqueColors"`
	Quality                int               `json:"quality"`
	TransparentOpaqueShare float64           `json:"transparentOpaqueShare"`
	DataNameParts          []string          `json:"dataNameParts"`
	FewColorsListed        int               `json:"fewColorsListed"`
	ColorCountCap          int               `json:"colorCountCap"`
	OpaqueAlphaMin         int               `json:"opaqueAlphaMin"`
	LosslessImages         webLosslessLimits `json:"losslessImages"`
}

// webLosslessLimits は 1 つの losslessImages の glob が png の broadGlobShare 以上に当たる時に知らせる境目。
type webLosslessLimits struct {
	BroadGlobShare     float64 `json:"broadGlobShare"`
	BroadGlobMinImages int     `json:"broadGlobMinImages"`
}

var webAutoLossyRulesPath = filepath.Join("bin", "lint-rules", "export-web.json")

// loadWebAutoLossyRules は engine の根の規約を読む。
// WhyNot: 読めない時に組み込みの数で続けない — 消しただけで判定が何も知らせずに変わり、配る絵の画質が人の知らない所で替わる。
func loadWebAutoLossyRules(engine string) (*webAutoLossyRules, error) {
	p := filepath.Join(engine, webAutoLossyRulesPath)
	data, err := os.ReadFile(p)
	if err != nil {
		return nil, fmt.Errorf("写真寄りの絵の判定の数を読めない: %v\n  次: engine の作業コピーに %s があるか確かめる", err, webAutoLossyRulesPath)
	}
	var file struct {
		AutoLossy *webAutoLossyRules `json:"autoLossy"`
	}
	if err := json.Unmarshal(data, &file); err != nil {
		return nil, fmt.Errorf("%s を読めない: %v", p, err)
	}
	r := file.AutoLossy
	if r == nil {
		return nil, fmt.Errorf("%s に autoLossy の欄が無い", p)
	}
	l := r.LosslessImages
	switch {
	case r.MinLosslessBytes <= 0, r.MinOpaqueColors <= 0, r.Quality < 1, r.Quality > 100,
		r.TransparentOpaqueShare <= 0, r.TransparentOpaqueShare > 1, r.FewColorsListed < 0,
		r.ColorCountCap <= r.MinOpaqueColors, r.OpaqueAlphaMin < 1, r.OpaqueAlphaMin > 255,
		l.BroadGlobShare <= 0, l.BroadGlobShare > 1, l.BroadGlobMinImages < 1:
		return nil, fmt.Errorf("%s の数が範囲の外（%+v）", p, *r)
	}
	return r, nil
}

// webImageKind は 1 枚の png が判定でどこへ落ちたか。
type webImageKind int

const (
	webImageLossless webImageKind = iota
	// webImageAutoLossy は何も書かれず、写真寄りなので lossy にした。
	webImageAutoLossy
	// webImageLosslessByRule は写真寄りだが losslessImages が lossless に留めた。
	webImageLosslessByRule
	// webImageDataTexture は写真寄りだが、シェーダーが値として読むか名前がデータの形なので lossless に留めた。
	webImageDataTexture
	// webImageExplicitSame は lossyImages が既定と同じ quality で lossy にし、既定の判定でも lossy になる。
	webImageExplicitSame
)

// webImageVerdict は 1 枚の png の判定と大きさ。Colors は ColorCountCap で打ち切った数。
type webImageVerdict struct {
	Rel           string
	Kind          webImageKind
	Colors        int
	OpaqueShare   float64
	LosslessBytes int64
	LossyBytes    int64
	// Note は lossy にしようとして諦めた理由（表の知らせへ出す）。
	Note string
	// explicitRules は当たった lossyImages の glob の番号（書いた順）。先頭の glob の quality で詰める。
	explicitRules []int
}

func (v webImageVerdict) isTransparent(r *webAutoLossyRules) bool {
	return v.OpaqueShare < r.TransparentOpaqueShare
}

// isWebDataImageName は名前が法線・高さ・マスク・LUT などデータとして読む絵の形か（部分一致）。
// WhyNot: 単語の境目で切らない — 当たり過ぎても lossless のままで崩れない向きに外れ、切ると water_normal2 のような名前を取りこぼす。
func isWebDataImageName(rel string, parts []string) bool {
	base := strings.ToLower(path.Base(rel))
	for _, p := range parts {
		if strings.Contains(base, strings.ToLower(p)) {
			return true
		}
	}
	return false
}

// countOpaqueColors は不透明な画素（α が alphaMin 以上）の色の数（limit を超えたら limit で打ち切る）と、不透明な画素の割合。
// WhyNot: 半透明の画素を数えない — ふちのアンチエイリアスの α が色ごとに別の値になり、ドット絵や字の色数が写真並みに膨らむ。
// WhyNot: α が最大の画素だけにしない — 生成した絵は見えている所の α が 250 前後の物があり、色を数える画素がほとんど残らない。
func countOpaqueColors(img image.Image, limit int, alphaMin uint8) (int, float64) {
	b := img.Bounds()
	total := b.Dx() * b.Dy()
	if total == 0 {
		return 0, 0
	}
	seen := map[uint32]struct{}{}
	opaque := 0
	add := func(key uint32) {
		opaque++
		if len(seen) <= limit {
			seen[key] = struct{}{}
		}
	}
	rgbaRows := func(pix []byte, stride int) {
		for y := 0; y < b.Dy(); y++ {
			row := pix[y*stride:]
			for x := 0; x < b.Dx(); x++ {
				p := row[4*x : 4*x+4]
				if p[3] >= alphaMin {
					add(uint32(p[0])<<16 | uint32(p[1])<<8 | uint32(p[2]))
				}
			}
		}
	}
	switch m := img.(type) {
	case *image.NRGBA:
		rgbaRows(m.Pix, m.Stride)
	case *image.RGBA:
		rgbaRows(m.Pix, m.Stride)
	case *image.Paletted:
		for y := 0; y < b.Dy(); y++ {
			for _, i := range m.Pix[y*m.Stride : y*m.Stride+b.Dx()] {
				c := color.NRGBAModel.Convert(m.Palette[i]).(color.NRGBA)
				if c.A >= alphaMin {
					add(uint32(i))
				}
			}
		}
	default:
		for y := b.Min.Y; y < b.Max.Y; y++ {
			for x := b.Min.X; x < b.Max.X; x++ {
				c := color.NRGBA64Model.Convert(img.At(x, y)).(color.NRGBA64)
				if uint8(c.A>>8) >= alphaMin {
					add(uint32(c.R>>8)<<16 | uint32(c.G>>8)<<8 | uint32(c.B>>8))
				}
			}
		}
	}
	return min(len(seen), limit), float64(opaque) / float64(total)
}

// countImageColors は絵のファイル（png・jpg）を解いて countOpaqueColors を返す。
func countImageColors(p string, r *webAutoLossyRules) (int, float64, error) {
	f, err := os.Open(p)
	if err != nil {
		return 0, 0, err
	}
	defer f.Close()
	img, _, err := image.Decode(f)
	if err != nil {
		return 0, 0, err
	}
	colors, share := countOpaqueColors(img, r.ColorCountCap, uint8(r.OpaqueAlphaMin))
	return colors, share, nil
}

// isPhotoLike は lossless の大きさと色数が写真寄りの境目を超えるか（色数も v に書く）。
func isPhotoLike(src string, r *webAutoLossyRules, v *webImageVerdict) bool {
	if v.LosslessBytes < r.MinLosslessBytes {
		return false
	}
	colors, share, err := countImageColors(src, r)
	if err != nil {
		return false
	}
	v.Colors, v.OpaqueShare = colors, share
	return colors > r.MinOpaqueColors
}

// encodeWebImageAuto は src を lossless の WebP にし、写真寄りなら lossy も作って小さい方を dst に残す。v に判定を書く。
// byRule は losslessImages に当たった絵、dataTexture はデータとして読む絵（どちらも lossy にしないが、写真寄りかは数えて表に出す）。
func encodeWebImageAuto(cwebp, src, dst string, r *webAutoLossyRules, byRule, dataTexture bool, v *webImageVerdict) error {
	if err := runQuiet(cwebp, cwebpArgs(src, dst, 0)...); err != nil {
		return err
	}
	v.LosslessBytes = fileSize(dst)
	if !isPhotoLike(src, r, v) {
		return nil
	}
	switch {
	case byRule:
		v.Kind = webImageLosslessByRule
		return nil
	case dataTexture:
		v.Kind = webImageDataTexture
		return nil
	}
	tmp := dst + ".lossy"
	defer os.Remove(tmp)
	if err := runQuiet(cwebp, cwebpArgs(src, tmp, r.Quality)...); err != nil {
		// WhyNot: 書き出しを止めない — lossless の WebP はもう作れていて、配る物はある。
		v.Note = fmt.Sprintf("%s は lossy にできなかった — lossless で配る（%v）", v.Rel, err)
		return nil
	}
	lossy := fileSize(tmp)
	if lossy <= 0 || lossy >= v.LosslessBytes {
		return nil
	}
	if err := os.Rename(tmp, dst); err != nil {
		return err
	}
	v.Kind, v.LossyBytes = webImageAutoLossy, lossy
	return nil
}

// encodeWebImageExplicit は lossyImages の quality で詰め、quality が既定と同じ png なら既定の判定でも lossy になるかを v に書く。
// WhyNot: いつも lossless も作らない — lossy が閾値以上なら lossless はそれより大きいので作らずに言え、cwebp の回数が増えるのは閾値の下の絵だけで済む。
func encodeWebImageExplicit(cwebp, src, dst string, quality int, r *webAutoLossyRules, dataTexture bool, v *webImageVerdict) error {
	if err := runQuiet(cwebp, cwebpArgs(src, dst, quality)...); err != nil {
		return err
	}
	v.LossyBytes = fileSize(dst)
	if r == nil || quality != r.Quality || dataTexture || strings.ToLower(path.Ext(src)) != ".png" {
		return nil
	}
	v.LosslessBytes = v.LossyBytes
	if v.LossyBytes < r.MinLosslessBytes {
		tmp := dst + ".lossless"
		defer os.Remove(tmp)
		if runQuiet(cwebp, cwebpArgs(src, tmp, 0)...) != nil {
			return nil
		}
		v.LosslessBytes = fileSize(tmp)
	}
	if isPhotoLike(src, r, v) {
		v.Kind = webImageExplicitSame
	}
	return nil
}

type webLosslessGlob struct {
	webGlob
	Why string
}

// checkWebLosslessGlobs は losslessImages の glob が lossless にできる png に当たるかを見る。当たらない glob・当たる png が全部 lossyImages に取られる glob は誤り。
// png の broadGlobShare 以上に当たる glob（png が broadGlobMinImages 枚以上の時）は知らせの行を返す。
func checkWebLosslessGlobs(images []string, c webCompress) ([]string, error) {
	if len(c.LosslessImages) == 0 {
		return nil, nil
	}
	var pngs []string
	for _, rel := range images {
		if strings.ToLower(path.Ext(rel)) == ".png" {
			pngs = append(pngs, rel)
		}
	}
	explicit := func(rel string) bool {
		for _, g := range c.LossyImages {
			if g.match(rel) {
				return true
			}
		}
		return false
	}
	var notes []string
	for _, g := range c.LosslessImages {
		hit, effective := 0, 0
		for _, rel := range pngs {
			if g.match(rel) {
				hit++
				if !explicit(rel) {
					effective++
				}
			}
		}
		switch {
		case hit == 0:
			return nil, fmt.Errorf("project.json の web.compress.losslessImages の glob %q に当たる png が無い。\n  次: textures の道を確かめるか、要らなければ行を消す", g.Pattern)
		case effective == 0:
			return nil, fmt.Errorf("project.json の web.compress.losslessImages の glob %q に当たる png は全部 lossyImages にも当たり、lossy になる（lossyImages が先）。\n  次: lossless にしたいなら lossyImages の glob から外す・要らなければ行を消す", g.Pattern)
		}
		if r := c.Auto; r != nil && len(pngs) >= r.LosslessImages.BroadGlobMinImages && float64(hit) >= r.LosslessImages.BroadGlobShare*float64(len(pngs)) {
			notes = append(notes, fmt.Sprintf("web.compress.losslessImages の glob %q が png %d 枚のうち %d 枚に当たる — 写真寄りの絵の既定の lossy をほぼ全部外している。崩したくない絵だけに絞る", g.Pattern, len(pngs), hit))
		}
	}
	return notes, nil
}

// loadWebShaderTextures はゲームの assets/ の下の JSON（ShaderDoc）が tex・blur・texSize で値として読むテクスチャの道。
// WhyNot: .flix のコードで組んだ ShaderDoc は見ない — 式を解かないと名前が決まらない。見えない物は名前の形か losslessImages で外す。
func loadWebShaderTextures(game string, pr exportProject) map[string]bool {
	names := map[string]bool{}
	files, err := walkFiles(filepath.Join(game, "assets"), nil)
	if err != nil {
		return nil
	}
	for _, rel := range files {
		if !strings.HasSuffix(rel, ".json") || strings.HasSuffix(rel, ".schema.json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(game, "assets", filepath.FromSlash(rel)))
		if err != nil || !bytes.Contains(data, []byte(`"kind"`)) {
			continue
		}
		var doc any
		if json.Unmarshal(data, &doc) != nil {
			continue
		}
		collectShaderTexNames(doc, names)
	}
	out := map[string]bool{}
	for _, t := range pr.Textures {
		if names[t.Name] {
			out[path.Clean(strings.ReplaceAll(t.Path, "\\", "/"))] = true
		}
	}
	return out
}

var shaderTexKinds = map[string]bool{"tex": true, "blur": true, "texSize": true}

func collectShaderTexNames(v any, names map[string]bool) {
	switch x := v.(type) {
	case map[string]any:
		if k, _ := x["kind"].(string); shaderTexKinds[k] {
			if n, ok := x["name"].(string); ok && n != "" {
				names[n] = true
			}
		}
		for _, c := range x {
			collectShaderTexNames(c, names)
		}
	case []any:
		for _, c := range x {
			collectShaderTexNames(c, names)
		}
	}
}

// loadPreviousLosslessImages は前の書き出し（out の bundle.json）で lossless で配っていた png の論理の道（WebP が VP8L の物と、png のまま配った物）。
// 前の書き出しが無ければ空（移行の ★ を出さない）。
// WhyNot: 前の版の engine の版の番号を読まない — 書き出し先には版が残らず、残っている画素の形が「lossless だった」の唯一の証になる。
func loadPreviousLosslessImages(out string) map[string]bool {
	data, err := os.ReadFile(filepath.Join(out, "bundle.json"))
	if err != nil {
		return nil
	}
	var b struct {
		Images     []string          `json:"images"`
		Transcoded map[string]string `json:"transcoded"`
	}
	if json.Unmarshal(data, &b) != nil {
		return nil
	}
	prev := map[string]bool{}
	for _, rel := range b.Images {
		if strings.ToLower(path.Ext(rel)) != ".png" {
			continue
		}
		served, ok := b.Transcoded[rel]
		if !ok || isWebpLossless(filepath.Join(out, "assets", filepath.FromSlash(served))) {
			prev[rel] = true
		}
	}
	return prev
}

// isWebpLossless は WebP の画素の区画が VP8L（劣化なし）か。読めない・WebP でない時は false。
func isWebpLossless(p string) bool {
	f, err := os.Open(p)
	if err != nil {
		return false
	}
	defer f.Close()
	head := make([]byte, 12)
	if _, err := f.Read(head); err != nil || string(head[:4]) != "RIFF" || string(head[8:12]) != "WEBP" {
		return false
	}
	chunk := make([]byte, 8)
	for {
		if _, err := f.Read(chunk); err != nil {
			return false
		}
		switch string(chunk[:4]) {
		case "VP8L":
			return true
		case "VP8 ":
			return false
		}
		size := int64(binary.LittleEndian.Uint32(chunk[4:]))
		if _, err := f.Seek(size+size%2, 1); err != nil {
			return false
		}
	}
}

// isRemovableLossyRule は lossyImages の i 番の glob を消しても配る絵が変わらないか（前の glob に全部取られている・既定の判定と同じ結果）。
func isRemovableLossyRule(i int, g webLossyGlob, vs []webImageVerdict, r *webAutoLossyRules) bool {
	hit := 0
	for _, v := range vs {
		if !slices.Contains(v.explicitRules, i) {
			continue
		}
		hit++
		if v.explicitRules[0] != i {
			continue
		}
		if g.Quality != r.Quality || v.Kind != webImageExplicitSame {
			return false
		}
	}
	return hit > 0
}

// buildWebAutoLossySummary は表に出す行（既定で lossy にした絵・外した絵・消せる lossyImages・移行の ★）。
func buildWebAutoLossySummary(vs []webImageVerdict, r *webAutoLossyRules, lossy []webLossyGlob, prev map[string]bool) []string {
	if r == nil {
		return nil
	}
	var auto, byRule, data []webImageVerdict
	for _, v := range vs {
		switch v.Kind {
		case webImageAutoLossy:
			auto = append(auto, v)
		case webImageLosslessByRule:
			byRule = append(byRule, v)
		case webImageDataTexture:
			data = append(data, v)
		}
	}
	var lines []string
	if len(auto) > 0 {
		var before, after int64
		transparent := 0
		for _, v := range auto {
			before += v.LosslessBytes
			after += v.LossyBytes
			if v.isTransparent(r) {
				transparent++
			}
		}
		line := fmt.Sprintf("絵: 既定で lossy にした %d 枚（%s → %s）", len(auto), humanBytes(before), humanBytes(after))
		if transparent > 0 {
			line += fmt.Sprintf("・うち透明の多い絵 %d 枚", transparent)
		}
		lines = append(lines, line)
		few := sortedByColors(auto)
		if n := min(r.FewColorsListed, len(few)); n > 0 {
			var names []string
			for _, v := range few[:n] {
				names = append(names, fmt.Sprintf("%s（%s 色）", v.Rel, groupDigits(v.Colors)))
			}
			lines = append(lines, fmt.Sprintf("    色数の少なかった %d 枚: %s", n, strings.Join(names, "・")))
		}
		lines = append(lines, `    崩したくない物は "losslessImages": [{ "glob": "...", "why": "..." }]・見比べは bin/fge web-image-diff`)
	}
	if len(byRule) > 0 {
		var size int64
		for _, v := range byRule {
			size += v.LosslessBytes
		}
		lines = append(lines, fmt.Sprintf("絵: losslessImages で lossless に留めた写真寄りの絵 %d 枚・%s（4G で約 %.1f 秒）", len(byRule), humanBytes(size), webSecondsFor(size)))
	}
	if len(data) > 0 {
		var names []string
		for _, v := range data {
			names = append(names, v.Rel)
		}
		lines = append(lines, fmt.Sprintf("絵: シェーダーが値として読む・名前がデータの形の写真寄りの絵 %d 枚は lossless のまま（%s）", len(data), strings.Join(names, "・")))
	}
	for i, g := range lossy {
		if isRemovableLossyRule(i, g, vs, r) {
			lines = append(lines, fmt.Sprintf("知らせ: web.compress.lossyImages の glob %q は消しても配る絵が変わらない（前の glob が先に当たるか、既定の判定と同じ q%d）", g.Pattern, r.Quality))
		}
	}
	for _, v := range vs {
		if v.Note != "" {
			lines = append(lines, "知らせ: "+v.Note)
		}
	}
	changed := 0
	for _, v := range auto {
		if prev[v.Rel] {
			changed++
		}
	}
	if changed > 0 {
		lines = append(lines, fmt.Sprintf("★ 前の書き出しでは lossless だった絵 %d 枚を既定で lossy にした（写真寄りの png は既定で lossy）。崩したくない物は web.compress.losslessImages へ（engine の docs/web-export.md の「写真寄りの絵は既定で lossy」）", changed))
	}
	return lines
}

func sortedByColors(vs []webImageVerdict) []webImageVerdict {
	out := append([]webImageVerdict{}, vs...)
	sort.SliceStable(out, func(i, j int) bool { return out[i].Colors < out[j].Colors })
	return out
}

// logWebAutoLossy は既定で lossy にした絵を 1 枚ずつ書き出しのログへ出す（色数の少ない順）。
// WhyNot: 表に全部を並べない — 100 枚を超えるゲームでは表が流れ、毎回目に入れたい色数の少ない数枚が埋もれる。
func logWebAutoLossy(vs []webImageVerdict) {
	var auto []webImageVerdict
	for _, v := range vs {
		if v.Kind == webImageAutoLossy {
			auto = append(auto, v)
		}
	}
	for _, v := range sortedByColors(auto) {
		ewLogf("  既定で lossy %7s 色・不透明 %3.0f%%・%s → %s  %s", groupDigits(v.Colors), 100*v.OpaqueShare,
			humanBytes(v.LosslessBytes), humanBytes(v.LossyBytes), v.Rel)
	}
}

func groupDigits(n int) string {
	s := fmt.Sprint(n)
	var b strings.Builder
	for i, c := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(c)
	}
	return b.String()
}
