// Package docrefs は、文書が指す Flix の名前・ファイル・行が今のリポに在るかを見る lint。
//
//	fge-go doc-refs                 見る文書を全部（make lint-doc-refs）
//	fge-go doc-refs <file.md> ...   名指しの文書だけ（コミット時はステージした .md。見る文書でない物は飛ばす）
//	fge-go doc-refs -v | --all      場所を全部画面に（既定は上位 limit 行・全部は fullOut のファイル）
//	fge-go doc-refs --json          1 件ずつ checkres の形
//	fge-go doc-refs --root DIR      リポジトリのルートを差し替える
//
// 見る文書は docDirs の下の .md と docFiles（在る物だけ）から skip を除いた物。拾うのは ` ` の中と
// 表の行の Mod.name・/ を含むパス・path:行（code は codes.go）。名前の索引は flixindex.go。
//
// 規約は bin/lint-rules/doc-refs.json。ゲームの doc-refs.local.json には skip（見ない文書のパスの並び。
// / で終わればその下の全部）だけを書ける。古い記録（notes/<年-月>.md・docs/gallery の README）を外すための物で、
// 1 か所ずつ外す道は持たない（指す先を直すか、消した物を記録に残すなら ~~消し線~~ で囲むか、文書ごと skip へ）。
package docrefs

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
	"github.com/ababup1192/flix_game_engine/go/internal/suggest"
)

// Name は規約ファイルの名前（bin/lint-rules/<Name>.json）。
const Name = "doc-refs"

// Rules は規約データ。
type Rules struct {
	Note             string   `json:"note"`
	DocDirs          []string `json:"docDirs"`
	DocFiles         []string `json:"docFiles"`
	Skip             []string `json:"skip"`
	Sources          []string `json:"sources"`
	SpansIndex       string   `json:"spansIndex"`
	PathSkipPrefixes []string `json:"pathSkipPrefixes"`
	FileExts         []string `json:"fileExts"`
	Limit            int      `json:"limit"`
	FullOut          string   `json:"fullOut"`

	fileExt map[string]bool
}

// LoadRules は規約とゲームの skip を読む。
func LoadRules(root string) (*Rules, error) {
	var r Rules
	rulesRel, localRel := lintconf.Paths(Name)
	body, err := os.ReadFile(filepath.Join(root, rulesRel))
	if err != nil {
		return nil, fmt.Errorf("規約ファイルを読めません: %v", err)
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return nil, fmt.Errorf("規約ファイルが JSON として壊れています (%s): %v", rulesRel, err)
	}
	if len(r.DocDirs)+len(r.DocFiles) == 0 || len(r.Sources) == 0 || len(r.FileExts) == 0 || r.Limit <= 0 || r.FullOut == "" {
		return nil, fmt.Errorf("%s には docDirs か docFiles・sources・fileExts・limit・fullOut が要ります", rulesRel)
	}
	local, err := os.ReadFile(filepath.Join(root, localRel))
	switch {
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return nil, fmt.Errorf("読めません (%s): %v", localRel, err)
	default:
		var keys map[string]json.RawMessage
		if err := json.Unmarshal(local, &keys); err != nil {
			return nil, fmt.Errorf("JSON として壊れています (%s): %v", localRel, err)
		}
		for k := range keys {
			if k != "note" && k != "skip" {
				return nil, fmt.Errorf("%s に書けるのは skip（見ない文書のパスの並び）だけです (%q)", localRel, k)
			}
		}
		var l struct {
			Skip []string `json:"skip"`
		}
		if err := json.Unmarshal(local, &l); err != nil {
			return nil, fmt.Errorf("JSON として壊れています (%s): %v", localRel, err)
		}
		r.Skip = append(r.Skip, l.Skip...)
	}
	r.fileExt = map[string]bool{}
	for _, e := range r.FileExts {
		r.fileExt[e] = true
	}
	return &r, nil
}

