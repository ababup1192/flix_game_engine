// Package useengine は、ゲームの作業場 1 つを別の版のエンジンへ一時的にそろえる。
//
//	fge use-engine <版 | パス>   local.mk の ENGINE と lib/ のエンジンの fpkg をそのエンジンへ
//	fge use-engine --status      今どのエンジンを向いているか（lib がずれていないか）
//	fge use-engine --restore     最初に use-engine する前へ戻す
//
// 版を渡すと ~/.flix_ge_studio/engines/<版> を使い、無ければエンジンのタグを
// ~/.flix_ge_studio/worktrees/v<版> に出して組む（組むのは heavy の鍵の内側）。
// 戻すための控えは lib/.use-engine/ に置く（lib/ は git に入らない）。
package useengine

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/heavy"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

// エンジンの fpkg が lib/ の中で置かれる所（flix.toml の依存の名前から決まる）。
const libEngineDir = "lib/github/ababup1192/flix_game_engine"

const stateDir = "lib/.use-engine"

var versionRe = regexp.MustCompile(`^\d+\.\d+\.\d+$`)

// depRe はゲームの flix.toml が指すエンジンの版。
var depRe = regexp.MustCompile(
	`("github:ababup1192/flix_game_engine"\s*=\s*\{[^}]*version\s*=\s*)"([^"]+)"`)

var engineLineRe = regexp.MustCompile(`(?m)^ENGINE\s*[:?]?=.*$`)

// State は戻すための控え。最初の use-engine で書き、--restore で消す。
type State struct {
	Since time.Time `json:"since"`
	// 最初の use-engine の前の姿。
	HadLocalMk  bool   `json:"hadLocalMk"`
	OrigLocalMk string `json:"origLocalMk,omitempty"`
	HadLib      bool   `json:"hadLib"`
	HadLibEng   bool   `json:"hadLibEngine"`
	OrigToml    string `json:"origTomlVersion"`
	// 今そろえている先。
	Engine        string `json:"engine"`
	EngineVersion string `json:"engineVersion"`
	SetToml       string `json:"setTomlVersion,omitempty"`
	FpkgSize      int64  `json:"fpkgSize"`
	FpkgModTime   string `json:"fpkgModTime"`
	// packages.lock のエンジンの行を書き換えた時の、最初の姿と書き換えた後の姿（--restore で戻す）。
	OrigLock string `json:"origLock,omitempty"`
	SetLock  string `json:"setLock,omitempty"`
}

// Options は差し替えられる所。
type Options struct {
	Game      string // ゲームの作業場（既定は今の場所）
	Home      string // 既定は ~/.flix_ge_studio
	Repo      string // タグを出すエンジンの clone（既定は FGE_ENGINE_REPO か今の ENGINE）
	Make      string
	Out, Err  io.Writer
	HeavyOpts heavy.Options
}

func (o *Options) fill() error {
	if o.Game == "" {
		wd, err := os.Getwd()
		if err != nil {
			return err
		}
		o.Game = wd
	}
	if o.Home == "" {
		if v := os.Getenv("FGE_STUDIO_HOME"); v != "" {
			o.Home = v
		} else {
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			o.Home = filepath.Join(home, ".flix_ge_studio")
		}
	}
	if o.Repo == "" {
		o.Repo = os.Getenv("FGE_ENGINE_REPO")
	}
	if o.Make == "" {
		o.Make = "make"
	}
	if o.Out == nil {
		o.Out = os.Stdout
	}
	if o.Err == nil {
		o.Err = os.Stderr
	}
	return nil
}

