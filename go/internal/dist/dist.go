// Package dist は、ゲームの jar・その OS の JRE・起動を 1 本の配布物にまとめる。
//
//	fge dist <linux|macos|windows|all> [--dir GAME] [--name NAME] [--version V] [--jar PATH] [--out DIR]
//	         [--include assets,project.json] [--jre-archive PATH]
//
// 配布物は <out>/<name>-<version>-<os>-<arch>.<tar.gz|zip> と .sha256。version の既定はゲームの短いコミット
// （変更が残っていれば -dirty）。中身の頭のフォルダは拡張子を除いた同じ名前で、その下（macOS は .app の
// Contents/Resources）に game/（game.jar と include）と jre/ を置く。起動と案内は OS ごとの Target が作る。
package dist

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"time"
)

// Options は組み立ての引数。JRE を空にすると Target の固定の版を使う。
type Options struct {
	Dir        string
	Name       string
	Version    string
	Jar        string
	Out        string
	Include    []string
	JREArchive string
	JRE        *JRESpec
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
	keys, opts, err := parseArgs(args)
	if err != nil {
		fmt.Fprintf(errOut, "[dist] %v\n", err)
		fmt.Fprintln(errOut, "使い方: fge dist <linux|macos|windows|all> [--dir GAME] [--name NAME] [--version V] [--out DIR] [--include a,b] [--jre-archive PATH]")
		return 2
	}
	for _, key := range keys {
		res, err := Build(Targets[key], opts, errOut)
		if err != nil {
			fmt.Fprintf(errOut, "[dist] %s: %v\n", key, err)
			return 1
		}
		fmt.Fprintf(out, "[dist] %s (%d ファイル・sha256 %s)\n", res.Archive, res.Files, res.SHA256)
	}
	return 0
}

func parseArgs(args []string) ([]string, Options, error) {
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		return nil, Options{}, errors.New("OS を 1 つ（linux・macos・windows）か all を最初に書いてください")
	}
	var keys []string
	switch args[0] {
	case "all":
		keys = TargetKeys
	default:
		if _, ok := Targets[args[0]]; !ok {
			return nil, Options{}, fmt.Errorf("知らない OS: %s", args[0])
		}
		keys = []string{args[0]}
	}
	fsFlags := flag.NewFlagSet("dist", flag.ContinueOnError)
	fsFlags.SetOutput(io.Discard)
	dir := fsFlags.String("dir", ".", "ゲームの根")
	name := fsFlags.String("name", "", "配布物の名前（既定はゲームの根のフォルダ名）")
	version := fsFlags.String("version", "", "ファイル名に入れる版（既定はゲームの短いコミット）")
	jar := fsFlags.String("jar", "", "ゲームの jar（既定は <dir>/build/headless/headless.jar）")
	outDir := fsFlags.String("out", "", "書き出す先（既定は <dir>/build/dist）")
	include := fsFlags.String("include", "assets,project.json", "jar の隣に置く物（ゲームの根からの相対・, 区切り）")
	jreArchive := fsFlags.String("jre-archive", "", "手元の JRE（落とさない。SHA-256 は同じく照合する）")
	if err := fsFlags.Parse(args[1:]); err != nil {
		return nil, Options{}, err
	}
	if fsFlags.NArg() > 0 {
		return nil, Options{}, fmt.Errorf("知らない引数: %s", strings.Join(fsFlags.Args(), " "))
	}
	if *jreArchive != "" && len(keys) > 1 {
		return nil, Options{}, errors.New("--jre-archive は OS を 1 つにした時だけ使えます")
	}
	cache, err := os.UserCacheDir()
	if err != nil {
		return nil, Options{}, err
	}
	var inc []string
	for _, s := range strings.Split(*include, ",") {
		if s = strings.TrimSpace(s); s != "" {
			inc = append(inc, s)
		}
	}
	return keys, Options{
		Dir: *dir, Name: *name, Version: *version, Jar: *jar, Out: *outDir, Include: inc,
		JREArchive: *jreArchive, CacheDir: filepath.Join(cache, "fge-jre"),
	}, nil
}

