package fgeinstall

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/fetchengine"
	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
)

// azulPackage は Azul の metadata API の一覧の 1 行（使う欄だけ）。
type azulPackage struct {
	PackageUUID string `json:"package_uuid"`
	Name        string `json:"name"`
	DownloadURL string `json:"download_url"`
	JavaVersion []int  `json:"java_version"`
}

// azulPackageDetail はパッケージの詳細（使う欄だけ）。
type azulPackageDetail struct {
	DownloadURL string `json:"download_url"`
	SHA256      string `json:"sha256_hash"`
}

// azulPlatform は Go の OS・CPU の名前を Azul の API の名前に替える。
func azulPlatform(goos, goarch string) (osName, arch string, err error) {
	switch goos {
	case "darwin":
		osName = "macos"
	case "linux":
		osName = "linux"
	default:
		return "", "", fmt.Errorf("この OS（%s）向けの JDK は取れません（macOS と Linux だけ）", goos)
	}
	switch goarch {
	case "amd64":
		arch = "x64"
	case "arm64":
		arch = "aarch64"
	default:
		return "", "", fmt.Errorf("この CPU（%s）向けの JDK は取れません（amd64 と arm64 だけ）", goarch)
	}
	return osName, arch, nil
}

// azulListURL は spec の版の JDK を探す問い合わせ。
func azulListURL(base string, spec fgehome.JDKSpec, osName, arch string) string {
	q := url.Values{}
	q.Set("java_version", spec.Version)
	q.Set("os", osName)
	q.Set("arch", arch)
	q.Set("archive_type", "tar.gz")
	q.Set("java_package_type", "jdk")
	q.Set("javafx_bundled", "false")
	q.Set("release_status", "ga")
	q.Set("latest", "true")
	return strings.TrimRight(base, "/") + "/metadata/v1/zulu/packages/?" + q.Encode()
}

// matchesVersion は Azul の java_version（[25, 0, 3] の形）が spec の版で始まるか。
func matchesVersion(got []int, want string) bool {
	if len(got) == 0 {
		return true
	}
	parts := strings.Split(want, ".")
	if len(parts) > len(got) {
		return false
	}
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n != got[i] {
			return false
		}
	}
	return true
}

// jdkSource は取ってくる tar.gz の在り処と、照合する値。
type jdkSource struct {
	URL    string
	SHA256 string
}

// lookUpJDK は Azul の API から spec の JDK の在り処と sha256 を引く。
func (e *Env) lookUpJDK(spec fgehome.JDKSpec) (jdkSource, error) {
	osName, arch, err := azulPlatform(e.GOOS, e.GOARCH)
	if err != nil {
		return jdkSource{}, err
	}
	listURL := azulListURL(e.JDKURL, spec, osName, arch)
	body, err := e.fetchQuick(listURL)
	if err != nil {
		return jdkSource{}, fmt.Errorf("JDK の一覧を引けません: %v（取り先は FGE_JDK_URL で替えられます）", err)
	}
	var list []azulPackage
	if err := json.Unmarshal(body, &list); err != nil {
		return jdkSource{}, fmt.Errorf("JDK の一覧の応答が読めません: %v", err)
	}
	var pick *azulPackage
	for i := range list {
		if list[i].PackageUUID != "" && matchesVersion(list[i].JavaVersion, spec.Version) {
			pick = &list[i]
			break
		}
	}
	if pick == nil {
		return jdkSource{}, fmt.Errorf("%s %s の %s/%s 向けの JDK が見つかりません", spec.Vendor, spec.Version, osName, arch)
	}
	detailURL := strings.TrimRight(e.JDKURL, "/") + "/metadata/v1/zulu/packages/" + url.PathEscape(pick.PackageUUID)
	body, err = e.fetchQuick(detailURL)
	if err != nil {
		return jdkSource{}, fmt.Errorf("JDK の詳細を引けません: %v", err)
	}
	var detail azulPackageDetail
	if err := json.Unmarshal(body, &detail); err != nil {
		return jdkSource{}, fmt.Errorf("JDK の詳細の応答が読めません: %v", err)
	}
	src := jdkSource{URL: detail.DownloadURL, SHA256: strings.ToLower(detail.SHA256)}
	if src.URL == "" {
		src.URL = pick.DownloadURL
	}
	if b, err := hex.DecodeString(src.SHA256); err != nil || len(b) != sha256.Size {
		// WhyNot: 照合の値が無い物を受けない — 途切れた tar.gz と別物を見分けられない。
		return jdkSource{}, fmt.Errorf("%s の sha256 が API の応答にありません", pick.Name)
	}
	// WhyNot: 平文の http を受けない — tar.gz と照合の値が同じ経路で来るので、途中で両方を差し替えられると照合が何も守らない。
	if !strings.HasPrefix(src.URL, "https://") {
		return jdkSource{}, fmt.Errorf("%s の置き場が https ではありません: %s", pick.Name, src.URL)
	}
	return src, nil
}

