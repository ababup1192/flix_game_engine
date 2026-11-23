package stageengine

// 外から取る物の種（Maven の取り物・flixlint）を入れる前の照合。

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
)

// checkSeed は種を入れる前に、配った先で取りに行かずに済む中身かを見る。種でない物は何もしない。
// WhyNot: 欠けた種をそのまま入れない — 一見入っているので、配った先の初回ビルドだけが外へ取りに行き、
// 続けて作ると Maven Central が 429 で止める。
func checkSeed(root string, it Item, src string) error {
	switch it.Src {
	case srcMvnCache:
		missing, err := MissingMavenJars(filepath.Join(root, "engine_full", "flix.toml"), src)
		if err != nil {
			return err
		}
		if len(missing) > 0 {
			return fmt.Errorf("%s (%s) に engine_full/flix.toml の Maven の jar がありません: %s",
				it.Src, src, strings.Join(missing, " "))
		}
	case srcFlixlint:
		r, err := hooks.LoadRules(root)
		if err != nil {
			return err
		}
		sv := r.Checkd.Server
		if sv.FlixlintVersion == nil || sv.ShimJar == nil || sv.ShimSHA256 == nil {
			return fmt.Errorf("%s を入れるには hooks.json の checkd.server に flixlintVersion・shimJar・shimSha256 が要る", it.Src)
		}
		dir := filepath.Join(src, *sv.FlixlintVersion)
		jar := filepath.Join(dir, *sv.ShimJar)
		if sum, err := FileSHA256(jar); err != nil || sum != *sv.ShimSHA256 {
			return fmt.Errorf("%s の %s が無いか、sha256 が hooks.json の checkd.server.shimSha256 と違う", it.Src, jar)
		}
		if _, err := os.Stat(filepath.Join(dir, "src", "bin", "flixlint")); err != nil {
			return fmt.Errorf("%s に flixlint の本体がありません (%s)", it.Src, filepath.Join(dir, "src", "bin", "flixlint"))
		}
	}
	return nil
}

var mvnDepRe = regexp.MustCompile(`^"([^":]+):([^":]+)"\s*=\s*"([^"]+)"`)

// MissingMavenJars は toml の [mvn-dependencies] のうち、cache（coursier の置き場の形）に jar が無い物を "group:artifact:版" で返す。
// WhyNot: 推移的に引く物までは見ない — POM を読んで解くのは coursier の仕事で、ここで解き直すと解き方が 2 つになる。
// 直に書いた物が揃っていれば、同じ解決で取った置き場と見なす。
func MissingMavenJars(toml, cache string) ([]string, error) {
	f, err := os.Open(toml)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	type dep struct{ coord, suffix string }
	var deps []dep
	in := false
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if strings.HasPrefix(line, "[") {
			in = line == "[mvn-dependencies]"
			continue
		}
		m := mvnDepRe.FindStringSubmatch(line)
		if !in || m == nil {
			continue
		}
		g, a, v := m[1], m[2], m[3]
		deps = append(deps, dep{g + ":" + a + ":" + v,
			"/" + strings.ReplaceAll(g, ".", "/") + "/" + a + "/" + v + "/" + a + "-" + v + ".jar"})
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	var jars []string
	err = filepath.WalkDir(cache, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() && strings.HasSuffix(p, ".jar") {
			jars = append(jars, filepath.ToSlash(p))
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	var missing []string
	for _, d := range deps {
		found := false
		for _, p := range jars {
			if strings.HasSuffix(p, d.suffix) {
				found = true
				break
			}
		}
		if !found {
			missing = append(missing, d.coord)
		}
	}
	return missing, nil
}

// FileSHA256 はファイルの sha256 を 16 進で返す。
func FileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
