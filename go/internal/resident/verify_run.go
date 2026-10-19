package resident

// `fge resident verify`: ゲームの根を一時の場所へ写し、素の道と常駐を 5 回流して比べる（設計 2.5 節）。

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// VerifyOptions は `fge resident verify` の引数。
type VerifyOptions struct {
	Dir      string
	Keep     bool
	TouchDoc string
	TouchPNG string
	Between  string
	Ignore   []string
	MakeArgs []string
	Env      map[string]string
	Progress io.Writer
	Report   io.Writer
	MakeCmd  string
}

// RunResult は 1 回流した結果。
type RunResult struct {
	Label  string
	Code   int
	Stdout string
	Files  FileTable
}

// Verify は 5 回流して比べ、差 0 なら 0・差があれば 1・流せなければ 2 を返す。
func Verify(engineRoot string, o VerifyOptions) int {
	if len(o.MakeArgs) == 0 {
		fmt.Fprintln(o.Report, "fge resident verify: -- の後に make の口を書く（例 -- render SHOT=title）")
		return 2
	}
	if o.MakeCmd == "" {
		o.MakeCmd = "make"
	}
	src, err := ResolveRoot(o.Dir)
	if err != nil {
		fmt.Fprintf(o.Report, "fge resident verify: %v\n", err)
		return 2
	}
	engine, shots, err := makeVars(o.MakeCmd, src, o.Env)
	if err != nil {
		fmt.Fprintf(o.Report, "fge resident verify: ゲームの Makefile から ENGINE を読めない: %v\n", err)
		return 2
	}
	between, err := BetweenArgs(o.Between, o.MakeArgs, shots)
	if err != nil {
		fmt.Fprintf(o.Report, "fge resident verify: %v\n", err)
		return 2
	}
	tmp, err := os.MkdirTemp("", "fge-verify-")
	if err != nil {
		fmt.Fprintf(o.Report, "fge resident verify: %v\n", err)
		return 2
	}
	copyRoot := filepath.Join(tmp, filepath.Base(src))
	defer func() {
		var b strings.Builder
		Stop(engineRoot, copyRoot, &b)
		if o.Keep {
			fmt.Fprintf(o.Report, "写しを残した: %s（make の出力は %s）\n", copyRoot, filepath.Join(tmp, "logs"))
			return
		}
		_ = os.RemoveAll(tmp)
	}()
	fmt.Fprintf(o.Progress, "[verify] 写す: %s → %s\n", src, copyRoot)
	if err := CopyTree(src, copyRoot); err != nil {
		fmt.Fprintf(o.Report, "fge resident verify: 写せない: %v\n", err)
		return 2
	}
	v := &verifier{o: o, root: copyRoot, engine: engine, logs: filepath.Join(tmp, "logs")}
	_ = os.MkdirAll(v.logs, 0o755)

	r1 := v.measure("1 素の道", "0", o.MakeArgs)
	r2 := v.measure("2 常駐", "1", o.MakeArgs)
	v.flow("3 の前に挟む", "1", between)
	r3 := v.measure("3 別の入口の後の常駐", "1", o.MakeArgs)
	touched, err := v.touch()
	if err != nil {
		fmt.Fprintf(o.Report, "fge resident verify: 書き換えられない: %v\n", err)
		return 2
	}
	r4 := v.measure("4 書き換えの後の常駐", "1", o.MakeArgs)
	r5 := v.measure("5 書き換えの後の素の道", "0", o.MakeArgs)

	fmt.Fprintf(o.Report, "口: make %s（ENGINE=%s・挟む口: make %s）\n", strings.Join(o.MakeArgs, " "), engine, strings.Join(between, " "))
	if len(o.Ignore) > 0 {
		fmt.Fprintf(o.Report, "表から除く: %s\n", strings.Join(o.Ignore, " "))
	}
	for _, t := range touched {
		fmt.Fprintf(o.Report, "書き換え: %s\n", t)
	}
	for _, r := range []RunResult{r1, r2, r3, r4, r5} {
		fmt.Fprintf(o.Report, "%s: exit %d・書いたファイル %d\n", r.Label, r.Code, len(r.Files))
	}
	fmt.Fprintln(o.Report, "書いたファイル（1 回目）:")
	for _, rel := range r1.Files.SortedPaths() {
		fmt.Fprintf(o.Report, "  %s  %s\n", r1.Files[rel], rel)
	}
	// 比べの組には入れない。書き換えが書いたファイルに届いたかを見るだけ（0 なら 4↔5 の差 0 は弱い証）。
	fmt.Fprintf(o.Report, "参考 1↔4: 書き換えで中身が変わったファイル %d\n", len(DiffTables(r1.Files, r4.Files)))
	diffs := 0
	for _, p := range [][2]RunResult{{r1, r2}, {r1, r3}, {r4, r5}} {
		for _, line := range ComparePair(p[0], p[1]) {
			fmt.Fprintln(o.Report, line)
			diffs++
		}
	}
	if diffs > 0 {
		fmt.Fprintf(o.Report, "verify NG: 5 回・差 %d\n", diffs)
		return 1
	}
	fmt.Fprintln(o.Report, "verify OK: 5 回・差 0")
	return 0
}

