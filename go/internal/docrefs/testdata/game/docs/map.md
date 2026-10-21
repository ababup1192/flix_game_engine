# 地図

`World.step`（`src/World.flix:15`）が 1 コマ進める。場面は `World.Phase` の `Phase.Home`・`World.Phase.Fight`。

| 物 | 置き場 |
|---|---|
| 盤 | Board.swapCells・src/Board.flix |
| 消えた | World.moveTo |

`World.removedOnce` は消えた。`Board.Cell.Wall` も無い。`src/Gone.flix` も無い。`src/World.flix:999` は行が無い。
`World.flix:16` はパスの無い書き方。`docs/nowhere.md` は無い。

エンジンの物は数えない: `Clock.Time`・`App.withHudView`・`ZStack.of`・engine の `docs/pacing.md`。
仮の字も数えない: `Phase.X`・`assets/face0..7.png`・`docs/<名前>.md`・`w#turn`・`build/out.png`。
消し線の中は記録: ~~`World.oldName` を消した~~。
type alias の欄: `World.Rec.turn`。eff の op: `World.Ask.ask`。入れ子の mod: `Board.Gen.fill`。
欄の名指し: `World.Rec#turn` は在る・`World.Rec#gone` は無い。

```
World.inFence は見ない
```
