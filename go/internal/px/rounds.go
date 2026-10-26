package px

// 周回の口: watch（保存のたびに build）・snap（見本を描いて fge rounds snap に積む）・
// diff（2 つの周の画素の差と違反の差）。
//
// 周を積む・戻す・止まって聞くのは fge rounds（internal/rounds）の仕事で、周の上限もそこ（rounds.json）の 1 か所。
// px snap は見本のシートを描いてから rounds snap に渡し、diff のために report.json を rN.report.json として隣に置く。
// 戻すのは fge rounds restore <名前> rN <spec>（rounds snap の案内に出る）。
//
// 置き場: debug/px/<名前>/last（build の出力）・debug/history/<名前>/rN.png・rN.<spec>・rN.report.json。

import (
	"fmt"
	"github.com/ababup1192/flixlint/go/checkres"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flix_game_engine/go/internal/rounds"
)

// liveOut は watch が結果を流す先（Run の out は戻るまで出ないので、端末へ直に書く）。
var liveOut io.Writer = os.Stdout

func specPath(workRoot, spec string) string {
	if filepath.IsAbs(spec) {
		return spec
	}
	return filepath.Join(workRoot, spec)
}

// historyDir は fge rounds が周を積む所（debug/history/<名前>）。
func historyDir(engineRoot, workRoot, spec string) (string, error) {
	r, err := rounds.LoadRules(engineRoot)
	if err != nil {
		return "", err
	}
	return filepath.Join(workRoot, filepath.FromSlash(r.HistoryDir), specName(spec)), nil
}

