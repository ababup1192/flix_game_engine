package refactor

// 使っていない use・import を flixlint の判定で探す（usages --unused と remove-use の元）。
//
// 埋め込みの規則（unused_use.flix: Flixlint.Flix.uses・namesUsed・isUnused）を flixlint の lint として resolved の段で
// 流し、unused-use の違反の行（file:line・モジュール・取り込んだ名前）を読む。ゲームの lint/rules.flix の unused-use と
// 同じ判定なので、道具が消した後に lint が別の物を言い出さない。effect・trait・mod・Java の import も判じられる
// （索引の行で決める判定は def・enum・case・alias の use しか見られなかった）。
// 答えは build/refactor/unused-use.tsv に索引と同じ鍵（ソース・依存・flixlint の版）で控え、同じなら流さない。
//
// WhyNot: 判定を Go で書き直さない。flixlint の判定と 2 つになると、片方だけ直って食い違う（BoardGifRender の
// 戻りの型にだけ書いた Java の型を、道具と lint のどちらが使っていると見るか）。

import (
	_ "embed"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

//go:embed unused_use.flix
var unusedUseRules string

// MinFlixlintUnusedUse は Flixlint.Flix.namesUsed・isUnused を持つ一番古い flixlint の版。
const MinFlixlintUnusedUse = "0.7.2"

// UseFinding は使っていない use・import の 1 つ（flixlint の unused-use の違反 1 件）。
type UseFinding struct {
	File   string `json:"file"`
	Line   int    `json:"line"`
	Module string `json:"module"`
	Name   string `json:"name"` // 取り込んだ物の名前（Auth.Permit・java.io.File）
}

var unusedUseLine = regexp.MustCompile(`^(\S+\.flix):(\d+): unused-use: (\S+): brings in (\S+), which the module never uses$`)

// parseUnusedUses は flixlint の出力から unused-use の違反を読む（ほかの行は見ない）。
func parseUnusedUses(text string) []UseFinding {
	var out []UseFinding
	for _, l := range strings.Split(text, "\n") {
		m := unusedUseLine.FindStringSubmatch(strings.TrimRight(l, "\r"))
		if m == nil {
			continue
		}
		n, _ := strconv.Atoi(m[2])
		out = append(out, UseFinding{File: m[1], Line: n, Module: m[3], Name: m[4]})
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].File != out[j].File {
			return out[i].File < out[j].File
		}
		return out[i].Line < out[j].Line
	})
	return out
}

func (b Builder) unusedUsePaths() (tsv, key, log string) {
	return filepath.Join(b.Dir(), "unused-use.tsv"), filepath.Join(b.Dir(), "unused-use.key"), filepath.Join(b.Dir(), "unused-use.log")
}

// UnusedUses は使っていない use・import を flixlint の判定で返す。flixlint が古い・流せない時は誤り（呼ぶ側は索引の
// 判定に戻して、そう書く）。
func (b Builder) UnusedUses() ([]UseFinding, error) {
	if v := b.version(); !versionAtLeast(v, MinFlixlintUnusedUse) {
		return nil, fmt.Errorf("flixlint %s 以上が要る（今は %s）", MinFlixlintUnusedUse, v)
	}
	src, err := b.sourceKey(Resolved)
	if err != nil {
		return nil, err
	}
	key := joinKey(src+" unused-use "+unusedUseRules, b.envKey())
	tsvPath, keyPath, log := b.unusedUsePaths()
	if !b.Rebuild {
		if old, _, ok := readKey(keyPath); ok && old == key {
			if data, err := os.ReadFile(tsvPath); err == nil {
				return parseUnusedUses(string(data)), nil
			}
		}
	}
	dir := filepath.Join(b.Dir(), "unused-use")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	rules := filepath.Join(dir, "rules.flix")
	if err := os.WriteFile(rules, []byte(unusedUseRules), 0o644); err != nil {
		return nil, err
	}
	cmd := []string{b.Flixlint}
	if versionAtLeast(b.version(), MinFlixlint) {
		cmd = append(cmd, "--resident")
	}
	cmd = append(cmd, "--rules", rules, "--stage", string(Resolved), "--build-dir", filepath.Join(dir, "build"))
	if b.FlixJar != "" {
		cmd = append(cmd, "--flix-jar", b.FlixJar)
	}
	if extra := strings.Fields(b.Config.JavaOpts); len(extra) > 0 {
		cmd = append(cmd, "--java-opts", b.Config.JavaOpts)
	}
	cmd = append(cmd, b.sources()...)
	fmt.Fprintf(b.Log, "[refactor] 使っていない use を flixlint で探します（ログ %s）\n", rel(log))
	start := time.Now()
	// 違反があれば 1・無ければ 0。ほかは流せていない（規則がコンパイルできない・ソースが通らない・環境）。
	code := b.Run(Resolved, "flixlint --rules unused-use", b.Root, cmd, log)
	if code != 0 && code != 1 {
		return nil, fmt.Errorf("flixlint の終了コード %d（%s）", code, rel(log))
	}
	found := parseUnusedUses(logText(log))
	var lines []string
	for _, f := range found {
		lines = append(lines, fmt.Sprintf("%s:%d: unused-use: %s: brings in %s, which the module never uses", f.File, f.Line, f.Module, f.Name))
	}
	if err := os.WriteFile(tsvPath, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		return nil, err
	}
	key = joinKey(src+" unused-use "+unusedUseRules, b.envKey())
	if err := os.WriteFile(keyPath, []byte(fmt.Sprintf("%s %.1f\n", key, time.Since(start).Seconds())), 0o644); err != nil {
		return nil, err
	}
	return found, nil
}
