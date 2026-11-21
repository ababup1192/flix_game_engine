package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
)

const wasmSizeUsage = `使い方: fge wasm-size <書き出したフォルダ | classes.wasm> [--by package|module|def|name] [--top N] [--grep 語] [--tsv] [--game <dir>] [--engine <dir>]
  ブラウザ版の classes.wasm の関数ごとの大きさを、classes.names（名前の区画）で名前に引き当てて集計する。
  brotli の見込みは、まとめた関数の本文だけを並べて圧縮した大きさ（全体の比で割り戻した値も出す）。
  --by package  engine・engine_world・render_gl・engine_web・ゲーム・Flix の標準・TeaVM の実行環境 で分ける（既定）
  --by module   Flix のモジュールで分ける（頭にパッケージ）
  --by def      元の関数で分ける（単相化の複製をまとめる。関数の列が複製の数）
  --by name     wasm の関数 1 本ずつ
  --game        ゲームの根（src/ と web/ のモジュールをゲームと見る。既定は渡した道から上へ flix.toml を探す）
  --engine      engine の根（既定はこの道具の engine）
  --top N       上から N 行（既定 40）
  --grep 語     名前にその語を含む関数だけ
  --tsv         表を TSV で出す
  --diff 前    前の書き出し（フォルダか classes.wasm）と区分ごとに比べ、本文が増えた順に出す（区分の brotli も別々に詰めて比べる）
  --without 式  「パッケージ  モジュール.関数」がその正規表現に当たる関数を抜いた時、code 区画の brotli が何 KB 減るか（何度でも付けられる。
                1 回に 2 度 q11 で詰めるので 1 分ほどかかる）
  並びは brotli の大きい順（区分が 400 を超える時は本文の順）`

func init() {
	register("wasm-size", "ブラウザ版の wasm の大きさを engine のパッケージ・モジュールごとに集計する。wasm-size --help", cmdWasmSize)
}

func cmdWasmSize(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	by, top, grep, tsv := "package", 40, "", false
	game, engineRoot := "", repoRoot()
	var without []string
	diff := ""
	var args []string
	for i := 0; i < len(rest); i++ {
		a := rest[i]
		switch {
		case a == "--help" || a == "-h":
			fmt.Fprintln(out, wasmSizeUsage)
			return 0
		case a == "--by" && i+1 < len(rest):
			by = rest[i+1]
			i++
		case a == "--top" && i+1 < len(rest):
			fmt.Sscanf(rest[i+1], "%d", &top)
			i++
		case a == "--grep" && i+1 < len(rest):
			grep = rest[i+1]
			i++
		case a == "--game" && i+1 < len(rest):
			game = rest[i+1]
			i++
		case a == "--engine" && i+1 < len(rest):
			engineRoot = rest[i+1]
			i++
		case a == "--without" && i+1 < len(rest):
			without = append(without, rest[i+1])
			i++
		case a == "--diff" && i+1 < len(rest):
			diff = rest[i+1]
			i++
		case a == "--tsv":
			tsv = true
		case strings.HasPrefix(a, "--"):
			fmt.Fprintf(errOut, "fge wasm-size: 知らない引数 %s\n%s\n", a, wasmSizeUsage)
			return 2
		default:
			args = append(args, a)
		}
	}
	if len(args) != 1 {
		fmt.Fprintf(errOut, "fge wasm-size: 書き出したフォルダか classes.wasm を 1 つ渡してください\n%s\n", wasmSizeUsage)
		return 2
	}
	funcs, total, err := loadWasmFuncs(args[0])
	if err != nil {
		fmt.Fprintf(errOut, "fge wasm-size: %v\n", err)
		return 2
	}
	if grep != "" {
		var kept []wasmFunc
		for _, f := range funcs {
			if strings.Contains(f.Name, grep) {
				kept = append(kept, f)
			}
		}
		funcs = kept
	}
	if game == "" {
		game = findGameRoot(args[0])
	}
	idx := buildWasmModuleIndex(engineRoot, game)
	if len(without) > 0 {
		return writeWasmWithout(out, errOut, funcs, idx, without)
	}
	rows := groupWasmFuncs(funcs, func(n string) string { return wasmGroupKey(idx, by, n) })
	if diff != "" {
		before, _, err := loadWasmFuncs(diff)
		if err != nil {
			fmt.Fprintf(errOut, "fge wasm-size: --diff: %v\n", err)
			return 2
		}
		old := groupWasmFuncs(before, func(n string) string { return wasmGroupKey(idx, by, n) })
		writeWasmDiff(out, old, rows, top)
		return 0
	}
	if asJSON {
		emitJSON(out, map[string]any{"wasmBytes": total.wasm, "codeBytes": total.code, "rows": rows})
		return 0
	}
	writeWasmSize(out, rows, total, top, tsv)
	return 0
}

