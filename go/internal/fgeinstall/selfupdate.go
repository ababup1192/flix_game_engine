package fgeinstall

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/fetchengine"
	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
)

// FgeSumsName は全体の fge の照合の相手（Release に添える）。
// WhyNot: SHA256SUMS.txt に足さない — 凍結した Studio の self-update がその 1 行を読むので、形を替えない（plans/onboarding.md 2.3）。
const FgeSumsName = "fge-SHA256SUMS.txt"

// FgeAssetName は Release に添える全体の fge の名前。
func FgeAssetName(goos, goarch string) (string, error) {
	if goos != "darwin" && goos != "linux" {
		return "", fmt.Errorf("この OS（%s）向けの fge は配っていません（macOS と Linux だけ）", goos)
	}
	if goarch != "amd64" && goarch != "arm64" {
		return "", fmt.Errorf("この CPU（%s）向けの fge は配っていません（amd64 と arm64 だけ）", goarch)
	}
	return "fge-" + goos + "-" + goarch, nil
}

type releaseAsset struct {
	Name string `json:"name"`
	URL  string `json:"browser_download_url"`
}

type releaseInfo struct {
	TagName string         `json:"tag_name"`
	Assets  []releaseAsset `json:"assets"`
}

// SelfUpdateResult は self-update の結果。
type SelfUpdateResult struct {
	Version      string `json:"version"`
	Path         string `json:"path"`
	AlreadyThere bool   `json:"alreadyThere"`
}

// SelfUpdate は Release の最新の fge-<os>-<arch> を取り、照合して <置き場>/bin/fge を差し替える（install.sh と同じ手順）。
func (e *Env) SelfUpdate() (SelfUpdateResult, error) {
	name, err := FgeAssetName(e.GOOS, e.GOARCH)
	if err != nil {
		return SelfUpdateResult{}, err
	}
	body, err := e.fetchQuick(strings.TrimRight(e.ReleasesAPI, "/") + "/repos/" + e.Repo + "/releases/latest")
	if err != nil {
		return SelfUpdateResult{}, fmt.Errorf("Release の最新を引けません: %v", err)
	}
	var rel releaseInfo
	if err := json.Unmarshal(body, &rel); err != nil {
		return SelfUpdateResult{}, fmt.Errorf("Release の応答が読めません: %v", err)
	}
	version := fetchengine.VersionFromTag(rel.TagName)
	binURL, sumsURL := "", ""
	for _, a := range rel.Assets {
		switch a.Name {
		case name:
			binURL = a.URL
		case FgeSumsName:
			sumsURL = a.URL
		}
	}
	if binURL == "" || sumsURL == "" {
		return SelfUpdateResult{}, fmt.Errorf("Release %s には %s と %s が揃っていません", rel.TagName, name, FgeSumsName)
	}
	// WhyNot: 平文の http を受けない — 実行ファイルと照合の相手が同じ経路で来る。
	if !strings.HasPrefix(binURL, "https://") || !strings.HasPrefix(sumsURL, "https://") {
		return SelfUpdateResult{}, fmt.Errorf("Release %s の置き場が https ではありません", rel.TagName)
	}
	sums, err := e.fetchQuick(sumsURL)
	if err != nil {
		return SelfUpdateResult{}, fmt.Errorf("%s を落とせません: %v", FgeSumsName, err)
	}
	want := fetchengine.SumFor(string(sums), name)
	if want == "" {
		return SelfUpdateResult{}, fmt.Errorf("%s に %s の値がありません", FgeSumsName, name)
	}
	dest := filepath.Join(fgehome.BinDir(), "fge")
	res := SelfUpdateResult{Version: version, Path: dest}
	if cur, err := os.ReadFile(dest); err == nil && sha256Hex(cur) == want {
		res.AlreadyThere = true
		return res, nil
	}
	e.progressf("[fge self-update] fge %s を取ります\n", version)
	bin, err := e.fetchLarge(binURL)
	if err != nil {
		return SelfUpdateResult{}, fmt.Errorf("%s を落とせません: %v", name, err)
	}
	if got := sha256Hex(bin); got != want {
		return SelfUpdateResult{}, fmt.Errorf("%s の中身が公開されている値と違います (期待 %s / 実際 %s)", name, want, got)
	}
	if err := replaceExecutable(dest, bin); err != nil {
		return SelfUpdateResult{}, err
	}
	return res, nil
}

// replaceExecutable は別名に書いてから名前を替える。
// WhyNot: dest へ上書きしない — macOS は同じ inode の実行ファイルを書き換えられると、覚えていた署名の検証結果を捨てて次の実行を SIGKILL する。
func replaceExecutable(dest string, body []byte) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(dest), ".fge.*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := bytes.NewReader(body).WriteTo(tmp); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o755); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), dest)
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
