package flow

// flow（e2e/<名前>.flow）を JVM なしで読む check。決まりと文面は engine_world/src/Flow/Parse.flix と同じ
// （片方だけ直さない —— testdata/flow/ の例を両方のテストが読む）。名前の一覧はゲームが書き出した e2e/vocab.json。

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Vocab は e2e/vocab.json（Flow.vocabJson が書く）。
type Vocab struct {
	Verbs    []string            `json:"verbs"`
	Settings []string            `json:"settings"`
	Options  map[string][]string `json:"options"`
	Roles    []string            `json:"roles"`
	Probes   []struct {
		Name string `json:"name"`
		Kind string `json:"kind"`
		Doc  string `json:"doc"`
	} `json:"probes"`
	Drives []struct {
		Name string `json:"name"`
	} `json:"drives"`
	Starts []struct {
		Name string `json:"name"`
	} `json:"starts"`
	Keys        []string `json:"keys"`
	Ready       bool     `json:"ready"`
	Replies     bool     `json:"replies"`
	Fingerprint bool     `json:"fingerprint"`
}

// LoadVocab は vocab.json を読む。
func LoadVocab(path string) (Vocab, error) {
	var v Vocab
	data, err := os.ReadFile(path)
	if err != nil {
		return v, err
	}
	if err := json.Unmarshal(data, &v); err != nil {
		return v, fmt.Errorf("%s を読めない: %w", path, err)
	}
	return v, nil
}

// Problem は読めない行（Number は 1 から。0 = ファイルそのもの）。
type Problem struct {
	File   string
	Number int
	Text   string
	Why    string
}

// ProblemsText は Flow.Parse.problemsText と同じ形。
func ProblemsText(ps []Problem) string {
	var b strings.Builder
	for i, p := range ps {
		if i > 0 {
			b.WriteString("\n")
		}
		fmt.Fprintf(&b, "%s:%d: %s", p.File, p.Number, p.Why)
		if p.Text != "" {
			b.WriteString("\n    " + p.Text)
		}
	}
	return b.String()
}

// CheckFile は path を読んで、読めない行を全部返す（run の先も同じフォルダから読む）。steps は読めた手の数。
func CheckFile(v Vocab, path string) (problems []Problem, steps int) {
	data, err := os.ReadFile(path)
	if err != nil {
		return []Problem{{File: path, Why: fmt.Sprintf("%s を読めない（%v）", path, err)}}, 0
	}
	c := &checker{vocab: v}
	c.lines(path, string(data), 0)
	if len(c.problems) == 0 && c.steps == 0 {
		c.problems = append(c.problems, Problem{Why: "手が 1 つも無い"})
	}
	return c.problems, c.steps
}

type checker struct {
	vocab    Vocab
	problems []Problem
	steps    int
}

func (c *checker) lines(file, text string, depth int) {
	for i, raw := range strings.Split(text, "\n") {
		body := strings.TrimSpace(stripComment(strings.TrimRight(raw, "\r")))
		if body == "" {
			continue
		}
		problem := func(why string) {
			c.problems = append(c.problems, Problem{File: file, Number: i + 1, Text: body, Why: why})
		}
		words := strings.Fields(body)
		if words[0] == "run" {
			if len(words) != 2 {
				problem("run は 'run <名前>.flow'")
				continue
			}
			path := siblingOf(file, words[1])
			if depth >= 8 {
				problem("run が 8 段より深い（自分を呼んでいないか）")
				continue
			}
			inner, err := os.ReadFile(path)
			if err != nil {
				problem(fmt.Sprintf("run の先 %s を読めない: %s を読めない", path, path))
				continue
			}
			c.lines(path, string(inner), depth+1)
			continue
		}
		isStep, why := c.line(depth, words)
		if why != "" {
			problem(why)
		} else if isStep {
			c.steps++
		}
	}
}

func siblingOf(file, name string) string {
	if i := strings.LastIndex(file, "/"); i >= 0 {
		return file[:i] + "/" + name
	}
	return name
}

