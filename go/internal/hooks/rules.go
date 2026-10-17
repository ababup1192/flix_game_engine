package hooks

// 規約データ (bin/lint-rules/hooks.json) の読み込み。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// RulesPath は規約データの置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "hooks.json")

// MaxDaemons は常駐の数の上限の決め方。
// WhyNot: 起動予約と常駐本体で別々に持たないのは、機械を変えたとき片方だけ
// 古い値が残り、歯止めの数と実際に立つ数が食い違うため。
type MaxDaemons struct {
	GBPerDaemon *float64 `json:"gbPerDaemon"`
	Cap         *int     `json:"cap"`
	Fallback    *int     `json:"fallback"`
	EnvVar      *string  `json:"envVar"`
}

// RSSLimit は repl 1 本を使い捨てるメモリの線の決め方。
type RSSLimit struct {
	MemoryShare *float64 `json:"memoryShare"`
	MinMB       *int     `json:"minMB"`
	MaxMB       *int     `json:"maxMB"`
	FallbackMB  *int     `json:"fallbackMB"`
	FloorMB     *int     `json:"floorMB"`
	EnvVar      *string  `json:"envVar"`
}

// CheckdDaemon は常駐そのものの寿命と使い捨ての条件。
type CheckdDaemon struct {
	HeapHeadroomMB    *int     `json:"heapHeadroomMB"`
	HeapMinMB         *int     `json:"heapMinMB"`
	IdleSec           *float64 `json:"idleSec"`
	IdleEnvVar        *string  `json:"idleEnvVar"`
	MaxChecks         *int     `json:"maxChecks"`
	SettleSec         *float64 `json:"settleSec"`
	WorkTimeoutSec    *float64 `json:"workTimeoutSec"`
	WarmTimeoutSec    *float64 `json:"warmTimeoutSec"`
	SpawnWaitSec      *float64 `json:"spawnWaitSec"`
	ConnectTimeoutSec *float64 `json:"connectTimeoutSec"`
	ConvTimeoutSec    *float64 `json:"convTimeoutSec"`
	RSSLimit          RSSLimit `json:"rssLimit"`
	SkipDirs          []string `json:"skipDirs"`
	DepSuffixes       []string `json:"depSuffixes"`
}

// Checkd は常駐との話し方と、起動予約の歯止め。
type Checkd struct {
	CacheDir             *string      `json:"cacheDir"`
	StateHashLen         *int         `json:"stateHashLen"`
	PkgSearchDepth       *int         `json:"pkgSearchDepth"`
	PingTimeoutSec       *float64     `json:"pingTimeoutSec"`
	CheckTimeoutSec      *float64     `json:"checkTimeoutSec"`
	GitTimeoutSec        *float64     `json:"gitTimeoutSec"`
	ReserveIntervalSec   *float64     `json:"reserveIntervalSec"`
	MarkerTTLSec         *float64     `json:"markerTtlSec"`
	ErrorBlockMaxLines   *int         `json:"errorBlockMaxLines"`
	TailLinesWhenNoBlock *int         `json:"tailLinesWhenNoBlock"`
	MaxDaemons           MaxDaemons   `json:"maxDaemons"`
	Daemon               CheckdDaemon `json:"daemon"`
	PatchFilePrefixes    []string     `json:"patchFilePrefixes"`
	CommentOnlyPrefixes  []string     `json:"commentOnlyPrefixes"`
	CommentMark          *string      `json:"commentMark"`
}

// ArtCheck は「この拡張子を書いたらこの検査」の 1 行。
type ArtCheck struct {
	Suffix string   `json:"suffix"`
	Sub    string   `json:"sub"`
	Args   []string `json:"args"`
	Prefix string   `json:"prefix"`
}

