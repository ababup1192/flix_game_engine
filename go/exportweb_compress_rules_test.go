package main

import (
	"encoding/json"
	"os"
	"slices"
	"strings"
	"testing"
)

func TestCwebpArgsLossyKeepsTransparentColors(t *testing.T) {
	if !slices.Contains(cwebpArgs("a.png", "a.webp", 80), "-exact") {
		t.Fatal("劣化ありの引数に -exact が無い")
	}
}

func TestCwebpArgsLosslessKeepsTransparentColors(t *testing.T) {
	args := cwebpArgs("a.png", "a.webp", 0)
	if !slices.Contains(args, "-exact") || !slices.Contains(args, "-lossless") {
		t.Fatalf("args = %v", args)
	}
}

// plannedImages は絵の道の並びから、変換を組んだ元の道を返す。
func plannedImages(t *testing.T, raw string, images []string) []string {
	t.Helper()
	c, err := resolveWebCompress(json.RawMessage(raw))
	if err != nil {
		t.Fatal(err)
	}
	jobs, _ := planWebImages(t.TempDir(), images, c, webEncoders{Cwebp: "cwebp"}, map[string]bool{})
	var rels []string
	for _, j := range jobs {
		rels = append(rels, j.rel)
	}
	return rels
}

func TestPlanWebImagesSkipsJpgWithoutLossyRule(t *testing.T) {
	got := plannedImages(t, `{}`, []string{"assets/a.jpg", "assets/b.png"})
	if !slices.Equal(got, []string{"assets/b.png"}) {
		t.Fatalf("got %v", got)
	}
}

func TestPlanWebImagesConvertsJpgMatchingLossyRule(t *testing.T) {
	got := plannedImages(t, `{"compress": {"lossyImages": [{"glob": "assets/*.jpg", "quality": 70}]}}`, []string{"assets/a.jpg"})
	if !slices.Equal(got, []string{"assets/a.jpg"}) {
		t.Fatalf("got %v", got)
	}
}

func TestPlanWebImagesConvertsSharedPathOnce(t *testing.T) {
	got := plannedImages(t, `{}`, []string{"assets/b.png", "assets/b.png"})
	if !slices.Equal(got, []string{"assets/b.png"}) {
		t.Fatalf("got %v", got)
	}
}

// 2 つの glob に当たる絵は先に書いた方の quality で詰める。
func TestPlanWebImagesFirstLossyRuleWins(t *testing.T) {
	c, _ := resolveWebCompress(json.RawMessage(`{"compress": {"lossyImages": [{"glob": "assets/*.png", "quality": 60}, {"glob": "assets/**", "quality": 90}]}}`))
	tool := fakeArgsTool(t)
	out, b, atlases := exportFixture(t)
	transcodeWebAssets(out, &b, atlases, c, webEncoders{Cwebp: tool})
	args, _ := os.ReadFile(tool + ".args")
	if !strings.Contains(string(args), "-q 60 ") {
		t.Fatalf("args = %q", args)
	}
}

// fakeArgsTool は受け取った引数を <道具>.args に書き、出力へ 1 バイトだけ書く道具。
func fakeArgsTool(t *testing.T) string {
	t.Helper()
	p := fakeToolSized(t, 1)
	script, _ := os.ReadFile(p)
	withArgs := strings.Replace(string(script), "#!/bin/sh\n", "#!/bin/sh\necho \"$@\" > \""+p+".args\"\n", 1)
	if err := os.WriteFile(p, []byte(withArgs), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestTranscodeSharedSoundPathSaysNothing(t *testing.T) {
	out, b, atlases := exportFixture(t)
	b.Sounds = append(b.Sounds, webSound{Name: "s2", Path: "assets/s.wav"})
	r := transcodeWebAssets(out, &b, atlases, defaultWebCompress(), webEncoders{FFmpeg: fakeToolSized(t, 10)})
	if strings.Contains(strings.Join(r.Notes, "\n"), "assets/s.wav") || b.Sounds[1].Seconds != 0.1 {
		t.Fatalf("notes = %v sounds = %+v", r.Notes, b.Sounds)
	}
}

func TestTranscodeSaysWhenUncompressedGlobMatchesNothing(t *testing.T) {
	out, b, atlases := exportFixture(t)
	c, _ := resolveWebCompress(json.RawMessage(`{"compress": {"uncompressedAudio": ["assets/bgm/**"]}}`))
	r := transcodeWebAssets(out, &b, atlases, c, webEncoders{})
	if !strings.Contains(strings.Join(r.Notes, "\n"), `"assets/bgm/**" に当たる音が無い`) {
		t.Fatalf("notes = %v", r.Notes)
	}
}
