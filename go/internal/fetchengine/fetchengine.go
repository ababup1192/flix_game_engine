// Package fetchengine は、公開されている engine の zip を落として置き場へ組み立てる。
//
// Studio の self-update がこれを呼ぶ。Studio 側でなく engine の道具として持つのは、
// 落とす・照合する・展開するの 3 つが Go の標準ライブラリで揃い、負の見本と
// テストの土台をそのまま使えるため。
package fetchengine

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"debug/elf"
	"debug/macho"
	"debug/pe"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/stageengine"
)

// 終了コード。
const (
	exitDone     = 0
	exitProblem  = 1
	exitBadUsage = 2
)

const defaultRepo = "ababup1192/flix_game_engine"

// SumsName は照合の相手。engine の make bundle-zip が zip と対で作る。
const SumsName = "SHA256SUMS.txt"

// ZipName は公開されている zip の名前。
func ZipName(version string) string {
	return "flix_game_engine-engine-v" + version + ".zip"
}

type asset struct {
	Name string `json:"name"`
	URL  string `json:"browser_download_url"`
}

type release struct {
	TagName string  `json:"tag_name"`
	Assets  []asset `json:"assets"`
}

// Found は 1 つのリリースから取り出した、差し替えに要る材料。
type Found struct {
	Version string `json:"version"`
	ZipURL  string `json:"zipUrl"`
	SumsURL string `json:"sumsUrl"`
}

type checkResult struct {
	Available bool   `json:"available"`
	Version   string `json:"version,omitempty"`
	Current   string `json:"current,omitempty"`
	ZipURL    string `json:"zipUrl,omitempty"`
	SumsURL   string `json:"sumsUrl,omitempty"`
}

type installResult struct {
	Installed bool     `json:"installed"`
	Version   string   `json:"version"`
	Dir       string   `json:"dir"`
	CarriedTo []string `json:"carriedTo,omitempty"`
}

type opts struct {
	repo      string
	apiBase   string
	check     bool
	current   string
	version   string
	into      string
	carryFrom string
	asJSON    bool

	progress io.Writer

	// 通信とファイルの外側は差し替えられる形にしておく（テストが網に出ない）。
	get    func(url string) ([]byte, error)
	runExe func(path string, args ...string) error
}

// Run は fge fetch-engine の本体。
func Run(out, errOut *strings.Builder, args []string, asJSON bool) (int, error) {
	o, code, err := parse(args, asJSON, out, errOut)
	if err != nil || code != exitDone {
		return code, err
	}
	if o.check {
		return runCheck(out, errOut, o)
	}
	return runInstall(out, errOut, o)
}

func parse(args []string, asJSON bool, out, errOut *strings.Builder) (*opts, int, error) {
	fs := flag.NewFlagSet("fetch-engine", flag.ContinueOnError)
	fs.SetOutput(errOut)
	o := &opts{asJSON: asJSON, progress: out}
	fs.StringVar(&o.repo, "repo", defaultRepo, "取りに行く GitHub のリポジトリ (owner/name)")
	fs.StringVar(&o.apiBase, "api", "https://api.github.com", "GitHub API の入口")
	fs.BoolVar(&o.check, "check", false, "新しいバージョンが出ているかだけを見る")
	fs.StringVar(&o.current, "current", "", "--check のときに今のバージョン (これより新しいときだけ available)")
	fs.StringVar(&o.version, "version", "", "入れるバージョン (例 0.32.0)")
	fs.StringVar(&o.into, "into", "", "バージョンごとの engine を並べる場所")
	fs.StringVar(&o.carryFrom, "carry-from", "", "持ち越す物を写してくる、今使っている engine の場所")
	if err := fs.Parse(args); err != nil {
		return nil, exitBadUsage, nil
	}
	if o.get == nil {
		if o.check {
			o.get = httpGetQuick
		} else {
			o.get = httpGet
		}
	}
	if o.runExe == nil {
		o.runExe = runExe
	}
	if o.check {
		return o, exitDone, nil
	}
	if o.version == "" || o.into == "" {
		fmt.Fprintln(errOut, "使い方: fge fetch-engine --version 0.32.0 --into <engines の場所> [--carry-from <今の engine>]")
		return nil, exitBadUsage, nil
	}
	if !IsVersionName(o.version) {
		fmt.Fprintf(errOut, "!! --version の %q はフォルダ名として置けません\n", o.version)
		return nil, exitBadUsage, nil
	}
	// WhyNot: 進み具合を out に貯めない — fge は全部の出力を終わりにまとめて吐くので、
	// 貯めると数分かかる差し替えの間、呼ぶ側 (Studio の帯) に 1 行も届かない。
	o.progress = os.Stderr
	return o, exitDone, nil
}

