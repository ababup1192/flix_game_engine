package rounds

// rounds — 絵の周回（描き直すたびの絵と台本）を debug/history/<名前>/ に積み、
// 止まって依頼主に聞く所で案内を出す。
//
//	fge-go rounds snap <名前> <PNG か sprite.json> <台本> [--new] [--bg "#2a2a33"]
//	fge-go rounds restore <名前> rN <台本>
//	fge-go rounds --help
//
// snap は rN.png（絵）と rN.<台本のファイル名>（台本の写し）を空いている次の番号で積む。
// PNG はそのまま写し、*.sprite.json は全コマを並べた見本のシート（等倍と拡大を横に並べる）に描く。
// ゲームのルートはカレントディレクトリ。周の数の決まりは bin/lint-rules/rounds.json。
//
// WhyNot: 案内の文言をコードが持つのは、文書に書いた決まりは呼ぶ側の prompt（「5 周まで」等）に
// 上書きされるが、口の出力は周ごとに必ず目に入るため。止める理由は docs/drawing-floor.md の
// 「絵の周回の理由」。

import (
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// RulesPath は規約データの置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "rounds.json")

type rulesFile struct {
	MaxRounds  *int    `json:"maxRounds"`
	AskAt      *int    `json:"askAt"`
	HistoryDir *string `json:"historyDir"`
	DefaultBg  *string `json:"defaultBg"`
}

// Rules は周回の決まり。すべて JSON から来る。
type Rules struct {
	MaxRounds  int
	AskAt      int
	HistoryDir string
	DefaultBg  string
}

// LoadRules は規約データを読む。
// WhyNot: 読めないときに既定値で続けないのは、上限を消しただけで黙って止まらなくなるため。
func LoadRules(root string) (*Rules, error) {
	data, err := os.ReadFile(filepath.Join(root, RulesPath))
	if err != nil {
		return nil, fmt.Errorf("規約ファイルを読めません: %v", err)
	}
	var f rulesFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("%s が壊れています: %v", RulesPath, err)
	}
	switch {
	case f.MaxRounds == nil:
		return nil, fmt.Errorf("%s に maxRounds がありません", RulesPath)
	case f.AskAt == nil:
		return nil, fmt.Errorf("%s に askAt がありません", RulesPath)
	case f.HistoryDir == nil:
		return nil, fmt.Errorf("%s に historyDir がありません", RulesPath)
	case f.DefaultBg == nil:
		return nil, fmt.Errorf("%s に defaultBg がありません", RulesPath)
	}
	return &Rules{*f.MaxRounds, *f.AskAt, *f.HistoryDir, *f.DefaultBg}, nil
}

// Usage は --help の本文。
const Usage = `使い方: bin/fge rounds <口> ...   絵の周回を debug/history/<名前>/ に積む（ゲームのルートで流す）

  rounds snap <名前> <PNG か sprite.json> <台本> [--new] [--bg "#2a2a33"]
      rN.png と rN.<台本のファイル名> を空いている次の番号で積み、次にすることを出す。
      sprite.json は全コマを並べた見本のシートに描く。
      --new  前の周回を debug/history/<名前>-old-<日時> へ退けて r1 から始める（別の作業のとき）
      --bg   見本のシートの背景
  rounds restore <名前> rN <台本>
      その周に保存した台本を <台本> の場所へ戻す（戻したら流し直して描く）。

周の数の決まりは bin/lint-rules/rounds.json。出る案内に従う。
`

var roundPattern = regexp.MustCompile(`^r([1-9][0-9]*)$`)

// Run は rounds の入口。rulesRoot は規約データの置き場、gameRoot は周回を積むゲームのルート。
func Run(out, errOut io.Writer, rulesRoot, gameRoot string, args []string) (int, error) {
	if len(args) == 0 {
		fmt.Fprint(errOut, Usage)
		return 2, nil
	}
	if args[0] == "--help" || args[0] == "-h" || args[0] == "help" {
		fmt.Fprint(out, Usage)
		return 0, nil
	}
	rules, err := LoadRules(rulesRoot)
	if err != nil {
		return 2, err
	}
	switch args[0] {
	case "snap":
		return snap(out, errOut, rules, gameRoot, args[1:])
	case "restore":
		return restore(out, errOut, rules, gameRoot, args[1:])
	}
	fmt.Fprintf(errOut, "rounds: 知らない口: %s\n\n", args[0])
	fmt.Fprint(errOut, Usage)
	return 2, nil
}

