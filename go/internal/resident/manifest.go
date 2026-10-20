package resident

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// ManifestFile は jar を作った時の中身の指紋を置く所（ゲームの根からの相対）。
var ManifestFile = filepath.Join("build", "headless", "jar.manifest")

// DispatcherFile は bin/headless-run が jar を作る写し（build/headless/proj）の src に足す入口の束。
// 指紋に入れない — ゲームの src には無いので、写しから取った指紋とゲームの根から取った指紋がずれる。
const DispatcherFile = "src/FgeHeadlessMain.flix"

// maxLinkDepth は lib の中で symlink を辿る深さの上限（輪になった symlink で止まらないため）。
const maxLinkDepth = 32

// BuildManifest は jar の中身を決める物（src・flix.toml・lib）の指紋を 64 字で返す。
//
// WhyNot: 更新時刻を使わないのは、checkd が macOS の見回りの遅れで書き換え前のソースを
// 検査して緑を返したのと同じく、時刻は中身が変わった証にならないため。
// WhyNot: java と java の旗（JAVA・HEADLESS_JAVA_OPTS）を混ぜないのは、それで jar の中身は変わらず、
// 混ぜると Studio のプレビュー（Studio の java・-Xmx1g）と端末の make render（PATH の java・旗なし）を
// 交互に使うたびに jar を作り直すため。常駐が同じ java と旗で起きたかは EnvMismatch が見る。
//
// lib/github/<持ち主>/<名前>/<版>/ は、flix.toml か packages.lock に名前のある版だけを入れる。
// WhyNot: lib の全部を見ないのは、版を上げた後も古い版（0.35〜0.51 など）が lib に残り、どれかを消す・
// 取り直すだけで、jar の中身に関わらないのに作り直しになるため。
func BuildManifest(root string) (string, error) {
	h := sha256.New()
	used := usedGithubVersions(root)
	for _, part := range []string{"src", "flix.toml", "lib"} {
		files, err := listFiles(root, part)
		if err != nil {
			return "", err
		}
		for _, rel := range files {
			if rel == DispatcherFile || !libFileUsed(rel, used) {
				continue
			}
			sum, err := fileSHA(filepath.Join(root, filepath.FromSlash(rel)))
			if err != nil {
				return "", err
			}
			fmt.Fprintf(h, "%s\x00%s\n", rel, sum)
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

var (
	tomlGithubDep = regexp.MustCompile(`"github:([^"]+)"\s*=\s*\{[^}]*version\s*=\s*"([^"]+)"`)
	lockGithubDep = regexp.MustCompile(`\[packages\."github:([^"]+)"\."([^"]+)"\]`)
)

// usedGithubVersions は flix.toml と packages.lock が名を挙げる github の依存（"持ち主/名前/版"）。
func usedGithubVersions(root string) map[string]bool {
	used := map[string]bool{}
	for _, f := range []struct {
		name string
		re   *regexp.Regexp
	}{{"flix.toml", tomlGithubDep}, {"packages.lock", lockGithubDep}} {
		raw, err := os.ReadFile(filepath.Join(root, f.name))
		if err != nil {
			continue
		}
		for _, m := range f.re.FindAllStringSubmatch(string(raw), -1) {
			used[m[1]+"/"+m[2]] = true
		}
	}
	return used
}

// libFileUsed は lib の中のファイルを指紋に入れるか（lib/github/<持ち主>/<名前>/ の下は used にある版のフォルダの中だけ。
// 版のフォルダの外に置かれた物も flix は読まない）。
func libFileUsed(rel string, used map[string]bool) bool {
	parts := strings.Split(rel, "/")
	if len(parts) < 5 || parts[0] != "lib" || parts[1] != "github" {
		return true
	}
	return len(parts) >= 6 && used[parts[2]+"/"+parts[3]+"/"+parts[4]]
}

// BuildSourceManifest は、jar の中身を決める元（src・flix.toml・packages.lock）の指紋（64 字）。lib の中身は見ない。
// packages.lock が無ければ error（依存の中身を決められない）。
//
// WhyNot: BuildManifest（lib の中身まで見る）を使わない — 新しい作業場では lib を jar を作る途中で flix が落とすので、
// 作る前と作った後で指紋が変わり、同じ機械の作業場どうしで jar を分け合う鍵（jarshare）がそろわない。
// lib/github の中身は packages.lock が toml と fpkg の SHA-256 で決め、lib/external（Maven の jar）は lock された toml の
// 版で決まる（同じ版の中身は変わらない）ので、lock の中身で足りる。
func BuildSourceManifest(root string) (string, error) {
	lock := filepath.Join(root, "packages.lock")
	if _, err := os.Stat(lock); err != nil {
		return "", fmt.Errorf("packages.lock が無い: %w", err)
	}
	h := sha256.New()
	for _, part := range []string{"src", "flix.toml", "packages.lock"} {
		files, err := listFiles(root, part)
		if err != nil {
			return "", err
		}
		for _, rel := range files {
			if rel == DispatcherFile {
				continue
			}
			sum, err := fileSHA(filepath.Join(root, filepath.FromSlash(rel)))
			if err != nil {
				return "", err
			}
			fmt.Fprintf(h, "%s\x00%s\n", rel, sum)
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// listFiles は root/part の下の全ファイルを、根からの相対パス（/ 区切り）の字の順で返す。
// part が無ければ空。symlink は先を辿る。
func listFiles(root, part string) ([]string, error) {
	var out []string
	var walk func(abs, rel string, depth int) error
	walk = func(abs, rel string, depth int) error {
		info, err := os.Stat(abs)
		if err != nil {
			if os.IsNotExist(err) && rel == part {
				return nil
			}
			return err
		}
		if !info.IsDir() {
			out = append(out, rel)
			return nil
		}
		if depth > maxLinkDepth {
			return fmt.Errorf("%s: フォルダが深すぎる（symlink の輪？）", rel)
		}
		entries, err := os.ReadDir(abs)
		if err != nil {
			return err
		}
		for _, e := range entries {
			if err := walk(filepath.Join(abs, e.Name()), rel+"/"+e.Name(), depth+1); err != nil {
				return err
			}
		}
		return nil
	}
	if err := walk(filepath.Join(root, part), part, 0); err != nil {
		return nil, err
	}
	sort.Strings(out)
	return out, nil
}

func fileSHA(path string) (string, error) {
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

// ReadManifest は jar.manifest の 1 行目（無ければ空）。
func ReadManifest(root string) string {
	raw, err := os.ReadFile(filepath.Join(root, ManifestFile))
	if err != nil {
		return ""
	}
	line, _, _ := strings.Cut(string(raw), "\n")
	return strings.TrimSpace(line)
}
