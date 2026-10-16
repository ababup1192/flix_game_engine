package notesrotate

// notes-rotate — NOTES.md の先頭（引き継ぎ）を短く保つ。先頭から数えて keepEntries 個・
// または maxLines 行を超えた古い項を、項の日付の月ごとに notes/<年-月>.md へ送る（捨てない）。
//
//	fge-go notes-rotate              送る（NOTES.md と notes/<年-月>.md を書き換える）
//	fge-go notes-rotate --dry-run    送る項を出すだけ（何も書かない）
//	fge-go notes-rotate --check      超えていたら終了コード 1
//	fge-go notes-rotate --check --staged  作業ツリーではなくステージした NOTES.md を見る（コミット時のゲートはこれ）
//	fge-go notes-rotate --root DIR   リポジトリのルートを差し替える
//
// 項の読み方: 規約データの entryPatterns のどれかに当たる行が項の始まり（1 つ目の () が年・2 つ目が月）。
// 最初の項より前の行は見出し（make status が読む所）としてそのまま残す。項の後ろの行は、次の項の始まりまで
// その項の本文。送る項の末尾に残った「本文の無い見出しの行」（# NOTES のような区切り）は送らずに落とし、
// 落とした行は出力に名指しする。
//
// 日付の行（entryPatterns）に当たらない行は前の項の本文なので、項は必ず月を持つ。
// WhyNot: コミット時に自動で送らず止めるだけなのは、ステージした中身とゲートが書き換えた中身が
// 食い違ったままコミットされるため。直す口（このコマンド）を名指しして止める。

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// RulesPath は規約データの置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "notes-rotate.json")

type rulesFile struct {
	NotesFile     *string   `json:"notesFile"`
	ArchiveDir    *string   `json:"archiveDir"`
	KeepEntries   *int      `json:"keepEntries"`
	MaxLines      *int      `json:"maxLines"`
	EntryPatterns *[]string `json:"entryPatterns"`
	ArchiveHeader *string   `json:"archiveHeader"`
}

// Rules は検査が使う規約。すべて JSON から来る。
type Rules struct {
	NotesFile     string
	ArchiveDir    string
	KeepEntries   int
	MaxLines      int
	EntryPatterns []*regexp.Regexp
	// ArchiveHeader は新しい月のファイルの 1 行目。{month} が「2026-10」に替わる。
	ArchiveHeader string
}

// LoadRules は規約データを読む。
// WhyNot: 読めないときに既定値で続けないのは、閾値を消しただけで何も言わずに送らなくなるため。
func LoadRules(root string) (*Rules, error) {
	path := filepath.Join(root, RulesPath)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("規約ファイルを読めません: %v", err)
	}
	var f rulesFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("%s が壊れています: %v", RulesPath, err)
	}
	missing := ""
	switch {
	case f.NotesFile == nil:
		missing = "notesFile"
	case f.ArchiveDir == nil:
		missing = "archiveDir"
	case f.KeepEntries == nil:
		missing = "keepEntries"
	case f.MaxLines == nil:
		missing = "maxLines"
	case f.EntryPatterns == nil:
		missing = "entryPatterns"
	case f.ArchiveHeader == nil:
		missing = "archiveHeader"
	}
	if missing != "" {
		return nil, fmt.Errorf("%s に %s がありません", RulesPath, missing)
	}
	if *f.KeepEntries < 1 || *f.MaxLines < 1 {
		return nil, fmt.Errorf("%s の keepEntries と maxLines は 1 以上", RulesPath)
	}
	r := &Rules{
		NotesFile: *f.NotesFile, ArchiveDir: *f.ArchiveDir,
		KeepEntries: *f.KeepEntries, MaxLines: *f.MaxLines, ArchiveHeader: *f.ArchiveHeader,
	}
	for _, p := range *f.EntryPatterns {
		re, err := regexp.Compile(p)
		if err != nil {
			return nil, fmt.Errorf("%s の entryPatterns が壊れています: %v", RulesPath, err)
		}
		if re.NumSubexp() < 2 {
			return nil, fmt.Errorf("%s の entryPatterns %q は () が 2 つ要る（年・月）", RulesPath, p)
		}
		r.EntryPatterns = append(r.EntryPatterns, re)
	}
	return r, nil
}

