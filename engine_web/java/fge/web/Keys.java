package fge.web;

import org.teavm.jso.JSBody;

/**
 * キーの表。fge-web.js が keydown・keyup（とスマホの重ね絵のボタン）で書き、ゲームは毎コマ読む。
 * 押したフラグは 1 回読まれるまで残す（1 コマより短い押しを落とさない）。窓やタブが裏に回ったら全部離す。
 * キーの名前は KeyboardEvent.code（"KeyZ"・"ArrowUp" など）。
 */
public final class Keys {
    private Keys() { }

    /** code のキーが今押されているか、前に読んでから押されたか。 */
    @JSBody(params = {"code"}, script = "return fgeKeyDown(code);")
    public static native boolean isDown(String code);
}
