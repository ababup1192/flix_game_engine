# make help / make help-all の一覧を Makefile の行末の説明から組む（エンジンの Makefile と mk/game.mk が共有）。
#
# 書き方（Makefile の側）:
#   ターゲット: 前提 ## 説明            … make help にも make help-all にも出る（日ごろ使う物）
#   ターゲット: 前提 ### 説明           … make help-all にだけ出る
#   説明の頭に「引数 | 」を書くと（区切りは最後の「 | 」）「make ターゲット 引数」の形で出す（ターゲットの % は引数で置き換える）
#   ##@ 見出し                         … 次の見出しまでの物をまとめる見出し（中身が 1 つも出ない時は出さない）
#   ##> 使い方 | 説明 / ###> …         … ターゲットの行でない物を 1 行出す（表から作るターゲットなど）
#
# ALL=1 で ### の物も出す。
# WhyNot: 説明に ; を書かない — lint-makefile-dup が ; の後ろをレシピと読む。

function flush_head() {
  if (head != "") { printf "\n%s\n", head; head = "" }
}

# 画面の上の幅（全角は 2）。awk が字をバイトで数えるか字で数えるかで、全角 1 字の長さが 3 か 1 になる。
function vwidth(str,    wide) {
  wide = str
  gsub(/[\001-\177]/, "", wide)
  return length(str) - length(wide) + (UTF8 ? length(wide) * 2 : int(length(wide) * 2 / 3))
}

function emit(usage, desc,    pad) {
  flush_head()
  if (desc == "") { printf "  %s\n", usage; return }
  pad = 31 - vwidth(usage)
  if (pad < 1) { printf "  %s\n", usage; pad = 33 }
  else printf "  %s", usage
  printf "%" pad "s%s\n", "", desc
}

BEGIN { UTF8 = (length("名") == 1) }

# 最後の「 | 」の位置（引数の中の [A | B] を区切りと読まない）。無ければ 0。
function lastbar(str,    at, i) {
  at = 0
  while ((i = index(substr(str, at + 1), " | ")) > 0) at += i
  return at
}

function verbatim(line,    bar) {
  bar = lastbar(line)
  if (bar > 0) emit(substr(line, 1, bar - 1), substr(line, bar + 3))
  else emit(line, "")
}

/^##@ / { head = substr($0, 5); next }
/^##> / { verbatim(substr($0, 5)); next }
/^###> / { if (ALL) verbatim(substr($0, 6)); next }

/^[^#\t ]/ {
  colon = index($0, ":")
  if (colon == 0 || substr($0, colon + 1, 1) == "=") next
  mark = index($0, " ##")
  if (mark == 0 || mark < colon) next
  rest = substr($0, mark + 3)
  all_only = 0
  if (substr(rest, 1, 1) == "#") { all_only = 1; rest = substr(rest, 2) }
  if (substr(rest, 1, 1) != " ") next
  if (all_only && !ALL) next
  rest = substr(rest, 2)
  args = ""
  bar = lastbar(rest)
  if (bar > 0) { args = substr(rest, 1, bar - 1); rest = substr(rest, bar + 3) }
  else if (substr(rest, 1, 2) == "| ") rest = substr(rest, 3)
  n = split(substr($0, 1, colon - 1), names, " ")
  usage = ""
  for (i = 1; i <= n; i++) usage = usage (i > 1 ? " / " : "") names[i]
  if (index(usage, "%") > 0 && args != "") { sub(/%/, args, usage); args = "" }
  emit("make " usage (args != "" ? " " args : ""), rest)
}
