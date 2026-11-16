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
)

// 1 本の flow を撮る JVM が使う物の見積もり（血鱗の route_gem: CPU は平均 5 コア・最大の常駐が約 10 GB）。
// 本数はこの 2 つで決め、上限は shootMaxJobs。
const (
	shootCoresPerJob = 4
	shootMemPerJob   = 8 << 30
	shootMaxJobs     = 6
)

type shootArgs struct {
	name, run, savesFrom    string
	jobs                    int
	video, overwrite, saves bool
	flows                   []string
}

func parseShootArgs(args []string) (shootArgs, error) {
	a := shootArgs{saves: true, savesFrom: filepath.Join("debug", "migrate", "baseline")}
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

// autoJobs はコア数とメモリから並べる本数を決める。
func autoJobs() int {
	n := runtime.NumCPU() / shootCoresPerJob
	if mem := totalMemory(); mem > 0 {
		if m := int(mem / shootMemPerJob); m < n {
			n = m
		}
	}
	if n > shootMaxJobs {
		n = shootMaxJobs
	}
	if n < 1 {
		n = 1
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
	if err := os.RemoveAll(out); err != nil {
		fmt.Fprintln(stderr, "migrate shoot:", err)
		return 2
	}
	logs := filepath.Join(out, "logs")
	if err := os.MkdirAll(logs, 0o755); err != nil {
		fmt.Fprintln(stderr, "migrate shoot:", err)
		return 2
	}
	javaOpts := os.Getenv("HEADLESS_JAVA_OPTS")
	if !strings.Contains(javaOpts, "MaxRAMPercentage") && !strings.Contains(javaOpts, "-Xmx") {
		// WhyNot: headless-run の既定（MaxRAMPercentage=50）のまま並べない — どの JVM も実メモリの半分まで膨らみ、本数分足すと溢れる。
		pct := 60 / jobs
		if pct < 8 {
			pct = 8
		}
		javaOpts = strings.TrimSpace(javaOpts + " -XX:MaxRAMPercentage=" + strconv.Itoa(pct))
	}
	base := append(os.Environ(), "HEADLESS_JAVA_OPTS="+javaOpts)
	if os.Getenv("JAVA_TOOL_OPTIONS") == "" {
		base = append(base, "JAVA_TOOL_OPTIONS=-Djava.awt.headless=true")
	}

	var list []*shootJob
	for _, f := range a.flows {
		n := flowName(f)
		rec := filepath.Join(out, FlowsDir, n)
		tmp := filepath.Join("debug", "video", "migrate-"+a.name+"-"+n)
		job := &shootJob{Kind: "flow", Name: n, Log: filepath.Join(logs, n+".log"), entry: "FlowVideo.play",
			weight: fileSize(filepath.Join(a.savesFrom, FlowsDir, n, TapeFile)),
			env:    []string{"FLOW=" + f, "FLOW_OUT=" + tmp, "MIGRATE_OUT=" + rec}}
		video := a.video
		if !video {
			// 全コマの動画と音を書かない合図（読むのは FlowVideo。読まない版は今まで通り書き、ここで消す）。
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
		list = append(list, job)
	}
	for _, s := range saveFiles {
		n := filepath.Base(filepath.Dir(s))
		list = append(list, &shootJob{Kind: "restore", Name: n, Log: filepath.Join(logs, "restore-"+n+".log"), entry: "FlowVideo.restore",
			weight: 0,
			env:    []string{"MIGRATE_SAVE=" + s, "MIGRATE_OUT=" + filepath.Join(out, SavesDir), "MIGRATE_NAME=" + n}})
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

	fmt.Fprintf(stdout, "migrate shoot: %s に flow %d 本・古いセーブ %d 個を %d 本ずつ並べて撮る（ログは %s）\n",
		out, len(a.flows), len(saveFiles), jobs, logs)
	start := time.Now()
	queue := make(chan *shootJob)
	var wg sync.WaitGroup
	var mu sync.Mutex
	for w := 0; w < jobs; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for job := range queue {
				runShootJob(a.run, base, job)
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
	wall := time.Since(start).Seconds()

	failed := 0
	for _, job := range list {
		if job.Code != 0 {
			failed++
		}
	}
	summary := map[string]any{"jobs": jobs, "wallSeconds": wall, "runs": list}
	if data, err := json.MarshalIndent(summary, "", "  "); err == nil {
		_ = os.WriteFile(filepath.Join(logs, "shoot.json"), append(data, '\n'), 0o644)
	}
	fmt.Fprintf(stdout, "migrate shoot: %.1f 秒で撮った（%d 本・止まった %d 本）\n", wall, len(list), failed)
	if failed > 0 {
		for _, job := range list {
			if job.Code != 0 {
				fmt.Fprintf(stderr, "  止まった: %s %s（ログ %s）\n", job.Kind, job.Name, job.Log)
			}
		}
		return 1
	}
	return 0
}

func runShootJob(run string, base []string, job *shootJob) {
	t0 := time.Now()
	defer func() { job.Seconds = time.Since(t0).Seconds() }()
	logf, err := os.Create(job.Log)
	if err != nil {
		job.Code = 2
		return
	}
	defer logf.Close()
	cmd := exec.Command("bash", "-c", run+" "+job.entry)
	cmd.Env = append(append([]string{}, base...), job.env...)
	cmd.Stdout, cmd.Stderr = logf, logf
	if err := cmd.Run(); err != nil {
		job.Code = 1
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() > 0 {
			job.Code = ee.ExitCode()
		}
	}
	if job.after != nil {
		if err := job.after(); err != nil {
			fmt.Fprintf(logf, "migrate shoot: %v\n", err)
			if job.Code == 0 {
				job.Code = 1
			}
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
