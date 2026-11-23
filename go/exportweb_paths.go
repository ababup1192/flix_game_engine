package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/fpkgstore"
	"github.com/ababup1192/flix_game_engine/go/internal/javacmd"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

// exportWebPaths は 1 回の書き出しで使う道の一式。
type exportWebPaths struct {
	Game, Engine, Version, Work, Project, Out                                       string
	FullWebFpkg, FullWebToml, GlJar, WebJar, WebToolsJar, WebJS, IndexHTML, FlixJar string
	// 置き場（build/fpkg-store）のエントリ。空なら置き場が無く、build/engine_full_web などを直に読んでいる。
	FullWebEntry string
	// AppIcon は project.json の web.appIcon の絶対の道（空なら engine のロゴでホーム画面のアイコンを作る）。
	AppIcon string
}

// resolveExportWebPaths は道を決め、要る物が揃っているかを見る。足りなければ終わりの番号 2 と次の 1 手。
func resolveExportWebPaths(o exportWebOptions) (exportWebPaths, int, error) {
	var p exportWebPaths
	game, err := filepath.Abs(o.Game)
	if err != nil || !dirExists(game) {
		return p, 2, fmt.Errorf("ゲームのフォルダが無い: %s", o.Game)
	}
	p.Game = game
	if !fileExists(filepath.Join(game, "web", "WebMain.flix")) {
		return p, 2, fmt.Errorf("web/WebMain.flix が無い（%s）。\n  次: テンプレートの web/WebMain.flix を写して入口を書く", game)
	}
	toml, err := os.ReadFile(filepath.Join(game, "flix.toml"))
	if err != nil {
		return p, 2, fmt.Errorf("flix.toml を読めない: %v", err)
	}
	p.Version = engineVersionFromToml(string(toml))
	if p.Version == "" {
		return p, 2, errors.New(`flix.toml に "github:ababup1192/flix_game_engine" = { version = "…" } が無い。` +
			"\n  次: engine を使うゲームのフォルダを渡す")
	}

	p.Engine = o.Engine
	if p.Engine == "" {
		p.Engine = engineDirOf(repoRoot())
	}
	if p.Engine, err = filepath.Abs(p.Engine); err != nil || !fileExists(filepath.Join(p.Engine, "mk", "game.mk")) {
		return p, 2, fmt.Errorf("engine の根が見つからない（%s）。\n  次: --engine <engine のフォルダ> を渡す", p.Engine)
	}
	p.FlixJar = os.Getenv("FLIX_JAR")
	if p.FlixJar == "" {
		p.FlixJar = filepath.Join(p.Engine, "bin", "flix.jar")
	}

	v := p.Version
	if code, err := ensureFullWebFresh(p.Engine, v); err != nil {
		return p, code, err
	}
	// WhyNot: build/engine_full_web と build/gl-jar・build/web-jar を直に読まない — 別の所で make sync-engine-full-web が走ると、
	// 書き出しの途中（TeaVM は数分後に fge-web-tools を読む）で中身が書き換わる。置き場のエントリは置いた後は変わらない。
	// 置き場が無い engine（配った版・置き場を作る前の作業コピー）だけ前の置き場を読む。
	if entry, ok := fpkgstore.Current(p.Engine, fpkgstore.EngineFullWeb); ok {
		p.FullWebEntry = entry
		p.FullWebFpkg = filepath.Join(entry, "package.fpkg")
		p.FullWebToml = filepath.Join(entry, "flix.toml")
		p.GlJar = filepath.Join(entry, glJarNameOf(p.FullWebToml, v))
		p.WebJar = filepath.Join(entry, "fge-web-"+v+".jar")
		p.WebToolsJar = filepath.Join(entry, "fge-web-tools-"+v+".jar")
	} else {
		p.FullWebFpkg = filepath.Join(p.Engine, "build", "engine_full_web", "artifact", "package.fpkg")
		p.FullWebToml = filepath.Join(p.Engine, "build", "engine_full_web", "flix.toml")
		p.GlJar = filepath.Join(p.Engine, "build", "gl-jar", glJarNameOf(p.FullWebToml, v))
		p.WebJar = filepath.Join(p.Engine, "build", "web-jar", "fge-web-"+v+".jar")
		p.WebToolsJar = filepath.Join(p.Engine, "build", "web-jar", "fge-web-tools-"+v+".jar")
	}
	p.WebJS = filepath.Join(p.Engine, "engine_web", "js", "fge-web.js")
	p.IndexHTML = filepath.Join(p.Engine, "engine_web", "js", "index.html")
	var missing []string
	for _, f := range []string{p.FullWebFpkg, p.FullWebToml, p.GlJar, p.WebJar, p.WebToolsJar} {
		if !fileExists(f) {
			missing = append(missing, f)
		}
	}
	if len(missing) > 0 {
		hint := "engine の根で make sync-engine-full-web を流す"
		if ev := status.ReadEngineVersion(p.Engine); ev != "" && ev != v {
			hint += fmt.Sprintf("（engine は %s・ゲームは %s。版をそろえる）", ev, v)
		}
		return p, 2, fmt.Errorf("engine_full_web の物が無い:\n  %s\n  次: %s", strings.Join(missing, "\n  "), hint)
	}
	for _, f := range []string{p.FlixJar, p.WebJS, p.IndexHTML} {
		if !fileExists(f) {
			return p, 2, fmt.Errorf("%s が無い。\n  次: engine の作業コピーを確かめる（flix.jar なら FLIX_JAR で名指しできる）", f)
		}
	}

	p.Work = o.Work
	if p.Work == "" {
		p.Work = filepath.Join(game, "build", "web-export")
	}
	p.Out = o.Out
	if p.Out == "" {
		p.Out = filepath.Join(game, "build", "web")
	}
	if p.Work, err = filepath.Abs(p.Work); err != nil {
		return p, 2, err
	}
	if p.Out, err = filepath.Abs(p.Out); err != nil {
		return p, 2, err
	}
	p.Project = filepath.Join(p.Work, "project")
	if isWithin(p.Work, game) != "" || isWithin(p.Out, game) != "" {
		return p, 2, errors.New("--work・--out にゲームのフォルダそのものか、その上のフォルダは渡せない（消して作り直すため）")
	}
	return p, 0, nil
}

