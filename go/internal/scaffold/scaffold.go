// Package scaffold は新しいゲームをテンプレートから作る（make new-game と fge new の中身）。決まりの本文は plans/windows.md 5 節の #3。
//
// テンプレートを写す → __NAME__ などを置き換える → lib に engine_full と依存を置く → git init → agents-pack と fge-go を配る →
// check → test → lint-flixlint → render-all を通す。置き換えの規則は前の make new-game の perl の 1 行と同じ。
package scaffold

import (
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/cmdhint"
	"github.com/ababup1192/flix_game_engine/go/internal/mvncache"
	"github.com/ababup1192/flix_game_engine/go/internal/syncagents"
)

// 既定（make new-game の TEMPLATE・W・H の既定と同じ）。
const (
	DefaultTemplate = "game-starter"
	DefaultW        = 480
	DefaultH        = 300
)

var (
	packageNameRe  = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)
	templateNameRe = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
	digitsRe       = regexp.MustCompile(`^[0-9]+$`)
	styleHeadRe    = regexp.MustCompile(`^(## この(?:画面|ゲーム)の画風)\s*$`)
)

// generatedDirs はどのテンプレートからも写さない根のフォルダ。
// WhyNot: build を写さない — テンプレ 1 本で 500MB 級に育ち、パッケージ名が変わるのでどのみち使えない。lib は engine_full から置き直す。
var generatedDirs = map[string]bool{
	"lib": true, "build": true, "debug": true, "gallery": true, ".devbox": true, ".test-logs": true,
}

// Request は作るゲーム 1 本の注文。
type Request struct {
	Engine   string
	Game     string
	Name     string
	Title    string
	Template string
	// W・H は人が渡した字のまま（空なら既定）。
	W, H string
	// PackNote は配った engine の時に最後の「配られた物は版上げで上書きされる」の 1 行を出すか（fge new は自分で出すので false）。
	PackNote bool
	// NextSteps は最後の「次にやること」の案内を出すか（fge new は自分で出すので false）。
	NextSteps bool
	GOOS      string
	GOARCH    string
}

// Steps は産声の確認に起こすゲームの作業。
type Steps interface {
	Check(game string) error
	Test(game string) error
	LintFlixlint(game string) error
	RenderAll(game string) error
}

// Deps は外の世界とつなぐ所。テストは差し替える。
type Deps struct {
	Out        io.Writer
	Steps      Steps
	Git        func(args ...string) error
	SyncAgents func(engine, game, version string) error
	LinkCache  func(game string) string
	CacheDir   func() string
}

// DefaultDeps は本物の git・sync-agents・共有の置き場を使う。
func DefaultDeps(out io.Writer, steps Steps) Deps {
	return Deps{
		Out:   out,
		Steps: steps,
		Git: func(args ...string) error {
			c := exec.Command("git", args...)
			c.Stdout, c.Stderr = out, out
			return c.Run()
		},
		SyncAgents: func(engine, game, version string) error {
			return RunSyncAgents(out, engine, game, version)
		},
		LinkCache: mvncache.Link,
		CacheDir: func() string {
			d, _ := mvncache.Dir()
			return d
		},
	}
}

// RunSyncAgents は agents-pack をゲームに配る（make sync-agents の Go の半分）。
func RunSyncAgents(out io.Writer, engine, game, version string) error {
	var o, e strings.Builder
	code, err := syncagents.Run(&o, &e, engine, []string{"--game", game, "--version", version})
	io.WriteString(out, e.String())
	io.WriteString(out, o.String())
	if err != nil {
		return fmt.Errorf("sync-agents: %v", err)
	}
	if code != 0 {
		return fmt.Errorf("sync-agents が %d で終わりました", code)
	}
	return nil
}

