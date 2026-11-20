package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// webApplyDeferredNote は project.json の web の "// deferred" に足す 1 文。
const webApplyDeferredNote = "export-web --apply-deferred で、タイトルの間に使わなかった起動の素材を足した。"

// applyDeferredToProject は project.json（file）の web.deferred と web.deferredFonts の後ろへ globs と fonts を足す
// （もうある物は足さない）。足した物が無ければ false。字の並びと他の欄はそのまま残す。
// WhyNot: 読んで組み直して書かない — 鍵の並び・字下げ・"// " の説明の位置が全部変わり、git の差分で何を足したか読めなくなる。
func applyDeferredToProject(file string, globs, fonts []string) (bool, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return false, err
	}
	next, changed, err := withDeferredAppended(data, globs, fonts)
	if err != nil || !changed {
		return false, err
	}
	var check map[string]any
	if err := json.Unmarshal(next, &check); err != nil {
		return false, fmt.Errorf("書き換えた project.json が JSON にならない（書かずに止めた）: %v", err)
	}
	return true, os.WriteFile(file, next, 0o644)
}

// withDeferredAppended は project.json の字 data に、web.deferred・web.deferredFonts・web の "// deferred" の説明を足した字を返す。
func withDeferredAppended(data []byte, globs, fonts []string) ([]byte, bool, error) {
	changed := false
	for _, step := range []struct {
		key   string
		items []string
	}{{"deferred", globs}, {"deferredFonts", fonts}} {
		if len(step.items) == 0 {
			continue
		}
		next, did, err := appendWebArray(data, step.key, step.items)
		if err != nil {
			return nil, false, err
		}
		data, changed = next, changed || did
	}
	if !changed {
		return data, false, nil
	}
	next, err := withDeferredNote(data)
	return next, true, err
}

// jsonMember は object の中の 1 つの鍵の値の場所（data の中の [Start, End)）。
type jsonMember struct {
	Key        string
	Start, End int
}

// jsonObjectAt は data[at] の '{' から始まる object の鍵と値の場所、閉じの '}' の場所を返す。
func jsonObjectAt(data []byte, at int) ([]jsonMember, int, error) {
	dec := json.NewDecoder(bytes.NewReader(data[at:]))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		return nil, 0, fmt.Errorf("%d 字目が object でない", at)
	}
	var members []jsonMember
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return nil, 0, err
		}
		key, _ := tok.(string)
		start := at + int(dec.InputOffset())
		var skip json.RawMessage
		if err := dec.Decode(&skip); err != nil {
			return nil, 0, err
		}
		end := at + int(dec.InputOffset())
		start += valueStartIn(data[start:end])
		members = append(members, jsonMember{Key: key, Start: start, End: end})
	}
	if _, err := dec.Token(); err != nil {
		return nil, 0, err
	}
	return members, at + int(dec.InputOffset()) - 1, nil
}

// valueStartIn は鍵の後ろ（': ' を含む）から値の最初の字までの字数。
func valueStartIn(b []byte) int {
	for i, c := range b {
		if c != ' ' && c != '\t' && c != '\n' && c != '\r' && c != ':' {
			return i
		}
	}
	return len(b)
}

func findMember(members []jsonMember, key string) (jsonMember, bool) {
	for _, m := range members {
		if m.Key == key {
			return m, true
		}
	}
	return jsonMember{}, false
}

// withWebObject は project.json の字と、その中の web の値の場所を返す。web が無ければ足した字を返す。
func withWebObject(data []byte) ([]byte, jsonMember, error) {
	root := bytes.IndexByte(data, '{')
	if root < 0 {
		return nil, jsonMember{}, errors.New("project.json が object でない")
	}
	members, end, err := jsonObjectAt(data, root)
	if err != nil {
		return nil, jsonMember{}, fmt.Errorf("project.json を読めない: %v", err)
	}
	if web, ok := findMember(members, "web"); ok {
		if data[web.Start] != '{' {
			return nil, jsonMember{}, errors.New("project.json の web が object でない")
		}
		return data, web, nil
	}
	next := insertMember(data, members, end, "web", "{}")
	return withWebObject(next)
}

