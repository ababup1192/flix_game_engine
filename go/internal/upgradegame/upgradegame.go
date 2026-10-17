package upgradegame

// upgradegame — ゲーム 1 本を新しい engine へ載せ替える。
//
//	fge upgrade-game --game DIR --version 0.31.0 \
//	  --fpkg engine_full/artifact/engine_full.fpkg --toml engine_full/flix.toml \
//	  --dest lib/github/... --fpkg-name ...fpkg --toml-name ...toml
//
// 終了コード: 0 上げ切った / 3 追随待ち（check は赤だが当たる非互換があるので正常） /
// 1 想定外 / 2 引数と入出力。
//
// WhyNot: sync-agents を check の前に走らせないのは、あれが agents-pack 一式
// （fge 本体・skills・lint-rules）を消す方向にも書くミラーで、巻き戻す物に入れると
// 戻す範囲が数百ファイルに広がるため。この順番なら戻す物は 3 ファイルで済む。
//
// WhyNot: 赤を一律で巻き戻さないのは、非互換のあるバージョン上げでは
// エージェントが直すまで check が必ず赤で、一律に戻すと本命の上げが永久に終わらないため。
// 当たる非互換が 0 件なのに赤いときだけ、想定外として戻す。
//
// WhyNot: 追随待ちに 0 でなく 3 を割り当てるのは、人の入口（make upgrade-game）では
// 成功に見せたい一方、CI や Studio からは「上げ切った」と区別が要るため。
// 潰すのは Makefile の側でやる。

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flix_game_engine/go/internal/updateplan"
)

const usage = "使い方: fge upgrade-game --game DIR --version X.Y.Z " +
	"--fpkg SRC --toml SRC --dest SUBPATH --fpkg-name NAME --toml-name NAME " +
	"[--reference] [--make MAKE] [--json]"

// 終了コード。
const (
	exitDone     = 0
	exitUnknown  = 1
	exitBadUsage = 2
	exitFollowUp = 3
)

// depRe はゲームの flix.toml が指す engine のバージョン（差し替える所）。
var depRe = regexp.MustCompile(
	`("github:ababup1192/flix_game_engine"\s*=\s*\{[^}]*version\s*=\s*)"[^"]+"`)

// readDepRe は今指しているバージョンを読む方。
var readDepRe = regexp.MustCompile(
	`"github:ababup1192/flix_game_engine"\s*=\s*\{[^}]*version\s*=\s*"([^"]+)"`)

// planName は指示書の既定の置き場（ゲームの直下）。
const planName = "UPDATE_PLAN.md"

type opts struct {
	game, version      string
	fpkg, toml         string
	dest               string
	fpkgName, tomlName string
	planOut            string
	makeBin            string
	reference          bool
	asJSON             bool
	// 進み具合はそのまま流す。溜めると make の長い出力より後に出て、
	// 何が始まったのか分からないまま数分待つことになる。
	progress, problems io.Writer
	// テストから外の物を差し替える口（本物は runMake / hasTarget / updateplan.Build）。
	makeRun   func(dir string, args ...string) error
	makeHas   func(dir, target string) bool
	buildPlan func(root, game string) (updateplan.Plan, error)
}

// result は --json で出す形。Studio は「上げ切った / 追随待ち / 失敗」を
// 終了コードだけでは見分けられないので、こちらを読む。
type result struct {
	Swapped    bool   `json:"swapped"`
	CheckGreen bool   `json:"checkGreen"`
	PlanKnown  bool   `json:"planKnown"`
	PlanCount  int    `json:"planCount"`
	PlanPath   string `json:"planPath,omitempty"`
	Reference  string `json:"reference,omitempty"`
	RolledBack bool   `json:"rolledBack"`
	Exit       int    `json:"exit"`
}

