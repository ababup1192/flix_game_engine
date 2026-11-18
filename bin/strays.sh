#!/bin/bash
# このリポジトリ（engine なら main と全部の worktree・ゲームならそのリポ）から起こされて、親がいなくなったまま残っている
# プロセスを一覧にする。KILL=1 で止める。make strays（mk/common.mk）から呼ぶ。
#
# usage: strays.sh <作業場のフォルダ>
#   環境変数: KILL=1（止める）・AGE=<分>（止めるのはこれより長く走っている物だけ。既定 30）・ROOT=<フォルダ>（根を差し替える）
#
# 拾う物（どれも「親が launchd（ppid 1）」= 起こした shell や道具が先に終わった物だけ）:
#   chrome   … ヘッドレスの Chrome（--headless と、engine の道具が作る使い捨ての --user-data-dir: fge-web-capture-* / hd2d_cdp_*）
#   server   … python3 -m http.server・jwebserver（今いるフォルダか --directory が根の下）
#   resident … flixlint.Resident（型検査・refactor の常駐）のうち、--root のフォルダがもう無い物（消した worktree の分）
#   java など … java・python・bash・fge-go・ffmpeg・Blender で、コマンドの字か今いるフォルダが根の下にある物（ゲームのウィンドウ・描き出し・測り）
#
# WhyNot: 親のいるプロセスは拾わない — make run・make explore-serve を人が端末で流している間は親（make・shell）がいる。
# 取り残された物だけが launchd の子になる。macOS では普段のアプリも ppid 1 なので、名前（java・python…）と根の下かで絞る。
# WhyNot: --root のある常駐は拾わない — 30 分使われなければ自分で降り、ほかの担当がいま使っている物でもある。
# WhyNot: 止めるのを AGE 分より古い物に限る — ほかの担当が裏で起こしたばかりのウィンドウや測りを止めない。一覧には全部出す。
set -uo pipefail

dir=$(cd "${1:-.}" && pwd -P)
age_min=${AGE:-30}
root=${ROOT:-}
if [ -z "$root" ]; then
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ] && [ "$(basename "$common")" = .git ]; then
    root=$(dirname "$common")
  else
    root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")
  fi
fi
root=$(cd "$root" 2>/dev/null && pwd -P || echo "$root")
# WhyNot: /private を外した字も見る — macOS の /tmp・/var は /private の別名で、コマンドの字にはどちらでも出る。
root_alt=${root#/private}

secs_of() { # ps の etime（[[dd-]hh:]mm:ss）を秒に
  awk -v t="$1" 'BEGIN { d = 0; if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
    n = split(t, p, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + p[i]; print d * 86400 + s }'
}
human() { local s=$1; if [ "$s" -ge 86400 ]; then echo "$((s / 86400))d$(((s % 86400) / 3600))h"; elif [ "$s" -ge 3600 ]; then echo "$((s / 3600))h$(((s % 3600) / 60))m"; else echo "$((s / 60))m"; fi; }
under() { case "$1" in "$root"|"$root"/*|"$root_alt"|"$root_alt"/*) return 0 ;; esac; return 1; }

# 今いるフォルダを全部のプロセスについて 1 回で引く（1 つずつ lsof を呼ぶと数十秒かかる）。
cwds=$(lsof -a -d cwd -Fpn 2>/dev/null | awk '/^p/ { pid = substr($0, 2) } /^n/ { print pid "\t" substr($0, 2) }')
cwd_of() { printf '%s\n' "$cwds" | awk -F'\t' -v p="$1" '$1 == p { print $2; exit }'; }

found=()
while IFS= read -r line; do
  read -r pid ppid pgid etime cmd <<<"$line"
  [ "$ppid" = 1 ] || continue
  [ "$pid" = "$$" ] && continue
  kind=""; where=""
  case "$cmd" in
    *--type=*) continue ;;
    *--headless*--user-data-dir=*)
      udd=$(printf '%s' "$cmd" | sed -n 's/.*--user-data-dir=\([^ ]*\).*/\1/p')
      case "$udd" in */fge-web-capture-*|*/hd2d_cdp_*) kind=chrome; where=$udd ;; *) under "$udd" && { kind=chrome; where=$udd; } ;; esac ;;
    *flixlint.Resident*server*)
      r=$(printf '%s' "$cmd" | sed -n 's/.*--root \([^ ]*\).*/\1/p')
      if [ -n "$r" ] && under "$r" && [ ! -d "$r" ]; then kind=resident; where="$r（もう無い）"; else continue; fi ;;
    *http.server*|*jwebserver*|*SimpleHTTPServer*)
      d=$(printf '%s' "$cmd" | sed -n 's/.*--directory[ =]\([^ ]*\).*/\1/p')
      c=$(cwd_of "$pid")
      case "$d" in /*) ;; ?*) d="$c/$d" ;; esac
      if { [ -n "$d" ] && under "$d"; } || { [ -n "$c" ] && under "$c"; }; then kind=server; where=${d:-$c}; else continue; fi ;;
  esac
  if [ -z "$kind" ]; then
    exe=${cmd%% *}; exe=${exe##*/}
    case "$exe" in
      java|python|python3|python3.*|Python|bash|sh|zsh|fge-go|flix|ffmpeg|Blender|blender|make|gmake) ;;
      *) continue ;;
    esac
    c=$(cwd_of "$pid")
    if [[ "$cmd" == *"$root"* || "$cmd" == *"$root_alt"* ]]; then kind=$exe; where=$c
    elif [ -n "$c" ] && under "$c"; then kind=$exe; where=$c
    else continue; fi
  fi
  found+=("$pid	$pgid	$(secs_of "$etime")	$kind	$where	$cmd")
