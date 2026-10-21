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
// flixComments なら sources の .flix のコメント（/// と //）も見る（ScanFlixComments）。.flix の物は上限で数える:
// 全部を見る時はリポごとの flixLimitFile と比べ（増えたら止め・減ったら下げるまで止める）、名指しの時（コミットの時の
// 触ったファイル）は HEAD の中身のコメントより増えた物だけで止める。
//
// 生成物の文書（頭の generatedHead 行に generatedMarks の印「手で直さない」など）は見ない。直すのは作る元の側で、
// 文書の名を skip に並べない。予定の名前（`名前`（予定））は数えず、Flix の標準ライブラリの名前
// （flixJar の src/library の宣言）は在ると数える。書き方は docs/doc-conventions.md。
//
// .flix のコメントに書いた呼び手（「名前 が呼ぶ」）を数えるのは callers.go（上限は callersLimitFile）。
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
	GeneratedMarks   []string `json:"generatedMarks"`
	GeneratedHead    int      `json:"generatedHead"`
	PlannedMarks     []string `json:"plannedMarks"`
	FlixJar          string   `json:"flixJar"`
	// FlixComments は sources の .flix のコメント（/// と //）も見るか。
	FlixComments bool `json:"flixComments"`
	// FlixLimitFile は .flix のコメントの見つからない件数の上限を書くリポごとのファイル（{"limit": N}。全部を見る時だけ。
	// 増えたら止め、減ったら上限を下げるまで止める。無ければ 0）。
	// WhyNot: doc-refs.local.json に置かないのは、エンジンの bin/lint-rules は sync-agents がまるごと配るので、エンジン自身の
	// 上限をそこに書くとゲームの物を上書きするため（lint/limits/ は配らない・flixlint の上限と同じ置き場）。
	FlixLimitFile string `json:"flixLimitFile"`
	// CallersLimitFile は .flix のコメントに書いた呼び手（callers.go）の上限を書くリポごとのファイル（{"limit": N}。置き場と数え方は
	// flixLimitFile と同じ）。空ならこの段を見ない（flixComments も要る）。
	CallersLimitFile string `json:"callersLimitFile"`

	flixLimit    int
	callersLimit int
	fileExt      map[string]bool
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
	if r.FlixComments {
		if r.flixLimit, err = readLimit(root, r.FlixLimitFile); err != nil {
			return nil, err
		}
		if r.callersLimit, err = readLimit(root, r.CallersLimitFile); err != nil {
			return nil, err
		}
	}
	r.fileExt = map[string]bool{}
	for _, e := range r.FileExts {
		r.fileExt[e] = true
	}
	return &r, nil
}

// readLimit はリポごとの上限のファイル（{"limit": N}）を読む（rel が "" か、ファイルが無ければ 0）。
func readLimit(root, rel string) (int, error) {
	if rel == "" {
		return 0, nil
	}
	body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	switch {
	case errors.Is(err, os.ErrNotExist):
		return 0, nil
	case err != nil:
		return 0, fmt.Errorf("読めません (%s): %v", rel, err)
	}
	var l struct {
		Limit int `json:"limit"`
	}
	if err := json.Unmarshal(body, &l); err != nil {
		return 0, fmt.Errorf("JSON として壊れています (%s): %v", rel, err)
	}
	return l.Limit, nil
}

// callersOn は doc の呼び手を照らすか（.flix のコメントを見て、上限のファイルの場所を規約が持つ時）。
func (r *Rules) callersOn() bool { return r.FlixComments && r.CallersLimitFile != "" }

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

// InFlixScope は rel が コメントを見る .flix か（flixComments で、sources の下の .flix で、skip に無い）。
func (r *Rules) InFlixScope(rel string) bool {
	if !r.FlixComments || !strings.HasSuffix(rel, ".flix") || r.skipped(rel) {
		return false
	}
	for _, d := range r.Sources {
		if strings.HasPrefix(rel, strings.TrimSuffix(d, "/")+"/") {
			return true
		}
	}
	return false
}

