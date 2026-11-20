package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func mustDeferredPolicy(t *testing.T, raw string) webDeferredPolicy {
	t.Helper()
	pol, err := resolveWebDeferredPolicy(json.RawMessage(raw))
	if err != nil {
		t.Fatal(err)
	}
	return pol
}

func policyFixtureEntries() []webDeferredEntry {
	return []webDeferredEntry{
		{Path: "font-atlas/gothic.fontatlas", Names: []string{"gothic"}},
		{Path: "assets/bg/gate.png", Names: []string{"bg_gate"}},
		{Path: "assets/bgm/sea.wav", Names: []string{"bgm_sea"}},
		{Path: "assets/walk/hall.glb"},
	}
}

func TestDeferredPolicyWithoutKeyLeavesEntries(t *testing.T) {
	b := deferredFixtureBundle()
	out, _, err := applyWebDeferredPolicy(policyFixtureEntries(), mustDeferredPolicy(t, `{"deferred": []}`), &b)
	if err != nil || out[1].OnMissing != "" || out[1].Group != "" {
		t.Errorf("行が無ければ何も書かないはず: %+v %v", out, err)
	}
}

func TestDeferredPolicyWritesGroupOfFirstMatchingRow(t *testing.T) {
	b := deferredFixtureBundle()
	pol := mustDeferredPolicy(t, `{"deferredPolicy": [{"match": "assets/bg/*.png", "group": "start"}, {"match": "assets/**", "group": "later"}]}`)
	out, _, err := applyWebDeferredPolicy(policyFixtureEntries(), pol, &b)
	if err != nil || out[1].Group != "start" {
		t.Errorf("先の行が勝つはず: %+v %v", out[1], err)
	}
}

func TestDeferredPolicyMatchesFontByName(t *testing.T) {
	b := deferredFixtureBundle()
	pol := mustDeferredPolicy(t, `{"deferredPolicy": [{"match": "font:gothic", "onMissing": "placeholder"}]}`)
	out, _, err := applyWebDeferredPolicy(policyFixtureEntries(), pol, &b)
	if err != nil || out[0].OnMissing != "placeholder" {
		t.Errorf("font: の行はフォントの名前で当たるはず: %+v %v", out[0], err)
	}
}

func TestDeferredPolicyRejectsSkipOnAPicture(t *testing.T) {
	b := deferredFixtureBundle()
	pol := mustDeferredPolicy(t, `{"deferredPolicy": [{"match": "assets/**", "onMissing": "skip"}]}`)
	_, _, err := applyWebDeferredPolicy(policyFixtureEntries(), pol, &b)
	if err == nil || !strings.Contains(err.Error(), "assets/bg/gate.png") {
		t.Errorf("絵に skip は使えないと道を挙げて止めるはず: %v", err)
	}
}

func TestDeferredPolicyAcceptsWaitOnMixedKinds(t *testing.T) {
	b := deferredFixtureBundle()
	pol := mustDeferredPolicy(t, `{"deferredPolicy": [{"match": "assets/**", "onMissing": "wait"}]}`)
	if _, _, err := applyWebDeferredPolicy(policyFixtureEntries(), pol, &b); err != nil {
		t.Errorf("wait はどの種類にも使えるはず: %v", err)
	}
}

func TestDeferredPolicyRejectsUnknownOnMissing(t *testing.T) {
	if _, err := resolveWebDeferredPolicy(json.RawMessage(`{"deferredPolicy": [{"match": "assets/**", "onMissing": "later"}]}`)); err == nil {
		t.Error("知らない onMissing は止めるはず")
	}
}

func TestDeferredPolicyWarnsOnRowMatchingNothing(t *testing.T) {
	b := deferredFixtureBundle()
	pol := mustDeferredPolicy(t, `{"deferredPolicy": [{"match": "assets/none/*.png", "group": "x"}]}`)
	_, warnings, err := applyWebDeferredPolicy(policyFixtureEntries(), pol, &b)
	if err != nil || len(warnings) != 1 {
		t.Errorf("当たらない行は 1 行知らせるはず: %v %v", warnings, err)
	}
}
