package status

// engine の場所とバージョンの解決。決まりの本文は plans/onboarding.md の 2.5。
//
// WhyNot: 呼ぶ側ごとに解決を書かないのは、同じ順で読まないと fge と status で
// 見ている engine が食い違うため。テンプレートの Makefile の ENGINE の既定と同じ答えを出す（engine_test.go で比べる）。

import (
	"encoding/json"
	"os"
	"path/filepath"

	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
)

// 「先頭の空白 ENGINE 空白 [?:]* = 空白 値」。値の末尾の空白は落とす。
var engineLineRe = compilePySpace(`^\s*ENGINE\s*[?:]*=\s*(.+?)\s*$`)

// Makefile の「VERSION := 値」。
var versionLineRe = compilePySpace(`^VERSION\s*:=\s*(\S+)`)

// ResolveEngineDir はゲームのフォルダ game の engine の根と、game 自身が engine か（mk/game.mk がある）を返す。
// game 自身が engine でなければ、次の順の最初に決まった物（在るかは見ない。make の ENGINE と同じ）:
//
//  1. 環境変数 ENGINE  2. game/local.mk の ENGINE
//  3. game/../../mk/game.mk と game/../../templates/ があれば game/../..（engine の中のテンプレート）
//  4. 置き場の engines/<flix.toml の flix_game_engine の版>
//
// 相対パスは game から読む。どれも決まらなければ空（flix.toml に依存の行が無い・版が読めない）。
// WhyNot: 版が読めない時に止めない — engine リポの中の engine/ などは flix.toml に依存の行を持たず、そこで道具を止めない。
func ResolveEngineDir(game string) (dir string, self bool) {
	if isRegularFile(filepath.Join(game, "mk", "game.mk")) {
		return game, true
	}
	for _, c := range engineCandidates(game) {
		if c != "" {
			return c, false
		}
	}
	return "", false
}

// engineCandidates は ResolveEngineDir の決まりの 1〜4 を順に（決まらない物は空）。相対パスは game から読んだ物にする。
func engineCandidates(game string) []string {
	abs := func(c string) string {
		if c == "" || filepath.IsAbs(c) {
			return c
		}
		return filepath.Join(game, c)
	}
	inTemplates := ""
	up := filepath.Join(game, "..", "..")
	if isRegularFile(filepath.Join(up, "mk", "game.mk")) && isDirPath(filepath.Join(up, "templates")) {
		inTemplates = up
	}
	bundled := ""
	if v := readGameEnginePin(game); v != "" {
		bundled = fgehome.EngineDir(v)
	}
	return []string{abs(os.Getenv("ENGINE")), abs(readLocalMkEngine(game)), inTemplates, bundled}
}

// readLocalMkEngine は game/local.mk の ENGINE の値（無ければ空）。
func readLocalMkEngine(game string) string {
	text, err := readTextPy(filepath.Join(game, "local.mk"))
	if err != nil {
		return ""
	}
	for _, line := range pyFileLines(text) {
		if m := engineLineRe.FindStringSubmatch(line); m != nil {
			return m[1]
		}
	}
	return ""
}

// readGameEnginePin は game/flix.toml の flix_game_engine の版（読めなければ空）。
func readGameEnginePin(game string) string {
	text, err := readTextPy(filepath.Join(game, "flix.toml"))
	if err != nil {
		return ""
	}
	v, _ := EnginePinOf(text)
	return v
}

// FindEngineDir は ResolveEngineDir の決まりのうち、marker（mk/game.mk など engine にだけある物）が実在する最初の所と、
// それが base 自身かを返す。どれにも無ければ空。
//
// WhyNot: ResolveEngineDir の答え 1 つだけを見ない — 環境変数 ENGINE が古い所を指したままでも、local.mk や置き場の
// engine で lint を続けたい（marker の無い候補は飛ばす）。
func FindEngineDir(base, marker string) (dir string, self bool) {
	has := func(d string) bool { return isRegularFile(filepath.Join(d, filepath.FromSlash(marker))) }
	if has(base) {
		return base, true
	}
	for _, c := range engineCandidates(base) {
		if c != "" && has(c) {
			return c, false
		}
	}
	return "", false
}

func isRegularFile(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.Mode().IsRegular()
}

func isDirPath(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

// ReadEngineVersion は engine の Makefile から VERSION := を読む。
// 読めなければ空文字（fail-open）。
func ReadEngineVersion(engine string) string {
	text, err := readTextPy(filepath.Join(engine, "Makefile"))
	if err != nil {
		return ""
	}
	for _, line := range pyFileLines(text) {
		if m := versionLineRe.FindStringSubmatch(line); m != nil {
			return m[1]
		}
	}
	return ""
}

// UseEnginePin は use-engine が flix.toml のエンジンの版を一時的に書き換えている間の
// (書き換えた版, 元の版)。控え lib/.use-engine/state.json が無いか、版を書き換えて
// いなければ ok = false。pre-commit（コミットを止める）と make status（1 行出す）が読む。
// WhyNot: useengine に置かないのは、useengine が status を使うので逆向きに引けないため。
func UseEnginePin(game string) (set, orig string, ok bool) {
	data, err := os.ReadFile(filepath.Join(game, "lib", ".use-engine", "state.json"))
	if err != nil {
		return "", "", false
	}
	var st struct {
		SetToml  string `json:"setTomlVersion"`
		OrigToml string `json:"origTomlVersion"`
	}
	if json.Unmarshal(data, &st) != nil || st.SetToml == "" {
		return "", "", false
	}
	return st.SetToml, st.OrigToml, true
}

// EnginePinOf はゲームの flix.toml の中身から、エンジンの依存の版を返す（無ければ ok = false）。
// make status と pre-commit が同じ読み方をするため、ここに 1 本だけ置く。
func EnginePinOf(toml string) (string, bool) {
	m := enginePinRe.FindStringSubmatch(toml)
	if m == nil {
		return "", false
	}
	return m[1], true
}
