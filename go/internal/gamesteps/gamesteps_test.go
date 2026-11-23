package gamesteps

// What: fge が test と render を持つ時はその fge を起こし、持たない時はゲームの make を起こすこと、
// make も無い時に止まること、lint-flixlint を make の無い所で飛ばすこと、絵の比較の起こし方。

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

type rec struct{ calls []string }

func fakeRunner(t *testing.T, names []string, hasMake bool) (*Runner, *rec) {
	t.Helper()
	r := &rec{}
	out := &strings.Builder{}
	return &Runner{
		Exe: "/x/fge", Engine: "/eng", MakeBin: "make", Out: out, Err: out,
		Run: func(c *exec.Cmd) error {
			r.calls = append(r.calls, filepath.Base(c.Path)+" "+strings.Join(c.Args[1:], " ")+" @"+c.Dir)
			return nil
		},
		List: func(string) []string { return names },
		LookPath: func(name string) (string, error) {
			if hasMake {
				return "/usr/bin/" + name, nil
			}
			return "", errors.New("無い")
		},
	}, r
}

func TestFgeWithTestAndRenderIsUsedForCheck(t *testing.T) {
	r, got := fakeRunner(t, []string{"check", "test", "render"}, true)
	if err := r.Check("/g"); err != nil {
		t.Fatal(err)
	}
	if strings.Join(got.calls, ";") != "fge check @/g" {
		t.Errorf("%v", got.calls)
	}
}

func TestOldFgeFallsBackToMakeWithEngine(t *testing.T) {
	r, got := fakeRunner(t, []string{"check"}, true)
	if err := r.RenderAll("/g"); err != nil {
		t.Fatal(err)
	}
	if strings.Join(got.calls, ";") != "make --no-print-directory -C /g render-all ENGINE=/eng @" {
		t.Errorf("%v", got.calls)
	}
}

func TestOldFgeWithoutMakeStops(t *testing.T) {
	r, _ := fakeRunner(t, []string{"check"}, false)
	if err := r.Test("/g"); err == nil {
		t.Error("make も fge の test も無いのに通しています")
	}
}

func TestLintFlixlintIsSkippedWithoutMake(t *testing.T) {
	game := t.TempDir()
	if err := os.MkdirAll(filepath.Join(game, "lint"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(game, "lint", "rules.flix"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	r, got := fakeRunner(t, []string{"test", "render"}, false)
	if err := r.LintFlixlint(game); err != nil || len(got.calls) != 0 {
		t.Errorf("err=%v calls=%v", err, got.calls)
	}
}

func TestLintFlixlintIsNothingWithoutRules(t *testing.T) {
	r, got := fakeRunner(t, nil, true)
	if err := r.LintFlixlint(t.TempDir()); err != nil || len(got.calls) != 0 {
		t.Errorf("err=%v calls=%v", err, got.calls)
	}
}

// 差し替えの seam を本物で 1 度も通していないと、--no-print-directory の位置や終了コードの読み方が間違っていても気づけない。
func TestRealMakeIsRunAndItsExitCodeIsRead(t *testing.T) {
	if _, err := exec.LookPath("make"); err != nil {
		t.Skip("make がありません")
	}
	game := t.TempDir()
	if err := os.WriteFile(filepath.Join(game, "Makefile"), []byte("check:\n\t@true\ntest:\n\t@exit 1\nreference-check:\n\t@true\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := New("/eng")
	r.List = func(string) []string { return nil }
	r.Out, r.Err = &strings.Builder{}, &strings.Builder{}
	if err := r.Check(game); err != nil {
		t.Errorf("通る的で落ちています: %v", err)
	}
	if err := r.Test(game); err == nil {
		t.Error("落ちる的を通っています")
	}
	if !r.HasReferenceCheck(game) {
		t.Error("在る的を無いと言っています")
	}
}

func TestReferenceCheckWithFgeRendersFirst(t *testing.T) {
	r, got := fakeRunner(t, []string{"test", "render"}, false)
	if err := r.ReferenceCheck("/g"); err != nil {
		t.Fatal(err)
	}
	if strings.Join(got.calls, ";") != "fge render --all @/g;fge reference check @/g" {
		t.Errorf("%v", got.calls)
	}
}
