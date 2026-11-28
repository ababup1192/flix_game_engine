// Package gltfpack は .gltf と外のファイル（.bin・画像）を 1 つの .glb にまとめる。
package gltfpack

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	glbMagic  = 0x46546C67
	chunkJSON = 0x4E4F534A
	chunkBIN  = 0x004E4942
)

// Result は 1 回のまとめの要約。
type Result struct {
	Buffers        int
	Images         int
	BinBytes       int
	ExtensionsUsed []string
}

// PackFile は src（.gltf）を読み、dst（.glb）へ書く。
func PackFile(src, dst string) (Result, error) {
	raw, err := os.ReadFile(src)
	if err != nil {
		return Result{}, err
	}
	glb, res, err := Pack(raw, func(uri string) ([]byte, error) {
		return readURI(filepath.Dir(src), uri)
	})
	if err != nil {
		return Result{}, err
	}
	return res, os.WriteFile(dst, glb, 0o644)
}

// Pack は .gltf の JSON を .glb のバイト列にする。load は uri（data URI 以外）を読む。
// WhyNot: 型付きの struct へ解かない — 知らない拡張や extras の欄を落とさずに通すため、
// 触る欄（buffers・bufferViews・images）だけを書き換える。
func Pack(gltfJSON []byte, load func(uri string) ([]byte, error)) ([]byte, Result, error) {
	dec := json.NewDecoder(bytes.NewReader(gltfJSON))
	dec.UseNumber()
	var doc map[string]any
	if err := dec.Decode(&doc); err != nil {
		return nil, Result{}, fmt.Errorf("glTF の JSON が読めない: %w", err)
	}
	buffers, _ := doc["buffers"].([]any)
	views, _ := doc["bufferViews"].([]any)
	images, _ := doc["images"].([]any)

	var bin []byte
	appendChunk := func(data []byte) int {
		for len(bin)%4 != 0 {
			bin = append(bin, 0)
		}
		off := len(bin)
		bin = append(bin, data...)
		return off
	}

	shifts := make([]int, len(buffers))
	for i, b := range buffers {
		bm, _ := b.(map[string]any)
		uri, _ := bm["uri"].(string)
		if uri == "" {
			return nil, Result{}, fmt.Errorf("buffers[%d] に uri が無い（もう .glb の BIN を指している）", i)
		}
		data, err := loadAny(uri, load)
		if err != nil {
			return nil, Result{}, fmt.Errorf("buffers[%d] (%s): %w", i, uri, err)
		}
		if n, ok := intOf(bm["byteLength"]); ok && n > len(data) {
			return nil, Result{}, fmt.Errorf("buffers[%d] (%s): byteLength %d より中身 %d バイトが短い", i, uri, n, len(data))
		}
		shifts[i] = appendChunk(data)
	}
	for i, v := range views {
		vm, _ := v.(map[string]any)
		bi, _ := intOf(vm["buffer"])
		if bi < 0 || bi >= len(shifts) {
			return nil, Result{}, fmt.Errorf("bufferViews[%d] の buffer %d が無い", i, bi)
		}
		off, _ := intOf(vm["byteOffset"])
		vm["buffer"] = 0
		vm["byteOffset"] = off + shifts[bi]
	}
	embedded := 0
	for i, im := range images {
		imm, _ := im.(map[string]any)
		uri, _ := imm["uri"].(string)
		if uri == "" {
			continue
		}
		data, err := loadAny(uri, load)
		if err != nil {
			return nil, Result{}, fmt.Errorf("images[%d] (%s): %w", i, uri, err)
		}
		mime, _ := imm["mimeType"].(string)
		if mime == "" {
			mime = mimeOf(uri, data)
		}
		if mime == "" {
			return nil, Result{}, fmt.Errorf("images[%d] (%s): 画像の種類が分からない（mimeType を書く）", i, uri)
		}
		off := appendChunk(data)
		views = append(views, map[string]any{"buffer": 0, "byteOffset": off, "byteLength": len(data)})
		delete(imm, "uri")
		imm["bufferView"] = len(views) - 1
		imm["mimeType"] = mime
		embedded++
	}
	for len(bin)%4 != 0 {
		bin = append(bin, 0)
	}
	if len(views) > 0 {
		doc["bufferViews"] = views
	}
	if len(bin) > 0 {
		doc["buffers"] = []any{map[string]any{"byteLength": len(bin)}}
	} else {
		delete(doc, "buffers")
	}

	js, err := json.Marshal(doc)
	if err != nil {
		return nil, Result{}, err
	}
	for len(js)%4 != 0 {
		js = append(js, ' ')
	}
	total := 12 + 8 + len(js)
	if len(bin) > 0 {
		total += 8 + len(bin)
	}
	var out bytes.Buffer
	w := func(v uint32) { _ = binary.Write(&out, binary.LittleEndian, v) }
	w(glbMagic)
	w(2)
	w(uint32(total))
	w(uint32(len(js)))
	w(chunkJSON)
	out.Write(js)
	if len(bin) > 0 {
		w(uint32(len(bin)))
		w(chunkBIN)
		out.Write(bin)
	}
	return out.Bytes(), Result{Buffers: len(buffers), Images: embedded, BinBytes: len(bin), ExtensionsUsed: extensionsOf(doc)}, nil
}

func loadAny(uri string, load func(string) ([]byte, error)) ([]byte, error) {
	if strings.HasPrefix(uri, "data:") {
		comma := strings.IndexByte(uri, ',')
		if comma < 0 || !strings.HasSuffix(uri[:comma], ";base64") {
			return nil, fmt.Errorf("base64 でない data URI は読まない")
		}
		return base64.StdEncoding.DecodeString(uri[comma+1:])
	}
	return load(uri)
}

// readURI は .gltf の隣からの相対の uri を読む。
// WhyNot: 絶対パスや .. で外へ出る uri を読まない — 拾ってきた .gltf が手元の任意のファイルを .glb に詰められてしまう。
func readURI(dir, uri string) ([]byte, error) {
	p, err := url.PathUnescape(uri)
	if err != nil {
		return nil, err
	}
	if strings.Contains(p, "://") || filepath.IsAbs(p) {
		return nil, fmt.Errorf("外の uri は読まない（.gltf の隣のファイルだけ）")
	}
	clean := filepath.Clean(filepath.FromSlash(p))
	if clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return nil, fmt.Errorf(".gltf のフォルダの外は読まない")
	}
	return os.ReadFile(filepath.Join(dir, clean))
}

func mimeOf(uri string, data []byte) string {
	switch {
	case bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")):
		return "image/png"
	case bytes.HasPrefix(data, []byte{0xFF, 0xD8, 0xFF}):
		return "image/jpeg"
	case bytes.HasPrefix(data, []byte("\xABKTX 20\xBB\r\n\x1A\n")):
		return "image/ktx2"
	case len(data) >= 12 && string(data[0:4]) == "RIFF" && string(data[8:12]) == "WEBP":
		return "image/webp"
	}
	switch strings.ToLower(filepath.Ext(uri)) {
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	}
	return ""
}

func intOf(v any) (int, bool) {
	switch n := v.(type) {
	case json.Number:
		i, err := n.Int64()
		return int(i), err == nil
	case int:
		return n, true
	case float64:
		return int(n), true
	}
	return 0, false
}

func extensionsOf(doc map[string]any) []string {
	list, _ := doc["extensionsUsed"].([]any)
	var names []string
	for _, e := range list {
		if s, ok := e.(string); ok {
			names = append(names, s)
		}
	}
	sort.Strings(names)
	return names
}
