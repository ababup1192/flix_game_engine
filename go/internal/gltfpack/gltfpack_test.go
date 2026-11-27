package gltfpack

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var pngBytes = []byte("\x89PNG\r\n\x1a\nrest")

func unpack(t *testing.T, glb []byte) (map[string]any, []byte) {
	t.Helper()
	if binary.LittleEndian.Uint32(glb[0:]) != glbMagic || int(binary.LittleEndian.Uint32(glb[8:])) != len(glb) {
		t.Fatalf("GLB の頭が違う")
	}
	jl := int(binary.LittleEndian.Uint32(glb[12:]))
	var doc map[string]any
	if err := json.Unmarshal(glb[20:20+jl], &doc); err != nil {
		t.Fatal(err)
	}
	rest := glb[20+jl:]
	if len(rest) == 0 {
		return doc, nil
	}
	bl := int(binary.LittleEndian.Uint32(rest[0:]))
	return doc, rest[8 : 8+bl]
}

func viewBytes(doc map[string]any, bin []byte, i int) []byte {
	v := doc["bufferViews"].([]any)[i].(map[string]any)
	off, n := int(v["byteOffset"].(float64)), int(v["byteLength"].(float64))
	return bin[off : off+n]
}

func TestTwoBuffersAndImageEndUpInOneBin(t *testing.T) {
	src := `{"asset":{"version":"2.0"},"extensionsUsed":["KHR_texture_transform"],
	  "buffers":[{"uri":"a.bin","byteLength":3},{"uri":"b.bin","byteLength":2}],
	  "bufferViews":[{"buffer":0,"byteLength":3},{"buffer":1,"byteOffset":1,"byteLength":1}],
	  "images":[{"uri":"tex.png"}],"extras":{"keep":true}}`
	files := map[string][]byte{"a.bin": {1, 2, 3}, "b.bin": {8, 9}, "tex.png": pngBytes}
	glb, res, err := Pack([]byte(src), func(u string) ([]byte, error) {
		if d, ok := files[u]; ok {
			return d, nil
		}
		return nil, fmt.Errorf("no %s", u)
	})
	if err != nil {
		t.Fatal(err)
	}
	doc, bin := unpack(t, glb)
	got := fmt.Sprint(viewBytes(doc, bin, 0), viewBytes(doc, bin, 1), string(viewBytes(doc, bin, 2)),
		doc["images"].([]any)[0].(map[string]any)["mimeType"], len(doc["buffers"].([]any)), res.Images,
		doc["extras"].(map[string]any)["keep"], res.ExtensionsUsed)
	want := fmt.Sprint([]byte{1, 2, 3}, []byte{9}, string(pngBytes), "image/png", 1, 1, true, []string{"KHR_texture_transform"})
	if got != want {
		t.Fatalf("got %s want %s", got, want)
	}
}

func TestDataUriBufferIsDecoded(t *testing.T) {
	src := `{"asset":{"version":"2.0"},"buffers":[{"uri":"data:application/octet-stream;base64,AQID","byteLength":3}],
	  "bufferViews":[{"buffer":0,"byteLength":3}]}`
	glb, _, err := Pack([]byte(src), func(string) ([]byte, error) { return nil, fmt.Errorf("unused") })
	if err != nil {
		t.Fatal(err)
	}
	doc, bin := unpack(t, glb)
	if fmt.Sprint(viewBytes(doc, bin, 0)) != fmt.Sprint([]byte{1, 2, 3}) {
		t.Fatalf("got %v", viewBytes(doc, bin, 0))
	}
}

func TestUriOutsideTheFolderIsRefused(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "m.gltf")
	os.WriteFile(src, []byte(`{"asset":{"version":"2.0"},"buffers":[{"uri":"../secret.bin","byteLength":1}]}`), 0o644)
	_, err := PackFile(src, filepath.Join(dir, "m.glb"))
	if err == nil || !strings.Contains(err.Error(), "外") {
		t.Fatalf("err = %v", err)
	}
}

func TestShortBufferIsAnError(t *testing.T) {
	src := `{"asset":{"version":"2.0"},"buffers":[{"uri":"a.bin","byteLength":10}]}`
	_, _, err := Pack([]byte(src), func(string) ([]byte, error) { return []byte{1}, nil })
	if err == nil {
		t.Fatal("短い buffer を通した")
	}
}

func TestChunksAreFourByteAligned(t *testing.T) {
	src := `{"asset":{"version":"2.0"},"buffers":[{"uri":"a.bin","byteLength":1}],"bufferViews":[{"buffer":0,"byteLength":1}],"images":[{"uri":"t.png"}]}`
	files := map[string][]byte{"a.bin": {7}, "t.png": pngBytes}
	glb, _, _ := Pack([]byte(src), func(u string) ([]byte, error) { return files[u], nil })
	doc, bin := unpack(t, glb)
	off := int(doc["bufferViews"].([]any)[1].(map[string]any)["byteOffset"].(float64))
	if off%4 != 0 || len(bin)%4 != 0 || len(glb)%4 != 0 {
		t.Fatalf("off %d bin %d glb %d", off, len(bin), len(glb))
	}
}
