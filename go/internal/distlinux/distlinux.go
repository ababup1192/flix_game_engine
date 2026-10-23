// Package distlinux は、ゲームの jar・Linux x64 の JRE・起動の run.sh を 1 本の tar.gz にまとめる。
//
//	fge dist-linux [--dir GAME] [--name NAME] [--jar PATH] [--out DIR]
//	               [--include assets,project.json] [--jre-archive PATH]
//
// 中身（<name>-linux-x64/ の下）:
//
//	run.sh          起動（書く物は ~/.local/share/<name>/ へ）
//	README.txt      Steam Deck での置き方の短い案内
//	game/game.jar   headless-run が作った jar（入口は FGE_ENTRY=main）
//	game/<include>  実行時に作業場からの相対で読む物
//	jre/            Temurin の JRE（版と SHA-256 は JRE で固定）
package distlinux

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
)

//go:embed run.sh
var runScript string

// JRESpec は取ってくる JRE の 1 版。
type JRESpec struct {
	Version string
	URL     string
	SHA256  string
}

// JRE は固定した版。上げる時は Adoptium の API で linux・x64・jre・hotspot の package の link と checksum を写す
// （api.adoptium.net/v3/assets/version/... の binaries[].package）。
// WhyNot: latest を引かない — 同じ engine の版で作った tar.gz の中身が日によって変わり、実機で起きた事を手元で再現できない。
var JRE = JRESpec{
	Version: "21.0.12.1+1",
	URL:     "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jre_x64_linux_hotspot_21.0.12.1_1.tar.gz",
	SHA256:  "2413149700df0f7d440500a84a8f764c535f21e5a5e87d38328b64eec2c5b500",
}

// Options は組み立ての引数。
type Options struct {
	Dir        string
	Name       string
	Jar        string
	Out        string
	Include    []string
	JREArchive string
	JRE        JRESpec
	CacheDir   string
}

// Result は作った物。
type Result struct {
	Archive string
	SHA256  string
	Files   int
}

// Run は引数を読んで組み立てる。終了コードを返す。
func Run(out, errOut io.Writer, args []string) int {
	opts, err := parseArgs(args)
	if err != nil {
		fmt.Fprintf(errOut, "[dist-linux] %v\n", err)
		return 2
	}
	res, err := Build(opts, errOut)
	if err != nil {
		fmt.Fprintf(errOut, "[dist-linux] %v\n", err)
		return 1
	}
	fmt.Fprintf(out, "[dist-linux] %s (%d ファイル・sha256 %s)\n", res.Archive, res.Files, res.SHA256)
	return 0
}

func parseArgs(args []string) (Options, error) {
	fsFlags := flag.NewFlagSet("dist-linux", flag.ContinueOnError)
	fsFlags.SetOutput(io.Discard)
	dir := fsFlags.String("dir", ".", "ゲームの根")
	name := fsFlags.String("name", "", "配布物の名前（既定はゲームの根のフォルダ名）")
	jar := fsFlags.String("jar", "", "ゲームの jar（既定は <dir>/build/headless/headless.jar）")
	outDir := fsFlags.String("out", "", "書き出す先（既定は <dir>/build/dist）")
	include := fsFlags.String("include", "assets,project.json", "jar の隣に置く物（ゲームの根からの相対・, 区切り）")
	jreArchive := fsFlags.String("jre-archive", "", "手元の JRE の tar.gz（落とさない。SHA-256 は同じく照合する）")
	if err := fsFlags.Parse(args); err != nil {
		return Options{}, err
	}
	if fsFlags.NArg() > 0 {
		return Options{}, fmt.Errorf("知らない引数: %s", strings.Join(fsFlags.Args(), " "))
	}
	cache, err := os.UserCacheDir()
	if err != nil {
		return Options{}, err
	}
	var inc []string
	for _, s := range strings.Split(*include, ",") {
		if s = strings.TrimSpace(s); s != "" {
			inc = append(inc, s)
		}
	}
	return Options{
		Dir: *dir, Name: *name, Jar: *jar, Out: *outDir, Include: inc,
		JREArchive: *jreArchive, JRE: JRE, CacheDir: filepath.Join(cache, "fge-jre"),
	}, nil
}

