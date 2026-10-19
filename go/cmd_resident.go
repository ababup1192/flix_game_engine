package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/resident"
)

const residentUsage = `使い方:
  resident manifest [dir]                        jar の中身の指紋（64 字）を出す
  resident run --entry X [--dir .] [--java J]    入口 X を常駐で流す（使えなければ 125）
  resident status [--dir .] [--all]              常駐の有無・pid・RSS・寿命の残り・served・busy
  resident stop [--dir .]                        常駐に /quit（居なければ何もせず 0）
  resident verify [--dir .] [--keep] [--touch-doc D] [--touch-png P] [--between "口 引数"] [--ignore 接頭辞]… -- <make の口と引数…>
                                                 根の写しで素の道と常駐を 5 回流して比べる（差 0 なら 0・差があれば 1）`

func init() {
	register("resident",
		"窓なしのゲームの常駐へ入口を頼む (docs/design/render-speed.md 2 節)。resident manifest [dir] / run --entry X [--dir .] / status [--dir .] [--all] / stop [--dir .] / verify [--dir .] [--keep] -- <make の口>",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			if len(rest) == 0 {
				fmt.Fprintln(errOut, residentUsage)
				return 2
			}
			verb, args := rest[0], rest[1:]
			if verb == "verify" {
				return residentVerify(out, errOut, args)
			}
			flags, positional := residentFlags(args)
			dir := flags["--dir"]
			if dir == "" {
				dir = "."
			}
			switch verb {
			case "manifest":
				if len(positional) > 0 {
					dir = positional[0]
				}
				sum, err := resident.BuildManifest(dir, os.Getenv("JAVA"), os.Getenv("HEADLESS_JAVA_OPTS"))
				if err != nil {
					fmt.Fprintf(errOut, "fge resident manifest: %v\n", err)
					return 2
				}
				fmt.Fprintln(out, sum)
				return 0
			case "run":
				if flags["--entry"] == "" {
					fmt.Fprintln(errOut, residentUsage)
					return 2
				}
				// WhyNot: out に貯めず os.Stdout へ直に写すのは、入口の出力を数分ぶん溜めてから
				// 吐くと、呼ぶ側が進み具合も止まった所も見られないため（heavy と同じ）。
				return resident.Run(repoRoot(), resident.RunOptions{
					Dir: dir, Entry: flags["--entry"], Java: flags["--java"],
					Env: resident.EnvMap(os.Environ()), Stdout: os.Stdout, Stderr: os.Stderr,
				})
			case "status":
				var b strings.Builder
				code := resident.Status(repoRoot(), dir, flags["--all"] != "", &b)
				out.WriteString(b.String())
				return code
			case "stop":
				var b strings.Builder
				code := resident.Stop(repoRoot(), dir, &b)
				errOut.WriteString(b.String())
				return code
			}
			fmt.Fprintln(errOut, residentUsage)
			return 2
		})
}

// residentFlags は --entry X / --dir X / --java X と値の無い --all を分ける。
func residentFlags(args []string) (map[string]string, []string) {
	flags := map[string]string{}
	var positional []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--all":
			flags[a] = "1"
		case a == "--entry" || a == "--dir" || a == "--java":
			if i+1 < len(args) {
				flags[a] = args[i+1]
				i++
			}
		case strings.HasPrefix(a, "--") && strings.Contains(a, "="):
			k, v, _ := strings.Cut(a, "=")
			flags[k] = v
		default:
			positional = append(positional, a)
		}
	}
	return flags, positional
}

// residentVerify は `resident verify [旗…] -- <make の口と引数…>` を読んで流す。
func residentVerify(out, errOut *strings.Builder, args []string) int {
	opts, err := parseVerifyArgs(args)
	if err != nil {
		fmt.Fprintf(errOut, "fge resident verify: %v\n%s\n", err, residentUsage)
		return 2
	}
	opts.Env = resident.EnvMap(os.Environ())
	// WhyNot: 進み具合を os.Stderr へ直に書くのは、5 回の make が数分かかり、終わるまで
	// 何も出ないと止まったのか分からないため。結果の表は out に貯めて最後に出す。
	opts.Progress = os.Stderr
	var b strings.Builder
	opts.Report = &b
	code := resident.Verify(repoRoot(), opts)
	out.WriteString(b.String())
	return code
}

// parseVerifyArgs は -- より前を旗、後ろを make の口と引数に分ける。
func parseVerifyArgs(args []string) (resident.VerifyOptions, error) {
	o := resident.VerifyOptions{Dir: "."}
	i := 0
	for ; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			o.MakeArgs = append([]string{}, args[i+1:]...)
			break
		}
		if a == "--keep" {
			o.Keep = true
			continue
		}
		if a == "--ignore" || strings.HasPrefix(a, "--ignore=") {
			v, ok := strings.CutPrefix(a, "--ignore=")
			if !ok {
				if i+1 >= len(args) {
					return o, fmt.Errorf("--ignore の値が無い")
				}
				i++
				v = args[i]
			}
			o.Ignore = append(o.Ignore, v)
			continue
		}
		k, v, hasEq := strings.Cut(a, "=")
		dest := map[string]*string{"--dir": &o.Dir, "--touch-doc": &o.TouchDoc, "--touch-png": &o.TouchPNG, "--between": &o.Between}[k]
		if dest == nil {
			return o, fmt.Errorf("知らない旗 %q（make の口は -- の後に書く）", a)
		}
		if !hasEq {
			if i+1 >= len(args) {
				return o, fmt.Errorf("%s の値が無い", k)
			}
			i++
			v = args[i]
		}
		*dest = v
	}
	if len(o.MakeArgs) == 0 {
		return o, fmt.Errorf("-- の後に make の口が無い")
	}
	return o, nil
}
