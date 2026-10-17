package pxlib

import (
	"image"
	"image/png"
	"os"
	"path/filepath"
)

// WritePNG は画像を PNG で書く（置き場のフォルダが無ければ作る）。
func WritePNG(path string, img image.Image) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	fh, err := os.Create(path)
	if err != nil {
		return err
	}
	if err := png.Encode(fh, img); err != nil {
		fh.Close()
		return err
	}
	return fh.Close()
}
