// Tests for AudioUtil — pure audio utility functions

// ========================================================================
// alFormat
// ========================================================================

@Test
def testAlFormatMono8(): Unit \ Assert =
    Assert.assertEq(expected = AudioUtil.alFormatMono8(), AudioUtil.alFormat(1, 8))

@Test
def testAlFormatMono16(): Unit \ Assert =
    Assert.assertEq(expected = AudioUtil.alFormatMono16(), AudioUtil.alFormat(1, 16))

@Test
def testAlFormatStereo8(): Unit \ Assert =
    Assert.assertEq(expected = AudioUtil.alFormatStereo8(), AudioUtil.alFormat(2, 8))

@Test
def testAlFormatStereo16(): Unit \ Assert =
    Assert.assertEq(expected = AudioUtil.alFormatStereo16(), AudioUtil.alFormat(2, 16))

// ========================================================================
// findDataChunkOffset
// ========================================================================

@Test
def testFindDataChunkAtStart(): Unit \ Assert =
    // "data" chunk immediately at the search offset
    let getByte = i -> match i {
        case 12 => 100i8   // 'd'
        case 13 => 97i8    // 'a'
        case 14 => 116i8   // 't'
        case 15 => 97i8    // 'a'
        case _  => 0i8
    };
    let getInt = _i -> 0;
    let result = AudioUtil.findDataChunkOffset(getByte, getInt, 64, 12);
    Assert.assertEq(expected = Some(12), result)

@Test
def testFindDataChunkAfterFmt(): Unit \ Assert =
    // "fmt " chunk (size=16) at offset 12, then "data" at offset 36
    let getByte = i -> match i {
        case 12 => 102i8   // 'f'
        case 13 => 109i8   // 'm'
        case 14 => 116i8   // 't'
        case 15 => 32i8    // ' '
        case 36 => 100i8   // 'd'
        case 37 => 97i8    // 'a'
        case 38 => 116i8   // 't'
        case 39 => 97i8    // 'a'
        case _  => 0i8
    };
    let getInt = i -> match i {
        case 16 => 16      // fmt chunk size
        case _  => 0
    };
    let result = AudioUtil.findDataChunkOffset(getByte, getInt, 64, 12);
    Assert.assertEq(expected = Some(36), result)

@Test
def testFindDataChunkSkipsMultipleChunks(): Unit \ Assert =
    // "fmt " (size=16) at 12, "LIST" (size=8) at 36, "data" at 52
    let getByte = i -> match i {
        case 12 => 102i8   // 'f'
        case 13 => 109i8   // 'm'
        case 14 => 116i8   // 't'
        case 15 => 32i8    // ' '
        case 36 => 76i8    // 'L'
        case 37 => 73i8    // 'I'
        case 38 => 83i8    // 'S'
        case 39 => 84i8    // 'T'
        case 52 => 100i8   // 'd'
        case 53 => 97i8    // 'a'
        case 54 => 116i8   // 't'
        case 55 => 97i8    // 'a'
        case _  => 0i8
    };
    let getInt = i -> match i {
        case 16 => 16      // fmt chunk size
        case 40 => 8       // LIST chunk size
        case _  => 0
    };
    let result = AudioUtil.findDataChunkOffset(getByte, getInt, 64, 12);
    Assert.assertEq(expected = Some(52), result)

@Test
def testFindDataChunkNotFound(): Unit \ Assert =
    // No "data" chunk within limit
    let getByte = _i -> 0i8;
    let getInt = _i -> 0;
    let result = AudioUtil.findDataChunkOffset(getByte, getInt, 12, 12);
    Assert.assertEq(expected = (None: Option[Int32]), result)


// ========================================================================
// formatOf / framesOf（ステレオの WAV）
// ========================================================================

def le16Of(v: Int32): List[Int32] = Int32.remainder(v, 256) :: v / 256 :: Nil

def le32Of(v: Int32): List[Int32] = List.append(le16Of(Int32.remainder(v, 65536)), le16Of(v / 65536))

def tagOf(s: String): List[Int32] = String.toList(s) |> List.map(Char.toBmpCodePoint)

/// RIFF の頭 + LIST（4 バイト）+ fmt（channels・rate・16bit）+ data（dataSize バイトの 0）。
def wavWithListFirst(channels: Int32, rate: Int32, dataSize: Int32): Vector[Int32] =
    List.flatten(
        tagOf("RIFF") :: le32Of(0) :: tagOf("WAVE") ::
        tagOf("LIST") :: le32Of(4) :: tagOf("INFO") ::
        tagOf("fmt ") :: le32Of(16) :: le16Of(1) :: le16Of(channels) :: le32Of(rate) ::
        le32Of(rate * 2 * channels) :: le16Of(2 * channels) :: le16Of(16) ::
        tagOf("data") :: le32Of(dataSize) :: List.repeat(dataSize, 0) :: Nil) |> List.toVector

def formatOfBytes(v: Vector[Int32]): Option[(Int32, Int32, Int32)] =
    let at = i -> if (i < Vector.length(v)) Vector.get(i, v) else 0;
    AudioUtil.formatOf(i -> Int32.truncateToInt8(at(i)),
                       i -> at(i) + at(i + 1) * 256 + at(i + 2) * 65536 + at(i + 3) * 16777216,
                       Vector.length(v))

/// fmt の前に LIST があっても、ステレオ・44100Hz・16bit と読める（決まった 22 バイト目を読まない）。
@Test
def testFormatOfFindsFmtAfterList(): Unit \ Assert =
    Assert.assertEq(expected = Some((2, 44100, 16)), formatOfBytes(wavWithListFirst(2, 44100, 8)))

/// ステレオ 16bit は 4 バイトで 1 組: 16 バイトは 4 組（モノラルなら 8 組）。ループ点はこの組の番号。
@Test
def testFramesOfCountsStereoPairs(): Unit \ Assert =
    Assert.assertEq(expected = (4, 8), (AudioUtil.framesOf(16, 2, 16), AudioUtil.framesOf(16, 1, 16)))
