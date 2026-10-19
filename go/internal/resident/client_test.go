package resident

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// engineRoot は resident 節だけの hooks.json を持つ根（印の置き場はテストの一時フォルダ）。
func engineRoot(t *testing.T) string {
	t.Helper()
	d := t.TempDir()
	cache := filepath.Join(d, "cache")
	writeFile(t, filepath.Join(d, "bin", "lint-rules", "hooks.json"), fmt.Sprintf(`{"resident": {
  "cacheDir": %q, "stateHashLen": 16,
  "maxDaemons": {"gbPerDaemon": 8, "cap": 2, "fallback": 1, "envVar": "RESIDENT_TEST_MAX"},
  "heap": {"memoryShare": 0.4, "minMB": 2048, "maxMB": 6144, "fallbackMB": 3072, "envVar": "RESIDENT_TEST_HEAP"},
  "readyWaitSec": 3, "connectTimeoutSec": 1, "helloTimeoutSec": 2, "quitWaitSec": 1,
  "silentSec": 120, "silentEnvVar": "HEADLESS_SILENT_SECS",
  "entryDefault": "E2e.serveHeadless", "entryEnvVar": "HEADLESS_RESIDENT_ENTRY"}}`, cache))
	return d
}

// game は jar.manifest を持つゲームの根（symlink を辿った絶対パス）。
func game(t *testing.T) string {
	t.Helper()
	d, err := ResolveRoot(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(d, ManifestFile), "m1\n")
	return d
}

type fake struct {
	root     string
	manifest string
	run      func(w http.ResponseWriter, f http.Flusher)
	quits    atomic.Int32
	entry    atomic.Value
}

func (f *fake) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/hello":
		fmt.Fprintf(w, "ok hello\npid=0\ndir=%s\nmanifest=%s\nserved=1\nbusy=\nidle.left=100\nidle.window=180\nenv.LANG=C\njob=SceneRender.one still\n",
			f.root, f.manifest)
	case "/run":
		f.entry.Store(r.URL.Query().Get("entry"))
		fl, _ := w.(http.Flusher)
		f.run(w, fl)
	case "/quit":
		f.quits.Add(1)
		fmt.Fprint(w, "ok quit\n")
	}
}

func serveFake(t *testing.T, f *fake) {
	t.Helper()
	srv := httptest.NewServer(f)
	t.Cleanup(srv.Close)
	u, _ := url.Parse(srv.URL)
	writeFile(t, filepath.Join(f.root, InfoFile), fmt.Sprintf(`{"pid":"0","port":%q,"dir":%q,"manifest":%q,"started":"x"}`,
		u.Port(), f.root, f.manifest))
}

func lines(body ...string) func(w http.ResponseWriter, f http.Flusher) {
	return func(w http.ResponseWriter, f http.Flusher) {
		for _, l := range body {
			fmt.Fprintln(w, l)
			f.Flush()
		}
	}
}

type result struct {
	code           int
	stdout, stderr string
}

func runWith(t *testing.T, root string, env map[string]string) result {
	t.Helper()
	if env == nil {
		env = map[string]string{"LANG": "C"}
	}
	var out, errOut strings.Builder
	code := Run(engineRoot(t), RunOptions{Dir: root, Entry: "SceneRender.one", Env: env, Stdout: &out, Stderr: &errOut})
	return result{code, out.String(), errOut.String()}
}

func TestRunWithoutResidentOrJarIs125(t *testing.T) {
	if r := runWith(t, game(t), nil); r.code != Unusable {
		t.Fatalf("code = %d", r.code)
	}
}

func TestRunWhenSpawnedJavaExitsIs125(t *testing.T) {
	root := game(t)
	writeFile(t, filepath.Join(root, "build", "headless", "headless.jar"), "")
	var out, errOut strings.Builder
	code := Run(engineRoot(t), RunOptions{Dir: root, Entry: "SceneRender.one", Java: "/usr/bin/false",
		Env: map[string]string{"LANG": "C"}, Stdout: &out, Stderr: &errOut})
	if code != Unusable {
		t.Fatalf("code = %d", code)
	}
}

func TestRunResidentEntryItselfIs125(t *testing.T) {
	var out, errOut strings.Builder
	code := Run(engineRoot(t), RunOptions{Dir: game(t), Entry: "E2e.serveHeadless", Env: map[string]string{},
		Stdout: &out, Stderr: &errOut})
	if code != Unusable {
		t.Fatalf("code = %d", code)
	}
}

func TestRunReturnsEntryCode(t *testing.T) {
	root := game(t)
	serveFake(t, &fake{root: root, manifest: "m1", run: lines("o hello", "e warn", "x 3")})
	if r := runWith(t, root, nil); r.code != 3 {
		t.Fatalf("code = %d", r.code)
	}
}

