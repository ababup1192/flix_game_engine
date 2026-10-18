package snd

// snd の code の表（checkres に載せる）。code は snd.<検査>[.<測り方>]（finding.code）。
// 表に無い code の結果は result で panic する（テストが止める）。docs/check-codes.md はこの表から書き出す。

import (
	"github.com/ababup1192/flix_game_engine/go/internal/checklevel"
	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

var sndCodes = []checkres.Code{
	{Name: "snd.style.op", Level: checklevel.Gate, Metric: "outside_ops", Unit: "count", Op: checkres.AtMost, Rule: "snd.json styles.ops", Summary: "機種の外の op"},
	{Name: "snd.style.duty", Level: checklevel.Gate, Metric: "outside_duty", Unit: "count", Op: checkres.AtMost, Rule: "snd.json styles.duties", Summary: "パルスの duty が機種の外"},
	{Name: "snd.style.noise-kind", Level: checklevel.Gate, Metric: "outside_kind", Unit: "count", Op: checkres.AtMost, Rule: "snd.json styles.noiseKinds", Summary: "雑音の作り方が機種の外"},
	{Name: "snd.style.break", Level: checklevel.Gate, Metric: "outside_breaks", Unit: "count", Op: checkres.AtMost, Rule: "snd.json styles.breaks", Summary: "破ってよい所（breaks）の外の手"},
	{Name: "snd.style.voices", Level: checklevel.Gate, Metric: "voices", Unit: "count", Op: checkres.AtMost, Rule: "snd.json styles.voices", Summary: "部品ごとに同時に鳴らす声の数"},
	{Name: "snd.drone", Level: checklevel.Gate, Metric: "held_s", Unit: "s", Op: checkres.AtMost, Rule: "snd.json droneSeconds", Summary: "song の 1 本のチャンネルが打ち直さず高さも変えずに鳴る長さ（離し忘れ）"},
	{Name: "snd.breaks", Level: checklevel.Advice, Metric: "breaks", Unit: "count", Op: checkres.AtMost, Summary: "使った機種の外の手（style が許す物。破った所として残す）"},
	{Name: "snd.clip", Level: checklevel.Gate, Metric: "over_samples", Unit: "count", Op: checkres.AtMost, Summary: "±1 を超えた・song の仕上げで切ったサンプル"},
	{Name: "snd.seam.step", Level: checklevel.Gate, Metric: "seam_step", Unit: "amp", Op: checkres.AtMost, Rule: "snd.json seamStepRatio", Summary: "ループの継ぎ目（終わり → 頭）の段差"},
	{Name: "snd.seam.level", Level: checklevel.Gate, Metric: "seam_level_diff", Unit: "dB", Op: checkres.AtMost, Rule: "snd.json seamLevelDb", Summary: "継ぎ目の前後 20ms の音量の差"},
	{Name: "snd.bars", Level: checklevel.Gate, Metric: "bar_off", Unit: "samples", Op: checkres.AtMost, Rule: "snd.json barTolerance", Summary: "輪の長さと tempo の整数小節の差"},
	{Name: "snd.loudness", Level: checklevel.Lint, Metric: "integrated", Unit: "LUFS", Op: checkres.InRange, Rule: "snd.json loudness", Summary: "統合ラウドネス（ループする音は輪の 1 周）"},
	{Name: "snd.peak", Level: checklevel.Lint, Metric: "sample_peak", Unit: "dBFS", Op: checkres.AtMost, Rule: "snd.json peakDbfs", Summary: "サンプルのピーク"},
	{Name: "snd.truepeak", Level: checklevel.Lint, Metric: "true_peak", Unit: "dBTP", Op: checkres.AtMost, Rule: "snd.json truePeakDbtp", Summary: "4 倍に読み直したピーク"},
	{Name: "snd.head", Level: checklevel.Lint, Metric: "onset_ms", Unit: "ms", Op: checkres.AtMost, Rule: "snd.json headSilenceMs", Summary: "鳴り出しの遅れ（ループしない音）"},
	{Name: "snd.tail", Level: checklevel.Lint, Metric: "last_sample", Unit: "amp", Op: checkres.AtMost, Rule: "snd.json tailClick", Summary: "終わりのサンプルの大きさ（0 へ戻らずプツと鳴る）"},
	{Name: "snd.dc", Level: checklevel.Lint, Metric: "mean", Unit: "amp", Op: checkres.AtMost, Rule: "snd.json dc", Summary: "直流（平均の大きさ）"},
	{Name: "snd.alias", Level: checklevel.Advice, Metric: "third_harmonic_hz", Unit: "Hz", Op: checkres.AtMost, Summary: "パルスの 3 倍音とナイキスト周波数"},
}

func init() {
	for _, c := range sndCodes {
		checkres.Register(c)
	}
}
