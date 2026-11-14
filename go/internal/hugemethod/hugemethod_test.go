package hugemethod

import (
	"archive/zip"
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
)

// classBytes は、メソッド 1 つ (名前 method・bytecode の長さ codeLen) だけを持つ最小の class ファイルを作る。
func classBytes(method string, codeLen int) []byte {
	var b bytes.Buffer
	u2 := func(v int) { binary.Write(&b, binary.BigEndian, uint16(v)) }
	u4 := func(v int) { binary.Write(&b, binary.BigEndian, uint32(v)) }
	utf := func(s string) { b.WriteByte(1); u2(len(s)); b.WriteString(s) }
	u4(0xCAFEBABE)
	u4(52)
	u2(6) // constant pool: 1 = method の名前・2 = "Code"・3 と 4 = long 1 つ・5 = descriptor
	utf(method)
	utf("Code")
	b.WriteByte(5)
	b.Write(make([]byte, 8))
	utf("()V")
	u2(0)
	u2(0)
	u2(0)
	u2(0) // interfaces
	u2(0) // fields
	u2(1) // methods
	u2(0)
	u2(1)
	u2(5)
	u2(1) // attributes
	u2(2)
	u4(12 + codeLen)
	u2(0)
	u2(0)
	u4(codeLen)
	b.Write(make([]byte, codeLen))
	u2(0)
	u2(0)
	u2(0) // class attributes
	return b.Bytes()
}

func jarOf(t *testing.T, classes map[string][]byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "game.jar")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	z := zip.NewWriter(f)
	for name, data := range classes {
		w, _ := z.Create(name)
		w.Write(data)
	}
	if err := z.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()
	return path
}

func run(t *testing.T, root string, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, args)
	if err != nil {
		return code, err.Error()
	}
	return code, out.String() + errOut.String()
}

// long を挟んだ constant pool でも、Code の長さを読める。
func TestCodeLengthsReadsBytecodeLength(t *testing.T) {
	got, err := CodeLengths(classBytes("applyFrame", 11791))
	if err != nil || len(got) != 1 || got[0] != (Method{Name: "applyFrame", Bytes: 11791}) {
		t.Fatalf("got=%v err=%v", got, err)
	}
}

// 依存の package の頭と複製の番号を落とし、closure は元の def の名前で呼ぶ。
func TestFlixNameDropsPackageAndCopyNumber(t *testing.T) {
	cases := map[string]string{
		"$pkg$github$a$b/App/Internal/Halt/Def$pausedStep$643692": "App.Internal.Halt.pausedStep",
		"ShaderGen/Def$fieldExpr":                                 "ShaderGen.fieldExpr",
		"Clo$main$999819":                                         "main の中のラムダ",
	}
	for in, want := range cases {
		if got, ok := FlixName(in); !ok || got != want {
			t.Errorf("FlixName(%q) = %q, %v（want %q）", in, got, ok, want)
		}
	}
	if _, ok := FlixName("org/lwjgl/opengl/GL11"); ok {
		t.Error("Java のライブラリの class を Flix の関数に数えた")
	}
}

// 上限を超えた Flix の関数は止まり、上限ちょうどの物と Java のライブラリは止まらない。複製は 1 件にまとめる。
func TestOverLimitFiresForFlixFunctionsOnly(t *testing.T) {
	root := lintconf.TestRepo(t, Name, nil)
	jar := jarOf(t, map[string][]byte{
		"Game/Def$step$1.class": classBytes("applyFrame", 9000),
		"Game/Def$step$2.class": classBytes("applyFrame", 8500),
		"Game/Def$edge.class":   classBytes("staticApply", 8000),
		"org/lib/Big.class":     classBytes("run", 20000),
	})
	code, msg := run(t, root, jar)
	if code != 1 || !strings.Contains(msg, "!! Game.step は 9000 バイト（上限 8000 バイト・複製 2 個）") || strings.Count(msg, "!! ") != 1 {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// ゲームの除外に載せた関数は超えていても通る。
func TestLocalExemptPasses(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"bin/lint-rules/huge-methods.local.json": `{"exempt": {"Game.step::huge-methods": "題名の画面でしか通らない"}}`,
	})
	jar := jarOf(t, map[string][]byte{"Game/Def$step$1.class": classBytes("applyFrame", 9000)})
	if code, msg := run(t, root, jar); code != 0 || !strings.Contains(msg, "OK") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// --stale は、除外に載っているのに渡した class の中で超えていない関数を知らせる。
func TestStaleReportsExemptThatNoLongerFires(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"bin/lint-rules/huge-methods.local.json": `{"exempt": {"Game.gone::huge-methods": "前は大きかった"}}`,
	})
	jar := jarOf(t, map[string][]byte{"Game/Def$gone.class": classBytes("applyFrame", 100)})
	if code, msg := run(t, root, "--stale", jar); code != 1 || !strings.Contains(msg, "Game.gone::huge-methods は") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// class のフォルダも jar と同じに読める。Flix の class が 1 つも無ければ、通さずに止まる。
func TestClassDirAndEmptyInput(t *testing.T) {
	root := lintconf.TestRepo(t, Name, nil)
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "Game"), 0o755)
	os.WriteFile(filepath.Join(dir, "Game", "Def$step.class"), classBytes("applyFrame", 9000), 0o644)
	if code, msg := run(t, root, dir); code != 1 || !strings.Contains(msg, "Game.step") {
		t.Fatalf("dir: code=%d msg=%s", code, msg)
	}
	if code, msg := run(t, root, t.TempDir()); code != 2 || !strings.Contains(msg, "1 つもありません") {
		t.Fatalf("empty: code=%d msg=%s", code, msg)
	}
}
