package refactor

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

// Name は規約ファイルの名前（bin/lint-rules/<Name>.json と <Name>.local.json）。
const Name = "refactor"

// Config は道具の設定。engine が配る refactor.json の上に、ゲームの refactor.local.json で書いた欄だけを重ねる。
type Config struct {
	Note string `json:"note,omitempty"`
	// Flixlint は bin/flixlint の場所（根からの相対か絶対）。空なら flixlint/bin/flixlint（submodule）→ PATH。
	Flixlint string `json:"flixlint,omitempty"`
	// FlixJar は flix.jar の場所。空なら FLIX_JAR → engine の bin/flix.jar → flixlint の bin/flix-jar に任せる。
	FlixJar string `json:"flixJar,omitempty"`
	// Sources は索引に入れるフォルダ（在る物だけ使う）。
	Sources []string `json:"sources,omitempty"`
	// Verify は書き換えの後に流す確かめの口（--apply の後。expand-wildcard など）。
	Verify string `json:"verify,omitempty"`
	// VerifyTests は def を消した後の確かめ（remove-dead。テストも消すのでテストまで流す）。
	VerifyTests string `json:"verifyTests,omitempty"`
	// TestDirs はテストのフォルダ（remove-dead が「テストからだけ参照される」を決める）。
	TestDirs []string `json:"testDirs,omitempty"`
	// Library は fpkg で配るライブラリか（true・false・"auto"）。auto（既定）は flix.toml の [package] に repository が
	// ある時（パッケージとして出す物）にライブラリと見る。ライブラリでは remove-dead が pub の def を消さない。
	Library LibraryMode `json:"library,omitempty"`
	// JavaOpts は flixlint の JVM に渡す物（空なら flixlint の既定）。
	JavaOpts string `json:"javaOpts,omitempty"`
}

// defaults は設定ファイルが 1 つも無い時の値（配る refactor.json と同じ）。
func defaults() Config {
	return Config{Sources: []string{"src", "test"}, Verify: "make check", VerifyTests: "make test", TestDirs: []string{"test"}}
}

// LoadConfig は root の bin/lint-rules/refactor.json と refactor.local.json を重ねて読む。
// どちらも無ければ既定値（まだ追随していないゲームでも読むだけの操作は動く）。
func LoadConfig(root string) (Config, error) {
	c := defaults()
	for _, name := range []string{Name + ".json", Name + ".local.json"} {
		path := filepath.Join(root, "bin", "lint-rules", name)
		data, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return c, err
		}
		var over Config
		if err := json.Unmarshal(data, &over); err != nil {
			return c, fmt.Errorf("JSON として壊れています (%s): %v", path, err)
		}
		c = c.with(over)
	}
	return c, nil
}

// with は over の空でない欄だけを重ねた設定を返す。
func (c Config) with(over Config) Config {
	if over.Flixlint != "" {
		c.Flixlint = over.Flixlint
	}
	if over.FlixJar != "" {
		c.FlixJar = over.FlixJar
	}
	if len(over.Sources) > 0 {
		c.Sources = over.Sources
	}
	if over.Verify != "" {
		c.Verify = over.Verify
	}
	if over.VerifyTests != "" {
		c.VerifyTests = over.VerifyTests
	}
	if len(over.TestDirs) > 0 {
		c.TestDirs = over.TestDirs
	}
	if over.Library != "" {
		c.Library = over.Library
	}
	if over.JavaOpts != "" {
		c.JavaOpts = over.JavaOpts
	}
	return c
}

// abs は根からの相対を絶対にする。
func abs(root, p string) string {
	if p == "" || filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(root, p)
}

// FindFlixlint は bin/flixlint を探す: --flixlint → FGE_FLIXLINT → 設定の flixlint → 根の flixlint/bin/flixlint → PATH。
func FindFlixlint(root, flag string, c Config) (string, error) {
	var tried []string
	for _, p := range []string{flag, os.Getenv("FGE_FLIXLINT"), abs(root, c.Flixlint), filepath.Join(root, "flixlint", "bin", "flixlint")} {
		if p == "" {
			continue
		}
		p = abs(root, p)
		if info, err := os.Stat(p); err == nil && !info.IsDir() {
			return p, nil
		}
		tried = append(tried, p)
	}
	if p := LookPath("flixlint"); p != "" {
		return p, nil
	}
	return "", fmt.Errorf("flixlint が見つかりません（見た所: %s・PATH）。--flixlint <bin/flixlint> か "+
		"bin/lint-rules/refactor.local.json の \"flixlint\" で名指ししてください（https://github.com/ababup1192/flixlint）",
		strings.Join(tried, "・"))
}

// FindFlixJar は flix.jar を探す: 設定の flixJar → FLIX_JAR → engine の bin/flix.jar → flixlint の bin/flix-jar。
// 見つからなければ ""（flixlint に任せる）。
//
// WhyNot: flixlint に黙って任せないのは、索引の鍵に jar を入れるため（PATH の flix が替わっても古い索引を使わない）。
func FindFlixJar(root, flixlint string, c Config) string {
	for _, p := range []string{abs(root, c.FlixJar), os.Getenv("FLIX_JAR")} {
		if p != "" {
			if info, err := os.Stat(p); err == nil && !info.IsDir() {
				return p
			}
		}
	}
	if dir, _ := status.FindEngineDir(root, "bin/flix.jar"); dir != "" {
		return abs(root, filepath.Join(dir, "bin", "flix.jar"))
	}
	if real, err := filepath.EvalSymlinks(flixlint); err == nil {
		if b, err := exec.Command(filepath.Join(filepath.Dir(real), "flix-jar")).Output(); err == nil {
			if p := strings.TrimSpace(string(b)); p != "" {
				return p
			}
		}
	}
	return ""
}

// LibraryMode は library の値（"true"・"false"・"auto"。空は auto）。JSON では true・false・"auto" と書く。
type LibraryMode string

func (m *LibraryMode) UnmarshalJSON(b []byte) error {
	switch s := strings.TrimSpace(string(b)); s {
	case "true", "false":
		*m = LibraryMode(s)
	case `"auto"`:
		*m = "auto"
	default:
		return fmt.Errorf("library は true・false・\"auto\" のどれか: %s", s)
	}
	return nil
}

var repositoryLine = regexp.MustCompile(`(?m)^\s*repository\s*=`)

// IsLibrary は root が fpkg で配るライブラリか（設定の library。auto なら flix.toml に repository があるか）。
//
// WhyNot: engine の refactor.json に true と書かないのは、bin/lint-rules はゲームへ配られ、ゲームまで
// ライブラリ扱いになるため。パッケージとして出す物だけが flix.toml に repository を持つので、そこで見分ける。
func IsLibrary(root string, c Config) bool {
	switch c.Library {
	case "true":
		return true
	case "false":
		return false
	}
	data, err := os.ReadFile(filepath.Join(root, "flix.toml"))
	return err == nil && repositoryLine.Match(data)
}