// Build は tar.gz と、その隣に <名前>.sha256 を書く。
func Build(opts Options, log io.Writer) (Result, error) {
	dir, err := filepath.Abs(opts.Dir)
	if err != nil {
		return Result{}, err
	}
	name := opts.Name
	if name == "" {
		name = filepath.Base(dir)
	}
	if !isPlainName(name) {
		return Result{}, fmt.Errorf("名前に使えない字があります（英数字・- _ . だけ）: %q", name)
	}
	jar := opts.Jar
	if jar == "" {
		jar = filepath.Join(dir, "build", "headless", "headless.jar")
	}
	if _, err := os.Stat(jar); err != nil {
		return Result{}, fmt.Errorf("jar がありません（%s）。ゲームの根で make dist-linux を使うか、先に headless-run --build-only", jar)
	}
	for _, inc := range opts.Include {
		if filepath.IsAbs(inc) || strings.HasPrefix(filepath.Clean(inc), "..") {
			return Result{}, fmt.Errorf("--include はゲームの根の中の相対で: %s", inc)
		}
		if _, err := os.Stat(filepath.Join(dir, inc)); err != nil {
			return Result{}, fmt.Errorf("--include の %s がありません", inc)
		}
	}
	jreArchive, err := getJRE(opts, log)
	if err != nil {
		return Result{}, err
	}
	outDir := opts.Out
	if outDir == "" {
		outDir = filepath.Join(dir, "build", "dist")
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return Result{}, err
	}
	top := name + "-linux-x64"
	archive := filepath.Join(outDir, top+".tar.gz")
	part := archive + ".part"
	n, err := writeArchive(part, top, name, dir, jar, opts.Include, jreArchive)
	if err != nil {
		os.Remove(part)
		return Result{}, err
	}
	sum, err := fileSHA256(part)
	if err != nil {
		return Result{}, err
	}
	// WhyNot: 前の .sha256 を残したまま差し替えない — 書く前に落ちると、新しい tar.gz に古い値が並ぶ。
	if err := os.Remove(archive + ".sha256"); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return Result{}, err
	}
	if err := os.Rename(part, archive); err != nil {
		return Result{}, err
	}
	if err := os.WriteFile(archive+".sha256", []byte(sum+"  "+filepath.Base(archive)+"\n"), 0o644); err != nil {
		return Result{}, err
	}
	return Result{Archive: archive, SHA256: sum, Files: n}, nil
}

func isPlainName(s string) bool {
	if s == "" || s == "." || s == ".." {
		return false
	}
	for _, r := range s {
		ok := r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' || r == '.'
		if !ok {
			return false
		}
	}
	return true
}

// getJRE は SHA-256 の合った JRE の tar.gz の場所を返す。無ければ置き場へ落とす。
func getJRE(opts Options, log io.Writer) (string, error) {
	if opts.JREArchive != "" {
		return opts.JREArchive, checkSHA256(opts.JREArchive, opts.JRE.SHA256)
	}
	cached := filepath.Join(opts.CacheDir, path.Base(strings.ReplaceAll(opts.JRE.URL, "%2B", "+")))
	if err := checkSHA256(cached, opts.JRE.SHA256); err == nil {
		return cached, nil
	}
	if err := os.MkdirAll(opts.CacheDir, 0o755); err != nil {
		return "", err
	}
	fmt.Fprintf(log, "[dist-linux] JRE %s を落とす: %s\n", opts.JRE.Version, opts.JRE.URL)
	if err := download(opts.JRE.URL, cached+".part"); err != nil {
		return "", err
	}
	// WhyNot: 落とした物を照合の前に置き場の名前へ移さない — 途中で切れた物を次の回が「ある」と読まないため。
	if err := checkSHA256(cached+".part", opts.JRE.SHA256); err != nil {
		os.Remove(cached + ".part")
		return "", err
	}
	return cached, os.Rename(cached+".part", cached)
}

func download(url, dest string) error {
	client := &http.Client{Timeout: 10 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("JRE を落とせません: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("JRE を落とせません: %s (%s)", resp.Status, url)
	}
	f, err := os.Create(dest)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		return fmt.Errorf("JRE を落とす途中で切れました: %v", err)
	}
	return f.Close()
}

