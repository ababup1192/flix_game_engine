package refactor

// usages の正しさをゲームの索引で固定する（設計 refactor-tool-design §8.0 の表・§8.6 の段 A）。
//
// testdata/game-0877ab5d-resolved.tsv.gz は internet_dungeon の 0877ab5d の resolved の索引（flixlint の spans-uses の
// 7923ecb が書いた物）を、この試験が見る行だけに絞った物:
//   - 問いの 4 つ（moveTo・defaults・Clear・Phase）と名前の終わりが同じ行と、World.Phase.* の行は全部
//   - src の pub な def の宣言は全部
//   - その def への参照は「テストから・同じ mod から・ほかの src から・自分の中」の組ごとに 1 行（--unused の分け方は
//     組の有る無しだけで決まる。数は残らない）
// 作り直すには、ゲームの写しで bin/fge refactor index を流してから
//   go test ./internal/refactor -run TestGameIndex -game-index <写し>/build/refactor/spans-resolved.tsv
// 使っていない use（8.0 の 35）はソースの字が要るので、ここでは数えない（写しで確かめる）。

import (
	"compress/gzip"
	"flag"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

var gameIndex = flag.String("game-index", "", "ゲームの写しの spans-resolved.tsv から testdata の絞った索引を作り直す")

const gameFixture = "testdata/game-0877ab5d-resolved.tsv.gz"

var gameQueries = []string{"moveTo", "defaults", "Clear", "Phase"}

// reduceGameIndex は試験が見る行だけを残す（並びは元のまま）。
func reduceGameIndex(rows []Row) []Row {
	defs, _ := defTable(rows)
	pub := func(sym string) bool {
		d, ok := defs[sym]
		return ok && d.Pub && strings.HasPrefix(d.File, "src/")
	}
	asked := func(sym string) bool {
		last := sym[strings.LastIndex(sym, ".")+1:]
		for _, q := range gameQueries {
			if last == q {
				return true
			}
		}
		return strings.HasPrefix(sym, "World.Phase.")
	}
	seen := map[string]bool{}
	var out []Row
	for _, r := range rows {
		switch {
		case asked(r.Sym):
			out = append(out, r)
		case r.Kind == KindDefDecl && pub(r.Sym):
			out = append(out, r)
		case r.Kind == KindDefUse && pub(r.Sym):
			key := strings.Join([]string{r.Sym, boolKey(inDirs(r.File, []string{"test"})), boolKey(modOf(r.Owner) == modOf(r.Sym)), boolKey(r.Owner == r.Sym)}, "|")
			if !seen[key] {
				seen[key] = true
				out = append(out, r)
			}
		}
	}
	return out
}

func boolKey(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

func writeGameFixture(t *testing.T, from string) {
	f, err := os.Open(from)
	must(t, err)
	defer f.Close()
	rows, adds, err := parseIndexAdds(f, Resolved)
	must(t, err)
	var b strings.Builder
	b.WriteString("# flixlint-spans 2 stage=resolved columns=kind,file,sl,sc,el,ec,sym,owner,extra adds=" + adds + "\n")
	for _, r := range reduceGameIndex(rows) {
		b.WriteString(strings.Join([]string{r.Kind, r.File, strconv.Itoa(r.Line), strconv.Itoa(r.Col), strconv.Itoa(r.EndLine), strconv.Itoa(r.EndCol), r.Sym, r.Owner, r.Extra}, "\t") + "\n")
	}
	out, err := os.Create(filepath.FromSlash(gameFixture))
	must(t, err)
	z, _ := gzip.NewWriterLevel(out, gzip.BestCompression)
	_, err = z.Write([]byte(b.String()))
	must(t, err)
	must(t, z.Close())
	must(t, out.Close())
}

func loadGameIndex(t *testing.T) *Index {
	t.Helper()
	if *gameIndex != "" {
		writeGameFixture(t, *gameIndex)
	}
	f, err := os.Open(filepath.FromSlash(gameFixture))
	must(t, err)
	defer f.Close()
	z, err := gzip.NewReader(f)
	must(t, err)
	rows, adds, err := parseIndexAdds(z, Resolved)
	must(t, err)
	return &Index{Stage: Resolved, Rows: rows, Adds: adds}
}

// 8.0 の表の「道具の数」: grep は短い名前で別物を拾い、長い名前で use 越しの素の名前を落とす。道具はどちらもしない。
func TestGameIndexUsagesMatchTheTable(t *testing.T) {
	idx := loadGameIndex(t)
	src := &srcCache{root: t.TempDir()} // 呼び出しか参照かの分けだけに使う（数は変わらない）
	for _, c := range []struct {
		q    string
		sym  string
		want int
	}{
		{"World.moveTo", "World.moveTo", 39},
		{"BoardDoc.defaults", "BoardDoc.defaults", 7},
		{"Phase.Clear", "World.Phase.Clear", 29},
		{"World.Phase", "World.Phase", 679},
	} {
		tg, err := ResolveTarget(idx.Rows, c.q)
		if err != nil {
			t.Errorf("%s: %v", c.q, err)
			continue
		}
		if got := len(SymbolUsages(idx.Rows, tg, src)); tg.Sym != c.sym || got != c.want {
			t.Errorf("%s: %s に %d か所（%s に %d のはず）", c.q, tg.Sym, got, c.sym, c.want)
		}
	}
}

// 8.0 の --unused: pub の def 402（参照 0: 45・テストからだけ: 126・同じ mod の中だけ: 231）。
func TestGameIndexUnusedDefsMatchTheTable(t *testing.T) {
	n := map[string]int{}
	defs := UnusedDefs(loadGameIndex(t).Rows, []string{"test"})
	for _, d := range defs {
		n[d.Why]++
	}
	if len(defs) != 402 || n["unreferenced"] != 45 || n["test-only"] != 126 || n["own-mod"] != 231 {
		t.Errorf("%d %v（402・参照 0: 45・テストからだけ: 126・同じ mod の中だけ: 231 のはず）", len(defs), n)
	}
}