func TestRunCopiesStdout(t *testing.T) {
	root := game(t)
	serveFake(t, &fake{root: root, manifest: "m1", run: lines("o hello", "o x 0", "e warn", "x 0")})
	if r := runWith(t, root, nil); r.stdout != "hello\nx 0\n" {
		t.Fatalf("stdout = %q", r.stdout)
	}
}

func TestRunCopiesStderr(t *testing.T) {
	root := game(t)
	serveFake(t, &fake{root: root, manifest: "m1", run: lines("o hello", "e warn", "x 0")})
	if r := runWith(t, root, nil); r.stderr != "warn\n" {
		t.Fatalf("stderr = %q", r.stderr)
	}
}

func TestRunSendsEntryName(t *testing.T) {
	root := game(t)
	f := &fake{root: root, manifest: "m1", run: lines("x 0")}
	serveFake(t, f)
	runWith(t, root, nil)
	if got, _ := f.entry.Load().(string); got != "SceneRender.one" {
		t.Fatalf("entry = %q", got)
	}
}

func TestRunOOMIs125(t *testing.T) {
	root := game(t)
	serveFake(t, &fake{root: root, manifest: "m1", run: lines("o a", "x oom")})
	if r := runWith(t, root, nil); r.code != Unusable {
		t.Fatalf("code = %d", r.code)
	}
}

func TestRunBrokenStreamAfterOutputPrintsSeparator(t *testing.T) {
	root := game(t)
	serveFake(t, &fake{root: root, manifest: "m1", run: lines("o a")})
	if r := runWith(t, root, nil); !strings.Contains(r.stderr, "[resident] 常駐との流れが途中で切れた") {
		t.Fatalf("stderr = %q", r.stderr)
	}
}

func TestRunManifestMismatchQuitsResident(t *testing.T) {
	root := game(t)
	f := &fake{root: root, manifest: "old", run: lines("x 0")}
	serveFake(t, f)
	runWith(t, root, nil)
	if f.quits.Load() != 1 {
		t.Fatalf("/quit の数 = %d", f.quits.Load())
	}
}

func TestRunManifestMismatchIs125(t *testing.T) {
	root := game(t)
	serveFake(t, &fake{root: root, manifest: "old", run: lines("x 0")})
	if r := runWith(t, root, nil); r.code != Unusable {
		t.Fatalf("code = %d", r.code)
	}
}

func TestRunEnvMismatchIs125(t *testing.T) {
	root := game(t)
	serveFake(t, &fake{root: root, manifest: "m1", run: lines("x 0")})
	if r := runWith(t, root, map[string]string{"LANG": "ja"}); r.code != Unusable {
		t.Fatalf("code = %d", r.code)
	}
}

func TestRunSilenceIs125(t *testing.T) {
	root := game(t)
	serveFake(t, &fake{root: root, manifest: "m1", run: func(w http.ResponseWriter, f http.Flusher) {
		fmt.Fprintln(w, "o a")
		f.Flush()
		time.Sleep(time.Second)
	}})
	r := runWith(t, root, map[string]string{"LANG": "C", "HEADLESS_SILENT_SECS": "0.2"})
	if r.code != Unusable {
		t.Fatalf("code = %d", r.code)
	}
}

func TestRunSpawnsResidentWithMarkerEnv(t *testing.T) {
	root := game(t)
	writeFile(t, filepath.Join(root, "build", "headless", "headless.jar"), "")
	f := &fake{root: root, manifest: "m1", run: lines("o spawned", "x 0")}
	srv := httptest.NewServer(f)
	t.Cleanup(srv.Close)
	u, _ := url.Parse(srv.URL)
	dump := filepath.Join(t.TempDir(), "env")
	java := filepath.Join(t.TempDir(), "java")
	writeFile(t, java, "#!/bin/sh\nenv > \"$HEADLESS_DUMP\"\necho \"[headless] ready port=$HEADLESS_FAKE_PORT pid=$$\"\nexec sleep 3\n")
	_ = os.Chmod(java, 0o755)
	var out, errOut strings.Builder
	Run(engineRoot(t), RunOptions{Dir: root, Entry: "SceneRender.one", Java: java,
		Env:    map[string]string{"LANG": "C", "HEADLESS_FAKE_PORT": u.Port(), "HEADLESS_DUMP": dump},
		Stdout: &out, Stderr: &errOut})
	raw, _ := os.ReadFile(dump)
	if !strings.Contains(string(raw), "HEADLESS_RESIDENT=1") {
		t.Fatalf("起こした env = %q", raw)
	}
}
