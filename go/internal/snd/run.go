package snd

// fge snd の口。
//
//	fge snd build <x.snd.star|x.sndsrc.json>... [--check]   鳴らして検査し、gate を通れば target の WAV を書く
//	fge snd gen <x.snd.star>                                 台本が書いた sndsrc と譜面をファイルへ書く
//	fge snd snap <x.snd.star|x.sndsrc.json> [--new] [--max N] build して、書いた WAV を fge rounds の周に積む
//	fge snd compare <前.wav> <後.wav> [--match <フォルダ> --name <名前>]   2 本の差（長さ・ループの頭・音量・差の音）
//	fge snd bars <x.wav> --bpm N                            小節ごとの音量・帯・左右の広がり（bars.go）
//	fge snd ops [--md]・fge snd schema [--write]              op の一覧と spec の JSON Schema（op の登録から作る）

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/checklevel"
	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
	"github.com/ababup1192/flix_game_engine/go/internal/rounds"
	"github.com/ababup1192/flix_game_engine/go/internal/starbox"
)

const usage = `使い方: bin/fge snd <口> ...   音の指定（*.sndsrc.json・台本 *.snd.star）を鳴らして検査する（ゲームのルートで流す）

  snd build <x.snd.star か x.sndsrc.json>... [--check]
      鳴らして検査し、gate を通れば target の WAV を書く（--check は検査だけ。既定はステレオ・"channels": "mono" で 1 本）。
      検査の結果は debug/snd/<名前>/report.json（check に score・next・1 件ずつの code・got・want・gap・fix）・
      波形は debug/snd/<名前>/sheet.png。終了コード: 0 合格・1 gate（WAV を書かない）・2 lint の fail だけ（near と advice は 0）。
  snd gen <x.snd.star>          台本が書いた sndsrc と譜面（write_chip）をファイルへ書く（中身が同じ物は触らない）
  snd snap <x.snd.star か x.sndsrc.json> [--new] [--max N] [--tokens 使った/予算]
      build して、書いた WAV（複数なら 0.25 秒の無音で 1 本につないだ物）を fge rounds の周に積む。
      周の検査は rN.check.json に積み、前の周との差・next・stop（止め時の判定）を出す（docs/check-results.md）
  snd compare <前.wav> <後.wav> [--match <フォルダ> --name <名前>]
      2 本の差: サンプル数・ループの頭・LUFS・差の音の RMS（dBFS）と一番大きい所。
      --match は 2 本を同じ LUFS にそろえて <フォルダ>/<名前>.old.wav・<名前>.new.wav に書く（聞き比べ用）
  snd bars <x.wav> --bpm <速さ> [--beats 4]
      曲を小節ごとに測る: 音量（K 特性）・低中高の帯・左右の広がり。ループの頭と一番大きい小節に印（山場と継ぎ目の下見）
  snd ops [--md]                op の一覧（--md は docs/snd-ops.md の本文）
  snd schema [--write]          sndsrc の JSON Schema（--write は docs/snd-ops.md と docs/sndsrc.schema.json を書き直す）

機種の縛りと検査の閾値は bin/lint-rules/snd.json。
`

// Run は fge snd の入口。engineRoot は規約データと docs の置き場、workRoot はゲームのルート。
func Run(out, errOut *strings.Builder, engineRoot, workRoot string, args []string, asJSON bool) int {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" || args[0] == "help" {
		out.WriteString(usage)
		if len(args) == 0 {
			return 2
		}
		return 0
	}
	rest := args[1:]
	switch args[0] {
	case "build":
		return cmdBuild(out, errOut, engineRoot, workRoot, rest, asJSON)
	case "gen":
		return cmdGen(out, errOut, workRoot, rest)
	case "snap":
		return cmdSnap(out, errOut, engineRoot, workRoot, rest)
	case "compare":
		return cmdCompare(out, errOut, workRoot, rest, asJSON)
	case "bars":
		return cmdBars(out, errOut, workRoot, rest)
	case "ops":
		if len(rest) > 0 && rest[0] == "--md" {
			out.WriteString(opsMarkdown())
		} else {
			out.WriteString(opsText())
		}
		return 0
	case "schema":
		if len(rest) > 0 && rest[0] == "--write" {
			return writeDocs(out, errOut, engineRoot)
		}
		data, _ := json.MarshalIndent(schema(), "", "  ")
		out.Write(append(data, '\n'))
		return 0
	}
	fmt.Fprintf(errOut, "snd: 知らない口: %s\n\n%s", args[0], usage)
	return 2
}