// splitFlags は --new と --bg 値 を取り出し、残りの位置引数を返す。
func splitFlags(args []string) (positional []string, isNew bool, bg string, err error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--new":
			isNew = true
		case a == "--bg":
			if i+1 >= len(args) {
				return nil, false, "", fmt.Errorf("--bg に色がありません")
			}
			bg = args[i+1]
			i++
		case strings.HasPrefix(a, "--bg="):
			bg = strings.TrimPrefix(a, "--bg=")
		case a == "--json":
			return nil, false, "", fmt.Errorf("--json は未対応（出力は人と依頼主に向けた案内の文だけ）")
		case strings.HasPrefix(a, "--"):
			return nil, false, "", fmt.Errorf("知らない指定: %s", a)
		default:
			positional = append(positional, a)
		}
	}
	return positional, isNew, bg, nil
}

// checkName は周回の名前がフォルダ 1 つに収まるかを見る。
func checkName(name string) error {
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
		return fmt.Errorf("名前はフォルダ 1 つ分にする（/ を含めない）: %q", name)
	}
	return nil
}

func relTo(root, path string) string {
	if rel, err := filepath.Rel(root, path); err == nil && !strings.HasPrefix(rel, "..") {
		return filepath.ToSlash(rel)
	}
	return path
}

func resolve(root, path string) string {
	if filepath.IsAbs(path) {
		return path
	}
	return filepath.Join(root, path)
}

// NextRound は historyDir に空いている次の番号（r1 から）。
func NextRound(hist string) int {
	n := 1
	for pxlib.HasFile(filepath.Join(hist, fmt.Sprintf("r%d.png", n))) {
		n++
	}
	return n
}

func snap(out, errOut io.Writer, rules *Rules, gameRoot string, args []string) (int, error) {
	positional, isNew, bg, err := splitFlags(args)
	if err != nil {
		fmt.Fprintf(errOut, "rounds: %v\n", err)
		return 2, nil
	}
	if len(positional) != 3 {
		fmt.Fprint(errOut, "rounds snap: <名前> <PNG か sprite.json> <台本> の 3 つが要る\n\n"+Usage)
		return 2, nil
	}
	name, picture, script := positional[0], resolve(gameRoot, positional[1]), resolve(gameRoot, positional[2])
	if err := checkName(name); err != nil {
		fmt.Fprintf(errOut, "rounds: %v\n", err)
		return 2, nil
	}
	if bg == "" {
		bg = rules.DefaultBg
	}
	isSprite := strings.HasSuffix(picture, ".sprite.json")
	if !isSprite && !strings.HasSuffix(strings.ToLower(picture), ".png") {
		fmt.Fprintf(errOut, "rounds: 絵は PNG か *.sprite.json にする: %s\n", positional[1])
		return 2, nil
	}
	for _, p := range []string{picture, script} {
		if !pxlib.HasFile(p) {
			fmt.Fprintf(errOut, "rounds: %s が無い\n", relTo(gameRoot, p))
			return 2, nil
		}
	}

	hist := filepath.Join(gameRoot, filepath.FromSlash(rules.HistoryDir), name)
	if isNew && pxlib.HasDir(hist) {
		old := hist + "-old-" + time.Now().Format("20060102-150405")
		if err := os.Rename(hist, old); err != nil {
			return 2, err
		}
		fmt.Fprintf(out, "前の周回は %s へ退けた\n", relTo(gameRoot, old))
	}
	n := NextRound(hist)
	if n > rules.MaxRounds {
		fmt.Fprintf(errOut, "rounds: %d 周を超える。依頼主に終わりを聞くか、--new で別の作業として始める\n", rules.MaxRounds)
		return 1, nil
	}
	if err := os.MkdirAll(hist, 0o755); err != nil {
		return 2, err
	}
	pngPath := filepath.Join(hist, fmt.Sprintf("r%d.png", n))
	if isSprite {
		frames, err := WriteSpriteSheet(gameRoot, picture, pngPath, bg, errOut)
		if err != nil {
			fmt.Fprintf(errOut, "rounds: %v\n", err)
			return 1, nil
		}
		fmt.Fprintf(out, "見本: %d コマ\n", frames)
	} else if err := copyFile(picture, pngPath); err != nil {
		return 2, err
	}
	if err := copyFile(script, filepath.Join(hist, fmt.Sprintf("r%d.%s", n, filepath.Base(script)))); err != nil {
		return 2, err
	}
	fmt.Fprintf(out, "周: %s（台本も同じ番号で保存）\n", relTo(gameRoot, pngPath))
	switch {
	case n == rules.AskAt:
		fmt.Fprintf(out, "r%d: ここで止める。依頼主に「①r%d と r%d のどちらが良いか ②続けるか終わりか ③続けるなら直す所を 1 つ」だけ聞き、返事まで r%d を描かない\n",
			n, n-1, n, n+1)
		fmt.Fprintf(out, "  ②が「終わり」なら①で選ばれた周を提出する。続けるなら、拡大で見つけた欠陥は実寸で読める物だけ直す\n")
	case n > rules.AskAt:
		fmt.Fprintf(out, "r%d: 依頼主に「①r%d と r%d のどちらが良いか」を聞く。前が良ければ戻す:\n", n, n-1, n)
		fmt.Fprintf(out, "  bin/fge rounds restore %s r%d %s\n", name, n-1, relTo(gameRoot, script))
		if n == rules.MaxRounds {
			fmt.Fprintf(out, "r%d が最後の周（%d 周まで）。選ばれた周を提出する\n", n, rules.MaxRounds)
		}
	}
	return 0, nil
}

