<#
.SYNOPSIS
    Squeeze - riduzione di video (HEVC), foto (JPEG) e audio (Opus) con verifica qualita'.

.DESCRIPTION
    TUI testuale centrata per:
      * scegliere una cartella di video (cambia a ogni sessione, l'ultima viene ricordata)
      * comprimere con NVIDIA NVENC (hevc_nvenc), Intel Quick Sync (hevc_qsv) o x265 (software)
      * verificare la qualita' di ogni file con VMAF contro l'originale
      * ricodificare automaticamente a qualita' piu' alta i file sotto soglia
      * salvare un log CSV con dimensioni, risparmio e punteggio di ogni file
      * gestire sia clip DJI sia Sony Alpha (audio PCM -> AAC per compatibilita' social,
        copia dei file XML/SRT affiancati, conversione 4:2:2 -> 4:2:0 quando serve)
      * comprimere le foto JPEG (Sony Alpha, ecc.) con ImageMagick, verificando SSIM e metadati
      * convertire audio WAV/FLAC in Opus (>=128 kb/s), trasferendo i tag pari-pari (artisti
        multipli come tag ARTIST separati) e salvando la copertina nella cartella "opus"

    Gli originali non vengono mai modificati ne' cancellati.
    Requisiti: Windows, PowerShell 5.1+, ffmpeg e ffprobe nel PATH (build "full" con libvmaf
    e libopus); per le foto ImageMagick 7 (comando "magick"). exiftool e' opzionale (verifica metadati piu' precisa).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\squeeze.ps1
#>

$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:ConfigPath = Join-Path $scriptDir 'squeeze.config.json'
$script:LegacyConfigPath = Join-Path $scriptDir 'dji-compress.config.json'

# ----------------------------------------------------------------------------
#  CONFIGURAZIONE (salvata in squeeze.config.json accanto allo script)
# ----------------------------------------------------------------------------
$script:Cfg = [ordered]@{
    SourceDir        = ''
    OutDir           = ''            # vuoto = <cartella sorgente>\out
    Recurse          = $false        # cerca anche nelle sottocartelle
    Encoder          = 'auto'        # auto | nvenc | qsv | x265
    NvencCq          = 24            # -cq per hevc_nvenc (10-40, piu' basso = qualita' piu' alta)
    NvencPreset      = 'p7'          # p1 (piu' veloce) ... p7 (piu' lento, qualita' massima)
    QsvQuality       = 24            # -global_quality (piu' basso = qualita' piu' alta)
    X265Crf          = 20            # -crf (piu' basso = qualita' piu' alta)
    X265Preset       = 'medium'      # ultrafast ... slow, slower
    VmafThreshold    = 96            # sotto questo punteggio il file e' "da rifare"
    VmafSubsample    = 5             # 1 = tutti i frame (lento), 5 = un frame ogni 5
    AutoRetry        = $true         # ricodifica automatica se sotto soglia
    MaxRetries       = 2
    Overwrite        = $false        # sovrascrive output gia' esistenti
    PreserveDates    = $true         # copia data creazione/modifica sull'output
    AudioMode        = 'auto'        # auto = PCM -> AAC, altri formati in copia | copy | aac
    AacBitrate       = 320           # kb/s, usato quando l'audio viene convertito in AAC
    NormalizeXvYCC   = $true         # Sony: tag trasferimento xvYCC -> bt709 (solo etichetta, pixel invariati)
    CopySidecars     = $true         # copia i file affiancati (XML Sony, SRT DJI, XMP)
    SidecarExts      = @('.xml', '.srt', '.xmp')
    PhotoQuality     = 90            # qualita' JPEG di partenza (ImageMagick -quality)
    PhotoSsim        = 0.990         # soglia SSIM: sotto, la foto viene ricodificata a qualita' piu' alta
    PhotoProgressive = $true         # JPEG progressivo (file un po' piu' piccoli)
    PhotoVerify      = $true         # verifica SSIM + confronto metadati dopo la compressione
    PhotoExtensions  = @('.jpg', '.jpeg')
    Extensions       = @('.mp4', '.mov')
    OpusBitrate      = 160           # kb/s (libopus VBR); minimo consentito 128
    OpusCover        = $true         # copia/estrae la copertina nella cartella opus
    OpusExtensions   = @('.wav', '.flac')
    OpusCoverNames   = @('cover', 'folder', 'front', 'album')
    OpusCoverExts    = @('.jpg', '.jpeg', '.png')
}

function Import-Config {
    $path = $script:ConfigPath
    if (-not (Test-Path -LiteralPath $path)) {
        # migrazione automatica dal vecchio nome "dji-compress"
        if (Test-Path -LiteralPath $script:LegacyConfigPath) { $path = $script:LegacyConfigPath }
        else { return }
    }
    try {
        $loaded = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        foreach ($p in $loaded.PSObject.Properties) {
            if ($script:Cfg.Contains($p.Name)) { $script:Cfg[$p.Name] = $p.Value }
        }
    } catch { return }
    # se ho letto il vecchio file, ne creo subito uno nuovo col nome corrente
    if ($path -ne $script:ConfigPath) { Save-Config }
}

function Save-Config {
    try { $script:Cfg | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8 } catch { }
}

# ----------------------------------------------------------------------------
#  UTILITA' E LAYOUT CENTRATO
# ----------------------------------------------------------------------------
$script:BoxW = 76

function Get-ConsoleWidth {
    try {
        if ($Host -and $Host.UI -and $Host.UI.RawUI) {
            $w = $Host.UI.RawUI.WindowSize.Width
            if ($w -gt 20) { return $w }
        }
    } catch { }
    return 80
}

function Get-BoxPad([int]$Width = $script:BoxW) {
    $conW = Get-ConsoleWidth
    $m = [math]::Max(0, [math]::Floor(($conW - $Width) / 2))
    return (' ' * $m)
}

function Write-BoxTop([int]$Width = $script:BoxW, [string]$Color = "DarkCyan") {
    $pad = Get-BoxPad $Width
    $inner = [string][char]0x2500 * ($Width - 2)
    Write-Host ("{0}{1}{2}{3}" -f $pad, [char]0x256D, $inner, [char]0x256E) -ForegroundColor $Color
}

function Write-BoxSep([int]$Width = $script:BoxW, [string]$Color = "DarkCyan") {
    $pad = Get-BoxPad $Width
    $inner = [string][char]0x2500 * ($Width - 2)
    Write-Host ("{0}{1}{2}{3}" -f $pad, [char]0x251C, $inner, [char]0x2524) -ForegroundColor $Color
}

function Write-BoxBottom([int]$Width = $script:BoxW, [string]$Color = "DarkCyan") {
    $pad = Get-BoxPad $Width
    $inner = [string][char]0x2500 * ($Width - 2)
    Write-Host ("{0}{1}{2}{3}" -f $pad, [char]0x2570, $inner, [char]0x256F) -ForegroundColor $Color
}

function Write-BoxLine {
    param(
        [string]$Text = '',
        [string]$Align = 'Left',
        [string]$Color = "White",
        [string]$BorderColor = "DarkCyan",
        [int]$Width = $script:BoxW
    )
    $pad = Get-BoxPad $Width
    $innerW = $Width - 2
    if ($Text.Length -gt $innerW) {
        $Text = $Text.Substring(0, $innerW - 3) + '...'
    }
    $rem = $innerW - $Text.Length
    $leftPad = 0
    $rightPad = 0
    if ($Align -eq 'Center') {
        $leftPad = [math]::Floor($rem / 2)
        $rightPad = $rem - $leftPad
    } elseif ($Align -eq 'Right') {
        $leftPad = $rem
        $rightPad = 0
    } else {
        $leftPad = 0
        $rightPad = $rem
    }
    Write-Host $pad -NoNewline
    Write-Host ([char]0x2502) -ForegroundColor $BorderColor -NoNewline
    if ($leftPad -gt 0) { Write-Host (' ' * $leftPad) -NoNewline }
    Write-Host $Text -ForegroundColor $Color -NoNewline
    if ($rightPad -gt 0) { Write-Host (' ' * $rightPad) -NoNewline }
    Write-Host ([char]0x2502) -ForegroundColor $BorderColor
}

function Write-BoxBadgedLine {
    param(
        [string]$Label,
        [string]$Badge,
        [string]$BadgeColor,
        [string]$Detail,
        [string]$DetailColor = "Gray",
        [string]$BorderColor = "DarkCyan",
        [int]$Width = $script:BoxW
    )
    $pad = Get-BoxPad $Width
    $innerW = $Width - 2
    $prefix = "  {0,-8} : " -f $Label
    $badgeStr = "[{0}]" -f $Badge
    $usedLen = $prefix.Length + $badgeStr.Length + 1 + $Detail.Length
    $detailStr = $Detail
    if ($usedLen -gt $innerW) {
        $maxDetail = $innerW - ($prefix.Length + $badgeStr.Length + 1)
        if ($maxDetail -gt 3) {
            $detailStr = $detailStr.Substring(0, $maxDetail - 3) + '...'
        } else {
            $detailStr = ''
        }
    }
    $rem = [math]::Max(0, $innerW - ($prefix.Length + $badgeStr.Length + 1 + $detailStr.Length))
    Write-Host $pad -NoNewline
    Write-Host ([char]0x2502) -ForegroundColor $BorderColor -NoNewline
    Write-Host $prefix -ForegroundColor DarkGray -NoNewline
    Write-Host $badgeStr -ForegroundColor $BadgeColor -NoNewline
    Write-Host (" " + $detailStr) -ForegroundColor $DetailColor -NoNewline
    if ($rem -gt 0) { Write-Host (' ' * $rem) -NoNewline }
    Write-Host ([char]0x2502) -ForegroundColor $BorderColor
}

function Write-BoxTwoCol {
    param(
        [string]$Left,
        [string]$Right,
        [string]$LeftColor = "White",
        [string]$RightColor = "White",
        [string]$BorderColor = "DarkCyan",
        [int]$Width = $script:BoxW
    )
    $pad = Get-BoxPad $Width
    $innerW = $Width - 2
    if (($Left.Length + $Right.Length) -gt $innerW) {
        $maxL = $innerW - $Right.Length - 3
        if ($maxL -gt 0) { $Left = $Left.Substring(0, $maxL) + '...' }
        else { $Left = '' }
    }
    $rem = [math]::Max(1, $innerW - ($Left.Length + $Right.Length))
    Write-Host $pad -NoNewline
    Write-Host ([char]0x2502) -ForegroundColor $BorderColor -NoNewline
    Write-Host $Left -ForegroundColor $LeftColor -NoNewline
    Write-Host (' ' * $rem) -NoNewline
    Write-Host $Right -ForegroundColor $RightColor -NoNewline
    Write-Host ([char]0x2502) -ForegroundColor $BorderColor
}

function Read-BoxPrompt([string]$PromptText = 'Scelta') {
    $pad = Get-BoxPad $script:BoxW
    Write-Host ("`n{0}{1}: " -f $pad, $PromptText) -ForegroundColor Cyan -NoNewline
    try {
        $res = Read-Host
        if ($res) { return $res.Trim() }
        if ([Console]::IsInputRedirected) { return '0' }
        return ''
    } catch {
        return '0'
    }
}

function Write-CenteredProgress([int]$Current, [int]$Total, [string]$FileName, [int]$BarWidth = 24) {
    if ($Total -le 0) { $Total = 1 }
    $pct = [int][math]::Round(($Current / $Total) * 100)
    $filled = [int][math]::Round(($Current / $Total) * $BarWidth)
    if ($filled -gt $BarWidth) { $filled = $BarWidth }
    if ($filled -lt 0) { $filled = 0 }
    $empty = $BarWidth - $filled
    $bar = ([string][char]0x2588 * $filled) + ([string][char]0x2591 * $empty)
    $prefix = ("[{0}] {1,3}% ({2}/{3}) • " -f $bar, $pct, $Current, $Total)
    $conW = Get-ConsoleWidth
    $maxFn = $conW - $prefix.Length - 4
    if ($maxFn -gt 3 -and $FileName.Length -gt $maxFn) {
        $FileName = $FileName.Substring(0, $maxFn - 3) + '...'
    }
    $text = $prefix + $FileName
    $pad = ' ' * [math]::Max(0, [math]::Floor(($conW - $text.Length) / 2))
    Write-Host ''
    Write-Host ("{0}{1}" -f $pad, $text) -ForegroundColor Cyan
}

function Wait-Enter {
    $pad = Get-BoxPad $script:BoxW
    Write-Host ("`n{0}Premi Invio per continuare..." -f $pad) -ForegroundColor DarkGray -NoNewline
    [void](Read-Host)
}

function Read-Default([string]$Prompt, [string]$Default) {
    $r = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
    return $r.Trim()
}