// Run は fge use-engine の入口。
func Run(args []string, asJSON bool, o Options) int {
	var target string
	mode := "use"
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--status":
			mode = "status"
		case a == "--restore":
			mode = "restore"
		case a == "--json":
		case a == "--repo" && i+1 < len(args):
			o.Repo = args[i+1]
			i++
		case a == "--game" && i+1 < len(args):
			o.Game = args[i+1]
			i++
		case strings.HasPrefix(a, "--"):
			fmt.Fprintf(os.Stderr, "use-engine: 知らない旗 %s\n", a)
			return 2
		default:
			target = a
		}
	}
	if err := o.fill(); err != nil {
		fmt.Fprintf(o.Err, "use-engine: %v\n", err)
		return 2
	}
	if !isFile(filepath.Join(o.Game, "flix.toml")) {
		fmt.Fprintf(o.Err, "use-engine: %s にゲームの flix.toml がありません（ゲームの作業場で流す）\n", o.Game)
		return 2
	}
	var err error
	switch mode {
	case "status":
		return printStatus(o, asJSON)
	case "restore":
		err = Restore(o)
	default:
		if target == "" {
			fmt.Fprintln(o.Err, "使い方: fge use-engine <版 | パス>   この作業場の local.mk と lib をそのエンジンへそろえる")
			fmt.Fprintln(o.Err, "        fge use-engine --status    今どのエンジンを向いているか")
			fmt.Fprintln(o.Err, "        fge use-engine --restore   最初に use-engine する前へ戻す")
			return 2
		}
		var dir string
		dir, err = Resolve(target, o)
		if err == nil {
			err = Use(dir, o)
		}
	}
	if err != nil {
		fmt.Fprintf(o.Err, "use-engine: %v\n", err)
		return 1
	}
	return 0
}

// ── エンジンを探す ───────────────────────────────────────

// Resolve は版かパスを、そろえる先のエンジンの場所にする。版の物が無ければ組む。
func Resolve(target string, o Options) (string, error) {
	if err := o.fill(); err != nil {
		return "", err
	}
	if !versionRe.MatchString(strings.TrimPrefix(target, "v")) || isDir(target) {
		dir, err := filepath.Abs(target)
		if err != nil {
			return "", err
		}
		if !isFile(filepath.Join(dir, "mk", "game.mk")) {
			return "", fmt.Errorf("%s はエンジンではありません（mk/game.mk が無い）", dir)
		}
		return dir, nil
	}
	version := strings.TrimPrefix(target, "v")
	installed := filepath.Join(o.Home, "engines", version)
	if isEngineReady(installed) {
		return installed, nil
	}
	wt := filepath.Join(o.Home, "worktrees", "v"+version)
	if isEngineReady(wt) {
		return wt, nil
	}
	repo, err := engineRepo(o)
	if err != nil {
		return "", fmt.Errorf("%s が無く、タグ v%s を出すエンジンの clone も分かりません。\n"+
			"  どれかをしてからもう一度: --repo <engine の clone> を渡す / FGE_ENGINE_REPO=<engine の clone> /\n"+
			"  Studio の engines を更新する（Studio の更新か、fge fetch-engine --version %s --into %s --carry-from <今の engine>）",
			installed, version, version, filepath.Join(o.Home, "engines"))
	}
	return wt, buildTag(version, wt, repo, o)
}

// isEngineReady はそのまま ENGINE に向けられるか（make の口と組んだ fpkg が揃っているか）。
func isEngineReady(dir string) bool {
	_, err := findFpkg(dir)
	return err == nil && isFile(filepath.Join(dir, "mk", "game.mk"))
}

// FindFpkg はエンジン dir の組んだ fpkg（use-engine がゲームの lib/ へ写す物）。
func FindFpkg(engine string) (string, error) { return findFpkg(engine) }