// ComparePair は 2 回の結果の違い（終了コード・書いたファイル・標準出力）を 1 行ずつ返す。
func ComparePair(a, b RunResult) []string {
	pair := a.Label[:1] + "↔" + b.Label[:1]
	var out []string
	if a.Code != b.Code {
		out = append(out, fmt.Sprintf("差 %s: 終了コード %d と %d", pair, a.Code, b.Code))
	}
	for _, rel := range DiffTables(a.Files, b.Files) {
		out = append(out, fmt.Sprintf("差 %s: %s（%s と %s）", pair, rel, shortSum(a.Files[rel]), shortSum(b.Files[rel])))
	}
	if n, x, y := FirstLineDiff(a.Stdout, b.Stdout); n > 0 {
		out = append(out, fmt.Sprintf("差 %s: 標準出力の %d 行目 %q と %q", pair, n, x, y))
	}
	return out
}

func shortSum(s string) string {
	if s == "" {
		return "無い"
	}
	return s[:12]
}

type verifier struct {
	o      VerifyOptions
	root   string
	engine string
	logs   string
	n      int
}

// measure は書いた物を消してから 1 回流し、書いたファイルの表と整えた標準出力を返す。
func (v *verifier) measure(label, resident string, args []string) RunResult {
	if err := clearOutputs(v.root); err != nil {
		fmt.Fprintf(v.o.Progress, "[verify] %s: 前の生成物を消せない: %v\n", label, err)
	}
	before, _ := SnapshotOutputs(v.root)
	code, stdout := v.flow(label, resident, args)
	after, err := SnapshotOutputs(v.root)
	if err != nil {
		fmt.Fprintf(v.o.Progress, "[verify] %s: 書いたファイルを読めない: %v\n", label, err)
	}
	r := RunResult{Label: label, Code: code, Files: WithoutPrefixes(Written(before, after), v.o.Ignore),
		Stdout: NormalizeStdout(stdout, v.root, unresolved(v.root))}
	var b strings.Builder
	for _, rel := range r.Files.SortedPaths() {
		fmt.Fprintf(&b, "%s\t%s\n", r.Files[rel], rel)
	}
	_ = os.WriteFile(filepath.Join(v.logs, fmt.Sprintf("%d.files.tsv", v.n)), []byte(b.String()), 0o644)
	_ = os.WriteFile(filepath.Join(v.logs, fmt.Sprintf("%d.stdout.txt", v.n)), []byte(r.Stdout+"\n"), 0o644)
	return r
}

