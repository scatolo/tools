# Squeeze: Documentation

[ 🇮🇹 Italiano ](README.md) · [ 🇬🇧 English ](README_EN.md) · [ 📘 Technical Docs ](TECHNICAL_EN.md)

Terminal tool (PowerShell on Windows, Python on Linux) to **shrink video, photo, and audio file sizes** from cameras like DJI Osmo Action and Sony Alpha, **with no visible difference from the original** while preserving all metadata that underlying libraries support.

Applies to `squeeze.ps1` and `squeeze.py` (DJI/Sony video, JPEG photos, and WAV/FLAC to Opus audio conversion).

---

## Table of Contents

1. [Overview](#1-overview)
2. [Requirements and Installation](#2-requirements-and-installation)
3. [Quick Start (First Run)](#3-quick-start-first-run)
4. [The Menu, Option by Option](#4-the-menu-option-by-option)
5. [Settings and Configuration File](#5-settings-and-configuration-file)
6. [How to Choose Quality](#6-how-to-choose-quality)
7. [What is Preserved and What is Lost](#7-what-is-preserved-and-what-is-lost)
8. [Output, Logs, and Statuses](#8-output-logs-and-statuses)
9. [Technical Documentation](#9-technical-documentation)
10. [Troubleshooting](#10-troubleshooting)
11. [Known Limitations and Test Status](#11-known-limitations-and-test-status)
12. [FAQ](#12-faq)
13. [Customizing the Script](#13-customizing-the-script)
14. [Glossary](#14-glossary)
15. [License](#15-license)

---

## 1. Overview

### What it does

| File Type | What happens | Quality control method |
|---|---|---|
| **Video** (`.mp4`, `.mov`) | Re-encoded to HEVC (H.265) via NVIDIA GPU (NVENC), Intel GPU (Quick Sync), or CPU (x265). Resolution and framerate remain identical. | **VMAF** (0–100) comparing output against the original |
| **Photos** (`.jpg`, `.jpeg`) | Re-encoded as JPEG at lower quality, keeping the same resolution and chroma subsampling. | **SSIM** (0–1) + metadata comparison |
| **Audio** (`.wav`, `.flac`) | Converted to **Opus** (>=128 kb/s, VBR), with all tags copied. Multiple artists are preserved as separate tags. | No metric: Opus at the selected bitrate is perceptually transparent |

### Operating Principles

- **Originals are never modified or deleted.** Video and photos go into an `out` folder, audio into an `opus` folder (both created next to the source files).
- **Quality is measured, not assumed.** If a file scores below the threshold, it is automatically re-encoded at higher quality.
- **No half-baked files.** Every file is written with a `.part` extension and renamed only upon successful completion.
- **Resumable.** If interrupted and restarted, already completed files in `out` or `opus` are skipped.

### Benchmark Results (from real-world tests)

| Source | Files | Before | After | Savings |
|---|---|---|---|---|
| DJI Osmo Action 4 (4K-ish, 2688x1512, HEVC 10-bit) | 3 clips | 147.1 MB | 64.5 MB | 56% |
| Sony Alpha (1080p50, AVC 8-bit, PCM audio) | 3 clips | 456.0 MB | 102.7 MB | 77% |

Savings depend heavily on content: dark, noisy, or highly detailed scenes compress less.

---

## 2. Requirements and Installation

### 2.1 Requirements

| Component | Required for | Notes |
|---|---|---|
| **Windows 10/11** | `.ps1` script | Run `squeeze.ps1` with PowerShell 5.1+ |
| **Linux (e.g. Fedora, Ubuntu, Arch)** | `.py` script | Run `squeeze.py` with Python 3.9+ |
| **ffmpeg + ffprobe** (*full* build) | video and audio | Requires `libx265`, `libvmaf`, `libopus`, and (for GPU) `hevc_nvenc` and/or `hevc_qsv` |
| **NVIDIA GPU (GeForce RTX 3000/4000)** + driver | video on NVIDIA GPU | Optional. NVENC encoder (`hevc_nvenc`) with highest quality preset (`p7`, fullres multipass, spatial/temporal AQ) |
| **Intel GPU with Quick Sync** + driver | video on Intel GPU | Optional (recommended for Intel CPUs). On Windows uses D3D11, on Linux `/dev/dri/renderD128` |
| **ImageMagick 7** (`magick` command) | photos | Must support the `SSIM` metric |
| **exiftool** | optional | Enables much deeper and more accurate photo metadata diffing |

You can use only the video, photo, or audio features: features missing dependencies are automatically disabled.

### 2.2 Installation (Windows)

**Step 1. Install dependencies** (from PowerShell):

```powershell
winget install Gyan.FFmpeg
winget install ImageMagick.ImageMagick
winget install OliverBetz.ExifTool
```

During ImageMagick installation, make sure to keep the option to add `magick` to your PATH checked.

**Step 2. Run the script.**
Place `squeeze.ps1` in a folder, unblock it with `Unblock-File` if downloaded from the web, then launch it:
```powershell
powershell -ExecutionPolicy Bypass -File "squeeze.ps1"
```

> If you edit the PS1 script manually, save it as **UTF-8 with BOM** to preserve accented characters in PowerShell 5.1.

### 2.3 Installation (Linux - e.g. Fedora 44)

**Step 1. Install packages via RPM Fusion** (needed for HEVC and libvmaf):

```bash
sudo dnf install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
sudo dnf install ffmpeg intel-media-driver ImageMagick perl-Image-ExifTool
```
*Note: `intel-media-driver` enables Quick Sync (iHD) via VA-API for Intel Arc / Arrow Lake iGPUs. For NVIDIA, install the proprietary `akmod-nvidia` drivers with NVENC support.*

**Step 2. Run the script.**
Run the Python script, which has zero third-party PIP dependencies (standard library only):
```bash
chmod +x squeeze.py
./squeeze.py
```

---

## 3. Quick Start (First Run)

Recommended workflow when using the tool on a new camera:

1. **Launch the script** and check the summary box at the top: `Encoder` will display a green badge *[GPU NVENC]* (if an NVIDIA GPU is found), *[GPU QSV]* (if an Intel GPU is found), or a yellow badge *[CPU x265]*; `VMAF` and `Photo` will display their respective status badges.
2. **`[1]` Select folder.** Press Enter to open the native graphical folder picker (or drag-and-drop / paste the folder path).
3. **`[2]` Analyze.** Review detected codecs, resolutions, bitrates (video), and estimated quality (photos) to understand what you are about to compress.
4. **Test on a few files first.** For video, use **`[11]`** (comparative test on a clip or snippet with multiple CQ/CRF values) or compress 2–3 clips with `[4]`. For photos, use `[9]` (test on a single photo).
5. **Inspect output files with your own eyes.** Especially dark clips, skies, and high-motion scenes. Metrics don't catch every localized flaw (see [6.4](#64-limits-of-metrics)).
6. **Set your chosen parameters** in `[6]` (or start with the *Archive* preset).
7. **Run the full batch** using `[4]` (video) and/or `[7]` (photos).
8. **Check the summary.** Review any files listed under *TO CHECK*: keep the original for those.
9. **Delete originals only after** spot-checking results.

---

## 4. The Menu, Option by Option

```
╭──────────────────────────────────────────────────────────────────────────────╮
│                       S Q U E E Z E   •   Media Compressor                   │
│                  Video HEVC (NVENC/QSV/x265) • Photos • Audio                │
├──────────────────────────────────────────────────────────────────────────────┤
│ Folder     : [DIR]            C:\Media\Project                               │
│ Encoder    : [GPU NVENC]      NVIDIA NVENC (CQ 24, preset p7)                │
│ VMAF       : [OK]             Threshold 96 • Auto-retry YES (1 in 5 frames)  │
│ Photo      : [OK]             ImageMagick (Q90, SSIM 0.990, exiftool)        │
│ Audio      : [OK]             WAV/FLAC -> Opus 160 kb/s • Cover YES          │
├──────────────────────────────────────────────────────────────────────────────┤
│   FOLDER AND ANALYSIS                                                        │
│    [1] Select source folder (drag-and-drop or press Enter to browse)         │
│    [2] Analyze folder (scan video, photos, and audio)                        │
│   VIDEO (HEVC + VMAF)                                                        │
│    [3] Compress VIDEO (compression only)                                     │
│    [4] Compress VIDEO + verify VMAF + auto-retry                *recommended │
│    [5] Verify VIDEO only (existing outputs)                                  │
│    [11] Quality test on a VIDEO (compare multiple CQ/CRF values)             │
│   PHOTOS (JPEG + SSIM)                                                       │
│    [7] Compress JPEG PHOTOS (+ verify SSIM & metadata + retry)               │
│    [8] Verify PHOTOS only (existing outputs)                                 │
│    [9] Quality test on a PHOTO (compare multiple Q values)                   │
│   AUDIO (WAV/FLAC -> Opus)                                                   │
│    [10] Compress AUDIO (WAV/FLAC -> Opus with tags & cover art)              │
│   SYSTEM                                                                     │
│    [6] Settings                                        [0] Save & Exit       │
╰──────────────────────────────────────────────────────────────────────────────╯
```

| Option | What it does | Notes |
|---|---|---|
| **1** | Set the source folder. | Remembered across sessions. Accepts drag-and-drop or, if Enter is pressed empty, opens the native OS folder picker dialog. |
| **2** | Lists found media with technical parameters. | Read-only. Displays video color profiles (`Trc`), resolutions, codecs, and audio files. |
| **3** | Compresses videos without VMAF verification. | Faster, but provides no objective quality guarantee. |
| **4** | Compresses, measures VMAF, and automatically retries sub-threshold files. | Standard mode. Displays a dynamic progress bar. Existing outputs are verified, not re-encoded. |
| **5** | Measures VMAF on already existing outputs. | Useful to check files produced earlier or with different settings. |
| **11** | Quality test on a video clip or snippet across multiple CQ/CRF values. | Compares size, savings %, bitrate, and VMAF in a benchmark table without writing to `out`. |
| **6** | Settings menu. | See [Section 5](#5-settings-and-configuration-file). |
| **7** | Compresses JPEG photos, then runs SSIM + metadata checks + retry. | Automatically skips photos already compressed below or equal to target quality. |
| **8** | Verifies SSIM and metadata on existing photo outputs. | Useful to check existing compressed photos. |
| **9** | Compresses **one** photo across multiple quality levels and displays size, SSIM, and metadata diff. | Uses a temporary directory cleaned up on exit. Does not write to `out`. |
| **10** | Converts **WAV/FLAC** files to **Opus** in the `opus` folder, copying tags and cover art. | See [7.3](#73-audio-wavflac-opus). |
| **0** | Saves configuration to JSON and exits. | |

Before every batch, the script displays a summary (file count, encoder, quality settings, destination) and asks for **confirmation** (`y`/`n`).

---

## 5. Settings and Configuration File

### 5.1 Settings Menu (`[6]`)

| Key | Setting | Default | Range | Meaning |
|---|---|---|---|---|
| `1` | Encoder | `auto` | auto / nvenc / qsv / x265 | `auto` attempts in order: NVENC -> QSV -> x265 |
| `2` | NVENC Quality (CQ) | 24 | 10–40 | Lower = higher quality and larger file |
| `3` | NVENC Preset | `p7` | p1...p7 | `p1` (fastest) ... `p7` (maximum HQ quality) |
| `4` | QSV Quality (`global_quality`) | 24 | 10–40 | Lower = higher quality and larger file |
| `5` | x265 Quality (CRF) | 20 | 10–35 | Lower = higher quality on CPU x265 |
| `6` | x265 Preset | `medium` | ultrafast...slower | Slower = slightly smaller file |
| `7` | VMAF Threshold | 96 | 80–99 | Below this score, the video is re-encoded |
| `8` | VMAF Subsampling | 5 | 1–30 | Analyzes 1 in every N frames (1 = all frames, very slow) |
| `9` | Auto-Retry | YES (max 2) | 1–5 attempts | Retries sub-threshold files with higher quality |
| `G` | Photo Quality (JPEG) | 90 | 50–98 | Starting quality for `magick -quality` |
| `H` | Photo SSIM Threshold | 0.990 | 0.95–0.9999 | Below this, the photo is re-encoded at higher Q |
| `I` | Progressive JPEG | YES | YES/NO | Slightly smaller files; streamable in web browsers |
| `J` | Photo Verification | YES | YES/NO | SSIM + metadata comparison |
| `C` | Video Audio Mode | `auto` | auto / copy / aac | `auto`: PCM becomes AAC 320k, others copied |
| `D` | AAC Bitrate | 320 | 128–512 kb/s | Used only when audio is converted to AAC |
| `K` | Opus Bitrate | 160 | 128–512 kb/s | Average VBR bitrate for audio conversion (`[10]`) |
| `L` | Audio Cover Art | YES | YES/NO | Copies/extracts album art to the `opus` folder |
| `A` | Include Subfolders | NO | YES/NO | Recursive mode; preserves folder hierarchy in `out` |
| `B` | Overwrite Output | NO | YES/NO | If NO, existing files in `out` are not re-encoded |
| `M` | Preserve File Timestamps | YES | YES/NO | Copies original creation and modification dates |
| `N` | Output Directory | `<source>\out` | path | Empty = default |
| `E` | xvYCC → bt709 (Sony) | YES | YES/NO | Updates transfer tag only, no pixel modifications |
| `F` | Copy XML/SRT/XMP sidecars | YES | YES/NO | Copies sidecar files next to videos/photos |
| `P` | Quick Presets | | | See below |

### 5.2 Quick Presets (`P`)

| Preset | NVENC CQ | QSV | x265 CRF | VMAF Threshold | Photo Q | SSIM Threshold |
|---|---|---|---|---|---|---|
| **Safe** | 21 | 21 | 18 | 97 | 93 | 0.993 |
| **Archive** (recommended) | 24 | 24 | 20 | 96 | 90 | 0.990 |
| **Compact** | 27 | 27 | 22 | 95 | 85 | 0.985 |

Presets do not alter auxiliary options (audio, subfolders, sidecars, etc.).

### 5.3 Configuration File `squeeze.config.json`

Created alongside the script and updated whenever settings change. Can also be edited manually when the script is closed:

```json
{
  "SourceDir": "",
  "OutDir": "",
  "Recurse": false,
  "Encoder": "auto",
  "NvencCq": 24,
  "NvencPreset": "p7",
  "QsvQuality": 24,
  "X265Crf": 20,
  "X265Preset": "medium",
  "VmafThreshold": 96,
  "VmafSubsample": 5,
  "AutoRetry": true,
  "MaxRetries": 2,
  "Overwrite": false,
  "PreserveDates": true,
  "AudioMode": "auto",
  "AacBitrate": 320,
  "NormalizeXvYCC": true,
  "CopySidecars": true,
  "SidecarExts": [".xml", ".srt", ".xmp"],
  "PhotoQuality": 90,
  "PhotoSsim": 0.99,
  "PhotoProgressive": true,
  "PhotoVerify": true,
  "PhotoExtensions": [".jpg", ".jpeg"],
  "Extensions": [".mp4", ".mov"],
  "OpusBitrate": 160,
  "OpusCover": true,
  "OpusExtensions": [".wav", ".flac"],
  "OpusCoverNames": ["cover", "folder", "front", "album"],
  "OpusCoverExts": [".jpg", ".jpeg", ".png"]
}
```

`Extensions`, `PhotoExtensions`, `SidecarExts`, `OpusExtensions`, `OpusCoverNames`, and `OpusCoverExts` can be customized here. To restore defaults, simply delete the file.

> **Automatic legacy migration:** If `dji-compress.config.json` is present and `squeeze.config.json` does not exist, settings are automatically imported and saved to `squeeze.config.json`.

---

## 6. How to Choose Quality

### 6.1 Video

`CQ` (NVENC), `global_quality` (QSV), and `CRF` (x265) **are not identical scales**: their numerical values behave slightly differently depending on encoder architectures, though NVENC CQ and QSV global_quality share comparable practical ranges.

Example measured on an 8-second DJI clip (original 45.3 MiB, 43.6 Mbps):

| QSV `global_quality` | Size | Savings | VMAF |
|---|---|---|---|
| 21 | 18.8 MiB | -59% | 99.73 |
| 24 | 12.1 MiB | -73% | 98.78 |
| 27 | 7.8 MiB | -83% | 96.68 |
| 30 | 5.2 MiB | -89% | 93.20 |
| 33 | 3.5 MiB | -92% | 87.07 |

Rule of thumb for VMAF scores:
- **Above ~95**: usually indistinguishable from source.
- **97–98 or higher**: imperceptible even in side-by-side zoomed comparison.
- **Below 93–94**: differences can become noticeable.

Recommendations:
- **Archive** (NVENC CQ 24 / QSV 24, threshold 96) is an optimal starting point.
- **NVENC CQ 27 (or QSV 27) with auto-retry enabled** maximizes space savings: easy clips remain lightweight at 27, while complex scenes are automatically re-encoded at 24 or 21.

### 6.2 Fast Video Test (`[11]`)

Use option **`[11] Quality test on a VIDEO`** before running a full batch:
1. Select any video from the source folder.
2. Choose between testing the entire clip or a short snippet (e.g. 10 seconds starting from an offset).
3. Specify quality values to evaluate (e.g. `21, 24, 27, 30`).
4. Review the generated benchmark table showing size, savings %, bitrate, VMAF score, and encoding speed (fps).
Outputs are temporary and cleaned up automatically.

### 6.3 Photos

Option `[9]` displays a test table (example values):

```
Quality   MB  Savings    SSIM    Metadata
     85  3.1  60%        0.9890  OK (118)
     90  4.2  46%        0.9930  OK (118)
     95  7.0  10%        0.9985  OK (118)
```

Choose the **lowest quality with SSIM above your threshold and metadata OK**, then set it in `[6]` → `G` with threshold `H`.

- Photos already saved at or below target quality are **skipped** (`ALREADY COMPRESSED`): recompressing them would only add generation loss.
- JPEG recompression is **always lossy**, even if imperceptible. For 100% lossless optimization, use tools like `jpegtran`.

### 6.4 Limits of Metrics

VMAF and SSIM are **averages** across frames and pixels; they may miss localized defects such as subtle color banding in gradients, shadow noise, or tiny textures. Always spot-check at least one dark clip and one high-motion scene before removing originals.

---

## 7. What is Preserved and What is Lost

### 7.1 Video

| Element | Status |
|---|---|
| Resolution, frame rate | Unchanged |
| Audio AAC (DJI) | **Copied bit-for-bit** |
| Audio PCM (Sony) | Converted to **AAC 320 kb/s** (`auto` mode); `copy` preserves PCM |
| Creation date, general container tags | Preserved (`-map_metadata 0`) |
| File system dates (creation/modification) | Copied to output |
| Color tags (primaries, transfer, matrix, range) | Extracted and passed to encoder. Exception: *xvYCC* → *bt709* (`E`, tag only) |
| QuickTime Timecode track (DJI) | Preserved in MP4 output |
| Sidecar files (`.XML`, `.SRT`, `.XMP`) | Copied into `out` |
| **DJI Data tracks** (`djmd`, `dbgi`) | **Lost**: ffmpeg's standard MP4 muxer rejects them |
| **Sony `rtmd` metadata** (per-frame ISO, shutter, aperture) | **Lost** |
| Embedded JPEG poster frame | Dropped (video stream only is selected) |

If you need gyroscope telemetry for Gyroflow or Sony per-frame camera data, **keep the original clip**.

### 7.2 Photos

| Element | Status |
|---|---|
| Resolution | Unchanged |
| Chroma subsampling (e.g. 4:2:2) | Kept identical to source |
| EXIF, ICC, XMP, IPTC | Preserved by ImageMagick (no `-strip`) |
| Metadata verification | With **exiftool**: deep tag diff; without: standard EXIF tags |
| File system dates | Copied to output |
| **Sony MPF preview** (1080p preview image embedded in Sony JPEGs) | **Lost** |
| Sony MakerNote | Retained by ImageMagick; verify with test `[9]` |

### 7.3 Audio (WAV/FLAC → Opus)

Option `[10]` converts **WAV** and **FLAC** files to **Opus** (Ogg container, `libopus` codec) inside `<source>\opus`. Audio is re-encoded using VBR at the bitrate set in `[6]` → `K` (default 160 kb/s, minimum 128).

**Metadata.** Tags are parsed natively from source files and rewritten directly into Opus:

| Element | Status |
|---|---|
| FLAC tags (Vorbis comments: `TITLE`, `ALBUM`, `DATE`, `GENRE`, `TRACKNUMBER`, etc.) | Copied identically (key and value) |
| WAV tags (RIFF `LIST/INFO` chunks: `IART`, `INAM`, `IPRD`, ...) | Mapped to standard Vorbis tags (`ARTIST`, `TITLE`, `ALBUM`, ...) |
| **Multiple artists** (multiple `ARTIST` comments) | Preserved as **distinct `ARTIST` tags** |
| **Single `ARTIST` with `;`** (e.g. `A; B`) | Split into separate `ARTIST` tags |
| Embedded artwork (`METADATA_BLOCK_PICTURE`/`COVERART`) | **Not** embedded into Opus: saved as sidecar file (see below) |
| Tag order and duplicate keys | Preserved |

> **Why ffmpeg alone is insufficient:** ffmpeg merges duplicate `ARTIST` tags into a single `A; B` string and cannot emit multiple tags with the same key. Squeeze directly rewrites the Ogg comment header pages (recalculating CRC-32 checksums) to keep multi-artist indexing functional.

**Cover Art.** Because embedded artwork in Opus is poorly supported across portable and in-car players, Squeeze (with `L` enabled):
1. Looks for an image file in the source directory named `cover`, `folder`, `front`, or `album` (`.jpg`/`.jpeg`/`.png`) and copies it to `opus/`.
2. If none is found, **extracts** the embedded picture from one of the FLAC files in the folder and saves it as `cover.jpg` (or `.png`).
3. If no artwork exists, no file is created. Existing artwork in `opus/` is never overwritten.

---

## 8. Output, Logs, and Statuses

### 8.1 Destination Folders

- Output folder: `<source>\out` (configurable via `B`); **audio** always goes to `<source>\opus`.
- With **subfolders** enabled, directory hierarchies are replicated in `out` and `opus`.
- Already processed files in target folders are **skipped** (unless `Overwrite` is enabled).
- File names and extensions are preserved (for audio, extensions become `.opus`).

### 8.2 CSV Logs

Generated upon batch completion inside `out\`:
- `log_video_YYYYMMDD_HHMMSS.csv`
- `log_photo_YYYYMMDD_HHMMSS.csv`
- `log_audio_YYYYMMDD_HHMMSS.csv`

### 8.3 Status Codes

| Status | Meaning | Action |
|---|---|---|
| `OK` | Above threshold (and photo metadata matches) | Done |
| `COMPRESSED (not verified)` | Processed in compression-only mode | Verify with `[5]`/`[8]` if needed |
| `BELOW THRESHOLD` | Scored below threshold even after retries | Keep original or increase quality |
| `CHECK METADATA` | Photo: tags missing compared to original | Keep original |
| `SKIPPED: output larger` | Encoded file was larger than source; discarded | Source was already highly compressed |
| `ALREADY COMPRESSED (Q~N)` | Photo estimated quality ≤ target quality | Lower quality setting in `G` to force |
| `EXISTING` | Output file already exists (compression-only mode) | Enable `Overwrite` to re-encode |
| `MISSING OUTPUT` | Verification mode: no corresponding output file | Compress the file first |
| `VMAF not read` / `SSIM not read` | Metric extraction failed | See [Section 10](#10-troubleshooting) |
| `VERIFICATION DISABLED` | Photo verification disabled in `J` | Re-enable in settings |
| `ERROR ...` | ffmpeg/magick failed or file corrupted | Analyze file with `[2]` |

---

## 9. Technical Documentation

For an exhaustive technical breakdown of internal architecture, binary structures, and engineering design, read:
👉 **[TECHNICAL_EN.md](TECHNICAL_EN.md)** (or Italian version: **[TECHNICAL.md](TECHNICAL.md)**).

### Summary of Internal Architecture

- **Single-file architecture**: `squeeze.ps1` (PowerShell 5.1) and `squeeze.py` (Python 3.9+ standard library).
- **Proactive tool detection (`Test-Tools`)**: runs 0.2s synthetic encodes on NVENC (10-bit) and QSV to verify real driver functionality before batch processing.
- **Multi-tier hardware fallback**:
  - NVENC: Full CUDA -> SW decode + NVENC -> Safe NVENC without spatial/temporal AQ.
  - QSV: Full QSV -> SW decode + QSV.
  - Software: x265 on CPU.
- **Colorimetry preservation**: `color_primaries`, `color_trc`, `colorspace`, and `color_range` passed explicitly; Sony xvYCC normalized without pixel alteration.
- **Subsampling protection**: ImageMagick forced to maintain source sampling factor (preventing unintended bloating to 4:4:4).
- **Binary Ogg manipulation**: native Vorbis comment binary parser + Ogg page rewrite engine calculating Ogg CRC-32 (`0x04C11DB7`) to support multiple `ARTIST` tags.

---

## 10. Troubleshooting

| Symptom | Probable Cause | Fix |
|---|---|---|
| `ERROR: neither ffmpeg nor ImageMagick found` | Binaries not in PATH | Restart terminal; test with `ffmpeg -version` and `magick -version` |
| Script will not run / "execution of scripts is disabled" | PowerShell Execution Policy | Launch with `powershell -ExecutionPolicy Bypass -File ...` and run `Unblock-File` |
| Corrupted accented characters | Script saved without UTF-8 BOM | Save file as UTF-8 with BOM |
| Encoder shows *x265 (CPU)* instead of QSV | Intel QSV unavailable or missing drivers | Update Intel Graphics drivers; verify with a full ffmpeg build |
| Encoding is very slow (2–3 fps) | Running on CPU x265 | Check GPU drivers or increase preset to `fast`/`veryfast` |
| `VMAF: NOT available` | ffmpeg build lacks `libvmaf` | Install a *full* ffmpeg build (e.g. `winget install Gyan.FFmpeg`) |
| `VMAF not read` | Analysis command failed | Try running `ffmpeg -i out.mp4 -i orig.mp4 -lavfi libvmaf -f null -` manually to view errors |
| `ERROR ffmpeg` on DJI with "codec none" | Data tracks included in muxer | Handled automatically by `-dn`; ensure you're running through Squeeze |
| Photo: `magick NOT found` | `magick` not in PATH | Reinstall ImageMagick with PATH option enabled |
| Photo: `SSIM not read` | ImageMagick missing SSIM metric | Run `magick -list metric` to confirm `SSIM` is supported |
| Photo: `ALREADY COMPRESSED` for all files | Estimated Q ≤ target Q | Lower target quality in `G` (e.g. 85) or evaluate with `[9]` |
| Photo: `CHECK METADATA` | Tags missing from output | Keep original; install `exiftool` to see exact tag diffs |
| `SKIPPED: output larger` | File already highly compressed | Normal: keep original |
| Audio: `libopus NOT available` | ffmpeg build lacks `libopus` | Install a *full* build of ffmpeg |
| Audio: artists remain merged | Tag does not use `;` or separate Vorbis tags | Separation splits on `;`: fix tags in source file |
| Audio: cover art missing in `opus` | No sidecar cover image and no embedded FLAC art | Add `cover.jpg` to source folder or enable `L` |

---

## 11. Known Limitations and Test Status

### 11.1 Limitations

- **DJI data tracks and Sony `rtmd` cannot be preserved** with ffmpeg (see [7.1](#71-video)).
- **Sony MPF preview** dropped in JPEG re-encoding.
- **JPEG only for photos**: RAW (`.ARW`, `.DNG`) and HEIF are not processed.
- **Video output is always HEVC**: no legacy H.264 mode.
- **JPEG recompression is lossy**: carefully tuned, but not lossless.
- **Sequential processing**: processes one file at a time.
- **Audio input limited to WAV and FLAC**: does not touch MP3, M4A, OGG, etc.
- **Artwork is not embedded in Opus** (by design): kept as external image file.

### 11.2 Verification Status

| Component | Tested On |
|---|---|
| DJI & Sony video pipeline (QSV & VMAF) | Verified on Intel Core Ultra 7 255H / Arc 140T, Windows 11, ffmpeg 9.0.1 |
| NVENC video pipeline | Verified on NVIDIA RTX hardware with 10-bit color |
| Audio conversion (PCM -> AAC, 4:2:2 -> 4:2:0, XML copy) | Verified on test clips |
| Photo pipeline (encode, sampling, progressive, retry, SSIM, test `[9]`) | Verified with ImageMagick 7.1.2 |
| Audio pipeline (WAV/FLAC -> Opus, multi-artist tags, cover extraction, Ogg CRC-32) | Verified on synthetic and real tracks with ffmpeg 9.0.1 and Python |

---

## 12. FAQ

**Can I delete originals after compression?**
Only after spot-checking files (especially dark clips) and reviewing the *TO CHECK* summary. For clips you intend to stabilize with Gyroflow, always keep originals.

**How much disk space will I save?**
Depends on source and scene complexity. High-bitrate H.264 (Sony Alpha) typically reduces by 75–85%; already compressed HEVC (DJI) typically reduces by 50–70%.

**Why GPU instead of CPU?**
On modern Intel/NVIDIA GPUs, encoding speeds jump from ~2.5 fps (x265 `slow`) to 100+ fps. While x265 can yield slightly smaller files at matched perceptual quality, GPU encoding takes minutes instead of hours.

**Can I compress the same file twice?**
Not recommended. Squeeze skips photos already at or below target quality, but video has no equivalent safeguard: always encode from original camera footage.

**Does it work with other cameras (GoPro, iPhone, etc.)?**
For video, yes, provided the container is MP4/MOV; proprietary telemetry tracks are stripped automatically. For photos, any JPEG is supported.

**How do I restore default settings?**
Delete `squeeze.config.json` next to the script.

---

## 13. Customizing the Script

| To customize | Where to look |
|---|---|
| Add video/photo/audio/sidecar file extensions | `Extensions`, `PhotoExtensions`, `OpusExtensions`, `SidecarExts` in `squeeze.config.json` |
| Change cover art search filenames or extensions | `OpusCoverNames`, `OpusCoverExts` in `squeeze.config.json` |
| Adjust artist tag split character | `ARTIST` branch in `Get-OpusComments` (PowerShell) / `get_opus_comments` (Python) |
| Tweak QSV encoder parameters | `Invoke-Encode` function, `$venc` variable in `qsv` branch |
| Modify auto-retry quality increments | `$qStep` / `$qMin` in `Invoke-VideoJob`, `$newQ = $q + 3` in `Invoke-PhotoJob` |
| Add a quick preset | Option `'P'` block in `Show-SettingsMenu` |
| Adjust metadata comparison strictness | `Get-ExifToolKeys` (excluded regex groups) |

---

## 14. Glossary

| Term | Meaning |
|---|---|
| **HEVC / H.265** | Modern video codec, roughly twice as efficient as H.264 |
| **AVC / H.264** | Prevalent legacy video codec (used by Sony Alpha 8-bit modes) |
| **NVENC** | Hardware video encoder on NVIDIA GPUs (GeForce RTX / Quadro) |
| **QSV (Quick Sync Video)** | Hardware video encoder on Intel GPUs (Iris Xe, Arc, Ultra) |
| **x265** | Software HEVC encoder running on CPU: slow but high compression density |
| **CQ** | *Constant Quality*: constant quality parameter for NVENC (lower = higher quality) |
| **CRF** | *Constant Rate Factor*: constant quality parameter for x265 (lower = higher quality) |
| **global_quality** | ICQ quality factor for Intel QSV |
| **Bitrate** | Video data throughput per second (Mbps); higher = larger file |
| **VMAF** | Video quality metric (0–100) developed by Netflix; ~95+ is visually lossless |
| **SSIM** | Structural Similarity index (0–1); 1 represents mathematical identity |
| **Chroma subsampling (4:2:0 / 4:2:2 / 4:4:4)** | Color resolution relative to luminance |
| **10-bit / 8-bit** | Color depth per channel; 10-bit yields smoother color gradients |
| **Metadata** | Auxiliary camera data: date, camera model, ISO, lens, GPS coordinates |
| **EXIF / XMP / IPTC / ICC** | Metadata and color profile formats embedded in photos |
| **MakerNote** | Manufacturer-specific proprietary EXIF block |
| **MPF** | *Multi-Picture Format*: embedded secondary preview image in JPEGs |
| **Data tracks (`djmd`, `dbgi`, `rtmd`)** | Proprietary telemetry tracks inside video containers |
| **Timecode** | Frame-accurate synchronization time code |
| **Progressive JPEG** | JPEG format decoded in progressive passes; 2–4% smaller |
| **Opus** | Modern, highly efficient lossy audio codec inside an Ogg container |
| **Ogg** | Container holding Opus audio; tags are formatted as **Vorbis comments** |
| **Vorbis Comment** | Tag format `KEY=value`; keys can be repeated for multiple artists |
| **FLAC** | Lossless compressed audio codec |
| **WAV** | Uncompressed PCM audio; metadata stored in `RIFF`/`INFO` chunks |
| **VBR** | *Variable Bit Rate*: bitrate dynamically adapts to audio complexity |
| **Sidecar** | Companion file alongside media files (`.xml`, `.srt`, `.xmp`) |
| **`.part`** | Temporary file while encoding, atomically renamed upon completion |

---

## 15. License

This project is licensed under the open-source **MIT License**. See the [LICENSE](LICENSE) file for the full legal text and conditions.

