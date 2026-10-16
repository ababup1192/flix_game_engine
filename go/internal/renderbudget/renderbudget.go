package renderbudget

// renderbudget — 絵の値段（1 場面が組んだ描き物の数）を裁くゲート。
//
//	fge-go check-render-budget <ゲームのルート>              gallery を裁く
//	fge-go check-render-budget <ルート> --gate <旧ITEMS.tsv>  基準の更新を裁く
//	fge-go check-render-budget <ルート> --brief              直し方の助言を出さない
//	fge-go check-render-budget --root DIR ...               規約データを読む先を差し替える
//
// ゲームのルートは第 1 引数（`--` で始まらない物）。無ければ "."。

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// kvLine は `k=v\tk=v` 1 行のサイドカーの中身。ok=false は読めなかった印。
type kvLine struct {
	fields map[string]string
	ok     bool
}

// truthy は「読めて、かつ中身がある」を返す（中身が空なら残骸として扱わない）。
func (k kvLine) truthy() bool { return k.ok && len(k.fields) > 0 }

// pyStrip は前後の空白を落とす（isPySpace の範囲）。
func pyStrip(s string) string {
	return strings.TrimFunc(s, isPySpace)
}

func isPySpace(r rune) bool {
	switch r {
	case 0x1c, 0x1d, 0x1e, 0x1f:
		// WhyNot: unicode.IsSpace に任せないのは、この 4 つ（区切りの制御文字）も
		// 空白として落とすため。残すと k=v の値に紛れ込む。
		return true
	}
	return unicode.IsSpace(r)
}

// pyFileLines はテキストモードで開いたファイルの行の切り方（\n / \r\n / \r）に合わせる。
// WhyNot: pxlib.SplitLines を使わないのは、あちらが \v \f \x1c なども行末に
// 数えるため。ファイルの反復はこの 3 つだけで切る。
func pyFileLines(s string) []string {
	var lines []string
	start := 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '\n':
			lines = append(lines, s[start:i])
			start = i + 1
		case '\r':
			lines = append(lines, s[start:i])
			if i+1 < len(s) && s[i+1] == '\n' {
				i++
			}
			start = i + 1
		}
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	return lines
}

// digitValue は Unicode の 10 進数字の値。10 進数字でなければ -1。
// WhyNot: ASCII だけにしないのは、全角数字で書かれた値も数として受けるため。
func digitValue(r rune) int {
	if r >= '0' && r <= '9' {
		return int(r - '0')
	}
	if !unicode.IsDigit(r) {
		return -1
	}
	for _, rg := range unicode.Nd.R16 {
		if rg.Stride == 1 && rune(rg.Lo) <= r && r <= rune(rg.Hi) && (rg.Hi-rg.Lo+1)%10 == 0 {
			return int(r-rune(rg.Lo)) % 10
		}
	}
	for _, rg := range unicode.Nd.R32 {
		if rg.Stride == 1 && rune(rg.Lo) <= r && r <= rune(rg.Hi) && (rg.Hi-rg.Lo+1)%10 == 0 {
			return int(r-rune(rg.Lo)) % 10
		}
	}
	return -1
}

// pyParseInt は文字列を整数として読む（前後の空白・符号・桁の下線を許す）。
func pyParseInt(s string) (int64, bool) {
	s = pyStrip(s)
	neg := false
	if strings.HasPrefix(s, "+") || strings.HasPrefix(s, "-") {
		neg = s[0] == '-'
		s = s[1:]
	}
	if s == "" {
		return 0, false
	}
	var n int64
	prevDigit := false
	runes := []rune(s)
	for i, r := range runes {
		if r == '_' {
			if !prevDigit || i+1 >= len(runes) || digitValue(runes[i+1]) < 0 {
				return 0, false
			}
			prevDigit = false
			continue
		}
		d := digitValue(r)
		if d < 0 {
			return 0, false
		}
		n = n*10 + int64(d)
		prevDigit = true
	}
	if !prevDigit {
		return 0, false
	}
	if neg {
		n = -n
	}
	return n, true
}

