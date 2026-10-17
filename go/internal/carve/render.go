package carve

// sprite.json の文字格子を PNG に描く。
//
//	fge-go carve-render                 # bin/assets 配下を全部 bin/gallery へ
//	fge-go carve-render a.sprite.json   # 指定ファイルだけ

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// RGBA は 1 画素。
type RGBA [4]int

// RGB は不透明な色。
type RGB [3]int

func pngChunk(buf *bytes.Buffer, tag string, data []byte) {
	_ = binary.Write(buf, binary.BigEndian, uint32(len(data)))
	body := append([]byte(tag), data...)
	buf.Write(body)
	_ = binary.Write(buf, binary.BigEndian, crc32.ChecksumIEEE(body))
}

// PNGOf は RGBA の格子を PNG のバイト列にする。
//
// WhyNot: 出たバイト列そのものを絵の同一性の物差しに使わない。圧縮の仕方が
// 変われば同じ画素でもバイト列は変わる。比べるなら展開した画素で見る。
func PNGOf(width, height int, rows [][]RGBA) []byte {
	raw := make([]byte, 0, height*(1+width*4))
	for _, row := range rows {
		raw = append(raw, 0)
		for _, px := range row {
			raw = append(raw, byte(px[0]), byte(px[1]), byte(px[2]), byte(px[3]))
		}
	}
	var z bytes.Buffer
	w, _ := zlib.NewWriterLevel(&z, zlib.BestCompression)
	_, _ = w.Write(raw)
	_ = w.Close()

	var buf bytes.Buffer
	buf.Write([]byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'})
	ihdr := make([]byte, 13)
	binary.BigEndian.PutUint32(ihdr[0:], uint32(width))
	binary.BigEndian.PutUint32(ihdr[4:], uint32(height))
	ihdr[8], ihdr[9] = 8, 6
	pngChunk(&buf, "IHDR", ihdr)
	pngChunk(&buf, "IDAT", z.Bytes())
	pngChunk(&buf, "IEND", nil)
	return buf.Bytes()
}

// RGBAOf は "#rrggbb" を不透明な画素にする。
func RGBAOf(value string) RGBA {
	body := value
	if strings.HasPrefix(body, "#") {
		body = body[1:]
	}
	out := RGBA{0, 0, 0, 255}
	for i, at := range []int{0, 2, 4} {
		v, _ := strconv.ParseInt(body[at:at+2], 16, 32)
		out[i] = int(v)
	}
	return out
}

// HexOf は値から "#rrggbb" を取り出す。取れなければ空。
func HexOf(value any) string {
	if s, ok := value.(string); ok {
		body := s
		if strings.HasPrefix(body, "#") {
			body = body[1:]
		}
		if len(body) == 6 && strings.IndexFunc(body, func(r rune) bool {
			return !strings.ContainsRune("0123456789abcdefABCDEF", r)
		}) < 0 {
			return "#" + strings.ToLower(body)
		}
	}
	if m, ok := value.(*pxlib.OMap[string, any]); ok {
		for _, key := range []string{"hex", "color", "value"} {
			if v, ok := m.Get(key); ok {
				if found := HexOf(v); found != "" {
					return found
				}
			}
		}
	}
	return ""
}

// RenderDoc は 1 つの sprite.json を PNG に描き、書いたパスを返す。
func RenderDoc(path, outDir string) ([]string, error) {
	doc, err := readJSONOrdered(path)
	if err != nil {
		return nil, err
	}
	palette := map[string]string{}
	if p, ok := doc.Get("palette"); ok {
		if obj, ok := p.(*pxlib.OMap[string, any]); ok {
			for _, name := range obj.Keys() {
				v, _ := obj.Get(name)
				if hex := HexOf(v); hex != "" {
					palette[name] = hex
				}
			}
		}
	}
	legend := map[string]RGBA{}
	if p, ok := doc.Get("legend"); ok {
		if obj, ok := p.(*pxlib.OMap[string, any]); ok {
			for _, char := range obj.Keys() {
				v, _ := obj.Get(char)
				direct := HexOf(v)
				name := ""
				if s, ok := v.(string); ok {
					name = s
					if strings.HasPrefix(s, "@") {
						name = s[1:]
					}
				}
				resolved := direct
				if resolved == "" {
					resolved = palette[name]
				}
				if resolved != "" {
					legend[char] = RGBAOf(resolved)
				}
			}
		}
	}

	base := strings.Replace(filepath.Base(path), ".sprite.json", "", 1)
	var written []string
	sprites, _ := doc.Get("sprites")
	spriteObj, ok := sprites.(*pxlib.OMap[string, any])
	if !ok {
		return written, nil
	}
	for _, spriteName := range spriteObj.Keys() {
		specAny, _ := spriteObj.Get(spriteName)
		spec, isObj := specAny.(*pxlib.OMap[string, any])
		if strings.HasPrefix(spriteName, "//") || !isObj {
			continue
		}
		framesAny, _ := spec.Get("frames")
		frames, isObj := framesAny.(*pxlib.OMap[string, any])
		if !isObj {
			continue
		}
		for _, frameName := range frames.Keys() {
			rowsAny, _ := frames.Get(frameName)
			rowsList, isList := rowsAny.([]any)
			if !isList {
				continue
			}
			var rows []string
			for _, r := range rowsList {
				s, _ := r.(string)
				rows = append(rows, s)
			}
			width := 0
			for _, r := range rows {
				if n := len([]rune(r)); n > width {
					width = n
				}
			}
			height := len(rows)
			if width == 0 || height == 0 {
				continue
			}
			side := width
			if height > side {
				side = height
			}
			scale := 4
			if side <= 48 {
				scale = 8
			}
			var rgbaRows [][]RGBA
			for _, row := range rows {
				runes := []rune(row)
				var line []RGBA
				for x := 0; x < width; x++ {
					char := "."
					if x < len(runes) {
						char = string(runes[x])
					}
					px := RGBA{0, 0, 0, 0}
					if c, ok := legend[char]; ok {
						px = c
					}
					for i := 0; i < scale; i++ {
						line = append(line, px)
					}
				}
				for i := 0; i < scale; i++ {
					rgbaRows = append(rgbaRows, line)
				}
			}
			out := filepath.Join(outDir, fmt.Sprintf("%s__%s__%s.png", base, spriteName, frameName))
			if err := os.WriteFile(out, PNGOf(width*scale, height*scale, rgbaRows), 0o644); err != nil {
				return written, err
			}
			written = append(written, out)
		}
	}
	return written, nil
}

// RunRender は carve-render の入口。root は assets / gallery を置く根。
func RunRender(out *strings.Builder, root string, args []string) (int, error) {
	outDir := filepath.Join(root, "gallery")
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return 1, err
	}
	targets := args
	if len(targets) == 0 {
		var found []string
		_ = filepath.Walk(filepath.Join(root, "assets"), func(p string, info os.FileInfo, err error) error {
			if err != nil || info.IsDir() {
				return nil //nolint:nilerr // 読めない枝で全体を止めないため、黙って飛ばす
			}
			if strings.HasSuffix(p, ".sprite.json") {
				found = append(found, p)
			}
			return nil
		})
		sort.Strings(found)
		targets = found
	}
	count := 0
	for _, path := range targets {
		written, err := RenderDoc(path, outDir)
		if err != nil {
			return 1, err
		}
		for _, w := range written {
			rel, _ := filepath.Rel(root, w)
			fmt.Fprintln(out, rel)
			count++
		}
	}
	fmt.Fprintf(out, "%d 枚を書き出した\n", count)
	return 0, nil
}