// ── 見に行くだけ ──────────────────────────────────────────

func runCheck(out, errOut *strings.Builder, o *opts) (int, error) {
	found, err := lookUp(o, "")
	if err != nil {
		fmt.Fprintf(errOut, "!! %v\n", err)
		return exitProblem, nil
	}
	res := checkResult{Current: o.current}
	if o.current == "" || IsNewer(o.current, found.Version) {
		res.Available = true
		res.Version = found.Version
		res.ZipURL = found.ZipURL
		res.SumsURL = found.SumsURL
	}
	if o.asJSON {
		return emit(out, res)
	}
	if res.Available {
		fmt.Fprintf(out, "[fetch-engine] 新しいバージョンが出ています: %s\n", res.Version)
	} else {
		fmt.Fprintf(out, "[fetch-engine] 今のバージョン (%s) が最新です\n", o.current)
	}
	return exitDone, nil
}

// lookUp はリリース 1 つを引いて、zip と照合の相手の在り処を取り出す。
// tag が空なら最新。
func lookUp(o *opts, tag string) (Found, error) {
	url := o.apiBase + "/repos/" + o.repo + "/releases/latest"
	if tag != "" {
		url = o.apiBase + "/repos/" + o.repo + "/releases/tags/" + tag
	}
	body, err := o.get(url)
	if err != nil {
		return Found{}, fmt.Errorf("リリースを見に行けません: %v", err)
	}
	var rel release
	if err := json.Unmarshal(body, &rel); err != nil {
		return Found{}, fmt.Errorf("リリースの応答が JSON として壊れています: %v", err)
	}
	version := VersionFromTag(rel.TagName)
	if version == "" {
		return Found{}, fmt.Errorf("タグ %q からバージョンを読めません", rel.TagName)
	}
	zipURL := urlOf(rel.Assets, ZipName(version))
	sumsURL := urlOf(rel.Assets, SumsName)
	// WhyNot: 照合の相手が無いリリースを受けない — 途切れた zip と別物を見分けられない。
	if zipURL == "" || sumsURL == "" {
		return Found{}, fmt.Errorf("v%s には %s と %s が揃っていません", version, ZipName(version), SumsName)
	}
	// WhyNot: 平文の http を受けない — zip と照合の相手が同じ経路で来るので、
	// 途中で両方を差し替えられると SHA-256 の突き合わせが何も守らなくなる。
	if !strings.HasPrefix(zipURL, "https://") || !strings.HasPrefix(sumsURL, "https://") {
		return Found{}, fmt.Errorf("v%s の置き場が https ではありません", version)
	}
	return Found{Version: version, ZipURL: zipURL, SumsURL: sumsURL}, nil
}

func urlOf(assets []asset, name string) string {
	for _, a := range assets {
		if a.Name == name {
			return a.URL
		}
	}
	return ""
}

// ── 入れる ────────────────────────────────────────────────

func runInstall(out, errOut *strings.Builder, o *opts) (int, error) {
	res, err := install(o)
	if err != nil {
		fmt.Fprintf(errOut, "!! %v\n", err)
		return exitProblem, nil
	}
	if o.asJSON {
		return emit(out, res)
	}
	fmt.Fprintf(out, "[fetch-engine] engine %s を置きました: %s\n", res.Version, res.Dir)
	return exitDone, nil
}