func findFpkg(engine string) (string, error) {
	for _, name := range []string{"package.fpkg", "engine_full.fpkg"} {
		p := filepath.Join(engine, "engine_full", "artifact", name)
		if isFile(p) {
			return p, nil
		}
	}
	return "", fmt.Errorf("%s に組んだエンジンの fpkg がありません（見た所: engine_full/artifact/package.fpkg・engine_full.fpkg）。次のどれか:\n"+
		"  組む: bin/fge heavy -- make -C %s sync（数分。git worktree で出したばかりなら、先に元の clone の各パッケージの lib/cache・lib/external"+
		"（engine_full・render_gl など）を写す。無いと依存の取り直しで Maven の 429 に当たる）\n"+
		"  タグから組ませる: bin/fge use-engine <版> --repo <engine の clone>（~/.flix_ge_studio/engines/<版> があればそれを使い、無ければタグを worktree に出して組む）\n"+
		"  配った版（Release の zip・Studio の engines）は engine_full.fpkg が入っているので、そのフォルダを渡す",
		engine, engine)
}

// buildTag はエンジンのタグを worktree に出して組む。
//
// WhyNot: 組むのを heavy の鍵の内側に置くのは、make sync が JVM を何本も立てる重さだから。
// 鍵の内側でもう一度揃っているかを見るので、同じ版を 2 本が同時に頼んでも組むのは 1 回。
func buildTag(version, wt, repo string, o Options) error {
	fmt.Fprintf(o.Err, "[use-engine] %s が無いので v%s を %s に出して組みます\n",
		filepath.Join(o.Home, "engines", version), version, wt)
	var failure error
	code := heavy.Hold("use-engine: v"+version+" を組む", repo, o.HeavyOpts, func(run heavy.Runner) int {
		if isEngineReady(wt) {
			return 0
		}
		if !isDir(wt) {
			if err := os.MkdirAll(filepath.Dir(wt), 0o755); err != nil {
				failure = err
				return 1
			}
			if run(repo, "git", "rev-parse", "-q", "--verify", "refs/tags/v"+version) != 0 {
				run(repo, "git", "fetch", "-q", "--tags", "origin")
			}
			if c := run(repo, "git", "worktree", "add", "--detach", wt, "v"+version); c != 0 {
				failure = fmt.Errorf("タグ v%s を %s に出せません", version, wt)
				return c
			}
		}
		for _, target := range []string{"go-build", "sync"} {
			if c := run(wt, o.Make, target); c != 0 {
				failure = fmt.Errorf("%s で make %s が失敗しました（worktree は残してあります）", wt, target)
				return c
			}
		}
		return 0
	})
	if failure != nil {
		return failure
	}
	if code != 0 {
		return fmt.Errorf("v%s を組めませんでした (終了コード %d)", version, code)
	}
	if !isEngineReady(wt) {
		return fmt.Errorf("make sync の後も %s に組んだ fpkg がありません", wt)
	}
	return nil
}

// engineRepo はタグを出す元の clone。--repo か FGE_ENGINE_REPO、無ければ今の ENGINE の git。
func engineRepo(o Options) (string, error) {
	candidates := []string{o.Repo}
	if st, err := readState(o.Game); err == nil && st.HadLocalMk {
		candidates = append(candidates, engineOfLocalMk(st.OrigLocalMk))
	}
	candidates = append(candidates, status.ReadEngineDir(o.Game))
	for _, c := range candidates {
		if c == "" {
			continue
		}
		out, err := exec.Command("git", "-C", c, "rev-parse", "--path-format=absolute", "--git-common-dir").Output()
		if err != nil {
			continue
		}
		common := strings.TrimSpace(string(out))
		// 本体の clone（.git の親）に worktree を足す。
		if filepath.Base(common) == ".git" {
			return filepath.Dir(common), nil
		}
		return c, nil
	}
	return "", errors.New("タグを出すエンジンの clone が分かりません — --repo <engine の clone> か FGE_ENGINE_REPO を渡す")
}

// ── そろえる ─────────────────────────────────────────────

