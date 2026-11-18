package main

import (
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/checkd"
	"github.com/ababup1192/flix_game_engine/go/internal/heavy"
	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
	"github.com/ababup1192/flix_game_engine/go/internal/javacmd"
	"github.com/ababup1192/flix_game_engine/go/internal/mvncache"
	"github.com/ababup1192/flix_game_engine/go/internal/refactorhost"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
	"github.com/ababup1192/flixlint/go/refactor"
)

func init() {
	// 道具の本体は flixlint（flix-search・flix-refactor）。エンジンの決まり（engine の置き場・doc-refs・呼び方）を差し込む。
	refactor.SetHost(refactorhost.Hooks())
	// WhyNot: engineOnly にしないのは、直したい Flix のコードが配った先のゲームにあるため（engine の src にも効く）。
	register("refactor",
		"Flix の名前の位置の索引（flixlint --spans）で探す（usages: 使われ所・呼び手の階層・--unused）・数える（refs・match-sites・field-sites）・書き換える（expand-wildcard・remove-dead・field-to-accessor・remove-field・fix-construction・rewrite（式を型紙で書き替える）。既定は dry-run）。refactor --help",
		cmdRefactor)
}

func cmdRefactor(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	root, rest, ok := declValueFlag(rest, "--root")
	if !ok {
		root = refactorRoot()
	}
	if asJSON {
		rest = append(dropJSONFlag(rest), "--json")
	}
	if _, self := status.FindEngineDir(root, "mk/game.mk"); self {
		reportRootSrcSync(root)
	}
	useEngineFlixlint(root, rest)
	useEngineJava(engineDirOf(repoRoot()))
	opts := refactor.Options{Run: heavyRunner, Verify: heavyVerify, Log: os.Stderr, Shared: sharedServer(root)}
	q, ok := parseTreeQuery(rest)
	trees, notes := refactorTrees(root)
	gate := treeGate{path: filepath.Join(root, "build", "refactor", "trees-skip.json"), stamp: treeStamp, run: runTreeRefactor, mu: &sync.Mutex{}, ran: indexLogSince}
	stopStaleResidents(root, trees, gate)
	if !ok || (len(trees) == 0 && len(notes) == 0) {
		return refactor.Run(out, errOut, root, rest, opts)
	}
	runRoot := func(rest []string) (string, string, int) {
		var o, e strings.Builder
		code := refactor.Run(&o, &e, root, rest, opts)
		return o.String(), e.String(), code
	}
	r := treeRefactor{
		runRoot:  runRoot,
		gate:     gate,
		readRows: readTreeRows,
		lastUsage: func(since time.Time) (io.ReadCloser, error) {
			return openFresh(filepath.Join(root, "build", "refactor", "last-usages.txt"), since)
		},
		mentions: treeMentions,
	}
	return r.run(out, errOut, rest, asJSON, q, trees, notes)
}

// stopStaleResidents は索引を作る常駐（ルートと各ソースツリーの物）のうち、起きた後に lib の依存
// （make sync-engine-full で張り替えた engine の束）が置き換わった物を止める。次の索引が新しい依存で起こし直す。
// 止めたソースツリーは、索引を作れなかった覚えも消す（古い engine で落ちたのかもしれない）。
// WhyNot: 常駐で作らないソースツリー（bench）も見る。bin/flixlint は --resident が無くても、socket があれば常駐に頼む。
func stopStaleResidents(root string, trees []refactorTree, gate treeGate) {
	r, err := hooks.LoadRules(root)
	if err != nil {
		return
	}
	checkd.StopStaleResident(r, repoRoot(), root, os.Stderr)
	for _, t := range trees {
		if checkd.StopStaleResident(r, repoRoot(), t.Root, os.Stderr) {
			gate.update(t.Name, nil)
		}
	}
}