// specsOf は引数（台本か sndsrc）から spec を集める。台本は走らせて、書いた sndsrc をメモリから読む。
func specsOf(errOut *strings.Builder, workRoot string, paths []string) ([]*spec, []string, bool) {
	var specs []*spec
	var advice []string
	for _, p := range paths {
		if strings.HasSuffix(p, starSuffix) {
			res, err := runStar(workRoot, p, starbox.Options{Stderr: os.Stderr})
			if err != nil {
				fmt.Fprintf(errOut, "snd: %v\n", err)
				return nil, nil, false
			}
			advice = append(advice, res.Advice...)
			if len(res.Files) == 0 {
				fmt.Fprintf(errOut, "snd: %s は sndsrc を 1 本も書かなかった（snd.write_spec）\n", p)
				return nil, nil, false
			}
			chips := map[string][]byte{}
			for _, f := range res.Files {
				if strings.HasSuffix(f.Path, ".chip.json") {
					chips[f.Path] = f.Data
				}
			}
			for _, f := range res.Files {
				if !strings.HasSuffix(f.Path, ".sndsrc.json") {
					continue
				}
				s, err := parseSpec(f.Path, f.Data)
				if err != nil {
					fmt.Fprintf(errOut, "snd: %v\n", err)
					return nil, nil, false
				}
				s.Files = chips
				specs = append(specs, s)
			}
			continue
		}
		s, err := loadSpec(workRoot, p)
		if err != nil {
			fmt.Fprintf(errOut, "snd: %v\n", err)
			return nil, nil, false
		}
		specs = append(specs, s)
	}
	return specs, advice, true
}

func cmdBuild(out, errOut *strings.Builder, engineRoot, workRoot string, args []string, asJSON bool) int {
	check := false
	var paths []string
	for _, a := range args {
		if a == "--check" {
			check = true
		} else {
			paths = append(paths, a)
		}
	}
	if len(paths) == 0 {
		errOut.WriteString("snd build: 台本か sndsrc を 1 つ以上渡す\n")
		return 2
	}
	results, advice, code, ok := buildPaths(errOut, engineRoot, workRoot, paths, check)
	if !ok {
		return 1
	}
	if asJSON {
		// 標準出力は詰めた形: 音ごとの要点と新しい形の check（古い findings は report.json に全部ある）
		var brief []map[string]any
		for _, br := range results {
			chk := any(br.Check.Brief())
			if br.Report == "" {
				chk = br.Check // --check は report.json を書かないので、1 件ずつの全部もここに出す
			}
			brief = append(brief, map[string]any{"spec": br.Spec, "target": br.Target, "wrote": br.Wrote, "seconds": br.Seconds,
				"lufs": br.LUFS, "peakDbfs": br.PeakDBFS, "truePeakDbtp": br.TruePeak, "report": br.Report, "check": chk})
		}
		out.Write(checkres.Compact(map[string]any{"results": brief, "advice": advice, "exit": code}))
		return code
	}
	for _, br := range results {
		out.WriteString(br.summary())
	}
	for _, a := range advice {
		out.WriteString("advice " + a + "\n")
	}
	return code
}

// buildPaths は台本か sndsrc を全部鳴らして検査する。code は 1 gate・2 lint の fail だけ・0（near と advice は 0）。
func buildPaths(errOut *strings.Builder, engineRoot, workRoot string, paths []string, check bool) ([]*buildResult, []string, int, bool) {
	specs, advice, ok := specsOf(errOut, workRoot, paths)
	if !ok {
		return nil, nil, 1, false
	}
	code := 0
	var results []*buildResult
	for _, s := range specs {
		br, err := buildSpec(engineRoot, workRoot, s, buildOptions{NoWrite: check})
		if err != nil {
			fmt.Fprintf(errOut, "snd: %v\n", err)
			return nil, nil, 1, false
		}
		code = checkres.WorseExit(code, br.Check.Summary.Exit)
		results = append(results, br)
	}
	return results, advice, code, true
}