func install(o *opts) (installResult, error) {
	found, err := lookUp(o, "v"+o.version)
	if err != nil {
		return installResult{}, err
	}
	if err := checkRoom(o, filepath.Join(o.into, found.Version)); err != nil {
		return installResult{}, err
	}
	// WhyNot: 既に揃っている置き場を「失敗」にしない — 展開が済んだ直後に落ちると
	// 実体だけが残る。そこで断ると、押しても毎回失敗する袋小路から人が手で
	// 消すまで戻れない。揃っていて中身も走るなら、置いた物として指し先を進める。
	if placed(o, filepath.Join(o.into, found.Version)) {
		fmt.Fprintln(o.progress, "[fetch-engine] 既に置いてありました。指し先だけ進めます")
		return installResult{Installed: true, Version: found.Version,
			Dir: filepath.Join(o.into, found.Version)}, nil
	}

	fmt.Fprintf(o.progress, "[fetch-engine] engine %s を落としています (100MB 前後・数分かかります)\n", found.Version)
	sums, err := o.get(found.SumsURL)
	if err != nil {
		return installResult{}, fmt.Errorf("%s を落とせません: %v", SumsName, err)
	}
	want := SumFor(string(sums), ZipName(found.Version))
	if want == "" {
		return installResult{}, fmt.Errorf("%s に %s の値がありません", SumsName, ZipName(found.Version))
	}

	body, err := o.get(found.ZipURL)
	if err != nil {
		return installResult{}, fmt.Errorf("zip を落とせません: %v", err)
	}
	got := hex.EncodeToString(sha256Of(body))
	if got != want {
		return installResult{}, fmt.Errorf("zip の中身が公開されている値と違います (期待 %s / 実際 %s)", want, got)
	}
	fmt.Fprintf(o.progress, "[fetch-engine] zip を照合しました (%s)\n", want[:12])

	dest := filepath.Join(o.into, found.Version)
	sweepHalfDone(o.into)
	staging := dest + ".partial-" + strconv.Itoa(os.Getpid())
	// WhyNot: 目当ての名前へ直に展開しない — 途中で落ちると半端な中身が
	// 「揃っている」と見えて、次からずっとそれを使ってしまう。
	if err := os.RemoveAll(staging); err != nil {
		return installResult{}, fmt.Errorf("途中の場所を空けられません: %v", err)
	}
	defer os.RemoveAll(staging)
	if err := os.MkdirAll(staging, 0o755); err != nil {
		return installResult{}, fmt.Errorf("途中の場所を作れません: %v", err)
	}
	if err := unzipInto(body, staging); err != nil {
		return installResult{}, err
	}

	rules, err := stageengine.LoadRules(staging)
	if err != nil {
		return installResult{}, fmt.Errorf("落とした engine の組み立ての規約を読めません: %v", err)
	}
	fmt.Fprintln(o.progress, "[fetch-engine] 展開しました。持ち越す物を写しています")
	carried, err := carryOver(rules, staging, o.carryFrom)
	if err != nil {
		return installResult{}, err
	}
	if err := pickFgeGo(rules, staging, runtime.GOOS, runtime.GOARCH); err != nil {
		return installResult{}, err
	}
	applyExec(rules, staging)
	if err := checkContents(o, rules, staging); err != nil {
		return installResult{}, err
	}

	if err := os.RemoveAll(dest); err != nil {
		return installResult{}, fmt.Errorf("古い %s をどけられません: %v", dest, err)
	}
	if err := os.Rename(staging, dest); err != nil {
		return installResult{}, fmt.Errorf("%s へ名前を付けられません: %v", dest, err)
	}
	return installResult{Installed: true, Version: found.Version, Dir: dest, CarriedTo: carried}, nil
}

// checkRoom は入れ先が空いているかを先に見る。落とし始めてから断るより安い。
func checkRoom(o *opts, dest string) error {
	if o.carryFrom != "" && filepath.Clean(dest) == filepath.Clean(o.carryFrom) {
		// WhyNot: 今使っている engine の上へ入れ直させない — 名前を付ける直前に
		// 消すのが、まさにその走っている engine になる。
		return fmt.Errorf("%s は今使っている engine です。同じ場所へは入れ直せません", dest)
	}
	return nil
}

// placed は、その場所に既に走る形の engine が揃っているか。
func placed(o *opts, dest string) bool {
	if _, err := os.Stat(filepath.Join(dest, "flix.toml")); err != nil {
		return false
	}
	rules, err := stageengine.LoadRules(dest)
	if err != nil {
		return false
	}
	return checkContents(o, rules, dest) == nil
}

