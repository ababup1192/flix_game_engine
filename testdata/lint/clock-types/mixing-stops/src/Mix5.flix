// 描く側の進みを、起点と違う時計で読む。
mod Mix5 {
    pub def progress(w: Shapes.World): Float64 =
        Timeline.progressOn(w#story, w#hitAt, Shapes.Beat.Hit, Shapes.cue())
}
