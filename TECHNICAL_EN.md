# Squeeze: Technical Documentation and Internal Architecture

[ 🇮🇹 Italiano ](TECHNICAL.md) · [ 🇬🇧 English ](TECHNICAL_EN.md) · [ ⬅️ Back to README ](README_EN.md)

This document provides a deep dive into the internal architecture, engineering decisions, low-level binary mechanisms, and processing pipelines of **Squeeze** (`squeeze.ps1` and `squeeze.py`).

It is intended for developers, sysadmins, video/audio encoding enthusiasts, and anyone curious about what happens under the hood.

---

## Table of Contents

1. [Design Philosophy and System Requirements](#1-design-philosophy-and-system-requirements)
2. [Dual Implementation: PowerShell 5.1 vs. Python 3](#2-dual-implementation-powershell-51-vs-python-3)
3. [Environment Detection and Hardware Probing (`Test-Tools`)](#3-environment-detection-and-hardware-probing-test-tools)
4. [Video Pipeline: Cascading Architecture and HEVC](#4-video-pipeline-cascading-architecture-and-hevc)
   - 4.1 Stream Selection and Sanitization (`-map`, `-dn`)
   - 4.2 Colorimetry Preservation and xvYCC Normalization
   - 4.3 NVENC (NVIDIA) Fallback Ladder
   - 4.4 QSV (Intel) Fallback Ladder
   - 4.5 CPU x265 Fallback
   - 4.6 Atomic Writes (`.part`), Size Guards, and Cleanup
5. [Quality Measurement: VMAF and SSIM](#5-quality-measurement-vmaf-and-ssim)
   - 5.1 VMAF Calculation with Multi-Tier Hardware Acceleration
   - 5.2 ImageMagick 7 and Normalized SSIM Parsing
   - 5.3 Closed-Loop Auto-Retry Algorithm
6. [Photo Pipeline: Subsampling and Metadata Preservation](#6-photo-pipeline-subsampling-and-metadata-preservation)
   - 6.1 The Chroma Subsampling Pitfall in ImageMagick
   - 6.2 Heuristic Pre-Filtering on Estimated Quality
   - 6.3 Deep Metadata Diffing with ExifTool
7. [Audio Pipeline: Binary Ogg Header Rewriting](#7-audio-pipeline-binary-ogg-header-rewriting)
   - 7.1 The Multiple Artist Problem in ffmpeg
   - 7.2 Native FLAC Vorbis Comment Binary Parser
   - 7.3 Native RIFF INFO Binary Parser for WAV
   - 7.4 Ogg Packet Rewriting Engine and CRC-32 Calculation
   - 7.5 Cover Art Handling Strategy
8. [Configuration, Schema Migration, and Compatibility](#8-configuration-schema-migration-and-compatibility)

---

## 1. Design Philosophy and System Requirements

Squeeze is built upon core engineering tenets:

1. **Zero Third-Party Runtime Dependencies**:
   - On Windows: a single `.ps1` script running natively on **stock PowerShell 5.1** (Windows 10/11) without installing modules from PSGallery.
   - On Linux: a single `.py` script relying solely on the **Python 3.9+ standard library** (no `pip` packages or virtualenvs).
   - Binary CLI dependencies are limited to proven industry standards: `ffmpeg`/`ffprobe`, `ImageMagick 7`, and optionally `exiftool`.
2. **Absolute Source Data Integrity**:
   - Source files are never modified, overwritten, or deleted.
   - All processing creates temporary `.part` files in designated target folders (`out/` or `opus/`), renamed atomically only when the process exits with return code `0`.
   - Any unexpected interruption (Ctrl+C, crash, muxer error) triggers cleanup handlers (`finally` blocks in PowerShell / Python and `SIGINT`/`SIGTERM` signal traps) that clean up incomplete `.part` files.
3. **Active Bloat Rejection (No-Bloat Policy)**:
   - If an encoded file ends up equal to or larger than the source (common with already heavily compressed video or audio), the output is immediately discarded and logged as `SKIPPED: output larger`.
4. **Objective Perceptual Verification**:
   - No blind assumptions: video and photo compressions can be bound to quantitative thresholds (VMAF for video, SSIM for photos) with a closed-loop feedback mechanism (automatic retry with higher quality).

---

## 2. Dual Implementation: PowerShell 5.1 vs. Python 3

While both files provide the identical centered interactive TUI and manage the same JSON configuration schema, each runtime environment requires specific architectural handling:

### PowerShell 5.1 (`squeeze.ps1`)
- **UTF-8 Compatibility**: PowerShell 5.1 defaults to ANSI/Windows-1252 for script parsing. `squeeze.ps1` is saved with **UTF-8 with BOM** (`0xEF, 0xBB, 0xBF`), allowing the parser to render ANSI box-drawing borders and accented characters cleanly. At startup, it programmatically sets `[Console]::OutputEncoding` and `$OutputEncoding` to `[System.Text.Encoding]::UTF8`.
- **`$ErrorActionPreference = 'Continue'`**: in PowerShell 5.1, setting `Stop` causes the script to abort the instant any native CLI tool (like `ffmpeg` or `identify`) outputs progress or notices to `stderr`. The script intentionally keeps `'Continue'` and explicitly inspects `$LASTEXITCODE`.
- **Numeric Parsing and Invariant Culture**: on non-English Windows locales (such as Italian), `,` is the decimal separator. All floating-point parsing explicitly uses `$script:Inv = [Globalization.CultureInfo]::InvariantCulture` (`[double]::Parse($val, $script:Inv)`) to prevent crashes when parsing ffmpeg or ImageMagick output numbers.
- **Argument Splatting**: commands are invoked using argument arrays (`& ffmpeg @args`), avoiding fragile string concatenation with spaces or bracket characters.
- **Folder Picker**: utilizes native Windows `System.Windows.Forms.FolderBrowserDialog` when the user presses Enter on an empty input.

### Python 3 (`squeeze.py`)
- **Standard Library Only**: relies exclusively on `csv`, `json`, `math`, `os`, `re`, `shutil`, `struct`, `subprocess`, `sys`, `tempfile`, `time`, and `pathlib.Path`.
- **Stdout/Stderr Reconfiguration**: calls `sys.stdout.reconfigure(encoding='utf-8', errors='replace')` for reliable output across POSIX terminal emulators.
- **Cross-Platform Dialog Cascades**: tries `tkinter.filedialog`, falling back to `zenity --file-selection --directory` or `kdialog --getexistingdirectory`.
- **Signal Handling**: installs `signal.signal(signal.SIGINT, handler)` to catch keyboard interrupts and clean up active `.part` files before exit.

---

## 3. Environment Detection and Hardware Probing (`Test-Tools`)

Merely checking if a binary exists in `PATH` does not ensure hardware acceleration is functional or that the installed GPU driver supports a given profile.

At startup, `Test-Tools` runs real synthetic tests:

```
[PATH Check] ---------> ffmpeg, ffprobe, magick, exiftool
                              │
                              ▼
[Codec Inspection] ---> ffprobe -encoders, -decoders, -filters
                              │
                              ▼
[NVENC Probe] --------> ffmpeg -f lavfi -i color=c=black:s=64x64:d=0.2
                        -c:v hevc_nvenc -profile:v main10 -f null -
                              │
                              ▼
[QSV Probe] ----------> ffmpeg -f lavfi -i color=c=black:s=64x64:d=0.2
                        -c:v hevc_qsv -f null -
                              │
                              ▼
[Filter Verification]-> Verify libvmaf, libopus availability
                              │
                              ▼
[Metric Inspection] --> magick -list metric (search for "SSIM")
```

1. **NVENC Hardware Probe**:
   Executes a 0.2-second test encode of a synthetic 10-bit video stream (`color=c=black:s=64x64:d=0.2`) to `-f null -`. If NVIDIA drivers are missing or the GPU cannot handle `hevc_nvenc` with the `main10` profile, NVENC is disabled for the session, avoiding mid-batch encoding failures.
2. **QSV Hardware Probe**:
   Executes a synthetic test using `hevc_qsv`. On Windows it utilizes Direct3D 11 (`-hwaccel d3d11va`); on Linux it interacts with `/dev/dri/renderD128` (VA-API / Intel iHD).
3. **Automatic Resolution Cascade (`Resolve-Encoder`)**:
   When set to `auto`, the priority ladder is:
   ```text
   NVENC (if hardware OK) ──> QSV (if hardware OK) ──> x265 (CPU, universal fallback)
   ```

---

## 4. Video Pipeline: Cascading Architecture and HEVC

`Invoke-VideoJob` (PowerShell) / `invoke_video_job` (Python) orchestrates the video recompression pipeline.

### 4.1 Stream Selection and Sanitization (`-map`, `-dn`)

Modern action and mirrorless cameras (DJI Osmo Action 3/4/5, Pocket, DJI drones, Sony Alpha series) pack multiple auxiliary data streams into MP4/MOV containers. A naive `ffmpeg -i input.mp4 output.mp4` command frequently fails:

1. **Cover Art & MJPEG Streams**: cameras often embed a static JPEG thumbnail as an auxiliary video stream. By specifying `-map 0:V:0` (capital `V`), ffmpeg selects only the primary **true video stream**, ignoring attached pictures/poster frames that would otherwise be encoded into an unintended second HEVC track or cause muxer conflicts.
2. **Proprietary Data Tracks (`-dn`)**:
   - DJI cameras record `djmd` (telemetry, gyro, accelerometer) and `dbgi` tracks.
   - Sony cameras record `rtmd` (Real-Time Metadata: per-frame ISO, f-stop, shutter, autofocus points).
   The standard ffmpeg MP4 muxer cannot handle these tracks and fails with `Could not find tag for codec none in stream #...`. The explicit `-dn` (*drop data*) switch strips these streams cleanly.
3. **Optional Audio Streams (`-map 0:a?`)**:
   The trailing `?` makes audio mapping optional. If a clip has no audio (e.g. DJI motion lapses or 120/240 fps slow-motion clips without sound), ffmpeg will not fail with a missing stream error.
4. **Metadata & Apple Compatibility**:
   - `-map_metadata 0 -movflags use_metadata_tags+faststart`: transfers container tags (creation date, camera model); `faststart` moves the `moov` atom header to the beginning of the file for instant streaming playback.
   - `-tag:v hvc1`: forces the FourCC tag to `hvc1` instead of `hev1`. This is mandatory for compatibility with Apple ecosystems (macOS QuickTime, iOS/iPadOS, Safari) and social media uploaders that reject `hev1`.

### 4.2 Colorimetry Preservation and xvYCC Normalization

A frequent pitfall when recompressing DJI (D-Log M, HLG) or Sony (S-Log3, HLG, Cine) footage is color shifting or crushed shadows due to missing or misread VUI (*Video Usability Information*) parameters.

Before encoding, `Get-VideoInfo` extracts four properties via `ffprobe`:
- `color_primaries` (e.g., `bt709`, `bt2020`)
- `color_transfer` / `color_trc` (e.g., `bt709`, `arib-std-b67`, `smpte2084`, `iec61966-2-4`)
- `color_space` / `colorspace` (e.g., `bt709`, `bt2020nc`)
- `color_range` (e.g., `tv` / limited, or `pc` / full)

These tags are explicitly passed to the encoder (`-color_primaries`, `-color_trc`, `-colorspace`, `-color_range`). As a result:
- HLG profiles (BT.2020 / ARIB STD-B67) remain recognized as true HDR by Smart TVs and players.
- D-Log M and flat log profiles retain their native logarithmic curve without gamma distortion.

#### The Sony xvYCC Correction (`NormalizeXvYCC`)
Many Sony Alpha cameras shoot SDR video within the BT.709 color gamut but tag the transfer function as `iec61966-2-4` (xvYCC). Many modern video players and web browsers misinterpret xvYCC as Rec.601, resulting in washed-out colors or clipped black levels.
When `NormalizeXvYCC` is enabled (default: `YES`), Squeeze detects `color_trc == 'iec61966-2-4'` and applies `-color_trc bt709`.
**Crucial technical detail**: this changes only the VUI metadata tag in the HEVC bitstream; no destructive video filter (`-vf`) or pixel color space remapping is applied. The underlying pixel values remain bit-for-bit intact.

### 4.3 NVENC (NVIDIA) Fallback Ladder

The NVIDIA NVENC pipeline applies high-quality encoding parameters across a 3-tier fallback strategy:

```
Tier 1: Full GPU Pipeline (CUDA Hardware Decode + NVENC HQ Encode)
  ├── -hwaccel cuda -hwaccel_output_format cuda
  ├── -preset p7 -tune hq -multipass fullres
  ├── -rc vbr -cq <N> -b:v 0 -rc-lookahead 32 -spatial-aq 1 -temporal-aq 1
  └── (If source is 4:2:2 or 4:4:4, skips directly to Tier 2)
         │
         ▼ Failure / CUDA Error
Tier 2: Software Decode + NVENC HQ Encode
  ├── CPU Software Decode
  ├── -vf "format=p010le" (10-bit) or "format=nv12" (8-bit)
  └── -c:v hevc_nvenc (with Tier 1 HQ tuning)
         │
         ▼ Failure / Resource limits / Old ffmpeg build without advanced AQ
Tier 3: Safe NVENC Mode
  └── -c:v hevc_nvenc -preset p7 -rc vbr -cq <N> (without spatial-aq/temporal-aq/lookahead)
```

- **Preset p7**: the highest-quality NVENC algorithmic preset (7 B-frame evaluation passes).
- **Multipass fullres**: full-resolution dual-pass hardware bitrate analysis.
- **Spatial AQ & Temporal AQ**: dynamic quantizer allocation based on spatial variance (complex textures vs. smooth surfaces) and temporal variance (motion between consecutive frames). Prevents banding in gradients (such as clear skies) and macroblocking in shadowy areas.

### 4.4 QSV (Intel) Fallback Ladder

Intel Quick Sync Video (`hevc_qsv`) provides exceptional hardware encoding efficiency on Intel Iris Xe, Arc, and Arrow Lake / Core Ultra processors:

1. **Tier 1 (Full HW)**:
   ```bash
   -hwaccel qsv -hwaccel_output_format qsv -i INPUT \
   -c:v hevc_qsv -preset veryslow -global_quality <N> -look_ahead 1
   ```
2. **Tier 2 (SW Decode + HW Encode)**:
   If the QSV hardware demuxer fails or if the source has a chroma sampling format unsupported by the hardware decoder (e.g. Sony 10-bit 4:2:2 XAVC HS):
   - Software CPU decoding.
   - Format normalization filter: `-vf "format=p010le"` (for 10-bit) or `-vf "format=nv12"` (for 8-bit).
   - Hardware encoding via `hevc_qsv`.

### 4.5 CPU x265 Fallback

When no compatible GPU is present or when CPU encoding is chosen:
```bash
-c:v libx265 -preset medium -crf <N> -pix_fmt yuv420p10le -x265-params log-level=error
```
x265 achieves the highest possible compression density per bit, at the cost of significantly longer processing times.

### 4.6 Atomic Writes (`.part`), Size Guards, and Cleanup

File writes on disk adhere to strict reliability procedures:
1. Target outputs are created with a temporary extension: `destination/file.mp4.part`.
2. If ffmpeg exits with an error code, the exception block immediately removes the `.part` file.
3. Upon clean completion:
   - If `Size(part) >= Size(source)`: the file is deleted (`Remove-Item` / `os.unlink`) and cataloged as `SKIPPED: output larger`.
   - If `Size(part) < Size(source)`: the file is atomically renamed to the final destination name (`file.mp4`).
4. **Timestamp Preservation**: when `PreserveDates` is enabled, original `CreationTime` and `LastWriteTime` timestamps are replicated onto the new output using .NET APIs (`[System.IO.File]::SetCreationTime`) or POSIX `os.utime`.

---

## 5. Quality Measurement: VMAF and SSIM

### 5.1 VMAF Calculation with Multi-Tier Hardware Acceleration

Netflix's **VMAF** (*Video Multi-Method Assessment Fusion*) combines visual information fidelity (VIF), detail loss metric (DLM), and temporal motion analysis to predict human subjective evaluation (MOS).

The measurement command invoked by `Measure-Vmaf`:
```bash
ffmpeg -hide_banner -nostats \
  <hwaccel_args> -i ENCODED \
  <hwaccel_args> -i ORIGINAL \
  -lavfi "[0:v:0][1:v:0]libvmaf=n_threads=<cores>:n_subsample=<N>" \
  -an -sn -dn -f null -
```

#### Subsampling Optimization (`n_subsample`)
Evaluating VMAF on every single frame (`n_subsample=1`) is computationally demanding and often takes longer than the encoding pass itself.
Squeeze defaults to `n_subsample=5`, analyzing **one frame every five**:
- *Statistical Reliability*: on a 50 or 60 fps clip, evaluating every fifth frame provides 10-12 samples per second, which reliably captures quality drops in fast-moving scenes or abrupt cutaways.
- *Performance Gain*: yields a **4x to 5x** speedup during quality measurement.

#### Cascading Hardware Decode
To avoid CPU saturation during dual-stream VMAF playback, Squeeze tries hardware decoding for both streams:
1. If the active encoder is NVENC, tries `-hwaccel cuda` for both inputs.
2. If the active encoder is QSV or CUDA fails, tries `-hwaccel qsv`.
3. Falls back to software CPU decoding if hardware filters or pixel formats mismatch.

### 5.2 ImageMagick 7 and Normalized SSIM Parsing

For JPEG images, Squeeze computes Structural Similarity (SSIM, theoretical range 0 to 1, where 1 represents identity).

Comparison command:
```bash
magick compare -metric SSIM ENCODED.JPG ORIGINAL.JPG null:
```

#### ImageMagick 7 Output Normalization
Recent versions of ImageMagick 7 print SSIM as a tuple `score (distance)`, for example: `0.993421 (0.003289)`.

In ImageMagick, the distance in parentheses is defined as:
$$\text{distance} = \frac{1 - \text{SSIM}}{2} \iff \text{SSIM} = 1 - (2 \times \text{distance})$$
*(equivalent to: `distance = (1 - SSIM) / 2` ⟺ `SSIM = 1 - (2 * distance)`)*

Squeeze uses a regular expression to detect the presence of the distance in parentheses; if found, it recalculates the exact SSIM score using the inverse formula, ensuring consistent metric interpretation across different OS builds and ImageMagick releases.

### 5.3 Closed-Loop Auto-Retry Algorithm

When automated quality verification is enabled (`AutoRetry = $true`):

```
                  ┌────────────────────────┐
                  │   Encode Video/Photo   │
                  └───────────┬────────────┘
                              │
                              ▼
                  ┌────────────────────────┐
                  │   Measure VMAF/SSIM    │
                  └───────────┬────────────┘
                              │
                    Score >= Threshold?
                    ├── YES ─> [Status: OK] Save and proceed
                    └── NO  ─> Retries remaining?
                               ├── YES: Decrement CQ/CRF (or Increase Photo Q)
                               │        Re-encode file
                               └── NO:  [Status: BELOW THRESHOLD] Keep best result
```

- **Video Quality Step**:
  - NVENC: `-3 CQ` per retry (floor limit `CQ = 14`).
  - QSV: `-3 global_quality` per retry (floor limit `15`).
  - x265: `-2 CRF` per retry (floor limit `12`).
- **Photo Quality Step**:
  - `+3 Q` (ImageMagick JPEG quality) per retry (ceiling limit `98`).

---

## 6. Photo Pipeline: Subsampling and Metadata Preservation

### 6.1 The Chroma Subsampling Pitfall in ImageMagick

An obscure behavior in ImageMagick 7: when encoding a JPEG image with `-quality 90` (or above) without explicitly setting chroma subsampling, ImageMagick automatically switches from standard subsampling (`4:2:0` or `4:2:2`) to `4:4:4` (no chroma subsampling).
Consequently, a compressed image at Q90 can turn out **larger than the camera original** due to doubled chroma data!

To avoid this:
1. Squeeze inspects the input image beforehand:
   ```bash
   magick identify -format "%w|%h|%Q|%[jpeg:sampling-factor]" "INPUT.JPG[0]"
   ```
2. Extracts the exact source sampling factor (e.g., `2x2,1x1,1x1` for 4:2:0, or `2x1,1x1,1x1` for 4:2:2).
3. Explicitly enforces this factor during encoding:
   ```bash
   magick INPUT.JPG -quality 90 -sampling-factor <original_factor> \
     -interlace JPEG -define jpeg:optimize-coding=true JPEG:OUTPUT.JPG.part
   ```
   - `-interlace JPEG`: generates progressive JPEG, saving 2-4% in file size and improving web streaming.
   - `-define jpeg:optimize-coding=true`: optimizes Huffman tables.
   - No `-strip` or `-auto-orient`: preserves full EXIF orientation and internal camera tags.

### 6.2 Heuristic Pre-Filtering on Estimated Quality

JPEG compression is inherently lossy. Recompressing an image originally saved at quality 80 with a target of 90 only introduces generation loss and inflates file size.

Squeeze extracts `%Q` (the estimated quantization table rating):
- If `Estimated_Q <= PhotoQuality`: the image is skipped with status `ALREADY COMPRESSED (Q~N)`.

### 6.3 Deep Metadata Diffing with ExifTool

When `exiftool` is installed, `Test-PhotoMetadata` performs deep tag comparison:
```bash
exiftool -a -u -G1 -s "FILE.JPG"
```
Tags are compared while filtering out natural container changes:
- Regex-ignored groups: `System`, `File`, `ExifTool`, `Composite`, `JFIF`, `MPF*`.
- Sony MPF (*Multi-Picture Format*, an embedded 1080p preview) is discarded by ImageMagick: the diff identifies this and verifies whether real photographic EXIF/MakerNote tags are preserved.

---

## 7. Audio Pipeline: Binary Ogg Header Rewriting

Converting uncompressed or lossless audio (**WAV**, **FLAC**) to high-efficiency **Opus** (`libopus`, Ogg container) presents metadata challenges.

### 7.1 The Multiple Artist Problem in ffmpeg

Under the Vorbis comment specification (used by Ogg, FLAC, and Opus), **comment keys may be repeated**. When multiple artists collaborate on a track, the standard representation is:
```
ARTIST=Artist A
ARTIST=Artist B
```
Modern media servers and players (MusicBee, Foobar2000, Navidrome, Plex, Apple Music) require separate tags to index artists individually.

However, ffmpeg's audio muxer:
- Merges duplicate artist tags into a single semicolon-delimited string: `ARTIST=Artist A; Artist B`.
- Provides no CLI option to write duplicate Vorbis comments into the output stream.

To resolve this limitation, Squeeze uses a two-stage approach:
1. Encodes the audio stream with ffmpeg with **metadata stripping**:
   ```bash
   ffmpeg -i INPUT.FLAC -map 0:a:0 -vn -map_metadata -1 \
     -c:a libopus -b:a 160k -vbr on -application audio -f opus OUTPUT.OPUS.part
   ```
2. **Injects metadata at the binary level**, directly rewriting the Ogg header pages in the `.opus.part` file.

### 7.2 Native FLAC Vorbis Comment Binary Parser

Squeeze implements a standalone FLAC binary parser:
1. Validates the 4-byte `fLaC` header.
2. Iterates through metadata blocks (`METADATA_BLOCK_HEADER`, 4 bytes):
   - Bit 0: `is_last` block flag.
   - Bits 1-7: `block_type`. Block type `4` corresponds to `VORBIS_COMMENT`.
   - Bytes 1-3: 24-bit big-endian block length.
3. Within `VORBIS_COMMENT`:
   - Reads 32-bit LE vendor length and vendor string.
   - Reads 32-bit LE `user_comment_list_length`.
   - Iterates through each comment, extracting 32-bit LE length and UTF-8 decoded `KEY=value` strings.
All duplicate keys and original ordering are preserved.

### 7.3 Native RIFF INFO Binary Parser for WAV

For WAV files:
1. Validates the master chunk: `RIFF....WAVE`.
2. Searches for the `LIST` chunk with list type `INFO`.
3. Maps standard 4-character RIFF FourCC tags to Vorbis comment equivalents:
   - `INAM` → `TITLE`
   - `IART` → `ARTIST`
   - `IPRD` → `ALBUM`
   - `ICMT` → `COMMENT`
   - `IGNR` → `GENRE`
   - `ICRD` / `YEAR` → `DATE`
   - `ITRK` → `TRACKNUMBER`

If no RIFF INFO chunk is found, Squeeze falls back to `ffprobe`.

### 7.4 Ogg Packet Rewriting Engine and CRC-32 Calculation

An Ogg bitstream is structured into logical pages. Each page begins with the 4-byte capture pattern `OggS`:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| capture_pattern: "OggS"       | version (0)   | header_type   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| granule_position (64 bit)                                     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| bitstream_serial_number (32 bit)                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| page_sequence_number (32 bit)                                 |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| CRC_checksum (32 bit)                                         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| page_segments | segment_table (1..255 bytes)...               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| payload data...                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

In Opus streams:
- **Page 0** stores the `OpusHead` packet (codec parameters, sample rate, channels).
- **Page 1** stores the `OpusTags` packet (Vorbis comments).
- **Subsequent pages** store encoded audio frames.

#### Rewriting Algorithm (`Set-OpusTags` / `set_opus_tags`)
1. Reads original Page 1 generated by ffmpeg and extracts the encoder vendor string (e.g. `Lavf61.1.100`).
2. Constructs the new `OpusTags` packet in memory:
   - 8-byte magic: `OpusTags`.
   - Vendor string (32-bit LE length + UTF-8 string).
   - User comment count (32-bit LE).
   - Tag sequence (32-bit LE length + `KEY=value` in UTF-8).
3. **Lacing Value Calculation**:
   Ogg segments packet data in chunks of at most 255 bytes. A packet of size $L$ is partitioned into $n$ 255-byte segments followed by a terminating segment of $L \pmod{255}$ bytes.
4. If the new header exceeds one page capacity (255 segments $\times$ 255 bytes $\approx 64$ KB), it spans multiple sequential pages with continuation header flags.
5. **Ogg CRC-32 Calculation**:
   The checksum is located at byte offset 22. To calculate it:
   - Zero out the 4-byte checksum field (`0x00, 0x00, 0x00, 0x00`).
   - Compute the CRC-32 over all header and body bytes of the page using the standard Ogg generator polynomial:
     $$P(x) = x^{32} + x^{26} + x^{23} + x^{22} + x^{16} + x^{12} + x^{11} + x^{10} + x^8 + x^7 + x^5 + x^4 + x^2 + x + 1$$
     with generator value `0x04C11DB7`.
   - Write the resulting 32-bit checksum in little-endian format at offset 22.
6. Subsequent audio pages have their `page_sequence_number` adjusted and their CRC checksums recalculated if the modified header altered the total page count.

### 7.5 Cover Art Handling Strategy

Although the Opus specification allows embedded artwork in a `METADATA_BLOCK_PICTURE` block inside `OpusTags`, embedding is discouraged in practice:
- It inflates the initial Ogg header, introducing streaming latency.
- Many embedded automotive and portable players crash when metadata pages exceed standard sizes.

Squeeze adopts a clean file-based approach:
1. Strips all embedded picture streams from `.opus` files.
2. Scans the source directory for standalone album art (`cover.jpg`, `folder.jpg`, `front.png`, etc.) and copies it into the `opus/` destination folder.
3. If no external image exists, extracts any embedded FLAC artwork via ffmpeg (`-map 0:v:0 -c copy cover.jpg`) and saves it as a sidecar image.

---

## 8. Configuration, Schema Migration, and Compatibility

Configuration is stored in `squeeze.config.json` next to the script.

### Safe Import Policy (`Import-Config`)
To prevent configuration drift or unexpected type injections:
1. The script maintains a fixed dictionary/hashtable containing all known keys and their default fallback values.
2. During `Import-Config`, the loaded JSON is filtered: **only keys already declared in the internal schema are imported**. Unrecognized keys are discarded.

### Automatic Legacy Migration
If `squeeze.config.json` does not exist but `dji-compress.config.json` is found (the project's previous name):
1. Values are automatically imported from `dji-compress.config.json`.
2. A new `squeeze.config.json` is written immediately.
3. Users upgrade seamlessly without losing customized settings.

---

[ ⬅️ Back to README ](README_EN.md)