// sweepHalfDone は、電源が落ちるなどして残った途中の場所を掃く。
// WhyNot: 掃除を install の defer だけに任せない — kill と電源断では defer が走らず、
// 1 回 100MB 級の残骸が置き場に溜まり続ける。
func sweepHalfDone(into string) {
	entries, err := os.ReadDir(into)
	if err != nil {
		return
	}
	for _, e := range entries {
		if !strings.Contains(e.Name(), ".partial-") {
			continue
		}
		// WhyNot: 名前の中の pid の生死で決めない — Studio を 2 つ起動した時に
		// 相手が今書いている最中の場所を消しかねない。触られなくなって
		// 1 時間経った物だけを残骸と見なす。
		info, err := e.Info()
		if err != nil || time.Since(info.ModTime()) < time.Hour {
			continue
		}
		_ = os.RemoveAll(filepath.Join(into, e.Name()))
	}
}

// unzipInto は zip を展開する。中身は engine/ の 1 段に入っているので、その 1 段を外す。
func unzipInto(body []byte, dest string) error {
	r, err := zip.NewReader(bytes.NewReader(body), int64(len(body)))
	if err != nil {
		return fmt.Errorf("zip を開けません: %v", err)
	}
	written := 0
	for _, f := range r.File {
		rel := stripTopDir(f.Name)
		if rel == "" {
			continue
		}
		// WhyNot: 名前をそのまま繋がない — zip の中の ../ で置き場の外へ書ける。
		target := filepath.Join(dest, filepath.FromSlash(rel))
		if !strings.HasPrefix(target, filepath.Clean(dest)+string(os.PathSeparator)) {
			return fmt.Errorf("zip の中に置き場の外を指す名前があります: %s", f.Name)
		}
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		if err := writeEntry(f, target); err != nil {
			return err
		}
		written++
	}
	// WhyNot: 0 件で通さない — 1 段目の外し方が合わない zip (区切りが \ の
	// Windows 製など) では全部が空振りし、空のフォルダが engine として置かれる。
	if written == 0 {
		return fmt.Errorf("zip から取り出せる中身がありませんでした")
	}
	return nil
}

