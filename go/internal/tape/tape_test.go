package tape

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const (
	planDir    = "../../../plans/tape"
	samplePath = planDir + "/tape.sample.json"
	mockPath   = planDir + "/mock.html"
	otherPath  = "testdata/other.tape.json"
)

var sampleStrip = Strip{File: StripFile, Count: 88, W: StripW, H: StripH}

func readFile(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func renderFile(t *testing.T, p string, strip Strip) string {
	t.Helper()
	tp, err := Parse(readFile(t, p))
	if err != nil {
		t.Fatal(err)
	}
	page, err := Render(tp, "e32b519", strip, Splash{})
	if err != nil {
		t.Fatal(err)
	}
	return string(page)
}

// mockFixes は mock.html から雛形へ直した所の全部（plans/tape/plan.md の「TAPE から引くように直す所」と、plans/tape/plan-wide.md）。
// ここに無い違いが出たら、雛形がモックから外れている。
var mockFixes = [][2]string{
	{"const KEY = \"tape4:\" + TAPE.game + \":\" + TAPE.commit;",
		"// WhyNot: 鍵を game と commit だけにしない — 同じ origin（Pages）に同じゲームのテープが flow ごと・置き場ごとに並び、別の頁の注釈を読み合う\nconst KEY = \"tape4:\" + location.pathname + \":\" + TAPE.flow + \":\" + TAPE.game + \":\" + TAPE.commit;"},
	{"try { const s = JSON.parse(localStorage.getItem(KEY) || \"{}\"); anns = s.anns || []; edits = s.edits || {}; } catch {}",
		"try { const s = JSON.parse(localStorage.getItem(KEY) || \"{}\"); anns = (s.anns || []).filter(knownAnn); edits = Object.fromEntries(Object.entries(s.edits || {}).filter(([ln, v]) => typeof v === \"string\" && TAPE.lines[ln]?.text !== undefined)); } catch {}\n// WhyNot: 読んだ注釈をそのまま信じない — 古い版の頁が書いた物や手で直した物が、今の TAPE に無い scene・行・音を指すと、一覧と書き出しが落ちる\nfunction knownAnn(a) {\n  if (!a || typeof a !== \"object\" || !a.target || !TAPE.scenes.some(s => s.id === a.scene) || !(a.seconds >= 0 && a.seconds <= TAPE.duration)) return false;\n  if (a.kind === \"scene\") return TAPE.scenes.some(s => s.id === a.target.id);\n  if (a.kind === \"object\") return TAPE.objects.some(o => o.id === a.target.id);\n  if (a.kind === \"sound\") return TAPE.sounds.some(s => s.name === a.target.name);\n  if (a.kind === \"script\") return TAPE.lines[a.target.line] !== undefined;\n  return a.kind === \"rect\" && !!a.rect;\n}"},
	{"<title>テープ（モック・広い画面）— 血鱗 序章</title>", "<title>テープ — 血鱗 序章</title>"},
	{"    --witch: #c8a6ff; --girl: #ffb46b; --narr: #e6e6e6;\n", ""},
	{"  .mock { font-size: 9px; font-weight: 700; color: #1a1300; background: var(--accent); border-radius: 3px; padding: 0 3px; margin-left: 4px; vertical-align: 2px; }\n", ""},
	{`<b>血鱗 序章</b><span class="mock">MOCK</span><br>`, `<b id="tapeTitle"></b><br>`},
	{`<b id="tcNow">0:00.0</b> / 0:43.6</div>`, `<b id="tcNow">0:00.0</b> / <span id="tcDur"></span></div>`},
	{`const WHO = { "魔女": "var(--witch)", "少女": "var(--girl)", "地の文": "var(--narr)" };`,
		"const WHO = Object.fromEntries(TAPE.speakers.map((s, i) => [s.name, `var(--speaker-${i})`]));"},
	{"`<div class=\"ctxline\">通し · ${TAPE.scenes.length} シーン · 分岐 ${TAPE.branches.length}（この序章には分岐が無いので、分岐は見せ方の例です）</div>`",
		"`<div class=\"ctxline\">通し · ${TAPE.scenes.length} シーン${TAPE.branches.length ? ` · 分岐 ${TAPE.branches.length}${TAPE.branches.some(br => br.example) ? \"（例の分岐は見せ方を試すための仮の物です）\" : \"\"}` : \"\"}</div>`"},
	{"// 枠の寸法は動画から測った値: 横は画面の 2.8%〜97.2%、縦は 1 行目の中心から 47px 上〜最終行の中心から 32px 下、行の間 43.6px、中心は 466px（540×960 で）\n", ""},
	{"const MSG = { x0: .028, x1: .972, cy: 466 / 960, lh: 43.6 / 960, padTop: 47 / 960, padBot: 32 / 960, font: 25 / 960, cps: 28 };\n" +
		`const SPEAKER_INK = { "魔女": "#e2c2ff", "少女": "#ffd29a", "地の文": "#f4f4f4" };`,
		"const MSG = TAPE.msg;\nconst SPEAKER_INK = Object.fromEntries(TAPE.speakers.map(s => [s.name, s.ink]));"},
	{"if (!ln || edits[ln] === undefined || t < 8) {", `if (!ln || edits[ln] === undefined || !msgOn(t) || !objectsAt(t).some(o => o.id === "message")) {`},
	{"function msgBox(n) {", "// msg.when の問いの値が全部そろうコマだけ重ねる（NVL のように別の形のウィンドウの時は重ねない）\n" +
		"function msgOn(t) { const p = probesAt(t); return Object.entries(MSG.when || {}).every(([k, v]) => String(p[k]) === v); }\n" +
		"function msgBox(n) {"},
	{`  const names = { phase: "場面", witch: "魔女", item: "小物", ambience: "環境音", logSize: "ログ" };`, "  const names = TAPE.probeNames;"},
	{"function playHref(t) { const ln = lineAt(t) || 18; return `${TAPE.playUrl}?talk=${TAPE.node}&line=${ln}`; }",
		"// 直した行は edit.<行>（後の文）と was.<行>（前の文のハッシュ）で渡す。URL が長すぎると開けない端末があるので、MAX_URL を超える分は載せずに数える\nconst MAX_URL = 8000;\nfunction playLink(t) {\n  const ln = lineAt(t), l = ln && TAPE.lines[ln], node = encodeURIComponent((l && l.node) ?? TAPE.node);\n  let href = ln ? `${TAPE.playUrl}?talk=${node}&line=${ln}&at=${fnv1a(l.text ?? l.cmd)}` : `${TAPE.playUrl}?talk=${node}`, dropped = 0;\n  Object.keys(edits).map(Number).sort((a, b) => a - b).forEach(e => {\n    const part = `&edit.${e}=${encodeURIComponent(edits[e])}&was.${e}=${fnv1a(TAPE.lines[e].text)}`;\n    if (href.length + part.length > MAX_URL) dropped++; else href += part;\n  });\n  return { href, dropped };\n}\nconst playHref = t => playLink(t).href;\nfunction fnv1a(s) { let h = 0x811c9dc5; for (const b of new TextEncoder().encode(s)) h = Math.imul(h ^ b, 0x01000193) >>> 0; return h.toString(16).padStart(8, \"0\"); }"},
	{"$(\"playHereBtn\").onclick = () => { video.pause(); $(\"playHereBtn\").href = playHref(video.currentTime); toast(\"別のタブでゲームを開きます（モックでは最初から）\"); };",
		"$(\"playHereBtn\").onclick = () => {\n  video.pause(); const link = playLink(video.currentTime); $(\"playHereBtn\").href = link.href;\n  toast(link.dropped ? `直しの一部（${link.dropped} 件）は URL に乗らないので当てずに開きます` : \"別のタブでゲームを開きます\");\n};"},
	{"function applyTape() {\n  const root = document.documentElement.style;\n",
		"function applyTape() {\n  const root = document.documentElement.style;\n  TAPE.speakers.forEach((s, i) => root.setProperty(`--speaker-${i}`, s.color));\n"},
	{"  root.setProperty(\"--chap-w\", CHAP_W + \"px\"); root.setProperty(\"--chap-bg\", `${CHAP_W * TAPE.strip.count}px 53px`);\n}\n",
		"  root.setProperty(\"--chap-w\", CHAP_W + \"px\"); root.setProperty(\"--chap-bg\", `${CHAP_W * TAPE.strip.count}px 53px`);\n" +
			"  $(\"tapeTitle\").textContent = TAPE.title; $(\"tcDur\").textContent = mmss(TAPE.duration);\n" +
			"  if (!TAPE.playUrl) $(\"playHereBtn\").style.display = \"none\";\n" +
			"}\n"},
	{"setIcon(); buildTimeline(); refresh(); onTime(0);\n" +
		`fetch("kesshou.mp4").then(r => r.blob()).then(b => { video.src = URL.createObjectURL(b); }).catch(() => { video.src = "kesshou.mp4"; });`,
		"setIcon(); buildTimeline(); refresh(); onTime(0);\n" +
			splashScript +
			"const startAt = +(/^#t=([\\d.]+)$/.exec(location.hash) || [])[1];\n" +
			"if (startAt > 0) video.addEventListener(\"loadedmetadata\", () => seek(Math.min(startAt, TAPE.duration - .01)), { once: true });" +
			viewScript},
	{"  .tip .m { color: var(--faint); font-size: 11px; }\n</style>",
		"  .tip .m { color: var(--faint); font-size: 11px; }\n" +
			"  #splash { position: fixed; inset: 0; width: 100%; height: 100%; z-index: 100; background: #0b0e12; transition: opacity .2s; }\n" +
			"  #splash.gone { opacity: 0; pointer-events: none; }\n</style>"},
	{"<div class=\"toast\" id=\"toast\"></div>\n", "<div class=\"toast\" id=\"toast\"></div>\n<canvas id=\"splash\"></canvas>\n"},
	{"  return l.cmd ? { file: TAPE.yarn, node: TAPE.node, line: ln, command: l.cmd } : { file: TAPE.yarn, node: TAPE.node, line: ln, speaker: TAPE.speaker[l.who] ?? l.who, text: textOf(ln) }; };",
		"  const node = l.node ?? TAPE.node;\n  return l.cmd ? { file: TAPE.yarn, node, line: ln, command: l.cmd } : { file: TAPE.yarn, node, line: ln, speaker: TAPE.speaker[l.who] ?? l.who, text: textOf(ln) }; };"},
	{"<dt>ノード</dt><dd>${TAPE.node}</dd></dl>",
		"<dt>ノード</dt><dd>${esc(l.node ?? TAPE.node)}</dd></dl>"},
	{"talk: `start talk node=${TAPE.node} line=<script.line> で台本の行から始められる` },",
		"talk: \"start talk node=<script.node> line=<script.line> で台本の行から始められる\" },"},
	{"scriptEdits: edited.map(ln => ({ file: TAPE.yarn, node: TAPE.node, line: ln,", "scriptEdits: edited.map(ln => ({ file: TAPE.yarn, node: TAPE.lines[ln].node ?? TAPE.node, line: ln,"},
	// グラフの行の $名前 を変数の表示名で出し、$名前 を小さく添える（plans/tape/mock-state.html の varHtml と .raw の形）。
	{"  .grows span { word-break: break-word; }\n", "  .grows span { word-break: break-word; }\n" +
		"  .raw { font-family: ui-monospace, Menlo, monospace; font-size: .78em; color: var(--faint); font-weight: 400; margin-left: 4px; }\n"},
	{"const GRAPH = TAPE.graph || null;\n", "const GRAPH = TAPE.graph || null;\n" +
		"// 変数の表示名（ゲームの Doc の vars）。行の $名前 は表示名を主に出し、$名前 を小さく添える（esc 済みの HTML に当てる）\n" +
		"const VAR_NAMES = (GRAPH && GRAPH.vars) || {};\n" +
		"const withVarNames = html => html.replace(/\\$[A-Za-z_][A-Za-z0-9_]*/g, v => VAR_NAMES[v] ? `${esc(VAR_NAMES[v])}<span class=\"raw\">${v}</span>` : v);\n"},
	{"style=\"padding-left:${r.d * 10}px\">${esc(r.t)}</span>", "style=\"padding-left:${r.d * 10}px\">${withVarNames(esc(r.t))}</span>"},
	// 縦（スマホ）と横（PC）の 2 本の動画の切り替えと、頁の隣に置いたブラウザ版をはじめから開くボタン（plans/tape/spec.md の「縦と横の 2 本」）。
	{"  .modes button.on { background: #fff; color: #111; }\n",
		"  .modes button.on { background: #fff; color: #111; }\n  .topbtn { flex: none; height: 30px; min-width: 30px; padding: 0 8px; display: inline-flex; align-items: center; justify-content: center; gap: 4px; border-radius: 99px; background: var(--raised); color: var(--text); font-size: 12px; font-weight: 600; white-space: nowrap; text-decoration: none; }\n  .topbtn[hidden] { display: none; }\n  .topbtn .long { display: none; }\n  body.wide .topbtn .long { display: inline; }\n  body.topbtns .titlebtn b { display: block; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }\n  body.topbtns .titlebtn small { max-width: 100%; overflow: hidden; white-space: nowrap; }\n" + narrowTopCSS},
	{"    <button class=\"export\" id=\"exportBtn\">書き出す</button>",
		"    <a class=\"topbtn\" id=\"startBtn\" target=\"_blank\" rel=\"noopener\" href=\"#\" hidden aria-label=\"ゲームをはじめから遊ぶ（別のタブ）\">" + startIcon + "<span class=\"long\">はじめから遊ぶ</span></a>\n    <button class=\"topbtn\" id=\"viewBtn\" hidden></button>\n    <button class=\"export\" id=\"exportBtn\">書き出す</button>"},
	{"      <div class=\"editpill\" id=\"editPill\"></div>\n",
		"      <div class=\"editpill\" id=\"editPill\"></div>\n      <div class=\"viewpill\" id=\"viewPill\" role=\"status\"></div>\n"},
	{"// 注釈は 3 つの帯のどれかに付く。",
		"// 縦と横の 2 本を撮ったテープ（views.phone がある）は縦で開き、?view=pc の時だけ横で開く。上の欄の video・strip・msg・objects は横の分\nconst VIEWS = TAPE.views && TAPE.views.phone ? { pc: { video: TAPE.video, videoBytes: TAPE.videoBytes, strip: TAPE.strip, msg: TAPE.msg, objects: TAPE.objects }, phone: TAPE.views.phone } : null;\nlet tapeView = VIEWS ? (new URLSearchParams(location.search).get(\"view\") === \"pc\" ? \"pc\" : \"phone\") : null;\n// WhyNot: 選んだ分の msg をそのまま TAPE に入れない — 切り替えで MSG の中身を入れ替えるので、同じ物を指すと元の分が書き換わる\nif (VIEWS) Object.assign(TAPE, VIEWS[tapeView], { msg: { ...VIEWS[tapeView].msg }, objects: VIEWS[tapeView].objects.slice() });\n// 注釈は 3 つの帯のどれかに付く。"},
	{"location.href = n.dataset.href;",
		"location.href = withTapeView(n.dataset.href);"},
	{"if (a.rect && Math.abs(a.frame - f) <= 12)",
		"if (a.rect && (!a.screen || a.screen === tapeView) && Math.abs(a.frame - f) <= 12)"},
	{"anns.push({ ...pending, note, script: scriptRef(lineAt(pending.seconds)), probes: probesAt(pending.seconds) });",
		"anns.push({ ...pending, ...(VIEWS && pending.rect ? { screen: tapeView } : {}), note, script: scriptRef(lineAt(pending.seconds)), probes: probesAt(pending.seconds) });"},
	{"rect は画面に対する割合（左上が 0,0）です。\"];",
		"rect は画面に対する割合（左上が 0,0）です。\"];\n  if (VIEWS) out.push(\"同じ flow を スマホの縦の画面（screen: phone）と PC の横の画面（screen: pc）で撮っています。rect は screen の画面の割合です。\");"},
	{"rect: a.rect, script: a.script, note: a.note, probes: a.probes }))",
		"rect: a.rect, screen: a.screen, script: a.script, note: a.note, probes: a.probes }))"},
	{"${a.script ? \" · \" + yarn + \":\" + a.script.line : \"\"}] ${a.note}`));",
		"${a.script ? \" · \" + yarn + \":\" + a.script.line : \"\"}${a.screen ? \" · \" + SCREEN_NAME[a.screen] : \"\"}] ${a.note}`));"},
}

// startIcon ははじめから遊ぶの絵（ここから遊ぶと同じゲーム機。|◀ の形は「頭へ戻る」に読まれた）。
const startIcon = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"><rect x="3" y="7" width="18" height="11" rx="4"/><path d="M8 11v3M6.5 12.5h3" stroke-linecap="round"/><circle cx="15.5" cy="11.5" r="1" fill="currentColor" stroke="none"/><circle cx="17.5" cy="13.5" r="1" fill="currentColor" stroke="none"/></svg>`

// narrowTopCSS ははじめから遊ぶを字の入った目立つボタンにし、狭いスマホで上の帯を 2 段に組み、切り替えの様子を出す CSS。
const narrowTopCSS = `  body.topbtns .titlebtn br { display: none; }
  #startBtn { background: var(--c-video); color: #04121c; padding: 0 12px 0 9px; }
  #startBtn .long { display: inline; }
  #viewBtn.busy { color: var(--c-video); }
  .viewpill { position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); padding: 10px 16px; border-radius: 99px; background: rgba(0,0,0,.72);
    backdrop-filter: blur(10px); font-size: 13px; font-weight: 600; white-space: nowrap; pointer-events: none; display: none; font-variant-numeric: tabular-nums; z-index: 3; }
  .viewpill.on { display: block; }
  /* 狭いスマホ: 1 段目に一覧・題名・書き出す、2 段目に映像/グラフ・画面の切り替え・はじめから遊ぶ */
  @media (max-width: 560px) {
    body.topbtns:not(.wide) .top { flex-wrap: wrap; height: auto; row-gap: 2px; padding-bottom: 6px; }
    body.topbtns:not(.wide) .top::after { content: ""; order: 4; flex-basis: 100%; height: 0; }
    body.topbtns:not(.wide) #listBtn { order: 1; }
    body.topbtns:not(.wide) #chapBtn { order: 2; min-height: 40px; }
    body.topbtns:not(.wide) #exportBtn { order: 3; }
    body.topbtns:not(.wide) #modes { order: 5; margin-left: 6px; }
    body.topbtns:not(.wide) #viewBtn { order: 6; }
    body.topbtns:not(.wide) #viewBtn::after { content: attr(data-short); }
    body.topbtns:not(.wide) #startBtn { order: 7; margin-left: auto; height: 34px; font-size: 13px; }
  }
`

// viewScript は縦と横の動画の切り替えとはじめから遊ぶボタンの script（頁の最後に足す）。
const viewScript = `
// ── 縦（スマホ）と横（PC）の動画の切り替え: 秒・止めているか・選んでいる物・帯と一覧はそのまま、動画・帯の絵・メッセージウィンドウ・物の枠だけを替える ──
const SCREEN_NAME = { phone: "スマホの画面", pc: "PC の画面" };
const SHORT_NAME = { phone: "スマホ", pc: "PC" };
const ICON_PC = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="11" rx="1.5"/><path d="M9 20h6M12 16v4"/></svg>';
const ICON_PHONE = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="7" y="3" width="10" height="18" rx="2"/><path d="M11 18h2"/></svg>';
// 選んでいる画面を隣の頁（分岐の道）へ持っていく。縦は既定なので何も足さない
function withTapeView(href) {
  if (tapeView !== "pc") return href;
  const i = href.indexOf("#"), base = i < 0 ? href : href.slice(0, i), hash = i < 0 ? "" : href.slice(i);
  return base + (base.includes("?") ? "&" : "?") + "view=pc" + hash;
}
// はじめから遊ぶ: 頁の隣に置いたブラウザ版（TAPE.start）を、見ている画面の向きで開く
function syncStartBtn() {
  const b = $("startBtn");
  if (!TAPE.start) return;
  b.hidden = false; document.body.classList.add("topbtns");
  b.href = VIEWS ? TAPE.start + "?orientation=" + (tapeView === "pc" ? "landscape" : "portrait") : TAPE.start;
}
function syncViewBtn() {
  const b = $("viewBtn");
  if (!VIEWS) return;
  b.hidden = false; document.body.classList.add("topbtns");
  const to = tapeView === "phone" ? "pc" : "phone";
  b.innerHTML = (to === "pc" ? ICON_PC : ICON_PHONE) + ` + "`" + `<span class="long">${SCREEN_NAME[to]}</span>` + "`" + `;
  b.dataset.short = SHORT_NAME[to];
  b.setAttribute("aria-label", ` + "`" + `${SCREEN_NAME[to]}で撮った動画に替える` + "`" + `);
  syncStartBtn();
}
// 切り替えている間はボタンと動画の上に様子を出す（ratio は取った割合・割合が分からない時は null・終わったら false）
function showSwitching(v, ratio) {
  const b = $("viewBtn"), p = $("viewPill"), on = ratio !== false;
  b.classList.toggle("busy", on); p.classList.toggle("on", on);
  if (!on) { syncViewBtn(); return; }
  const pct = ratio === null ? "" : ` + "`" + ` ${Math.floor(ratio * 100)}%` + "`" + `;
  b.dataset.short = "切り替え中" + pct; b.querySelector(".long").textContent = "切り替え中…" + pct;
  p.textContent = ` + "`" + `${SCREEN_NAME[v]}に切り替え中…${pct}` + "`" + `;
}
// 置き場が Range を返すか。返すなら動画の URL を video.src へ直に渡し、取り終えるのを待たずに秒へ送る
let rangeOk = null;
async function canRange(url) {
  if (rangeOk !== null) return rangeOk;
  try { const r = await fetch(url, { headers: { Range: "bytes=0-1" } }); rangeOk = r.status === 206; r.body?.cancel?.(); } catch { rangeOk = false; }
  return rangeOk;
}
// 取り終えた動画（blob の URL）を画面ごとに持ち、行き来で取り直さない
const viewSrc = {};
function setTapeView(v) {
  if (!VIEWS || !VIEWS[v] || v === tapeView) return;
  const d = VIEWS[v], t = video.currentTime, playing = !video.paused, from = tapeView;
  tapeView = v;
  TAPE.video = d.video; TAPE.videoBytes = d.videoBytes; TAPE.strip = d.strip; TAPE.objects = d.objects.slice();
  Object.keys(MSG).forEach(k => delete MSG[k]); Object.assign(MSG, d.msg);
  document.documentElement.style.setProperty("--strip", ` + "`" + `url("${encodeURI(d.strip.file)}")` + "`" + `);
  // WhyNot: 頁を読み直して替えない — 書きかけの注釈・開いている欄・帯の広げ具合が消え、動画も最初から取り直す
  try { const u = new URL(location.href); if (v === "pc") u.searchParams.set("view", "pc"); else u.searchParams.delete("view"); history.replaceState(history.state, "", u.href); } catch {}
  syncViewBtn(); showSwitching(v, null);
  if (video.src.startsWith("blob:")) viewSrc[from] = video.src;
  // WhyNot: Range を返さない置き場（手元の簡易な http サーバ）で URL を video.src へ直に渡さない — 秒へ送れず頭へ戻る。その時だけ丸ごと取って割合を出す
  const src = viewSrc[v] ? Promise.resolve(viewSrc[v]) : canRange(d.video).then(ok => ok ? d.video
    : fetchVideo(d.video, d.videoBytes, (got, total) => { if (tapeView === v) showSwitching(v, total > 0 ? Math.min(1, got / total) : null); })
      .then(b => viewSrc[v] = URL.createObjectURL(b))).catch(() => d.video);
  src.then(url => {
    if (tapeView !== v) return;
    const done = () => { if (tapeView === v) showSwitching(v, false); };
    video.addEventListener("loadedmetadata", () => {
      video.addEventListener("seeked", done, { once: true });
      refresh(); seek(Math.min(t, TAPE.duration - .01)); if (playing) video.play();
    }, { once: true });
    video.addEventListener("error", done, { once: true });
    video.src = url;
  });
}
$("viewBtn").onclick = () => setTapeView(tapeView === "phone" ? "pc" : "phone");
syncViewBtn(); syncStartBtn();`

// splashScript は動画を全部取ってから渡していた所を、取りの割合を起動画面に出す形へ直した script（SPLASH は Splash{} を渡した時の字）。
const splashScript = `
// ── 起動画面: 動画を取っている間、ゲームのブラウザ版（fge-web.js の fgeSplash）と同じ配置・色・ゲージ・ドットの字で描く ──
// design はゲームの縦画面の既定（540×960）に固定し、ゲームと同じく黒帯ありで画面へ広げる。
// WhyNot: 画面の CSS px をそのまま design にしない — ロゴと字の大きさの段がゲームの起動画面と変わり、並べると別の絵に見える
const SPLASH = {};
const SPLASH_COLORS = { backdrop: "#0b0e12", white: "#ffffff", brand: "rgb(158,204,242)", dim: "rgb(140,148,163)" };
const SPLASH_DESIGN = { w: 540, h: 960 };
const splash = { el: $("splash"), got: 0, ratio: null, phase: "loading...", font: null, logo: null, glyphs: new Map(), tints: {}, startedAt: performance.now(), on: true, layout: null, view: null };
for (let i = 0; i + 14 <= (SPLASH.glyphs || "").length; i += 14) {
  const hex = (at, n) => parseInt(SPLASH.glyphs.substr(i + at, n), 16) || 0;
  splash.glyphs.set(hex(0, 4), { x: hex(4, 3), y: hex(7, 3), w: hex(10, 2), adv: hex(12, 2) });
}
[["font", SPLASH.font], ["logo", SPLASH.logo]].forEach(([key, url]) => {
  if (!url) return;
  const img = new Image(); img.onload = () => { splash[key] = img; splash.tints = {}; }; img.src = url;
});
const splashDrawable = s => !!s && [...s].every(c => splash.glyphs.has(c.charCodeAt(0)));
// WhyNot: 題名をそのまま描かない — 組み込みのドットの字は英数字だけで、日本語の題名は 1 字も出ない。描けなければゲームの名前、それも無理ならエンジンの名前
const splashTitle = () => [TAPE.title, TAPE.game].find(splashDrawable) || "Flix_GE";
function splashLayout(dw, dh) {
  const scale = Math.max(1, Math.floor(dh / 200)), logoBase = splash.logo ? splash.logo.naturalHeight : 0;
  let logoH = 0;
  if (logoBase > 0) {
    logoH = logoBase / 4;
    [logoBase / 4, logoBase / 2, logoBase, logoBase * 2].forEach(h => { if (h <= dh * .3) logoH = Math.max(logoH, h); });
  }
  const lineH = ((SPLASH.ascent || 9) + (SPLASH.descent || 2) + (SPLASH.lineGap || 0)) * scale, gaugeH = Math.max(2, 3 * scale), gap = 4 * scale;
  const top = Math.floor((dh - (logoH + gap + lineH + gap * 2 + gaugeH + gap + lineH)) / 2), cx = Math.floor(dw / 2);
  const titleTop = top + logoH + gap, gaugeTop = titleTop + lineH + gap * 2, gaugeW = Math.floor(Math.min(dw - 16 * scale, dw * .6));
  return { scale, logoH, cx, logoTop: top, titleTop, gaugeTop, gaugeW, gaugeH, gaugeLeft: Math.floor(cx - gaugeW / 2), phaseTop: gaugeTop + gaugeH + gap };
}
function splashTint(color) {
  if (splash.tints[color]) return splash.tints[color];
  const f = splash.font, t = document.createElement("canvas");
  t.width = f.naturalWidth; t.height = f.naturalHeight;
  const c = t.getContext("2d");
  c.drawImage(f, 0, 0); c.globalCompositeOperation = "source-in"; c.fillStyle = color; c.fillRect(0, 0, t.width, t.height);
  return splash.tints[color] = t;
}
function splashText(c, text, L, top, color) {
  if (!text || !splash.font) return;
  const cellH = SPLASH.cellH || 11, tint = splashTint(color);
  const width = [...text].reduce((w, ch) => w + (splash.glyphs.get(ch.charCodeAt(0))?.adv || 0), 0);
  let pen = 0;
  for (const ch of text) {
    const g = splash.glyphs.get(ch.charCodeAt(0));
    if (!g) continue;
    if (g.w > 0) c.drawImage(tint, g.x, g.y, g.w, cellH, L.cx - width * L.scale / 2 + pen * L.scale, top, g.w * L.scale, cellH * L.scale);
    pen += g.adv;
  }
}
function splashDraw() {
  const el = splash.el, dpr = devicePixelRatio || 1, dw = SPLASH_DESIGN.w, dh = SPLASH_DESIGN.h;
  const cw = Math.max(1, Math.round(el.clientWidth * dpr)), ch = Math.max(1, Math.round(el.clientHeight * dpr));
  if (el.width !== cw || el.height !== ch) { el.width = cw; el.height = ch; }
  const c = el.getContext("2d"), L = splashLayout(dw, dh);
  c.setTransform(1, 0, 0, 1, 0, 0); c.fillStyle = SPLASH_COLORS.backdrop; c.fillRect(0, 0, cw, ch);
  const vpW = cw / ch > dw / dh ? Math.trunc(ch * dw / dh) : cw, vpH = cw / ch > dw / dh ? ch : Math.trunc(cw * dh / dw);
  const k = vpW / dw, x = Math.floor((cw - vpW) / 2), y = Math.floor((ch - vpH) / 2);
  splash.layout = L; splash.view = { k, x, y };
  c.setTransform(k, 0, 0, k, x, y); c.imageSmoothingEnabled = false;
  if (splash.logo && L.logoH > 0) {
    const lw = L.logoH * splash.logo.naturalWidth / splash.logo.naturalHeight;
    c.drawImage(splash.logo, Math.floor(L.cx - lw / 2), L.logoTop, lw, L.logoH);
  }
  splashText(c, splashTitle(), L, L.titleTop, SPLASH_COLORS.brand);
  c.globalAlpha = .18; c.fillStyle = SPLASH_COLORS.white; c.fillRect(L.gaugeLeft, L.gaugeTop, L.gaugeW, L.gaugeH); c.globalAlpha = 1;
  if (splash.ratio !== null) {
    const fw = Math.floor(L.gaugeW * splash.ratio);
    if (fw >= 1) c.fillRect(L.gaugeLeft, L.gaugeTop, fw, L.gaugeH);
  } else {
    const sec = (performance.now() - splash.startedAt) / 1000, bw = Math.floor(L.gaugeW * .25);
    c.fillRect(L.gaugeLeft + Math.floor((L.gaugeW - bw) * (sec - Math.floor(sec))), L.gaugeTop, bw, L.gaugeH);
  }
  splashText(c, splash.phase, L, L.phaseTop, SPLASH_COLORS.dim);
}
(function splashLoop() { if (splash.on) { splashDraw(); requestAnimationFrame(splashLoop); } })();
function splashProgress(done, total) {
  splash.got = done; splash.ratio = total > 0 ? Math.max(0, Math.min(1, done / total)) : null;
  splash.phase = splash.ratio === null ? "loading..." : "loading " + Math.floor(splash.ratio * 100) + "%";
}
function splashHide() {
  if (!splash.on) return;
  splash.on = false; splash.el.classList.add("gone"); setTimeout(() => splash.el.remove(), 200);
}
// WhyNot: r.blob() で一息に取らない — 45MB ほどの動画を取り終えるまで何割取れたかが分からず、起動画面のゲージが進まない
async function fetchVideo(url, bytes, progress) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(url + ": " + r.status);
  const total = +r.headers.get("Content-Length") || bytes || 0;
  if (!r.body?.getReader) return r.blob();
  const reader = r.body.getReader(), parts = [];
  let got = 0;
  progress(0, total);
  for (let part = await reader.read(); !part.done; part = await reader.read()) {
    parts.push(part.value); got += part.value.length; progress(got, total);
  }
  return new Blob(parts, { type: r.headers.get("Content-Type") || "video/mp4" });
}
fetchVideo(TAPE.video, TAPE.videoBytes, splashProgress).then(b => { video.src = URL.createObjectURL(b); }).catch(() => { video.src = TAPE.video; }).finally(splashHide);
`

// tapeLiteral は頁の「const TAPE = …;」の右辺を返す（モックは JS の書き方、雛形は JSON なので比べずに差し替える）。
func tapeLiteral(t *testing.T, page, start, end string) (int, int) {
	t.Helper()
	i := strings.Index(page, start)
	if i < 0 {
		t.Fatalf("%q が無い", start)
	}
	j := strings.Index(page[i:], end)
	if j < 0 {
		t.Fatalf("%q の後に %q が無い", start, end)
	}
	return i, i + j + len(end)
}

func TestSampleRenderEqualsMockExceptListedFixes(t *testing.T) {
	got := renderFile(t, samplePath, sampleStrip)
	want := string(readFile(t, mockPath))
	for _, f := range mockFixes {
		if n := strings.Count(want, f[0]); n != 1 {
			t.Fatalf("mock.html に直す前の文が %d 回: %q", n, f[0])
		}
		want = strings.Replace(want, f[0], f[1], 1)
	}
	mi, mj := tapeLiteral(t, want, "// ── 書き出しの道具が埋め込む想定のデータ", "\n};\n")
	gi, gj := tapeLiteral(t, got, "const TAPE = ", ";\n")
	want = want[:mi] + got[gi:gj] + want[mj:]
	if got != want {
		gl, wl := strings.Split(got, "\n"), strings.Split(want, "\n")
		for k := 0; k < len(gl) && k < len(wl); k++ {
			if gl[k] != wl[k] {
				t.Fatalf("%d 行目が違う\n雛形: %s\nモック: %s", k+1, gl[k], wl[k])
			}
		}
		t.Fatalf("行の数が違う 雛形 %d / モック %d", len(gl), len(wl))
	}
}

func TestOtherSampleLeavesNoMockNames(t *testing.T) {
	page := renderFile(t, otherPath, Strip{File: StripFile, Count: 13, W: StripW, H: StripH})
	for _, word := range []string{"kesshou", "血鱗", "MOCK", "2992", "魔女", "* 88", "/ 54"} {
		if strings.Contains(page, word) {
			t.Errorf("書き出した頁に %q が残っている", word)
		}
	}
}

func TestRenderEscapesScriptCloseInText(t *testing.T) {
	var m map[string]any
	if err := json.Unmarshal(readFile(t, otherPath), &m); err != nil {
		t.Fatal(err)
	}
	m["title"] = "</script><b>x"
	data, _ := json.Marshal(m)
	tp, err := Parse(data)
	if err != nil {
		t.Fatal(err)
	}
	page, _ := Render(tp, "abc", sampleStrip, Splash{})
	if strings.Contains(string(page), "</script><b>") {
		t.Fatal("題名の </script> がそのまま頁に出た")
	}
}

func TestRenderAddedFieldsOverrideGameValues(t *testing.T) {
	page := renderFile(t, samplePath, Strip{File: StripFile, Count: 5, W: StripW, H: StripH})
	if !strings.Contains(page, `"strip":{"file":"strip.jpg","count":5,"w":54,"h":96}`) {
		t.Fatal("strip が Render の値になっていない")
	}
}

func dropKey(t *testing.T, key string) []byte {
	t.Helper()
	var m map[string]json.RawMessage
	if err := json.Unmarshal(readFile(t, otherPath), &m); err != nil {
		t.Fatal(err)
	}
	delete(m, key)
	b, _ := json.Marshal(m)
	return b
}

func TestParseNamesEachMissingField(t *testing.T) {
	for _, r := range required {
		_, err := Parse(dropKey(t, r.key))
		if err == nil || !strings.Contains(err.Error(), `"`+r.key+`"`) {
			t.Errorf("%s を抜いた時の言葉に欄の名前が無い: %v", r.key, err)
		}
	}
}

func TestParseAcceptsMissingPlayUrl(t *testing.T) {
	if _, err := Parse(readFile(t, otherPath)); err != nil {
		t.Fatal(err)
	}
}

func withEdit(t *testing.T, edit func(m map[string]any)) error {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(readFile(t, otherPath), &m); err != nil {
		t.Fatal(err)
	}
	edit(m)
	b, _ := json.Marshal(m)
	_, err := Parse(b)
	return err
}

func TestParseAcceptsSoundWithoutLine(t *testing.T) {
	err := withEdit(t, func(m map[string]any) { m["sounds"].([]any)[0].(map[string]any)["line"] = nil })
	if err != nil {
		t.Fatal(err)
	}
}

func TestParseRejectsUnknownField(t *testing.T) {
	err := withEdit(t, func(m map[string]any) { m["speakerColors"] = []any{} })
	if err == nil || !strings.Contains(err.Error(), "speakerColors") {
		t.Fatalf("got %v", err)
	}
}

func TestParseAcceptsMigrateFields(t *testing.T) {
	err := withEdit(t, func(m map[string]any) {
		m["events"], m["frames"], m["ranLines"] = []any{}, []any{}, []any{}
		m["buses"], m["screen"] = map[string]any{}, map[string]any{"w": 540, "h": 960}
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestParseRejectsTimelineLineAbsentFromLines(t *testing.T) {
	err := withEdit(t, func(m map[string]any) { m["timeline"] = []any{[]any{0, nil}, []any{1, 99}} })
	if err == nil || !strings.Contains(err.Error(), "99") {
		t.Fatalf("got %v", err)
	}
}

func TestParseRejectsSpeakerWithoutColor(t *testing.T) {
	err := withEdit(t, func(m map[string]any) { m["speakers"] = m["speakers"].([]any)[1:] })
	if err == nil || !strings.Contains(err.Error(), "灯台守") {
		t.Fatalf("got %v", err)
	}
}

func TestParseRejectsMsgWithoutKey(t *testing.T) {
	err := withEdit(t, func(m map[string]any) { delete(m["msg"].(map[string]any), "cps") })
	if err == nil || !strings.Contains(err.Error(), "cps") {
		t.Fatalf("got %v", err)
	}
}

func TestParseRejectsMsgWhenOnUnknownProbe(t *testing.T) {
	err := withEdit(t, func(m map[string]any) { m["msg"].(map[string]any)["when"] = map[string]any{"nope": "Adv"} })
	if err == nil || !strings.Contains(err.Error(), "nope") {
		t.Fatalf("got %v", err)
	}
}

func TestParseRejectsMsgWhenWithNonTextValue(t *testing.T) {
	err := withEdit(t, func(m map[string]any) { m["msg"].(map[string]any)["when"] = map[string]any{"mode": 1} })
	if err == nil || !strings.Contains(err.Error(), "when") {
		t.Fatalf("got %v", err)
	}
}

func TestParseRejectsDuplicateSceneID(t *testing.T) {
	err := withEdit(t, func(m map[string]any) {
		s := m["scenes"].([]any)
		m["scenes"] = append(s, s[0])
	})
	if err == nil || !strings.Contains(err.Error(), "title") {
		t.Fatalf("got %v", err)
	}
}

func TestStripCountIncludesFrameZero(t *testing.T) {
	if got := StripCount(43.6); got != 88 {
		t.Fatalf("got %d", got)
	}
}

func TestStripCountOnExactHalfSecond(t *testing.T) {
	if got := StripCount(3.0); got != 6 {
		t.Fatalf("got %d", got)
	}
}

func TestParseArgsNeedsDir(t *testing.T) {
	if _, err := parseArgs(nil); err == nil {
		t.Fatal("want error")
	}
}

func TestParseArgsTakesDirEquals(t *testing.T) {
	opt, err := parseArgs([]string{"--dir=debug/tape/a"})
	if err != nil || opt.Dir != "debug/tape/a" {
		t.Fatalf("got %+v %v", opt, err)
	}
}

// makeVideo は ffmpeg の試験用の絵で secs 秒の 540×960 の mp4 を作る。ffmpeg が無ければ飛ばす。
func makeVideo(t *testing.T, path string, secs float64) {
	t.Helper()
	makeVideoSized(t, path, secs, "540x960")
}

// makeVideoSized は size（"幅x高さ"）の試験の動画を作る。
func makeVideoSized(t *testing.T, path string, secs float64, size string) {
	t.Helper()
	ff, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg が無い")
	}
	out, err := exec.Command(ff, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
		"-i", fmt.Sprintf("testsrc2=size=%s:rate=30:duration=%g", size, secs),
		"-pix_fmt", "yuv420p", path).CombinedOutput()
	if err != nil {
		t.Fatalf("試験の動画を作れない: %v\n%s", err, out)
	}
}

func TestBuildWritesStripAndIndex(t *testing.T) {
	dir := t.TempDir()
	makeVideo(t, filepath.Join(dir, VideoFile), 6.2)
	if err := os.WriteFile(filepath.Join(dir, TapeFile), readFile(t, otherPath), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Build(Options{Dir: dir, Commit: "abc1234"}); err != nil {
		t.Fatal(err)
	}
	page := string(readFile(t, filepath.Join(dir, IndexFile)))
	if !strings.Contains(page, `"strip":{"file":"strip.jpg","count":13,"w":54,"h":96}`) || !strings.Contains(page, `"commit":"abc1234"`) {
		t.Fatal("index.html に strip と commit が入っていない")
	}
}

func TestBuildWritesVideoBytes(t *testing.T) {
	// 頁に動画のファイルの大きさを videoBytes として書く（Content-Length が無い返事でも割合を出すため）。
	dir := t.TempDir()
	video := filepath.Join(dir, VideoFile)
	makeVideo(t, video, 1)
	if err := os.WriteFile(filepath.Join(dir, TapeFile), readFile(t, otherPath), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Build(Options{Dir: dir, Commit: "abc1234"}); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(video)
	if err != nil {
		t.Fatal(err)
	}
	if page := string(readFile(t, filepath.Join(dir, IndexFile))); !strings.Contains(page, fmt.Sprintf(`"videoBytes":%d`, info.Size())) {
		t.Errorf("index.html に videoBytes %d が入っていない", info.Size())
	}
}

func TestBuildStopsWithoutVideo(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, TapeFile), readFile(t, otherPath), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Build(Options{Dir: dir, Commit: "abc1234"})
	if err == nil || !strings.Contains(err.Error(), VideoFile) {
		t.Fatalf("got %v", err)
	}
}

func TestRenderedPageBuildsPlayLinkWithEditsAndLimit(t *testing.T) {
	page := renderFile(t, otherPath, Strip{File: StripFile, Count: 13, W: StripW, H: StripH})
	for _, want := range []string{"const MAX_URL = 8000;", "&edit.${e}=${encodeURIComponent(edits[e])}&was.${e}=${fnv1a(TAPE.lines[e].text)}",
		"直しの一部（${link.dropped} 件）は URL に乗らないので当てずに開きます"} {
		if !strings.Contains(page, want) {
			t.Errorf("頁に %q が無い", want)
		}
	}
}

// starterPath はテンプレ（sound-novel-starter）の make tape FLOW=e2e/tape.flow が書いた本物の tape.json。
// テンプレの TapeOut を変えたら、作り直してここへ写す。
const starterPath = "testdata/starter.tape.json"

func TestStarterTapeFromMakeTapeParses(t *testing.T) {
	tp, err := Parse(readFile(t, starterPath))
	if err != nil {
		t.Fatalf("テンプレの make tape が書いた tape.json が通らない: %v", err)
	}
	if tp.Title == "" {
		t.Fatal("題名が空")
	}
}

func TestStarterTapeHasMessageObject(t *testing.T) {
	var m struct {
		Objects []struct{ ID string } `json:"objects"`
	}
	if err := json.Unmarshal(readFile(t, starterPath), &m); err != nil {
		t.Fatal(err)
	}
	for _, o := range m.Objects {
		if o.ID == "message" {
			return
		}
	}
	t.Fatalf("objects に message が無い: %+v", m.Objects)
}

func TestStripCellSizeKeepsLongTapeUnderJpegLimit(t *testing.T) {
	n := StripCount(643.5)
	w, _ := stripCellSize(n)
	if n*w > maxJpegSide {
		t.Fatalf("%d 枚 × %d px = %d px（上限 %d）", n, w, n*w, maxJpegSide)
	}
}

func TestStripCellSizeLeavesShortTapeAsIs(t *testing.T) {
	w, h := stripCellSize(StripCount(60))
	if w != StripW || h != StripH {
		t.Fatalf("%dx%d（%dx%d のはず）", w, h, StripW, StripH)
	}
}