done < <(ps -axww -o pid=,ppid=,pgid=,etime=,command=)

if [ ${#found[@]} -eq 0 ]; then
  echo "[strays] $root から起こして取り残された物は無い"
  exit 0
fi
echo "[strays] $root から起こして取り残された物（親がいない）: ${#found[@]} 個"
printf '  %-7s %-7s %-9s %s\n' PID 経過 種類 場所
for f in "${found[@]}"; do
  IFS=$'\t' read -r pid pgid s kind where cmd <<<"$f"
  printf '  %-7s %-7s %-9s %s\n' "$pid" "$(human "$s")" "$kind" "${where:-$(printf '%s' "$cmd" | cut -c1-100)}"
done

if [ "${KILL:-}" != 1 ]; then
  echo "  止めるのは make strays KILL=1（${age_min} 分より長く走っている物だけ。AGE=<分> で変える）"
  exit 0
fi

# 止める: chrome とプロセスの組の頭は組ごと、ほかは子ごと。TERM → 3 秒 → まだ居れば KILL。
tree() { local p=$1; echo "$p"; for c in $(pgrep -P "$p"); do tree "$c"; done; }
targets=()
for f in "${found[@]}"; do
  IFS=$'\t' read -r pid pgid s kind where cmd <<<"$f"
  [ "$s" -ge $((age_min * 60)) ] || { echo "  残す（${age_min} 分より新しい）: $pid $kind"; continue; }
  if [ "$pgid" = "$pid" ]; then
    targets+=($(ps -axo pid=,pgid= | awk -v g="$pgid" '$2 == g { print $1 }'))
  else
    targets+=($(tree "$pid"))
  fi
done
if [ ${#targets[@]} -eq 0 ]; then echo "[strays] 止めた物は無い"; exit 0; fi
kill -TERM "${targets[@]}" 2>/dev/null
sleep 3
left=()
for p in "${targets[@]}"; do kill -0 "$p" 2>/dev/null && left+=("$p"); done
[ ${#left[@]} -eq 0 ] || { kill -KILL "${left[@]}" 2>/dev/null; sleep 1; }
still=()
for p in "${targets[@]}"; do kill -0 "$p" 2>/dev/null && still+=("$p"); done
if [ ${#still[@]} -eq 0 ]; then
  echo "[strays] 止めた: ${#targets[@]} 個（ps で消えたのを確かめた）"
else
  echo "[strays] 止まらない物が残った: ${still[*]}"; exit 1
fi
