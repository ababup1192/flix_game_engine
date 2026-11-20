package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"path"
	"sort"
	"strings"
)

// webTitleFrames は書き出しの確かめで、タイトルの間として素材の使い方を記録するコマ数（60 コマで 1 秒）。
// WhyNot: 数コマで切らない — タイトルの BGM や背景の絵を、最初の数コマの後（フェードの後）に出すゲームがある。
// WhyNot: もっと長くしない — 確かめは入力を送らないので、タイトルの後の場面へは進まない。長くしても候補は減らず、書き出しが延びるだけ。
const webTitleFrames = 120

// webUsedAssets は頁の window.fgeUsedAssets（engine_web の fge-web.js が ?usedAssets=1 で記録する物）。
// 種類ごとに 名前か道 → 初めて使ったコマ（0 は最初のコマの前の読み込み）。Texture は描いた絵の名前（フォントの字は font_<名前>）・
// Sound は鳴らした音の名前・File は読んだ素材の道・Early は後回しの絵か音を届く前に描こうとした・鳴らそうとした名前。
type webUsedAssets struct {
	Frame   int            `json:"frame"`
	Texture map[string]int `json:"texture"`
	Sound   map[string]int `json:"sound"`
	File    map[string]int `json:"file"`
	Early   map[string]int `json:"early"`
}

// webDeferredKind は後回しの候補の種類。
type webDeferredKind int

const (
	webDeferredImage webDeferredKind = iota
	webDeferredSound
	webDeferredFont
	webDeferredFile
)

func (k webDeferredKind) label() string {
	switch k {
	case webDeferredImage:
		return "絵"
	case webDeferredSound:
		return "音"
	case webDeferredFont:
		return "フォント"
	default:
		return "ファイル"
	}
}

// webDeferredCandidate は後回しの候補 1 本。Wire は回線に乗る量・Font はフォントの時の名前。
type webDeferredCandidate struct {
	Path  string
	Kind  webDeferredKind
	Wire  int64
	Names []string
	Font  string
}

// webDeferredSuggestion は後回しの候補と、貼った時の起動の見積もり。
type webDeferredSuggestion struct {
	Frames     int
	Candidates []webDeferredCandidate // 絵・音・フォント（大きい順）
	Files      []webDeferredCandidate // 読まなかったファイル（大きい順・貼る形と --apply-deferred には入れない）
	Globs      []string               // web.deferred に足す物（大きい物を含む glob から）
	Fonts      []string               // web.deferredFonts に足す物
	Arrivals   []webArrival           // 足した物が届く時刻（今の後回しの列の後ろに足した時）
	Before     float64                // 今の起動の秒
	After      float64                // 足した後の起動の秒
	UsedLate   []string               // 後回しの物のうち、タイトルの間に届く前に描こうとした・鳴らそうとした物
	KeptFont   string                 // 全部のフォントを後回しにしないよう候補から外したフォント
}

// webTextDocExts は読まなかったファイルの一覧にも出さない拡張子（Doc・台本）。小さく、起動を軽くする効果が薄い。
var webTextDocExts = map[string]bool{
	".json": true, ".yarn": true, ".txt": true, ".md": true, ".csv": true, ".tsv": true, ".ink": true, ".xml": true,
}

