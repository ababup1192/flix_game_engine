package scaffold

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/ababup1192/flix_game_engine/go/internal/exereplace"
	"github.com/ababup1192/flix_game_engine/go/internal/fpkgstore"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

// engine の中の置き場（Makefile の ENGINE_FULL_* と同じ）。
const (
	engineFullFpkgBundled = "engine_full/artifact/engine_full.fpkg"
	engineFullToml        = "engine_full/flix.toml"
)

// IsBundle は配った engine（Release の zip・Studio の同梱）か。配った版は Go のソース go/ を運ばない（Makefile の IS_BUNDLE と同じ見分け方）。
func IsBundle(engine string) bool {
	info, err := os.Stat(filepath.Join(engine, "go"))
	return err != nil || !info.IsDir()
}

// EngineVersion は engine の Makefile の VERSION。
func EngineVersion(engine string) (string, error) {
	v := status.ReadEngineVersion(engine)
	if v == "" {
		return "", fmt.Errorf("%s の Makefile に VERSION がありません", engine)
	}
	return v, nil
}

// EngineFull はゲームの lib へ写す engine_full の束と toml の置き場、写す先の名前。
type EngineFull struct {
	Fpkg, Toml         string
	Subpath            string
	FpkgName, TomlName string
}

// EngineFullFiles は engine からゲームへ写す束を決める。配った版は付け替えた engine_full.fpkg、作業コピーは置き場の今のエントリ。
//
// WhyNot: 作業コピーで置き場を 2 回引かない — 間に sync-engine-full が current を替えると、束と toml を別のエントリから取る。
func EngineFullFiles(engine, version string) (EngineFull, error) {
	ef := EngineFull{
		Subpath:  "lib/github/ababup1192/flix_game_engine/" + version,
		FpkgName: "flix_game_engine-" + version + ".fpkg",
		TomlName: "flix_game_engine-" + version + ".toml",
	}
	if IsBundle(engine) {
		ef.Fpkg = filepath.Join(engine, filepath.FromSlash(engineFullFpkgBundled))
		ef.Toml = filepath.Join(engine, filepath.FromSlash(engineFullToml))
		if _, err := os.Stat(ef.Fpkg); err != nil {
			return ef, fmt.Errorf("%s がありません（配った engine が欠けています。入れ直してください）", ef.Fpkg)
		}
		return ef, nil
	}
	entry, ok := fpkgstore.Current(engine, fpkgstore.EngineFull)
	if !ok {
		return ef, fmt.Errorf("置き場に engine_full がありません。make sync-engine-full")
	}
	ef.Fpkg = filepath.Join(entry, "package.fpkg")
	ef.Toml = filepath.Join(entry, "flix.toml")
	return ef, nil
}

// FgeGoSource は engine からゲームへ配る fge-go。配った版は同梱の bin/fge-go（取った時に機械に合う物へ選び直してある）、
// 作業コピーは make go-build が組んだ bin/dist/fge-go-<os>-<arch>。
func FgeGoSource(engine, goos, goarch string) string {
	ext := exeExt(goos)
	if IsBundle(engine) {
		return filepath.Join(engine, "bin", "fge-go"+ext)
	}
	return filepath.Join(engine, "bin", "dist", "fge-go-"+goos+"-"+goarch+ext)
}

func exeExt(goos string) string {
	if goos == "windows" {
		return ".exe"
	}
	return ""
}

// SyncFgeGo は機械に合う fge-go を 1 つだけゲームの bin/ へ置き、置いた 1 行を返す。
func SyncFgeGo(engine, game, goos, goarch string) (string, error) {
	src := FgeGoSource(engine, goos, goarch)
	if _, err := os.Stat(src); err != nil {
		if IsBundle(engine) {
			return "", fmt.Errorf("[sync-fge-go] %s がありません（配った engine が欠けています）", src)
		}
		return "", fmt.Errorf("[sync-fge-go] %s がありません (make go-build)", src)
	}
	dest := filepath.Join(game, "bin", "fge-go"+exeExt(goos))
	if err := exereplace.Copy(src, dest, goos); err != nil {
		return "", fmt.Errorf("[sync-fge-go] %s を置けません: %v", dest, err)
	}
	return fmt.Sprintf("[sync-fge-go] %s → %s", src, dest), nil
}
