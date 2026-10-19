// Package resident は窓なしのゲームの常駐（engine_world の App.Headless）へ入口を頼むクライアント。
//
// 境目（ファイル・HTTP の口・終了コード）は docs/design/render-speed.md の 2 節にある。
// 常駐を使えない時は 125 を返し、bin/headless-run が今までの java -jar で流す。
package resident

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
)

// Unusable は「常駐を使えなかった。素の道で流す」の終了コード。
const Unusable = 125

// Heap は常駐の JVM に付ける -Xmx の決め方。
type Heap struct {
	MemoryShare *float64 `json:"memoryShare"`
	MinMB       *int     `json:"minMB"`
	MaxMB       *int     `json:"maxMB"`
	FallbackMB  *int     `json:"fallbackMB"`
	EnvVar      *string  `json:"envVar"`
}

// Config は hooks.json の resident 節。
type Config struct {
	CacheDir          *string          `json:"cacheDir"`
	StateHashLen      *int             `json:"stateHashLen"`
	MaxDaemons        hooks.MaxDaemons `json:"maxDaemons"`
	Heap              Heap             `json:"heap"`
	ReadyWaitSec      *float64         `json:"readyWaitSec"`
	ConnectTimeoutSec *float64         `json:"connectTimeoutSec"`
	HelloTimeoutSec   *float64         `json:"helloTimeoutSec"`
	QuitWaitSec       *float64         `json:"quitWaitSec"`
	SilentSec         *float64         `json:"silentSec"`
	SilentEnvVar      *string          `json:"silentEnvVar"`
	EntryDefault      *string          `json:"entryDefault"`
	EntryEnvVar       *string          `json:"entryEnvVar"`
}

// LoadConfig は root/bin/lint-rules/hooks.json の resident 節を読む。
//
// WhyNot: 欠けたキーを既定値で埋めないのは、checkd と同じく、規約ファイルが古いだけで
// 数の上限やメモリの蓋が別物に化けたまま常駐が立つため。欠けていれば常駐を使わない。
func LoadConfig(root string) (*Config, error) {
	path := filepath.Join(root, hooks.RulesPath)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("規約ファイルを読めません: %v", err)
	}
	var whole struct {
		Resident *Config `json:"resident"`
	}
	if err := json.Unmarshal(data, &whole); err != nil {
		return nil, fmt.Errorf("規約ファイルが JSON として壊れています (%s): %v", path, err)
	}
	if whole.Resident == nil {
		return nil, fmt.Errorf("規約ファイルに resident がありません (%s)", path)
	}
	if missing := whole.Resident.missingKey(); missing != "" {
		return nil, fmt.Errorf("規約ファイルに resident.%s がありません (%s)", missing, path)
	}
	return whole.Resident, nil
}

func (c *Config) missingKey() string {
	switch {
	case c.CacheDir == nil:
		return "cacheDir"
	case c.StateHashLen == nil:
		return "stateHashLen"
	case c.MaxDaemons.GBPerDaemon == nil || c.MaxDaemons.Cap == nil || c.MaxDaemons.Fallback == nil || c.MaxDaemons.EnvVar == nil:
		return "maxDaemons (gbPerDaemon・cap・fallback・envVar)"
	case c.Heap.MemoryShare == nil || c.Heap.MinMB == nil || c.Heap.MaxMB == nil || c.Heap.FallbackMB == nil || c.Heap.EnvVar == nil:
		return "heap (memoryShare・minMB・maxMB・fallbackMB・envVar)"
	case c.ReadyWaitSec == nil:
		return "readyWaitSec"
	case c.ConnectTimeoutSec == nil:
		return "connectTimeoutSec"
	case c.HelloTimeoutSec == nil:
		return "helloTimeoutSec"
	case c.QuitWaitSec == nil:
		return "quitWaitSec"
	case c.SilentSec == nil || c.SilentEnvVar == nil:
		return "silentSec・silentEnvVar"
	case c.EntryDefault == nil || c.EntryEnvVar == nil:
		return "entryDefault・entryEnvVar"
	}
	return ""
}

// MaxResidents は全部の根を合わせた常駐の数の上限。
func (c *Config) MaxResidents() int { return hooks.CountDaemons(c.MaxDaemons) }

// HeapCapMB は常駐の JVM の -Xmx（MB）。
func (c *Config) HeapCapMB(env map[string]string) int {
	total, ok := hooks.MachineMemoryMB()
	return computeHeapMB(c.Heap, c.MaxResidents(), total, ok, env[*c.Heap.EnvVar])
}

// computeHeapMB は物理メモリ・上限の数・環境変数から -Xmx を決める。
//
// WhyNot: 数が 1 でも 2 で割るのは、1 本しか立てない小さい機械でその 1 本に予算を丸ごと
// 渡すと、素の道の JVM と並んだ時に他のアプリの居場所が無くなるため（checkd と同じ）。
func computeHeapMB(h Heap, residents int, totalMB int64, known bool, override string) int {
	if override != "" {
		if v, err := strconv.Atoi(override); err == nil && v > 0 {
			return v
		}
	}
	if !known {
		return *h.FallbackMB
	}
	if residents < 2 {
		residents = 2
	}
	mb := int(float64(totalMB) * *h.MemoryShare / float64(residents))
	if mb < *h.MinMB {
		mb = *h.MinMB
	}
	if mb > *h.MaxMB {
		mb = *h.MaxMB
	}
	return mb
}

// SilentLimit は出力の行が止まってから常駐を見限るまでの時間。
func (c *Config) SilentLimit(env map[string]string) time.Duration {
	v := *c.SilentSec
	if s := env[*c.SilentEnvVar]; s != "" {
		if parsed, err := strconv.ParseFloat(s, 64); err == nil && parsed > 0 {
			v = parsed
		}
	}
	return seconds(v)
}

// ResidentEntry は常駐として起こす入口の名前。
func (c *Config) ResidentEntry(env map[string]string) string {
	if v := env[*c.EntryEnvVar]; v != "" {
		return v
	}
	return *c.EntryDefault
}

func seconds(v float64) time.Duration { return time.Duration(v * float64(time.Second)) }
