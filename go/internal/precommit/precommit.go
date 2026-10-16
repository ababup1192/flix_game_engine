package precommit

// precommit — git commit の直前に走るゲート。
//
// 自分では何も判定せず、同じプロセスの中で検査のハンドラを順に呼んで結果を束ねる。
// 呼ぶ順と条件は bin/lint-rules/precommit.json が持つ。
//
// 出力の並びについて:
// 各検査の出力は Stdout / Stderr へその場で書き、ゲート自身が出す知らせだけを
// out へ貯めて呼び側 (main) に最後へ書かせる。2>&1 でまとめて受けても
// 「検査の出力が全部先・ゲートの知らせが後」の並びになる。

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

// Lint は 1 本の検査の入口。out が stdout・errOut が stderr へ出す分。
type Lint func(out, errOut *strings.Builder, args []string) int

// Options は Run に渡す道具立て。
type Options struct {
	// Root はリポジトリのルート (絶対パスに直してから使う)。
	Root string
	// Args はコマンド名より後ろの引数 (--root は取り除いた後)。
	Args []string
	// Stdout / Stderr は各検査がその場で書く先。
	Stdout io.Writer
	Stderr io.Writer
	// Lints はサブコマンド名から検査の入口を引く表。
	Lints map[string]Lint
	// Images は「過去から追跡されている絵」の検査 (終了コードだけを見る)。
	Images func(root string) int
}

type runner struct {
	opts   Options
	rules  *Rules
	root   string
	parent *strings.Builder
}

// ResolveRoot は根を絶対パスに直し、途中の symlink も解く。
// WhyNot: filepath.Abs だけで済ませないのは、macOS の /var → /private/var のような
// symlink の食い違いが残ると、検査が出すパスの見え方が変わるため。
func ResolveRoot(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("根のパスを解けません: %v", err)
	}
	if real, err := filepath.EvalSymlinks(abs); err == nil {
		return real, nil
	}
	return abs, nil
}

// Run はゲートを走らせる。out には親が出す知らせだけが入る (呼び側が最後に書く)。
func Run(out *strings.Builder, opts Options) (int, error) {
	root, err := ResolveRoot(opts.Root)
	if err != nil {
		return 2, err
	}
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	r := &runner{opts: opts, rules: rules, root: root, parent: out}

	// WhyNot: 根へ移ってから走らせるのは、検査が受け取るパスを根からの相対のままに
	// しておくため。移らないと出力に絶対パスが混ざる。
	old, err := os.Getwd()
	if err != nil {
		return 2, fmt.Errorf("いまの場所を取れません: %v", err)
	}
	if err := os.Chdir(root); err != nil {
		return 2, fmt.Errorf("根へ移れません: %v", err)
	}
	defer func() { _ = os.Chdir(old) }()

	staged, err := r.stagedFiles()
	if err != nil {
		return 2, err
	}
	return r.gate(staged)
}

// stagedFiles は今回ステージしたパス。--files が来ていればそちらを使う。
func (r *runner) stagedFiles() ([]string, error) {
	args := r.opts.Args
	// WhyNot: len(args) > 1 を見るのは、「--files だけ」で中身が空のときに
	// 「対象なし」と取らず、ステージを読みに行かせるため。
	if len(args) > 1 && args[0] == "--files" {
		return args[1:], nil
	}
	cmd := exec.Command("git", "-C", r.root, "diff", "--cached",
		"--name-only", "--diff-filter=ACMR", "-z")
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("git diff --cached が失敗しました: %v", err)
	}
	var paths []string
	for _, p := range strings.Split(string(out), "\x00") {
		if p != "" && !pxlib.InTestdata(p) {
			paths = append(paths, p)
		}
	}
	return paths, nil
}

