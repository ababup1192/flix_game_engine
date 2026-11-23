package syncagents

// 引数の読み。
//
// WhyNot: Go の flag へ寄せないのは、使い方を間違えたときに出る 3 行
// （usage 2 行 + `sync-agents.py: error: ...`）まで出力の一部だから。

import (
	"fmt"
	"regexp"
	"strings"
)

// usageText は使い方の 2 行（画面幅 80 で折り返した形）。
const usageText = "usage: sync-agents.py [-h] [--game GAME] [--version VERSION]\n" +
	"                      [--check-manifest]\n"

// helpText は -h / --help の全文。
//
// WhyNot: Go だけが持つ --root をここへ足さないのは、この字面がそのまま出力として
// 決まっているため。--root は突き合わせ用の口で、配る先の決まりではない。
const helpText = usageText + `
optional arguments:
  -h, --help         show this help message and exit
  --game GAME
  --version VERSION
  --check-manifest
`

// parsedArgs は読み取った引数。
type parsedArgs struct {
	game          string
	version       string
	checkManifest bool
	checkFollow   bool
}

type optionSpec struct {
	name       string
	takesValue bool
	// exactOnly は前を省いた書き方で当てない（後から足した物。--check が今までどおり --check-manifest に当たるように）。
	exactOnly bool
}

// optionSpecs は受け取る option。並びは前を省いた書き方を解く順でもある。
var optionSpecs = []optionSpec{
	{"--help", false, false},
	{"--game", true, false},
	{"--version", true, false},
	{"--check-manifest", false, false},
	// WhyNot: helpText に載せないのは --root と同じ理由（使い方の字面が出力として決まっている）。
	{"--check-follow-latest", false, true},
}

// negativeNumber は option ではなく「値」とみなす負の数の形。
var negativeNumber = regexp.MustCompile(`^-\d+$|^-\d*\.\d+$`)

// looksLikeValue は次の引数を値として食べてよいかを見る。
func looksLikeValue(s string) bool {
	if s == "" || !strings.HasPrefix(s, "-") {
		return true
	}
	if s == "-" || negativeNumber.MatchString(s) {
		return true
	}
	return strings.Contains(s, " ")
}

// matchOption は前を省いた書き方（--c → --check-manifest）を解く。
func matchOption(name string) (optionSpec, []string) {
	var hits []optionSpec
	var names []string
	for _, o := range optionSpecs {
		if o.name == name {
			return o, nil
		}
		if !o.exactOnly && strings.HasPrefix(o.name, name) {
			hits = append(hits, o)
			names = append(names, o.name)
		}
	}
	if len(hits) == 1 {
		return hits[0], nil
	}
	return optionSpec{}, names
}

// parseArgs は引数を読む。done が true なら呼ぶ側はその終了コードで止まる。
func parseArgs(out, errOut *strings.Builder, argv []string) (parsedArgs, int, bool) {
	res := parsedArgs{version: "unknown"}
	var extras []string
	fail := func(msg string) (parsedArgs, int, bool) {
		errOut.WriteString(usageText)
		fmt.Fprintf(errOut, "sync-agents.py: error: %s\n", msg)
		return res, 2, true
	}

	for i := 0; i < len(argv); i++ {
		a := argv[i]
		if a == "-h" {
			out.WriteString(helpText)
			return res, 0, true
		}
		if !strings.HasPrefix(a, "--") || a == "--" {
			extras = append(extras, a)
			continue
		}
		name, value, hasValue := a, "", false
		if k := strings.Index(a, "="); k >= 0 {
			name, value, hasValue = a[:k], a[k+1:], true
		}
		spec, ambiguous := matchOption(name)
		if spec.name == "" {
			if len(ambiguous) > 1 {
				return fail(fmt.Sprintf("ambiguous option: %s could match %s", name, strings.Join(ambiguous, ", ")))
			}
			extras = append(extras, a)
			continue
		}
		if !spec.takesValue {
			if hasValue {
				return fail(fmt.Sprintf("argument %s: ignored explicit argument %s", spec.name, pyReprString(value)))
			}
			switch spec.name {
			case "--help":
				out.WriteString(helpText)
				return res, 0, true
			case "--check-manifest":
				res.checkManifest = true
			case "--check-follow-latest":
				res.checkFollow = true
			}
			continue
		}
		if !hasValue {
			if i+1 >= len(argv) || !looksLikeValue(argv[i+1]) {
				return fail(fmt.Sprintf("argument %s: expected one argument", spec.name))
			}
			value = argv[i+1]
			i++
		}
		switch spec.name {
		case "--game":
			res.game = value
		case "--version":
			res.version = value
		}
	}
	if len(extras) > 0 {
		return fail("unrecognized arguments: " + strings.Join(extras, " "))
	}
	return res, 0, false
}