// InstallJDK は spec の JDK を <置き場>/jdk/<配り元>-<版>/ に開く。既に .complete があれば何もしない。
func (e *Env) InstallJDK(spec fgehome.JDKSpec) (dir string, alreadyThere bool, err error) {
	dest := spec.Dir()
	if fgehome.IsComplete(dest) {
		return dest, true, nil
	}
	if spec.Vendor != "zulu" {
		return "", false, fmt.Errorf("JDK の配り元 %q の取り方を知りません（%s に書けるのは zulu だけ）", spec.Vendor, fgehome.JDKSpecFile)
	}
	if !fetchengine.IsVersionName(spec.Version) {
		return "", false, fmt.Errorf("JDK の版 %q はフォルダ名として置けません", spec.Version)
	}
	unlock, err := fgehome.Lock(fgehome.LockPath(), e.Progress)
	if err != nil {
		return "", false, fmt.Errorf("排他を取れません: %v", err)
	}
	defer unlock()
	if fgehome.IsComplete(dest) {
		return dest, true, nil
	}

	src, err := e.lookUpJDK(spec)
	if err != nil {
		return "", false, err
	}
	root := fgehome.JDKRoot()
	if err := os.MkdirAll(root, 0o755); err != nil {
		return "", false, err
	}
	fetchengine.SweepHalfDone(root)
	staging := filepath.Join(root, spec.Name()+".partial-"+strconv.Itoa(os.Getpid()))
	if err := fgehome.RemoveReadOnly(staging); err != nil {
		return "", false, err
	}
	defer fgehome.RemoveReadOnly(staging)
	if err := os.MkdirAll(staging, 0o755); err != nil {
		return "", false, err
	}

	e.progressf("[fge engines] JDK %s を取ります（約 200 MB）\n", spec.Name())
	archive := filepath.Join(staging, "jdk.tar.gz")
	if err := e.downloadVerified(src, archive); err != nil {
		return "", false, fmt.Errorf("%v%s", err, diskHint(err))
	}
	e.progressf("[fge engines] JDK を照合しました (%s)。開いています\n", src.SHA256[:12])
	unpacked := filepath.Join(staging, "x")
	if err := extractTarGz(archive, unpacked); err != nil {
		return "", false, fmt.Errorf("JDK を開けません: %v%s", err, diskHint(err))
	}
	home, err := findJavaHome(unpacked)
	if err != nil {
		return "", false, err
	}
	java := filepath.Join(home, "bin", "java")
	// WhyNot: 置いただけで済ませない — 別の CPU 向けを取り違えた時、描き出しの途中で初めて落ちる。
	if err := e.RunExe(java, "-version"); err != nil {
		return "", false, fmt.Errorf("取った JDK の java がこの機械で走りません: %v", err)
	}
	if err := os.WriteFile(filepath.Join(home, fgehome.CompleteMarker), []byte(spec.Name()+"\n"), 0o644); err != nil {
		return "", false, err
	}
	if _, err := os.Lstat(dest); err == nil {
		aside := staging + "-old"
		if err := os.Rename(dest, aside); err != nil {
			return "", false, fmt.Errorf("半端な %s をどけられません: %v", dest, err)
		}
		defer fgehome.RemoveReadOnly(aside)
	}
	if err := os.Rename(home, dest); err != nil {
		return "", false, fmt.Errorf("%s へ名前を付けられません: %v", dest, err)
	}
	if err := fgehome.MakeReadOnly(dest); err != nil {
		return "", false, fmt.Errorf("%s を読み取り専用にできません: %v", dest, err)
	}
	return dest, false, nil
}

