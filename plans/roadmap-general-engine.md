# 汎用のエンジンへの道筋（メモ・未着手）

2026-11-26 に人と話した事のメモ。計画ではない（段ごとの計画は、Bistro の差の表 `plans/engine-bistro-gap.md` が出てから別に立て、レビューに通す）。

## 目標

- 当面: **Amazon Lumberyard Bistro を Blender どおりの見た目で 60 fps**（PC）。スマホは面と絵を削って動けばよい。
- その先: **PC でも Godot 4.8 に並ぶ**。web では Godot より上を狙う（Godot の web の書き出しは今も WebGL2 の Compatibility だけで、SSAO・SSR・SDFGI・volumetric fog が使えない）。

## 進み方の決め方（負荷）

足す絵の技（SSAO・SSR・カスケード）は GPU の仕事で、重さはどのエンジンでもほぼ同じ。M 系の Mac なら全部足しても 10〜14 ms 前後の見込み（推測）。
壁はこのエンジン特有の **毎コマの CPU**（World から場面を組み直す）。Bistro の PC の窓の CPU で決める:

| Bistro の CPU（PC の窓） | 進み方 |
|---|---|
| 4 ms 以下 | 絵の技を足す（段 1 へ） |
| 4〜8 ms | 両方を少しずつ |
| 8 ms 超 | 技の前に CPU を削る（GraalVM の native・持ち越しの範囲を広げる・毎コマの組み直しを減らす） |

参考: MoltenVK の素朴な描き手で、M1 Pro・1080p の Bistro は 256 fps（CPU draw 0.055 ms・GPU 3.1 ms・draw 約 132 本・影の地図 1 枚）。

## 次の目標の 3 本（推す順・まだ取っていない）

どれも Godot の場面の形式（.tscn・.res）なので、glb へ写すには Godot の editor が要る。取る時はファイル名・取り元・大きさを示して許しを取る。