// ArtRemind は「絵を描く View を書いたら、セッションに 1 回だけ絵の決まりを指す」の設定。
// rules の drawing.md は絵の Doc にしか当たらないので、View の .flix からはこの 1 行が入口になる。
type ArtRemind struct {
	Suffix       string `json:"suffix"`
	Pattern      string `json:"pattern"`
	MinHits      int    `json:"minHits"`
	MarkerPrefix string `json:"markerPrefix"`
	Message      string `json:"message"`
}

// ArtEdit は絵に関わるファイルを書いた直後の検査。
type ArtEdit struct {
	Checks []ArtCheck `json:"checks"`
	Remind ArtRemind  `json:"remind"`
}

// AssetGuard は「ゲームの assets/ の素材へエージェントが直に書くのを止める」設定（hook-asset-guard）。
type AssetGuard struct {
	AssetsDir  string   `json:"assetsDir"`
	AtelierDir string   `json:"atelierDir"`
	Suffixes   []string `json:"suffixes"`
	Message    string   `json:"message"`
	// Bash の呼び出しで素材を書く形（BashWriteTargets が使う）。
	BashInPlace []string `json:"bashInPlace"`
	BashCopy    []string `json:"bashCopy"`
}

// ReadGuard は「大きな .flix の丸読みを止める」設定（hook-read-guard）。
type ReadGuard struct {
	Suffix      string   `json:"suffix"`
	MaxLines    int      `json:"maxLines"`
	CatCommands []string `json:"catCommands"`
	Message     string   `json:"message"`
}

// Rules はフックが使う規約。すべて JSON から来る。
// AssetGuard・ReadGuard は LoadRules では必須にしない（古い hooks.json のゲームで
// ほかのフックまで止めないため）。欠けていれば各フックが読み直し先を探す（LoadGuardRules）。
type Rules struct {
	Checkd     Checkd      `json:"checkd"`
	ArtEdit    ArtEdit     `json:"artEdit"`
	AssetGuard *AssetGuard `json:"assetGuard"`
	ReadGuard  *ReadGuard  `json:"readGuard"`
}

