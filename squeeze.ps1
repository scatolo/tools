<#
.SYNOPSIS
    Squeeze - riduzione di video (HEVC), foto (JPEG) e audio (Opus) con verifica qualita'.

.DESCRIPTION
    TUI testuale per:
      * scegliere una cartella di video (cambia a ogni sessione, l'ultima viene ricordata)
      * comprimere con Intel Quick Sync (hevc_qsv) o x265 (software)
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
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:ConfigPath = Join-Path $scriptDir 'squeeze.config.json'
$script:LegacyConfigPath = Join-Path $scriptDir 'dji-compress.config.json'

# ----------------------------------------------------------------------------
#  CONFIGURAZIONE (salvata in squeeze.config.json accanto allo script)
# ----------------------------------------------------------------------------
$script:Cfg = [ordered]@{
    SourceDir     = ''
    OutDir        = ''            # vuoto = <cartella sorgente>\out
    Recurse       = $false        # cerca anche nelle sottocartelle
    Encoder       = 'auto'        # auto | qsv | x265
    QsvQuality    = 24            # -global_quality (piu' basso = qualita' piu' alta)
    X265Crf       = 20            # -crf (piu' basso = qualita' piu' alta)
    X265Preset    = 'medium'      # ultrafast ... slow, slower
    VmafThreshold = 96            # sotto questo punteggio il file e' "da rifare"
    VmafSubsample = 5             # 1 = tutti i frame (lento), 5 = un frame ogni 5
    AutoRetry     = $true         # ricodifica automatica se sotto soglia
    MaxRetries    = 2
    Overwrite     = $false        # sovrascrive output gia' esistenti
    PreserveDates = $true         # copia data creazione/modifica sull'output
    AudioMode     = 'auto'        # auto = PCM -> AAC, altri formati in copia | copy | aac
    AacBitrate    = 320           # kb/s, usato quando l'audio viene convertito in AAC
    NormalizeXvYCC = $true        # Sony: tag trasferimento xvYCC -> bt709 (solo etichetta, pixel invariati)
    CopySidecars  = $true         # copia i file affiancati (XML Sony, SRT DJI, XMP)
    SidecarExts   = @('.xml', '.srt', '.xmp')
    PhotoQuality  = 90            # qualita' JPEG di partenza (ImageMagick -quality)
    PhotoSsim     = 0.990         # soglia SSIM: sotto, la foto viene ricodificata a qualita' piu' alta
    PhotoProgressive = $true      # JPEG progressivo (file un po' piu' piccoli)
    PhotoVerify   = $true         # verifica SSIM + confronto metadati dopo la compressione
    PhotoExtensions = @('.jpg', '.jpeg')
    Extensions    = @('.mp4', '.mov')
    OpusBitrate   = 160           # kb/s (libopus VBR); minimo consentito 128
    OpusCover     = $true         # copia/estrae la copertina nella cartella opus
    OpusExtensions = @('.wav', '.flac')
    OpusCoverNames = @('cover', 'folder', 'front', 'album')
    OpusCoverExts  = @('.jpg', '.jpeg', '.png')
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
#  UTILITA'
# ----------------------------------------------------------------------------
function Wait-Enter { [void](Read-Host 'Premi Invio per continuare') }

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
        'qsv'  { if ($script:QsvWorks) { return 'qsv' } else { return $null } }
        'x265' { if ($script:HasX265) { return 'x265' } else { return $null } }
        default {
            if ($script:QsvWorks) { return 'qsv' }
            if ($script:HasX265)  { return 'x265' }
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
    param([string]$Src, [string]$Dst, $Info, [string]$Enc, [int]$Q)

    $part = "$Dst.part"
    $fmt  = if ([IO.Path]::GetExtension($Dst).ToLower() -eq '.mov') { 'mov' } else { 'mp4' }
    $is10 = ("$($Info.PixFmt)" -match '10')
    $chromaNon420 = ("$($Info.PixFmt)" -match '422|444')   # es. Sony XAVC HS 4:2:2: si converte a 4:2:0

    $base = @('-hide_banner', '-loglevel', 'error', '-stats', '-y')
    # 0:V = solo video "vero" (esclude la copertina JPEG); -dn = niente tracce dati DJI (il muxer MP4 le rifiuta)
    $maps = @('-map', '0:V:0', '-map', '0:a?', '-dn', '-map_metadata', '0')
    $audio = @('-c:a', 'copy')
    if (Test-AudioToAac $Info) { $audio = @('-c:a', 'aac', '-b:a', "$($script:Cfg.AacBitrate)k") }
    $mux  = @('-movflags', 'use_metadata_tags+faststart', '-tag:v', 'hvc1') +
            @(Get-ColorArgs $Info) + $audio + @('-f', $fmt)

    $attempts = @()
    if ($Enc -eq 'qsv') {
        $prof  = if ($is10) { 'main10' } else { 'main' }
        $swFmt = if ($is10) { 'p010le' } else { 'nv12' }
        $venc  = @('-c:v', 'hevc_qsv', '-profile:v', $prof, '-preset', 'veryslow',
                   '-global_quality', "$Q", '-look_ahead', '1')
        # tentativo 1: decodifica + encode tutto su GPU; tentativo 2: decodifica software (fallback)
        # con 4:2:2/4:4:4 salto il percorso GPU completo e uso decodifica software + conversione 4:2:0
        if (-not $chromaNon420) { $attempts += , @{ Pre = @('-hwaccel', 'qsv', '-hwaccel_output_format', 'qsv'); Vf = @() } }
        $attempts += , @{ Pre = @(); Vf = @('-vf', "format=$swFmt") }
    } else {
        $pix  = if ($chromaNon420) { if ($is10) { 'yuv420p10le' } else { 'yuv420p' } } elseif ($Info.PixFmt) { $Info.PixFmt } else { 'yuv420p10le' }
        $venc = @('-c:v', 'libx265', '-preset', $script:Cfg.X265Preset, '-crf', "$Q", '-pix_fmt', $pix, '-x265-params', 'log-level=error')
        $attempts += , @{ Pre = @(); Vf = @() }
    }

    try {
        foreach ($a in $attempts) {
            $ffArgs = $base + $a.Pre + @('-i', $Src) + $maps + $a.Vf + $venc + $mux + @($part)
            & ffmpeg @ffArgs
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $part)) {
                Move-Item -LiteralPath $part -Destination $Dst -Force
                return $true
            }
            if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
        }
        return $false
    } finally {
        # Ctrl+C o errore: non lasciare mai file parziali in giro
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    }
}