func restore(out, errOut io.Writer, rules *Rules, gameRoot string, args []string) (int, error) {
	positional, _, _, err := splitFlags(args)
	if err != nil || len(positional) != 3 {
		fmt.Fprint(errOut, "rounds restore: <名前> rN <台本> の 3 つが要る\n\n"+Usage)
		return 2, nil
	}
	name, round, script := positional[0], positional[1], resolve(gameRoot, positional[2])
	if err := checkName(name); err != nil {
		fmt.Fprintf(errOut, "rounds: %v\n", err)
		return 2, nil
	}
	if !roundPattern.MatchString(round) {
		fmt.Fprintf(errOut, "rounds: 周は r1・r2 … の形で書く: %s\n", round)
		return 2, nil
	}
	saved := filepath.Join(gameRoot, filepath.FromSlash(rules.HistoryDir), name, round+"."+filepath.Base(script))
	if !pxlib.HasFile(saved) {
		fmt.Fprintf(errOut, "rounds: %s が無い\n", relTo(gameRoot, saved))
		return 1, nil
	}
	if err := copyFile(saved, script); err != nil {
		return 2, err
	}
	fmt.Fprintf(out, "%s を %s の版に戻した（流し直して描く）\n", relTo(gameRoot, script), round)
	return 0, nil
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o644)
}

// 見本のシートの割り付け（bin/pxkit の sheet と同じ: 等倍の隣に拡大を置き、横幅 sheetMaxWidth で折り返す）。
const (
	sheetGap      = 6
	sheetMaxWidth = 1600
	zoomSmallSide = 64 // コマの長い辺がこれ以下なら 4 倍、超えたら 2 倍
)

var missingColor = pxlib.RGBA{0xFF, 0x00, 0xFF, 0xFF} // legend に無い・解けない色は目立つ色で塗る