// Validate は注文を確かめ、既定を埋めた物を返す（make new-game の頭の検査と同じ）。
func Validate(r Request) (Request, error) {
	if r.Game == "" {
		return r, fmt.Errorf("GAME を指定してください (make new-game GAME=/abs/path NAME=mygame TITLE=題名 W=240 H=320)")
	}
	if !filepath.IsAbs(r.Game) {
		return r, fmt.Errorf("GAME は絶対パスで指定してください: %s", r.Game)
	}
	if _, err := os.Lstat(r.Game); err == nil {
		return r, fmt.Errorf("生成先が既に存在します: %s", r.Game)
	}
	if r.Name == "" {
		return r, fmt.Errorf("NAME を指定してください（Flix パッケージ名）")
	}
	if !packageNameRe.MatchString(r.Name) {
		return r, fmt.Errorf("NAME が不正です: %s（小文字英字はじまり・英小文字/数字/_ のみ）", r.Name)
	}
	if r.W != "" && !digitsRe.MatchString(r.W) {
		return r, fmt.Errorf("W が数値ではありません: %s", r.W)
	}
	if r.H != "" && !digitsRe.MatchString(r.H) {
		return r, fmt.Errorf("H が数値ではありません: %s", r.H)
	}
	if r.Template == "" {
		r.Template = DefaultTemplate
	}
	if !templateNameRe.MatchString(r.Template) {
		return r, fmt.Errorf("TEMPLATE が不正です: %s", r.Template)
	}
	if info, err := os.Stat(filepath.Join(r.Engine, "templates", r.Template)); err != nil || !info.IsDir() {
		return r, fmt.Errorf("templates/%s がありません", r.Template)
	}
	if r.Title == "" {
		r.Title = r.Name
	}
	return r, nil
}

// Tokens は置き換える字と値（この順に置き換える。__WW__ を __W__ より先にしないと __W__ が W の 2 字を食う）。
func Tokens(name, title string, w, h int) [][2]string {
	return [][2]string{
		{"__NAME__", name},
		{"__TITLE__", title},
		{"__WW__", strconv.Itoa(w * 2)},
		{"__WH__", strconv.Itoa(h * 2)},
		{"__W__", strconv.Itoa(w)},
		{"__H__", strconv.Itoa(h)},
	}
}

// ApplyTokens は text の字を順に置き換える。
func ApplyTokens(text string, tokens [][2]string) string {
	for _, t := range tokens {
		text = strings.ReplaceAll(text, t[0], t[1])
	}
	return text
}

// IsTokenTarget は置き換える物か（*.flix *.json *.toml *.md Makefile）。絵や音はそのまま写す。
func IsTokenTarget(base string) bool {
	if base == "Makefile" {
		return true
	}
	for _, ext := range []string{".flix", ".json", ".toml", ".md"} {
		if strings.HasSuffix(base, ext) {
			return true
		}
	}
	return false
}

// ExcludePaths は new-game.exclude の本文から写さないパスを取り出す。1 行に 1 つ・テンプレートの根からの相対・# から行末は注釈。
// WhyNot: / で始まる物と .. を含む物は読み飛ばす — 外す先がゲームのフォルダの外へ出る。
func ExcludePaths(text string) []string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		if i := strings.Index(line, "#"); i >= 0 {
			line = line[:i]
		}
		line = strings.TrimRight(line, " \t\r\n\v\f")
		if line == "" || strings.HasPrefix(line, "/") || strings.Contains(line, "..") {
			continue
		}
		out = append(out, path.Clean(line))
	}
	return out
}

// WithStyleNote は AGENTS.local.md の「この画面の画風」の見出しの下に、テンプレートの画風の仮置きの 1 行を足す。
//
// WhyNot: 見出しの行の改行ごと置き換える — 前の perl の 1 行（s/^(見出し)\s*$/$1\n\n（…）/）は \s* が行末の改行まで食い、
// 見出しの次の空行が仮置きの行の終わりになる。同じ形にそろえる。
func WithStyleNote(text, template string) string {
	note := "（テンプレ " + template + " の画風の仮置き。**最初に決めて、ここに** 自分の画風を書き直す — 決め方は画風の聞き取りスキル）"
	lines := strings.SplitAfter(text, "\n")
	for i, line := range lines {
		if m := styleHeadRe.FindStringSubmatch(line); m != nil {
			lines[i] = m[1] + "\n\n" + note
		}
	}
	return strings.Join(lines, "")
}

