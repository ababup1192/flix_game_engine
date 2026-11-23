package main

// fge-go — bin/fge が呼ぶ検査・要約ツールの本体。判定はここが全部持つ。
//
//	fge-go digest  old.png new.png | oldDir/ newDir/ [名前...] | --stats [--unit N] a.png ...
//	fge-go loop    [コマ列ディレクトリ...] [--strict]
//	fge-go sil     --mode sil|gray|bg [*.sprite.json ...]
//	fge-go images  [ルート]
//	fge-go audio   [ルート]
//	fge-go palette [ルート]
//	fge-go view    [*.flix ...]
//
// どのサブコマンドにも --json を付けると機械可読の出力になる。
// 判定の閾値・語彙・一覧は bin/lint-rules/*.json がsource of truth。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

// Version はこのバイナリの版。CI の smoke test が最初に見る。
const Version = "0.1.0"

func emitJSON(out *strings.Builder, v any) {
	data, err := json.Marshal(v)
	if err != nil {
		fmt.Fprintf(out, "{\"error\":%q}\n", err.Error())
		return
	}
	out.Write(data)
	// WhyNot: 出力は必ず LF。Windows でも改行を \r\n にしない (比較がずれる)。
	out.WriteString("\n")
}

func orEmpty(v []string) []string {
	if v == nil {
		return []string{}
	}
	return v
}

func repoRoot() string {
	if v := os.Getenv("FGE_ROOT"); v != "" {
		return v
	}
	exe, err := os.Executable()
	if err == nil {
		// bin/fge-go から見た親の親。
		root := filepath.Dir(filepath.Dir(exe))
		if pxlib.HasDir(filepath.Join(root, "bin")) {
			return root
		}
	}
	cwd, _ := os.Getwd()
	return cwd
}

func hasFlag(args []string, name string) bool {
	for _, a := range args {
		if a == name {
			return true
		}
	}
	return false
}

// dropJSONFlag は --json だけを取り除く。
// WhyNot: -- 付きを全部落とさないのは、--strict などをサブコマンド側が自分で
// 読むため。ここで落とすと引数の解釈がずれる。
func dropJSONFlag(args []string) []string {
	var out []string
	for _, a := range args {
		if a != "--json" {
			out = append(out, a)
		}
	}
	return out
}

func dropFlags(args []string) []string {
	var out []string
	for _, a := range args {
		if !strings.HasPrefix(a, "--") {
			out = append(out, a)
		}
	}
	return out
}

// Handler は 1 つのサブコマンドの入口。out が stdout・errOut が stderr。
type Handler func(out, errOut *strings.Builder, rest []string, asJSON bool) int

// registry は init() で自分を名乗ったサブコマンド。note は一覧に出す 1 行説明。
//
// WhyNot: switch に直に並べないのは、サブコマンドを別々の人が同時に足すとき、
// 1 つのファイルへ全員が書き込んで衝突するため。名乗りは各 cmd_*.go に閉じる。
var registry = map[string]Handler{}
var registryNote = map[string]string{}

// engineOnly は engine のリポでしか意味を持たないサブコマンド。
//
// WhyNot: 配るバイナリから外せないので名乗りの側で分けるのは、1 本の実行ファイルに
// 全部入っているのがそのまま配れる利点だから。Python の頃は「配らない道具は
// ゲームに存在しない」で自然に分かれていた仕切りを、ここで置き直す。
var engineOnly = map[string]bool{}

func register(name, note string, fn Handler) {
	if _, dup := registry[name]; dup {
		panic("fge-go: サブコマンド名が重複している: " + name)
	}
	registry[name] = fn
	registryNote[name] = note
}

// registerEngineOnly は engine のリポでだけ使えるサブコマンドを名乗る。
func registerEngineOnly(name, note string, fn Handler) {
	register(name, note, fn)
	engineOnly[name] = true
}

// isEngineRepo は足元が engine のリポかどうか。
//
// WhyNot: agents-pack/ の実在で見るのは、あれを持つのが配り元だけだから
// (配られた先は .agents/ と .claude/ を受け取る)。
func isEngineRepo(root string) bool {
	info, err := os.Stat(filepath.Join(root, "agents-pack", "manifest.json"))
	return err == nil && info.Mode().IsRegular()
}

