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
  bin/fge migrate diff <baseline> <new> [--accept FILE] [--game DIR] [--out DIR] [--no-coverage] [--strict] [--times] [--json]
      前の版と新しい版の記録（flows/<flow>/<大きさ>/tape.json と書き出したコマ・saves/<名前>/restore.json）を突き合わせる。
      --accept 既定 <new の親>/migrate-accept.json・--game 既定 <new> から上へ辿った project.json のあるフォルダ・
      --out 既定 <new の親>/report（index.html と report.json と heat/）。
      台詞・選択肢・問いの値・音の順の違いと通らない命令の行は門を止める。絵・矩形・音の時刻・音量の違いは
      「迷った差」として一覧に溜め、止めない（--strict なら止める）。
      --times は台詞・選択肢・待ちの時刻を、前の出来事からの間で比べる（1 フレームを超えたら迷った差）。
      終わりの番号: 0 通った・1 止める違いがある・2 引数か記録が読めない。
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
	r := Compare(base, cur, acc, Options{Out: a.out, Game: a.game, NoCoverage: a.noCoverage, Strict: a.strict, Times: a.times, Th: DefaultThresholds(), Lim: DefaultLimits()})
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
