package hooks

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// gameDir は assets/ と atelier/ を持つ小さなゲームの作業場を作る。
func gameDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, d := range []string{"assets/sfx", "atelier", "src"} {
		if err := os.MkdirAll(filepath.Join(dir, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func runAsset(t *testing.T, root string, v any) (int, string) {
	t.Helper()
	var e strings.Builder
	code := RunAssetGuard(&e, root, repoRoot(), payloadOf(t, v))
	return code, e.String()
}

func runRead(t *testing.T, root string, v any) (int, string) {
	t.Helper()
	var e strings.Builder
	code := RunReadGuard(&e, root, repoRoot(), payloadOf(t, v))
	return code, e.String()
}

func writeInput(path string) map[string]any {
	return map[string]any{"tool_name": "Write", "tool_input": map[string]any{"file_path": path, "content": "{}"}}
}

// 素材のスロットへの書き込みは止め、atelier/ の同じ相対パスを返す。
func TestAssetGuardBlocksSprite(t *testing.T) {
	dir := gameDir(t)
	code, msg := runAsset(t, dir, writeInput(filepath.Join(dir, "assets", "x.sprite.json")))
	if code != 2 || !strings.Contains(msg, "atelier/x.sprite.json") {
		t.Errorf("code=%d msg=%q", code, msg)
	}
}

// 下のフォルダも atelier/ 側へ写して返す（archive の積み方と同じ形）。
func TestAssetGuardKeepsSubdir(t *testing.T) {
	dir := gameDir(t)
	_, msg := runAsset(t, dir, writeInput(filepath.Join(dir, "assets", "sfx", "hit.wav")))
	if !strings.Contains(msg, "atelier/sfx/hit.wav") {
		t.Errorf("msg=%q", msg)
	}
}

// 調整の Doc（*.cue.json など）は止めない。
func TestAssetGuardLetsTuningDocThrough(t *testing.T) {
	dir := gameDir(t)
	if code, msg := runAsset(t, dir, writeInput(filepath.Join(dir, "assets", "g.cue.json"))); code != 0 {
		t.Errorf("code=%d msg=%q", code, msg)
	}
}

// atelier/ への書き込みは止めない。
func TestAssetGuardLetsAtelierThrough(t *testing.T) {
	dir := gameDir(t)
	if code, _ := runAsset(t, dir, writeInput(filepath.Join(dir, "atelier", "x.sprite.json"))); code != 0 {
		t.Errorf("code=%d", code)
	}
}

// atelier/ を持たないリポジトリ（エンジンの templates など）は対象外。
func TestAssetGuardSkipsRepoWithoutAtelier(t *testing.T) {
	dir := t.TempDir()
	if code, _ := runAsset(t, dir, writeInput(filepath.Join(dir, "assets", "x.png"))); code != 0 {
		t.Errorf("code=%d", code)
	}
}

// apply_patch の相対パスも見る。
func TestAssetGuardReadsPatch(t *testing.T) {
	dir := gameDir(t)
	v := map[string]any{"cwd": dir, "tool_input": map[string]any{"command": "*** Begin Patch\n*** Add File: assets/a.chip.json\n+{}\n*** End Patch\n"}}
	if code, _ := runAsset(t, dir, v); code != 2 {
		t.Errorf("code=%d", code)
	}
}

func flixOf(t *testing.T, dir string, lines int) string {
	t.Helper()
	path := filepath.Join(dir, "src", "A.flix")
	if err := os.WriteFile(path, []byte(strings.Repeat("x\n", lines)), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func maxLines(t *testing.T) int { return load(t).ReadGuard.MaxLines }

// 大きな .flix を範囲なしで Read するのは止める。
func TestReadGuardBlocksWholeRead(t *testing.T) {
	dir := gameDir(t)
	path := flixOf(t, dir, maxLines(t)+1)
	v := map[string]any{"tool_name": "Read", "tool_input": map[string]any{"file_path": path}}
	if code, _ := runRead(t, dir, v); code != 2 {
		t.Errorf("code=%d", code)
	}
}

// limit があれば通す。
func TestReadGuardLetsRangedReadThrough(t *testing.T) {
	dir := gameDir(t)
	path := flixOf(t, dir, maxLines(t)+1)
	v := map[string]any{"tool_name": "Read", "tool_input": map[string]any{"file_path": path, "limit": 50}}
	if code, _ := runRead(t, dir, v); code != 0 {
		t.Errorf("code=%d", code)
	}
}

// 線を超えない小さなファイルは通す。
func TestReadGuardLetsSmallFileThrough(t *testing.T) {
	dir := gameDir(t)
	path := flixOf(t, dir, maxLines(t))
	v := map[string]any{"tool_name": "Read", "tool_input": map[string]any{"file_path": path}}
	if code, _ := runRead(t, dir, v); code != 0 {
		t.Errorf("code=%d", code)
	}
}

// Bash の `cat x.flix` は止める。
func TestReadGuardBlocksCat(t *testing.T) {
	dir := gameDir(t)
	flixOf(t, dir, maxLines(t)+1)
	v := map[string]any{"cwd": dir, "tool_name": "Bash", "tool_input": map[string]any{"command": "cd x && cat src/A.flix"}}
	if code, _ := runRead(t, dir, v); code != 2 {
		t.Errorf("code=%d", code)
	}
}

// パイプ・リダイレクト・sed -n は拾わない。
func TestWholeCatTargetsSkipsPipes(t *testing.T) {
	for _, cmd := range []string{"cat a.flix | grep x", "cat a.flix > b", "sed -n '1,9p' a.flix", "make check || cat a.flix | head"} {
		if got := WholeCatTargets(cmd, []string{"cat"}); len(got) != 0 {
			t.Errorf("%q → %v", cmd, got)
		}
	}
}

func bashInput(cmd string) map[string]any {
	return map[string]any{"tool_name": "Bash", "tool_input": map[string]any{"command": cmd}}
}

// Bash で素材を書き込む形は止める（breaktest で sed -i と python の open(.., 'w') で抜けた）。
func TestAssetGuardBlocksBashWrites(t *testing.T) {
	dir := gameDir(t)
	for _, cmd := range []string{
		`sed -i '' 's/a/b/' assets/x.sprite.json && git add assets/x.sprite.json`,
		"python3 -I - <<'EOF'\np='assets/x.sprite.json'\ns=open(p).read()\nopen(p,'w').write(s)\nEOF",
		`echo '{}' > assets/x.chip.json`,
		`cp /tmp/a.png ./assets/a.png`,
		`command cp atelier/a.wav assets/sfx/a.wav`,
		`sed -i.bak 's/a/b/' assets/x.sprite.json`,
		`perl -0pi -e 's/a/b/' assets/x.sprite.json`,
		`dd if=/tmp/a of=assets/a.png`,
		`cd assets && cp /tmp/a.png b.png`,
		`cp /tmp/a.png assets/`,
		`rsync -a atelier/ assets/`,
		`sed -i 's/a/b/' ` + filepath.Join(dir, "assets", "x.sprite.json"),
		`python3 -c "from pathlib import Path; Path('assets/x.png').write_bytes(b'')"`,
	} {
		if code, msg := runAsset(t, dir, bashInput(cmd)); code != 2 || !strings.Contains(msg, "atelier/") {
			t.Errorf("止まらなかった: %q → code=%d msg=%q", cmd, code, msg)
		}
	}
}

// 読むだけ・素材を読んで atelier/ へ書く・素材の外へ写す・パスを書かない生成スクリプト・調整の Doc は止めない。
func TestAssetGuardLetsBashReadsThrough(t *testing.T) {
	dir := gameDir(t)
	for _, cmd := range []string{
		`head -c 1500 assets/x.sprite.json && python3 -c "import json;print(json.load(open('assets/x.sprite.json')).keys())"`,
		`grep -n 'w' assets/x.sprite.json 2>/dev/null`,
		`cp assets/a.png /tmp/a.png`,
		`python3 bin/gen-puzzle-sprites.py`,
		`sed -i 's/1/2/' assets/g.cue.json`,
		`git add assets/x.sprite.json && git commit -m x`,
		"python3 - <<'EOF'\nimport json\nd=json.load(open('assets/x.sprite.json'))\njson.dump(d, open('atelier/x.sprite.json','w'))\nEOF",
		`python3 -c "from PIL import Image; Image.open('assets/x.png').save('/tmp/a.png')"`,
		`tee -a /tmp/log < assets/x.png`,
		`cp -r assets/ /tmp/backup/`,
	} {
		if code, msg := runAsset(t, dir, bashInput(cmd)); code != 0 {
			t.Errorf("止めてしまった: %q → %q", cmd, msg)
		}
	}
}

// offset だけ・大きな limit は丸読みと同じなので止める。
func TestReadGuardBlocksWideRange(t *testing.T) {
	dir := gameDir(t)
	path := flixOf(t, dir, maxLines(t)+1)
	for _, in := range []map[string]any{
		{"file_path": path, "offset": 0},
		{"file_path": path, "offset": 1, "limit": 5000},
	} {
		v := map[string]any{"tool_name": "Read", "tool_input": in}
		if code, _ := runRead(t, dir, v); code != 2 {
			t.Errorf("止まらなかった: %v → code=%d", in, code)
		}
	}
}