function Read-IntRange([string]$Prompt, [int]$Current, [int]$Min, [int]$Max) {
    while ($true) {
        $r = Read-Default "$Prompt ($Min-$Max)" "$Current"
        $n = 0
        if ([int]::TryParse($r, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
        Write-Host "  Valore non valido." -ForegroundColor Yellow
    }
}

function Format-OnOff([bool]$v) { if ($v) { 'SI' } else { 'NO' } }

function Get-OutDir {
    if ($script:Cfg.OutDir) { return $script:Cfg.OutDir.TrimEnd('\') }
    return (Join-Path $script:Cfg.SourceDir 'out')
}

# Cartella di destinazione degli .opus: sempre <sorgente>\opus
function Get-OpusDir {
    return (Join-Path $script:Cfg.SourceDir 'opus')
}

function Test-UnderDir([string]$Path, [string]$Dir) {
    if ([string]::IsNullOrEmpty($Dir) -or [string]::IsNullOrEmpty($Path)) { return $false }
    $d = $Dir.TrimEnd('\', '/') + '\'
    return $Path.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)
}

# ----------------------------------------------------------------------------
#  CONTROLLO STRUMENTI
# ----------------------------------------------------------------------------
$script:HasX265 = $false
$script:HasVmaf = $false
$script:NvencWorks = $false
$script:QsvWorks = $false
$script:HasOpus = $false

$script:HasFfmpeg = $false
$script:MagickExe = $null
$script:MagickSsim = $false
$script:ExifTool = $null

function Test-Tools {
    $script:HasFfmpeg = [bool]((Get-Command ffmpeg -ErrorAction SilentlyContinue) -and (Get-Command ffprobe -ErrorAction SilentlyContinue))

    $cmd = Get-Command magick -ErrorAction SilentlyContinue
    if ($cmd) { $script:MagickExe = $cmd.Source }
    elseif ($env:ProgramFiles) {
        $cand = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'ImageMagick*\magick.exe') -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending | Select-Object -First 1
        if ($cand) { $script:MagickExe = $cand.FullName }
    }

    if (-not $script:HasFfmpeg -and -not $script:MagickExe) {
        Write-Host "ERRORE: ne' ffmpeg/ffprobe ne' ImageMagick (magick) trovati nel PATH." -ForegroundColor Red
        return $false
    }

    if ($script:HasFfmpeg) {
        $enc = (& ffmpeg -hide_banner -encoders 2>&1 | Out-String)
        $flt = (& ffmpeg -hide_banner -filters 2>&1 | Out-String)
        $script:HasX265 = $enc -match 'libx265'
        $script:HasVmaf = $flt -match 'libvmaf'
        $script:HasOpus = $enc -match 'libopus'
        if ($enc -match 'hevc_nvenc') {
            # Prova reale: encode minuscolo di 0.2s verso null per testare presenza GPU NVIDIA e driver
            & ffmpeg -hide_banner -loglevel error -f lavfi -i 'color=c=black:s=1280x720:d=0.2' -vf 'format=p010le' `
                -c:v hevc_nvenc -profile:v main10 -f null - 2>$null
            if ($LASTEXITCODE -eq 0) {
                $script:NvencWorks = $true
            } else {
                & ffmpeg -hide_banner -loglevel error -f lavfi -i 'color=c=black:s=1280x720:d=0.2' -vf 'format=nv12' `
                    -c:v hevc_nvenc -profile:v main -f null - 2>$null
                $script:NvencWorks = ($LASTEXITCODE -eq 0)
            }
        }
        if ($enc -match 'hevc_qsv') {
            # prova reale: un encode minuscolo, perche' la build puo' avere QSV ma la GPU no
            & ffmpeg -hide_banner -loglevel error -f lavfi -i 'color=c=black:s=1280x720:d=0.2' -vf 'format=p010le' `
                -c:v hevc_qsv -profile:v main10 -f null - 2>$null
            $script:QsvWorks = ($LASTEXITCODE -eq 0)
        }
    }
    if ($script:MagickExe) {
        $script:MagickSsim = ((& $script:MagickExe -list metric 2>&1 | Out-String) -match 'SSIM')
        $et = Get-Command exiftool -ErrorAction SilentlyContinue
        if ($et) { $script:ExifTool = $et.Source }
    }
    return $true
}

function Resolve-Encoder {
    switch ($script:Cfg.Encoder) {
        'nvenc' { if ($script:NvencWorks) { return 'nvenc' } else { return $null } }
        'qsv'   { if ($script:QsvWorks)   { return 'qsv' }   else { return $null } }
        'x265'  { if ($script:HasX265)    { return 'x265' }  else { return $null } }
        default {
            if ($script:NvencWorks) { return 'nvenc' }
            if ($script:QsvWorks)   { return 'qsv' }
            if ($script:HasX265)    { return 'x265' }
            return $null
        }
    }
}

# ----------------------------------------------------------------------------
#  ANALISI FILE
# ----------------------------------------------------------------------------
function Get-VideoInfo([string]$Path) {
    $json = & ffprobe -v error -select_streams v:0 `
        -show_entries 'stream=codec_name,pix_fmt,width,height,avg_frame_rate,color_range,color_space,color_transfer,color_primaries:format=duration' `
        -of json -i $Path 2>$null
    try { $o = ($json -join "`n") | ConvertFrom-Json } catch { return $null }
    if (-not $o -or -not $o.streams -or @($o.streams).Count -eq 0) { return $null }
    $s = @($o.streams)[0]
    $fps = 0.0
    if ("$($s.avg_frame_rate)" -match '^(\d+)/(\d+)$' -and [double]$Matches[2] -ne 0) {
        $fps = [double]$Matches[1] / [double]$Matches[2]
    }
    $dur = 0.0
    try { $dur = [double]::Parse("$($o.format.duration)", $script:Inv) } catch { }
    $aCodec = $null; $aCh = 0
    $aj = & ffprobe -v error -select_streams a:0 -show_entries 'stream=codec_name,channels' -of json -i $Path 2>$null
    try {
        $ao = ($aj -join "`n") | ConvertFrom-Json
        if ($ao -and $ao.streams) { $as = @($ao.streams)[0]; $aCodec = $as.codec_name; $aCh = [int]$as.channels }
    } catch { }
    [pscustomobject]@{
        Codec = $s.codec_name; PixFmt = $s.pix_fmt; Width = $s.width; Height = $s.height
        Fps = $fps; Duration = $dur; ACodec = $aCodec; AChannels = $aCh
        Range = $s.color_range; Space = $s.color_space; Trc = $s.color_transfer; Prim = $s.color_primaries
    }
}

# Replica nell'output i tag colore dell'ORIGINALE (cosi' D-Log/HLG/Normal restano corretti)
function Get-ColorArgs($Info) {
    $a = New-Object System.Collections.Generic.List[string]
    if ($Info.Prim  -and $Info.Prim  -ne 'unknown') { $a.Add('-color_primaries'); $a.Add($Info.Prim) }
    if ($Info.Trc -and $Info.Trc -ne 'unknown') {
        $trc = $Info.Trc
        if ($script:Cfg.NormalizeXvYCC -and $trc -eq 'iec61966-2-4') { $trc = 'bt709' }
        $a.Add('-color_trc'); $a.Add($trc)
    }
    if ($Info.Space -and $Info.Space -ne 'unknown') { $a.Add('-colorspace');      $a.Add($Info.Space) }
    if ($Info.Range -in @('tv', 'pc'))              { $a.Add('-color_range');     $a.Add($Info.Range) }
    return $a.ToArray()
}

# True se l'audio va convertito in AAC (PCM Sony: pesante e poco compatibile con social/browser)
function Test-AudioToAac($Info) {
    if (-not $Info.ACodec) { return $false }
    $okLayout = ($Info.AChannels -le 2 -or $Info.AChannels -eq 6)
    switch ($script:Cfg.AudioMode) {
        'copy'  { return $false }
        'aac'   { return $okLayout }
        default { return (("$($Info.ACodec)" -like 'pcm*') -and $okLayout) }
    }
}

# Copia i file affiancati al video (es. C0070M01.XML Sony, .SRT DJI) nella cartella di output
function Copy-Sidecars([IO.FileInfo]$File, [string]$DstDir) {
    $base = [IO.Path]::GetFileNameWithoutExtension($File.Name)
    $exts = @($script:Cfg.SidecarExts)
    Get-ChildItem -LiteralPath $File.DirectoryName -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -and ($exts -contains $_.Extension.ToLower()) } |
        ForEach-Object {
            $t = Join-Path $DstDir $_.Name
            if (-not (Test-Path -LiteralPath $t)) {
                Copy-Item -LiteralPath $_.FullName -Destination $t
                (Get-Item -LiteralPath $t).LastWriteTime = $_.LastWriteTime
            }
        }
}

function Get-MediaFiles([string]$Kind = 'video') {
    $p = @{ LiteralPath = $script:Cfg.SourceDir; File = $true; ErrorAction = 'SilentlyContinue' }
    if ($script:Cfg.Recurse) { $p.Recurse = $true }
    $exts = switch ($Kind) {
        'photo' { @($script:Cfg.PhotoExtensions) }
        'audio' { @($script:Cfg.OpusExtensions) }
        default { @($script:Cfg.Extensions) }
    }
    $excl = @((Get-OutDir), (Get-OpusDir))
    $files = Get-ChildItem @p | Where-Object {
        $f = $_
        if (-not ($exts -contains $f.Extension.ToLower())) { return $false }
        foreach ($e in $excl) { if (Test-UnderDir $f.FullName $e) { return $false } }
        return $true
    } | Sort-Object FullName
    return @($files)
}

# ----------------------------------------------------------------------------
#  ENCODE
# ----------------------------------------------------------------------------
function Invoke-Encode {
    param([string]$Src, [string]$Dst, $Info, [string]$Enc, [int]$Q, [double]$Duration = 0)

    $part = "$Dst.part"
    $fmt  = if ([IO.Path]::GetExtension($Dst).ToLower() -eq '.mov') { 'mov' } else { 'mp4' }
    $is10 = ("$($Info.PixFmt)" -match '10')
    $chromaNon420 = ("$($Info.PixFmt)" -match '422|444')   # es. Sony XAVC HS 4:2:2: si converte a 4:2:0

    $base = @('-hide_banner', '-loglevel', 'error', '-stats', '-y')
    # 0:V:0 = solo video "vero" (esclude la copertina JPEG); -dn = niente tracce dati DJI (il muxer MP4 le rifiuta)
    $maps = @('-map', '0:V:0', '-map', '0:a?', '-dn', '-map_metadata', '0')
    $audio = @('-c:a', 'copy')
    if (Test-AudioToAac $Info) { $audio = @('-c:a', 'aac', '-b:a', "$($script:Cfg.AacBitrate)k") }
    $mux  = @('-movflags', 'use_metadata_tags+faststart', '-tag:v', 'hvc1') +
            @(Get-ColorArgs $Info) + $audio + @('-f', $fmt)
    $durArg = if ($Duration -gt 0) { @('-t', "$Duration") } else { @() }

    $attempts = @()
    if ($Enc -eq 'nvenc') {
        $prof  = if ($is10) { 'main10' } else { 'main' }
        $swFmt = if ($is10) { 'p010le' } else { 'nv12' }
        $preset = if ($script:Cfg.NvencPreset) { $script:Cfg.NvencPreset } else { 'p7' }
        $vencHq = @('-c:v', 'hevc_nvenc', '-profile:v', $prof, '-preset', $preset,
                    '-tune', 'hq', '-rc', 'vbr', '-cq', "$Q", '-b:v', '0',
                    '-multipass', 'fullres', '-rc-lookahead', '32', '-spatial-aq', '1', '-temporal-aq', '1')
        $vencSafe = @('-c:v', 'hevc_nvenc', '-profile:v', $prof, '-preset', $preset,
                      '-rc', 'vbr', '-cq', "$Q", '-b:v', '0')
        if (-not $chromaNon420) {
            $attempts += , @{ Pre = @('-hwaccel', 'cuda', '-hwaccel_output_format', 'cuda'); Vf = @(); Venc = $vencHq }
        }
        $attempts += , @{ Pre = @(); Vf = @('-vf', "format=$swFmt"); Venc = $vencHq }
        $attempts += , @{ Pre = @(); Vf = @('-vf', "format=$swFmt"); Venc = $vencSafe }
    } elseif ($Enc -eq 'qsv') {
        $prof  = if ($is10) { 'main10' } else { 'main' }
        $swFmt = if ($is10) { 'p010le' } else { 'nv12' }
        $venc  = @('-c:v', 'hevc_qsv', '-profile:v', $prof, '-preset', 'veryslow',
                   '-global_quality', "$Q", '-look_ahead', '1')
        if (-not $chromaNon420) { $attempts += , @{ Pre = @('-hwaccel', 'qsv', '-hwaccel_output_format', 'qsv'); Vf = @(); Venc = $venc } }
        $attempts += , @{ Pre = @(); Vf = @('-vf', "format=$swFmt"); Venc = $venc }
    } else {
        $pix  = if ($chromaNon420) { if ($is10) { 'yuv420p10le' } else { 'yuv420p' } } elseif ($Info.PixFmt) { $Info.PixFmt } else { 'yuv420p10le' }
        $venc = @('-c:v', 'libx265', '-preset', $script:Cfg.X265Preset, '-crf', "$Q", '-pix_fmt', $pix, '-x265-params', 'log-level=error')
        $attempts += , @{ Pre = @(); Vf = @(); Venc = $venc }
    }

    try {
        foreach ($a in $attempts) {
            $ffArgs = $base + $a.Pre + @('-i', $Src) + $maps + $a.Vf + $a.Venc + $mux + $durArg + @($part)
            & ffmpeg @ffArgs
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $part)) {
                Move-Item -LiteralPath $part -Destination $Dst -Force
                return $true
            }
            if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
        }
        return $false
    } finally {
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    }
}

# ----------------------------------------------------------------------------
#  VMAF  (primo input = compresso, secondo = originale)
# ----------------------------------------------------------------------------
function Measure-Vmaf([string]$Dist, [string]$Ref, [int]$Sub, [double]$Duration = 0) {
    $threads = [Environment]::ProcessorCount
    $filter  = "[0:v:0][1:v:0]libvmaf=n_threads=${threads}:n_subsample=${Sub}"
    $hwaccels = @()
    if ($script:NvencWorks) { $hwaccels += 'cuda' }
    if ($script:QsvWorks)   { $hwaccels += 'qsv' }
    $hwaccels += 'none'

    $durArg = if ($Duration -gt 0) { @('-t', "$Duration") } else { @() }

    foreach ($hw in $hwaccels) {
        $pre = if ($hw -eq 'cuda') { @('-hwaccel', 'cuda') }
               elseif ($hw -eq 'qsv') { @('-hwaccel', 'qsv') }
               else { @() }
        $ffArgs = @('-hide_banner', '-nostats') + $pre + @('-i', $Dist) + $pre + @('-i', $Ref) +
                  $durArg + @('-lavfi', $filter, '-an', '-sn', '-dn', '-f', 'null', '-')
        $lines = & ffmpeg @ffArgs 2>&1 | ForEach-Object { "$_" }
        $m = $lines | Select-String 'VMAF score:\s*([\d\.,]+)'
        if ($m) {
            return [double]::Parse($m.Matches[0].Groups[1].Value.Replace(',', '.'), $script:Inv)
        }
    }
    return $null
}

# ----------------------------------------------------------------------------
#  LAVORO SU UN SINGOLO FILE
#  Mode: compress | full (comprimi + verifica + retry) | verify
# ----------------------------------------------------------------------------
function Invoke-VideoJob {
    param([IO.FileInfo]$File, [string]$Mode, [string]$Enc, [string]$SrcRoot, [string]$OutRoot)

    $rel = $File.FullName.Substring($SrcRoot.Length).TrimStart('\', '/')
    $dst = Join-Path $OutRoot $rel
    $row = [ordered]@{ File = $rel; InMB = [math]::Round($File.Length / 1MB, 1); OutMB = $null
                       Saved = $null; Quality = '-'; VMAF = $null; Audio = '-'; Status = '' }

    $info = Get-VideoInfo $File.FullName
    if (-not $info) { $row.Status = 'ERRORE: nessun video'; return [pscustomobject]$row }

    if ($Enc -eq 'nvenc') {
        $q     = [int]$script:Cfg.NvencCq
        $qMin  = 14
        $qStep = 3
    } elseif ($Enc -eq 'qsv') {
        $q     = [int]$script:Cfg.QsvQuality
        $qMin  = 15
        $qStep = 3
    } else {
        $q     = [int]$script:Cfg.X265Crf
        $qMin  = 12
        $qStep = 2
    }
    $exists = Test-Path -LiteralPath $dst
    $encodedNow = $false

    if ($Mode -eq 'verify') {
        if (-not $exists) { $row.Status = 'MANCA OUTPUT'; return [pscustomobject]$row }
    } elseif ($exists -and -not $script:Cfg.Overwrite) {
        $row.Status = 'ESISTENTE'
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        Write-Host ("   encode q={0} ({1}) ..." -f $q, $Enc) -ForegroundColor DarkGray
        if ("$($info.PixFmt)" -match '422|444') {
            Write-Host ("   nota: sorgente {0} -> convertita a 4:2:0 (compatibile con tutti i player)" -f $info.PixFmt) -ForegroundColor Yellow
        }
        if (-not (Invoke-Encode -Src $File.FullName -Dst $dst -Info $info -Enc $Enc -Q $q)) {
            $row.Status = 'ERRORE ffmpeg'; return [pscustomobject]$row
        }
        $encodedNow = $true
        $row.Quality = $q
        $row.Audio = if (Test-AudioToAac $info) { "AAC $($script:Cfg.AacBitrate)k" } else { 'copia' }
    }

    # --- verifica + eventuali retry ---
    if ($Mode -in @('full', 'verify')) {
        Write-Host '   verifica VMAF ...' -ForegroundColor DarkGray
        $v = Measure-Vmaf $dst $File.FullName $script:Cfg.VmafSubsample
        $tries = 0
        while ($encodedNow -and $script:Cfg.AutoRetry -and $null -ne $v -and
               $v -lt $script:Cfg.VmafThreshold -and $tries -lt $script:Cfg.MaxRetries) {
            $newQ = $q - $qStep
            if ($newQ -lt $qMin) { break }
            Write-Host ("   VMAF {0:N2} < {1}: riprovo con q={2}" -f $v, $script:Cfg.VmafThreshold, $newQ) -ForegroundColor Yellow
            $q = $newQ
            if (-not (Invoke-Encode -Src $File.FullName -Dst $dst -Info $info -Enc $Enc -Q $q)) { break }
            $row.Quality = $q
            $tries++
            $v = Measure-Vmaf $dst $File.FullName $script:Cfg.VmafSubsample
        }
        $row.VMAF = if ($null -ne $v) { [math]::Round($v, 2) } else { $null }
        if ($null -eq $v)                                  { $row.Status = 'VMAF non letto' }
        elseif ($v -lt $script:Cfg.VmafThreshold)          { $row.Status = 'SOTTO SOGLIA' }
        else                                               { $row.Status = 'OK' }
    } elseif ($encodedNow) {
        $row.Status = 'COMPRESSO (non verificato)'
    }

    # --- dimensioni e controllo "output piu' grande dell'input" ---
    if (Test-Path -LiteralPath $dst) {
        $outLen = (Get-Item -LiteralPath $dst).Length
        $row.OutMB = [math]::Round($outLen / 1MB, 1)
        $row.Saved = [math]::Round((1 - $outLen / $File.Length) * 100, 0)
        if ($encodedNow -and $outLen -ge $File.Length) {
            Remove-Item -LiteralPath $dst -Force
            $row.Status = 'SALTATO: output piu grande'; $row.OutMB = $null; $row.Saved = $null
        } elseif ($encodedNow -and $script:Cfg.PreserveDates) {
            $o = Get-Item -LiteralPath $dst
            $o.CreationTime = $File.CreationTime
            $o.LastWriteTime = $File.LastWriteTime
        }
        if ($encodedNow -and $script:Cfg.CopySidecars -and (Test-Path -LiteralPath $dst)) {
            Copy-Sidecars $File (Split-Path $dst)
        }
    }
    return [pscustomobject]$row
}

# ----------------------------------------------------------------------------
#  FOTO (ImageMagick): ricompressione JPEG + verifica SSIM + confronto metadati
# ----------------------------------------------------------------------------
function Get-PhotoInfo([string]$Path) {
    $raw = & $script:MagickExe identify -format '%w|%h|%Q|%[jpeg:sampling-factor]' "$Path[0]" 2>$null
    $line = @($raw)[0]
    if (-not $line) { return $null }
    $p = ("$line").Trim() -split '\|'
    if ($p.Count -lt 3) { return $null }
    $w = 0; $h = 0; $q = 0
    [void][int]::TryParse($p[0], [ref]$w); [void][int]::TryParse($p[1], [ref]$h); [void][int]::TryParse($p[2], [ref]$q)
    $samp = '2x2'
    if ($p.Count -ge 4 -and $p[3] -match '^(\d+x\d+)') { $samp = $Matches[1] }
    [pscustomobject]@{ Width = $w; Height = $h; Q = $q; Sampling = $samp }
}

# Ricodifica: stessa risoluzione, stesso sottocampionamento croma dell'originale, nessuno strip dei metadati
function Invoke-PhotoEncode([string]$Src, [string]$Dst, $Info, [int]$Q) {
    $part = "$Dst.part"
    $il = if ($script:Cfg.PhotoProgressive) { 'JPEG' } else { 'None' }
    $im = @($Src, '-quality', "$Q", '-sampling-factor', $Info.Sampling, '-interlace', $il,
            '-define', 'jpeg:optimize-coding=true', "JPEG:$part")
    try {
        $log = & $script:MagickExe @im 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $part)) {
            Move-Item -LiteralPath $part -Destination $Dst -Force
            return $true
        }
        @($log) | Select-Object -First 3 | ForEach-Object { Write-Host "   magick: $_" -ForegroundColor DarkGray }
        return $false
    } finally {
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    }
}

