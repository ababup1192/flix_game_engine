package upgradegame

// What: 差し替え・check・sync-agents の順番と**どこで何を渡したか**、赤の意味の分け方
// （当たる非互換 0 件なら戻す・N 件なら新しいまま置く・追随の途中は途中と言う）、
// 数えられなかったときに戻さないこと、指示書を書けないときに成功で返さないこと、
// 巻き戻しの取りこぼし、本物の make の呼び方。

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/updateplan"
)

// recorder は make の呼びを「的@フォルダ 引数…」の形で覚える。
//
// 的の名前だけ覚えると、sync-agents をゲームのフォルダで回す・ENGINE= を落とすといった
// 配線の壊れが緑のまま通る。
type recorder struct {
	calls   []string
	failOn  map[string]bool
	targets map[string]bool
}

func (r *recorder) run(dir string, args ...string) error {
	r.calls = append(r.calls, args[0]+"@"+dir+" "+strings.Join(args[1:], " "))
	if r.failOn[args[0]] {
		return errFake
	}
	return nil
}

func (r *recorder) has(dir, target string) bool { return r.targets[target] }

// targetsOf は的の名前だけを順に返す。
func (r *recorder) targetsOf() []string {
	var out []string
	for _, c := range r.calls {
		out = append(out, c[:strings.Index(c, "@")])
	}
	return out
}

var errFake = errors.New("落ちました")