// suggestWebDeferred は書き出し先 out の束と、タイトルの frames コマの間に使った素材の記録から、後回しの候補を出す。
// hidden は web.embed・web.omit に当たる道（候補にも glob の当たりにも入れない）。
func suggestWebDeferred(out string, b *webBundle, pr exportProject, deferredFonts []string, hidden map[string]bool,
	used webUsedAssets, frames int) webDeferredSuggestion {
	s := webDeferredSuggestion{Frames: frames}
	texNames := textureNamesByPath(pr)
	soundNames := map[string][]string{}
	for _, snd := range b.Sounds {
		soundNames[snd.Path] = append(soundNames[snd.Path], snd.Name)
	}
	isImage := map[string]bool{}
	for _, rel := range b.Images {
		isImage[rel] = true
	}
	fontOfAtlas := map[string]string{}
	for _, name := range pr.fontNames() {
		fontOfAtlas[webFontAtlasRel(name)] = name
	}
	within := func(m map[string]int, key string) bool {
		f, ok := m[key]
		return ok && f <= frames
	}
	usedInTitle := func(rel string) bool {
		if font, ok := fontOfAtlas[rel]; ok {
			return within(used.Texture, "font_"+font)
		}
		if within(used.File, rel) {
			return true
		}
		for _, n := range texNames[rel] {
			if within(used.Texture, n) {
				return true
			}
		}
		for _, n := range soundNames[rel] {
			if within(used.Sound, n) {
				return true
			}
		}
		return false
	}
	kindOf := func(rel string) webDeferredKind {
		switch {
		case fontOfAtlas[rel] != "":
			return webDeferredFont
		case len(soundNames[rel]) > 0:
			return webDeferredSound
		case isImage[rel]:
			return webDeferredImage
		default:
			return webDeferredFile
		}
	}

	deferred := map[string]bool{}
	for _, e := range b.Deferred {
		deferred[e.Path] = true
		for _, n := range e.Names {
			if within(used.Early, n) {
				s.UsedLate = append(s.UsedLate, e.Path)
				break
			}
		}
	}

	for _, rel := range b.copyList() {
		if deferred[rel] || hidden[rel] || rel == "project.json" || usedInTitle(rel) {
			continue
		}
		kind := kindOf(rel)
		c := webDeferredCandidate{Path: rel, Kind: kind, Wire: webWireSize(exportAssetPath(out, b.served(rel)))}
		// WhyNot: 読まなかったファイルを貼る形に入れない — ファイルの読み込み（Fs.FileRead）は後回しの物を待たず、届く前に読むと Err になる。
		// 絵・音と違い「届くまで黒い」で済まないので、届いたかを見てから読む（BackgroundLoad）物だけを担当が選んで足す。
		if kind == webDeferredFile {
			if !webTextDocExts[strings.ToLower(path.Ext(rel))] {
				s.Files = append(s.Files, c)
			}
			continue
		}
		switch kind {
		case webDeferredFont:
			c.Font = fontOfAtlas[rel]
			c.Names = []string{c.Font}
		case webDeferredSound:
			c.Names = soundNames[rel]
		default:
			c.Names = texNames[rel]
		}
		s.Candidates = append(s.Candidates, c)
	}
	s.keepOneFont(pr.fontNames(), deferredFonts)
	sort.SliceStable(s.Candidates, func(i, j int) bool { return s.Candidates[i].Wire > s.Candidates[j].Wire })
	sort.SliceStable(s.Files, func(i, j int) bool { return s.Files[i].Wire > s.Files[j].Wire })

	var plain []string
	for _, c := range s.Candidates {
		if c.Kind == webDeferredFont {
			s.Fonts = append(s.Fonts, c.Font)
		} else {
			plain = append(plain, c.Path)
		}
	}
	allowed := map[string]bool{}
	for rel := range deferred {
		allowed[rel] = true
	}
	for _, rel := range plain {
		allowed[rel] = true
	}
	var all []string
	for _, rel := range b.copyList() {
		if !hidden[rel] {
			all = append(all, rel)
		}
	}
	s.Globs = deferredGlobsOf(plain, all, allowed)
	s.estimate(out, b, deferred)
	return s
}

// keepOneFont は、候補のフォントと後回しのフォントで fonts が全部になる時、manifest の先頭の候補を外す（export-web が止める形）。
func (s *webDeferredSuggestion) keepOneFont(fonts, deferredFonts []string) {
	n := len(deferredFonts)
	for _, c := range s.Candidates {
		if c.Kind == webDeferredFont {
			n++
		}
	}
	if len(fonts) == 0 || n < len(fonts) {
		return
	}
	for _, name := range fonts {
		for i, c := range s.Candidates {
			if c.Kind == webDeferredFont && c.Font == name {
				s.KeptFont = name
				s.Candidates = append(s.Candidates[:i], s.Candidates[i+1:]...)
				return
			}
		}
	}
}

