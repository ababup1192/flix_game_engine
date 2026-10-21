package refactor

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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
	// Verify は書き換えの後に流す確かめの口（段 1 の --apply から使う）。
	Verify string `json:"verify,omitempty"`
	// JavaOpts は flixlint の JVM に渡す物（空なら flixlint の既定）。
	JavaOpts string `json:"javaOpts,omitempty"`
}

// defaults は設定ファイルが 1 つも無い時の値（配る refactor.json と同じ）。
func defaults() Config {
	return Config{Sources: []string{"src", "test"}, Verify: "make check"}
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
