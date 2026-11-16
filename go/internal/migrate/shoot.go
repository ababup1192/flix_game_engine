package migrate

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/rendercache"
)

// 1 本の flow を撮る JVM の見積もり（長いノベルの flow 1 本で CPU は平均 5 コア。plans/novel-migrate-scale.md の M2）。本数はコアの数だけで決め、上限は shootMaxJobs。
// ヒープは shootHeap で蓋をする（Full GC の後に生きている物は 0.2 GB 前後・若い世代の GC の後の最大 1.8 GB。plans/novel-migrate-scale.md の M5）。
const (
	shootCoresPerJob = 4
	shootMaxJobs     = 6
	shootHeap        = "-Xmx3g"
	shootHeapBytes   = 3 << 30
	// shootPNGBytes は比べのコマの PNG 1 枚の大きさの見積もり（M8 の置き場で 904 枚 781 MB）。
	shootPNGBytes = 900 << 10
)

type shootArgs struct {
	name, run, savesFrom    string
	jobs                    int
	video, overwrite, saves bool
	// full は鍵を先に撮らず全部のコマを塗る（基準を撮り直す時）。resident は常駐の JVM で流す（--no-resident で切る）。
	full, resident bool
	flows          []string
	// paint は比べのコマの PNG を塗る描き手（gpu・cpu・空 = 既定。painter.go の choosePainter）。
	paint string
}

