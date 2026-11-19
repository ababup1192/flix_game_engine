package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// exportReuseRevision は指紋の作り方の版。書き出しの中身を変える直しを入れたら上げる（前の指紋と合わなくする）。
const exportReuseRevision = "3"

// exportReuseStamp は --reuse が前の書き出しの指紋を残す所（作業フォルダの中）。
// WhyNot: 書き出し先（--out）の中に置かない — 書き出し先はそのままテープの play/ に写り、公開した頁に指紋が混ざる。
func exportReuseStamp(p exportWebPaths) string { return filepath.Join(p.Work, "export.inputs") }

// exportInputsFingerprint は書き出しの中身を決める物の指紋（64 字）。id は解決した後の bundle の id。
// WhyNot: 更新時刻で決めない — 時刻は中身が変わった証にならない（resident の jar.manifest と同じ）。
// WhyNot: Maven から取る TeaVM の jar を入れない — 版はこの実行ファイルに書いてあり、実行ファイルの指紋で足りる。
// WhyNot: --no-browser-check を指紋の外に置かない — 確かめずに組んだ書き出しを、確かめる呼び出しで使い回す。
func exportInputsFingerprint(p exportWebPaths, o exportWebOptions, id string, enc webEncoders) (string, error) {
	h := sha256.New()
	fmt.Fprintf(h, "rev\x00%s\nid\x00%s\nversion\x00%s\nnocheck\x00%v\n", exportReuseRevision, id, p.Version, o.NoBrowserCheck)
	// WhyNot: 道具の道を symlink のまま入れない — brew は版を上げても道を変えず、先の Cellar の道だけが変わる。
	for _, tool := range []string{enc.FFmpeg, enc.Cwebp, enc.Dwebp} {
		if real, err := filepath.EvalSymlinks(tool); err == nil {
			tool = real
		}
		fmt.Fprintf(h, "tool\x00%s\n", tool)
	}
	fmt.Fprintf(h, "env\x00FLIX_JAR\x00%s\n", os.Getenv("FLIX_JAR"))
	files, err := exportGameFiles(p.Game)
	if err != nil {
		return "", err
	}
	for _, rel := range files {
		if err := hashFileInto(h, "game/"+rel, filepath.Join(p.Game, filepath.FromSlash(rel))); err != nil {
			return "", err
		}
	}
	engine := []string{p.FullWebFpkg, p.FullWebToml, p.GlJar, p.WebJar, p.WebToolsJar, p.WebJS, p.IndexHTML, p.FlixJar,
		bootFontDataPath(p.Engine)}
	if exe, err := os.Executable(); err == nil {
		engine = append(engine, exe)
	}
	if dir := os.Getenv("FLIX_GE_TEAVM_DIR"); dir != "" {
		jars, _ := filepath.Glob(filepath.Join(dir, "*.jar"))
		sort.Strings(jars)
		engine = append(engine, jars...)
	}
	for _, f := range engine {
		if err := hashFileInto(h, "engine/"+f, f); err != nil {
			return "", err
		}
	}
	if o.FontAtlasDir != "" {
		atlases, err := walkFiles(o.FontAtlasDir, nil)
		if err != nil {
			return "", err
		}
		for _, rel := range atlases {
			if err := hashFileInto(h, "atlas/"+rel, filepath.Join(o.FontAtlasDir, filepath.FromSlash(rel))); err != nil {
				return "", err
			}
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// exportGameFiles はゲームの根から書き出しが写す物（prepareExportProject と同じく直下の exportWebCopyExcludes を除く）。
func exportGameFiles(game string) ([]string, error) {
	return walkFiles(game, func(rel string) bool {
		top, _, _ := strings.Cut(rel, "/")
		return exportWebCopyExcludes[top]
	})
}

// walkFiles は root の下のファイルを / 区切りの相対パスで字の順に返す。skip が true の道は降りない。symlink は先を辿る。
func walkFiles(root string, skip func(rel string) bool) ([]string, error) {
	var out []string
	var walk func(abs, rel string, depth int) error
	walk = func(abs, rel string, depth int) error {
		if rel != "" && skip != nil && skip(rel) {
			return nil
		}
		info, err := os.Stat(abs)
		if err != nil {
			if os.IsNotExist(err) && rel != "" {
				return nil
			}
			return err
		}
		if !info.IsDir() {
			out = append(out, rel)
			return nil
		}
		if depth > 32 {
			return fmt.Errorf("%s: フォルダが深すぎる（symlink の輪？）", abs)
		}
		entries, err := os.ReadDir(abs)
		if err != nil {
			return err
		}
		for _, e := range entries {
			next := e.Name()
			if rel != "" {
				next = rel + "/" + e.Name()
			}
			if err := walk(filepath.Join(abs, e.Name()), next, depth+1); err != nil {
				return err
			}
		}
		return nil
	}
	if err := walk(root, "", 0); err != nil {
		return nil, err
	}
	sort.Strings(out)
	return out, nil
}

// hashFileInto は名前と中身の SHA-256 を h へ足す。ファイルが無ければ「無い」を足す（無いことも中身の一部）。
func hashFileInto(h io.Writer, name, path string) error {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		fmt.Fprintf(h, "%s\x00missing\n", name)
		return nil
	}
	if err != nil {
		return err
	}
	defer f.Close()
	fh := sha256.New()
	if _, err := io.Copy(fh, f); err != nil {
		return err
	}
	fmt.Fprintf(h, "%s\x00%x\n", name, fh.Sum(nil))
	return nil
}

// exportReuseLine は指紋を残す 1 行（指紋・書き出し先・書き出し先の版）。
func exportReuseLine(fingerprint, out, version string) string {
	return fingerprint + "\t" + out + "\t" + version + "\n"
}

// canReuseExport は前の書き出しをそのまま使えるか（指紋と書き出し先が同じで、書き出し先の版が書いた時のまま）。
func canReuseExport(p exportWebPaths, fingerprint string) bool {
	stamp, err := os.ReadFile(exportReuseStamp(p))
	if err != nil {
		return false
	}
	version, err := os.ReadFile(filepath.Join(p.Out, "version.txt"))
	if err != nil || !fileExists(filepath.Join(p.Out, "index.html")) {
		return false
	}
	return string(stamp) == exportReuseLine(fingerprint, p.Out, strings.TrimSpace(string(version)))
}
