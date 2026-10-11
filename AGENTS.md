# AGENTS.md

Two parallel single-file implementations: `squeeze.ps1` (Windows/PowerShell)
and `squeeze.py` (Linux/Python). Interactive TUI for recompressing DJI/Sony
video (HEVC) and JPEG photos with quality checks (VMAF/SSIM), plus converting
WAV/FLAC audio to Opus. No build, lint, test, or package manager in this repo.

## Commands

- Run the tool: `powershell -ExecutionPolicy Bypass -File .\squeeze.ps1`
- There is no test/lint/build command. Verify changes by running the script and
  walking the TUI manually; there is no headless/automated test harness.
- Runtime tool detection happens at startup (`Test-Tools`); it needs `ffmpeg`
  + `ffprobe` (build with `libx265`/`hevc_qsv`, `libvmaf` and `libopus`) and,
  for photos, ImageMagick 7 (`magick`) on `PATH`. `exiftool` is optional. The
  script exits with code 1 if neither ffmpeg nor ImageMagick is found.

## Constraints

- Target **PowerShell 5.1**, not 7+. Do not introduce PS7-only syntax
  (ternary `? :`, `??`, `-Parallel`, etc.); the script is invoked via
  `powershell.exe`.
- Windows-only: paths, `%ProgramFiles%`, and backslash handling are assumed.
- User-facing output and comments are in **Italian**; keep that convention.
- The script is fully interactive (`Read-Host`). You cannot exercise a code
  path without feeding input, so reason carefully before claiming it works.
- `README.md` is the user-facing Italian manual and documents the settings menu,
  config keys, and statuses; update it in the same change whenever behavior,
  defaults, or menu options change.

## Structure

- `$script:Cfg` is an ordered hashtable holding all settings; persisted to
  `squeeze.config.json` beside the script by `Save-Config`/`Import-Config`
  (`Import-Config` auto-migrates a legacy `dji-compress.config.json`).
  `Import-Config` only applies keys already present in `$script:Cfg`, so add new
  settings to that hashtable or they will be silently ignored.
- Main flow: `Show-MainMenu` -> `Start-Batch` -> `Invoke-VideoJob` / `Invoke-PhotoJob`
  / `Invoke-AudioJob` -> `Invoke-Encode` / `Invoke-PhotoEncode` + `Measure-Vmaf` /
  `Measure-Ssim`.
- Encodes write to a `<name>.part` file and are renamed only on success; never
  break the cleanup in `finally` blocks. Sources are never modified/deleted.
- Photos use ImageMagick; video uses ffmpeg with explicit `-map 0:V:0` (skips
  cover-art streams) and color metadata copied from the source.
- Audio (WAV/FLAC -> Opus) reads tags natively (FLAC Vorbis comments / WAV RIFF
  INFO) and rewrites the Ogg OpusTags page by hand (ffmpeg cannot emit duplicate
  `ARTIST` tags); covers are copied/extracted to the `opus` folder, never
  embedded.

## Git

- Remote: `github.com:scatolo/tools` (`scatolo/tools`). Commit only when asked.
