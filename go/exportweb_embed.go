package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// project.json の web.embed（wasm に符号で埋め込む素材）と web.omit（配らない素材）。どちらもゲームの根からの glob。
type webEmbedSettings struct {
	Embed []string `json:"embed"`
	Omit  []string `json:"omit"`
}

type webEmbed struct {
	Embed []webGlob
	Omit  []webGlob
}

func resolveWebEmbed(raw json.RawMessage) (webEmbed, error) {
	var e webEmbed
	if len(raw) == 0 || string(raw) == "null" {
		return e, nil
	}
	var s webEmbedSettings
	if err := json.Unmarshal(raw, &s); err != nil {
		return e, fmt.Errorf("project.json の web.embed か web.omit を読めない: %v\n  次: どちらも glob の字の配列にする（例 [\"assets/talk/dialogue.json\"]）", err)
	}
	for _, g := range s.Embed {
		wg, err := compileWebGlob(g)
		if err != nil {
			return e, fmt.Errorf("project.json の web.embed: %v", err)
		}
		e.Embed = append(e.Embed, wg)
	}
	for _, g := range s.Omit {
		wg, err := compileWebGlob(g)
		if err != nil {
			return e, fmt.Errorf("project.json の web.omit: %v", err)
		}
		e.Omit = append(e.Omit, wg)
	}
	return e, nil
}

func matchAny(globs []webGlob, rel string) bool {
	for _, g := range globs {
		if g.match(rel) {
			return true
		}
	}
	return false
}

// webEmbedPlan は束の files のうち、埋め込む物と配らない物を決めた結果。
type webEmbedPlan struct {
	Embedded []string
	Omitted  []string
}

// planWebEmbed は束の中身に web.embed と web.omit を当てる。当たる物の無い glob・files の外（絵・音・project.json）に当たる glob は誤り。
// WhyNot: 当たらない glob を何も知らせずに通さない — 道を打ち間違えると、隠したつもりのシナリオがそのまま配られる。
func planWebEmbed(b webBundle, e webEmbed) (webEmbedPlan, error) {
	var plan webEmbedPlan
	hit := map[string]bool{}
	for _, rel := range b.Files {
		inEmbed, inOmit := matchAny(e.Embed, rel), matchAny(e.Omit, rel)
		if (inEmbed || inOmit) && rel == "project.json" {
			return plan, fmt.Errorf("project.json は web.embed にも web.omit にも入れられない（頁が起動の前に読む）")
		}
		for _, g := range e.Embed {
			if g.match(rel) {
				hit["embed:"+g.Pattern] = true
			}
		}
		for _, g := range e.Omit {
			if g.match(rel) {
				hit["omit:"+g.Pattern] = true
			}
		}
		switch {
		case inEmbed && inOmit:
			return plan, fmt.Errorf("%s が web.embed と web.omit の両方に当たる。\n  次: どちらか一方の glob から外す", rel)
		case inEmbed:
			plan.Embedded = append(plan.Embedded, rel)
		case inOmit:
			plan.Omitted = append(plan.Omitted, rel)
		}
	}
	if len(plan.Embedded) > webEmbedLimit {
		return plan, fmt.Errorf("web.embed に当たるファイルが %d 本ある（%d 本まで）。\n  次: glob を隠したいシナリオだけに狭める", len(plan.Embedded), webEmbedLimit)
	}
	media := append(append([]string{}, b.Images...), soundPaths(b.Sounds)...)
	for _, rel := range media {
		if matchAny(e.Embed, rel) || matchAny(e.Omit, rel) {
			return plan, fmt.Errorf("%s は絵か音なので web.embed・web.omit に入れられない。\n  次: glob を字・JSON などのファイルだけに当たるよう狭める", rel)
		}
	}
	for _, field := range []struct {
		key, name string
		globs     []webGlob
	}{{"embed:", "web.embed", e.Embed}, {"omit:", "web.omit", e.Omit}} {
		for _, g := range field.globs {
			if !hit[field.key+g.Pattern] {
				return plan, fmt.Errorf("project.json の %s の %q に当たるファイルが assets/ の下に無い。\n  次: ゲームの根からの道に直す（例 assets/talk/dialogue.json）", field.name, g.Pattern)
			}
		}
	}
	return plan, nil
}

func soundPaths(sounds []webSound) []string {
	var out []string
	for _, s := range sounds {
		out = append(out, s.Path)
	}
	return out
}

// withoutHidden は束の files から埋め込む物と配らない物を抜く。
func (plan webEmbedPlan) withoutHidden(files []string) []string {
	hidden := map[string]bool{}
	for _, rel := range plan.Embedded {
		hidden[rel] = true
	}
	for _, rel := range plan.Omitted {
		hidden[rel] = true
	}
	var kept []string
	for _, rel := range files {
		if !hidden[rel] {
			kept = append(kept, rel)
		}
	}
	return kept
}

// webEmbedLimit は埋め込める素材の数。生成する class の 1 つの関数は 64 KiB まで（1 本につき切れ端 1 つでも約 8 バイト × 3）。
const webEmbedLimit = 500