// wasmFunc は code 区画の 1 本の関数。Body は本文のバイト（brotli の見込みに使う）。
type wasmFunc struct {
	Name string
	Body []byte
}

type wasmTotals struct {
	wasm, code, brotli int
}

type wasmSizeRow struct {
	Key    string `json:"key"`
	Funcs  int    `json:"funcs"`
	Bytes  int    `json:"bytes"`
	Brotli int    `json:"brotli"`
}

func loadWasmFuncs(arg string) ([]wasmFunc, wasmTotals, error) {
	wasmPath := arg
	if info, err := os.Stat(arg); err == nil && info.IsDir() {
		wasmPath = filepath.Join(arg, "classes.wasm")
	}
	data, err := os.ReadFile(wasmPath)
	if err != nil {
		return nil, wasmTotals{}, err
	}
	stripped, names, err := splitWasmNames(data)
	if err != nil {
		return nil, wasmTotals{}, err
	}
	if names == nil {
		names, err = os.ReadFile(filepath.Join(filepath.Dir(wasmPath), webWasmNamesFile))
		if err != nil {
			return nil, wasmTotals{}, fmt.Errorf("名前の区画も %s も無い: %w", webWasmNamesFile, err)
		}
	}
	imported, bodies, err := wasmCodeBodies(stripped)
	if err != nil {
		return nil, wasmTotals{}, err
	}
	nameOf, err := wasmFuncNames(names)
	if err != nil {
		return nil, wasmTotals{}, err
	}
	funcs := make([]wasmFunc, len(bodies))
	code := 0
	for i, b := range bodies {
		n, ok := nameOf[imported+i]
		if !ok {
			n = fmt.Sprintf("<名無し %d>", imported+i)
		}
		funcs[i] = wasmFunc{Name: n, Body: b}
		code += len(b)
	}
	// WhyNot: 書き出しに classes.wasm.br があればそれを使う — 17 MB を q11 で詰め直すと 1 分近くかかる。
	br := 0
	if info, err := os.Stat(filepath.Join(filepath.Dir(wasmPath), webWasmBrotliFile)); err == nil {
		br = int(info.Size())
	} else {
		br = brotliSize(stripped)
	}
	return funcs, wasmTotals{wasm: len(stripped), code: code, brotli: br}, nil
}

// wasmCodeBodies は import された関数の数と、code 区画の関数の本文を順に返す。
func wasmCodeBodies(data []byte) (imported int, bodies [][]byte, err error) {
	at := 8
	for at < len(data) {
		id := data[at]
		size, body, err := readWasmLEB(data, at+1)
		if err != nil {
			return 0, nil, err
		}
		end := body + size
		switch id {
		case 2:
			imported, err = wasmImportedFuncs(data[body:end])
			if err != nil {
				return 0, nil, err
			}
		case 10:
			n, p, err := readWasmLEB(data, body)
			if err != nil {
				return 0, nil, err
			}
			for i := 0; i < n; i++ {
				sz, start, err := readWasmLEB(data, p)
				if err != nil {
					return 0, nil, err
				}
				bodies = append(bodies, data[start:start+sz])
				p = start + sz
			}
		}
		at = end
	}
	return imported, bodies, nil
}