// cmdWatch は spec の更新を 100ms ごとに見て、変わったら build する。止めるまで戻らない。
func cmdWatch(errOut *strings.Builder, engineRoot, workRoot, spec string, noCheck bool) int {
	var last time.Time
	full := specPath(workRoot, spec)
	fmt.Fprintf(liveOut, "px watch: %s を見ている（Ctrl-C で止める）\n", rel(workRoot, full))
	for {
		st, err := os.Stat(full)
		if err == nil && st.ModTime() != last {
			last = st.ModTime()
			res, err := build(workRoot, spec, buildOptions{RulesRoot: engineRoot, NoCheck: noCheck})
			if err != nil {
				fmt.Fprintf(liveOut, "px: %v\n", err)
			} else {
				fmt.Fprint(liveOut, summarize(workRoot, res))
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// cmdSnap は今の spec で見本つきで描き直し、見本と spec を fge rounds snap で積む。
// 台本（.px.star）を渡すと gen してから、台本が書いた pxsrc（1 本）を撮り、周には台本を積む。
// maxRounds は --max N（任された上限。0 は書いていない）。
func cmdSnap(out, errOut *strings.Builder, engineRoot, workRoot, spec string, fresh bool, maxRounds int, tokens *checkres.Tokens) int {
	name, script := specName(spec), spec
	r, err := rounds.LoadRules(engineRoot)
	if err != nil {
		fmt.Fprintf(errOut, "px: %v\n", err)
		return 1
	}
	hist := filepath.Join(workRoot, filepath.FromSlash(r.HistoryDir), name)
	// 上限を超える周は描く前に断る（描いてから rounds snap に断られると、last だけ進んで周が積まれない）
	if !fresh {
		if err := rounds.CheckNext(r, hist, maxRounds); err != nil {
			fmt.Fprintf(errOut, "rounds: %v\n", err)
			return 1
		}
	}
	if strings.HasSuffix(spec, ".px.star") {
		res, err := runStar(workRoot, spec, starOptions{Stderr: errOut})
		if err != nil {
			fmt.Fprintf(errOut, "px snap: %v\n", err)
			return 1
		}
		var specs []string
		for _, f := range res.Files {
			if f.Spec {
				specs = append(specs, f.Path)
			}
		}
		if len(specs) != 1 {
			fmt.Fprintf(errOut, "px snap: 台本は pxsrc を 1 本だけ書く物にする（%s は %d 本。いくつもなら build --sheet で見る）\n", spec, len(specs))
			return 1
		}
		changed, err := writeStarFiles(workRoot, res.Files)
		if err != nil {
			fmt.Fprintf(errOut, "px snap: %v\n", err)
			return 1
		}
		fmt.Fprintf(out, "px gen: %d 本（変わった %d）← %s\n", len(res.Files), changed, spec)
		spec = specs[0]
	} else if w := staleStar(workRoot, spec); w != "" {
		fmt.Fprintln(errOut, w)
	}
	res, err := build(workRoot, spec, buildOptions{RulesRoot: engineRoot, Sheet: true})
	if err != nil {
		fmt.Fprintf(errOut, "px: %v\n", err)
		return 1
	}
	out.WriteString(summarize(workRoot, res))
	args := []string{"snap", name, res.Sheet, specPath(workRoot, script)}
	if fresh {
		args = append(args, "--new")
	}
	if maxRounds > 0 {
		args = append(args, "--max", fmt.Sprint(maxRounds))
	}
	code, err := rounds.Run(out, errOut, engineRoot, workRoot, args)
	if err != nil {
		fmt.Fprintf(errOut, "px: %v\n", err)
		return 1
	}
	if code != 0 {
		return code
	}
	n := rounds.NextRound(hist) - 1
	data, err := os.ReadFile(filepath.Join(filepath.Dir(res.Sheet), "report.json"))
	if err == nil {
		err = os.WriteFile(filepath.Join(hist, fmt.Sprintf("r%d.report.json", n)), data, 0o644)
	}
	if err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	if res.Check != nil {
		fmtRules, err := checkres.LoadRules(engineRoot)
		if err != nil {
			fmt.Fprintf(errOut, "px: %v\n", err)
			return 1
		}
		cur := *res.Check
		cur.Tokens = tokens
		_, lines, err := checkres.Snap(hist, n, cur, fmtRules)
		if err != nil {
			fmt.Fprintln(errOut, err)
			return 1
		}
		out.WriteString(lines)
	}
	return buildExit(res) // 周は積んだ上で、0 合格・1 gate・2 lint の fail だけ
}

// cmdDiff は 2 つの周の画素の差の PNG（左 rA・右 rB・差）と、違反の増減を出す。
func cmdDiff(out, errOut *strings.Builder, engineRoot, workRoot, spec, ra, rb string) int {
	dir, err := historyDir(engineRoot, workRoot, spec)
	if err != nil {
		fmt.Fprintf(errOut, "px: %v\n", err)
		return 1
	}
	a := loadPrev(filepath.Join(dir, ra+".report.json"))
	b := loadPrev(filepath.Join(dir, rb+".report.json"))
	if a == nil || b == nil {
		fmt.Fprintf(errOut, "px: %s か %s の report.json が無い（fge px snap で積んだ周を指す）\n", ra, rb)
		return 1
	}
	hexOf := map[pxlib.Key]string{}
	for _, r := range []*buildResult{a, b} {
		for k, h := range r.Hex {
			hexOf[pxlib.Key(k)] = h
		}
	}
	aRows := map[string][]string{}
	for _, f := range a.Frames {
		aRows[f.Sprite+"/"+f.Name] = f.Rows
	}
	var frames []pxlib.SheetFrame
	changed := 0
	for _, f := range b.Frames {
		sf := pxlib.SheetFrame{Px: colorsOf(f.Rows, b.Legend, hexOf)}
		if rows, ok := aRows[f.Sprite+"/"+f.Name]; ok {
			sf.Prev = colorsOf(rows, a.Legend, hexOf)
			if strings.Join(rows, "/") != strings.Join(f.Rows, "/") {
				changed++
			}
		}
		frames = append(frames, sf)
	}
	png := filepath.Join(dir, fmt.Sprintf("diff-%s-%s.png", ra, rb))
	if err := pxlib.WritePNG(png, pxlib.Sheet(frames, groundColor(""), 4)); err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	keys := func(r *buildResult) map[string]violation {
		m := map[string]violation{}
		for _, v := range r.Violations {
			m[v.key()] = v
		}
		return m
	}
	ka, kb := keys(a), keys(b)
	var added, removed []string
	for k, v := range kb {
		if _, ok := ka[k]; !ok {
			added = append(added, v.String())
		}
	}
	for k, v := range ka {
		if _, ok := kb[k]; !ok {
			removed = append(removed, v.String())
		}
	}
	sort.Strings(added)
	sort.Strings(removed)
	fmt.Fprintf(out, "px diff %s → %s: 変わったコマ %d・違反 増えた %d・消えた %d → %s\n", ra, rb, changed, len(added), len(removed), rel(workRoot, png))
	for i, l := range added {
		if i == 5 {
			break
		}
		fmt.Fprintf(out, "  + %s\n", l)
	}
	for i, l := range removed {
		if i == 5 {
			break
		}
		fmt.Fprintf(out, "  - %s\n", l)
	}
	// code ごとの got の差（rN.check.json がある周どうし）
	na, errA := strconv.Atoi(strings.TrimPrefix(ra, "r"))
	nb, errB := strconv.Atoi(strings.TrimPrefix(rb, "r"))
	if errA == nil && errB == nil {
		ha, hb := checkres.LoadHistory(dir, na+1), checkres.LoadHistory(dir, nb+1)
		if len(ha) > 0 && len(hb) > 0 {
			ca, cb := ha[len(ha)-1], hb[len(hb)-1]
			fmt.Fprintf(out, "検査 %s → %s: score %d → %d\n", ra, rb, ca.Summary.Score, cb.Summary.Score)
			for _, l := range checkres.DeltaLines(checkres.Compare(ca.Results, cb.Results), 8) {
				fmt.Fprintf(out, "  %s\n", l)
			}
		}
	}
	return 0
}