func stripComment(line string) string {
	if i := strings.Index(line, "#"); i >= 0 {
		return line[:i]
	}
	return line
}

func number(text string) (float64, string) {
	f, err := strconv.ParseFloat(text, 64)
	if err != nil {
		return 0, fmt.Sprintf("'%s' は数でない", text)
	}
	return f, ""
}

// line は 1 行を確かめる: 手なら true・設定なら false・読めなければ理由。
func (c *checker) line(depth int, w []string) (bool, string) {
	v := c.vocab
	verb := w[0]
	n := len(w)
	switch {
	case verb == "fps" && n == 2:
		_, why := number(w[1])
		return false, why
	case verb == "fps":
		return false, "fps は 'fps <数>'"
	case verb == "ready" && n == 2:
		switch w[1] {
		case "on":
			if v.Ready {
				return false, ""
			}
			return false, "ready on はゲームが ready を宣言していない（App.withFlow の ready）"
		case "off":
			return false, ""
		default:
			return false, fmt.Sprintf("ready は on か off（'%s'）", w[1])
		}
	case verb == "start" && n >= 2:
		if depth > 0 {
			return true, "run の先では start を書かない（始まりは呼ぶ側で）"
		}
		if why := nameIn("始まり", w[1], v.startNames()); why != "" {
			return true, why
		}
		return true, argsAndFiles(w[2:])
	case verb == "tap" && n >= 2, verb == "release" && n >= 2:
		if why := c.target(w[1]); why != "" {
			return true, why
		}
		return true, opts(w[2:])
	case verb == "hold" && n >= 2:
		if why := c.target(w[1]); why != "" {
			return true, why
		}
		rest := w[2:]
		if len(rest) > 0 && isSpanWord(rest[0]) {
			rest = rest[1:]
		}
		return true, opts(rest)
	case verb == "wait" && n >= 2:
		if why := span(w[1]); why != "" {
			return true, why
		}
		return true, opts(w[2:])
	case verb == "until" && n == 4 && w[2] == "max":
		if why := c.expr(w[1]); why != "" {
			return true, why
		}
		_, why := number(w[3])
		return true, why
	case verb == "until":
		return true, "until は 'until <問い> max <秒>'（max は必須）"
	case verb == "drive" && n == 6 && w[2] == "until" && w[4] == "max":
		if why := nameIn("操作", w[1], v.driveNames()); why != "" {
			return true, why
		}
		if why := c.expr(w[3]); why != "" {
			return true, why
		}
		_, why := number(w[5])
		return true, why
	case verb == "drive":
		return true, "drive は 'drive <操作> until <問い> max <秒>'（max は必須）"
	case verb == "expect" && n == 2:
		return true, c.expr(w[1])
	case verb == "expect":
		return true, "expect は 'expect <問い>'"
	case verb == "mark" && n == 2:
		return true, ""
	case verb == "mark":
		return true, "mark は 'mark <名前>'"
	case verb == "reload" && n >= 2:
		for _, word := range w[2:] {
			if !strings.HasPrefix(word, "+") {
				return true, "reload の後ろはファイル（+パス=b64:…）だけ"
			}
		}
		return true, argsAndFiles(w[2:])
	case verb == "request" && n >= 2:
		return true, argsAndFiles(w[2:])
	case verb == "close" && n == 1:
		return true, ""
	case verb == "rewind" && n == 2:
		if k, err := strconv.Atoi(w[1]); err != nil || k < 0 {
			return true, "rewind は 'rewind <フレーム数>'"
		}
		return true, ""
	case verb == "idle" && n == 2:
		return true, fmt.Sprintf("idle は無い。'wait %sf' と書く（N フレーム何も触らない）", w[1])
	case verb == "press" && n == 2:
		return true, fmt.Sprintf("press は無い。'tap %s' と書く", w[1])
	}
	if allowed, ok := v.Options[verb]; ok && n == 2 {
		if len(allowed) == 0 || contains(allowed, w[1]) {
			return false, ""
		}
		return false, fmt.Sprintf("設定 %s の値 '%s' は無い%s", verb, w[1], Hint(w[1], allowed))
	}
	known := append(append(append([]string{}, v.Verbs...), v.Settings...), v.optionNames()...)
	if contains(known, verb) {
		return true, fmt.Sprintf("'%s' の書き方が違う", verb)
	}
	return true, fmt.Sprintf("手 '%s' は無い%s", verb, Hint(verb, known))
}

