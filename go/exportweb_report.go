package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// suggestTitleDeferred は最後の確かめで記録したタイトルの間の素材から後回しの候補を出す（記録が無ければ nil）。
func suggestTitleDeferred(sizes *webSizeTable, b *webBundle, c exportConfig, used *webUsedAssets) *webDeferredSuggestion {
	if used == nil {
		return nil
	}
	hidden := map[string]bool{}
	for _, rel := range append(append([]string{}, c.EmbedPlan.Embedded...), c.EmbedPlan.Omitted...) {
		hidden[rel] = true
	}
	s := suggestWebDeferred(sizes, b, c.Project, c.DeferredFonts, hidden, *used, webTitleFrames)
	return &s
}

// webCandidateAdvice は後回しの候補を貼った時の次に打つ手（候補が無いか、減らない時は空）。
func webCandidateAdvice(s *webDeferredSuggestion) string {
	if s == nil || len(s.Candidates) == 0 || s.After >= s.Before {
		return ""
	}
	return fmt.Sprintf("後回しの候補 %d 本（タイトルの %d コマで使わなかった）→ 起動 約 -%.1f 秒（押した直後に使う物は外してから貼る・export-web --apply-deferred）",
		len(s.Candidates), webTitleFrames, s.Before-s.After)
}

// writeWebGateSummary は表の後ろへ門の 1 行と ★ を書く。予算を書いていないゲームが赤なら、移行の間は止めずに ★ で知らせる。
func writeWebGateSummary(w io.Writer, g webGate, v exportVerdict) {
	fmt.Fprintf(w, "  %s\n", g.line())
	for _, n := range g.Notes {
		fmt.Fprintf(w, "  %s\n", n)
	}
	switch v {
	case exportDraft:
		fmt.Fprintf(w, "  ★ 門が赤のまま --draft で書き出した（draft のマーカー付き・web-check が拒むので公開できない）: %s\n", strings.Join(g.Red, " / "))
	case exportMigrating:
		fmt.Fprintf(w, "  ★ %s。移行が終わる版から書き出しも止まる（docs/migrations/0.106.0.md）。公開の道（web-check）は今も止めるので、手で写す前に bin/fge web-check <書き出し先>\n", strings.Join(g.Red, " / "))
		writeWebGateAdvice(w, g.Advice, "")
	}
}

// writeTitleAssets は最後の確かめで記録したタイトルの間の素材から後回しの候補を書き、--apply-deferred なら project.json へ足す。
// s は suggestTitleDeferred の候補で、used が nil の時だけ nil。
func writeTitleAssets(out, errOut *strings.Builder, o exportWebOptions, p exportWebPaths, s *webDeferredSuggestion, used *webUsedAssets) int {
	if used == nil {
		if o.ApplyDeferred {
			fmt.Fprintln(errOut, "fge export-web: --apply-deferred: ブラウザの確かめで素材の記録が取れなかった（Chrome が無いか、engine の fge-web.js が記録を持たない）。project.json は変えていない")
			return 1
		}
		return 0
	}
	w := bufio.NewWriter(out)
	defer w.Flush()
	writeDeferredSuggestion(w, *s, o.Game)
	if raw, err := json.MarshalIndent(used, "", "  "); err == nil {
		record := filepath.Join(p.Work, "title-assets.json")
		if os.WriteFile(record, append(raw, '\n'), 0o644) == nil {
			fmt.Fprintf(w, "    記録の全部（名前・道 → 初めて使ったコマ）: %s\n", record)
		}
	}
	if !o.ApplyDeferred {
		return 0
	}
	file := filepath.Join(p.Game, "project.json")
	changed, err := applyDeferredToProject(file, s.Globs, s.Fonts)
	if err != nil {
		w.Flush()
		fmt.Fprintf(errOut, "fge export-web: --apply-deferred: %s を書き換えられない: %v\n", file, err)
		return 1
	}
	writeAppliedDeferred(w, file, changed, *s)
	return 0
}

// writeWebMissingTitleTo は ?net=4g のタイトルの間の記録を書き出しの表の後へ書く。
func writeWebMissingTitleTo(out *strings.Builder, r *webMissingReport) {
	w := bufio.NewWriter(out)
	writeWebMissingTitle(w, r, webTitleFrames)
	w.Flush()
}

