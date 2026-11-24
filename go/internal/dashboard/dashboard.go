// Package dashboard は fge dashboard の本体。1 台に 1 つ、前面でワークスペースのサーバー（127.0.0.1:8790）を立てる。
// `/` はワークスペースの頁（新しいゲームを作るカード・ゲームの一覧）、`/<ゲーム名>/` はそのゲームのカード、API は `/_api/`。
// 決まりの本文は plans/onboarding.md の 2.6 と plans/dashboard.md の 6・13 節。
package dashboard

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/claudeopen"
	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
	"github.com/ababup1192/flix_game_engine/go/internal/fgeinstall"
)

const (
	exitDone     = 0
	exitProblem  = 1
	exitBadUsage = 2
)

// DefaultPort はワークスペースのサーバーの番号。
const DefaultPort = 8790

const usage = "使い方: fge dashboard [--port <番号>] [--no-open] [--dir <ワークスペースのフォルダ>]"

// Deps は外の世界（網・ブラウザ・待ち受け）とつなぐ所。テストは欄を差し替える。
type Deps struct {
	Getwd         func() (string, error)
	OpenBrowser   func(url string) error
	Install       func(progress io.Writer) error
	RefreshLatest func()
	// IsOurServer は port で既に自分のサーバーが待っているか（GET /_api/whoami）。
	IsOurServer func(port int) bool
	// Serve は ln で h を出し、人が止めるまで返らない。
	Serve func(ln net.Listener, h http.Handler) error
}

// DefaultDeps は本物の網・ブラウザ・待ち受けを使う。
func DefaultDeps(goos string, env *fgeinstall.Env) Deps {
	return Deps{
		Getwd: os.Getwd,
		OpenBrowser: func(link string) error {
			name, args, ok := claudeopen.OpenCommand(goos, link)
			if !ok {
				return fmt.Errorf("この OS（%s）でブラウザを開く方法を知りません", goos)
			}
			return exec.Command(name, args...).Run()
		},
		Install: func(progress io.Writer) error {
			e := *env
			e.Progress = io.MultiWriter(os.Stderr, progress)
			_, err := e.Install("latest")
			return err
		},
		RefreshLatest: func() {
			// WhyNot: 引けなかった時に止めない — オフラインでも手元の engine で頁は出せる（plans/onboarding.md 10 節）。
			if _, _, err := env.RefreshLatest(false); err != nil {
				fmt.Fprintf(os.Stderr, "[fge dashboard] Release の最新を引けませんでした（続けます）: %v\n", err)
			}
		},
		IsOurServer: isOurServer,
		Serve:       serveUntilInterrupt,
	}
}

