// 校舎の見た目（階ごとの集まり）と当たり判定の箱の食い違い（World.collisionProblems）: 見えない壁と、外へ抜ける穴が無い。
// 配置の表（assets/school/layout.json）を置き直したら、このテストが止める。
mod TestSchoolCheck {
    use fge::{App, HeadlessLoad, Resources}

    def app(): App.App[Resources.With[Res.Res, World.World], {}] \ IO = run { Game.app(HeadlessLoad.handle(Controls.loadDocs)) } with Fs.FileRead.runWithIO

    @Test
    def testSchoolHasNoInvisibleWallOrEscapeHole(): Unit \ Assert + Fs.FileRead + IO =
        let started = App.startOrBug(app(), "at", Map.empty());
        Assert.assertEq(expected = Nil, Resources.read((res, _) -> World.collisionProblems(res), started))
}
