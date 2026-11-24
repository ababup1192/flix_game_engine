package proposal

import (
	"bytes"
	"encoding/json"
)

// Manifest は検査を通った proposal.json（キーの順番を保つ）。ダッシュボードの post.json も同じ形に author と origin を足した物。
type Manifest struct {
	v any
}

// ParseManifest は data を読んで検査する。壊れていれば name を頭に付けた 1 行ずつの理由を返す。
func ParseManifest(name string, data []byte) (*Manifest, []string) {
	m, errs := load(name, data)
	if len(errs) > 0 {
		return nil, errs
	}
	return &Manifest{v: m}, nil
}

// PageOptions は Page の切り替え。ゼロ値は fge proposal build と同じ静的な頁。
type PageOptions struct {
	// Send は頁の下の帯を常に出し、自由文の欄と「送る」を置く（帯は SendURL へ {picks, comment} を POST する）。
	Send    bool
	SendURL string
	// Picks は節の id → 選んだ案の id。選べる節をこの選択で開く（無い節は rec の案）。
	// WhyNot: decision へ入れて描かない — decision は「採用」の札と片付けの手順を出す別の意味の欄。
	Picks map[string]string
	// Comment は自由文の欄に最初から入れる文。
	Comment string
	// BackURL があれば頁の頭に戻るリンクを置く。
	BackURL string
}

// Page は manifest を 1 枚の HTML にする。root は相対パスの素材を探すフォルダ。missing は見つからなかった素材。
func Page(m *Manifest, root string, opts PageOptions) (html string, missing []string) {
	b := &builder{root: root, opts: opts}
	return b.page(m.v), b.missing
}

// Title は title の文字列（無ければ空）。
func (m *Manifest) Title() string { return m.text("title") }

// Lead は lead の文字列（無ければ空）。
func (m *Manifest) Lead() string { return m.text("lead") }

// Author は author の文字列（無ければ空）。
func (m *Manifest) Author() string { return m.text("author") }

func (m *Manifest) text(key string) string {
	if !has(m.v, key) || get(m.v, key) == nil {
		return ""
	}
	return str(get(m.v, key))
}

// HasChoices は options を持つ節（選べる節）があるか。
func (m *Manifest) HasChoices() bool {
	for _, s := range list(get(m.v, "sections")) {
		if truthy(get(s, "options")) {
			return true
		}
	}
	return false
}

// mediaRefs は素材を指す所（options の media と節の compare）を並びの順に回す。
// set は文字列の media をその場で書き換える口（オブジェクトの media は src を書き換える）。
func (m *Manifest) mediaRefs(visit func(src string, set func(string))) {
	ref := func(holder any, key string, idx int) {
		var cur any
		if idx >= 0 {
			cur = holder.([]any)[idx]
		} else {
			cur = get(holder, key)
		}
		switch t := cur.(type) {
		case string:
			visit(t, func(n string) {
				if idx >= 0 {
					holder.([]any)[idx] = n
				} else {
					holder.(*object).vals[key] = n
				}
			})
		case *object:
			if s, ok := t.vals["src"].(string); ok {
				visit(s, func(n string) { t.vals["src"] = n })
			}
		}
	}
	for _, sec := range list(get(m.v, "sections")) {
		if truthy(get(sec, "compare")) {
			ref(sec, "compare", -1)
		}
		for _, o := range list(get(sec, "options")) {
			if media, ok := get(o, "media").([]any); ok {
				for i := range media {
					ref(media, "", i)
				}
			}
		}
	}
}

// MediaSources は素材のパスを書いた順に返す（同じパスは 1 回）。
func (m *Manifest) MediaSources() []string {
	var out []string
	seen := map[string]bool{}
	m.mediaRefs(func(src string, _ func(string)) {
		if !seen[src] {
			seen[src] = true
			out = append(out, src)
		}
	})
	return out
}

// Images は画像の素材のパスを書いた順に返す（同じパスは 1 回）。
func (m *Manifest) Images() []string {
	var out []string
	for _, s := range m.MediaSources() {
		if imgExt[extOf(s)] {
			out = append(out, s)
		}
	}
	return out
}

// RewriteMedia は素材のパスを to の通りに書き換える（to に無いパスは触らない）。
func (m *Manifest) RewriteMedia(to map[string]string) {
	m.mediaRefs(func(src string, set func(string)) {
		if n, ok := to[src]; ok {
			set(n)
		}
	})
}

// Set は頂の欄 key を v（JSON にできる値）にする。既にあれば並びの位置を保って替え、無ければ末尾に足す。
func (m *Manifest) Set(key string, v any) error {
	raw, err := json.Marshal(v)
	if err != nil {
		return err
	}
	val, err := decode(raw)
	if err != nil {
		return err
	}
	o := m.v.(*object)
	if _, ok := o.vals[key]; !ok {
		o.keys = append(o.keys, key)
	}
	o.vals[key] = val
	return nil
}

// JSON は書いた人のキーの順のまま、字下げした JSON を返す。
func (m *Manifest) JSON() []byte {
	var buf bytes.Buffer
	if err := json.Indent(&buf, []byte(dumps(m.v)), "", "  "); err != nil {
		return []byte(dumps(m.v) + "\n")
	}
	buf.WriteByte('\n')
	return buf.Bytes()
}

func (b *builder) sendBar(openQ bool) string {
	out := ""
	if openQ {
		out = "<output></output>"
	}
	return `<div class="bar send" data-send="` + attr(b.opts.SendURL) + `">` + out +
		`<textarea rows="2" aria-label="返事の自由文" placeholder="自由に書く（例: B はもう少し暗く）">` + escape(b.opts.Comment) + `</textarea>` +
		`<button type="button">送る</button><small>選んで「送る」を押すと、AI が bin/fge dashboard inbox で拾います</small></div>` +
		"<script>" + sendJS + "</script>"
}

const sendCSS = `
.bar.send{align-items:stretch}
.bar.send output{align-self:center}
.bar textarea{flex:1 1 320px;max-width:560px;font:inherit;font-size:.92rem;border-radius:6px;border:0;padding:6px 10px;background:var(--barfg);color:var(--bar);resize:vertical}
.bar small{align-self:center;flex-basis:100%;text-align:center}
`

const sendJS = `
const bar=document.querySelector('.bar'),out=bar.querySelector('output'),note=bar.querySelector('small'),ta=bar.querySelector('textarea'),btn=bar.querySelector('button');
const groups=()=>[...document.querySelectorAll('.choice')];
function line(){if(!out)return;out.textContent='決定: '+groups().map(g=>{const c=g.querySelector('input:checked');return c?c.value:g.dataset.id+':?';}).join(' ');}
document.addEventListener('change',line);line();
btn.onclick=async()=>{const picks={};for(const g of groups()){const c=g.querySelector('input:checked');if(c)picks[g.dataset.id]=c.value;}
 btn.disabled=true;note.textContent='送っています…';
 try{const r=await fetch(bar.dataset.send,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({picks,comment:ta.value})});
  if(!r.ok)throw new Error((await r.text()).trim()||r.status);const j=await r.json();
  note.textContent='送りました（'+j.at+'）。AI が bin/fge dashboard inbox で拾います';}
 catch(e){note.textContent='送れませんでした: '+e.message;}
 finally{btn.disabled=false;}};
`
