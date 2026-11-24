package status

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
)

const enginePinToml = "\"github:ababup1192/flix_game_engine\" = { version = \"0.108.0\", mount = \"fge\" }\n"

// makeEngineLines はテンプレートの Makefile の ENGINE の既定（plans/onboarding.md 2.5 の 3 行）と、答えを出すターゲット。
const makeEngineLines = `-include local.mk
FGE_VERSION := $(shell sed -n 's/^"github:ababup1192\/flix_game_engine"[^}]*version *= *"\([0-9.]*\)".*/\1/p' flix.toml)
ENGINE ?= $(if $(and $(wildcard ../../mk/game.mk),$(wildcard ../../templates)),../..,$(or $(FGE_HOME),$(HOME)/.flix_ge)/engines/$(FGE_VERSION))
print:
	@echo $(ENGINE)
`

func isolateEngineEnv(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	// WhyNot: 空の ENGINE を置かない — make の ?= は空でも定義済みと見て、既定の行を通らない。
	t.Setenv("ENGINE", "")
	os.Unsetenv("ENGINE")
	t.Setenv("FGE_HOME", home)
	return home
}

// engineCase は決まりの 1 つ分のゲームのフォルダを作り、期待する engine を返す。
type engineCase struct {
	name  string
	setup func(t *testing.T, base string) (game, want string)
}

var engineCases = []engineCase{
	{"環境変数 ENGINE", func(t *testing.T, base string) (string, string) {
		game := filepath.Join(base, "game")
		write(t, filepath.Join(game, "flix.toml"), enginePinToml)
		write(t, filepath.Join(game, "local.mk"), "ENGINE ?= /from/local\n")
		t.Setenv("ENGINE", "/from/env")
		return game, "/from/env"
	}},
	{"local.mk の ENGINE", func(t *testing.T, base string) (string, string) {
		game := filepath.Join(base, "game")
		write(t, filepath.Join(game, "flix.toml"), enginePinToml)
		write(t, filepath.Join(game, "local.mk"), "ENGINE ?= /from/local\n")
		return game, "/from/local"
	}},
	{"engine の中のテンプレート", func(t *testing.T, base string) (string, string) {
		write(t, filepath.Join(base, "mk", "game.mk"), "")
		game := filepath.Join(base, "templates", "game-starter")
		write(t, filepath.Join(game, "flix.toml"), enginePinToml)
		return game, base
	}},
	{"置き場の engines/<版>", func(t *testing.T, base string) (string, string) {
		game := filepath.Join(base, "game")
		write(t, filepath.Join(game, "flix.toml"), enginePinToml)
		return game, filepath.Join(os.Getenv("FGE_HOME"), "engines", "0.108.0")
	}},
}

func TestResolveEngineDirFollowsRules(t *testing.T) {
	for _, c := range engineCases {
		t.Run(c.name, func(t *testing.T) {
			isolateEngineEnv(t)
			game, want := c.setup(t, t.TempDir())
			got, self := ResolveEngineDir(game)
			if filepath.Clean(got) != filepath.Clean(want) || self {
				t.Errorf("got %q self=%v, want %q", got, self, want)
			}
		})
	}
}

func TestResolveEngineDirMatchesMakefileDefault(t *testing.T) {
	if _, err := exec.LookPath("make"); err != nil {
		t.Skip("make がありません")
	}
	for _, c := range engineCases {
		t.Run(c.name, func(t *testing.T) {
			isolateEngineEnv(t)
			game, _ := c.setup(t, t.TempDir())
			write(t, filepath.Join(game, "Makefile"), makeEngineLines)
			cmd := exec.Command("make", "-s", "-f", "Makefile", "print")
			cmd.Dir = game
			var out bytes.Buffer
			cmd.Stdout = &out
			cmd.Stderr = os.Stderr
			if err := cmd.Run(); err != nil {
				t.Fatal(err)
			}
			fromMake := strings.TrimSpace(out.String())
			if !filepath.IsAbs(fromMake) {
				fromMake = filepath.Join(game, fromMake)
			}
			got, _ := ResolveEngineDir(game)
			if filepath.Clean(got) != filepath.Clean(fromMake) {
				t.Errorf("Go %q / make %q", got, fromMake)
			}
		})
	}
}

func TestResolveEngineDirIsSelfForEngineRoot(t *testing.T) {
	isolateEngineEnv(t)
	root := t.TempDir()
	write(t, filepath.Join(root, "mk", "game.mk"), "")
	t.Setenv("ENGINE", "/elsewhere")
	if got, self := ResolveEngineDir(root); got != root || !self {
		t.Errorf("got %q self=%v", got, self)
	}
}

