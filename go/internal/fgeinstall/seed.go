package fgeinstall

import (
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
	"github.com/ababup1192/flix_game_engine/go/internal/mvncache"
	"github.com/ababup1192/flix_game_engine/go/internal/stageengine"
)

// SeedCaches は配った engine に入っている、外から取る物の種（bin/lint-rules/stage-engine.json の @flixlint・@mvn-cache）を
// それぞれの置き場へ写し、人へ見せる行を返す。置き場に既にある物は触らない。
//
// WhyNot: 写せなくても止めない — 種が無くても、使う時に今まで通り取りに行くだけで、engine は使える。
func SeedCaches(engineDir string) []string {
	var lines []string
	if line, err := seedFlixlint(engineDir); err != nil {
		lines = append(lines, fmt.Sprintf("flixlint の同梱を置き場へ写せませんでした（使う時に取りに行きます）: %v", err))
	} else if line != "" {
		lines = append(lines, line)
	}
	// WhyNot: Windows では写さない — ゲームの lib/cache は共有の置き場への symlink にならず（開発者モードでないと張れない）、
	// 置き場に写しても誰も読まない。ゲームを作る時に engine の lib/cache をそのゲームへ写す道（scaffold の seedLib）だけで足りる。
	if runtime.GOOS != "windows" {
		n, err := mvncache.Seed(filepath.Join(engineDir, "lib", "cache"))
		switch {
		case err != nil:
			lines = append(lines, fmt.Sprintf("Maven の取り物の同梱を共有の置き場へ写せませんでした（初回ビルドで取りに行きます）: %v", err))
		case n > 0:
			dir, _ := mvncache.Dir()
			lines = append(lines, fmt.Sprintf("Maven の取り物 %d 件を同梱から共有の置き場 %s へ写しました", n, relHome(dir)))
		}
	}
	return lines
}

// seedFlixlint は <engine>/cache/flixlint/<版>/ の shim の jar と本体を hooks.FlixlintDir へ写す。
func seedFlixlint(engineDir string) (string, error) {
	r, err := hooks.LoadRules(engineDir)
	if err != nil {
		return "", nil
	}
	sv := r.Checkd.Server
	dest := hooks.FlixlintDir(r)
	if dest == "" || sv.ShimJar == nil || sv.ShimSHA256 == nil {
		return "", nil
	}
	from := filepath.Join(engineDir, "cache", "flixlint", *sv.FlixlintVersion)
	if _, err := os.Stat(from); err != nil {
		return "", nil
	}
	var placed []string
	jar := filepath.Join(dest, *sv.ShimJar)
	if sum, err := stageengine.FileSHA256(jar); err != nil || sum != *sv.ShimSHA256 {
		src := filepath.Join(from, *sv.ShimJar)
		// WhyNot: sha256 が合わない同梱を置かない — 置くと ShimJar が取り直さずに使い続ける物が、hooks.json の決めた物と違う。
		if sum, err := stageengine.FileSHA256(src); err != nil || sum != *sv.ShimSHA256 {
			return "", fmt.Errorf("同梱の %s の sha256 が hooks.json の checkd.server.shimSha256 と違う", src)
		}
		if err := copyTreeVia(src, jar); err != nil {
			return "", err
		}
		placed = append(placed, "shim の jar")
	}
	if _, err := os.Stat(filepath.Join(dest, "src", "bin", "flixlint")); err != nil {
		if err := copyTreeVia(filepath.Join(from, "src"), filepath.Join(dest, "src")); err != nil {
			return "", err
		}
		placed = append(placed, "本体")
	}
	if len(placed) == 0 {
		return "", nil
	}
	return fmt.Sprintf("flixlint %s（%s）を同梱から %s に置きました", *sv.FlixlintVersion, strings.Join(placed, "・"), relHome(dest)), nil
}

// copyTreeVia は from（ファイルかフォルダ）を to の隣の .part に写してから名前を替える。
// WhyNot: to へ直に写さない — 途中で止まると、ShimJar と prepareFlixlint が「在る」と見て欠けた物を使い続ける。
func copyTreeVia(from, to string) error {
	part := to + ".part"
	_ = os.RemoveAll(part)
	if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
		return err
	}
	err := filepath.WalkDir(from, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(from, p)
		target := filepath.Join(part, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		if !d.Type().IsRegular() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		// WhyNot: 元の許可のまま写さない — 配った engine は読み取り専用で開くので、写した物も消せなくなる。
		return copyRegular(p, target, info.Mode().Perm()|0o200)
	})
	if err != nil {
		_ = os.RemoveAll(part)
		return err
	}
	_ = os.RemoveAll(to)
	return os.Rename(part, to)
}

func copyRegular(from, to string, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
		return err
	}
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
