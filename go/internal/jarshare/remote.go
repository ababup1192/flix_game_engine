package jarshare

// 段 2: 機械の外（ゲームの repo の GitHub Release の資産）へ置き、そこから取る（docs/design/prebuilt-jar.md の 7 節の 1）。
//
// 置き場は、ゲームの repo の prerelease ReleaseTag に <鍵>.jar と <鍵>.json（Meta）を並べた物。
// 取る・置くのは gh で、gh のトークンが読める人だけが取れ、置けるのは作り手だけ（7 節の 4: 署名は付けない）。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// ReleaseTag は段 2 の置き場にする Release の名前（tag）。
const ReleaseTag = "headless-jar-cache"

// RemoteEnv を off にすると段 2 を使わない（段 1 は使う）。
const RemoteEnv = "FGE_PREBUILT_JAR"

// RemoteTimeout は段 2 から 1 本取るのを待つ長さ。超えたら諦めて手元で作る。
const RemoteTimeout = 30 * time.Second

// Meta は <鍵>.json の中身。取る側は、jar の中身の SHA-256・元の指紋・入口の束を、ここと今の物で比べる。
type Meta struct {
	Format     string `json:"format"`
	Key        string `json:"key"`
	Source     string `json:"source"`
	SHA256     string `json:"sha256"`
	Dispatcher string `json:"dispatcher"`
	Commit     string `json:"commit"`
	Created    string `json:"created"`
}

// GH は gh コマンドを流す口（テストでは偽物に替える）。dir は gh を流す作業場所（release download の置き先）。
type GH interface {
	Run(ctx context.Context, dir string, args ...string) ([]byte, error)
}

type execGH struct{ bin string }