// skipped は文書 rel を見ないか（skip のパスと同じか、/ で終わる物の下）。
func (r *Rules) skipped(rel string) bool {
	for _, s := range r.Skip {
		if rel == s || strings.HasSuffix(s, "/") && strings.HasPrefix(rel, s) {
			return true
		}
	}
	return false
}

// InScope は rel が見る文書か。
func (r *Rules) InScope(rel string) bool {
	if r.skipped(rel) {
		return false
	}
	for _, f := range r.DocFiles {
		if rel == f {
			return true
		}
	}
	if !strings.HasSuffix(rel, ".md") {
		return false
	}
	for _, d := range r.DocDirs {
		if strings.HasPrefix(rel, strings.TrimSuffix(d, "/")+"/") {
			return true
		}
	}
	return false
}

// Docs は見る文書を全部（根からの相対・名前の順）。
func (r *Rules) Docs(root string) []string {
	var out []string
	for _, f := range r.DocFiles {
		if info, err := os.Stat(filepath.Join(root, f)); err == nil && info.Mode().IsRegular() && r.InScope(f) {
			out = append(out, f)
		}
	}
	for _, d := range r.DocDirs {
		filepath.WalkDir(filepath.Join(root, d), func(p string, e os.DirEntry, err error) error {
			if err != nil || e.IsDir() {
				return nil
			}
			rel, _ := filepath.Rel(root, p)
			rel = filepath.ToSlash(rel)
			if r.InScope(rel) {
				out = append(out, rel)
			}
			return nil
		})
	}
	sort.Strings(out)
	return out
}

// Hit は見つからない 1 件。
type Hit struct {
	Code string
	Doc  string
	Line int
	Text string   // 書かれた字
	Msg  string   // 何が無いか（行が無い・ファイルが無い・名前が無い）
	Near []string // 近い候補
}

// Report は 1 回の結果。
type Report struct {
	Docs    int
	Names   int // 確かめた名前の数
	Files   int // 確かめたパスの数（行つきも）
	Foreign int // 頭のモジュールか先頭のフォルダがこのリポに無く、数えなかった物
	Source  string
	Decls   int
	Hits    []Hit
}

// fileSet はリポのファイルの見分け（在るか・行数・同じ名前の物）。
type fileSet struct {
	root   string
	engine string // ゲームから見たエンジンの根（分からなければ ""。engine のリポ自身でも ""）
	self   bool   // 根が engine のリポ自身
	lines  map[string]int
	byBase map[string][]string // 名前 → パス（パスの無い path:行 と、無いファイルの候補）
}

func newFileSet(root string, sources []string) *fileSet {
	fs := &fileSet{root: root, lines: map[string]int{}, byBase: map[string][]string{}}
	dir, self := status.FindEngineDir(root, "mk/game.mk")
	if fs.self = self; !self {
		fs.engine = dir
	}
	files, _ := flixFiles(root, sources)
	for _, f := range files {
		fs.byBase[path.Base(f)] = append(fs.byBase[path.Base(f)], f)
	}
	return fs
}

// lineCount は rel の行数（無い・ディレクトリなら -1）。
func (fs *fileSet) lineCount(rel string) int {
	if n, ok := fs.lines[rel]; ok {
		return n
	}
	n := -1
	p := filepath.Join(fs.root, filepath.FromSlash(rel))
	if info, err := os.Stat(p); err == nil && info.Mode().IsRegular() {
		if body, err := os.ReadFile(p); err == nil {
			n = strings.Count(string(body), "\n")
			if len(body) > 0 && body[len(body)-1] != '\n' {
				n++
			}
		}
	} else if err == nil && info.IsDir() {
		n = 0
	}
	fs.lines[rel] = n
	return n
}

// inEngine は rel がエンジンの根に在るか（ゲームの文書がエンジンの docs・mk を指すのは普通）。
func (fs *fileSet) inEngine(rel string) bool {
	if fs.engine == "" {
		return false
	}
	_, err := os.Stat(filepath.Join(fs.engine, filepath.FromSlash(rel)))
	return err == nil
}

