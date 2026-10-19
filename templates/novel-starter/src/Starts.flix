// Starts — 始まりの登録簿（App.withStarts）。名前と引数から、新しく作った初期の World を場面へ組む。
// 起動（START="choice id=clock"）・リモートの POST /start・flow の `start choice`・テストの App.startOrBug が同じ表を引く。
// 節の名前（id）は台本 novel.story.json の sections[].id。知らない id は近い名前の案つきで断る。
mod Starts {
    use fge::{App, Suggest}

    /// 登録簿。先頭が起動の既定。
    pub def all(): List[App.Start[World.World]] =
        { name = "title", doc = "表紙（起動の既定。決定で物語がはじまる）", args = Map.empty(),
          build = (w, _) -> Ok(w) } ::
        { name = "section", doc = "台本の節（id = 節の名前。既定は台本の start）の 1 行目を読んでいる所", args = Map.empty(),
          build = (w, args) -> sectionOf(args, w) |> Result.map(section -> World.enter(section#id, 0, reading(w))) } ::
        { name = "choice", doc = "節（id。既定は台本の start）を読み終えて選択肢が開き、問いの文を出し終えた所", args = Map.empty(),
          build = (w, args) -> sectionOf(args, w) |> Result.flatMap(section -> match section#ask {
              case Some(_) => Ok(World.revealLine(World.enter(section#id, List.length(section#beats), reading(w))))
              case None    => Err("節 '${section#id}' には選択肢が無い")
          }) } :: Nil

    /// 表紙から物語へ入った World（灯りは全部点いている）。節の行は enter が載せる。
    def reading(w: World.World): World.World =
        { phase = World.Phase.Story, lightsOut = 0, lampOutAt = None | w }

    /// 引数 id の節（無ければ台本の start）。
    def sectionOf(args: Map[String, String], w: World.World): Result[String, StoryDoc.Section] =
        let id = Map.getWithDefault("id", StoryDoc.rec(w#story)#start, args);
        let known = StoryDoc.rec(w#story)#sections |> List.map(section -> section#id);
        StoryDoc.sectionOf(id, w#story) |> Option.toOk("節 '${id}' は台本に無い${Suggest.hint(id, known)}")
}