| 順 | 場面 | 大きさ・条件 | 試される物 | コード |
|---|---|---|---|---|
| 1 | [Abandoned Spaceship](https://github.com/perfoon/Abandoned-Spaceship-Godot-Demo)（Godot 4.0） | 238 MB・素材 CC BY-NC 4.0・コード MIT | lightmap・SSAO・SSIL・volumetric fog・TAA・反射プローブ・頂点の色の地面・画面の中の映像 | ほぼ無い（絵の段） |
| 2 | [TPS デモ](https://github.com/godotengine/tps-demo)（Godot 公式） | 803 MB・素材 CC BY 3.0・コード MIT | 骨つきのキャラと敵・粒・発光・GI・反射。遊び 1 本 | 三人称の操作・敵の AI・弾・扉・アニメの状態遷移 |
| 3 | [Forest](https://github.com/Lakshman-YT/Forest-Godot4)（Godot 4.6.3） | 159 MB・リポの license 無し（Sketchfab の素材ごとに条件が違う → 手元の試しだけ・公開しない） | 地形・大量の葉・風・LOD | キャラの歩き・地形の当たり |

順の理由: 宇宙船は Bistro の段 1 の技の確かめの続きで、光はベイク済み（走る時の GI が要らない）。TPS で絵からゲームの部品へ。森は重さが一番きつく、地形が独自形式なので最後。

## 段の見立て（推測の実時間）

| 段 | 届く絵 | 足す物 | 大きさ |
|---|---|---|---|
| 1 | Bistro を Blender どおり | カスケードの影・SSAO・contact shadows・SSR・bloom と色の仕上げ・TAA・異方性フィルタ | 30〜40 時間 |
| 2 | ジャングル・Sponza・宇宙船 | 葉の透過・volumetric fog・clustered lighting・lightmap の道か SSIL・LOD・遮蔽の間引き | 50〜70 時間 |
| 3 | Godot の SDFGI 並み | 走る時に計算する GI | 100 時間超。並ぶかは後で決める（ベイクで代える道もある） |

相談事: 描き手が GL・WebGPU・CPU（SoftRaster・描き出しと gallery）の 3 つあり、gl-parity でそろえている。画面の上の技を 3 つとも書くと手間がほぼ 3 倍。**画面の上の技は GPU の描き手だけ・CPU の描き出しには入れない** と決めるかは engine の決まりの変更なので、段 1 の計画で案を並べて決める。

## ゲームの部品（TPS で要る）

今ある（11-26 に api-digest で確認）: `CollisionWorld3d`（箱を xz の格子で引く）・カプセル・`Ray3d`・`Skin3d`・`AnimationClip3d`・`Pose3d.blend`・`PostProcess`（トーンマップ ACES・Reinhard と露出）・lightmap・MultiMesh3d・staticGroup。

無い: 物理の剛体・navmesh・3D の粒・アニメの状態遷移。

TPS ではゲーム側で書ける形: 敵の経路は床の格子の A*・弾は光線の当たり・アニメの状態遷移は状態の enum と `Pose3d.blend`・粒は MultiMesh3d の板。engine に入れるのは、2 本目のゲームで同じ物が要った時（層を置く物差しと同じ）。

## 3 本が通ったら何と言えるか

描き手としては Godot の 3D に近い段（写実の PBR の屋外・ベイクした光と空気・骨つきのキャラの遊び・大量の葉と地形。2D・ドット絵・ノベル・HD-2D・PS1 風は既にある）。それでも汎用と言うには、絵の外が足りない:

| 分野 | 今 | 汎用のエンジンが普通に持つ物 |
|---|---|---|
| 物理 | 箱とカプセルの当たり・光線だけ | 剛体・関節・布・車 |
| AI の部品 | 無い | navmesh・経路・群れ |
| アニメ | 姿勢を混ぜる所まで | 状態遷移の表・IK・root motion |
| 音 | 2D の音 | 3D の音（距離・方向・残響） |
| 作る道具 | Studio は凍結中・コードと Doc で作る | 場面を置くエディタ |
| 配る先 | ブラウザ・PC（JVM・native は試作） | スマホのアプリ・ゲーム機 |
| 周り | このリポジトリだけ | 素材の店・追加機能・人の集まり |

TPS で物理・経路・アニメの状態遷移を部品にすれば、上の 3 行はかなり埋まる。

## 立ち位置

Godot・Unity と同じ土俵で全部を揃えるより、違う強みで汎用を名乗る:

- **エージェントが作るエンジン**: 描き出しが決定的で絵の退行を SHA で止められる・テープで遊びを再生できる・型と lint で誤った書き方を止める。人がエディタで置く代わりに、エージェントがコードと Doc で組む前提。
- **web が一級**: WebGPU で PC と同じ絵を web に出せる。

3 本が通った時の言い方: 「エージェントが作る、web でも PC でも Godot の PC 並みの絵が出る、汎用の 2D と 3D のエンジン」。そこから先は、物理・3D の音・配る先をどこまで広げるかを決める段。

## 参考に見た物（11-26）

- Godot 4.8（ベータ）の screen space shadows: https://x.com/wrobot123/status/2125700052584661096
- Godot のジャングルの場面（葉の透過・霧の中の光・AO・色の仕上げ）: https://x.com/wrobot123/status/2125278299785998716
- Godot の巨大構造物の風景（霧と構図・草原。今の engine で射程内、足りないのは草を風で揺らす頂点シェーダー）: https://x.com/Botan_cr/status/2123891690796921170
- Opus 5.5 + Godot + Blender の 2.5D の RPG（遊んだ映像をモデルに見せて直す作り方は `/render-loop`・テープと同じ考え）: https://x.com/rewind02/status/2125558708339884408
- 次の段の候補: Intel の新しい Sponza（GI）・NVIDIA Emerald Square（約 1,005 万三角形・CC BY-NC-SA 3.0・広さと LOD）・Beeple Zero Day（灯りの数）
