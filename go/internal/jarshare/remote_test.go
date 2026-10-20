package jarshare

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeGH はディスクの上のフォルダを Release とみなす偽の gh（release の view・create・upload・download・delete-asset だけ）。
type fakeGH struct {
	store   string // 資産を置くフォルダ（無ければ Release が無い）
	created int    // release create を呼んだ数
	uploads int    // 上げた資産の数
}

func (g *fakeGH) Run(_ context.Context, dir string, args ...string) ([]byte, error) {
	if len(args) < 3 || args[0] != "release" {
		return nil, errors.New("知らない頼み: " + strings.Join(args, " "))
	}
	_, exists := os.Stat(g.store)
	switch args[1] {
	case "view":
		if exists != nil {
			return nil, errors.New("release not found")
		}
		items, _ := os.ReadDir(g.store)
		var assets []Asset
		for _, it := range items {
			info, _ := it.Info()
			assets = append(assets, Asset{Name: it.Name(), Size: info.Size(), CreatedAt: info.ModTime()})
		}
		return json.Marshal(map[string][]Asset{"assets": assets})
	case "create":
		g.created++
		return nil, os.MkdirAll(g.store, 0o755)
	case "upload":
		name := args[len(args)-1]
		g.uploads++
		raw, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return nil, err
		}
		return nil, os.WriteFile(filepath.Join(g.store, name), raw, 0o644)
	case "download":
		dest := ""
		var patterns []string
		for i := 0; i < len(args); i++ {
			switch args[i] {
			case "-p":
				patterns = append(patterns, args[i+1])
			case "-D":
				dest = args[i+1]
			}
		}
		for _, p := range patterns {
			raw, err := os.ReadFile(filepath.Join(g.store, p))
			if err != nil {
				return nil, errors.New("no assets match the file pattern")
			}
			if err := os.WriteFile(filepath.Join(dest, p), raw, 0o644); err != nil {
				return nil, err
			}
		}
		return nil, nil
	case "delete-asset":
		return nil, os.Remove(filepath.Join(g.store, args[3]))
	}
	return nil, errors.New("知らない頼み: " + args[1])
}

// 作り手が段 1 から段 2 へ上げた jar を、別の機械（空の段 1）が段 2 から取って段 1 へ入れ、写せる。
func TestPublishRemoteThenFetchRemoteOnAnotherMachine(t *testing.T) {
	gh := &fakeGH{store: filepath.Join(t.TempDir(), "release")}
	in := inputs()
	key := Key(in)
	builderCache := t.TempDir()
	if err := Publish(builderCache, key, in, game(t, in, "JAR")); err != nil {
		t.Fatal(err)
	}
	if err := PublishRemote(context.Background(), gh, "o/r", builderCache, key, "abc", time.Now()); err != nil {
		t.Fatal(err)
	}
	otherCache := t.TempDir()
	if err := FetchRemote(context.Background(), gh, "o/r", otherCache, key, in); err != nil {
		t.Fatal(err)
	}
	other := t.TempDir()
	if err := Fetch(otherCache, key, in, other, "now"); err != nil {
		t.Fatal(err)
	}
	if got := read(t, filepath.Join(other, "build", "headless", "headless.jar")); got != "JAR" {
		t.Fatalf("got %q", got)
	}
}

// 段 2 の jar の中身が <鍵>.json の SHA-256 と違えば取らない。
func TestFetchRemoteRejectsATamperedJar(t *testing.T) {
	gh := &fakeGH{store: filepath.Join(t.TempDir(), "release")}
	in := inputs()
	key := Key(in)
	cache := t.TempDir()
	if err := Publish(cache, key, in, game(t, in, "JAR")); err != nil {
		t.Fatal(err)
	}
	if err := PublishRemote(context.Background(), gh, "o/r", cache, key, "abc", time.Now()); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(gh.store, key+".jar"), "OTHER")
	if err := FetchRemote(context.Background(), gh, "o/r", t.TempDir(), key, in); err == nil {
		t.Fatal("中身の違う jar を取った")
	}
}

// 段 2 に鍵が無ければ取らない（呼ぶ側は手元で作る）。
func TestFetchRemoteFailsWhenTheKeyIsMissing(t *testing.T) {
	gh := &fakeGH{store: t.TempDir()}
	in := inputs()
	if err := FetchRemote(context.Background(), gh, "o/r", t.TempDir(), Key(in), in); err == nil {
		t.Fatal("無い鍵を取れたと言った")
	}
}