func (g execGH) Run(ctx context.Context, dir string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, g.bin, args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		return out, fmt.Errorf("gh %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return out, nil
}

// FindGH は PATH の gh を返す。無ければ false（段 2 を使わない）。
func FindGH() (GH, bool) {
	bin, err := exec.LookPath("gh")
	if err != nil {
		return nil, false
	}
	return execGH{bin: bin}, true
}

// RemoteEnabled は段 2 を使うか（RemoteEnv が off・0 でなければ使う）。
func RemoteEnabled(env func(string) string) bool {
	switch env(RemoteEnv) {
	case "off", "0":
		return false
	}
	return true
}

var githubRemote = regexp.MustCompile(`github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$`)

// ParseGitHubRepo は git の remote の URL から "持ち主/名前" を取り出す（ssh・https の両方）。
func ParseGitHubRepo(url string) (string, bool) {
	m := githubRemote.FindStringSubmatch(strings.TrimSpace(url))
	if m == nil {
		return "", false
	}
	return m[1] + "/" + m[2], true
}

// RepoOf はゲームの根の origin の GitHub の "持ち主/名前"。
func RepoOf(root string) (string, error) {
	out, err := exec.Command("git", "-C", root, "remote", "get-url", "origin").Output()
	if err != nil {
		return "", fmt.Errorf("origin の URL を読めない: %v", err)
	}
	repo, ok := ParseGitHubRepo(string(out))
	if !ok {
		return "", fmt.Errorf("origin が GitHub ではない: %s", strings.TrimSpace(string(out)))
	}
	return repo, nil
}

// CheckMeta は落とした <鍵>.json と jar が、今の入力と合うか。合わなければ訳（空なら合う）。
func CheckMeta(meta Meta, key string, in Inputs, jarSHA string) string {
	switch {
	case meta.Format != Format:
		return "置き場の形の版が違う"
	case meta.Key != key:
		return "置き場の鍵が違う"
	case meta.SHA256 == "" || meta.SHA256 != jarSHA:
		return "jar の SHA-256 が違う"
	case meta.Source != in.Source:
		return "置いた時の元の指紋が今と違う"
	case meta.Dispatcher != in.Dispatcher:
		return "置いた時の入口の束が今と違う"
	}
	return ""
}

// FetchRemote は段 2 から鍵の jar を落とし、確かめてから段 1 の置き場へ入れる。入れられたら nil（その後は Fetch で写す）。
func FetchRemote(ctx context.Context, gh GH, repo, cache, key string, in Inputs) error {
	if cache == "" || key == "" {
		return errors.New("置き場か鍵が無い")
	}
	if err := os.MkdirAll(cache, 0o755); err != nil {
		return err
	}
	tmp, err := os.MkdirTemp(cache, ".dl-"+key[:12]+"-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	ctx, cancel := context.WithTimeout(ctx, RemoteTimeout)
	defer cancel()
	if _, err := gh.Run(ctx, tmp, "release", "download", ReleaseTag, "-R", repo,
		"-p", key+".json", "-p", key+".jar", "-D", tmp, "--clobber"); err != nil {
		return err
	}
	raw, err := os.ReadFile(filepath.Join(tmp, key+".json"))
	if err != nil {
		return err
	}
	var meta Meta
	if err := json.Unmarshal(raw, &meta); err != nil {
		return fmt.Errorf("%s.json を読めない: %v", key, err)
	}
	jarPath := filepath.Join(tmp, key+".jar")
	jarSHA, err := fileSHA(jarPath)
	if err != nil {
		return err
	}
	if why := CheckMeta(meta, key, in, jarSHA); why != "" {
		return errors.New(why)
	}
	return storeEntry(cache, key, in, jarPath)
}

// Asset は段 2 の置き場の資産 1 つ。
type Asset struct {
	Name      string    `json:"name"`
	Size      int64     `json:"size"`
	CreatedAt time.Time `json:"createdAt"`
}

// listAssets は段 2 の置き場の資産の一覧。置き場（Release）が無ければ false。
func listAssets(ctx context.Context, gh GH, repo string) ([]Asset, bool, error) {
	out, err := gh.Run(ctx, "", "release", "view", ReleaseTag, "-R", repo, "--json", "assets")
	if err != nil {
		if strings.Contains(err.Error(), "release not found") {
			return nil, false, nil
		}
		return nil, false, err
	}
	var view struct {
		Assets []Asset `json:"assets"`
	}
	if err := json.Unmarshal(out, &view); err != nil {
		return nil, true, err
	}
	return view.Assets, true, nil
}

// PublishRemote は段 1 にある鍵の 1 本を、段 2 へ上げる。もう同じ鍵があれば何もしない。置き場（Release）が無ければ作る。
func PublishRemote(ctx context.Context, gh GH, repo, cache, key, commit string, now time.Time) error {
	dir := filepath.Join(cache, key)
	if _, err := os.Stat(dir); err != nil {
		return fmt.Errorf("段 1 に鍵 %s が無い: %v", key[:12], err)
	}
	assets, exists, err := listAssets(ctx, gh, repo)
	if err != nil {
		return err
	}
	for _, a := range assets {
		if a.Name == key+".jar" {
			return nil
		}
	}
	if !exists {
		// WhyNot: draft にしない — draft の資産は repo に書ける人にしか見えず、読むだけの人の Studio が取れない。
		if _, err := gh.Run(ctx, "", "release", "create", ReleaseTag, "-R", repo, "--prerelease",
			"--title", "headless.jar の置き場（bin/fge jar）",
			"--notes", "窓なしのゲームの jar を作り手（Mac mini）が置く所。手で触らない（engine の docs/design/prebuilt-jar.md）。"); err != nil {
			return err
		}
	}
	tmp, err := os.MkdirTemp(cache, ".up-"+key[:12]+"-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	meta := Meta{
		Format: Format, Key: key,
		Source:     strings.TrimSpace(readText(filepath.Join(dir, sourceName))),
		SHA256:     strings.TrimSpace(readText(filepath.Join(dir, shaName))),
		Dispatcher: readText(filepath.Join(dir, dispatcherName)),
		Commit:     commit, Created: now.UTC().Format(time.RFC3339),
	}
	raw, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(tmp, key+".json"), raw, 0o644); err != nil {
		return err
	}
	if err := copyAtomic(filepath.Join(dir, jarName), filepath.Join(tmp, key+".jar")); err != nil {
		return err
	}
	// WhyNot: jar を先に上げる — 取る側は <鍵>.json と <鍵>.jar を両方落とすので、片方しか無い間は取れずに手元で作る。
	// json だけが先にあると、無い jar を探しに行く回が増える。
	if _, err := gh.Run(ctx, tmp, "release", "upload", ReleaseTag, "-R", repo, key+".jar"); err != nil {
		return err
	}
	_, err = gh.Run(ctx, tmp, "release", "upload", ReleaseTag, "-R", repo, key+".json")
	return err
}

// PlanRemotePrune は段 2 から消す資産の名前を決める（純粋）。鍵ごとに束ね、上げてから maxAge より古い鍵と、
// 新しい順に足して maxBytes を超えた鍵を消す。keep の鍵（今の master の物）は消さない。
//
// WhyNot: 段 2 は「最後に使ってから」で数えない — 取った時刻を Release に残す口が無い（資産を書き直すしかない）ため、上げてからで数える。
func PlanRemotePrune(assets []Asset, now time.Time, maxAge time.Duration, maxBytes int64, keep string) []string {
	byKey := map[string][]Asset{}
	var entries []Entry
	for _, a := range assets {
		key := strings.TrimSuffix(strings.TrimSuffix(a.Name, ".jar"), ".json")
		if key == a.Name {
			continue // 置き場の物でない資産は触らない
		}
		byKey[key] = append(byKey[key], a)
	}
	for key, list := range byKey {
		e := Entry{Key: key}
		for _, a := range list {
			e.Bytes += a.Size
			if a.CreatedAt.After(e.Used) {
				e.Used = a.CreatedAt
			}
		}
		if key == keep {
			e.Used = now
		}
		entries = append(entries, e)
	}
	var names []string
	for _, key := range PlanPrune(entries, now, maxAge, maxBytes) {
		if key == keep {
			continue
		}
		for _, a := range byKey[key] {
			names = append(names, a.Name)
		}
	}
	return names
}

// PruneRemote は段 2 の古い資産を消し、消した数を返す。
func PruneRemote(ctx context.Context, gh GH, repo, keep string, now time.Time) (int, error) {
	assets, exists, err := listAssets(ctx, gh, repo)
	if err != nil || !exists {
		return 0, err
	}
	removed := 0
	for _, name := range PlanRemotePrune(assets, now, MaxAge, MaxBytes, keep) {
		if _, err := gh.Run(ctx, "", "release", "delete-asset", ReleaseTag, name, "-R", repo, "-y"); err != nil {
			return removed, err
		}
		removed++
	}
	return removed, nil
}
