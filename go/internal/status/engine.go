package status

// engine の場所とバージョンの解決。
//
// 解決順は 環境変数 ENGINE → local.mk。呼ぶ側は置き場（local.mk を探すディレクトリ）
// だけを渡す。
//
// WhyNot: 呼ぶ側ごとに解決を書かないのは、同じ順で読まないと fge と status で
// 見ている engine が食い違うため。

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// 「先頭の空白 ENGINE 空白 [?:]* = 空白 値」。値の末尾の空白は落とす。
var engineLineRe = compilePySpace(`^\s*ENGINE\s*[?:]*=\s*(.+?)\s*$`)

// Makefile の「VERSION := 値」。
var versionLineRe = compilePySpace(`^VERSION\s*:=\s*(\S+)`)

// ReadEngineDir は base（ゲームのリポの根）から見た engine の場所。
// 環境変数 ENGINE → base/local.mk の順で読む。見つからなければ空文字。
func ReadEngineDir(base string) string {
	if v := os.Getenv("ENGINE"); v != "" {
		return v
	}
	text, err := readTextPy(filepath.Join(base, "local.mk"))
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

// FindEngineDir は base（リポの根）から見た engine の根と、それが base 自身かを返す。
// 探す順: base に marker（mk/game.mk など engine にだけある物）があれば base 自身（engine のリポ）
// → 環境変数 ENGINE → base/local.mk の ENGINE → base/Makefile の ENGINE（`ENGINE ?= ../..` の既定）。
// 相対パスは base から読む。marker が実在する最初の候補を返し、どれも無ければ空文字。
//
// WhyNot: lint ごとに探し方を書かないのは、makefile-dup（game.mk）と doc-shape
// （docs/<種類>.schema.json）で見ている engine が食い違わないようにするため。
func FindEngineDir(base, marker string) (dir string, self bool) {
	has := func(d string) bool {
		info, err := os.Stat(filepath.Join(d, filepath.FromSlash(marker)))
		return err == nil && info.Mode().IsRegular()
	}
	if has(base) {
		return base, true
	}
	cands := []string{ReadEngineDir(base)}
	if text, err := readTextPy(filepath.Join(base, "Makefile")); err == nil {
		for _, line := range pyFileLines(text) {
			if m := engineLineRe.FindStringSubmatch(line); m != nil {
				cands = append(cands, m[1])
				break
			}
		}
	}
	for _, c := range cands {
		if c == "" {
			continue
		}
		if !filepath.IsAbs(c) {
			c = filepath.Join(base, c)
		}
		if has(c) {
			return c, false
		}
	}
	return "", false
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
