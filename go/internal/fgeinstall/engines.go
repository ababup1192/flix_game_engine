package fgeinstall

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/fetchengine"
	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
)

// LatestMaxAge より古い latest.json だけを問い合わせ直す（1 日 1 回まで）。
const LatestMaxAge = 24 * time.Hour

// InstalledVersions は手元にある、開き終えた engine の版（古い順）。
func InstalledVersions() []string {
	entries, err := os.ReadDir(fgehome.EnginesDir())
	if err != nil {
		return nil
	}
	var versions []string
	for _, e := range entries {
		name := e.Name()
		// WhyNot: 名前の字だけで数えない — 開いている途中の "<版>.partial-<pid>" も版の字として読める。
		if !e.IsDir() || strings.Contains(name, ".partial-") || !fetchengine.IsVersionName(name) {
			continue
		}
		if fgehome.IsComplete(fgehome.EngineDir(name)) {
			versions = append(versions, name)
		}
	}
	sort.Slice(versions, func(i, j int) bool { return fetchengine.IsNewer(versions[i], versions[j]) })
	return versions
}

// NewestInstalled は手元の一番新しい版。無ければ空。
func NewestInstalled() string {
	v := InstalledVersions()
	if len(v) == 0 {
		return ""
	}
	return v[len(v)-1]
}

// RefreshLatest は latest.json を返す。控えが 1 日より古ければ Release に問い合わせて書き直す。
// 問い合わせに失敗した時は、控えがあればそれと、失敗の理由を返す（止めない）。
func (e *Env) RefreshLatest(force bool) (fgehome.Latest, bool, error) {
	cached, ok := fgehome.ReadLatest()
	if ok && !force && e.Now().Sub(cached.CheckedAt) < LatestMaxAge {
		return cached, true, nil
	}
	found, err := fetchengine.LookUpLatest(e.ReleasesAPI, e.Repo, e.fetchQuick)
	if err != nil {
		return cached, ok, err
	}
	l := fgehome.Latest{Version: found.Version, CheckedAt: e.Now().UTC()}
	if err := fgehome.WriteLatest(l); err != nil {
		return l, true, fmt.Errorf("latest.json を書けません: %v", err)
	}
	return l, true, nil
}

// InstallResult は engines install の結果。
type InstallResult struct {
	Version      string `json:"version"`
	EngineDir    string `json:"engineDir"`
	EngineWasSet bool   `json:"engineAlreadyThere"`
	JDK          string `json:"jdk,omitempty"`
	JDKDir       string `json:"jdkDir,omitempty"`
	JDKWasSet    bool   `json:"jdkAlreadyThere,omitempty"`
}

// ResolveVersion は "latest" を Release の最新の版に替える。
func (e *Env) ResolveVersion(version string) (string, error) {
	if version != "latest" {
		if !fetchengine.IsVersionName(version) {
			return "", fmt.Errorf("版 %q は読めません（例: 0.108.0 か latest）", version)
		}
		return version, nil
	}
	l, ok, err := e.RefreshLatest(false)
	if !ok {
		return "", fmt.Errorf("Release の最新の版を引けません: %v", err)
	}
	return l.Version, nil
}

// Install は engine の版と、その版の mk/jdk.mk が指す JDK を取る。どちらも揃っていれば何もしない。
func (e *Env) Install(version string) (InstallResult, error) {
	version, err := e.ResolveVersion(version)
	if err != nil {
		return InstallResult{}, err
	}
	if !fgehome.IsComplete(fgehome.EngineDir(version)) {
		e.progressf("[fge engines] engine %s を取ります（約 120 MB）\n", version)
	}
	dir, already, err := fetchengine.InstallStandalone(fetchengine.Standalone{
		Version:  version,
		Into:     fgehome.EnginesDir(),
		APIBase:  e.ReleasesAPI,
		Repo:     e.Repo,
		Progress: e.Progress,
		Get:      e.fetchLarge,
		RunExe:   e.RunExe,
	})
	if err != nil {
		return InstallResult{}, err
	}
	res := InstallResult{Version: version, EngineDir: dir, EngineWasSet: already}
	// WhyNot: ここでワークスペースのフォルダを作らない — dashboard を開いたことの無い人の home に、頼まれていないフォルダが増える。
	if _, err := SyncWorkspaceFolder(false); err != nil {
		e.progressf("[fge engines] ワークスペースの AGENTS.md を写し直せませんでした: %v\n", err)
	}
	spec, ok, err := fgehome.ReadJDKSpec(dir)
	if err != nil {
		return res, err
	}
	if !ok {
		e.progressf("[fge engines] engine %s は %s を持たない版なので、JDK は取りません（PATH の java を使います）\n", version, fgehome.JDKSpecFile)
		return res, nil
	}
	jdkDir, jdkAlready, err := e.InstallJDK(spec)
	if err != nil {
		return res, err
	}
	res.JDK, res.JDKDir, res.JDKWasSet = spec.Name(), jdkDir, jdkAlready
	return res, nil
}