// Entry は NOTES.md の項 1 つ。Month は「2026-10」。
type Entry struct {
	Month string
	Lines []string
}

// Parse は本文を見出し（最初の項より前）と項の列に分ける。
func Parse(text string, r *Rules) (head []string, entries []Entry) {
	lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
	for _, line := range lines {
		if month, ok := entryMonth(line, r); ok {
			entries = append(entries, Entry{Month: month, Lines: []string{line}})
			continue
		}
		if len(entries) == 0 {
			head = append(head, line)
		} else {
			last := &entries[len(entries)-1]
			last.Lines = append(last.Lines, line)
		}
	}
	return head, entries
}

func entryMonth(line string, r *Rules) (string, bool) {
	for _, re := range r.EntryPatterns {
		if m := re.FindStringSubmatch(line); m != nil {
			return m[1] + "-" + m[2], true
		}
	}
	return "", false
}

// Plan は送り方。Kept は残す項、Moved は送る項、Dropped は落とす区切りの見出しの行。
type Plan struct {
	Head    []string
	Kept    []Entry
	Moved   []Entry
	Dropped []string
}

// MakePlan は残す項を先頭から数えて決める。少なくとも 1 項は残す。
func MakePlan(text string, r *Rules) Plan {
	head, entries := Parse(text, r)
	lines := len(head)
	keep := 0
	for keep < len(entries) {
		n := len(trimTail(entries[keep].Lines))
		if keep >= 1 && (keep >= r.KeepEntries || lines+n > r.MaxLines) {
			break
		}
		lines += n + 1
		keep++
	}
	p := Plan{Head: head, Kept: append([]Entry{}, entries[:keep]...)}
	if keep < len(entries) && keep > 0 {
		// 残す最後の項の末尾の区切り（送る項の前に立っていた見出し）も、送った後は指す物が無い。
		last := &p.Kept[keep-1]
		body, dropped := stripSeparators(last.Lines)
		last.Lines = append(body, "")
		p.Dropped = append(p.Dropped, dropped...)
	}
	for _, e := range entries[keep:] {
		body, dropped := stripSeparators(e.Lines)
		p.Moved = append(p.Moved, Entry{Month: e.Month, Lines: body})
		p.Dropped = append(p.Dropped, dropped...)
	}
	return p
}

// Over は送る物があるか。
func (p Plan) Over() bool { return len(p.Moved) > 0 }

// trimTail は末尾の空行を落とす。
func trimTail(lines []string) []string {
	n := len(lines)
	for n > 1 && strings.TrimSpace(lines[n-1]) == "" {
		n--
	}
	return lines[:n]
}

// stripSeparators は項の末尾に付いた「本文の無い見出し」（# NOTES など。後ろの項の区切り）を落とす。
func stripSeparators(lines []string) (body, dropped []string) {
	n := len(lines)
	for n > 1 {
		s := strings.TrimSpace(lines[n-1])
		if s == "" {
			n--
			continue
		}
		if strings.HasPrefix(s, "#") {
			dropped = append(dropped, s)
			n--
			continue
		}
		break
	}
	return lines[:n], dropped
}

// RenderNotes は残した NOTES.md の本文を組む。
func (p Plan) RenderNotes() string {
	var out []string
	out = append(out, p.Head...)
	for _, e := range p.Kept {
		out = append(out, e.Lines...)
	}
	return strings.TrimRight(strings.Join(out, "\n"), "\n") + "\n"
}

// MergeArchive は送り先の月のファイルの今の中身（無ければ空）へ、送る項を前に足す。
// 送る項は月のファイルにある項より新しいので、見出しの直後に新しい順のまま入れる。
func MergeArchive(existing, month string, moved []Entry, r *Rules) string {
	var head []string
	var rest []Entry
	if strings.TrimSpace(existing) == "" {
		head = []string{strings.ReplaceAll(r.ArchiveHeader, "{month}", month), ""}
	} else {
		head, rest = Parse(existing, r)
	}
	var out []string
	out = append(out, head...)
	if len(head) > 0 && strings.TrimSpace(head[len(head)-1]) != "" {
		out = append(out, "")
	}
	for _, e := range moved {
		out = append(out, trimTail(e.Lines)...)
		out = append(out, "")
	}
	for _, e := range rest {
		out = append(out, e.Lines...)
	}
	return strings.TrimRight(strings.Join(out, "\n"), "\n") + "\n"
}

