package resident

// `fge resident verify` の部品のうち、走らせずに決まる物（写すかの判定・書いたファイルの表の差・
// 標準出力の比べ方・Doc と PNG の書き換え・挟む入口の選び方）。

import (
	"bytes"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"regexp"
	"sort"
	"strings"
)

// OutputDirs は「書いたファイル」を探すフォルダ（ゲームの根からの相対）。
var OutputDirs = []string{"gallery", "debug"}

// isIgnoredOutput は書いたファイルの表に入れない物か（rel は / 区切り）。
func isIgnoredOutput(rel string) bool {
	return rel == "debug/headless" || strings.HasPrefix(rel, "debug/headless/")
}

// keptBuildFiles は build/ の下で写す物。jar を作り直させないための 3 つ（headless-run は
// jar・指紋・入口を並べた main の写しの 3 つがそろって初めて「古くない」と読む）。
var keptBuildFiles = map[string]bool{
	"build/headless/headless.jar":                  true,
	"build/headless/jar.manifest":                  true,
	"build/headless/proj/src/FgeHeadlessMain.flix": true,
}

// ShouldCopy はゲームの根からの相対パス rel（/ 区切り）を一時の写しへ写すか。isDir はフォルダか。
//
// WhyNot: debug/ と gallery/ を写さないのは、前の生成物が残ると「流した回が書いた」と
// 「元からあった」を分けられないため。build/ を丸ごと写さないのは、常駐の名乗り
// （resident.json）や鍵まで写って、写しの常駐が元の根の常駐を指すため。
func ShouldCopy(rel string, isDir bool) bool {
	top, _, _ := strings.Cut(rel, "/")
	switch top {
	case ".git", "debug", "gallery":
		return false
	case "build":
		if !isDir {
			return keptBuildFiles[rel]
		}
		for k := range keptBuildFiles {
			if strings.HasPrefix(k, rel+"/") {
				return true
			}
		}
		return false
	}
	return true
}

// FileTable は書いたファイルの相対パス（/ 区切り）→ SHA-256（16 進）。
type FileTable map[string]string

// Written は before に無かったか、中身が変わった物だけを返す。
func Written(before, after FileTable) FileTable {
	out := FileTable{}
	for rel, sum := range after {
		if before[rel] != sum {
			out[rel] = sum
		}
	}
	return out
}

// WithoutPrefixes は prefixes（/ 区切りの接頭辞）のどれかで始まる物を除いた表を返す。
func WithoutPrefixes(t FileTable, prefixes []string) FileTable {
	out := FileTable{}
	for rel, sum := range t {
		skip := false
		for _, p := range prefixes {
			if p != "" && strings.HasPrefix(rel, p) {
				skip = true
				break
			}
		}
		if !skip {
			out[rel] = sum
		}
	}
	return out
}

// DiffTables は a と b で違うファイル（片方にしか無い物を含む）を字の順に返す。
func DiffTables(a, b FileTable) []string {
	seen := map[string]bool{}
	var out []string
	for rel, sum := range a {
		seen[rel] = true
		if b[rel] != sum {
			out = append(out, rel)
		}
	}
	for rel := range b {
		if !seen[rel] {
			out = append(out, rel)
		}
	}
	sort.Strings(out)
	return out
}

// SortedPaths は表のパスを字の順に返す。
func (t FileTable) SortedPaths() []string {
	out := make([]string, 0, len(t))
	for rel := range t {
		out = append(out, rel)
	}
	sort.Strings(out)
	return out
}

// StdoutRule は標準出力を比べる前に、毎回変わる字を決まった字へ置き換える 1 つの規則。
type StdoutRule struct {
	Name string
	re   *regexp.Regexp
	repl string
	Note string
}

// Pattern は規則の正規表現の字。
func (r StdoutRule) Pattern() string { return r.re.String() }

// Replacement は置き換え先の字。
func (r StdoutRule) Replacement() string { return r.repl }

func rule(name, pattern, repl, note string) StdoutRule {
	return StdoutRule{Name: name, re: regexp.MustCompile(pattern), repl: repl, Note: note}
}

// StdoutRules は上から順に当てる。写しの根の置き換えは NormalizeStdout が先に済ませる。
//
// WhyNot: 数字を全部消さないのは、描いた枚数・場面の名前・items の数のように、
// 違えば絵が違う証になる数字まで見えなくなるため。消すのは単位か前置きで「毎回変わる」と分かる物だけ。
var StdoutRules = []StdoutRule{
	rule("ansi", `\x1b\[[0-9;]*[A-Za-z]`, "", "色の字"),
	rule("make-dir", `(?m)^make(\[\d+\])?: (Entering|Leaving) directory .*$`, "make: <dir>", "make の出入り"),
	rule("datetime", `\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?`, "<datetime>", "日時"),
	rule("clock", `\b\d{1,2}:\d{2}:\d{2}(\.\d+)?\b`, "<clock>", "時刻"),
	rule("duration", `\b\d+(\.\d+)?\s?(ns|µs|us|ms|s|sec|secs|m|min|h)\b|\d+(\.\d+)?\s?(秒|分|ミリ秒)`, "<dur>", "秒数・経過時間"),
	rule("size", `\b\d+(\.\d+)?\s?(B|KB|KiB|MB|MiB|GB|GiB)\b`, "<size>", "メモリ・ファイルの大きさ"),
	rule("pid", `\bpid[ =:]?\s*\d+`, "pid <n>", "プロセス番号"),
	rule("port", `\bport[ =:]?\s*\d+|127\.0\.0\.1:\d+|localhost:\d+`, "port <n>", "port"),
	rule("shot-serial", `\bshot-\d+`, "shot-<n>", "1 枚撮りの通し番号（pid 由来）"),
	rule("tmp", `(/private)?/(var/folders|tmp)/[^\s"']*`, "<tmp>", "写し以外の一時の場所"),
}