// Use はゲームの local.mk と lib/ をエンジン dir へそろえる。
func Use(dir string, o Options) error {
	if err := o.fill(); err != nil {
		return err
	}
	fpkg, err := findFpkg(dir)
	if err != nil {
		return err
	}
	version := status.ReadEngineVersion(dir)
	if version == "" {
		return fmt.Errorf("%s の Makefile に VERSION がありません", dir)
	}
	tomlPath := filepath.Join(o.Game, "flix.toml")
	tomlText, err := os.ReadFile(tomlPath)
	if err != nil {
		return err
	}
	m := depRe.FindSubmatch(tomlText)
	if m == nil {
		return fmt.Errorf("%s にエンジンの依存 (github:ababup1192/flix_game_engine) がありません", tomlPath)
	}
	tomlVersion := string(m[2])
	if err := refuseSharedLib(o.Game); err != nil {
		return err
	}

	st, err := readState(o.Game)
	if err != nil {
		st = State{Since: time.Now(), OrigToml: tomlVersion}
		if data, err := os.ReadFile(filepath.Join(o.Game, "local.mk")); err == nil {
			st.HadLocalMk, st.OrigLocalMk = true, string(data)
		}
		st.HadLib = isDir(filepath.Join(o.Game, "lib"))
		st.HadLibEng = isDir(filepath.Join(o.Game, libEngineDir))
		if err := saveOriginal(o.Game, st); err != nil {
			return err
		}
	}

	// flix.toml の版と fpkg を置くフォルダの名前をそろえる。
	if version != tomlVersion {
		updated := depRe.ReplaceAll(tomlText, []byte(`${1}"`+version+`"`))
		if err := os.WriteFile(tomlPath, updated, 0o644); err != nil {
			return err
		}
		st.SetToml = version
		fmt.Fprintf(o.Err, "[use-engine] flix.toml のエンジンの版を %s → %s にしました（--restore で戻る。commit しない）\n",
			tomlVersion, version)
	} else if st.SetToml != "" && version == st.OrigToml {
		st.SetToml = ""
	}

	if err := fillLibExternal(o.Game, dir); err != nil {
		return err
	}
	engLib := filepath.Join(o.Game, libEngineDir)
	if err := os.RemoveAll(engLib); err != nil {
		return err
	}
	dest := filepath.Join(engLib, version)
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return err
	}
	// WhyNot: symlink にせずコピーするのは、向けた先（他人の worktree）が消えたり
	// 組み直されたりしたとき、この作業場の lib まで黙って壊れるため。
	if err := copyFile(fpkg, filepath.Join(dest, "flix_game_engine-"+version+".fpkg")); err != nil {
		return err
	}
	if err := copyFile(filepath.Join(dir, "engine_full", "flix.toml"),
		filepath.Join(dest, "flix_game_engine-"+version+".toml")); err != nil {
		return err
	}
	if err := syncLock(o, &st, version, fpkg, filepath.Join(dir, "engine_full", "flix.toml")); err != nil {
		return err
	}
	if err := writeLocalMk(o.Game, dir, st); err != nil {
		return err
	}
	info, _ := os.Stat(fpkg)
	st.Engine, st.EngineVersion = dir, version
	st.FpkgSize, st.FpkgModTime = info.Size(), info.ModTime().UTC().Format(time.RFC3339)
	if err := writeState(o.Game, st); err != nil {
		return err
	}
	fmt.Fprintf(o.Out, "[use-engine] %s → エンジン %s (v%s)\n", filepath.Base(o.Game), shortPath(dir), version)
	return nil
}

// syncLock は packages.lock に今の版のエンジンの行があれば、指紋を写した fpkg と toml にそろえる。
//
// WhyNot: lock をそのままにしない — 同じ版の字のまま手元で組んだエンジン（ブランチの作業場）へ向けると、
// lock が配布版の指紋を持ったままなので、flix が「packages.lock の記録と違う」で組めない
// （compare の BASE_ENGINE=<パス> の基準側も同じ所で止まる）。
func syncLock(o Options, st *State, version, fpkg, toml string) error {
	lockPath := filepath.Join(o.Game, "packages.lock")
	data, err := os.ReadFile(lockPath)
	if err != nil {
		return nil
	}
	fpkgSum, err := sha256File(fpkg)
	if err != nil {
		return err
	}
	tomlSum, err := sha256File(toml)
	if err != nil {
		return err
	}
	updated, found := withEngineLock(string(data), version, tomlSum, fpkgSum)
	if !found || updated == string(data) {
		return nil
	}
	if st.SetLock == "" {
		st.OrigLock = string(data)
	}
	st.SetLock = updated
	if err := os.WriteFile(lockPath, []byte(updated), 0o644); err != nil {
		return err
	}
	fmt.Fprintf(o.Err, "[use-engine] packages.lock のエンジン v%s の指紋を向けた先の fpkg にそろえました（--restore で戻る。commit しない）\n", version)
	return nil
}

