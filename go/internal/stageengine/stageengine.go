package stageengine

// stage-engine — Studio に同梱する engine 一式を組み立てる。
//
//	fge stage-engine --out DIR [--windows]
//	                 [--flix-jar PATH] [--flix-wrapper PATH]
//	                 [--fge-go PATH] [--maven-seed DIR]
//	fge stage-engine --sources
//
// --sources は運ぶ物の元をリポの根からの相対で 1 行ずつ出す（make release-guard が
// 未コミットを見る範囲。@fge-go は中身の Go のソース go/ に読み替える）。
//
// 運ぶ物の一覧は bin/lint-rules/stage-engine.json が source of truth。組み上げたあとに
// check-refs --bundle と同じ照合をここで通すので、呼ぶ側が忘れられない。

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/checkrefs"
)

// Options は組み立ての引数。
type Options struct {
	Out         string
	Windows     bool
	FlixJar     string
	FlixWrapper string
	FgeGo       string
	MavenSeed   string
	Sources     bool
}

// Run は組み立てを走らせて終了コードを返す。
// err が返ったとき呼ぶ側は必ず止まる（規約を読めないまま緑にしない）。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	opts, err := parseArgs(args)
	if err != nil {
		return 2, err
	}
	if opts.Sources {
		rules, err := LoadRules(root)
		if err != nil {
			return 2, err
		}
		for _, p := range SourcePaths(rules) {
			fmt.Fprintln(out, p)
		}
		return 0, nil
	}
	if opts.Out == "" {
		fmt.Fprintln(errOut, "usage: fge stage-engine --out DIR [--windows] "+
			"[--flix-jar PATH] [--flix-wrapper PATH] [--fge-go PATH] [--maven-seed DIR]")
		return 2, nil
	}
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}

	if err := os.RemoveAll(opts.Out); err != nil {
		return 2, fmt.Errorf("行き先を作り直せません (%s): %v", opts.Out, err)
	}
	if err := os.MkdirAll(opts.Out, 0o755); err != nil {
		return 2, fmt.Errorf("行き先を作れません (%s): %v", opts.Out, err)
	}

	for _, it := range rules.Items {
		if opts.Windows && it.SkipOnWindows {
			continue
		}
		src, skipped, err := resolveSrc(root, it, opts)
		if err != nil {
			fmt.Fprintf(errOut, "[stage-engine] %v\n", err)
			return 1, nil
		}
		if src == "" {
			// WhyNot: 黙って飛ばさないのは、任意の物 (Maven の種) が抜けたバンドルは
			// 一見同じに見えて、配った先の初回ビルドだけが何分も止まるため。
			fmt.Fprintf(errOut, "!! [stage-engine] 同梱しません: %s (%s)\n", it.Src, skipped)
			continue
		}
		dest := filepath.Join(opts.Out, filepath.FromSlash(it.DestOf(opts.Windows)))
		if err := copyItem(src, dest, it); err != nil {
			fmt.Fprintf(errOut, "[stage-engine] %s を運べません: %v\n", it.Src, err)
			return 1, nil
		}
		fmt.Fprintf(out, "-- %s -> %s\n", it.Src, it.DestOf(opts.Windows))
	}

	// 組み上げた物を自分で照合する。
	// WhyNot: 呼ぶ側 (Makefile / ps1) に任せないのは、片方だけ書き忘れると
	// 痩せたバンドルがそのまま配られるため。
	var body, errBody strings.Builder
	checkArgs := []string{"--bundle", opts.Out}
	if opts.Windows {
		checkArgs = append(checkArgs, "--windows")
	}
	code, err := checkrefs.Run(&body, &errBody, root, checkArgs)
	out.WriteString(body.String())
	errOut.WriteString(errBody.String())
	if err != nil {
		return 2, err
	}
	// 運んだ検査データと検査の中身が同じ新しさか。
	if !checkStagedSubs(out, errOut, opts) && code == 0 {
		code = 1
	}
	return code, nil
}

func parseArgs(args []string) (Options, error) {
	var opts Options
	for i := 0; i < len(args); i++ {
		a := args[i]
		name, value := a, ""
		if eq := strings.Index(a, "="); strings.HasPrefix(a, "--") && eq > 0 {
			name, value = a[:eq], a[eq+1:]
		} else if strings.HasPrefix(a, "--") && i+1 < len(args) && a != "--windows" && a != "--sources" {
			value = args[i+1]
			i++
		}
		switch name {
		case "--out":
			opts.Out = value
		case "--windows":
			opts.Windows = true
		case "--sources":
			opts.Sources = true
		case "--flix-jar":
			opts.FlixJar = value
		case "--flix-wrapper":
			opts.FlixWrapper = value
		case "--fge-go":
			opts.FgeGo = value
		case "--maven-seed":
			opts.MavenSeed = value
		default:
			return opts, fmt.Errorf("知らない引数です: %s", a)
		}
	}
	return opts, nil
}

// SourcePaths は運ぶ物の元のうち、このリポの中にある物をリポの根からの相対で返す
// （重なりは 1 つに・並びは一覧の順）。@ で始まる外の物は運ぶ側が引数で渡すので外し、
// @fge-go だけは中身を組む Go のソース go/ に読み替える。末尾の /* はフォルダにする。
func SourcePaths(rules *Rules) []string {
	seen := map[string]bool{}
	var paths []string
	for _, it := range rules.Items {
		p := it.Src
		switch {
		case p == "@fge-go":
			p = "go"
		case strings.HasPrefix(p, "@"):
			continue
		}
		if i := strings.LastIndex(p, "/"); i > 0 && strings.Contains(p[i:], "*") {
			p = p[:i]
		}
		if !seen[p] {
			seen[p] = true
			paths = append(paths, p)
		}
	}
	return paths
}