// FlixDocs はコメントを見る .flix を全部（根からの相対・名前の順）。
func (r *Rules) FlixDocs(root string) []string {
	if !r.FlixComments {
		return nil
	}
	files, _ := flixFiles(root, r.Sources)
	var out []string
	for _, f := range files {
		if r.InFlixScope(f) {
			out = append(out, f)
		}
	}
	sort.Strings(out)
	return out
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

// Generated は本文 body が生成物の文書か（頭の GeneratedHead 行に GeneratedMarks のどれかがある）。
func (r *Rules) Generated(body string) bool {
	head := strings.SplitN(body, "\n", r.GeneratedHead+1)
	if len(head) > r.GeneratedHead {
		head = head[:r.GeneratedHead]
	}
	text := strings.Join(head, "\n")
	for _, m := range r.GeneratedMarks {
		if m != "" && strings.Contains(text, m) {
			return true
		}
	}
	return false
}

// Refs は文書 rel（中身 body）から確かめる物を拾う（この検査と同じ決まり。生成物の文書は無し・.flix はコメントだけ）。
// 予定の印の物も返す（Planned で分かる）。bin/fge refactor が、消す名前を文書が名指すかを見るのに使う。
func (r *Rules) Refs(rel, body string) []Ref {
	if r.Generated(body) {
		return nil
	}
	if strings.HasSuffix(rel, ".flix") {
		return ScanFlixComments(body, r.fileExt, r.PlannedMarks)
	}
	return ScanMarkdown(body, r.fileExt, r.PlannedMarks)
}

// Hit は見つからない 1 件。
type Hit struct {
	Code string
	Doc  string
	Line int
	Text string // 書かれた字
	// Comment は .flix のコメントの中の物（上限で数える。md の物は 1 件でも止める）。
	Comment bool
	// Caller は .flix のコメントに書いた呼び手（callers.go。Comment と別の上限で数える）。
	Caller bool
	Msg    string   // 何が無いか（行が無い・ファイルが無い・名前が無い）
	Near   []string // 近い候補
}

// Report は 1 回の結果。
type Report struct {
	Docs    int
	Names   int // 確かめた名前の数
	Files   int // 確かめたパスの数（行つきも）
	Foreign int // 頭のモジュールか先頭のフォルダがこのリポに無く、数えなかった物
	Planned int // 予定の印のついた名前・パス（数えない）
	Std     int // Flix の標準ライブラリの名前（在ると数える）
	// Generated は生成物で見なかった文書の数。
	Generated int
	// FlixFiles はコメントを見た .flix の数。
	FlixFiles int
	// StdJar は標準ライブラリの名前を読んだ flix.jar（見つからなければ ""）。
	StdJar string
	Source string
	Decls  int
	Hits   []Hit
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
	c := r.checker(root)
	for _, doc := range docs {
		body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(doc)))
		if err != nil {
			continue
		}
		c.body(doc, string(body))
	}
	return c.rep
}

// checker は索引とファイルの見分けを 1 度作り、文書を 1 本ずつ見る物（.flix の HEAD の中身も同じ索引で見る）。
type checker struct {
	r    *Rules
	root string
	idx  *Index
	fs   *fileSet
	rep  *Report
}

func (r *Rules) checker(root string) *checker {
	idx, _ := BuildIndex(root, r.Sources, r.SpansIndex)
	fs := newFileSet(root, r.Sources)
	rep := &Report{Source: idx.Source, Decls: idx.Decls}
	if r.FlixJar != "" {
		rep.StdJar = findFlixJar(root, fs.engine, r.FlixJar)
		idx.std = loadStd(rep.StdJar)
	}
	return &checker{r: r, root: root, idx: idx, fs: fs, rep: rep}
}

