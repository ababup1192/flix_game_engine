package fontbake

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// jarRevision は生成する入口の jar の作り方の版。mainSource か組み方を変えたら 1 上げる（前の jar を使い回さない）。
const jarRevision = 1

// Runner は、ゲームの lib にある engine で生成する入口（FontAtlasBake.main）の jar を組み、流す。
// WhyNot: ゲームの src を組まない — 生成するのに要るのは engine だけで、ゲームの src を足すとコンパイルが数倍になり、
// ゲームの型の誤りで書き出しごと止まる。WhyNot: headless-run を使わない — あれはゲームの src の入口しか拾わない。
type Runner struct {
	GameDir string
	FlixJar string
	Java    string
	Log     io.Writer
}

// Baked は入口が書いた 1 本（標準出力の fontatlas の行）。
type Baked struct {
	Name   string
	Path   string
	Side   int
	Glyphs int
}

func (r Runner) workDir() string { return filepath.Join(r.GameDir, "build", "font-bake") }

var mountRe = regexp.MustCompile(`flix_game_engine"\s*=\s*\{[^}]*mount\s*=\s*"([^"]+)"`)

// mountOf はゲームの flix.toml が engine を入れる mount の名前（無ければ fge）。
func mountOf(toml string) string {
	if m := mountRe.FindStringSubmatch(toml); m != nil {
		return m[1]
	}
	return "fge"
}

func mainSource(mount string) string {
	return "// font-bake が組む入口（bin/fge font-bake の生成物）。\n" +
		"use " + mount + "::FontAtlasBake\n\n" +
		"def main(): Unit \\ IO = FontAtlasBake.main()\n"
}

// jarKey は jar を組み直すかを決める指紋: 作り方の版・flix.toml・packages.lock・入口・flix.jar・lib の中身の一覧。
func (r Runner) jarKey(toml, lock, src string) string {
	h := sha256.New()
	fmt.Fprintf(h, "rev=%d\n%s\n--\n%s\n--\n%s\n", jarRevision, toml, lock, src)
	if info, err := os.Stat(r.FlixJar); err == nil {
		fmt.Fprintf(h, "flix.jar %s %d %d\n", r.FlixJar, info.Size(), info.ModTime().UnixNano())
	}
	lib := filepath.Join(r.GameDir, "lib")
	var rows []string
	_ = filepath.WalkDir(lib, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(lib, path)
		if d.IsDir() {
			if rel == "cache" {
				return filepath.SkipDir
			}
			return nil
		}
		if info, err := d.Info(); err == nil {
			rows = append(rows, fmt.Sprintf("%s %d %d", filepath.ToSlash(rel), info.Size(), info.ModTime().UnixNano()))
		}
		return nil
	})
	sort.Strings(rows)
	fmt.Fprintln(h, strings.Join(rows, "\n"))
	return hex.EncodeToString(h.Sum(nil))
}

// EnsureJar は生成する入口の jar を返す（指紋が同じなら前の物・違えば組み直す）。
func (r Runner) EnsureJar() (string, error) {
	tomlBytes, err := os.ReadFile(filepath.Join(r.GameDir, "flix.toml"))
	if err != nil {
		return "", fmt.Errorf("flix.toml が読めない: %w", err)
	}
	toml := string(tomlBytes)
	lockBytes, _ := os.ReadFile(filepath.Join(r.GameDir, "packages.lock"))
	src := mainSource(mountOf(toml))
	work := r.workDir()
	jar := filepath.Join(work, "font-bake.jar")
	keyFile := filepath.Join(work, "jar.key")
	key := r.jarKey(toml, string(lockBytes), src)
	if kept, err := os.ReadFile(keyFile); err == nil && strings.TrimSpace(string(kept)) == key {
		if _, err := os.Stat(jar); err == nil {
			return jar, nil
		}
	}
	proj := filepath.Join(work, "proj")
	if err := os.RemoveAll(proj); err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Join(proj, "src"), 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(proj, "flix.toml"), tomlBytes, 0o644); err != nil {
		return "", err
	}
	if len(lockBytes) > 0 {
		if err := os.WriteFile(filepath.Join(proj, "packages.lock"), lockBytes, 0o644); err != nil {
			return "", err
		}
	}
	if err := os.WriteFile(filepath.Join(proj, "src", "FontBakeMain.flix"), []byte(src), 0o644); err != nil {
		return "", err
	}
	lib := filepath.Join(r.GameDir, "lib")
	if err := os.MkdirAll(lib, 0o755); err != nil {
		return "", err
	}
	if err := os.Symlink(lib, filepath.Join(proj, "lib")); err != nil {
		return "", fmt.Errorf("lib を繋げない（%v）— Windows なら開発者モードか管理者で symlink を許してください", err)
	}
	fmt.Fprintln(r.Log, "[font-bake] 生成する入口の jar を組む（engine か flix.toml が変わった時だけ・1〜数分）")
	logPath := filepath.Join(work, "build.log")
	logFile, err := os.Create(logPath)
	if err != nil {
		return "", err
	}
	cmd := exec.Command(r.Java, "-Djava.awt.headless=true", "-jar", r.FlixJar, "build-fatjar")
	cmd.Dir = proj
	cmd.Stdin = nil
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	runErr := cmd.Run()
	logFile.Close()
	built, _ := filepath.Glob(filepath.Join(proj, "artifact", "*.jar"))
	if runErr != nil || len(built) == 0 {
		return "", fmt.Errorf("生成する入口の jar を組めない（%v）。%s の終わり:\n%s"+
			"\n（FontAtlasBake が無いと出るなら、ゲームの engine が古い — font-bake は engine 0.85.0 から）",
			runErr, logPath, tail(logPath, 15))
	}
	if err := os.Rename(built[0], jar); err != nil {
		return "", err
	}
	// 指紋は組み終えた後の lib から取り直す — 組む間に flix が lib へ依存を落とすので、組む前の指紋だと次の回にまた組む。
	if err := os.WriteFile(keyFile, []byte(r.jarKey(toml, string(lockBytes), src)+"\n"), 0o644); err != nil {
		return "", err
	}
	return jar, nil
}

// Bake は jar を流す。glyphs は「--all」「--used」か、字の集合のファイルのパス。
func (r Runner) Bake(jar, glyphs, outDir string) ([]Baked, error) {
	root, err := filepath.Abs(r.GameDir)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(r.Java, "-Djava.awt.headless=true", "-jar", jar, root, glyphs, outDir)
	cmd.Dir = root
	cmd.Stderr = r.Log
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	var baked []Baked
	sc := bufio.NewScanner(stdout)
	for sc.Scan() {
		line := sc.Text()
		f := strings.Split(line, "\t")
		if len(f) == 5 && f[0] == "fontatlas" {
			side, _ := strconv.Atoi(f[3])
			n, _ := strconv.Atoi(f[4])
			baked = append(baked, Baked{Name: f[1], Path: f[2], Side: side, Glyphs: n})
			continue
		}
		fmt.Fprintln(r.Log, line)
	}
	if err := cmd.Wait(); err != nil {
		return nil, fmt.Errorf("生成する入口が止まった（%v）", err)
	}
	return baked, nil
}

func tail(path string, n int) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
