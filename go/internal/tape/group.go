package tape

import (
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Branch は頁の TAPE.branches の 1 つ（同じ行の選択肢で、テープごとに選んだ道が分かれた所）。
type Branch struct {
	T        float64 `json:"t"`
	Line     int     `json:"line"`
	Question string  `json:"question"`
	Routes   []Route `json:"routes"`
}

// Route は分岐の道 1 つ。Here = この頁が撮った道、Href = その道を撮った隣のテープ（無ければ空）。
type Route struct {
	Label string `json:"label"`
	Note  string `json:"note"`
	Here  bool   `json:"here"`
	Href  string `json:"href,omitempty"`
}

// questionRunes は分岐のカードに出す問いの字の数の上限（行の番号と並べて、スマホの幅のカードの 1 行に収める）。
const questionRunes = 14

// GroupBranches は同じ始まりから撮った複数のテープ（並びは names と同じ）から、各テープの branches を作る。
// 同じ行の選択肢を 2 本以上のテープが通り、選んだ番号が分かれた所だけを分岐にする。names はフォルダ名（隣の頁への道に使う）。
// 1 本のテープが同じ行の選択肢を 2 回以上通った時は最後の 1 回を使う。
// WhyNot: 最初の 1 回を使わない — 選択肢へ戻って選び直す作りでは、先へ進んだ道（最後に選んだ方）がそのテープの道になる。
func GroupBranches(names []string, tapes []*Tape) [][]Branch {
	type pick struct {
		tape   int
		choice Choice
	}
	byLine := map[int][]pick{}
	for i, t := range tapes {
		last := map[int]Choice{}
		for _, ch := range t.Choices {
			last[ch.Line] = ch
		}
		for ln, ch := range last {
			byLine[ln] = append(byLine[ln], pick{i, ch})
		}
	}
	for ln := range byLine {
		sort.Slice(byLine[ln], func(a, b int) bool { return byLine[ln][a].tape < byLine[ln][b].tape })
	}
	out := make([][]Branch, len(tapes))
	for i := range out {
		out[i] = []Branch{}
	}
	lines := make([]int, 0, len(byLine))
	for ln := range byLine {
		lines = append(lines, ln)
	}
	sort.Ints(lines)
	for _, ln := range lines {
		picks := byLine[ln]
		firstBy := map[int]pick{}
		for _, p := range picks {
			if _, ok := firstBy[p.choice.Picked]; !ok {
				firstBy[p.choice.Picked] = p
			}
		}
		if len(firstBy) < 2 {
			continue
		}
		for _, p := range picks {
			routes := make([]Route, len(p.choice.Options))
			for j, label := range p.choice.Options {
				r := Route{Label: label, Note: "まだ撮っていない"}
				if j == p.choice.Picked {
					r.Here, r.Note = true, "このテープ"
				} else if other, ok := firstBy[j]; ok {
					// WhyNot: 「../<フォルダ>/#t=」にしない — file:// で開いた頁ではフォルダの道が index.html を開かない。
					r.Href = "../" + url.PathEscape(names[other.tape]) + "/" + IndexFile + "#t=" + strconv.FormatFloat(other.choice.T, 'f', -1, 64)
					r.Note = names[other.tape] + " のテープ"
				}
				routes[j] = r
			}
			out[p.tape] = append(out[p.tape], Branch{T: p.choice.T, Line: ln, Question: tapes[p.tape].questionOf(p.choice), Routes: routes})
		}
	}
	for i := range out {
		sort.SliceStable(out[i], func(a, b int) bool { return out[i][a].T < out[i][b].T })
	}
	return out
}

// questionOf は分岐のカードに出す問い。ゲームが書いた question（選択肢を出していた時の台詞）が無ければ、
// timeline で選択肢が出る直前の台詞を使い、それも無ければノードの名前。最初の文を、カードの 1 行に収まる長さで返す。
func (t *Tape) questionOf(ch Choice) string {
	text := ch.Question
	if text == "" {
		text = t.textBefore(ch.T)
	}
	if text == "" {
		return ch.Node
	}
	text = strings.ReplaceAll(text, "／", "")
	if i := strings.IndexAny(text, "。！？"); i > 0 {
		text = text[:i]
	}
	if rs := []rune(text); len(rs) > questionRunes {
		return string(rs[:questionRunes-1]) + "…"
	}
	return text
}

// textBefore は timeline で sec より前に出ていた最後の台詞の字（無ければ空）。
func (t *Tape) textBefore(sec float64) string {
	text := ""
	for _, r := range t.timeline {
		if r.T >= sec-1e-6 {
			break
		}
		if l, ok := t.lines[r.Line]; ok && l.Text != nil {
			text = *l.Text
		}
	}
	return text
}

// BuildGroup は複数のテープのフォルダを、互いの分岐をつないだ頁にする（各フォルダの index.html の道を返す）。
// 同じ game・同じ .yarn のテープだけを束ねる。フォルダ名は隣の頁への道になるので重ねない。
// 分岐が 1 つもできなかった時は warn に 1 行言う（頁は作る）。
func BuildGroup(dirs []string, commit, ffmpeg string, warn io.Writer) ([]string, error) {
	if len(dirs) < 2 {
		return nil, fmt.Errorf("--group には 2 つ以上のフォルダが要る（1 つなら --dir）")
	}
	names := make([]string, len(dirs))
	tapes := make([]*Tape, len(dirs))
	seen := map[string]string{}
	for i, d := range dirs {
		names[i] = filepath.Base(filepath.Clean(d))
		if prev, ok := seen[names[i]]; ok {
			return nil, fmt.Errorf("フォルダ名 %s が 2 つある（%s と %s）。隣の頁への道はフォルダ名で引くので、名前を分ける", names[i], prev, d)
		}
		seen[names[i]] = d
		raw, err := os.ReadFile(filepath.Join(d, TapeFile))
		if err != nil {
			return nil, fmt.Errorf("%s を読めない（ゲームの make tape が書く）: %w", filepath.Join(d, TapeFile), err)
		}
		if tapes[i], err = Parse(raw); err != nil {
			return nil, fmt.Errorf("%s: %w", d, err)
		}
		if tapes[i].Game != tapes[0].Game || tapes[i].Yarn != tapes[0].Yarn {
			return nil, fmt.Errorf("%s は %s と別のゲームか別のシナリオ（game %q・yarn %q と game %q・yarn %q）。同じ始まりのテープだけを束ねる",
				d, dirs[0], tapes[i].Game, tapes[i].Yarn, tapes[0].Game, tapes[0].Yarn)
		}
	}
	branches := GroupBranches(names, tapes)
	if total := countBranches(branches); total == 0 && warn != nil {
		fmt.Fprintf(warn, "tape: 分岐が 1 つもできなかった（同じ行の選択肢で、別の番号を選んだテープが無い。flow ごとに違う選択肢を選んでいるか、tape.json の choices を確かめる）\n")
	}
	out := make([]string, len(dirs))
	for i, d := range dirs {
		b := branches[i]
		index, err := build(Options{Dir: d, Commit: commit, FFmpeg: ffmpeg, Branches: &b}, tapes[i])
		if err != nil {
			return nil, fmt.Errorf("%s: %w", d, err)
		}
		out[i] = index
	}
	return out, nil
}

func countBranches(branches [][]Branch) int {
	n := 0
	for _, b := range branches {
		n += len(b)
	}
	return n
}
