package migrate

import (
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/yarn"
)

const usage = `使い方:
  bin/fge migrate diff <baseline> <new> [--accept FILE] [--game DIR] [--out DIR] [--no-coverage] [--strict] [--times] [--no-auto] [--no-keys] [--json]
      前の版と新しい版の記録（flows/<flow>/<大きさ>/tape.json と書き出したコマ・saves/<名前>/restore.json）を突き合わせる。
      --accept 既定 <new の親>/migrate-accept.json・--game 既定 <new> から上へ辿った project.json のあるフォルダ・
      --out 既定 <new の親>/report（index.html と report.json と heat/）。
      台詞・選択肢・問いの値・音の順の違いと通らない命令の行は門を止める。絵・矩形・音の時刻・音量の違いは
      「迷った差」として一覧に溜め、止めない（--strict なら止める）。
      --times は台詞・選択肢・待ちの時刻を、前の出来事からの間で比べる（1 フレーム + 丸めの幅を超えたら迷った差）。
      音・画面の物の区間・バスの音量も、直前に組になった出来事のずれを引いて比べる。
      迷った差のうち線引きで自動で通した物（合わせ直し・時刻のずれたコマのブロックの比べ）は --strict でも止めない。
      --no-auto はそれも人が見る物に数える。線引きの上書きは migrate-accept.json の thresholds。
      コマは前と後の鍵（frames/<層>/drawhash.txt）が同じなら画素を読まずに同じと見る。比べた結果は <new の親>/diff-cache.json に
      覚え、同じ中身と線引きの組は読み直さない。--no-keys はどちらも使わず全部の画素を比べる。
      基準と新しい撮りの描き手（logs/shoot.json の painter）が違えば画素を比べず、撮り直し方を 1 行出して終わりの番号 2。
      終わりの番号: 0 通った・1 止める違いがある・2 引数か記録が読めない。
  bin/fge migrate shoot <名前> <flow>... [--jobs N] [--video] [--run CMD] [--saves-from DIR] [--no-saves] [--overwrite] [--full] [--no-resident] [--paint gpu|cpu]
      ゲームの根で flow を並べて流し、記録を debug/migrate/<名前> に撮る（FlowVideo.play を MIGRATE_OUT 付きで流し、
      続けて --saves-from（既定 debug/migrate/baseline）の flows/*/saves.json を FlowVideo.restore で読み戻す）。
      --jobs の既定はコア数から（1 本のヒープは -Xmx3g）。--video で flow ごとの video.mp4 も束ねる（既定は束ねない）。
      基準（--saves-from）がある時は、比べのコマを鍵だけ先に撮り、基準と鍵の違うコマだけに PNG を用意する
      （基準か render-cache の同じ鍵から写し、無ければ同じ鍵を 1 か所だけで塗って写す）。--full は全部のコマを塗る（基準を撮る回）。
      flow は本数ぶんの常駐の JVM（E2e.serveHeadless）へ配る。--no-resident は 1 本ごとに JVM を起こす。
      --run の既定は環境変数 HEADLESS_RUN か engine の bin/headless-run。JVM ごとのログと秒は <記録>/logs/。
      --paint は比べのコマの PNG を塗る描き手。基準が無い（--overwrite も）時の既定は gpu（画面なしの WebGPU。開けなければ CPU で塗って知らせる）、
      基準がある時の既定は基準と同じ描き手。基準と違う描き手を頼むと撮らずに止める（描き手の違いは画素の差になる）。描き手は logs/shoot.json の painter。
  bin/fge migrate fill <記録>
      鍵だけ撮った記録の欠けた PNG を、同じ親フォルダのほかの記録と render-cache の同じ鍵から埋める（新しい記録を基準に上げる前に流す。
      基準は全部の PNG を持つ約束）。埋められないコマが残れば終わりの番号 1（migrate shoot --full で撮り直す）。
  bin/fge migrate video --old OLD.mp4 --new NEW.mp4 --out OUT.mp4 [--tape NEW/tape.json]
      2 本を左右に並べた mp4 を書く（前の音を左・新しい音を右のチャンネル。--tape があれば台詞のノードと番号の字幕を絵に重ねる）。
記録の形は docs/migrate-diff.md。`