// wasmImportedFuncs は import 区画の中の関数（kind 0）の数を数える。関数の番号は import の後から始まる。
func wasmImportedFuncs(sec []byte) (int, error) {
	n, p, err := readWasmLEB(sec, 0)
	if err != nil {
		return 0, err
	}
	funcs := 0
	for i := 0; i < n; i++ {
		for k := 0; k < 2; k++ {
			l, q, err := readWasmLEB(sec, p)
			if err != nil {
				return 0, err
			}
			p = q + l
		}
		kind := sec[p]
		p++
		switch kind {
		case 0:
			funcs++
			_, p, err = readWasmLEB(sec, p)
		case 1:
			// WhyNot: GC の table の型は参照型の符号が複数バイトになりうる。TeaVM は table を import しないので読まない。
			return 0, fmt.Errorf("table の import は読めない")
		case 2:
			flags := sec[p]
			_, p, err = readWasmLEB(sec, p+1)
			if err == nil && flags&1 == 1 {
				_, p, err = readWasmLEB(sec, p)
			}
		case 3:
			p += 2
		case 4:
			_, p, err = readWasmLEB(sec, p+1)
		default:
			return 0, fmt.Errorf("知らない import の種類 %d", kind)
		}
		if err != nil {
			return 0, err
		}
	}
	return funcs, nil
}

// wasmFuncNames は名前の区画の中身から、関数の番号 → 名前（subsection 1）を読む。
func wasmFuncNames(names []byte) (map[int]string, error) {
	out := map[int]string{}
	at := 0
	for at < len(names) {
		id := names[at]
		size, body, err := readWasmLEB(names, at+1)
		if err != nil {
			return nil, err
		}
		end := body + size
		if id == 1 {
			n, p, err := readWasmLEB(names, body)
			if err != nil {
				return nil, err
			}
			for i := 0; i < n; i++ {
				idx, q, err := readWasmLEB(names, p)
				if err != nil {
					return nil, err
				}
				l, r, err := readWasmLEB(names, q)
				if err != nil {
					return nil, err
				}
				out[idx] = string(names[r : r+l])
				p = r + l
			}
		}
		at = end
	}
	return out, nil
}

func groupWasmFuncs(funcs []wasmFunc, key func(string) string) []wasmSizeRow {
	byKey := map[string]*wasmSizeRow{}
	bodies := map[string][]byte{}
	for _, f := range funcs {
		k := key(f.Name)
		r := byKey[k]
		if r == nil {
			r = &wasmSizeRow{Key: k}
			byKey[k] = r
		}
		r.Funcs++
		r.Bytes += len(f.Body)
		bodies[k] = append(bodies[k], f.Body...)
	}
	rows := make([]wasmSizeRow, 0, len(byKey))
	// WhyNot: 区分が多い時は 1 つずつ圧縮しない — 4 万本を q11 で詰めると 1 分を超える。本文の大きさで割り戻した列だけで足りる。
	compress := len(byKey) <= 400
	var wg sync.WaitGroup
	sem := make(chan struct{}, runtime.NumCPU())
	for k, r := range byKey {
		r.Brotli = r.Bytes
		if compress {
			wg.Add(1)
			go func() {
				defer wg.Done()
				sem <- struct{}{}
				r.Brotli = brotliSize(bodies[k])
				<-sem
			}()
		}
	}
	wg.Wait()
	for _, r := range byKey {
		rows = append(rows, *r)
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Brotli != rows[j].Brotli {
			return rows[i].Brotli > rows[j].Brotli
		}
		if rows[i].Bytes != rows[j].Bytes {
			return rows[i].Bytes > rows[j].Bytes
		}
		return rows[i].Key < rows[j].Key
	})
	return rows
}

func writeWasmSize(w *strings.Builder, rows []wasmSizeRow, t wasmTotals, top int, tsv bool) {
	brSum := 0
	for _, r := range rows {
		brSum += r.Brotli
	}
	// WhyNot: 区分ごとに別々に圧縮した和は、まとめて圧縮した全体より大きい（区分をまたぐ繰り返しが効かない）。
	// 比べやすさのため、全体の brotli に合わせて割り戻した列も並べる。
	scale := 1.0
	if brSum > 0 {
		scale = float64(t.brotli) / float64(brSum)
	}
	if tsv {
		fmt.Fprintln(w, "key\tfuncs\tbytes\tbrotli\tbrotli_scaled")
	} else {
		fmt.Fprintf(w, "classes.wasm %s（名前の区画を除く）・code 区画 %s・brotli %s\n", kb(t.wasm), kb(t.code), kb(t.brotli))
		fmt.Fprintf(w, "%-60s %7s %10s %10s %10s %6s\n", "区分", "関数", "本文", "brotli", "割り戻し", "割合")
	}
	for i, r := range rows {
		if i >= top {
			break
		}
		scaled := int(float64(r.Brotli) * scale)
		if tsv {
			fmt.Fprintf(w, "%s\t%d\t%d\t%d\t%d\n", r.Key, r.Funcs, r.Bytes, r.Brotli, scaled)
			continue
		}
		fmt.Fprintf(w, "%-60s %7d %10s %10s %10s %5.1f%%\n", trimKey(r.Key, 60), r.Funcs, kb(r.Bytes), kb(r.Brotli), kb(scaled), 100*float64(r.Bytes)/float64(max(t.code, 1)))
	}
	if !tsv && len(rows) > top {
		fmt.Fprintf(w, "…ほか %d 行\n", len(rows)-top)
	}
}