// Build は配布物と、その隣に <名前>.sha256 を書く。
func Build(t Target, opts Options, log io.Writer) (Result, error) {
	dir, err := filepath.Abs(opts.Dir)
	if err != nil {
		return Result{}, err
	}
	m := meta{Name: opts.Name, Version: opts.Version}
	if m.Name == "" {
		m.Name = filepath.Base(dir)
	}
	if !isPlainName(m.Name) {
		return Result{}, fmt.Errorf("名前に使えない字があります（英数字・- _ . だけ）: %q", m.Name)
	}
	if m.Version == "" {
		if m.Version, err = gitVersion(dir); err != nil {
			return Result{}, err
		}
	}
	if !isPlainName(m.Version) {
		return Result{}, fmt.Errorf("版に使えない字があります（英数字・- _ . だけ）: %q", m.Version)
	}
	m.Title = projectTitle(dir, m.Name)
	jar := opts.Jar
	if jar == "" {
		jar = filepath.Join(dir, "build", "headless", "headless.jar")
	}
	if _, err := os.Stat(jar); err != nil {
		return Result{}, fmt.Errorf("jar がありません（%s）。ゲームの根で make dist-%s を使うか、先に headless-run --build-only", jar, t.Key)
	}
	for _, inc := range opts.Include {
		if filepath.IsAbs(inc) || !isInside(filepath.ToSlash(inc)) {
			return Result{}, fmt.Errorf("--include はゲームの根の中の相対で: %s", inc)
		}
		if _, err := os.Stat(filepath.Join(dir, inc)); err != nil {
			return Result{}, fmt.Errorf("--include の %s がありません", inc)
		}
	}
	spec := t.JRE
	if opts.JRE != nil {
		spec = *opts.JRE
	}
	jreArchive, err := getJRE(spec, opts, log)
	if err != nil {
		return Result{}, err
	}
	generated, err := t.files(m)
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
	top := fmt.Sprintf("%s-%s-%s-%s", m.Name, m.Version, t.Key, t.Arch)
	archive := filepath.Join(outDir, top+"."+t.Format)
	part := archive + ".part"

	n, err := writeArchive(part, t, top, t.root(m), generated, dir, jar, opts.Include, jreArchive, spec.Root)
	if err != nil {
		os.Remove(part)
		return Result{}, err
	}
	sum, err := fileSHA256(part)
	if err != nil {
		return Result{}, err
	}
	// WhyNot: 前の .sha256 を残したまま差し替えない — 書く前に落ちると、新しい配布物に古い値が並ぶ。
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

// isInside は / 区切りの相対の名前が、たたんだ後も自分の下に留まるか。
func isInside(rel string) bool {
	c := path.Clean(rel)
	return !path.IsAbs(rel) && c != ".." && !strings.HasPrefix(c, "../")
}

// gitVersion はゲームの短いコミット。追跡しているファイルに変更が残っていれば -dirty を付ける。
func gitVersion(dir string) (string, error) {
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--short", "HEAD").Output()
	if err != nil {
		return "", fmt.Errorf("ゲームのコミットを読めません（git の外なら --version で版を渡してください）: %v", err)
	}
	v := strings.TrimSpace(string(out))
	st, err := exec.Command("git", "-C", dir, "status", "--porcelain", "--untracked-files=no").Output()
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(string(st)) != "" {
		v += "-dirty"
	}
	return v, nil
}

// projectTitle は project.json の title。読めなければ名前で続ける（案内と Dock の名前にしか使わない）。
func projectTitle(dir, fallback string) string {
	b, err := os.ReadFile(filepath.Join(dir, "project.json"))
	if err != nil {
		return fallback
	}
	var p struct {
		Title string `json:"title"`
	}
	if json.Unmarshal(b, &p) != nil || strings.TrimSpace(p.Title) == "" {
		return fallback
	}
	return p.Title
}

// getJRE は SHA-256 の合った JRE の場所を返す。無ければ置き場へ落とす。
func getJRE(spec JRESpec, opts Options, log io.Writer) (string, error) {
	if opts.JREArchive != "" {
		return opts.JREArchive, checkSHA256(opts.JREArchive, spec.SHA256)
	}
	cached := filepath.Join(opts.CacheDir, path.Base(strings.ReplaceAll(spec.URL, "%2B", "+")))
	if err := checkSHA256(cached, spec.SHA256); err == nil {
		return cached, nil
	}
	if err := os.MkdirAll(opts.CacheDir, 0o755); err != nil {
		return "", err
	}
	fmt.Fprintf(log, "[dist] JRE %s を落とす: %s\n", spec.Version, spec.URL)
	if err := download(spec.URL, cached+".part"); err != nil {
		return "", err
	}
	// WhyNot: 落とした物を照合の前に置き場の名前へ移さない — 途中で切れた物を次の回が「ある」と読まないため。
	if err := checkSHA256(cached+".part", spec.SHA256); err != nil {
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

func writeArchive(dest string, t Target, top, root string, generated []genFile, dir, jar string, include []string, jreArchive, jreRoot string) (int, error) {
	f, err := os.Create(dest)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	var s sink
	if t.Format == "zip" {
		s = newZipSink(f)
	} else {
		s = newTarSink(f)
	}
	w := &archiveWriter{s: s, top: top, dirs: map[string]bool{}}
	w.err = s.dir(top, 0o755, time.Now())

	if root != "" {
		root += "/"
	}
	for _, g := range generated {
		w.bytes(g.rel, []byte(g.body), g.mode)
	}
	w.file(root+"game/game.jar", jar)
	for _, inc := range include {
		w.tree(filepath.Join(dir, inc), root+"game/"+filepath.ToSlash(filepath.Clean(inc)))
	}
	w.jre(jreArchive, jreRoot, root+"jre", t.java)
	if w.err != nil {
		return 0, w.err
	}
	if err := s.close(); err != nil {
		return 0, err
	}
	return w.files, f.Close()
}

// sink は tar.gz と zip の書き方の差を受け持つ。名前は / 区切りの頭のフォルダからの全部。
type sink interface {
	dir(name string, mode int64, mtime time.Time) error
	file(name string, mode, size int64, mtime time.Time, r io.Reader) error
	symlink(name, target string, mtime time.Time) error
	close() error
}

type tarSink struct {
	gz *gzip.Writer
	tw *tar.Writer
}

func newTarSink(w io.Writer) *tarSink {
	gz := gzip.NewWriter(w)
	return &tarSink{gz: gz, tw: tar.NewWriter(gz)}
}

func (s *tarSink) dir(name string, mode int64, mtime time.Time) error {
	return s.tw.WriteHeader(&tar.Header{Typeflag: tar.TypeDir, Name: name + "/", Mode: mode, ModTime: mtime})
}

func (s *tarSink) file(name string, mode, size int64, mtime time.Time, r io.Reader) error {
	if err := s.tw.WriteHeader(&tar.Header{Typeflag: tar.TypeReg, Name: name, Mode: mode, Size: size, ModTime: mtime}); err != nil {
		return err
	}
	_, err := io.Copy(s.tw, r)
	return err
}

func (s *tarSink) symlink(name, target string, mtime time.Time) error {
	return s.tw.WriteHeader(&tar.Header{Typeflag: tar.TypeSymlink, Name: name, Linkname: target, Mode: 0o777, ModTime: mtime})
}

func (s *tarSink) close() error {
	if err := s.tw.Close(); err != nil {
		return err
	}
	return s.gz.Close()
}

type zipSink struct{ zw *zip.Writer }

func newZipSink(w io.Writer) *zipSink { return &zipSink{zw: zip.NewWriter(w)} }

func (s *zipSink) header(name string, mode fs.FileMode, mtime time.Time, method uint16) (io.Writer, error) {
	h := &zip.FileHeader{Name: name, Method: method, Modified: mtime}
	h.SetMode(mode)
	return s.zw.CreateHeader(h)
}

func (s *zipSink) dir(name string, mode int64, mtime time.Time) error {
	_, err := s.header(name+"/", fs.ModeDir|fs.FileMode(mode), mtime, zip.Store)
	return err
}

func (s *zipSink) file(name string, mode, size int64, mtime time.Time, r io.Reader) error {
	w, err := s.header(name, fs.FileMode(mode), mtime, zip.Deflate)
	if err != nil {
		return err
	}
	_, err = io.Copy(w, r)
	return err
}

func (s *zipSink) symlink(name, target string, mtime time.Time) error {
	w, err := s.header(name, fs.ModeSymlink|0o777, mtime, zip.Store)
	if err != nil {
		return err
	}
	_, err = io.WriteString(w, target)
	return err
}

func (s *zipSink) close() error { return s.zw.Close() }

// archiveWriter は親のフォルダを先に書き、最初の誤りで止まって以降の書き込みを飛ばす。
type archiveWriter struct {
	s     sink
	top   string
	dirs  map[string]bool
	files int
	err   error
}

// parents は親のフォルダを先に書く（解く道具によっては無い親を 0700 で作るため）。
func (w *archiveWriter) parents(rel string) {
	d := path.Dir(rel)
	if d == "." || w.dirs[d] || w.err != nil {
		return
	}
	w.parents(d)
	w.mkdir(d, 0o755, time.Now())
}

func (w *archiveWriter) mkdir(rel string, mode int64, mtime time.Time) {
	if w.err != nil || w.dirs[rel] {
		return
	}
	w.parents(rel)
	w.dirs[rel] = true
	if w.err == nil {
		w.err = w.s.dir(w.top+"/"+rel, mode, mtime)
	}
}

func (w *archiveWriter) put(rel string, mode, size int64, mtime time.Time, r io.Reader) {
	if w.err != nil {
		return
	}
	w.parents(rel)
	if w.err == nil {
		w.err = w.s.file(w.top+"/"+rel, mode, size, mtime, r)
		w.files++
	}
}

func (w *archiveWriter) bytes(rel string, b []byte, mode int64) {
	w.put(rel, mode, int64(len(b)), time.Now(), strings.NewReader(string(b)))
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
	r, err := os.Open(src)
	if err != nil {
		w.err = err
		return
	}
	defer r.Close()
	mode := int64(0o644)
	if info.Mode()&0o111 != 0 {
		mode = 0o755
	}
	w.put(rel, mode, info.Size(), info.ModTime(), r)
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
			w.mkdir(to, 0o755, time.Now())
		case d.Type().IsRegular():
			w.file(to, p)
		default:
			return fmt.Errorf("ファイルでもフォルダでもない物は入れられません: %s", p)
		}
		return w.err
	})
}

