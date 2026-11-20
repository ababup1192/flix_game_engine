package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

// project.json の web.deferred（「押して始める」の前に取らず、wasm を読んだ後に裏で取る素材）。ゲームの根からの glob。
// 並び順がそのまま裏で取る順になる（同じ glob に当たる物は道の順）。
type webDeferredSettings struct {
	Deferred      []string `json:"deferred"`
	DeferredFonts []string `json:"deferredFonts"`
}

// webDeferredEntry は bundle.json の deferred の 1 本。Bytes は配る物（WebP・Opus に替えた後）の大きさ。
// Names は同じ道を指す project.json の textures と sounds の名前（ゲームが「まだ届いていない名前」として受ける）。
// OnMissing と Group は web.deferredPolicy で当たった行の物（無ければ空 = 種類の既定・組なし）。
type webDeferredEntry struct {
	Path      string   `json:"path"`
	Bytes     int64    `json:"bytes"`
	Names     []string `json:"names,omitempty"`
	OnMissing string   `json:"onMissing,omitempty"`
	Group     string   `json:"group,omitempty"`
	// ArrivalSeconds は後回しを取り始めてから 4G（1.6 Mbps・往復 150 ms）で届くまでの見積もりの秒（頁の ?net=4g が使う）。
	ArrivalSeconds float64 `json:"arrivalSeconds,omitempty"`
}

func resolveWebDeferred(raw json.RawMessage) ([]webGlob, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}
	var s webDeferredSettings
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, fmt.Errorf("project.json の web.deferred を読めない: %v\n  次: glob の字の配列にする（例 [\"assets/bgm/*.wav\"]）", err)
	}
	var globs []webGlob
	for _, g := range s.Deferred {
		wg, err := compileWebGlob(g)
		if err != nil {
			return nil, fmt.Errorf("project.json の web.deferred: %v", err)
		}
		globs = append(globs, wg)
	}
	return globs, nil
}

// resolveWebDeferredFonts は project.json の web.deferredFonts（タイトルの後に読むフォントの名前）を、fonts の名前と照らして返す。
// WhyNot: 全部のフォントを後回しにさせない — タイトルの字を出すフォントが 1 本も無いと、届くまで組み込みの英数の字で出る。
func resolveWebDeferredFonts(raw json.RawMessage, fonts []string) ([]string, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}
	var s webDeferredSettings
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, fmt.Errorf("project.json の web.deferredFonts を読めない: %v\n  次: フォントの名前の配列にする（例 [\"gothic\"]）", err)
	}
	known := map[string]bool{}
	for _, name := range fonts {
		known[name] = true
	}
	seen := map[string]bool{}
	var names []string
	for _, name := range s.DeferredFonts {
		if !known[name] {
			return nil, fmt.Errorf("project.json の web.deferredFonts の %q が fonts に無い。\n  次: fonts[].name の名前を書く（%s）", name, strings.Join(fonts, "・"))
		}
		if !seen[name] {
			seen[name] = true
			names = append(names, name)
		}
	}
	if len(names) > 0 && len(names) == len(fonts) {
		return nil, fmt.Errorf("project.json の web.deferredFonts が fonts を全部後回しにしている。\n  次: タイトルの字に使うフォントを 1 本は外す")
	}
	return names, nil
}

// checkDeferredFontNames は後回しのフォントの名前が、textures と sounds の名前と被っていないかを見る。
// WhyNot: 被ったまま通さない — 頁は後回しの物を名前でも引く（fgeDeferred.byName）ので、同じ名前の絵か音の届き具合と取り違える。
func checkDeferredFontNames(fonts []string, textureNames map[string][]string, sounds []webSound) error {
	taken := map[string]bool{}
	for _, names := range textureNames {
		for _, n := range names {
			taken[n] = true
		}
	}
	for _, s := range sounds {
		taken[s.Name] = true
	}
	for _, name := range fonts {
		if taken[name] {
			return fmt.Errorf("project.json の web.deferredFonts の %q が textures か sounds の名前と同じ。\n  次: フォントか素材の名前を替える（届いていない名前の一覧で取り違える）", name)
		}
	}
	return nil
}

// webFontAtlasRel はフォントのアトラスを置く道（engine_web の WebAssets.atlasPathOf と同じ）。
func webFontAtlasRel(name string) string { return "font-atlas/" + name + ".fontatlas" }

