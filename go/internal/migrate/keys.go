package migrate

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

// DrawHashFile は書き出したコマの隣にエンジンの VideoOut が書く鍵の表（「コマ番号 鍵」・鍵を作れないコマは -）。
const DrawHashFile = "drawhash.txt"

// noKey は鍵を作れなかったコマ（キャッシュを使わない・Pass のある鍵だけの回・鍵の無い記録）。
const noKey = "-"

// drawKeys は記録のコマの鍵を、層のフォルダの drawhash.txt から引く（同じフォルダは 1 回だけ読む）。
type drawKeys struct {
	mu   sync.Mutex
	dirs map[string]map[int]string
}

func newDrawKeys() *drawKeys { return &drawKeys{dirs: map[string]map[int]string{}} }

// of は tape.json のあるフォルダ tapeDir と frames[].file（frames/world/f0126.png）から鍵を引く。分からなければ noKey。
func (k *drawKeys) of(tapeDir, file string) string {
	n, ok := frameNumber(file)
	if !ok {
		return noKey
	}
	dir := filepath.Join(tapeDir, filepath.Dir(file))
	k.mu.Lock()
	table, seen := k.dirs[dir]
	if !seen {
		table = readDrawHash(filepath.Join(dir, DrawHashFile))
		k.dirs[dir] = table
	}
	k.mu.Unlock()
	if key, ok := table[n]; ok && validKey(key) {
		return key
	}
	return noKey
}

// frameNumber は f0126.png の 126。
func frameNumber(file string) (int, bool) {
	base := filepath.Base(file)
	digits, ok := strings.CutPrefix(strings.TrimSuffix(base, ".png"), "f")
	if !ok || digits == "" || !strings.HasSuffix(base, ".png") {
		return 0, false
	}
	n, err := strconv.Atoi(digits)
	return n, err == nil
}

// readDrawHash は drawhash.txt を読む（無ければ空）。
func readDrawHash(path string) map[int]string {
	data, err := os.ReadFile(path)
	if err != nil {
		return map[int]string{}
	}
	return parseDrawHash(string(data))
}

// parseDrawHash は drawhash.txt の中身（「コマ番号 鍵」の行）を読む。
func parseDrawHash(text string) map[int]string {
	out := map[int]string{}
	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) != 2 {
			continue
		}
		if n, err := strconv.Atoi(fields[0]); err == nil {
			out[n] = fields[1]
		}
	}
	return out
}

// validKey は鍵として突き合わせてよい字か（- と空と 1 字は鍵でない。置き場は頭の 2 字のフォルダに分ける）。
func validKey(key string) bool { return len(key) >= 2 && key != noKey }

// sameKey は前と後の鍵が同じで、画素を読まずに同じと言えるか（片方でも鍵が無ければ言えない）。
// 鍵が同じなら PNG は 1 バイトも違わない（DrawHash の約束）。
func sameKey(a, b string) bool { return validKey(a) && a == b }

// DiffCacheFile は比べた結果を覚えておく所（<new の親>/diff-cache.json）。
const DiffCacheFile = "diff-cache.json"

// diffCacheVersion は覚えた結果の形と比べ方の版。比べ方（comparePixels・blockP99）を変えたら上げる。
const diffCacheVersion = "migrate-diff-1"

// cachedStats は 1 組のコマを比べた数。線の内で通った組だけを使う（線を超えた組は差の色の図のために読み直す）。
type cachedStats struct {
	Mean   float64 `json:"mean"`
	Max    int     `json:"max"`
	Within float64 `json:"within"`
}

// diffCache は比べた結果を、前と後のコマの中身の名乗りと線引きで引けるように覚える。
// 書き出すのはこの回に引いたか足した物だけ（使わなくなった組は次の回に消える）。
type diffCache struct {
	path string
	mu   sync.Mutex
	old  map[string]cachedStats
	used map[string]cachedStats
}

func loadDiffCache(path string) *diffCache {
	c := &diffCache{path: path, old: map[string]cachedStats{}, used: map[string]cachedStats{}}
	if path == "" {
		return c
	}
	var file struct {
		Version string                 `json:"version"`
		Entries map[string]cachedStats `json:"entries"`
	}
	if data, err := os.ReadFile(path); err == nil && json.Unmarshal(data, &file) == nil && file.Version == diffCacheVersion && file.Entries != nil {
		c.old = file.Entries
	}
	return c
}

func (c *diffCache) get(key string) (cachedStats, bool) {
	if c == nil || key == "" {
		return cachedStats{}, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if s, ok := c.used[key]; ok {
		return s, true
	}
	s, ok := c.old[key]
	if ok {
		c.used[key] = s
	}
	return s, ok
}

func (c *diffCache) put(key string, s cachedStats) {
	if c == nil || key == "" {
		return
	}
	c.mu.Lock()
	c.used[key] = s
	c.mu.Unlock()
}

func (c *diffCache) save() error {
	if c == nil || c.path == "" {
		return nil
	}
	data, err := json.Marshal(map[string]any{"version": diffCacheVersion, "entries": c.used})
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(c.path), filepath.Base(c.path)+".*.part")
	if err != nil {
		return err
	}
	_, werr := f.Write(append(data, '\n'))
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr != nil {
		os.Remove(f.Name())
		return werr
	}
	return os.Rename(f.Name(), c.path)
}

// contentID はコマの中身の名乗り: 鍵があれば鍵、無ければ PNG のバイト列の SHA-256（読めなければ空）。
func contentID(key, path string) string {
	if validKey(key) {
		return "k:" + key
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)
	return "s:" + hex.EncodeToString(sum[:])
}

// cacheKey は覚えた結果を引く鍵。前と後の中身・線の種類（途中のコマ・3D の背景の休み・ずれを許す px と差の線）・
// 時刻のずれたコマか・重ねた後の線引き・比べ方の版のどれかが違えば別の鍵になる。中身を名乗れなければ空（覚えない）。
func cacheKey(idA, idB string, mid, still3d bool, delta, shift int, shifted bool, th Thresholds) string {
	if idA == "" || idB == "" {
		return ""
	}
	thJSON, _ := json.Marshal(th)
	sum := sha256.Sum256([]byte(fmt.Sprintf("%s|%s|%s|mid=%v|still3d=%v|delta=%d|shift=%d|shifted=%v|%s",
		diffCacheVersion, idA, idB, mid, still3d, delta, shift, shifted, thJSON)))
	return hex.EncodeToString(sum[:])
}
