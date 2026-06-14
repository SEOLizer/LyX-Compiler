# Video Reader — VID-00..02

## Ziel
Lesen von AVI- und MP4-Containern: Metadaten (Auflösung, Dauer, FPS, Codec) und für MJPEG-AVI auch Frame-Extraktion.

## Work Packages

### VID-00 · Core Video API
**Unit:** `std/video/core.lyx`

- `VidMeta`-Struct (Offset-Konstanten, `VID_SIZE=64`)
- Format-Konstanten: `VID_FMT_AVI=1`, `VID_FMT_MP4=2`
- Codec-Konstanten: `VID_CODEC_MJPEG=1`, `VID_CODEC_H264=2`, `VID_CODEC_H265=3`, `VID_CODEC_AV1=4`, `VID_CODEC_MP4V=5`, `VID_CODEC_VP8=6`, `VID_CODEC_VP9=7`
- `VidDetectFormat(buf, len): int64`

### VID-01 · AVI Reader
**Unit:** `std/video/avi.lyx`

- RIFF/AVI-Container-Parser
- `AviMeta(buf, len, vid): int64` — extrahiert Width/Height/Duration/FPS/Codec/FrameCount
- `AviMetaFile(path, plen, vid): int64`
- `AviGetFrameCount(buf, len): int64` — zählt `00dc`-Chunks in `movi`
- `AviGetFrameOffset(buf, len, frameIdx, pFrameLen): int64` — Pointer zu Frame-Daten
- `AviExtractMjpegFrame(buf, len, frameIdx, img): int64` — nur MJPEG; delegiert an JpegDecode

### VID-02 · MP4 Reader
**Unit:** `std/video/mp4.lyx`

- ISOBMFF Box-Traversal (flat `mp4FindBox`)
- `Mp4Meta(buf, len, vid): int64` — sucht moov→mvhd (Dauer/Timescale), trak→tkhd (W/H 16.16 fixed-point), mdia→hdlr→'vide', minf→stbl→stsd (Codec 4CC)
- `Mp4MetaFile(path, plen, vid): int64`
- Version 0 und Version 1 Boxes (32- vs 64-bit Timestamps)

## Struct-Layout `VidMeta` (int64-Felder, 8 Byte je)

| Offset | Feld |
|--------|------|
| 0 | WIDTH |
| 8 | HEIGHT |
| 16 | DURATION_MS |
| 24 | FPS_NUM |
| 32 | FPS_DEN |
| 40 | FRAME_COUNT |
| 48 | FORMAT |
| 56 | CODEC |

## Nicht enthalten (Future Work)
- H.264/H.265/AV1 Pixel-Decode
- MP4 Frame-Extraktion
- Audio-Metadaten
- OpenDML-AVI (Index-basiert)