// withDeferredFonts は後回しの列の頭へ、後回しのフォントのアトラスを足し、アトラスの道 → フォントの名前を names に足した物を返す。
// 頁の届いていない名前（LoadProgress の missing）にフォントの名前が並び、ゲームは絵と同じ扱いで待てる。
// WhyNot: 列の後ろに足さない — 字は最初の場面から使い、3D の部屋や後半の絵より先に要る。
func withDeferredFonts(plan webDeferredPlan, fonts []string, names map[string][]string) (webDeferredPlan, map[string][]string) {
	if len(fonts) == 0 {
		return plan, names
	}
	merged := map[string][]string{}
	for rel, n := range names {
		merged[rel] = n
	}
	var heads []string
	for _, name := range fonts {
		rel := webFontAtlasRel(name)
		heads = append(heads, rel)
		merged[rel] = []string{name}
	}
	plan.Paths = append(heads, plan.Paths...)
	return plan, merged
}

// webDeferredPlan は後回しにする道（取る順）と、知らせるだけの行。
type webDeferredPlan struct {
	Paths    []string
	Warnings []string
}

// planWebDeferred は束の中身（files・images・sounds）に web.deferred を当てる。
// 誤り: 1 本も当たらない glob・project.json・web.embed と web.omit に当たる物・フォントのアトラス（頁が起動の前に読む・wasm に入る・配らない物）。
// タイトル画面の背景らしい絵（textures の名前か道に title を含む）に当たる時は知らせるだけ（どの絵がタイトルかは Doc にしか無い）。
// WhyNot: 当たらない glob を何も知らせずに通さない — 道を打ち間違えると、後回しにしたつもりの重い素材が起動の前に取られ、気付けない。
func planWebDeferred(b webBundle, globs []webGlob, embed webEmbedPlan, fonts []string, textureNames map[string][]string) (webDeferredPlan, error) {
	var plan webDeferredPlan
	if len(globs) == 0 {
		return plan, nil
	}
	hidden := map[string]string{}
	for _, rel := range embed.Embedded {
		hidden[rel] = "web.embed"
	}
	for _, rel := range embed.Omitted {
		hidden[rel] = "web.omit"
	}
	for _, name := range fonts {
		rel := webFontAtlasRel(name)
		for _, g := range globs {
			if g.match(rel) {
				return plan, fmt.Errorf("web.deferred の %q がフォントのアトラス %s に当たる（起動の画面の字に要る）。\n  次: glob を assets/ の下の素材だけに当たるよう狭める", g.Pattern, rel)
			}
		}
	}
	candidates := webBundleMediaAndFiles(b)
	taken := map[string]bool{}
	for _, g := range globs {
		var hits []string
		for _, rel := range candidates {
			if !g.match(rel) {
				continue
			}
			if rel == "project.json" {
				return plan, fmt.Errorf("web.deferred の %q が project.json に当たる（頁が起動の前に読む）", g.Pattern)
			}
			if field, ok := hidden[rel]; ok {
				return plan, fmt.Errorf("web.deferred の %q が %s の %s に当たる。\n  次: どちらか一方の glob から外す", g.Pattern, field, rel)
			}
			hits = append(hits, rel)
		}
		if len(hits) == 0 {
			return plan, fmt.Errorf("project.json の web.deferred の %q に当たる素材が束に無い。\n  次: ゲームの根からの道に直す（例 assets/bgm/*.wav）", g.Pattern)
		}
		sort.Strings(hits)
		for _, rel := range hits {
			if taken[rel] {
				continue
			}
			taken[rel] = true
			plan.Paths = append(plan.Paths, rel)
		}
	}
	for _, rel := range plan.Paths {
		if looksLikeTitleImage(rel, textureNames[rel]) {
			plan.Warnings = append(plan.Warnings, fmt.Sprintf("web.deferred の %s はタイトル画面の絵に見える — 届くまでタイトルに出ない（タイトルの背景は後回しにしない）", rel))
		}
	}
	return plan, nil
}

// webBundleMediaAndFiles は束の files・images・sounds の道を重ねずに並べる（アトラスは含まない — 束を作った直後に呼ぶ）。
func webBundleMediaAndFiles(b webBundle) []string {
	seen := map[string]bool{}
	var out []string
	for _, rel := range append(append(append([]string{}, b.Files...), b.Images...), soundPaths(b.Sounds)...) {
		if !seen[rel] {
			seen[rel] = true
			out = append(out, rel)
		}
	}
	return out
}

func looksLikeTitleImage(rel string, names []string) bool {
	switch strings.ToLower(path.Ext(rel)) {
	case ".png", ".jpg", ".jpeg", ".webp":
	default:
		return false
	}
	if strings.Contains(strings.ToLower(path.Base(rel)), "title") {
		return true
	}
	for _, n := range names {
		if strings.Contains(strings.ToLower(n), "title") {
			return true
		}
	}
	return false
}

