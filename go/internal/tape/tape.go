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

const (
	TapeFile  = "tape.json"
	VideoFile = "video.mp4"
	StripFile = "strip.jpg"
	IndexFile = "index.html"

	// StripPerSec は strip のコマの間隔（0.5 秒ごと）。頁の欄の名前 stripPerSec はモックのまま。
	StripPerSec = 2
	StripW      = 54
	StripH      = 96
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
	Commit string // 空なら Dir で git rev-parse --short HEAD
	FFmpeg string // 空なら環境変数 FFMPEG、それも無ければ PATH の ffmpeg
}

// Run は bin/fge tape の本体。
func Run(args []string, stdout, stderr io.Writer) int {
	if len(args) > 0 && args[0] == "publish" {
		return RunPublish(args[1:], stdout, stderr)
	}
	opt, err := parseArgs(args)
	if err != nil {
		fmt.Fprintln(stderr, err)
		fmt.Fprintln(stderr, usage)
		return 2
	}
	out, err := Build(opt)
	if err != nil {
		fmt.Fprintln(stderr, "tape:", err)
		return 1
	}
	fmt.Fprintln(stdout, out)
	return 0
}

const usage = "使い方: bin/fge tape --dir <フォルダ>   （フォルダに tape.json と video.mp4。strip.jpg と index.html を書く）\n       bin/fge tape publish <フォルダ>   （Pages の置き場へ置いて URL を出す。詳しくは publish --help）"

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
		case a == "-h" || a == "--help":
			return opt, errors.New("")
		default:
			return opt, fmt.Errorf("知らない引数: %s", a)
		}
	}
	if opt.Dir == "" {
		return opt, errors.New("--dir が要る")
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
	video := filepath.Join(opt.Dir, VideoFile)
	if _, err := os.Stat(video); err != nil {
		return "", fmt.Errorf("%s が無い（ゲームの Makefile の動画の手順が作る）: %w", video, err)
	}
	commit := opt.Commit
	if commit == "" {
		if commit, err = gitShortHead(opt.Dir); err != nil {
			return "", err
		}
	}
	strip, err := MakeStrip(opt.FFmpeg, video, filepath.Join(opt.Dir, StripFile), t.Duration)
	if err != nil {
		return "", err
	}
	page, err := Render(t, commit, strip)
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

// Render は雛形の HTML に TAPE を差し込む。足す欄（commit・video・stripPerSec・strip）はゲームの値より優先する。
func Render(t *Tape, commit string, strip Strip) ([]byte, error) {
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

	page := strings.Replace(templateHTML, "__TAPE_JSON__", safe.String(), 1)
	page = strings.Replace(page, "__TAPE_TITLE__", html.EscapeString(t.Title), 1)
	return []byte(page), nil
}