// ignored は rel を git が無視するか（作る物の置き場: bin/flix.jar・artifact/ など。無くて当たり前）。
// git の外・git が無い時は false（数える側に倒す）。
func (fs *fileSet) ignored(rel string) bool {
	cmd := exec.Command("git", "-C", fs.root, "check-ignore", "-q", "--", rel)
	return cmd.Run() == nil
}

func (fs *fileSet) isDir(rel string) bool {
	info, err := os.Stat(filepath.Join(fs.root, filepath.FromSlash(rel)))
	return err == nil && info.IsDir()
}

// nearFiles は無いファイル rel の候補: 同じ名前の別の場所の .flix → 同じフォルダの似た名前。
func (fs *fileSet) nearFiles(rel string) []string {
	var out []string
	for _, p := range fs.byBase[path.Base(rel)] {
		if len(out) < 3 {
			out = append(out, p)
		}
	}
	dir := path.Dir(rel)
	entries, err := os.ReadDir(filepath.Join(fs.root, filepath.FromSlash(dir)))
	if err != nil {
		return out
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	for _, n := range suggest.Near(path.Base(rel), names) {
		if len(out) < 3 {
			out = append(out, path.Join(dir, n))
		}
	}
	return out
}

// Check は docs（根からの相対）を見て結果を返す。
func (r *Rules) Check(root string, docs []string) *Report {
	idx, _ := BuildIndex(root, r.Sources, r.SpansIndex)
	fs := newFileSet(root, r.Sources)
	rep := &Report{Source: idx.Source, Decls: idx.Decls}
	for _, doc := range docs {
		body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(doc)))
		if err != nil {
			continue
		}
		rep.Docs++
		for _, ref := range ScanMarkdown(string(body), r.fileExt) {
			if h, counted := r.checkRef(root, doc, ref, idx, fs); counted {
				switch ref.Kind {
				case RefName:
					rep.Names++
				default:
					rep.Files++
				}
				if h != nil {
					rep.Hits = append(rep.Hits, *h)
				}
			} else {
				rep.Foreign++
			}
		}
	}
	return rep
}

// resolvePath は文書 doc の中のパス p を根からの相対にする（根から → 文書のフォルダから の順）。
// 無ければ根からの方を返す。owned は先頭のフォルダがこのリポに在るか（無ければ外の物で数えない）。
func (r *Rules) resolvePath(doc, p string, fs *fileSet) (rel string, owned bool) {
	p = strings.TrimPrefix(p, "./")
	cands := []string{path.Clean(p)}
	if dir := path.Dir(doc); dir != "." {
		cands = append(cands, path.Clean(path.Join(dir, p)))
	}
	for _, c := range cands {
		if fs.lineCount(c) >= 0 {
			return c, true
		}
	}
	first, _, _ := strings.Cut(cands[0], "/")
	if strings.HasPrefix(cands[0], "../") || lintconf.HasPrefixAny(cands[0], r.PathSkipPrefixes) || !fs.isDir(first) {
		return cands[0], false
	}
	return cands[0], true
}