// webDeferredEntries は後回しの道に、配る大きさと名前を付ける（素材を小さくした後に呼ぶ）。
func webDeferredEntries(out string, b *webBundle, paths []string, textureNames map[string][]string) []webDeferredEntry {
	soundNames := map[string][]string{}
	for _, s := range b.Sounds {
		soundNames[s.Path] = append(soundNames[s.Path], s.Name)
	}
	var entries []webDeferredEntry
	for _, rel := range paths {
		names := append(append([]string{}, textureNames[rel]...), soundNames[rel]...)
		entries = append(entries, webDeferredEntry{Path: rel, Bytes: fileSize(exportAssetPath(out, b.served(rel))), Names: names})
	}
	return entries
}

// webStartupSize は「押して始める」の前に取る素材（後回しでない files・images・sounds）の本数と配る大きさの和、後回しの本数と大きさの和。
type webStartupSize struct {
	StartCount, DeferredCount int
	StartBytes, DeferredBytes int64
}

func webStartupSizeOf(out string, b *webBundle) webStartupSize {
	deferred := map[string]bool{}
	var s webStartupSize
	for _, e := range b.Deferred {
		deferred[e.Path] = true
		s.DeferredCount++
		s.DeferredBytes += e.Bytes
	}
	for _, rel := range b.copyList() {
		if deferred[rel] {
			continue
		}
		s.StartCount++
		s.StartBytes += fileSize(exportAssetPath(out, b.served(rel)))
	}
	return s
}

// textureNamesByPath は project.json の textures の道 → 名前。
func textureNamesByPath(pr exportProject) map[string][]string {
	out := map[string][]string{}
	for _, t := range pr.Textures {
		rel := path.Clean(strings.ReplaceAll(t.Path, "\\", "/"))
		if t.Name != "" {
			out[rel] = append(out[rel], t.Name)
		}
	}
	return out
}

// 起動まで（遊べるまで）の見積もりの前提。測った 4G の回線（Lighthouse のモバイルと同じ 1.6 Mbps・往復 150 ms）に合わせる。
const (
	webStartupBitsPerSecond = 1.6e6
	// webStartupPreludeSeconds は index.html → version.txt → js → bundle.json の直列の往復（測った値）。
	webStartupPreludeSeconds = 1.5
	// webStartupTargetSeconds を超えたら書き出しの終わりに知らせる（止めない）。
	webStartupTargetSeconds = 16.0
)

// webStartupBytes は頁が進みの棒を量で動かすための、起動の素材と wasm の大きさ（頁が数えるバイト数と回線に乗る量の見積もり）。
// wasm を brotli で配る時の Wasm は classes.wasm.br の大きさ（頁はそれを数える）。
type webStartupBytes struct {
	Assets     int64 `json:"assets"`
	AssetsWire int64 `json:"assetsWire"`
	Wasm       int64 `json:"wasm"`
	WasmWire   int64 `json:"wasmWire"`
}

// webArrival は後回しの 1 本が 1.6 Mbps で何秒目に届くかの見積もり。
type webArrival struct {
	Path    string
	Seconds float64
}

// webStartupEstimate は遊べるまでに回線に乗る量と秒数の見積もり、と後回しの届く時刻。
type webStartupEstimate struct {
	Boot     webStartupBytes
	PageWire int64
	Seconds  float64
	Deferred []webArrival
}

// webWireSize は置き場が gzip で配るとした時に回線に乗る量。もう詰めてある形（絵・音）は素の大きさ。
// WhyNot: 置き場の圧縮を brotli で見積もらない — 今の置き先（GitHub Pages）は gzip しか配らない。
func webWireSize(p string) int64 {
	switch strings.ToLower(path.Ext(p)) {
	case ".webp", ".jpg", ".jpeg", ".png", ".webm", ".opus", ".ogg", ".mp3", ".woff2", ".avif":
		return fileSize(p)
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return 0
	}
	gz, err := gzipBytes(data)
	if err != nil || int64(len(gz)) > int64(len(data)) {
		return int64(len(data))
	}
	return int64(len(gz))
}

func webSecondsFor(wire int64) float64 { return float64(wire) * 8 / webStartupBitsPerSecond }

