# ゲームの src/*.flix から pub の定義（def / enum / type / trait / eff / struct）と mod、
# 各ファイル冒頭の doc コメントの 1 行目を引き出す（正規表現だけの最小版。型検査はしない）。
# mk/game.mk の src-index（FORMAT=md: ファイル別の見出し + 行番号つきの箇条）と
# src（FORMAT=flat: 「ファイル:行: 定義」の 1 行ずつ。grep で絞る）から呼ぶ。
FNR == 1 {
    head = ""; inHead = 1
    if (FORMAT == "md") printf "\n## %s\n", FILENAME
}
inHead {
    line = $0
    if (line ~ /^[ \t]*$/) next
    if (line ~ /^[ \t]*(\/\/+|\/\*+|\*)/) {
        sub(/^[ \t]*(\/\/+|\/\*+|\*+)[ \t]*/, "", line)
        sub(/[ \t]*\*\/[ \t]*$/, "", line)
        if (line != "" && head == "") {
            head = line
            if (FORMAT == "md") printf "%s\n\n", head
        }
        next
    }
    inHead = 0
}
/^[ \t]*(pub[ \t]+((opaque|lawful|sealed)[ \t]+)*(def|enum|type|trait|eff|struct)|mod)[ \t]/ {
    d = $0
    sub(/^[ \t]+/, "", d)
    sub(/[ \t]*(=|\{)[ \t]*$/, "", d)
    if (length(d) > 160) d = substr(d, 1, 157) "..."
    if (FORMAT == "md") printf "- %d: `%s`\n", FNR, d
    else printf "%s:%d: %s\n", FILENAME, FNR, d
}