// LocalMk は作業コピーの engine から作った時に置く local.mk の本文。
// WhyNot: Windows の \ を / に直す — make と sh のクォートは \ と相性が悪く、java は / のパスを受け付ける。
func LocalMk(engine string) string {
	return "# このマシンの実行環境 (git には入れない — .gitignore 済み)。make new-game が生成。\n" +
		"# ?= なのは Studio が環境変数 ENGINE で渡してくる同梱 engine を勝たせるため。\n" +
		"ENGINE ?= " + filepath.ToSlash(engine) + "\n"
}

func (d Deps) printf(format string, args ...any) {
	fmt.Fprintf(d.Out, format, args...)
}

// Create はゲームを 1 本作る。途中で止まった時の作りかけは消さない（呼ぶ側が決める）。
func Create(r Request, d Deps) error {
	r, err := Validate(r)
	if err != nil {
		return err
	}
	version, err := EngineVersion(r.Engine)
	if err != nil {
		return err
	}
	ef, err := EngineFullFiles(r.Engine, version)
	if err != nil {
		return err
	}
	tplDir := filepath.Join(r.Engine, "templates", r.Template)
	w, h := DefaultW, DefaultH
	if r.W != "" {
		w, _ = strconv.Atoi(r.W)
	}
	if r.H != "" {
		h, _ = strconv.Atoi(r.H)
	}
	if r.W == "" && r.H == "" {
		if b, err := os.ReadFile(filepath.Join(tplDir, "project.json")); err == nil && strings.Contains(string(b), "__W__") {
			d.printf("[new-game] W/H 未指定 — トークン式テンプレの既定 480×300 で作ります\n")
		}
	}
	d.printf("[new-game] %s を作成します (NAME=%s TITLE=%s design=%dx%d TEMPLATE=%s)\n", r.Game, r.Name, r.Title, w, h, r.Template)

	if err := copyTemplate(tplDir, r.Game); err != nil {
		return err
	}
	for _, sub := range []string{"gallery", "reference", "debug", "atelier"} {
		if err := os.MkdirAll(filepath.Join(r.Game, sub), 0o755); err != nil {
			return err
		}
	}
	if err := renameNameAssets(r.Game, r.Name); err != nil {
		return err
	}
	if err := replaceTokens(r.Game, Tokens(r.Name, r.Title, w, h)); err != nil {
		return err
	}
	if err := rewriteFile(filepath.Join(r.Game, "AGENTS.local.md"), func(s string) string { return WithStyleNote(s, r.Template) }); err != nil {
		return err
	}
	// WhyNot: 配った engine では local.mk を書かない — ENGINE はゲームの Makefile が flix.toml の版から決める（版を上げると一緒に替わる）。
	if !IsBundle(r.Engine) {
		if err := os.WriteFile(filepath.Join(r.Game, "local.mk"), []byte(LocalMk(r.Engine)), 0o644); err != nil {
			return err
		}
	}
	if err := seedLib(r, ef, d); err != nil {
		return err
	}
	if err := d.Git("-C", r.Game, "init", "-q"); err != nil {
		return fmt.Errorf("git init: %v", err)
	}
	if err := d.Git("-C", r.Game, "config", "core.hooksPath", "bin/githooks"); err != nil {
		return fmt.Errorf("git config: %v", err)
	}
	if err := d.SyncAgents(r.Engine, r.Game, version); err != nil {
		return err
	}
	line, err := SyncFgeGo(r.Engine, r.Game, r.GOOS, r.GOARCH)
	if err != nil {
		return err
	}
	d.printf("%s\n", line)

	d.printf("[new-game] 産声の確認: check → test → lint-flixlint → render-all\n")
	for _, step := range []struct {
		name string
		run  func(string) error
	}{
		{"check", d.Steps.Check}, {"test", d.Steps.Test}, {"lint-flixlint", d.Steps.LintFlixlint}, {"render-all", d.Steps.RenderAll},
	} {
		if err := step.run(r.Game); err != nil {
			return fmt.Errorf("産声の確認の %s で止まりました: %v", step.name, err)
		}
	}
	// WhyNot: fge new から呼ばれた時に案内を出さない — fge new が自分の「次にやること」を最後に出すので、2 回並ぶ。
	if r.NextSteps {
		printNext(r, d)
	}
	return nil
}