var lockKeyRe = regexp.MustCompile(`^(\s*(toml|fpkg)\s*=\s*)"sha256:[0-9a-f]*"`)

// withEngineLock は lock の [packages."github:ababup1192/flix_game_engine"."<版>"] の toml・fpkg の行を差し替える。
// 節が無ければ found=false。
func withEngineLock(lock, version, tomlSum, fpkgSum string) (string, bool) {
	header := `[packages."github:ababup1192/flix_game_engine"."` + version + `"]`
	lines := strings.Split(lock, "\n")
	in, found := false, false
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[") {
			in = trimmed == header
			found = found || in
			continue
		}
		if !in {
			continue
		}
		if m := lockKeyRe.FindStringSubmatch(line); m != nil {
			sum := fpkgSum
			if m[2] == "toml" {
				sum = tomlSum
			}
			lines[i] = lockKeyRe.ReplaceAllString(line, `${1}"sha256:`+sum+`"`)
		}
	}
	return strings.Join(lines, "\n"), found
}

func sha256File(p string) (string, error) {
	data, err := os.ReadFile(p)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}

// refuseSharedLib は lib（かその中のエンジンのフォルダ）が symlink なら断る。
//
// WhyNot: 辿って書かないのは、symlink の先が別の作業場の lib で、そこの fpkg を消し、
// 控えまで共有して、こちらの --restore が他人の local.mk の控えを読むことになるため。
func refuseSharedLib(game string) error {
	for _, p := range []string{"lib", "lib/github", "lib/github/ababup1192", libEngineDir} {
		if info, err := os.Lstat(filepath.Join(game, p)); err == nil && info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("%s が symlink です（別の作業場と共有）。use-engine は自分の lib に写すので、先に symlink を外す（rm %s）", p, p)
		}
	}
	return nil
}

// fillLibExternal は lib/external と lib/cache が無いとき、エンジンの手元の物を写す。
//
// WhyNot: 既にある物を上書きしないのは、Maven から取ってきた jar は版をまたいで同じで、
// 写し直すと数百 MB を毎回書くだけだから。
func fillLibExternal(game, engine string) error {
	for _, sub := range []string{"external", "cache"} {
		dst := filepath.Join(game, "lib", sub)
		if isDir(dst) {
			continue
		}
		for _, src := range []string{filepath.Join(engine, "engine_full", "lib", sub), filepath.Join(engine, "lib", sub)} {
			if isDir(src) {
				if err := copyTree(src, dst); err != nil {
					return err
				}
				break
			}
		}
	}
	return nil
}

func writeLocalMk(game, engine string, st State) error {
	line := "ENGINE := " + engine
	body := line + "\n"
	if st.HadLocalMk {
		if engineLineRe.MatchString(st.OrigLocalMk) {
			body = engineLineRe.ReplaceAllLiteralString(st.OrigLocalMk, line)
		} else {
			body = line + "\n" + st.OrigLocalMk
		}
	}
	return os.WriteFile(filepath.Join(game, "local.mk"), []byte(body), 0o644)
}

// ── 戻す ─────────────────────────────────────────────────