// reportRootSrcSync は engine のルートで索引を作る前に、ルートの src/（索引の元）を各パッケージの src に追いつかせる。
// WhyNot: make sync-root-src-missing を呼ばない。make の無い所（Windows の素の shell）でも refactor は流れる。
func reportRootSrcSync(root string) {
	added, removed, err := syncRootSrc(root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[refactor] ルートの src/ の symlink を張り直せない: %v（make sync-root-src で張り直す）\n", err)
		return
	}
	if added+removed > 0 {
		fmt.Fprintf(os.Stderr, "[refactor] ルートの src/ の symlink を %d 本足し %d 本消した（git に入れる）\n", added, removed)
	}
}

// useEngineFlixlint は、ゲームが flixlint を名指ししていない時（submodule・--flixlint・FGE_FLIXLINT・FLIXLINT_BIN・
// refactor.local.json の flixlint・PATH のどれも無い）に、make lint-flixlint と同じ hooks.json の版の flixlint を使わせる。
// WhyNot: テンプレートから作ったゲームは flixlint を submodule で持たないので、これが無いと索引を作れず止まる。
func useEngineFlixlint(root string, rest []string) {
	if _, _, given := declValueFlag(rest, "--flixlint"); given || os.Getenv("FGE_FLIXLINT") != "" || os.Getenv("FLIXLINT_BIN") != "" {
		return
	}
	if _, err := os.Stat(filepath.Join(root, "flixlint", "bin", "flixlint")); err == nil {
		return
	}
	if localNamesFlixlint(root) {
		return
	}
	if refactor.LookPath("flixlint") != "" {
		return
	}
	if dir, shim, err := prepareFlixlint(repoRoot()); err == nil {
		os.Setenv("FGE_FLIXLINT", filepath.Join(dir, "bin", "flixlint"))
		if os.Getenv("FLIXLINT_SHIM") == "" {
			os.Setenv("FLIXLINT_SHIM", shim)
		}
	}
}

// localNamesFlixlint は bin/lint-rules/refactor.local.json が flixlint の欄を書いているか。
// WhyNot: ファイルが在るだけで見ない。verify だけを書いた設定でも、既定の flixlint の探し方が止まっていた。
func localNamesFlixlint(root string) bool {
	b, err := os.ReadFile(filepath.Join(root, "bin", "lint-rules", "refactor.local.json"))
	if err != nil {
		return false
	}
	var c struct {
		Flixlint string `json:"flixlint"`
	}
	// WhyNot: 読めない JSON を「名指し無し」と取らない。flixlint の設定も同じファイルを読んで止まるので、別の flixlint を
	// 差し込むと止まった理由が見えなくなる。
	if json.Unmarshal(b, &c) != nil {
		return true
	}
	return strings.TrimSpace(c.Flixlint) != ""
}

// useEngineJava は、PATH の java が動かない時に engine の devbox の jdk を PATH の先頭へ足す（checkd の javaCmd と同じ順）。
// WhyNot: flixlint へ java のパスを渡す口は無く、flixlint は PATH の java で常駐を起こす。macOS の /usr/bin/java は
// jdk の無い入口なので、engine の外（ゲーム・templates/*）で流すと索引を作れずに止まっていた。
func useEngineJava(engine string) {
	if javacmd.PathWorks() {
		return
	}
	if path, ok := pathWithEngineJava(os.Getenv("PATH"), engine); ok {
		os.Setenv("PATH", path)
	}
}

// engineDirOf は root から engine の置き場（mk/game.mk のある所）を引く。生成したゲームでは local.mk・Makefile の ENGINE を辿る。
// WhyNot: repoRoot のままにしない — 生成したゲームでは bin/fge-go がゲームの bin に写されていて、repoRoot はゲームの根になる。
func engineDirOf(root string) string {
	if dir, _ := status.FindEngineDir(root, "mk/game.mk"); dir != "" {
		return dir
	}
	return root
}

