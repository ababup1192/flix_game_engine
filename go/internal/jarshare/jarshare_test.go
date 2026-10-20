package jarshare

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func inputs() Inputs {
	return Inputs{Source: "m1", Dispatcher: "mod FgeHeadlessMain {}", FlixJarSHA: "f1", Revision: "1"}
}

// game は jar を作り終えた後のゲームの根（build/headless に jar・jar.manifest・入口の束）を作る。
func game(t *testing.T, in Inputs, jar string) string {
	t.Helper()
	root := t.TempDir()
	out := filepath.Join(root, "build", "headless")
	if err := os.MkdirAll(filepath.Join(out, "proj", "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(out, "headless.jar"), jar)
	write(t, filepath.Join(out, "proj", "src", "FgeHeadlessMain.flix"), in.Dispatcher)
	return root
}

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// 鍵に混ぜる 4 つのどれを変えても、鍵が変わる。
func TestKeyChangesWithEachInput(t *testing.T) {
	base := Key(inputs())
	for name, change := range map[string]func(*Inputs){
		"source":     func(in *Inputs) { in.Source = "m2" },
		"dispatcher": func(in *Inputs) { in.Dispatcher = "mod FgeHeadlessMain { x }" },
		"flix":       func(in *Inputs) { in.FlixJarSHA = "f2" },
		"revision":   func(in *Inputs) { in.Revision = "2" },
	} {
		in := inputs()
		change(&in)
		if Key(in) == base {
			t.Fatalf("%s を変えても鍵が同じ", name)
		}
	}
}

// どれかが空なら鍵を作らない（分け合わない）。
func TestKeyIsEmptyWithoutFlixJar(t *testing.T) {
	in := inputs()
	in.FlixJarSHA = ""
	if got := Key(in); got != "" {
		t.Fatalf("got %q", got)
	}
}

// 置いた jar を、別の作業場が同じ鍵で取ると、jar・指紋・入口の束がそろって写る。
func TestPublishThenFetchCopiesTheJar(t *testing.T) {
	cache := t.TempDir()
	in := inputs()
	if err := Publish(cache, Key(in), in, game(t, in, "JAR")); err != nil {
		t.Fatal(err)
	}
	other := t.TempDir()
	if err := Fetch(cache, Key(in), in, other, "now"); err != nil {
		t.Fatal(err)
	}
	if got := read(t, filepath.Join(other, "build", "headless", "headless.jar")); got != "JAR" {
		t.Fatalf("got %q", got)
	}
}

// 置き場の jar の中身が sha256 と違えば取らず、その 1 本を置き場から消す。
func TestFetchRejectsAndDropsATamperedJar(t *testing.T) {
	cache := t.TempDir()
	in := inputs()
	key := Key(in)
	if err := Publish(cache, key, in, game(t, in, "JAR")); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(cache, key, "headless.jar"), "OTHER")
	if err := Fetch(cache, key, in, t.TempDir(), "now"); err == nil {
		t.Fatal("中身の違う jar を取った")
	}
	if _, err := os.Stat(filepath.Join(cache, key)); !os.IsNotExist(err) {
		t.Fatal("中身の違う 1 本が置き場に残った")
	}
}

// 置いた時の元の指紋が今と違えば取らない。
func TestFetchRejectsAnotherManifest(t *testing.T) {
	cache := t.TempDir()
	in := inputs()
	key := Key(in)
	if err := Publish(cache, key, in, game(t, in, "JAR")); err != nil {
		t.Fatal(err)
	}
	other := in
	other.Source = "m2"
	if err := Fetch(cache, key, other, t.TempDir(), "now"); err == nil {
		t.Fatal("指紋の違う jar を取った")
	}
}

// 置き場に無ければ取らない（呼ぶ側は今どおり作る）。
func TestFetchFailsWhenNothingIsStored(t *testing.T) {
	in := inputs()
	if err := Fetch(t.TempDir(), Key(in), in, t.TempDir(), "now"); err == nil {
		t.Fatal("無い物を取れたと言った")
	}
}

// 同じ鍵を 8 本が同時に置いても、置き場には揃った 1 本だけが残り、それを取れる。
func TestConcurrentPublishLeavesOneCompleteEntry(t *testing.T) {
	cache := t.TempDir()
	in := inputs()
	key := Key(in)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		root := game(t, in, "JAR")
		wg.Add(1)
		go func() { defer wg.Done(); _ = Publish(cache, key, in, root) }()
	}
	wg.Wait()
	if err := Fetch(cache, key, in, t.TempDir(), "now"); err != nil {
		t.Fatal(err)
	}
	items, _ := os.ReadDir(cache)
	if len(items) != 1 {
		t.Fatalf("置き場に %d 個ある", len(items))
	}
}

// 最後に使ってから 14 日より古い物を消す。
func TestPlanPruneDropsOldEntries(t *testing.T) {
	now := time.Now()
	got := PlanPrune([]Entry{{Key: "new", Used: now, Bytes: 1}, {Key: "old", Used: now.Add(-15 * 24 * time.Hour), Bytes: 1}}, now, MaxAge, MaxBytes)
	if len(got) != 1 || got[0] != "old" {
		t.Fatalf("got %v", got)
	}
}

// 全部で上限を超えたら、最後に使ったのが古い方から消す。
func TestPlanPruneDropsLeastRecentlyUsedOverTheLimit(t *testing.T) {
	now := time.Now()
	got := PlanPrune([]Entry{
		{Key: "a", Used: now, Bytes: 6},
		{Key: "b", Used: now.Add(-time.Hour), Bytes: 6},
	}, now, MaxAge, 10)
	if len(got) != 1 || got[0] != "b" {
		t.Fatalf("got %v", got)
	}
}

// off なら置き場を使わない。
func TestCacheRootOff(t *testing.T) {
	env := func(k string) string {
		if k == CacheEnv {
			return "off"
		}
		return "/home/x"
	}
	if got := CacheRoot(env); got != "" {
		t.Fatalf("got %q", got)
	}
}

// 取った作業場の build/headless/jar.manifest には、その作業場の今の指紋を書く（作り手の指紋ではなく）。
func TestFetchWritesTheCallersManifest(t *testing.T) {
	cache := t.TempDir()
	in := inputs()
	if err := Publish(cache, Key(in), in, game(t, in, "JAR")); err != nil {
		t.Fatal(err)
	}
	other := t.TempDir()
	if err := Fetch(cache, Key(in), in, other, "mine"); err != nil {
		t.Fatal(err)
	}
	if got := read(t, filepath.Join(other, "build", "headless", "jar.manifest")); got != "mine\n" {
		t.Fatalf("got %q", got)
	}
}