// exportDocFiles は files のうち素材の行に数える物。アトラスと、絵の行で数える images の道を除く。
func exportDocFiles(b webBundle, isAtlas map[string]bool) []string {
	isImage := map[string]bool{}
	for _, f := range b.Images {
		isImage[f] = true
	}
	var docs []string
	for _, f := range b.Files {
		if !isAtlas[f] && !isImage[f] {
			docs = append(docs, f)
		}
	}
	return docs
}

// writeExportSizes は配る大きさの内訳を 1 行ずつ出す（変換した種類は「前 → 後」）と、変換の知らせ。
func writeExportSizes(out *strings.Builder, sizes *webSizeTable, b webBundle, atlases []string, r webTranscodeReport, strip webStripPlan) {
	isAtlas := map[string]bool{}
	for _, a := range atlases {
		isAtlas[a] = true
	}
	docFiles := exportDocFiles(b, isAtlas)
	var docs int64
	for _, f := range docFiles {
		docs += sizes.rawOf("assets/" + f)
	}
	page := sizes.rawOf("index.html") + sizes.rawOf("fge-web.js") + sizes.rawOf("wasm-gc-runtime.js") + sizes.rawOf("bundle.json")
	wasm := sizes.rawOf("classes.wasm")
	pair := func(p webSizePair) string {
		if p.Before == p.After {
			return humanBytes(p.After)
		}
		return fmt.Sprintf("%s → %s", humanBytes(p.Before), humanBytes(p.After))
	}
	rows := []struct {
		name, size, note string
	}{
		{"wasm", humanBytes(wasm), "classes.wasm"},
		{"素材", humanBytes(docs), fmt.Sprintf("Doc など %d 本", len(docFiles))},
		{"絵", pair(r.Images), fmt.Sprintf("%d 枚", len(b.Images))},
		{"アトラス", pair(r.Atlases), fmt.Sprintf("%d 本", len(atlases))},
		{"音", pair(r.Sounds), fmt.Sprintf("%d 本", len(b.Sounds))},
		{"頁", humanBytes(page), "index.html・js・bundle.json"},
	}
	w := bufio.NewWriter(out)
	for _, row := range rows {
		fmt.Fprintf(w, "  %-8s %22s  %s\n", row.name, row.size, row.note)
	}
	total := webSizePair{
		Before: wasm + docs + page + r.Images.Before + r.Atlases.Before + r.Sounds.Before,
		After:  wasm + docs + page + r.Images.After + r.Atlases.After + r.Sounds.After,
	}
	fmt.Fprintf(w, "  %-8s %22s  ブラウザが取る量\n", "合計", pair(total))
	if n := len(strip.Stripped); n > 0 {
		fmt.Fprintf(w, "  %-8s %22s  schema・制作の元ファイル %d 本（動く時に読まない。戻すなら web.keep）\n", "外した", humanBytes(strip.StrippedBytes), n)
	}
	for _, line := range r.AutoLossyLines {
		fmt.Fprintf(w, "  %s\n", line)
	}
	start := webStartupSizeOf(sizes, &b)
	var waitFor []string
	logoMax := webAfterTapMaxSeconds
	if t := b.Splash; t != nil && t.AfterTap != nil && t.AfterTap.Mode != "none" {
		waitFor, logoMax = t.AfterTap.WaitFor, t.AfterTap.MaxSeconds
	}
	writeStartupEstimate(w, webStartupEstimateOf(sizes, &b), start)
	writeTapWaitEstimate(w, webTapWaitOf(sizes, &b, waitFor), logoMax)
	if r.FallbackBytes > 0 {
		fmt.Fprintf(w, "  置き場には元の wav（%s）も残す — Opus を解けないブラウザだけが取る\n", humanBytes(r.FallbackBytes))
	}
	for _, n := range r.Notes {
		fmt.Fprintf(w, "  知らせ: %s\n", n)
	}
	if n := len(strip.Noticed); n > 0 {
		fmt.Fprintf(w, "  知らせ: .md・.txt %d 本（%s）を束に入れた — ゲームが読まないなら web.omit へ\n", n, humanBytes(strip.NoticedBytes))
	}
	// WhyNot: 運ばない物を言わずに終えない — assets/ の外の Doc や readBytes で読む素材は束に入らず、ブラウザで初めて「無い」になる。
	fmt.Fprintln(w, "  束に入れたのは project.json と assets/ の下だけ（assets/ の外を読むゲームはブラウザで読めない）")
	w.Flush()
}