// pathWithEngineJava は devbox の java がある時だけ（javacmd.DevboxBin）、その bin を先頭に足した PATH を返す。
func pathWithEngineJava(path, engine string) (string, bool) {
	bin := javacmd.DevboxBin(engine)
	if bin == "" {
		return path, false
	}
	if path == "" {
		return bin, true
	}
	return bin + string(os.PathListSeparator) + path, true
}

// sharedServer は make check（checkd の server の道）の常駐と同じ jar・ヒープ・寿命。ゲームの hooks.json に checkd.server が
// 無いか jar を用意できなければ空（flixlint の既定の jar で、索引だけの常駐になる）。
func sharedServer(root string) refactor.Shared {
	if msg := mvncache.Link(root); msg != "" {
		fmt.Fprintln(os.Stderr, msg)
	}
	r, err := hooks.LoadRules(root)
	if err != nil {
		return refactor.Shared{}
	}
	s, err := checkd.SharedServer(r, repoRoot(), root)
	if err != nil {
		return refactor.Shared{}
	}
	return refactor.Shared{FlixJar: s.FlixJar, ShimJar: s.ShimJar, HeapMB: s.HeapMB, IdleMinutes: s.IdleMinutes}
}

// refactorRoot は --root が無い時の根: FGE_ROOT → 今の所から上へ flix.toml のある所 → repoRoot（bin/fge-go の親の親）。
// WhyNot: repoRoot だけにしないのは、engine の bin/fge-go を名指しして流すと engine の根になり、ゲームの中で
// 打っても --root が要ったため。
func refactorRoot() string {
	if v := os.Getenv("FGE_ROOT"); v != "" {
		return v
	}
	if dir, err := os.Getwd(); err == nil {
		for d := dir; ; d = filepath.Dir(d) {
			if info, err := os.Stat(filepath.Join(d, "flix.toml")); err == nil && !info.IsDir() {
				return d
			}
			if filepath.Dir(d) == d {
				break
			}
		}
	}
	return repoRoot()
}

// heavyRunner は索引を作る flixlint を heavy の枠の中で流す。resolved（2 GB・数秒）は短い物、typed（4〜5 GB・20〜60 秒）は長い物。
// log が空でなければ出力をそのファイルへ書く（--verbose でない時。画面には refactor の 1 行だけ）。
// WhyNot: typed を短い物にしないのは、短い物の枠は make test と同時に走り、5 GB の JVM が 2 本並ぶとマシンが詰まるため。
// 常駐で作る索引（--resident）は heavy の枠を取らない: 仕事は常駐の JVM 1 本が並べて流し、ここで立つのは話すだけの JVM。
// WhyNot: 枠を取ると、make test などの長い物が枠を持っている間、索引が常駐は空いているのに待つ。
func heavyRunner(stage refactor.Stage, desc, dir string, cmd []string, log string) int {
	if containsArg(cmd, "--resident") {
		return runDirect(dir, cmd, log, nil)
	}
	return heavy.Hold(desc, dir, heavy.Options{Long: stage == refactor.Typed, Short: stage != refactor.Typed}, func(run heavy.Runner) int {
		if log == "" {
			return run(dir, cmd...)
		}
		quoted := make([]string, len(cmd))
		for i, c := range cmd {
			quoted[i] = "'" + strings.ReplaceAll(c, "'", `'\''`) + "'"
		}
		return run(dir, "sh", "-c", strings.Join(quoted, " ")+" > '"+strings.ReplaceAll(log, "'", `'\''`)+"' 2>&1")
	})
}

// heavyVerify は書き換えの後の確かめ（make check・make test など）を heavy の枠で流し、出力を全部 log へ書く
// （最初の誤りを拾うため。枠の長短は heavy が名前で決める）。
func heavyVerify(cmd, dir, log string) int {
	fmt.Fprintf(os.Stderr, "[refactor] 確かめ: %s（出力は %s）\n", cmd, log)
	if strings.TrimSpace(cmd) == "make check" {
		// make check は checkd の server の道で、索引と同じ常駐に頼む（heavy の枠を取らず、heavy が入れる CHECKD=0 も避ける）。
		return runDirect(dir, []string{"sh", "-c", cmd}, log, []string{"CHECKD=1", "CHECKD_BACKEND=server"})
	}
	return heavy.Hold(cmd, dir, heavy.Options{}, func(run heavy.Runner) int {
		return run(dir, "sh", "-c", cmd+" > \""+log+"\" 2>&1")
	})
}

