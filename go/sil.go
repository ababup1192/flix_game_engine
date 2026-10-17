package main

// sil — ドット絵 (*.sprite.json) を目視用の PNG に描き出す。
//   sil  … 全 legend を黒 1 色に潰す
//   gray … 明度だけのグレーにする
//   bg   … 明背景と暗背景に並べて置く

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

var (
	silInk  = pxlib.RGBA{0x1A, 0x1A, 0x1A, 255}
	silBG   = pxlib.RGBA{255, 255, 255, 255}
	bgLight = pxlib.RGBA{0xE8, 0xE8, 0xE8, 255}
	bgDark  = pxlib.RGBA{0x20, 0x20, 0x20, 255}
)

const (
	bgGap     = 2  // 並べた 2 枚の間の隙間 (拡大前のセル数)
	smallSide = 48 // これ以下は 8 倍、超えたら 4 倍に拡大する
)

func pngChunk(buf *bytes.Buffer, tag string, data []byte) {
	_ = binary.Write(buf, binary.BigEndian, uint32(len(data)))
	body := append([]byte(tag), data...)
	buf.Write(body)
	_ = binary.Write(buf, binary.BigEndian, crc32.ChecksumIEEE(body))
}

func encodePNG(width, height int, grid [][]pxlib.RGBA) []byte {
	raw := make([]byte, 0, height*(1+width*4))
	for _, row := range grid {
		raw = append(raw, 0)
		for _, px := range row {
			raw = append(raw, px[0], px[1], px[2], px[3])
		}
	}
	var z bytes.Buffer
	w, _ := zlib.NewWriterLevel(&z, zlib.BestCompression)
	_, _ = w.Write(raw)
	_ = w.Close()

	var buf bytes.Buffer
	buf.Write(pxlib.PNGMagic)
	ihdr := make([]byte, 13)
	binary.BigEndian.PutUint32(ihdr[0:], uint32(width))
	binary.BigEndian.PutUint32(ihdr[4:], uint32(height))
	ihdr[8], ihdr[9] = 8, 6
	pngChunk(&buf, "IHDR", ihdr)
	pngChunk(&buf, "IDAT", z.Bytes())
	pngChunk(&buf, "IEND", nil)
	return buf.Bytes()
}

// legendColorsOf は legend の 文字 → RGBA と、解けなかった色名 (文字=名前) を返す。
// 解けない文字は塗らない (palette の縄張り)。
func legendColorsOf(gameDir string, doc map[string]any) (map[string]pxlib.RGBA, []string) {
	return pxlib.LegendColorsOf(gameDir, doc)
}

func toGray(px pxlib.RGBA) pxlib.RGBA {
	y := byte(math.RoundToEven(
		0.299*float64(px[0]) + 0.587*float64(px[1]) + 0.114*float64(px[2])))
	return pxlib.RGBA{y, y, y, px[3]}
}

// framePixels は rows を RGBA の 2 次元列へ (legend に無い文字 = background)。
func framePixels(rows []string, legend map[string]pxlib.RGBA, background pxlib.RGBA) (int, int, [][]pxlib.RGBA) {
	width := 0
	runeRows := make([][]rune, len(rows))
	for i, r := range rows {
		runeRows[i] = []rune(r)
		if len(runeRows[i]) > width {
			width = len(runeRows[i])
		}
	}
	grid := make([][]pxlib.RGBA, len(rows))
	for y, row := range runeRows {
		line := make([]pxlib.RGBA, width)
		for x := 0; x < width; x++ {
			char := "."
			if x < len(row) {
				char = string(row[x])
			}
			if got, ok := legend[char]; ok {
				line[x] = got
			} else {
				line[x] = background
			}
		}
		grid[y] = line
	}
	return width, len(rows), grid
}

func scaleUp(width, height int, grid [][]pxlib.RGBA) (int, int, [][]pxlib.RGBA) {
	side := width
	if height > side {
		side = height
	}
	scale := 4
	if side <= smallSide {
		scale = 8
	}
	var out [][]pxlib.RGBA
	for _, row := range grid {
		line := make([]pxlib.RGBA, 0, len(row)*scale)
		for _, px := range row {
			for i := 0; i < scale; i++ {
				line = append(line, px)
			}
		}
		for i := 0; i < scale; i++ {
			out = append(out, line)
		}
	}
	return width * scale, height * scale, out
}

func buildFrame(mode string, rows []string, legend map[string]pxlib.RGBA) (int, int, [][]pxlib.RGBA) {
	switch mode {
	case "sil":
		ink := map[string]pxlib.RGBA{}
		for char := range legend {
			ink[char] = silInk
		}
		return framePixels(rows, ink, silBG)
	case "gray":
		gray := map[string]pxlib.RGBA{}
		for char, px := range legend {
			gray[char] = toGray(px)
		}
		return framePixels(rows, gray, pxlib.RGBA{0, 0, 0, 0})
	}
	width, height, light := framePixels(rows, legend, bgLight)
	_, _, dark := framePixels(rows, legend, bgDark)
	joined := make([][]pxlib.RGBA, height)
	for y := 0; y < height; y++ {
		line := make([]pxlib.RGBA, 0, width*2+bgGap)
		line = append(line, light[y]...)
		for i := 0; i < bgGap; i++ {
			line = append(line, pxlib.RGBA{0, 0, 0, 0})
		}
		line = append(line, dark[y]...)
		joined[y] = line
	}
	return width*2 + bgGap, height, joined
}