// writeStartupEstimate は起動まで（遊べるまで）の回線の量と 1.6 Mbps での秒数、後回しの最後が届く時刻を書く（予算と比べて止めるのは門・webGateOf）。
func writeStartupEstimate(w io.Writer, s webStartupEstimate, start webStartupSize) {
	wire := s.Boot.WasmWire + s.Boot.AssetsWire + s.PageWire
	fmt.Fprintf(w, "  起動まで（タッチして開始まで）%d 本・回線 %s（wasm %s・素材 %s・頁 %s）→ 4G（1.6 Mbps）で約 %.1f 秒（前置き %.1f 秒を含む）\n",
		start.StartCount, humanBytes(wire), humanBytes(s.Boot.WasmWire), humanBytes(s.Boot.AssetsWire), humanBytes(s.PageWire),
		s.Seconds, webStartupPreludeSeconds)
	if n := len(s.Deferred); n > 0 {
		fmt.Fprintf(w, "  後回し %d 本・%s → 最後の %s が届くのは約 %.0f 秒目（1 本ずつの時刻は書き出しのログ）\n",
			start.DeferredCount, humanBytes(start.DeferredBytes), s.Deferred[n-1].Path, s.Deferred[n-1].Seconds)
		for _, a := range s.Deferred {
			ewLogf("  後回し %6.1f 秒目  %s", a.Seconds, a.Path)
		}
	}
}

// writeTapWaitEstimate は「開いてすぐ押した時に、押してから最初の場面が動くまで」の 4G の見積もりを書く（人の要件の 2 本目の数字）。
// logoMax は押した後のロゴの上限の秒（ゲームの web.splash.maxSeconds）。
func writeTapWaitEstimate(w io.Writer, t webTapWait, logoMax float64) {
	switch {
	case t.Count == 0 && len(t.Group) > 0:
		fmt.Fprintf(w, "  押してから動くまで（開いてすぐ押した時・4G）: 0 秒（group %s に後回しの物が無い）\n", strings.Join(t.Group, "・"))
	case t.Count == 0:
		fmt.Fprintln(w, "  押してから動くまで（開いてすぐ押した時・4G）: 0 秒（届く前に使うと engine が待つ後回しの物が無い）")
	case len(t.Group) > 0:
		fmt.Fprintf(w, "  押してから動くまで（開いてすぐ押した時・4G）: 約 %.1f 秒（押した後のロゴが待つ group %s の %d 本がそろうまで）\n",
			t.Seconds, strings.Join(t.Group, "・"), t.Count)
	default:
		fmt.Fprintf(w, "  押してから動くまで（開いてすぐ押した時・4G）: 約 %.1f〜%.1f 秒（最初に届く待つ物 %s から、待つ物 %d 本の最後まで。最初の場面が使う物で決まる）\n",
			t.Seconds, t.Until, t.FirstPath, t.Count)
	}
	if t.Count > 0 && t.Seconds > logoMax {
		fmt.Fprintf(w, "  知らせ: 押してから動くまでが 4G で押した後のロゴの上限 %.1f 秒を超える — すぐ要る物を web.deferred の頭へ並べ替えるか、後回しから外す（ロゴと待ちの合計が後回しにしない時の起動の秒を超えるなら後回しにしない）\n",
			logoMax)
	}
}

// writeWebGateAdvice は次に打つ手を 3 つまでと、予算の書き方・--draft を書く。
func writeWebGateAdvice(w io.Writer, advice []string, more string) {
	fmt.Fprintln(w, "  次に打つ手（4G の秒が減る順）")
	for i, a := range advice {
		if i == 3 {
			break
		}
		fmt.Fprintf(w, "    %d. %s\n", i+1, a)
	}
	if more != "" {
		fmt.Fprintf(w, "    ・%s\n", more)
	}
	fmt.Fprintf(w, "  どうしても超えるなら project.json の web.startupBudget に { \"seconds\": <秒>, \"why\": \"<理由>\" }（%.0f 秒を超えると毎回 ★・why は公開される）\n", webStartupTargetSeconds)
}