// LoadRules は規約データを読む。
// WhyNot: 読めないときに既定値へ倒さないのは、規約ファイルを消しただけで
// 閾値や常駐の歯止めが別物に化けたまま黙って走るため。
func LoadRules(root string) (*Rules, error) {
	path := filepath.Join(root, RulesPath)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("規約ファイルを読めません: %v", err)
	}
	var r Rules
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("規約ファイルが JSON として壊れています (%s): %v", path, err)
	}
	cd := r.Checkd
	// warmTimeoutSec は 2026-08-30 に足した新キー。欠けキーで止める方針の例外として
	// 1 リリースの間だけ既定値へフォールバックする — 古い hooks.json + 新バイナリの
	// 組み合わせ (バイナリだけ部分更新した clone) との後方互換のため。次のリリースで
	// 必須キーへ昇格させ、この既定値を消す。
	if cd.Daemon.WarmTimeoutSec == nil {
		v := 240.0
		cd.Daemon.WarmTimeoutSec = &v
		r.Checkd = cd
	}
	missing := ""
	switch {
	case cd.CacheDir == nil:
		missing = "checkd.cacheDir"
	case cd.StateHashLen == nil:
		missing = "checkd.stateHashLen"
	case cd.PkgSearchDepth == nil:
		missing = "checkd.pkgSearchDepth"
	case cd.PingTimeoutSec == nil:
		missing = "checkd.pingTimeoutSec"
	case cd.CheckTimeoutSec == nil:
		missing = "checkd.checkTimeoutSec"
	case cd.GitTimeoutSec == nil:
		missing = "checkd.gitTimeoutSec"
	case cd.ReserveIntervalSec == nil:
		missing = "checkd.reserveIntervalSec"
	case cd.MarkerTTLSec == nil:
		missing = "checkd.markerTtlSec"
	case cd.ErrorBlockMaxLines == nil:
		missing = "checkd.errorBlockMaxLines"
	case cd.TailLinesWhenNoBlock == nil:
		missing = "checkd.tailLinesWhenNoBlock"
	case cd.MaxDaemons.GBPerDaemon == nil:
		missing = "checkd.maxDaemons.gbPerDaemon"
	case cd.MaxDaemons.Cap == nil:
		missing = "checkd.maxDaemons.cap"
	case cd.MaxDaemons.Fallback == nil:
		missing = "checkd.maxDaemons.fallback"
	case cd.MaxDaemons.EnvVar == nil:
		missing = "checkd.maxDaemons.envVar"
	case cd.Daemon.HeapHeadroomMB == nil:
		missing = "checkd.daemon.heapHeadroomMB"
	case cd.Daemon.HeapMinMB == nil:
		missing = "checkd.daemon.heapMinMB"
	case cd.Daemon.IdleSec == nil:
		missing = "checkd.daemon.idleSec"
	case cd.Daemon.IdleEnvVar == nil:
		missing = "checkd.daemon.idleEnvVar"
	case cd.Daemon.MaxChecks == nil:
		missing = "checkd.daemon.maxChecks"
	case cd.Daemon.SettleSec == nil:
		missing = "checkd.daemon.settleSec"
	case cd.Daemon.WorkTimeoutSec == nil:
		missing = "checkd.daemon.workTimeoutSec"
	case cd.Daemon.SpawnWaitSec == nil:
		missing = "checkd.daemon.spawnWaitSec"
	case cd.Daemon.ConnectTimeoutSec == nil:
		missing = "checkd.daemon.connectTimeoutSec"
	case cd.Daemon.ConvTimeoutSec == nil:
		missing = "checkd.daemon.convTimeoutSec"
	case cd.Daemon.RSSLimit.MemoryShare == nil:
		missing = "checkd.daemon.rssLimit.memoryShare"
	case cd.Daemon.RSSLimit.MinMB == nil:
		missing = "checkd.daemon.rssLimit.minMB"
	case cd.Daemon.RSSLimit.MaxMB == nil:
		missing = "checkd.daemon.rssLimit.maxMB"
	case cd.Daemon.RSSLimit.FallbackMB == nil:
		missing = "checkd.daemon.rssLimit.fallbackMB"
	case cd.Daemon.RSSLimit.FloorMB == nil:
		missing = "checkd.daemon.rssLimit.floorMB"
	case cd.Daemon.RSSLimit.EnvVar == nil:
		missing = "checkd.daemon.rssLimit.envVar"
	case len(cd.Daemon.SkipDirs) == 0:
		missing = "checkd.daemon.skipDirs"
	case len(cd.Daemon.DepSuffixes) == 0:
		missing = "checkd.daemon.depSuffixes"
	case len(cd.PatchFilePrefixes) == 0:
		missing = "checkd.patchFilePrefixes"
	case len(cd.CommentOnlyPrefixes) == 0:
		missing = "checkd.commentOnlyPrefixes"
	case cd.CommentMark == nil:
		missing = "checkd.commentMark"
	case len(r.ArtEdit.Checks) == 0:
		missing = "artEdit.checks"
	case r.ArtEdit.Remind.Suffix == "" || r.ArtEdit.Remind.Pattern == "" ||
		r.ArtEdit.Remind.MinHits <= 0 || r.ArtEdit.Remind.MarkerPrefix == "" || r.ArtEdit.Remind.Message == "":
		missing = "artEdit.remind (suffix・pattern・minHits・markerPrefix・message)"
	}
	if missing != "" {
		return nil, fmt.Errorf("規約ファイルに %s がありません (%s)", missing, path)
	}
	for i, c := range r.ArtEdit.Checks {
		if c.Suffix == "" || c.Sub == "" {
			return nil, fmt.Errorf("artEdit.checks[%d] に suffix か sub がありません (%s)", i, path)
		}
	}
	return &r, nil
}