func writeEntry(f *zip.File, target string) error {
	in, err := f.Open()
	if err != nil {
		return err
	}
	defer in.Close()
	// WhyNot: 規約データ (exec) の印だけで実行ビットを決めない — zip は実行ビットを
	// 持っており、印の無いスクリプト (bin/githooks/pre-commit・templates の中身) まで
	// 落とすと、差し替えた後だけゲームのゲートが無言で効かなくなる。
	mode := os.FileMode(0o644)
	if f.Mode().Perm()&0o111 != 0 {
		mode = 0o755
	}
	out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// stripTopDir は zip の中の 1 段目 (engine/) を外した残り。
// WhyNot: ここで名前を整えない — ".." を畳んでしまうと、置き場の外を指す名前が
// 無害な名前に化けて、外へ書こうとした zip をそうと知らずに受け入れる。
func stripTopDir(name string) string {
	i := strings.Index(strings.TrimPrefix(name, "./"), "/")
	if i < 0 {
		return ""
	}
	return strings.TrimPrefix(name, "./")[i+1:]
}

// carryOver は「中身を Studio が決める物」を今使っている engine から写す。
func carryOver(rules *stageengine.Rules, staging, from string) ([]string, error) {
	windows := runtime.GOOS == "windows"
	var carried []string
	for _, it := range rules.Items {
		if !it.OwnedByStudio() {
			continue
		}
		if windows && it.SkipOnWindows {
			continue
		}
		dest := it.DestOf(windows)
		if from == "" {
			return nil, fmt.Errorf("%s は持ち越す物ですが、写す元 (--carry-from) を教わっていません", dest)
		}
		src := filepath.Join(from, filepath.FromSlash(dest))
		if _, err := os.Stat(src); err != nil {
			// WhyNot: optional を必須と同じに扱わない — Maven の種を持たずに
			// 組んだ Studio では lib/cache が最初から無く、必須にすると
			// そのマシンは二度と engine を上げられなくなる。
			if it.Optional {
				continue
			}
			// WhyNot: 無い物を黙って飛ばさない — 新しい engine が持ち越す物を増やしたときに
			// 欠けたまま組み上がり、差し替えた先でゲームが一切ビルドできなくなる。
			return nil, fmt.Errorf("持ち越す %s が今の engine にありません (%s)", dest, src)
		}
		if err := copyPath(src, filepath.Join(staging, filepath.FromSlash(dest))); err != nil {
			return nil, fmt.Errorf("%s を持ち越せません: %v", dest, err)
		}
		carried = append(carried, dest)
	}
	return carried, nil
}

func applyExec(rules *stageengine.Rules, staging string) {
	windows := runtime.GOOS == "windows"
	for _, it := range rules.Items {
		if !it.Exec {
			continue
		}
		target := filepath.Join(staging, filepath.FromSlash(it.DestOf(windows)))
		if info, err := os.Stat(target); err == nil && !info.IsDir() {
			_ = os.Chmod(target, 0o755)
		}
	}
}

// checkContents は組み上がった中身が本当に走る形かを見る。存在の照合だけでは足りない。
func checkContents(o *opts, rules *stageengine.Rules, staging string) error {
	windows := runtime.GOOS == "windows"
	if rel := destForSrc(rules, "@flix-wrapper", windows); rel != "" {
		if body, err := os.ReadFile(filepath.Join(staging, filepath.FromSlash(rel))); err == nil {
			// WhyNot: 中身まで見るのは、engine のリポの devbox ラッパで上書きしていると
			// nix も devbox も無い Studio でゲームのビルドが一切通らなくなるため。
			if !strings.Contains(string(body), "/jre/") {
				return fmt.Errorf("%s が同梱 JRE を見るラッパではありません (持ち越しに失敗しています)", rel)
			}
		}
	}
	rel := destForSrc(rules, "@fge-go", windows)
	if rel == "" {
		return nil
	}
	fge := filepath.Join(staging, filepath.FromSlash(rel))
	info, err := os.Stat(fge)
	if err != nil || info.IsDir() {
		// WhyNot: 無いのを通さない — 入れた後のゲームで bin/fge が毎回 exit 127 になり、
		// 更新が済んだように見えて、検査だけが何も知らせずに効かなくなる。
		return fmt.Errorf("%s がありません (この機械 %s/%s 向けの検査の中身が zip に入っていません)",
			rel, runtime.GOOS, runtime.GOARCH)
	}
	// WhyNot: 走らせて確かめるのは、名前が在るだけでは別の OS/CPU 向けかもしれないため。
	if err := o.runExe(fge, "--version"); err != nil {
		return fmt.Errorf("%s がこの機械 (%s/%s) で走りません: %v", rel, runtime.GOOS, runtime.GOARCH, err)
	}
	return nil
}

// pickFgeGo は、zip に入っている検査の中身 (bin/fge-go・bin/fge-go.exe・bin/dist/ の中) から
// この機械の OS/CPU 向けの 1 つを選び、規約データの置き先 (bin/fge-go・Windows は bin/fge-go.exe) に置く。
// 置いた後は他の機械向けの物を消し、Studio の同梱と同じ 1 つだけの形にする。
//
// WhyNot: 名前の並びで選ばず中身の頭 (Mach-O・ELF・PE) を読む — これを走らせるのは今の
// engine で、入れるのは次の版の zip。並びの約束を持つと、次の版で並びを変えた時に
// 古い側が選び違える。頭を読めば、1 つしか入っていない 0.102.0 までの zip でも
// 「linux/amd64 向けしか無い」と言って止まれる。
func pickFgeGo(rules *stageengine.Rules, staging, goos, arch string) error {
	rel := destForSrc(rules, "@fge-go", goos == "windows")
	if rel == "" {
		return nil
	}
	dest := filepath.Join(staging, filepath.FromSlash(rel))
	candidates := []string{filepath.Join(staging, "bin", "fge-go"), filepath.Join(staging, "bin", "fge-go.exe")}
	dist := filepath.Join(staging, "bin", "dist")
	if entries, err := os.ReadDir(dist); err == nil {
		for _, e := range entries {
			if !e.IsDir() {
				candidates = append(candidates, filepath.Join(dist, e.Name()))
			}
		}
	}
	match, seen, unknown := "", []string{}, false
	for _, c := range candidates {
		if _, err := os.Stat(c); err != nil {
			continue
		}
		cos, carch, ok := targetOf(c)
		if !ok {
			unknown = unknown || c == dest
			continue
		}
		seen = append(seen, cos+"/"+carch)
		if cos == goos && carch == arch && match == "" {
			match = c
		}
	}
	if match == "" {
		// WhyNot: 頭の読めない置き先 (sh など) は止めずに後の --version に任せる — 読めないだけで
		// 走る物を、この機械向けでないと決めつけない。
		if unknown || len(seen) == 0 {
			return nil
		}
		return fmt.Errorf("この zip には、この機械 (%s/%s) で走る検査の中身 (fge-go) がありません (入っているのは %s 向け)",
			goos, arch, strings.Join(seen, "・"))
	}
	if match != dest {
		if err := replaceWith(match, dest); err != nil {
			return fmt.Errorf("%s を %s へ置けません: %v", match, rel, err)
		}
	}
	for _, c := range candidates {
		if c == dest {
			continue
		}
		if _, _, ok := targetOf(c); ok {
			_ = os.Remove(c)
		}
	}
	_ = os.Remove(dist)
	return nil
}

// replaceWith は src を dest に写す。
// WhyNot: dest へ上書きせず別名に写してから名前を替える — macOS は同じ inode の実行ファイルを
// 書き換えられると、覚えていた署名の検証結果を捨てて次の実行を SIGKILL する。
func replaceWith(src, dest string) error {
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	tmp := dest + ".new"
	if err := copyFile(src, tmp, info); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o755); err != nil {
		return err
	}
	return os.Rename(tmp, dest)
}

