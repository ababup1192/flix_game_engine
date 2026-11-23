// Package fgeinstall は、配った engine を使う人の置き場（~/.flix_ge）へ engine・JDK・全体の fge を取ってくる。
// fge engines・fge engines install / remove・fge self-update の本体。決まりの本文は plans/onboarding.md の 2.4・2.7・2.8・2.9。
package fgeinstall

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"time"
)

// DefaultRepo は Release を引く GitHub のリポジトリ。
const DefaultRepo = "ababup1192/flix_game_engine"

// Env は外の世界（網・時計・実行）とつなぐ所。テストは欄を差し替える。
type Env struct {
	ReleasesAPI string // GitHub API の根（FGE_RELEASES_API）
	JDKURL      string // Azul の metadata API の根（FGE_JDK_URL）
	Repo        string
	Client      *http.Client
	Progress    io.Writer
	Now         func() time.Time
	RunExe      func(path string, args ...string) error
	GOOS        string
	GOARCH      string
}

// DefaultEnv は環境変数と既定値から Env を作る。
// WhyNot: 進み具合を out に貯めず stderr へ直に書く — fge は出力を終わりにまとめて吐くので、数分かかる取得の間 1 行も届かない。
func DefaultEnv() *Env {
	return &Env{
		ReleasesAPI: envOr("FGE_RELEASES_API", "https://api.github.com"),
		JDKURL:      envOr("FGE_JDK_URL", "https://api.azul.com"),
		Repo:        DefaultRepo,
		Client:      http.DefaultClient,
		Progress:    os.Stderr,
		Now:         time.Now,
		RunExe:      func(path string, args ...string) error { return exec.Command(path, args...).Run() },
		GOOS:        runtime.GOOS,
		GOARCH:      runtime.GOARCH,
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func (e *Env) progressf(format string, args ...any) {
	if e.Progress != nil {
		fmt.Fprintf(e.Progress, format, args...)
	}
}

// open は 1 回取りに行き、本文を開いたまま返す。
func (e *Env) open(url string, timeout time.Duration) (io.ReadCloser, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	// WhyNot: 名乗るのは、GitHub API が User-Agent の無い呼び出しを断るため。
	req.Header.Set("User-Agent", "flix_game_engine-fge")
	client := *e.Client
	client.Timeout = timeout
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, fmt.Errorf("%s が %s を返しました", url, resp.Status)
	}
	return resp.Body, nil
}

// fetch は本文を丸ごと読む。limit を超える物は取りに行く先が違うと見る。
func (e *Env) fetch(url string, timeout time.Duration, limit int64) ([]byte, error) {
	body, err := e.open(url, timeout)
	if err != nil {
		return nil, err
	}
	defer body.Close()
	b, err := io.ReadAll(io.LimitReader(body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, fmt.Errorf("%s の応答が大きすぎます (%d バイトを超えました)", url, limit)
	}
	return b, nil
}

// WhyNot: 問い合わせに長い上限を使わない — オフラインの時に fge engines が何十秒も返らない。
func (e *Env) fetchQuick(url string) ([]byte, error) { return e.fetch(url, 15*time.Second, 8<<20) }

func (e *Env) fetchLarge(url string) ([]byte, error) { return e.fetch(url, 30*time.Minute, 512<<20) }
