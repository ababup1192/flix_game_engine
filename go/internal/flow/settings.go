package flow

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// 設定の行（fps・ready）は run で入れた先と元で 1 つを分け合い、後に書いた方が勝つ（Flow.Parse の Acc）。
// 部品の flow（run で入れる側）を単独でも流すと、親が決めていた設定が抜けて別の速さ・別の待ち方で流れる。

// flowSettings は 1 本の flow を run の先まで読み終えた時の設定と、run で入れた先（同じ木の中の全部）。
type flowSettings struct {
	values map[string]string // "fps" → "30"・"ready" → "off"（書いていなければ無い）
	runs   []string          // run で入れた先（filepath.Clean した道・入れた順・重なりなし）
}

var settingDefaults = map[string]string{"fps": "60", "ready": "on"}

// readSettings は path を run の先まで読み、設定と run の先を集める。読めない所は黙って飛ばす（読めない行は CheckFile が言う）。
func readSettings(path string) flowSettings {
	s := flowSettings{values: map[string]string{}}
	seen := map[string]bool{}
	var walk func(file string, depth int)
	walk = func(file string, depth int) {
		data, err := os.ReadFile(file)
		if err != nil || depth > 8 {
			return
		}
		for _, raw := range strings.Split(string(data), "\n") {
			words := asciiFields(trimASCII(stripComment(strings.TrimRight(raw, "\r"))))
			if len(words) != 2 {
				continue
			}
			switch words[0] {
			case "run":
				child := filepath.Clean(siblingOf(file, words[1]))
				if !seen[child] {
					seen[child] = true
					s.runs = append(s.runs, child)
				}
				walk(child, depth+1)
			case "fps":
				if f, err := strconv.ParseFloat(words[1], 64); err == nil {
					s.values["fps"] = strconv.FormatFloat(f, 'f', -1, 64)
				}
			case "ready":
				if words[1] == "on" || words[1] == "off" {
					s.values["ready"] = words[1]
				}
			}
		}
	}
	walk(path, 0)
	return s
}

func (s flowSettings) get(key string) string {
	if v, ok := s.values[key]; ok {
		return v
	}
	return settingDefaults[key]
}

// settingMismatches は、files のうち別の flow から run で入れられている物について、親が流す時の設定（fps・ready）と
// 単独で流した時の設定が違えば、子のファイルの問題として返す。親どうしで設定が違う時は子だけでは直せないので言わない。
func settingMismatches(files []string) map[string][]Problem {
	settings := map[string]flowSettings{}
	clean := map[string]string{}
	for _, f := range files {
		c := filepath.Clean(f)
		clean[c] = f
		settings[c] = readSettings(f)
	}
	parents := map[string][]string{}
	for _, f := range files {
		p := filepath.Clean(f)
		for _, child := range settings[p].runs {
			if _, standalone := settings[child]; standalone && child != p {
				parents[child] = append(parents[child], p)
			}
		}
	}
	out := map[string][]Problem{}
	children := make([]string, 0, len(parents))
	for child := range parents {
		children = append(children, child)
	}
	sort.Strings(children)
	for _, child := range children {
		ps := parents[child]
		sort.Strings(ps)
		var lines []string
		var diffs []string
		for _, key := range []string{"fps", "ready"} {
			want := settings[ps[0]].get(key)
			agreed := true
			for _, p := range ps[1:] {
				agreed = agreed && settings[p].get(key) == want
			}
			if have := settings[child].get(key); agreed && have != want {
				lines = append(lines, key+" "+want)
				diffs = append(diffs, fmt.Sprintf("%s は親で %s・単独で %s", key, want, have))
			}
		}
		if len(lines) == 0 {
			continue
		}
		file := clean[child]
		out[file] = append(out[file], Problem{File: file, Why: fmt.Sprintf(
			"%s から run で入れると設定が違う（%s）。単独でも流すので、この flow にも '%s' を書く",
			filepath.Base(ps[0]), strings.Join(diffs, "・"), strings.Join(lines, "' '"))})
	}
	return out
}