// targetOf は実行ファイルの頭から、走る OS と CPU を読む。読めなければ ok が false。
func targetOf(path string) (goos, arch string, ok bool) {
	if f, err := macho.Open(path); err == nil {
		defer f.Close()
		return "darwin", machoArch(f.Cpu), machoArch(f.Cpu) != ""
	}
	if f, err := elf.Open(path); err == nil {
		defer f.Close()
		a := elfArch(f.Machine)
		switch f.OSABI {
		case elf.ELFOSABI_NONE, elf.ELFOSABI_LINUX:
			return "linux", a, a != ""
		case elf.ELFOSABI_FREEBSD:
			return "freebsd", a, a != ""
		}
		return "", "", false
	}
	if f, err := pe.Open(path); err == nil {
		defer f.Close()
		a := peArch(f.Machine)
		return "windows", a, a != ""
	}
	return "", "", false
}

func machoArch(cpu macho.Cpu) string {
	switch cpu {
	case macho.CpuArm64:
		return "arm64"
	case macho.CpuAmd64:
		return "amd64"
	}
	return ""
}

func elfArch(m elf.Machine) string {
	switch m {
	case elf.EM_AARCH64:
		return "arm64"
	case elf.EM_X86_64:
		return "amd64"
	case elf.EM_RISCV:
		return "riscv64"
	}
	return ""
}

func peArch(m uint16) string {
	switch m {
	case pe.IMAGE_FILE_MACHINE_AMD64:
		return "amd64"
	case pe.IMAGE_FILE_MACHINE_ARM64:
		return "arm64"
	}
	return ""
}

// destForSrc は規約データの src の印から、置き先の相対パスを引く。
func destForSrc(rules *stageengine.Rules, src string, windows bool) string {
	for _, it := range rules.Items {
		if it.Src == src {
			return it.DestOf(windows)
		}
	}
	return ""
}

// ── 純粋なルール ──────────────────────────────────────────

// VersionFromTag はタグからバージョンの字を取り出す (v0.32.0 → 0.32.0)。読めなければ空。
func VersionFromTag(tag string) string {
	body := strings.TrimPrefix(tag, "v")
	if !IsVersionName(body) {
		return ""
	}
	return body
}