// downloadVerified は src を path に書きながら sha256 を数え、合わなければ止める。
func (e *Env) downloadVerified(src jdkSource, path string) error {
	body, err := e.open(src.URL, 30*time.Minute)
	if err != nil {
		return fmt.Errorf("JDK を落とせません: %v", err)
	}
	defer body.Close()
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	h := sha256.New()
	// WhyNot: 上限を置くのは、取りに行く先を間違えた時にディスクを埋めないため。JDK の tar.gz は 200 MB 前後。
	const limit = 1 << 30
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(body, limit+1))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return fmt.Errorf("JDK を落とせません: %v", err)
	}
	if n > limit {
		return fmt.Errorf("JDK の tar.gz が大きすぎます（%d バイトを超えました）", int64(limit))
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != src.SHA256 {
		return fmt.Errorf("JDK の中身が API の値と違います (期待 %s / 実際 %s)", src.SHA256, got)
	}
	return nil
}

// extractTarGz は tar.gz を dest の下に開く。dest の外を指す名前・リンクがあれば止める。
func extractTarGz(archive, dest string) error {
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	defer gz.Close()
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return err
	}
	root := filepath.Clean(dest)
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		target, err := insideRoot(root, h.Name)
		if err != nil {
			return err
		}
		if target == root {
			continue
		}
		// WhyNot: 先に置いた symlink の下へ書かせない — リンクの先が外なら、名前が中でも外へ書ける。
		if err := noSymlinkParents(root, filepath.Dir(target)); err != nil {
			return err
		}
		switch h.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := writeTarFile(tr, target, h.FileInfo().Mode().Perm()); err != nil {
				return err
			}
		case tar.TypeSymlink:
			if filepath.IsAbs(h.Linkname) {
				return fmt.Errorf("tar.gz の中に外を指すリンクがあります: %s -> %s", h.Name, h.Linkname)
			}
			if _, err := insideRoot(root, filepath.Join(filepath.Dir(strings.TrimPrefix(target, root+string(os.PathSeparator))), h.Linkname)); err != nil {
				return fmt.Errorf("tar.gz の中に外を指すリンクがあります: %s -> %s", h.Name, h.Linkname)
			}
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			if err := os.Symlink(h.Linkname, target); err != nil {
				return err
			}
		case tar.TypeLink:
			from, err := insideRoot(root, h.Linkname)
			if err != nil {
				return err
			}
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			if err := os.Link(from, target); err != nil {
				return err
			}
		}
	}
}

// insideRoot は tar の中の名前を root の下のパスにする。外を指せば止める。
// WhyNot: 名前を Clean してから比べるだけにしない — ".." を含む名前を正規化すると、外を指す名前が無害な名前に化ける。
func insideRoot(root, name string) (string, error) {
	name = filepath.FromSlash(name)
	if filepath.IsAbs(name) {
		return "", fmt.Errorf("tar.gz の中に絶対パスの名前があります: %s", name)
	}
	target := filepath.Join(root, name)
	if target != root && !strings.HasPrefix(target, root+string(os.PathSeparator)) {
		return "", fmt.Errorf("tar.gz の中に置き場の外を指す名前があります: %s", name)
	}
	return target, nil
}

func noSymlinkParents(root, dir string) error {
	for p := dir; p != root && strings.HasPrefix(p, root); p = filepath.Dir(p) {
		info, err := os.Lstat(p)
		if err != nil {
			continue
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("tar.gz の中にリンクの下へ書く名前があります: %s", p)
		}
	}
	return nil
}

func writeTarFile(r io.Reader, target string, perm os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, perm|0o200)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, r); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// findJavaHome は開いた中から bin/java を持つ一番浅いフォルダを探す。
// macOS の tar.gz は <name>/zulu-25.jdk/Contents/Home の入れ子で、<name>/bin はそこを指す symlink。
// WhyNot: symlink の bin を当たりにしない — 入れ子の外側を選ぶと、Contents/Home を指すリンクが置き場へ移した後に切れる。
func findJavaHome(root string) (string, error) {
	best, bestDepth := "", -1
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || !d.IsDir() {
			return nil
		}
		bin := filepath.Join(path, "bin")
		java := filepath.Join(bin, "java")
		bi, err1 := os.Lstat(bin)
		ji, err2 := os.Lstat(java)
		if err1 != nil || err2 != nil || !bi.IsDir() || !ji.Mode().IsRegular() {
			return nil
		}
		depth := strings.Count(strings.TrimPrefix(path, root), string(os.PathSeparator))
		if bestDepth < 0 || depth < bestDepth {
			best, bestDepth = path, depth
		}
		return filepath.SkipDir
	})
	if err != nil {
		return "", err
	}
	if best == "" {
		return "", fmt.Errorf("取った JDK の中に bin/java が見つかりません")
	}
	return best, nil
}