// estimate は候補を貼った時の起動の秒と、足した物が届く時刻を出す。並びは export-web が組む後回しの列と同じ
// （フォントのアトラスが頭・今の web.deferred・足した glob の順。1 つの glob に当たる物は道の順）。
func (s *webDeferredSuggestion) estimate(out string, b *webBundle, deferred map[string]bool) {
	wire := map[string]int64{}
	var moved int64
	for _, c := range s.Candidates {
		wire[c.Path] = c.Wire
		moved += c.Wire
	}
	s.Before = webStartupEstimateOf(out, b).Seconds
	s.After = s.Before - webSecondsFor(moved)
	wireOf := func(rel string) int64 {
		if w, ok := wire[rel]; ok {
			return w
		}
		return webWireSize(exportAssetPath(out, b.served(rel)))
	}
	at := s.After
	var oldFonts, oldRest []string
	for _, e := range b.Deferred {
		if strings.HasSuffix(e.Path, ".fontatlas") {
			oldFonts = append(oldFonts, e.Path)
		} else {
			oldRest = append(oldRest, e.Path)
		}
	}
	added := map[string]bool{}
	step := func(rel string, report bool) {
		at += webSecondsFor(wireOf(rel))
		if report {
			s.Arrivals = append(s.Arrivals, webArrival{Path: rel, Seconds: at})
		}
	}
	for _, rel := range oldFonts {
		step(rel, false)
	}
	for _, name := range s.Fonts {
		step(webFontAtlasRel(name), true)
	}
	for _, rel := range oldRest {
		step(rel, false)
	}
	for _, g := range s.Globs {
		wg, err := compileWebGlob(g)
		if err != nil {
			continue
		}
		var hits []string
		for rel := range wire {
			if wg.match(rel) && !deferred[rel] && !added[rel] {
				hits = append(hits, rel)
			}
		}
		sort.Strings(hits)
		for _, rel := range hits {
			added[rel] = true
			step(rel, true)
		}
	}
}

// deferredGlobsOf は後回しにする道（大きい順）を、同じフォルダ・同じ頭の名前の物で glob にまとめる。
// glob は all（束の道）のうち allowed（候補と、もう後回しの物）にだけ当たる時に使う。並びは各 glob の一番大きい物の順。
// WhyNot: タイトルで使う物まで 1 本の glob に含めない — 貼ると、タイトルの絵や音まで後回しになる。
func deferredGlobsOf(paths []string, all []string, allowed map[string]bool) []string {
	pos := map[string]int{}
	for i, rel := range paths {
		pos[rel] = i
	}
	safe := func(glob string, members []string) bool {
		wg, err := compileWebGlob(glob)
		if err != nil {
			return false
		}
		for _, rel := range members {
			if !wg.match(rel) {
				return false
			}
		}
		for _, rel := range all {
			if wg.match(rel) && !allowed[rel] {
				return false
			}
		}
		return true
	}
	type group struct {
		glob    string
		members []string
	}
	byDirExt := map[string][]string{}
	var keys []string
	for _, rel := range paths {
		k := path.Dir(rel) + "\x00" + strings.ToLower(path.Ext(rel))
		if _, ok := byDirExt[k]; !ok {
			keys = append(keys, k)
		}
		byDirExt[k] = append(byDirExt[k], rel)
	}
	var groups []group
	for _, k := range keys {
		members := byDirExt[k]
		dir, ext := path.Dir(members[0]), path.Ext(members[0])
		if len(members) >= 2 && safe(dir+"/*"+ext, members) {
			groups = append(groups, group{dir + "/*" + ext, members})
			continue
		}
		byPrefix := map[string][]string{}
		var prefixes []string
		for _, rel := range members {
			p := namePrefix(path.Base(rel))
			if _, ok := byPrefix[p]; !ok {
				prefixes = append(prefixes, p)
			}
			byPrefix[p] = append(byPrefix[p], rel)
		}
		for _, p := range prefixes {
			ms := byPrefix[p]
			if p != "" && len(ms) >= 2 && safe(dir+"/"+p+"*"+ext, ms) {
				groups = append(groups, group{dir + "/" + p + "*" + ext, ms})
				continue
			}
			for _, rel := range ms {
				groups = append(groups, group{rel, []string{rel}})
			}
		}
	}
	first := func(g group) int {
		best := len(paths)
		for _, rel := range g.members {
			if pos[rel] < best {
				best = pos[rel]
			}
		}
		return best
	}
	sort.SliceStable(groups, func(i, j int) bool { return first(groups[i]) < first(groups[j]) })
	out := make([]string, 0, len(groups))
	for _, g := range groups {
		out = append(out, g.glob)
	}
	return out
}

