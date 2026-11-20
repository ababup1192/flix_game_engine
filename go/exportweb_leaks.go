package main

import (
	"archive/zip"
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// flixSourcePathRe は絶対パスで始まり、`/project/src/`・`/project/test/`（`\` の形も）の後に続いて `.flix` で終わる 1 つの位置。
// WhyNot: `<Work>/project/` の前方一致で探さない — `--work` を渡された時・/var と /private/var・symlink・
// Windows のドライブ文字と大文字小文字・NFC と NFD の名前で、渡した字と Flix が残した字が食い違う。
var flixSourcePathRe = regexp.MustCompile(`^(?:[A-Za-z]:[\\/]|[\\/]).*[\\/]project[\\/]((?:src|test)[\\/].+\.flix)$`)

// relativizeFlixSourcePaths は s の中の各位置（`>` でつながる形も）を `game/...` に置き換える。替えた数も返す。
func relativizeFlixSourcePaths(s []byte) ([]byte, int) {
	if !bytes.Contains(s, []byte(".flix")) {
		return s, 0
	}
	segs := bytes.Split(s, []byte(">"))
	n := 0
	for i, seg := range segs {
		m := flixSourcePathRe.FindSubmatch(seg)
		if m == nil {
			continue
		}
		segs[i] = append([]byte("game/"), bytes.ReplaceAll(m[1], []byte(`\`), []byte("/"))...)
		n++
	}
	if n == 0 {
		return s, 0
	}
	return bytes.Join(segs, []byte(">")), n
}

// webLeakGenericRes は名前を決めずに探すホームのパスの形（別の機械で見ても当たる）。
// WhyNot: 素のユーザー名で探さない — `github:<名前>...` のような公開してよい字に部分一致する。
var webLeakGenericRes = []*regexp.Regexp{
	regexp.MustCompile(`(?i)/Users/[^/\x00-\x1f]+/`),
	regexp.MustCompile(`(?i)/home/[^/\x00-\x1f]+/`),
	regexp.MustCompile(`(?i)[A-Za-z]:\\Users\\[^\\\x00-\x1f]+\\`),
	regexp.MustCompile(`(?i)[A-Za-z]:/Users/[^/\x00-\x1f]+/`),
}

// webLeakFinder はパスの形を探す物。local は手元で分かる道（$HOME・作業フォルダ・ゲームの絶対パス）の字。
type webLeakFinder struct {
	local [][]byte
}

// webLeakLocalMin より短い手元の道は探さない（`/` や `/tmp` だけだと公開してよい字に当たる）。
const webLeakLocalMin = 6

// newWebLeakFinder は dirs（$HOME・作業フォルダ・ゲームの根など）を、realpath にした物としない物、`/` と `\` の両方で持つ。
func newWebLeakFinder(dirs ...string) webLeakFinder {
	seen := map[string]bool{}
	var f webLeakFinder
	add := func(s string) {
		s = strings.TrimRight(s, `/\`)
		if len(s) < webLeakLocalMin || seen[s] {
			return
		}
		seen[s] = true
		f.local = append(f.local, []byte(s))
	}
	for _, d := range dirs {
		if d == "" {
			continue
		}
		forms := []string{d}
		if abs, err := filepath.Abs(d); err == nil {
			forms = append(forms, abs)
		}
		if real, err := filepath.EvalSymlinks(d); err == nil {
			forms = append(forms, real)
		}
		for _, s := range forms {
			slash := strings.ReplaceAll(s, `\`, "/")
			add(slash)
			add(strings.ReplaceAll(slash, "/", `\`))
		}
	}
	sort.Slice(f.local, func(i, j int) bool { return len(f.local[i]) > len(f.local[j]) })
	return f
}

// find は data の中のパスの形の位置と字を返す（重なる物は 1 つに数える）。
func (f webLeakFinder) find(data []byte) []string {
	type hit struct{ at, end int }
	var hits []hit
	for _, re := range webLeakGenericRes {
		for _, m := range re.FindAllIndex(data, -1) {
			hits = append(hits, hit{m[0], m[1]})
		}
	}
	for _, l := range f.local {
		for at := 0; ; {
			i := bytes.Index(data[at:], l)
			if i < 0 {
				break
			}
			hits = append(hits, hit{at + i, at + i + len(l)})
			at += i + len(l)
		}
	}
	sort.Slice(hits, func(i, j int) bool { return hits[i].at < hits[j].at })
	var out []string
	end := -1
	for _, h := range hits {
		if h.at < end {
			continue
		}
		out = append(out, string(data[h.at:leakContextEnd(data, h.end)]))
		end = h.end
	}
	return out
}

// webSourcePathResult は jar の置き換えの結果。Leaks は置き換えた後の定数プールにまだ残る字（画面には数だけ出す）。
type webSourcePathResult struct {
	Replaced int
	Leaks    []string
}

// rewriteJarSourcePaths は src の全クラスの定数プールの位置を置き換えて dst へ書き、置き換えた後の定数プールを f で探す。
// WhyNot: 替えないクラスと、クラスでない物を圧し直さない — fatjar の大半は engine と依存の類で、全部を圧し直すと書き出しが秒単位で延びる。
func rewriteJarSourcePaths(src, dst string, f webLeakFinder) (webSourcePathResult, error) {
	var res webSourcePathResult
	zr, err := zip.OpenReader(src)
	if err != nil {
		return res, err
	}
	defer zr.Close()
	out, err := os.Create(dst)
	if err != nil {
		return res, err
	}
	zw := zip.NewWriter(out)
	fail := func(e error) (webSourcePathResult, error) {
		zw.Close()
		out.Close()
		os.Remove(dst)
		return res, e
	}
	for _, zf := range zr.File {
		if !strings.HasSuffix(zf.Name, ".class") {
			if err := zw.Copy(zf); err != nil {
				return fail(err)
			}
			continue
		}
		rc, err := zf.Open()
		if err != nil {
			return fail(err)
		}
		data, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			return fail(err)
		}
		rewritten, n, leaks, err := rewriteClassSourcePaths(data, f)
		if err != nil {
			return fail(fmt.Errorf("%s: %v", zf.Name, err))
		}
		res.Replaced += n
		res.Leaks = append(res.Leaks, leaks...)
		if n == 0 {
			if err := zw.Copy(zf); err != nil {
				return fail(err)
			}
			continue
		}
		w, err := zw.CreateHeader(&zip.FileHeader{Name: zf.Name, Method: zip.Deflate, Modified: zf.Modified})
		if err != nil {
			return fail(err)
		}
		if _, err := w.Write(rewritten); err != nil {
			return fail(err)
		}
	}
	if err := zw.Close(); err != nil {
		out.Close()
		os.Remove(dst)
		return res, err
	}
	return res, out.Close()
}

// rewriteClassSourcePaths は 1 クラスの定数プールの Utf8 を置き換え、置き換えた後の Utf8 に残るパスの形を返す。
// WhyNot: 定数プールの Utf8 を全部見る（String の参照先だけに絞らない）— SourceFile などの属性も同じ Utf8 を指し、
// 長さが変わっても定数プールは番号で引かれるので、ほかの所を直さずに済む。
func rewriteClassSourcePaths(data []byte, f webLeakFinder) ([]byte, int, []string, error) {
	if len(data) < 10 || binary.BigEndian.Uint32(data) != 0xCAFEBABE {
		return nil, 0, nil, fmt.Errorf("クラスの頭でない")
	}
	count := int(binary.BigEndian.Uint16(data[8:10]))
	var out bytes.Buffer
	out.Write(data[:10])
	at := 10
	replaced := 0
	var leaks []string
	for i := 1; i < count; i++ {
		if at >= len(data) {
			return nil, 0, nil, fmt.Errorf("定数プールが切れている")
		}
		tag := data[at]
		size := 0
		switch tag {
		case 1:
			if at+3 > len(data) {
				return nil, 0, nil, fmt.Errorf("定数プールが切れている")
			}
			n := int(binary.BigEndian.Uint16(data[at+1 : at+3]))
			if at+3+n > len(data) {
				return nil, 0, nil, fmt.Errorf("定数プールが切れている")
			}
			s := data[at+3 : at+3+n]
			r, k := relativizeFlixSourcePaths(append([]byte{}, s...))
			replaced += k
			leaks = append(leaks, f.find(r)...)
			out.WriteByte(1)
			var l [2]byte
			binary.BigEndian.PutUint16(l[:], uint16(len(r)))
			out.Write(l[:])
			out.Write(r)
			at += 3 + n
			continue
		case 7, 8, 16, 19, 20:
			size = 3
		case 15:
			size = 4
		case 3, 4, 9, 10, 11, 12, 17, 18:
			size = 5
		case 5, 6:
			size = 9
		default:
			return nil, 0, nil, fmt.Errorf("知らない定数の種類 %d", tag)
		}
		if at+size > len(data) {
			return nil, 0, nil, fmt.Errorf("定数プールが切れている")
		}
		out.Write(data[at : at+size])
		at += size
		if tag == 5 || tag == 6 {
			i++
		}
	}
	out.Write(data[at:])
	return out.Bytes(), replaced, leaks, nil
}

// webWasmLeaks は書き出した wasm の中身（名前の区画を抜いた物）と名前の区画のそれぞれに残るパスの形。
type webWasmLeaks struct {
	Wasm, Names []string
}

func (l webWasmLeaks) total() int { return len(l.Wasm) + len(l.Names) }

// findWasmLeaks は TeaVM が出した wasm を、配る形（名前の区画を抜いた classes.wasm と classes.names）に分けて探す。
func findWasmLeaks(wasm []byte, f webLeakFinder) (webWasmLeaks, error) {
	stripped, names, err := splitWasmNames(wasm)
	if err != nil {
		return webWasmLeaks{}, err
	}
	return webWasmLeaks{Wasm: f.find(stripped), Names: f.find(names)}, nil
}

// leakContextMax は当たりの後ろへ字を足す上限（--show-leaks の表示と、.flix の位置かどうかの見分けに使う）。
const leakContextMax = 200

// leakContextEnd は at から制御のバイトの手前まで（leakContextMax まで）の終わり。
// WhyNot: 当たりだけを返さない — `/Users/<名前>/` だけでは .flix の位置の漏れか、ゲームの字に書いた絶対パスかを見分けられない。
func leakContextEnd(data []byte, at int) int {
	end := at
	for end < len(data) && end-at < leakContextMax && data[end] >= 0x20 {
		end++
	}
	return end
}

// webLeakReport は止める時の行と「次:」の行。見つかった字は show の時だけ足す。
// WhyNot: 字を既定で出さない — 書き出しのログは CI や人に貼る report に残り、ホームの名前がそこから広がる。
// afterJar は jar の段を通った後（wasm の段）か。
// WhyNot: wasm の段では .flix を含むかで「次:」を分けない — 文字列が長さのバイトだけで隣り合い、足した字が隣の engine の位置をまたぐ。
// ゲームの字の絶対パスは jar の段で止まるので、jar を通った後の漏れは書き出しの道具の側の物。
func webLeakReport(where map[string][]string, show, afterJar bool) string {
	var b strings.Builder
	keys := []string{"jar", "wasm", "names"}
	var parts []string
	source := afterJar
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s %d", k, len(where[k])))
		for _, s := range where[k] {
			source = source || strings.Contains(s, ".flix")
		}
	}
	fmt.Fprintf(&b, "作業フォルダかホームのパスが残った（%s 件）。書き出し先には何も置いていない。\n  次: ", strings.Join(parts, "・"))
	if source {
		b.WriteString(".flix の位置の置き換え（exportweb_leaks.go の flixSourcePathRe）の漏れなので engine に報告する。")
	} else {
		b.WriteString("ゲームのコードか素材の字に絶対パスが書いてある。ゲームの根からの相対の道に直す。")
	}
	b.WriteString("字は --show-leaks で手元の画面に出る")
	if show {
		for _, k := range keys {
			for _, s := range where[k] {
				fmt.Fprintf(&b, "\n    %s: %q", k, s)
			}
		}
	}
	return b.String()
}
