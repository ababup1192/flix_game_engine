// Package tape は flow で撮った動画を、スマホで注釈を付ける 1 枚の頁（index.html）に束ねる。
//
// 入力はゲームが書いた tape.json と video.mp4。ここで足すのは commit・strip.jpg（コマを横に並べた絵）と
// それを指す欄だけで、ゲームの書いた値は並びも中身もそのまま頁へ渡す。
package tape

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

//go:embed template.html
var templateHTML string

// tapeDecl は雛形で TAPE の JSON を置く所の前の字（publish が置いた頁の branches を読み返す時にも引く）。
const tapeDecl = "const TAPE = "

// splashDecl は雛形で SPLASH の JSON を置く所の前の字。
const splashDecl = "const SPLASH = "

const (
	TapeFile  = "tape.json"
	VideoFile = "video.mp4"
	StripFile = "strip.jpg"
	IndexFile = "index.html"

	// StripPerSec は strip のコマの間隔（0.5 秒ごと）。頁の欄の名前 stripPerSec はモックのまま。
	StripPerSec = 2
	// StripW・StripH は strip の 1 コマ（帯とサムネの枠の比）。動画の比が違えば真ん中から切り抜く（横長の動画は左右が落ちる）。
	StripW = 54
	StripH = 96
)

// Strip は頁の TAPE.strip。
type Strip struct {
	File  string `json:"file"`
	Count int    `json:"count"`
	W     int    `json:"w"`
	H     int    `json:"h"`
}

// Options は Build の指定。
type Options struct {
	Dir    string
	Group  []string // --group のフォルダ（2 つ以上。Dir の代わり）
	Commit string   // 空なら Dir で git rev-parse --short HEAD
	FFmpeg string   // 空なら環境変数 FFMPEG、それも無ければ PATH の ffmpeg
	// Branches は頁の branches をこの値にする（--group が組み立てた物）。nil なら tape.json の値のまま。
	Branches *[]Branch
	// Splash は動画を取っている間に頁が描く起動画面の材料（bin/fge が engine の BootFontData から作って渡す）。
	Splash Splash
}

// Splash は頁の SPLASH。ゲームのブラウザ版の bundle.json の splash と同じ形（ロゴと組み込みフォントの PNG・字の表・字の寸法）。
// WhyNot: 頁の system-ui の字で起動画面を描かない — ゲームの起動画面はドットの字で描くので、並べた時に同じ絵に見えない。
// WhyNot: ここで BootFontData.flix を読まない — 読み解きは書き出し（export-web）の側に 1 つだけ置き、2 つに割らない。
type Splash struct {
	Logo     string  `json:"logo,omitempty"`
	Font     string  `json:"font,omitempty"`
	Glyphs   string  `json:"glyphs,omitempty"`
	FontSize float64 `json:"fontSize,omitempty"`
	Ascent   float64 `json:"ascent,omitempty"`
	Descent  float64 `json:"descent,omitempty"`
	LineGap  float64 `json:"lineGap,omitempty"`
	CellH    int     `json:"cellH,omitempty"`
}

// Run は bin/fge tape の本体。splash は作る頁に埋める起動画面の材料（publish では使わない）。
func Run(args []string, splash Splash, stdout, stderr io.Writer) int {
	if len(args) > 0 && args[0] == "publish" {
		return RunPublish(args[1:], stdout, stderr)
	}
	opt, err := parseArgs(args)
	if err != nil {
		fmt.Fprintln(stderr, err)
		fmt.Fprintln(stderr, usage)
		return 2
	}
	opt.Splash = splash
	if len(opt.Group) > 0 {
		outs, err := BuildGroup(opt, stderr)
		if err != nil {
			fmt.Fprintln(stderr, "tape:", err)
			return 1
		}
		fmt.Fprintln(stdout, strings.Join(outs, "\n"))
		return 0
	}
	out, err := Build(opt)
	if err != nil {
		fmt.Fprintln(stderr, "tape:", err)
		return 1
	}
	fmt.Fprintln(stdout, out)
	return 0
}

const usage = "使い方: bin/fge tape --dir <フォルダ>   （フォルダに tape.json と video.mp4。strip.jpg と index.html を書く）\n" +
	"       bin/fge tape --group <フォルダ> <フォルダ>…   （同じ始まりから撮った複数のテープ。選んだ道が分かれた所を分岐のカードにして、隣の頁へつなぐ。フォルダは並べて置く）\n" +
	"       bin/fge tape publish <フォルダ>…   （Pages の置き場へ置いて URL を出す。詳しくは publish --help）"

