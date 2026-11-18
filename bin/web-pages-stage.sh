#!/bin/bash
# ブラウザ版を GitHub Pages（gh-pages の枝）のサブフォルダへ置いてコミットするまで。push は人に任せ、打つ 1 行を出す。
# ゲームの足元の make web-pages-stage DEST=<サブフォルダ> から呼ぶ（手順と旗の全文は engine の docs/web-export.md の「GitHub Pages に出す」）。
#
# usage: web-pages-stage.sh <engine> <ゲームのフォルダ> <DEST> [SRC]
#   環境変数: AUDIO=ok（音のファイル・sounds・deferred の音を残したまま出す）・BRANCH（既定 gh-pages）・
#             PAGES_WT（gh-pages の worktree。既定はある物を使い、無ければ <ゲーム>/build/gh-pages）・NO_BROWSER_CHECK=1
#   SRC を渡すと書き出さず、その書き出し済みのフォルダを置く（ゲームの側で写し方を変えた書き出し。bench/hd2d_town の explore-web-public）。
#
# 止める所: 音が 1 本でも残る（AUDIO=ok で通す）・gh-pages の worktree に未コミットの変更がある・置いた頁がサブフォルダの道で開けない。
# WhyNot: 音を既定で止める — 外から持ってきた BGM・効果音は配る許しが要る物が多く（docs/audio.md）、
# 書き出しの残りの ogg が入ったまま出しかけた。自分で作った音だけのゲームは AUDIO=ok で通す。
# WhyNot: 書き出しを build/web と分ける（build/web-pages）— 手元で曲を足して書き出した build/web の残りを、そのまま公開へ回さない。
# WhyNot: push しない — 公開は取り消しが効かない（一度配った音や字は人の手元に残る）ので、人が差分を見てから打つ。
set -euo pipefail

engine=$(cd "$1" && pwd)
game=$(cd "$2" && pwd)
dest=${3:-}
src=${4:-}
branch=${BRANCH:-gh-pages}
say() { echo "[web-pages-stage] $*"; }
die() { echo "[web-pages-stage] $*" >&2; exit 1; }