func commandNames() []string {
	inEngine := isEngineRepo(repoRoot())
	names := make([]string, 0, len(registry))
	for name := range registry {
		if engineOnly[name] && !inEngine {
			continue
		}
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// printVersion は engine のバージョンを出す。
// WhyNot: このバイナリ自身の版 (Version) を出さないのは、呼ぶ側が知りたいのが
// 「どの engine で組んだゲームか」であって道具の版ではないため。
func printVersion() int {
	// engine リポジトリ自身なら足元の Makefile。ゲームリポジトリなら ENGINE の指す先。
	root := repoRoot()
	version := status.ReadEngineVersion(root)
	if version == "" {
		if engine, _ := status.ResolveEngineDir(root); engine != "" {
			version = status.ReadEngineVersion(engine)
		}
	}
	if version == "" {
		fmt.Fprintln(os.Stderr,
			"fge (engine のバージョンが読めません: Makefile の VERSION が見当たらない)")
		return 1
	}
	fmt.Printf("fge (engine v%s)\n", version)
	return 0
}

func usage() {
	fmt.Println("使い方: fge <サブコマンド> [引数...]")
	fmt.Println("        fge --version      engine のバージョン")
	fmt.Println("        fge --list         サブコマンド名だけを 1 行ずつ")
	fmt.Println()
	width := 0
	for _, name := range commandNames() {
		if len(name) > width {
			width = len(name)
		}
	}
	for _, name := range commandNames() {
		fmt.Printf("  %-*s  %s\n", width, name, registryNote[name])
	}
}

// orAbort は検査そのものが動かなかったとき（規約ファイルが無い等）に理由を出して 2 で終わる。
// WhyNot: エラーを握って既定値で続けないのは、検査が死んだことを緑と見分けられなくなるため。
func orAbort(errOut *strings.Builder, code int, err error) int {
	if err == nil {
		return code
	}
	fmt.Fprintf(errOut, "fge-go: %v\n", err)
	return 2
}

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		usage()
		os.Exit(1)
	}
	if args[0] == "--version" || args[0] == "-V" || args[0] == "version" {
		os.Exit(printVersion())
	}
	// --list はサブコマンド名だけを 1 行ずつ出す口。
	// WhyNot: 呼ぶ側に一覧を写して持たせないのは、サブコマンドを足すたびに
	// 2 か所直すことになり、片方だけ古いまま黙って食い違うため。
	if args[0] == "--list" {
		for _, name := range commandNames() {
			fmt.Println(name)
		}
		return
	}
	cmd, rest := args[0], args[1:]
	asJSON := hasFlag(rest, "--json")

	handler, known := registry[cmd]
	if !known {
		usage()
		os.Exit(1)
	}
	// WhyNot: 生のファイル読み取りエラーで落とさないのは、あれが「配布が壊れている」と
	// 読めるため。ここで止めるのは、engine の中身を見る検査がゲームでは必ず空振りするから。
	if engineOnly[cmd] && !isEngineRepo(repoRoot()) {
		fmt.Fprintf(os.Stderr,
			"fge %s は engine のリポでだけ走ります (ここは %s)\n", cmd, repoRoot())
		os.Exit(2)
	}
	var out, errOut strings.Builder
	code := handler(&out, &errOut, rest, asJSON)
	// WhyNot: stderr を先に書くのは、2>&1 でまとめて受けたときに行順が
	// 入れ替わらないようにするため。
	os.Stderr.WriteString(errOut.String())
	os.Stdout.WriteString(out.String())
	os.Exit(code)
}

func rootArg(rest []string) string {
	positional := dropFlags(rest)
	if len(positional) > 0 {
		return positional[0]
	}
	return repoRoot()
}

// digestResult は --json 用のまとめ。
type digestResult struct {
	Lines []string `json:"lines"`
	Exit  int      `json:"exit"`
}

