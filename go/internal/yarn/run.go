package yarn

// fge yarn の入口。
//
//	fge yarn build <フォルダか x.yarn>... [--out <パス>] [--vocab <パス> | --no-vocab]   読んで検査し、木の JSON を書く
//	fge yarn check <パス>...                                                           書かずに、書いてある JSON とずれていないかも見る
//	どちらも --json で Report（知らせ・ノードの一覧・書いたファイル）を 1 行の JSON にする（Studio の会話の画面が読む）

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/suggest"
)

const usage = `使い方: bin/fge yarn <サブコマンド> ...   会話のシナリオ（Yarn Spinner の .yarn の部分集合）を読む（ゲームのルートで流す）

  yarn build <フォルダか x.yarn>... [--out <パス>] [--vocab <パス> | --no-vocab]
      フォルダの *.yarn を全部読み（ノード名はフォルダの中で 1 つ）、検査を通れば木の JSON を書く。
      既定の書き先は <フォルダ>/dialogue.json、語彙は <フォルダ>/vocab.json（ゲームの Talk.vocab が書く。make talk-vocab）。
      書き先が既にあれば、指定の無い時はそこに書いてある語彙（"vocab"）で組み直す（テストのシナリオは --vocab で一度組めばよい）。
      知らせは「ファイル:行: 文」。読まない構文は「読まない: … — 代わりに: …」。終わりの番号: 0 書いた・1 知らせあり（書かない）。
  yarn check <パス>...
      パス（.yarn・vocab.json・dialogue.json）のフォルダごとに build と同じ検査をし、書いてある dialogue.json が
      .yarn から作り直した物と違えば 1（書かない）。コミットの前の門が流す。

読む: ノード（title: 〜 --- 〜 ===）・ヘッダ・話し手: 台詞・#タグ・-> の選択肢と字下げ・<<jump>>・<<stop>>・<<wait 秒>>・// コメント・\ のエスケープ。
変数と条件（公式と同じ書き方）:
  <<declare $切符 = 2>>               宣言（数・真偽・"文字列"。型は初めの値で決まる。フォルダの中で 1 つ・どのノードに書いてもよい）
  <<set $切符 to $切符 - 1>>           入れる（= と += -= *= /= %= も）。宣言の無い変数・型の違う式は build が行番号つきで止める
  <<if 式>> … <<elseif 式>> … <<else>> … <<endif>>   中に台詞・選択肢・jump・コマンドを置ける
  -> 一緒に降りる <<if $切符 > 0>> #タグ   条件が偽なら選べない印（DialogueOption の available = false）で並べる。
                                       灰色にするか隠すかはゲームが決める。まとまりの全部が偽なら飛ばす
  girl: 切符は {$切符} 枚              行と選択肢の字に式の値を差し込む（数は 2・真偽は True / False）
  式: + - * / %・== != < <= > >=・and or not・( )・visited("ノード")・visited_count("ノード")（ノードを出た回数）
  値はゲームの YarnRunner.valueOf / withStorage で読み書きし、YarnStorage.toJson でセーブに乗せる。
  プレビューに値を渡す: bin/fge talk shot / goto <file.yarn>:<行> '$切符=0'（始まりの引数を YarnStorage.withArgs → YarnRunner.startAtWith）。
読まない: 宣言の無い変数（公式の暗黙の宣言）・別の綴り（is eq && || ! など）・and と or の括弧なしの混ぜ書き・関数の自作と他の組み込み関数・
  <<declare>> の計算した値と as 型・台詞の行末の <<if>>・コマンドの中の {式}・<<local>>・<<detour>>・<<once>>・=> の行のグループ・
  when:・tracking:・[マークアップ]・ゲームを待つコマンド。
`

const (
	outName   = "dialogue.json"
	vocabName = "vocab.json"
	remake    = "make talk-vocab"
)

// Report は --json の時に出す 1 回分の結果（Studio の会話の画面が誤りをその行に出し、ノードの一覧を作る）。
// Problems は止めた知らせ（あれば dialogue.json は書かない）、Notes は止めない注意（届かないノードなど）。
type Report struct {
	Ok       bool         `json:"ok"`
	Problems []ReportLine `json:"problems"`
	Notes    []ReportLine `json:"notes"`
	Nodes    []ReportNode `json:"nodes"`
	Wrote    []string     `json:"wrote"`
}

