package main

import (
	"os"
	"path/filepath"
	"strings"
)

// embedShaderLibrary は記録（web/shader-variants.json）から 3D のシェーダーの字の表を作り（shader-bake）、
// 空の版の fge.web.ShaderLibraryData を表入りの class に差し替えた jar を dst に書く（fge.teavmfix.ShaderEmbed）。
// WhyNot: ブラウザで字を作らない — 字を作るコード（ShaderAst の木と printer・光の式の Codegen）が wasm に載り、表より大きい。
func embedShaderLibrary(c exportConfig, asmJar, src, dst string) *exportFailure {
	p, java := c.Paths, c.Java
	table := filepath.Join(p.Work, "shader-library.json")
	bakeLog := filepath.Join(p.Work, "shader-bake.log")
	cmdEnv := append(os.Environ(), "FGE_SHADER_BAKE_VARIANTS="+c.Shaders.Variants, "FGE_SHADER_BAKE_OUT="+table)
	if code := runLoggedWith(p.Work, bakeLog, false, cmdEnv, java, "-jar", p.ShaderBakeJar); code != 0 || !fileExists(table) {
		return exportFailf(1, "%s\nfge export-web: シェーダーの表を作れない（shader-bake・ログ %s）。\n  次: 上の行を読む（記録が壊れているなら web/shader-variants.json を消して make run で 3D の場面を通し直す）\n",
			tailFile(bakeLog, 20), bakeLog)
	}
	reportShaderLine(bakeLog, "shader-bake", "  シェーダーの表 %s 本（%s 字）")
	embedLog := filepath.Join(p.Work, "shader-embed.log")
	cp := strings.Join([]string{asmJar, p.WebToolsJar}, string(os.PathListSeparator))
	if code := runLogged(p.Work, embedLog, false, java, "-cp", cp, "fge.teavmfix.ShaderEmbed", src, dst, table); code != 0 || !fileExists(dst) {
		return exportFailf(1, "%s\nfge export-web: シェーダーの表を埋め込めない（fge.teavmfix.ShaderEmbed・ログ %s）。\n  次: ShaderLibraryData が無いと言うなら engine の根で make sync-engine-full-web を流して fge-web と fge-web-tools を作り直す\n",
			tailFile(embedLog, 20), embedLog)
	}
	return nil
}

// reportShaderLine は log の `<head> <本数> <字の数>` の行を format で 1 行知らせる。
func reportShaderLine(log, head, format string) {
	text, _ := os.ReadFile(log)
	for _, line := range strings.Split(string(text), "\n") {
		f := strings.Fields(line)
		if len(f) == 3 && f[0] == head {
			ewLogf(format, f[1], f[2])
		}
	}
}
