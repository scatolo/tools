#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
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
    Requisiti: Linux (Fedora), python3, ffmpeg e ffprobe nel PATH (build "full" con libvmaf
    e libopus); per le foto ImageMagick 7 (comando "magick"). exiftool e' opzionale (verifica metadati piu' precisa).
"""
import csv
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    if hasattr(sys.stderr, 'reconfigure'):
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

# --- ANSI Colors ---
CYAN = '\033[36m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RED = '\033[31m'
GRAY = '\033[90m'
RESET = '\033[0m'

def print_color(text, color=RESET, end='\n'):
    print(f"{color}{text}{RESET}", end=end)

def clear_screen():
    os.system('cls' if os.name == 'nt' else 'clear')

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
    'NvencCq': 24,
    'NvencPreset': 'p7',
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
    if path != config_path:
        save_config()

def save_config():
    try:
        with open(config_path, 'w', encoding='utf-8') as f:
            json.dump(cfg, f, indent=4, ensure_ascii=False)
    except Exception:
        pass

# ----------------------------------------------------------------------------
#  UTILITA' E LAYOUT CENTRATO
# ----------------------------------------------------------------------------
BOX_WIDTH = 76

def get_console_width():
    try:
        return shutil.get_terminal_size(fallback=(80, 24)).columns
    except Exception:
        return 80

def get_box_pad(width=BOX_WIDTH):
    w = get_console_width()
    return ' ' * max(0, (w - width) // 2)

def write_box_top(width=BOX_WIDTH, color=CYAN):
    pad = get_box_pad(width)
    print_color(f"{pad}╭{'─' * (width - 2)}╮", color)

def write_box_sep(width=BOX_WIDTH, color=CYAN):
    pad = get_box_pad(width)
    print_color(f"{pad}├{'─' * (width - 2)}┤", color)

def write_box_bottom(width=BOX_WIDTH, color=CYAN):
    pad = get_box_pad(width)
    print_color(f"{pad}╰{'─' * (width - 2)}╯", color)

def write_box_line(text="", align="Left", color=RESET, border_color=CYAN, width=BOX_WIDTH):
    pad = get_box_pad(width)
    inner_w = width - 2
    if len(text) > inner_w:
        text = text[:inner_w - 3] + "..."
    rem = inner_w - len(text)
    if align == "Center":
        l_pad = rem // 2
        r_pad = rem - l_pad
    elif align == "Right":
        l_pad = rem
        r_pad = 0
    else:
        l_pad = 0
        r_pad = rem
    print(f"{pad}{border_color}│{RESET}{' ' * l_pad}{color}{text}{RESET}{' ' * r_pad}{border_color}│{RESET}")

def write_box_badged_line(label, badge, badge_color, detail, detail_color=GRAY, border_color=CYAN, width=BOX_WIDTH):
    pad = get_box_pad(width)
    inner_w = width - 2
    prefix = f"  {label:<8} : "
    badge_str = f"[{badge}]"
    used_len = len(prefix) + len(badge_str) + 1 + len(detail)
    if used_len > inner_w:
        max_d = inner_w - (len(prefix) + len(badge_str) + 1)
        detail = detail[:max_d - 3] + "..." if max_d > 3 else ""
    rem = max(0, inner_w - (len(prefix) + len(badge_str) + 1 + len(detail)))
    line = f"{pad}{border_color}│{GRAY}{prefix}{badge_color}{badge_str}{RESET} {detail_color}{detail}{' ' * rem}{border_color}│{RESET}"
    print(line)

def write_box_two_col(left, right, left_color=RESET, right_color=RESET, border_color=CYAN, width=BOX_WIDTH):
    pad = get_box_pad(width)
    inner_w = width - 2
    if (len(left) + len(right)) > inner_w:
        max_l = inner_w - len(right) - 3
        left = left[:max_l] + "..." if max_l > 0 else ""
    rem = max(1, inner_w - (len(left) + len(right)))
    line = f"{pad}{border_color}│{left_color}{left}{' ' * rem}{right_color}{right}{border_color}│{RESET}"
    print(line)

def read_box_prompt(prompt_text="Scelta"):
    pad = get_box_pad(BOX_WIDTH)
    print_color(f"\n{pad}{prompt_text}: ", CYAN, end="")
    try:
        r = input()
        if not r and not sys.stdin.isatty():
            return "0"
        return r.strip() if r else ""
    except (EOFError, KeyboardInterrupt):
        return "0"

def write_centered_progress(current, total, file_name, bar_width=24):
    if total <= 0: total = 1
    pct = int(round((current / total) * 100))
    filled = int(round((current / total) * bar_width))
    filled = min(bar_width, max(0, filled))
    empty = bar_width - filled
    bar = ('█' * filled) + ('░' * empty)
    prefix = f"[{bar}] {pct:3d}% ({current}/{total}) • "
    con_w = get_console_width()
    max_fn = con_w - len(prefix) - 4
    if max_fn > 3 and len(file_name) > max_fn:
        file_name = file_name[:max_fn - 3] + "..."
    text = prefix + file_name
    pad = ' ' * max(0, (con_w - len(text)) // 2)
    print()
    print_color(f"{pad}{text}", CYAN)

def wait_enter():
    pad = get_box_pad(BOX_WIDTH)
    try:
        input(f"\n{pad}\033[90mPremi Invio per continuare...\033[0m")
    except (EOFError, KeyboardInterrupt):
        pass

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
nvenc_works = False
qsv_works = False
has_opus = False

has_ffmpeg = False
magick_exe = None
magick_ssim = False
exiftool_exe = None

def test_tools():
    global has_ffmpeg, has_x265, has_vmaf, nvenc_works, qsv_works, has_opus, magick_exe, magick_ssim, exiftool_exe
    
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
            
            if 'hevc_nvenc' in enc:
                nv_cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=1280x720:d=0.2',
                          '-vf', 'format=p010le', '-c:v', 'hevc_nvenc', '-profile:v', 'main10', '-f', 'null', '-']
                res_nv = subprocess.run(nv_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if res_nv.returncode == 0:
                    nvenc_works = True
                else:
                    nv_cmd8 = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=1280x720:d=0.2',
                               '-vf', 'format=nv12', '-c:v', 'hevc_nvenc', '-profile:v', 'main', '-f', 'null', '-']
                    res_nv8 = subprocess.run(nv_cmd8, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    nvenc_works = (res_nv8.returncode == 0)

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
    if enc == 'nvenc':
        return 'nvenc' if nvenc_works else None
    if enc == 'qsv':
        return 'qsv' if qsv_works else None
    if enc == 'x265':
        return 'x265' if has_x265 else None
    
    if nvenc_works: return 'nvenc'
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
    return (str(info['ACodec']).startswith('pcm') and ok_layout)

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
def invoke_encode(src, dst, info, enc, q, duration=0):
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
    dur_arg = ['-t', str(duration)] if duration > 0 else []

    attempts = []
    if enc == 'nvenc':
        prof = 'main10' if is10 else 'main'
        sw_fmt = 'p010le' if is10 else 'nv12'
        preset = cfg.get('NvencPreset', 'p7')
        venc_hq = ['-c:v', 'hevc_nvenc', '-profile:v', prof, '-preset', preset,
                   '-tune', 'hq', '-rc', 'vbr', '-cq', str(q), '-b:v', '0',
                   '-multipass', 'fullres', '-rc-lookahead', '32', '-spatial-aq', '1', '-temporal-aq', '1']
        venc_safe = ['-c:v', 'hevc_nvenc', '-profile:v', prof, '-preset', preset,
                     '-rc', 'vbr', '-cq', str(q), '-b:v', '0']
        if not chroma_non420:
            attempts.append({'pre': ['-hwaccel', 'cuda', '-hwaccel_output_format', 'cuda'], 'vf': [], 'venc': venc_hq})
        attempts.append({'pre': [], 'vf': ['-vf', f"format={sw_fmt}"], 'venc': venc_hq})
        attempts.append({'pre': [], 'vf': ['-vf', f"format={sw_fmt}"], 'venc': venc_safe})
    elif enc == 'qsv':
        prof = 'main10' if is10 else 'main'
        sw_fmt = 'p010le' if is10 else 'nv12'
        venc = ['-c:v', 'hevc_qsv', '-profile:v', prof, '-preset', 'veryslow', '-global_quality', str(q), '-look_ahead', '1']
        
        if not chroma_non420:
            a1_pre = ['-hwaccel', 'qsv', '-hwaccel_output_format', 'qsv']
            if os.path.exists('/dev/dri/renderD128'):
                a1_pre.extend(['-qsv_device', '/dev/dri/renderD128'])
            attempts.append({'pre': a1_pre, 'vf': [], 'venc': venc})
            
        a2_pre = []
        if os.path.exists('/dev/dri/renderD128'):
            a2_pre = ['-qsv_device', '/dev/dri/renderD128']
        attempts.append({'pre': a2_pre, 'vf': ['-vf', f"format={sw_fmt}"], 'venc': venc})
    else:
        pix = 'yuv420p10le' if is10 else 'yuv420p'
        if not chroma_non420 and info.get('PixFmt'):
            pix = info['PixFmt']
        venc = ['-c:v', 'libx265', '-preset', cfg['X265Preset'], '-crf', str(q), '-pix_fmt', pix, '-x265-params', 'log-level=error']
        attempts.append({'pre': [], 'vf': [], 'venc': venc})

    try:
        for a in attempts:
            ff_args = base + a['pre'] + ['-i', src] + maps + a['vf'] + a['venc'] + mux + dur_arg + [part]
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
def measure_vmaf(dist, ref, sub, duration=0):
    threads = os.cpu_count() or 4
    filter_str = f"[0:v:0][1:v:0]libvmaf=n_threads={threads}:n_subsample={sub}"
    
    hwaccels = []
    if nvenc_works:
        hwaccels.append('cuda')
    if qsv_works:
        hwaccels.append('qsv')
    hwaccels.append('none')

    dur_arg = ['-t', str(duration)] if duration > 0 else []

    for hw in hwaccels:
        pre = []
        if hw == 'cuda':
            pre.extend(['-hwaccel', 'cuda'])
        elif hw == 'qsv':
            pre.extend(['-hwaccel', 'qsv'])
            if os.path.exists('/dev/dri/renderD128'):
                pre.extend(['-qsv_device', '/dev/dri/renderD128'])
            
        ff_args = ['ffmpeg', '-hide_banner', '-nostats'] + pre + ['-i', dist] + pre + ['-i', ref] + \
                  dur_arg + ['-lavfi', filter_str, '-an', '-sn', '-dn', '-f', 'null', '-']
        
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

    if enc == 'nvenc':
        q = int(cfg['NvencCq'])
        q_min = 14
        q_step = 3
    elif enc == 'qsv':
        q = int(cfg['QsvQuality'])
        q_min = 15
        q_step = 3
    else:
        q = int(cfg['X265Crf'])
        q_min = 12
        q_step = 2

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
        print_color(f"   encode q={q} ({enc}) ...", GRAY)
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
        p = lines[0].strip().split('|')
        if len(p) < 3:
            return None
        w, h, q = int(p[0]), int(p[1]), int(p[2])
        samp = '2x2'
        if len(p) >= 4:
            m = re.match(r'^(\d+x\d+)', p[3])
            if m: samp = m.group(1)
        return {'Width': w, 'Height': h, 'Q': q, 'Sampling': samp}
    except Exception:
        return None

def invoke_photo_encode(src, dst, info, q):
    part = dst + ".part"
    il = 'JPEG' if cfg['PhotoProgressive'] else 'None'
    im = [magick_exe, src, '-quality', str(q), '-sampling-factor', info['Sampling'],
          '-interlace', il, '-define', 'jpeg:optimize-coding=true', f"JPEG:{part}"]
    try:
        res = subprocess.run(im, capture_output=True, text=True)
        if res.returncode == 0 and os.path.exists(part):
            os.replace(part, dst)
            return True
        for line in (res.stdout + res.stderr).splitlines()[:3]:
            print_color(f"   magick: {line}", GRAY)
        return False
    except KeyboardInterrupt:
        if os.path.exists(part): os.remove(part)
        raise
    finally:
        if os.path.exists(part):
            try: os.remove(part)
            except Exception: pass

def measure_ssim(a, b):
    cmd = [magick_exe, 'compare', '-metric', 'SSIM', a, b, 'null:']
    try:
        res = subprocess.run(cmd, capture_output=True, text=True)
        lines = (res.stdout + "\n" + res.stderr).splitlines()
        num_pat = r'[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?'
        for l in lines:
            m = re.match(rf"^\s*{num_pat}\s*\(\s*({num_pat})\s*\)", l)
            if m:
                d = float(m.group(1))
                return max(0.0, 1.0 - 2.0 * d)
            m = re.match(rf"^\s*({num_pat})\s*$", l)
            if m:
                return float(m.group(1))
    except Exception:
        pass
    return None

def get_exiftool_keys(path):
    s = set()
    try:
        res = subprocess.run([exiftool_exe, '-a', '-u', '-G1', '-s', path], capture_output=True, text=True)
        for line in res.stdout.splitlines():
            m = re.match(r'^\[([^\]]+)\]\s+(\S+)\s*:', line)
            if m:
                g, t = m.group(1), m.group(2)
                if not re.match(r'^(System|File|ExifTool|Composite|JFIF|MPF.*)$', g):
                    s.add(f"{g}:{t}")
    except Exception:
        pass
    return s

def get_exif_lines(path):
    try:
        res = subprocess.run([magick_exe, 'identify', '-format', '%[EXIF:*]', f"{path}[0]"], capture_output=True, text=True)
        return [l for l in res.stdout.splitlines() if '=' in l]
    except Exception:
        return []

def test_photo_metadata(src, dst):
    miss = 0
    total = 0
    if exiftool_exe:
        a = get_exiftool_keys(src)
        b = get_exiftool_keys(dst)
        total = len(a)
        miss = len(a - b)
    else:
        a = get_exif_lines(src)
        b = set(get_exif_lines(dst))
        total = len(a)
        miss = sum(1 for line in a if line not in b)
        
    if total == 0:
        txt = 'n/d'
    elif miss == 0:
        txt = f"OK ({total})"
    else:
        txt = f"MANCANO {miss}/{total}"
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
        while encoded_now and cfg['AutoRetry'] and v is not None and v < float(cfg['PhotoSsim']) and tries < cfg['MaxRetries']:
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
        elif v < float(cfg['PhotoSsim']):
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
#  AUDIO (WAV/FLAC -> Opus)
# ----------------------------------------------------------------------------
RIFF_INFO_MAP = {
    'IART': 'ARTIST', 'INAM': 'TITLE', 'IPRD': 'ALBUM', 'ICRD': 'DATE', 'IGNR': 'GENRE',
    'ITRK': 'TRACKNUMBER', 'ICOP': 'COPYRIGHT', 'ICMT': 'COMMENT', 'ISFT': 'ENCODER',
    'IENG': 'ENGINEER', 'IWRI': 'WRITER', 'IMUS': 'COMPOSER', 'IALK': 'ALBUMARTIST',
    'ILNG': 'LANGUAGE', 'IBPM': 'BPM', 'IKEY': 'KEY'
}

def get_flac_comments(path):
    comments = []
    try:
        with open(path, 'rb') as f:
            b = f.read()
        if len(b) < 8 or b[:4] != b'fLaC':
            return []
        pos = 4
        last = False
        while not last and pos + 4 <= len(b):
            h = b[pos]
            last = bool(h & 0x80)
            btype = h & 0x7F
            length = (b[pos+1] << 16) | (b[pos+2] << 8) | b[pos+3]
            body_start = pos + 4
            if btype == 4:
                o = body_start
                if o + 4 <= len(b):
                    vlen = struct.unpack('<I', b[o:o+4])[0]
                    o += 4 + vlen
                    if o + 4 <= len(b):
                        n = struct.unpack('<I', b[o:o+4])[0]
                        o += 4
                        for _ in range(n):
                            if o + 4 > len(b): break
                            clen = struct.unpack('<I', b[o:o+4])[0]
                            o += 4
                            if o + clen > len(b): break
                            comments.append(b[o:o+clen].decode('utf-8', errors='replace'))
                            o += clen
            pos = body_start + length
    except Exception:
        pass
    return comments

def get_riff_info_comments(path):
    comments = []
    try:
        with open(path, 'rb') as f:
            b = f.read()
        if len(b) < 12 or b[:4] != b'RIFF':
            return []
        pos = 12
        while pos + 8 <= len(b):
            cid = b[pos:pos+4].decode('ascii', errors='ignore')
            size = struct.unpack('<I', b[pos+4:pos+8])[0]
            pos += 8
            if cid == 'LIST' and pos + 4 <= len(b) and b[pos:pos+4] == b'INFO':
                o = pos + 4
                lim = min(pos + size, len(b))
                while o + 8 <= lim:
                    sid = b[o:o+4].decode('ascii', errors='ignore')
                    ssize = struct.unpack('<I', b[o+4:o+8])[0]
                    o += 8
                    if o + ssize > len(b): break
                    val = b[o:o+ssize].decode('utf-8', errors='replace').rstrip('\x00')
                    key = RIFF_INFO_MAP.get(sid, sid.strip())
                    if val:
                        comments.append(f"{key}={val}")
                    o += ssize
                    if ssize % 2 == 1: o += 1
            if size < 0: break
            pos += size
            if size % 2 == 1: pos += 1
    except Exception:
        pass
    return comments

def get_ffprobe_comments(path):
    cmd = ['ffprobe', '-v', 'error', '-show_entries', 'format_tags', '-of', 'json', path]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True)
        o = json.loads(res.stdout)
        tags = o.get('format', {}).get('tags', {})
        return [f"{k}={v}" for k, v in tags.items()]
    except Exception:
        return []

def get_source_comments(path):
    p = Path(path)
    ext = p.suffix.lower()
    c = []
    if ext == '.flac':
        c = get_flac_comments(path)
    elif ext == '.wav':
        c = get_riff_info_comments(path)
    if not c:
        c = get_ffprobe_comments(path)
    return c

def get_opus_comments(comments):
    out = []
    for c in comments:
        if '=' not in c: continue
        key, val = c.split('=', 1)
        if re.match(r'^(?i)(METADATA_BLOCK_PICTURE|COVERART|COVERARTMIME)$', key):
            continue
        if key.upper() == 'ARTIST' and ';' in val:
            for a in val.split(';'):
                a = a.strip()
                if a: out.append(f"{key}={a}")
        else:
            out.append(c)
    return out

def new_opus_tags_packet(vendor_bytes, comments):
    data = bytearray()
    data.extend(b'OpusTags')
    data.extend(struct.pack('<I', len(vendor_bytes)))
    data.extend(vendor_bytes)
    data.extend(struct.pack('<I', len(comments)))
    for c in comments:
        cb = c.encode('utf-8')
        data.extend(struct.pack('<I', len(cb)))
        data.extend(cb)
    return bytes(data)

def get_ogg_crc32(data, start, count):
    crc = 0
    high_bit = 0x80000000
    poly = 0x04C11DB7
    end = start + count
    for i in range(start, end):
        crc = ((crc ^ (data[i] << 24)) & 0xFFFFFFFF)
        for _ in range(8):
            if crc & high_bit:
                crc = (((crc << 1) & 0xFFFFFFFF) ^ poly)
            else:
                crc = ((crc << 1) & 0xFFFFFFFF)
    return crc

def read_ogg_pages(b):
    pages = []
    pos = 0
    while pos + 27 <= len(b):
        if b[pos:pos+4] != b'OggS':
            break
        nseg = b[pos+26]
        if pos + 27 + nseg > len(b): break
        seg = list(b[pos+27 : pos+27+nseg])
        body_len = sum(seg)
        page_len = 27 + nseg + body_len
        if pos + page_len > len(b): break
        
        header_type = b[pos+5]
        serial = struct.unpack('<I', b[pos+14:pos+18])[0]
        seq = struct.unpack('<I', b[pos+18:pos+22])[0]
        pages.append({
            'offset': pos, 'page_length': page_len, 'header_type': header_type,
            'serial': serial, 'seq': seq, 'num_segments': nseg,
            'seg_table': seg, 'body_offset': pos + 27 + nseg, 'body_length': body_len
        })
        pos += page_len
    return pages

def get_opus_tags_info(b, pages, idx):
    buf = bytearray()
    p = idx
    done = False
    while not done and p < len(pages):
        pg = pages[p]
        bo = pg['body_offset']
        for v in pg['seg_table']:
            buf.extend(b[bo : bo+v])
            bo += v
            if v < 255:
                done = True
                break
        p += 1
    vlen = 0
    if len(buf) >= 12:
        vlen = struct.unpack('<I', buf[8:12])[0]
    if vlen < 0 or vlen + 12 > len(buf):
        vlen = 0
    vendor = buf[12 : 12+vlen]
    return {'vendor': bytes(vendor), 'page_count': p - idx}

def new_ogg_page_bytes(header_type, serial, seq, seg, body):
    page = bytearray(27 + len(seg) + len(body))
    page[0:5] = b'OggS\x00'
    page[5] = header_type
    page[14:18] = struct.pack('<I', serial)
    page[18:22] = struct.pack('<I', seq)
    page[26] = len(seg)
    page[27 : 27+len(seg)] = bytes(seg)
    page[27+len(seg) : ] = bytes(body)
    crc = get_ogg_crc32(page, 0, len(page))
    page[22:26] = struct.pack('<I', crc)
    return bytes(page)

def set_opus_tags(path, comments):
    try:
        with open(path, 'rb') as f:
            b = f.read()
        pages = read_ogg_pages(b)
        idx = -1
        for i, pg in enumerate(pages):
            if pg['body_length'] >= 8 and b[pg['body_offset'] : pg['body_offset']+8] == b'OpusTags':
                idx = i
                break
        if idx < 0: return False

        info = get_opus_tags_info(b, pages, idx)
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
            seg = lace[i2 : i2+cnt]
            body_len = sum(seg)
            body = packet[off : off+body_len]
            ht = 0 if first else 1
            new_pages.append(new_ogg_page_bytes(ht, pages[idx]['serial'], seq, seg, body))
            off += body_len
            i2 += cnt
            seq += 1
            first = False

        delta = len(new_pages) - info['page_count']
        out_bytes = bytearray()
        i = 0
        while i < len(pages):
            if i == idx:
                for np in new_pages:
                    out_bytes.extend(np)
                i += info['page_count']
                continue
            pg = pages[i]
            if i > idx and delta != 0:
                copy = bytearray(b[pg['offset'] : pg['offset']+pg['page_length']])
                struct.pack_into('<I', copy, 18, pg['seq'] + delta)
                copy[22:26] = b'\x00\x00\x00\x00'
                crc = get_ogg_crc32(copy, 0, len(copy))
                struct.pack_into('<I', copy, 22, crc)
                out_bytes.extend(copy)
            else:
                out_bytes.extend(b[pg['offset'] : pg['offset']+pg['page_length']])
            i += 1

        with open(path, 'wb') as f:
            f.write(out_bytes)
        return True
    except Exception:
        return False

def extract_audio_cover(src, out_dir):
    cmd = ['ffprobe', '-v', 'error', '-select_streams', 'v', '-show_entries', 'stream=codec_name', '-of', 'json', src]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True)
        o = json.loads(res.stdout)
        if not o or 'streams' not in o or len(o['streams']) == 0:
            return None
        codec = o['streams'][0].get('codec_name', '')
        ext = '.png' if codec == 'png' else ('.webp' if codec == 'webp' else '.jpg')
        dst = os.path.join(out_dir, f"cover{ext}")
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', src, '-map', '0:v:0', '-c', 'copy', dst])
        if os.path.exists(dst):
            return dst
    except Exception:
        pass
    return None

def test_cover_present(dir_path):
    for n in cfg['OpusCoverNames']:
        for e in cfg['OpusCoverExts']:
            if os.path.exists(os.path.join(dir_path, n + e)):
                return True
    return os.path.exists(os.path.join(dir_path, 'cover.jpg')) or os.path.exists(os.path.join(dir_path, 'cover.png'))

def set_audio_cover(file_path, dst):
    out_dir = os.path.dirname(dst)
    if test_cover_present(out_dir):
        return 'presente'
    p = Path(file_path)
    for n in cfg['OpusCoverNames']:
        for e in cfg['OpusCoverExts']:
            src_cover = p.parent / (n + e)
            if src_cover.is_file():
                shutil.copy2(src_cover, Path(out_dir) / src_cover.name)
                return 'copiata'
    if extract_audio_cover(str(file_path), out_dir):
        return 'estratta'
    return '-'

def invoke_audio_job(file_path, src_root, out_root):
    src_str = str(file_path)
    rel = src_str[len(src_root):].lstrip('/\\')
    p = Path(rel)
    dst = os.path.join(out_root, str(p.with_suffix('.opus')))
    
    f_stat = os.stat(src_str)
    f_size = f_stat.st_size
    row = {'File': rel, 'InMB': round(f_size / (1024*1024), 1), 'OutMB': None,
           'Saved': None, 'Bitrate': cfg['OpusBitrate'], 'Tags': '-', 'Cover': '-', 'Status': ''}

    if os.path.exists(dst) and not cfg['Overwrite']:
        row['Status'] = 'ESISTENTE'
        return row

    os.makedirs(os.path.dirname(dst), exist_ok=True)
    comments = get_opus_comments(get_source_comments(src_str))

    part = dst + ".part"
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
    finally:
        if os.path.exists(part):
            try: os.remove(part)
            except Exception: pass

    if cfg['OpusCover']:
        row['Cover'] = set_audio_cover(src_str, dst)

    if os.path.exists(dst):
        out_len = os.path.getsize(dst)
        row['OutMB'] = round(out_len / (1024*1024), 1)
        row['Saved'] = round((1 - out_len / f_size) * 100, 0)
        if out_len >= f_size:
            os.remove(dst)
            row['Status'] = 'SALTATO: output piu grande'
            row['OutMB'] = None
            row['Saved'] = None
        else:
            row['Status'] = 'OK'
            if cfg['PreserveDates']:
                try: os.utime(dst, (f_stat.st_atime, f_stat.st_mtime))
                except Exception: pass

    return row

# ----------------------------------------------------------------------------
#  BATCH
# ----------------------------------------------------------------------------
def test_source():
    if not cfg['SourceDir'] or not os.path.isdir(cfg['SourceDir']):
        print_color('Nessuna cartella valida selezionata: usa prima [1].', YELLOW)
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
            print_color("ImageMagick non trovato: installalo e riavvia il terminale.", RED)
            wait_enter(); return
        if mode == 'verify' and not magick_ssim:
            print_color('Questa build di ImageMagick non ha la metrica SSIM: verifica non disponibile.', RED)
            wait_enter(); return
    elif is_audio:
        if not has_ffmpeg:
            print_color('ffmpeg/ffprobe non trovati nel PATH: conversione audio non disponibile.', RED)
            wait_enter(); return
        if not has_opus:
            print_color('Questa build di ffmpeg non include libopus: conversione audio non disponibile.', RED)
            wait_enter(); return
    else:
        if not has_ffmpeg:
            print_color('ffmpeg/ffprobe non trovati nel PATH: funzioni video non disponibili.', RED)
            wait_enter(); return
        if mode != 'verify':
            enc = resolve_encoder()
            if not enc:
                print_color('Nessun encoder disponibile con la scelta attuale (vedi [6] Impostazioni).', RED)
                wait_enter(); return
        if mode != 'compress' and not has_vmaf:
            print_color('Il tuo ffmpeg non include libvmaf: verifica non disponibile.', RED)
            wait_enter(); return

    files = get_media_files(kind)
    if not files:
        kind_label = 'JPEG' if is_photo else ('audio (WAV/FLAC)' if is_audio else 'video')
        print_color(f"Nessun file {kind_label} trovato.", YELLOW)
        wait_enter(); return

    src_root = cfg['SourceDir'].rstrip('/\\')
    out_root = get_opus_dir() if is_audio else get_out_dir()
    total_mb = round(sum(f.stat().st_size for f in files) / (1024*1024), 1)

    clear_screen()
    write_box_top()
    write_box_line("A V V I O   E L A B O R A Z I O N E   L O T T O", align="Center", color=CYAN)
    write_box_sep()
    write_box_line(f"  File da elaborare : {len(files)} ({total_mb} MB)")
    if is_photo:
        mode_str = 'solo verifica foto' if mode == 'verify' else ('compressione foto' + (' + verifica + retry' if cfg['PhotoVerify'] else ' (senza verifica)'))
        write_box_line(f"  Modalita'         : {mode_str}")
        write_box_line(f"  JPEG              : qualita' {cfg['PhotoQuality']}, {'progressivo' if cfg['PhotoProgressive'] else 'baseline'}", color=GRAY)
        if cfg['PhotoVerify']:
            write_box_line(f"  Soglia SSIM       : {cfg['PhotoSsim']:.3f}", color=GRAY)
    elif is_audio:
        write_box_line("  Modalita'         : conversione audio -> Opus")
        write_box_line(f"  Opus              : {cfg['OpusBitrate']} kb/s VBR", color=GRAY)
        write_box_line("  Metadati          : commenti Vorbis copiati fedelmente", color=GRAY)
        write_box_line(f"  Copertina         : {'copiata/estratta nella cartella opus' if cfg['OpusCover'] else 'disattivata'}", color=GRAY)
    else:
        modes_map = {'compress': 'solo compressione', 'full': 'compressione + verifica VMAF + retry', 'verify': 'solo verifica'}
        write_box_line(f"  Modalita'         : {modes_map.get(mode, mode)}")
        if enc:
            if enc == 'nvenc':
                enc_desc = f"NVIDIA NVENC (CQ {cfg['NvencCq']}, preset {cfg['NvencPreset']})"
            elif enc == 'qsv':
                enc_desc = f"Intel QSV (global_quality {cfg['QsvQuality']})"
            else:
                enc_desc = f"x265 (CRF {cfg['X265Crf']}, preset {cfg['X265Preset']})"
            write_box_line(f"  Encoder           : {enc_desc}", color=GRAY)
        if mode != 'verify':
            if cfg['AudioMode'] == 'copy': a_txt = 'copia originale'
            elif cfg['AudioMode'] == 'aac': a_txt = f"AAC {cfg['AacBitrate']}k"
            else: a_txt = f"auto (PCM -> AAC {cfg['AacBitrate']}k, altri in copia)"
            write_box_line(f"  Audio             : {a_txt}", color=GRAY)
        if mode != 'compress':
            write_box_line(f"  Soglia VMAF       : {cfg['VmafThreshold']}", color=GRAY)
            
    write_box_line(f"  Output            : {out_root}")
    write_box_bottom()

    ans = read_box_prompt("Procedo? (s/n) [s]")
    if ans and not ans.lower().startswith(('s', 'y')):
        return

    os.makedirs(out_root, exist_ok=True)
    results = []
    start_t = time.time()
    
    for i, f in enumerate(files, 1):
        write_centered_progress(current=i, total=len(files), file_name=f.name)
        if is_photo:
            r = invoke_photo_job(f, mode, src_root, out_root)
        elif is_audio:
            r = invoke_audio_job(f, src_root, out_root)
        else:
            r = invoke_video_job(f, mode, enc, src_root, out_root)
        results.append(r)
        
        st = r['Status']
        if 'OK' in st or 'COMPRESS' in st: color = GREEN
        elif 'ESISTENTE' in st or 'GIA' in st: color = GRAY
        else: color = YELLOW
            
        if is_photo: m_txt = f"SSIM={r['SSIM']}  meta={r['Meta']}"
        elif is_audio: m_txt = f"tags={r['Tags']}  cover={r['Cover']}"
        else: m_txt = f"VMAF={r['VMAF']}"
        print_color(f"   -> {r['Status']}  {r['InMB']} -> {r['OutMB']} MB  (-{r['Saved']}%)  {m_txt}", color)
        
    elapsed = time.time() - start_t

    print()
    write_box_top()
    write_box_line("R I E P I L O G O   E L A B O R A Z I O N E", align="Center", color=CYAN)
    write_box_bottom()
    print()
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
    auds = get_media_files('audio') if has_ffmpeg else []
    
    if not vids and not pics and not auds:
        print_color("Nessun file video, JPEG o audio trovato nella cartella.", YELLOW)
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

    if auds:
        print_color("\nAUDIO (WAV / FLAC)", CYAN)
        rows = []
        for f in auds:
            mb = round(f.stat().st_size / (1024*1024), 1)
            rows.append({
                'File': f.name,
                'MB': mb,
                'Formato': f.suffix.upper().lstrip('.')
            })
        print(format_table(rows, ['File', 'MB', 'Formato']))
        tot_mb = sum(f.stat().st_size for f in auds) / (1024*1024)
        print(f"Totale audio: {len(auds)} file, {tot_mb:.1f} MB")
        
    wait_enter()

def show_video_test():
    if not has_ffmpeg:
        print_color('ffmpeg/ffprobe non trovati nel PATH: test video non disponibile.', RED)
        wait_enter(); return
    enc = resolve_encoder()
    if not enc:
        print_color('Nessun encoder video disponibile (vedi [6] Impostazioni).', RED)
        wait_enter(); return
    if not has_vmaf:
        print_color('libvmaf non disponibile in ffmpeg: calcolo del punteggio non disponibile.', YELLOW)

    default = ''
    if cfg['SourceDir'] and os.path.isdir(cfg['SourceDir']):
        vids = get_media_files('video')
        if vids:
            default = str(vids[0])

    clear_screen()
    write_box_top()
    write_box_line("TEST QUALITA VIDEO (CONFRONTO CQ / CRF)", align="Center", color=CYAN)
    write_box_sep()
    write_box_line("  Trascina un file video o premi Invio per usare il default.", color=GRAY)
    if default:
        write_box_line(f"  Default: {os.path.basename(default)}", color=CYAN)
    write_box_bottom()

    r = read_box_prompt("Video di prova")
    if not r: r = default
    r = r.strip().strip('"\'')
    if r.lower() in ['q', 'annulla', 'exit', '0']:
        return
    if not r or not os.path.isfile(r):
        print_color("File video non valido o non trovato.", YELLOW)
        wait_enter(); return
    
    info = get_video_info(r)
    if not info:
        print_color("Impossibile leggere le informazioni del video.", RED)
        wait_enter(); return

    f_size = os.path.getsize(r)
    f_name = os.path.basename(r)
    print_color(f"\n{f_name}: {f_size/(1024*1024):.1f} MB, {info['Width']}x{info['Height']} @ {info['Fps']:.2f} fps, dur {info['Duration']:.1f}s, croma {info['PixFmt']}", CYAN)

    dur_sec = read_int_range('Durata spezzone di test in secondi (0 = intero file)', 10, 0, 300)

    def_q = '20,23,26,29' if enc in ['nvenc', 'qsv'] else '18,20,22,24'
    if enc == 'nvenc': q_prompt = 'Valori CQ hevc_nvenc da provare'
    elif enc == 'qsv': q_prompt = 'Valori global_quality QSV da provare'
    else: q_prompt = 'Valori CRF x265 da provare'

    q_input = read_default(q_prompt, def_q)
    q_list = []
    for s in q_input.split(','):
        try:
            n = int(s.strip())
            if 10 <= n <= 45:
                q_list.append(n)
        except ValueError:
            pass

    if not q_list:
        print_color("Nessun valore di qualita valido specificato.", YELLOW)
        wait_enter(); return

    tmp = os.path.join(tempfile.gettempdir(), 'squeeze-video-test')
    os.makedirs(tmp, exist_ok=True)
    try:
        rows = []
        for idx, q in enumerate(q_list, 1):
            write_centered_progress(current=idx, total=len(q_list), file_name=f"Test q={q} ({enc})")
            out_ext = Path(r).suffix
            dst = os.path.join(tmp, f"test_q{q}{out_ext}")

            if not invoke_encode(src=r, dst=dst, info=info, enc=enc, q=q, duration=dur_sec):
                print_color(f"   errore nella codifica a q={q}", RED)
                continue

            out_len = os.path.getsize(dst)
            clip_mb = round(out_len / (1024*1024), 2)

            if dur_sec > 0 and info['Duration'] > dur_sec:
                est_bytes = (out_len / dur_sec) * info['Duration']
                est_total_mb = round(est_bytes / (1024*1024), 1)
                est_saved = round((1 - (est_bytes / f_size)) * 100, 0)
            else:
                est_total_mb = round(out_len / (1024*1024), 1)
                est_saved = round((1 - (out_len / f_size)) * 100, 0)

            vmaf = None
            if has_vmaf:
                print_color('   calcolo VMAF ...', GRAY)
                vmaf = measure_vmaf(dist=dst, ref=r, sub=cfg['VmafSubsample'], duration=dur_sec)

            rows.append({
                'CQ/CRF': q,
                'Clip MB': clip_mb,
                'Est Totale': f"{est_total_mb} MB",
                'Risparmio': f"{est_saved:.0f}%",
                'VMAF': round(vmaf, 2) if vmaf is not None else 'n/d'
            })

        print()
        write_box_top()
        write_box_line("R I S U L T A T I   T E S T   V I D E O", align="Center", color=CYAN)
        write_box_bottom()
        print()
        print(format_table(rows, ['CQ/CRF', 'Clip MB', 'Est Totale', 'Risparmio', 'VMAF']))
        print_color("\nScegli il valore con VMAF sopra la tua soglia (es. 96) e impostalo in [6] Impostazioni.", GRAY)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    wait_enter()

def show_photo_test():
    if not magick_exe:
        print_color("ImageMagick non trovato.", RED)
        wait_enter(); return
        
    default = ''
    if cfg['SourceDir'] and os.path.isdir(cfg['SourceDir']):
        pics = get_media_files('photo')
        if pics:
            default = str(pics[0])

    clear_screen()
    write_box_top()
    write_box_line("TEST QUALITA FOTO (CONFRONTO Q)", align="Center", color=CYAN)
    write_box_sep()
    write_box_line("  Trascina una foto o premi Invio per usare il default.", color=GRAY)
    if default:
        write_box_line(f"  Default: {os.path.basename(default)}", color=CYAN)
    write_box_bottom()
            
    r = read_box_prompt("Foto di prova")
    if not r: r = default
    r = r.strip().strip('"\'')
    if r.lower() in ['q', 'annulla', 'exit', '0']:
        return
    if not r or not os.path.isfile(r):
        print_color("File non valido o non trovato.", YELLOW)
        wait_enter(); return
        
    info = get_photo_info(r)
    if not info:
        print_color("Immagine non leggibile.", RED)
        wait_enter(); return
        
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
        print_color("Nessun valore di qualita valido specificato.", YELLOW)
        wait_enter()
        return
    tmp = os.path.join(tempfile.gettempdir(), 'squeeze-test')
    os.makedirs(tmp, exist_ok=True)
    
    try:
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
                'Risparmio': f"{round((1 - out_len / f_size) * 100, 0):.0f}%",
                'SSIM': round(ssim, 4) if ssim is not None else None,
                'Metadati': meta['Text']
            })
            
        print()
        write_box_top()
        write_box_line("R I S U L T A T I   T E S T   F O T O", align="Center", color=CYAN)
        write_box_bottom()
        print()
        print(format_table(rows, ['Quality', 'MB', 'Risparmio', 'SSIM', 'Metadati']))
        print_color("\nScegli la qualita' piu' bassa con SSIM sopra la tua soglia (e Metadati OK), poi impostala in [6] -> G/H.", GRAY)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    wait_enter()

# ----------------------------------------------------------------------------
#  TUI INTERATTIVA
# ----------------------------------------------------------------------------
def select_folder():
    clear_screen()
    write_box_top()
    write_box_line("SELEZIONE CARTELLA SORGENTE", align="Center", color=CYAN)
    write_box_sep()
    write_box_line("  Trascina o incolla qui il percorso di una cartella.", color=GRAY)
    write_box_line("  OPPURE premi direttamente INVIO per aprire la finestra di selezione.", color=YELLOW)
    write_box_line("  (Scrivi 'q' o 'annulla' per uscire senza modificare)", color=GRAY)
    write_box_bottom()

    r = read_box_prompt("Cartella")
    if r.lower() in ['q', 'annulla', 'exit', '0']:
        return

    if not r:
        selected = None
        if shutil.which('zenity'):
            try:
                cmd = ['zenity', '--file-selection', '--directory', '--title=Scegli la cartella sorgente per Squeeze']
                if cfg['SourceDir'] and os.path.isdir(cfg['SourceDir']):
                    cmd.append(f"--filename={cfg['SourceDir']}/")
                res = subprocess.run(cmd, capture_output=True, text=True)
                if res.returncode == 0 and res.stdout.strip():
                    selected = res.stdout.strip()
                else:
                    return
            except Exception:
                pass
        elif shutil.which('kdialog'):
            try:
                cmd = ['kdialog', '--getexistingdirectory', cfg['SourceDir'] or os.path.expanduser('~')]
                res = subprocess.run(cmd, capture_output=True, text=True)
                if res.returncode == 0 and res.stdout.strip():
                    selected = res.stdout.strip()
                else:
                    return
            except Exception:
                pass

        if not selected:
            try:
                import tkinter as tk
                from tkinter import filedialog
                root = tk.Tk()
                root.withdraw()
                root.attributes('-topmost', True)
                init_dir = cfg['SourceDir'] if cfg['SourceDir'] and os.path.isdir(cfg['SourceDir']) else None
                selected = filedialog.askdirectory(title="Scegli la cartella per Squeeze", initialdir=init_dir)
                root.destroy()
            except Exception:
                pass

        if selected:
            r = selected
        else:
            return

    r = r.strip().strip('"\'').rstrip('/\\')
    if os.path.isdir(r):
        cfg['SourceDir'] = os.path.abspath(r).rstrip('/\\')
        save_config()
        print_color(f"\nCartella impostata: {cfg['SourceDir']}", GREEN)
        time.sleep(0.8)
    else:
        print_color("\nPercorso non valido o cartella non trovata.", YELLOW)
        wait_enter()

def show_settings_menu():
    while True:
        clear_screen()
        write_box_top()
        write_box_line("I M P O S T A Z I O N I", align="Center", color=CYAN)
        write_box_sep()

        write_box_line("  VIDEO", color=CYAN)
        write_box_line(f"   [1] Encoder scelto        : {cfg['Encoder']}  (auto | nvenc | qsv | x265)")
        write_box_line(f"   [2] Qualita' NVENC (CQ)   : {cfg['NvencCq']}  (24 archivio, 21 sicuro, 27 compatto)")
        write_box_line(f"   [3] Preset NVENC          : {cfg['NvencPreset']}  (p1 piu' veloce ... p7 piu' lento HQ)")
        write_box_line(f"   [4] Qualita' QSV          : {cfg['QsvQuality']}  (24 archivio, 21 sicuro, 27 compatto)")
        write_box_line(f"   [5] Qualita' x265 (CRF)   : {cfg['X265Crf']}  (20 archivio, 18 sicuro, 22 compatto)")
        write_box_line(f"   [6] Preset x265           : {cfg['X265Preset']}")
        write_box_line(f"   [7] Soglia VMAF           : {cfg['VmafThreshold']}")
        write_box_line(f"   [8] Precisione VMAF       : 1 frame ogni {cfg['VmafSubsample']}")
        write_box_line(f"   [9] Retry automatico      : {format_on_off(cfg['AutoRetry'])}  (max {cfg['MaxRetries']} tentativi)")

        write_box_line("  FOTO (JPEG)", color=CYAN)
        write_box_line(f"   [G] Qualita' foto (JPEG)  : {cfg['PhotoQuality']}  (90 archivio; piu' basso = piu' piccolo)")
        write_box_line(f"   [H] Soglia SSIM foto      : {cfg['PhotoSsim']:.3f}")
        write_box_line(f"   [I] JPEG progressivo      : {format_on_off(cfg['PhotoProgressive'])}")
        write_box_line(f"   [J] Verifica foto         : {format_on_off(cfg['PhotoVerify'])}  (SSIM + confronto metadati)")

        write_box_line("  AUDIO", color=CYAN)
        write_box_line(f"   [C] Audio video           : {cfg['AudioMode']}  (auto: PCM->AAC, altri in copia)")
        write_box_line(f"   [D] Bitrate AAC           : {cfg['AacBitrate']} kb/s")
        write_box_line(f"   [K] Bitrate Opus          : {cfg['OpusBitrate']} kb/s (WAV/FLAC -> Opus)")
        write_box_line(f"   [L] Copertina audio       : {format_on_off(cfg['OpusCover'])}  (copia/estrai cover in opus/)")

        write_box_line("  GENERALE E SOTTOCARTELLE", color=CYAN)
        write_box_line(f"   [A] Includi sottocartelle : {format_on_off(cfg['Recurse'])}")
        write_box_line(f"   [B] Sovrascrivi output    : {format_on_off(cfg['Overwrite'])}")
        write_box_line(f"   [M] Conserva date file    : {format_on_off(cfg['PreserveDates'])}")
        out_str = cfg['OutDir'] if cfg['OutDir'] else '<sorgente>/out'
        write_box_line(f"   [N] Cartella output       : {out_str}")
        write_box_line(f"   [E] xvYCC -> bt709 (Sony) : {format_on_off(cfg['NormalizeXvYCC'])}  (solo etichetta colore)")
        write_box_line(f"   [F] Copia XML/SRT/XMP     : {format_on_off(cfg['CopySidecars'])}")

        write_box_line("  PRESET E USCITA", color=CYAN)
        write_box_line("   [P] Preset rapidi (Sicuro / Archivio / Compatto)", color=YELLOW)
        write_box_line("   [0] Salva e torna al menu principale", color=CYAN)
        write_box_bottom()
        
        c = read_box_prompt("Scelta").upper()
        if c == '1':
            enc = read_default('Encoder (auto/nvenc/qsv/x265)', cfg['Encoder'])
            cfg['Encoder'] = enc if enc in ['nvenc', 'qsv', 'x265'] else 'auto'
        elif c == '2':
            cfg['NvencCq'] = read_int_range('Qualita NVENC (CQ)', cfg['NvencCq'], 10, 40)
        elif c == '3':
            p = read_default('Preset NVENC (p1 p2 p3 p4 p5 p6 p7)', cfg['NvencPreset'])
            if p in ['p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7']:
                cfg['NvencPreset'] = p
        elif c == '4':
            cfg['QsvQuality'] = read_int_range('Qualita QSV', cfg['QsvQuality'], 10, 40)
        elif c == '5':
            cfg['X265Crf'] = read_int_range('CRF x265', cfg['X265Crf'], 10, 35)
        elif c == '6':
            p = read_default('Preset x265 (ultrafast superfast veryfast faster fast medium slow slower)', cfg['X265Preset'])
            if p in ['ultrafast','superfast','veryfast','faster','fast','medium','slow','slower']:
                cfg['X265Preset'] = p
        elif c == '7':
            cfg['VmafThreshold'] = read_int_range('Soglia VMAF', cfg['VmafThreshold'], 80, 99)
        elif c == '8':
            cfg['VmafSubsample'] = read_int_range('Analizza 1 frame ogni N', cfg['VmafSubsample'], 1, 30)
        elif c == '9':
            cfg['AutoRetry'] = not cfg['AutoRetry']
            if cfg['AutoRetry']:
                cfg['MaxRetries'] = read_int_range('Tentativi massimi', cfg['MaxRetries'], 1, 5)
        elif c == 'A':
            cfg['Recurse'] = not cfg['Recurse']
        elif c == 'B':
            cfg['Overwrite'] = not cfg['Overwrite']
        elif c == 'M':
            cfg['PreserveDates'] = not cfg['PreserveDates']
        elif c == 'N':
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
            print(" 1 = Sicuro   (NVENC CQ 21, QSV 21, x265 CRF 18, VMAF 97 | foto Q93, SSIM 0.993)")
            print(" 2 = Archivio (NVENC CQ 24, QSV 24, x265 CRF 20, VMAF 96 | foto Q90, SSIM 0.990)  <- consigliato")
            print(" 3 = Compatto (NVENC CQ 27, QSV 27, x265 CRF 22, VMAF 95 | foto Q85, SSIM 0.985)")
            p = input("Preset: ").strip()
            if p == '1':
                cfg['NvencCq'] = 21; cfg['QsvQuality'] = 21; cfg['X265Crf'] = 18; cfg['VmafThreshold'] = 97; cfg['PhotoQuality'] = 93; cfg['PhotoSsim'] = 0.993
            elif p == '2':
                cfg['NvencCq'] = 24; cfg['QsvQuality'] = 24; cfg['X265Crf'] = 20; cfg['VmafThreshold'] = 96; cfg['PhotoQuality'] = 90; cfg['PhotoSsim'] = 0.990
            elif p == '3':
                cfg['NvencCq'] = 27; cfg['QsvQuality'] = 27; cfg['X265Crf'] = 22; cfg['VmafThreshold'] = 95; cfg['PhotoQuality'] = 85; cfg['PhotoSsim'] = 0.985
        elif c == '0':
            save_config()
            return
            
        save_config()

def show_main_menu():
    while True:
        clear_screen()
        write_box_top()
        write_box_line("S Q U E E Z E   •   Media Compressor", align="Center", color=CYAN)
        write_box_line("Video HEVC (NVENC/QSV/x265) • Foto • Audio", align="Center", color=CYAN)
        write_box_sep()
        
        # Status badge 1: Cartella
        dir_txt = cfg['SourceDir'] if cfg['SourceDir'] else '(non selezionata: usa [1])'
        dir_badge = 'DIR' if cfg['SourceDir'] else 'NON IMPOSTATA'
        dir_col = GREEN if cfg['SourceDir'] else YELLOW
        write_box_badged_line('Cartella', dir_badge, dir_col, dir_txt, detail_color=RESET if cfg['SourceDir'] else YELLOW)

        # Status badge 2: Encoder
        enc = resolve_encoder()
        if enc == 'nvenc':
            enc_badge = 'GPU NVENC'
            enc_col = GREEN
            enc_detail = f"NVIDIA NVENC (CQ {cfg['NvencCq']}, preset {cfg['NvencPreset']})"
        elif enc == 'qsv':
            enc_badge = 'GPU QSV'
            enc_col = GREEN
            enc_detail = f"Intel QSV (qualita' {cfg['QsvQuality']})"
        elif enc == 'x265':
            enc_badge = 'CPU x265'
            enc_col = YELLOW
            enc_detail = f"x265 (CRF {cfg['X265Crf']}, preset {cfg['X265Preset']})"
        else:
            enc_badge = 'NESSUNO'
            enc_col = RED
            enc_detail = "Nessun encoder utilizzabile (controlla [6])"
        write_box_badged_line('Encoder', enc_badge, enc_col, enc_detail, detail_color=RESET)

        # Status badge 3: VMAF
        vmaf_badge = 'OK' if has_vmaf else 'NO'
        vmaf_col = GREEN if has_vmaf else RED
        vmaf_detail = f"Soglia {cfg['VmafThreshold']} • Retry auto {format_on_off(cfg['AutoRetry'])} (1 frame ogni {cfg['VmafSubsample']})" if has_vmaf else "libvmaf NON presente in ffmpeg (verifica video disattivata)"
        write_box_badged_line('VMAF', vmaf_badge, vmaf_col, vmaf_detail)

        # Status badge 4: Foto
        if not magick_exe:
            photo_badge = 'NO'
            photo_col = GRAY
            photo_detail = "ImageMagick non trovato (funzioni foto disattivate)"
        elif not magick_ssim:
            photo_badge = 'SENZA SSIM'
            photo_col = YELLOW
            et_str = ', exiftool' if exiftool_exe else ''
            photo_detail = f"ImageMagick (Q{cfg['PhotoQuality']}, SSIM non disp!{et_str})"
        else:
            photo_badge = 'OK'
            photo_col = GREEN
            et_str = ', exiftool' if exiftool_exe else ''
            photo_detail = f"ImageMagick (Q{cfg['PhotoQuality']}, SSIM {cfg['PhotoSsim']:.3f}{et_str})"
        write_box_badged_line('Foto', photo_badge, photo_col, photo_detail)

        # Status badge 5: Audio
        audio_ok = (has_ffmpeg and has_opus)
        audio_badge = 'OK' if audio_ok else 'NO'
        audio_col = GREEN if audio_ok else GRAY
        if not has_ffmpeg: audio_detail = "ffmpeg non trovato"
        elif not has_opus: audio_detail = "libopus non disponibile in ffmpeg"
        else: audio_detail = f"WAV/FLAC -> Opus {cfg['OpusBitrate']} kb/s • Cover {format_on_off(cfg['OpusCover'])}"
        write_box_badged_line('Audio', audio_badge, audio_col, audio_detail)

        write_box_sep()
        write_box_line("  CARTELLA E ANALISI", color=CYAN)
        write_box_line("   [1] Scegli cartella sorgente (trascina o premi Invio per sfogliare)")
        write_box_line("   [2] Analizza cartella (elenco video, foto e audio)")

        write_box_line("  VIDEO (HEVC + VMAF)", color=CYAN)
        write_box_line("   [3] Comprimi VIDEO (solo compressione)")
        write_box_two_col("   [4] Comprimi VIDEO + verifica VMAF + retry auto", "*consigliato  ", right_color=GREEN)
        write_box_line("   [5] Solo verifica VIDEO (output gia' presenti)")
        write_box_line("   [11] Test qualita' su un VIDEO (confronto di piu' valori CQ/CRF)")

        write_box_line("  FOTO (JPEG + SSIM)", color=CYAN)
        write_box_line("   [7] Comprimi FOTO JPEG (+ verifica SSIM e metadati + retry)")
        write_box_line("   [8] Solo verifica FOTO (output gia' presenti)")
        write_box_line("   [9] Test qualita' su una FOTO (confronto di piu' valori Q)")

        write_box_line("  AUDIO (WAV/FLAC -> Opus)", color=CYAN)
        write_box_line("   [10] Comprimi AUDIO (WAV/FLAC -> Opus con tag e copertina)")

        write_box_line("  SISTEMA", color=CYAN)
        write_box_two_col("   [6] Impostazioni", "[0] Salva ed esci  ", left_color=CYAN, right_color=GRAY)
        write_box_bottom()
        
        c = read_box_prompt("Scelta")
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
        elif c == '11':
            show_video_test()
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
    print_color('Controllo ffmpeg / NVENC / QSV / VMAF / ImageMagick ...', GRAY)
    if not test_tools():
        wait_enter()
        sys.exit(1)
    show_main_menu()

if __name__ == '__main__':
    main()