func containsArg(cmd []string, a string) bool {
	for _, c := range cmd {
		if c == a {
			return true
		}
	}
	return false
}

// runDirect は cmd を dir で流す（heavy の枠の外）。log が空でなければ出力をそのファイルへ、env は足す環境変数。
func runDirect(dir string, cmd []string, log string, env []string) int {
	c := exec.Command(cmd[0], cmd[1:]...)
	c.Dir = dir
	c.Env = append(os.Environ(), env...)
	if log == "" {
		c.Stdout, c.Stderr = os.Stdout, os.Stderr
	} else {
		f, err := os.Create(log)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[refactor] %s を書けない: %v\n", log, err)
			return 2
		}
		defer f.Close()
		c.Stdout, c.Stderr = f, f
	}
	if err := c.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode()
		}
		fmt.Fprintf(os.Stderr, "[refactor] %s を起動できない: %v\n", cmd[0], err)
		return 2
	}
	return 0
}

// syncRootSrc は root/src/<名前>/ のうち、パッケージ（root/<名前>/flix.toml と root/<名前>/src）の写しである物を、
// その src の .flix に合わせる: 足りない symlink を相対で張り、先の無い symlink を消す（make sync-root-src-missing と同じ）。
// WhyNot: 写しを丸ごと消して張り直さない。並べて走る make check・別の索引が読んでいる最中のソースが消える。
// WhyNot: 写すパッケージの一覧を Makefile の ROOT_SRC_PKGS から持ってこない。src/ に在る写しから引けば、一覧を 2 か所に持たずに済む。
func syncRootSrc(root string) (added, removed int, err error) {
	entries, err := os.ReadDir(filepath.Join(root, "src"))
	if err != nil {
		return 0, 0, nil
	}
	for _, e := range entries {
		if !e.IsDir() || !isPackageDir(filepath.Join(root, e.Name())) {
			continue
		}
		a, r, err := mirrorFlixTree(filepath.Join(root, e.Name(), "src"), filepath.Join(root, "src", e.Name()))
		added += a
		removed += r
		if err != nil {
			return added, removed, err
		}
	}
	return added, removed, nil
}

func isPackageDir(dir string) bool {
	if info, err := os.Stat(filepath.Join(dir, "flix.toml")); err != nil || info.IsDir() {
		return false
	}
	info, err := os.Stat(filepath.Join(dir, "src"))
	return err == nil && info.IsDir()
}

// mirrorFlixTree は from の下の .flix を to の下へ同じ形の相対 symlink で並べ、to の下の先の無い symlink を消す。
func mirrorFlixTree(from, to string) (added, removed int, err error) {
	err = filepath.WalkDir(from, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(d.Name(), ".flix") {
			return err
		}
		rel, _ := filepath.Rel(from, path)
		link := filepath.Join(to, rel)
		if _, err := os.Lstat(link); err == nil {
			return nil
		}
		if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
			return err
		}
		target, err := filepath.Rel(filepath.Dir(link), path)
		if err != nil {
			return err
		}
		if err := os.Symlink(target, link); err != nil && !os.IsExist(err) {
			return err
		}
		added++
		return nil
	})
	if err != nil {
		return added, removed, err
	}
	err = filepath.WalkDir(to, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.Type()&fs.ModeSymlink == 0 {
			return err
		}
		if _, err := os.Stat(path); err == nil {
			return nil
		}
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
		removed++
		return nil
	})
	return added, removed, err
}
