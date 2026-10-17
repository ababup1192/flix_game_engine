package verbnames

import (
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
)

func run(t *testing.T, root string, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, args)
	if err != nil {
		t.Fatal(err)
	}
	return code, out.String() + errOut.String()
}

// is* が Bool 以外を返す・get* が IO を持つ、の 2 つを止め、規約の hint を出す。
func TestBoolAndEffectfulGetFire(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{"src/A.flix": `mod A {
    pub def isReady(w: World): Int32 = 0
    pub def getSave(p: String): String \ IO = p
    pub def hasItem(w: World, k: String): Bool = true
    def getName(w: World): String = w.name
}`})
	code, msg := run(t, root, "src/A.flix")
	if code != 1 || !strings.Contains(msg, "src/A.flix:2 isReady") || !strings.Contains(msg, "src/A.flix:3 getSave") ||
		strings.Contains(msg, "hasItem") || strings.Contains(msg, "getName") || !strings.Contains(msg, "load/fetch 外から") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// 効果の変数・\ {}・Bool \ IO・複数行の宣言・動詞でない頭 (isometric) は止めない。
func TestQuietCases(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{"src/B.flix": `mod B {
    pub def getOr(f: Unit -> a \ ef, d: a): a \ ef = f()
    pub def getAt(k: String, m: Map[String, a]): Result[String, a] \ {} with Order[a] = ???
    pub def isOpen(): Bool \ IO = true
    pub def isometric(x: Int32): Int32 = x
    pub def isLong(a: Int32,
                  b: Int32): Int32 = a
}`})
	if code, msg := run(t, root, "src/B.flix"); code != 0 {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// ゲームの除外で黙り、鳴らなくなった除外は --all で古いと言う。
func TestLocalExemptAndStale(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"src/C.flix":                           "    def getBean(): Bean \\ IO = ???\n",
		"src/D.flix":                           "    def getX(): Int32 = 1\n",
		"bin/lint-rules/verb-names.local.json": `{"exempt":{"src/C.flix::getBean":"Java の getter","src/D.flix::getX":"古い"}}`,
	})
	lintconf.GitInit(t, root)
	if code, msg := run(t, root, "src/C.flix"); code != 0 {
		t.Fatalf("除外で黙るはず code=%d msg=%s", code, msg)
	}
	code, msg := run(t, root, "--all")
	if code != 1 || !strings.Contains(msg, "src/D.flix::getX は bin/lint-rules/verb-names.local.json の exempt") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}
