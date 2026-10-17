// Package px はドット絵を指定（<名前>.pxsrc.json）から描き、同じ型で検査する。
//
//	fge px build <spec> [--json] [--no-check] [--sheet] [--time] [--png]   描いて target に書き、report.json を作る
//	fge px check [--gate <colorgate>] <sprite.json…>   手描きや assets にも色の門と形の検査をかける
//	fge px ops [--md] [--check]                 op の早見表（--md は docs/px-ops.md を書く）
//	fge px schema [--write] [--check]           docs/pxsrc.schema.json と docs/colorgate.schema.json（既定は表示だけ）
//	fge px help [<op>|<コマンド>]               コマンド・機種の style の一覧か、1 つの説明
//	fge px watch <spec> [--no-check]            保存のたびに build する
//	fge px snap <spec|台本> [--new] [--max N]   見本つきで描き直し、fge rounds snap で周に積む（戻すのは fge rounds restore）
//	fge px diff <spec> rA rB                    2 つの周の画素の差と違反の増減
//	fge px gen <名前>.px.star                   台本を走らせ、台本が書く pxsrc・JSON を書き出す（star.go）
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
	"strconv"
	"strings"
	"time"
)

const usage = `使い方: fge px build <名前>.pxsrc.json|<名前>.px.star [--json] [--no-check] [--sheet] [--time] [--png]
        fge px gen <名前>.px.star
        fge px check [--gate <名前>.colorgate.json] <sprite.json…>
        fge px ops [--md] [--check]
        fge px schema [--write] [--check]
        fge px help [<op>|<コマンド>]
        fge px watch <名前>.pxsrc.json [--no-check]
        fge px snap <名前>.pxsrc.json|<名前>.px.star [--new] [--max N]   （戻すのは bin/fge rounds restore <名前> rN <spec>）
        fge px diff <名前>.pxsrc.json rA rB
`