// Run はゲームを載せ替えて終了コードを返す。
func Run(out, errOut *strings.Builder, root string, args []string, asJSON bool) (int, error) {
	o := opts{
		makeBin: "make", asJSON: asJSON,
		progress: os.Stdout, problems: os.Stderr,
		buildPlan: func(root, game string) (updateplan.Plan, error) {
			return updateplan.Build(root, game, "")
		},
	}
	o.makeRun = func(dir string, args ...string) error { return runMake(o.makeBin, dir, args...) }
	o.makeHas = func(dir, target string) bool { return hasTarget(o.makeBin, dir, target) }
	if code := parse(&o, errOut, args); code != 0 {
		return code, nil
	}
	return run(root, o)
}

func parse(o *opts, errOut *strings.Builder, args []string) int {
	values := map[string]*string{
		"--game": &o.game, "--version": &o.version,
		"--fpkg": &o.fpkg, "--toml": &o.toml, "--dest": &o.dest,
		"--fpkg-name": &o.fpkgName, "--toml-name": &o.tomlName,
		"--plan-out": &o.planOut, "--make": &o.makeBin,
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--reference" {
			o.reference = true
			continue
		}
		name, inline := a, ""
		if j := strings.Index(a, "="); j > 0 {
			name, inline = a[:j], a[j+1:]
		}
		p, ok := values[name]
		if !ok {
			fmt.Fprintf(errOut, "error: 知らない引数です: %s\n%s\n", a, usage)
			return exitBadUsage
		}
		if name != a {
			*p = inline
			continue
		}
		if i+1 >= len(args) || strings.HasPrefix(args[i+1], "--") {
			fmt.Fprintf(errOut, "error: %s には値を渡してください\n%s\n", a, usage)
			return exitBadUsage
		}
		*p = args[i+1]
		i++
	}
	for _, need := range []struct{ name, val string }{
		{"--game", o.game}, {"--version", o.version}, {"--fpkg", o.fpkg},
		{"--toml", o.toml}, {"--dest", o.dest},
		{"--fpkg-name", o.fpkgName}, {"--toml-name", o.tomlName},
	} {
		if need.val == "" {
			fmt.Fprintf(errOut, "error: %s を指定してください\n%s\n", need.name, usage)
			return exitBadUsage
		}
	}
	// WhyNot: 行き先にバージョンが入っているか見るのは、Makefile 以外から呼んだときに
	// 0.31.0 の fpkg を 0.30.0 のフォルダへ写しても誰も止めないため。
	// Flix は flix.toml のバージョンでフォルダを探すので、その場合は古い物を掴み続ける。
	if !strings.Contains(o.dest, o.version) {
		fmt.Fprintf(errOut, "error: --dest (%s) に --version (%s) が入っていません\n",
			o.dest, o.version)
		return exitBadUsage
	}
	return 0
}

func run(root string, o opts) (int, error) {
	// WhyNot: 絶対パスへ直すのは、sync-agents を engine のフォルダで回すため。
	// 相対のまま渡すと、そこから見て違う場所を指す。
	o.game = absFrom(root, o.game)
	o.fpkg = absFrom(root, o.fpkg)
	o.toml = absFrom(root, o.toml)
	o.planOut = absFrom(root, o.planOut)

	gameToml := filepath.Join(o.game, "flix.toml")
	if _, err := os.Stat(gameToml); err != nil {
		return exitBadUsage, fmt.Errorf("%s がありません", gameToml)
	}

	// 指示書は差し替える前に組む。当たり所を数えるのは古い方のソースが相手なので、
	// どちらでも同じ物が出るが、差し替えに失敗したときに材料だけ残るのを避ける。
	plan, planErr := o.buildPlan(root, o.game)

	before, err := pxlib.LoadTextReplace(gameToml)
	if err != nil {
		return exitBadUsage, err
	}
	res := result{PlanKnown: planErr == nil, PlanCount: plan.Count}
	res.Swapped = versionIn(before) != o.version

	var undo *backup
	if res.Swapped {
		fmt.Fprintf(o.progress, "[upgrade-game] %s: v%s -> v%s\n",
			o.game, versionIn(before), o.version)
		undo, err = apply(o, gameToml, before)
		if err != nil {
			if undo != nil {
				undo.restore()
			}
			return exitBadUsage, err
		}
	} else {
		// WhyNot: 既に新しいときに何もせず終わらないのは、直したあとに打ち直す口が
		// 無くなるため。前の回が「赤のまま置いた」で終わっていると sync-agents が
		// 走っていないので、ここで check からやり直せる形にしておく。
		fmt.Fprintf(o.progress, "[upgrade-game] %s: 既に v%s です。check からやり直します\n",
			o.game, o.version)
	}

	code, err := decide(root, o, &res, plan, planErr, undo)
	if o.asJSON {
		res.Exit = code
		body, _ := json.MarshalIndent(res, "", "  ")
		fmt.Fprintf(o.progress, "%s\n", body)
	}
	return code, err
}

