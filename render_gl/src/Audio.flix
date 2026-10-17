// RenderAudio — OpenAL バッファ読み込みとサウンドレジストリ構築
//
// LwjglLayer.flix の loadOggToALBuffer / loadWavToALBuffer / loadAudioRegistry を移植。
// OpenAL の初期化 (alcOpenDevice 等) や再生制御は外周 (engine/ide 側) が担当する。

mod RenderAudio {
    import org.lwjgl.openal.AL10
    import org.lwjgl.openal.AL11
    import org.lwjgl.openal.SOFTLoopPoints
    import org.lwjgl.stb.STBVorbis
    import org.lwjgl.system.MemoryStack
    import org.lwjgl.system.MemoryUtil
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    import java.nio.file.Files
    import java.nio.file.Paths

    /// OGG ファイルを STBVorbis でデコードし、OpenAL バッファにアップロードする
    pub def loadOggToALBuffer(path: String): Int32 \ IO =
        let stack = MemoryStack.stackPush();
        let channelsBuf = stack.mallocInt(1);
        let sampleRateBuf = stack.mallocInt(1);
        let pcm = STBVorbis.stb_vorbis_decode_filename(path, channelsBuf, sampleRateBuf);
        if (Object.isNull(pcm)) {
            discard MemoryStack.stackPop();
            bug!("Failed to decode OGG: ${path}")
        } else {
            let channels = channelsBuf.get(0);
            let sampleRate = sampleRateBuf.get(0);
            discard MemoryStack.stackPop();
            let format = if (channels == 1) AL10.AL_FORMAT_MONO16 else AL10.AL_FORMAT_STEREO16;
            let buffer = AL10.alGenBuffers();
            AL10.alBufferData(buffer, format, pcm, sampleRate);
            MemoryUtil.memFree(pcm);
            buffer
        }

    /// WAV ファイル（16bit か 8bit・モノラルかステレオ）をパースし、OpenAL バッファにアップロードする（smpl チャンクのループ点も付ける）。
    /// ステレオはそのままステレオで鳴る。音量（setVolume）・高さ（setPitch）・ローパスはモノラルと同じに効く。
    pub def loadWavToALBuffer(path: String): Int32 \ IO =
        let wavBytes = Files.readAllBytes(Paths.get(path));
        let hdr = ByteBuffer.wrap(wavBytes);
        discard hdr.order(ByteOrder.LITTLE_ENDIAN);
        // 形式は fmt チャンクから（モノラル・ステレオどちらも。読めなければ従来どおり 44 バイトのヘッダの位置）。
        let (channels, sampleRate, bitsPerSample) =
            AudioUtil.formatOf(i -> hdr.get(i), i -> hdr.getInt(i), hdr.limit())
            |> Option.getWithDefault((Int16.toInt32(hdr.getShort(22)), hdr.getInt(24), Int16.toInt32(hdr.getShort(34))));
        let dataOffset = match AudioUtil.findDataChunkOffset(i -> hdr.get(i), i -> hdr.getInt(i), hdr.limit(), 12) {
            case Some(off) => off
            case None      => bug!("WAV data chunk not found: ${path}")
        };
        let dataSize = hdr.getInt(dataOffset + 4);
        let pcmStart = dataOffset + 8;
        let pcmBuf = MemoryUtil.memAlloc(dataSize);
        discard pcmBuf.put(wavBytes, pcmStart, dataSize);
        discard pcmBuf.flip();
        let format = AudioUtil.alFormat(channels, bitsPerSample);
        let buffer = AL10.alGenBuffers();
        AL10.alBufferData(buffer, format, pcmBuf, sampleRate);
        MemoryUtil.memFree(pcmBuf);
        // ループ点（smpl チャンク）があれば、AL_LOOPING のときに [頭, 終わり) だけを繰り返す。
        // 音源へ付ける前のバッファにしか設定できない（OpenAL Soft の AL_SOFT_loop_points の決まり）ので、ここで付ける。
        // ループ点はサンプルの組（ステレオなら左右 1 つずつ）の番号なので、左右は同じ所で継ぎ目を迎える。
        let frames = AudioUtil.framesOf(dataSize, channels, bitsPerSample);
        let points = AudioUtil.loopPointsOf(i -> hdr.get(i), i -> hdr.getInt(i), hdr.limit());
        let supported = Option.nonEmpty(points) and AL10.alIsExtensionPresent("AL_SOFT_loop_points");
        match points {
            case Some((start, end)) if end <= frames and supported =>
                let stack = MemoryStack.stackPush();
                AL11.alBufferiv(buffer, SOFTLoopPoints.AL_LOOP_POINTS_SOFT, stack.ints(start, end));
                discard MemoryStack.stackPop()
            case _ => ()
        };
        buffer

    /// 拡張子で読み方を振り分けて OpenAL バッファへ載せる。
    /// 起動時の一括読み込みと、実行中の差し替え（reloadAudio）で同じ道を通すために切り出してある。
    pub def loadBuffer(path: String): Int32 \ IO =
        if (String.endsWith({suffix = ".ogg"}, path)) loadOggToALBuffer(path)
        else loadWavToALBuffer(path)

    /// サウンドマニフェストから全音声を読み込み、AudioRegistry (名前 → OpenAL ソース ID) を返す。
    /// onProgress には「読み終えた本数 / 全本数」を渡す（起動画面が進み具合を出す）。
    pub def loadAudioRegistry(manifest: List[RenderAsset.AudioEntry],
                              onProgress: (Int32, Int32) -> Unit \ IO): RenderAsset.AudioRegistry \ IO =
        let total = List.length(manifest);
        onProgress(0, total);
        let result = List.foldLeft((acc, entry) -> {
            let (registry, done) = acc;
            let buffer = loadBuffer(entry#path);
            let source = AL10.alGenSources();
            AL10.alSourcei(source, AL10.AL_BUFFER, buffer);
            AL10.alSourcei(source, AL10.AL_LOOPING, if (entry#looping) AL10.AL_TRUE else AL10.AL_FALSE);
            println("  ${entry#path} loaded");
            onProgress(done + 1, total);
            (Map.insert(entry#name, source, registry), done + 1)
        }, (Map.empty(), 0), manifest);
        fst(result)

}