// cmdHelps は fge px help <コマンド> の説明（op でないコマンド）。
var cmdHelps = map[string]string{
	"build": `fge px build <名前>.pxsrc.json|<名前>.px.star [--json] [--no-check] [--sheet] [--time] [--png]
  指定を描いて target の sprite.json に書き、debug/px/<名前>/last/report.json を作る（色の門を外れたら書かずに 1）。
  台本（.px.star）はメモリの中で走らせる（pxsrc・色票はファイルに書かない。書くなら gen）。
  --sheet  見比べのシート（sheet.png・前の周との差・玉ねぎの皮）も書く
  --png    debug/px/<名前>/png/ に、スプライトごとの 1 コマ目の実寸（<名>.png）と 4 倍（<名>@4x.png）、
           全コマを横に並べた実寸と 4 倍（<名>.strip.png・<名>.strip@4x.png）を書く（透明はそのまま）。
           2 コマ以上なら 2 倍でコマを回す <名>.gif（1 コマ 200ms・減色しない・同じ絵から同じバイト）も書く
  --no-check  lint と advice を回さない（色の門は回す）   --time  時間の内訳   --json  結果を JSON で
`,
	"gen": `fge px gen <名前>.px.star
  台本を走らせ、台本が書く pxsrc・色票・JSON をファイルへ書く（中身が同じ物は触らない）。
  台本の中のパスは台本のフォルダが起点（// で始めると作業場の根から）。書ける物は docs/px-ops.md の「台本」。
`,
	"check": `fge px check [--gate <名前>.colorgate.json] <sprite.json…>
  手描きや assets の sprite.json にも、色の門と形の検査をかける（--gate を省くと art/*.colorgate.json を 1 つ探す）。
`,
	"ops": `fge px ops [--md] [--check]
  op の 1 行の一覧。--md は docs/px-ops.md を書き、--check はずれていれば 1（書かない）。
`,
	"schema": `fge px schema [--write] [--check]
  docs/pxsrc.schema.json と docs/colorgate.schema.json の中身を表示する（既定は書かない）。
  --write で docs/ へ書き、--check はずれていれば 1。
`,
	"watch": `fge px watch <名前>.pxsrc.json [--no-check]
  保存のたびに build して、まとめの行を出す（Ctrl-C で止める）。
`,
	"snap": `fge px snap <名前>.pxsrc.json|<名前>.px.star [--new] [--max N]
  見本つきで描き直し、bin/fge rounds snap で debug/history/<名前>/rN に積む（台本も同じ番号で残す）。
  台本（.px.star）を渡すと gen してから撮る（pxsrc を 1 本だけ書く台本）。pxsrc を渡した時に、
  同じフォルダの台本の方が新しく中身が違えば警告する。
  --new    前の周回を退けて r1 から始める（別の作業の時）
  --max N  依頼主か親から「N 周まで任せる」と言われた時の上限（rounds.json の maxRounds まで）。
           一度書けば同じ周回の間は覚えていて、N 周までは止まって聞かずに進み、N 周目で報告へ積む案内を出す。
  戻すのは bin/fge rounds restore <名前> rN <spec>。
`,
	"diff": `fge px diff <名前>.pxsrc.json rA rB
  snap で積んだ 2 つの周の画素の差（左 rA・右 rB・差）の PNG と、違反の増減を出す。
`,
	"help": `fge px help [<op>|<コマンド>]
  引数なしでコマンドと機種の style の一覧。op の名前なら引数と例、コマンドの名前ならその使い方。
`,
}

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
	maxRounds := 0
	for i := 0; i < len(rest); i++ {
		switch a := rest[i]; {
		case a == "--gate":
			if i+1 >= len(rest) {
				fmt.Fprintf(errOut, "px: --gate の後に色の門の Doc を書く\n%s", usage)
				return 2
			}
			gatePath = rest[i+1]
			i++
		case a == "--max":
			n := 0
			if i+1 < len(rest) {
				n, _ = strconv.Atoi(rest[i+1])
			}
			if n < 1 {
				fmt.Fprintf(errOut, "px: --max の後に任された周の数（1 以上の整数）を書く\n%s", usage)
				return 2
			}
			maxRounds = n
			flags[a] = true
			i++
		case strings.HasPrefix(a, "--"):
			flags[a] = true
		default:
			pos = append(pos, a)
		}
	}
	allowed := map[string][]string{"build": {"--no-check", "--sheet", "--time", "--png"}, "check": nil, "ops": {"--md", "--check"}, "schema": {"--check", "--write"}, "help": nil,
		"watch": {"--no-check"}, "snap": {"--new", "--max"}, "diff": nil, "gen": nil}
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
		opt := buildOptions{RulesRoot: engineRoot, NoCheck: flags["--no-check"], Sheet: flags["--sheet"], PNG: flags["--png"]}
		if strings.HasSuffix(pos[0], ".star") {
			return cmdBuildStar(out, errOut, engineRoot, workRoot, pos[0], opt, flags["--time"], asJSON)
		}
		if w := staleStar(workRoot, pos[0]); w != "" {
			fmt.Fprintln(errOut, w)
		}
		return cmdBuild(out, errOut, engineRoot, workRoot, pos[0], opt, flags["--time"], asJSON)
	case "gen":
		if len(pos) != 1 {
			errOut.WriteString(usage)
			return 2
		}
		return cmdGen(out, errOut, workRoot, pos[0])
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
		files := map[string]string{"docs/pxsrc.schema.json": specSchema(), "docs/colorgate.schema.json": gateSchema()}
		if !flags["--write"] && !flags["--check"] {
			// 既定は表示だけ（引数なしで打って docs/ を書き替えない）
			for _, n := range []string{"docs/pxsrc.schema.json", "docs/colorgate.schema.json"} {
				fmt.Fprintf(out, "// %s（書くのは --write）\n%s", n, files[n])
			}
			return 0
		}
		return writeOrCheck(out, errOut, engineRoot, files, flags["--check"])
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
		return cmdSnap(out, errOut, engineRoot, workRoot, pos[0], flags["--new"], maxRounds)
	case "diff":
		if len(pos) != 3 {
			errOut.WriteString(usage)
			return 2
		}
		return cmdDiff(out, errOut, engineRoot, workRoot, pos[0], pos[1], pos[2])
	case "help":
		switch {
		case len(pos) == 0:
			return cmdHelpIndex(out, errOut, engineRoot)
		case len(pos) != 1:
			errOut.WriteString(usage)
			return 2
		}
		if h, ok := cmdHelps[pos[0]]; ok {
			out.WriteString(h)
			return 0
		}
		op, ok := lookupOp(pos[0])
		if !ok {
			fmt.Fprintf(errOut, "px: 知らない op かコマンド %q（op の一覧は fge px ops・コマンドの一覧は fge px help）\n", pos[0])
			return 2
		}
		out.WriteString(opHelp(op))
		return 0
	}
	fmt.Fprintf(errOut, "px: 知らない動詞 %q\n%s", verb, usage)
	return 2
}