# SSIM tra compresso ($A) e originale ($B): 1.0 = identico.
function Measure-Ssim([string]$A, [string]$B) {
    $lines = & $script:MagickExe compare -metric SSIM $A $B 'null:' 2>&1 | ForEach-Object { "$_" }
    $num = '[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?'
    foreach ($l in $lines) {
        if ($l -match "^\s*$num\s*\(\s*($num)\s*\)") {
            $d = [double]::Parse($Matches[1], [Globalization.NumberStyles]::Float, $script:Inv)
            return [math]::Max(0.0, 1.0 - 2.0 * $d)
        }
        if ($l -match "^\s*($num)\s*$") {
            return [double]::Parse($Matches[1], [Globalization.NumberStyles]::Float, $script:Inv)
        }
    }
    return $null
}

function Get-ExifToolKeys([string]$Path) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    & $script:ExifTool -a -u -G1 -s $Path 2>$null | ForEach-Object {
        if ("$_" -match '^\[([^\]]+)\]\s+(\S+)\s*:') {
            $g = $Matches[1]; $t = $Matches[2]
            if ($g -notmatch '^(System|File|ExifTool|Composite|JFIF|MPF.*)$') { [void]$set.Add("${g}:${t}") }
        }
    }
    return , $set
}

function Get-ExifLines([string]$Path) {
    $o = & $script:MagickExe identify -format '%[EXIF:*]' "$Path[0]" 2>$null
    $txt = (@($o) -join "`n")
    return @($txt -split "`n" | Where-Object { $_ -match '=' })
}

# Confronta i metadati: con exiftool (tutti i tag, MakerNote Sony inclusi) se presente, altrimenti i tag EXIF letti da ImageMagick
function Test-PhotoMetadata([string]$Src, [string]$Dst) {
    $miss = 0; $total = 0
    if ($script:ExifTool) {
        $a = Get-ExifToolKeys $Src; $b = Get-ExifToolKeys $Dst
        $total = $a.Count
        foreach ($k in $a) { if (-not $b.Contains($k)) { $miss++ } }
    } else {
        $a = Get-ExifLines $Src; $b = Get-ExifLines $Dst
        $total = $a.Count
        $bs = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($l in $b) { [void]$bs.Add($l) }
        foreach ($l in $a) { if (-not $bs.Contains($l)) { $miss++ } }
    }
    $txt = if ($total -eq 0) { 'n/d' } elseif ($miss -eq 0) { "OK ($total)" } else { "MANCANO $miss/$total" }
    return [pscustomobject]@{ Missing = $miss; Total = $total; Text = $txt }
}

