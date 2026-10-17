// Package px はドット絵を指定（<名前>.pxsrc.json）から描き、同じ型で検査する。
//
//	fge px build <spec> [--json] [--no-check] [--sheet] [--time]   描いて target に書き、report.json を作る（--sheet で見比べの PNG も）
//	fge px check [--gate <colorgate>] <sprite.json…>   手描きや assets にも色の門と形の検査をかける
//	fge px ops [--md] [--check]                 op の早見表（--md は docs/px-ops.md の中身）
//	fge px schema [--check]                     docs/pxsrc.schema.json と docs/colorgate.schema.json を作る
//	fge px help <op>                            op 1 つの説明と引数
//	fge px watch <spec> [--no-check]            保存のたびに build する
//	fge px snap <spec> [--new]                  見本つきで描き直し、fge rounds snap で周に積む（戻すのは fge rounds restore）
//	fge px diff <spec> rA rB                    2 つの周の画素の差と違反の増減
//
// 書き出し先は spec の "target"（atelier/ を指す。AI が作る素材は assets/ へ直接書かない）。
package px

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"
)

const usage = `使い方: fge px build <名前>.pxsrc.json [--json] [--no-check] [--sheet] [--time]
        fge px check [--gate <名前>.colorgate.json] <sprite.json…>
        fge px ops [--md] [--check]
        fge px schema [--check]
        fge px help <op>
        fge px watch <名前>.pxsrc.json [--no-check]
        fge px snap <名前>.pxsrc.json [--new]        （戻すのは bin/fge rounds restore <名前> rN <spec>）
        fge px diff <名前>.pxsrc.json rA rB
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
		case a == "--gate":
			if i+1 >= len(rest) {
				fmt.Fprintf(errOut, "px: --gate の後に色の門の Doc を書く\n%s", usage)
				return 2
			}
			gatePath = rest[i+1]
			i++
		case strings.HasPrefix(a, "--"):
			flags[a] = true
		default:
			pos = append(pos, a)
		}
	}
	allowed := map[string][]string{"build": {"--no-check", "--sheet", "--time"}, "check": nil, "ops": {"--md", "--check"}, "schema": {"--check"}, "help": nil,
		"watch": {"--no-check"}, "snap": {"--new"}, "diff": nil}
	if names, known := allowed[verb]; known {
		for f := range flags {
			if !slices.Contains(names, f) {
				fmt.Fprintf(errOut, "px %s: 知らない指定 %s\n%s", verb, f, usage)
				return 2
			}
		}
	}
	if gatePath != "" && verb != "check" {
		fmt.Fprintf(errOut, "px %s: --gate は check だけに書ける\n%s", verb, usage)
		return 2
	}
	switch verb {
	case "build":
		if len(pos) != 1 {
			errOut.WriteString(usage)
			return 2
		}
		return cmdBuild(out, errOut, engineRoot, workRoot, pos[0], buildOptions{RulesRoot: engineRoot, NoCheck: flags["--no-check"], Sheet: flags["--sheet"]}, flags["--time"], asJSON)
	case "check":
		if len(pos) == 0 {
			errOut.WriteString(usage)
			return 2
		}
		return cmdCheck(out, errOut, engineRoot, workRoot, gatePath, pos, asJSON)
	case "ops":
		if flags["--md"] || flags["--check"] {
			return writeOrCheck(out, errOut, engineRoot, map[string]string{"docs/px-ops.md": opsMarkdown()}, flags["--check"])
		}
		out.WriteString(opsTable())
		return 0
	case "schema":
		return writeOrCheck(out, errOut, engineRoot, map[string]string{
			"docs/pxsrc.schema.json":     specSchema(),
			"docs/colorgate.schema.json": gateSchema(),
		}, flags["--check"])
	case "watch":
		if len(pos) != 1 {
			errOut.WriteString(usage)
			return 2
		}
		return cmdWatch(errOut, engineRoot, workRoot, pos[0], flags["--no-check"])
	case "snap":
		if len(pos) != 1 {
			errOut.WriteString(usage)
			return 2
		}
		return cmdSnap(out, errOut, engineRoot, workRoot, pos[0], flags["--new"])
	case "diff":
		if len(pos) != 3 {
			errOut.WriteString(usage)
			return 2
		}
		return cmdDiff(out, errOut, engineRoot, workRoot, pos[0], pos[1], pos[2])
	case "help":
		if len(pos) != 1 {
			errOut.WriteString(usage)
			return 2
		}
		op, ok := lookupOp(pos[0])
		if !ok {
			fmt.Fprintf(errOut, "px: 知らない op %q（一覧は fge px ops）\n", pos[0])
			return 2
		}
		out.WriteString(opHelp(op))
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

func cmdBuild(out, errOut *strings.Builder, engineRoot, workRoot, spec string, opt buildOptions, timing, asJSON bool) int {
	res, err := build(workRoot, spec, opt)
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
	out.WriteString(summarize(workRoot, res))
	if timing {
		ms := func(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }
		fmt.Fprintf(out, "時間: 描く %.1f ms・検査 %.1f ms・門と書き出し %.1f ms・シート %.1f ms\n",
			ms(res.Timing.Draw), ms(res.Timing.Check), ms(res.Timing.Gate), ms(res.Timing.Sheet))
	}
	return code
}

// summarize は build の結果を 5 行以内にまとめる。
func summarize(root string, res *buildResult) string {
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
	delta := func(now int, prev func(levelCounts) int) string {
		if res.Prev == nil {
			return ""
		}
		return fmt.Sprintf("（%+d）", now-prev(*res.Prev))
	}
	sheet := "（見比べのシートは --sheet）"
	if res.Sheet != "" {
		sheet = "・見本 " + rel(root, res.Sheet)
	}
	fmt.Fprintf(&b, "%s・lint %d%s・advice %d%s%s\n", gate,
		c.Lint, delta(c.Lint, func(p levelCounts) int { return p.Lint }),
		c.Advice, delta(c.Advice, func(p levelCounts) int { return p.Advice }), sheet)
	// 上位の件は gate と lint だけ（advice は数だけ。中身は report.json と --json）。
	// 前の周に無かった物を先に、同じなら重い物を先に出す
	var top []violation
	for _, v := range res.Violations {
		if v.Level != levelAdvice {
			top = append(top, v)
		}
	}
	sort.SliceStable(top, func(i, j int) bool {
		ni, nj := !res.prevKeys[top[i].key()], !res.prevKeys[top[j].key()]
		if ni != nj {
			return ni
		}
		return top[i].Level < top[j].Level
	})
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