// decide は check を回し、その結果で分かれる。
func decide(root string, o opts, res *result, plan updateplan.Plan, planErr error, undo *backup) (int, error) {
	if err := o.makeRun(o.game, "check", "ENGINE="+root); err != nil {
		return red(o, res, plan, planErr, undo)
	}
	res.CheckGreen = true
	return green(root, o, res, plan, planErr)
}

// green は check が通ったとき。ここで初めて agents-pack を配る。
func green(root string, o opts, res *result, plan updateplan.Plan, planErr error) (int, error) {
	if err := o.makeRun(root, "sync-agents", "GAME="+o.game); err != nil {
		return exitUnknown, fmt.Errorf("check は通りましたが sync-agents が失敗しました: %v", err)
	}
	fmt.Fprintf(o.progress, "[upgrade-game] check OK / agents-pack を配りました\n")

	res.Reference = referenceLine(root, o)
	if res.Reference != "" {
		fmt.Fprintf(o.progress, "[upgrade-game] %s\n", res.Reference)
	}
	if planErr == nil && plan.Count == 0 {
		// WhyNot: 前の回の指示書を消すのは、残っていると次に読むエージェントが
		// 直し終わった物をもう一度直しにいく材料になるため。
		clearPlan(o)
	}
	if planErr == nil && plan.Count > 0 {
		path, err := writePlan(o, plan, res.Reference)
		if err != nil {
			fmt.Fprintf(o.problems, "[upgrade-game] 指示書を書けませんでした: %v\n", err)
		}
		res.PlanPath = path
		fmt.Fprintf(o.progress, "[upgrade-game] check は通りましたが、当たる非互換が %d 件あります。"+
			"指示書を見て確かめてください\n", plan.Count)
	}
	fmt.Fprintf(o.progress, "[upgrade-game] 続きは自分の目で: make test\n")
	return exitDone, nil
}

