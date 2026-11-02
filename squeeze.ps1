<#
.SYNOPSIS
    Squeeze - riduzione di video (HEVC), foto (JPEG) e conversione/organizzazione audio (Opus, M4A, AAC, MP3) con verifica qualita'.

.DESCRIPTION
    TUI testuale centrata per:
      * scegliere una cartella di media (cambia a ogni sessione, l'ultima viene ricordata)
      * comprimere video con NVIDIA NVENC (hevc_nvenc), Intel Quick Sync (hevc_qsv) o x265 (software)
      * verificare la qualita' di ogni video con VMAF contro l'originale
      * ricodificare automaticamente a qualita' piu' alta i file sotto soglia
      * salvare un log CSV con dimensioni, risparmio e punteggio di ogni file
      * gestire sia clip DJI sia Sony Alpha (audio PCM -> AAC per compatibilita' social,
        copia dei file XML/SRT affiancati, conversione 4:2:2 -> 4:2:0 quando serve)
      * comprimere le foto JPEG (Sony Alpha, ecc.) con ImageMagick, verificando SSIM e metadati
      * convertire e aggregare librerie audio (WAV, FLAC, MP3, M4A, AAC, AIFF, OGG, WMA, APE, ALAC, Opus)
        con focus principale su Opus (VBR + riscrittura Ogg OpusTags con artisti multipli separati)
        e supporto aggiuntivo per M4A, AAC e MP3, modalita' Mirror o aggregatore Artista/Album
        (compilation Various Artists e multi-disco) ed esportazione copertina
      * opzione facoltativa per eliminare gli originali convertiti con successo

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

$script:DefaultAudioExts = @('.wav', '.flac', '.mp3', '.aiff', '.aif', '.m4a', '.aac', '.ogg', '.oga', '.wma', '.ape', '.alac', '.opus')
$script:DefaultCoverNames = @('cover', 'folder', 'front', 'album', 'albumart', 'albumcover')

# ----------------------------------------------------------------------------
#  CONFIGURAZIONE (salvata in squeeze.config.json accanto allo script)
# ----------------------------------------------------------------------------
$script:Cfg = [ordered]@{
    SourceDir           = ''
    OutDir              = ''            # vuoto = <cartella sorgente>\out
    Recurse             = $false        # cerca anche nelle sottocartelle
    Encoder             = 'auto'        # auto | nvenc | qsv | x265
    NvencCq             = 24            # -cq per hevc_nvenc (10-40, piu' basso = qualita' piu' alta)
    NvencPreset         = 'p7'          # p1 (piu' veloce) ... p7 (piu' lento, qualita' massima)
    QsvQuality          = 24            # -global_quality (piu' basso = qualita' piu' alta)
    X265Crf             = 20            # -crf (piu' basso = qualita' piu' alta)
    X265Preset          = 'medium'      # ultrafast ... slow, slower
    VmafThreshold       = 96            # sotto questo punteggio il file e' "da rifare"
    VmafSubsample       = 5             # 1 = tutti i frame (lento), 5 = un frame ogni 5
    AutoRetry           = $true         # ricodifica automatica se sotto soglia
    MaxRetries          = 2
    Overwrite           = $false        # sovrascrive output gia' esistenti
    PreserveDates       = $true         # copia data creazione/modifica sull'output
    DeleteOriginals     = $false        # elimina i file sorgente convertiti con esito OK
    AudioMode           = 'auto'        # auto = PCM -> AAC, altri formati in copia | copy | aac
    AacBitrate          = 320           # kb/s, usato quando l'audio dei video viene convertito in AAC
    NormalizeXvYCC      = $true         # Sony: tag trasferimento xvYCC -> bt709 (solo etichetta, pixel invariati)
    CopySidecars        = $true         # copia i file affiancati (XML Sony, SRT DJI, XMP)
    SidecarExts         = @('.xml', '.srt', '.xmp')
    PhotoQuality        = 90            # qualita' JPEG di partenza (ImageMagick -quality)
    PhotoSsim           = 0.990         # soglia SSIM: sotto, la foto viene ricodificata a qualita' piu' alta
    PhotoProgressive    = $true         # JPEG progressivo (file un po' piu' piccoli)
    PhotoVerify         = $true         # verifica SSIM + confronto metadati dopo la compressione
    PhotoExtensions     = @('.jpg', '.jpeg')
    Extensions          = @('.mp4', '.mov')
    AudioFormat         = 'opus'        # opus (focus principale) | m4a | aac | mp3
    OpusBitrate         = 160           # kb/s per la conversione audio (default 160 per Opus, 192 per M4A/AAC/MP3)
    AudioLayout         = 'mirror'      # mirror (struttura originale) | artist_album (Artista/Album/NN - Titolo)
    AudioOutDir         = ''            # vuoto = <sorgente>\opus (o <sorgente>\<formato>)
    AudioFallbackArtist = 'Unknown'     # artista di fallback per file senza tag in modalita' artist_album
    AudioFallbackAlbum  = 'Unknown'     # album di fallback per file senza tag in modalita' artist_album
    OpusCover           = $true         # copia/estrae la copertina nella cartella audio di output
    OpusExtensions      = $script:DefaultAudioExts
    OpusCoverNames      = $script:DefaultCoverNames
    OpusCoverExts       = @('.jpg', '.jpeg', '.png')
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

    if ($script:Cfg.AudioFormat -notin @('opus', 'm4a', 'aac', 'mp3')) { $script:Cfg.AudioFormat = 'opus' }
    if ($script:Cfg.AudioLayout -notin @('mirror', 'artist_album')) { $script:Cfg.AudioLayout = 'mirror' }
    if ([string]::IsNullOrWhiteSpace("$($script:Cfg.AudioFallbackArtist)")) { $script:Cfg.AudioFallbackArtist = 'Unknown' }
    if ([string]::IsNullOrWhiteSpace("$($script:Cfg.AudioFallbackAlbum)")) { $script:Cfg.AudioFallbackAlbum = 'Unknown' }
    $script:Cfg.DeleteOriginals = [bool]$script:Cfg.DeleteOriginals

    # Migrazione automatica delle estensioni/cover audio dal vecchio default WAV/FLAC a tutti i formati musNav
    $curExts = @($script:Cfg.OpusExtensions | ForEach-Object { "$_".ToLower() })
    if ($curExts.Count -le 2 -and ($curExts -contains '.wav') -and ($curExts -contains '.flac')) {
        $script:Cfg.OpusExtensions = $script:DefaultAudioExts
    }
    $curNames = @($script:Cfg.OpusCoverNames | ForEach-Object { "$_".ToLower() })
    if ($curNames.Count -eq 4 -and -not ($curNames -contains 'albumart')) {
        $script:Cfg.OpusCoverNames = $script:DefaultCoverNames
    }

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
        if ([Console]::IsInputRedirected -and $PromptText -eq 'Scelta') { return '0' }
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
    $prefix = ("[{0}] {1,3}% ({2}/{3}) {4} " -f $bar, $pct, $Current, $Total, [char]0x2022)
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

# Cartella di destinazione dell'audio: <sorgente>\opus (default) oppure <sorgente>\<formato> / personalizzata
function Get-OpusDir {
    if (-not [string]::IsNullOrWhiteSpace("$($script:Cfg.AudioOutDir)")) {
        $custom = "$($script:Cfg.AudioOutDir)".Trim().Trim('"').Trim("'").TrimEnd('\', '/')
        if ([IO.Path]::IsPathRooted($custom)) { return $custom }
        return (Join-Path $script:Cfg.SourceDir $custom)
    }
    $fmt = if ($script:Cfg.AudioFormat) { "$($script:Cfg.AudioFormat)".ToLower() } else { 'opus' }
    $sub = if ($fmt -in @('m4a', 'aac', 'mp3')) { $fmt } else { 'opus' }
    return (Join-Path $script:Cfg.SourceDir $sub)
}

function Get-AudioFormatSpec([string]$Fmt = $script:Cfg.AudioFormat) {
    $k = if ($Fmt) { $Fmt.ToLower() } else { 'opus' }
    switch ($k) {
        'm4a' {
            return [pscustomobject]@{
                Key = 'm4a'; Ext = '.m4a'; Codec = 'aac'; Muxer = 'ipod'
                Label = 'M4A (AAC)'; DefaultBitrate = 192; Bitrates = @(128, 160, 192, 256, 320)
            }
        }
        'aac' {
            return [pscustomobject]@{
                Key = 'aac'; Ext = '.aac'; Codec = 'aac'; Muxer = 'adts'
                Label = 'AAC (ADTS)'; DefaultBitrate = 192; Bitrates = @(128, 160, 192, 256, 320)
            }
        }
        'mp3' {
            return [pscustomobject]@{
                Key = 'mp3'; Ext = '.mp3'; Codec = 'libmp3lame'; Muxer = 'mp3'
                Label = 'MP3'; DefaultBitrate = 192; Bitrates = @(128, 160, 192, 256, 320)
            }
        }
        default {
            return [pscustomobject]@{
                Key = 'opus'; Ext = '.opus'; Codec = 'libopus'; Muxer = 'opus'
                Label = 'Opus'; DefaultBitrate = 160; Bitrates = @(96, 128, 160, 192, 256)
            }
        }
    }
}

function Remove-SourceFile([string]$SrcPath, [string]$DstPath) {
    if (-not $SrcPath -or -not $DstPath) { return $false }
    if (-not (Test-Path -LiteralPath $SrcPath -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $DstPath -PathType Leaf)) { return $false }
    try {
        $sp = [IO.Path]::GetFullPath($SrcPath)
        $dp = [IO.Path]::GetFullPath($DstPath)
        if ($sp.Equals($dp, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $dstItem = Get-Item -LiteralPath $DstPath -Force -ErrorAction Stop
        if ($dstItem.Length -le 0) { return $false }
    } catch {
        return $false
    }
    try {
        Remove-Item -LiteralPath $SrcPath -Force -ErrorAction Stop
        return (-not (Test-Path -LiteralPath $SrcPath))
    } catch {
        try {
            $item = Get-Item -LiteralPath $SrcPath -Force -ErrorAction SilentlyContinue
            if ($item) { $item.Attributes = [IO.FileAttributes]::Normal }
            Remove-Item -LiteralPath $SrcPath -Force -ErrorAction Stop
            return (-not (Test-Path -LiteralPath $SrcPath))
        } catch {
            return $false
        }
    }
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
$script:HasMp3 = $false
$script:HasAac = $false

$script:HasFfmpeg = $false
$script:MagickExe = $null
$script:MagickSsim = $false
$script:ExifTool = $null

function Test-AudioEncoderAvailable([string]$Fmt = $script:Cfg.AudioFormat) {
    if (-not $script:HasFfmpeg) { return $false }
    $k = if ($Fmt) { $Fmt.ToLower() } else { 'opus' }
    switch ($k) {
        'mp3'   { return [bool]$script:HasMp3 }
        'm4a'   { return [bool]$script:HasAac }
        'aac'   { return [bool]$script:HasAac }
        default { return [bool]$script:HasOpus }
    }
}

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
        $script:HasMp3  = $enc -match 'libmp3lame'
        $script:HasAac  = $enc -match '\baac\b'
        if ($enc -match 'hevc_nvenc') {
            # Prova reale: encode minuscolo di 0.2s verso null per testare presenza GPU NVIDIA e driver
            & ffmpeg -hide_banner -loglevel error -nostdin -f lavfi -i 'color=c=black:s=1280x720:d=0.2' -vf 'format=p010le' `
                -c:v hevc_nvenc -profile:v main10 -f null - 2>$null
            if ($LASTEXITCODE -eq 0) {
                $script:NvencWorks = $true
            } else {
                & ffmpeg -hide_banner -loglevel error -nostdin -f lavfi -i 'color=c=black:s=1280x720:d=0.2' -vf 'format=nv12' `
                    -c:v hevc_nvenc -profile:v main -f null - 2>$null
                $script:NvencWorks = ($LASTEXITCODE -eq 0)
            }
        }
        if ($enc -match 'hevc_qsv') {
            # prova reale: un encode minuscolo, perche' la build puo' avere QSV ma la GPU no
            & ffmpeg -hide_banner -loglevel error -nostdin -f lavfi -i 'color=c=black:s=1280x720:d=0.2' -vf 'format=p010le' `
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
    if ($script:Cfg.Recurse -or ($Kind -eq 'audio' -and $script:Cfg.AudioLayout -eq 'artist_album')) {
        $p.Recurse = $true
    }
    $exts = switch ($Kind) {
        'photo' { @($script:Cfg.PhotoExtensions | ForEach-Object { "$_".ToLower() }) }
        'audio' { @($script:Cfg.OpusExtensions  | ForEach-Object { "$_".ToLower() }) }
        default { @($script:Cfg.Extensions      | ForEach-Object { "$_".ToLower() }) }
    }
    $excl = @(
        (Get-OutDir),
        (Get-OpusDir),
        (Join-Path $script:Cfg.SourceDir 'opus'),
        (Join-Path $script:Cfg.SourceDir 'm4a'),
        (Join-Path $script:Cfg.SourceDir 'aac'),
        (Join-Path $script:Cfg.SourceDir 'mp3')
    )
    $files = @(Get-ChildItem @p | Where-Object {
        $f = $_
        if (-not ($exts -contains $f.Extension.ToLower())) { return $false }
        foreach ($e in $excl) { if (Test-UnderDir $f.FullName $e) { return $false } }
        return $true
    } | Sort-Object FullName)

    if ($Kind -eq 'audio' -and $files.Count -eq 0 -and -not $p.Recurse) {
        $p.Recurse = $true
        $files = @(Get-ChildItem @p | Where-Object {
            $f = $_
            if (-not ($exts -contains $f.Extension.ToLower())) { return $false }
            foreach ($e in $excl) { if (Test-UnderDir $f.FullName $e) { return $false } }
            return $true
        } | Sort-Object FullName)
    }
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
#  AUDIO (Opus focus principale + M4A / AAC / MP3, Mirror e Artista/Album)
# ----------------------------------------------------------------------------
$script:RiffInfoMap = @{
    IART = 'ARTIST'; INAM = 'TITLE'; IPRD = 'ALBUM'; ICRD = 'DATE'; IGNR = 'GENRE'
    ITRK = 'TRACKNUMBER'; ICOP = 'COPYRIGHT'; ICMT = 'COMMENT'; ISFT = 'ENCODER'
    IENG = 'ENGINEER'; IWRI = 'WRITER'; IMUS = 'COMPOSER'; IALK = 'ALBUMARTIST'
    ILNG = 'LANGUAGE'; IBPM = 'BPM'; IKEY = 'KEY'
}

function Normalize-TagKey([string]$Key) {
    if ([string]::IsNullOrEmpty($Key)) { return '' }
    return ([regex]::Replace($Key.ToLowerInvariant(), '[^a-z0-9]', ''))
}

function Get-TagValue($Tags, [string[]]$Names) {
    if (-not $Tags) { return $null }
    $lookup = @{}
    if ($Tags -is [System.Collections.IDictionary]) {
        foreach ($k in $Tags.Keys) {
            $nk = Normalize-TagKey "$k"
            $val = "$($Tags[$k])".Trim()
            if ($nk -and $val -and -not $lookup.ContainsKey($nk)) { $lookup[$nk] = $val }
        }
    } else {
        foreach ($p in $Tags.PSObject.Properties) {
            $nk = Normalize-TagKey "$($p.Name)"
            $val = "$($p.Value)".Trim()
            if ($nk -and $val -and -not $lookup.ContainsKey($nk)) { $lookup[$nk] = $val }
        }
    }
    foreach ($name in $Names) {
        $nk = Normalize-TagKey $name
        if ($lookup.ContainsKey($nk) -and $lookup[$nk]) { return $lookup[$nk] }
    }
    return $null
}

function Get-FirstTagValue([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    foreach ($part in ($Value -split '[/;\x00]')) {
        $t = $part.Trim()
        if ($t) { return $t }
    }
    return $Value.Trim()
}

function Get-TrackNumber([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ("$Value" -match '^\s*(\d+)') {
        $n = 0
        if ([int]::TryParse($Matches[1], [ref]$n)) { return $n }
    }
    return $null
}

function Format-SafeFileName([string]$Name) {
    if ([string]::IsNullOrEmpty($Name)) { return '_' }
    $s = $Name
    foreach ($ch in @('<', '>', ':', '"', '/', '\', '|', '?', '*')) {
        $s = $s.Replace($ch, '_')
    }
    $s = [regex]::Replace($s, '[\x00-\x1f]', '_')
    $s = $s.TrimEnd('.', ' ')
    if ($s.Length -gt 120) {
        $s = $s.Substring(0, 120).TrimEnd('.', ' ')
    }
    if (-not $s) { return '_' }
    $base = ($s -split '\.')[0].ToUpperInvariant()
    if ($base -in @('CON', 'PRN', 'AUX', 'NUL') -or ($base.Length -eq 4 -and $base.Substring(0, 3) -in @('COM', 'LPT') -and $base[3] -match '^\d$')) {
        $s = '_' + $s
    }
    return $s
}

function Test-VariousArtists([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ((Normalize-TagKey $Value) -in @('variousartists', 'various', 'va', 'compilation', 'vari', 'artistivari'))
}

function Format-Duration([double]$Seconds) {
    $s = [int][math]::Floor([math]::Max(0, $Seconds))
    $h = [int][math]::Floor($s / 3600)
    $rem = $s % 3600
    $m = [int][math]::Floor($rem / 60)
    $sec = $rem % 60
    if ($h -gt 0) { return ("{0}h {1:D2}m" -f $h, $m) }
    if ($m -gt 0) { return ("{0}m {1:D2}s" -f $m, $sec) }
    return ("{0}s" -f $sec)
}

function Format-SampleRate($Hz) {
    if ($null -eq $Hz -or $Hz -le 0) { return 'n/d' }
    if (($Hz % 1000) -eq 0) { return ("{0} kHz" -f [int]($Hz / 1000)) }
    return ("{0} kHz" -f ([double]$Hz / 1000.0).ToString('0.0', $script:Inv))
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
    $json = & ffprobe -v error -show_entries 'format_tags:stream_tags' -of json $Path 2>$null
    $list = New-Object System.Collections.Generic.List[string]
    try { $o = ($json -join "`n") | ConvertFrom-Json } catch { return $list.ToArray() }
    if ($o -and $o.streams) {
        foreach ($s in @($o.streams)) {
            if ($s.tags) {
                foreach ($p in $s.tags.PSObject.Properties) { [void]$list.Add("$($p.Name)=$($p.Value)") }
            }
        }
    }
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

function Get-AudioInfo([string]$Path) {
    $info = [ordered]@{
        Path             = $Path
        ProbeOk          = $false
        Format           = $null
        SampleRate       = $null
        BitsPerSample    = $null
        HasEmbeddedCover = $false
        Title            = $null
        Artist           = $null
        Album            = $null
        AlbumArtist      = $null
        Track            = $null
        Disc             = $null
        DiscTotal        = $null
        Compilation      = $false
        Duration         = 0.0
    }
    $json = & ffprobe -v error -print_format json -show_format -show_streams $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return [pscustomobject]$info }
    try { $data = ($json -join "`n") | ConvertFrom-Json } catch { return [pscustomobject]$info }
    if (-not $data) { return [pscustomobject]$info }

    $info.ProbeOk = $true
    $tags = [ordered]@{}

    if ($data.streams) {
        foreach ($s in @($data.streams)) {
            if ($s.codec_type -eq 'audio') {
                if ($null -eq $info.SampleRate -and $s.sample_rate) {
                    $sr = 0
                    if ([int]::TryParse("$($s.sample_rate)", [ref]$sr) -and $sr -gt 0) { $info.SampleRate = $sr }
                }
                if ($null -eq $info.BitsPerSample) {
                    $bps = 0
                    if ($s.bits_per_sample -and [int]::TryParse("$($s.bits_per_sample)", [ref]$bps) -and $bps -gt 0) {
                        $info.BitsPerSample = $bps
                    } elseif ($s.bits_per_raw_sample -and [int]::TryParse("$($s.bits_per_raw_sample)", [ref]$bps) -and $bps -gt 0) {
                        $info.BitsPerSample = $bps
                    }
                }
                if ($s.tags) {
                    foreach ($p in $s.tags.PSObject.Properties) { $tags[$p.Name] = "$($p.Value)" }
                }
            } elseif ($s.codec_type -eq 'video') {
                if (($s.disposition -and $s.disposition.attached_pic) -or $s.codec_name) {
                    $info.HasEmbeddedCover = $true
                }
            }
        }
    }

    if ($data.format) {
        if ($data.format.format_name) {
            $fn = ("$($data.format.format_name)" -split ',')[0].Trim()
            if ($fn) { $info.Format = $fn }
        }
        if ($data.format.duration) {
            $d = 0.0
            if ([double]::TryParse("$($data.format.duration)", [Globalization.NumberStyles]::Float, $script:Inv, [ref]$d)) {
                $info.Duration = $d
            }
        }
        if ($data.format.tags) {
            foreach ($p in $data.format.tags.PSObject.Properties) { $tags[$p.Name] = "$($p.Value)" }
        }
    }

    # Integra anche eventuali commenti nativi FLAC/WAV non esposti da ffprobe
    try {
        $fi = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($fi -and $fi.Extension.ToLower() -in @('.flac', '.wav')) {
            foreach ($c in @(Get-SourceComments $fi)) {
                $ix = $c.IndexOf('=')
                if ($ix -gt 0) {
                    $ck = $c.Substring(0, $ix).Trim()
                    $cv = $c.Substring($ix + 1).Trim()
                    if ($ck -and $cv -and -not $tags.Contains($ck)) { $tags[$ck] = $cv }
                }
            }
        }
    } catch { }

    $info.Title       = Get-TagValue $tags @('title')
    $info.Artist      = Get-TagValue $tags @('artist', 'performer', 'author')
    $info.Album       = Get-TagValue $tags @('album')
    $info.AlbumArtist = Get-TagValue $tags @('album_artist', 'albumartist', 'album artist', 'band', 'ensemble')
    $info.Track       = Get-TrackNumber (Get-TagValue $tags @('track', 'tracknumber', 'trkn'))
    $discRaw          = Get-TagValue $tags @('disc', 'discnumber', 'disk', 'disknumber', 'tpos')
    if ($discRaw) {
        $parts = $discRaw -split '/'
        if ($parts[0].Trim()) { $info.Disc = Get-TrackNumber $parts[0] }
        if ($parts.Count -gt 1 -and $parts[1].Trim()) { $info.DiscTotal = Get-TrackNumber $parts[1] }
    }
    $compRaw = Get-TagValue $tags @('compilation', 'tcmp', 'cpil', 'itunescompilation')
    $effArtist = if ($info.AlbumArtist) { $info.AlbumArtist } else { $info.Artist }
    if ((Test-VariousArtists $effArtist) -or ($compRaw -and $compRaw.Trim().ToLowerInvariant() -in @('1', 'true', 'yes'))) {
        $info.Compilation = $true
    }
    return [pscustomobject]$info
}

function Get-ArtistAlbumPath([string]$OutRoot, $Info, [IO.FileInfo]$File, [string]$FallbackArtist, [string]$FallbackAlbum, [string]$Ext, [hashtable]$MultiDiscMap = $null) {
    $folderArtist = $null
    if ($Info) {
        $folderArtist = Get-FirstTagValue $Info.AlbumArtist
        if (-not $folderArtist) { $folderArtist = Get-FirstTagValue $Info.Artist }
    }
    if (-not $folderArtist) { $folderArtist = $FallbackArtist }

    $isComp = (Test-VariousArtists $folderArtist) -or ($Info -and $Info.Compilation)
    if ($isComp) { $folderArtist = 'Various Artists' }

    $album = if ($Info -and $Info.Album) { $Info.Album } else { $FallbackAlbum }
    $safeArtist = Format-SafeFileName $folderArtist
    $safeAlbum  = Format-SafeFileName $album
    $dir = Join-Path (Join-Path $OutRoot $safeArtist) $safeAlbum

    $albKey = ("{0}`n{1}" -f $safeArtist.ToLowerInvariant(), $safeAlbum.ToLowerInvariant())
    $isMultiDisc = ($Info -and $Info.DiscTotal -and $Info.DiscTotal -gt 1) -or ($MultiDiscMap -and $MultiDiscMap.ContainsKey($albKey))
    if ($isMultiDisc) {
        $dNum = if ($Info -and $Info.Disc) { $Info.Disc } else { 1 }
        $dir = Join-Path $dir ("Disc {0}" -f $dNum)
    }

    $rawTitle = if ($Info -and $Info.Title) { $Info.Title } else { [IO.Path]::GetFileNameWithoutExtension($File.Name) }
    $title = Format-SafeFileName $rawTitle
    $track = if ($Info) { $Info.Track } else { $null }

    if ($isComp) {
        $tArtistRaw = if ($Info) { Get-FirstTagValue $Info.Artist } else { $null }
        if (-not $tArtistRaw) { $tArtistRaw = $FallbackArtist }
        $tArtist = Format-SafeFileName $tArtistRaw
        $name = if ($null -ne $track) { "{0:D2} - {1} - {2}" -f [int]$track, $tArtist, $title } else { "{0} - {1}" -f $tArtist, $title }
    } else {
        $name = if ($null -ne $track) { "{0:D2} - {1}" -f [int]$track, $title } else { $title }
    }
    return (Join-Path $dir ($name + $Ext))
}

function Plan-AudioOutputs([IO.FileInfo[]]$Files, [hashtable]$InfoMap, [string]$SrcRoot, [string]$OutRoot, [string]$Layout, [string]$FallbackArtist, [string]$FallbackAlbum, [string]$Ext, [bool]$Overwrite) {
    $plan = New-Object System.Collections.Generic.List[object]
    $used = @{}
    $discTracker = @{}
    $multiDiscMap = @{}
    foreach ($f in $Files) {
        $inf = $InfoMap[$f.FullName]
        if (-not $inf) { continue }
        $fa = Get-FirstTagValue $inf.AlbumArtist
        if (-not $fa) { $fa = Get-FirstTagValue $inf.Artist }
        if (-not $fa) { $fa = $FallbackArtist }
        if ((Test-VariousArtists $fa) -or $inf.Compilation) { $fa = 'Various Artists' }
        $fl = if ($inf.Album) { $inf.Album } else { $FallbackAlbum }
        $ak = ("{0}`n{1}" -f (Format-SafeFileName $fa).ToLowerInvariant(), (Format-SafeFileName $fl).ToLowerInvariant())
        if ($inf.DiscTotal -and $inf.DiscTotal -gt 1) { $multiDiscMap[$ak] = $true }
        if ($inf.Disc) {
            if (-not $discTracker.ContainsKey($ak)) { $discTracker[$ak] = @{} }
            $discTracker[$ak][[int]$inf.Disc] = $true
            if ($inf.Disc -gt 1 -or $discTracker[$ak].Count -gt 1) { $multiDiscMap[$ak] = $true }
        }
    }
    foreach ($f in $Files) {
        $rel = $f.FullName.Substring($SrcRoot.Length).TrimStart('\', '/')
        $info = $InfoMap[$f.FullName]
        if (Test-UnderDir $f.FullName $OutRoot) {
            [void]$plan.Add([pscustomobject]@{ File = $f; Rel = $rel; Dst = $null; Info = $info; Skip = $true; Reason = 'ESISTENTE' })
            continue
        }
        if ($Ext -eq '.opus' -and $f.Extension.ToLower() -eq '.opus') {
            [void]$plan.Add([pscustomobject]@{ File = $f; Rel = $rel; Dst = $null; Info = $info; Skip = $true; Reason = 'GIA OPUS' })
            continue
        }
        if ($Layout -eq 'artist_album') {
            $dst = Get-ArtistAlbumPath -OutRoot $OutRoot -Info $info -File $f -FallbackArtist $FallbackArtist -FallbackAlbum $FallbackAlbum -Ext $Ext -MultiDiscMap $multiDiscMap
        } else {
            $dst = Join-Path $OutRoot ([IO.Path]::ChangeExtension($rel, $Ext))
        }
        if ((Test-Path -LiteralPath $dst) -and -not $Overwrite) {
            [void]$plan.Add([pscustomobject]@{ File = $f; Rel = $rel; Dst = $dst; Info = $info; Skip = $true; Reason = 'ESISTENTE' })
            continue
        }
        $key = $dst.ToLowerInvariant()
        $cnt = if ($used.ContainsKey($key)) { [int]$used[$key] } else { 0 }
        $used[$key] = $cnt + 1
        if ($cnt -gt 0) {
            $stem = [IO.Path]::GetFileNameWithoutExtension($dst)
            $parent = Split-Path $dst
            $dst = Join-Path $parent ("{0} ({1}){2}" -f $stem, ($cnt + 1), $Ext)
        }
        [void]$plan.Add([pscustomobject]@{ File = $f; Rel = $rel; Dst = $dst; Info = $info; Skip = $false; Reason = '' })
    }
    return , $plan
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

function Find-FolderCover([string]$Dir) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return $null }
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($script:Cfg.OpusCoverNames)) {
        foreach ($e in @($script:Cfg.OpusCoverExts)) {
            [void]$candidates.Add(("$n$e").ToLowerInvariant())
        }
    }
    foreach ($c in $candidates) {
        $p = Join-Path $Dir $c
        if (Test-Path -LiteralPath $p -PathType Leaf) { return (Get-Item -LiteralPath $p).FullName }
    }
    try {
        foreach ($entry in (Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue)) {
            if ($candidates -contains $entry.Name.ToLowerInvariant()) { return $entry.FullName }
        }
    } catch { }
    return $null
}

function Extract-AudioCover([string]$Src, [string]$OutDir) {
    $json = & ffprobe -v error -select_streams v -show_entries 'stream=codec_name' -of json $Src 2>$null
    try { $o = ($json -join "`n") | ConvertFrom-Json } catch { return $null }
    if (-not $o -or -not $o.streams -or @($o.streams).Count -eq 0) { return $null }
    $dstJpeg = Join-Path $OutDir 'cover.jpeg'
    & ffmpeg -hide_banner -loglevel error -nostdin -y -i $Src -map 0:v:0 -frames:v 1 -c:v mjpeg -q:v 2 $dstJpeg 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $dstJpeg)) { return $dstJpeg }
    $codec = "$(@($o.streams)[0].codec_name)"
    $ext = switch ($codec) { 'mjpeg' { '.jpg' } 'jpeg' { '.jpg' } 'png' { '.png' } 'webp' { '.webp' } default { '.jpg' } }
    $dstCopy = Join-Path $OutDir ('cover' + $ext)
    & ffmpeg -hide_banner -loglevel error -nostdin -y -i $Src -map 0:v:0 -c copy $dstCopy 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $dstCopy)) { return $dstCopy }
    return $null
}