func parseArgs(args []string) (Options, error) {
	var opt Options
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--dir" && i+1 < len(args):
			opt.Dir = args[i+1]
			i++
		case strings.HasPrefix(a, "--dir="):
			opt.Dir = strings.TrimPrefix(a, "--dir=")
		case a == "--group":
			for i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") {
				opt.Group = append(opt.Group, args[i+1])
				i++
			}
		case a == "-h" || a == "--help":
			return opt, errors.New("")
		default:
			return opt, fmt.Errorf("知らない引数: %s", a)
		}
	}
	if opt.Dir != "" && len(opt.Group) > 0 {
		return opt, errors.New("--dir と --group はどちらか 1 つ")
	}
	if len(opt.Group) == 1 {
		return opt, errors.New("--group には 2 つ以上のフォルダが要る（1 つなら --dir）")
	}
	if opt.Dir == "" && len(opt.Group) == 0 {
		return opt, errors.New("--dir か --group が要る")
	}
	return opt, nil
}

// Build は Dir の tape.json と video.mp4 から strip.jpg と index.html を書き、index.html の道を返す。
func Build(opt Options) (string, error) {
	raw, err := os.ReadFile(filepath.Join(opt.Dir, TapeFile))
	if err != nil {
		return "", fmt.Errorf("%s を読めない（ゲームの make tape が書く）: %w", TapeFile, err)
	}
	t, err := Parse(raw)
	if err != nil {
		return "", err
	}
	return build(opt, t)
}

func build(opt Options, t *Tape) (string, error) {
	video := filepath.Join(opt.Dir, VideoFile)
	if _, err := os.Stat(video); err != nil {
		return "", fmt.Errorf("%s が無い（ゲームの Makefile の動画の手順が作る）: %w", video, err)
	}
	commit := opt.Commit
	var err error
	if commit == "" {
		if commit, err = gitShortHead(opt.Dir); err != nil {
			return "", err
		}
	}
	strip, err := MakeStrip(opt.FFmpeg, video, filepath.Join(opt.Dir, StripFile), t.Duration)
	if err != nil {
		return "", err
	}
	if opt.Branches != nil {
		b, err := json.Marshal(*opt.Branches)
		if err != nil {
			return "", err
		}
		t.raw["branches"] = b
	}
	page, err := Render(t, commit, strip, opt.Splash)
	if err != nil {
		return "", err
	}
	index := filepath.Join(opt.Dir, IndexFile)
	if err := os.WriteFile(index, page, 0o644); err != nil {
		return "", err
	}
	return index, nil
}

func gitShortHead(dir string) (string, error) {
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--short", "HEAD").Output()
	if err != nil {
		return "", fmt.Errorf("commit を取れない（%s で git rev-parse --short HEAD が失敗。ゲームのリポジトリの中で流す）: %w", dir, err)
	}
	return strings.TrimSpace(string(out)), nil
}

// Render は雛形の HTML に TAPE と SPLASH を差し込む。足す欄（commit・video・stripPerSec・strip）はゲームの値より優先する。
func Render(t *Tape, commit string, strip Strip, splash Splash) ([]byte, error) {
	added := map[string]any{"commit": commit, "video": VideoFile, "stripPerSec": StripPerSec, "strip": strip}
	var buf bytes.Buffer
	buf.WriteByte('{')
	first := true
	write := func(key string, val []byte) {
		if !first {
			buf.WriteByte(',')
		}
		first = false
		k, _ := json.Marshal(key)
		buf.Write(k)
		buf.WriteByte(':')
		buf.Write(val)
	}
	for _, key := range fieldOrder {
		if v, ok := added[key]; ok {
			b, err := json.Marshal(v)
			if err != nil {
				return nil, err
			}
			write(key, b)
			continue
		}
		v, ok := t.raw[key]
		if !ok {
			continue
		}
		var c bytes.Buffer
		if err := json.Compact(&c, v); err != nil {
			return nil, err
		}
		write(key, c.Bytes())
	}
	buf.WriteByte('}')
	// WhyNot: 素の JSON を <script> にそのまま置くと、台詞の "</script>" で頁が切れる。< > & と U+2028/9 を \u に逃がす。
	var safe bytes.Buffer
	json.HTMLEscape(&safe, buf.Bytes())

	splashJSON, err := json.Marshal(splash)
	if err != nil {
		return nil, err
	}
	page := strings.Replace(templateHTML, tapeDecl+"__TAPE_JSON__", tapeDecl+safe.String(), 1)
	page = strings.Replace(page, splashDecl+"__SPLASH_JSON__", splashDecl+string(splashJSON), 1)
	page = strings.Replace(page, "__TAPE_TITLE__", html.EscapeString(t.Title), 1)
	return []byte(page), nil
}
