#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
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
    Requisiti: Linux (Fedora), python3, ffmpeg e ffprobe nel PATH (build "full" con libvmaf
    e libopus); per le foto ImageMagick 7 (comando "magick"). exiftool e' opzionale (verifica metadati piu' precisa).
"""
import csv
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

# --- ANSI Colors ---
CYAN = '\033[36m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RED = '\033[31m'
GRAY = '\033[90m'
RESET = '\033[0m'

def print_color(text, color=RESET, end='\n'):
    print(f"{color}{text}{RESET}", end=end)

script_dir = Path(__file__).resolve().parent
config_path = script_dir / 'squeeze.config.json'
legacy_config_path = script_dir / 'dji-compress.config.json'

# ----------------------------------------------------------------------------
#  CONFIGURAZIONE (salvata in squeeze.config.json accanto allo script)
# ----------------------------------------------------------------------------
cfg = {
    'SourceDir': '',
    'OutDir': '',
    'Recurse': False,
    'Encoder': 'auto',
    'QsvQuality': 24,
    'X265Crf': 20,
    'X265Preset': 'medium',
    'VmafThreshold': 96,
    'VmafSubsample': 5,
    'AutoRetry': True,
    'MaxRetries': 2,
    'Overwrite': False,
    'PreserveDates': True,
    'AudioMode': 'auto',
    'AacBitrate': 320,
    'NormalizeXvYCC': True,
    'CopySidecars': True,
    'SidecarExts': ['.xml', '.srt', '.xmp'],
    'PhotoQuality': 90,
    'PhotoSsim': 0.990,
    'PhotoProgressive': True,
    'PhotoVerify': True,
    'PhotoExtensions': ['.jpg', '.jpeg'],
    'Extensions': ['.mp4', '.mov'],
    'OpusBitrate': 160,
    'OpusCover': True,
    'OpusExtensions': ['.wav', '.flac'],
    'OpusCoverNames': ['cover', 'folder', 'front', 'album'],
    'OpusCoverExts': ['.jpg', '.jpeg', '.png']
}

def import_config():
    path = config_path
    if not path.exists():
        # migrazione automatica dal vecchio nome "dji-compress"
        if legacy_config_path.exists():
            path = legacy_config_path
        else:
            return
    try:
        with open(path, 'r', encoding='utf-8') as f:
            loaded = json.load(f)
        for k, v in loaded.items():
            if k in cfg:
                cfg[k] = v
    except Exception:
        return
    # se ho letto il vecchio file, ne creo subito uno nuovo col nome corrente
    if path != config_path:
        save_config()

def save_config():
    try:
        with open(config_path, 'w', encoding='utf-8') as f:
            json.dump(cfg, f, indent=4, ensure_ascii=False)
    except Exception:
        pass

# ----------------------------------------------------------------------------
#  UTILITA'
# ----------------------------------------------------------------------------
def wait_enter():
    input('Premi Invio per continuare')

def read_default(prompt, default):
    r = input(f"{prompt} [{default}]: ")
    if not r or r.isspace():
        return str(default)
    return r.strip()

def read_int_range(prompt, current, min_val, max_val):
    while True:
        r = read_default(f"{prompt} ({min_val}-{max_val})", current)
        try:
            n = int(r)
            if min_val <= n <= max_val:
                return n
        except ValueError:
            pass
        print_color("  Valore non valido.", YELLOW)

def format_on_off(v):
    return 'SI' if v else 'NO'

def get_out_dir():
    if cfg['OutDir']:
        return cfg['OutDir'].rstrip('/\\')
    return str(Path(cfg['SourceDir']) / 'out')

def get_opus_dir():
    return str(Path(cfg['SourceDir']) / 'opus')

def is_under(path, directory):
    if not directory:
        return False
    d = str(directory).rstrip('/\\') + os.sep
    return str(path).startswith(d)


def format_table(rows, columns):
    if not rows:
        return ""
    col_widths = {c: len(c) for c in columns}
    for r in rows:
        for c in columns:
            val = str(r.get(c, ''))
            if len(val) > col_widths[c]:
                col_widths[c] = len(val)
    
    header = "  ".join(c.ljust(col_widths[c]) for c in columns)
    lines = [header, "-" * len(header)]
    for r in rows:
        line = "  ".join(str(r.get(c, '')).ljust(col_widths[c]) for c in columns)
        lines.append(line)
    return "\n".join(lines)

# ----------------------------------------------------------------------------
#  CONTROLLO STRUMENTI
# ----------------------------------------------------------------------------
has_x265 = False
has_vmaf = False
qsv_works = False
has_opus = False

has_ffmpeg = False
magick_exe = None
magick_ssim = False
exiftool_exe = None

def test_tools():
    global has_ffmpeg, has_x265, has_vmaf, qsv_works, has_opus, magick_exe, magick_ssim, exiftool_exe
    
    has_ffmpeg = bool(shutil.which('ffmpeg') and shutil.which('ffprobe'))
    magick_exe = shutil.which('magick')
    exiftool_exe = shutil.which('exiftool')

    if not has_ffmpeg and not magick_exe:
        print_color("ERRORE: ne' ffmpeg/ffprobe ne' ImageMagick (magick) trovati nel PATH.", RED)
        return False

    if has_ffmpeg:
        try:
            enc_res = subprocess.run(['ffmpeg', '-hide_banner', '-encoders'], capture_output=True, text=True)
            enc = enc_res.stdout + enc_res.stderr
            flt_res = subprocess.run(['ffmpeg', '-hide_banner', '-filters'], capture_output=True, text=True)
            flt = flt_res.stdout + flt_res.stderr
            has_x265 = 'libx265' in enc
            has_vmaf = 'libvmaf' in flt
            has_opus = 'libopus' in enc
            
            if 'hevc_qsv' in enc:
                qsv_cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=1280x720:d=0.2']
                if os.path.exists('/dev/dri/renderD128'):
                    qsv_cmd.extend(['-qsv_device', '/dev/dri/renderD128'])
                qsv_cmd.extend(['-vf', 'format=p010le', '-c:v', 'hevc_qsv', '-profile:v', 'main10', '-f', 'null', '-'])
                res = subprocess.run(qsv_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                qsv_works = (res.returncode == 0)
        except Exception:
            pass

    if magick_exe:
        try:
            res = subprocess.run([magick_exe, '-list', 'metric'], capture_output=True, text=True)
            magick_ssim = 'SSIM' in res.stdout or 'SSIM' in res.stderr
        except Exception:
            pass

    return True

def resolve_encoder():
    enc = cfg['Encoder']
    if enc == 'qsv':
        return 'qsv' if qsv_works else None
    if enc == 'x265':
        return 'x265' if has_x265 else None
    
    if qsv_works: return 'qsv'
    if has_x265: return 'x265'
    return None

# ----------------------------------------------------------------------------
#  ANALISI FILE
# ----------------------------------------------------------------------------
def get_video_info(path):
    cmd = ['ffprobe', '-v', 'error', '-select_streams', 'v:0', 
           '-show_entries', 'stream=codec_name,pix_fmt,width,height,avg_frame_rate,color_range,color_space,color_transfer,color_primaries:format=duration',
           '-of', 'json', path]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True)
        o = json.loads(res.stdout)
    except Exception:
        return None

    if not o or 'streams' not in o or len(o['streams']) == 0:
        return None

    s = o['streams'][0]
    fps = 0.0
    afr = s.get('avg_frame_rate', '')
    if '/' in afr:
        num, den = afr.split('/')
        if den != '0':
            fps = float(num) / float(den)
            
    dur = 0.0
    try:
        dur = float(o.get('format', {}).get('duration', 0))
    except (ValueError, TypeError):
        pass

    acodec = None
    ach = 0
    cmd_audio = ['ffprobe', '-v', 'error', '-select_streams', 'a:0', '-show_entries', 'stream=codec_name,channels', '-of', 'json', path]
    try:
        res_a = subprocess.run(cmd_audio, capture_output=True, text=True)
        ao = json.loads(res_a.stdout)
        if ao and 'streams' in ao and len(ao['streams']) > 0:
            ac_stream = ao['streams'][0]
            acodec = ac_stream.get('codec_name')
            ach = int(ac_stream.get('channels', 0))
    except Exception:
        pass

    return {
        'Codec': s.get('codec_name'),
        'PixFmt': s.get('pix_fmt'),
        'Width': s.get('width'),
        'Height': s.get('height'),
        'Fps': fps,
        'Duration': dur,
        'ACodec': acodec,
        'AChannels': ach,
        'Range': s.get('color_range'),
        'Space': s.get('color_space'),
        'Trc': s.get('color_transfer'),
        'Prim': s.get('color_primaries')
    }

def get_color_args(info):
    a = []
    if info.get('Prim') and info['Prim'] != 'unknown':
        a.extend(['-color_primaries', info['Prim']])
    if info.get('Trc') and info['Trc'] != 'unknown':
        trc = info['Trc']
        if cfg['NormalizeXvYCC'] and trc == 'iec61966-2-4':
            trc = 'bt709'
        a.extend(['-color_trc', trc])
    if info.get('Space') and info['Space'] != 'unknown':
        a.extend(['-colorspace', info['Space']])
    if info.get('Range') in ['tv', 'pc']:
        a.extend(['-color_range', info['Range']])
    return a

def test_audio_to_aac(info):
    if not info.get('ACodec'):
        return False
    ok_layout = (info['AChannels'] <= 2 or info['AChannels'] == 6)
    mode = cfg['AudioMode']
    if mode == 'copy':
        return False
    if mode == 'aac':
        return ok_layout
    return (info['ACodec'].startswith('pcm') and ok_layout)

def copy_sidecars(file_path, dst_dir):
    p = Path(file_path)
    base = p.stem
    exts = [e.lower() for e in cfg['SidecarExts']]
    try:
        for f in p.parent.iterdir():
            if f.is_file() and f.name.lower().startswith(base.lower()) and f.suffix.lower() in exts:
                dst_file = Path(dst_dir) / f.name
                if not dst_file.exists():
                    shutil.copy2(f, dst_file)
    except Exception:
        pass

def get_media_files(kind='video'):
    src = Path(cfg['SourceDir'])
    if not src.is_dir():
        return []
    
    if kind == 'photo':
        exts = [e.lower() for e in cfg['PhotoExtensions']]
    elif kind == 'audio':
        exts = [e.lower() for e in cfg['OpusExtensions']]
    else:
        exts = [e.lower() for e in cfg['Extensions']]

    exclude = [get_out_dir(), get_opus_dir()]
    
    files = []
    iterator = src.rglob('*') if cfg['Recurse'] else src.iterdir()
    for f in iterator:
        if f.is_file() and f.suffix.lower() in exts:
            if not any(is_under(f, d) for d in exclude):
                files.append(f)
    files.sort()
    return files

# ----------------------------------------------------------------------------
#  ENCODE
# ----------------------------------------------------------------------------
def invoke_encode(src, dst, info, enc, q):
    part = dst + ".part"
    fmt = 'mov' if dst.lower().endswith('.mov') else 'mp4'
    pix_fmt = str(info.get('PixFmt') or '')
    is10 = '10' in pix_fmt
    chroma_non420 = ('422' in pix_fmt or '444' in pix_fmt)

    base = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-stats', '-y']
    maps = ['-map', '0:V:0', '-map', '0:a?', '-dn', '-map_metadata', '0']
    
    audio = ['-c:a', 'copy']
    if test_audio_to_aac(info):
        audio = ['-c:a', 'aac', '-b:a', f"{cfg['AacBitrate']}k"]
        
    mux = ['-movflags', 'use_metadata_tags+faststart', '-tag:v', 'hvc1'] + get_color_args(info) + audio + ['-f', fmt]

    attempts = []
    if enc == 'qsv':
        prof = 'main10' if is10 else 'main'
        sw_fmt = 'p010le' if is10 else 'nv12'
        venc = ['-c:v', 'hevc_qsv', '-profile:v', prof, '-preset', 'veryslow', '-global_quality', str(q), '-look_ahead', '1']
        
        if not chroma_non420:
            a1_pre = ['-hwaccel', 'qsv', '-hwaccel_output_format', 'qsv']
            if os.path.exists('/dev/dri/renderD128'):
                a1_pre.extend(['-qsv_device', '/dev/dri/renderD128'])
            attempts.append({'pre': a1_pre, 'vf': []})
            
        a2_pre = []
        if os.path.exists('/dev/dri/renderD128'):
            a2_pre = ['-qsv_device', '/dev/dri/renderD128']
        attempts.append({'pre': a2_pre, 'vf': ['-vf', f"format={sw_fmt}"]})
    else:
        pix = 'yuv420p10le' if is10 else 'yuv420p'
        if chroma_non420:
            pass # already handled by pix above
        elif info.get('PixFmt'):
            pix = info['PixFmt']
        venc = ['-c:v', 'libx265', '-preset', cfg['X265Preset'], '-crf', str(q), '-pix_fmt', pix, '-x265-params', 'log-level=error']
        attempts.append({'pre': [], 'vf': []})

    try:
        for a in attempts:
            ff_args = base + a['pre'] + ['-i', src] + maps + a['vf'] + venc + mux + [part]
            res = subprocess.run(ff_args)
            if res.returncode == 0 and os.path.exists(part):
                os.replace(part, dst)
                return True
            if os.path.exists(part):
                os.remove(part)
        return False
    except KeyboardInterrupt:
        if os.path.exists(part):
            os.remove(part)
        raise
    finally:
        if os.path.exists(part):
            try:
                os.remove(part)
            except Exception:
                pass

# ----------------------------------------------------------------------------
#  VMAF
# ----------------------------------------------------------------------------
def measure_vmaf(dist, ref, sub):
    threads = os.cpu_count() or 4
    filter_str = f"[0:v:0][1:v:0]libvmaf=n_threads={threads}:n_subsample={sub}"
    
    modes = [True, False] if qsv_works else [False]
    for hw in modes:
        pre = []
        if hw:
            pre.extend(['-hwaccel', 'qsv'])
            if os.path.exists('/dev/dri/renderD128'):
                pre.extend(['-qsv_device', '/dev/dri/renderD128'])
            
        ff_args = ['ffmpeg', '-hide_banner', '-nostats'] + pre + ['-i', dist] + pre + ['-i', ref] + \
                  ['-lavfi', filter_str, '-an', '-sn', '-dn', '-f', 'null', '-']
        
        try:
            res = subprocess.run(ff_args, capture_output=True, text=True)
            m = re.search(r'VMAF score:\s*([\d\.,]+)', res.stdout + "\n" + res.stderr)
            if m:
                return float(m.group(1).replace(',', '.'))
        except Exception:
            pass
    return None

# ----------------------------------------------------------------------------
#  LAVORO SU UN SINGOLO FILE
# ----------------------------------------------------------------------------
def invoke_video_job(file_path, mode, enc, src_root, out_root):
    src_str = str(file_path)
    rel = src_str[len(src_root):].lstrip('/\\')
    dst = os.path.join(out_root, rel)
    
    f_stat = os.stat(src_str)
    f_size = f_stat.st_size
    row = {'File': rel, 'InMB': round(f_size / (1024*1024), 1), 'OutMB': None,
           'Saved': None, 'Quality': '-', 'VMAF': None, 'Audio': '-', 'Status': ''}

    info = get_video_info(src_str)
    if not info:
        row['Status'] = 'ERRORE: nessun video'
        return row

    is_qsv = (enc == 'qsv')
    q = int(cfg['QsvQuality']) if is_qsv else int(cfg['X265Crf'])
    q_min = 15 if is_qsv else 12
    q_step = 3 if is_qsv else 2
    exists = os.path.exists(dst)
    encoded_now = False

    if mode == 'verify':
        if not exists:
            row['Status'] = 'MANCA OUTPUT'
            return row
    elif exists and not cfg['Overwrite']:
        row['Status'] = 'ESISTENTE'
    else:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        print_color(f"   encode q={q} ...", GRAY)
        pix_fmt_str = str(info.get('PixFmt') or '')
        if '422' in pix_fmt_str or '444' in pix_fmt_str:
            print_color(f"   nota: sorgente {info.get('PixFmt')} -> convertita a 4:2:0 (compatibile con tutti i player)", YELLOW)
        
        if not invoke_encode(src_str, dst, info, enc, q):
            row['Status'] = 'ERRORE ffmpeg'
            return row
        
        encoded_now = True
        row['Quality'] = q
        row['Audio'] = f"AAC {cfg['AacBitrate']}k" if test_audio_to_aac(info) else 'copia'

    if mode in ['full', 'verify']:
        print_color('   verifica VMAF ...', GRAY)
        v = measure_vmaf(dst, src_str, cfg['VmafSubsample'])
        tries = 0
        while encoded_now and cfg['AutoRetry'] and v is not None and v < cfg['VmafThreshold'] and tries < cfg['MaxRetries']:
            new_q = q - q_step
            if new_q < q_min:
                break
            print_color(f"   VMAF {v:.2f} < {cfg['VmafThreshold']}: riprovo con q={new_q}", YELLOW)
            q = new_q
            if not invoke_encode(src_str, dst, info, enc, q):
                break
            row['Quality'] = q
            tries += 1
            v = measure_vmaf(dst, src_str, cfg['VmafSubsample'])
            
        row['VMAF'] = round(v, 2) if v is not None else None
        if v is None:
            row['Status'] = 'VMAF non letto'
        elif v < cfg['VmafThreshold']:
            row['Status'] = 'SOTTO SOGLIA'
        else:
            row['Status'] = 'OK'
    elif encoded_now:
        row['Status'] = 'COMPRESSO (non verificato)'

    if os.path.exists(dst):
        out_len = os.path.getsize(dst)
        row['OutMB'] = round(out_len / (1024*1024), 1)
        row['Saved'] = round((1 - out_len / f_size) * 100, 0)
        
        if encoded_now and out_len >= f_size:
            os.remove(dst)
            row['Status'] = 'SALTATO: output piu grande'
            row['OutMB'] = None
            row['Saved'] = None
        elif encoded_now and cfg['PreserveDates']:
            try:
                os.utime(dst, (f_stat.st_atime, f_stat.st_mtime))
            except Exception:
                pass
                
        if encoded_now and cfg['CopySidecars'] and os.path.exists(dst):
            copy_sidecars(src_str, os.path.dirname(dst))

    return row

# ----------------------------------------------------------------------------
#  FOTO
# ----------------------------------------------------------------------------
def get_photo_info(path):
    cmd = [magick_exe, 'identify', '-format', '%w|%h|%Q|%[jpeg:sampling-factor]', f"{path}[0]"]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True)
        lines = res.stdout.strip().split('\n')
        if not lines or not lines[0]:
            return None
        p = lines[0].split('|')
        if len(p) < 3:
            return None
        w = int(p[0])
        h = int(p[1])
        q = int(p[2])
        samp = '2x2'
        if len(p) >= 4:
            m = re.match(r'^(\d+x\d+)', p[3])
            if m:
                samp = m.group(1)
        return {'Width': w, 'Height': h, 'Q': q, 'Sampling': samp}
    except Exception:
        return None

def invoke_photo_encode(src, dst, info, q):
    part = dst + ".part"
    il = 'JPEG' if cfg['PhotoProgressive'] else 'None'
    im = [magick_exe, src, '-quality', str(q), '-sampling-factor', info['Sampling'], '-interlace', il,
          '-define', 'jpeg:optimize-coding=true', f"JPEG:{part}"]
    try:
        res = subprocess.run(im, capture_output=True, text=True)
        if res.returncode == 0 and os.path.exists(part):
            os.replace(part, dst)
            return True
        lines = (res.stdout + "\n" + res.stderr).split('\n')
        for i in range(min(3, len(lines))):
            if lines[i].strip():
                print_color(f"   magick: {lines[i]}", GRAY)
        return False
    except KeyboardInterrupt:
        if os.path.exists(part):
            os.remove(part)
        raise
    finally:
        if os.path.exists(part):
            try:
                os.remove(part)
            except Exception:
                pass

def measure_ssim(a, b):
    cmd = [magick_exe, 'compare', '-metric', 'SSIM', a, b, 'null:']
    try:
        res = subprocess.run(cmd, capture_output=True, text=True)
        out = res.stdout + "\n" + res.stderr
        num = r'[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?'
        for l in out.split('\n'):
            m1 = re.match(r"^\s*" + num + r"\s*\(\s*(" + num + r")\s*\)", l)
            if m1:
                d = float(m1.group(1))
                return max(0.0, 1.0 - 2.0 * d)
            m2 = re.match(r"^\s*(" + num + r")\s*$", l)
            if m2:
                return float(m2.group(1))
    except Exception:
        pass
    return None

def get_exiftool_keys(path):
    s = set()
    cmd = [exiftool_exe, '-a', '-u', '-G1', '-s', path]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True)
        for l in res.stdout.split('\n'):
            m = re.match(r'^\[([^\]]+)\]\s+(\S+)\s*:', l)
            if m:
                g, t = m.group(1), m.group(2)
                if not re.match(r'^(System|File|ExifTool|Composite|JFIF|MPF.*)$', g):
                    s.add(f"{g}:{t}")
    except Exception:
        pass
    return s

def get_exif_lines(path):
    cmd = [magick_exe, 'identify', '-format', '%[EXIF:*]', f"{path}[0]"]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True)
        return [l for l in res.stdout.split('\n') if '=' in l]
    except Exception:
        return []

def test_photo_metadata(src, dst):
    miss = 0
    total = 0
    if exiftool_exe:
        a = get_exiftool_keys(src)
        b = get_exiftool_keys(dst)
        total = len(a)
        for k in a:
            if k not in b:
                miss += 1
    else:
        a = get_exif_lines(src)
        b = get_exif_lines(dst)
        total = len(a)
        bs = set(b)
        for l in a:
            if l not in bs:
                miss += 1
    
    txt = 'n/d' if total == 0 else (f"OK ({total})" if miss == 0 else f"MANCANO {miss}/{total}")
    return {'Missing': miss, 'Total': total, 'Text': txt}

def invoke_photo_job(file_path, mode, src_root, out_root):
    src_str = str(file_path)
    rel = src_str[len(src_root):].lstrip('/\\')
    dst = os.path.join(out_root, rel)
    
    f_stat = os.stat(src_str)
    f_size = f_stat.st_size
    row = {'File': rel, 'InMB': round(f_size / (1024*1024), 1), 'OutMB': None,
           'Saved': None, 'Quality': '-', 'SSIM': None, 'Meta': '-', 'Status': ''}

    info = get_photo_info(src_str)
    if not info:
        row['Status'] = 'ERRORE: immagine non leggibile'
        return row

    q = int(cfg['PhotoQuality'])
    exists = os.path.exists(dst)
    encoded_now = False

    if mode == 'verify':
        if not exists:
            row['Status'] = 'MANCA OUTPUT'
            return row
    elif exists and not cfg['Overwrite']:
        row['Status'] = 'ESISTENTE'
    else:
        if info['Q'] > 0 and info['Q'] <= q:
            row['Status'] = f"GIA COMPRESSA (Q~{info['Q']})"
            row['Quality'] = info['Q']
            return row
            
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        print_color(f"   encode Q={q}  (sorgente Q~{info['Q']}, croma {info['Sampling']})", GRAY)
        
        if not invoke_photo_encode(src_str, dst, info, q):
            row['Status'] = 'ERRORE magick'
            return row
            
        encoded_now = True
        row['Quality'] = q

    if mode in ['full', 'verify'] and cfg['PhotoVerify']:
        print_color('   verifica SSIM + metadati ...', GRAY)
        v = measure_ssim(dst, src_str)
        tries = 0
        while encoded_now and cfg['AutoRetry'] and v is not None and v < cfg['PhotoSsim'] and tries < cfg['MaxRetries']:
            new_q = q + 3
            if new_q > 98:
                break
            print_color(f"   SSIM {v:.4f} < {cfg['PhotoSsim']}: riprovo con Q={new_q}", YELLOW)
            q = new_q
            if not invoke_photo_encode(src_str, dst, info, q):
                break
            row['Quality'] = q
            tries += 1
            v = measure_ssim(dst, src_str)
            
        row['SSIM'] = round(v, 4) if v is not None else None
        meta = test_photo_metadata(src_str, dst)
        row['Meta'] = meta['Text']
        
        if v is None:
            row['Status'] = 'SSIM non letto'
        elif v < cfg['PhotoSsim']:
            row['Status'] = 'SOTTO SOGLIA'
        elif meta['Missing'] > 0:
            row['Status'] = 'CONTROLLA METADATI'
        else:
            row['Status'] = 'OK'
    elif encoded_now:
        row['Status'] = 'COMPRESSO (non verificato)'
    elif mode == 'verify':
        row['Status'] = 'VERIFICA DISATTIVATA'

    if os.path.exists(dst):
        out_len = os.path.getsize(dst)
        row['OutMB'] = round(out_len / (1024*1024), 1)
        row['Saved'] = round((1 - out_len / f_size) * 100, 0)
        
        if encoded_now and out_len >= f_size:
            os.remove(dst)
            row['Status'] = 'SALTATO: output piu grande'
            row['OutMB'] = None
            row['Saved'] = None
        elif encoded_now and cfg['PreserveDates']:
            try:
                os.utime(dst, (f_stat.st_atime, f_stat.st_mtime))
            except Exception:
                pass
                
        if encoded_now and cfg['CopySidecars'] and os.path.exists(dst):
            copy_sidecars(src_str, os.path.dirname(dst))

    return row

# ----------------------------------------------------------------------------
#  AUDIO (WAV/FLAC -> Opus) con trasferimento fedele dei tag e copertina
# ----------------------------------------------------------------------------
RIFF_INFO_MAP = {
    'IART': 'ARTIST', 'INAM': 'TITLE', 'IPRD': 'ALBUM', 'ICRD': 'DATE', 'IGNR': 'GENRE',
    'ITRK': 'TRACKNUMBER', 'ICOP': 'COPYRIGHT', 'ICMT': 'COMMENT', 'ISFT': 'ENCODER',
    'IENG': 'ENGINEER', 'IWRI': 'WRITER', 'IMUS': 'COMPOSER', 'IALK': 'ALBUMARTIST',
    'ILNG': 'LANGUAGE', 'IBPM': 'BPM', 'IKEY': 'KEY',
}
PICTURE_KEYS = {'METADATA_BLOCK_PICTURE', 'COVERART', 'COVERARTMIME'}

def get_flac_comments(path):
    comments = []
    try:
        data = open(path, 'rb').read()
    except Exception:
        return comments
    if data[:4] != b'fLaC':
        return comments
    pos = 4
    last = False
    while not last and pos + 4 <= len(data):
        h = data[pos]
        last = bool(h & 0x80)
        btype = h & 0x7f
        length = int.from_bytes(data[pos + 1:pos + 4], 'big')
        body_start = pos + 4
        if btype == 4:
            o = body_start
            if o + 4 <= len(data):
                vlen = int.from_bytes(data[o:o + 4], 'little')
                o += 4 + vlen
                if o + 4 <= len(data):
                    n = int.from_bytes(data[o:o + 4], 'little')
                    o += 4
                    for _ in range(n):
                        if o + 4 > len(data):
                            break
                        clen = int.from_bytes(data[o:o + 4], 'little')
                        o += 4
                        if o + clen > len(data):
                            break
                        comments.append(data[o:o + clen].decode('utf-8', 'replace'))
                        o += clen
        pos = body_start + length
    return comments

def get_riff_info_comments(path):
    comments = []
    try:
        data = open(path, 'rb').read()
    except Exception:
        return comments
    if data[:4] != b'RIFF' or data[8:12] != b'WAVE':
        return comments
    pos = 12
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = int.from_bytes(data[pos + 4:pos + 8], 'little')
        pos += 8
        if cid == b'LIST' and data[pos:pos + 4] == b'INFO':
            o = pos + 4
            lim = min(pos + size, len(data))
            while o + 8 <= lim:
                sid = data[o:o + 4]
                ssize = int.from_bytes(data[o + 4:o + 8], 'little')
                o += 8
                if o + ssize > len(data):
                    break
                val = data[o:o + ssize].decode('utf-8', 'replace').rstrip('\x00')
                key = RIFF_INFO_MAP.get(sid.decode('ascii', 'replace'), sid.decode('ascii', 'replace').strip())
                if val:
                    comments.append(f"{key}={val}")
                o += ssize + (ssize & 1)
        pos += size + (size & 1)
    return comments

def get_ffprobe_comments(path):
    comments = []
    try:
        res = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format_tags', '-of', 'json', path],
                             capture_output=True, text=True)
        o = json.loads(res.stdout)
        tags = (o.get('format', {}) or {}).get('tags', {}) or {}
        for k, v in tags.items():
            comments.append(f"{k}={v}")
    except Exception:
        pass
    return comments

def get_source_comments(file_path):
    p = Path(file_path)
    ext = p.suffix.lower()
    comments = []
    if ext == '.flac':
        comments = get_flac_comments(str(p))
    elif ext == '.wav':
        comments = get_riff_info_comments(str(p))
    if not comments:
        comments = get_ffprobe_comments(str(p))
    return comments

def get_opus_comments(comments):
    out = []
    for c in comments:
        if '=' not in c:
            continue
        key, val = c.split('=', 1)
        if key.upper() in PICTURE_KEYS:
            continue
        if key.upper() == 'ARTIST' and ';' in val:
            for a in val.split(';'):
                a = a.strip()
                if a:
                    out.append(f"{key}={a}")
        else:
            out.append(c)
    return out

def new_opus_tags_packet(vendor, comments):
    out = bytearray(b'OpusTags')
    out += len(vendor).to_bytes(4, 'little') + vendor
    out += len(comments).to_bytes(4, 'little')
    for c in comments:
        cb = c.encode('utf-8')
        out += len(cb).to_bytes(4, 'little') + cb
    return bytes(out)

def ogg_crc32(data, start=0, count=None):
    if count is None:
        count = len(data) - start
    crc = 0
    for i in range(start, start + count):
        crc ^= (data[i] << 24)
        for _ in range(8):
            if crc & 0x80000000:
                crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            else:
                crc = (crc << 1) & 0xFFFFFFFF
    return crc & 0xFFFFFFFF

def read_ogg_pages(data):
    pages = []
    pos = 0
    while pos + 27 <= len(data):
        if data[pos:pos + 4] != b'OggS':
            break
        nseg = data[pos + 26]
        if pos + 27 + nseg > len(data):
            break
        seg = list(data[pos + 27:pos + 27 + nseg])
        body_len = sum(seg)
        page_len = 27 + nseg + body_len
        if pos + page_len > len(data):
            break
        pages.append({
            'offset': pos, 'page_len': page_len, 'header_type': data[pos + 5],
            'serial': int.from_bytes(data[pos + 14:pos + 18], 'little'),
            'seq': int.from_bytes(data[pos + 18:pos + 22], 'little'),
            'seg': seg, 'body_offset': pos + 27 + nseg, 'body_len': body_len,
        })
        pos += page_len
    return pages

def get_opus_tags_info(data, pages, idx):
    buf = bytearray()
    p = idx
    done = False
    while not done and p < len(pages):
        pg = pages[p]
        bo = pg['body_offset']
        for v in pg['seg']:
            buf += data[bo:bo + v]
            bo += v
            if v < 255:
                done = True
                break
        p += 1
    vlen = int.from_bytes(buf[8:12], 'little') if len(buf) >= 12 else 0
    if vlen + 12 > len(buf):
        vlen = 0
    return {'vendor': bytes(buf[12:12 + vlen]), 'page_count': p - idx}

def new_ogg_page_bytes(header_type, serial, seq, seg, body):
    page = bytearray(27 + len(seg) + len(body))
    page[0:4] = b'OggS'
    page[4] = 0
    page[5] = header_type
    page[14:18] = serial.to_bytes(4, 'little')
    page[18:22] = seq.to_bytes(4, 'little')
    page[26] = len(seg)
    page[27:27 + len(seg)] = bytes(seg)
    page[27 + len(seg):27 + len(seg) + len(body)] = body
    page[22:26] = ogg_crc32(page, 0, len(page)).to_bytes(4, 'little')
    return bytes(page)

def set_opus_tags(path, comments):
    data = open(path, 'rb').read()
    pages = read_ogg_pages(data)
    idx = -1
    for i, pg in enumerate(pages):
        if pg['body_len'] >= 8 and data[pg['body_offset']:pg['body_offset'] + 8] == b'OpusTags':
            idx = i
            break
    if idx < 0:
        return False

    info = get_opus_tags_info(data, pages, idx)
    packet = new_opus_tags_packet(info['vendor'], comments)

    lace = []
    rem = len(packet)
    while rem >= 255:
        lace.append(255)
        rem -= 255
    lace.append(rem)

    new_pages = []
    seq = pages[idx]['seq']
    off = 0
    i2 = 0
    first = True
    while i2 < len(lace):
        cnt = min(255, len(lace) - i2)
        seg = lace[i2:i2 + cnt]
        body_len = sum(seg)
        body = packet[off:off + body_len]
        ht = 0 if first else 1
        new_pages.append(new_ogg_page_bytes(ht, pages[idx]['serial'], seq, seg, body))
        off += body_len
        i2 += cnt
        seq += 1
        first = False

    delta = len(new_pages) - info['page_count']
    out = bytearray()
    i = 0
    while i < len(pages):
        if i == idx:
            for np in new_pages:
                out += np
            i += info['page_count']
            continue
        pg = pages[i]
        if i > idx and delta != 0:
            page = bytearray(data[pg['offset']:pg['offset'] + pg['page_len']])
            page[18:22] = (pg['seq'] + delta).to_bytes(4, 'little')
            page[22:26] = b'\x00\x00\x00\x00'
            page[22:26] = ogg_crc32(page, 0, len(page)).to_bytes(4, 'little')
            out += page
        else:
            out += data[pg['offset']:pg['offset'] + pg['page_len']]
        i += 1

    with open(path, 'wb') as f:
        f.write(out)
    return True

def extract_audio_cover(src, out_dir):
    try:
        res = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v',
                              '-show_entries', 'stream=codec_name', '-of', 'json', src],
                             capture_output=True, text=True)
        o = json.loads(res.stdout)
    except Exception:
        return None
    if not o or not o.get('streams'):
        return None
    codec = str(o['streams'][0].get('codec_name', ''))
    ext = {'mjpeg': '.jpg', 'jpeg': '.jpg', 'png': '.png', 'webp': '.webp'}.get(codec, '.jpg')
    dst = os.path.join(out_dir, 'cover' + ext)
    try:
        res = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', src,
                              '-map', '0:v:0', '-c', 'copy', dst], capture_output=True, text=True)
    except Exception:
        return None
    if res.returncode == 0 and os.path.exists(dst):
        return dst
    return None

def test_cover_present(directory):
    for n in cfg['OpusCoverNames']:
        for e in cfg['OpusCoverExts']:
            if os.path.exists(os.path.join(directory, n + e)):
                return True
    return os.path.exists(os.path.join(directory, 'cover.jpg')) or os.path.exists(os.path.join(directory, 'cover.png'))

def set_audio_cover(file_path, dst):
    out_dir = os.path.dirname(dst)
    if test_cover_present(out_dir):
        return 'presente'
    src_dir = os.path.dirname(str(file_path))
    for n in cfg['OpusCoverNames']:
        for e in cfg['OpusCoverExts']:
            p = os.path.join(src_dir, n + e)
            if os.path.isfile(p):
                shutil.copy2(p, os.path.join(out_dir, os.path.basename(p)))
                return 'copiata'
    if extract_audio_cover(str(file_path), out_dir):
        return 'estratta'
    return '-'

def invoke_audio_job(file_path, src_root, out_root):
    src_str = str(file_path)
    rel = src_str[len(src_root):].lstrip('/\\')
    dst = os.path.join(out_root, os.path.splitext(rel)[0] + '.opus')

    f_stat = os.stat(src_str)
    f_size = f_stat.st_size
    row = {'File': rel, 'InMB': round(f_size / (1024 * 1024), 1), 'OutMB': None,
           'Saved': None, 'Bitrate': cfg['OpusBitrate'], 'Tags': '-', 'Cover': '-', 'Status': ''}

    if os.path.exists(dst) and not cfg['Overwrite']:
        row['Status'] = 'ESISTENTE'
        return row

    os.makedirs(os.path.dirname(dst), exist_ok=True)
    comments = get_opus_comments(get_source_comments(src_str))

    part = dst + '.part'
    ff_args = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-stats', '-y', '-i', src_str,
               '-map', '0:a:0', '-vn', '-map_metadata', '-1',
               '-c:a', 'libopus', '-b:a', f"{cfg['OpusBitrate']}k", '-vbr', 'on',
               '-application', 'audio', '-f', 'opus', part]
    try:
        print_color(f"   encode Opus {cfg['OpusBitrate']}k ...", GRAY)
        res = subprocess.run(ff_args)
        if res.returncode != 0 or not os.path.exists(part):
            row['Status'] = 'ERRORE ffmpeg'
            return row
        try:
            if set_opus_tags(part, comments):
                row['Tags'] = len(comments)
            else:
                row['Tags'] = 'non scritti'
        except Exception:
            row['Tags'] = 'non scritti'
        os.replace(part, dst)
    except KeyboardInterrupt:
        if os.path.exists(part):
            os.remove(part)
        raise
    finally:
        if os.path.exists(part):
            try:
                os.remove(part)
            except Exception:
                pass

    if cfg['OpusCover']:
        row['Cover'] = set_audio_cover(file_path, dst)

    if os.path.exists(dst):
        out_len = os.path.getsize(dst)
        row['OutMB'] = round(out_len / (1024 * 1024), 1)
        row['Saved'] = round((1 - out_len / f_size) * 100, 0)
        if out_len >= f_size:
            os.remove(dst)
            row['Status'] = 'SALTATO: output piu grande'
            row['OutMB'] = None
            row['Saved'] = None
        else:
            row['Status'] = 'OK'
            if cfg['PreserveDates']:
                try:
                    os.utime(dst, (f_stat.st_atime, f_stat.st_mtime))
                except Exception:
                    pass
    return row

# ----------------------------------------------------------------------------
#  BATCH & TUI
# ----------------------------------------------------------------------------
def clear_screen():
    os.system('clear' if os.name == 'posix' else 'cls')

def test_source():
    if not cfg['SourceDir'] or not os.path.isdir(cfg['SourceDir']):
        print_color("Nessuna cartella valida selezionata: usa prima [1].", YELLOW)
        wait_enter()
        return False
    return True

def start_batch(mode, kind='video'):
    if not test_source(): return
    is_photo = (kind == 'photo')
    is_audio = (kind == 'audio')
    enc = None

    if is_photo:
        if not magick_exe:
            print_color("ImageMagick non trovato: installalo (comando 'magick' nel PATH) e riavvia il terminale.", RED)
            wait_enter()
            return
        if mode == 'verify' and not magick_ssim:
            print_color("Questa build di ImageMagick non ha la metrica SSIM: verifica non disponibile.", RED)
            wait_enter()
            return
    elif is_audio:
        if not has_ffmpeg:
            print_color("ffmpeg/ffprobe non trovati nel PATH: conversione audio non disponibile.", RED)
            wait_enter()
            return
        if not has_opus:
            print_color("Questa build di ffmpeg non include libopus: conversione audio non disponibile.", RED)
            wait_enter()
            return
    else:
        if not has_ffmpeg:
            print_color("ffmpeg/ffprobe non trovati nel PATH: funzioni video non disponibili.", RED)
            wait_enter()
            return
        if mode != 'verify':
            enc = resolve_encoder()
            if not enc:
                print_color("Nessun encoder disponibile con la scelta attuale (vedi [6] Impostazioni).", RED)
                wait_enter()
                return
        if mode != 'compress' and not has_vmaf:
            print_color("Il tuo ffmpeg non include libvmaf: verifica non disponibile.", RED)
            wait_enter()
            return

    files = get_media_files(kind)
    if not files:
        label = 'JPEG' if is_photo else ('audio (WAV/FLAC)' if is_audio else 'video')
        print_color(f"Nessun file {label} trovato.", YELLOW)
        wait_enter()
        return

    src_root = cfg['SourceDir'].rstrip('/\\')
    out_root = get_opus_dir() if is_audio else get_out_dir()
    total_bytes = sum(f.stat().st_size for f in files)
    total_mb = round(total_bytes / (1024*1024), 1)

    print()
    print(f"File da elaborare : {len(files)}  ({total_mb} MB)")
    if is_photo:
        mode_txt = 'solo verifica foto' if mode == 'verify' else ('compressione foto' + (' + verifica + retry' if cfg['PhotoVerify'] else ' (senza verifica)'))
        print(f"Modalita'         : {mode_txt}")
        print(f"JPEG              : qualita' {cfg['PhotoQuality']}, {'progressivo' if cfg['PhotoProgressive'] else 'baseline'}, croma e metadati dell'originale")
        if cfg['PhotoVerify']:
            print(f"Soglia SSIM       : {cfg['PhotoSsim']:.3f}")
    elif is_audio:
        print("Modalita'         : conversione audio -> Opus")
        print(f"Opus              : {cfg['OpusBitrate']} kb/s VBR")
        print("Metadati          : copiati pari-pari (artisti multipli come tag ARTIST separati)")
        print(f"Copertina         : {'copiata/estratta nella cartella opus' if cfg['OpusCover'] else 'disattivata'}")
    else:
        modes_map = {'compress': 'solo compressione', 'full': 'compressione + verifica + retry', 'verify': 'solo verifica'}
        print(f"Modalita'         : {modes_map[mode]}")
        if enc:
            q_txt = f"QSV global_quality={cfg['QsvQuality']}" if enc == 'qsv' else f"x265 crf={cfg['X265Crf']} preset={cfg['X265Preset']}"
            print(f"Encoder           : {q_txt}")
        if mode != 'verify':
            if cfg['AudioMode'] == 'copy':
                a_txt = 'copia originale'
            elif cfg['AudioMode'] == 'aac':
                a_txt = f"AAC {cfg['AacBitrate']}k"
            else:
                a_txt = f"auto (PCM -> AAC {cfg['AacBitrate']}k, altri formati in copia)"
            print(f"Audio             : {a_txt}")
        if mode != 'compress':
            print(f"Soglia VMAF       : {cfg['VmafThreshold']}")
            
    print(f"Output            : {out_root}")
    if not read_default('Procedo? (s/n)', 's').lower().startswith('s'):
        return

    os.makedirs(out_root, exist_ok=True)
    results = []
    start_t = time.time()
    
    for i, f in enumerate(files, 1):
        print()
        print_color(f"[{i}/{len(files)}] {f.name}", CYAN)
        if is_photo:
            r = invoke_photo_job(f, mode, src_root, out_root)
        elif is_audio:
            r = invoke_audio_job(f, src_root, out_root)
        else:
            r = invoke_video_job(f, mode, enc, src_root, out_root)
        results.append(r)
        
        st = r['Status']
        if 'OK' in st or 'COMPRESS' in st:
            color = GREEN
        elif 'ESISTENTE' in st or 'GIA' in st:
            color = GRAY
        else:
            color = YELLOW
            
        if is_photo:
            m_txt = f"SSIM={r['SSIM']}  meta={r['Meta']}"
        elif is_audio:
            m_txt = f"tags={r['Tags']}  cover={r['Cover']}"
        else:
            m_txt = f"VMAF={r['VMAF']}"
        print_color(f"   -> {r['Status']}  {r['InMB']} -> {r['OutMB']} MB  (-{r['Saved']}%)  {m_txt}", color)
        
    elapsed = time.time() - start_t

    print()
    print_color('================ RIEPILOGO ================', CYAN)
    if is_photo:
        cols = ['File', 'InMB', 'OutMB', 'Saved', 'Quality', 'SSIM', 'Meta', 'Status']
    elif is_audio:
        cols = ['File', 'InMB', 'OutMB', 'Saved', 'Bitrate', 'Tags', 'Cover', 'Status']
    else:
        cols = ['File', 'InMB', 'OutMB', 'Saved', 'Quality', 'VMAF', 'Audio', 'Status']
    print(format_table(results, cols))

    done = [r for r in results if r['OutMB'] is not None]
    if done:
        in_tot = sum(r['InMB'] for r in done)
        out_tot = sum(r['OutMB'] for r in done)
        saved_pct = ((1 - out_tot / in_tot) * 100) if in_tot else 0
        h = int(elapsed // 3600)
        m = int((elapsed % 3600) // 60)
        s = int(elapsed % 60)
        time_str = f"{h:02d}:{m:02d}:{s:02d}"
        print_color(f"\nTotale: {in_tot:.1f} MB -> {out_tot:.1f} MB  (risparmio {saved_pct:.0f}%)  in {time_str}", GREEN)
    bad = [r for r in results if re.search(r'SOTTO|ERRORE|non letto|MANCA|METADATI', r['Status'])]
    if bad:
        print_color(f"\nDA CONTROLLARE ({len(bad)}):", YELLOW)
        for b in bad:
            print_color(f"  - {b['File']}  [{b['Status']}]", YELLOW)
        if is_photo:
            print_color("Per i 'SOTTO SOGLIA': alza la qualita' foto in [6] (es. 93) o tieni l'originale.", YELLOW)
        elif is_audio:
            print_color("Per gli errori: controlla il file sorgente con [2] o l'installazione di ffmpeg/libopus.", YELLOW)
        else:
            print_color("Per i 'SOTTO SOGLIA': abbassa la qualita' numerica (es. 21) in [6] o tieni l'originale.", YELLOW)

    log_file = os.path.join(out_root, f"log_{kind}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv")
    try:
        with open(log_file, 'w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=cols)
            writer.writeheader()
            writer.writerows(results)
        print_color(f"Log salvato: {log_file}", GRAY)
    except Exception:
        pass
    wait_enter()

def show_scan():
    if not test_source(): return
    vids = get_media_files('video') if has_ffmpeg else []
    pics = get_media_files('photo') if magick_exe else []
    
    if not vids and not pics:
        print_color("Nessun file video o JPEG trovato.", YELLOW)
        wait_enter()
        return

    if vids:
        print_color("\nVIDEO", CYAN)
        rows = []
        for f in vids:
            i = get_video_info(str(f))
            if not i: continue
            mb = round(f.stat().st_size / (1024*1024), 1)
            mbps = round((f.stat().st_size * 8 / i['Duration'] / 1e6), 1) if i['Duration'] > 0 else None
            rows.append({
                'File': f.name, 'MB': mb,
                'Codec': i['Codec'], 'Res': f"{i['Width']}x{i['Height']}", 'FPS': round(i['Fps'], 2),
                'PixFmt': i['PixFmt'], 'Trc': i['Trc'], 'Audio': i['ACodec'], 'Sec': round(i['Duration'], 1),
                'Mbps': mbps
            })
        print(format_table(rows, ['File', 'MB', 'Codec', 'Res', 'FPS', 'PixFmt', 'Trc', 'Audio', 'Sec', 'Mbps']))
        tot_mb = sum(f.stat().st_size for f in vids) / (1024*1024)
        print(f"Totale video: {len(vids)} file, {tot_mb:.1f} MB")
        print_color("Nota: 'Trc' diverso da bt709 (es. arib-std-b67 = HLG) indica profilo colore non Normal.", GRAY)

    if pics:
        print_color("\nFOTO (JPEG)", CYAN)
        rows = []
        for f in pics:
            i = get_photo_info(str(f))
            mb = round(f.stat().st_size / (1024*1024), 1)
            rows.append({
                'File': f.name, 'MB': mb,
                'Res': f"{i['Width']}x{i['Height']}" if i else '?',
                'Q stimata': i['Q'] if i else '?',
                'Croma': i['Sampling'] if i else '?'
            })
        print(format_table(rows, ['File', 'MB', 'Res', 'Q stimata', 'Croma']))
        tot_mb = sum(f.stat().st_size for f in pics) / (1024*1024)
        print(f"Totale foto: {len(pics)} file, {tot_mb:.1f} MB")
        print_color("Nota: le foto con 'Q stimata' <= qualita' foto impostata vengono saltate (gia' compresse).", GRAY)
        
    wait_enter()

def show_photo_test():
    if not magick_exe:
        print_color("ImageMagick non trovato.", RED)
        wait_enter()
        return
        
    default = ''
    if cfg['SourceDir'] and os.path.isdir(cfg['SourceDir']):
        pics = get_media_files('photo')
        if pics:
            default = str(pics[0])
            
    r = read_default('Foto di prova (trascina il file qui)', default)
    r = r.strip().strip('"\'')
    if not r or not os.path.isfile(r):
        print_color("File non valido.", YELLOW)
        wait_enter()
        return
        
    info = get_photo_info(r)
    if not info:
        print_color("Immagine non leggibile.", RED)
        wait_enter()
        return
        
    f_size = os.path.getsize(r)
    f_name = os.path.basename(r)
    print(f"\n{f_name}: {f_size/(1024*1024):.2f} MB, {info['Width']}x{info['Height']}, qualita' stimata ~{info['Q']}, croma {info['Sampling']}")

    t = read_default('Qualita da provare (separate da virgola)', '80,85,88,90,92,95')
    q_list = []
    for s in t.split(','):
        try:
            n = int(s.strip())
            if 40 <= n <= 100:
                q_list.append(n)
        except ValueError:
            pass
            
    if not q_list:
        return
    tmp = os.path.join(tempfile.gettempdir(), 'squeeze-test')
    os.makedirs(tmp, exist_ok=True)
    
    rows = []
    for q in q_list:
        o = os.path.join(tmp, f"q{q}.jpg")
        print_color(f"  provo Q={q} ...", GRAY)
        if not invoke_photo_encode(r, o, info, q):
            continue
            
        out_len = os.path.getsize(o)
        ssim = measure_ssim(o, r)
        meta = test_photo_metadata(r, o)
        
        rows.append({
            'Quality': q,
            'MB': round(out_len / (1024*1024), 2),
            'Risparmio': f"{round((1 - out_len / f_size) * 100, 0)}%",
            'SSIM': round(ssim, 4) if ssim is not None else None,
            'Metadati': meta['Text']
        })
        
    print()
    print(format_table(rows, ['Quality', 'MB', 'Risparmio', 'SSIM', 'Metadati']))
    shutil.rmtree(tmp, ignore_errors=True)
    print_color("\nScegli la qualita' piu' bassa con SSIM sopra la tua soglia (e Metadati OK), poi impostala in [6] -> G/H.", GRAY)
    wait_enter()

def select_folder():
    print()
    print("Trascina qui la cartella (o incolla il percorso). Invio vuoto = annulla.")
    r = input("Cartella: ")
    if not r or r.isspace(): return
    r = r.strip().strip('"\'').rstrip('/\\')
    if os.path.isdir(r):
        cfg['SourceDir'] = os.path.abspath(r).rstrip('/\\')
        save_config()
    else:
        print_color("Percorso non valido.", YELLOW)
        wait_enter()

def show_settings_menu():
    while True:
        clear_screen()
        print_color('=============== IMPOSTAZIONI ===============', CYAN)
        print(f" [1] Encoder              : {cfg['Encoder']}   (auto = QSV se funziona, altrimenti x265)")
        print(f" [2] Qualita' QSV         : {cfg['QsvQuality']}   (24 = archivio, 21 = piu' sicuro, 27 = compatto)")
        print(f" [3] Qualita' x265 (CRF)  : {cfg['X265Crf']}   (20 = archivio, 18 = piu' sicuro, 22 = compatto)")
        print(f" [4] Preset x265          : {cfg['X265Preset']}")
        print(f" [5] Soglia VMAF          : {cfg['VmafThreshold']}")
        print(f" [6] Precisione VMAF      : 1 frame ogni {cfg['VmafSubsample']}  (1 = tutti, piu' lento)")
        print(f" [7] Retry automatico     : {format_on_off(cfg['AutoRetry'])}   (max {cfg['MaxRetries']} tentativi, scende di qualita' a ogni giro)")
        print(f" [8] Includi sottocartelle: {format_on_off(cfg['Recurse'])}")
        print(f" [9] Sovrascrivi output   : {format_on_off(cfg['Overwrite'])}")
        print(f" [A] Conserva date file   : {format_on_off(cfg['PreserveDates'])}")
        out_dir = cfg['OutDir'] if cfg['OutDir'] else '<sorgente>/out'
        print(f" [B] Cartella output      : {out_dir}")
        print(f" [C] Audio                : {cfg['AudioMode']}   (auto = PCM -> AAC, altri formati in copia)")
        print(f" [D] Bitrate AAC          : {cfg['AacBitrate']} kb/s")
        print(f" [E] xvYCC -> bt709 (Sony): {format_on_off(cfg['NormalizeXvYCC'])}   (solo etichetta colore, pixel invariati)")
        print(f" [F] Copia XML/SRT/XMP    : {format_on_off(cfg['CopySidecars'])}")
        print(f" [G] Qualita' foto (JPEG) : {cfg['PhotoQuality']}   (90 = archivio; piu' basso = file piu' piccoli)")
        print(f" [H] Soglia SSIM foto     : {cfg['PhotoSsim']:.3f}   (sotto la soglia la foto viene rifatta a Q piu' alta)")
        print(f" [I] JPEG progressivo     : {format_on_off(cfg['PhotoProgressive'])}")
        print(f" [J] Verifica foto        : {format_on_off(cfg['PhotoVerify'])}   (SSIM + confronto metadati)")
        print(f" [K] Bitrate Opus         : {cfg['OpusBitrate']} kb/s   (VBR, minimo 128; audio WAV/FLAC -> Opus)")
        print(f" [L] Copertina audio      : {format_on_off(cfg['OpusCover'])}   (copia/estrai cover nella cartella opus)")
        print(" [P] Preset rapidi (Sicuro / Archivio / Compatto)")
        print(" [0] Indietro")
        
        c = input('Scelta: ').strip().upper()
        if c == '1':
            enc = read_default('Encoder (auto/qsv/x265)', cfg['Encoder'])
            cfg['Encoder'] = enc if enc in ['qsv', 'x265'] else 'auto'
        elif c == '2':
            cfg['QsvQuality'] = read_int_range('Qualita QSV', cfg['QsvQuality'], 10, 40)
        elif c == '3':
            cfg['X265Crf'] = read_int_range('CRF x265', cfg['X265Crf'], 10, 35)
        elif c == '4':
            p = read_default('Preset (ultrafast superfast veryfast faster fast medium slow slower)', cfg['X265Preset'])
            if p in ['ultrafast','superfast','veryfast','faster','fast','medium','slow','slower']:
                cfg['X265Preset'] = p
        elif c == '5':
            cfg['VmafThreshold'] = read_int_range('Soglia VMAF', cfg['VmafThreshold'], 80, 99)
        elif c == '6':
            cfg['VmafSubsample'] = read_int_range('Analizza 1 frame ogni N', cfg['VmafSubsample'], 1, 30)
        elif c == '7':
            cfg['AutoRetry'] = not cfg['AutoRetry']
            if cfg['AutoRetry']:
                cfg['MaxRetries'] = read_int_range('Tentativi massimi', cfg['MaxRetries'], 1, 5)
        elif c == '8':
            cfg['Recurse'] = not cfg['Recurse']
        elif c == '9':
            cfg['Overwrite'] = not cfg['Overwrite']
        elif c == 'A':
            cfg['PreserveDates'] = not cfg['PreserveDates']
        elif c == 'B':
            r = input('Percorso output (vuoto = <sorgente>/out): ').strip().strip('"\'')
            cfg['OutDir'] = r
        elif c == 'C':
            am = read_default('Audio (auto/copy/aac)', cfg['AudioMode'])
            cfg['AudioMode'] = am if am in ['copy', 'aac'] else 'auto'
        elif c == 'D':
            cfg['AacBitrate'] = read_int_range('Bitrate AAC kb/s', cfg['AacBitrate'], 128, 512)
        elif c == 'E':
            cfg['NormalizeXvYCC'] = not cfg['NormalizeXvYCC']
        elif c == 'F':
            cfg['CopySidecars'] = not cfg['CopySidecars']
        elif c == 'G':
            cfg['PhotoQuality'] = read_int_range('Qualita foto', cfg['PhotoQuality'], 50, 98)
        elif c == 'H':
            r = read_default('Soglia SSIM (0.95-0.9999)', f"{cfg['PhotoSsim']:.4f}")
            try:
                d = float(r.replace(',', '.'))
                if 0.95 <= d < 1:
                    cfg['PhotoSsim'] = d
                else:
                    raise ValueError
            except ValueError:
                print_color('  Valore non valido.', YELLOW)
                time.sleep(1)
        elif c == 'I':
            cfg['PhotoProgressive'] = not cfg['PhotoProgressive']
        elif c == 'J':
            cfg['PhotoVerify'] = not cfg['PhotoVerify']
        elif c == 'K':
            cfg['OpusBitrate'] = read_int_range('Bitrate Opus kb/s', cfg['OpusBitrate'], 128, 512)
        elif c == 'L':
            cfg['OpusCover'] = not cfg['OpusCover']
        elif c == 'P':
            print(" 1 = Sicuro   (QSV 21, x265 CRF 18, soglia 97 | foto Q93, SSIM 0.993)")
            print(" 2 = Archivio (QSV 24, x265 CRF 20, soglia 96 | foto Q90, SSIM 0.990)  <- consigliato")
            print(" 3 = Compatto (QSV 27, x265 CRF 22, soglia 95 | foto Q85, SSIM 0.985)")
            p = input("Preset: ").strip()
            if p == '1':
                cfg['QsvQuality'] = 21; cfg['X265Crf'] = 18; cfg['VmafThreshold'] = 97; cfg['PhotoQuality'] = 93; cfg['PhotoSsim'] = 0.993
            elif p == '2':
                cfg['QsvQuality'] = 24; cfg['X265Crf'] = 20; cfg['VmafThreshold'] = 96; cfg['PhotoQuality'] = 90; cfg['PhotoSsim'] = 0.990
            elif p == '3':
                cfg['QsvQuality'] = 27; cfg['X265Crf'] = 22; cfg['VmafThreshold'] = 95; cfg['PhotoQuality'] = 85; cfg['PhotoSsim'] = 0.985
        elif c == '0':
            save_config()
            return
            
        save_config()

def show_main_menu():
    while True:
        clear_screen()
        print_color('==============================================================', CYAN)
        print_color("   SQUEEZE  -  video HEVC, foto JPEG, audio Opus", CYAN)
        print_color('==============================================================', CYAN)
        
        enc = resolve_encoder()
        if enc == 'qsv':
            enc_txt = f"Intel QSV (GPU), qualita' {cfg['QsvQuality']}"
        elif enc == 'x265':
            enc_txt = f"x265 (CPU), CRF {cfg['X265Crf']}, preset {cfg['X265Preset']}"
        else:
            enc_txt = "NESSUNO DISPONIBILE (controlla [6])"
            
        dir_txt = cfg['SourceDir'] if cfg['SourceDir'] else '(non selezionata)'
        print(f" Cartella : {dir_txt}")
        print(f" Encoder  : {enc_txt}")
        print(f" VMAF     : {'disponibile' if has_vmaf else 'NON disponibile'}   soglia {cfg['VmafThreshold']}   retry auto {format_on_off(cfg['AutoRetry'])}")
        
        if magick_exe:
            im_txt = f"ImageMagick OK, Q{cfg['PhotoQuality']}, soglia SSIM {cfg['PhotoSsim']:.3f}"
            if not magick_ssim:
                im_txt += " (SSIM non disponibile!)"
            if exiftool_exe:
                im_txt += ", exiftool"
        else:
            im_txt = "ImageMagick NON trovato (funzioni foto disattivate)"
            
        print(f" Foto     : {im_txt}")
        if not has_ffmpeg:
            audio_txt = 'ffmpeg non trovato'
        elif not has_opus:
            audio_txt = 'libopus NON disponibile'
        else:
            audio_txt = f"WAV/FLAC -> Opus {cfg['OpusBitrate']}k, cover {format_on_off(cfg['OpusCover'])}"
        print(f" Audio    : {audio_txt}")
        print('--------------------------------------------------------------')
        print(" [1] Scegli cartella (video, foto e audio)")
        print(" [2] Analizza cartella (elenco video e foto)")
        print(" [3] Comprimi VIDEO")
        print(" [4] Comprimi VIDEO + verifica + ricodifica automatica   (consigliato)")
        print(" [5] Solo verifica VIDEO (output gia' presenti)")
        print(" [6] Impostazioni")
        print(" [7] Comprimi FOTO JPEG (+ verifica SSIM e metadati + retry)")
        print(" [8] Solo verifica FOTO (output gia' presenti)")
        print(" [9] Test qualita' su una foto (confronto di piu' valori)")
        print(" [10] Comprimi AUDIO (WAV/FLAC -> Opus)")
        print(" [0] Esci")
        
        c = input('Scelta: ').strip()
        if c == '1':
            select_folder()
        elif c == '2':
            show_scan()
        elif c == '3':
            start_batch('compress')
        elif c == '4':
            start_batch('full')
        elif c == '5':
            start_batch('verify')
        elif c == '6':
            show_settings_menu()
        elif c == '7':
            start_batch('full', 'photo')
        elif c == '8':
            start_batch('verify', 'photo')
        elif c == '9':
            show_photo_test()
        elif c == '10':
            start_batch('compress', 'audio')
        elif c == '0':
            save_config()
            return

def main():
    import_config()
    print_color('Controllo ffmpeg / QSV / VMAF ...', GRAY)
    if not test_tools():
        wait_enter()
        sys.exit(1)
    show_main_menu()

if __name__ == '__main__':
    main()