// ReportLine は知らせ 1 つ（ファイルはゲームのルートから・行は 1 始まり・行の無い知らせは 0）。
type ReportLine struct {
	File        string `json:"file"`
	Line        int    `json:"line"`
	Msg         string `json:"msg"`
	Unsupported bool   `json:"unsupported,omitempty"`
}

// ReportNode はノード 1 つ（title: の行）。
type ReportNode struct {
	Title string `json:"title"`
	File  string `json:"file"`
	Line  int    `json:"line"`
}

func lineOf(p Problem) ReportLine {
	return ReportLine{File: p.File, Line: p.Line, Msg: p.Msg, Unsupported: p.Unsupported}
}

// RunJSON は Run と同じことをし、結果を Report で返す（人向けの文は捨てる）。
func RunJSON(workRoot string, args []string) (Report, int) {
	rep := Report{Problems: []ReportLine{}, Notes: []ReportLine{}, Nodes: []ReportNode{}, Wrote: []string{}}
	var out, errOut strings.Builder
	code := run(&out, &errOut, workRoot, args, &rep)
	if code != 0 && len(rep.Problems) == 0 {
		msg := strings.TrimSpace(errOut.String() + out.String())
		rep.Problems = append(rep.Problems, ReportLine{Msg: msg})
	}
	rep.Ok = code == 0
	return rep, code
}

// Run は fge yarn の入口。workRoot は流した場所（パスはそこから読み、木にはゲームのルートからのパスを書く）。
func Run(out, errOut *strings.Builder, workRoot string, args []string) int {
	return run(out, errOut, workRoot, args, &Report{})
}

func run(out, errOut *strings.Builder, workRoot string, args []string, rep *Report) int {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" || args[0] == "help" {
		out.WriteString(usage)
		if len(args) == 0 {
			return 2
		}
		return 0
	}
	opts, paths, err := parseFlags(args[1:])
	if err != nil {
		errOut.WriteString(err.Error() + "\n")
		return 2
	}
	switch args[0] {
	case "build":
		return build(out, errOut, workRoot, paths, opts, false, rep)
	case "check":
		return build(out, errOut, workRoot, paths, opts, true, rep)
	}
	errOut.WriteString(fmt.Sprintf("知らないサブコマンド: %s%s\n", args[0], suggest.Hint(args[0], []string{"build", "check", "help"})))
	return 2
}

type options struct {
	out     string
	vocab   string
	noVocab bool
}

func parseFlags(args []string) (options, []string, error) {
	var o options
	var paths []string
	for i := 0; i < len(args); i++ {
		switch a := args[i]; a {
		case "--out", "--vocab":
			if i+1 >= len(args) {
				return o, nil, fmt.Errorf("%s の後ろにパスが要る", a)
			}
			if a == "--out" {
				o.out = args[i+1]
			} else {
				o.vocab = args[i+1]
			}
			i++
		case "--no-vocab":
			o.noVocab = true
		default:
			if strings.HasPrefix(a, "--") {
				return o, nil, fmt.Errorf("知らない指定: %s", a)
			}
			paths = append(paths, a)
		}
	}
	if len(paths) == 0 {
		return o, nil, fmt.Errorf("フォルダか .yarn を 1 つ以上渡す（bin/fge yarn help）")
	}
	return o, paths, nil
}

// group は 1 つの書き先にまとめる .yarn の束。
type group struct {
	dir   string
	files []string
}

// groupsOf はパスをフォルダごとの束にする（.yarn 以外のパスは、そのフォルダの .yarn を全部読む合図）。
func groupsOf(workRoot string, paths []string) ([]group, error) {
	byDir := map[string]map[string]bool{}
	whole := map[string]bool{}
	for _, p := range paths {
		abs := p
		if !filepath.IsAbs(abs) {
			abs = filepath.Join(workRoot, p)
		}
		info, err := os.Stat(abs)
		switch {
		case err == nil && info.IsDir():
			whole[abs] = true
			if byDir[abs] == nil {
				byDir[abs] = map[string]bool{}
			}
		case strings.HasSuffix(abs, ".yarn") && err == nil:
			dir := filepath.Dir(abs)
			if byDir[dir] == nil {
				byDir[dir] = map[string]bool{}
			}
			byDir[dir][abs] = true
		case err != nil && strings.HasSuffix(abs, ".yarn"):
			return nil, fmt.Errorf("読めない: %s", p)
		default:
			dir := filepath.Dir(abs)
			whole[dir] = true
			if byDir[dir] == nil {
				byDir[dir] = map[string]bool{}
			}
		}
	}
	var out []group
	for dir, files := range byDir {
		if whole[dir] {
			matches, _ := filepath.Glob(filepath.Join(dir, "*.yarn"))
			for _, m := range matches {
				files[m] = true
			}
		}
		var list []string
		for f := range files {
			list = append(list, f)
		}
		sort.Strings(list)
		if len(list) > 0 {
			out = append(out, group{dir: dir, files: list})
		}
	}
	sort.Slice(out, func(a, b int) bool { return out[a].dir < out[b].dir })
	return out, nil
}

