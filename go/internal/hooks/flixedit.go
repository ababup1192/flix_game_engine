package hooks

// hook-flix-edit — 保存 1 回ぶんを常駐へ投げて型検査する（1 ファイルの手動確認用）。
//
// WhyNot: 保存のたびの引き金 (PostToolUse) に配線していないのは、サブエージェントを
// 並列に走らせると保存が秒間何度も届き、常駐 (JVM) が増殖して機械が重くなるため。
// 引き金は作業の区切り (hook-flix-work) にある。ここは 1 ファイル分のペイロードを
// 手で流し込んで常駐の返事を確かめる口として残す。

import (
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/explainerror"
	"github.com/ababup1192/flix_game_engine/go/internal/flixreserved"
	"github.com/ababup1192/flix_game_engine/go/internal/valuediscard"
)

// RunFlixEdit は 1 ファイル分のペイロードを読んで型検査する。返すのは 0 か 2 だけ。
func RunFlixEdit(errOut io.Writer, root string, in io.Reader) int {
	t0 := time.Now()
	payload, ok := ReadPayload(in)
	if !ok {
		return 0
	}
	r, err := LoadRules(root)
	if err != nil {
		fmt.Fprintf(errOut, "# hook-flix-edit: %v\n", err)
		return 2
	}
	rules, err := explainerror.LoadRules(root)
	if err != nil {
		fmt.Fprintf(errOut, "# hook-flix-edit: %v\n", err)
		return 2
	}
	path := payload.EditedPath()
	if !strings.HasSuffix(path, ".flix") {
		return 0
	}
	// WhyNot: 予約語だけは常駐を待たずにここで見る — 踏むと Flix はパースで止まらず
	// 型検査が終わらなくなるので、型検査に任せると「何も出ないまま返らない」になる。
	if code := reservedWords(errOut, root, path); code != 0 {
		return code
	}
	// WhyNot: let _ = も型検査を待たずに見る — 型検査は通り、知らせが実行時に黙って消えるだけなので、
	// 書いたその場で言わないと気づく場面が無い。
	if code := valueDiscards(errOut, root, path); code != 0 {
		return code
	}
	pkg := FindPkg(r, absolutize(payload, root, path))
	if pkg == "" {
		return 0
	}
	code, out, ok := checkPkg(r, root, pkg)
	if !ok || code <= 0 {
		// 常駐が温まっていない・緑・「素の CLI で確かめて」のどれか。
		// WhyNot: ここで CLI を回さないのは、保存のたびに数十秒待たせるため。
		return 0
	}
	block := explainerror.FirstErrorBlock(rules, out,
		*r.Checkd.ErrorBlockMaxLines, *r.Checkd.TailLinesWhenNoBlock)
	msg := fmt.Sprintf("# hook-flix-edit: %s で型検査 NG (先頭 1 件, %.1fs)\n%s",
		filepath.Base(pkg), time.Since(t0).Seconds(), block)
	if tip := explainerror.Prescribe(rules, block); tip != "" {
		msg += "\n" + fmt.Sprintf(rules.TipFormat, tip)
	}
	fmt.Fprintln(errOut, msg)
	return 2
}

// valueDiscards は保存したファイル 1 つに let _ = が無いかを見る。規約ファイルが無い (古い配布) なら黙る。
func valueDiscards(errOut io.Writer, root, path string) int {
	var body, problems strings.Builder
	if code, err := valuediscard.Run(&body, &problems, root, []string{path}); err != nil || code == 0 {
		return 0
	}
	fmt.Fprintf(errOut, "# hook-flix-edit: 値を let _ = で捨てています\n%s", problems.String())
	return 2
}

// reservedWords は保存したファイル 1 つに予約語が入っていないかを見る。
func reservedWords(errOut io.Writer, root, path string) int {
	var body, problems strings.Builder
	if code, err := flixreserved.Run(&body, &problems, root, []string{path}); err != nil || code == 0 {
		return 0
	}
	fmt.Fprintf(errOut, "# hook-flix-edit: 予約語を識別子に使っています\n%s", problems.String())
	return 2
}
