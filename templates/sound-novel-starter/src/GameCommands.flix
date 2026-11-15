// GameCommands — このゲームだけの演出コマンド（テンプレートの表 Commands.all() の後ろに足す）。
// 足したコマンドは Commands.execute が同じように引き、make talk-vocab が vocab.json に書き出して bin/fge yarn build が検査する。
// 後に残る値は Stage の props（PropertyTween）に game. で始まる鍵で書き、GameView が読んで描く。
// そうすればセーブ・settle・素材待ちはテンプレートの道をそのまま通る（Saves や WorldRead を直さない）。
//
//   def hop(): Commands.Command[Stage.Stage] =
//       let who = Param.name("name", Nil) |> Param.at(1) |> Param.required;
//       { spec = YarnCommands.spec("hop", "跳ねる", Param.erase(who) :: Nil), timing = Commands.Timing.Timed,
//         apply = (ctx, a, st) -> Ok(({ props = PropertyTween.trigger(PropertyTween.triggerKey("game.hop.${Param.get(who, a)}"),
//                                                                      ctx#now, 0.0, 0.4, st#props) | st }, Nil)),
//         needs = Commands.noAssets }
mod GameCommands {

    /// このゲームが足すコマンド（名前はテンプレートの表と重ねない）。
    pub def all(): List[Commands.Command[Stage.Stage]] = Nil
}