func nameIn(kind, name string, known []string) string {
	if contains(known, name) {
		return ""
	}
	return fmt.Sprintf("%s '%s' は無い%s", kind, name, Hint(name, known))
}

func isSpanWord(word string) bool {
	return !strings.Contains(word, "=") && span(word) == ""
}

func span(text string) string {
	if strings.HasSuffix(text, "f") {
		if _, err := strconv.Atoi(strings.TrimSuffix(text, "f")); err != nil {
			return fmt.Sprintf("'%s' はフレーム数でない（30f のように）", text)
		}
		return ""
	}
	if _, why := number(text); why != "" {
		return fmt.Sprintf("長さ '%s' は秒（0.5）かフレーム数（30f）", text)
	}
	return ""
}

func (c *checker) target(text string) string {
	v := c.vocab
	if contains(v.Roles, text) {
		return ""
	}
	parts := strings.Split(text, ",")
	if len(parts) == 2 {
		if _, err := strconv.ParseFloat(parts[0], 64); err == nil {
			if _, why := number(parts[1]); why != "" {
				return why
			}
			return ""
		}
	}
	if keySet(v, text) == "" {
		return ""
	}
	return fmt.Sprintf("役かキー '%s' は無い%s", text, Hint(text, append(append([]string{}, v.Roles...), v.Keys...)))
}

func keySet(v Vocab, text string) string {
	if text == "-" {
		return ""
	}
	for _, name := range strings.Split(text, ",") {
		if !containsFold(v.Keys, name) {
			return fmt.Sprintf("キー '%s' は無い", name)
		}
	}
	return ""
}

func opts(words []string) string {
	known := []string{"ns=", "dt=", "at=", "mouse", "wheel=", "pad", "keys=", "new=", "click", "moved"}
	for _, word := range words {
		switch {
		case word == "mouse", word == "pad", word == "click", word == "noclick", word == "moved", word == "still":
		case strings.HasPrefix(word, "ns="):
			for _, part := range strings.Split(strings.TrimPrefix(word, "ns="), ",") {
				if _, err := strconv.ParseInt(part, 10, 64); err != nil {
					return fmt.Sprintf("ns= はナノ秒の整数の列（'%s'）", part)
				}
			}
		case strings.HasPrefix(word, "dt="):
			if _, why := number(strings.TrimPrefix(word, "dt=")); why != "" {
				return why
			}
		case strings.HasPrefix(word, "wheel="):
			if _, why := number(strings.TrimPrefix(word, "wheel=")); why != "" {
				return why
			}
		case strings.HasPrefix(word, "keys="), strings.HasPrefix(word, "new="):
		case strings.HasPrefix(word, "at="):
			xy := strings.Split(strings.TrimPrefix(word, "at="), ",")
			if len(xy) != 2 {
				return "at は at=x,y"
			}
			for _, part := range xy {
				if _, why := number(part); why != "" {
					return why
				}
			}
		default:
			return fmt.Sprintf("付け足し '%s' は無い%s", word, Hint(word, known))
		}
	}
	return ""
}

// expr は問いの式を確かめる（Flow.Parse.exprOf と同じ順: & → ! → 比べ → 真偽の名前）。
func (c *checker) expr(text string) string {
	if i := strings.Index(text, "&"); i >= 0 {
		if why := c.expr(text[:i]); why != "" {
			return why
		}
		return c.expr(text[i+1:])
	}
	if strings.HasPrefix(text, "!") {
		return c.expr(text[1:])
	}
	if name, op, value, ok := splitCompare(text); ok {
		kind, why := c.kind(name)
		if why != "" {
			return why
		}
		switch kind {
		case "num":
			if _, why := number(value); why != "" {
				return fmt.Sprintf("数の問い %s と比べる値 '%s' が数でない", name, value)
			}
		case "text":
			if op != "=" && op != "!=" {
				return fmt.Sprintf("文字の問い %s は = か != で比べる", name)
			}
		case "flag":
			return fmt.Sprintf("真偽の問い %s は比べずに書く（%s か !%s）", name, name, name)
		}
		return ""
	}
	kind, why := c.kind(text)
	if why != "" {
		return why
	}
	if kind != "flag" {
		return fmt.Sprintf("問い %s は真偽でない。比べて書く（%s=… / %s>=…）", text, text, text)
	}
	return ""
}

