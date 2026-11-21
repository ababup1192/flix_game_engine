package main

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// wasmEnginePrefix は fpkg から入った物（engine の束）に TeaVM が付ける頭。ゲームのモジュールには付かない。
const wasmEnginePrefix = "$pkg$github$ababup1192$flix_game_engine."

// wasmName は TeaVM の関数名を読み分けた物。
type wasmName struct {
	Package string // engine・engine_world・render_gl・engine_web・ゲーム・Flix 標準・Flix 実行環境・Java/TeaVM
	Module  string // Flix のモジュール（Def$ / Clo$ の前まで）
	Def     string // 単相化の番号を外した元の関数の名前（モジュール付き）
}

// wasmModuleIndex はモジュールの道 → パッケージ。長い道の一致を先に見る。
type wasmModuleIndex struct {
	engine map[string]string
	game   map[string]bool
}

var wasmModDecl = regexp.MustCompile(`(?m)^(?:pub\s+)?mod\s+([A-Za-z0-9_.]+)`)

// wasmEnginePackages は engine の束に入るパッケージ。engine_tools は束に入らない（ブラウザ版の入口から届かない）が、
// 入ってしまった時に見分けられるよう並べておく。
var wasmEnginePackages = []string{"engine", "render_gl", "engine_world", "engine_web", "engine_tools"}

func buildWasmModuleIndex(engineRoot, gameRoot string) wasmModuleIndex {
	idx := wasmModuleIndex{engine: map[string]string{}, game: map[string]bool{}}
	for _, p := range wasmEnginePackages {
		for _, m := range flixModulesUnder(filepath.Join(engineRoot, p, "src")) {
			idx.engine[m] = p
		}
	}
	if gameRoot != "" {
		for _, m := range flixModulesUnder(filepath.Join(gameRoot, "src")) {
			idx.game[m] = true
		}
		for _, m := range flixModulesUnder(filepath.Join(gameRoot, "web")) {
			idx.game[m] = true
		}
	}
	return idx
}

// flixModulesUnder は dir の下の .flix の、行頭の mod 宣言の道を集める。
// WhyNot: bin/fge refactor を使わない — 欲しいのは宣言の道の一覧だけで、Flix を起こすと 1 回で数十秒かかる。
func flixModulesUnder(dir string) []string {
	seen := map[string]bool{}
	filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".flix") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		for _, m := range wasmModDecl.FindAllSubmatch(data, -1) {
			seen[string(m[1])] = true
		}
		return nil
	})
	out := make([]string, 0, len(seen))
	for m := range seen {
		out = append(out, m)
	}
	sort.Strings(out)
	return out
}

func (idx wasmModuleIndex) engineOwner(module string) string {
	for m := module; m != ""; m = parentModule(m) {
		if p, ok := idx.engine[m]; ok {
			return p
		}
	}
	return "engine(不明)"
}

func (idx wasmModuleIndex) isGame(module string) bool {
	for m := module; m != ""; m = parentModule(m) {
		if idx.game[m] {
			return true
		}
	}
	return false
}

func parentModule(m string) string {
	if i := strings.LastIndex(m, "."); i > 0 {
		return m[:i]
	}
	return ""
}

var wasmCopySuffix = regexp.MustCompile(`\$\d+$`)

func (idx wasmModuleIndex) classify(name string) wasmName {
	cls := name
	if i := strings.Index(cls, "::"); i >= 0 {
		cls = cls[:i]
	}
	if i := strings.Index(cls, "@"); i >= 0 {
		cls = cls[:i]
	}
	engine := strings.HasPrefix(cls, wasmEnginePrefix)
	cls = strings.TrimPrefix(cls, wasmEnginePrefix)
	switch {
	case strings.HasPrefix(cls, "java.") || strings.HasPrefix(cls, "javax.") || strings.HasPrefix(cls, "org.teavm") || strings.HasPrefix(cls, "teavm") || cls == "" || strings.HasPrefix(cls, "<名無し"):
		return wasmName{Package: "Java/TeaVM", Module: firstSegments(cls, 2), Def: cls}
	case strings.HasPrefix(cls, "fge."):
		// WhyNot: 頭が $pkg$ でなくても engine の物 — engine_web が持つ Java のクラス（fge.web.*）。
		return wasmName{Package: "engine_web", Module: firstSegments(cls, 3), Def: cls}
	case strings.HasPrefix(cls, "dev.flix.runtime"):
		return wasmName{Package: "Flix 実行環境", Module: "dev.flix.runtime", Def: cls}
	case strings.HasPrefix(cls, "org.lwjgl") || strings.HasPrefix(cls, "com.") || strings.HasPrefix(cls, "org."):
		return wasmName{Package: "Java/TeaVM", Module: firstSegments(cls, 2), Def: cls}
	}
	segs := strings.Split(cls, ".")
	module, def := cls, cls
	for i, s := range segs {
		if strings.HasPrefix(s, "Def$") || strings.HasPrefix(s, "Clo$") {
			module = strings.Join(segs[:i], ".")
			def = module + "." + wasmCopySuffix.ReplaceAllString(s[4:], "")
			break
		}
		if i == len(segs)-1 {
			// WhyNot: Def$ / Clo$ の無い名前は enum・struct・tuple などの型のクラス。型の名前を 1 つの区分にする。
			module = strings.Join(segs[:max(len(segs)-1, 1)], ".")
			def = module + ".<型>"
		}
	}
	switch {
	case engine:
		return wasmName{Package: idx.engineOwner(module), Module: module, Def: def}
	case idx.isGame(module):
		return wasmName{Package: "ゲーム", Module: module, Def: def}
	case !strings.Contains(module, ".") && strings.Contains(module, "$"):
		return wasmName{Package: "Flix 実行環境", Module: "(型の器)", Def: def}
	default:
		return wasmName{Package: "Flix 標準", Module: module, Def: def}
	}
}

func firstSegments(s string, n int) string {
	segs := strings.SplitN(s, ".", n+1)
	if len(segs) > n {
		segs = segs[:n]
	}
	return strings.Join(segs, ".")
}

// brotliSize は data を配る形（q11）で詰めた大きさ。
func brotliSize(data []byte) int {
	br, err := brotliBytes(data)
	if err != nil {
		return 0
	}
	return len(br)
}

// findGameRoot は path から上へ辿り、flix.toml のあるフォルダを返す（無ければ ""）。
func findGameRoot(path string) string {
	abs, err := filepath.Abs(path)
	if err != nil {
		return ""
	}
	for d := abs; d != filepath.Dir(d); d = filepath.Dir(d) {
		if _, err := os.Stat(filepath.Join(d, "flix.toml")); err == nil {
			return d
		}
	}
	return ""
}