func build(out, errOut *strings.Builder, workRoot string, paths []string, opts options, checkOnly bool, rep *Report) int {
	groups, err := groupsOf(workRoot, paths)
	if err != nil {
		errOut.WriteString(err.Error() + "\n")
		return 2
	}
	if len(groups) == 0 {
		out.WriteString("[yarn] .yarn が無い（何も見ない）\n")
		return 0
	}
	if opts.out != "" && len(groups) > 1 {
		errOut.WriteString("--out は 1 つのフォルダの時だけ使える\n")
		return 2
	}
	code := 0
	for _, g := range groups {
		if c := buildGroup(out, workRoot, g, opts, checkOnly, rep); c > code {
			code = c
		}
	}
	return code
}

func buildGroup(out *strings.Builder, cwd string, g group, opts options, checkOnly bool, rep *Report) int {
	// 木に書くパスと語彙のパスは、どこから流してもゲームのルート（project.json のあるフォルダ）から数える
	// （エンジンのルートから流すコミットの門と、ゲームのルートから流す build で中身が変わらないように）。
	workRoot := gameRootOf(g.dir, cwd)
	if opts.out != "" && !filepath.IsAbs(opts.out) {
		opts.out = filepath.Join(cwd, opts.out)
	}
	if opts.vocab != "" && !filepath.IsAbs(opts.vocab) {
		opts.vocab = filepath.Join(cwd, opts.vocab)
	}
	outPath := opts.out
	if outPath == "" {
		outPath = filepath.Join(g.dir, outName)
	} else if !filepath.IsAbs(outPath) {
		outPath = filepath.Join(workRoot, outPath)
	}
	old, readErr := os.ReadFile(outPath)
	if checkOnly && readErr != nil && opts.out == "" {
		if _, err := os.Stat(filepath.Join(g.dir, vocabName)); err != nil {
			// WhyNot: 止めない —— 1 本ずつ書き先を決めて組む .yarn（エンジンの testdata など）のフォルダで、
			// コミットの門が書き先の無い dialogue.json を探して落ちる。そこのずれは Go のテストが見る。
			fmt.Fprintf(out, "[yarn] %s も %s も無いフォルダは見ない: %s\n", outName, vocabName, rel(workRoot, g.dir))
			return 0
		}
	}
	noVocab, vocabPath := opts.noVocab, opts.vocab
	if !noVocab && vocabPath == "" {
		var recorded struct {
			Vocab *string `json:"vocab"`
		}
		if json.Unmarshal(old, &recorded) == nil && recorded.Vocab != nil {
			noVocab, vocabPath = *recorded.Vocab == "", *recorded.Vocab
		}
	}
	var vocab *Vocab
	if !noVocab {
		if vocabPath == "" {
			vocabPath = filepath.Join(g.dir, vocabName)
		} else if !filepath.IsAbs(vocabPath) {
			vocabPath = filepath.Join(workRoot, vocabPath)
		}
		data, err := os.ReadFile(vocabPath)
		if err != nil {
			msg := fmt.Sprintf("語彙が無い — %s で書き出す（語彙を見ずに組むなら --no-vocab）", remake)
			fmt.Fprintf(out, "%s: %s\n", rel(workRoot, vocabPath), msg)
			rep.Problems = append(rep.Problems, ReportLine{File: rel(workRoot, vocabPath), Msg: msg})
			return 1
		}
		v, err := ParseVocab(data)
		if err != nil {
			fmt.Fprintf(out, "%s: %v\n", rel(workRoot, vocabPath), err)
			rep.Problems = append(rep.Problems, ReportLine{File: rel(workRoot, vocabPath), Msg: err.Error()})
			return 1
		}
		vocab = v
		if line := suggest.Stale(workRoot, rel(workRoot, vocabPath), remake); line != "" {
			out.WriteString(line + "\n")
		}
	}
	var names, texts []string
	for _, f := range g.files {
		data, err := os.ReadFile(f)
		if err != nil {
			fmt.Fprintf(out, "%s: 読めない: %v\n", rel(workRoot, f), err)
			return 1
		}
		names = append(names, rel(workRoot, f))
		texts = append(texts, string(data))
	}
	prog, problems := BuildProgram(names, texts, vocab, rel(workRoot, vocabPath))
	prog.Vocab = rel(workRoot, vocabPath)
	for _, n := range prog.Nodes {
		rep.Nodes = append(rep.Nodes, ReportNode{Title: n.Title, File: n.File, Line: n.Line})
	}
	for _, p := range problems {
		out.WriteString(p.String() + "\n")
		rep.Problems = append(rep.Problems, lineOf(p))
	}
	if len(problems) > 0 {
		fmt.Fprintf(out, "[yarn] %d 件の知らせ（%s は書かない）\n", len(problems), rel(workRoot, outPath))
		return 1
	}
	for _, p := range Unreached(prog, vocab) {
		out.WriteString("注意: " + p.String() + "\n")
		rep.Notes = append(rep.Notes, lineOf(p))
	}
	data, err := Encode(prog)
	if err != nil {
		fmt.Fprintf(out, "%v\n", err)
		return 1
	}
	if checkOnly {
		if !bytes.Equal(old, data) {
			fmt.Fprintf(out, "%s が .yarn とずれている — bin/fge yarn build %s で書き直す\n", rel(workRoot, outPath), rel(workRoot, g.dir))
			rep.Problems = append(rep.Problems, ReportLine{File: rel(workRoot, outPath), Msg: "書いてある木が .yarn とずれている"})
			return 1
		}
		fmt.Fprintf(out, "[yarn] ok %s（%d ノード）\n", rel(workRoot, outPath), len(prog.Nodes))
		return 0
	}
	if bytes.Equal(old, data) {
		fmt.Fprintf(out, "[yarn] 変わらない %s（%d ノード）\n", rel(workRoot, outPath), len(prog.Nodes))
		return 0
	}
	if err := os.WriteFile(outPath, data, 0o644); err != nil {
		fmt.Fprintf(out, "%s: 書けない: %v\n", rel(workRoot, outPath), err)
		return 1
	}
	fmt.Fprintf(out, "[yarn] 書いた %s（%d ノード）\n", rel(workRoot, outPath), len(prog.Nodes))
	rep.Wrote = append(rep.Wrote, rel(workRoot, outPath))
	return 0
}

