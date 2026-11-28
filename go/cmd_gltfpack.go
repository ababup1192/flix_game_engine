package main

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/gltfpack"
)

func init() {
	register("gltf-pack",
		"glTF 一式（.gltf と隣の .bin・画像）を 1 つの .glb にまとめる（engine は .glb に埋めた物だけ読む）。gltf-pack <in.gltf> [-o out.glb]",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			return runGltfPack(out, errOut, rest)
		})
}

func runGltfPack(out, errOut *strings.Builder, rest []string) int {
	src, dst := "", ""
	for i := 0; i < len(rest); i++ {
		switch {
		case rest[i] == "-o" && i+1 < len(rest):
			dst = rest[i+1]
			i++
		case src == "" && !strings.HasPrefix(rest[i], "-"):
			src = rest[i]
		default:
			fmt.Fprintf(errOut, "gltf-pack: 分からない引数 %q\n使い方: bin/fge gltf-pack <in.gltf> [-o out.glb]\n", rest[i])
			return 2
		}
	}
	if src == "" {
		fmt.Fprintln(errOut, "使い方: bin/fge gltf-pack <in.gltf> [-o out.glb]")
		return 2
	}
	if dst == "" {
		dst = strings.TrimSuffix(src, filepath.Ext(src)) + ".glb"
	}
	res, err := gltfpack.PackFile(src, dst)
	if err != nil {
		fmt.Fprintf(errOut, "gltf-pack: %v\n", err)
		return 1
	}
	fmt.Fprintf(out, "%s: buffer %d 本・画像 %d 枚を埋めた（BIN %d バイト）\n", dst, res.Buffers, res.Images, res.BinBytes)
	if len(res.ExtensionsUsed) > 0 {
		fmt.Fprintf(out, "extensionsUsed: %s（engine が読む拡張かは docs/scene3d.md）\n", strings.Join(res.ExtensionsUsed, ", "))
	}
	return 0
}