func TestResolveEngineDirIsEmptyWithoutPin(t *testing.T) {
	isolateEngineEnv(t)
	game := t.TempDir()
	write(t, filepath.Join(game, "flix.toml"), "[package]\nname = \"x\"\n")
	if got, _ := ResolveEngineDir(game); got != "" {
		t.Errorf("got %q", got)
	}
}

// WhyNot: Go の \s は ASCII だけなので使えない。全角空白も落とす必要がある。
func TestResolveEngineDirReadsLocalMkRelativeToGame(t *testing.T) {
	isolateEngineEnv(t)
	game := t.TempDir()
	write(t, filepath.Join(game, "local.mk"), "ENGINE := ../eng　\n")
	if got, _ := ResolveEngineDir(game); got != filepath.Join(game, "..", "eng") {
		t.Errorf("got %q", got)
	}
}

func TestFindEngineDirSkipsCandidateWithoutMarker(t *testing.T) {
	home := isolateEngineEnv(t)
	game := filepath.Join(t.TempDir(), "game")
	write(t, filepath.Join(game, "flix.toml"), enginePinToml)
	write(t, filepath.Join(game, "local.mk"), "ENGINE := /no/such\n")
	bundled := filepath.Join(home, "engines", "0.108.0")
	write(t, filepath.Join(bundled, "mk", "game.mk"), "")
	if got, self := FindEngineDir(game, "mk/game.mk"); got != bundled || self {
		t.Errorf("got %q self=%v", got, self)
	}
}

func TestFindEngineDirIsSelfWhenRootHasMarker(t *testing.T) {
	isolateEngineEnv(t)
	root := t.TempDir()
	write(t, filepath.Join(root, "mk", "game.mk"), "")
	if got, self := FindEngineDir(root, "mk/game.mk"); got != root || !self {
		t.Errorf("got %q self=%v", got, self)
	}
}

func writeBundledEngine(t *testing.T, dir, version string) {
	t.Helper()
	write(t, filepath.Join(dir, "Makefile"), "VERSION := "+version+"\n")
	write(t, filepath.Join(dir, "mk", "game.mk"), "")
}

func writeLatest(t *testing.T, version string) {
	t.Helper()
	b, _ := json.Marshal(fgehome.Latest{Version: version, CheckedAt: time.Now()})
	write(t, fgehome.LatestPath(), string(b))
}

func TestStatusAnnouncesNewerBundledEngine(t *testing.T) {
	home := isolateEngineEnv(t)
	writeBundledEngine(t, filepath.Join(home, "engines", "0.108.0"), "0.108.0")
	writeLatest(t, "0.109.0")
	game := t.TempDir()
	write(t, filepath.Join(game, "flix.toml"), enginePinToml)
	line := find(t, build(t, game), "engine 0.109.0 が出ています")
	if !strings.Contains(line, "make engine-upgrade TO=0.109.0") {
		t.Errorf("案内が違います: %s", line)
	}
}

func TestStatusIsQuietWhenLatestIsNotNewer(t *testing.T) {
	home := isolateEngineEnv(t)
	writeBundledEngine(t, filepath.Join(home, "engines", "0.108.0"), "0.108.0")
	writeLatest(t, "0.108.0")
	game := t.TempDir()
	write(t, filepath.Join(game, "flix.toml"), enginePinToml)
	for _, line := range build(t, game) {
		if strings.Contains(line, "が出ています") {
			t.Errorf("出ない行です: %s", line)
		}
	}
}

func TestStatusDoesNotAnnounceForClonedEngine(t *testing.T) {
	isolateEngineEnv(t)
	engine := t.TempDir()
	writeBundledEngine(t, engine, "0.108.0")
	write(t, filepath.Join(engine, "go", "go.mod"), "module x\n")
	writeLatest(t, "0.109.0")
	game := t.TempDir()
	write(t, filepath.Join(game, "flix.toml"), enginePinToml)
	write(t, filepath.Join(game, "local.mk"), "ENGINE ?= "+engine+"\n")
	for _, line := range build(t, game) {
		if strings.Contains(line, "が出ています") {
			t.Errorf("clone した engine には出ない行です: %s", line)
		}
	}
}

func TestStatusReportsMissingBundledEngine(t *testing.T) {
	isolateEngineEnv(t)
	game := t.TempDir()
	write(t, filepath.Join(game, "flix.toml"), enginePinToml)
	line := find(t, build(t, game), "engine 0.108.0 が手元にありません")
	if !strings.Contains(line, "fge engines install 0.108.0") {
		t.Errorf("案内が違います: %s", line)
	}
}

func TestEngineVersionLessComparesNumerically(t *testing.T) {
	if !engineVersionLess("0.108.9", "0.108.10") || engineVersionLess("0.109.0", "0.108.0") {
		t.Error("数の並びで比べていません")
	}
}