func parseShootArgs(args []string) (shootArgs, error) {
	a := shootArgs{saves: true, resident: true, savesFrom: filepath.Join("debug", "migrate", "baseline")}
	var pos []string
	for i := 0; i < len(args); i++ {
		v := args[i]
		value := func() (string, error) {
			if i+1 >= len(args) {
				return "", fmt.Errorf("%s の後に値が要る", v)
			}
			i++
			return args[i], nil
		}
		var err error
		switch v {
		case "--jobs":
			var s string
			if s, err = value(); err == nil {
				a.jobs, err = strconv.Atoi(s)
				if err == nil && a.jobs < 1 {
					err = fmt.Errorf("--jobs は 1 以上")
				}
			}
		case "--run":
			a.run, err = value()
		case "--saves-from":
			a.savesFrom, err = value()
		case "--no-saves":
			a.saves = false
		case "--video":
			a.video = true
		case "--overwrite":
			a.overwrite = true
		case "--full":
			a.full = true
		case "--no-resident":
			a.resident = false
		case "--paint":
			if a.paint, err = value(); err == nil && a.paint != PaintGPU && a.paint != PaintCPU {
				err = fmt.Errorf("--paint は gpu か cpu（%q）", a.paint)
			}
		default:
			if strings.HasPrefix(v, "-") {
				return a, fmt.Errorf("知らない引数: %s", v)
			}
			pos = append(pos, v)
		}
		if err != nil {
			return a, err
		}
	}
	if len(pos) < 2 {
		return a, fmt.Errorf("記録の名前と flow が 1 本以上要る")
	}
	a.name, a.flows = pos[0], pos[1:]
	if strings.ContainsAny(a.name, `/\`) || a.name == "." || a.name == ".." {
		return a, fmt.Errorf("記録の名前 %q はフォルダの名前 1 つ（debug/migrate/<名前> に書く）", a.name)
	}
	seen := map[string]string{}
	for _, f := range a.flows {
		n := flowName(f)
		if prev, ok := seen[n]; ok {
			return a, fmt.Errorf("同じ名前の flow が 2 本ある: %s と %s（flows/%s が重なる）", prev, f, n)
		}
		seen[n] = f
	}
	if a.run == "" {
		a.run = os.Getenv("HEADLESS_RUN")
	}
	if a.run == "" {
		exe, err := os.Executable()
		if err != nil {
			return a, fmt.Errorf("headless-run の場所が分からない（--run で渡す）: %v", err)
		}
		a.run = shellQuote(filepath.Join(filepath.Dir(exe), "headless-run"))
	}
	return a, nil
}

func flowName(path string) string {
	return strings.TrimSuffix(filepath.Base(path), ".flow")
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// autoJobs はコア数から並べる本数を決める。
// WhyNot: メモリで絞らない — 1 本のヒープを shootHeap で蓋をしたので、既定のヒープの上限まで膨らむゴミで本数を削る理由が無い。
// 足りない機械では memoryNote が知らせる。
func autoJobs() int {
	n := runtime.NumCPU() / shootCoresPerJob
	if n > shootMaxJobs {
		n = shootMaxJobs
	}
	if n < 1 {
		n = 1
	}
	return n
}

// shootJavaOpts は HEADLESS_JAVA_OPTS に 1 本のヒープの蓋を足した物（自分で -Xmx か MaxRAMPercentage を渡せばそれが勝つ）。
// WhyNot: headless-run の既定（MaxRAMPercentage=50）のまま並べない — どの JVM も実メモリの半分までゴミで膨らみ、本数分足すと溢れる。
func shootJavaOpts(opts string) string {
	if strings.Contains(opts, "MaxRAMPercentage") || strings.Contains(opts, "-Xmx") {
		return opts
	}
	return strings.TrimSpace(opts + " " + shootHeap)
}

// memoryNote は本数 × ヒープの蓋が実メモリの 8 割を超える時の 1 行（足りていれば空）。
func memoryNote(jobs int, mem uint64) string {
	need := uint64(jobs) * shootHeapBytes
	if mem == 0 || need*10 <= mem*8 {
		return ""
	}
	return fmt.Sprintf("%d 本 × %s で %d GB 使いうるが、実メモリは %d GB（足りなければ --jobs で減らす）", jobs, shootHeap, need>>30, mem>>30)
}

// cacheNote は render-cache の置き場が、基準の記録の比べのコマ（前と後の 2 回分）を入れきれない時の 1 行（足りていれば空）。
// 入れきれないと prune が古い順に消し、毎回冷えた状態から塗り直す（間違えはしない）。
func cacheNote(baseline, cacheDir string, maxBytes int64, free func(string) int64) string {
	if cacheDir == "" {
		return ""
	}
	frames := baselineFrameCount(baseline)
	need := int64(frames) * shootPNGBytes * 2
	if frames == 0 {
		return ""
	}
	if need > maxBytes {
		return fmt.Sprintf("render-cache の上限 %d MB が、基準のコマ %d 枚の前と後（約 %d MB）より小さい。prune で消えて毎回塗り直す（%s で上げる）",
			maxBytes>>20, frames, need>>20, rendercache.MaxMBEnv)
	}
	if f := free(cacheDir); f >= 0 && f < need {
		return fmt.Sprintf("render-cache の置き場 %s のディスクの空き %d MB が、基準のコマ %d 枚の前と後（約 %d MB）より小さい", cacheDir, f>>20, frames, need>>20)
	}
	return ""
}

// baselineFrameCount は基準の記録の tape.json の frames の数の合計（読めない物は数えない）。
func baselineFrameCount(root string) int {
	side, err := LoadSide(root)
	if err != nil {
		return 0
	}
	n := 0
	for _, sizes := range side.Flows {
		for _, t := range sizes {
			n += len(t.Frames)
		}
	}
	return n
}

func totalMemory() uint64 {
	if out, err := exec.Command("sysctl", "-n", "hw.memsize").Output(); err == nil {
		if v, err := strconv.ParseUint(strings.TrimSpace(string(out)), 10, 64); err == nil {
			return v
		}
	}
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return 0
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) >= 2 && fields[0] == "MemTotal:" {
			kb, _ := strconv.ParseUint(fields[1], 10, 64)
			return kb << 10
		}
	}
	return 0
}

// shootJob は JVM 1 回分（flow 1 本か、古いセーブのファイル 1 つの読み戻し）。
type shootJob struct {
	Kind    string  `json:"kind"`
	Name    string  `json:"name"`
	Seconds float64 `json:"seconds"`
	Code    int     `json:"code"`
	Log     string  `json:"log"`
	weight  int64
	env     []string
	entry   string
	after   func() error
}

func runShoot(args []string, stdout, stderr io.Writer) int {
	a, err := parseShootArgs(args)
	if err != nil {
		fmt.Fprintf(stderr, "migrate shoot: %v\n%s\n", err, usage)
		return 2
	}
	out := filepath.Join("debug", "migrate", a.name)
	if fileExists(filepath.Join(out, FlowsDir)) && !a.overwrite && filepath.Clean(out) == filepath.Clean(a.savesFrom) {
		fmt.Fprintf(stderr, "migrate shoot: %s は古いセーブの元（--saves-from）で、撮ると前の版の基準が消える（撮り直すなら --overwrite）\n", out)
		return 2
	}
	for _, f := range a.flows {
		if !fileExists(f) {
			fmt.Fprintf(stderr, "migrate shoot: flow %s が無い\n", f)
			return 2
		}
	}
	jobs := a.jobs
	if jobs == 0 {
		jobs = autoJobs()
	}
	// 古いセーブは前の版の記録から読むので、消す前に並べておく（--saves-from と out が同じ時に消えないように）。
	var saveFiles []string
	if a.saves {
		saveFiles, _ = filepath.Glob(filepath.Join(a.savesFrom, FlowsDir, "*", "saves.json"))
		if filepath.Clean(out) == filepath.Clean(a.savesFrom) {
			fmt.Fprintf(stderr, "migrate shoot: --overwrite で基準を撮り直す時は古いセーブを読み戻さない（読み戻す元が消える）\n")
			saveFiles = nil
		}
	}
	// 描き手は基準を消す前に決める（--overwrite の時は基準が撮る先なので、基準に合わせない）。
	baselinePainter := ""
	hasBaseline := filepath.Clean(out) != filepath.Clean(a.savesFrom) && isDir(filepath.Join(a.savesFrom, FlowsDir))
	if hasBaseline {
		baselinePainter = recordPainter(a.savesFrom)
	}
	painterValue, painterNote, painterProblem := choosePainter(a.paint, hasBaseline, baselinePainter)
	if painterProblem != "" {
		fmt.Fprintln(stderr, "migrate shoot:", painterProblem)
		return 2
	}
	if painterNote != "" {
		fmt.Fprintln(stdout, "migrate shoot:", painterNote)
	}
	if err := os.RemoveAll(out); err != nil {
		fmt.Fprintln(stderr, "migrate shoot:", err)
		return 2
	}
	logs := filepath.Join(out, "logs")
	if err := os.MkdirAll(logs, 0o755); err != nil {
		fmt.Fprintln(stderr, "migrate shoot:", err)
		return 2
	}
	javaOpts := shootJavaOpts(os.Getenv("HEADLESS_JAVA_OPTS"))
	if note := memoryNote(jobs, totalMemory()); note != "" {
		fmt.Fprintln(stderr, "migrate shoot:", note)
	}
	if note := cacheNote(a.savesFrom, rendercache.Dir(), int64(rendercache.MaxMB())<<20, rendercache.FreeBytes); note != "" {
		fmt.Fprintln(stderr, "migrate shoot:", note)
	}
	base := append(os.Environ(), "HEADLESS_JAVA_OPTS="+javaOpts)
	if os.Getenv("JAVA_TOOL_OPTIONS") == "" {
		base = append(base, "JAVA_TOOL_OPTIONS=-Djava.awt.headless=true")
	}

	// WhyNot: 撮る先が基準と同じ時（--overwrite）は鍵を先に撮らない — 突き合わせる基準はもう消してあり、撮る物が次の基準になる（全部の PNG が要る）。
	var baseSide *Side
	if !a.video && !a.full && filepath.Clean(out) != filepath.Clean(a.savesFrom) {
		baseSide, _ = LoadSide(a.savesFrom)
	}
	engine := engineFingerprint(".")
	// WhyNot: engine が基準と違う時は鍵を先に撮らない — 鍵に engine の fpkg が入るので 1 枚も合わず、全部の flow を 2 回流すだけになる。
	if baseSide != nil && engineDiffers(baselineEngine(a.savesFrom), engine) {
		fmt.Fprintln(stdout, "migrate shoot: 基準と engine が違う（鍵が合わない）ので、鍵を先に撮らず全部のコマを塗る")
		baseSide = nil
	}
	keysFirst := baseSide != nil

	var list []*shootJob
	flowJobs := map[string]*shootJob{}
	for _, f := range a.flows {
		n := flowName(f)
		rec := filepath.Join(out, FlowsDir, n)
		tmp := filepath.Join("debug", "video", "migrate-"+a.name+"-"+n)
		job := &shootJob{Kind: "flow", Name: n, Log: filepath.Join(logs, n+".log"), entry: "FlowVideo.play",
			weight: fileSize(filepath.Join(a.savesFrom, FlowsDir, n, TapeFile)),
			env:    []string{"FLOW=" + f, "FLOW_OUT=" + tmp, "MIGRATE_OUT=" + rec, PngPainterEnv + "=" + painterValue}}
		video := a.video
		if !video {
			// 全コマの動画と音を書かない合図（読むのは FlowVideo。読まない版は今まで通り書き、ここで消す）。
			// WhyNot: FGE_GPU=off を足さない — FLOW_VIDEO を読まない古い FlowVideo は全コマの動画を書くので、GPU を断つと全コマを SoftRaster で塗る。
			job.env = append(job.env, "FLOW_VIDEO=off")
		}
		job.after = func() error {
			defer os.RemoveAll(tmp)
			if !video {
				return nil
			}
			return flowMp4(tmp, filepath.Join(rec, "video.mp4"))
		}
		os.RemoveAll(tmp)
		flowJobs[n] = job
		list = append(list, job)
	}
	for _, s := range saveFiles {
		n := filepath.Base(filepath.Dir(s))
		list = append(list, &shootJob{Kind: "restore", Name: n, Log: filepath.Join(logs, "restore-"+n+".log"), entry: "FlowVideo.restore",
			weight: 0,
			env:    []string{"MIGRATE_SAVE=" + s, "MIGRATE_OUT=" + filepath.Join(out, SavesDir), "MIGRATE_NAME=" + n, PngPainterEnv + "=" + painterValue}})
	}
	// 長い flow から先に流す（最後に長い 1 本だけが残って他のコアが遊ぶのを避ける）。
	sort.SliceStable(list, func(i, j int) bool { return list[i].weight > list[j].weight })

	if strings.Contains(a.run, "headless-run") {
		// jar が古い時に、並べた全部が作り直しの鍵を待って並ぶより先に 1 回作る。
		build := exec.Command("bash", "-c", a.run+" --build-only")
		build.Env, build.Stdout, build.Stderr = base, stdout, stderr
		if err := build.Run(); err != nil {
			fmt.Fprintln(stderr, "migrate shoot: jar を作れない:", err)
			return 2
		}
	}

	// WhyNot: 動画を束ねる回（--video）は常駐へ頼まない — 全コマの動画は GPU で塗る事があり、待ち受けの JVM は GL を持たない。
	entries := []string{"FlowVideo.play"}
	if len(saveFiles) > 0 {
		entries = append(entries, "FlowVideo.restore")
	}
	useResident := a.resident && !a.video
	if useResident && !flowVideoSkipsVideo("src") {
		useResident = false
		fmt.Fprintln(stderr, "migrate shoot: ゲームの FlowVideo が FLOW_VIDEO=off を読まない（全コマの動画を GPU で書く）ので、常駐へ頼まず 1 本ずつ JVM を起こす")
	}
	pool := newShootPool(a.run, base, logs, jobs, useResident, entries)
	defer pool.close()
	mode := "全部のコマを塗る"
	if keysFirst {
		mode = "比べのコマは鍵を先に撮り、基準と鍵の違うコマだけ塗る"
	}
	fmt.Fprintf(stdout, "migrate shoot: %s に flow %d 本・古いセーブ %d 個を %d 本ずつ並べて撮る（%s・%s・ログは %s）\n",
		out, len(a.flows), len(saveFiles), jobs, mode, map[bool]string{true: "常駐で流す", false: "1 本ずつ JVM を起こす"}[pool.useResident()], logs)
	start := time.Now()
	if keysFirst {
		for _, job := range flowJobs {
			job.env = append(job.env, paintEnv(nil)...)
		}
	}
	runShootJobs(pool, jobs, list, stdout)
	all := list
	var plan *paintPlan
	var problems []string
	if keysFirst {
		if countFailed(list) > 0 {
			problems = append(problems, "鍵だけ撮る 1 回目で止まった仕事があるので、鍵の違うコマを塗らずに終える")
		} else {
			var paintJobs []*shootJob
			plan, paintJobs, problems = paintAndCopy(pool, jobs, out, baseSide, flowJobs, logs, stdout, baselinePainter)
			all = append(all, paintJobs...)
		}
	}
	wall := time.Since(start).Seconds()
	for drained := false; !drained; {
		select {
		case n := <-pool.notes:
			fmt.Fprintln(stderr, "migrate shoot:", n)
		default:
			drained = true
		}
	}

	failed := countFailed(all)
	painter, note, problem := shotPainter(paintedWith(out), painterValue, baselinePainter)
	if note != "" {
		fmt.Fprintln(stdout, "migrate shoot:", note)
	}
	if problem != "" {
		problems = append(problems, problem)
	}
	summary := map[string]any{"jobs": jobs, "wallSeconds": wall, "runs": all, "resident": pool.useResident(), "keysFirst": keysFirst,
		"engine": engine, "painter": painter, "problems": problems}
	if plan != nil {
		summary["paint"] = plan
	}
	if data, err := json.MarshalIndent(summary, "", "  "); err == nil {
		_ = os.WriteFile(filepath.Join(logs, ShootSummaryFile), append(data, '\n'), 0o644)
	}
	fmt.Fprintf(stdout, "migrate shoot: %.1f 秒で撮った（%d 本・止まった %d 本）\n", wall, len(all), failed)
	for _, p := range problems {
		fmt.Fprintln(stderr, "migrate shoot:", p)
	}
	if failed > 0 {
		for _, job := range all {
			if job.Code != 0 {
				fmt.Fprintf(stderr, "  止まった: %s %s（ログ %s）\n", job.Kind, job.Name, job.Log)
			}
		}
	}
	if failed > 0 || len(problems) > 0 {
		return 1
	}
	return 0
}

func countFailed(list []*shootJob) int {
	n := 0
	for _, job := range list {
		if job.Code != 0 {
			n++
		}
	}
	return n
}

// paintAndCopy は鍵だけ撮った記録に、基準と鍵の違うコマの PNG を用意する（写す・塗るために flow を流し直す・同じ鍵へ写す）。
// 止める理由があれば problems に返す。
func paintAndCopy(pool *shootPool, jobs int, out string, baseSide *Side, flowJobs map[string]*shootJob, logs string, stdout io.Writer, painter string) (*paintPlan, []*shootJob, []string) {
	plan, paintJobs, err := paintStage(out, baseSide, flowJobs, logs, painter)
	if err != nil {
		return nil, nil, []string{"鍵を先に撮った後に PNG を用意できない: " + err.Error()}
	}
	before := drawHashTexts(filepath.Join(out, FlowsDir))
	runShootJobs(pool, jobs, paintJobs, stdout)
	if countFailed(paintJobs) > 0 {
		return plan, paintJobs, []string{"塗るために流し直した flow が止まった"}
	}
	if bad := sameDrawHashes(before, drawHashTexts(filepath.Join(out, FlowsDir))); len(bad) > 0 {
		return plan, paintJobs, []string{"塗るために流し直した flow の鍵が 1 回目と違う（決定性が破れている）: " + strings.Join(bad, " ")}
	}
	var problems []string
	for _, c := range plan.Copies {
		if err := copyFile(c.src, c.dst); err != nil {
			problems = append(problems, "同じ鍵のコマへ写せない: "+err.Error())
		}
	}
	cur, err := LoadSide(out)
	if err != nil {
		return plan, paintJobs, append(problems, err.Error())
	}
	if miss := missingPNGs(cur, baseSide); len(miss) > 0 {
		problems = append(problems, fmt.Sprintf("鍵が基準と違うのに PNG の無いコマが %d 枚（最初: %s）", len(miss), miss[0]))
	}
	fmt.Fprintf(stdout, "migrate shoot: 鍵が基準と同じで PNG を書かなかった %d 枚・基準から写した %d 枚・render-cache から写した %d 枚・塗った %d 枚（flow %d 本を流し直した）・同じ鍵のほかのコマから写した %d 枚\n",
		plan.KeysOnly, plan.FromBaseline, plan.FromCache, plan.Painted, len(paintJobs), plan.FromSibling)
	return plan, paintJobs, problems
}

// flowVideoSkipsVideo はゲームの FlowVideo.flix が FLOW_VIDEO を読むか（読まない古い版は全コマの動画を書く）。
// WhyNot: 古い版を常駐へ頼まない — 全コマの動画は GPU で塗り、待ち受けの JVM は入口を主スレッドでなく別の糸で流すので、
// GL が開けずに全コマを SoftRaster で塗る事がある。
func flowVideoSkipsVideo(src string) bool {
	found := false
	_ = filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || info.Name() != "FlowVideo.flix" {
			return nil
		}
		if b, err := os.ReadFile(p); err == nil && strings.Contains(string(b), "FLOW_VIDEO") {
			found = true
		}
		return nil
	})
	return found
}

// runShootJobs は list を jobs 本ずつ並べて流す（枠ごとに 1 本の糸）。
func runShootJobs(pool *shootPool, jobs int, list []*shootJob, stdout io.Writer) {
	queue := make(chan *shootJob)
	var wg sync.WaitGroup
	var mu sync.Mutex
	for slot := 0; slot < jobs; slot++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for job := range queue {
				pool.exec(slot, job)
				mu.Lock()
				mark := "ok"
				if job.Code != 0 {
					mark = "FAIL（" + strconv.Itoa(job.Code) + "）"
				}
				fmt.Fprintf(stdout, "  %-8s %-24s %6.1f 秒 %s\n", job.Kind, job.Name, job.Seconds, mark)
				mu.Unlock()
			}
		}()
	}
	for _, job := range list {
		queue <- job
	}
	close(queue)
	wg.Wait()
}

// paintStage は鍵だけ撮った記録を基準と突き合わせ、写せる PNG を写し、塗るコマのある flow を流し直す仕事を作る。
// painter は基準の描き手（鍵が基準と同じコマは基準の PNG を写すので、塗るのも同じ描き手。render-cache の名前に混ぜる）。
func paintStage(out string, baseSide *Side, flowJobs map[string]*shootJob, logs string, painter string) (*paintPlan, []*shootJob, error) {
	cur, err := LoadSide(out)
	if err != nil {
		return nil, nil, err
	}
	plan, err := planPaint(cur, baseSide, cacheDirForCopy(), painter)
	if err != nil {
		return nil, nil, err
	}
	var paintJobs []*shootJob
	for _, flow := range sortedKeys(plan.Paint) {
		first := flowJobs[flow]
		if first == nil {
			continue
		}
		var env []string
		for _, kv := range first.env {
			if !strings.HasPrefix(kv, PaintWorldEnv+"=") && !strings.HasPrefix(kv, PaintAllEnv+"=") {
				env = append(env, kv)
			}
		}
		paintJobs = append(paintJobs, &shootJob{Kind: "paint", Name: flow, Log: filepath.Join(logs, flow+".paint.log"), entry: first.entry,
			weight: first.weight, env: append(env, paintEnv(plan.Paint[flow])...), after: first.after})
	}
	return plan, paintJobs, nil
}

func runShootJob(run string, base []string, job *shootJob) {
	t0 := time.Now()
	defer func() { job.Seconds = time.Since(t0).Seconds() }()
	logf, err := os.Create(job.Log)
	if err != nil {
		job.Code = 2
		return
	}
	cmd := exec.Command("bash", "-c", run+" "+job.entry)
	cmd.Env = append(append([]string{}, base...), job.env...)
	cmd.Stdout, cmd.Stderr = logf, logf
	if err := cmd.Run(); err != nil {
		job.Code = 1
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() > 0 {
			job.Code = ee.ExitCode()
		}
	}
	logf.Close()
	finishJob(job)
}

// finishJob は仕事の後片付け（job.after）を流し、失敗したらログへ書いて止まった事にする。
func finishJob(job *shootJob) {
	if job.after == nil {
		return
	}
	if err := job.after(); err != nil {
		if f, ferr := os.OpenFile(job.Log, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o644); ferr == nil {
			fmt.Fprintf(f, "migrate shoot: %v\n", err)
			f.Close()
		}
		if job.Code == 0 {
			job.Code = 1
		}
	}
}

// flowMp4 は FlowVideo が書いたコマと音（dir）を H.264 + AAC の mp4 に束ねる（ゲームの Makefile の flow-mp4 と同じ旗）。
func flowMp4(dir, mp4 string) error {
	fps := "30"
	if b, err := os.ReadFile(filepath.Join(dir, "fps.txt")); err == nil {
		fps = strings.TrimSpace(string(b))
	}
	in := []string{"-i", filepath.Join(dir, "frames.mkv")}
	if !fileExists(filepath.Join(dir, "frames.mkv")) {
		in = []string{"-framerate", fps, "-i", filepath.Join(dir, "f%04d.png")}
	}
	args := append([]string{"-y", "-loglevel", "error"}, in...)
	args = append(args, "-f", "f64be", "-ar", "44100", "-ac", "2", "-i", filepath.Join(dir, "audio.f64"),
		"-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-r", fps, "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", mp4)
	out, err := exec.Command(ffmpegPath(), args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("mp4 に束ねられない: %v %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func fileSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size()
}