// jreEntry は tar.gz と zip のどちらから読んだ JRE の 1 件でも同じ形にした物。
type jreEntry struct {
	name  string
	kind  byte // 'd' フォルダ・'f' ファイル・'l' symlink・'?' それ以外
	mode  int64
	link  string
	size  int64
	mtime time.Time
	body  io.Reader
}

// jre は Temurin の JRE の頭のフォルダの下の root（macOS は Contents/Home）を to へ写す。
// 実行権限と symlink はそのまま運ぶ。
func (w *archiveWriter) jre(archive, root, to, javaRel string) {
	if w.err != nil {
		return
	}
	sawJava := false
	prefix := ""
	if root != "" {
		prefix = root + "/"
	}
	w.err = eachJREEntry(archive, func(e jreEntry) error {
		_, rest, found := strings.Cut(strings.TrimPrefix(e.name, "./"), "/")
		rest = strings.TrimSuffix(rest, "/")
		if !found || rest == "" {
			return nil
		}
		if !isInside(rest) {
			return fmt.Errorf("JRE に外へ出る名前があります: %s", e.name)
		}
		if prefix != "" {
			if !strings.HasPrefix(rest, prefix) {
				return nil
			}
			rest = strings.TrimPrefix(rest, prefix)
		}
		rel := to + "/" + rest
		switch e.kind {
		case 'd':
			w.mkdir(rel, e.mode, e.mtime)
		case 'f':
			if rest == javaRel {
				sawJava = true
			}
			w.put(rel, e.mode, e.size, e.mtime, e.body)
		case 'l':
			if path.IsAbs(e.link) || !isInside(path.Join(path.Dir(rest), e.link)) {
				return fmt.Errorf("JRE の symlink が jre/ の外を指しています: %s -> %s", e.name, e.link)
			}
			w.parents(rel)
			if w.err == nil {
				w.err = w.s.symlink(w.top+"/"+rel, e.link, e.mtime)
			}
		default:
			// WhyNot: 知らない種類（hardlink など）を知らせずに捨てない — 版を上げた JRE で欠けた物に気づけない。
			return fmt.Errorf("JRE に運べない種類の物があります: %s", e.name)
		}
		return w.err
	})
	if w.err == nil && !sawJava {
		w.err = fmt.Errorf("JRE に %s がありません: %s", javaRel, archive)
	}
}