// Run は入口。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	mode := "write"
	staged := false
	for _, a := range args {
		switch a {
		case "--dry-run":
			mode = "dry"
		case "--check":
			mode = "check"
		case "--staged":
			staged = true
		default:
			fmt.Fprintf(errOut, "notes-rotate: 知らない引数 %s（--dry-run / --check [--staged] / --root DIR）\n", a)
			return 2, nil
		}
	}
	if staged && mode != "check" {
		fmt.Fprintln(errOut, "notes-rotate: --staged は --check と一緒にだけ使える（ステージした中身は書き換えない）")
		return 2, nil
	}
	r, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	notesPath := filepath.Join(root, r.NotesFile)
	var data []byte
	if staged {
		data, err = readStaged(root, r.NotesFile)
	} else {
		data, err = os.ReadFile(notesPath)
	}
	if os.IsNotExist(err) {
		fmt.Fprintf(out, "[notes-rotate] %s が無い（何もしない）\n", r.NotesFile)
		return 0, nil
	}
	if err != nil {
		return 2, err
	}
	p := MakePlan(string(data), r)
	if !p.Over() {
		fmt.Fprintf(out, "[notes-rotate] OK（%s の項 %d 個・上限 %d 個 / %d 行）\n",
			r.NotesFile, len(p.Kept), r.KeepEntries, r.MaxLines)
		return 0, nil
	}
	byMonth := map[string][]Entry{}
	for _, e := range p.Moved {
		byMonth[e.Month] = append(byMonth[e.Month], e)
	}
	months := make([]string, 0, len(byMonth))
	for m := range byMonth {
		months = append(months, m)
	}
	sort.Sort(sort.Reverse(sort.StringSlice(months)))

	if mode == "check" {
		fmt.Fprintf(out, "[notes-rotate] %s の先頭が長すぎる（項 %d 個を送る所。上限 %d 個 / %d 行）。"+
			"bin/fge notes-rotate で古い項を %s/<年-月>.md へ送ってからコミット\n",
			r.NotesFile, len(p.Moved), r.KeepEntries, r.MaxLines, r.ArchiveDir)
		return 1, nil
	}
	for _, m := range months {
		fmt.Fprintf(out, "[notes-rotate] %s/%s.md へ %d 項\n", r.ArchiveDir, m, len(byMonth[m]))
	}
	for _, d := range p.Dropped {
		fmt.Fprintf(out, "[notes-rotate] 区切りの見出しを落とす: %s\n", d)
	}
	if mode == "dry" {
		return 0, nil
	}
	for _, m := range months {
		path := filepath.Join(root, r.ArchiveDir, m+".md")
		existing, err := os.ReadFile(path)
		if err != nil && !os.IsNotExist(err) {
			return 2, err
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return 2, err
		}
		if err := os.WriteFile(path, []byte(MergeArchive(string(existing), m, byMonth[m], r)), 0o644); err != nil {
			return 2, err
		}
	}
	// WhyNot: 送り先を書いてから NOTES.md を書くのは、途中で止まっても項が消えず、二重に残るだけにするため。
	if err := os.WriteFile(notesPath, []byte(p.RenderNotes()), 0o644); err != nil {
		return 2, err
	}
	fmt.Fprintf(out, "[notes-rotate] %s は項 %d 個に\n", r.NotesFile, len(p.Kept))
	return 0, nil
}

// readStaged はステージした中身（git show :<rel>）を読む。ステージに無ければ os.ErrNotExist。
// WhyNot: コミットのゲートが作業ツリーを読むと、送った後の NOTES.md をステージし忘れても通り、
// 送る前の長い中身がコミットされるため。
func readStaged(root, rel string) ([]byte, error) {
	out, err := exec.Command("git", "-C", root, "show", ":"+filepath.ToSlash(rel)).Output()
	if err != nil {
		return nil, os.ErrNotExist
	}
	return out, nil
}