// red は check が落ちたとき。当たる非互換の数で意味が変わる。
func red(o opts, res *result, plan updateplan.Plan, planErr error, undo *backup) (int, error) {
	// WhyNot: 指示書を組めなかったときに巻き戻さないのは、「当たる非互換が無い」のと
	// 「数えられなかった」を同じに扱うと、正常な上げまで戻してしまうため。
	if planErr != nil {
		fmt.Fprintf(o.problems, "[upgrade-game] check が赤ですが、当たる非互換を数えられませんでした"+
			"（%v）。念のため戻さずに置きます。\n"+
			"  戻すなら flix.toml の engine のバージョンを手で書き戻してください\n", planErr)
		return exitUnknown, nil
	}
	if plan.Count == 0 && !res.Swapped && hasPlanFile(o) {
		// WhyNot: ここを「想定外」と言わないのは、既に上げてあるゲームでは数え元が
		// 新しいバージョンになり、追随の途中でも必ず 0 件と出るため。
		fmt.Fprintf(o.problems, "[upgrade-game] 追随の途中です。%s の残りを直してから"+
			"打ち直してください\n", planPath(o))
		return exitFollowUp, nil
	}
	if plan.Count == 0 && undo != nil {
		if err := undo.restore(); err != nil {
			fmt.Fprintf(o.problems, "[upgrade-game] 戻せませんでした（%v）。"+
				"flix.toml の engine のバージョンを手で v%s に戻してください\n", err, undo.version)
			return exitUnknown, nil
		}
		res.RolledBack = true
		fmt.Fprintf(o.problems, "[upgrade-game] 上がりませんでした。当たる非互換は 0 件なのに "+
			"check が赤いので、想定外として v%s へ戻しました\n", undo.version)
		return exitUnknown, nil
	}
	if plan.Count == 0 {
		fmt.Fprintf(o.problems, "[upgrade-game] check が赤いままです（当たる非互換は 0 件）。"+
			"差し替えていないので戻す物はありません\n")
		return exitUnknown, nil
	}
	path, err := writePlan(o, plan, "")
	if err != nil {
		// WhyNot: 書けなかったときに追随待ちで返さないのは、「赤でも成功」を成り立たせて
		// いる唯一の担保が指示書のため。無ければ、直す材料の無い赤が成功に見える。
		return exitUnknown, fmt.Errorf("check は赤で、指示書も書けませんでした: %v", err)
	}
	res.PlanPath = path
	fmt.Fprintf(o.progress, "[upgrade-game] check は赤ですが、当たる非互換が %d 件あるので正常です。\n"+
		"  新しい engine のまま置きました。%s をエージェントに直させてください。\n"+
		"  直したら make upgrade-game GAME=%s を打ち直すと、check から続きます\n",
		plan.Count, path, o.game)
	return exitFollowUp, nil
}

// planPath は指示書の置き場。
func planPath(o opts) string {
	if o.planOut != "" {
		return o.planOut
	}
	return filepath.Join(o.game, planName)
}

func hasPlanFile(o opts) bool {
	_, err := os.Stat(planPath(o))
	return err == nil
}

// writePlan は指示書を書き、その置き場を返す。
func writePlan(o opts, plan updateplan.Plan, refLine string) (string, error) {
	path := planPath(o)
	body := plan.Body
	if refLine != "" {
		body += "\n" + refLine + "\n"
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		return "", err
	}
	fmt.Fprintf(o.progress, "[upgrade-game] %s を書きました（直す物 %d 件）\n", path, plan.Count)
	return path, nil
}

func clearPlan(o opts) {
	if err := os.Remove(planPath(o)); err == nil {
		fmt.Fprintf(o.progress, "[upgrade-game] 直し終わったので %s を消しました\n", planPath(o))
	}
}

// referenceLine は絵が変わったかの 1 行。
//
// WhyNot: 既定で回さないのは、reference-check が render-all を連れてきて数分かかり、
// 得られるのが指示書の 1 行だけのため。リファレンス画像をまだ作っていないゲームでは
// 赤になるので、「絵が変わりました」という嘘まで載る。
//
// WhyNot: 赤でも upgrade-game を失敗にしないのは、絵の差は人が見て決める物で、
// 機械が「上がらなかった」と言う理由にならないため。
func referenceLine(root string, o opts) string {
	if !o.reference {
		return ""
	}
	if !o.makeHas(o.game, "reference-check") {
		return "絵の比較はしていません（reference-check がありません）"
	}
	fmt.Fprintf(o.progress, "[upgrade-game] 絵の比較を回します（描き出すので数分かかります）\n")
	if err := o.makeRun(o.game, "reference-check", "ENGINE="+root); err != nil {
		return "絵が変わりました（reference-check が赤）。変わってよい差かは人が見て決めます"
	}
	return "絵は変わっていません（reference-check は緑）"
}

// backup は差し替えた 3 ファイルを元へ戻すための控え。
type backup struct {
	version    string
	tomlPath   string
	tomlBody   []byte
	created    []string
	createdDir string
	replaced   map[string][]byte
}