func fileSHA256(p string) (string, error) {
	f, err := os.Open(p)
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

func checkSHA256(p, want string) error {
	got, err := fileSHA256(p)
	if err != nil {
		return err
	}
	if got != want {
		return fmt.Errorf("JRE の SHA-256 が合いません（%s）: %s（期待 %s）", p, got, want)
	}
	return nil
}

func writeArchive(dest, top, name, dir, jar string, include []string, jreArchive string) (int, error) {
	f, err := os.Create(dest)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	w := &archiveWriter{tw: tw, top: top, dirs: map[string]bool{}}
	w.err = tw.WriteHeader(&tar.Header{Typeflag: tar.TypeDir, Name: top + "/", Mode: 0o755, ModTime: time.Now()})

	script := strings.ReplaceAll(runScript, "@GAME@", name)
	w.bytes("run.sh", []byte(script), 0o755)
	w.bytes("README.txt", []byte(readme(name)), 0o644)
	w.file("game/game.jar", jar)
	for _, inc := range include {
		w.tree(filepath.Join(dir, inc), "game/"+filepath.ToSlash(filepath.Clean(inc)))
	}
	w.jre(jreArchive)
	if w.err != nil {
		return 0, w.err
	}
	if err := tw.Close(); err != nil {
		return 0, err
	}
	if err := gz.Close(); err != nil {
		return 0, err
	}
	return w.files, f.Close()
}

// archiveWriter は最初の誤りで止まり、以降の書き込みを飛ばす。
type archiveWriter struct {
	tw    *tar.Writer
	top   string
	dirs  map[string]bool
	files int
	err   error
}

func (w *archiveWriter) header(h *tar.Header) {
	if w.err != nil {
		return
	}
	w.parents(h.Name)
	h.Name = w.top + "/" + h.Name
	if h.Typeflag == tar.TypeDir {
		h.Name += "/"
	}
	h.Uname, h.Gname, h.Uid, h.Gid = "", "", 0, 0
	if h.ModTime.IsZero() {
		h.ModTime = time.Now()
	}
	w.err = w.tw.WriteHeader(h)
	if h.Typeflag == tar.TypeReg {
		w.files++
	}
}

// parents は親のフォルダを先に書く（tar を解く道具によっては無い親を 0700 で作るため）。
func (w *archiveWriter) parents(rel string) {
	d := path.Dir(rel)
	if d == "." || w.dirs[d] {
		return
	}
	w.parents(d)
	w.dirs[d] = true
	w.err = w.tw.WriteHeader(&tar.Header{Typeflag: tar.TypeDir, Name: w.top + "/" + d + "/", Mode: 0o755, ModTime: time.Now()})
}

func (w *archiveWriter) bytes(rel string, b []byte, mode int64) {
	w.header(&tar.Header{Typeflag: tar.TypeReg, Name: rel, Mode: mode, Size: int64(len(b))})
	if w.err == nil {
		_, w.err = w.tw.Write(b)
	}
}

func (w *archiveWriter) file(rel, src string) {
	if w.err != nil {
		return
	}
	info, err := os.Stat(src)
	if err != nil {
		w.err = err
		return
	}
	mode := int64(0o644)
	if info.Mode()&0o111 != 0 {
		mode = 0o755
	}
	w.header(&tar.Header{Typeflag: tar.TypeReg, Name: rel, Mode: mode, Size: info.Size(), ModTime: info.ModTime()})
	if w.err != nil {
		return
	}
	r, err := os.Open(src)
	if err != nil {
		w.err = err
		return
	}
	defer r.Close()
	_, w.err = io.Copy(w.tw, r)
}

// tree は src（ファイルかフォルダ）を rel の下へ写す。. で始まる物（.DS_Store など）は入れない。
func (w *archiveWriter) tree(src, rel string) {
	if w.err != nil {
		return
	}
	w.err = filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p != src && strings.HasPrefix(d.Name(), ".") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		sub, _ := filepath.Rel(src, p)
		to := path.Join(rel, filepath.ToSlash(sub))
		switch {
		case d.IsDir():
			if !w.dirs[to] {
				w.dirs[to] = true
				w.header(&tar.Header{Typeflag: tar.TypeDir, Name: to, Mode: 0o755})
			}
		case d.Type().IsRegular():
			w.file(to, p)
		default:
			return fmt.Errorf("ファイルでもフォルダでもない物は入れられません: %s", p)
		}
		return w.err
	})
}

