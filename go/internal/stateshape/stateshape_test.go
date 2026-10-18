package stateshape

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
)

const localRel = "bin/lint-rules/state-shape.local.json"

func run(t *testing.T, root string, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, args)
	if err != nil {
		t.Fatal(err)
	}
	return code, out.String() + errOut.String()
}

func runErr(t *testing.T, root string, args ...string) error {
	t.Helper()
	var out, errOut strings.Builder
	_, err := Run(&out, &errOut, root, args)
	return err
}

// 状態の record の Bool の欄が boolFieldMin 個以上なら止まる。
func TestBoolFieldsFire(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{"src/World.flix": `mod World {
    pub type alias World = { open = Bool, closing = Bool,
        done = Bool, at = Float64 }
}`})
	code, msg := run(t, root, "src/World.flix")
	if code != 1 || !strings.Contains(msg, "src/World.flix:2 [state-shape.bool-fields] World の Bool の欄 3 個") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// Bool の欄が boolFieldMin より少ない record・Doc のファイルの record は止まらない。
func TestBoolFieldsQuiet(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"src/A.flix":       "    type alias A = { open = Bool, done = Bool, at = Float64 }\n",
		"src/TuneDoc.flix": "    type alias Tune = { a = Bool, b = Bool, c = Bool }\n",
	})
	if code, msg := run(t, root, "src/A.flix", "src/TuneDoc.flix"); code != 0 {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// 歯止めの数までは通り、1 つ増えたら止まる。
func TestBoolFieldLimit(t *testing.T) {
	files := map[string]string{
		"src/W.flix": "    type alias W = { a = Bool, b = Bool, c = Bool }\n",
		localRel:     `{"boolFieldLimits": {"src/W.flix::W": 3}}`,
	}
	if code, msg := run(t, lintconf.TestRepo(t, Name, files), "src/W.flix"); code != 0 {
		t.Fatalf("今の数までは通るはず code=%d msg=%s", code, msg)
	}
	files["src/W.flix"] = "    type alias W = { a = Bool, b = Bool, c = Bool, d = Bool }\n"
	code, msg := run(t, lintconf.TestRepo(t, Name, files), "src/W.flix")
	if code != 1 || !strings.Contains(msg, "bool_fields 4 / want <= 3") {
		t.Fatalf("増えたら止まるはず code=%d msg=%s", code, msg)
	}
}

// --all で、今の数より緩い歯止めと、もう鳴らない除外を止める。
func TestStaleLimitAndExempt(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"src/W.flix": "    type alias W = { a = Bool, b = Bool, c = Bool }\n",
		localRel:     `{"boolFieldLimits": {"src/W.flix::W": 5}, "exempt": {"src/W.flix::option-bool::f": "古い"}}`,
	})
	lintconf.GitInit(t, root)
	code, msg := run(t, root, "--all")
	if code != 1 || !strings.Contains(msg, "boolFieldLimits を 3 に下げてください") ||
		!strings.Contains(msg, "src/W.flix::option-bool::f は bin/lint-rules/state-shape.local.json の exempt") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// Option[Bool] は止まり、持ち主（record の欄・def）の鍵の除外で黙る。コメントと文字列の中は見ない。
func TestOptionBool(t *testing.T) {
	src := `mod R {
    type alias Track = { at = Float64, won = Option[Bool] }
    def next(w: W): Option[Bool] = None
    // Option[Bool] はコメント
    def label(): String = "Option[Bool]"
}`
	root := lintconf.TestRepo(t, Name, map[string]string{"src/R.flix": src})
	code, msg := run(t, root, "src/R.flix")
	if code != 1 || !strings.Contains(msg, "src/R.flix:2 [state-shape.option-bool] Track.won") ||
		!strings.Contains(msg, "src/R.flix:3 [state-shape.option-bool] next") || strings.Count(msg, "option-bool]") != 2 {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
	root = lintconf.TestRepo(t, Name, map[string]string{"src/R.flix": src,
		localRel: `{"exempt": {"src/R.flix::option-bool::Track.won": "決着前", "src/R.flix::option-bool::next": "誰も打たない"}}`})
	if code, msg := run(t, root, "src/R.flix"); code != 0 {
		t.Fatalf("除外で黙るはず code=%d msg=%s", code, msg)
	}
}

const offerEnum = `mod World {
    pub enum CardOffer {
        case Choosing(Int32)
        case Confirming(Int32), Closed
    }
}`

// 名指しした enum への match の `case _ =>` と変数で受ける腕は止まる。
func TestCatchAllFire(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"src/World.flix": offerEnum,
		"src/Use.flix": `mod Use {
    def a(o: CardOffer): Int32 = match o {
        case CardOffer.Choosing(c) => c
        case _ => 0
    }
    def b(o: CardOffer): Int32 = match o {
        case CardOffer.Closed => 1
        case other => 2
    }
}`,
		localRel: `{"stateEnums": ["CardOffer"]}`,
	})
	lintconf.GitInit(t, root)
	code, msg := run(t, root, "src/Use.flix")
	if code != 1 || !strings.Contains(msg, "src/Use.flix:4 [state-shape.catch-all] CardOffer への match に取りこぼしの腕 `case _ => 0`") ||
		!strings.Contains(msg, "src/Use.flix:8 [state-shape.catch-all]") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// 見張りつきの腕・述語の形の腕・名指ししていない enum・全部の case を書いた match は止まらない。