function Invoke-PhotoJob {
    param([IO.FileInfo]$File, [string]$Mode, [string]$SrcRoot, [string]$OutRoot)

    $rel = $File.FullName.Substring($SrcRoot.Length).TrimStart('\', '/')
    $dst = Join-Path $OutRoot $rel
    $row = [ordered]@{ File = $rel; InMB = [math]::Round($File.Length / 1MB, 1); OutMB = $null
                       Saved = $null; Quality = '-'; SSIM = $null; Meta = '-'; Status = '' }

    $info = Get-PhotoInfo $File.FullName
    if (-not $info) { $row.Status = 'ERRORE: immagine non leggibile'; return [pscustomobject]$row }

    $q = [int]$script:Cfg.PhotoQuality
    $exists = Test-Path -LiteralPath $dst
    $encodedNow = $false

    if ($Mode -eq 'verify') {
        if (-not $exists) { $row.Status = 'MANCA OUTPUT'; return [pscustomobject]$row }
    } elseif ($exists -and -not $script:Cfg.Overwrite) {
        $row.Status = 'ESISTENTE'
    } else {
        if ($info.Q -gt 0 -and $info.Q -le $q) {
            $row.Status = "GIA COMPRESSA (Q~$($info.Q))"; $row.Quality = $info.Q
            return [pscustomobject]$row
        }
        New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        Write-Host ("   encode Q={0}  (sorgente Q~{1}, croma {2})" -f $q, $info.Q, $info.Sampling) -ForegroundColor DarkGray
        if (-not (Invoke-PhotoEncode -Src $File.FullName -Dst $dst -Info $info -Q $q)) {
            $row.Status = 'ERRORE magick'; return [pscustomobject]$row
        }
        $encodedNow = $true
        $row.Quality = $q
    }

    if ($Mode -in @('full', 'verify') -and $script:Cfg.PhotoVerify) {
        Write-Host '   verifica SSIM + metadati ...' -ForegroundColor DarkGray
        $v = Measure-Ssim $dst $File.FullName
        $tries = 0
        while ($encodedNow -and $script:Cfg.AutoRetry -and $null -ne $v -and
               $v -lt [double]$script:Cfg.PhotoSsim -and $tries -lt $script:Cfg.MaxRetries) {
            $newQ = $q + 3
            if ($newQ -gt 98) { break }
            Write-Host ("   SSIM {0:N4} < {1}: riprovo con Q={2}" -f $v, $script:Cfg.PhotoSsim, $newQ) -ForegroundColor Yellow
            $q = $newQ
            if (-not (Invoke-PhotoEncode -Src $File.FullName -Dst $dst -Info $info -Q $q)) { break }
            $row.Quality = $q
            $tries++
            $v = Measure-Ssim $dst $File.FullName
        }
        $row.SSIM = if ($null -ne $v) { [math]::Round($v, 4) } else { $null }
        $meta = Test-PhotoMetadata $File.FullName $dst
        $row.Meta = $meta.Text
        if ($null -eq $v)                                           { $row.Status = 'SSIM non letto' }
        elseif ($v -lt [double]$script:Cfg.PhotoSsim)               { $row.Status = 'SOTTO SOGLIA' }
        elseif ($meta.Missing -gt 0)                                { $row.Status = 'CONTROLLA METADATI' }
        else                                                        { $row.Status = 'OK' }
    } elseif ($encodedNow) {
        $row.Status = 'COMPRESSO (non verificato)'
    } elseif ($Mode -eq 'verify') {
        $row.Status = 'VERIFICA DISATTIVATA'
    }

    if (Test-Path -LiteralPath $dst) {
        $outLen = (Get-Item -LiteralPath $dst).Length
        $row.OutMB = [math]::Round($outLen / 1MB, 1)
        $row.Saved = [math]::Round((1 - $outLen / $File.Length) * 100, 0)
        if ($encodedNow -and $outLen -ge $File.Length) {
            Remove-Item -LiteralPath $dst -Force
            $row.Status = 'SALTATO: output piu grande'; $row.OutMB = $null; $row.Saved = $null
        } elseif ($encodedNow -and $script:Cfg.PreserveDates) {
            $o = Get-Item -LiteralPath $dst
            $o.CreationTime = $File.CreationTime
            $o.LastWriteTime = $File.LastWriteTime
        }
        if ($encodedNow -and $script:Cfg.CopySidecars -and (Test-Path -LiteralPath $dst)) {
            Copy-Sidecars $File (Split-Path $dst)
        }
    }
    return [pscustomobject]$row
}

# ----------------------------------------------------------------------------
#  AUDIO (WAV/FLAC -> Opus) con trasferimento fedele dei tag e copertina
# ----------------------------------------------------------------------------
$script:RiffInfoMap = @{
    IART = 'ARTIST'; INAM = 'TITLE'; IPRD = 'ALBUM'; ICRD = 'DATE'; IGNR = 'GENRE'
    ITRK = 'TRACKNUMBER'; ICOP = 'COPYRIGHT'; ICMT = 'COMMENT'; ISFT = 'ENCODER'
    IENG = 'ENGINEER'; IWRI = 'WRITER'; IMUS = 'COMPOSER'; IALK = 'ALBUMARTIST'
    ILNG = 'LANGUAGE'; IBPM = 'BPM'; IKEY = 'KEY'
}

function Get-FlacComments([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    $list = New-Object System.Collections.Generic.List[string]
    if ($b.Length -lt 8) { return $list.ToArray() }
    if (-not ($b[0] -eq 0x66 -and $b[1] -eq 0x4C -and $b[2] -eq 0x61 -and $b[3] -eq 0x43)) { return $list.ToArray() }
    $pos = 4
    $last = $false
    while (-not $last -and $pos + 4 -le $b.Length) {
        $h = $b[$pos]
        $last = (($h -band 0x80) -ne 0)
        $btype = $h -band 0x7F
        $len = ([int]$b[$pos+1] -shl 16) -bor ([int]$b[$pos+2] -shl 8) -bor [int]$b[$pos+3]
        $bodyStart = $pos + 4
        if ($btype -eq 4) {
            $o = $bodyStart
            if ($o + 4 -le $b.Length) {
                $vlen = [BitConverter]::ToUInt32($b, $o); $o += 4 + [int]$vlen
                if ($o + 4 -le $b.Length) {
                    $n = [BitConverter]::ToUInt32($b, $o); $o += 4
                    for ($i = 0; $i -lt $n; $i++) {
                        if ($o + 4 -gt $b.Length) { break }
                        $clen = [BitConverter]::ToUInt32($b, $o); $o += 4
                        if ($o + [int]$clen -gt $b.Length) { break }
                        [void]$list.Add([Text.Encoding]::UTF8.GetString($b, $o, [int]$clen))
                        $o += [int]$clen
                    }
                }
            }
        }
        $pos = $bodyStart + $len
    }
    return $list.ToArray()
}

function Get-RiffInfoComments([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    $list = New-Object System.Collections.Generic.List[string]
    if ($b.Length -lt 12) { return $list.ToArray() }
    if (-not ($b[0] -eq 0x52 -and $b[1] -eq 0x49 -and $b[2] -eq 0x46 -and $b[3] -eq 0x46)) { return $list.ToArray() }
    $pos = 12
    while ($pos + 8 -le $b.Length) {
        $id = [Text.Encoding]::ASCII.GetString($b, $pos, 4)
        $size = [int][BitConverter]::ToUInt32($b, $pos + 4)
        $pos += 8
        if ($id -eq 'LIST' -and $pos + 4 -le $b.Length -and [Text.Encoding]::ASCII.GetString($b, $pos, 4) -eq 'INFO') {
            $o = $pos + 4
            $lim = [Math]::Min($pos + $size, $b.Length)
            while ($o + 8 -le $lim) {
                $sid = [Text.Encoding]::ASCII.GetString($b, $o, 4)
                $ssize = [int][BitConverter]::ToUInt32($b, $o + 4)
                $o += 8
                if ($o + $ssize -gt $b.Length) { break }
                $val = [Text.Encoding]::UTF8.GetString($b, $o, $ssize).TrimEnd([char]0)
                $key = $script:RiffInfoMap[$sid]
                if (-not $key) { $key = $sid.Trim() }
                if ($val) { [void]$list.Add("${key}=${val}") }
                $o += $ssize
                if ($ssize % 2 -eq 1) { $o++ }
            }
        }
        if ($size -lt 0) { break }
        $pos += $size
        if ($size % 2 -eq 1) { $pos++ }
    }
    return $list.ToArray()
}

function Get-FfprobeComments([string]$Path) {
    $json = & ffprobe -v error -show_entries 'format_tags' -of json $Path 2>$null
    $list = New-Object System.Collections.Generic.List[string]
    try { $o = ($json -join "`n") | ConvertFrom-Json } catch { return $list.ToArray() }
    if ($o -and $o.format -and $o.format.tags) {
        foreach ($p in $o.format.tags.PSObject.Properties) { [void]$list.Add("$($p.Name)=$($p.Value)") }
    }
    return $list.ToArray()
}

function Get-SourceComments([IO.FileInfo]$File) {
    $ext = $File.Extension.ToLower()
    $c = @()
    if ($ext -eq '.flac') { $c = @(Get-FlacComments $File.FullName) }
    elseif ($ext -eq '.wav') { $c = @(Get-RiffInfoComments $File.FullName) }
    if ($c.Count -eq 0) { $c = @(Get-FfprobeComments $File.FullName) }
    return $c
}

function Get-OpusComments([string[]]$Comments) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($c in $Comments) {
        $ix = $c.IndexOf('=')
        if ($ix -lt 0) { continue }
        $key = $c.Substring(0, $ix)
        $val = $c.Substring($ix + 1)
        if ($key -match '^(?i)(METADATA_BLOCK_PICTURE|COVERART|COVERARTMIME)$') { continue }
        if ($key -ieq 'ARTIST' -and $val.Contains(';')) {
            foreach ($a in ($val -split ';')) {
                $a = $a.Trim()
                if ($a) { [void]$out.Add("${key}=${a}") }
            }
        } else {
            [void]$out.Add($c)
        }
    }
    return $out.ToArray()
}

function New-OpusTagsPacket([byte[]]$Vendor, [string[]]$Comments) {
    $ms = New-Object IO.MemoryStream
    $wr = New-Object IO.BinaryWriter($ms)
    try {
        $wr.Write([Text.Encoding]::ASCII.GetBytes('OpusTags'))
        $wr.Write([uint32]$Vendor.Length); $wr.Write($Vendor)
        $wr.Write([uint32]@($Comments).Count)
        foreach ($c in @($Comments)) {
            $cb = [Text.Encoding]::UTF8.GetBytes($c)
            $wr.Write([uint32]$cb.Length); $wr.Write($cb)
        }
        $wr.Flush()
        return $ms.ToArray()
    } finally { $wr.Dispose(); $ms.Dispose() }
}

function Get-OggCrc32([byte[]]$Data, [int]$Start, [int]$Count) {
    [uint32]$crc = 0
    $highBit = [uint32]2147483648
    $poly = [uint32]79764919
    $end = $Start + $Count
    for ($i = $Start; $i -lt $end; $i++) {
        $crc = [uint32]((($crc -bxor ([uint32]([uint32]$Data[$i] -shl 24))) -band 4294967295))
        for ($j = 0; $j -lt 8; $j++) {
            if (($crc -band $highBit) -ne 0) {
                $crc = [uint32](((($crc -shl 1) -band 4294967295)) -bxor $poly)
            } else {
                $crc = [uint32](($crc -shl 1) -band 4294967295)
            }
        }
    }
    return $crc
}

function Read-OggPages([byte[]]$Bytes) {
    $list = New-Object System.Collections.Generic.List[object]
    $pos = 0
    while ($pos + 27 -le $Bytes.Length) {
        if (-not ($Bytes[$pos] -eq 0x4F -and $Bytes[$pos+1] -eq 0x67 -and $Bytes[$pos+2] -eq 0x67 -and $Bytes[$pos+3] -eq 0x53)) { break }
        $nseg = [int]$Bytes[$pos + 26]
        if ($pos + 27 + $nseg -gt $Bytes.Length) { break }
        $seg = New-Object 'System.Byte[]' $nseg
        [Array]::Copy($Bytes, $pos + 27, $seg, 0, $nseg)
        $bodyLen = 0
        foreach ($s in $seg) { $bodyLen += [int]$s }
        $pageLen = 27 + $nseg + $bodyLen
        if ($pos + $pageLen -gt $Bytes.Length) { break }
        [void]$list.Add([pscustomobject]@{
            Offset = $pos; PageLength = $pageLen; HeaderType = [int]$Bytes[$pos + 5]
            Serial = [BitConverter]::ToUInt32($Bytes, $pos + 14); Seq = [BitConverter]::ToUInt32($Bytes, $pos + 18)
            NumSegments = $nseg; SegTable = $seg; BodyOffset = $pos + 27 + $nseg; BodyLength = $bodyLen
        })
        $pos += $pageLen
    }
    return , $list
}

function Get-OpusTagsInfo([byte[]]$Bytes, $Pages, [int]$Idx) {
    $buf = New-Object System.Collections.Generic.List[byte]
    $p = $Idx; $done = $false
    while (-not $done -and $p -lt $Pages.Count) {
        $pg = $Pages[$p]; $bo = $pg.BodyOffset
        foreach ($v in $pg.SegTable) {
            for ($k = 0; $k -lt [int]$v; $k++) { [void]$buf.Add($Bytes[$bo]); $bo++ }
            if ([int]$v -lt 255) { $done = $true; break }
        }
        $p++
    }
    $arr = $buf.ToArray()
    $vlen = 0
    if ($arr.Length -ge 12) { $vlen = [int][BitConverter]::ToUInt32($arr, 8) }
    if ($vlen -lt 0 -or $vlen + 12 -gt $arr.Length) { $vlen = 0 }
    $vendor = New-Object 'System.Byte[]' $vlen
    if ($vlen -gt 0) { [Array]::Copy($arr, 12, $vendor, 0, $vlen) }
    return [pscustomobject]@{ Vendor = $vendor; PageCount = ($p - $Idx) }
}

function New-OggPageBytes([int]$HeaderType, [uint32]$Serial, [uint32]$Seq, [byte[]]$Seg, [byte[]]$Body) {
    $page = New-Object 'System.Byte[]' (27 + $Seg.Length + $Body.Length)
    $page[0] = 0x4F; $page[1] = 0x67; $page[2] = 0x67; $page[3] = 0x53; $page[4] = 0
    $page[5] = [byte]$HeaderType
    [BitConverter]::GetBytes($Serial).CopyTo($page, 14)
    [BitConverter]::GetBytes($Seq).CopyTo($page, 18)
    $page[26] = [byte]$Seg.Length
    [Array]::Copy($Seg, 0, $page, 27, $Seg.Length)
    [Array]::Copy($Body, 0, $page, 27 + $Seg.Length, $Body.Length)
    $crc = Get-OggCrc32 $page 0 $page.Length
    [BitConverter]::GetBytes([uint32]$crc).CopyTo($page, 22)
    return $page
}

function Set-OpusTags([string]$Path, [string[]]$Comments) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $pages = Read-OggPages $bytes
    $idx = -1
    for ($i = 0; $i -lt $pages.Count; $i++) {
        $pg = $pages[$i]
        if ($pg.BodyLength -ge 8 -and [Text.Encoding]::ASCII.GetString($bytes, $pg.BodyOffset, 8) -eq 'OpusTags') { $idx = $i; break }
    }
    if ($idx -lt 0) { return $false }

    $info = Get-OpusTagsInfo $bytes $pages $idx
    $packet = New-OpusTagsPacket $info.Vendor $Comments

    $lace = New-Object System.Collections.Generic.List[int]
    $rem = $packet.Length
    while ($rem -ge 255) { [void]$lace.Add(255); $rem -= 255 }
    [void]$lace.Add($rem)

    $newPages = New-Object System.Collections.Generic.List[byte[]]
    $seq = [uint32]$pages[$idx].Seq
    $off = 0; $i2 = 0; $first = $true
    while ($i2 -lt $lace.Count) {
        $cnt = [Math]::Min(255, $lace.Count - $i2)
        $seg = New-Object 'System.Byte[]' $cnt
        $bodyLen = 0
        for ($k = 0; $k -lt $cnt; $k++) { $seg[$k] = [byte]$lace[$i2 + $k]; $bodyLen += $lace[$i2 + $k] }
        $body = New-Object 'System.Byte[]' $bodyLen
        [Array]::Copy($packet, $off, $body, 0, $bodyLen)
        $ht = if ($first) { 0 } else { 1 }
        [void]$newPages.Add((New-OggPageBytes $ht $pages[$idx].Serial $seq $seg $body))
        $off += $bodyLen; $i2 += $cnt; $seq++; $first = $false
    }

    $delta = $newPages.Count - $info.PageCount
    $ms = New-Object IO.MemoryStream
    try {
        for ($i = 0; $i -lt $pages.Count; $i++) {
            if ($i -eq $idx) {
                foreach ($np in $newPages) { $ms.Write($np, 0, $np.Length) }
                $i += ($info.PageCount - 1)
                continue
            }
            $pg = $pages[$i]
            if ($i -gt $idx -and $delta -ne 0) {
                $copy = New-Object 'System.Byte[]' $pg.PageLength
                [Array]::Copy($bytes, $pg.Offset, $copy, 0, $pg.PageLength)
                [BitConverter]::GetBytes([uint32]($pg.Seq + $delta)).CopyTo($copy, 18)
                $copy[22] = 0; $copy[23] = 0; $copy[24] = 0; $copy[25] = 0
                [BitConverter]::GetBytes([uint32](Get-OggCrc32 $copy 0 $copy.Length)).CopyTo($copy, 22)
                $ms.Write($copy, 0, $copy.Length)
            } else {
                $ms.Write($bytes, $pg.Offset, $pg.PageLength)
            }
        }
        [IO.File]::WriteAllBytes($Path, $ms.ToArray())
        return $true
    } finally { $ms.Dispose() }
}

function Extract-AudioCover([string]$Src, [string]$OutDir) {
    $json = & ffprobe -v error -select_streams v -show_entries 'stream=codec_name' -of json $Src 2>$null
    try { $o = ($json -join "`n") | ConvertFrom-Json } catch { return $null }
    if (-not $o -or -not $o.streams -or @($o.streams).Count -eq 0) { return $null }
    $codec = "$(@($o.streams)[0].codec_name)"
    $ext = switch ($codec) { 'mjpeg' { '.jpg' } 'jpeg' { '.jpg' } 'png' { '.png' } 'webp' { '.webp' } default { '.jpg' } }
    $dst = Join-Path $OutDir ('cover' + $ext)
    & ffmpeg -hide_banner -loglevel error -y -i $Src -map 0:v:0 -c copy $dst 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $dst)) { return $dst }
    return $null
}