// Restore は最初に use-engine する前の local.mk・flix.toml・lib へ戻す。
func Restore(o Options) error {
	if err := o.fill(); err != nil {
		return err
	}
	if err := refuseSharedLib(o.Game); err != nil {
		return err
	}
	st, err := readState(o.Game)
	if err != nil {
		return errors.New("use-engine の控えがありません（まだ何も向けていない）")
	}
	if st.SetToml != "" {
		tomlPath := filepath.Join(o.Game, "flix.toml")
		text, err := os.ReadFile(tomlPath)
		if err != nil {
			return err
		}
		if m := depRe.FindSubmatch(text); m != nil && string(m[2]) == st.SetToml {
			if err := os.WriteFile(tomlPath, depRe.ReplaceAll(text, []byte(`${1}"`+st.OrigToml+`"`)), 0o644); err != nil {
				return err
			}
		} else {
			fmt.Fprintf(o.Err, "[use-engine] flix.toml の版が %s から変わっているので触りません\n", st.SetToml)
		}
	}
	if st.SetLock != "" {
		lockPath := filepath.Join(o.Game, "packages.lock")
		if data, err := os.ReadFile(lockPath); err == nil && string(data) == st.SetLock {
			if err := os.WriteFile(lockPath, []byte(st.OrigLock), 0o644); err != nil {
				return err
			}
		} else {
			fmt.Fprintln(o.Err, "[use-engine] packages.lock が use-engine の後に変わっているので触りません")
		}
	}
	localMk := filepath.Join(o.Game, "local.mk")
	if st.HadLocalMk {
		if err := os.WriteFile(localMk, []byte(st.OrigLocalMk), 0o644); err != nil {
			return err
		}
	} else {
		os.Remove(localMk)
	}
	if !st.HadLib {
		fmt.Fprintf(o.Out, "[use-engine] 元に戻しました（lib/ は無かったので消しました）\n")
		return os.RemoveAll(filepath.Join(o.Game, "lib"))
	}
	engLib := filepath.Join(o.Game, libEngineDir)
	if err := os.RemoveAll(engLib); err != nil {
		return err
	}
	if st.HadLibEng {
		if err := os.Rename(filepath.Join(o.Game, stateDir, "lib-engine"), engLib); err != nil {
			return err
		}
	}
	if err := os.RemoveAll(filepath.Join(o.Game, stateDir)); err != nil {
		return err
	}
	fmt.Fprintf(o.Out, "[use-engine] 元に戻しました (%s)\n", describeOrig(st))
	return nil
}

func describeOrig(st State) string {
	if !st.HadLocalMk {
		return "local.mk 無し"
	}
	if e := engineOfLocalMk(st.OrigLocalMk); e != "" {
		return "ENGINE := " + shortPath(e)
	}
	return "local.mk に ENGINE 無し"
}

// ── 見せる ───────────────────────────────────────────────

// Report は --status の中身。
type Report struct {
	Game        string   `json:"game"`
	Engine      string   `json:"engine"`
	Version     string   `json:"engineVersion"`
	TomlVersion string   `json:"tomlVersion"`
	LibVersions []string `json:"libVersions"`
	UsedByTool  bool     `json:"usedByTool"`
	LibStale    bool     `json:"libStale"`
	Original    string   `json:"original,omitempty"`
}

func buildReport(o Options) Report {
	r := Report{Game: o.Game, LibVersions: []string{}}
	if data, err := os.ReadFile(filepath.Join(o.Game, "local.mk")); err == nil {
		r.Engine = engineOfLocalMk(string(data))
	}
	if r.Engine != "" {
		r.Version = status.ReadEngineVersion(r.Engine)
	}
	if text, err := os.ReadFile(filepath.Join(o.Game, "flix.toml")); err == nil {
		if m := depRe.FindSubmatch(text); m != nil {
			r.TomlVersion = string(m[2])
		}
	}
	entries, _ := os.ReadDir(filepath.Join(o.Game, libEngineDir))
	for _, e := range entries {
		r.LibVersions = append(r.LibVersions, e.Name())
	}
	if st, err := readState(o.Game); err == nil {
		r.UsedByTool = true
		r.Original = describeOrig(st)
		if fpkg, err := findFpkg(st.Engine); err == nil {
			if info, err := os.Stat(fpkg); err == nil {
				r.LibStale = info.Size() != st.FpkgSize ||
					info.ModTime().UTC().Format(time.RFC3339) != st.FpkgModTime
			}
		}
	}
	return r
}