// NormalizeStdout は roots（写しの根。symlink を辿る前と後の両方を渡す）を <root> にし、
// StdoutRules を順に当てる。行の終わりの空白も落とす。
func NormalizeStdout(s string, roots ...string) string {
	sort.Slice(roots, func(i, j int) bool { return len(roots[i]) > len(roots[j]) })
	for _, r := range roots {
		if r != "" {
			s = strings.ReplaceAll(s, r, "<root>")
		}
	}
	for _, r := range StdoutRules {
		s = r.re.ReplaceAllString(s, r.repl)
	}
	lines := strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
	for i, l := range lines {
		lines[i] = strings.TrimRight(l, " \t")
	}
	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}

// FirstLineDiff は 2 つの字の最初に違う行（1 始まり）と両方の行。同じなら 0。
func FirstLineDiff(a, b string) (int, string, string) {
	la, lb := strings.Split(a, "\n"), strings.Split(b, "\n")
	for i := 0; i < len(la) || i < len(lb); i++ {
		var x, y string
		if i < len(la) {
			x = la[i]
		}
		if i < len(lb) {
			y = lb[i]
		}
		if i >= len(la) || i >= len(lb) || x != y {
			return i + 1, x, y
		}
	}
	return 0, "", ""
}

var hexColor = regexp.MustCompile(`"#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?"`)

// TouchJSON は Doc の中身を変え、何をしたかの 1 行と一緒に返す。
// "#rrggbb"（"#rrggbbaa"）の色を全部、青の下の 1 ビットだけ反転する（絵が変わりうる・JSON として正しいまま）。
// 色が無ければ末尾に空白を 1 つ足す（中身の指紋だけが変わる）。
//
// WhyNot: 最初の 1 色だけにしないのは、背景色のように他の物に覆われる色だと絵に届かず、
// 4↔5 の差 0 が「キャッシュが古い物を返しても気づけない」弱い証になるため。
// 数を書き換えないのは、整数の範囲や個数のようにスキーマで縛られた値を壊して、
// 4 と 5 の両方が同じ誤りで止まり「差 0」の偽の緑になるため。
func TouchJSON(raw []byte) ([]byte, string) {
	locs := hexColor.FindAllIndex(raw, -1)
	if len(locs) == 0 {
		out := append(append([]byte{}, raw...), ' ')
		return out, "末尾に空白を 1 つ足した（色が無い）"
	}
	out := append([]byte{}, raw...)
	for _, loc := range locs {
		// "#rrggbb" の b の 2 字目は loc[0]+7。
		out[loc[0]+7] = flipHexLowBit(out[loc[0]+7])
	}
	first := locs[0]
	return out, fmt.Sprintf("色 %d 個の青の下の 1 ビットを反転した（最初の %s → %s）",
		len(locs), raw[first[0]:first[1]], out[first[0]:first[1]])
}

func flipHexLowBit(c byte) byte {
	const digits = "0123456789abcdef"
	n := strings.IndexByte(digits, toLower(c))
	return digits[n^1]
}

func toLower(c byte) byte {
	if 'A' <= c && c <= 'F' {
		return c + ('a' - 'A')
	}
	return c
}

// TouchPNG は左上 (0,0) の画素の赤の下の 1 ビットを反転した PNG を返す（透明なら不透明度も 1 足す）。
func TouchPNG(raw []byte) ([]byte, string, error) {
	img, err := png.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, "", err
	}
	b := img.Bounds()
	if b.Empty() {
		return nil, "", errors.New("PNG の大きさが 0")
	}
	dst := image.NewNRGBA(b)
	draw.Draw(dst, b, img, b.Min, draw.Src)
	c := dst.NRGBAAt(b.Min.X, b.Min.Y)
	before := c
	c.R ^= 1
	if c.A == 0 {
		c.A = 1
	}
	dst.SetNRGBA(b.Min.X, b.Min.Y, c)
	var buf bytes.Buffer
	if err := png.Encode(&buf, dst); err != nil {
		return nil, "", err
	}
	return buf.Bytes(), fmt.Sprintf("左上の画素 %s を %s にした（NRGBA で書き直し）", rgbaText(before), rgbaText(c)), nil
}

func rgbaText(c color.NRGBA) string {
	return fmt.Sprintf("rgba(%d,%d,%d,%d)", c.R, c.G, c.B, c.A)
}

// BetweenArgs は 3 番目で挟む make の口。指定があればそれ、無ければ `render SHOT=<場面>` で、
// 場面は主の引数の SHOT= と違う最初の物（主に SHOT= が無ければ最初の場面）。
func BetweenArgs(given string, main, shots []string) ([]string, error) {
	if f := strings.Fields(given); len(f) > 0 {
		return f, nil
	}
	cur := ""
	for _, a := range main {
		if v, ok := strings.CutPrefix(a, "SHOT="); ok {
			cur = v
		}
	}
	for _, s := range shots {
		if s != cur {
			return []string{"render", "SHOT=" + s}, nil
		}
	}
	return nil, errors.New("挟む入口を決められない（Makefile の SHOTS に別の場面が無い）— --between \"<make の口と引数>\" で渡す")
}