func (r *runner) gate(staged []string) (int, error) {
	if len(staged) == 0 {
		return 0, nil
	}
	failed := false

	if msg := r.checkUseEngineToml(staged); msg != "" {
		failed = true
		fmt.Fprintln(r.parent, msg)
	}

	problems := r.checkStagedImages(staged)
	if len(problems) > 0 {
		failed = true
		fmt.Fprintf(r.parent, "[pre-commit] 画像 %d 件:\n", len(problems))
		for _, m := range problems {
			fmt.Fprintf(r.parent, "  %s\n", m)
		}
	}

	for _, c := range r.rules.Checks {
		matched := selectPaths(staged, c.When)
		if len(matched) == 0 {
			continue
		}
		var args []string
		args = append(args, c.Flags...)
		if c.Pass == "matched" {
			args = append(args, matched...)
		}
		code, err := r.runLint(c, args)
		if err != nil {
			return 2, err
		}
		if code != 0 {
			failed = true
		}
	}

	if len(selectPaths(staged, r.rules.DocsSync.When)) > 0 && r.hasDocsSyncTarget() {
		if r.runMake("-s", r.rules.DocsSync.Target) != 0 {
			failed = true
		}
	}

	if t := r.rules.LocalGate.Target; t != "" && len(staged) > 0 && r.hasTarget(t) {
		code, err := r.runLocalGate(t, staged)
		if err != nil {
			return 2, err
		}
		if code != 0 {
			failed = true
		}
	}

	if failed {
		// WhyNot: フックを飛ばす書き方を案内しないのは、止めた理由を直さずに通す道を
		// 止めた本人が示すことになるため（エージェントはそのまま使う）。
		fmt.Fprint(r.parent, "[pre-commit] 止めました。上の文を読んで直してから再コミット\n")
		return 1, nil
	}
	return 0, nil
}

func selectPaths(staged []string, m Matcher) []string {
	var out []string
	for _, p := range staged {
		if m.Match(p) {
			out = append(out, p)
		}
	}
	return out
}

// runLint は検査を 1 本走らせる。
// WhyNot: 走らせる前に道具の実在を見ないのは、検査の中身がこのバイナリ自身の中に
// あるため。外の道具を呼んでいた頃の実在検査を残すと、常に「無い」と読めて
// 全部の検査がスキップする（ゲートが黙って開く）。
func (r *runner) runLint(c Check, args []string) (int, error) {
	fn := r.opts.Lints[c.Sub]
	if fn == nil {
		return 0, fmt.Errorf("サブコマンド %s の入口がありません (bin/lint-rules/precommit.json)", c.Sub)
	}
	var body, errBody strings.Builder
	code := fn(&body, &errBody, args)
	// WhyNot: stderr を先に書くのは、2>&1 でまとめて受けたときに
	// 1 本の検査の中で行順が入れ替わらないようにするため。
	io.WriteString(r.opts.Stderr, errBody.String())
	io.WriteString(r.opts.Stdout, body.String())
	return code, nil
}

func human(n int64) string {
	if n >= 1024*1024 {
		return fmt.Sprintf("%.1fMB", float64(n)/1024/1024)
	}
	return fmt.Sprintf("%.0fKB", float64(n)/1024)
}

// checkStagedImages は今回ステージした画像だけを、置き場と大きさの決まりに照らす。
func (r *runner) checkStagedImages(staged []string) []string {
	var problems []string
	s := r.rules.StagedImages
	var imgs []string
	for _, p := range staged {
		if s.IsImage(p) {
			imgs = append(imgs, p)
		}
	}
	for _, p := range imgs {
		if !s.Allowed(p) {
			problems = append(problems, p+" — 追跡してよい置き場ではありません。"+
				"生成した絵は git に入れない決まりです。"+
				"人に見せる絵なら docs/gallery/ へ (上限あり)")
			continue
		}
		var size int64
		if info, err := os.Stat(filepath.Join(r.root, p)); err == nil {
			size = info.Size()
		}
		if strings.HasPrefix(p, s.GalleryPrefix) && size > s.GalleryMaxFileBytes {
			problems = append(problems, fmt.Sprintf("%s が %s — 1 枚の上限 %s (docs/gallery/README.md)",
				p, human(size), human(s.GalleryMaxFileBytes)))
		}
	}
	// 過去分の違反はここでは止めない。画像を触るコミットのときだけ 1 行知らせる。
	if len(imgs) > 0 && len(problems) == 0 {
		if r.opts.Images != nil && r.opts.Images(r.root) != 0 {
			fmt.Fprint(r.parent, "[pre-commit] 注意: 過去から追跡されている絵に違反が残っています"+
				" (このコミットは止めません): bin/fge images で一覧\n")
		}
	}
	return problems
}