func printStatus(o Options, asJSON bool) int {
	r := buildReport(o)
	if asJSON {
		data, _ := json.Marshal(r)
		fmt.Fprintln(o.Out, string(data))
		return 0
	}
	engine := "local.mk に ENGINE がありません"
	if r.Engine != "" {
		engine = shortPath(r.Engine)
		if r.Version != "" {
			engine += " (v" + r.Version + ")"
		}
	}
	fmt.Fprintf(o.Out, "[use-engine] ENGINE: %s\n", engine)
	fmt.Fprintf(o.Out, "[use-engine] flix.toml: v%s / lib: %s\n", r.TomlVersion, strings.Join(r.LibVersions, ", "))
	if r.UsedByTool {
		fmt.Fprintf(o.Out, "[use-engine] use-engine で向けています。--restore で戻す先: %s\n", r.Original)
	}
	if r.LibStale {
		fmt.Fprintln(o.Out, "[use-engine] !! エンジンの fpkg が組み直されています。lib を合わせるならもう一度 use-engine")
	}
	if r.Version != "" && r.TomlVersion != "" && r.Version != r.TomlVersion {
		fmt.Fprintf(o.Out, "[use-engine] !! ENGINE (v%s) と flix.toml (v%s) の版が違います\n", r.Version, r.TomlVersion)
	}
	return 0
}

// ── 控え ─────────────────────────────────────────────────

func saveOriginal(game string, st State) error {
	sd := filepath.Join(game, stateDir)
	if err := os.MkdirAll(sd, 0o755); err != nil {
		return err
	}
	if st.HadLibEng {
		if err := os.Rename(filepath.Join(game, libEngineDir), filepath.Join(sd, "lib-engine")); err != nil {
			return err
		}
	}
	return writeState(game, st)
}

func readState(game string) (State, error) {
	var st State
	data, err := os.ReadFile(filepath.Join(game, stateDir, "state.json"))
	if err != nil {
		return st, err
	}
	return st, json.Unmarshal(data, &st)
}

func writeState(game string, st State) error {
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(game, stateDir, "state.json"), data, 0o644)
}

func engineOfLocalMk(text string) string {
	line := engineLineRe.FindString(text)
	if line == "" {
		return ""
	}
	if i := strings.Index(line, "="); i >= 0 {
		return strings.TrimSpace(line[i+1:])
	}
	return ""
}

// ── ファイル ─────────────────────────────────────────────

func isFile(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.Mode().IsRegular()
}

func isDir(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".tmp"
	out, err := os.Create(tmp)
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
	return os.Rename(tmp, dst)
}

func copyTree(src, dst string) error {
	return filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		switch {
		case info.IsDir():
			return os.MkdirAll(target, 0o755)
		case info.Mode()&os.ModeSymlink != 0:
			link, err := os.Readlink(p)
			if err != nil {
				return err
			}
			return os.Symlink(link, target)
		default:
			return copyFile(p, target)
		}
	})
}

func shortPath(p string) string {
	if home, err := os.UserHomeDir(); err == nil && strings.HasPrefix(p, home+"/") {
		return "~" + p[len(home):]
	}
	return p
}

// TomlEngineVersion はゲームの flix.toml が指すエンジンの版。無ければ空。
func TomlEngineVersion(toml []byte) string {
	if m := depRe.FindSubmatch(toml); m != nil {
		return string(m[2])
	}
	return ""
}

// EngineOfLocalMk は local.mk の本文から ENGINE の値を取り出す。無ければ空。
func EngineOfLocalMk(text string) string { return engineOfLocalMk(text) }