var engineDepRe = regexp.MustCompile(`"github:ababup1192/flix_game_engine"\s*=\s*\{[^}]*?\bversion\s*=\s*"([^"]+)"`)

// engineVersionFromToml はゲームの flix.toml が使う engine の版。無ければ空。
func engineVersionFromToml(toml string) string {
	for _, line := range strings.Split(toml, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if m := engineDepRe.FindStringSubmatch(line); m != nil {
			return m[1]
		}
	}
	return ""
}

// isWithin は child が parent の中（同じも含む）なら parent から見た道、外なら空。
func isWithin(parent, child string) string {
	rel, err := filepath.Rel(parent, child)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return ""
	}
	return rel
}

// exportWebJava は java の呼び方（javacmd.Resolve: JAVA → PATH の動く java → engine の devbox の jdk → main の checkout の物）。
func exportWebJava(engine string) (string, error) {
	return javacmd.Resolve(engine)
}

var glJarDepRe = regexp.MustCompile(`^\s*"(fge-gl-[^"]+\.jar)"\s*=`)

// glJarNameOf は、組む flix.toml の [jar-dependencies] が宣言する GL の層の jar の名前を返す。
// WhyNot: 名前を版から組み立てない — jar の置き場は render_gl/java の中身のハッシュで名付け、版とは別に変わる。
// 宣言と違う名前で lib/external に置くと、Flix が置き場のリリースへ取りに行く。
func glJarNameOf(toml, version string) string {
	b, err := os.ReadFile(toml)
	if err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			if m := glJarDepRe.FindStringSubmatch(line); m != nil {
				return m[1]
			}
		}
	}
	return "fge-gl-" + version + ".jar"
}