func cmdGen(out, errOut *strings.Builder, workRoot string, args []string) int {
	if len(args) != 1 || !strings.HasSuffix(args[0], starSuffix) {
		errOut.WriteString("snd gen: <名前>.snd.star を 1 つ渡す\n")
		return 2
	}
	res, err := runStar(workRoot, args[0], starbox.Options{Stderr: os.Stderr})
	if err != nil {
		fmt.Fprintf(errOut, "snd: %v\n", err)
		return 1
	}
	changed := 0
	for _, f := range res.Files {
		full := filepath.Join(workRoot, filepath.FromSlash(f.Path))
		if old, err := os.ReadFile(full); err == nil && string(old) == string(f.Data) {
			continue
		}
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			fmt.Fprintf(errOut, "snd: %v\n", err)
			return 1
		}
		if err := os.WriteFile(full, f.Data, 0o644); err != nil {
			fmt.Fprintf(errOut, "snd: %v\n", err)
			return 1
		}
		changed++
	}
	fmt.Fprintf(out, "%s: sndsrc と譜面 %d 本（書き替え %d・手数 %d）\n", args[0], len(res.Files), changed, res.Steps)
	for _, a := range res.Advice {
		out.WriteString("advice " + a + "\n")
	}
	return 0
}

func cmdSnap(out, errOut *strings.Builder, engineRoot, workRoot string, args []string) int {
	var paths, flags []string
	var tokens *checkres.Tokens
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--tokens":
			if i+1 >= len(args) {
				errOut.WriteString("snd snap: --tokens の後に 使った/予算 を書く\n")
				return 2
			}
			t, err := checkres.ParseTokens(args[i+1])
			if err != nil {
				fmt.Fprintf(errOut, "snd snap: %v\n", err)
				return 2
			}
			tokens = t
			i++
		case "--new":
			flags = append(flags, args[i])
		case "--max":
			if i+1 < len(args) {
				flags = append(flags, args[i], args[i+1])
				i++
			}
		default:
			paths = append(paths, args[i])
		}
	}
	if len(paths) != 1 {
		errOut.WriteString("snd snap: 台本か sndsrc を 1 つ渡す\n")
		return 2
	}
	results, _, buildCode, ok := buildPaths(errOut, engineRoot, workRoot, paths, false)
	if !ok {
		return 1
	}
	for _, br := range results {
		out.WriteString(br.summary())
	}
	if buildCode == 1 {
		return 1 // gate で WAV を書かなかった（周に積む物が無い）
	}
	specs, _, _ := specsOf(errOut, workRoot, paths)
	var clips [][][]float64
	rate, nc := 0, 1
	for _, s := range specs {
		data, err := os.ReadFile(filepath.Join(workRoot, filepath.FromSlash(s.Target)))
		if err != nil {
			fmt.Fprintf(errOut, "snd: %v\n", err)
			return 1
		}
		c, err := DecodeWAV(data)
		if err != nil {
			fmt.Fprintf(errOut, "snd: %s: %v\n", s.Target, err)
			return 1
		}
		rate, nc = c.Rate, max(nc, len(c.Chans))
		clips = append(clips, c.Chans)
	}
	joined := make([][]float64, nc)
	for i, c := range clips {
		for k := range joined {
			if i > 0 {
				joined[k] = append(joined[k], make([]float64, rate/4)...)
			}
			joined[k] = append(joined[k], c[min(k, len(c)-1)]...) // モノラルは左右に同じ物
		}
	}
	name := specName(paths[0])
	wav := filepath.Join(workRoot, "debug", "snd", name, "round.wav")
	if err := os.MkdirAll(filepath.Dir(wav), 0o755); err != nil {
		fmt.Fprintf(errOut, "snd: %v\n", err)
		return 1
	}
	if err := os.WriteFile(wav, EncodeWAV(rate, joined, -1), 0o644); err != nil {
		fmt.Fprintf(errOut, "snd: %v\n", err)
		return 1
	}
	var o, e strings.Builder
	code, err := rounds.Run(&o, &e, engineRoot, workRoot, append([]string{"snap", name, wav, paths[0]}, flags...))
	out.WriteString(o.String())
	errOut.WriteString(e.String())
	if err != nil {
		fmt.Fprintf(errOut, "snd: %v\n", err)
		return 1
	}
	if code != 0 {
		return code
	}
	// 周の検査（全部の spec の結果を 1 つの周に）: 前の周との差・next・stop
	fmtRules, err := checkres.LoadRules(engineRoot)
	if err != nil {
		fmt.Fprintf(errOut, "snd: %v\n", err)
		return 1
	}
	var all []checkres.Result
	for _, br := range results {
		all = append(all, br.Check.Results...)
	}
	rr, err := rounds.LoadRules(engineRoot)
	if err != nil {
		fmt.Fprintf(errOut, "snd: %v\n", err)
		return 1
	}
	hist := filepath.Join(workRoot, filepath.FromSlash(rr.HistoryDir), name)
	cur := checkres.Round{Summary: checkres.Summarize(all, fmtRules, nil), Results: all, Tokens: tokens}
	cur.Summary.Applied = map[string]checklevel.Applied{}
	for _, br := range results {
		for k, v := range br.Check.Summary.Applied {
			cur.Summary.Applied[k] = v
		}
	}
	_, lines, err := checkres.Snap(hist, rounds.NextRound(hist)-1, cur, fmtRules)
	if err != nil {
		fmt.Fprintf(errOut, "snd: %v\n", err)
		return 1
	}
	out.WriteString(lines)
	return buildCode
}

