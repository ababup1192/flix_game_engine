# カメラと投影（ズーム・揺れ・見下ろしの前後・疑似 3D）

> [docs/module-index.md](../module-index.md) の分野の 1 つ。1 行 = 1 件で、`make module Q=<語>` が行ごとに引く。
> 型と引数は `make api Q=<名前>`、使い方は `engine_world/src/<名前>.flix` 冒頭の doc。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| カメラでズームする・追いかける | CameraRig |
| 被弾・着弾で画面を揺らす（減衰ノイズの画面揺れ・screen shake） | CameraRig（addTrauma / tick / shakeOffset） |
| 見下ろしで「足元が下にある物ほど手前」に並べる（人が木の裏に回る） | ZStack.zIndex(Depth.orderAt(足元の y), 1 人の葉) |
| 一人称・疑似 3D（2.5D）で世界の点を画面へ落とす（透視除算・近クリップ・逆投影・距離霧） | Persp |
| マス目の迷路から「カメラに見える壁の面」だけを集める（内部面・裏面は落とす） | WallFaces |
| world 座標を画面へ落とす・戻す（横視点・見下ろし・斜め見下ろし・一人称の 4 通り） | ViewProjection（横視点と見下ろしは CameraRig へ委譲・一人称は Persp・見下ろしの前後は Depth） |
| 「画面のここを 16px 直したい」を配置 Doc の数字へ翻訳する | ViewProjection.inverseOf → toWorldDelta（斜め見下ろしでは x だけ動かしても world は 2 軸とも動く） |
| 斜め見下ろしで画面を覆うマスを列挙する（外接だけでは四隅と高いマスが落ちる） | ViewProjection.quarterOf → coveringCells（軸に平行な盤は Grid.cellsIn） |
| 距離の遠→近の描画順（zIndex）を振る（疑似 3D の上塗り） | Painter（見下ろしの前後は Depth） |

## モジュール 1 行紹介

- **CameraRig** — world のどこを・どれだけズームして映すかを描画物の列に掛ける道具箱。
- **Depth** — 見下ろし画面で「足元が下にある物ほど手前」を重なり順（zIndex）の数として決める。ZStack の木では orderAt(足元の y) を zIndex に渡す。帯は ZStack.of に奥 → 手前で積む。
- **Persp** — 疑似 3D（2.5D）カメラの数学一式。世界の点を前後 fwd・左右 lat に分解し、透視除算で画面へ落とす。近クリップ・逆投影（depthAtY）・距離霧の式も持つ。焦点距離や霧の色の実体はゲーム側の意見（theme Doc など）。
- **WallFaces** — マス目の迷路から「カメラに見える壁の境界面」だけを集める純幾何。壁どうしの内部面と、カメラに背を向けた裏面は落とす。solid の判定は関数で注入する（MapDoc の形を知らない）。
- **Painter** — カメラからの距離で遠→近に並べ、zBase から zStride 刻みの zIndex を振る（画家の順）。疑似 3D は z バッファを持たないので、遠い物から上塗りして前後を作る。見下ろしの前後は Depth（別物）。
- **ViewProjection** — world 座標を画面（design px）へ写す 4 通り（Side / TopDown / Quarter / FirstPerson）と、その逆算。**斜め見下ろし（Quarter）の world↔screen はここにしかない**（横視点・見下ろしは CameraRig の centerOn / toWorldPos へそのまま渡す・一人称は Persp・見下ろしの前後は Depth）。**「その写し方にその操作が有るか」は Option で返さず、持ち物を取り出す口（quarterOf / firstPersonOf / inverseOf）で 1 回だけ捌く** — 取り出した後の toWorld / toWorldDelta / coveringCells / yawOf / distanceOf / visibleFraction / wallQuad は Option を返さない。Option が残るのは toScreen（カメラの後ろに来た点）だけ。画面を覆うマスの列挙は coveringCells（外接だけでは落ちるマスがある。契約は Grid.cellsIn とそろえてあり、cols / rows で盤の外を落とし margin で余分を足す）。壁の台形は wallQuad（四隅 + 描画順の dist + 模様を世界に固定する t0 / t1）。タイルの大きさ・カメラ・焦点距離は既定値を持たない（ゲーム側の意見）。
- **Viewport** — 画面の矩形の外へ出た物を見つけて返す。