function Test-CoverPresent([string]$Dir) {
    foreach ($n in @($script:Cfg.OpusCoverNames)) {
        foreach ($e in @($script:Cfg.OpusCoverExts)) {
            if (Test-Path -LiteralPath (Join-Path $Dir ($n + $e))) { return $true }
        }
    }
    if ((Test-Path -LiteralPath (Join-Path $Dir 'cover.jpg')) -or (Test-Path -LiteralPath (Join-Path $Dir 'cover.png'))) { return $true }
    return $false
}

function Set-AudioCover([IO.FileInfo]$File, [string]$Dst) {
    $outDir = Split-Path $Dst
    if (Test-CoverPresent $outDir) { return 'presente' }
    foreach ($n in @($script:Cfg.OpusCoverNames)) {
        foreach ($e in @($script:Cfg.OpusCoverExts)) {
            $p = Join-Path $File.DirectoryName ($n + $e)
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                Copy-Item -LiteralPath $p -Destination (Join-Path $outDir (Split-Path $p -Leaf))
                return 'copiata'
            }
        }
    }
    if (Extract-AudioCover $File.FullName $outDir) { return 'estratta' }
    return '-'
}

function Invoke-AudioJob {
    param([IO.FileInfo]$File, [string]$SrcRoot, [string]$OutRoot)

    $rel = $File.FullName.Substring($SrcRoot.Length).TrimStart('\', '/')
    $dst = Join-Path $OutRoot ([IO.Path]::ChangeExtension($rel, '.opus'))
    $row = [ordered]@{ File = $rel; InMB = [math]::Round($File.Length / 1MB, 1); OutMB = $null
                       Saved = $null; Bitrate = $script:Cfg.OpusBitrate; Tags = '-'; Cover = '-'; Status = '' }

    if ((Test-Path -LiteralPath $dst) -and -not $script:Cfg.Overwrite) { $row.Status = 'ESISTENTE'; return [pscustomobject]$row }

    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    $comments = @(Get-OpusComments (Get-SourceComments $File))

    $part = "$dst.part"
    $ffArgs = @('-hide_banner', '-loglevel', 'error', '-stats', '-y', '-i', $File.FullName,
                '-map', '0:a:0', '-vn', '-map_metadata', '-1',
                '-c:a', 'libopus', '-b:a', "$($script:Cfg.OpusBitrate)k", '-vbr', 'on',
                '-application', 'audio', '-f', 'opus', $part)
    try {
        Write-Host ("   encode Opus {0}k ..." -f $script:Cfg.OpusBitrate) -ForegroundColor DarkGray
        & ffmpeg @ffArgs
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $part)) { $row.Status = 'ERRORE ffmpeg'; return [pscustomobject]$row }
        try {
            if (Set-OpusTags $part $comments) { $row.Tags = @($comments).Count } else { $row.Tags = 'non scritti' }
        } catch { $row.Tags = 'non scritti' }
        Move-Item -LiteralPath $part -Destination $dst -Force
    } finally {
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    }

    if ($script:Cfg.OpusCover) { $row.Cover = Set-AudioCover $File $dst }

    if (Test-Path -LiteralPath $dst) {
        $outLen = (Get-Item -LiteralPath $dst).Length
        $row.OutMB = [math]::Round($outLen / 1MB, 1)
        $row.Saved = [math]::Round((1 - $outLen / $File.Length) * 100, 0)
        if ($outLen -ge $File.Length) {
            Remove-Item -LiteralPath $dst -Force
            $row.Status = 'SALTATO: output piu grande'; $row.OutMB = $null; $row.Saved = $null
        } else {
            $row.Status = 'OK'
            if ($script:Cfg.PreserveDates) {
                $o = Get-Item -LiteralPath $dst
                $o.CreationTime = $File.CreationTime
                $o.LastWriteTime = $File.LastWriteTime
            }
        }
    }
    return [pscustomobject]$row
}

# ----------------------------------------------------------------------------
#  BATCH
# ----------------------------------------------------------------------------
function Test-Source {
    if (-not $script:Cfg.SourceDir -or -not (Test-Path -LiteralPath $script:Cfg.SourceDir -PathType Container)) {
        Write-Host 'Nessuna cartella valida selezionata: usa prima [1].' -ForegroundColor Yellow
        Wait-Enter
        return $false
    }
    return $true
}

