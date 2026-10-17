# assets/sfx

このフォルダの `.wav` は手で置いた録音ではなく、`make render-all` が `src/render/SfxRender.flix` から生成する成果物です。
音を変えたいときは `.wav` を直接編集せず、次のどちらかを直して `make render-all` し直してください。

- 音量・高さ・長さ … `assets/race.sfxtune.json`（Studio のフォームからも触れます）
- 音そのものの組み立て … `src/render/SfxRender.flix` の合成レシピ

どの出来事でどれが鳴るかは `src/Sounds.flix`、一覧は `README.md` の「音」の節にあります。