// checkRef は 1 か所を確かめる。counted は数えたか（外の物は false）、hit は見つからない時だけ。
func (r *Rules) checkRef(root, doc string, ref Ref, idx *Index, fs *fileSet) (*Hit, bool) {
	if ref.Engine && !fs.self {
		// 「engine の `docs/…`」: ゲームのリポでは引かない（Studio の同梱のエンジンは docs を一部しか持たない）。
		return nil, false
	}
	switch ref.Kind {
	case RefName:
		if !idx.Owns(ref.Text) {
			return nil, false
		}
		if idx.Has(ref.Text) {
			return nil, true
		}
		return &Hit{Code: CodeName, Doc: doc, Line: ref.Line, Text: ref.Text, Msg: "名前が無い",
			Near: idx.Near(ref.Text, suggest.Near)}, true
	case RefFile:
		rel, owned := r.resolvePath(doc, ref.Path, fs)
		if !owned {
			return nil, false
		}
		if fs.lineCount(rel) >= 0 || fs.inEngine(rel) {
			return nil, true
		}
		if fs.ignored(rel) {
			return nil, false
		}
		return &Hit{Code: CodeFile, Doc: doc, Line: ref.Line, Text: ref.Text, Msg: "ファイルが無い", Near: fs.nearFiles(rel)}, true
	}
	// RefLine: パスの無い名前（World.flix:12）は sources の同じ名前の .flix のどれかで引く。
	var rels []string
	if !strings.Contains(ref.Path, "/") {
		if base := fs.byBase[ref.Path]; len(base) > 0 {
			rels = base
		} else if rel, _ := r.resolvePath(doc, ref.Path, fs); fs.lineCount(rel) >= 0 {
			rels = []string{rel}
		} else {
			return nil, false
		}
	} else {
		rel, owned := r.resolvePath(doc, ref.Path, fs)
		if !owned {
			return nil, false
		}
		if fs.lineCount(rel) < 0 {
			if fs.inEngine(rel) || fs.ignored(rel) {
				return nil, false
			}
			return &Hit{Code: CodeFile, Doc: doc, Line: ref.Line, Text: ref.Text, Msg: "ファイルが無い", Near: fs.nearFiles(rel)}, true
		}
		rels = []string{rel}
	}
	most := 0
	for _, rel := range rels {
		n := fs.lineCount(rel)
		if ref.To <= n {
			return nil, true
		}
		most = max(most, n)
	}
	return &Hit{Code: CodeLine, Doc: doc, Line: ref.Line, Text: ref.Text,
		Msg: fmt.Sprintf("行が無い（今は %d 行）", most)}, true
}

// Result は 1 件を checkres の形にする。
func (h Hit) Result() checkres.Result {
	res := checkres.New(h.Code, 0, checkres.Measure{Got: 1, Want: checkres.WantAtMost(0)}, nil, h.Text+" — "+h.Msg)
	res.Scope = checkres.ScopeFile
	res.Cause = checkres.Cause{Op: h.Text, Script: fmt.Sprintf("%s:%d", h.Doc, h.Line)}
	if len(h.Near) > 0 {
		res.Fix = checkres.Fix{Hint: "候補: " + strings.Join(h.Near, "・")}
	}
	return res
}

// site は場所の 1 行（文書:行 → 書かれた字 → 何が無いか・候補）。
func (h Hit) site() string {
	s := fmt.Sprintf("%s:%d\t%s\t%s", h.Doc, h.Line, h.Text, h.Msg)
	if len(h.Near) > 0 {
		s += " → 候補 " + strings.Join(h.Near, "・")
	}
	return s
}

type jsonReport struct {
	Results []checkres.Result `json:"results"`
	Docs    int               `json:"docs"`
	Names   int               `json:"names"`
	Files   int               `json:"files"`
	Foreign int               `json:"foreign"`
	Index   string            `json:"index"`
	Exit    int               `json:"exit"`
}

