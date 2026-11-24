package main

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/doclookup"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

func init() {
	register("api", "<名前> [--engine <dir>] で engine API の型・引数を 1 行ずつ引く（docs/api-digest・ソースを読む前にまずこれ）", cmdAPI)
	register("module", "<語> [--engine <dir>] でやりたいこと → engine のモジュールを 1 行ずつ引く（docs/modules）", cmdModule)
	register("src", "<名前> でゲームの src/ の pub 定義を 1 行ずつ引く（.flix を丸読みする前にまずこれ）", cmdSrc)
}

// lookupArgs は --engine <dir> と、残りを空白でつないだ問い（make の Q= と同じ 1 つの字）を分ける。
func lookupArgs(rest []string) (engine, q string) {
	var words []string
	for i := 0; i < len(rest); i++ {
		switch {
		case rest[i] == "--engine" && i+1 < len(rest):
			engine = rest[i+1]
			i++
		case strings.HasPrefix(rest[i], "--engine="):
			engine = strings.TrimPrefix(rest[i], "--engine=")
		case strings.HasPrefix(rest[i], "Q="):
			// WhyNot: Q= を問いの字に含めない — make の形（make api Q=…）をそのまま bin/fge に打っても同じ物を引く。
			words = append(words, strings.TrimPrefix(rest[i], "Q="))
		default:
			words = append(words, rest[i])
		}
	}
	return engine, strings.Join(words, " ")
}

// lookupEngine は引く先の engine の根と、行に付ける前置き（engine の根で打てば空・ゲームでは "<engine>/"）。
// WhyNot: repoRoot() だけで決めない — ゲームの bin/fge-go から見た親はゲームで、docs/ を持たない。
func lookupEngine(given string) (dir, prefix string) {
	if given != "" {
		return given, strings.TrimSuffix(filepath.ToSlash(given), "/") + "/"
	}
	cwd, _ := os.Getwd()
	if engine, self := status.FindEngineDir(cwd, "mk/common.mk"); engine != "" {
		if self {
			return engine, ""
		}
		return engine, strings.TrimSuffix(filepath.ToSlash(engine), "/") + "/"
	}
	return repoRoot(), ""
}

func cmdAPI(out, _ *strings.Builder, rest []string, _ bool) int {
	given, q := lookupArgs(dropJSONFlag(rest))
	engine, _ := lookupEngine(given)
	return doclookup.API(out, engine, q)
}

func cmdModule(out, _ *strings.Builder, rest []string, _ bool) int {
	given, q := lookupArgs(dropJSONFlag(rest))
	engine, prefix := lookupEngine(given)
	return doclookup.Module(out, engine, prefix, q)
}

func cmdSrc(out, _ *strings.Builder, rest []string, _ bool) int {
	_, q := lookupArgs(dropJSONFlag(rest))
	cwd, _ := os.Getwd()
	return doclookup.Src(out, cwd, q)
}