// body は文書 doc（中身 text）を見て、見つからない物を rep に足す（.flix はコメントだけ）。
func (c *checker) body(doc, text string) {
	r, root, idx, fs, rep := c.r, c.root, c.idx, c.fs, c.rep
	if r.Generated(text) {
		rep.Generated++
		return
	}
	flix := strings.HasSuffix(doc, ".flix")
	refs := ScanMarkdown(text, r.fileExt, r.PlannedMarks)
	if flix {
		refs = ScanFlixComments(text, r.fileExt, r.PlannedMarks)
		rep.FlixFiles++
		if r.callersOn() {
			rep.Hits = append(rep.Hits, callerHits(doc, text, r.fileExt, r.PlannedMarks)...)
		}
	} else {
		rep.Docs++
	}
	for _, ref := range refs {
		if ref.Planned {
			rep.Planned++
			continue
		}
		if ref.Kind == RefName && idx.Owns(ref.Key()) && !idx.Has(ref.Key()) && idx.std[ref.Key()] {
			rep.Std++
			continue
		}
		if h, counted := r.checkRef(root, doc, ref, idx, fs); counted {
			switch ref.Kind {
			case RefName:
				rep.Names++
			default:
				rep.Files++
			}
			if h != nil {
				h.Comment = flix
				rep.Hits = append(rep.Hits, *h)
			}
		} else {
			rep.Foreign++
		}
	}
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
		if !idx.Owns(ref.Key()) {
			return nil, false
		}
		if idx.Has(ref.Key()) {
			return nil, true
		}
		return &Hit{Code: CodeName, Doc: doc, Line: ref.Line, Text: ref.Text, Msg: "名前が無い",
			Near: idx.Near(ref.Key(), suggest.Near)}, true
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
	switch {
	case h.Caller:
		res.Fix = checkres.Fix{Hint: callerHint}
	case len(h.Near) > 0:
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

// callerHint は doc に書いた呼び手の直し方。
const callerHint = "doc に呼び手を書かない（古くなる）。呼び手は bin/fge refactor usages --callers <def> で引く。何をするか・なぜかを書く"

type jsonReport struct {
	Results []checkres.Result `json:"results"`
	Docs    int               `json:"docs"`
	Names   int               `json:"names"`
	Files   int               `json:"files"`
	Foreign int               `json:"foreign"`
	Planned int               `json:"planned"`
	Std     int               `json:"std"`
	// Generated は生成物で見なかった文書の数。
	Generated int    `json:"generated"`
	Index     string `json:"index"`
	Exit      int    `json:"exit"`
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
	docs := append(rules.Docs(root), rules.FlixDocs(root)...)
	if len(named) > 0 {
		docs = nil
		for _, n := range named {
			if rules.InScope(n) || rules.InFlixScope(n) {
				docs = append(docs, n)
			}
		}
		if len(docs) == 0 {
			return 0, nil
		}
	}
	c := rules.checker(root)
	for _, doc := range docs {
		if body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(doc))); err == nil {
			c.body(doc, string(body))
		}
	}
	rep := c.rep
	// md の物は 1 件でも止める。.flix のコメントの物は、全部を見る時は上限（flixLimitFile）と比べ、名指しの時
	// （コミットの時の触った .flix）は HEAD の中身の件数より増えた物だけを止める（古い件で関係の無いコミットを止めない）。
	// doc の呼び手（Caller）も同じ数え方で、上限は別のファイル（callersLimitFile）。
	var shown, flixGroup, callerGroup []Hit
	for _, h := range rep.Hits {
		switch {
		case h.Caller:
			callerGroup = append(callerGroup, h)
		case h.Comment:
			flixGroup = append(flixGroup, h)
		default:
			shown = append(shown, h)
		}
	}
	flixHits := len(flixGroup)
	var verdicts, lower []string
	for _, g := range []ratchetGroup{
		{what: ".flix のコメントで見つからない物", hits: flixGroup, limit: rules.flixLimit, file: rules.FlixLimitFile, caller: false},
		{what: "doc に書いた呼び手", hits: callerGroup, limit: rules.callersLimit, file: rules.CallersLimitFile, caller: true},
	} {
		s, v, low := c.ratchet(g, len(named) > 0)
		shown = append(shown, s...)
		if v != "" {
			verdicts = append(verdicts, v)
		}
		if low {
			lower = append(lower, g.file)
		}
	}
	verdict := strings.Join(verdicts, "／")
	code := 0
	if len(shown) > 0 || verdict != "" {
		code = 1
	}
	if asJSON {
		jr := jsonReport{Results: []checkres.Result{}, Docs: rep.Docs, Names: rep.Names, Files: rep.Files,
			Foreign: rep.Foreign, Planned: rep.Planned, Std: rep.Std, Generated: rep.Generated, Index: rep.Source, Exit: code}
		for _, h := range shown {
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
	if rules.FlixComments {
		head = fmt.Sprintf("[doc-refs] 文書 %d 本・.flix のコメント %d 本・名前 %d・パス %d を確かめた（宣言 %d・%s）", rep.Docs, rep.FlixFiles, rep.Names, rep.Files, rep.Decls, index)
		if flixHits > 0 && len(named) == 0 {
			head += fmt.Sprintf("・.flix のコメントの見つからない物 %d 件（上限 %d）", flixHits, rules.flixLimit)
		}
	}
	if rules.callersOn() && len(callerGroup) > 0 && len(named) == 0 {
		head += fmt.Sprintf("・doc に書いた呼び手 %d 件（上限 %d）", len(callerGroup), rules.callersLimit)
	}
	var skipped []string
	for _, c := range []struct {
		n    int
		what string
	}{{rep.Generated, "生成物の文書 %d 本"}, {rep.Planned, "予定の印 %d か所"}, {rep.Std, "Flix の標準ライブラリの名前 %d"}} {
		if c.n > 0 {
			skipped = append(skipped, fmt.Sprintf(c.what, c.n))
		}
	}
	if len(skipped) > 0 {
		head += "・数えない物: " + strings.Join(skipped, "・")
	}
	if code == 0 {
		fmt.Fprintf(out, "%s OK\n", head)
		return 0, nil
	}
	b := checkres.Brief{Head: head}
	if rules.FlixJar != "" && rep.StdJar == "" {
		b.Notes = append(b.Notes, rules.FlixJar+" が見つからず、Flix の標準ライブラリの名前（Clock.runWithIO など）も「無い」に出る。make status で jar を置いてから流し直す")
	}
	counts := map[string]int{}
	worst := map[string]int{}
	for _, h := range shown {
		counts[h.Code]++
		worst[h.Doc]++
	}
	b.Count = fmt.Sprintf("見つからない %d 件（名前 %d・ファイル %d・行 %d）", len(shown)-counts[CodeCaller], counts[CodeName], counts[CodeFile], counts[CodeLine])
	if counts[CodeCaller] > 0 {
		b.Count += fmt.Sprintf("・doc に書いた呼び手 %d 件", counts[CodeCaller])
	}
	if verdict != "" {
		b.State = "fail: " + verdict
	}
	if rep.Foreign > 0 {
		b.Notes = append(b.Notes, fmt.Sprintf("頭のモジュールか先頭のフォルダがこのリポに無い %d か所（エンジン・外の物）は数えていない", rep.Foreign))
	}
	b.Fix = "今の名前・パスへ直す（行の番号でなく名前で指すと古びない）。これから作る名前なら `名前`（予定）、消した物の記録なら ~~ ~~ で消し線、ゲームの側のパスなら <ゲーム>/…、文書ごと古い記録なら bin/lint-rules/doc-refs.local.json の skip へ（書き方は engine の docs/doc-conventions.md）"
	if counts[CodeCaller] > 0 {
		b.Fix += "。" + callerHint
	}
	for _, h := range shown {
		b.Sites.Lines = append(b.Sites.Lines, h.site())
	}
	if !verbose {
		b.Sites.Limit = rules.Limit
		b.Sites.Save(filepath.Join(root, filepath.FromSlash(rules.FullOut)))
		b.Shown = func(p string) string { return lintconf.RelTo(root, p) }
	}
	if len(shown) == 0 {
		// 減った（上限を下げる）だけ: 直す所は無い。
		b.Next, b.NextWhy = "bin/fge doc-refs", strings.Join(lower, "・")+" の limit を下げてから同じコマンドで確かめる"
		errOut.WriteString(b.Text())
		return 1, nil
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

// ratchetGroup は上限で数える組 1 つ（.flix のコメントの見つからない物・doc の古い呼び手）。
type ratchetGroup struct {
	what   string
	hits   []Hit
	limit  int
	file   string
	caller bool
}

// ratchet は組 g を、全部を見る時は上限のファイルと比べ、名指しの時（コミットの時の触った .flix）は HEAD の中身の件数より
// 増えた物だけを出す（古い件で関係の無いコミットを止めない）。low は上限を下げる（減った・0 件になった）だけの時。
func (c *checker) ratchet(g ratchetGroup, named bool) (shown []Hit, verdict string, low bool) {
	n := len(g.hits)
	switch {
	case n == 0:
	case named:
		shown = c.addedSinceHead(g.hits)
		if len(shown) > 0 {
			verdict = fmt.Sprintf("触った .flix の%sが HEAD より %d 件増えた", g.what, len(shown))
		}
	case n > g.limit:
		shown = g.hits
		verdict = fmt.Sprintf("%s %d 件が上限 %d を超えた（増えた所を直す）", g.what, n, g.limit)
	case n < g.limit:
		verdict = fmt.Sprintf("%sが %d 件に減った。%s の limit を %d に下げる", g.what, n, g.file, n)
		low = true
	}
	if n == 0 && g.limit > 0 && !named {
		verdict = g.what + "が 0 件になった。" + g.file + " を消す"
		low = true
	}
	return shown, verdict, low
}

// addedSinceHead は hits（同じ組の物）のうち、同じファイルの HEAD の中身で出る物より増えた物
// （ファイルごとに code と書かれた字で数える。HEAD に無いファイルは全部が増えた物）。
func (c *checker) addedSinceHead(hits []Hit) []Hit {
	byDoc := map[string][]Hit{}
	var order []string
	for _, h := range hits {
		if _, ok := byDoc[h.Doc]; !ok {
			order = append(order, h.Doc)
		}
		byDoc[h.Doc] = append(byDoc[h.Doc], h)
	}
	var out []Hit
	for _, doc := range order {
		base := map[string]int{}
		if old, err := exec.Command("git", "-C", c.root, "show", "HEAD:"+doc).Output(); err == nil {
			saved := c.rep
			c.rep = &Report{}
			c.body(doc, string(old))
			for _, h := range c.rep.Hits {
				base[h.Code+"\t"+h.Text]++
			}
			c.rep = saved
		}
		for _, h := range byDoc[doc] {
			if k := h.Code + "\t" + h.Text; base[k] > 0 {
				base[k]--
				continue
			}
			out = append(out, h)
		}
	}
	return out
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

const usage = `使い方: bin/fge doc-refs [文書.md・src/X.flix ...] [-v|--all] [--json] [--root DIR]
  文書（docs/**/*.md・NOTES.md・AGENTS.local.md。規約は bin/lint-rules/doc-refs.json）の ` + "` `" + ` の中と表の行と、
  sources の .flix のコメント（/// と //）が指す Mod.name・パス・path:行 が今のリポに在るかを見る。引数なしは全部、名指しすればそれだけ。
  .flix の物は上限で数える: 全部の時は lint/limits/doc-refs-flix.json（{"limit": N}）と比べ、名指しの .flix は HEAD より増えた物だけ止める。
  .flix のコメントの「名前 が呼ぶ・から呼ぶ・が読む・が使う・が組む・が受け取る・で受け取る」（doc に書いた呼び手）を
  lint/limits/doc-refs-callers.json の上限で数える（数え方は上と同じ）。呼び手は bin/fge refactor usages --callers <def> で引く。
  -v・--all は場所を全部画面に（既定は上位だけ・全部は build/doc-refs/last.txt）。
  これから作る名前は ` + "`名前`（予定）" + `、消した物は ~~ ~~、ゲームの側のパスは <ゲーム>/… と書く（docs/doc-conventions.md）。
  頭に「手で直さない」と書いた生成物の文書は見ない。古い記録の文書は bin/lint-rules/doc-refs.local.json の
  {"skip": ["notes/", "docs/old.md"]} で外す。
`