// flow は写しの中で make を 1 回流す。標準出力は返し、標準エラーは logs へ書く。
func (v *verifier) flow(label, resident string, args []string) (int, string) {
	v.n++
	fmt.Fprintf(v.o.Progress, "[verify] %s: HEADLESS_RESIDENT=%s make %s\n", label, resident, strings.Join(args, " "))
	full := append([]string{"--no-print-directory", "ENGINE=" + v.engine}, args...)
	cmd := exec.Command(v.o.MakeCmd, full...)
	cmd.Dir = v.root
	cmd.Env = runEnv(v.o.Env, resident)
	var stdout bytes.Buffer
	logPath := filepath.Join(v.logs, fmt.Sprintf("%d.log", v.n))
	logf, err := os.Create(logPath)
	if err != nil {
		logf = nil
	}
	if logf != nil {
		defer logf.Close()
		fmt.Fprintf(logf, "# %s: HEADLESS_RESIDENT=%s make %s\n", label, resident, strings.Join(args, " "))
		cmd.Stdout = io.MultiWriter(&stdout, logf)
		cmd.Stderr = logf
	} else {
		cmd.Stdout = &stdout
	}
	code := 0
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			code = ee.ExitCode()
		} else {
			fmt.Fprintf(v.o.Progress, "[verify] %s: make を流せない: %v\n", label, err)
			code = -1
		}
	}
	fmt.Fprintf(v.o.Progress, "[verify] %s: exit %d\n", label, code)
	return code, stdout.String()
}

// touch は写しの中の Doc と PNG を書き換え、何をしたかを返す。
func (v *verifier) touch() ([]string, error) {
	var done []string
	if v.o.TouchDoc != "" {
		path := filepath.Join(v.root, filepath.FromSlash(v.o.TouchDoc))
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		out, what := TouchJSON(raw)
		if err := os.WriteFile(path, out, 0o644); err != nil {
			return nil, err
		}
		done = append(done, v.o.TouchDoc+": "+what)
	}
	if v.o.TouchPNG != "" {
		path := filepath.Join(v.root, filepath.FromSlash(v.o.TouchPNG))
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		out, what, err := TouchPNG(raw)
		if err != nil {
			return nil, fmt.Errorf("%s: %v", v.o.TouchPNG, err)
		}
		if err := os.WriteFile(path, out, 0o644); err != nil {
			return nil, err
		}
		done = append(done, v.o.TouchPNG+": "+what)
	}
	if len(done) == 0 {
		done = append(done, "無し（--touch-doc も --touch-png も無いので 4・5 は書き換えずに流した）")
	}
	return done, nil
}

// runEnv は呼んだ人の env に HEADLESS_RESIDENT を決めて足す。
//
// WhyNot: MAKEFLAGS・MAKELEVEL を落とすのは、verify を make の中から呼んだ時に、外の make の
// -j や変数の上書きが写しの make へ漏れて、素の道と常駐で違う旗のまま比べることになるため。
func runEnv(env map[string]string, resident string) []string {
	var out []string
	for k, val := range env {
		switch k {
		case "HEADLESS_RESIDENT", "MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES":
			continue
		}
		out = append(out, k+"="+val)
	}
	return append(out, "HEADLESS_RESIDENT="+resident)
}