// spriteFrames は sprites のコマを名前順に並べて取り出す（"//" で始まる名前と文字列でない行は飛ばす）。
func spriteFrames(doc map[string]any) [][]string {
	sprites, _ := pxlib.AsObject(doc["sprites"])
	names := make([]string, 0, len(sprites))
	for n := range sprites {
		names = append(names, n)
	}
	sort.Strings(names)
	var frames [][]string
	for _, name := range names {
		spec, ok := pxlib.AsObject(sprites[name])
		if strings.HasPrefix(name, "//") || !ok {
			continue
		}
		byName, _ := pxlib.AsObject(spec["frames"])
		frameNames := make([]string, 0, len(byName))
		for n := range byName {
			frameNames = append(frameNames, n)
		}
		sort.Strings(frameNames)
		for _, fn := range frameNames {
			rowsAny, ok := byName[fn].([]any)
			if !ok || len(rowsAny) == 0 {
				continue
			}
			rows := make([]string, 0, len(rowsAny))
			for _, r := range rowsAny {
				if s, ok := r.(string); ok {
					rows = append(rows, s)
				}
			}
			if len(rows) == len(rowsAny) {
				frames = append(frames, rows)
			}
		}
	}
	return frames
}

// WriteSpriteSheet は sprite.json の全コマを並べた見本を outPNG に書き、コマの数を返す。
// 色名は gameRoot の下の *.theme.json・paletteFile・palette から解く（pxlib.LegendColorsOf）。
func WriteSpriteSheet(gameRoot, spritePath, outPNG, bg string, warn io.Writer) (int, error) {
	doc, ok := pxlib.AsObject(pxlib.ReadJSON(spritePath))
	if !ok {
		return 0, fmt.Errorf("読めない: %s", relTo(gameRoot, spritePath))
	}
	legend, unresolved := pxlib.LegendColorsOf(gameRoot, doc)
	if len(unresolved) > 0 {
		fmt.Fprintf(warn, "!! 解けない色（マゼンタで塗った）: %s\n", strings.Join(unresolved, " "))
	}
	frames := spriteFrames(doc)
	if len(frames) == 0 {
		return 0, fmt.Errorf("見本にするコマが無い: %s", relTo(gameRoot, spritePath))
	}
	back, ok := pxlib.RGBAOfValue(bg)
	if !ok {
		return 0, fmt.Errorf("--bg の色が読めない: %s", bg)
	}
	fw, fh := 0, 0
	runeFrames := make([][][]rune, len(frames))
	for i, rows := range frames {
		runeFrames[i] = make([][]rune, len(rows))
		for y, r := range rows {
			runeFrames[i][y] = []rune(r)
			if len(runeFrames[i][y]) > fw {
				fw = len(runeFrames[i][y])
			}
		}
		if len(rows) > fh {
			fh = len(rows)
		}
	}
	zoom := 2
	if max(fw, fh) <= zoomSmallSide {
		zoom = 4
	}
	cellW, cellH := fw+sheetGap+fw*zoom, fh*zoom
	cols := max(1, min(len(frames), sheetMaxWidth/(cellW+sheetGap)))
	nrows := (len(frames) + cols - 1) / cols
	img := image.NewNRGBA(image.Rect(0, 0, sheetGap+cols*(cellW+sheetGap), sheetGap+nrows*(cellH+sheetGap)))
	toColor := func(c pxlib.RGBA) color.NRGBA { return color.NRGBA{c[0], c[1], c[2], c[3]} }
	b := img.Bounds()
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			img.SetNRGBA(x, y, toColor(back))
		}
	}
	for i, rows := range runeFrames {
		ox, oy := sheetGap+(i%cols)*(cellW+sheetGap), sheetGap+(i/cols)*(cellH+sheetGap)
		for y, row := range rows {
			for x, ch := range row {
				if ch == '.' || ch == ' ' {
					continue
				}
				c, ok := legend[string(ch)]
				if !ok {
					c = missingColor
				}
				img.SetNRGBA(ox+x, oy+y, toColor(c))
				for dy := 0; dy < zoom; dy++ {
					for dx := 0; dx < zoom; dx++ {
						img.SetNRGBA(ox+fw+sheetGap+x*zoom+dx, oy+y*zoom+dy, toColor(c))
					}
				}
			}
		}
	}
	f, err := os.Create(outPNG)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		return 0, err
	}
	return len(frames), nil
}
