# jdk.mk — 配った engine（go/ の無い engine）が使う JDK を、engine の版ごとに 1 つに決める。
# 読むのは bin/java-resolve.sh（sh）・fge engines install（Go の fgehome.ReadJDKSpec）・make check-docs-sync。
# 置き場は ${FGE_HOME:-~/.flix_ge}/jdk/<FGE_JDK_VENDOR>-<FGE_JDK_VERSION>/bin/java。
#
# WhyNot: devbox の JDK とそろえない — devbox の JDK は OS ごとに違い（macOS は Zulu・Linux は nixpkgs の OpenJDK）、
# 配った engine は devbox を使わない。check-docs-sync が見るのは主な版（25）が同じことだけ。
# WhyNot: JSON にしない — make と sh と Go の 3 つが読む。`KEY := 値` の 2 行ならどれも追加の道具なしで読める。
FGE_JDK_VENDOR  := zulu
FGE_JDK_VERSION := 25.0.3