func write(t *testing.T, dir, rel, body string) {
	t.Helper()
	path := filepath.Join(dir, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

const gameToml = "[dependencies]\n" +
	`"github:ababup1192/flix_game_engine" = { version = "0.30.0", security = "unrestricted" }` + "\n"

const destDir = "lib/github/ababup1192/flix_game_engine/0.31.0"

// setup はゲーム 1 本と、写す元を置いた engine のフォルダを返す。
func setup(t *testing.T) (string, string, opts, *recorder) {
	t.Helper()
	root, game := t.TempDir(), t.TempDir()
	write(t, game, "flix.toml", gameToml)
	write(t, root, "engine_full/artifact/engine_full.fpkg", "new-fpkg")
	write(t, root, "engine_full/flix.toml", "new-toml")
	r := &recorder{failOn: map[string]bool{}, targets: map[string]bool{}}
	o := opts{
		game: game, version: "0.31.0",
		fpkg: "engine_full/artifact/engine_full.fpkg", toml: "engine_full/flix.toml",
		dest:     destDir,
		fpkgName: "flix_game_engine-0.31.0.fpkg", tomlName: "flix_game_engine-0.31.0.toml",
		makeRun: r.run, makeHas: r.has,
		progress: &strings.Builder{}, problems: &strings.Builder{},
		buildPlan: plannedAs(updateplan.Plan{From: "0.30.0", To: "0.31.0"}, nil),
	}
	return root, game, o, r
}

func plannedAs(p updateplan.Plan, err error) func(string, string) (updateplan.Plan, error) {
	return func(string, string) (updateplan.Plan, error) { return p, err }
}

func call(t *testing.T, root string, o opts) (int, string, string) {
	t.Helper()
	progress, problems := &strings.Builder{}, &strings.Builder{}
	o.progress, o.problems = progress, problems
	code, err := run(root, o)
	if err != nil {
		problems.WriteString(err.Error())
	}
	return code, progress.String(), problems.String()
}

// sync-agents は agents-pack 一式を消す方向にも書くミラー。check の前に走らせると
// 巻き戻す物が数百ファイルへ広がる。
func TestSyncAgentsRunsOnlyAfterCheckIsGreen(t *testing.T) {
	root, game, o, r := setup(t)
	code, _, problems := call(t, root, o)
	if code != exitDone {
		t.Fatalf("code=%d problems=%s", code, problems)
	}
	want := []string{
		"check@" + game + " ENGINE=" + root,
		"sync-agents@" + root + " GAME=" + game,
	}
	if strings.Join(r.calls, " / ") != strings.Join(want, " / ") {
		t.Errorf("呼び方=%v\n欲しい=%v", r.calls, want)
	}
	if !strings.Contains(read(t, filepath.Join(game, "flix.toml")), `"0.31.0"`) {
		t.Error("flix.toml が上がっていません")
	}
	if read(t, filepath.Join(game, destDir, o.fpkgName)) != "new-fpkg" {
		t.Error("fpkg を写していません")
	}
}

func TestRedSkipsSyncAgents(t *testing.T) {
	root, _, o, r := setup(t)
	r.failOn["check"] = true
	call(t, root, o)
	for _, c := range r.targetsOf() {
		if c == "sync-agents" {
			t.Error("赤なのに agents-pack を配っています")
		}
	}
}

// 当たる非互換が 0 件なのに赤い = 想定外。ここは戻す。
func TestRollsBackWhenNothingAppliedButCheckIsRed(t *testing.T) {
	root, game, o, r := setup(t)
	r.failOn["check"] = true
	code, _, problems := call(t, root, o)
	if code != exitUnknown {
		t.Errorf("戻したのに code=%d problems=%s", code, problems)
	}
	if got := read(t, filepath.Join(game, "flix.toml")); !strings.Contains(got, `"0.30.0"`) {
		t.Errorf("flix.toml が戻っていません: %s", got)
	}
	if _, err := os.Stat(filepath.Join(game, destDir, o.fpkgName)); err == nil {
		t.Error("写した fpkg が残っています")
	}
	// 空のフォルダが残ると、コミット時のゲートや git status に何の残骸か分からない物が出る。
	if _, err := os.Stat(filepath.Join(game, destDir)); err == nil {
		t.Error("作ったフォルダが空のまま残っています")
	}
}

// 非互換のある上げでは、エージェントが直すまで check は必ず赤。一律に戻すと
// 本命の上げが永久に終わらない。
func TestKeepsTheNewVersionWhenBreakingChangesApply(t *testing.T) {
	root, game, o, r := setup(t)
	r.failOn["check"] = true
	o.buildPlan = plannedAs(updateplan.Plan{Count: 2, Body: "# 指示書\n"}, nil)
	code, out, _ := call(t, root, o)
	if code != exitFollowUp {
		t.Errorf("追随待ちの終了コードになっていません code=%d out=%s", code, out)
	}
	if got := read(t, filepath.Join(game, "flix.toml")); !strings.Contains(got, `"0.31.0"`) {
		t.Errorf("新しいバージョンのまま置いていません: %s", got)
	}
	if !strings.Contains(read(t, filepath.Join(game, planName)), "# 指示書") {
		t.Error("指示書を書いていません")
	}
}

// 「赤でも成功」を成り立たせている唯一の担保が指示書。無ければ、直す材料の無い赤が
// 成功に見える。
func TestFailsWhenThePlanCannotBeWritten(t *testing.T) {
	root, game, o, r := setup(t)
	r.failOn["check"] = true
	o.buildPlan = plannedAs(updateplan.Plan{Count: 2, Body: "# 指示書\n"}, nil)
	o.planOut = filepath.Join(game, "no-such-dir", planName)
	code, _, problems := call(t, root, o)
	if code == exitFollowUp || code == exitDone {
		t.Errorf("指示書が無いのに成功で返しています code=%d", code)
	}
	if !strings.Contains(problems, "指示書") {
		t.Errorf("何が書けなかったか言っていません: %s", problems)
	}
}

// 「当たる非互換が無い」と「数えられなかった」を同じに扱うと、正常な上げまで戻る。
func TestDoesNotRollBackWhenTheCountIsUnknown(t *testing.T) {
	root, game, o, r := setup(t)
	r.failOn["check"] = true
	o.buildPlan = plannedAs(updateplan.Plan{}, errFake)
	code, _, problems := call(t, root, o)
	if code != exitUnknown {
		t.Errorf("code=%d", code)
	}
	if got := read(t, filepath.Join(game, "flix.toml")); !strings.Contains(got, `"0.31.0"`) {
		t.Errorf("数えられないだけで戻しています: %s", got)
	}
	if !strings.Contains(problems, "数えられませんでした") {
		t.Errorf("数えられなかったことを言っていません: %s", problems)
	}
	// 戻す手が無いまま終わると、そこで詰む。
	if !strings.Contains(problems, "手で書き戻して") {
		t.Errorf("戻し方を言っていません: %s", problems)
	}
}

// 前の回が「赤のまま置いた」で終わっていると sync-agents が走っていない。
// 直したあとに打ち直す口が無いと、そこで詰む。
func TestRerunAfterTheFixStillChecksAndSyncs(t *testing.T) {
	root, game, o, r := setup(t)
	write(t, game, "flix.toml", strings.Replace(gameToml, "0.30.0", "0.31.0", 1))
	code, _, _ := call(t, root, o)
	if code != exitDone {
		t.Errorf("code=%d", code)
	}
	if strings.Join(r.targetsOf(), ",") != "check,sync-agents" {
		t.Errorf("打ち直しで何もしていません: %v", r.targetsOf())
	}
}

// 打ち直したゲームは数え元が新しいバージョンなので、追随の途中でも必ず 0 件になる。
// そこを「想定外」と言うと、直している人に嘘を伝える。
func TestPartialFollowUpIsToldApartFromTheUnexpectedRed(t *testing.T) {
	root, game, o, r := setup(t)
	write(t, game, "flix.toml", strings.Replace(gameToml, "0.30.0", "0.31.0", 1))
	write(t, game, planName, "# 指示書\n")
	r.failOn["check"] = true
	code, _, problems := call(t, root, o)
	if code != exitFollowUp {
		t.Errorf("追随の途中として返していません code=%d", code)
	}
	if strings.Contains(problems, "想定外") {
		t.Errorf("追随の途中を想定外と言っています: %s", problems)
	}
	if !strings.Contains(problems, "追随の途中") {
		t.Errorf("何が起きているか言っていません: %s", problems)
	}
}

// 直し終わった指示書が残ると、次に読むエージェントが直し済みの物を直しにいく。
func TestStalePlanIsRemovedOnceEverythingIsGreen(t *testing.T) {
	root, game, o, _ := setup(t)
	write(t, game, planName, "# 前の回の指示書\n")
	call(t, root, o)
	if _, err := os.Stat(filepath.Join(game, planName)); err == nil {
		t.Error("直し終わった指示書が残っています")
	}
}

// 絵の差は人が見て決める物で、機械が「上がらなかった」と言う理由にならない。
func TestReferenceCheckIsInformationNotAFailure(t *testing.T) {
	root, game, o, r := setup(t)
	o.reference = true
	r.targets["reference-check"] = true
	r.failOn["reference-check"] = true
	o.buildPlan = plannedAs(updateplan.Plan{Count: 1, Body: "# 指示書\n"}, nil)
	code, out, _ := call(t, root, o)
	if code != exitDone {
		t.Errorf("絵の差で失敗にしています code=%d", code)
	}
	if !strings.Contains(out, "絵が変わりました") {
		t.Errorf("絵が変わったことを言っていません: %s", out)
	}
	if !strings.Contains(read(t, filepath.Join(game, planName)), "絵が変わりました") {
		t.Error("指示書に絵の 1 行が載っていません")
	}
}

// render-all を連れてくるので数分かかる。毎回払う値段としては釣り合わない。
func TestReferenceCheckIsOffUnlessAsked(t *testing.T) {
	root, _, o, r := setup(t)
	r.targets["reference-check"] = true
	call(t, root, o)
	for _, c := range r.targetsOf() {
		if c == "reference-check" {
			t.Error("頼んでいないのに絵の比較を回しています")
		}
	}
}

// 写す元が無いのに「上げました」と言うと、次の check が別の理由で落ちて読み違える。
func TestMissingSourceRollsBackAndFails(t *testing.T) {
	for _, missing := range []string{"fpkg", "toml"} {
		root, game, o, _ := setup(t)
		if missing == "fpkg" {
			o.fpkg = "engine_full/artifact/nope.fpkg"
		} else {
			o.toml = "engine_full/nope.toml"
		}
		code, _, _ := call(t, root, o)
		if code == exitDone {
			t.Errorf("%s の写す元が無いのに成功しています", missing)
		}
		if got := read(t, filepath.Join(game, "flix.toml")); !strings.Contains(got, `"0.30.0"`) {
			t.Errorf("%s: flix.toml が戻っていません: %s", missing, got)
		}
		// toml だけ無いときは fpkg を写した後なので、そちらも消えていないと残骸になる。
		if _, err := os.Stat(filepath.Join(game, destDir)); err == nil {
			t.Errorf("%s: 作ったフォルダが残っています", missing)
		}
	}
}

func TestApplyNeedsTheDependencyLine(t *testing.T) {
	root, game, o, _ := setup(t)
	write(t, game, "flix.toml", "[package]\nname = \"x\"\n")
	code, _, problems := call(t, root, o)
	if code != exitBadUsage {
		t.Errorf("code=%d", code)
	}
	if !strings.Contains(problems, "依存行") {
		t.Errorf("何が無いか言っていません: %s", problems)
	}
}

func TestParseNeedsEveryPlace(t *testing.T) {
	var errOut strings.Builder
	o := opts{}
	if code := parse(&o, &errOut, []string{"--game", "/tmp/g"}); code != exitBadUsage {
		t.Errorf("足りない引数で code=%d", code)
	}
	if !strings.Contains(errOut.String(), "--version") {
		t.Errorf("何が足りないか言っていません: %s", errOut.String())
	}
}

func TestParseTakesTheNameEqualsValueForm(t *testing.T) {
	var errOut strings.Builder
	o := opts{}
	code := parse(&o, &errOut, []string{
		"--game=/tmp/g", "--version=0.31.0", "--fpkg=a", "--toml=b",
		"--dest=lib/0.31.0", "--fpkg-name=c", "--toml-name=d", "--reference",
	})
	if code != 0 {
		t.Fatalf("code=%d errOut=%s", code, errOut.String())
	}
	if o.game != "/tmp/g" || o.version != "0.31.0" || !o.reference {
		t.Errorf("読めていません: %+v", o)
	}
}

// Flix は flix.toml のバージョンで lib のフォルダを探す。行き先がずれていると、
// 写したのに古い物を掴み続ける（誰も止めない）。
func TestParseRejectsADestThatDoesNotMatchTheVersion(t *testing.T) {
	var errOut strings.Builder
	o := opts{}
	code := parse(&o, &errOut, []string{
		"--game=/tmp/g", "--version=0.31.0", "--fpkg=a", "--toml=b",
		"--dest=lib/0.30.0", "--fpkg-name=c", "--toml-name=d",
	})
	if code != exitBadUsage {
		t.Errorf("ずれた行き先を通しています code=%d", code)
	}
}

// 差し替えの seam を本物で 1 度も通していないと、--no-print-directory の位置や
// 終了コードの読み方が間違っていても気づけない。
func TestRealMakeIsRunAndItsExitCodeIsRead(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "Makefile", "ok:\n\t@true\nng:\n\t@exit 1\n")
	if err := runMake("make", dir, "ok"); err != nil {
		t.Errorf("通る的で落ちています: %v", err)
	}
	if err := runMake("make", dir, "ng"); err == nil {
		t.Error("落ちる的を通っています")
	}
	if !hasTarget("make", dir, "ok") {
		t.Error("在る的を無いと言っています")
	}
	if hasTarget("make", dir, "nope") {
		t.Error("無い的を在ると言っています")
	}
}

// sameVersionGame は版の字が engine と同じ 0.31.0 で、lib に前の束（old-fpkg・old-toml）と、その sha の packages.lock を持つゲーム。
func sameVersionGame(t *testing.T) (string, string, opts, *recorder) {
	t.Helper()
	root, game, o, r := setup(t)
	write(t, game, "flix.toml", strings.Replace(gameToml, "0.30.0", "0.31.0", 1))
	write(t, game, destDir+"/flix_game_engine-0.31.0.fpkg", "old-fpkg")
	write(t, game, destDir+"/flix_game_engine-0.31.0.toml", "old-toml")
	write(t, game, "packages.lock", "[lock]\nversion = 1\n\n"+
		`[packages."github:ababup1192/flix_game_engine"."0.31.0"]`+"\n"+
		`toml    = "sha256:`+sumOf("old-toml")+`"`+"\n"+
		`fpkg    = "sha256:`+sumOf("old-fpkg")+`"`+"\n")
	return root, game, o, r
}

func sumOf(body string) string {
	sum := sha256.Sum256([]byte(body))
	return hex.EncodeToString(sum[:])
}

// 版の字が同じでも engine の束を作り直せば中身は変わる。版だけ見ていると古い束を掴み続け、担当が手で lib と lock を替えていた。
func TestSameVersionWithNewContentIsSwappedAndTheLockFollows(t *testing.T) {
	root, game, o, _ := sameVersionGame(t)
	code, progress, problems := call(t, root, o)
	if code != exitDone {
		t.Fatalf("code=%d problems=%s", code, problems)
	}
	if got := read(t, filepath.Join(game, destDir, "flix_game_engine-0.31.0.fpkg")); got != "new-fpkg" {
		t.Errorf("fpkg を入れ替えていません: %q", got)
	}
	lock := read(t, filepath.Join(game, "packages.lock"))
	if !strings.Contains(lock, sumOf("new-fpkg")) || !strings.Contains(lock, sumOf("new-toml")) {
		t.Errorf("packages.lock の sha をそろえていません:\n%s", lock)
	}
	if !strings.Contains(progress, "v0.31.0 のまま engine の束の中身が新しくなっていたので入れ替えます") {
		t.Errorf("入れ替えたと言っていません:\n%s", progress)
	}
}

// 中身も同じなら何も写さない（打ち直しのたびに lib の時刻を進めると、jar を毎回組み直す）。
func TestSameVersionWithSameContentIsLeftAlone(t *testing.T) {
	root, game, o, _ := sameVersionGame(t)
	write(t, game, destDir+"/flix_game_engine-0.31.0.fpkg", "new-fpkg")
	write(t, game, destDir+"/flix_game_engine-0.31.0.toml", "new-toml")
	_, progress, _ := call(t, root, o)
	if !strings.Contains(progress, "既に v0.31.0 です") {
		t.Errorf("同じ中身を入れ替えています:\n%s", progress)
	}
}

// 入れ替えた束で check が赤く、当たる非互換も無ければ、前の束と前の lock へ戻す（lock だけ新しいと flix が止まる）。
func TestSameVersionSwapIsRolledBackWithTheLock(t *testing.T) {
	root, game, o, r := sameVersionGame(t)
	r.failOn["check"] = true
	code, _, problems := call(t, root, o)
	if code != exitUnknown {
		t.Errorf("code=%d", code)
	}
	if got := read(t, filepath.Join(game, destDir, "flix_game_engine-0.31.0.fpkg")); got != "old-fpkg" {
		t.Errorf("fpkg を戻していません: %q", got)
	}
	if lock := read(t, filepath.Join(game, "packages.lock")); !strings.Contains(lock, sumOf("old-fpkg")) {
		t.Errorf("packages.lock を戻していません:\n%s", lock)
	}
	if !strings.Contains(problems, "v0.31.0 の前の束へ戻しました") {
		t.Errorf("何へ戻したか言っていません: %s", problems)
	}
}

// lib の束は engine と同じで lock の sha だけ古い時も、engine-upgrade で直る（status がそう勧めるので、直らないと知らせが消えない）。
func TestLockOnlyMismatchIsAligned(t *testing.T) {
	root, game, o, _ := sameVersionGame(t)
	write(t, game, destDir+"/flix_game_engine-0.31.0.fpkg", "new-fpkg")
	write(t, game, destDir+"/flix_game_engine-0.31.0.toml", "new-toml")
	if code, _, problems := call(t, root, o); code != exitDone {
		t.Fatalf("code=%d problems=%s", code, problems)
	}
	if lock := read(t, filepath.Join(game, "packages.lock")); !strings.Contains(lock, sumOf("new-fpkg")) {
		t.Errorf("lock だけの差を直していません:\n%s", lock)
	}
}

// 配った版の engine は同じ版の束を中身で入れ替えない（use-engine で入れた作業場の束を同梱の束へ戻さない）。
func TestNoContentSwapKeepsTheGameBundle(t *testing.T) {
	root, game, o, _ := sameVersionGame(t)
	o.noContentSwap = true
	call(t, root, o)
	if got := read(t, filepath.Join(game, destDir, "flix_game_engine-0.31.0.fpkg")); got != "old-fpkg" {
		t.Errorf("--no-content-swap なのに入れ替えています: %q", got)
	}
}

// lib に束の無い同じ版のゲーム（Release から flix に取らせる形）へは、手元の束を黙って置かない。
func TestSameVersionWithoutALibBundleIsNotSwapped(t *testing.T) {
	root, game, o, _ := setup(t)
	write(t, game, "flix.toml", strings.Replace(gameToml, "0.30.0", "0.31.0", 1))
	call(t, root, o)
	if _, err := os.Stat(filepath.Join(game, destDir, "flix_game_engine-0.31.0.fpkg")); err == nil {
		t.Error("lib に無かった束を置いています")
	}
}

// lock にその版の節が無ければ触らない（flix が足す）。
func TestLockWithoutTheSectionIsLeftToFlix(t *testing.T) {
	root, game, o, _ := sameVersionGame(t)
	body := "[lock]\nversion = 1\n"
	write(t, game, "packages.lock", body)
	call(t, root, o)
	if got := read(t, filepath.Join(game, "packages.lock")); got != body {
		t.Errorf("節の無い lock を書き換えています:\n%s", got)
	}
}

// 置き場の束は読むだけ（0444）。前の回に写した物が 0444 でも、上書きできずに落ちてはいけない。
func TestReadOnlyCopyInTheGameIsReplaced(t *testing.T) {
	root, game, o, _ := sameVersionGame(t)
	if err := os.Chmod(filepath.Join(game, destDir, "flix_game_engine-0.31.0.fpkg"), 0o444); err != nil {
		t.Fatal(err)
	}
	if code, _, problems := call(t, root, o); code != exitDone {
		t.Fatalf("code=%d problems=%s", code, problems)
	}
	if got := read(t, filepath.Join(game, destDir, "flix_game_engine-0.31.0.fpkg")); got != "new-fpkg" {
		t.Errorf("読むだけの写しを入れ替えていません: %q", got)
	}
}