// IsVersionName はフォルダ名として置いてよいバージョンの字か。
//
// WhyNot: 禁じる字を並べるのでなく通す字を並べるのは、置き場の外を指す ".." や "/" だけでなく、
// 空白・制御文字・Windows の予約名のように「作れないのでこの先ずっと失敗する」名前も
// まとめて落ちるため。
func IsVersionName(name string) bool {
	if name == "" || len(name) > 64 {
		return false
	}
	if name[0] < '0' || name[0] > '9' {
		return false
	}
	for _, c := range name {
		ok := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			c == '.' || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

// IsNewer は candidate が current より新しいか。数字の列として比べる。
//
// WhyNot: 読めない字を「新しい」に倒さないのは、0.32.0-rc1 のような試作を
// 人の意図なく本番へ進めないため。
func IsNewer(current, candidate string) bool {
	a, ok1 := numbersOf(current)
	b, ok2 := numbersOf(candidate)
	if !ok1 || !ok2 {
		return false
	}
	for i := 0; i < len(a) || i < len(b); i++ {
		x, y := 0, 0
		if i < len(a) {
			x = a[i]
		}
		if i < len(b) {
			y = b[i]
		}
		if y != x {
			return y > x
		}
	}
	return false
}

func numbersOf(version string) ([]int, bool) {
	if version == "" {
		return nil, false
	}
	parts := strings.Split(version, ".")
	nums := make([]int, 0, len(parts))
	for _, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil {
			return nil, false
		}
		nums = append(nums, n)
	}
	return nums, true
}

// SumFor は SHA256SUMS.txt から 1 つのファイルの値を引く。行は "<64 桁>  <名前>"。
//
// WhyNot: 名前の頭の "*" を落とすのは、shasum が印を付ける形 ("<値> *<名前>") でも
// 同じ行として読めるようにするため。読めないと更新が「値がありません」で止まる。
func SumFor(text, name string) string {
	for _, line := range strings.Split(text, "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 || strings.TrimPrefix(fields[1], "*") != name {
			continue
		}
		sum := strings.ToLower(fields[0])
		if len(sum) != 64 {
			continue
		}
		if _, err := hex.DecodeString(sum); err != nil {
			continue
		}
		return sum
	}
	return ""
}

// ── 外の世界 ──────────────────────────────────────────────

// httpGetWith は待つ上限を変えて 1 回取りに行く。
func httpGetWith(url string, timeout time.Duration) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	// WhyNot: 名乗るのは、GitHub API が User-Agent の無い呼び出しを断るため。
	req.Header.Set("User-Agent", "flix_game_engine-fge")
	req.Header.Set("Accept", "application/vnd.github+json")
	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s が %s を返しました", url, resp.Status)
	}
	// WhyNot: 上限を置くのは、応答を丸ごとメモリに載せるため。engine の zip は
	// 100MB 前後なので、これを超える物は「取りに行く先が違う」と見る。
	return io.ReadAll(io.LimitReader(resp.Body, 512<<20))
}

func httpGet(url string) ([]byte, error) { return httpGetWith(url, 30*time.Minute) }

// WhyNot: 見に行くだけの時に長い上限を使わない — 網が詰まったときに
// 走行権を何十分も掴んだままになり、次に押せなくなる。
func httpGetQuick(url string) ([]byte, error) { return httpGetWith(url, 30*time.Second) }

func runExe(path string, args ...string) error {
	return exec.Command(path, args...).Run()
}

func sha256Of(body []byte) []byte {
	sum := sha256.Sum256(body)
	return sum[:]
}

func copyPath(src, dst string) error {
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return copyDir(src, dst, info)
	}
	return copyFile(src, dst, info)
}

func copyDir(src, dst string, info os.FileInfo) error {
	if err := os.MkdirAll(dst, info.Mode().Perm()); err != nil {
		return err
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if err := copyPath(filepath.Join(src, e.Name()), filepath.Join(dst, e.Name())); err != nil {
			return err
		}
	}
	return nil
}

func copyFile(src, dst string, info os.FileInfo) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, info.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func emit(out *strings.Builder, value any) (int, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return exitProblem, err
	}
	out.Write(data)
	out.WriteString("\n")
	return exitDone, nil
}