# ----------------------------------------------------------------------------
#  VMAF  (primo input = compresso, secondo = originale)
# ----------------------------------------------------------------------------
function Measure-Vmaf([string]$Dist, [string]$Ref, [int]$Sub) {
    $threads = [Environment]::ProcessorCount
    $filter  = "[0:v:0][1:v:0]libvmaf=n_threads=${threads}:n_subsample=${Sub}"
    # prima prova con decodifica su GPU (lascia la CPU libera per VMAF), poi fallback software
    $modes = if ($script:QsvWorks) { @($true, $false) } else { @($false) }
    foreach ($hw in $modes) {
        $pre = if ($hw) { @('-hwaccel', 'qsv') } else { @() }
        $ffArgs = @('-hide_banner', '-nostats') + $pre + @('-i', $Dist) + $pre + @('-i', $Ref) +
                  @('-lavfi', $filter, '-an', '-sn', '-dn', '-f', 'null', '-')
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

    $rel = $File.FullName.Substring($SrcRoot.Length).TrimStart('\')
    $dst = Join-Path $OutRoot $rel
    $row = [ordered]@{ File = $rel; InMB = [math]::Round($File.Length / 1MB, 1); OutMB = $null
                       Saved = $null; Quality = '-'; VMAF = $null; Audio = '-'; Status = '' }

    $info = Get-VideoInfo $File.FullName
    if (-not $info) { $row.Status = 'ERRORE: nessun video'; return [pscustomobject]$row }

    $isQsv = ($Enc -eq 'qsv')
    $q     = if ($isQsv) { [int]$script:Cfg.QsvQuality } else { [int]$script:Cfg.X265Crf }
    $qMin  = if ($isQsv) { 15 } else { 12 }
    $qStep = if ($isQsv) { 3 } else { 2 }
    $exists = Test-Path -LiteralPath $dst
    $encodedNow = $false

    if ($Mode -eq 'verify') {
        if (-not $exists) { $row.Status = 'MANCA OUTPUT'; return [pscustomobject]$row }
    } elseif ($exists -and -not $script:Cfg.Overwrite) {
        $row.Status = 'ESISTENTE'
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        Write-Host ("   encode q={0} ..." -f $q) -ForegroundColor DarkGray
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
# ImageMagick 7 recente stampa "<valore> (<distanza normalizzata>)" dove la distanza e' (1-SSIM)/2 (0 = identico):
# in quel caso SSIM = 1 - 2*distanza. Se invece stampa un solo numero lo si usa direttamente come SSIM.
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
        # gia' compressa almeno quanto il target: ricomprimerla aggiungerebbe solo perdita
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

# Legge i commenti Vorbis di un FLAC (tutti, duplicati inclusi), in ordine
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

# Legge i tag RIFF INFO di un WAV, mappandoli sulle chiavi Vorbis standard
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

# Commenti del file sorgente: parser nativo (fedele) e, solo se vuoto, fallback ffprobe
function Get-SourceComments([IO.FileInfo]$File) {
    $ext = $File.Extension.ToLower()
    $c = @()
    if ($ext -eq '.flac') { $c = @(Get-FlacComments $File.FullName) }
    elseif ($ext -eq '.wav') { $c = @(Get-RiffInfoComments $File.FullName) }
    if ($c.Count -eq 0) { $c = @(Get-FfprobeComments $File.FullName) }
    return $c
}

# Prepara i commenti per Opus: scarta le copertine incorporate, divide gli artisti sul ';'
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

# Costruisce il pacchetto Vorbis comment "OpusTags" (id venditore riusato + commenti)
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

# CRC-32 di Ogg: polinomio 0x04C11DB7, init 0, non riflesso, nessun xor finale
function Get-OggCrc32([byte[]]$Data, [int]$Start, [int]$Count) {
    [uint32]$crc = 0
    $highBit = [uint32]2147483648     # 0x80000000 come uint32 (il literal andrebbe in Int32 negativo)
    $poly = [uint32]79764919          # 0x04C11DB7
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

# Dalla pagina del pacchetto OpusTags ricava il vendor e quante pagine occupa
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

# Riscrive i tag di un file Ogg Opus, sostituendo il pacchetto OpusTags
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

    # lacing del pacchetto in segmenti da 255 byte
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

# Estrae la copertina incorporata (FLAC picture) dal file sorgente
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

# True se nella cartella esiste gia' un file copertina (nomi/estensioni configurati o cover.*)
function Test-CoverPresent([string]$Dir) {
    foreach ($n in @($script:Cfg.OpusCoverNames)) {
        foreach ($e in @($script:Cfg.OpusCoverExts)) {
            if (Test-Path -LiteralPath (Join-Path $Dir ($n + $e))) { return $true }
        }
    }
    if ((Test-Path -LiteralPath (Join-Path $Dir 'cover.jpg')) -or (Test-Path -LiteralPath (Join-Path $Dir 'cover.png'))) { return $true }
    return $false
}

# Copia la copertina affiancata (cover/folder/front/album) o, se assente, la estrae dal file
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

    Write-Host ''
    Write-Host ("File da elaborare : {0}  ({1} MB)" -f $files.Count, $totalMB)
    if ($isPhoto) {
        Write-Host ("Modalita'         : {0}" -f $(if ($Mode -eq 'verify') { 'solo verifica foto' } else { 'compressione foto' + $(if ($script:Cfg.PhotoVerify) { ' + verifica + retry' } else { ' (senza verifica)' }) }))
        Write-Host ("JPEG              : qualita' {0}, {1}, croma e metadati dell'originale" -f $script:Cfg.PhotoQuality, $(if ($script:Cfg.PhotoProgressive) { 'progressivo' } else { 'baseline' }))
        if ($script:Cfg.PhotoVerify) { Write-Host ("Soglia SSIM       : {0}" -f ([double]$script:Cfg.PhotoSsim).ToString('0.000', $script:Inv)) }
    } elseif ($isAudio) {
        Write-Host  "Modalita'         : conversione audio -> Opus"
        Write-Host ("Opus              : {0} kb/s VBR" -f $script:Cfg.OpusBitrate)
        Write-Host  "Metadati          : copiati pari-pari (artisti multipli come tag ARTIST separati)"
        Write-Host ("Copertina         : {0}" -f $(if ($script:Cfg.OpusCover) { 'copiata/estratta nella cartella opus' } else { 'disattivata' }))
    } else {
        Write-Host ("Modalita'         : {0}" -f @{ compress = 'solo compressione'; full = 'compressione + verifica + retry'; verify = 'solo verifica' }[$Mode])
        if ($enc) {
            $qTxt = if ($enc -eq 'qsv') { "QSV global_quality=$($script:Cfg.QsvQuality)" } else { "x265 crf=$($script:Cfg.X265Crf) preset=$($script:Cfg.X265Preset)" }
            Write-Host ("Encoder           : {0}" -f $qTxt)
        }
        if ($Mode -ne 'verify') {
            $aTxt = switch ($script:Cfg.AudioMode) {
                'copy'  { 'copia originale' }
                'aac'   { "AAC $($script:Cfg.AacBitrate)k" }
                default { "auto (PCM -> AAC $($script:Cfg.AacBitrate)k, altri formati in copia)" }
            }
            Write-Host ("Audio             : {0}" -f $aTxt)
        }
        if ($Mode -ne 'compress') { Write-Host ("Soglia VMAF       : {0}" -f $script:Cfg.VmafThreshold) }
    }
    Write-Host ("Output            : {0}" -f $outRoot)
    if ((Read-Default 'Procedo? (s/n)' 's') -notmatch '^[sSyY]') { return }

    New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
    $results = New-Object System.Collections.Generic.List[object]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $i = 0
    foreach ($f in $files) {
        $i++
        Write-Host ''
        Write-Host ("[{0}/{1}] {2}" -f $i, $files.Count, $f.Name) -ForegroundColor Cyan
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
    Write-Host '================ RIEPILOGO ================' -ForegroundColor Cyan
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
    if ($vids.Count -eq 0 -and $pics.Count -eq 0) { Write-Host 'Nessun file video o JPEG trovato.' -ForegroundColor Yellow; Wait-Enter; return }

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
    Wait-Enter
}

# Prova su UNA foto: comprime a piu' qualita' e mostra dimensione, SSIM e metadati (come il test VMAF dei video)
function Show-PhotoTest {
    if (-not $script:MagickExe) { Write-Host 'ImageMagick non trovato.' -ForegroundColor Red; Wait-Enter; return }
    $default = ''
    if ($script:Cfg.SourceDir -and (Test-Path -LiteralPath $script:Cfg.SourceDir -PathType Container)) {
        $first = @(Get-MediaFiles 'photo') | Select-Object -First 1
        if ($first) { $default = $first.FullName }
    }
    $r = Read-Default 'Foto di prova (trascina il file qui)' $default
    $r = $r.Trim().Trim('"').Trim("'")
    if (-not $r -or -not (Test-Path -LiteralPath $r -PathType Leaf)) {
        Write-Host 'File non valido.' -ForegroundColor Yellow; Wait-Enter; return
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
    if ($list.Count -eq 0) { return }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'squeeze-test'
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
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
    ($rows | Format-Table -AutoSize | Out-String -Width 220).TrimEnd() | Write-Host
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "`nScegli la qualita' piu' bassa con SSIM sopra la tua soglia (e Metadati OK), poi impostala in [6] -> G/H." -ForegroundColor DarkGray
    Wait-Enter
}

# ----------------------------------------------------------------------------
#  TUI
# ----------------------------------------------------------------------------
function Select-Folder {
    Write-Host ''
    Write-Host 'Trascina qui la cartella (o incolla il percorso). Invio vuoto = annulla.'
    $r = Read-Host 'Cartella'
    if ([string]::IsNullOrWhiteSpace($r)) { return }
    $r = $r.Trim().Trim('"').Trim("'").TrimEnd('\')
    if (Test-Path -LiteralPath $r -PathType Container) {
        $script:Cfg.SourceDir = (Resolve-Path -LiteralPath $r).Path.TrimEnd('\')
        Save-Config
    } else {
        Write-Host 'Percorso non valido.' -ForegroundColor Yellow
        Wait-Enter
    }
}

function Show-SettingsMenu {
    while ($true) {
        Clear-Host
        Write-Host '=============== IMPOSTAZIONI ===============' -ForegroundColor Cyan
        Write-Host (" [1] Encoder              : {0}   (auto = QSV se funziona, altrimenti x265)" -f $script:Cfg.Encoder)
        Write-Host (" [2] Qualita' QSV         : {0}   (24 = archivio, 21 = piu' sicuro, 27 = compatto)" -f $script:Cfg.QsvQuality)
        Write-Host (" [3] Qualita' x265 (CRF)  : {0}   (20 = archivio, 18 = piu' sicuro, 22 = compatto)" -f $script:Cfg.X265Crf)
        Write-Host (" [4] Preset x265          : {0}" -f $script:Cfg.X265Preset)
        Write-Host (" [5] Soglia VMAF          : {0}" -f $script:Cfg.VmafThreshold)
        Write-Host (" [6] Precisione VMAF      : 1 frame ogni {0}  (1 = tutti, piu' lento)" -f $script:Cfg.VmafSubsample)
        Write-Host (" [7] Retry automatico     : {0}   (max {1} tentativi, scende di qualita' a ogni giro)" -f (Format-OnOff $script:Cfg.AutoRetry), $script:Cfg.MaxRetries)
        Write-Host (" [8] Includi sottocartelle: {0}" -f (Format-OnOff $script:Cfg.Recurse))
        Write-Host (" [9] Sovrascrivi output   : {0}" -f (Format-OnOff $script:Cfg.Overwrite))
        Write-Host (" [A] Conserva date file   : {0}" -f (Format-OnOff $script:Cfg.PreserveDates))
        Write-Host (" [B] Cartella output      : {0}" -f $(if ($script:Cfg.OutDir) { $script:Cfg.OutDir } else { '<sorgente>\out' }))
        Write-Host (" [C] Audio                : {0}   (auto = PCM -> AAC, altri formati in copia)" -f $script:Cfg.AudioMode)
        Write-Host (" [D] Bitrate AAC          : {0} kb/s" -f $script:Cfg.AacBitrate)
        Write-Host (" [E] xvYCC -> bt709 (Sony): {0}   (solo etichetta colore, pixel invariati)" -f (Format-OnOff $script:Cfg.NormalizeXvYCC))
        Write-Host (" [F] Copia XML/SRT/XMP    : {0}" -f (Format-OnOff $script:Cfg.CopySidecars))
        Write-Host (" [G] Qualita' foto (JPEG) : {0}   (90 = archivio; piu' basso = file piu' piccoli)" -f $script:Cfg.PhotoQuality)
        Write-Host (" [H] Soglia SSIM foto     : {0}   (sotto la soglia la foto viene rifatta a Q piu' alta)" -f ([double]$script:Cfg.PhotoSsim).ToString('0.000', $script:Inv))
        Write-Host (" [I] JPEG progressivo     : {0}" -f (Format-OnOff $script:Cfg.PhotoProgressive))
        Write-Host (" [J] Verifica foto        : {0}   (SSIM + confronto metadati)" -f (Format-OnOff $script:Cfg.PhotoVerify))
        Write-Host (" [K] Bitrate Opus         : {0} kb/s   (VBR, minimo 128; audio WAV/FLAC -> Opus)" -f $script:Cfg.OpusBitrate)
        Write-Host (" [L] Copertina audio      : {0}   (copia/estrai cover nella cartella opus)" -f (Format-OnOff $script:Cfg.OpusCover))
        Write-Host ' [P] Preset rapidi (Sicuro / Archivio / Compatto)'
        Write-Host ' [0] Indietro'
        $c = (Read-Host 'Scelta').Trim().ToUpper()
        switch ($c) {
            '1' { $script:Cfg.Encoder = switch (Read-Default 'Encoder (auto/qsv/x265)' $script:Cfg.Encoder) { 'qsv' { 'qsv' } 'x265' { 'x265' } default { 'auto' } } }
            '2' { $script:Cfg.QsvQuality = Read-IntRange 'Qualita QSV' $script:Cfg.QsvQuality 10 40 }
            '3' { $script:Cfg.X265Crf = Read-IntRange 'CRF x265' $script:Cfg.X265Crf 10 35 }
            '4' {
                $p = Read-Default 'Preset (ultrafast superfast veryfast faster fast medium slow slower)' $script:Cfg.X265Preset
                if ($p -in 'ultrafast','superfast','veryfast','faster','fast','medium','slow','slower') { $script:Cfg.X265Preset = $p }
            }
            '5' { $script:Cfg.VmafThreshold = Read-IntRange 'Soglia VMAF' $script:Cfg.VmafThreshold 80 99 }
            '6' { $script:Cfg.VmafSubsample = Read-IntRange 'Analizza 1 frame ogni N' $script:Cfg.VmafSubsample 1 30 }
            '7' {
                $script:Cfg.AutoRetry = -not $script:Cfg.AutoRetry
                if ($script:Cfg.AutoRetry) { $script:Cfg.MaxRetries = Read-IntRange 'Tentativi massimi' $script:Cfg.MaxRetries 1 5 }
            }
            '8' { $script:Cfg.Recurse = -not $script:Cfg.Recurse }
            '9' { $script:Cfg.Overwrite = -not $script:Cfg.Overwrite }
            'A' { $script:Cfg.PreserveDates = -not $script:Cfg.PreserveDates }
            'B' {
                $r = (Read-Host 'Percorso output (vuoto = <sorgente>\out)').Trim().Trim('"')
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
                Write-Host ' 1 = Sicuro   (QSV 21, x265 CRF 18, soglia 97 | foto Q93, SSIM 0.993)'
                Write-Host ' 2 = Archivio (QSV 24, x265 CRF 20, soglia 96 | foto Q90, SSIM 0.990)  <- consigliato'
                Write-Host ' 3 = Compatto (QSV 27, x265 CRF 22, soglia 95 | foto Q85, SSIM 0.985)'
                switch (Read-Host 'Preset') {
                    '1' { $script:Cfg.QsvQuality = 21; $script:Cfg.X265Crf = 18; $script:Cfg.VmafThreshold = 97; $script:Cfg.PhotoQuality = 93; $script:Cfg.PhotoSsim = 0.993 }
                    '2' { $script:Cfg.QsvQuality = 24; $script:Cfg.X265Crf = 20; $script:Cfg.VmafThreshold = 96; $script:Cfg.PhotoQuality = 90; $script:Cfg.PhotoSsim = 0.990 }
                    '3' { $script:Cfg.QsvQuality = 27; $script:Cfg.X265Crf = 22; $script:Cfg.VmafThreshold = 95; $script:Cfg.PhotoQuality = 85; $script:Cfg.PhotoSsim = 0.985 }
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
        Write-Host '==============================================================' -ForegroundColor Cyan
        Write-Host '   SQUEEZE  -  video HEVC, foto JPEG, audio Opus' -ForegroundColor Cyan
        Write-Host '==============================================================' -ForegroundColor Cyan
        $enc = Resolve-Encoder
        $encTxt = switch ($enc) {
            'qsv'  { "Intel QSV (GPU), qualita' $($script:Cfg.QsvQuality)" }
            'x265' { "x265 (CPU), CRF $($script:Cfg.X265Crf), preset $($script:Cfg.X265Preset)" }
            default { 'NESSUNO DISPONIBILE (controlla [6])' }
        }
        Write-Host (" Cartella : {0}" -f $(if ($script:Cfg.SourceDir) { $script:Cfg.SourceDir } else { '(non selezionata)' }))
        Write-Host (" Encoder  : {0}" -f $encTxt)
        Write-Host (" VMAF     : {0}   soglia {1}   retry auto {2}" -f $(if ($script:HasVmaf) { 'disponibile' } else { 'NON disponibile' }), $script:Cfg.VmafThreshold, (Format-OnOff $script:Cfg.AutoRetry))
        $imTxt = if ($script:MagickExe) {
            "ImageMagick OK, Q$($script:Cfg.PhotoQuality), soglia SSIM $(([double]$script:Cfg.PhotoSsim).ToString('0.000', $script:Inv))" +
            $(if (-not $script:MagickSsim) { ' (SSIM non disponibile!)' } else { '' }) + $(if ($script:ExifTool) { ', exiftool' } else { '' })
        } else { 'ImageMagick NON trovato (funzioni foto disattivate)' }
        Write-Host (" Foto     : {0}" -f $imTxt)
        $audioTxt = if (-not $script:HasFfmpeg) { 'ffmpeg non trovato' }
                    elseif (-not $script:HasOpus) { 'libopus NON disponibile' }
                    else { "WAV/FLAC -> Opus $($script:Cfg.OpusBitrate)k, cover " + (Format-OnOff $script:Cfg.OpusCover) }
        Write-Host (" Audio    : {0}" -f $audioTxt)
        Write-Host '--------------------------------------------------------------'
        Write-Host ' [1] Scegli cartella (video, foto e audio)'
        Write-Host ' [2] Analizza cartella (elenco video e foto)'
        Write-Host ' [3] Comprimi VIDEO'
        Write-Host ' [4] Comprimi VIDEO + verifica + ricodifica automatica   (consigliato)'
        Write-Host ' [5] Solo verifica VIDEO (output gia'' presenti)'
        Write-Host ' [6] Impostazioni'
        Write-Host ' [7] Comprimi FOTO JPEG (+ verifica SSIM e metadati + retry)'
        Write-Host ' [8] Solo verifica FOTO (output gia'' presenti)'
        Write-Host ' [9] Test qualita'' su una foto (confronto di piu'' valori)'
        Write-Host ' [10] Comprimi AUDIO (WAV/FLAC -> Opus)'
        Write-Host ' [0] Esci'
        switch ((Read-Host 'Scelta').Trim()) {
            '1' { Select-Folder }
            '2' { Show-Scan }
            '3' { Start-Batch 'compress' }
            '4' { Start-Batch 'full' }
            '5' { Start-Batch 'verify' }
            '6' { Show-SettingsMenu }
            '7' { Start-Batch 'full' 'photo' }
            '8' { Start-Batch 'verify' 'photo' }
            '9' { Show-PhotoTest }
            '10' { Start-Batch 'compress' 'audio' }
            '0' { Save-Config; return }
        }
    }
}

# ----------------------------------------------------------------------------
#  AVVIO
# ----------------------------------------------------------------------------
Import-Config
Write-Host 'Controllo ffmpeg / QSV / VMAF ...' -ForegroundColor DarkGray
if (-not (Test-Tools)) { Wait-Enter; exit 1 }
Show-MainMenu