// cmdHelpIndex は fge px help（引数なし）: コマンドと機種の style（色数の上限）の一覧。
func cmdHelpIndex(out, errOut *strings.Builder, engineRoot string) int {
	out.WriteString(usage)
	out.WriteString("\nコマンドの説明は fge px help <コマンド>、op の一覧は fge px ops、op 1 つは fge px help <op>。\n\n機種の style（pxsrc の \"style\"。*.pxstyle.json も書ける）:\n")
	data, err := os.ReadFile(filepath.Join(engineRoot, "bin", "lint-rules", "px.json"))
	if err != nil {
		fmt.Fprintf(errOut, "px: 機種の決まり（bin/lint-rules/px.json）が読めない: %v\n", err)
		return 1
	}
	var r pxRules
	if err := json.Unmarshal(data, &r); err != nil {
		fmt.Fprintf(errOut, "px: bin/lint-rules/px.json が壊れている: %v\n", err)
		return 1
	}
	names := make([]string, 0, len(r.Styles))
	for n := range r.Styles {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		st := r.Styles[n]
		var lim []string
		if st.MaxColors > 0 {
			lim = append(lim, fmt.Sprintf("1 コマ %d 色", st.MaxColors))
		} else {
			lim = append(lim, "色数の縛りなし")
		}
		if st.MaxTileColors > 0 {
			lim = append(lim, fmt.Sprintf("升目 %dx%d に %d 色", st.Tile[0], st.Tile[1], st.MaxTileColors))
		}
		if st.ChannelLevels > 0 {
			lim = append(lim, fmt.Sprintf("RGB 各 %d 段", st.ChannelLevels))
		}
		if len(st.Colors) > 0 {
			lim = append(lim, fmt.Sprintf("使える色 %d 色", len(st.Colors)))
		}
		fmt.Fprintf(out, "  %-8s %s（%s）\n", n, st.Label, strings.Join(lim, "・"))
	}
	out.WriteString("（どれも透明を除く。色の門の画風の上に乗る縛り）\n")
	return 0
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
				fmt.Fprintf(errOut, "px: %s が op の登録とずれている（bin/fge px ops --md・bin/fge px schema --write で作り直す）\n", n)
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
	if res.PNGDir != "" {
		sheet += "・PNG " + rel(root, res.PNGDir) + "/"
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
	// コマだけが違う同じ違反はまとめて 1 件にし、何コマで出たかを添える
	var groups []violation
	frames := map[string]int{}
	for _, v := range top {
		k := v.frameless()
		if frames[k] == 0 {
			groups = append(groups, v)
		}
		frames[k]++
	}
	for i, v := range groups {
		if i == 3 {
			fmt.Fprintf(&b, "  ほか %d 件（全 %d 件。全部は debug/px/%s/last/report.json か --json）\n", len(groups)-3, len(groups), specName(res.Spec))
			break
		}
		if n := frames[v.frameless()]; n > 1 {
			v.Frame = fmt.Sprintf("%d コマ", n)
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
