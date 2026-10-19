package yarn

// fge yarn の入口。
//
//	fge yarn build <フォルダか x.yarn>... [--out <パス>] [--vocab <パス> | --no-vocab]   読んで検査し、木の JSON を書く
//	fge yarn check <パス>...                                                           書かずに、書いてある JSON とずれていないかも見る

import (
	"bytes"
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
      知らせは「ファイル:行: 文」。読まない構文は「読まない: … — 代わりに: …」。終わりの番号: 0 書いた・1 知らせあり（書かない）。
  yarn check <パス>...
      パス（.yarn・vocab.json・dialogue.json）のフォルダごとに build と同じ検査をし、書いてある dialogue.json が
      .yarn から作り直した物と違えば 1（書かない）。コミットの前の門が流す。

読む: ノード（title: 〜 --- 〜 ===）・ヘッダ・話し手: 台詞・#タグ・-> の選択肢と字下げ・<<jump>>・<<stop>>・<<wait 秒>>・// コメント・\ のエスケープ。
読まない: 変数（<<set>>・<<declare>>）・<<if>>・{式}・関数・<<detour>>・<<once>>・=> の行のグループ・when:・[マークアップ]・ゲームを待つコマンド。
`

const (
	outName   = "dialogue.json"
	vocabName = "vocab.json"
	remake    = "make talk-vocab"
)

// Run は fge yarn の入口。workRoot はゲームのルート。
func Run(out, errOut *strings.Builder, workRoot string, args []string) int {
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
		return build(out, errOut, workRoot, paths, opts, false)
	case "check":
		return build(out, errOut, workRoot, paths, opts, true)
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

func build(out, errOut *strings.Builder, workRoot string, paths []string, opts options, checkOnly bool) int {
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
		if c := buildGroup(out, workRoot, g, opts, checkOnly); c > code {
			code = c
		}
	}
	return code
}

func buildGroup(out *strings.Builder, workRoot string, g group, opts options, checkOnly bool) int {
	outPath := opts.out
	if outPath == "" {
		outPath = filepath.Join(g.dir, outName)
	} else if !filepath.IsAbs(outPath) {
		outPath = filepath.Join(workRoot, outPath)
	}
	var vocab *Vocab
	vocabPath := ""
	if !opts.noVocab {
		vocabPath = opts.vocab
		if vocabPath == "" {
			vocabPath = filepath.Join(g.dir, vocabName)
		} else if !filepath.IsAbs(vocabPath) {
			vocabPath = filepath.Join(workRoot, vocabPath)
		}
		data, err := os.ReadFile(vocabPath)
		if err != nil {
			fmt.Fprintf(out, "%s: 語彙が無い — %s で書き出す（語彙を見ずに組むなら --no-vocab）\n", rel(workRoot, vocabPath), remake)
			return 1
		}
		v, err := ParseVocab(data)
		if err != nil {
			fmt.Fprintf(out, "%s: %v\n", rel(workRoot, vocabPath), err)
			return 1
		}
		vocab = v
		if line := suggest.Stale(workRoot, vocabPath, remake); line != "" {
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
	for _, p := range problems {
		out.WriteString(p.String() + "\n")
	}
	if len(problems) > 0 {
		fmt.Fprintf(out, "[yarn] %d 件の知らせ（%s は書かない）\n", len(problems), rel(workRoot, outPath))
		return 1
	}
	for _, p := range Unreached(prog, vocab) {
		out.WriteString("注意: " + p.String() + "\n")
	}
	data, err := Encode(prog)
	if err != nil {
		fmt.Fprintf(out, "%v\n", err)
		return 1
	}
	old, _ := os.ReadFile(outPath)
	if checkOnly {
		if !bytes.Equal(old, data) {
			fmt.Fprintf(out, "%s が .yarn とずれている — bin/fge yarn build %s で書き直す\n", rel(workRoot, outPath), rel(workRoot, g.dir))
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
