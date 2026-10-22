package refactor

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
)

// flix.jar の版を flix.toml の版に合わせる（索引の flixlint と、--apply の後の make check の両方）。
//
// 見つけた jar（設定の flixJar・FLIX_JAR・make check の常駐の jar・engine の bin/flix.jar・PATH の flix）の版が
// flix.toml の `flix = "…"` と違えば、nix の store（/nix/store/*-flix-<版>/share/java/flix/flix.jar）と Studio の
// engines（~/.flix_ge_studio/engines/<engine の版>/bin/flix.jar。engine_full/flix.toml の flix が同じ物）から同じ版の jar を
// 探して使い、FLIX_JAR にも入れる（make check が通る engine の bin/flix は FLIX_JAR を最優先で使う）。
// 設定の flixJar と FLIX_JAR で名指しした jar は差し替えない（人の決め）。見つからなければ、索引が落ちた時に
// 「使っている flix は X（パス）・要るのは Y。FLIX_JAR=… を前に置く」と直し方を出す。
//
// WhyNot: 版は jar の中の印（MANIFEST）に無いので `java -jar <jar> --version` で読む（0.2 秒・1 回の実行で jar ごとに 1 回）。

// FlixJarChoice は使う flix.jar と、知らせる 1 行・版が合わない時の直し方。
type FlixJarChoice struct {
	Jar      string
	Note     string // 自動で別の jar を選んだ時の 1 行（空なら何も言わない）
	Mismatch string // 版が合わないまま使う時の直し方（索引が落ちた時に出す）
	Picked   bool   // 自動で選び直した（FLIX_JAR に入れる）
}

var (
	flixVersionMu sync.Mutex
	flixVersions  = map[string]string{}
	// 差し替えのテストの口（java を立てずに版を返す）。
	flixJarVersion = javaFlixVersion
	flixJarRoots   = defaultFlixJarRoots
)

var flixVersionLine = regexp.MustCompile(`\b(\d+\.\d+\.\d+)\b`)

// javaFlixVersion は `java -jar jar --version` の版（読めなければ ""）。
func javaFlixVersion(jar string) string {
	flixVersionMu.Lock()
	defer flixVersionMu.Unlock()
	if v, ok := flixVersions[jar]; ok {
		return v
	}
	out, _ := exec.Command("java", "-jar", jar, "--version").CombinedOutput()
	v := ""
	if m := flixVersionLine.FindStringSubmatch(string(out)); m != nil && strings.Contains(string(out), "Flix") {
		v = m[1]
	}
	flixVersions[jar] = v
	return v
}

var tomlFlixLine = regexp.MustCompile(`(?m)^\s*flix\s*=\s*"([^"]+)"`)

// wantedFlix は root/flix.toml の flix の版（無ければ ""）。
func wantedFlix(root string) string {
	b, err := os.ReadFile(filepath.Join(root, "flix.toml"))
	if err != nil {
		return ""
	}
	if m := tomlFlixLine.FindSubmatch(b); m != nil {
		return string(m[1])
	}
	return ""
}

// defaultFlixJarRoots は同じ版の jar を探す所（nix の store・Studio の engines）。
func defaultFlixJarRoots() (nix []string, engines string) {
	nix, _ = filepath.Glob("/nix/store/*-flix-*/share/java/flix/flix.jar")
	if home, err := os.UserHomeDir(); err == nil {
		engines = filepath.Join(home, ".flix_ge_studio", "engines")
	}
	return nix, engines
}

// flixJarCandidates は版 want の jar の候補（nix の store が先・Studio の engines は新しい版から）。
func flixJarCandidates(want string) []string {
	nix, engines := flixJarRoots()
	var out []string
	for _, p := range nix {
		if strings.Contains(p, "-flix-"+want+"/") {
			out = append(out, p)
		}
	}
	if engines != "" {
		dirs, _ := os.ReadDir(engines)
		var vs []string
		for _, d := range dirs {
			if b, err := os.ReadFile(filepath.Join(engines, d.Name(), "engine_full", "flix.toml")); err == nil {
				if m := tomlFlixLine.FindSubmatch(b); m != nil && string(m[1]) == want {
					vs = append(vs, d.Name())
				}
			}
		}
		sort.Slice(vs, func(i, j int) bool { return versionAtLeast(vs[i], vs[j]) && vs[i] != vs[j] })
		for _, v := range vs {
			out = append(out, filepath.Join(engines, v, "bin", "flix.jar"))
		}
	}
	return out
}

// ChooseFlixJar は使う flix.jar を決める。shared は make check の常駐の jar（空なら無し）。
func ChooseFlixJar(root, flixlint string, c Config, shared string) FlixJarChoice {
	jar, from := "", ""
	switch {
	case c.FlixJar != "" && isFileAt(abs(root, c.FlixJar)):
		jar, from = abs(root, c.FlixJar), "設定の flixJar"
	case os.Getenv("FLIX_JAR") != "" && isFileAt(os.Getenv("FLIX_JAR")):
		jar, from = os.Getenv("FLIX_JAR"), "FLIX_JAR"
	case shared != "":
		jar, from = shared, "make check の常駐の jar"
	default:
		jar, from = FindFlixJar(root, flixlint, c), "engine の bin/flix.jar か PATH の flix"
	}
	want := wantedFlix(root)
	if want == "" || jar == "" {
		return FlixJarChoice{Jar: jar}
	}
	got := flixJarVersion(jar)
	if got == "" || got == want {
		return FlixJarChoice{Jar: jar}
	}
	named := from == "設定の flixJar" || from == "FLIX_JAR"
	if !named {
		for _, cand := range flixJarCandidates(want) {
			if isFileAt(cand) && flixJarVersion(cand) == want {
				return FlixJarChoice{Jar: cand, Picked: true,
					Note: fmt.Sprintf("[refactor] flix.toml は flix %s・%s（%s）は %s なので、%s の jar を使います: %s（--apply の make check にも FLIX_JAR で渡す）", want, from, jar, got, want, cand)}
			}
		}
	}
	fix := fmt.Sprintf("FLIX_JAR=<flix %s の flix.jar> を前に置いて流し直す（nix なら /nix/store/<hash>-flix-%s/share/java/flix/flix.jar。devbox の flix を上げれば要らなくなる）", want, want)
	if named {
		fix = fmt.Sprintf("%s を flix %s の jar に替える", from, want)
	}
	return FlixJarChoice{Jar: jar, Mismatch: fmt.Sprintf("使っている flix は %s（%s・%s）・このプロジェクトの flix.toml は %s。%s", got, jar, from, want, fix)}
}

func isFileAt(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}