// baseNameOf は書き出しファイルの頭。ゲームが違えば同じ名前の Doc があるので潰さない。
func baseNameOf(root, shown string) string {
	stem := strings.TrimSuffix(shown, ".sprite.json")
	abs, err := filepath.Abs(stem)
	if err != nil {
		abs = stem
	}
	rel, err := filepath.Rel(root, abs)
	if err != nil {
		rel = abs
	}
	rel = strings.ReplaceAll(rel, string(os.PathSeparator), "__")
	return strings.ReplaceAll(rel, "..", "_")
}

type silTarget struct {
	shown   string
	path    string
	gameDir string
}

func gameDirOf(path string) string {
	abs, _ := filepath.Abs(path)
	parent := filepath.Dir(abs)
	if filepath.Base(parent) == "assets" {
		return filepath.Dir(parent)
	}
	return parent
}

func gatherTargets(argvPaths []string, root string) []silTarget {
	var targets []silTarget
	if len(argvPaths) > 0 {
		for _, p := range argvPaths {
			targets = append(targets, silTarget{p, p, gameDirOf(p)})
		}
		return targets
	}
	for _, game := range pxlib.GameDirsOf(root, func() bool { return pxlib.HasDir(filepath.Join(root, "assets")) }) {
		gameDir := filepath.Join(root, game)
		for _, rel := range pxlib.WalkJSON(gameDir, pxlib.SpriteExcludedDirs) {
			if strings.HasSuffix(rel, ".sprite.json") {
				targets = append(targets, silTarget{
					game + "/" + rel, filepath.Join(gameDir, rel), gameDir})
			}
		}
	}
	return targets
}

func processSilDoc(root string, t silTarget, mode, outDir string) ([]string, error) {
	doc, ok := pxlib.AsObject(pxlib.LoadJSON(t.path))
	if !ok {
		return nil, fmt.Errorf("読めない: %s", t.shown)
	}
	legend, unresolved := legendColorsOf(t.gameDir, doc)
	// WhyNot: 解けない色があっても白紙を書き出さないのは、この道具の出す絵が
	// 「形が物として読めるか」を人が見るための物だから。全面白の PNG は
	// 「入力が解けなかった」と「本当に何も描かれていない」を見分けられない。
	if len(legend) == 0 {
		if len(unresolved) == 0 {
			return nil, fmt.Errorf("legend がありません: %s", t.shown)
		}
		return nil, fmt.Errorf(
			"legend の色が 1 つも解けません: %s (%s)\n"+
				"  色名の出どころは 3 つ: 同じゲームの *.theme.json / doc の paletteFile / doc の palette。\n"+
				"  入れ子やドット付きの色名 (grass.lit) は解けません",
			t.shown, strings.Join(unresolved, " "))
	}
	if len(unresolved) > 0 {
		fmt.Fprintf(os.Stderr, "!! 解けない色: %s (%s)\n", t.shown, strings.Join(unresolved, " "))
	}
	base := baseNameOf(root, t.shown)
	sprites, _ := pxlib.AsObject(doc["sprites"])
	spriteNames := make([]string, 0, len(sprites))
	for n := range sprites {
		spriteNames = append(spriteNames, n)
	}
	sort.Strings(spriteNames)

	var written []string
	for _, spriteName := range spriteNames {
		spec, ok := pxlib.AsObject(sprites[spriteName])
		if strings.HasPrefix(spriteName, "//") || !ok {
			continue
		}
		frames, _ := pxlib.AsObject(spec["frames"])
		frameNames := make([]string, 0, len(frames))
		for n := range frames {
			frameNames = append(frameNames, n)
		}
		sort.Strings(frameNames)
		for _, frameName := range frameNames {
			rowsAny, ok := frames[frameName].([]any)
			if !ok || len(rowsAny) == 0 {
				continue
			}
			rows := make([]string, len(rowsAny))
			allStrings := true
			maxLen := 0
			for i, r := range rowsAny {
				s, ok := r.(string)
				if !ok {
					allStrings = false
					break
				}
				rows[i] = s
				if n := len([]rune(s)); n > maxLen {
					maxLen = n
				}
			}
			if !allStrings || maxLen == 0 {
				continue
			}
			w, h, grid := buildFrame(mode, rows, legend)
			w, h, grid = scaleUp(w, h, grid)
			out := filepath.Join(outDir, fmt.Sprintf("%s__%s__%s.png", base, spriteName, frameName))
			if err := os.WriteFile(out, encodePNG(w, h, grid), 0o644); err != nil {
				return written, err
			}
			written = append(written, out)
		}
	}
	return written, nil
}

// silResult は --json 用のまとめ。
type silResult struct {
	Mode    string   `json:"mode"`
	Written []string `json:"written"`
	Count   int      `json:"count"`
	Exit    int      `json:"exit"`
}

func runSil(out *strings.Builder, root, mode string, files []string, asJSON bool) int {
	outDir := filepath.Join(root, "gallery", mode)
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	count := 0
	failed := 0
	var written []string
	for _, t := range gatherTargets(files, root) {
		got, err := processSilDoc(root, t, mode, outDir)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			failed++
		}
		for _, p := range got {
			rel, _ := filepath.Rel(root, p)
			written = append(written, rel)
			if !asJSON {
				fmt.Fprintln(out, rel)
			}
			count++
		}
	}
	// WhyNot: 1 つも描けなかった doc があっても 0 で終わらないのは、呼ぶ側 (人・フック) が
	// 「緑だから絵は出ている」と読むため。書けた物は残したまま、赤で知らせる。
	code := 0
	if failed > 0 {
		code = 1
	}
	if asJSON {
		emitJSON(out, silResult{mode, orEmpty(written), count, code})
		return code
	}
	fmt.Fprintf(out, "%d 枚を書き出した (%s)\n", count, mode)
	if failed > 0 {
		fmt.Fprintf(out, "%d 個の doc は描けなかった (上の理由)\n", failed)
	}
	return code
}