// resolveSrc は運ぶ元の実体を返す。第 1 返り値が空文字なら運ばず、第 2 返り値がその訳。
func resolveSrc(root string, it Item, opts Options) (string, string, error) {
	switch {
	case it.Src == srcFlixJar:
		return needPath(opts.FlixJar, it, "--flix-jar で Flix コンパイラ (flix.jar) の場所を渡してください")
	case it.Src == srcFlixWrapper:
		return needPath(opts.FlixWrapper, it, "--flix-wrapper で bin/flix ラッパの場所を渡してください")
	case it.Src == srcFgeGo:
		return resolveFgeGo(root, it, opts)
	case strings.HasPrefix(it.Src, srcMavenSeed+"/"):
		if opts.MavenSeed == "" {
			return "", "元の場所が渡されていません (--maven-seed)", nil
		}
		sub := strings.TrimPrefix(it.Src, srcMavenSeed+"/")
		return needPath(filepath.Join(opts.MavenSeed, filepath.FromSlash(sub)), it, "")
	}

	rel := it.Src
	if strings.Contains(rel, "*") {
		// glob はフォルダを渡して copyItem 側で名前を絞る。
		rel = filepath.Dir(rel)
	}
	return needPath(filepath.Join(root, filepath.FromSlash(rel)), it, "")
}

func needPath(path string, it Item, hint string) (string, string, error) {
	if path == "" {
		if it.Optional {
			return "", "元の場所が渡されていません", nil
		}
		return "", "", fmt.Errorf("%s の元がありません。%s", it.Src, hint)
	}
	if _, err := os.Stat(path); err != nil {
		if it.Optional {
			return "", fmt.Sprintf("元が見つかりません: %s", path), nil
		}
		if hint != "" {
			return "", "", fmt.Errorf("%s が見つかりません (%s)。%s", it.Src, path, hint)
		}
		return "", "", fmt.Errorf("%s が見つかりません (%s)", it.Src, path)
	}
	return path, "", nil
}

// resolveFgeGo は走らせる先の OS/CPU に合う検査の中身を 1 つ選ぶ。
// WhyNot: 5 つ全部入れないのは、1 つ 5M 弱あってバンドルがその分ふくらむため。
func resolveFgeGo(root string, it Item, opts Options) (string, string, error) {
	if opts.FgeGo != "" {
		return needPath(opts.FgeGo, it, "")
	}
	goos, arch, ext := runtime.GOOS, runtime.GOARCH, ""
	if opts.Windows {
		goos, arch, ext = "windows", "amd64", ".exe"
	}
	candidates := []string{
		filepath.Join(root, "bin", "dist", fmt.Sprintf("fge-go-%s-%s%s", goos, arch, ext)),
		filepath.Join(root, "bin", "fge-go"+ext),
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c, "", nil
		}
	}
	return "", "", fmt.Errorf("%s が見つかりません (%s)。engine で make go-build してください",
		it.Src, strings.Join(candidates, " / "))
}

// ------------------------------------------------------------ 複製

func copyItem(src, dest string, it Item) error {
	if strings.Contains(it.Src, "*") {
		return copyGlob(src, dest, filepath.Base(it.Src), it)
	}
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return copyTree(src, dest, it)
	}
	return copyFile(src, dest, modeOf(info, it))
}

func copyGlob(srcDir, destDir, pattern string, it Item) error {
	entries, err := os.ReadDir(srcDir)
	if err != nil {
		return err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		ok, err := filepath.Match(pattern, e.Name())
		if err != nil {
			return err
		}
		if ok {
			names = append(names, e.Name())
		}
	}
	if len(names) == 0 && !it.Optional {
		return fmt.Errorf("%s に当たるファイルがありません", it.Src)
	}
	sort.Strings(names)
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return err
	}
	for _, name := range names {
		info, err := os.Stat(filepath.Join(srcDir, name))
		if err != nil {
			return err
		}
		if err := copyFile(filepath.Join(srcDir, name), filepath.Join(destDir, name), modeOf(info, it)); err != nil {
			return err
		}
	}
	return nil
}

func copyTree(srcDir, destDir string, it Item) error {
	pruned := map[string]bool{}
	for _, name := range it.PruneDirs {
		pruned[name] = true
	}
	return filepath.WalkDir(srcDir, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(srcDir, path)
		if err != nil {
			return err
		}
		target := filepath.Join(destDir, rel)
		if d.IsDir() {
			if pruned[d.Name()] {
				return filepath.SkipDir
			}
			return os.MkdirAll(target, 0o755)
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		// WhyNot: symlink を運ばないのは、指す先がそのマシンにしか無いことがあり、
		// 配った先で codesign や展開が転ぶため。
		if info.Mode()&os.ModeSymlink != 0 {
			return nil
		}
		return copyFile(path, target, modeOf(info, it))
	})
}

// modeOf は行き先の許可。書ける (u+w) 形にそろえ、実行できる元だけ実行できるまま渡す。
// WhyNot: 元の許可をそのまま写さないのは、nix store から来る物が読み取り専用で、
// 後段の Tauri のリソース収集や zip 展開が Permission denied で死ぬため。
func modeOf(info os.FileInfo, it Item) os.FileMode {
	if it.Exec || info.Mode().Perm()&0o111 != 0 {
		return 0o755
	}
	return 0o644
}

func copyFile(src, dest string, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
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
	return os.Chmod(dest, mode)
}