function Test-CoverPresent([string]$Dir) {
    if ((Test-Path -LiteralPath (Join-Path $Dir 'cover.jpeg')) -or
        (Test-Path -LiteralPath (Join-Path $Dir 'cover.jpg')) -or
        (Test-Path -LiteralPath (Join-Path $Dir 'cover.png'))) { return $true }
    foreach ($n in @($script:Cfg.OpusCoverNames)) {
        foreach ($e in @($script:Cfg.OpusCoverExts)) {
            if (Test-Path -LiteralPath (Join-Path $Dir ($n + $e))) { return $true }
        }
    }
    return $false
}

function Write-FolderCover([string]$CoverSrc, [string]$OutDir) {
    $ext = [IO.Path]::GetExtension($CoverSrc).ToLowerInvariant()
    $dst = Join-Path $OutDir 'cover.jpeg'
    if ($ext -in @('.jpg', '.jpeg')) {
        Copy-Item -LiteralPath $CoverSrc -Destination $dst -Force
        return $true
    }
    & ffmpeg -hide_banner -loglevel error -nostdin -y -i $CoverSrc -frames:v 1 -c:v mjpeg -q:v 2 $dst 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $dst)) { return $true }
    Copy-Item -LiteralPath $CoverSrc -Destination (Join-Path $OutDir (Split-Path $CoverSrc -Leaf)) -Force
    return $true
}