// jre は Temurin の tar.gz の中身を、頭のフォルダ（jdk-…-jre/）を jre/ に替えて写す。
// 実行権限と symlink はそのまま運ぶ。
func (w *archiveWriter) jre(archive string) {
	if w.err != nil {
		return
	}
	f, err := os.Open(archive)
	if err != nil {
		w.err = err
		return
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		w.err = fmt.Errorf("JRE の tar.gz を読めません: %v", err)
		return
	}
	tr := tar.NewReader(gz)
	sawJava := false
	for w.err == nil {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			w.err = fmt.Errorf("JRE の tar.gz を読めません: %v", err)
			return
		}
		if h.Typeflag == tar.TypeXGlobalHeader {
			continue
		}
		_, rest, found := strings.Cut(strings.TrimPrefix(h.Name, "./"), "/")
		rest = strings.TrimSuffix(rest, "/")
		if !found || rest == "" {
			continue
		}
		if !isInside(rest) {
			w.err = fmt.Errorf("JRE の tar.gz に外へ出る名前があります: %s", h.Name)
			return
		}
		rel := "jre/" + rest
		switch h.Typeflag {
		case tar.TypeDir:
			if !w.dirs[rel] {
				w.dirs[rel] = true
				w.header(&tar.Header{Typeflag: tar.TypeDir, Name: rel, Mode: h.Mode, ModTime: h.ModTime})
			}
		case tar.TypeReg:
			if rest == "bin/java" {
				sawJava = true
			}
			w.header(&tar.Header{Typeflag: tar.TypeReg, Name: rel, Mode: h.Mode, Size: h.Size, ModTime: h.ModTime})
			if w.err == nil {
				_, w.err = io.Copy(w.tw, tr)
			}
		case tar.TypeSymlink:
			if path.IsAbs(h.Linkname) || !isInside(path.Join(path.Dir(rest), h.Linkname)) {
				w.err = fmt.Errorf("JRE の tar.gz の symlink が jre/ の外を指しています: %s -> %s", h.Name, h.Linkname)
				return
			}
			w.header(&tar.Header{Typeflag: tar.TypeSymlink, Name: rel, Linkname: h.Linkname, Mode: h.Mode, ModTime: h.ModTime})
		default:
			// WhyNot: 知らない種類（hardlink など）を知らせずに捨てない — 版を上げた JRE で欠けた物に気づけない。
			w.err = fmt.Errorf("JRE の tar.gz に運べない種類の物があります（%c）: %s", h.Typeflag, h.Name)
			return
		}
	}
	if w.err == nil && !sawJava {
		w.err = fmt.Errorf("JRE の tar.gz に bin/java がありません: %s", archive)
	}
}

// isInside は / 区切りの相対の名前が、たたんだ後も自分の下に留まるか。
func isInside(rel string) bool {
	c := path.Clean(rel)
	return !path.IsAbs(rel) && c != ".." && !strings.HasPrefix(c, "../")
}

func readme(name string) string {
	return name + ` — Linux x64（Steam Deck）用

起動:   ./run.sh
セーブ: ~/.local/share/` + name + `/saves/
ログ:   ~/.local/share/` + name + `/logs/run.log（1 つ前は run.prev.log）

Steam Deck:
  1. デスクトップモードで、このフォルダを ~/Games/` + name + `-linux-x64/ などに解く
     （tar xzf で解く。zip や FAT の USB を通すと実行権限が落ちる → chmod +x run.sh jre/bin/*）
  2. Steam を開き「ゲーム」→「ゲーム以外の物をマイライブラリに追加」→「参照」で run.sh を選ぶ
  3. ゲームモードに戻り、ライブラリの「ゲーム以外」から起動する

環境変数: FGE_WAYLAND=1（Wayland で開く）・FGE_JAVA_OPTS（java の旗）・FGE_DATA_DIR（セーブの置き場）
`
}