// embedSeedOf は埋め込む素材の道と中身から鍵を決める。
// WhyNot: 書き出しのたびに乱数で鍵を作らない — 中身が同じでも classes.wasm と版が毎回変わり、配るたびにブラウザのキャッシュが外れ、同じ入力から同じ物ができなくなる。
func embedSeedOf(game string, embedded []string) (int64, error) {
	h := sha256.New()
	for _, rel := range embedded {
		data, err := os.ReadFile(filepath.Join(game, filepath.FromSlash(rel)))
		if err != nil {
			return 0, fmt.Errorf("%s を読めない: %v", rel, err)
		}
		fmt.Fprintf(h, "%s\x00%d\x00", rel, len(data))
		h.Write(data)
	}
	seed := int64(binary.LittleEndian.Uint64(h.Sum(nil)[:8]) >> 1)
	if seed == 0 {
		seed = 1
	}
	return seed, nil
}

// runEmbed は fge.teavmfix.Embed を流し、標準出力の `embed <道> <元> <符号>` の行を画面へ出す。
func runEmbed(java, asmJar, toolsJar, webJar, game, src, dst, log string, embedded []string, seed int64) int {
	cp := strings.Join([]string{asmJar, toolsJar, webJar}, string(os.PathListSeparator))
	args := []string{"-cp", cp, "fge.teavmfix.Embed", src, dst, strconv.FormatInt(seed, 10)}
	for _, rel := range embedded {
		args = append(args, rel, filepath.Join(game, filepath.FromSlash(rel)))
	}
	code := runLogged(filepath.Dir(dst), log, false, java, args...)
	text, _ := os.ReadFile(log)
	for _, line := range strings.Split(string(text), "\n") {
		f := strings.Fields(line)
		if len(f) == 4 && f[0] == "embed" {
			plain, _ := strconv.ParseInt(f[2], 10, 64)
			coded, _ := strconv.ParseInt(f[3], 10, 64)
			ewLogf("  embed %s（%s → 符号 %s）", f[1], humanBytes(plain), humanBytes(coded))
		}
	}
	if code == 0 && !fileExists(dst) {
		return 1
	}
	return code
}

// embedLeakSamples は埋め込んだ素材から、書き出し先に平文で残っていないか探す断片（ASCII でない字が 10 字以上続く所）を取る。
// WhyNot: ASCII の行を断片にしない — 同じ形の JSON（"kind": "line" など）はほかの Doc にもあり、隠していない物で止まる。
// WhyNot: 同じ字の繰り返し（……）を断片にしない — どの台詞の Doc にもある。
func embedLeakSamples(data []byte) [][]byte {
	const minRunes, limit = 10, 16
	var samples [][]byte
	start, runes := -1, 0
	distinct := map[rune]bool{}
	flush := func(end int) {
		if start >= 0 && runes >= minRunes && len(distinct) >= minRunes/2 {
			samples = append(samples, data[start:end])
		}
		start, runes = -1, 0
		distinct = map[rune]bool{}
	}
	for i := 0; i < len(data); {
		r, size := utf8.DecodeRune(data[i:])
		if r >= 0x80 && r != utf8.RuneError {
			if start < 0 {
				start = i
			}
			runes++
			distinct[r] = true
		} else {
			flush(i)
		}
		i += size
	}
	flush(len(data))
	if len(samples) <= limit {
		return samples
	}
	picked := make([][]byte, 0, limit)
	for i := 0; i < limit; i++ {
		picked = append(picked, samples[i*len(samples)/limit])
	}
	return picked
}

// checkEmbedLeaks は書き出し先の全部のファイルを、埋め込んだ素材の断片で探す。見つかれば何がどこにあったかを返す。
// 断片を 1 つも取れなかった素材（ASCII だけの物）の道は unchecked に返す。
func checkEmbedLeaks(out, game string, embedded []string) (unchecked []string, err error) {
	type sample struct {
		rel  string
		text []byte
	}
	var samples []sample
	for _, rel := range embedded {
		data, err := os.ReadFile(filepath.Join(game, filepath.FromSlash(rel)))
		if err != nil {
			return nil, fmt.Errorf("%s を読めない: %v", rel, err)
		}
		found := embedLeakSamples(data)
		if len(found) == 0 {
			unchecked = append(unchecked, rel)
		}
		for _, s := range found {
			samples = append(samples, sample{rel, s})
		}
	}
	if len(samples) == 0 {
		return unchecked, nil
	}
	var leaks []string
	err = filepath.WalkDir(out, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		for _, s := range samples {
			if bytes.Contains(data, s.text) {
				shown, _ := filepath.Rel(out, p)
				leaks = append(leaks, fmt.Sprintf("%s の %q が %s に平文で残っている", s.rel, string(s.text), filepath.ToSlash(shown)))
				break
			}
		}
		return nil
	})
	if err != nil {
		return unchecked, err
	}
	if len(leaks) > 0 {
		sort.Strings(leaks)
		return unchecked, fmt.Errorf("埋め込んだ素材の中身が書き出し先に残っている:\n  %s\n  次: 同じ中身のファイルを、実行時に読まない物（.yarn など）は web.omit に、読む物は web.embed に足す", strings.Join(leaks, "\n  "))
	}
	return unchecked, nil
}