// 置き場（Release）が無ければ 1 回だけ作り、同じ鍵はもう一度上げない。
func TestPublishRemoteCreatesTheReleaseOnceAndSkipsKnownKeys(t *testing.T) {
	gh := &fakeGH{store: filepath.Join(t.TempDir(), "release")}
	in := inputs()
	key := Key(in)
	cache := t.TempDir()
	if err := Publish(cache, key, in, game(t, in, "JAR")); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := PublishRemote(context.Background(), gh, "o/r", cache, key, "abc", time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	if gh.created != 1 || gh.uploads != 2 {
		t.Fatalf("created=%d uploads=%d", gh.created, gh.uploads)
	}
}

// 上げてから 14 日より古い鍵は、jar も json も消す。今の master の鍵（keep）は古くても消さない。
func TestPlanRemotePruneDropsOldKeysButKeepsTheCurrentOne(t *testing.T) {
	now := time.Now()
	old := now.Add(-20 * 24 * time.Hour)
	got := PlanRemotePrune([]Asset{
		{Name: "a.jar", Size: 1, CreatedAt: old}, {Name: "a.json", Size: 1, CreatedAt: old},
		{Name: "b.jar", Size: 1, CreatedAt: old}, {Name: "b.json", Size: 1, CreatedAt: old},
	}, now, MaxAge, MaxBytes, "b")
	if strings.Join(got, ",") != "a.jar,a.json" {
		t.Fatalf("got %v", got)
	}
}

// 置き場の物でない資産（.jar・.json でない名前）は消さない。
func TestPlanRemotePruneLeavesOtherAssets(t *testing.T) {
	now := time.Now()
	got := PlanRemotePrune([]Asset{{Name: "README.md", Size: 1, CreatedAt: now.Add(-100 * 24 * time.Hour)}}, now, MaxAge, MaxBytes, "")
	if len(got) != 0 {
		t.Fatalf("got %v", got)
	}
}

// ssh と https の両方の remote の URL から "持ち主/名前" を取り出す。
func TestParseGitHubRepo(t *testing.T) {
	for url, want := range map[string]string{
		"git@github.com:vale8studio/internet_dungeon.git":       "vale8studio/internet_dungeon",
		"https://github.com/vale8studio/internet_dungeon.git\n": "vale8studio/internet_dungeon",
		"https://github.com/ababup1192/flix_game_engine":        "ababup1192/flix_game_engine",
	} {
		if got, ok := ParseGitHubRepo(url); !ok || got != want {
			t.Fatalf("%q → %q", url, got)
		}
	}
}

// GitHub でない remote は段 2 を使わない。
func TestParseGitHubRepoRejectsOtherHosts(t *testing.T) {
	if _, ok := ParseGitHubRepo("git@gitlab.com:x/y.git"); ok {
		t.Fatal("GitHub でない remote を受けた")
	}
}

// FGE_PREBUILT_JAR=off なら段 2 を使わない。
func TestRemoteEnabledOff(t *testing.T) {
	if RemoteEnabled(func(string) string { return "off" }) {
		t.Fatal("off なのに段 2 を使う")
	}
}

// flix.toml からエンジンの版を読む。
func TestEngineVersionOf(t *testing.T) {
	got, ok := EngineVersionOf(`"github:ababup1192/flix_game_engine" = { version = "0.52.1", mount = "fge" }`)
	if !ok || got != "0.52.1" {
		t.Fatalf("got %q", got)
	}
}

// plist に Label・ゲームの clone・5 分ごとが入る。
func TestRenderPlist(t *testing.T) {
	text, err := RenderPlist(PlistConfig{Label: LabelOf("/x/internet_dungeon"), Fge: "/e/bin/fge", Repo: "/x/internet_dungeon", Log: "/l", Path: "/bin"})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"<string>com.flixge.jar-builder.internet_dungeon</string>", "<string>--repo=/x/internet_dungeon</string>", "<integer>300</integer>"} {
		if !strings.Contains(text, want) {
			t.Fatalf("%q が無い:\n%s", want, text)
		}
	}
}