func printNext(r Request, d Deps) {
	run, refUpdate := cmdhint.CommandFor(r.GOOS, "run"), cmdhint.CommandFor(r.GOOS, "reference-update")
	d.printf("\n")
	d.printf("新しいゲームが産まれました: %s\n", r.Game)
	d.printf("  次にやること:\n")
	d.printf("    cd %s && %s              … ウィンドウを開いて遊ぶ（矢印キーで移動）\n", r.Game, run)
	d.printf("    %s                 … いまの絵をリファレンス画像(基準)にする\n", refUpdate)
	if IsBundle(r.Engine) {
		// WhyNot: fge new から呼ばれた時に上書きの 1 行を出さない — fge new が同じ 1 行を最後に出すので、2 回並ぶ。
		if r.PackNote {
			d.printf("  配られた skills・rules・AGENTS.md の共通部は版上げで上書きされる。ゲーム用に変えたい時は AGENTS.local.md に書くか、別の名前のスキルを足す。\n")
		}
	} else {
		d.printf("    Studio で %s を開く            … 色や数値をフォームから調整する\n", r.Game)
	}
	d.printf("  git init 済み・未コミットです。最初のコミットは自分の手で。\n")
}

// copyTemplate はテンプレートをゲームへ写す（生成物と new-game.exclude の物は写さない）。
//
// WhyNot: 写した後に書けるようにする（u+w）— 配った engine は読み取り専用で開くので、そのまま写すとゲームのファイルまで
// 読み取り専用になり、AI も人も直せない。
func copyTemplate(tplDir, game string) error {
	var excludes []string
	if b, err := os.ReadFile(filepath.Join(tplDir, "new-game.exclude")); err == nil {
		excludes = ExcludePaths(string(b))
	}
	skip := func(rel string) bool {
		top := strings.SplitN(rel, "/", 2)[0]
		if generatedDirs[top] {
			return true
		}
		for _, p := range excludes {
			if rel == p || strings.HasPrefix(rel, p+"/") {
				return true
			}
		}
		return false
	}
	if err := os.MkdirAll(game, 0o755); err != nil {
		return err
	}
	return filepath.WalkDir(tplDir, func(p string, de fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(tplDir, p)
		if rel == "." {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if skip(rel) {
			if de.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		dest := filepath.Join(game, filepath.FromSlash(rel))
		info, err := os.Lstat(p)
		if err != nil {
			return err
		}
		switch {
		case info.Mode()&fs.ModeSymlink != 0:
			return copySymlink(p, dest)
		case info.IsDir():
			return os.MkdirAll(dest, info.Mode().Perm()|0o700)
		default:
			return copyFile(p, dest, info.Mode().Perm()|0o200)
		}
	})
}

// copySymlink は symlink を symlink のまま写す（cp -R と同じ）。張れない機械（Windows）では指す先の中身を写す。
func copySymlink(src, dest string) error {
	target, err := os.Readlink(src)
	if err != nil {
		return err
	}
	if os.Symlink(target, dest) == nil {
		return nil
	}
	info, err := os.Stat(src)
	if err != nil {
		return nil
	}
	if info.IsDir() {
		return copyTree(src, dest)
	}
	return copyFile(src, dest, info.Mode().Perm()|0o200)
}

func copyFile(src, dest string, perm fs.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	out, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, perm)
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
	return os.Chmod(dest, perm)
}

// copyTree はフォルダを中身ごと写す（cp -R。symlink は指す先の中身を写す）。
func copyTree(src, dest string) error {
	return filepath.WalkDir(src, func(p string, de fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		to := filepath.Join(dest, rel)
		info, err := os.Stat(p)
		if err != nil {
			return err
		}
		if info.IsDir() {
			return os.MkdirAll(to, info.Mode().Perm()|0o700)
		}
		return copyFile(p, to, info.Mode().Perm()|0o200)
	})
}

// renameNameAssets は assets/__NAME__.* を assets/<名前>.* に替える。
func renameNameAssets(game, name string) error {
	dir := filepath.Join(game, "assets")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	for _, e := range entries {
		rest, ok := strings.CutPrefix(e.Name(), "__NAME__.")
		if !ok {
			continue
		}
		if err := os.Rename(filepath.Join(dir, e.Name()), filepath.Join(dir, name+"."+rest)); err != nil {
			return err
		}
	}
	return nil
}

func replaceTokens(game string, tokens [][2]string) error {
	return filepath.WalkDir(game, func(p string, de fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !de.Type().IsRegular() || !IsTokenTarget(de.Name()) {
			return nil
		}
		return rewriteFile(p, func(s string) string { return ApplyTokens(s, tokens) })
	})
}

// rewriteFile はファイルを fn で書き換える（無ければ何もしない・変わらなければ書かない）。
func rewriteFile(p string, fn func(string) string) error {
	b, err := os.ReadFile(p)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	after := fn(string(b))
	if after == string(b) {
		return nil
	}
	info, err := os.Stat(p)
	if err != nil {
		return err
	}
	return os.WriteFile(p, []byte(after), info.Mode().Perm())
}

// seedLib はゲームの lib に engine_full の束・lib/external・LWJGL の natives・lib/cache を置く。
func seedLib(r Request, ef EngineFull, d Deps) error {
	destDir := filepath.Join(r.Game, filepath.FromSlash(ef.Subpath))
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return err
	}
	// WhyNot: 置き場の束の 0444 のまま写さない — 次の engine-upgrade の入れ替えと人の手の差し替えで書けない。
	if err := copyFile(ef.Fpkg, filepath.Join(destDir, ef.FpkgName), 0o644); err != nil {
		return err
	}
	if err := copyFile(ef.Toml, filepath.Join(destDir, ef.TomlName), 0o644); err != nil {
		return err
	}
	ext := filepath.Join(r.Engine, "lib", "external")
	if info, err := os.Stat(ext); err == nil && info.IsDir() {
		if err := copyTree(ext, filepath.Join(r.Game, "lib", "external")); err != nil {
			return err
		}
	}
	// WhyNot: LWJGL の natives を手元から写す — flix.toml の jar-dependencies は coursier を通らず lib/cache にも入らないので、
	// 無ければ Flix が 1 本ずつ Maven Central へ取りに行き、続けて作ると 429 で止まる。
	natives, _ := filepath.Glob(filepath.Join(r.Engine, "render_gl", "lib", "external", "lwjgl-*-natives-*.jar"))
	for _, j := range natives {
		to := filepath.Join(r.Game, "lib", "external", filepath.Base(j))
		if _, err := os.Stat(to); err == nil {
			continue
		}
		if err := copyFile(j, to, 0o644); err != nil {
			return err
		}
	}
	cache := filepath.Join(r.Engine, "lib", "cache")
	if info, err := os.Lstat(cache); err == nil && info.IsDir() {
		if err := copyTree(cache, filepath.Join(r.Game, "lib", "cache")); err != nil {
			return err
		}
	}
	// WhyNot: Windows で lib/cache を共有の置き場への symlink にしない — symlink は開発者モードでないと張れない。今まで通り lib/cache に取る。
	if r.GOOS != "windows" {
		if line := d.LinkCache(r.Game); line != "" {
			d.printf("%s\n", line)
		}
		d.printf("[new-game] lib/ を種付けしました（Maven の取り物は共有の置き場 %s を使う。無い物は初回ビルドで取りに行く）\n", d.CacheDir())
	} else {
		d.printf("[new-game] lib/ を種付けしました（Maven の取り物は lib/cache に取る。無い物は初回ビルドで取りに行く）\n")
	}
	return nil
}
