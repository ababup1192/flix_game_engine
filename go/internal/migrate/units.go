package migrate

import (
	"fmt"
	"sort"
)

// Unit は人に見せる単位。承認の無い、人が見る迷った差を、同じ (種類, ノード, 番号, 名前) なら flow をまたいで 1 つに、
// 続いたコマは 1 区間にまとめた物。From・To は代表の flow（差のいちばん多い物）の新しい版の秒（並べた動画と字幕の秒）。
type Unit struct {
	What   string   `json:"what"`
	Flow   string   `json:"flow"`
	Size   string   `json:"size"`
	Flows  []string `json:"flows"`
	From   float64  `json:"from"`
	To     float64  `json:"to"`
	Place  string   `json:"place"`
	Detail string   `json:"detail"`
	Diffs  []int    `json:"diffs"`
}

// buildUnits は r.Diffs から人に見せる単位を組む。
// WhyNot: 差を 1 件ずつ見せない — 同じ台本を流す flow（通しと抜き出し）は同じ所で同じ差を出し、揺れの続く場面は
// コマごとに差が出るので、人が同じ物を何十回も見る。
func buildUnits(r *Result) []Unit {
	var idx []int
	for i, d := range r.Diffs {
		if d.Review && d.Accepted == "" && r.needsEye(d) {
			idx = append(idx, i)
		}
	}
	parent := map[int]int{}
	var find func(int) int
	find = func(i int) int {
		if parent[i] == i {
			return i
		}
		parent[i] = find(parent[i])
		return parent[i]
	}
	union := func(i, j int) { parent[find(i)] = find(j) }
	for _, i := range idx {
		parent[i] = i
	}
	byKey := map[string]int{}
	byOrd := map[string]int{}
	for _, i := range idx {
		d := r.Diffs[i]
		if key := unitKey(d); key != "" {
			if j, ok := byKey[key]; ok {
				union(i, j)
			} else {
				byKey[key] = i
			}
		}
		if d.ord > 0 {
			byOrd[fmt.Sprintf("%s/%s/%d", d.Flow, d.Size, d.ord)] = i
		}
	}
	for _, i := range idx {
		d := r.Diffs[i]
		if d.ord <= 0 {
			continue
		}
		if j, ok := byOrd[fmt.Sprintf("%s/%s/%d", d.Flow, d.Size, d.ord+1)]; ok {
			union(i, j)
		}
	}
	groups := map[int][]int{}
	for _, i := range idx {
		groups[find(i)] = append(groups[find(i)], i)
	}
	units := make([]Unit, 0, len(groups))
	for _, members := range groups {
		units = append(units, makeUnit(r, members))
	}
	sort.SliceStable(units, func(i, j int) bool {
		if units[i].Flow != units[j].Flow {
			return units[i].Flow < units[j].Flow
		}
		if units[i].Size != units[j].Size {
			return units[i].Size < units[j].Size
		}
		return units[i].From < units[j].From
	})
	return units
}

// unitKey は flow をまたいでまとめる鍵（空ならまとめない）。新しい版にだけある物は id だけで 1 つ。
func unitKey(d *Diff) string {
	if d.What == WhatNewObject {
		return d.What + "|" + d.Subject
	}
	if d.Node == "" {
		return ""
	}
	return fmt.Sprintf("%s|%s#%d|%s|%s", d.What, d.Node, d.Seq, d.FrameKind, d.Subject)
}

func makeUnit(r *Result, members []int) Unit {
	sort.Ints(members)
	count := map[string]int{}
	var order []string
	for _, i := range members {
		d := r.Diffs[i]
		k := d.Flow + "/" + d.Size
		if count[k] == 0 {
			order = append(order, k)
		}
		count[k]++
	}
	best := order[0]
	for _, k := range order {
		if count[k] > count[best] {
			best = k
		}
	}
	sort.Strings(order)
	u := Unit{Flows: order, Diffs: members}
	var first, last *Diff
	for _, i := range members {
		d := r.Diffs[i]
		if d.Flow+"/"+d.Size != best {
			continue
		}
		if first == nil || d.T < first.T {
			first = d
		}
		if last == nil || d.T > last.T {
			last = d
		}
	}
	u.What, u.Flow, u.Size, u.From, u.To, u.Detail = first.What, first.Flow, first.Size, first.T, last.T, first.Detail
	u.Place = place(first)
	if p := place(last); p != u.Place {
		u.Place += "〜" + p
	}
	return u
}