// appendWebArray は web.<key> の配列の後ろへ items のうち無い物を足す。配列が無ければ web の最後の鍵の後ろに作る。
func appendWebArray(data []byte, key string, items []string) ([]byte, bool, error) {
	data, web, err := withWebObject(data)
	if err != nil {
		return nil, false, err
	}
	members, end, err := jsonObjectAt(data, web.Start)
	if err != nil {
		return nil, false, err
	}
	arr, ok := findMember(members, key)
	if !ok {
		return insertMember(data, members, end, key, "["+quotedList(items)+"]"), true, nil
	}
	var have []string
	if err := json.Unmarshal(data[arr.Start:arr.End], &have); err != nil {
		return nil, false, fmt.Errorf("project.json の web.%s が字の配列でない: %v", key, err)
	}
	seen := map[string]bool{}
	for _, h := range have {
		seen[h] = true
	}
	var add []string
	for _, it := range items {
		if !seen[it] {
			seen[it] = true
			add = append(add, it)
		}
	}
	if len(add) == 0 {
		return data, false, nil
	}
	if len(have) == 0 {
		return splice(data, arr.Start, arr.End, "["+quotedList(add)+"]"), true, nil
	}
	body := data[arr.Start:arr.End]
	last := bytes.LastIndexByte(body[:len(body)-1], '"') + 1
	var ins strings.Builder
	if bytes.IndexByte(body, '\n') >= 0 {
		indent := lineIndent(data, arr.Start+1+valueStartIn(body[1:]))
		for _, it := range add {
			fmt.Fprintf(&ins, ",\n%s%s", indent, jsonString(it))
		}
	} else {
		for _, it := range add {
			fmt.Fprintf(&ins, ", %s", jsonString(it))
		}
	}
	at := arr.Start + last
	return splice(data, at, at, ins.String()), true, nil
}

// withDeferredNote は web の "// deferred" の説明に webApplyDeferredNote を足す（もう書いてあれば何もしない）。説明が無ければ deferred の前に作る。
func withDeferredNote(data []byte) ([]byte, error) {
	_, web, err := withWebObject(data)
	if err != nil {
		return nil, err
	}
	members, _, err := jsonObjectAt(data, web.Start)
	if err != nil {
		return nil, err
	}
	if note, ok := findMember(members, "// deferred"); ok {
		var text string
		if json.Unmarshal(data[note.Start:note.End], &text) != nil || strings.Contains(text, "--apply-deferred") {
			return data, nil
		}
		sep := ""
		if text != "" && !strings.HasSuffix(text, "。") {
			sep = "。"
		}
		return splice(data, note.Start, note.End, jsonString(text+sep+webApplyDeferredNote)), nil
	}
	target, ok := findMember(members, "deferred")
	if !ok {
		target, ok = findMember(members, "deferredFonts")
	}
	if !ok {
		return data, nil
	}
	keyAt := bytes.LastIndexByte(data[:target.Start], '"')
	keyAt = bytes.LastIndexByte(data[:keyAt], '"')
	indent := lineIndent(data, keyAt)
	return splice(data, keyAt, keyAt, "\"// deferred\": "+jsonString(webApplyDeferredNote)+",\n"+indent), nil
}

// insertMember は object（閉じの '}' が end）の最後に "key": value を足す。字下げは最後の鍵の行に合わせる。
func insertMember(data []byte, members []jsonMember, end int, key, value string) []byte {
	if len(members) == 0 {
		open := bytes.LastIndexByte(data[:end], '{')
		outer := lineIndent(data, open)
		return splice(data, open+1, end, fmt.Sprintf("\n%s  %s: %s\n%s", outer, jsonString(key), value, outer))
	}
	last := members[len(members)-1]
	keyAt := bytes.LastIndexByte(data[:last.Start], '"')
	keyAt = bytes.LastIndexByte(data[:keyAt], '"')
	indent := lineIndent(data, keyAt)
	return splice(data, last.End, last.End, fmt.Sprintf(",\n%s%s: %s", indent, jsonString(key), value))
}

// lineIndent は data[at] のある行の頭の空白。
func lineIndent(data []byte, at int) string {
	start := bytes.LastIndexByte(data[:at], '\n') + 1
	end := start
	for end < len(data) && (data[end] == ' ' || data[end] == '\t') {
		end++
	}
	return string(data[start:end])
}

func splice(data []byte, from, to int, text string) []byte {
	out := make([]byte, 0, len(data)+len(text))
	out = append(out, data[:from]...)
	out = append(out, text...)
	return append(out, data[to:]...)
}

// writeAppliedDeferred は --apply-deferred の結果を書く。
func writeAppliedDeferred(w io.Writer, file string, changed bool, s webDeferredSuggestion) {
	if !changed {
		fmt.Fprintf(w, "  --apply-deferred: %s に足す物は無かった\n", file)
		return
	}
	fmt.Fprintf(w, "  --apply-deferred: %s の web.deferred に %d 本・web.deferredFonts に %d 本を足した（差分は git diff で見る）。\n"+
		"    次: もう一度 export-web で書き出すと後回しで配られる。タイトルの直後に使う物が届く前に黒い・鳴らないなら、その物を外す\n",
		file, len(s.Globs), len(s.Fonts))
}
