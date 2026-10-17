// Package px はドット絵を指定（<名前>.pxsrc.json）から描き、同じ型で検査する。
//
//	fge px build <spec> [--json] [--no-check]   描いて target に書き、見本と report.json を作る
//	fge px check [--gate <colorgate>] <sprite.json…>   手描きや assets にも色の門と形の検査をかける
//	fge px ops [--md] [--check]                 op の早見表（--md は docs/px-ops.md の中身）
//	fge px schema [--check]                     docs/pxsrc.schema.json と docs/colorgate.schema.json を作る
//	fge px help <op>                            op 1 つの説明と引数
//
// 書き出し先は spec の "target"（atelier/ を指す。AI が作る素材は assets/ へ直接書かない）。
package px

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const usage = `使い方: fge px build <名前>.pxsrc.json [--json] [--no-check]
        fge px check [--gate <名前>.colorgate.json] <sprite.json…>
        fge px ops [--md] [--check]
        fge px schema [--check]
        fge px help <op>
`

// Run は fge px の入口。engineRoot は検査の閾値と docs/ を読むリポジトリ、workRoot は指定のパスの起点。
func Run(out, errOut *strings.Builder, engineRoot, workRoot string, args []string, asJSON bool) int {
	if len(args) == 0 {
		errOut.WriteString(usage)
		return 2
	}
	verb, rest := args[0], args[1:]
	flags := map[string]bool{}
	var pos []string
	gatePath := ""
	for i := 0; i < len(rest); i++ {
		switch a := rest[i]; {
		case a == "--gate" && i+1 < len(rest):
			gatePath = rest[i+1]
			i++
		case strings.HasPrefix(a, "--"):
			flags[a] = true
		default:
			pos = append(pos, a)
		}
	}
	switch verb {
	case "build":
		if len(pos) != 1 {
			errOut.WriteString(usage)
			return 2
		}
		return cmdBuild(out, errOut, engineRoot, workRoot, pos[0], flags["--no-check"], asJSON)
	case "check":
		if len(pos) == 0 {
			errOut.WriteString(usage)
			return 2
		}
		return cmdCheck(out, errOut, engineRoot, workRoot, gatePath, pos, asJSON)
	case "ops":
		if flags["--md"] || flags["--check"] {
			return writeOrCheck(out, errOut, engineRoot, map[string]string{"docs/px-ops.md": OpsMarkdown()}, flags["--check"])
		}
		out.WriteString(OpsTable())
		return 0
	case "schema":
		return writeOrCheck(out, errOut, engineRoot, map[string]string{
			"docs/pxsrc.schema.json":     SpecSchema(),
			"docs/colorgate.schema.json": GateSchema(),
		}, flags["--check"])
	case "help":
		if len(pos) != 1 {
			errOut.WriteString(usage)
			return 2
		}
		op, ok := LookupOp(pos[0])
		if !ok {
			fmt.Fprintf(errOut, "px: 知らない op %q（一覧は fge px ops）\n", pos[0])
			return 2
		}
		out.WriteString(OpHelp(op))
		return 0
	}
	fmt.Fprintf(errOut, "px: 知らない動詞 %q\n%s", verb, usage)
	return 2
}

// writeOrCheck は生成物を書く。check なら書かずに、ずれた物を挙げて 1 を返す。
func writeOrCheck(out, errOut *strings.Builder, root string, files map[string]string, check bool) int {
	names := make([]string, 0, len(files))
	for n := range files {
		names = append(names, n)
	}
	sort.Strings(names)
	code := 0
	for _, n := range names {
		path := filepath.Join(root, filepath.FromSlash(n))
		if check {
			cur, _ := os.ReadFile(path)
			if string(cur) != files[n] {
				fmt.Fprintf(errOut, "px: %s が op の登録とずれている（bin/fge px ops --md・bin/fge px schema で作り直す）\n", n)
				code = 1
			}
			continue
		}
		if err := os.WriteFile(path, []byte(files[n]), 0o644); err != nil {
			fmt.Fprintln(errOut, err)
			return 1
		}
		fmt.Fprintf(out, "px: %s を書いた\n", n)
	}
	return code
}

func cmdBuild(out, errOut *strings.Builder, engineRoot, workRoot, spec string, noCheck, asJSON bool) int {
	res, err := Build(workRoot, spec, Options{RulesRoot: engineRoot, NoCheck: noCheck})
	if err != nil {
		fmt.Fprintf(errOut, "px: %v\n", err)
		return 1
	}
	code := 0
	if !res.Wrote {
		code = 1
	}
	if asJSON {
		data, _ := json.MarshalIndent(res, "", "  ")
		out.Write(append(data, '\n'))
		return code
	}
	out.WriteString(Summary(workRoot, res))
	return code
}

// Summary は build の結果を 5 行以内にまとめる。
func Summary(root string, res *Result) string {
	same, changed, added := 0, 0, 0
	for _, f := range res.Frames {
		switch {
		case !f.HadBase:
			added++
		case f.Same:
			same++
		default:
			changed++
		}
	}
	var b strings.Builder
	dest := res.Target
	if !res.Wrote {
		dest += " は書かなかった（色の門）"
	}
	fmt.Fprintf(&b, "px: %d コマ（base と同じ %d・変わった %d・新しい %d）→ %s（%d ms）\n",
		len(res.Frames), same, changed, added, dest, res.Elapsed.Milliseconds())
	c := res.Count()
	gate := "門 OK"
	if c.Gate > 0 {
		gate = fmt.Sprintf("門 NG %d", c.Gate)
	}
	if len(res.Known) > 0 {
		gate += fmt.Sprintf("（known %d 色）", len(res.Known))
	}
	delta := func(now int, prev func(Counts) int) string {
		if res.Prev == nil {
			return ""
		}
		return fmt.Sprintf("（%+d）", now-prev(*res.Prev))
	}
	fmt.Fprintf(&b, "%s・lint %d%s・advice %d%s・見本 %s\n", gate,
		c.Lint, delta(c.Lint, func(p Counts) int { return p.Lint }),
		c.Advice, delta(c.Advice, func(p Counts) int { return p.Advice }), rel(root, res.Sheet))
	top := append([]Violation(nil), res.Violations...)
	sort.SliceStable(top, func(i, j int) bool { return top[i].Level < top[j].Level })
	for i, v := range top {
		if i == 3 {
			break
		}
		fmt.Fprintf(&b, "  %s\n", v.String())
	}
	return b.String()
}

// findGate は --gate が無いときに art/*.colorgate.json を 1 つ探す。
func findGate(root string) (string, error) {
	found, _ := filepath.Glob(filepath.Join(root, "art", "*.colorgate.json"))
	if len(found) != 1 {
		return "", fmt.Errorf("色の門の Doc を 1 つに決められない（art/*.colorgate.json が %d 個。--gate で指す）", len(found))
	}
	r, _ := filepath.Rel(root, found[0])
	return r, nil
}

func rel(root, p string) string {
	if r, err := filepath.Rel(root, p); err == nil && !strings.HasPrefix(r, "..") {
		return r
	}
	return p
}