func kb(n int) string {
	return fmt.Sprintf("%.1f KB", float64(n)/1024)
}

func trimKey(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

func wasmGroupKey(idx wasmModuleIndex, by, name string) string {
	if by == "name" {
		return name
	}
	c := idx.classify(name)
	switch by {
	case "module":
		return c.Package + "  " + c.Module
	case "def":
		return c.Package + "  " + c.Def
	default:
		return c.Package
	}
}

// writeWasmWithout は当たる関数を抜いた時の code 区画の brotli の差を出す。
// WhyNot: 区分を別々に詰めた大きさで「削れる量」を言わない — 区分をまたぐ繰り返しが効くので、抜いても減るのはそれより少ない。
// 抜いた残りを詰め直すのが、実際に外した時に一番近い。
func writeWasmWithout(out, errOut *strings.Builder, funcs []wasmFunc, idx wasmModuleIndex, exprs []string) int {
	var res []*regexp.Regexp
	for _, e := range exprs {
		re, err := regexp.Compile(e)
		if err != nil {
			fmt.Fprintf(errOut, "fge wasm-size: --without %s: %v\n", e, err)
			return 2
		}
		res = append(res, re)
	}
	var all, kept []byte
	hit, hitBytes := 0, 0
	for _, f := range funcs {
		all = append(all, f.Body...)
		c := idx.classify(f.Name)
		key := c.Package + "  " + c.Def
		matched := false
		for _, re := range res {
			if re.MatchString(key) {
				matched = true
				break
			}
		}
		if matched {
			hit++
			hitBytes += len(f.Body)
			continue
		}
		kept = append(kept, f.Body...)
	}
	var brAll, brKept int
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); brAll = brotliSize(all) }()
	go func() { defer wg.Done(); brKept = brotliSize(kept) }()
	wg.Wait()
	fmt.Fprintf(out, "当たった関数 %d 本・本文 %s\n", hit, kb(hitBytes))
	fmt.Fprintf(out, "code 区画の brotli %s → %s（−%s）\n", kb(brAll), kb(brKept), kb(brAll-brKept))
	return 0
}

// writeWasmDiff は前と今の区分を突き合わせ、本文の増えた順に並べる。
func writeWasmDiff(w *strings.Builder, old, cur []wasmSizeRow, top int) {
	type d struct {
		key         string
		dBytes, dBr int
		before, now int
	}
	byKey := map[string]*d{}
	for _, r := range old {
		byKey[r.Key] = &d{key: r.Key, dBytes: -r.Bytes, dBr: -r.Brotli, before: r.Bytes}
	}
	for _, r := range cur {
		x := byKey[r.Key]
		if x == nil {
			x = &d{key: r.Key}
			byKey[r.Key] = x
		}
		x.dBytes += r.Bytes
		x.dBr += r.Brotli
		x.now = r.Bytes
	}
	list := make([]*d, 0, len(byKey))
	for _, x := range byKey {
		if x.dBytes != 0 || x.dBr != 0 {
			list = append(list, x)
		}
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].dBr != list[j].dBr {
			return list[i].dBr > list[j].dBr
		}
		return list[i].key < list[j].key
	})
	fmt.Fprintf(w, "%-60s %10s %10s %10s %10s\n", "区分", "前", "今", "本文の差", "brotli の差")
	for i, x := range list {
		if i >= top {
			fmt.Fprintf(w, "…ほか %d 行\n", len(list)-top)
			break
		}
		fmt.Fprintf(w, "%-60s %10s %10s %+9.1fK %+9.1fK\n", trimKey(x.key, 60), kb(x.before), kb(x.now), float64(x.dBytes)/1024, float64(x.dBr)/1024)
	}
}