case "$dest" in
  ""|/*|*..*|.|./*) die "DEST=<サブフォルダ> を渡す（例 make web-pages-stage DEST=hd2d-town。/ で始めない・.. を含めない）" ;;
esac
dest=${dest%/}

fge="$game/bin/fge"; [ -x "$fge" ] || fge="$engine/bin/fge"
repo=$(git -C "$game" rev-parse --show-toplevel 2>/dev/null) || die "$game は git の中にない（gh-pages の枝を置く先が無い）"

# ── 1. 書き出す ──
if [ -z "$src" ]; then
  out="$game/build/web-pages"
  rm -rf "$out"
  say "書き出す: $fge export-web $game --out $out"
  "$fge" export-web "$game" --out "$out" || die "書き出しで止まった（上の字を見る）"
else
  out=$(cd "$src" && pwd) || die "SRC=$src が無い"
  [ -f "$out/index.html" ] || die "SRC=$out に index.html が無い（書き出したフォルダを渡す）"
fi

# ── 2. 音が残っていないか ──
audio_files=$(cd "$out" && find . -type f \( -iname '*.ogg' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.wav' \
  -o -iname '*.opus' -o -iname '*.webm' -o -iname '*.flac' -o -iname '*.aac' \) | sed 's|^\./||' | sort)
bundle_audio=$("$engine/bin/py3" - "$out/bundle.json" <<'EOF'
import json, sys
try:
    b = json.load(open(sys.argv[1]))
except Exception as e:
    print("bundle.json を読めない: %s" % e); sys.exit(0)
exts = (".ogg", ".mp3", ".m4a", ".wav", ".opus", ".webm", ".flac", ".aac")
for s in b.get("sounds") or []:
    print("sounds: %s（%s）" % (s.get("name"), s.get("path")))
for d in b.get("deferred") or []:
    if str(d.get("path", "")).lower().endswith(exts):
        print("deferred: %s" % d.get("path"))
EOF
)
if [ -n "$audio_files$bundle_audio" ]; then
  say "音が残っている:"
  { [ -z "$audio_files" ] || printf 'ファイル: %s\n' $audio_files; [ -z "$bundle_audio" ] || printf '%s\n' "$bundle_audio"; } |
    awk '{ n++; if (n <= 12) print "  " $0 } END { if (n > 12) print "  … ほか " n - 12 " 件（全 " n " 件）" }'
  if [ "${AUDIO:-}" != ok ]; then
    die "止めた。配ってよい音（自分で作った・許しのある素材）だけなら AUDIO=ok を付けて流し直す。外す音は project.json の sounds と web.deferred から抜くか、書き出し用に写した先で消す（docs/web-export.md）"
  fi
  say "AUDIO=ok なので音を入れたまま進む"
fi

# ── 3. gh-pages の worktree ──
wt=${PAGES_WT:-}
if [ -z "$wt" ]; then
  wt=$(git -C "$repo" worktree list --porcelain | awk -v b="refs/heads/$branch" '/^worktree /{w=substr($0,10)} $0=="branch "b{print w; exit}')
fi
if [ -z "$wt" ]; then
  wt="$game/build/gh-pages"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo" worktree add -q "$wt" "$branch"
  elif git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$repo" worktree add -q -b "$branch" "$wt" "origin/$branch"
  else
    say "$branch の枝が無いので、何も無い枝として作る（push すると GitHub の Settings → Pages で $branch を選べる）"
    git -C "$repo" worktree add -q --orphan -b "$branch" "$wt"
  fi
  say "gh-pages の worktree を作った: $wt"
fi
[ -d "$wt" ] || die "PAGES_WT=$wt が無い"
[ "$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null)" = "$branch" ] || die "$wt は $branch の枝でない"
[ -z "$(git -C "$wt" status --porcelain)" ] || die "$wt に未コミットの変更がある（混ぜないので、先に片付ける: git -C $wt status）"
if git -C "$wt" rev-parse --verify --quiet "origin/$branch" >/dev/null; then
  behind=$(git -C "$wt" rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo 0)
  [ "$behind" = 0 ] || say "注意: $branch が origin より $behind 個遅れている（最後に取ってきた時点で。push の前に git -C $wt pull --ff-only）"
fi

# ── 4. 置いてコミット ──
mkdir -p "$wt/$dest"
rsync -a --delete --exclude .git "$out/" "$wt/$dest/"
# WhyNot: .nojekyll を置く — GitHub Pages の Jekyll は _ で始まるファイルを配らず、束の中の名前によっては頁が欠ける。
[ -f "$wt/.nojekyll" ] || : > "$wt/.nojekyll"
git -C "$wt" add -A -- "$dest" .nojekyll
if git -C "$wt" diff --cached --quiet; then
  say "前のコミットと同じ中身なので、コミットしない（$wt/$dest）"
else
  src_rev=$(git -C "$game" rev-parse --short HEAD 2>/dev/null || echo "?")
  ver=$(sed -n 's/^VERSION *:= *//p' "$engine/Makefile" 2>/dev/null | head -1)
  git -C "$wt" commit -q -m "pages: $dest に $(basename "$game") の書き出しを置く（ゲーム $src_rev・engine ${ver:-?}）"
  say "コミットした: $(git -C "$wt" log --oneline -1)"
fi

# ── 5. サブフォルダの道で開けるか ──
if [ "${NO_BROWSER_CHECK:-}" != 1 ]; then
  shot="$game/build/web-pages-check.png"
  if "$fge" web-capture "$dest/index.html?capture=3" "$shot" --dir "$wt" --wait 90 >/dev/null; then
    say "ヘッドレスの Chrome で $dest/index.html を開き、3 コマ目まで描けた（$shot）"
  else
    die "置いた頁を $dest/ の道で開けなかった（上の字を見る。コミットは残っているので、直したら流し直す）"
  fi
fi

# ── 6. 人が打つ物 ──
url=""
remote=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
if [[ "$remote" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
  url="https://${BASH_REMATCH[1]}.github.io/${BASH_REMATCH[2]}/$dest/"
fi
echo
say "手元で開く: $engine/bin/py3 -m http.server 8000 --bind 0.0.0.0 --directory $wt"
say "  PC は http://127.0.0.1:8000/$dest/ ・スマホ（同じ Wi-Fi）は http://$(ipconfig getifaddr en0 2>/dev/null || echo '<この機械の IP>'):8000/$dest/?fps=1"
say "  見終えたら Ctrl-C でサーバーを止める"
say "公開する（人が打つ）: git -C $wt push origin $branch"
[ -z "$url" ] || say "  公開の後の URL: $url（Pages の反映に 1〜2 分）"