// rel はゲームのルートからのパス（/ 区切り）。ルートの外ならそのまま。
func rel(root, path string) string {
	if path == "" {
		return ""
	}
	r, err := filepath.Rel(root, path)
	if err != nil || strings.HasPrefix(r, "..") {
		return filepath.ToSlash(path)
	}
	return filepath.ToSlash(r)
}

// BuildProgram は .yarn の束（names は木と知らせに書く名前・texts は中身）を 1 つの木にし、検査の知らせをファイル:行の順で返す。
func BuildProgram(names, texts []string, vocab *Vocab, vocabPath string) (*Program, []Problem) {
	prog := &Program{Version: Version, Files: names, Nodes: []*Node{}}
	var problems []Problem
	for i, name := range names {
		nodes, ps := ParseFile(name, texts[i])
		prog.Nodes = append(prog.Nodes, nodes...)
		problems = append(problems, ps...)
		for _, n := range nodes {
			prog.Variables = append(prog.Variables, n.declared...)
		}
	}
	if !usesVersionTwo(prog) {
		prog.Version = versionOne
	}
	prog.Note = fmt.Sprintf("bin/fge yarn build が %s から書いた木。手で直さない（.yarn を直して build する）", strings.Join(names, " "))
	problems = append(problems, CheckProgram(prog, vocab, vocabPath)...)
	sort.SliceStable(problems, func(a, b int) bool {
		if problems[a].File != problems[b].File {
			return problems[a].File < problems[b].File
		}
		return problems[a].Line < problems[b].Line
	})
	return prog, problems
}

// gameRootOf は dir から上へ辿って最初に project.json のあるフォルダ（無ければ cwd）。
func gameRootOf(dir, cwd string) string {
	for d := dir; ; d = filepath.Dir(d) {
		if _, err := os.Stat(filepath.Join(d, "project.json")); err == nil {
			return d
		}
		if filepath.Dir(d) == d {
			return cwd
		}
	}
}