// makeVars はゲームの根の make が読む ENGINE（絶対パス）と SHOTS を引く。
func makeVars(makeCmd, root string, env map[string]string) (string, []string, error) {
	probe, err := os.CreateTemp("", "fge-verify-*.mk")
	if err != nil {
		return "", nil, err
	}
	defer os.Remove(probe.Name())
	_, _ = io.WriteString(probe, "__fge_verify_vars:\n\t@printf '%s\\n' '$(ENGINE)'\n\t@printf '%s\\n' '$(SHOTS)'\n")
	probe.Close()
	cmd := exec.Command(makeCmd, "--no-print-directory", "-s", "-f", "Makefile", "-f", probe.Name(), "__fge_verify_vars")
	cmd.Dir = root
	cmd.Env = runEnv(env, "0")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	raw, err := cmd.Output()
	if err != nil {
		return "", nil, fmt.Errorf("%v: %s", err, strings.TrimSpace(stderr.String()))
	}
	lines := strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	if len(lines) < 2 || strings.TrimSpace(lines[len(lines)-2]) == "" {
		return "", nil, fmt.Errorf("ENGINE が空（出力 %q）", raw)
	}
	engine := strings.TrimSpace(lines[len(lines)-2])
	if !filepath.IsAbs(engine) {
		engine = filepath.Join(root, engine)
	}
	if real, err := filepath.EvalSymlinks(engine); err == nil {
		engine = real
	}
	return engine, strings.Fields(lines[len(lines)-1]), nil
}

// unresolved は /private/var/… の /private を外した字（macOS の一時の場所は両方の字で見える）。
func unresolved(root string) string {
	if rest, ok := strings.CutPrefix(root, "/private/"); ok {
		return "/" + rest
	}
	return ""
}

// clearOutputs は gallery/ と debug/ の中身を消す（debug/headless は残す）。
func clearOutputs(root string) error {
	for _, dir := range OutputDirs {
		entries, err := os.ReadDir(filepath.Join(root, dir))
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		for _, e := range entries {
			rel := dir + "/" + e.Name()
			if isIgnoredOutput(rel) {
				continue
			}
			if err := os.RemoveAll(filepath.Join(root, dir, e.Name())); err != nil {
				return err
			}
		}
	}
	return nil
}

// SnapshotOutputs は gallery/ と debug/ の下のファイル（debug/headless を除く）の表。
func SnapshotOutputs(root string) (FileTable, error) {
	t := FileTable{}
	for _, dir := range OutputDirs {
		base := filepath.Join(root, dir)
		err := filepath.WalkDir(base, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				if errors.Is(err, fs.ErrNotExist) && path == base {
					return nil
				}
				return err
			}
			rel, _ := filepath.Rel(root, path)
			rel = filepath.ToSlash(rel)
			if isIgnoredOutput(rel) {
				if d.IsDir() {
					return fs.SkipDir
				}
				return nil
			}
			if !d.Type().IsRegular() {
				return nil
			}
			sum, err := fileSHA(path)
			if err != nil {
				return err
			}
			t[rel] = sum
			return nil
		})
		if err != nil {
			return t, err
		}
	}
	return t, nil
}

// CopyTree は src を dst へ ShouldCopy の判定で写す。symlink は symlink のまま写し、
// 相対の行き先は元の場所から見た絶対パスに直す（写しの場所から辿っても同じ物を指すように）。
func CopyTree(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, path)
		target := filepath.Join(dst, rel)
		if rel == "." {
			return os.MkdirAll(target, 0o755)
		}
		slash := filepath.ToSlash(rel)
		if !ShouldCopy(slash, d.IsDir()) {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		switch {
		case d.Type()&fs.ModeSymlink != 0:
			link, err := os.Readlink(path)
			if err != nil {
				return err
			}
			if !filepath.IsAbs(link) {
				link = filepath.Join(filepath.Dir(path), link)
			}
			return os.Symlink(link, target)
		case d.IsDir():
			return os.MkdirAll(target, 0o755)
		case d.Type().IsRegular():
			return copyFile(path, target)
		}
		return nil
	})
}

func copyFile(from, to string) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	info, err := in.Stat()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
		return err
	}
	out, err := os.OpenFile(to, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, info.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	// WhyNot: 更新時刻を元にそろえるのは、指紋を作れない時の headless-run が時刻で jar の古さを
	// 決めるので、写した src が jar より新しく見えて作り直しが走るのを避けるため。
	return os.Chtimes(to, info.ModTime(), info.ModTime())
}
