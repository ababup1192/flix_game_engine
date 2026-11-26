package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
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
	// Why は当たった deferredPolicy の行の why（遅く届く待つ物の門が、書いた理由で許す・bundle.json に写るので公開される）。
	Why string `json:"why,omitempty"`
	// ArrivalSeconds は後回しを取り始めてから 4G（1.6 Mbps・往復 150 ms）で届くまでの見積もりの秒（頁の ?fge=4g が使う）。
	ArrivalSeconds float64 `json:"arrivalSeconds,omitempty"`
}

// webDeferredOrder は web.deferred の glob と、その間に書いた font:<名前> の行の位置。
type webDeferredOrder struct {
	Globs []webGlob
	Fonts []webDeferredFontSlot
}

// webDeferredFontSlot は web.deferred の font:<名前> の 1 行。Before はその行より前に書いた glob の数。
type webDeferredFontSlot struct {
	Font   string
	Before int
}

const webDeferredFontPrefix = "font:"

func resolveWebDeferred(raw json.RawMessage) (webDeferredOrder, error) {
	var order webDeferredOrder
	if len(raw) == 0 || string(raw) == "null" {
		return order, nil
	}
	var s webDeferredSettings
	if err := json.Unmarshal(raw, &s); err != nil {
		return order, fmt.Errorf("project.json の web.deferred を読めない: %v\n  次: glob の字の配列にする（例 [\"assets/bgm/*.wav\"]）", err)
	}
	seen := map[string]bool{}
	for _, g := range s.Deferred {
		if strings.HasPrefix(g, webDeferredFontPrefix) {
			name := strings.TrimPrefix(g, webDeferredFontPrefix)
			if name == "" {
				return order, fmt.Errorf("project.json の web.deferred の %q にフォントの名前が無い。\n  次: font:<fonts[].name> の形にする", g)
			}
			if seen[name] {
				return order, fmt.Errorf("project.json の web.deferred に %q が 2 行ある。\n  次: 取る順にしたい位置の 1 行だけ残す", g)
			}
			seen[name] = true
			order.Fonts = append(order.Fonts, webDeferredFontSlot{Font: name, Before: len(order.Globs)})
			continue
		}
		wg, err := compileWebGlob(g)
		if err != nil {
			return order, fmt.Errorf("project.json の web.deferred: %v", err)
		}
		order.Globs = append(order.Globs, wg)
	}
	return order, nil
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

// withDeferredFonts は後回しの列へ後回しのフォントのアトラスを差し込み、アトラスの道 → フォントの名前を names に足した物を返す。
// 差し込む位置は、web.deferred の font:<名前> の行があればその行の位置、無ければ groupAt（同じ group の最初の素材の位置）、どちらも無ければ列の頭。
// 頁の届いていない名前（LoadProgress の missing）にフォントの名前が並び、ゲームは絵と同じ扱いで待てる。
// WhyNot: 書いていないフォントを列の後ろに回さない — 字は最初の場面から使うゲームが多く、font: の行を書いていないゲームの並びは今までの頭のまま残す。
// WhyNot: deferredFonts に無いフォントを font: の行だけで後回しにしない — 後回しにするフォントを書く所が 2 つになり、候補を出す口と --apply-deferred が片方しか見ない。
func withDeferredFonts(plan webDeferredPlan, fonts []string, slots []webDeferredFontSlot, groupAt map[string]int, names map[string][]string) (webDeferredPlan, map[string][]string, error) {
	deferred := map[string]bool{}
	for _, name := range fonts {
		deferred[name] = true
	}
	slotAt := map[string]int{}
	for _, slot := range slots {
		if !deferred[slot.Font] {
			return plan, names, fmt.Errorf("project.json の web.deferred の font:%s が web.deferredFonts に無い。\n  次: deferredFonts に %q を足す（後回しにするフォントは deferredFonts に書き、web.deferred の行は取る位置だけを決める）か行を消す", slot.Font, slot.Font)
		}
		slotAt[slot.Font] = plan.GlobStarts[slot.Before]
	}
	if len(fonts) == 0 {
		return plan, names, nil
	}
	merged := map[string][]string{}
	for rel, n := range names {
		merged[rel] = n
	}
	type placed struct {
		rel string
		at  int
	}
	var inserts []placed
	add := func(name string, at int) {
		rel := webFontAtlasRel(name)
		merged[rel] = []string{name}
		inserts = append(inserts, placed{rel, at})
	}
	for _, name := range fonts {
		if _, ok := slotAt[name]; ok {
			continue
		}
		at, ok := groupAt[name]
		if !ok {
			at = 0
		}
		add(name, at)
	}
	for _, slot := range slots {
		add(slot.Font, slotAt[slot.Font])
	}
	sort.SliceStable(inserts, func(i, j int) bool { return inserts[i].at < inserts[j].at })
	paths := make([]string, 0, len(plan.Paths)+len(inserts))
	next := 0
	for i, rel := range plan.Paths {
		for next < len(inserts) && inserts[next].at <= i {
			paths = append(paths, inserts[next].rel)
			next++
		}
		paths = append(paths, rel)
	}
	for ; next < len(inserts); next++ {
		paths = append(paths, inserts[next].rel)
	}
	plan.Paths = paths
	return plan, merged, nil
}

// webFontGroupStarts は group を付けた後回しのフォント → 同じ group の最初の素材（フォントでない物）の paths の位置。
// その group の素材が列に無いフォントは入れない（列の頭に置く）。
// WhyNot: deferredPolicy の誤りをここで出さない — 後で書き出しの列全部に当て直す applyWebDeferredPolicy が同じ誤りを出して止める。
func webFontGroupStarts(paths []string, fonts []string, pol webDeferredPolicy, b *webBundle, textureNames map[string][]string) map[string]int {
	if len(fonts) == 0 || len(pol.Rows) == 0 {
		return nil
	}
	entries := webDeferredEntries(newWebSizeTable(""), b, paths, textureNames)
	for _, name := range fonts {
		entries = append(entries, webDeferredEntry{Path: webFontAtlasRel(name), Names: []string{name}})
	}
	entries, _, err := applyWebDeferredPolicy(entries, pol, b)
	if err != nil {
		return nil
	}
	first := map[string]int{}
	for i, e := range entries[:len(paths)] {
		if _, ok := first[e.Group]; !ok && e.Group != "" {
			first[e.Group] = i
		}
	}
	out := map[string]int{}
	for i, e := range entries[len(paths):] {
		if at, ok := first[e.Group]; ok && e.Group != "" {
			out[fonts[i]] = at
		}
	}
	return out
}

// webDeferredPlan は後回しにする道（取る順）と、知らせるだけの行。
// GlobStarts[i] は web.deferred の i 本目の glob が当てた最初の道の Paths の位置（末尾に len(Paths) を足す・font: の行の位置に使う）。
type webDeferredPlan struct {
	Paths      []string
	GlobStarts []int
	Warnings   []string
}

// planWebDeferred は束の中身（files・images・sounds）に web.deferred を当てる。
// 誤り: 1 本も当たらない glob・project.json・web.embed と web.omit に当たる物・フォントのアトラス（頁が起動の前に読む・wasm に入る・配らない物）。
// タイトル画面の背景らしい絵（textures の名前か道に title を含む）に当たる時は知らせるだけ（どの絵がタイトルかは Doc にしか無い）。
// WhyNot: 当たらない glob を何も知らせずに通さない — 道を打ち間違えると、後回しにしたつもりの重い素材が起動の前に取られ、気付けない。
func planWebDeferred(b webBundle, globs []webGlob, embed webEmbedPlan, fonts []string, textureNames map[string][]string) (webDeferredPlan, error) {
	var plan webDeferredPlan
	if len(globs) == 0 {
		plan.GlobStarts = []int{0}
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
		plan.GlobStarts = append(plan.GlobStarts, len(plan.Paths))
		for _, rel := range hits {
			if taken[rel] {
				continue
			}
			taken[rel] = true
			plan.Paths = append(plan.Paths, rel)
		}
	}
	plan.GlobStarts = append(plan.GlobStarts, len(plan.Paths))
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
func webDeferredEntries(sizes *webSizeTable, b *webBundle, paths []string, textureNames map[string][]string) []webDeferredEntry {
	soundNames := map[string][]string{}
	for _, s := range b.Sounds {
		soundNames[s.Path] = append(soundNames[s.Path], s.Name)
	}
	var entries []webDeferredEntry
	for _, rel := range paths {
		names := append(append([]string{}, textureNames[rel]...), soundNames[rel]...)
		entries = append(entries, webDeferredEntry{Path: rel, Bytes: sizes.assetRaw(b, rel), Names: names})
	}
	return entries
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

// webGlbPrimitiveLimit は後回しの glb 1 つの primitive の数の目安（M4 Pro の Chrome で解く仕事 35 ms 前後・engine の docs/startup.md の costMs の目安）。
const webGlbPrimitiveLimit = 200

// deferredGlbWarnings は web.deferred の glb のうち、primitive が limit 個を超える物を 1 行ずつ知らせる。読めない glb は黙って飛ばす（束を作る時に壊れていれば読み込みが知らせる）。
// WhyNot: 止めない — 1 つの glb を分けられない物（骨つきの大きなキャラ 1 体など）もあり、届いたコマが止まるだけで遊べなくはならない。
func deferredGlbWarnings(game string, paths []string, limit int) []string {
	var out []string
	for _, rel := range paths {
		if !strings.EqualFold(path.Ext(rel), ".glb") {
			continue
		}
		n, err := glbPrimitiveCount(filepath.Join(game, filepath.FromSlash(rel)))
		if err != nil || n <= limit {
			continue
		}
		out = append(out, fmt.Sprintf("web.deferred の %s は primitive が %d 個（目安 %d 個）— 遊んでいる最中に届くと、解くコマがこの束 1 つで止まる（M4 Pro の Chrome で 200 個 35 ms 前後・スマホは 3〜5 倍）。\n  次: 束を分ける（engine の docs/startup.md の costMs の目安）", rel, n, limit))
	}
	return out
}

// glbPrimitiveCount は glb の最初のチャンク（JSON）の meshes[].primitives の数の合計。
func glbPrimitiveCount(file string) (int, error) {
	f, err := os.Open(file)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	var head [20]byte
	if _, err := io.ReadFull(f, head[:]); err != nil {
		return 0, err
	}
	if binary.LittleEndian.Uint32(head[0:4]) != 0x46546C67 || binary.LittleEndian.Uint32(head[16:20]) != 0x4E4F534A {
		return 0, fmt.Errorf("%s: glb の頭でない", file)
	}
	body := make([]byte, binary.LittleEndian.Uint32(head[12:16]))
	if _, err := io.ReadFull(f, body); err != nil {
		return 0, err
	}
	var doc struct {
		Meshes []struct {
			Primitives []json.RawMessage `json:"primitives"`
		} `json:"meshes"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return 0, err
	}
	n := 0
	for _, m := range doc.Meshes {
		n += len(m.Primitives)
	}
	return n, nil
}