function Set-AudioCover([IO.FileInfo]$File, [string]$Dst, $Info = $null) {
    $outDir = Split-Path $Dst
    if (Test-CoverPresent $outDir) { return 'presente' }
    if (($null -eq $Info -or $Info.HasEmbeddedCover) -and (Extract-AudioCover $File.FullName $outDir)) {
        return 'estratta'
    }
    $folderCover = Find-FolderCover $File.DirectoryName
    if ($folderCover) {
        if (Write-FolderCover $folderCover $outDir) { return 'copiata' }
    }
    if ($Info -and -not $Info.HasEmbeddedCover -and (Extract-AudioCover $File.FullName $outDir)) {
        return 'estratta'
    }
    return '-'
}

function Invoke-AudioJob {
    param(
        [IO.FileInfo]$File,
        [string]$SrcRoot,
        [string]$OutRoot,
        [string]$PlannedDst = '',
        [bool]$Skip = $false,
        [string]$SkipReason = '',
        $AudioInfo = $null
    )

    $spec = Get-AudioFormatSpec $script:Cfg.AudioFormat
    $rel = $File.FullName.Substring($SrcRoot.Length).TrimStart('\', '/')
    $dst = if ($PlannedDst) { $PlannedDst } else { Join-Path $OutRoot ([IO.Path]::ChangeExtension($rel, $spec.Ext)) }
    $outDisplay = if (Test-UnderDir $dst $OutRoot) { $dst.Substring($OutRoot.Length).TrimStart('\', '/') } else { $rel }
    $fileDisplay = if ($script:Cfg.AudioLayout -eq 'artist_album' -and -not $Skip) { "$rel -> $outDisplay" } else { $rel }

    $row = [ordered]@{
        File = $fileDisplay; InMB = [math]::Round($File.Length / 1MB, 1); OutMB = $null
        Saved = $null; Formato = $spec.Key.ToUpper(); Bitrate = $script:Cfg.OpusBitrate; Tags = '-'; Cover = '-'; Status = ''
    }

    if ($Skip) {
        $row.Status = if ($SkipReason) { $SkipReason } else { 'ESISTENTE' }
        return [pscustomobject]$row
    }
    if ((Test-Path -LiteralPath $dst) -and -not $script:Cfg.Overwrite) {
        $row.Status = 'ESISTENTE'
        return [pscustomobject]$row
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    $comments = @(Get-OpusComments (Get-SourceComments $File))

    $part = "$dst.part"
    $ffArgs = @(
        '-hide_banner', '-loglevel', 'error', '-nostdin', '-stats', '-y',
        '-i', $File.FullName,
        '-map', '0:a:0', '-vn',
        '-map_metadata', '0',
        '-map_metadata:s:a', '0:s:a',
        '-c:a', $spec.Codec,
        '-b:a', "$($script:Cfg.OpusBitrate)k"
    )
    if ($spec.Key -eq 'opus') {
        $ffArgs += @('-vbr', 'on', '-application', 'audio')
    } elseif ($spec.Key -eq 'm4a') {
        $ffArgs += @('-movflags', '+faststart')
    } elseif ($spec.Key -eq 'aac') {
        $ffArgs += @('-write_id3v2', '1')
    } elseif ($spec.Key -eq 'mp3') {
        $ffArgs += @('-id3v2_version', '3')
    }
    $ffArgs += @('-f', $spec.Muxer, $part)

    try {
        Write-Host ("   encode {0} {1}k ..." -f $spec.Label, $script:Cfg.OpusBitrate) -ForegroundColor DarkGray
        & ffmpeg @ffArgs
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $part)) {
            $row.Status = 'ERRORE ffmpeg'
            return [pscustomobject]$row
        }
        if ($spec.Key -eq 'opus') {
            if ($comments.Count -gt 0) {
                try {
                    if (Set-OpusTags $part $comments) { $row.Tags = $comments.Count } else { $row.Tags = 'ffmpeg' }
                } catch { $row.Tags = 'ffmpeg' }
            } else {
                $row.Tags = 0
            }
        } else {
            $row.Tags = $comments.Count
        }
        Move-Item -LiteralPath $part -Destination $dst -Force
    } finally {
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    }

    if ($script:Cfg.OpusCover) { $row.Cover = Set-AudioCover -File $File -Dst $dst -Info $AudioInfo }

    if (Test-Path -LiteralPath $dst) {
        $outLen = (Get-Item -LiteralPath $dst).Length
        $row.OutMB = [math]::Round($outLen / 1MB, 1)
        $row.Saved = if ($File.Length -gt 0) { [math]::Round((1 - $outLen / $File.Length) * 100, 0) } else { 0 }
        $row.Status = 'OK'
        if ($script:Cfg.PreserveDates) {
            try {
                $o = Get-Item -LiteralPath $dst
                $o.CreationTime = $File.CreationTime
                $o.LastWriteTime = $File.LastWriteTime
            } catch { }
        }
    }
    return [pscustomobject]$row
}

function Write-AudioSummary([IO.FileInfo[]]$Files, [hashtable]$InfoMap) {
    $folders = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $foldersWithCover = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $artists = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $albums = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $fmtCount = @{}
    $srCount = @{}
    $bdCount = @{}
    $totalBytes = [int64]0
    $totalDur = 0.0

    foreach ($f in $Files) {
        [void]$folders.Add($f.DirectoryName)
        $totalBytes += $f.Length
        $info = $InfoMap[$f.FullName]
        if ($info -and $info.ProbeOk) {
            $fmt = if ($info.Format) { $info.Format } else { $f.Extension.ToLower().TrimStart('.') }
            if ($fmt) { $fmtCount[$fmt] = $(if ($fmtCount.ContainsKey($fmt)) { $fmtCount[$fmt] + 1 } else { 1 }) }
            if ($info.SampleRate) { $srCount[$info.SampleRate] = $(if ($srCount.ContainsKey($info.SampleRate)) { $srCount[$info.SampleRate] + 1 } else { 1 }) }
            if ($info.BitsPerSample) { $bdCount[$info.BitsPerSample] = $(if ($bdCount.ContainsKey($info.BitsPerSample)) { $bdCount[$info.BitsPerSample] + 1 } else { 1 }) }
            if ($info.Duration -gt 0) { $totalDur += $info.Duration }
            if ($info.HasEmbeddedCover) { [void]$foldersWithCover.Add($f.DirectoryName) }
            $a = Get-FirstTagValue $info.AlbumArtist
            if (-not $a) { $a = Get-FirstTagValue $info.Artist }
            if ($a) { [void]$artists.Add($a) }
            if ($info.Album) { [void]$albums.Add($info.Album) }
        } else {
            $fmt = $f.Extension.ToLower().TrimStart('.')
            if ($fmt) { $fmtCount[$fmt] = $(if ($fmtCount.ContainsKey($fmt)) { $fmtCount[$fmt] + 1 } else { 1 }) }
        }
    }
    $coverTotal = 0
    foreach ($dir in $folders) {
        if ($foldersWithCover.Contains($dir) -or (Find-FolderCover $dir)) { $coverTotal++ }
    }

    $spec = Get-AudioFormatSpec $script:Cfg.AudioFormat
    $estMB = if ($totalDur -gt 0) { [math]::Round(($totalDur * $script:Cfg.OpusBitrate * 1000 / 8) / 1MB, 1) } else { 0 }

    Write-Host ''
    Write-BoxTop
    Write-BoxLine -Text "R I E P I L O G O   L I B R E R I A   A U D I O" -Align Center -Color Cyan
    Write-BoxSep
    Write-BoxLine -Text ("  Cartelle con audio : {0}   |   File: {1}   |   Totale: {2} MB" -f $folders.Count, $Files.Count, [math]::Round($totalBytes / 1MB, 1)) -Color White
    Write-BoxLine -Text ("  Durata complessiva : {0}   |   Copertine rilevate: {1}/{2} cartelle" -f (Format-Duration $totalDur), $coverTotal, $folders.Count) -Color Gray
    if ($fmtCount.Count -gt 0) {
        $fmtStr = (($fmtCount.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key) ($($_.Value))" }) -join ', ')
        Write-BoxLine -Text ("  Formati sorgente   : {0}" -f $fmtStr) -Color Gray
    }
    if ($srCount.Count -gt 0) {
        $srStr = (($srCount.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$(Format-SampleRate $_.Key) ($($_.Value))" }) -join ', ')
        Write-BoxLine -Text ("  Campionamento      : {0}" -f $srStr) -Color Gray
    }
    if ($bdCount.Count -gt 0) {
        $bdStr = (($bdCount.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key)-bit ($($_.Value))" }) -join ', ')
        Write-BoxLine -Text ("  Profondita' bit    : {0}" -f $bdStr) -Color Gray
    }
    if ($artists.Count -gt 0 -or $albums.Count -gt 0) {
        Write-BoxLine -Text ("  Tag rilevati       : {0} artisti unici, {1} album unici" -f $artists.Count, $albums.Count) -Color Gray
    }
    if ($estMB -gt 0) {
        Write-BoxLine -Text ("  Stima output       : ~{0} MB ({1} @ {2} kb/s)" -f $estMB, $spec.Label, $script:Cfg.OpusBitrate) -Color DarkCyan
    }
    Write-BoxBottom
}

function Write-AudioDryRunPreview($Plan, [string]$OutRoot) {
    $toConv = @($Plan | Where-Object { -not $_.Skip })
    $skipped = @($Plan | Where-Object { $_.Skip })
    if ($toConv.Count -eq 0) { return }
    $pad = Get-BoxPad $script:BoxW
    Write-Host ("`n{0}Anteprima mappatura (dry-run):" -f $pad) -ForegroundColor Cyan
    $limit = 15
    $shown = 0
    foreach ($item in $toConv) {
        if ($shown -ge $limit) { break }
        $relOut = if (Test-UnderDir $item.Dst $OutRoot) { $item.Dst.Substring($OutRoot.Length).TrimStart('\', '/') } else { $item.Dst }
        Write-Host ("{0}  {1}  <-  {2}" -f $pad, $relOut, $item.File.Name) -ForegroundColor Gray
        $shown++
    }
    if ($toConv.Count -gt $limit) {
        Write-Host ("{0}  ... e altri {1} file" -f $pad, ($toConv.Count - $limit)) -ForegroundColor DarkGray
    }
    if ($skipped.Count -gt 0) {
        Write-Host ("{0}  [saltati: {1}]" -f $pad, $skipped.Count) -ForegroundColor DarkGray
    }
}

function Read-AudioFallbacks([hashtable]$InfoMap) {
    $needArtist = $false
    $needAlbum = $false
    foreach ($info in $InfoMap.Values) {
        if (-not $info -or -not $info.ProbeOk) { continue }
        $a = Get-FirstTagValue $info.AlbumArtist
        if (-not $a) { $a = Get-FirstTagValue $info.Artist }
        if (-not $a) { $needArtist = $true }
        if (-not $info.Album) { $needAlbum = $true }
        if ($needArtist -and $needAlbum) { break }
    }
    if (-not $needArtist -and -not $needAlbum) { return }
    Write-Host "`n  Alcuni file non hanno metadati artista/album per la modalita' Artista/Album." -ForegroundColor Yellow
    if ($needArtist) {
        $script:Cfg.AudioFallbackArtist = Read-Default "  Artista per i file senza tag" $script:Cfg.AudioFallbackArtist
    }
    if ($needAlbum) {
        $script:Cfg.AudioFallbackAlbum = Read-Default "  Album per i file senza tag" $script:Cfg.AudioFallbackAlbum
    }
}

function Invoke-AudioQuickOptions([hashtable]$InfoMap) {
    Write-Host "`n  --- OPZIONI CONVERSIONE E AGGREGAZIONE AUDIO ---" -ForegroundColor Cyan
    Write-Host "  Formato di output (focus principale su Opus):" -ForegroundColor White
    Write-Host "    1) Opus (.opus) [consigliato]" -ForegroundColor Green
    Write-Host "    2) M4A  (.m4a - AAC in contenitore MP4/iTunes)" -ForegroundColor Gray
    Write-Host "    3) AAC  (.aac - ADTS raw con ID3v2)" -ForegroundColor Gray
    Write-Host "    4) MP3  (.mp3 - libmp3lame)" -ForegroundColor Gray
    $fChoice = (Read-Default "  Formato (1-4 o opus/m4a/aac/mp3)" $script:Cfg.AudioFormat).ToLowerInvariant()
    $newFmt = switch ($fChoice) {
        '1'    { 'opus' }
        'opus' { 'opus' }
        '2'    { 'm4a' }
        'm4a'  { 'm4a' }
        '3'    { 'aac' }
        'aac'  { 'aac' }
        '4'    { 'mp3' }
        'mp3'  { 'mp3' }
        default { $script:Cfg.AudioFormat }
    }
    $spec = Get-AudioFormatSpec $newFmt
    if (-not (Test-AudioEncoderAvailable $newFmt)) {
        Write-Host ("  ATTENZIONE: encoder '{0}' non trovato in ffmpeg, mantengo {1}." -f $spec.Codec, $script:Cfg.AudioFormat) -ForegroundColor Yellow
        $spec = Get-AudioFormatSpec $script:Cfg.AudioFormat
    } else {
        if ($newFmt -ne $script:Cfg.AudioFormat) {
            $script:Cfg.AudioFormat = $newFmt
            if ($script:Cfg.OpusBitrate -notin $spec.Bitrates) {
                $script:Cfg.OpusBitrate = $spec.DefaultBitrate
            }
        }
    }

    $bList = ($spec.Bitrates -join '/')
    $defB = if ($script:Cfg.OpusBitrate -gt 0) { $script:Cfg.OpusBitrate } else { $spec.DefaultBitrate }
    $script:Cfg.OpusBitrate = Read-IntRange ("  Bitrate {0} kb/s ({1})" -f $spec.Label, $bList) $defB 64 512

    Write-Host "  Organizzazione cartelle di output:" -ForegroundColor White
    Write-Host "    1) Mirror (mantiene la struttura delle sottocartelle sorgente)" -ForegroundColor Green
    Write-Host "    2) Artista/Album (aggregatore: Artista/Album/NN - Titolo, Various Artists, Disc N)" -ForegroundColor Green
    $defLay = if ($script:Cfg.AudioLayout -eq 'artist_album') { '2' } else { '1' }
    $lChoice = (Read-Default "  Modalita' (1=mirror, 2=artist_album)" $defLay).ToLowerInvariant()
    $script:Cfg.AudioLayout = if ($lChoice -in @('2', 'artist_album', 'a', 'artist', 'album')) { 'artist_album' } else { 'mirror' }

    $defOutName = if ($script:Cfg.AudioOutDir) { $script:Cfg.AudioOutDir } else { $script:Cfg.AudioFormat }
    $outInput = (Read-Default "  Nome/percorso cartella output" $defOutName).Trim().Trim('"').Trim("'").TrimEnd('\', '/')
    if ($outInput -in @('.', '..') -or $outInput -eq $script:Cfg.AudioFormat) {
        $script:Cfg.AudioOutDir = ''
    } else {
        $script:Cfg.AudioOutDir = $outInput
    }

    if ($script:Cfg.AudioLayout -eq 'artist_album' -and $InfoMap) {
        Read-AudioFallbacks $InfoMap
    }

    $defCov = if ($script:Cfg.OpusCover) { 's' } else { 'n' }
    $covAns = (Read-Default "  Esportare copertina (cover.jpeg) nella cartella di output? (s/n)" $defCov).ToLowerInvariant()
    $script:Cfg.OpusCover = ($covAns -match '^[sSyY1]')

    $defDel = if ($script:Cfg.DeleteOriginals) { 's' } else { 'n' }
    $delAns = (Read-Default "  Eliminare i file originali convertiti con successo? (s/n)" $defDel).ToLowerInvariant()
    $script:Cfg.DeleteOriginals = ($delAns -match '^[sSyY1]')

    Save-Config
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
        $spec = Get-AudioFormatSpec $script:Cfg.AudioFormat
        if (-not (Test-AudioEncoderAvailable $spec.Key)) {
            Write-Host ("Questa build di ffmpeg non include l'encoder '{0}' per {1} (vedi [6] Impostazioni)." -f $spec.Codec, $spec.Label) -ForegroundColor Red
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
        $kindLabel = if ($isPhoto) { 'JPEG' } elseif ($isAudio) { 'audio' } else { 'video' }
        Write-Host ("Nessun file {0} trovato." -f $kindLabel) -ForegroundColor Yellow
        Wait-Enter; return
    }

    $srcRoot = $script:Cfg.SourceDir.TrimEnd('\', '/')
    $audioInfoMap = @{}
    $audioPlan = $null
    $askedFallbacks = $false

    if ($isAudio) {
        Write-Host ("Analizzo {0} file audio..." -f $files.Count) -ForegroundColor DarkGray
        foreach ($f in $files) {
            $audioInfoMap[$f.FullName] = Get-AudioInfo $f.FullName
        }
    }

    while ($true) {
        $outRoot = if ($isAudio) { Get-OpusDir } else { Get-OutDir }
        $totalMB = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)

        if ($isAudio) {
            $spec = Get-AudioFormatSpec $script:Cfg.AudioFormat
            $audioPlan = Plan-AudioOutputs -Files $files -InfoMap $audioInfoMap -SrcRoot $srcRoot -OutRoot $outRoot `
                -Layout $script:Cfg.AudioLayout -FallbackArtist $script:Cfg.AudioFallbackArtist `
                -FallbackAlbum $script:Cfg.AudioFallbackAlbum -Ext $spec.Ext -Overwrite ([bool]$script:Cfg.Overwrite)
        }

        Clear-Host
        Write-BoxTop
        Write-BoxLine -Text "A V V I O   E L A B O R A Z I O N E   L O T T O" -Align Center -Color Cyan
        Write-BoxSep
        Write-BoxLine -Text ("  File trovati      : {0}  ({1} MB)" -f $files.Count, $totalMB) -Color White
        if ($isPhoto) {
            $modeStr = if ($Mode -eq 'verify') { 'solo verifica foto' } else { 'compressione foto' + $(if ($script:Cfg.PhotoVerify) { ' + verifica + retry' } else { ' (senza verifica)' }) }
            Write-BoxLine -Text ("  Modalita'         : {0}" -f $modeStr) -Color White
            Write-BoxLine -Text ("  JPEG              : qualita' {0}, {1}" -f $script:Cfg.PhotoQuality, $(if ($script:Cfg.PhotoProgressive) { 'progressivo' } else { 'baseline' })) -Color Gray
            if ($script:Cfg.PhotoVerify) {
                Write-BoxLine -Text ("  Soglia SSIM       : {0}" -f ([double]$script:Cfg.PhotoSsim).ToString('0.000', $script:Inv)) -Color Gray
            }
        } elseif ($isAudio) {
            $spec = Get-AudioFormatSpec $script:Cfg.AudioFormat
            $toConvCnt = @($audioPlan | Where-Object { -not $_.Skip }).Count
            $skipCnt = @($audioPlan | Where-Object { $_.Skip }).Count
            $layDesc = if ($script:Cfg.AudioLayout -eq 'artist_album') { 'Artista/Album (aggregatore con Various Artists e Disc N)' } else { 'Mirror (mantiene struttura cartelle)' }
            $vbrTag = if ($spec.Key -eq 'opus') { ' VBR (focus principale)' } else { '' }
            $metaDesc = if ($spec.Key -eq 'opus') { 'commenti Vorbis + multi-ARTIST (OpusTags)' } else { 'tag e metadati preservati via ffmpeg' }
            Write-BoxLine -Text ("  Da convertire     : {0} file  (saltati: {1})" -f $toConvCnt, $skipCnt) -Color White
            Write-BoxLine -Text ("  Formato e bitrate : {0} ({1}) @ {2} kb/s{3}" -f $spec.Label, $spec.Ext, $script:Cfg.OpusBitrate, $vbrTag) -Color Green
            Write-BoxLine -Text ("  Organizzazione    : {0}" -f $layDesc) -Color White
            Write-BoxLine -Text ("  Metadati          : {0}" -f $metaDesc) -Color Gray
            Write-BoxLine -Text ("  Copertina         : {0}" -f $(if ($script:Cfg.OpusCover) { 'cover.jpeg esportata per ogni cartella album' } else { 'disattivata' })) -Color Gray
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
        if ($Mode -ne 'verify') {
            $delTxt = if ($script:Cfg.DeleteOriginals) { 'SI (solo file convertiti con esito OK)' } else { 'NO (gli originali vengono conservati)' }
            $delCol = if ($script:Cfg.DeleteOriginals) { 'Yellow' } else { 'Gray' }
            Write-BoxLine -Text ("  Elimina originali : {0}" -f $delTxt) -Color $delCol
        }
        Write-BoxLine -Text ("  Output            : {0}" -f $outRoot) -Color White
        if ($isAudio) {
            Write-BoxSep
            Write-BoxLine -Text "  Premi [m] per scegliere formato (Opus/M4A/AAC/MP3), Artista/Album o elimina originali" -Color Yellow
        }
        Write-BoxBottom

        if ($isAudio) {
            Write-AudioSummary -Files $files -InfoMap $audioInfoMap
            Write-AudioDryRunPreview -Plan $audioPlan -OutRoot $outRoot
            $ans = Read-BoxPrompt "Procedo? (s = avvia, m = modifica opzioni, n = annulla) [s]"
            if ($ans -in @('m', 'M')) {
                Invoke-AudioQuickOptions $audioInfoMap
                $askedFallbacks = $true
                $files = Get-MediaFiles 'audio'
                foreach ($f in $files) {
                    if (-not $audioInfoMap.ContainsKey($f.FullName)) {
                        $audioInfoMap[$f.FullName] = Get-AudioInfo $f.FullName
                    }
                }
                continue
            }
            if ($ans -and $ans -notmatch '^[sSyY]') { return }
            if ($script:Cfg.AudioLayout -eq 'artist_album' -and -not $askedFallbacks -and -not [Console]::IsInputRedirected) {
                Read-AudioFallbacks $audioInfoMap
                Save-Config
                $spec = Get-AudioFormatSpec $script:Cfg.AudioFormat
                $audioPlan = Plan-AudioOutputs -Files $files -InfoMap $audioInfoMap -SrcRoot $srcRoot -OutRoot $outRoot `
                    -Layout $script:Cfg.AudioLayout -FallbackArtist $script:Cfg.AudioFallbackArtist `
                    -FallbackAlbum $script:Cfg.AudioFallbackAlbum -Ext $spec.Ext -Overwrite ([bool]$script:Cfg.Overwrite)
            }
            break
        } else {
            $ans = Read-BoxPrompt "Procedo? (s/n) [s]"
            if ($ans -and $ans -notmatch '^[sSyY]') { return }
            break
        }
    }

    $outRoot = if ($isAudio) { Get-OpusDir } else { Get-OutDir }
    New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
    $results = New-Object System.Collections.Generic.List[object]
    $deletedCount = 0
    $notDeleted = New-Object System.Collections.Generic.List[string]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $i = 0

    if ($isAudio) {
        foreach ($item in $audioPlan) {
            $i++
            $f = $item.File
            Write-CenteredProgress -Current $i -Total $audioPlan.Count -FileName $f.Name
            $r = Invoke-AudioJob -File $f -SrcRoot $srcRoot -OutRoot $outRoot -PlannedDst $item.Dst -Skip $item.Skip -SkipReason $item.Reason -AudioInfo $item.Info
            if ($script:Cfg.DeleteOriginals -and -not $item.Skip -and $r.Status -eq 'OK' -and $item.Dst) {
                if (Remove-SourceFile $f.FullName $item.Dst) {
                    $deletedCount++
                    $r.Status = "$($r.Status) (orig. eliminato)"
                } else {
                    [void]$notDeleted.Add($f.FullName)
                }
            }
            $results.Add($r)
            $color = switch -Wildcard ($r.Status) { 'OK*' { 'Green' } 'ESISTENTE' { 'DarkGray' } 'GIA*' { 'DarkGray' } default { 'Yellow' } }
            $mTxt = "fmt=$($r.Formato)  tags=$($r.Tags)  cover=$($r.Cover)"
            Write-Host ("   -> {0}  {1} -> {2} MB  (-{3}%)  {4}" -f $r.Status, $r.InMB, $r.OutMB, $r.Saved, $mTxt) -ForegroundColor $color
        }
    } else {
        foreach ($f in $files) {
            $i++
            $rel = $f.FullName.Substring($srcRoot.Length).TrimStart('\', '/')
            $dst = Join-Path $outRoot $rel
            Write-CenteredProgress -Current $i -Total $files.Count -FileName $f.Name
            $r = if ($isPhoto) { Invoke-PhotoJob -File $f -Mode $Mode -SrcRoot $srcRoot -OutRoot $outRoot }
                 else          { Invoke-VideoJob -File $f -Mode $Mode -Enc $enc -SrcRoot $srcRoot -OutRoot $outRoot }
            if ($script:Cfg.DeleteOriginals -and $Mode -ne 'verify' -and $r.Status -in @('OK', 'COMPRESSO (non verificato)')) {
                if (Remove-SourceFile $f.FullName $dst) {
                    $deletedCount++
                    $r.Status = "$($r.Status) (orig. eliminato)"
                } else {
                    [void]$notDeleted.Add($f.FullName)
                }
            }
            $results.Add($r)
            $color = switch -Wildcard ($r.Status) { 'OK*' { 'Green' } 'COMPRESS*' { 'Green' } 'ESISTENTE' { 'DarkGray' } 'GIA*' { 'DarkGray' } default { 'Yellow' } }
            $mTxt = if ($isPhoto) { "SSIM=$($r.SSIM)  meta=$($r.Meta)" } else { "VMAF=$($r.VMAF)" }
            Write-Host ("   -> {0}  {1} -> {2} MB  (-{3}%)  {4}" -f $r.Status, $r.InMB, $r.OutMB, $r.Saved, $mTxt) -ForegroundColor $color
        }
    }
    $sw.Stop()

    # --- riepilogo e log ---
    Write-Host ''
    Write-BoxTop
    Write-BoxLine -Text "R I E P I L O G O   E L A B O R A Z I O N E" -Align Center -Color Cyan
    Write-BoxBottom
    Write-Host ''
    $cols = if ($isPhoto) { 'File', 'InMB', 'OutMB', 'Saved', 'Quality', 'SSIM', 'Meta', 'Status' }
            elseif ($isAudio) { 'File', 'InMB', 'OutMB', 'Saved', 'Formato', 'Bitrate', 'Tags', 'Cover', 'Status' }
            else          { 'File', 'InMB', 'OutMB', 'Saved', 'Quality', 'VMAF', 'Audio', 'Status' }
    ($results | Format-Table -Property $cols -AutoSize | Out-String -Width 220).TrimEnd() | Write-Host

    $done = @($results | Where-Object { $null -ne $_.OutMB })
    if ($done.Count -gt 0) {
        $in  = ($done | Measure-Object InMB  -Sum).Sum
        $out = ($done | Measure-Object OutMB -Sum).Sum
        $pct = if ($in -gt 0) { (1 - $out / $in) * 100 } else { 0 }
        Write-Host ("`nTotale: {0} MB -> {1} MB  (risparmio {2:N0}%)  in {3}" -f $in, $out, $pct, $sw.Elapsed.ToString('hh\:mm\:ss')) -ForegroundColor Green
    }

    if ($script:Cfg.DeleteOriginals -and $Mode -ne 'verify') {
        if ($deletedCount -gt 0) {
            Write-Host ("Originali eliminati: {0}" -f $deletedCount) -ForegroundColor Yellow
        }
        if ($notDeleted.Count -gt 0) {
            Write-Host ("Impossibile eliminare {0} file (bloccati/sola-lettura):" -f $notDeleted.Count) -ForegroundColor Red
            foreach ($nd in $notDeleted) { Write-Host ("  - {0}" -f (Split-Path $nd -Leaf)) -ForegroundColor Red }
        }
    }

    $bad = @($results | Where-Object { $_.Status -match 'SOTTO|ERRORE|non letto|MANCA|METADATI' })
    if ($bad.Count -gt 0) {
        Write-Host ("`nDA CONTROLLARE ({0}):" -f $bad.Count) -ForegroundColor Yellow
        $bad | ForEach-Object { Write-Host ("  - {0}  [{1}]" -f $_.File, $_.Status) -ForegroundColor Yellow }
        if ($isPhoto) { Write-Host "Per i 'SOTTO SOGLIA': alza la qualita' foto in [6] (es. 93) o tieni l'originale." -ForegroundColor Yellow }
        elseif ($isAudio) { Write-Host "Per gli errori: controlla il file sorgente con [2] o l'installazione di ffmpeg." -ForegroundColor Yellow }
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
        Write-Host "`nAUDIO" -ForegroundColor Cyan
        $infoMap = @{}
        $rows = foreach ($f in $auds) {
            $ai = Get-AudioInfo $f.FullName
            $infoMap[$f.FullName] = $ai
            [pscustomobject]@{
                File    = $f.Name
                MB      = [math]::Round($f.Length / 1MB, 1)
                Formato = if ($ai -and $ai.Format) { $ai.Format.ToUpper() } else { $f.Extension.ToUpper().TrimStart('.') }
                kHz     = if ($ai -and $ai.SampleRate) { Format-SampleRate $ai.SampleRate } else { '-' }
                Bit     = if ($ai -and $ai.BitsPerSample) { "$($ai.BitsPerSample)-bit" } else { '-' }
                Durata  = if ($ai -and $ai.Duration -gt 0) { Format-Duration $ai.Duration } else { '-' }
                Artista = if ($ai -and ($ai.AlbumArtist -or $ai.Artist)) { $(if ($ai.AlbumArtist) { $ai.AlbumArtist } else { $ai.Artist }) } else { '-' }
                Album   = if ($ai -and $ai.Album) { $ai.Album } else { '-' }
                Titolo  = if ($ai -and $ai.Title) { $ai.Title } else { '-' }
            }
        }
        ($rows | Format-Table -AutoSize | Out-String -Width 220).TrimEnd() | Write-Host
        Write-AudioSummary -Files $auds -InfoMap $infoMap
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

        $aSpec = Get-AudioFormatSpec $script:Cfg.AudioFormat
        Write-BoxLine -Text "  AUDIO (CONVERSIONE E AGGREGAZIONE)" -Color DarkCyan
        Write-BoxLine -Text ("   [C] Audio nei video       : {0}  (auto: PCM->AAC, altri in copia)" -f $script:Cfg.AudioMode) -Color White
        Write-BoxLine -Text ("   [D] Bitrate AAC video     : {0} kb/s" -f $script:Cfg.AacBitrate) -Color White
        Write-BoxLine -Text ("   [Q] Formato audio         : {0}  (opus [focus] | m4a | aac | mp3)" -f $script:Cfg.AudioFormat) -Color White
        Write-BoxLine -Text ("   [K] Bitrate audio         : {0} kb/s  ({1})" -f $script:Cfg.OpusBitrate, $aSpec.Label) -Color White
        Write-BoxLine -Text ("   [R] Organizzazione audio  : {0}  (mirror | artist_album)" -f $script:Cfg.AudioLayout) -Color White
        Write-BoxLine -Text ("   [L] Copertina audio       : {0}  (cover.jpeg per ogni cartella album)" -f (Format-OnOff $script:Cfg.OpusCover)) -Color White

        Write-BoxLine -Text "  GENERALE E SOTTOCARTELLE" -Color DarkCyan
        Write-BoxLine -Text ("   [A] Includi sottocartelle : {0}" -f (Format-OnOff $script:Cfg.Recurse)) -Color White
        Write-BoxLine -Text ("   [B] Sovrascrivi output    : {0}" -f (Format-OnOff $script:Cfg.Overwrite)) -Color White
        Write-BoxLine -Text ("   [M] Conserva date file    : {0}" -f (Format-OnOff $script:Cfg.PreserveDates)) -Color White
        $outStr = if ($script:Cfg.OutDir) { $script:Cfg.OutDir } else { '<sorgente>\out' }
        Write-BoxLine -Text ("   [N] Cartella output       : {0}" -f $outStr) -Color White
        Write-BoxLine -Text ("   [O] Elimina originali     : {0}  (solo file convertiti con esito OK)" -f (Format-OnOff $script:Cfg.DeleteOriginals)) -Color $(if ($script:Cfg.DeleteOriginals) { 'Yellow' } else { 'White' })
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
            'O' { $script:Cfg.DeleteOriginals = -not $script:Cfg.DeleteOriginals }
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
            'Q' {
                $f = (Read-Default 'Formato audio (opus/m4a/aac/mp3)' $script:Cfg.AudioFormat).ToLowerInvariant()
                if ($f -in @('opus', 'm4a', 'aac', 'mp3')) {
                    if ($f -ne $script:Cfg.AudioFormat) {
                        $script:Cfg.AudioFormat = $f
                        $sp = Get-AudioFormatSpec $f
                        if ($script:Cfg.OpusBitrate -notin $sp.Bitrates) { $script:Cfg.OpusBitrate = $sp.DefaultBitrate }
                    }
                }
            }
            'K' { $script:Cfg.OpusBitrate = Read-IntRange 'Bitrate audio kb/s' $script:Cfg.OpusBitrate 64 512 }
            'R' {
                $script:Cfg.AudioLayout = if ($script:Cfg.AudioLayout -eq 'artist_album') { 'mirror' } else { 'artist_album' }
            }
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
    $b = [char]0x2022
    while ($true) {
        Clear-Host
        Write-BoxTop
        Write-BoxLine -Text "S Q U E E Z E   $b   Media Compressor" -Align Center -Color Cyan
        Write-BoxLine -Text "Video HEVC (NVENC/QSV/x265) $b Foto $b Audio" -Align Center -Color DarkCyan
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
            "Soglia $($script:Cfg.VmafThreshold) $b Retry auto $(Format-OnOff $script:Cfg.AutoRetry) (1 frame ogni $($script:Cfg.VmafSubsample))"
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
        $aSpec = Get-AudioFormatSpec $script:Cfg.AudioFormat
        $audioOk = Test-AudioEncoderAvailable $aSpec.Key
        $audioBadge = if ($audioOk) { $aSpec.Key.ToUpper() } else { 'NO' }
        $audioBadgeCol = if ($audioOk) { 'Green' } else { 'DarkGray' }
        $layBadge = if ($script:Cfg.AudioLayout -eq 'artist_album') { 'Artista/Album' } else { 'Mirror' }
        $delBadge = if ($script:Cfg.DeleteOriginals) { " $b DelOrig SI" } else { '' }
        $audioDetail = if (-not $script:HasFfmpeg) { "ffmpeg non trovato" }
                       elseif (-not $audioOk) { "encoder $($aSpec.Codec) non disponibile in ffmpeg" }
                       else { "$($aSpec.Label) $($script:Cfg.OpusBitrate) kb/s $b $layBadge $b Cover $(Format-OnOff $script:Cfg.OpusCover)$delBadge" }
        Write-BoxBadgedLine -Label 'Audio' -Badge $audioBadge -BadgeColor $audioBadgeCol -Detail $audioDetail

        Write-BoxSep
        Write-BoxLine -Text "  CARTELLA E ANALISI" -Color DarkCyan
        Write-BoxLine -Text "   [1] Scegli cartella sorgente (trascina o premi Invio per sfogliare)" -Color White
        Write-BoxLine -Text "   [2] Analizza cartella (elenco video, foto e riepilogo libreria audio)" -Color White

        Write-BoxLine -Text "  VIDEO (HEVC + VMAF)" -Color DarkCyan
        Write-BoxLine -Text "   [3] Comprimi VIDEO (solo compressione)" -Color White
        Write-BoxTwoCol -Left "   [4] Comprimi VIDEO + verifica VMAF + retry auto" -Right "*consigliato  " -LeftColor White -RightColor Green
        Write-BoxLine -Text "   [5] Solo verifica VIDEO (output gia' presenti)" -Color White
        Write-BoxLine -Text "   [11] Test qualita' su un VIDEO (confronto di piu' valori CQ/CRF)" -Color White

        Write-BoxLine -Text "  FOTO (JPEG + SSIM)" -Color DarkCyan
        Write-BoxLine -Text "   [7] Comprimi FOTO JPEG (+ verifica SSIM e metadati + retry)" -Color White
        Write-BoxLine -Text "   [8] Solo verifica FOTO (output gia' presenti)" -Color White
        Write-BoxLine -Text "   [9] Test qualita' su una FOTO (confronto di piu' valori Q)" -Color White

        Write-BoxLine -Text "  AUDIO (Opus focus + M4A / AAC / MP3)" -Color DarkCyan
        Write-BoxLine -Text "   [10] Converti e organizza AUDIO (Mirror o Artista/Album, tag e cover)" -Color White

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
