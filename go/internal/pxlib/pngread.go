// Package pxlib は fge-go のサブコマンドが共有する土台 (PNG 読み・色差・色票の解決)。
package pxlib

// PNG を RGBA のバイト列にする入口。
// WhyNot: 手書きのデコーダを持たないのは image/png で足りるため。ただし
// 受け付ける範囲は 8bit・インターレース無しに絞る。広げると、検査が
// 「ダイジェスト不可」と断るはずの絵まで読めてしまい、出力が変わる。

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/color"
	_ "image/png"
	"os"
)

// Image は 1 枚の絵。Pix は 1 画素 4 バイト (RGBA・非乗算)。
type Image struct {
	W, H int
	Pix  []byte
}

var PNGMagic = []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}

// checkPNGHeader は IHDR を見て、受け付けない形式の絵を弾く。
func checkPNGHeader(data []byte) error {
	if len(data) < 8 || !bytes.Equal(data[:8], PNGMagic) {
		return errors.New("PNG ではない")
	}
	pos := 8
	for pos+8 <= len(data) {
		length := int(binary.BigEndian.Uint32(data[pos : pos+4]))
		tag := string(data[pos+4 : pos+8])
		if tag == "IHDR" {
			if pos+8+13 > len(data) {
				return errors.New("PNG ではない")
			}
			body := data[pos+8 : pos+8+13]
			depth := body[8]
			interlace := body[12]
			if interlace != 0 {
				return errors.New("インターレース PNG は未対応")
			}
			if depth != 8 {
				return fmt.Errorf("8bit 以外は未対応 (depth=%d)", depth)
			}
			return nil
		}
		pos += 12 + length
	}
	return errors.New("PNG ではない")
}

// LoadPNG は PNG を読んで RGBA にする。
func LoadPNG(path string) (*Image, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return DecodePNG(data)
}

// DecodePNG はバイト列から読む。
func DecodePNG(data []byte) (*Image, error) {
	if err := checkPNGHeader(data); err != nil {
		return nil, err
	}
	img, err := decodePNGImage(data)
	if err != nil {
		return nil, err
	}
	return toRGBA(img), nil
}

func decodePNGImage(data []byte) (image.Image, error) {
	img, _, err := image.Decode(bytes.NewReader(data))
	return img, err
}

func toRGBA(img image.Image) *Image {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	out := &Image{W: w, H: h, Pix: make([]byte, w*h*4)}
	switch src := img.(type) {
	case *image.NRGBA:
		for y := 0; y < h; y++ {
			copy(out.Pix[y*w*4:(y+1)*w*4],
				src.Pix[(y+b.Min.Y-src.Rect.Min.Y)*src.Stride:])
		}
		return out
	case *image.Gray:
		for y := 0; y < h; y++ {
			row := src.Pix[(y+b.Min.Y-src.Rect.Min.Y)*src.Stride:]
			for x := 0; x < w; x++ {
				v := row[x]
				o := (y*w + x) * 4
				out.Pix[o], out.Pix[o+1], out.Pix[o+2], out.Pix[o+3] = v, v, v, 255
			}
		}
		return out
	}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := color.NRGBAModel.Convert(img.At(b.Min.X+x, b.Min.Y+y)).(color.NRGBA)
			o := (y*w + x) * 4
			out.Pix[o], out.Pix[o+1], out.Pix[o+2], out.Pix[o+3] = c.R, c.G, c.B, c.A
		}
	}
	return out
}

// Row は y 行目の RGBA バイト列。
func (im *Image) Row(y int) []byte { return im.Pix[y*im.W*4 : (y+1)*im.W*4] }

// RGBAt は (x, y) の RGB を 1 つの整数にした物。
func (im *Image) RGBAt(x, y int) uint32 {
	o := (y*im.W + x) * 4
	return uint32(im.Pix[o])<<16 | uint32(im.Pix[o+1])<<8 | uint32(im.Pix[o+2])
}

// Rows は絵を画素の行にする。
func (im *Image) Rows() [][]RGBA {
	rows := make([][]RGBA, im.H)
	for y := range rows {
		rows[y] = make([]RGBA, im.W)
		for x := range rows[y] {
			o := (y*im.W + x) * 4
			copy(rows[y][x][:], im.Pix[o:o+4])
		}
	}
	return rows
}
