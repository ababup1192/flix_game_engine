package fgeinstall

// 何を守るか: 取った物が公開されている値と一致すること、JDK がどの OS の形でも <dir>/bin/java にそろうこと、
// 置き場の外へ書けないこと、latest.json を 1 日 1 回より多く問い合わせないこと、使っている版を消さないこと。

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
)

type tarEntry struct {
	name string
	body string
	link string // symlink の先（空なら普通のファイルかフォルダ）
	dir  bool
	mode int64
}

func makeTarGz(t *testing.T, entries []tarEntry) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, e := range entries {
		h := &tar.Header{Name: e.name, Mode: e.mode}
		switch {
		case e.dir:
			h.Typeflag = tar.TypeDir
			if h.Mode == 0 {
				h.Mode = 0o755
			}
		case e.link != "":
			h.Typeflag = tar.TypeSymlink
			h.Linkname = e.link
		default:
			h.Typeflag = tar.TypeReg
			h.Size = int64(len(e.body))
			if h.Mode == 0 {
				h.Mode = 0o644
			}
		}
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if h.Typeflag == tar.TypeReg {
			if _, err := tw.Write([]byte(e.body)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func linuxJDK(t *testing.T) []byte {
	return makeTarGz(t, []tarEntry{
		{name: "zulu25.32.17-ca-jdk25.0.3-linux_x64/", dir: true},
		{name: "zulu25.32.17-ca-jdk25.0.3-linux_x64/bin/java", body: "#!/bin/sh\n", mode: 0o755},
		{name: "zulu25.32.17-ca-jdk25.0.3-linux_x64/lib/modules", body: "m"},
	})
}

func macJDK(t *testing.T) []byte {
	top := "zulu25.32.17-ca-jdk25.0.3-macosx_aarch64/"
	return makeTarGz(t, []tarEntry{
		{name: top, dir: true},
		{name: top + "zulu-25.jdk/Contents/Home/bin/java", body: "#!/bin/sh\n", mode: 0o755},
		{name: top + "zulu-25.jdk/Contents/Home/lib/modules", body: "m"},
		{name: top + "zulu-25.jdk/Contents/Info.plist", body: "<plist/>"},
		{name: top + "bin", link: "zulu-25.jdk/Contents/Home/bin"},
		{name: top + "lib", link: "zulu-25.jdk/Contents/Home/lib"},
	})
}

func sumHex(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// fakeNet は GitHub の releases と Azul の metadata API の形で応える https のサーバー。
type fakeNet struct {
	srv   *httptest.Server
	mu    sync.Mutex
	pages map[string][]byte
	hits  map[string]int
	query map[string]string
}

func newFakeNet(t *testing.T) *fakeNet {
	t.Helper()
	f := &fakeNet{pages: map[string][]byte{}, hits: map[string]int{}, query: map[string]string{}}
	f.srv = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		body, ok := f.pages[r.URL.Path]
		f.hits[r.URL.Path]++
		f.query[r.URL.Path] = r.URL.RawQuery
		f.mu.Unlock()
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Write(body)
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeNet) set(path string, body []byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pages[path] = body
}

func (f *fakeNet) hitCount(path string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[path]
}

func (f *fakeNet) serveJDK(t *testing.T, archive []byte, sha string) {
	t.Helper()
	list, _ := json.Marshal([]map[string]any{{
		"package_uuid": "uuid-1", "name": "zulu.tar.gz", "java_version": []int{25, 0, 3},
		"download_url": f.srv.URL + "/cdn/zulu.tar.gz",
	}})
	detail, _ := json.Marshal(map[string]any{"download_url": f.srv.URL + "/cdn/zulu.tar.gz", "sha256_hash": sha})
	f.set("/metadata/v1/zulu/packages/", list)
	f.set("/metadata/v1/zulu/packages/uuid-1", detail)
	f.set("/cdn/zulu.tar.gz", archive)
}

func (f *fakeNet) serveRelease(t *testing.T, tag string, assets map[string][]byte) {
	t.Helper()
	type asset struct {
		Name string `json:"name"`
		URL  string `json:"browser_download_url"`
	}
	rel := struct {
		TagName string  `json:"tag_name"`
		Assets  []asset `json:"assets"`
	}{TagName: tag}
	for name, body := range assets {
		rel.Assets = append(rel.Assets, asset{Name: name, URL: f.srv.URL + "/dl/" + name})
		f.set("/dl/"+name, body)
	}
	b, _ := json.Marshal(rel)
	f.set("/repos/"+DefaultRepo+"/releases/latest", b)
	f.set("/repos/"+DefaultRepo+"/releases/tags/"+tag, b)
}

func testEnv(t *testing.T, f *fakeNet, goos string) *Env {
	t.Helper()
	home := t.TempDir()
	t.Setenv("FGE_HOME", home)
	t.Setenv("HOME", filepath.Join(home, "user"))
	t.Setenv("USERPROFILE", filepath.Join(home, "user"))
	t.Cleanup(func() {
		_ = fgehome.RemoveReadOnly(fgehome.EnginesDir())
		_ = fgehome.RemoveReadOnly(fgehome.JDKRoot())
	})
	return &Env{
		ReleasesAPI: f.srv.URL, JDKURL: f.srv.URL, Repo: DefaultRepo,
		Client: f.srv.Client(), Progress: &strings.Builder{},
		Now:    func() time.Time { return time.Date(2026, 11, 23, 12, 0, 0, 0, time.UTC) },
		RunExe: func(string, ...string) error { return nil },
		GOOS:   goos, GOARCH: "amd64",
	}
}

var spec = fgehome.JDKSpec{Vendor: "zulu", Version: "25.0.3"}

func TestAzulPlatformNames(t *testing.T) {
	cases := map[[2]string][2]string{
		{"linux", "amd64"}:  {"linux", "x64"},
		{"linux", "arm64"}:  {"linux", "aarch64"},
		{"darwin", "amd64"}: {"macos", "x64"},
		{"darwin", "arm64"}: {"macos", "aarch64"},
	}
	for in, want := range cases {
		osName, arch, err := azulPlatform(in[0], in[1])
		if err != nil || osName != want[0] || arch != want[1] {
			t.Errorf("%v → %s/%s %v (want %v)", in, osName, arch, err, want)
		}
	}
}

func TestAzulPlatformRefusesAnUnknownOS(t *testing.T) {
	if _, _, err := azulPlatform("freebsd", "amd64"); err == nil {
		t.Fatal("知らない OS を受けた")
	}
}

func TestInstallJDKAsksAzulForTheSpecVersionAndPlatform(t *testing.T) {
	f := newFakeNet(t)
	archive := linuxJDK(t)
	f.serveJDK(t, archive, sumHex(archive))
	e := testEnv(t, f, "linux")

	if _, _, err := e.InstallJDK(spec); err != nil {
		t.Fatal(err)
	}
	q := f.query["/metadata/v1/zulu/packages/"]
	for _, want := range []string{"java_version=25.0.3", "os=linux", "arch=x64", "archive_type=tar.gz", "java_package_type=jdk", "release_status=ga", "latest=true"} {
		if !strings.Contains(q, want) {
			t.Errorf("問い合わせに %s が無い: %s", want, q)
		}
	}
}

func TestInstallJDKPutsJavaUnderTheSpecFolder(t *testing.T) {
	f := newFakeNet(t)
	archive := linuxJDK(t)
	f.serveJDK(t, archive, sumHex(archive))
	e := testEnv(t, f, "linux")

	dir, already, err := e.InstallJDK(spec)
	if err != nil || already {
		t.Fatalf("already=%v err=%v", already, err)
	}
	if _, err := os.Stat(spec.Java()); err != nil {
		t.Fatalf("bin/java が無い: %v", err)
	}
	if !fgehome.IsComplete(dir) {
		t.Fatal(".complete が無い")
	}
}

func TestInstallJDKLiftsMacOSContentsHome(t *testing.T) {
	f := newFakeNet(t)
	archive := macJDK(t)
	f.serveJDK(t, archive, sumHex(archive))
	e := testEnv(t, f, "darwin")

	if _, _, err := e.InstallJDK(spec); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(spec.Java())
	if err != nil || !info.Mode().IsRegular() {
		t.Fatalf("Contents/Home の中身が jdk/zulu-25.0.3/ の直下にそろっていない: %v", err)
	}
}

func TestInstallJDKLeavesNoStagingBehind(t *testing.T) {
	f := newFakeNet(t)
	archive := macJDK(t)
	f.serveJDK(t, archive, sumHex(archive))
	e := testEnv(t, f, "darwin")

	if _, _, err := e.InstallJDK(spec); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(fgehome.JDKRoot())
	if len(entries) != 1 || entries[0].Name() != spec.Name() {
		t.Fatalf("途中の場所が残っている: %v", entries)
	}
}

func TestInstallJDKRefusesAMismatchedSum(t *testing.T) {
	f := newFakeNet(t)
	f.serveJDK(t, linuxJDK(t), strings.Repeat("0", 64))
	e := testEnv(t, f, "linux")

	if _, _, err := e.InstallJDK(spec); err == nil || !strings.Contains(err.Error(), "違います") {
		t.Fatalf("照合の合わない JDK を受けた: %v", err)
	}
}

func TestInstallJDKRefusesPlainHTTP(t *testing.T) {
	f := newFakeNet(t)
	archive := linuxJDK(t)
	f.serveJDK(t, archive, sumHex(archive))
	detail, _ := json.Marshal(map[string]any{"download_url": "http://cdn.test/zulu.tar.gz", "sha256_hash": sumHex(archive)})
	f.set("/metadata/v1/zulu/packages/uuid-1", detail)
	e := testEnv(t, f, "linux")

	if _, _, err := e.InstallJDK(spec); err == nil || !strings.Contains(err.Error(), "https") {
		t.Fatalf("http の置き場を受けた: %v", err)
	}
}

func TestInstallJDKDoesNothingWhenComplete(t *testing.T) {
	f := newFakeNet(t)
	e := testEnv(t, f, "linux")
	if err := os.MkdirAll(spec.Dir(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(spec.Dir(), fgehome.CompleteMarker), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	_, already, err := e.InstallJDK(spec)
	if err != nil || !already {
		t.Fatalf("already=%v err=%v", already, err)
	}
}

func TestInstallJDKRefusesAJavaThatDoesNotRun(t *testing.T) {
	f := newFakeNet(t)
	archive := linuxJDK(t)
	f.serveJDK(t, archive, sumHex(archive))
	e := testEnv(t, f, "linux")
	e.RunExe = func(string, ...string) error { return errors.New("exec format error") }

	if _, _, err := e.InstallJDK(spec); err == nil {
		t.Fatal("走らない java を置いた")
	}
}

func TestExtractRefusesALinkThatPointsOutside(t *testing.T) {
	dir := t.TempDir()
	archive := filepath.Join(dir, "a.tar.gz")
	if err := os.WriteFile(archive, makeTarGz(t, []tarEntry{{name: "jdk/evil", link: "../../../etc"}}), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := extractTarGz(archive, filepath.Join(dir, "x")); err == nil {
		t.Fatal("外を指すリンクを受けた")
	}
}

func TestExtractRefusesWritingThroughALink(t *testing.T) {
	dir := t.TempDir()
	archive := filepath.Join(dir, "a.tar.gz")
	body := makeTarGz(t, []tarEntry{{name: "jdk/sub/", dir: true}, {name: "jdk/l", link: "sub"}, {name: "jdk/l/file", body: "x"}})
	if err := os.WriteFile(archive, body, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := extractTarGz(archive, filepath.Join(dir, "x")); err == nil {
		t.Fatal("リンクの下へ書いた")
	}
}

func TestExtractRefusesAnEscapingName(t *testing.T) {
	dir := t.TempDir()
	archive := filepath.Join(dir, "a.tar.gz")
	if err := os.WriteFile(archive, makeTarGz(t, []tarEntry{{name: "../evil", body: "x"}}), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := extractTarGz(archive, filepath.Join(dir, "x")); err == nil {
		t.Fatal("外を指す名前を受けた")
	}
}

func TestRefreshLatestUsesTheCacheWithinADay(t *testing.T) {
	f := newFakeNet(t)
	e := testEnv(t, f, "linux")
	if err := fgehome.WriteLatest(fgehome.Latest{Version: "0.108.0", CheckedAt: e.Now().Add(-time.Hour)}); err != nil {
		t.Fatal(err)
	}

	l, ok, err := e.RefreshLatest(false)
	if !ok || err != nil || l.Version != "0.108.0" || f.hitCount("/repos/"+DefaultRepo+"/releases/latest") != 0 {
		t.Fatalf("1 日以内なのに問い合わせた: %+v ok=%v err=%v", l, ok, err)
	}
}

func TestRefreshLatestAsksAgainAfterADay(t *testing.T) {
	f := newFakeNet(t)
	f.serveRelease(t, "v0.109.0", map[string][]byte{
		"flix_game_engine-engine-v0.109.0.zip": []byte("z"), "SHA256SUMS.txt": []byte("s"),
	})
	e := testEnv(t, f, "linux")
	if err := fgehome.WriteLatest(fgehome.Latest{Version: "0.108.0", CheckedAt: e.Now().Add(-25 * time.Hour)}); err != nil {
		t.Fatal(err)
	}

	if _, _, err := e.RefreshLatest(false); err != nil {
		t.Fatal(err)
	}
	saved, _ := fgehome.ReadLatest()
	if saved.Version != "0.109.0" || !saved.CheckedAt.Equal(e.Now()) {
		t.Fatalf("latest.json が新しくなっていない: %+v", saved)
	}
}

func TestRefreshLatestKeepsTheOldCacheWhenOffline(t *testing.T) {
	f := newFakeNet(t)
	e := testEnv(t, f, "linux")
	if err := fgehome.WriteLatest(fgehome.Latest{Version: "0.108.0", CheckedAt: e.Now().Add(-48 * time.Hour)}); err != nil {
		t.Fatal(err)
	}

	l, ok, err := e.RefreshLatest(false)
	if !ok || err == nil || l.Version != "0.108.0" {
		t.Fatalf("前の控えを返していない: %+v ok=%v err=%v", l, ok, err)
	}
}

const stageRules = `{"items": [
  {"src": "@flix-wrapper", "dest": "bin/flix", "exec": true, "skipOnWindows": true, "owner": "studio", "why": "w"},
  {"src": "@fge-go", "dest": "bin/fge-go", "destWindows": "bin/fge-go.exe", "exec": true, "why": "t"},
  {"src": "Makefile", "dest": "Makefile", "why": "m"}
]}`

func engineZip(t *testing.T, withJDKSpec bool) []byte {
	t.Helper()
	files := map[string]string{
		"bin/lint-rules/stage-engine.json": stageRules,
		"bin/flix":                         "#!/bin/sh\n",
		"bin/fge-go":                       "tool",
		"Makefile":                         "VERSION := 0.109.0\n",
		"templates/game-starter/README.md": "# t\n",
		WorkspaceAgentsSrc:                 "# ws 0.109.0\n",
	}
	if withJDKSpec {
		files["mk/jdk.mk"] = "FGE_JDK_VENDOR  := zulu\nFGE_JDK_VERSION := 25.0.3\n"
	}
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	for name, body := range files {
		fw, err := w.Create("engine/" + name)
		if err != nil {
			t.Fatal(err)
		}
		fw.Write([]byte(body))
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func serveEngine(t *testing.T, f *fakeNet, withJDKSpec bool) {
	t.Helper()
	body := engineZip(t, withJDKSpec)
	zipName := "flix_game_engine-engine-v0.109.0.zip"
	f.serveRelease(t, "v0.109.0", map[string][]byte{
		zipName:          body,
		"SHA256SUMS.txt": []byte(sumHex(body) + "  " + zipName + "\n"),
	})
}

func TestInstallTakesTheEngineAndItsJDK(t *testing.T) {
	f := newFakeNet(t)
	serveEngine(t, f, true)
	archive := linuxJDK(t)
	f.serveJDK(t, archive, sumHex(archive))
	e := testEnv(t, f, "linux")

	res, err := e.Install("latest")
	if err != nil {
		t.Fatal(err)
	}
	if res.Version != "0.109.0" || !fgehome.IsComplete(res.EngineDir) || res.JDK != "zulu-25.0.3" || !fgehome.IsComplete(res.JDKDir) {
		t.Fatalf("engine と JDK が揃っていない: %+v", res)
	}
}

func TestInstallSkipsTheJDKForAnEngineWithoutJDKSpec(t *testing.T) {
	f := newFakeNet(t)
	serveEngine(t, f, false)
	e := testEnv(t, f, "linux")

	res, err := e.Install("0.109.0")
	if err != nil || res.JDK != "" {
		t.Fatalf("res=%+v err=%v", res, err)
	}
}

func TestInstalledVersionsSkipsHalfDoneFolders(t *testing.T) {
	f := newFakeNet(t)
	_ = testEnv(t, f, "linux")
	for _, name := range []string{"0.108.0", "0.109.0.partial-12", "0.110.0"} {
		dir := fgehome.EngineDir(name)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if name != "0.110.0" {
			os.WriteFile(filepath.Join(dir, fgehome.CompleteMarker), nil, 0o644)
		}
	}
	if got := InstalledVersions(); len(got) != 1 || got[0] != "0.108.0" {
		t.Fatalf("got %v", got)
	}
}

func placeEngine(t *testing.T, version string, jdk bool) {
	t.Helper()
	dir := fgehome.EngineDir(version)
	if err := os.MkdirAll(filepath.Join(dir, "mk"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, fgehome.CompleteMarker), nil, 0o644)
	if jdk {
		os.WriteFile(filepath.Join(dir, "mk", "jdk.mk"), []byte("FGE_JDK_VENDOR := zulu\nFGE_JDK_VERSION := 25.0.3\n"), 0o644)
		os.MkdirAll(spec.Dir(), 0o755)
		os.WriteFile(filepath.Join(spec.Dir(), fgehome.CompleteMarker), nil, 0o644)
	}
}

func TestRemoveRefusesAVersionAGameUses(t *testing.T) {
	f := newFakeNet(t)
	e := testEnv(t, f, "linux")
	placeEngine(t, "0.108.0", false)
	game := t.TempDir()
	os.WriteFile(filepath.Join(game, "flix.toml"), []byte(`[dependencies]
"github:ababup1192/flix_game_engine" = { version = "0.108.0" }
`), 0o644)
	if err := fgehome.WriteWorkspace(fgehome.Workspace{Games: []fgehome.Game{{Name: "tide", Dir: game}}}); err != nil {
		t.Fatal(err)
	}

	if _, err := e.Remove("0.108.0"); err == nil || !strings.Contains(err.Error(), "tide") {
		t.Fatalf("使っている版を消した: %v", err)
	}
}

func TestRemoveAlsoRemovesAJDKNoOtherVersionUses(t *testing.T) {
	f := newFakeNet(t)
	e := testEnv(t, f, "linux")
	placeEngine(t, "0.108.0", true)
	fgehome.MakeReadOnly(fgehome.EngineDir("0.108.0"))

	res, err := e.Remove("0.108.0")
	if err != nil || res.RemovedJDK != "zulu-25.0.3" {
		t.Fatalf("res=%+v err=%v", res, err)
	}
	if _, err := os.Stat(spec.Dir()); !os.IsNotExist(err) {
		t.Fatalf("JDK が残っている: %v", err)
	}
}

func TestRemoveKeepsAJDKAnotherVersionUses(t *testing.T) {
	f := newFakeNet(t)
	e := testEnv(t, f, "linux")
	placeEngine(t, "0.108.0", true)
	placeEngine(t, "0.109.0", true)

	if _, err := e.Remove("0.108.0"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(spec.Dir()); err != nil {
		t.Fatalf("他の版が使う JDK を消した: %v", err)
	}
}

func TestSelfUpdateReplacesTheGlobalFge(t *testing.T) {
	f := newFakeNet(t)
	bin := []byte("new fge")
	f.serveRelease(t, "v0.109.0", map[string][]byte{
		"fge-linux-amd64": bin,
		FgeSumsName:       []byte(sumHex(bin) + "  fge-linux-amd64\n"),
	})
	e := testEnv(t, f, "linux")

	if _, err := e.SelfUpdate(); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(fgehome.BinDir(), "fge"))
	if err != nil || string(got) != "new fge" {
		t.Fatalf("差し替わっていない: %q %v", got, err)
	}
}

func TestSelfUpdateRefusesAMismatchedSum(t *testing.T) {
	f := newFakeNet(t)
	f.serveRelease(t, "v0.109.0", map[string][]byte{
		"fge-linux-amd64": []byte("tampered"),
		FgeSumsName:       []byte(strings.Repeat("a", 64) + "  fge-linux-amd64\n"),
	})
	e := testEnv(t, f, "linux")

	if _, err := e.SelfUpdate(); err == nil {
		t.Fatal("照合の合わない fge を置いた")
	}
}

func TestFgeAssetNameNamesTheWindowsExe(t *testing.T) {
	if got, err := FgeAssetName("windows", "amd64"); err != nil || got != "fge-windows-amd64.exe" {
		t.Fatalf("got %q err=%v", got, err)
	}
}

func TestFgeAssetNameRefusesWindowsArm64(t *testing.T) {
	if _, err := FgeAssetName("windows", "arm64"); err == nil {
		t.Fatal("配っていない windows/arm64 を受けた")
	}
}

func TestFgeAssetNameRefusesAnUnknownOS(t *testing.T) {
	if _, err := FgeAssetName("plan9", "amd64"); err == nil {
		t.Fatal("知らない OS を受けた")
	}
}

func TestInstallRewritesTheAgentsOfAnExistingWorkspaceFolder(t *testing.T) {
	f := newFakeNet(t)
	serveEngine(t, f, false)
	e := testEnv(t, f, "linux")
	dir := fgehome.DefaultWorkspaceDir()
	os.MkdirAll(dir, 0o755)
	os.WriteFile(filepath.Join(dir, "AGENTS.md"), []byte("# old\n"), 0o644)

	if _, err := e.Install("0.109.0"); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "AGENTS.md")); string(b) != "# ws 0.109.0\n" {
		t.Fatalf("AGENTS.md=%q", b)
	}
}

func TestInstallDoesNotCreateTheWorkspaceFolder(t *testing.T) {
	f := newFakeNet(t)
	serveEngine(t, f, false)
	e := testEnv(t, f, "linux")

	if _, err := e.Install("0.109.0"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fgehome.DefaultWorkspaceDir()); !os.IsNotExist(err) {
		t.Fatalf("ワークスペースのフォルダができています: %v", err)
	}
}

func TestSyncWorkspaceFolderWritesNothingWhenUnchanged(t *testing.T) {
	f := newFakeNet(t)
	_ = testEnv(t, f, "linux")
	placeEngine(t, "0.108.0", false)
	os.MkdirAll(filepath.Join(fgehome.EngineDir("0.108.0"), "agents-pack", "workspace"), 0o755)
	os.WriteFile(filepath.Join(fgehome.EngineDir("0.108.0"), WorkspaceAgentsSrc), []byte("# ws\n"), 0o644)
	if _, err := SyncWorkspaceFolder(true); err != nil {
		t.Fatal(err)
	}
	res, err := SyncWorkspaceFolder(true)
	if err != nil || res.Updated {
		t.Fatalf("res=%+v err=%v", res, err)
	}
}

func TestSyncWorkspaceFolderReportsAnEngineWithoutTheWorkspaceAgents(t *testing.T) {
	f := newFakeNet(t)
	_ = testEnv(t, f, "linux")
	placeEngine(t, "0.108.0", false)
	res, err := SyncWorkspaceFolder(true)
	_, statErr := os.Stat(filepath.Join(res.Dir, "CLAUDE.md"))
	if err != nil || !res.MissingSource || !os.IsNotExist(statErr) {
		t.Fatalf("res=%+v err=%v claude=%v", res, err, statErr)
	}
}
