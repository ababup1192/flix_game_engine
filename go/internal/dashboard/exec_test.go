package dashboard

// 何を守るか: 全体の fge が本物のプロセスとして起こした子から、listen の 1 行で番号を読めること、
// 子は stdin が閉じたら自分で止まること、stop で止まること。子にはこのテストのバイナリを使う。

import (
	"bytes"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

const childEnv = "FGE_DASHBOARD_TEST_CHILD"

func TestMain(m *testing.M) {
	if os.Getenv(childEnv) == "1" {
		args := os.Args[1:]
		if len(args) > 0 && args[0] == "dashboard" {
			args = args[1:]
		}
		d := Deps{Getwd: os.Getwd, Serve: serveUntilInterrupt, WatchParent: exitWhenStdinCloses, Now: time.Now}
		os.Exit(Main(args, false, os.Stdout, os.Stderr, d))
	}
	os.Exit(m.Run())
}

func selfLauncher(t *testing.T) execLauncher {
	t.Helper()
	t.Setenv(childEnv, "1")
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return execLauncher{log: io.Discard, find: func(string) (string, error) { return exe, nil }}
}

func childGame(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	write(t, filepath.Join(dir, "flix.toml"), "")
	return dir
}

func waitClosed(t *testing.T, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("子が 10 秒たっても止まらない")
	}
}

func TestExecLauncherReadsVersion(t *testing.T) {
	if v, err := selfLauncher(t).Version(childGame(t)); err != nil || v != ContractVersion {
		t.Fatalf("v=%d err=%v", v, err)
	}
}

func TestExecLauncherReadsListenLine(t *testing.T) {
	c, err := selfLauncher(t).startChild(childGame(t), "/g/")
	if err != nil {
		t.Fatal(err)
	}
	defer c.stop()
	req, _ := http.NewRequest("GET", "http://127.0.0.1:"+strconv.Itoa(c.port)+"/g/_api/state", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !bytes.Contains(body, []byte(`"base":"/g/"`)) {
		t.Fatalf("code=%d body=%s", resp.StatusCode, body)
	}
}

func TestExecChildStopsWhenStdinCloses(t *testing.T) {
	c, err := selfLauncher(t).startChild(childGame(t), "/g/")
	if err != nil {
		t.Fatal(err)
	}
	defer c.cmd.Process.Kill()
	c.stdin.Close()
	waitClosed(t, c.done)
}

func TestExecStopEndsChild(t *testing.T) {
	_, done, stop, err := selfLauncher(t).Start(childGame(t), "/g/")
	if err != nil {
		t.Fatal(err)
	}
	stop()
	waitClosed(t, done)
}
