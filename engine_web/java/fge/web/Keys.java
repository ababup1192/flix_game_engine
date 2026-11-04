package fge.web;

import org.teavm.jso.JSBody;

/**
 * キーの表。fge-web.js が keydown・keyup（とスマホの重ね絵のボタン）で書き、ゲームは毎コマ読む。
 * 1 コマより短い押しも、次のコマの間は押されたことにする（Browser.beginFrame で切り替える）。ウィンドウやタブが裏に回ったら全部離す。
 * キーの名前は KeyboardEvent.code（"KeyZ"・"ArrowUp" など）。
 */
public final class Keys {
    private Keys() { }

    /** code のキーが今押されているか、このコマの前に押されたか。読んでも表は変えない。 */
    @JSBody(params = {"code"}, script = "return fgeKeyDown(code);")
    public static native boolean isDown(String code);
}