// eachJREEntry は .zip か .tar.gz の中身を順に fn へ渡す。
func eachJREEntry(archive string, fn func(jreEntry) error) error {
	if strings.HasSuffix(archive, ".zip") {
		zr, err := zip.OpenReader(archive)
		if err != nil {
			return fmt.Errorf("JRE の zip を読めません: %v", err)
		}
		defer zr.Close()
		for _, f := range zr.File {
			e := jreEntry{name: f.Name, mode: int64(f.Mode().Perm()), size: int64(f.UncompressedSize64), mtime: f.Modified}
			switch {
			case f.Mode().IsDir():
				e.kind = 'd'
			case f.Mode()&fs.ModeSymlink != 0:
				e.kind = 'l'
			case f.Mode().IsRegular():
				e.kind = 'f'
			default:
				e.kind = '?'
			}
			if e.kind == 'f' || e.kind == 'l' {
				rc, err := f.Open()
				if err != nil {
					return err
				}
				if e.kind == 'l' {
					b, err := io.ReadAll(rc)
					rc.Close()
					if err != nil {
						return err
					}
					e.link = string(b)
				} else {
					e.body = rc
					err = fn(e)
					rc.Close()
					if err != nil {
						return err
					}
					continue
				}
			}
			if err := fn(e); err != nil {
				return err
			}
		}
		return nil
	}
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return fmt.Errorf("JRE の tar.gz を読めません: %v", err)
	}
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("JRE の tar.gz を読めません: %v", err)
		}
		e := jreEntry{name: h.Name, mode: h.Mode, link: h.Linkname, size: h.Size, mtime: h.ModTime, body: tr}
		switch h.Typeflag {
		case tar.TypeXGlobalHeader:
			continue
		case tar.TypeDir:
			e.kind = 'd'
		case tar.TypeReg:
			e.kind = 'f'
		case tar.TypeSymlink:
			e.kind = 'l'
		default:
			e.kind = '?'
		}
		if err := fn(e); err != nil {
			return err
		}
	}
}
