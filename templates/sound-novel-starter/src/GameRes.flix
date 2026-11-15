// GameRes — このゲームだけの描く元（ゲームの Doc と、読み込んだ素材の表）。Res#game に入り、GameView・GameCommands・GameBoot が読む。
// テンプレートは中身を見ない。欄は Rec に足し、読み込みは load、保存即反映は docRows に書く（テンプレートの Controls と Res は直さない）。
//   pub type alias Rec = { scenes = ScenesDoc.Doc, rooms = Rooms.Table, roomsPending = BackgroundLoad.Pending }
//   pub def docRows() = Resources.reloadUnnamedRow(ScenesDoc.path(), res -> Res.withGame(withScenes(ScenesDoc.load(ScenesDoc.path()), res#game), res), (_, w) -> w) :: Nil
// 後から届く素材（3D の部屋・ドットのアトラス）を読み始めるのは GameBoot。
mod GameRes {
    use fge::{DocTable, Resources}

    /// このゲームの描く元（テンプレートは持つ物が無い）。欄を持つゲームは Rec を書いて 1 case の enum で包む
    /// （pub enum Data(Rec)。型検査が大きな record を展開しないため）。
    pub enum Data {
        case Empty
    }

    /// 起動時と描き出しとテストが読む（Controls.loadRes）。読めない Doc は既定で続ける（fail-open）。Doc を読むゲームは効果に \ Fs.FileRead を足す。
    pub def load(): Data = Data.Empty

    /// ゲームの Doc を保存即反映する行（Controls.docTable の後ろに足す）。
    pub def docRows(): List[DocTable.Entry[Resources.With[Res.Res, World.World]]] = Nil
}