// readKV は `k=v\tk=v` 1 行のサイドカーを読む。読めなければ ok=false。
func readKV(path string) kvLine {
	data, err := os.ReadFile(path)
	if err != nil {
		return kvLine{nil, false}
	}
	text := pxlib.DecodeReplace(data)
	line := ""
	if lines := pyFileLines(text); len(lines) > 0 {
		line = lines[0]
	}
	line = pyStrip(line)
	out := map[string]string{}
	for _, part := range strings.Split(line, "\t") {
		if k, v, found := strings.Cut(part, "="); found {
			out[pyStrip(k)] = pyStrip(v)
		}
	}
	return kvLine{out, true}
}

// table は `名前\tk=v...` の表。並びは最初に出た順を保つ。
type table struct {
	order []string
	rows  map[string]map[string]string
}

// readTable は want のキーをすべて持つ行だけを拾う。ファイルが無ければ空。
func readTable(path string, want []string) *table {
	t := &table{rows: map[string]map[string]string{}}
	if _, err := os.Stat(path); err != nil {
		return t
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return t
	}
	for _, raw := range pyFileLines(pxlib.DecodeReplace(data)) {
		line := pyStrip(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		cells := strings.Split(line, "\t")
		fields := map[string]string{}
		for _, cell := range cells[1:] {
			if k, v, found := strings.Cut(cell, "="); found {
				fields[pyStrip(k)] = pyStrip(v)
			}
		}
		all := true
		for _, k := range want {
			if _, ok := fields[k]; !ok {
				all = false
				break
			}
		}
		if !all {
			continue
		}
		if _, dup := t.rows[cells[0]]; !dup {
			t.order = append(t.order, cells[0])
		}
		t.rows[cells[0]] = fields
	}
	return t
}

func asInt(fields map[string]string, key string, fallback int64) int64 {
	v, ok := fields[key]
	if !ok {
		return fallback
	}
	n, ok := pyParseInt(v)
	if !ok {
		return fallback
	}
	return n
}

// sceneNames は gallery/*.png の名前。サイドカーの残骸を基準に混ぜないための唯一の正。
func sceneNames(gallery string) []string {
	if info, err := os.Stat(gallery); err != nil || !info.IsDir() {
		return nil
	}
	f, err := os.Open(gallery)
	if err != nil {
		return nil
	}
	entries, err := f.Readdirnames(-1)
	f.Close()
	if err != nil {
		return nil
	}
	var names []string
	for _, e := range entries {
		if strings.HasSuffix(e, ".png") {
			names = append(names, e[:len(e)-4])
		}
	}
	sort.Strings(names)
	return names
}

// stat は 1 場面の計測結果。dynamic が書かれていないときは hasDynamic=false。
type stat struct {
	dynamic    int64
	hasDynamic bool
	ok         bool
	reason     string
}

func measure(gallery string, names []string) map[string]stat {
	out := map[string]stat{}
	for _, name := range names {
		items := readKV(filepath.Join(gallery, name+".items.tsv"))
		staticKV := readKV(filepath.Join(gallery, name+".static.tsv"))
		var static int64
		if staticKV.truthy() {
			static = asInt(staticKV.fields, "static", 0)
		}
		if !items.ok {
			// 古い engine で生成した gallery。黙らせないが、落としもしない。
			reason := ""
			if staticKV.truthy() {
				reason = "静的層の申告だけがあり計測がありません（残骸か呼び順の誤り）"
			}
			out[name] = stat{0, false, false, reason}
			continue
		}
		total := asInt(items.fields, "total", 0)
		if static > total {
			out[name] = stat{0, false, true,
				fmt.Sprintf("静的層の申告 %d が総数 %d を超えています", static, total)}
			continue
		}
		out[name] = stat{total - static, true, true, ""}
	}
	return out
}

// capsOf は場面ごとの上限と、note を書き忘れている場面の名前を返す。
func (r *Rules) capsOf(root string) (map[string]int64, []string) {
	rows := readTable(filepath.Join(root, "reference", "ITEMS.caps.tsv"), []string{"cap"})
	caps := map[string]int64{}
	var bad []string
	for _, name := range rows.order {
		fields := rows.rows[name]
		if fields["note"] == "" {
			bad = append(bad, name)
			continue
		}
		caps[name] = asInt(fields, "cap", r.DefaultCap)
	}
	return caps, bad
}

func baselineOf(path string) map[string]int64 {
	rows := readTable(path, []string{"dynamic"})
	base := map[string]int64{}
	for _, name := range rows.order {
		base[name] = asInt(rows.rows[name], "dynamic", 0)
	}
	return base
}

func (r *Rules) driftLimit(base int64) int64 {
	scaled := int64(float64(base) * r.DriftFactor)
	if floor := base + r.DriftFloor; floor > scaled {
		return floor
	}
	return scaled
}

// judge は (赤の行, 注意の行, 計測できた場面数) を返す。
func (r *Rules) judge(root, galleryDir, baselinePath string, gate bool) (red, note []string, measured int) {
	gallery := filepath.Join(root, galleryDir)
	names := sceneNames(gallery)
	stats := measure(gallery, names)
	caps, capless := r.capsOf(root)
	base := baselineOf(baselinePath)

	for _, name := range capless {
		red = append(red, fmt.Sprintf("%s: ITEMS.caps.tsv の cap に note がありません"+
			"（なぜ上限を上げるのかを書かないと、上限は意味を失います）", name))
	}

	for _, name := range names {
		s := stats[name]
		if s.reason != "" {
			red = append(red, fmt.Sprintf("%s: %s", name, s.reason))
			continue
		}
		if !s.ok || !s.hasDynamic {
			note = append(note, fmt.Sprintf("%s: 予算 未計測（古い engine で生成した絵）", name))
			continue
		}
		measured++
		limitCap, named := caps[name]
		if !named {
			limitCap = r.DefaultCap
		}
		if s.dynamic >= limitCap {
			suffix := "（既定）"
			if named {
				suffix = ""
			}
			red = append(red, fmt.Sprintf("%s: 動的 %d 個 ≥ 上限 %d 個%s", name, s.dynamic, limitCap, suffix))
			continue
		}
		if b, ok := base[name]; ok {
			limit := r.driftLimit(b)
			if s.dynamic > limit {
				verb := "増えすぎです"
				if gate {
					verb = "基準として焼けません"
				}
				red = append(red, fmt.Sprintf("%s: 動的 %d 個 — 基準 %d 個から%d 個を超えて増えたので%s",
					name, s.dynamic, b, limit, verb))
			}
		}
	}
	return red, note, measured
}

// Run は検査を走らせて終了コードを返す。
// err が返ったとき呼ぶ側は必ず止まる（規約を読めないまま緑にしない）。
func Run(out, errOut *strings.Builder, rulesRoot string, args []string) (int, error) {
	rules, err := LoadRules(rulesRoot)
	if err != nil {
		return 2, err
	}

	root := "."
	if len(args) > 0 && !strings.HasPrefix(args[0], "--") {
		root = args[0]
	}
	gate := false
	gateAt := -1
	brief := false
	for i, a := range args {
		if a == "--gate" && gateAt < 0 {
			gate, gateAt = true, i
		}
		if a == "--brief" {
			brief = true
		}
	}
	baselinePath := filepath.Join(root, "reference", "ITEMS.tsv")
	if gate {
		baselinePath = ""
		if len(args) > gateAt+1 {
			baselinePath = args[gateAt+1]
		}
	}

	red, note, measured := rules.judge(root, "gallery", baselinePath, gate)

	for _, line := range note {
		fmt.Fprintf(out, "[budget] %s\n", line)
	}

	if len(red) > 0 {
		head := "reference-check NG: 絵の値段"
		if gate {
			head = "reference-update 中止: 絵の値段"
		}
		fmt.Fprintf(errOut, "%s\n", head)
		for _, line := range red {
			fmt.Fprintf(errOut, "  %s\n", line)
		}
		if brief {
			return 1, nil
		}
		if gate {
			fmt.Fprintln(errOut, "  意図した増加なら make reference-update BUDGET=accept で明示してください。")
			fmt.Fprintln(errOut, "  上限そのものを場面ごとに上げるなら reference/ITEMS.caps.tsv に"+
				"cap と note を書いてください。")
		} else {
			fmt.Fprintln(errOut, "  盤や群れを毎フレーム組んでいないか確かめてください"+
				"（逆引き: make module Q=毎フレーム）。")
			fmt.Fprintln(errOut, "  意図した増加なら make reference-update BUDGET=accept で基準を更新します。")
		}
		return 1, nil
	}

	if measured > 0 {
		fmt.Fprintf(out, "budget OK: %d 場面すべて予算の内側です\n", measured)
	}
	return 0, nil
}