// webStartupBytesOf は書き出し先 out の起動の素材（後回しでない物）と classes.wasm の大きさ。
func webStartupBytesOf(out string, b *webBundle) webStartupBytes {
	deferred := map[string]bool{}
	for _, e := range b.Deferred {
		deferred[e.Path] = true
	}
	var s webStartupBytes
	for _, rel := range b.copyList() {
		if deferred[rel] {
			continue
		}
		p := exportAssetPath(out, b.served(rel))
		s.Assets += fileSize(p)
		s.AssetsWire += webWireSize(p)
	}
	wasm := filepath.Join(out, "classes.wasm")
	s.Wasm, s.WasmWire = fileSize(wasm), webWireSize(wasm)
	if br := filepath.Join(out, b.WasmBrotli); b.WasmBrotli != "" && fileExists(br) {
		decoder := webWireSize(filepath.Join(out, webBrotliDecoderFile))
		s.Wasm, s.WasmWire = fileSize(br), fileSize(br)+decoder
	}
	return s
}

// webStartupEstimateOf は書き出し先 out から起動までの見積もりを作る。後回しは起動の後に、並べた順で回線を使い切るとして届く時刻を出す。
func webStartupEstimateOf(out string, b *webBundle) webStartupEstimate {
	s := webStartupEstimate{Boot: webStartupBytesOf(out, b)}
	for _, name := range []string{"index.html", "version.txt", "fge-web.js", "wasm-gc-runtime.js", "bundle.json"} {
		s.PageWire += webWireSize(filepath.Join(out, name))
	}
	s.Seconds = webStartupPreludeSeconds + webSecondsFor(s.Boot.AssetsWire+s.Boot.WasmWire+s.PageWire)
	for i, after := range webDeferredArrivals(out, b) {
		s.Deferred = append(s.Deferred, webArrival{Path: b.Deferred[i].Path, Seconds: s.Seconds + after})
	}
	return s
}

// webDeferredRoundTripSeconds は後回しの 1 本ごとに足す往復の秒（往復 150 ms を、頁が同時に取る 2 本で分け合う）。
// WhyNot: 帯域だけで積まない — 小さな絵が百本を超えるゲームは、帯域より本数の往復で詰まる。
const webDeferredRoundTripSeconds = 0.15 / 2

// webDeferredArrivals は後回しの 1 本ずつが、後回しを取り始めて（タッチして開始の頃）から 4G で届くまでの秒（取る順に積む）。
func webDeferredArrivals(out string, b *webBundle) []float64 {
	arrivals := make([]float64, len(b.Deferred))
	at := 0.0
	for i, e := range b.Deferred {
		at += webSecondsFor(webWireSize(exportAssetPath(out, b.served(e.Path)))) + webDeferredRoundTripSeconds
		arrivals[i] = at
	}
	return arrivals
}

// setWebArrivalSeconds は bundle.json の後回しの項目に arrivalSeconds を書く（頁の ?net=4g がその秒まで渡さない）。
func setWebArrivalSeconds(out string, b *webBundle) {
	for i, at := range webDeferredArrivals(out, b) {
		b.Deferred[i].ArrivalSeconds = math.Round(at*1000) / 1000
	}
}

// webTapWait は「開いてすぐ押した時に、押してから最初の場面が動くまで」の 4G での見積もり。
// Group が空でなければ押した後のロゴが待つ group の最後が届く秒（Seconds）。空なら engine が待ちうる後回し（絵・wait の物・group を付けたフォント）の
// 最初が届く秒（Seconds・最初の場面が待つ物を使うなら少なくともこれだけ待つ）と最後が届く秒（Until・場面がどれを使うかで決まる上限）。待つ物が無ければ Count が 0。
type webTapWait struct {
	Group          []string
	Seconds, Until float64
	FirstPath      string
	Count          int
}

// webWaitsWhenMissing は後回しの 1 本が、届く前に使われた時に engine が待つ扱いか（fge-web.js の fgeDeferredPolicy と種類の既定を合わせる）。
func webWaitsWhenMissing(e webDeferredEntry, kind string) bool {
	switch kind {
	case "image":
		return e.OnMissing != "placeholder"
	case "font":
		return e.OnMissing == "wait" || (e.OnMissing == "" && e.Group != "")
	case "sound":
		return e.OnMissing == "wait"
	}
	return false
}

func webTapWaitOf(out string, b *webBundle, waitFor []string) webTapWait {
	arrivals := webDeferredArrivals(out, b)
	want := map[string]bool{}
	for _, g := range waitFor {
		want[g] = true
	}
	w := webTapWait{Group: waitFor}
	for i, e := range b.Deferred {
		if len(want) > 0 {
			if want[e.Group] {
				w.Count++
				w.Seconds = arrivals[i]
				w.Until = arrivals[i]
			}
			continue
		}
		if !webWaitsWhenMissing(e, webDeferredKindOf(e.Path, b)) {
			continue
		}
		if w.Count == 0 {
			w.Seconds, w.FirstPath = arrivals[i], e.Path
		}
		w.Count++
		w.Until = arrivals[i]
	}
	return w
}
