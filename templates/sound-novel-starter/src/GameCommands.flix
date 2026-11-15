// GameCommands — このゲームだけの演出コマンド（テンプレートの表 Commands.all() の後ろに足す）と、<<bg>> の切り替えをゲームが持つ口。
// 足したコマンドは Commands.execute が同じように引き、make talk-vocab が vocab.json に書き出して bin/fge yarn build が検査する。
// 後に残る値は Stage の props（PropertyTween）に game. で始まる鍵で書き、GameView が読んで描く。
// そうすればセーブ・settle・素材待ちはテンプレートの道をそのまま通る（Saves や WorldRead を直さない）。
// 人物・背景・覆いを替える時は、台本と同じ 1 行を Commands.applyText で当てる（needs は Commands.needsOfText）。
//
//   use fge::YarnCommands
//   use fge::YarnCommands.Param
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

    /// <<bg>> の切り替えをゲームが持つか（3D の部屋を歩いて替わる、など）。prev = 今の背景（背景が無い間は novel.backdrops.json の initial）、
    /// to = 替える先、switch = 台本の transition・pace・ease。Some なら、その秒だけ続きの台詞を待たせ、音を物語の時計で鳴らし、
    /// 切り替えの間は GameView.backdrop が今の背景をそのまま描く（前の背景は stage#under・始めた時刻は stage#fadeFrom・秒は stage#fadeSeconds）。
    /// None なら台本の transition と time= でテンプレートが重ねる。ゲームの素材がまだ届いていない時も None（2D で替わる）。
    /// Silent の当て直しとスキップ中（ctx#instant）は呼ばれない。
    pub def backdropSwitch(_ctx: Commands.Ctx, _prev: Option[Stage.Shot], _to: Stage.Shot, _switch: Stage.Switch): Option[Stage.GameSwitch] = None
}
