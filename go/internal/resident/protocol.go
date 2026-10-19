package resident

// 常駐との口の字の形（/hello の本文・/run の行）と、そこから決まる判定。どれも純粋な関数。

import (
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// JobKindVideo は /hello の job= 行で動画の入口を表す字。
const JobKindVideo = "video"

// Job は常駐が受ける入口 1 つ。
type Job struct {
	Name string
	Kind string
}

// Hello は GET /hello の答え。
type Hello struct {
	Pid      string
	Dir      string
	Manifest string
	Served   string
	Busy     string
	// IdleLeft・IdleWindow は寿命の残りと今の寿命の幅（秒）。名乗らない常駐は -1。
	IdleLeft   int
	IdleWindow int
	Env        map[string]string
	Jobs       []Job
}

// ParseHello は /hello の本文を読む。1 行目が `ok hello` でなければ誤り。
func ParseHello(body string) (Hello, error) {
	lines := strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "ok hello" {
		return Hello{}, errors.New("/hello の 1 行目が ok hello ではない")
	}
	h := Hello{Env: map[string]string{}, IdleLeft: -1, IdleWindow: -1}
	for _, line := range lines[1:] {
		if line == "" {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			return Hello{}, fmt.Errorf("/hello の行が key=value ではない: %q", line)
		}
		switch {
		case key == "pid":
			h.Pid = val
		case key == "dir":
			h.Dir = val
		case key == "manifest":
			h.Manifest = val
		case key == "served":
			h.Served = val
		case key == "busy":
			h.Busy = val
		case key == "idle.left":
			h.IdleLeft = parseSeconds(val)
		case key == "idle.window":
			h.IdleWindow = parseSeconds(val)
		case key == "job":
			name, kind, _ := strings.Cut(val, " ")
			h.Jobs = append(h.Jobs, Job{Name: name, Kind: strings.TrimSpace(kind)})
		case strings.HasPrefix(key, "env."):
			h.Env[strings.TrimPrefix(key, "env.")] = val
		}
	}
	return h, nil
}

// parseSeconds は idle.* の秒を読む。読めなければ -1。
func parseSeconds(s string) int {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil || n < 0 {
		return -1
	}
	return n
}

// FindJob は名前の入口を探す。
func (h Hello) FindJob(name string) (Job, bool) {
	for _, j := range h.Jobs {
		if j.Name == name {
			return j, true
		}
	}
	return Job{}, false
}

// isSpawnKey は常駐を起こす時に通す環境変数のキーか。
func isSpawnKey(k string) bool {
	switch k {
	case "HOME", "PATH", "JAVA_HOME", "TMPDIR", "LANG", "JAVA_TOOL_OPTIONS", renderCacheKey:
		return true
	}
	return strings.HasPrefix(k, "LC_") || strings.HasPrefix(k, "HEADLESS_")
}

// renderCacheKey は塗りの取り置き（RenderCache）の置き場と使い方を決める環境変数。
//
// WhyNot: 要求の env で渡さず起動時に通す — RenderCache は SoftRaster.render* の奥で毎回読むので、
// 引数で渡すと描き出しの pub の口の型が全部変わる。起動時の値を比べて違えば常駐を立て直せば、
// FGE_RENDER_CACHE=off を付けた要求が取り置きを使ってしまう（偽の緑）ことはない。
const renderCacheKey = "FGE_RENDER_CACHE"

// isComparedKey は /hello の env. と自分の env を突き合わせるキーか（常駐が名乗る LANG・LC_*・HEADLESS_*・FGE_RENDER_CACHE）。
//
// WhyNot: HEADLESS_PORT・HEADLESS_RESIDENT・HEADLESS_ENTRIES を比べないのは、クライアントが起こす時に
// 自分で決めて渡す値で、呼ぶ側の env と食い違うのが当たり前だから。HEADLESS_SILENT_SECS は
// クライアントだけが読むので、違っても常駐の答えは変わらない。
func isComparedKey(k string) bool {
	switch k {
	case "HEADLESS_PORT", "HEADLESS_RESIDENT", "HEADLESS_ENTRIES", "HEADLESS_SILENT_SECS":
		return false
	case "LANG", renderCacheKey:
		return true
	}
	return strings.HasPrefix(k, "LC_") || strings.HasPrefix(k, "HEADLESS_")
}

// EnvMismatch は常駐が起動時に受けた値と自分の env が食い違う最初のキー（字の順）。同じなら空。
// 片方にしか無いキーも食い違いとして数える。
func EnvMismatch(resident, mine map[string]string) string {
	keys := map[string]bool{}
	for k := range resident {
		if isComparedKey(k) {
			keys[k] = true
		}
	}
	for k := range mine {
		if isComparedKey(k) {
			keys[k] = true
		}
	}
	sorted := make([]string, 0, len(keys))
	for k := range keys {
		sorted = append(sorted, k)
	}
	sort.Strings(sorted)
	for _, k := range sorted {
		a, inA := resident[k]
		b, inB := mine[k]
		if inA != inB || a != b {
			return k
		}
	}
	return ""
}

// Verdict は /hello を見て決めること。
type Verdict int

const (
	// Use は常駐へ /run を頼む。
	Use Verdict = iota
	// Refuse は常駐を残したまま素の道へ。
	Refuse
	// QuitAndRefuse は常駐を /quit で落としてから素の道へ（次に来た人が今の jar・env で起こし直す）。
	QuitAndRefuse
)

// Want は /hello と突き合わせる、呼ぶ側の今。
type Want struct {
	Dir      string
	Manifest string
	Env      map[string]string
	Entry    string
}

// Judge は /hello を見て、常駐に頼むか・落とすかと、その訳を返す。
//
// WhyNot: 動画の入口を FGE_GPU=off の時しか送らないのは、GPU で塗る入口を常駐の糸で
// 流すと GL を開けない（GL は主スレッドの 1 本だけ。設計 3.3）ため。
func Judge(h Hello, w Want) (Verdict, string) {
	if w.Manifest == "" {
		return Refuse, "build/headless/jar.manifest が無い"
	}
	// WhyNot: 根を manifest より先に見るのは、別の根の常駐を「jar が古い」と読んで落とさないため。
	if h.Dir != w.Dir {
		return Refuse, "常駐の根が違う: " + h.Dir
	}
	if h.Manifest != w.Manifest {
		return QuitAndRefuse, "常駐の jar が古い（manifest が違う）"
	}
	if k := EnvMismatch(h.Env, w.Env); k != "" {
		return QuitAndRefuse, "起動時の環境変数 " + k + " が今と違う"
	}
	if h.Busy != "" {
		return Refuse, "常駐が " + h.Busy + " を流している"
	}
	job, ok := h.FindJob(w.Entry)
	if !ok {
		return Refuse, w.Entry + " は常駐の入口の束に無い"
	}
	if job.Kind == JobKindVideo && w.Env["FGE_GPU"] != "off" {
		return Refuse, w.Entry + " は動画の入口（FGE_GPU=off の時だけ常駐で流す）"
	}
	return Use, ""
}

// LineKind は /run の答えの 1 行の種類。
type LineKind int

const (
	LineOut LineKind = iota
	LineErr
	LineEnd
	LineBad
)

// ParseLine は /run の答えの 1 行（改行を除いた物）を読む。
// `o` と `e` は字が空の行（頭の 1 字の後に空白が無い）も受ける。
func ParseLine(line string) (LineKind, string) {
	if len(line) == 0 {
		return LineBad, ""
	}
	rest := line[1:]
	if rest != "" {
		if rest[0] != ' ' {
			return LineBad, line
		}
		rest = rest[1:]
	}
	switch line[0] {
	case 'o':
		return LineOut, rest
	case 'e':
		return LineErr, rest
	case 'x':
		return LineEnd, rest
	}
	return LineBad, line
}

// End は /run の流れがどう終わったか。
type End int

const (
	EndExit End = iota
	EndOOM
	EndStale
	EndBusy
	EndUnknownEntry
	EndNeedsGL
	EndBroken
	EndSilent
)

// ParseEnd は `x <字>` の字を読む。数でも決まった字でもなければ EndBroken。
func ParseEnd(s string) (End, int) {
	switch s {
	case "oom":
		return EndOOM, 0
	case "stale":
		return EndStale, 0
	case "busy":
		return EndBusy, 0
	case "unknown-entry":
		return EndUnknownEntry, 0
	case "needs-gl":
		return EndNeedsGL, 0
	}
	if n, err := strconv.Atoi(s); err == nil {
		return EndExit, n
	}
	return EndBroken, 0
}

// Outcome は /run を 1 回流した結果。
type Outcome struct {
	End     End
	Code    int
	Emitted bool // 入口の出力を 1 行でも写したか
	Entry   string
}

// Settle は流した結果から、返す終了コード・標準エラーへ出す区切りの 1 行（無ければ空）・
// 常駐をどうするかを決める。
//
// WhyNot: 入口の出力を出した後の 125 に必ず区切りを付けるのは、素の道がもう一度同じ出力を
// 出すので、2 度出た行を読み違えないようにするため。
func Settle(o Outcome) (code int, notice string, after Aftercare) {
	switch o.End {
	case EndExit:
		return o.Code, "", KeepResident
	case EndOOM:
		return Unusable, "[resident] メモリが足りず常駐が落ちた — 素の道で流し直す", KeepResident
	case EndSilent:
		return Unusable, "[resident] 返事が止まった — 常駐を落として素の道で流し直す", KillResident
	case EndNeedsGL:
		return Unusable, "[resident] " + o.Entry + " は Still と名乗ったのに GL を開こうとした（入口の束の kind の漏れ）— 素の道で流し直す", KeepResident
	case EndStale:
		return Unusable, emittedNotice(o, "常駐の jar が古かった"), QuitResident
	case EndBusy:
		return Unusable, emittedNotice(o, "常駐が塞がっていた"), KeepResident
	case EndUnknownEntry:
		return Unusable, emittedNotice(o, o.Entry+" を常駐が知らなかった"), KeepResident
	}
	return Unusable, emittedNotice(o, "常駐との流れが途中で切れた"), KeepResident
}

func emittedNotice(o Outcome, why string) string {
	if !o.Emitted {
		return ""
	}
	return "[resident] " + why + " — 素の道で流し直す"
}

// Aftercare は流した後に常駐をどうするか。
type Aftercare int

const (
	KeepResident Aftercare = iota
	QuitResident
	KillResident
)

// AftercareOf は入口の種類を見て、流した後の扱いを決め直す。動画の入口を流した後は、
// 入口が成功しても常駐を畳む。
//
// WhyNot: 動画の後も寿命まで残さない — 910 コマの動画を流した常駐は RSS が 5.5 GB まで
// 太ったまま 180 秒待つ（2026-10-19 実測）。動画は 1 本数十秒で JVM の立ち上げは 1 割以下
// なので、次の動画で起こし直す方が安い（依頼主の希望: メモリを持ったまま待つ時間を短く）。
func AftercareOf(job Job, after Aftercare) Aftercare {
	if job.Kind == JobKindVideo && after == KeepResident {
		return QuitResident
	}
	return after
}

// RunBody は POST /run の本文（呼ぶ側の env を KEY=VALUE の行で・キーの字の順）。
// 値に改行を含むキーは落とす（行の区切りと取り違えないため）。
func RunBody(env map[string]string) string {
	keys := make([]string, 0, len(env))
	for k, v := range env {
		if k == "" || strings.ContainsAny(k, "=\n\r") || strings.ContainsAny(v, "\n\r") {
			continue
		}
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		b.WriteString(k + "=" + env[k] + "\n")
	}
	return b.String()
}

// SpawnEnv は常駐を起こす時の env（通すキーだけ + 起動の印）。
func SpawnEnv(mine map[string]string, residentEntry, entries string) []string {
	var out []string
	for k, v := range mine {
		if !isSpawnKey(k) {
			continue
		}
		switch k {
		case "HEADLESS_PORT", "HEADLESS_RESIDENT", "HEADLESS_ENTRIES":
			continue
		}
		out = append(out, k+"="+v)
	}
	out = append(out,
		"FGE_ENTRY="+residentEntry,
		"HEADLESS_PORT=0",
		"HEADLESS_RESIDENT=1",
		"HEADLESS_ENTRIES="+entries)
	sort.Strings(out)
	return out
}

// JavaArgs は常駐の java の引数。素の道と同じ旗に、-Xmx が無ければ蓋を足す。
//
// WhyNot: -XstartOnFirstThread を付けないのは、常駐は窓を開かず、付けると主スレッドを
// AWT が取って HTTP の糸と並べられなくなるため（取り決めの起動）。
func JavaArgs(opts string, heapMB int) []string {
	args := []string{"-Xss32m", "-XX:MaxRAMPercentage=50", "-Djava.awt.headless=true"}
	fields := strings.Fields(opts)
	if !hasXmx(fields) && heapMB > 0 {
		args = append(args, fmt.Sprintf("-Xmx%dm", heapMB))
	}
	args = append(args, fields...)
	return append(args, "-jar", "build/headless/headless.jar")
}

func hasXmx(fields []string) bool {
	for _, f := range fields {
		if strings.HasPrefix(f, "-Xmx") || strings.HasPrefix(f, "-XX:MaxHeapSize=") {
			return true
		}
	}
	return false
}

// ParseReady は `[headless] ready port=N pid=P` の行から port と pid を取る。
func ParseReady(line string) (port, pid int, ok bool) {
	rest, found := strings.CutPrefix(strings.TrimSpace(line), "[headless] ready ")
	if !found {
		return 0, 0, false
	}
	for _, f := range strings.Fields(rest) {
		k, v, _ := strings.Cut(f, "=")
		n, err := strconv.Atoi(v)
		if err != nil {
			continue
		}
		switch k {
		case "port":
			port = n
		case "pid":
			pid = n
		}
	}
	return port, pid, port > 0
}