// ── compare ──

type compareResult struct {
	A, B               string
	Rate               int
	SamplesA, SamplesB int
	LoopA, LoopB       int
	LUFSA, LUFSB       float64
	DiffRMSDBFS        float64 // 差の音の RMS（短い方の長さで）
	DiffPeakDBFS       float64
	DiffPeakAt         float64 // 秒
	Differ             int     // 違うサンプルの数
	FirstDiffAt        float64 // 秒（-1 は同じ）
	SameBytes          bool
}

func cmdCompare(out, errOut *strings.Builder, workRoot string, args []string, asJSON bool) int {
	var paths []string
	matchDir, name := "", ""
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--match":
			if i+1 < len(args) {
				matchDir = args[i+1]
				i++
			}
		case "--name":
			if i+1 < len(args) {
				name = args[i+1]
				i++
			}
		default:
			paths = append(paths, args[i])
		}
	}
	if len(paths) != 2 || (matchDir != "") != (name != "") {
		errOut.WriteString("snd compare: <前.wav> <後.wav> [--match <フォルダ> --name <名前>]\n")
		return 2
	}
	read := func(p string) (Clip, []byte, bool) {
		data, err := os.ReadFile(filepath.Join(workRoot, p))
		if filepath.IsAbs(p) {
			data, err = os.ReadFile(p)
		}
		if err != nil {
			fmt.Fprintf(errOut, "snd: %v\n", err)
			return Clip{}, nil, false
		}
		c, err := DecodeWAV(data)
		if err != nil {
			fmt.Fprintf(errOut, "snd: %s: %v\n", p, err)
			return Clip{}, nil, false
		}
		return c, data, true
	}
	a, da, ok1 := read(paths[0])
	b, db, ok2 := read(paths[1])
	if !ok1 || !ok2 {
		return 1
	}
	if a.Rate != b.Rate {
		fmt.Fprintf(errOut, "snd compare: サンプルレートが違う（%d と %d）\n", a.Rate, b.Rate)
		return 1
	}
	if len(a.Chans) != len(b.Chans) {
		fmt.Fprintf(errOut, "snd compare: チャンネルの数が違う（%d と %d）\n", len(a.Chans), len(b.Chans))
		return 1
	}
	r := compareResult{A: paths[0], B: paths[1], Rate: a.Rate, SamplesA: a.Frames(), SamplesB: b.Frames(),
		LoopA: a.LoopStart, LoopB: b.LoopStart, LUFSA: finite(LUFS(a.Rate, a.Chans)), LUFSB: finite(LUFS(b.Rate, b.Chans)),
		FirstDiffAt: -1, SameBytes: string(da) == string(db)}
	nc := len(a.Chans)
	n := min(len(a.Ints), len(b.Ints))
	sum, peak, at := 0.0, 0.0, 0
	for i := 0; i < n; i++ {
		d := float64(int(a.Ints[i])-int(b.Ints[i])) / 32768
		if d != 0 {
			r.Differ++
			if r.FirstDiffAt < 0 {
				r.FirstDiffAt = float64(i/nc) / float64(a.Rate)
			}
		}
		sum += d * d
		if math.Abs(d) > peak {
			peak, at = math.Abs(d), i
		}
	}
	r.DiffRMSDBFS = finite(dBFS(math.Sqrt(sum / float64(max(1, n)))))
	r.DiffPeakDBFS = finite(dBFS(peak))
	r.DiffPeakAt = float64(at/nc) / float64(a.Rate)
	if matchDir != "" {
		target := math.Min(r.LUFSA, r.LUFSB)
		ga, gb := math.Pow(10, (target-r.LUFSA)/20), math.Pow(10, (target-r.LUFSB)/20)
		if p := math.Max(peakOf(a.Chans...)*ga, peakOf(b.Chans...)*gb); p > 0.98 {
			ga, gb = ga*0.98/p, gb*0.98/p
		}
		dir := filepath.Join(workRoot, matchDir)
		if filepath.IsAbs(matchDir) {
			dir = matchDir
		}
		if err := os.MkdirAll(dir, 0o755); err != nil {
			fmt.Fprintf(errOut, "snd: %v\n", err)
			return 1
		}
		for _, w := range []struct {
			suffix string
			c      Clip
			g      float64
		}{{"old", a, ga}, {"new", b, gb}} {
			p := filepath.Join(dir, name+"."+w.suffix+".wav")
			if err := os.WriteFile(p, EncodeWAV(w.c.Rate, gainAll(w.g, w.c.Chans), w.c.LoopStart), 0o644); err != nil {
				fmt.Fprintf(errOut, "snd: %v\n", err)
				return 1
			}
		}
		fmt.Fprintf(out, "そろえた: %s/%s.old.wav・%s.new.wav（%.1f LUFS・倍率 %.3f と %.3f）\n", matchDir, name, name, LUFS(a.Rate, gainAll(ga, a.Chans)), ga, gb)
	}
	if asJSON {
		data, _ := json.MarshalIndent(r, "", "  ")
		out.Write(append(data, '\n'))
		return 0
	}
	fmt.Fprintf(out, "前 %s: %d サンプル・ループの頭 %s・%.1f LUFS\n", r.A, r.SamplesA, loopText(r.LoopA), r.LUFSA)
	fmt.Fprintf(out, "後 %s: %d サンプル・ループの頭 %s・%.1f LUFS\n", r.B, r.SamplesB, loopText(r.LoopB), r.LUFSB)
	if r.SameBytes {
		out.WriteString("バイトまで同じ\n")
		return 0
	}
	fmt.Fprintf(out, "差の音: RMS %.1f dBFS・一番大きい所 %.1f dBFS（%.3f 秒）・違うサンプル %d / %d（左右は別に数える・最初は %.3f 秒）\n",
		r.DiffRMSDBFS, r.DiffPeakDBFS, r.DiffPeakAt, r.Differ, n, r.FirstDiffAt)
	return 0
}

func loopText(n int) string {
	if n < 0 {
		return "無し"
	}
	return strconv.Itoa(n)
}

func gainAll(g float64, chans [][]float64) [][]float64 {
	out := make([][]float64, len(chans))
	for i, x := range chans {
		out[i] = gainOf(g, x)
	}
	return out
}