func (c *checker) kind(name string) (string, string) {
	v := c.vocab
	if name == "fp" && v.Fingerprint {
		return "text", ""
	}
	var known []string
	for _, p := range v.Probes {
		if p.Name == name {
			return p.Kind, ""
		}
		known = append(known, p.Name)
	}
	if v.Fingerprint {
		known = append(known, "fp")
	}
	return "", fmt.Sprintf("問い '%s' は無い%s", name, Hint(name, known))
}

// splitCompare は "lines>=4" を (名前, 記号, 値) に分ける。一番前の記号（同じ位置なら長い方）。
func splitCompare(text string) (string, string, string, bool) {
	best, bestSymbol := -1, ""
	for _, symbol := range []string{"<=", ">=", "!=", "<", ">", "="} {
		if i := strings.Index(text, symbol); i >= 0 {
			if best < 0 || i*10-len(symbol) < best*10-len(bestSymbol) {
				best, bestSymbol = i, symbol
			}
		}
	}
	if best < 0 {
		return "", "", "", false
	}
	return text[:best], bestSymbol, text[best+len(bestSymbol):], true
}

func argsAndFiles(words []string) string {
	for _, word := range words {
		if strings.HasPrefix(word, "+") {
			body := word[1:]
			i := strings.Index(body, "=")
			if i <= 0 {
				return "ファイルは +パス=b64:中身 か +パス=missing"
			}
			if value := body[i+1:]; value != "missing" {
				if why := decoded(value); why != "" {
					return why
				}
			}
			continue
		}
		i := strings.Index(word, "=")
		if i <= 0 {
			return fmt.Sprintf("引数 '%s' は key=value で書く", word)
		}
		if why := decoded(word[i+1:]); why != "" {
			return why
		}
	}
	return ""
}

func decoded(value string) string {
	if strings.HasPrefix(value, "b64:") {
		if _, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(value, "b64:")); err != nil {
			return "b64: の中身を戻せない"
		}
	}
	return ""
}

func (v Vocab) startNames() []string {
	var out []string
	for _, s := range v.Starts {
		out = append(out, s.Name)
	}
	return out
}

func (v Vocab) driveNames() []string {
	var out []string
	for _, d := range v.Drives {
		out = append(out, d.Name)
	}
	return out
}

func (v Vocab) optionNames() []string {
	var out []string
	for name := range v.Options {
		out = append(out, name)
	}
	return out
}

func contains(xs []string, x string) bool {
	for _, y := range xs {
		if y == x {
			return true
		}
	}
	return false
}

func containsFold(xs []string, x string) bool {
	for _, y := range xs {
		if strings.EqualFold(y, x) {
			return true
		}
	}
	return false
}

// StaleVocab は vocab.json が src/ の .flix より古ければ、そう言う 1 行（新しければ ""）。
func StaleVocab(root, vocabPath string) string {
	info, err := os.Stat(vocabPath)
	if err != nil {
		return ""
	}
	newest := ""
	_ = filepath.WalkDir(filepath.Join(root, "src"), func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".flix") {
			return nil
		}
		if fi, err := d.Info(); err == nil && fi.ModTime().After(info.ModTime()) && newest == "" {
			newest = path
		}
		return nil
	})
	if newest == "" {
		return ""
	}
	rel, _ := filepath.Rel(root, newest)
	return fmt.Sprintf("注意: %s は %s より古い（語彙を書き直すなら make flow-vocab）", vocabPath, rel)
}