func cmdDigest(out *strings.Builder, rest []string, asJSON bool) int {
	var body strings.Builder
	code := digestBody(&body, rest)
	if asJSON {
		emitJSON(out, digestResult{splitLines(body.String()), code})
		return code
	}
	out.WriteString(body.String())
	return code
}

func digestBody(out *strings.Builder, rest []string) int {
	if hasFlag(rest, "--stats") {
		var argv []string
		for _, a := range rest {
			if a != "--stats" && a != "--json" {
				argv = append(argv, a)
			}
		}
		unit := 0
		for i := 0; i < len(argv); i++ {
			if argv[i] == "--unit" {
				if i+1 >= len(argv) {
					fmt.Fprintln(out, "--unit には数を渡してください")
					return 1
				}
				n, err := strconv.Atoi(argv[i+1])
				if err != nil {
					fmt.Fprintf(out, "--unit には数を渡してください: %s\n", argv[i+1])
					return 1
				}
				unit = n
				argv = append(argv[:i], argv[i+2:]...)
				break
			}
		}
		if len(argv) == 0 {
			fmt.Fprintln(out, "使い方: fge-go digest --stats [--unit N] a.png ...")
			return 1
		}
		for _, p := range argv {
			if !pxlib.HasFile(p) {
				fmt.Fprintf(out, "見つからない: %s\n", p)
				return 1
			}
			statsOne(out, p, unit)
		}
		return 0
	}

	argv := dropFlags(rest)
	if len(argv) < 2 {
		fmt.Fprintln(out, "使い方: fge-go digest old.png new.png")
		fmt.Fprintln(out, "        fge-go digest oldDir/ newDir/ [名前...]")
		fmt.Fprintln(out, "        fge-go digest --stats [--unit N] a.png ...")
		return 1
	}
	oldPath, newPath, names := argv[0], argv[1], argv[2:]
	for _, p := range []string{oldPath, newPath} {
		if _, err := os.Stat(p); err != nil {
			fmt.Fprintf(out, "見つからない: %s\n", p)
			return 1
		}
	}
	if pxlib.HasDir(oldPath) && pxlib.HasDir(newPath) {
		return compareDirs(out, oldPath, newPath, names)
	}
	if pxlib.HasFile(oldPath) && pxlib.HasFile(newPath) {
		if len(names) > 0 {
			fmt.Fprintln(out, "名前絞り込みはフォルダ比較のときだけ使えます")
			return 1
		}
		return compareFiles(out, oldPath, newPath)
	}
	fmt.Fprintln(out, "片方がファイルで片方がフォルダです。同じ種類どうしで比べてください")
	return 1
}

// loopResult は --json 用のまとめ。
type loopResult struct {
	Lines []string `json:"lines"`
	Exit  int      `json:"exit"`
}

func cmdLoop(out *strings.Builder, rest []string, asJSON bool) int {
	strict := hasFlag(rest, "--strict")
	targets := dropFlags(rest)
	var body strings.Builder
	var code int
	if hasFlag(rest, "--self-test") {
		code = runLoopSelfTest(&body)
	} else {
		code = runLoop(&body, repoRoot(), targets, strict)
	}
	if asJSON {
		emitJSON(out, loopResult{splitLines(body.String()), code})
		return code
	}
	out.WriteString(body.String())
	return code
}

func cmdSil(out *strings.Builder, rest []string, asJSON bool) int {
	mode := ""
	var files []string
	for i := 0; i < len(rest); i++ {
		switch {
		case rest[i] == "--mode" && i+1 < len(rest):
			mode = rest[i+1]
			i++
		case strings.HasPrefix(rest[i], "--mode="):
			mode = strings.TrimPrefix(rest[i], "--mode=")
		case strings.HasPrefix(rest[i], "--"):
		default:
			files = append(files, rest[i])
		}
	}
	if mode != "sil" && mode != "gray" && mode != "bg" {
		fmt.Fprintln(os.Stderr, "--mode は sil / gray / bg のどれかです")
		return 2
	}
	return runSil(out, repoRoot(), mode, files, asJSON)
}

func splitLines(s string) []string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.TrimSuffix(s, "\n")
	if s == "" {
		return []string{}
	}
	return strings.Split(s, "\n")
}