function Start-Batch([string]$Mode, [string]$Kind = 'video') {
    if (-not (Test-Source)) { return }
    $isPhoto = ($Kind -eq 'photo')
    $isAudio = ($Kind -eq 'audio')
    $enc = $null

    if ($isPhoto) {
        if (-not $script:MagickExe) {
            Write-Host "ImageMagick non trovato: installalo (comando 'magick' nel PATH) e riavvia il terminale." -ForegroundColor Red
            Wait-Enter; return
        }
        if ($Mode -eq 'verify' -and -not $script:MagickSsim) {
            Write-Host 'Questa build di ImageMagick non ha la metrica SSIM: verifica non disponibile.' -ForegroundColor Red
            Wait-Enter; return
        }
    } elseif ($isAudio) {
        if (-not $script:HasFfmpeg) {
            Write-Host 'ffmpeg/ffprobe non trovati nel PATH: conversione audio non disponibile.' -ForegroundColor Red
            Wait-Enter; return
        }
        if (-not $script:HasOpus) {
            Write-Host 'Questa build di ffmpeg non include libopus: conversione audio non disponibile.' -ForegroundColor Red
            Wait-Enter; return
        }
    } else {
        if (-not $script:HasFfmpeg) {
            Write-Host 'ffmpeg/ffprobe non trovati nel PATH: funzioni video non disponibili.' -ForegroundColor Red
            Wait-Enter; return
        }
        if ($Mode -ne 'verify') {
            $enc = Resolve-Encoder
            if (-not $enc) {
                Write-Host 'Nessun encoder disponibile con la scelta attuale (vedi [6] Impostazioni).' -ForegroundColor Red
                Wait-Enter; return
            }
        }
        if ($Mode -ne 'compress' -and -not $script:HasVmaf) {
            Write-Host 'Il tuo ffmpeg non include libvmaf: verifica non disponibile.' -ForegroundColor Red
            Wait-Enter; return
        }
    }

    $files = Get-MediaFiles $Kind
    if ($files.Count -eq 0) {
        $kindLabel = if ($isPhoto) { 'JPEG' } elseif ($isAudio) { 'audio (WAV/FLAC)' } else { 'video' }
        Write-Host ("Nessun file {0} trovato." -f $kindLabel) -ForegroundColor Yellow
        Wait-Enter; return
    }

    $srcRoot = $script:Cfg.SourceDir.TrimEnd('\', '/')
    $outRoot = if ($isAudio) { Get-OpusDir } else { Get-OutDir }
    $totalMB = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)

    Clear-Host
    Write-BoxTop
    Write-BoxLine -Text "A V V I O   E L A B O R A Z I O N E   L O T T O" -Align Center -Color Cyan
    Write-BoxSep
    Write-BoxLine -Text ("  File da elaborare : {0}  ({1} MB)" -f $files.Count, $totalMB) -Color White
    if ($isPhoto) {
        $modeStr = if ($Mode -eq 'verify') { 'solo verifica foto' } else { 'compressione foto' + $(if ($script:Cfg.PhotoVerify) { ' + verifica + retry' } else { ' (senza verifica)' }) }
        Write-BoxLine -Text ("  Modalita'         : {0}" -f $modeStr) -Color White
        Write-BoxLine -Text ("  JPEG              : qualita' {0}, {1}" -f $script:Cfg.PhotoQuality, $(if ($script:Cfg.PhotoProgressive) { 'progressivo' } else { 'baseline' })) -Color Gray
        if ($script:Cfg.PhotoVerify) {
            Write-BoxLine -Text ("  Soglia SSIM       : {0}" -f ([double]$script:Cfg.PhotoSsim).ToString('0.000', $script:Inv)) -Color Gray
        }
    } elseif ($isAudio) {
        Write-BoxLine -Text "  Modalita'         : conversione audio -> Opus" -Color White
        Write-BoxLine -Text ("  Opus              : {0} kb/s VBR" -f $script:Cfg.OpusBitrate) -Color Gray
        Write-BoxLine -Text  "  Metadati          : commenti Vorbis copiati fedelmente" -Color Gray
        Write-BoxLine -Text ("  Copertina         : {0}" -f $(if ($script:Cfg.OpusCover) { 'copiata/estratta nella cartella opus' } else { 'disattivata' })) -Color Gray
    } else {
        $modeDesc = switch ($Mode) { 'compress' { 'solo compressione' } 'full' { 'compressione + verifica VMAF + retry' } default { 'solo verifica' } }
        Write-BoxLine -Text ("  Modalita'         : {0}" -f $modeDesc) -Color White
        if ($enc) {
            $encDesc = switch ($enc) {
                'nvenc' { "NVIDIA NVENC (CQ $($script:Cfg.NvencCq), preset $($script:Cfg.NvencPreset))" }
                'qsv'   { "Intel QSV (global_quality $($script:Cfg.QsvQuality))" }
                default { "x265 (CRF $($script:Cfg.X265Crf), preset $($script:Cfg.X265Preset))" }
            }
            Write-BoxLine -Text ("  Encoder           : {0}" -f $encDesc) -Color Gray
        }
        if ($Mode -ne 'verify') {
            $aTxt = switch ($script:Cfg.AudioMode) {
                'copy'  { 'copia originale' }
                'aac'   { "AAC $($script:Cfg.AacBitrate)k" }
                default { "auto (PCM -> AAC $($script:Cfg.AacBitrate)k, altri in copia)" }
            }
            Write-BoxLine -Text ("  Audio             : {0}" -f $aTxt) -Color Gray
        }
        if ($Mode -ne 'compress') {
            Write-BoxLine -Text ("  Soglia VMAF       : {0}" -f $script:Cfg.VmafThreshold) -Color Gray
        }
    }
    Write-BoxLine -Text ("  Output            : {0}" -f $outRoot) -Color White
    Write-BoxBottom

    $ans = Read-BoxPrompt "Procedo? (s/n) [s]"
    if ($ans -and $ans -notmatch '^[sSyY]') { return }

    New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
    $results = New-Object System.Collections.Generic.List[object]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $i = 0
    foreach ($f in $files) {
        $i++
        Write-CenteredProgress -Current $i -Total $files.Count -FileName $f.Name
        $r = if ($isPhoto) { Invoke-PhotoJob -File $f -Mode $Mode -SrcRoot $srcRoot -OutRoot $outRoot }
             elseif ($isAudio) { Invoke-AudioJob -File $f -SrcRoot $srcRoot -OutRoot $outRoot }
             else          { Invoke-VideoJob -File $f -Mode $Mode -Enc $enc -SrcRoot $srcRoot -OutRoot $outRoot }
        $results.Add($r)
        $color = switch -Wildcard ($r.Status) { 'OK' { 'Green' } 'COMPRESS*' { 'Green' } 'ESISTENTE' { 'DarkGray' } 'GIA*' { 'DarkGray' } default { 'Yellow' } }
        $mTxt = if ($isPhoto) { "SSIM=$($r.SSIM)  meta=$($r.Meta)" } elseif ($isAudio) { "tags=$($r.Tags)  cover=$($r.Cover)" } else { "VMAF=$($r.VMAF)" }
        Write-Host ("   -> {0}  {1} -> {2} MB  (-{3}%)  {4}" -f $r.Status, $r.InMB, $r.OutMB, $r.Saved, $mTxt) -ForegroundColor $color
    }
    $sw.Stop()

    # --- riepilogo e log ---
    Write-Host ''
    Write-BoxTop
    Write-BoxLine -Text "R I E P I L O G O   E L A B O R A Z I O N E" -Align Center -Color Cyan
    Write-BoxBottom
    Write-Host ''
    $cols = if ($isPhoto) { 'File', 'InMB', 'OutMB', 'Saved', 'Quality', 'SSIM', 'Meta', 'Status' }
            elseif ($isAudio) { 'File', 'InMB', 'OutMB', 'Saved', 'Bitrate', 'Tags', 'Cover', 'Status' }
            else          { 'File', 'InMB', 'OutMB', 'Saved', 'Quality', 'VMAF', 'Audio', 'Status' }
    ($results | Format-Table -Property $cols -AutoSize | Out-String -Width 220).TrimEnd() | Write-Host

    $done = @($results | Where-Object { $null -ne $_.OutMB })
    if ($done.Count -gt 0) {
        $in  = ($done | Measure-Object InMB  -Sum).Sum
        $out = ($done | Measure-Object OutMB -Sum).Sum
        Write-Host ("`nTotale: {0} MB -> {1} MB  (risparmio {2:N0}%)  in {3}" -f $in, $out, ((1 - $out / $in) * 100), $sw.Elapsed.ToString('hh\:mm\:ss')) -ForegroundColor Green
    }
    $bad = @($results | Where-Object { $_.Status -match 'SOTTO|ERRORE|non letto|MANCA|METADATI' })
    if ($bad.Count -gt 0) {
        Write-Host ("`nDA CONTROLLARE ({0}):" -f $bad.Count) -ForegroundColor Yellow
        $bad | ForEach-Object { Write-Host ("  - {0}  [{1}]" -f $_.File, $_.Status) -ForegroundColor Yellow }
        if ($isPhoto) { Write-Host "Per i 'SOTTO SOGLIA': alza la qualita' foto in [6] (es. 93) o tieni l'originale." -ForegroundColor Yellow }
        elseif ($isAudio) { Write-Host "Per gli errori: controlla il file sorgente con [2] o l'installazione di ffmpeg/libopus." -ForegroundColor Yellow }
        else          { Write-Host "Per i 'SOTTO SOGLIA': abbassa la qualita' numerica (es. 21) in [6] o tieni l'originale." -ForegroundColor Yellow }
    }
    $log = Join-Path $outRoot ("log_{0}_{1}.csv" -f $Kind, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $results | Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8
    Write-Host "Log salvato: $log" -ForegroundColor DarkGray
    Wait-Enter
}

function Show-Scan {
    if (-not (Test-Source)) { return }
    $vids = if ($script:HasFfmpeg) { Get-MediaFiles 'video' } else { @() }
    $pics = if ($script:MagickExe) { Get-MediaFiles 'photo' } else { @() }
    $auds = if ($script:HasFfmpeg) { Get-MediaFiles 'audio' } else { @() }
    if ($vids.Count -eq 0 -and $pics.Count -eq 0 -and $auds.Count -eq 0) {
        Write-Host 'Nessun file video, JPEG o audio trovato nella cartella.' -ForegroundColor Yellow
        Wait-Enter; return
    }

    if ($vids.Count -gt 0) {
        Write-Host "`nVIDEO" -ForegroundColor Cyan
        $rows = foreach ($f in $vids) {
            $i = Get-VideoInfo $f.FullName
            [pscustomobject]@{
                File = $f.Name; MB = [math]::Round($f.Length / 1MB, 1)
                Codec = $i.Codec; Res = "$($i.Width)x$($i.Height)"; FPS = [math]::Round($i.Fps, 2)
                PixFmt = $i.PixFmt; Trc = $i.Trc; Audio = $i.ACodec; Sec = [math]::Round($i.Duration, 1)
                Mbps = if ($i -and $i.Duration -gt 0) { [math]::Round($f.Length * 8 / $i.Duration / 1e6, 1) } else { $null }
            }
        }
        ($rows | Format-Table -AutoSize | Out-String -Width 220).TrimEnd() | Write-Host
        Write-Host ("Totale video: {0} file, {1} MB" -f $vids.Count, [math]::Round((($vids | Measure-Object Length -Sum).Sum) / 1MB, 1))
        Write-Host "Nota: 'Trc' diverso da bt709 (es. arib-std-b67 = HLG) indica profilo colore non Normal." -ForegroundColor DarkGray
    }
    if ($pics.Count -gt 0) {
        Write-Host "`nFOTO (JPEG)" -ForegroundColor Cyan
        $rows = foreach ($f in $pics) {
            $i = Get-PhotoInfo $f.FullName
            [pscustomobject]@{
                File = $f.Name; MB = [math]::Round($f.Length / 1MB, 1)
                Res = if ($i) { "$($i.Width)x$($i.Height)" } else { '?' }
                'Q stimata' = if ($i) { $i.Q } else { '?' }
                Croma = if ($i) { $i.Sampling } else { '?' }
            }
        }
        ($rows | Format-Table -AutoSize | Out-String -Width 220).TrimEnd() | Write-Host
        Write-Host ("Totale foto: {0} file, {1} MB" -f $pics.Count, [math]::Round((($pics | Measure-Object Length -Sum).Sum) / 1MB, 1))
        Write-Host "Nota: le foto con 'Q stimata' <= qualita' foto impostata vengono saltate (gia' compresse)." -ForegroundColor DarkGray
    }
    if ($auds.Count -gt 0) {
        Write-Host "`nAUDIO (WAV / FLAC)" -ForegroundColor Cyan
        $rows = foreach ($f in $auds) {
            [pscustomobject]@{
                File = $f.Name; MB = [math]::Round($f.Length / 1MB, 1)
                Formato = $f.Extension.ToUpper().TrimStart('.')
            }
        }
        ($rows | Format-Table -AutoSize | Out-String -Width 220).TrimEnd() | Write-Host
        Write-Host ("Totale audio: {0} file, {1} MB" -f $auds.Count, [math]::Round((($auds | Measure-Object Length -Sum).Sum) / 1MB, 1))
    }
    Wait-Enter
}

# Prova su UN video: comprime a piu' valori di qualita' (CQ/CRF) su uno spezzone o sull'intero file
function Show-VideoTest {
    if (-not $script:HasFfmpeg) {
        Write-Host 'ffmpeg/ffprobe non trovati nel PATH: test video non disponibile.' -ForegroundColor Red
        Wait-Enter; return
    }
    $enc = Resolve-Encoder
    if (-not $enc) {
        Write-Host 'Nessun encoder video disponibile (vedi [6] Impostazioni).' -ForegroundColor Red
        Wait-Enter; return
    }
    if (-not $script:HasVmaf) {
        Write-Host 'libvmaf non disponibile in ffmpeg: calcolo del punteggio non disponibile.' -ForegroundColor Yellow
    }

    $default = ''
    if ($script:Cfg.SourceDir -and (Test-Path -LiteralPath $script:Cfg.SourceDir -PathType Container)) {
        $first = @(Get-MediaFiles 'video') | Select-Object -First 1
        if ($first) { $default = $first.FullName }
    }

    Clear-Host
    Write-BoxTop
    Write-BoxLine -Text "TEST QUALITA VIDEO (CONFRONTO CQ / CRF)" -Align Center -Color Cyan
    Write-BoxSep
    Write-BoxLine -Text "  Trascina un file video o premi Invio per usare il default." -Color Gray
    if ($default) {
        Write-BoxLine -Text ("  Default: {0}" -f (Split-Path $default -Leaf)) -Color DarkCyan
    }
    Write-BoxBottom

    $r = Read-BoxPrompt "Video di prova"
    if ([string]::IsNullOrWhiteSpace($r)) { $r = $default }
    $r = $r.Trim().Trim('"').Trim("'")
    if ($r -in 'q', 'annulla', 'exit', '0') { return }
    if (-not $r -or -not (Test-Path -LiteralPath $r -PathType Leaf)) {
        Write-Host 'File video non valido o non trovato.' -ForegroundColor Yellow
        Wait-Enter; return
    }
    $f = Get-Item -LiteralPath $r
    $info = Get-VideoInfo $f.FullName
    if (-not $info) {
        Write-Host 'Impossibile leggere le informazioni del video.' -ForegroundColor Red
        Wait-Enter; return
    }

    Write-Host ("`n{0}: {1} MB, {2}x{3} @ {4:N2} fps, dur {5:N1}s, croma {6}" -f $f.Name,
        [math]::Round($f.Length / 1MB, 1), $info.Width, $info.Height, $info.Fps, $info.Duration, $info.PixFmt) -ForegroundColor Cyan

    $durSec = Read-IntRange 'Durata spezzone di test in secondi (0 = intero file)' 10 0 300

    $defQ = if ($enc -in 'nvenc', 'qsv') { '20,23,26,29' } else { '18,20,22,24' }
    $qPrompt = if ($enc -eq 'nvenc') { "Valori CQ hevc_nvenc da provare" }
               elseif ($enc -eq 'qsv') { "Valori global_quality QSV da provare" }
               else { "Valori CRF x265 da provare" }

    $qInput = Read-Default $qPrompt $defQ
    $list = @()
    foreach ($t in ($qInput -split ',')) {
        $n = 0
        if ([int]::TryParse($t.Trim(), [ref]$n) -and $n -ge 10 -and $n -le 45) { $list += $n }
    }
    if ($list.Count -eq 0) {
        Write-Host 'Nessun valore di qualita valido specificato.' -ForegroundColor Yellow
        Wait-Enter; return
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'squeeze-video-test'
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $rows = @()
        $idx = 0
        foreach ($q in $list) {
            $idx++
            Write-CenteredProgress -Current $idx -Total $list.Count -FileName ("Test q={0} ({1})" -f $q, $enc)
            $outName = "test_q{0}{1}" -f $q, $f.Extension
            $dst = Join-Path $tmp $outName

            if (-not (Invoke-Encode -Src $f.FullName -Dst $dst -Info $info -Enc $enc -Q $q -Duration $durSec)) {
                Write-Host ("   errore nella codifica a q={0}" -f $q) -ForegroundColor Red
                continue
            }

            $outLen = (Get-Item -LiteralPath $dst).Length
            $clipMB = [math]::Round($outLen / 1MB, 2)

            $estTotalMB = $clipMB
            $estSaved = 0
            if ($durSec -gt 0 -and $info.Duration -gt $durSec) {
                $estTotalBytes = ($outLen / $durSec) * $info.Duration
                $estTotalMB = [math]::Round($estTotalBytes / 1MB, 1)
                $estSaved = [math]::Round((1 - ($estTotalBytes / $f.Length)) * 100, 0)
            } else {
                $estTotalMB = [math]::Round($outLen / 1MB, 1)
                $estSaved = [math]::Round((1 - ($outLen / $f.Length)) * 100, 0)
            }

            $vmaf = $null
            if ($script:HasVmaf) {
                Write-Host '   calcolo VMAF ...' -ForegroundColor DarkGray
                $vmaf = Measure-Vmaf -Dist $dst -Ref $f.FullName -Sub $script:Cfg.VmafSubsample -Duration $durSec
            }

            $rows += [pscustomobject]@{
                'CQ/CRF'      = $q
                'Clip MB'     = $clipMB
                'Est Totale'  = ("{0} MB" -f $estTotalMB)
                'Risparmio'   = ("{0}%" -f $estSaved)
                'VMAF'        = if ($null -ne $vmaf) { [math]::Round($vmaf, 2) } else { 'n/d' }
            }
        }

        Write-Host ''
        Write-BoxTop
        Write-BoxLine -Text "R I S U L T A T I   T E S T   V I D E O" -Align Center -Color Cyan
        Write-BoxBottom
        Write-Host ''
        ($rows | Format-Table -AutoSize | Out-String -Width 220).TrimEnd() | Write-Host
        Write-Host "`nScegli il valore con VMAF sopra la tua soglia (es. 96) e impostalo in [6] Impostazioni." -ForegroundColor DarkGray
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Wait-Enter
}

# Prova su UNA foto: comprime a piu' qualita' e mostra dimensione, SSIM e metadati
function Show-PhotoTest {
    if (-not $script:MagickExe) { Write-Host 'ImageMagick non trovato.' -ForegroundColor Red; Wait-Enter; return }
    $default = ''
    if ($script:Cfg.SourceDir -and (Test-Path -LiteralPath $script:Cfg.SourceDir -PathType Container)) {
        $first = @(Get-MediaFiles 'photo') | Select-Object -First 1
        if ($first) { $default = $first.FullName }
    }

    Clear-Host
    Write-BoxTop
    Write-BoxLine -Text "TEST QUALITA FOTO (CONFRONTO Q)" -Align Center -Color Cyan
    Write-BoxSep
    Write-BoxLine -Text "  Trascina una foto o premi Invio per usare il default." -Color Gray
    if ($default) {
        Write-BoxLine -Text ("  Default: {0}" -f (Split-Path $default -Leaf)) -Color DarkCyan
    }
    Write-BoxBottom

    $r = Read-BoxPrompt "Foto di prova"
    if ([string]::IsNullOrWhiteSpace($r)) { $r = $default }
    $r = $r.Trim().Trim('"').Trim("'")
    if ($r -in 'q', 'annulla', 'exit', '0') { return }
    if (-not $r -or -not (Test-Path -LiteralPath $r -PathType Leaf)) {
        Write-Host 'File non valido o non trovato.' -ForegroundColor Yellow; Wait-Enter; return
    }
    $f = Get-Item -LiteralPath $r
    $info = Get-PhotoInfo $f.FullName
    if (-not $info) { Write-Host 'Immagine non leggibile.' -ForegroundColor Red; Wait-Enter; return }
    Write-Host ("`n{0}: {1} MB, {2}x{3}, qualita' stimata ~{4}, croma {5}" -f $f.Name, [math]::Round($f.Length / 1MB, 2), $info.Width, $info.Height, $info.Q, $info.Sampling)

    $list = @()
    foreach ($t in (Read-Default 'Qualita da provare (separate da virgola)' '80,85,88,90,92,95') -split ',') {
        $n = 0
        if ([int]::TryParse($t.Trim(), [ref]$n) -and $n -ge 40 -and $n -le 100) { $list += $n }
    }
    if ($list.Count -eq 0) {
        Write-Host 'Nessun valore di qualita valido specificato.' -ForegroundColor Yellow
        Wait-Enter; return
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'squeeze-test'
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $rows = foreach ($q in $list) {
            $o = Join-Path $tmp ("q{0}.jpg" -f $q)
            Write-Host ("  provo Q={0} ..." -f $q) -ForegroundColor DarkGray
            if (-not (Invoke-PhotoEncode -Src $f.FullName -Dst $o -Info $info -Q $q)) { continue }
            $len = (Get-Item -LiteralPath $o).Length
            $ssim = Measure-Ssim $o $f.FullName
            $meta = Test-PhotoMetadata $f.FullName $o
            [pscustomobject]@{
                Quality = $q; MB = [math]::Round($len / 1MB, 2)
                Risparmio = ('{0}%' -f [math]::Round((1 - $len / $f.Length) * 100, 0))
                SSIM = if ($null -ne $ssim) { [math]::Round($ssim, 4) } else { $null }
                Metadati = $meta.Text
            }
        }
        Write-Host ''
        Write-BoxTop
        Write-BoxLine -Text "R I S U L T A T I   T E S T   F O T O" -Align Center -Color Cyan
        Write-BoxBottom
        Write-Host ''
        ($rows | Format-Table -AutoSize | Out-String -Width 220).TrimEnd() | Write-Host
        Write-Host "`nScegli la qualita' piu' bassa con SSIM sopra la tua soglia (e Metadati OK), poi impostala in [6] -> G/H." -ForegroundColor DarkGray
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Wait-Enter
}

# ----------------------------------------------------------------------------
#  TUI INTERATTIVA
# ----------------------------------------------------------------------------
function Select-Folder {
    Clear-Host
    Write-BoxTop
    Write-BoxLine -Text "SELEZIONE CARTELLA SORGENTE" -Align Center -Color Cyan
    Write-BoxSep
    Write-BoxLine -Text "  Trascina o incolla qui il percorso di una cartella." -Color Gray
    Write-BoxLine -Text "  OPPURE premi direttamente INVIO per aprire la finestra di selezione." -Color Yellow
    Write-BoxLine -Text "  (Scrivi 'q' o 'annulla' per uscire senza modificare)" -Color DarkGray
    Write-BoxBottom

    $r = Read-BoxPrompt "Cartella"
    if ($r -in 'q', 'annulla', 'exit', '0') { return }

    if ([string]::IsNullOrWhiteSpace($r)) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = "Scegli la cartella contenente i file multimediali per Squeeze"
            $dialog.ShowNewFolderButton = $false
            if ($script:Cfg.SourceDir -and (Test-Path -LiteralPath $script:Cfg.SourceDir -PathType Container)) {
                $dialog.SelectedPath = $script:Cfg.SourceDir
            }
            $form = New-Object System.Windows.Forms.Form
            $form.TopMost = $true
            $dialogResult = $dialog.ShowDialog($form)
            $form.Dispose()
            if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK -and $dialog.SelectedPath) {
                $r = $dialog.SelectedPath
            } else {
                $dialog.Dispose()
                return
            }
            $dialog.Dispose()
        } catch {
            Write-Host "Impossibile aprire la finestra di selezione grafica." -ForegroundColor Yellow
            Wait-Enter
            return
        }
    }

    $r = $r.Trim().Trim('"').Trim("'").TrimEnd('\', '/')
    if (Test-Path -LiteralPath $r -PathType Container) {
        $script:Cfg.SourceDir = (Resolve-Path -LiteralPath $r).Path.TrimEnd('\')
        Save-Config
        Write-Host "`nCartella impostata: $($script:Cfg.SourceDir)" -ForegroundColor Green
        Start-Sleep -Milliseconds 800
    } else {
        Write-Host "`nPercorso non valido o cartella non trovata." -ForegroundColor Yellow
        Wait-Enter
    }
}

function Show-SettingsMenu {
    while ($true) {
        Clear-Host
        Write-BoxTop
        Write-BoxLine -Text "I M P O S T A Z I O N I" -Align Center -Color Cyan
        Write-BoxSep

        Write-BoxLine -Text "  VIDEO" -Color DarkCyan
        Write-BoxLine -Text ("   [1] Encoder scelto        : {0}  (auto | nvenc | qsv | x265)" -f $script:Cfg.Encoder) -Color White
        Write-BoxLine -Text ("   [2] Qualita' NVENC (CQ)   : {0}  (24 archivio, 21 sicuro, 27 compatto)" -f $script:Cfg.NvencCq) -Color White
        Write-BoxLine -Text ("   [3] Preset NVENC          : {0}  (p1 piu' veloce ... p7 piu' lento HQ)" -f $script:Cfg.NvencPreset) -Color White
        Write-BoxLine -Text ("   [4] Qualita' QSV          : {0}  (24 archivio, 21 sicuro, 27 compatto)" -f $script:Cfg.QsvQuality) -Color White
        Write-BoxLine -Text ("   [5] Qualita' x265 (CRF)   : {0}  (20 archivio, 18 sicuro, 22 compatto)" -f $script:Cfg.X265Crf) -Color White
        Write-BoxLine -Text ("   [6] Preset x265           : {0}" -f $script:Cfg.X265Preset) -Color White
        Write-BoxLine -Text ("   [7] Soglia VMAF           : {0}" -f $script:Cfg.VmafThreshold) -Color White
        Write-BoxLine -Text ("   [8] Precisione VMAF       : 1 frame ogni {0}" -f $script:Cfg.VmafSubsample) -Color White
        Write-BoxLine -Text ("   [9] Retry automatico      : {0}  (max {1} tentativi)" -f (Format-OnOff $script:Cfg.AutoRetry), $script:Cfg.MaxRetries) -Color White

        Write-BoxLine -Text "  FOTO (JPEG)" -Color DarkCyan
        Write-BoxLine -Text ("   [G] Qualita' foto (JPEG)  : {0}  (90 archivio; piu' basso = piu' piccolo)" -f $script:Cfg.PhotoQuality) -Color White
        Write-BoxLine -Text ("   [H] Soglia SSIM foto      : {0}" -f ([double]$script:Cfg.PhotoSsim).ToString('0.000', $script:Inv)) -Color White
        Write-BoxLine -Text ("   [I] JPEG progressivo      : {0}" -f (Format-OnOff $script:Cfg.PhotoProgressive)) -Color White
        Write-BoxLine -Text ("   [J] Verifica foto         : {0}  (SSIM + confronto metadati)" -f (Format-OnOff $script:Cfg.PhotoVerify)) -Color White

        Write-BoxLine -Text "  AUDIO" -Color DarkCyan
        Write-BoxLine -Text ("   [C] Audio video           : {0}  (auto: PCM->AAC, altri in copia)" -f $script:Cfg.AudioMode) -Color White
        Write-BoxLine -Text ("   [D] Bitrate AAC           : {0} kb/s" -f $script:Cfg.AacBitrate) -Color White
        Write-BoxLine -Text ("   [K] Bitrate Opus          : {0} kb/s (WAV/FLAC -> Opus)" -f $script:Cfg.OpusBitrate) -Color White
        Write-BoxLine -Text ("   [L] Copertina audio       : {0}  (copia/estrai cover in opus/)" -f (Format-OnOff $script:Cfg.OpusCover)) -Color White

        Write-BoxLine -Text "  GENERALE E SOTTOCARTELLE" -Color DarkCyan
        Write-BoxLine -Text ("   [A] Includi sottocartelle : {0}" -f (Format-OnOff $script:Cfg.Recurse)) -Color White
        Write-BoxLine -Text ("   [B] Sovrascrivi output    : {0}" -f (Format-OnOff $script:Cfg.Overwrite)) -Color White
        Write-BoxLine -Text ("   [M] Conserva date file    : {0}" -f (Format-OnOff $script:Cfg.PreserveDates)) -Color White
        $outStr = if ($script:Cfg.OutDir) { $script:Cfg.OutDir } else { '<sorgente>\out' }
        Write-BoxLine -Text ("   [N] Cartella output       : {0}" -f $outStr) -Color White
        Write-BoxLine -Text ("   [E] xvYCC -> bt709 (Sony) : {0}  (solo etichetta colore)" -f (Format-OnOff $script:Cfg.NormalizeXvYCC)) -Color White
        Write-BoxLine -Text ("   [F] Copia XML/SRT/XMP     : {0}" -f (Format-OnOff $script:Cfg.CopySidecars)) -Color White

        Write-BoxLine -Text "  PRESET E USCITA" -Color DarkCyan
        Write-BoxLine -Text  "   [P] Preset rapidi (Sicuro / Archivio / Compatto)" -Color Yellow
        Write-BoxLine -Text  "   [0] Salva e torna al menu principale" -Color Cyan
        Write-BoxBottom

        $c = (Read-BoxPrompt "Scelta").ToUpper()
        switch ($c) {
            '1' { $script:Cfg.Encoder = switch (Read-Default 'Encoder (auto/nvenc/qsv/x265)' $script:Cfg.Encoder) { 'nvenc' { 'nvenc' } 'qsv' { 'qsv' } 'x265' { 'x265' } default { 'auto' } } }
            '2' { $script:Cfg.NvencCq = Read-IntRange 'Qualita NVENC (CQ)' $script:Cfg.NvencCq 10 40 }
            '3' {
                $p = Read-Default 'Preset NVENC (p1 p2 p3 p4 p5 p6 p7)' $script:Cfg.NvencPreset
                if ($p -in 'p1','p2','p3','p4','p5','p6','p7') { $script:Cfg.NvencPreset = $p }
            }
            '4' { $script:Cfg.QsvQuality = Read-IntRange 'Qualita QSV' $script:Cfg.QsvQuality 10 40 }
            '5' { $script:Cfg.X265Crf = Read-IntRange 'CRF x265' $script:Cfg.X265Crf 10 35 }
            '6' {
                $p = Read-Default 'Preset x265 (ultrafast superfast veryfast faster fast medium slow slower)' $script:Cfg.X265Preset
                if ($p -in 'ultrafast','superfast','veryfast','faster','fast','medium','slow','slower') { $script:Cfg.X265Preset = $p }
            }
            '7' { $script:Cfg.VmafThreshold = Read-IntRange 'Soglia VMAF' $script:Cfg.VmafThreshold 80 99 }
            '8' { $script:Cfg.VmafSubsample = Read-IntRange 'Analizza 1 frame ogni N' $script:Cfg.VmafSubsample 1 30 }
            '9' {
                $script:Cfg.AutoRetry = -not $script:Cfg.AutoRetry
                if ($script:Cfg.AutoRetry) { $script:Cfg.MaxRetries = Read-IntRange 'Tentativi massimi' $script:Cfg.MaxRetries 1 5 }
            }
            'A' { $script:Cfg.Recurse = -not $script:Cfg.Recurse }
            'B' { $script:Cfg.Overwrite = -not $script:Cfg.Overwrite }
            'M' { $script:Cfg.PreserveDates = -not $script:Cfg.PreserveDates }
            'N' {
                $r = (Read-Host 'Percorso output (vuoto = <sorgente>\out)').Trim().Trim('"').Trim("'")
                $script:Cfg.OutDir = $r
            }
            'C' { $script:Cfg.AudioMode = switch (Read-Default 'Audio (auto/copy/aac)' $script:Cfg.AudioMode) { 'copy' { 'copy' } 'aac' { 'aac' } default { 'auto' } } }
            'D' { $script:Cfg.AacBitrate = Read-IntRange 'Bitrate AAC kb/s' $script:Cfg.AacBitrate 128 512 }
            'E' { $script:Cfg.NormalizeXvYCC = -not $script:Cfg.NormalizeXvYCC }
            'F' { $script:Cfg.CopySidecars = -not $script:Cfg.CopySidecars }
            'G' { $script:Cfg.PhotoQuality = Read-IntRange 'Qualita foto' $script:Cfg.PhotoQuality 50 98 }
            'H' {
                $r = Read-Default 'Soglia SSIM (0.95-0.9999)' ([double]$script:Cfg.PhotoSsim).ToString('0.0000', $script:Inv)
                $d = 0.0
                if ([double]::TryParse($r.Replace(',', '.'), [Globalization.NumberStyles]::Float, $script:Inv, [ref]$d) -and $d -ge 0.95 -and $d -lt 1) { $script:Cfg.PhotoSsim = $d }
                else { Write-Host '  Valore non valido.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
            }
            'I' { $script:Cfg.PhotoProgressive = -not $script:Cfg.PhotoProgressive }
            'J' { $script:Cfg.PhotoVerify = -not $script:Cfg.PhotoVerify }
            'K' { $script:Cfg.OpusBitrate = Read-IntRange 'Bitrate Opus kb/s' $script:Cfg.OpusBitrate 128 512 }
            'L' { $script:Cfg.OpusCover = -not $script:Cfg.OpusCover }
            'P' {
                Write-Host ' 1 = Sicuro   (NVENC CQ 21, QSV 21, x265 CRF 18, VMAF 97 | foto Q93, SSIM 0.993)'
                Write-Host ' 2 = Archivio (NVENC CQ 24, QSV 24, x265 CRF 20, VMAF 96 | foto Q90, SSIM 0.990)  <- consigliato'
                Write-Host ' 3 = Compatto (NVENC CQ 27, QSV 27, x265 CRF 22, VMAF 95 | foto Q85, SSIM 0.985)'
                switch (Read-Host 'Preset') {
                    '1' { $script:Cfg.NvencCq = 21; $script:Cfg.QsvQuality = 21; $script:Cfg.X265Crf = 18; $script:Cfg.VmafThreshold = 97; $script:Cfg.PhotoQuality = 93; $script:Cfg.PhotoSsim = 0.993 }
                    '2' { $script:Cfg.NvencCq = 24; $script:Cfg.QsvQuality = 24; $script:Cfg.X265Crf = 20; $script:Cfg.VmafThreshold = 96; $script:Cfg.PhotoQuality = 90; $script:Cfg.PhotoSsim = 0.990 }
                    '3' { $script:Cfg.NvencCq = 27; $script:Cfg.QsvQuality = 27; $script:Cfg.X265Crf = 22; $script:Cfg.VmafThreshold = 95; $script:Cfg.PhotoQuality = 85; $script:Cfg.PhotoSsim = 0.985 }
                }
            }
            '0' { Save-Config; return }
        }
        Save-Config
    }
}

function Show-MainMenu {
    while ($true) {
        Clear-Host
        Write-BoxTop
        Write-BoxLine -Text "S Q U E E Z E   •   Media Compressor" -Align Center -Color Cyan
        Write-BoxLine -Text "Video HEVC (NVENC/QSV/x265) • Foto • Audio" -Align Center -Color DarkCyan
        Write-BoxSep

        # Status badge 1: Cartella
        $dirTxt = if ($script:Cfg.SourceDir) { $script:Cfg.SourceDir } else { '(non selezionata: usa [1])' }
        $dirBadge = if ($script:Cfg.SourceDir) { 'DIR' } else { 'NON IMPOSTATA' }
        $dirCol = if ($script:Cfg.SourceDir) { 'Green' } else { 'Yellow' }
        Write-BoxBadgedLine -Label 'Cartella' -Badge $dirBadge -BadgeColor $dirCol -Detail $dirTxt -DetailColor $(if ($script:Cfg.SourceDir) { 'White' } else { 'DarkYellow' })

        # Status badge 2: Encoder
        $enc = Resolve-Encoder
        $encBadge = switch ($enc) {
            'nvenc' { 'GPU NVENC' }
            'qsv'   { 'GPU QSV' }
            'x265'  { 'CPU x265' }
            default { 'NESSUNO' }
        }
        $encBadgeCol = switch ($enc) {
            'nvenc' { 'Green' }
            'qsv'   { 'Green' }
            'x265'  { 'Yellow' }
            default { 'Red' }
        }
        $encDetail = switch ($enc) {
            'nvenc' { "NVIDIA NVENC (CQ $($script:Cfg.NvencCq), preset $($script:Cfg.NvencPreset))" }
            'qsv'   { "Intel QSV (qualita' $($script:Cfg.QsvQuality))" }
            'x265'  { "x265 (CRF $($script:Cfg.X265Crf), preset $($script:Cfg.X265Preset))" }
            default { "Nessun encoder utilizzabile (controlla [6])" }
        }
        Write-BoxBadgedLine -Label 'Encoder' -Badge $encBadge -BadgeColor $encBadgeCol -Detail $encDetail -DetailColor 'White'

        # Status badge 3: VMAF
        $vmafBadge = if ($script:HasVmaf) { 'OK' } else { 'NO' }
        $vmafBadgeCol = if ($script:HasVmaf) { 'Green' } else { 'Red' }
        $vmafDetail = if ($script:HasVmaf) {
            "Soglia $($script:Cfg.VmafThreshold) • Retry auto $(Format-OnOff $script:Cfg.AutoRetry) (1 frame ogni $($script:Cfg.VmafSubsample))"
        } else {
            "libvmaf NON presente in ffmpeg (verifica video disattivata)"
        }
        Write-BoxBadgedLine -Label 'VMAF' -Badge $vmafBadge -BadgeColor $vmafBadgeCol -Detail $vmafDetail

        # Status badge 4: Foto
        $photoBadge = if (-not $script:MagickExe) { 'NO' } elseif (-not $script:MagickSsim) { 'SENZA SSIM' } else { 'OK' }
        $photoBadgeCol = if (-not $script:MagickExe) { 'DarkGray' } elseif (-not $script:MagickSsim) { 'Yellow' } else { 'Green' }
        $photoDetail = if ($script:MagickExe) {
            $ssimStr = if ($script:MagickSsim) { ([double]$script:Cfg.PhotoSsim).ToString('0.000', $script:Inv) } else { 'non disp!' }
            $etStr = if ($script:ExifTool) { ', exiftool' } else { '' }
            "ImageMagick (Q$($script:Cfg.PhotoQuality), SSIM $ssimStr$etStr)"
        } else {
            "ImageMagick non trovato (funzioni foto disattivate)"
        }
        Write-BoxBadgedLine -Label 'Foto' -Badge $photoBadge -BadgeColor $photoBadgeCol -Detail $photoDetail

        # Status badge 5: Audio
        $audioOk = ($script:HasFfmpeg -and $script:HasOpus)
        $audioBadge = if ($audioOk) { 'OK' } else { 'NO' }
        $audioBadgeCol = if ($audioOk) { 'Green' } else { 'DarkGray' }
        $audioDetail = if (-not $script:HasFfmpeg) { "ffmpeg non trovato" }
                       elseif (-not $script:HasOpus) { "libopus non disponibile in ffmpeg" }
                       else { "WAV/FLAC -> Opus $($script:Cfg.OpusBitrate) kb/s • Cover $(Format-OnOff $script:Cfg.OpusCover)" }
        Write-BoxBadgedLine -Label 'Audio' -Badge $audioBadge -BadgeColor $audioBadgeCol -Detail $audioDetail

        Write-BoxSep
        Write-BoxLine -Text "  CARTELLA E ANALISI" -Color DarkCyan
        Write-BoxLine -Text "   [1] Scegli cartella sorgente (trascina o premi Invio per sfogliare)" -Color White
        Write-BoxLine -Text "   [2] Analizza cartella (elenco video, foto e audio)" -Color White

        Write-BoxLine -Text "  VIDEO (HEVC + VMAF)" -Color DarkCyan
        Write-BoxLine -Text "   [3] Comprimi VIDEO (solo compressione)" -Color White
        Write-BoxTwoCol -Left "   [4] Comprimi VIDEO + verifica VMAF + retry auto" -Right "*consigliato  " -LeftColor White -RightColor Green
        Write-BoxLine -Text "   [5] Solo verifica VIDEO (output gia' presenti)" -Color White
        Write-BoxLine -Text "   [11] Test qualita' su un VIDEO (confronto di piu' valori CQ/CRF)" -Color White

        Write-BoxLine -Text "  FOTO (JPEG + SSIM)" -Color DarkCyan
        Write-BoxLine -Text "   [7] Comprimi FOTO JPEG (+ verifica SSIM e metadati + retry)" -Color White
        Write-BoxLine -Text "   [8] Solo verifica FOTO (output gia' presenti)" -Color White
        Write-BoxLine -Text "   [9] Test qualita' su una FOTO (confronto di piu' valori Q)" -Color White

        Write-BoxLine -Text "  AUDIO (WAV/FLAC -> Opus)" -Color DarkCyan
        Write-BoxLine -Text "   [10] Comprimi AUDIO (WAV/FLAC -> Opus con tag e copertina)" -Color White

        Write-BoxLine -Text "  SISTEMA" -Color DarkCyan
        Write-BoxTwoCol -Left "   [6] Impostazioni" -Right "[0] Salva ed esci  " -LeftColor Cyan -RightColor Gray
        Write-BoxBottom

        $choice = Read-BoxPrompt "Scelta"
        switch ($choice) {
            '1'  { Select-Folder }
            '2'  { Show-Scan }
            '3'  { Start-Batch 'compress' }
            '4'  { Start-Batch 'full' }
            '5'  { Start-Batch 'verify' }
            '11' { Show-VideoTest }
            '6'  { Show-SettingsMenu }
            '7'  { Start-Batch 'full' 'photo' }
            '8'  { Start-Batch 'verify' 'photo' }
            '9'  { Show-PhotoTest }
            '10' { Start-Batch 'compress' 'audio' }
            '0'  { Save-Config; return }
        }
    }
}

# ----------------------------------------------------------------------------
#  AVVIO
# ----------------------------------------------------------------------------
Import-Config
Write-Host 'Controllo ffmpeg / NVENC / QSV / VMAF / ImageMagick ...' -ForegroundColor DarkGray
if (-not (Test-Tools)) { Wait-Enter; exit 1 }
Show-MainMenu
