package main

// images — git に入れる絵が増えすぎていないか見張るゲート。

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

var imageExts = []string{".png", ".gif", ".jpg", ".jpeg", ".webp", ".bmp"}

const (
	galleryMaxFiles      = 20
	galleryMaxFileBytes  = 300 * 1024
	galleryMaxTotalBytes = 4 * 1024 * 1024
	trackedMaxTotalBytes = 8 * 1024 * 1024
)

// "assets/" はゲームのリポ直下の assets/（素材の置き場）。"/assets/" だけだと直下に当たらない。
var allowedPrefixes = []string{"docs/gallery/", "docs/brand/", "assets/"}
var allowedSubstrings = []string{"/assets/"}
var allowedSuffixes = []string{"/reference/title.png"}
var allowedExact = []string{"reference/title.png"}

func human(n int64) string {
	if n >= 1024*1024 {
		return fmt.Sprintf("%.1fMB", float64(n)/1024/1024)
	}
	return fmt.Sprintf("%.0fKB", float64(n)/1024)
}

func trackedImages(root string) ([]string, error) {
	cmd := exec.Command("git", "-C", root, "ls-files", "-z")
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	var paths []string
	for _, p := range strings.Split(string(out), "\x00") {
		if pxlib.InTestdata(p) {
			continue
		}
		low := strings.ToLower(p)
		for _, ext := range imageExts {
			if strings.HasSuffix(low, ext) {
				paths = append(paths, p)
				break
			}
		}
	}
	sort.Strings(paths)
	return paths, nil
}

func imageAllowed(path string) bool {
	for _, p := range allowedPrefixes {
		if strings.HasPrefix(path, p) {
			return true
		}
	}
	for _, s := range allowedSuffixes {
		if strings.HasSuffix(path, s) {
			return true
		}
	}
	for _, e := range allowedExact {
		if path == e {
			return true
		}
	}
	for _, s := range allowedSubstrings {
		if strings.Contains(path, s) {
			return true
		}
	}
	return false
}

// imagesResult は --json 用のまとめ。
type imagesResult struct {
	Problems     []string `json:"problems"`
	Tracked      int      `json:"tracked"`
	TrackedBytes int64    `json:"trackedBytes"`
	Gallery      int      `json:"gallery"`
	GalleryBytes int64    `json:"galleryBytes"`
	Exit         int      `json:"exit"`
}

func runImages(out *strings.Builder, root string, asJSON bool) int {
	var problems []string
	paths, err := trackedImages(root)
	if err != nil {
		fmt.Fprintf(out, "git ls-files が失敗しました: %s\n", err)
		return 1
	}
	sizes := map[string]int64{}
	for _, p := range paths {
		if info, err := os.Stat(filepath.Join(root, p)); err == nil {
			sizes[p] = info.Size()
		}
	}

	for _, p := range paths {
		if !imageAllowed(p) {
			problems = append(problems, fmt.Sprintf(
				"%s (%s) — 追跡してよい置き場ではありません。"+
					"人に見せる絵なら docs/gallery/ へ移してください", p, human(sizes[p])))
		}
	}

	var gallery []string
	var total int64
	for _, p := range paths {
		if strings.HasPrefix(p, "docs/gallery/") {
			gallery = append(gallery, p)
			total += sizes[p]
		}
	}
	if len(gallery) > galleryMaxFiles {
		problems = append(problems, fmt.Sprintf(
			"docs/gallery/ が %d 枚 — 上限 %d 枚。古いものを落としてください",
			len(gallery), galleryMaxFiles))
	}
	for _, p := range gallery {
		if sizes[p] > galleryMaxFileBytes {
			problems = append(problems, fmt.Sprintf(
				"%s が %s — 1 枚の上限 %s。"+
					"寸法を整数分の 1 に縮めてください (docs/gallery/README.md)",
				p, human(sizes[p]), human(galleryMaxFileBytes)))
		}
	}
	if total > galleryMaxTotalBytes {
		problems = append(problems, fmt.Sprintf(
			"docs/gallery/ の合計が %s — 上限 %s", human(total), human(galleryMaxTotalBytes)))
	}

	var grand int64
	for _, v := range sizes {
		grand += v
	}
	if grand > trackedMaxTotalBytes {
		problems = append(problems, fmt.Sprintf(
			"追跡している絵の合計が %s — 上限 %s。"+
				"生成した絵が紛れ込んでいないか git ls-files で確かめてください",
			human(grand), human(trackedMaxTotalBytes)))
	}

	exit := 0
	if len(problems) > 0 {
		exit = 1
	}
	if asJSON {
		emitJSON(out, imagesResult{orEmpty(problems), len(paths), grand, len(gallery), total, exit})
		return exit
	}
	if exit == 1 {
		fmt.Fprintf(out, "[lint-images] %d 件:\n", len(problems))
		for _, m := range problems {
			fmt.Fprintf(out, "  %s\n", m)
		}
		return 1
	}
	fmt.Fprintf(out, "[lint-images] OK — 追跡 %d 枚 / %s (展示場 docs/gallery/ は %d 枚 / %s)\n",
		len(paths), human(grand), len(gallery), human(total))
	return 0
}