// restore は控えから元へ戻す。
//
// WhyNot: 失敗を握り潰さないのは、戻せていないのに「戻しました」と言うと、
// 読む側の次の判断が全部ずれるため。
func (b *backup) restore() error {
	err := os.WriteFile(b.tomlPath, b.tomlBody, 0o644)
	for path, body := range b.replaced {
		if e := os.WriteFile(path, body, 0o644); e != nil && err == nil {
			err = e
		}
	}
	for _, path := range b.created {
		if e := os.Remove(path); e != nil && !os.IsNotExist(e) && err == nil {
			err = e
		}
	}
	// WhyNot: 作ったフォルダも消すのは、空のまま残るとコミット時のゲートや
	// git status に出て、次に触る人が何の残骸か分からないため。
	// 元から在ったフォルダは消さない（中身を消したのはこちらではない）。
	if b.createdDir != "" {
		_ = os.Remove(b.createdDir)
	}
	return err
}

// apply は flix.toml のバージョンを進め、fpkg と toml をゲームの lib へ写す。
//
// WhyNot: 書き込みに失敗した経路でも控えを返すのは、os.WriteFile が中身を切り詰めてから
// 落ちうるため。控えを捨てると、切り詰められた flix.toml が戻されないまま残る。
func apply(o opts, gameToml, before string) (*backup, error) {
	after := depRe.ReplaceAllString(before, `${1}"`+o.version+`"`)
	if after == before {
		return nil, fmt.Errorf("%s に flix_game_engine の依存行がありません", gameToml)
	}
	undo := &backup{
		version:  versionIn(before),
		tomlPath: gameToml,
		tomlBody: []byte(before),
		replaced: map[string][]byte{},
	}
	if err := os.WriteFile(gameToml, []byte(after), 0o644); err != nil {
		return undo, err
	}
	destDir := filepath.Join(o.game, filepath.FromSlash(o.dest))
	if _, err := os.Stat(destDir); os.IsNotExist(err) {
		undo.createdDir = destDir
	}
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return undo, err
	}
	for _, f := range []struct{ src, name string }{
		{o.fpkg, o.fpkgName}, {o.toml, o.tomlName},
	} {
		if err := copyInto(undo, f.src, filepath.Join(destDir, f.name)); err != nil {
			return undo, err
		}
	}
	return undo, nil
}

func copyInto(undo *backup, src, dest string) error {
	body, err := os.ReadFile(src)
	if err != nil {
		return fmt.Errorf("%s を読めません: %v", src, err)
	}
	if old, readErr := os.ReadFile(dest); readErr == nil {
		undo.replaced[dest] = old
	} else {
		undo.created = append(undo.created, dest)
	}
	return os.WriteFile(dest, body, 0o644)
}

// versionIn は flix.toml が今指しているバージョン（読めなければ空）。
func versionIn(text string) string {
	m := readDepRe.FindStringSubmatch(text)
	if m == nil {
		return ""
	}
	return m[1]
}

// absFrom は相対パスを engine のフォルダから見た絶対パスにする。
func absFrom(root, path string) string {
	if path == "" || filepath.IsAbs(path) {
		return path
	}
	return filepath.Join(root, path)
}

// runMake は make を回し、出す物はそのまま流す（長いので溜めない）。
func runMake(makeBin, dir string, args ...string) error {
	cmd := exec.Command(makeBin, append([]string{"--no-print-directory", "-C", dir}, args...)...)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	return cmd.Run()
}

// hasTarget はそのフォルダの Makefile がその的を持つか（空回しで見る）。
//
// WhyNot: 空回しにも同じ引数を渡すのは、渡さないと local.mk の解決に失敗して
// 「的が無い」と読み、絵の比較を黙って飛ばすため。
func hasTarget(makeBin, dir, target string) bool {
	cmd := exec.Command(makeBin, "-C", dir, "-n", target)
	cmd.Stdout, cmd.Stderr = nil, nil
	return cmd.Run() == nil
}
