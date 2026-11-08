package main

import (
	"encoding/json"
	"fmt"
	"path"
	"sort"
	"strings"
)

// project.json の web.deferred（「押して始める」の前に取らず、wasm を読んだ後に裏で取る素材）。ゲームの根からの glob。
// 並び順がそのまま裏で取る順になる（同じ glob に当たる物は道の順）。
type webDeferredSettings struct {
	Deferred []string `json:"deferred"`
}

// webDeferredEntry は bundle.json の deferred の 1 本。Bytes は配る物（WebP・Opus に替えた後）の大きさ。
// Names は同じ道を指す project.json の textures と sounds の名前（ゲームが「まだ届いていない名前」として受ける）。
type webDeferredEntry struct {
	Path  string   `json:"path"`
	Bytes int64    `json:"bytes"`
	Names []string `json:"names,omitempty"`
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
		rel := "font-atlas/" + name + ".fontatlas"
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