// Run は fge dashboard の本体。出力は居座るサーバーなので stdout へ直に書く。
func Run(args []string, stdout, stderr io.Writer, d Deps) int {
	port := DefaultPort
	var noOpen bool
	var dir string
	fs := flag.NewFlagSet("dashboard", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.IntVar(&port, "port", DefaultPort, "待つ番号（塞がっていれば空いた番号）")
	fs.BoolVar(&noOpen, "no-open", false, "ブラウザを開かない")
	fs.StringVar(&dir, "dir", "", "ワークスペースのフォルダ（workspace.json に残す。既定 ~/flix-games）")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 || port < 0 || port > 65535 {
		fmt.Fprintln(stderr, usage)
		return exitBadUsage
	}

	openPath := "/"
	game, err := prepareWorkspace(dir, d.Getwd)
	if err != nil {
		fmt.Fprintf(stderr, "!! %v\n", err)
		return exitProblem
	}
	if game != "" {
		openPath = "/" + url.PathEscape(game) + "/"
		fmt.Fprintf(stdout, "[fge dashboard] ゲーム %s をワークスペースの一覧に足しました\n", game)
	}

	if port != 0 && d.IsOurServer(port) {
		link := localURL(port, openPath)
		fmt.Fprintf(stdout, "[fge dashboard] 既に %s で立っています。ブラウザだけ開きます\n", localURL(port, "/"))
		openOrPrint(stdout, d, link, noOpen)
		return exitDone
	}

	synced, err := fgeinstall.SyncWorkspaceFolder(true)
	if err != nil {
		fmt.Fprintf(stderr, "!! %v\n", err)
		return exitProblem
	}
	fgeinstall.ReportFollowLatestSkills(stdout, "[fge dashboard]")
	if synced.MissingSource {
		fmt.Fprintf(stderr, "[fge dashboard] engine %s は %s を持たない版なので、ワークスペースの AGENTS.md を置けません\n",
			synced.EngineVersion, fgeinstall.WorkspaceAgentsSrc)
	}

	ln, err := listenLocal(port)
	if err != nil {
		fmt.Fprintf(stderr, "!! 127.0.0.1 で待てません: %v\n", err)
		return exitProblem
	}
	actual := ln.Addr().(*net.TCPAddr).Port
	if port != 0 && actual != port {
		fmt.Fprintf(stdout, "[fge dashboard] %d は別の物が使っているので %d で待ちます\n", port, actual)
	}

	state := &installState{}
	startInstall := func() {
		if !state.begin() {
			return
		}
		go func() {
			err := d.Install(state)
			if err == nil {
				if _, serr := fgeinstall.SyncWorkspaceFolder(true); serr != nil {
					fmt.Fprintf(state, "ワークスペースの AGENTS.md を写せませんでした: %v\n", serr)
				}
			}
			state.finish(err)
		}()
	}
	srv := NewServer(actual, state, startInstall, fgehome.ReadLatest)
	if d.RefreshLatest != nil {
		go d.RefreshLatest()
	}
	if fgeinstall.NewestInstalled() == "" {
		fmt.Fprintln(stdout, "[fge dashboard] 手元に engine が無いので、最新の版を取ります（進み具合は頁にも出ます）")
		startInstall()
	}

	fmt.Fprintf(stdout, "[fge dashboard] %s で待っています（ワークスペース: %s・Ctrl-C で止める）\n", localURL(actual, "/"), synced.Dir)
	openOrPrint(stdout, d, localURL(actual, openPath), noOpen)
	if err := d.Serve(ln, srv); err != nil {
		fmt.Fprintf(stderr, "!! %v\n", err)
		return exitProblem
	}
	return exitDone
}

func openOrPrint(stdout io.Writer, d Deps, link string, noOpen bool) {
	if noOpen {
		fmt.Fprintf(stdout, "[fge dashboard] 開く頁: %s\n", link)
		return
	}
	if err := d.OpenBrowser(link); err != nil {
		fmt.Fprintf(stdout, "[fge dashboard] ブラウザを開けませんでした。次を開いてください: %s\n", link)
		return
	}
	fmt.Fprintf(stdout, "[fge dashboard] ブラウザで開きました: %s\n", link)
}

func localURL(port int, path string) string {
	return "http://127.0.0.1:" + strconv.Itoa(port) + path
}

// prepareWorkspace は --dir を workspace.json に残し、今のフォルダがゲームの中ならそのゲームを一覧に足して名前を返す。
func prepareWorkspace(dir string, getwd func() (string, error)) (string, error) {
	gameDir := ""
	if wd, err := getwd(); err == nil {
		gameDir = findGameRoot(wd)
	}
	if dir == "" && gameDir == "" {
		return "", nil
	}
	unlock, err := fgehome.Lock(fgehome.LockPath(), os.Stderr)
	if err != nil {
		return "", fmt.Errorf("排他を取れません: %v", err)
	}
	defer unlock()
	ws, err := fgehome.ReadWorkspace()
	if err != nil {
		return "", fmt.Errorf("workspace.json を読めません: %v", err)
	}
	if dir != "" {
		abs, err := filepath.Abs(dir)
		if err != nil {
			return "", err
		}
		ws.Dir = abs
	}
	name := ""
	if gameDir != "" {
		name = gameName(ws, gameDir)
		ws.AddGame(fgehome.Game{Name: name, Dir: gameDir})
	}
	if err := fgehome.WriteWorkspace(ws); err != nil {
		return "", fmt.Errorf("workspace.json を書けません: %v", err)
	}
	return name, nil
}

// gameName は一覧に足す名前。同じフォルダが既にあればその名前、別のフォルダが同じ名前を使っていれば -2 から番号を付ける。
func gameName(ws fgehome.Workspace, gameDir string) string {
	taken := map[string]bool{}
	for _, g := range ws.Games {
		if g.Dir == gameDir {
			return g.Name
		}
		taken[g.Name] = true
	}
	base := filepath.Base(gameDir)
	name := base
	for i := 2; taken[name]; i++ {
		name = base + "-" + strconv.Itoa(i)
	}
	return name
}

// findGameRoot は wd から上へ flix.toml のあるフォルダを探す。engine のリポと置き場の engine はゲームとして扱わない。
func findGameRoot(wd string) string {
	enginesDir, _ := filepath.Abs(fgehome.EnginesDir())
	for dir := wd; ; dir = filepath.Dir(dir) {
		if strings.HasPrefix(dir, enginesDir+string(filepath.Separator)) || dir == enginesDir {
			return ""
		}
		if info, err := os.Stat(filepath.Join(dir, "flix.toml")); err == nil && info.Mode().IsRegular() {
			if isEngineRoot(dir) {
				return ""
			}
			return dir
		}
		if filepath.Dir(dir) == dir {
			return ""
		}
	}
}

func isEngineRoot(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, "agents-pack", "manifest.json"))
	return err == nil
}

func isOurServer(port int) bool {
	client := http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(localURL(port, "/_api/whoami"))
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false
	}
	var who struct {
		App string `json:"app"`
	}
	if json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&who) != nil {
		return false
	}
	return who.App == AppName
}

func serveUntilInterrupt(ln net.Listener, h http.Handler) error {
	srv := &http.Server{Handler: h, ReadHeaderTimeout: 10 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()
	select {
	case err := <-errc:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		return srv.Shutdown(shutdown)
	}
}