// GamesUsing は workspace.json のゲームのうち、flix.toml が version を指す物。
func GamesUsing(version string) ([]fgehome.Game, error) {
	ws, err := fgehome.ReadWorkspace()
	if err != nil {
		return nil, fmt.Errorf("workspace.json を読めません: %v", err)
	}
	var using []fgehome.Game
	for _, g := range ws.Games {
		if fgehome.ReadGameEngineVersion(g.Dir) == version {
			using = append(using, g)
		}
	}
	return using, nil
}

// RemoveResult は engines remove の結果。
type RemoveResult struct {
	Version    string `json:"version"`
	RemovedJDK string `json:"removedJdk,omitempty"`
}

// Remove は engine の版を消す。workspace.json にその版を使うゲームがあれば止める。
// その版の JDK を他の版が使っていなければ、JDK も消す。
func (e *Env) Remove(version string) (RemoveResult, error) {
	if !fetchengine.IsVersionName(version) {
		return RemoveResult{}, fmt.Errorf("版 %q は読めません（例: 0.108.0）", version)
	}
	dir := fgehome.EngineDir(version)
	if _, err := os.Stat(dir); err != nil {
		return RemoveResult{}, fmt.Errorf("engine %s は手元にありません（%s）", version, dir)
	}
	using, err := GamesUsing(version)
	if err != nil {
		return RemoveResult{}, err
	}
	if len(using) > 0 {
		var names []string
		for _, g := range using {
			names = append(names, g.Name+"（"+g.Dir+"）")
		}
		return RemoveResult{}, fmt.Errorf("engine %s を使っているゲームがあるので消しません: %s", version, strings.Join(names, "・"))
	}
	unlock, err := fgehome.Lock(fgehome.LockPath(), e.Progress)
	if err != nil {
		return RemoveResult{}, fmt.Errorf("排他を取れません: %v", err)
	}
	defer unlock()
	spec, hasSpec, _ := fgehome.ReadJDKSpec(dir)
	if err := fgehome.RemoveReadOnly(dir); err != nil {
		return RemoveResult{}, fmt.Errorf("%s を消せません: %v", dir, err)
	}
	res := RemoveResult{Version: version}
	if hasSpec && !jdkUsedByAny(spec) {
		if _, err := os.Stat(spec.Dir()); err == nil {
			if err := fgehome.RemoveReadOnly(spec.Dir()); err != nil {
				return res, fmt.Errorf("%s を消せません: %v", spec.Dir(), err)
			}
			res.RemovedJDK = spec.Name()
		}
	}
	return res, nil
}

func jdkUsedByAny(spec fgehome.JDKSpec) bool {
	for _, v := range InstalledVersions() {
		if other, ok, _ := fgehome.ReadJDKSpec(fgehome.EngineDir(v)); ok && other == spec {
			return true
		}
	}
	return false
}

// diskHint は取得が書けずに止まった時に添える 1 行。
func diskHint(err error) string {
	if err == nil {
		return ""
	}
	msg := err.Error()
	if strings.Contains(msg, "no space left") {
		return "\n  ディスクが足りません。使っていない版を消してください: fge engines remove <版>（手元の版は fge engines）"
	}
	return ""
}

func relHome(path string) string {
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		if rel, err := filepath.Rel(home, path); err == nil && !strings.HasPrefix(rel, "..") {
			return filepath.Join("~", rel)
		}
	}
	return path
}