// hasDocsSyncTarget は make に配線検査のターゲットが在るか。
// 無い・make 自体が無いなら 1 行知らせてスキップ (fail-open)。
func (r *runner) hasDocsSyncTarget() bool {
	cmd := exec.Command("make", "-q", r.rules.DocsSync.Target)
	cmd.Dir = r.root
	_ = cmd.Run()
	if cmd.ProcessState == nil {
		// make 自体を起こせなかった。
		fmt.Fprintln(r.parent, r.rules.FailOpen.MakeMissing)
		return false
	}
	if cmd.ProcessState.ExitCode() == r.rules.FailOpen.TargetMissingExitCode {
		fmt.Fprintln(r.parent, r.rules.FailOpen.TargetMissing)
		return false
	}
	return true
}

// hasTarget はゲームの Makefile に口が在るか（無ければ黙って飛ばす。固有の口は無いのが普通）。
// make -q が 2 を返したとき、口が無いのか Makefile が壊れているのかを make の文で見分け、
// 壊れているときだけ 1 行知らせて飛ばす。
// WhyNot: LC_ALL=C で流すのは、make の文が訳されていると見分けの文字列が当たらないため。
func (r *runner) hasTarget(target string) bool {
	cmd := exec.Command("make", "-q", target)
	cmd.Dir = r.root
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	var stderr strings.Builder
	cmd.Stderr = &stderr
	_ = cmd.Run()
	if cmd.ProcessState == nil {
		return false
	}
	if cmd.ProcessState.ExitCode() != r.rules.FailOpen.TargetMissingExitCode {
		return true
	}
	msg := stderr.String()
	if !strings.Contains(msg, "No rule to make target") || strings.Contains(msg, "needed by") {
		line, _, _ := strings.Cut(strings.TrimSpace(msg), "\n")
		fmt.Fprintf(r.parent, "[pre-commit] make -q %s が失敗したので %s は飛ばします: %s\n", target, target, line)
	}
	return false
}

// runLocalGate はステージしたファイルを 1 行 1 つで一時ファイルに書き、そのパスを
// STAGED_FILE で make の口へ渡して流す。
// WhyNot: ファイル名を make の変数へ直に並べないのは、make が $(...) を展開し、
// 名前の中の " がレシピの引用を壊すため。一時ファイルなら名前は make を通らない。
func (r *runner) runLocalGate(target string, staged []string) (int, error) {
	f, err := os.CreateTemp("", "fge-staged-*.txt")
	if err != nil {
		return 0, err
	}
	defer os.Remove(f.Name())
	_, werr := f.WriteString(strings.Join(staged, "\n") + "\n")
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr != nil {
		return 0, werr
	}
	return r.runMake("-s", target, "STAGED_FILE="+f.Name()), nil
}

// runMake は出力をそのまま見せて終了コードを返す。
func (r *runner) runMake(args ...string) int {
	cmd := exec.Command("make", args...)
	cmd.Dir = r.root
	cmd.Stdout = r.opts.Stdout
	cmd.Stderr = r.opts.Stderr
	_ = cmd.Run()
	if cmd.ProcessState == nil {
		return 1
	}
	return cmd.ProcessState.ExitCode()
}

// checkUseEngineToml は、use-engine が一時的に書き換えた flix.toml のエンジンの版を
// コミットしようとしていれば知らせを返す（無ければ空）。控え lib/.use-engine/ がある間だけ見る。
// WhyNot: 版だけを見るのは、use-engine の最中に flix.toml の別の行を直してコミットする
// のは止めないため（ステージした中身の版が元へ戻っていれば通す）。
func (r *runner) checkUseEngineToml(staged []string) string {
	set, orig, ok := status.UseEnginePin(r.root)
	if !ok || !containsPath(staged, "flix.toml") {
		return ""
	}
	out, err := exec.Command("git", "-C", r.root, "show", ":flix.toml").Output()
	if err != nil {
		return ""
	}
	if v, ok := status.EnginePinOf(string(out)); !ok || v != set {
		return ""
	}
	return fmt.Sprintf("[pre-commit] flix.toml のエンジンの版 v%s は use-engine が一時的に書いた物です（元は v%s）。\n"+
		"  bin/fge use-engine --restore で戻してからコミットする（版を上げるなら make engine-upgrade）", set, orig)
}

func containsPath(paths []string, want string) bool {
	for _, p := range paths {
		if p == want {
			return true
		}
	}
	return false
}
