mod Hand {
    use View.World

    pub def hand(ctx: Int32, w: World): Int32 = ctx + w#speed
}
