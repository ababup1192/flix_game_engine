package snd

// 鳴りっぱなしの音（drone）を見つける: 1 本のチャンネルで、打ち直さず・高さを変えず・音量が残ったまま長く続く音。
// 離し忘れ（休みの小節で前の音を離さない・ループの継ぎ目を越えて最後の音が残る）は和音が変わっても一直線に鳴り、
// 耳鳴りのように聞こえる。検査の gate（drone）が snd.json の droneSeconds より長い物を、チャンネルと小節を付けて止める。

import (
	"fmt"
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/crmath"
)

// drone は鳴りっぱなしの音 1 つ（チャンネル・始まりの小節（頭から・ループの 2 周目は 1 周目に折る）・長さ・高さ）。
type drone struct {
	channel string
	bar     float64
	seconds float64
	hz      float64
}

func (d drone) String() string {
	return fmt.Sprintf("チャンネル %s の %.0f Hz が %.1f 小節目から %.1f 秒、打ち直さず高さも変えずに鳴り続ける（離し忘れ？ 休みは OFF・mus.rest で離す）",
		d.channel, d.hz, d.bar+1, d.seconds)
}

// droneMinVolume はこれより小さい音量（0〜1）は鳴っていないと見る。
const droneMinVolume = 0.05

// droneFloorSeconds は song が拾っておく短さの下限（gate の長さは snd.json の droneSeconds）。
const droneFloorSeconds = 4.0

// findDrones はチャンネルごとに一番長い「打ち直さず・高さが同じ・音量が残る」続きを返す（minSeconds 以上の物だけ）。
func findDrones(s *song, frames [][]frame, used []int, bars []float64, minSeconds float64) []drone {
	var out []drone
	for _, c := range used {
		fs := frames[c]
		best := drone{}
		start := -1
		flush := func(end int) {
			if start < 0 {
				return
			}
			sec := float64(s.sampleAt(end)-s.sampleAt(start)) / float64(s.rate)
			if sec > best.seconds {
				best = drone{channel: s.chans[c].name, bar: bars[min(start, len(bars)-1)], seconds: sec,
					hz: 440 * math.Pow(2, (fs[start].pitch-69)/12)}
			}
			start = -1
		}
		for t, f := range fs {
			alive := f.volume >= droneMinVolume && s.chans[c].part != partNoise
			switch {
			case !alive || f.retrigger || (start >= 0 && f.pitch != fs[start].pitch):
				flush(t)
				if alive {
					start = t
				}
			case start < 0:
				start = t
			}
		}
		flush(len(fs))
		if best.seconds >= minSeconds {
			out = append(out, best)
		}
	}
	return out
}

// seamFadeMs は輪の終わりを 1 周目の終わりへ寄せる長さ（ミリ秒）。
const seamFadeMs = 40.0

// seamCrossfade は輪（2 周目）の終わりの seamFadeMs を、1 周目の終わり（end1 の手前）へ滑らかに寄せる。
// 輪の頭（2 周目の頭）の音は 1 周目の終わりから続いて鳴らした物なので、こうすると継ぎ目で、継ぎ目をまたいで
// 伸ばした音の位相も響きの尾もそろう（2 周目の終わりと 1 周目の終わりは同じ譜面なので、違うのは位相と尾だけ）。
func seamCrossfade(left, right []float64, end1, end2, rate int) {
	n := int(seamFadeMs * float64(rate) / 1000)
	if end1-n < 0 || end2 > len(left) || end2-n < end1 {
		return
	}
	for i := 0; i < n; i++ {
		w := 0.5 - float64(0.5*crmath.Cos(float64(math.Pi*float64(i+1))/float64(n))) // 0 → 1（最後のサンプルで 1 周目の値そのもの）
		for _, x := range [][]float64{left, right} {
			a, b := x[end2-n+i], x[end1-n+i]
			x[end2-n+i] = a + float64(w*(b-a))
		}
	}
}
