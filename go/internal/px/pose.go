package px

// 歩きの下ごしらえ: 決まった姿勢の名前（contact・down・passing・up）から、部品ごとの回転とずらしの
// patch を作る。4 方向を作るのは carve と adopt の仕事で、ここは 1 方向（横向き・右を向く）のコマだけ。
//
//	"roles": {"legF": "legR", "legB": "legL", "armF": "armL", "armB": "armR", "body": "torso", "head": "head"},
//	"frames": {"walk1": {"pose": "contact", "parts": {"legR": {"rotate": -30}}}, "walk2": {"pose": "down"}, …}
//
// 役（role）を書かなければ、部品 id が役の名前と同じ部品に当てる。"parts" は姿勢の patch の上に重ねる。
// 回転は部品の "rotate"（度・正で時計回り）と "pivot"。rotsprite の考え方（8 倍に Scale2x してから
// 回して画素の中心で拾う）で回すので、色は足さない。

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// poseRoles は役の名前と、何の部品か。
var poseRoles = map[string]string{
	"legF": "手前の脚", "legB": "奥の脚", "armF": "手前の腕", "armB": "奥の腕", "body": "胴", "head": "頭",
}

func poseRoleNames() []string {
	out := make([]string, 0, len(poseRoles))
	for k := range poseRoles {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// poseMove は役 1 つの動き（回転とずらし）。
type poseMove struct {
	Rotate float64
	At     [2]int
}

// poses は姿勢の表（右を向いた横向き。角度は仮置き。大きい見比べで決め直す）。
// 負の角度は前（右）へ振る。down で胴・頭・腕が 1px 沈み、up で 1px 浮く（脚は地面に残す）。
var poses = map[string]map[string]poseMove{
	"contact": {"legF": {Rotate: -25}, "legB": {Rotate: 25}, "armF": {Rotate: 20}, "armB": {Rotate: -20}},
	"down": {"legF": {Rotate: -15}, "legB": {Rotate: 15}, "armF": {Rotate: 10, At: [2]int{0, 1}},
		"armB": {Rotate: -10, At: [2]int{0, 1}}, "body": {At: [2]int{0, 1}}, "head": {At: [2]int{0, 1}}},
	"passing": {"legF": {Rotate: 0}, "legB": {Rotate: 0}},
	"up": {"legF": {Rotate: 10}, "legB": {Rotate: -10}, "armF": {Rotate: -5, At: [2]int{0, -1}},
		"armB": {Rotate: 5, At: [2]int{0, -1}}, "body": {At: [2]int{0, -1}}, "head": {At: [2]int{0, -1}}},
}

func poseNames() []string {
	out := make([]string, 0, len(poses))
	for k := range poses {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// poseToPatch は {"pose": 名前, "parts": {id: patch}} を部品 id → patch に直す。
func poseToPatch(r *reader, where string, frame *pxlib.Obj, roles map[string]string, ids map[string]bool) *pxlib.Obj {
	r.keys(frame, where, []string{"pose", "parts"})
	name, _ := frame.GetOr("pose", "").(string)
	table, ok := poses[name]
	if !ok {
		r.bad(where+".pose", "知らない姿勢 %q（%s）", name, strings.Join(poseNames(), "・"))
		return nil
	}
	out := pxlib.NewObj()
	roleNames := make([]string, 0, len(table))
	for k := range table {
		roleNames = append(roleNames, k)
	}
	sort.Strings(roleNames)
	for _, role := range roleNames {
		id := roles[role]
		if id == "" {
			id = role
		}
		if !ids[id] {
			continue // その役の部品が無い絵（腕の無い魔物など）
		}
		mv := table[role]
		p := pxlib.NewObj()
		if mv.Rotate != 0 {
			p.Set("rotate", json.Number(fmt.Sprint(mv.Rotate)))
		}
		if mv.At != [2]int{} {
			p.Set("at", []any{json.Number(fmt.Sprint(mv.At[0])), json.Number(fmt.Sprint(mv.At[1]))})
		}
		out.Set(id, p)
	}
	if pv, ok := frame.Get("parts"); ok {
		po, isObj := pv.(*pxlib.Obj)
		if !isObj {
			r.bad(where+".parts", "部品 id → patch のオブジェクトで書く")
			return out
		}
		keys, vals := po.Items()
		for i, id := range keys {
			if !ids[id] {
				r.bad(where+".parts."+id, "parts に id %q が無い", id)
				continue
			}
			cur, _ := out.Get(id)
			out.Set(id, mergePatch(cur, vals[i]))
		}
	}
	return out
}

// liftPart は今の部品が書いた画素を取り上げ（下の画素は描く前の格子から戻す）、色キーを返す。
func (c *ctx) liftPart() map[pxlib.Pt]pxlib.Key {
	out := map[pxlib.Pt]pxlib.Key{}
	ps := c.Part
	for _, p := range ps.written.Points() {
		out[p] = c.G.At(p.X, p.Y)
		if ps.before != nil {
			c.G.Put(p.X, p.Y, ps.before.At(p.X, p.Y), ps.before.SrcAt(p.X, p.Y))
		} else {
			c.G.Put(p.X, p.Y, pxlib.Clear, pxlib.OpRef{})
		}
		ps.written[p.Y][p.X] = false
	}
	return out
}

// dropPixels は取り上げた画素を置き直す（透明は置かない）。
func (c *ctx) dropPixels(px map[pxlib.Pt]pxlib.Key) {
	pts := make([]pxlib.Pt, 0, len(px))
	for p := range px {
		pts = append(pts, p)
	}
	pxlib.SortPtsByXY(pts)
	for _, p := range pts {
		if k := px[p]; k != pxlib.Clear {
			c.PutAbs(p.X, p.Y, k)
		}
	}
}

// rotatePart は今の部品を pivot のまわりに deg 度回す（rotsprite の考え方。色を足さない）。
func (c *ctx) rotatePart(deg float64, pivot *pxlib.Pt) {
	src := c.liftPart()
	if len(src) == 0 {
		return
	}
	pts := make([]pxlib.Pt, 0, len(src))
	for p := range src {
		pts = append(pts, p)
	}
	x0, y0, x1, _ := pxlib.BBox(pts)
	pv := pxlib.Pt{X: (x0 + x1) / 2, Y: y0}
	if pivot != nil {
		pv = pxlib.Pt{X: pivot.X + c.ox, Y: pivot.Y + c.oy} // 部品の at でずらした分も付いていく
	}
	c.dropPixels(rotSprite(src, deg, pv, c.G.W, c.G.H))
}

// rotSprite は画素の集まりを pivot（画素の中心）のまわりに deg 度回す。8 倍に Scale2x してから、
// 回した先の画素の中心を逆に回して 8 倍の絵から拾う（Xenowhirl の RotSprite の考え方。色を足さない）。
func rotSprite(src map[pxlib.Pt]pxlib.Key, deg float64, pivot pxlib.Pt, w, h int) map[pxlib.Pt]pxlib.Key {
	pts := make([]pxlib.Pt, 0, len(src))
	for p := range src {
		pts = append(pts, p)
	}
	x0, y0, x1, y1 := pxlib.BBox(pts)
	x0, y0, x1, y1 = x0-1, y0-1, x1+1, y1+1
	bw, bh := x1-x0+1, y1-y0+1
	img := make([][]pxlib.Key, bh)
	for y := range img {
		img[y] = make([]pxlib.Key, bw)
		for x := range img[y] {
			img[y][x] = src[pxlib.Pt{X: x + x0, Y: y + y0}]
		}
	}
	for i := 0; i < 3; i++ {
		img = scale2x(img)
	}
	const k = 8
	th := deg * math.Pi / 180
	cs, sn := math.Cos(th), math.Sin(th)
	cx, cy := float64(pivot.X)+0.5, float64(pivot.Y)+0.5
	// 回した先が入る範囲: 元の箱の 4 隅を回した外接箱
	r := math.Hypot(float64(bw), float64(bh)) + math.Hypot(float64(pivot.X-x0), float64(pivot.Y-y0))
	out := map[pxlib.Pt]pxlib.Key{}
	for y := int(cy - r); y <= int(cy+r); y++ {
		for x := int(cx - r); x <= int(cx+r); x++ {
			if x < 0 || y < 0 || x >= w || y >= h {
				continue
			}
			dx, dy := float64(x)+0.5-cx, float64(y)+0.5-cy
			// 逆に回す
			sx := dx*cs + dy*sn + cx
			sy := -dx*sn + dy*cs + cy
			ix := int(math.Floor((sx - float64(x0)) * k))
			iy := int(math.Floor((sy - float64(y0)) * k))
			if ix < 0 || iy < 0 || iy >= len(img) || ix >= len(img[0]) {
				continue
			}
			if key := img[iy][ix]; key != pxlib.Clear {
				out[pxlib.Pt{X: x, Y: y}] = key
			}
		}
	}
	return out
}

// scale2x は Scale2x（EPX）で 2 倍にする。角の段を斜めにつなぎ、色は足さない。
func scale2x(img [][]pxlib.Key) [][]pxlib.Key {
	h := len(img)
	w := len(img[0])
	at := func(x, y int) pxlib.Key {
		x = max(0, min(w-1, x))
		y = max(0, min(h-1, y))
		return img[y][x]
	}
	out := make([][]pxlib.Key, 2*h)
	for y := range out {
		out[y] = make([]pxlib.Key, 2*w)
	}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			p := img[y][x]
			a, b, cc, d := at(x, y-1), at(x+1, y), at(x-1, y), at(x, y+1)
			e0, e1, e2, e3 := p, p, p, p
			if cc == a && cc != d && a != b {
				e0 = a
			}
			if a == b && a != cc && b != d {
				e1 = b
			}
			if d == cc && d != b && cc != a {
				e2 = cc
			}
			if b == d && b != a && d != cc {
				e3 = d
			}
			out[2*y][2*x], out[2*y][2*x+1], out[2*y+1][2*x], out[2*y+1][2*x+1] = e0, e1, e2, e3
		}
	}
	return out
}