// Run は bin/fge migrate の本体。
func Run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	switch args[0] {
	case "diff":
		return runDiff(args[1:], stdout, stderr)
	case "video":
		return runVideo(args[1:], stdout, stderr)
	case "shoot":
		return runShoot(args[1:], stdout, stderr)
	case "fill":
		return runFill(args[1:], stdout, stderr)
	case "-h", "--help", "help":
		fmt.Fprintln(stdout, usage)
		return 0
	}
	fmt.Fprintf(stderr, "migrate: 知らないサブコマンド %q\n%s\n", args[0], usage)
	return 2
}

type diffArgs struct {
	base, cur, accept, game, out      string
	noCoverage, strict, times, asJSON bool
	noAuto, noKeys                    bool
}

func parseDiffArgs(args []string) (diffArgs, error) {
	var a diffArgs
	var pos []string
	for i := 0; i < len(args); i++ {
		v := args[i]
		value := func() (string, error) {
			if i+1 >= len(args) {
				return "", fmt.Errorf("%s の後に値が要る", v)
			}
			i++
			return args[i], nil
		}
		var err error
		switch v {
		case "--accept":
			a.accept, err = value()
		case "--game":
			a.game, err = value()
		case "--out":
			a.out, err = value()
		case "--no-coverage":
			a.noCoverage = true
		case "--strict":
			a.strict = true
		case "--times":
			a.times = true
		case "--no-auto":
			a.noAuto = true
		case "--no-keys":
			a.noKeys = true
		case "--json":
			a.asJSON = true
		default:
			if strings.HasPrefix(v, "-") {
				return a, fmt.Errorf("知らない引数: %s", v)
			}
			pos = append(pos, v)
		}
		if err != nil {
			return a, err
		}
	}
	if len(pos) != 2 {
		return a, fmt.Errorf("baseline と new の 2 つのフォルダが要る")
	}
	a.base, a.cur = pos[0], pos[1]
	parent := filepath.Dir(filepath.Clean(a.cur))
	if a.accept == "" {
		a.accept = filepath.Join(parent, AcceptFile)
	}
	if a.out == "" {
		a.out = filepath.Join(parent, "report")
	}
	if a.game == "" {
		a.game = yarn.FindGameRoot(a.cur)
	}
	return a, nil
}

func runDiff(args []string, stdout, stderr io.Writer) int {
	a, err := parseDiffArgs(args)
	if err != nil {
		fmt.Fprintf(stderr, "migrate diff: %v\n%s\n", err, usage)
		return 2
	}
	if why := painterMismatch(recordPainter(a.base), recordPainter(a.cur)); why != "" {
		fmt.Fprintln(stderr, "migrate diff:", why)
		return 2
	}
	base, err := LoadSide(a.base)
	if err != nil {
		fmt.Fprintln(stderr, "migrate diff:", err)
		return 2
	}
	cur, err := LoadSide(a.cur)
	if err != nil {
		fmt.Fprintln(stderr, "migrate diff:", err)
		return 2
	}
	acc, err := LoadAccept(a.accept)
	if err != nil {
		fmt.Fprintln(stderr, "migrate diff:", err)
		return 2
	}
	r := Compare(base, cur, acc, Options{Out: a.out, Game: a.game, NoCoverage: a.noCoverage, Strict: a.strict, Times: a.times, NoAuto: a.noAuto, NoKeys: a.noKeys,
		CachePath: filepath.Join(filepath.Dir(filepath.Clean(a.cur)), DiffCacheFile), Th: DefaultThresholds(), Lim: DefaultLimits()})
	page, err := WriteReport(r, a.out)
	if err != nil {
		fmt.Fprintln(stderr, "migrate diff: 頁を書けない:", err)
		return 2
	}
	if a.asJSON {
		data, _ := json.Marshal(r)
		fmt.Fprintln(stdout, string(data))
	} else {
		fmt.Fprint(stdout, Text(r, page))
	}
	if r.Passed {
		return 0
	}
	return 1
}