// namePrefix は名前の頭（最初の `_` か `-` までを含む）。区切りが無ければ空。
func namePrefix(base string) string {
	i := strings.IndexAny(base, "_-")
	if i <= 0 {
		return ""
	}
	return base[:i+1]
}

// writeDeferredSuggestion は後回しの候補を project.json に貼れる形で書く。
func writeDeferredSuggestion(w io.Writer, s webDeferredSuggestion, game string) {
	for _, rel := range s.UsedLate {
		fmt.Fprintf(w, "  知らせ: 後回しの %s を、タイトルの %d コマの間に届く前に使おうとした — 4G では届くまで出ない・鳴らない（web.deferred から外すか、ゲームが downloads#missing() で待つ）\n", rel, s.Frames)
	}
	if len(s.Candidates) == 0 && len(s.Files) == 0 {
		fmt.Fprintf(w, "  後回しの候補: 無し（起動で取る素材は全部タイトルの %d コマの間に使った）\n", s.Frames)
		return
	}
	var moved int64
	for _, c := range s.Candidates {
		moved += c.Wire
	}
	fmt.Fprintf(w, "  後回しの候補（タイトルの %d コマで使わなかった起動の素材）%d 本・%s → 起動 約 %.1f → %.1f 秒（4G）\n",
		s.Frames, len(s.Candidates), humanBytes(moved), s.Before, s.After)
	if len(s.Globs) > 0 {
		fmt.Fprintf(w, "    \"deferred\": [%s]\n", quotedList(s.Globs))
	}
	if len(s.Fonts) > 0 {
		fmt.Fprintf(w, "    \"deferredFonts\": [%s]\n", quotedList(s.Fonts))
	}
	arrival := map[string]float64{}
	for _, a := range s.Arrivals {
		arrival[a.Path] = a.Seconds
	}
	fmt.Fprintln(w, "    大きい順（届く時刻は今の後回しの列の後ろに足した時）:")
	for _, c := range s.Candidates {
		names := ""
		if len(c.Names) > 0 {
			names = "（" + strings.Join(c.Names, "・") + "）"
		}
		fmt.Fprintf(w, "      %9s  %-6s %5.1f 秒目  %s%s\n", humanBytes(c.Wire), c.Kind.label(), arrival[c.Path], c.Path, names)
	}
	if len(s.Files) > 0 {
		fmt.Fprintf(w, "    読まなかったファイル %d 本（貼る形に入れていない。読み込みは届くのを待たないので、届いたかを見てから読む物だけ手で web.deferred へ）:\n", len(s.Files))
		for _, c := range s.Files {
			fmt.Fprintf(w, "      %9s  %s\n", humanBytes(c.Wire), c.Path)
		}
	}
	if s.KeptFont != "" {
		fmt.Fprintf(w, "    フォント %s は使っていないが候補から外した（全部のフォントは後回しにできない。届くまでの字の代わりに使う）\n", s.KeptFont)
	}
	fmt.Fprintf(w, "    確かめ: タイトルで押した時だけ使う物（カーソル・決定の音など）と、タイトルの直後の場面で使う物も候補に出る。\n"+
		"      後回しにした物は届くまで黒い・鳴らない — 外してから貼るか、ゲームが LoadProgress の downloads#missing() で待つ（docs/startup.md）\n")
	fmt.Fprintf(w, "    書き込むなら: bin/fge export-web %s --apply-deferred（project.json の web.deferred・web.deferredFonts の後ろへ足す）\n", game)
}

func quotedList(items []string) string {
	q := make([]string, len(items))
	for i, s := range items {
		q[i] = jsonString(s)
	}
	return strings.Join(q, ", ")
}

// jsonString は s を JSON の字にする（<>& はそのまま）。
// WhyNot: fmt の %q にしない — Go の書き方なので、制御文字が \x01 のように出て JSON として読めない。
func jsonString(s string) string {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.Encode(s)
	return strings.TrimSuffix(buf.String(), "\n")
}