func TestCatchAllQuiet(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"src/World.flix": offerEnum + `
mod Other { pub enum Phase { case Day, Night } }`,
		"src/Use.flix": `mod Use {
    def isChoosing(o: CardOffer): Bool = match o {
        case CardOffer.Choosing(_) => true
        case _ => false
    }
    def picked(o: CardOffer): Option[Int32] = match o {
        case CardOffer.Confirming(c) => Some(c)
        case _ => None
    }
    def g(o: CardOffer, n: Int32): Int32 = match o {
        case CardOffer.Choosing(c) => c
        case _ if n > 0 => n
        case CardOffer.Confirming(c) => c
        case CardOffer.Closed => 0
    }
    def p(x: Phase): Int32 = match x {
        case Phase.Day => 1
        case _ => 0
    }
}`,
		localRel: `{"stateEnums": ["CardOffer"]}`,
	})
	lintconf.GitInit(t, root)
	if code, msg := run(t, root, "src/Use.flix"); code != 0 {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// 同じ名前の enum が 2 つあれば "パス::名前" で決めるよう止め、決めれば別のファイルの同名の enum は見ない。
func TestCatchAllSameName(t *testing.T) {
	files := map[string]string{
		"src/World.flix": "mod World { pub enum Phase { case Day, Night } }\n",
		"src/Cue.flix": `mod Cue {
    enum Phase { case Day, Hold }
    def f(p: Phase): Int32 = match p {
        case Phase.Day => 1
        case _ => 0
    }
}`,
		localRel: `{"stateEnums": ["Phase"]}`,
	}
	root := lintconf.TestRepo(t, Name, files)
	lintconf.GitInit(t, root)
	if err := runErr(t, root, "src/Cue.flix"); err == nil || !strings.Contains(err.Error(), "\"パス::Phase\"") {
		t.Fatalf("重なりを止めるはず err=%v", err)
	}
	files[localRel] = `{"stateEnums": ["src/World.flix::Phase"]}`
	root = lintconf.TestRepo(t, Name, files)
	lintconf.GitInit(t, root)
	if code, msg := run(t, root, "src/Cue.flix"); code != 0 {
		t.Fatalf("別の Phase は見ないはず code=%d msg=%s", code, msg)
	}
}

// View の def が決まった効果を持てば止まる（宣言が複数行でも）。
func TestViewEffectFire(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{"src/PuzzleView.flix": `mod PuzzleView {
    def tree(w: World): List[Item] \ IO = Nil
    pub def panel(ctx: Ctx,
                  w: World): List[Item] \ { IO, Fs } =
        Nil
}`})
	code, msg := run(t, root, "src/PuzzleView.flix")
	if code != 1 || !strings.Contains(msg, "src/PuzzleView.flix:2 [state-shape.view-effect] View の def tree が効果 IO を持つ") ||
		!strings.Contains(msg, "src/PuzzleView.flix:3 [state-shape.view-effect] View の def panel が効果 IO + Fs を持つ") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// 効果の変数・\ {}・ラムダの型の中の効果・View でないファイルの効果は止まらない。
func TestViewEffectQuiet(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"src/View.flix": `mod View {
    def mapped(f: a -> b \ ef, xs: List[a]): List[b] \ ef = List.map(f, xs)
    def pure(w: World): List[Item] \ {} = Nil
    def each(f: Item -> Unit \ IO, w: World): Int32 = 0
}`,
		"src/Update.flix": "    def step(w: World): World \\ IO = w\n",
	})
	if code, msg := run(t, root, "src/View.flix", "src/Update.flix"); code != 0 {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// local に規約本体の鍵を書いたら止める（書き間違いで規則が黙って消えない）。
func TestLocalUnknownKey(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{localRel: `{"stateEnum": ["Layer"]}`})
	if err := runErr(t, root, "--all"); err == nil || !strings.Contains(err.Error(), "stateEnum") {
		t.Fatalf("err=%v", err)
	}
}

// --json は 1 件ずつ code・got・want・fix の形で出す。
func TestJSONShape(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"src/W.flix": "    type alias W = { a = Bool, b = Bool, c = Bool, d = Bool }\n",
		localRel:     `{"boolFieldLimits": {"src/W.flix::W": 3}}`,
	})
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, []string{"src/W.flix", "--json"})
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Results []struct {
			Code string  `json:"code"`
			Got  float64 `json:"got"`
			Want struct {
				Op    string  `json:"op"`
				Value float64 `json:"value"`
			} `json:"want"`
			Fix struct {
				Hint string `json:"hint"`
				Try  []struct {
					Try any `json:"try"`
				} `json:"try"`
			} `json:"fix"`
			Cause struct {
				Script string `json:"script"`
			} `json:"cause"`
		} `json:"results"`
		Exit int `json:"exit"`
	}
	if err := json.Unmarshal([]byte(out.String()), &got); err != nil {
		t.Fatalf("%v: %s", err, out.String())
	}
	if code != 1 || got.Exit != 1 || len(got.Results) != 1 {
		t.Fatalf("code=%d out=%s", code, out.String())
	}
	r := got.Results[0]
	if r.Code != CodeBoolFields || r.Got != 4 || r.Want.Op != "<=" || r.Want.Value != 3 || r.Fix.Hint == "" ||
		len(r.Fix.Try) != 1 || r.Cause.Script != "src/W.flix:1" {
		t.Fatalf("%+v", r)
	}
}