// Run は fge doc-refs の本体。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	asJSON, verbose := false, false
	var named []string
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--json":
			asJSON = true
		case a == "-v" || a == "--verbose" || a == "--all":
			verbose = true
		case a == "-h" || a == "--help":
			out.WriteString(usage)
			return 0, nil
		case strings.HasPrefix(a, "-"):
			return 2, fmt.Errorf("doc-refs: 知らない指定 %s\n%s", a, usage)
		default:
			named = append(named, lintconf.RelTo(root, a))
		}
	}
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	docs := rules.Docs(root)
	if len(named) > 0 {
		docs = nil
		for _, n := range named {
			if rules.InScope(n) {
				docs = append(docs, n)
			}
		}
		if len(docs) == 0 {
			return 0, nil
		}
	}
	rep := rules.Check(root, docs)
	code := 0
	if len(rep.Hits) > 0 {
		code = 1
	}
	if asJSON {
		jr := jsonReport{Results: []checkres.Result{}, Docs: rep.Docs, Names: rep.Names, Files: rep.Files,
			Foreign: rep.Foreign, Index: rep.Source, Exit: code}
		for _, h := range rep.Hits {
			jr.Results = append(jr.Results, h.Result())
		}
		out.Write(checkres.Compact(jr))
		return code, nil
	}
	index := "字の索引（" + strings.Join(existing(root, rules.Sources), "・") + " の宣言）"
	if rep.Source == "spans" {
		index = "flixlint の索引（" + rules.SpansIndex + "）＋字の索引"
	}
	head := fmt.Sprintf("[doc-refs] 文書 %d 本・名前 %d・パス %d を確かめた（宣言 %d・%s）", rep.Docs, rep.Names, rep.Files, rep.Decls, index)
	if code == 0 {
		fmt.Fprintf(out, "%s OK\n", head)
		return 0, nil
	}
	b := checkres.Brief{Head: head}
	counts := map[string]int{}
	worst := map[string]int{}
	for _, h := range rep.Hits {
		counts[h.Code]++
		worst[h.Doc]++
	}
	b.Count = fmt.Sprintf("見つからない %d 件（名前 %d・ファイル %d・行 %d）", len(rep.Hits), counts[CodeName], counts[CodeFile], counts[CodeLine])
	if rep.Foreign > 0 {
		b.Notes = append(b.Notes, fmt.Sprintf("頭のモジュールか先頭のフォルダがこのリポに無い %d か所（エンジン・外の物）は数えていない", rep.Foreign))
	}
	b.Fix = "今の名前・パスへ直す（行の番号でなく名前で指すと古びない）。消した物の記録なら ~~ ~~ で消し線、文書ごと古い記録なら bin/lint-rules/doc-refs.local.json の skip へ"
	for _, h := range rep.Hits {
		b.Sites.Lines = append(b.Sites.Lines, h.site())
	}
	if !verbose {
		b.Sites.Limit = rules.Limit
		b.Sites.Save(filepath.Join(root, filepath.FromSlash(rules.FullOut)))
		b.Shown = func(p string) string { return lintconf.RelTo(root, p) }
	}
	var docsByCount []string
	for d := range worst {
		docsByCount = append(docsByCount, d)
	}
	sort.Slice(docsByCount, func(i, j int) bool {
		if worst[docsByCount[i]] != worst[docsByCount[j]] {
			return worst[docsByCount[i]] > worst[docsByCount[j]]
		}
		return docsByCount[i] < docsByCount[j]
	})
	b.Next = "bin/fge doc-refs " + docsByCount[0]
	b.NextWhy = "一番多い文書（" + strconv.Itoa(worst[docsByCount[0]]) + " 件）から。直したら同じコマンドで確かめる"
	errOut.WriteString(b.Text())
	return 1, nil
}

func existing(root string, dirs []string) []string {
	var out []string
	for _, d := range dirs {
		if info, err := os.Stat(filepath.Join(root, d)); err == nil && info.IsDir() {
			out = append(out, d)
		}
	}
	return out
}

const usage = `使い方: bin/fge doc-refs [文書.md ...] [-v|--all] [--json] [--root DIR]
  文書（docs/**/*.md・NOTES.md・AGENTS.local.md。規約は bin/lint-rules/doc-refs.json）の ` + "` `" + ` の中と表の行が指す
  Mod.name・パス・path:行 が今のリポに在るかを見る。引数なしは全部、文書を名指しすればそれだけ。
  -v・--all は場所を全部画面に（既定は上位だけ・全部は build/doc-refs/last.txt）。
  古い記録の文書は bin/lint-rules/doc-refs.local.json の {"skip": ["notes/", "docs/old.md"]} で外す。
`
