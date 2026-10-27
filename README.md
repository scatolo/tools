# Squeeze: documentazione

[ 🇮🇹 Italiano ](README.md) · [ 🇬🇧 English ](README_EN.md) · [ 📘 Documentazione Tecnica ](TECHNICAL.md)

Strumento da terminale (PowerShell su Windows, Python su Linux) per **ridurre le dimensioni di video, foto e audio** di fotocamere come DJI Osmo Action e Sony Alpha, **senza differenze visibili rispetto all'originale** e conservando i metadati che le librerie permettono di conservare.

Documento riferito a `squeeze.ps1` e `squeeze.py` (video DJI/Sony, foto JPEG e conversione audio WAV/FLAC in Opus), aggiornato al 11 ottobre 2026.

## Indice

1. [Panoramica](#1-panoramica)
2. [Requisiti e installazione](#2-requisiti-e-installazione)
3. [Guida rapida (primo utilizzo)](#3-guida-rapida-primo-utilizzo)
4. [Il menu, voce per voce](#4-il-menu-voce-per-voce)
5. [Impostazioni e file di configurazione](#5-impostazioni-e-file-di-configurazione)
6. [Come scegliere la qualità](#6-come-scegliere-la-qualità)
7. [Cosa viene conservato e cosa si perde](#7-cosa-viene-conservato-e-cosa-si-perde)
8. [Output, log e stati](#8-output-log-e-stati)
9. [Documentazione tecnica](#9-documentazione-tecnica) ([approfondimento completo in TECHNICAL.md](TECHNICAL.md))
10. [Risoluzione dei problemi](#10-risoluzione-dei-problemi)
11. [Limiti noti e stato dei test](#11-limiti-noti-e-stato-dei-test)
12. [FAQ](#12-faq)
13. [Personalizzare lo script](#13-personalizzare-lo-script)
14. [Glossario](#14-glossario)
15. [Licenza](#15-licenza)

---

## 1. Panoramica

### Cosa fa

| Tipo di file | Cosa succede | Come si controlla la qualità |
|---|---|---|
| **Video** (`.mp4`, `.mov`) | Ricodificati in HEVC (H.265) con la GPU NVIDIA (NVENC), GPU Intel (Quick Sync) o con la CPU (x265). Risoluzione e fps restano uguali. | **VMAF** (0-100) confrontando output e originale |
| **Foto** (`.jpg`, `.jpeg`) | Ricodificate come JPEG a qualità inferiore, stessa risoluzione e stesso sottocampionamento del colore. | **SSIM** (0-1) + confronto dei metadati |
| **Audio** (`.wav`, `.flac`) | Convertiti in **Opus** (>=128 kb/s, VBR), con tutti i tag copiati. Gli artisti multipli restano tag separati. | Nessuna misura: Opus a bitrate scelto è trasparente |

### Principi di funzionamento

- **Gli originali non vengono mai modificati né cancellati.** Video e foto vanno in una cartella `out`, l'audio in una cartella `opus` (entrambe accanto alla sorgente).
- **La qualità viene misurata, non presunta.** Se un file scende sotto la soglia, viene ricodificato in automatico a qualità più alta.
- **Niente file a metà.** Ogni file viene scritto con estensione `.part` e rinominato solo a lavoro finito.
- **È riprendibile.** Se interrompi e rilanci, i file già pronti in `out` non vengono rifatti.

### Risultati di riferimento (dai test reali)

| Sorgente | File | Prima | Dopo | Risparmio |
|---|---|---|---|---|
| DJI Osmo Action 4 (4K-ish, 2688x1512, HEVC 10-bit) | 3 clip | 147,1 MB | 64,5 MB | 56% |
| Sony Alpha (1080p50, AVC 8-bit, audio PCM) | 3 clip | 456 MB | 102,7 MB | 77% |

Il risparmio dipende molto dal contenuto: scene scure, rumorose o molto dettagliate comprimono meno.

---

## 2. Requisiti e installazione

### 2.1 Requisiti

| Componente | Obbligatorio per | Note |
|---|---|---|
| **Windows 10/11** | script `.ps1` | Usa `squeeze.ps1` con PowerShell 5.1+ |
| **Linux (Fedora 44)** | script `.py` | Usa `squeeze.py` con Python 3.9+ |
| **ffmpeg + ffprobe** (build *full*) | video e audio | Servono i componenti `libx265`, `libvmaf`, `libopus` e (per la GPU) `hevc_nvenc` e/o `hevc_qsv` |
| **GPU NVIDIA (GeForce RTX 3000/4000)** + driver | video su GPU NVIDIA | Opzionale. Encoder NVENC (`hevc_nvenc`) con preset ad altissima qualità (`p7`, multipass fullres, spatial/temporal AQ) |
| **GPU Intel con Quick Sync** + driver | video su GPU Intel | Opzionale (ma consigliata). Su Windows usa D3D11, su Linux `/dev/dri/renderD128` |
| **ImageMagick 7** (comando `magick`) | foto | Deve avere la metrica `SSIM` |
| **exiftool** | opzionale | Rende molto più preciso il confronto dei metadati delle foto |

Puoi usare solo la parte video, solo la parte foto o solo la parte audio: le funzioni che mancano di dipendenze si disattivano da sole.

### 2.2 Installazione (Windows)

**Passo 1. Installa le dipendenze** (da PowerShell):

```powershell
winget install Gyan.FFmpeg
winget install ImageMagick.ImageMagick
winget install OliverBetz.ExifTool
```

Durante l'installazione di ImageMagick lascia spuntata l'opzione per aggiungere `magick` al PATH.

**Passo 2. Avvia lo script.** 
Metti `squeeze.ps1` in una cartella, sbloccalo con `Unblock-File` se necessario, poi avvialo:
```powershell
powershell -ExecutionPolicy Bypass -File "squeeze.ps1"
```

> Se modifichi lo script PS1 a mano, salvalo come **UTF-8 con BOM** per preservare gli accenti su PowerShell 5.1.

### 2.3 Installazione (Linux - Fedora 44)

**Passo 1. Installa i pacchetti tramite RPM Fusion** (serve per HEVC e libvmaf):

```bash
sudo dnf install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
sudo dnf install ffmpeg intel-media-driver ImageMagick perl-Image-ExifTool
```
*Nota: `intel-media-driver` abilita il supporto Quick Sync (iHD) tramite VA-API per le iGPU Arrow Lake / Intel Arc 140T. Per NVIDIA installare i driver proprietari `akmod-nvidia` con supporto NVENC.*

**Passo 2. Avvia lo script.**
Avvia semplicemente la versione Python, che non ha dipendenze PIP esterne (usa solo librerie standard):
```bash
chmod +x squeeze.py
./squeeze.py
```

---

## 3. Guida rapida (primo utilizzo)

Workflow consigliato, la prima volta che usi lo strumento su una nuova fotocamera:

1. **Avvia lo script** e controlla il box riepilogativo in alto: `Encoder` mostrerà il badge verde *GPU NVENC* (se hai una scheda NVIDIA), *GPU QSV* (se hai una GPU Intel) oppure il badge giallo *CPU x265*; `VMAF` e `Foto` mostreranno i rispettivi badge di stato.
2. **`[1]` Scegli cartella.** Premi Invio per aprire il selettore grafico cartelle nativo di sistema (oppure trascina la cartella o incollane il percorso).
3. **`[2]` Analizza.** Controlla codec, risoluzione, bitrate (video) e qualità stimata (foto). Serve a capire cosa stai per comprimere.
4. **Prova su pochi file.** Per i video puoi usare **`[11]`** (test comparativo su uno spezzone/clip con diversi valori CQ/CRF) oppure comprimere 2-3 clip con `[4]`. Per le foto usa `[9]` (test su una foto).
5. **Guarda i file di output a occhio.** In particolare i clip scuri, i cieli e le scene con molto movimento. Le metriche non vedono tutto (vedi [6.4](#64-limiti-delle-metriche)).
6. **Imposta i valori scelti** in `[6]` (o parti dal preset *Archivio*).
7. **Lancia sul lotto vero** con `[4]` (video) e/o `[7]` (foto).
8. **Controlla il riepilogo.** I file elencati in *DA CONTROLLARE* vanno esaminati: tieni l'originale per quelli.
9. **Cancella gli originali solo dopo** aver controllato a campione i risultati.

---

## 4. Il menu, voce per voce

```
╭──────────────────────────────────────────────────────────────────────────────╮
│                       S Q U E E Z E   •   Media Compressor                   │
│                  Video HEVC (NVENC/QSV/x265) • Foto • Audio                  │
├──────────────────────────────────────────────────────────────────────────────┤
│ Cartella   : [DIR]            C:\Media\Progetto                              │
│ Encoder    : [GPU NVENC]      NVIDIA NVENC (CQ 24, preset p7)                │
│ VMAF       : [OK]             Soglia 96 • Retry auto SI (1 frame ogni 5)     │
│ Foto       : [OK]             ImageMagick (Q90, SSIM 0.990, exiftool)        │
│ Audio      : [OK]             WAV/FLAC -> Opus 160 kb/s • Cover SI           │
├──────────────────────────────────────────────────────────────────────────────┤
│   CARTELLA E ANALISI                                                         │
│    [1] Scegli cartella sorgente (trascina o premi Invio per sfogliare)       │
│    [2] Analizza cartella (elenco video, foto e audio)                        │
│   VIDEO (HEVC + VMAF)                                                        │
│    [3] Comprimi VIDEO (solo compressione)                                    │
│    [4] Comprimi VIDEO + verifica VMAF + retry auto              *consigliato │
│    [5] Solo verifica VIDEO (output già presenti)                             │
│    [11] Test qualità su un VIDEO (confronto di più valori CQ/CRF)            │
│   FOTO (JPEG + SSIM)                                                         │
│    [7] Comprimi FOTO JPEG (+ verifica SSIM e metadati + retry)               │
│    [8] Solo verifica FOTO (output già presenti)                              │
│    [9] Test qualità su una FOTO (confronto di più valori Q)                  │
│   AUDIO (WAV/FLAC -> Opus)                                                   │
│    [10] Comprimi AUDIO (WAV/FLAC -> Opus con tag e copertina)                │
│   SISTEMA                                                                    │
│    [6] Impostazioni                                    [0] Salva ed esci     │
╰──────────────────────────────────────────────────────────────────────────────╯
```

| Voce | Cosa fa | Note |
|---|---|---|
| **1** | Imposta la cartella sorgente. | Viene ricordata alla prossima apertura. Accetta il trascinamento o, premendo Invio a vuoto, apre la finestra di dialogo grafica nativa (FolderBrowserDialog su Windows / Zenity, Kdialog o Tkinter su Linux). |
| **2** | Elenca i file trovati con i loro parametri. | Non modifica nulla. Mostra anche il profilo colore (`Trc`) dei video e i file audio. |
| **3** | Comprime i video senza verificare. | Più veloce, ma senza garanzia di qualità. |
| **4** | Comprime, misura il VMAF e ricodifica da solo i file sotto soglia. | La modalità normale. Mostra la barra di avanzamento dinamica. Un output già presente viene verificato, non rifatto. |
| **5** | Misura il VMAF di output già esistenti. | Utile per controllare file fatti in altro modo. |
| **11** | Test qualità su uno spezzone/clip video con più valori CQ/CRF. | Confronta dimensioni, percentuale di risparmio, bitrate e VMAF senza scrivere in `out`. |
| **6** | Menu impostazioni. | Vedi [sezione 5](#5-impostazioni-e-file-di-configurazione). |
| **7** | Comprime le foto JPEG, poi SSIM + metadati + retry. | Salta le foto già compresse almeno quanto il target. |
| **8** | Verifica SSIM e metadati di output foto già esistenti. | |
| **9** | Comprime **una** foto a più qualità e mostra dimensione, SSIM e metadati. | Usa una cartella temporanea che viene poi cancellata. Non scrive in `out`. |
| **10** | Converte i file **WAV/FLAC** in **Opus** nella cartella `opus`, copiando i tag e la copertina. | Vedi [7.3](#73-audio-wavflac-opus). |
| **0** | Salva la configurazione ed esce. | |

Prima di ogni lotto lo script mostra un riepilogo (numero file, encoder, qualità, cartella di output) e chiede **conferma** (`s`/`n`).

---

## 5. Impostazioni e file di configurazione

### 5.1 Menu impostazioni (`[6]`)

| Tasto | Impostazione | Default | Intervallo | Significato |
|---|---|---|---|---|
| `1` | Encoder | `auto` | auto / nvenc / qsv / x265 | `auto` prova in cascata: NVENC -> QSV -> x265 |
| `2` | Qualità NVENC (CQ) | 24 | 10-40 | Più basso = qualità più alta e file più grande |
| `3` | Preset NVENC | `p7` | p1...p7 | `p1` (più veloce) ... `p7` (massima qualità HQ) |
| `4` | Qualità QSV (`global_quality`) | 24 | 10-40 | Più basso = qualità più alta e file più grande |
| `5` | Qualità x265 (CRF) | 20 | 10-35 | Idem per x265 su CPU |
| `6` | Preset x265 | `medium` | ultrafast...slower | Più lento = file un po' più piccolo |
| `7` | Soglia VMAF | 96 | 80-99 | Sotto, il video viene rifatto |
| `8` | Precisione VMAF | 5 | 1-30 | Analizza 1 frame ogni N (1 = tutti, lentissimo) |
| `9` | Retry automatico | SI (max 2) | 1-5 tentativi | Rifà i file sotto soglia a qualità più alta |
| `G` | Qualità foto (JPEG) | 90 | 50-98 | Qualità di partenza per `magick -quality` |
| `H` | Soglia SSIM foto | 0.990 | 0.95-0.9999 | Sotto, la foto viene rifatta a Q più alta |
| `I` | JPEG progressivo | SI | SI/NO | File un po' più piccoli; compatibile con i browser e i social |
| `J` | Verifica foto | SI | SI/NO | SSIM + confronto metadati |
| `C` | Audio video | `auto` | auto / copy / aac | `auto`: PCM diventa AAC, il resto resta in copia |
| `D` | Bitrate AAC | 320 | 128-512 kb/s | Usato solo quando l'audio viene convertito |
| `K` | Bitrate Opus | 160 | 128-512 kb/s | Bitrate medio VBR della conversione audio (`[10]`) |
| `L` | Copertina audio | SI | SI/NO | Copia/estrae la copertina nella cartella `opus` |
| `A` | Includi sottocartelle | NO | SI/NO | Ricorsivo; mantiene la struttura in `out` |
| `B` | Sovrascrivi output | NO | SI/NO | Se NO, i file già in `out` non vengono rifatti |
| `M` | Conserva date file | SI | SI/NO | Copia data di creazione e modifica sull'output |
| `N` | Cartella output | `<sorgente>\out` | percorso | Vuoto = default |
| `E` | xvYCC → bt709 (Sony) | SI | SI/NO | Cambia solo l'etichetta del colore, non i pixel |
| `F` | Copia XML/SRT/XMP | SI | SI/NO | Copia i file affiancati al video/foto |
| `P` | Preset rapidi | | | Vedi sotto |

### 5.2 Preset rapidi (`P`)

| Preset | NVENC CQ | QSV | x265 CRF | Soglia VMAF | Foto Q | Soglia SSIM |
|---|---|---|---|---|---|---|
| **Sicuro** | 21 | 21 | 18 | 97 | 93 | 0.993 |
| **Archivio** (consigliato) | 24 | 24 | 20 | 96 | 90 | 0.990 |
| **Compatto** | 27 | 27 | 22 | 95 | 85 | 0.985 |

I preset non toccano le altre impostazioni (audio, sottocartelle, ecc.).

### 5.3 File `squeeze.config.json`

Viene creato accanto allo script e riscritto a ogni modifica. Puoi editarlo a mano (con lo script chiuso). Chiavi e valori di default:

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

`Extensions`, `PhotoExtensions`, `SidecarExts`, `OpusExtensions`, `OpusCoverNames` e `OpusCoverExts` si cambiano solo da qui. Per tornare ai default, elimina il file.

> **Migrazione dal vecchio nome.** Se accanto allo script esiste ancora `dji-compress.config.json` e non esiste `squeeze.config.json`, le impostazioni vengono lette dal vecchio file e riscritte automaticamente come `squeeze.config.json`.

---

## 6. Come scegliere la qualità

### 6.1 Video

La scala `CQ` (NVENC), `global_quality` (QSV) e `CRF` (x265) **non sono identiche tra loro**: i numeri hanno comportamenti e scale leggermente differenti a seconda dell'architettura dell'encoder, sebbene NVENC CQ e QSV global_quality si attestino su intervalli pratici comparabili. Esempio misurato su un clip DJI di 8 secondi (originale 45,3 MiB, 43,6 Mbps):

| QSV `global_quality` | Dimensione | Risparmio | VMAF |
|---|---|---|---|
| 21 | 18,8 MiB | -59% | 99,73 |
| 24 | 12,1 MiB | -73% | 98,78 |
| 27 | 7,8 MiB | -83% | 96,68 |
| 30 | 5,2 MiB | -89% | 93,20 |
| 33 | 3,5 MiB | -92% | 87,07 |

Regole pratiche per il VMAF:

- **Sopra circa 95**: differenza di solito impercettibile.
- **97-98 o più**: quasi indistinguibile anche in confronto affiancato.
- **Sotto 93-94**: la differenza può diventare visibile.

Consigli:

- **Archivio** (NVENC CQ 24 / QSV 24, soglia 96) è un eccellente punto di partenza.
- **NVENC CQ 27 (o QSV 27) con retry attivo** massimizza il risparmio: i clip facili restano leggeri a 27, quelli complessi vengono ricodificati a 24 o 21 in automatico.
- Un clip che viene ricodificato dal retry di solito ha poca luce, rumore o molto dettaglio: guardalo a occhio.

### 6.2 Test rapido video ([11])

Se vuoi testare l'encoder e i valori di qualità prima di avviare un intero lotto, usa la voce **`[11] Test qualità su un VIDEO`**. Permette di:
1. Scegliere uno dei video presenti nella cartella sorgente.
2. Scegliere se testare l'intero clip o uno spezzone breve (es. 10 secondi a partire da un offset desiderato, molto veloce per test iterativi).
3. Specificare una serie di valori di qualità da confrontare (es. `21, 24, 27, 30` per NVENC/QSV o `18, 20, 22` per x265).
4. Generare una tabella riassuntiva con dimensione, risparmio %, bitrate risultante, punteggio VMAF e velocità di codifica (fps).
I file generati sono temporanei e vengono cancellati al termine del test senza toccare la cartella `out`.

### 6.3 Foto

Il test `[9]` mostra una tabella come questa (valori di esempio, non reali):

```
Quality   MB  Risparmio  SSIM    Metadati
     85  3.1  60%        0.9890  OK (118)
     90  4.2  46%        0.9930  OK (118)
     95  7.0  10%        0.9985  OK (118)
```

Scegli la **qualità più bassa con SSIM sopra la tua soglia e metadati OK**, poi impostala in `[6]` → `G` e la soglia in `H`.

- Le soglie di default (Q90 / SSIM 0.990) **non sono calibrate su foto reali**: fai il test su una tua foto.
- Le foto già salvate a una qualità pari o inferiore al target vengono **saltate** (`GIA COMPRESSA`): ricomprimerle aggiungerebbe solo perdita. Per forzarle abbassa la qualità in `G`.
- Ricomprimere un JPEG è **sempre** una perdita tecnica, anche se non si vede. Se vuoi zero perdita, serve un ottimizzatore lossless (es. `jpegtran`), che questo strumento non include.

### 6.4 Limiti delle metriche

VMAF e SSIM sono **medie** e non vedono bene alcuni difetti localizzati: *banding* nei cieli, rumore nelle zone scure, piccoli dettagli. Per questo conviene controllare a occhio almeno un file scuro e uno con molto movimento prima di cancellare gli originali.

---

## 7. Cosa viene conservato e cosa si perde

### 7.1 Video

| Elemento | Esito |
|---|---|
| Risoluzione, frame rate | Invariati |
| Audio AAC (DJI) | **Copiato identico** |
| Audio PCM (Sony) | Convertito in **AAC 320 kb/s** (modalità `auto`); `copy` lo lascia identico |
| Data di creazione, tag generali del file | Conservati (`-map_metadata 0`) |
| Date del file (creazione/modifica) | Copiate sull'output |
| Tag colore (primari, trasferimento, matrice, range) | Copiati dall'originale. Eccezione: *xvYCC* → *bt709* (opzione `E`, solo etichetta) |
| Traccia timecode QuickTime (DJI) | Osservata nell'output nei test con DJI |
| File affiancati `.XML`, `.SRT`, `.XMP` | Copiati in `out` |
| **Tracce dati DJI** (`djmd`, `dbgi`) | **Persi**: il muxer MP4 di ffmpeg non le accetta |
| **Metadati Sony `rtmd`** (ISO, otturatore, diaframma frame per frame) | **Persi** |
| Copertina JPEG incorporata | Non copiata (si prende solo il video vero) |

Se ti servono i dati giroscopio (per Gyroflow) o i metadati Sony per un clip, **tieni l'originale** di quel clip.

### 7.2 Foto

| Elemento | Esito |
|---|---|
| Risoluzione | Invariata |
| Sottocampionamento del colore (es. 4:2:2) | Mantenuto uguale all'originale |
| EXIF, ICC, XMP, IPTC | Conservati da ImageMagick (nessuno `-strip`) |
| Verifica metadati | Con **exiftool**: confronto di tutti i tag; senza: solo i tag EXIF letti da ImageMagick |
| Date del file | Copiate sull'output |
| **Anteprima MPF** (immagine 1920x1080 incorporata dalle Sony) | **Persa** |
| MakerNote Sony | Non verificato su file reali Sony: guarda la colonna *Metadati* nel test `[9]` |

### 7.3 Audio (WAV/FLAC → Opus)

La voce `[10]` converte i file **WAV** e **FLAC** in **Opus** (contenitore Ogg, codec `libopus`), scrivendo nella cartella `<sorgente>\opus` (con sottocartelle replicate se *Includi sottocartelle* è attivo). L'audio è sempre ricodificato; il bitrate medio è quello scelto in `[6]` → `K` (default 160 kb/s, minimo 128), in modalità VBR.

**Metadati.** I tag vengono letti direttamente dal file sorgente e riscritti pari-pari nell'Opus:

| Elemento | Esito |
|---|---|
| Tag FLAC (commenti Vorbis: `TITLE`, `ALBUM`, `DATE`, `GENRE`, `TRACKNUMBER`, ecc.) | Copiati identici (nome e valore) |
| Tag WAV (chunk RIFF `LIST/INFO`: `IART`, `INAM`, `IPRD`, ...) | Copiati con il nome Vorbis standard (`ARTIST`, `TITLE`, `ALBUM`, ...) |
| **Artisti multipli** (più commenti `ARTIST`) | Conservati come **tag `ARTIST` separati** |
| **`ARTIST` unico con `;`** (es. `A; B`) | Diviso in più tag `ARTIST` separati |
| Copertina incorporata (`METADATA_BLOCK_PICTURE`/`COVERART`) | **Non** incorporata nell'Opus: salvata come file (vedi sotto) |
| Ordine e duplicati degli altri tag | Preservati |

> **Perché non basta ffmpeg da solo:** ffmpeg unisce più tag `ARTIST` in un unico campo `A;B` e non sa scrivere tag duplicati. Per questo lo script riscrive a mano l'header dei commenti Ogg dell'Opus (ricalcolando i CRC delle pagine), così gli artisti restano separati.

**Copertina.** Opus non incorpora in modo affidabile le copertine, quindi (con `L` attivo) lo script, per ogni cartella elaborata:

1. cerca un file immagine nella cartella sorgente con nome `cover`, `folder`, `front` o `album` e estensione `.jpg`/`.jpeg`/`.png`, e lo copia nella cartella di destinazione `opus` mantenendo il nome;
2. se non lo trova, **estrae** la copertina incorporata da uno dei file FLAC della cartella e la salva come `cover.jpg` (o `.png`);
3. se non trova nulla, non crea nessun file.

Se nella cartella `opus` esiste già una copertina, non viene sovrascritta.

---

## 8. Output, log e stati

### 8.1 Dove finiscono i file

- Cartella di output: `<sorgente>\out` (cambiabile con `B`); l'**audio** va sempre in `<sorgente>\opus`.
- Con **sottocartelle** attive, la struttura viene replicata in `out` (e in `opus`).
- I file nella cartella di output **non** vengono rielaborati (né quelli in `opus`).
- Nomi e estensioni restano gli stessi (per l'audio il nome resta, l'estensione diventa `.opus`).

### 8.2 Log CSV

A fine lotto viene creato in `out\`:

- `log_video_AAAAMMGG_HHMMSS.csv`
- `log_photo_AAAAMMGG_HHMMSS.csv`
- `log_audio_AAAAMMGG_HHMMSS.csv`

Colonne video: `File, InMB, OutMB, Saved, Quality, VMAF, Audio, Status`. Colonne foto: `File, InMB, OutMB, Saved, Quality, SSIM, Meta, Status`. Colonne audio: `File, InMB, OutMB, Saved, Bitrate, Tags, Cover, Status`. `Saved` è la percentuale risparmiata; `Tags` è il numero di tag scritti, `Cover` l'esito della copertina (`copiata`/`estratta`/`presente`/`-`).

### 8.3 Stati

| Stato | Significato | Cosa fare |
|---|---|---|
| `OK` | Sopra soglia (e metadati foto a posto) | Nulla |
| `COMPRESSO (non verificato)` | Fatto senza verifica | Verifica con `[5]`/`[8]` se serve |
| `SOTTO SOGLIA` | Anche dopo i retry, qualità sotto la soglia | Tieni l'originale o alza la qualità |
| `CONTROLLA METADATI` | Foto: mancano tag rispetto all'originale | Tieni l'originale |
| `SALTATO: output piu grande` | L'output pesava più dell'originale: scartato | Il file era già molto compresso |
| `GIA COMPRESSA (Q~N)` | Foto già a qualità ≤ target | Abbassa la qualità in `G` per forzare |
| `ESISTENTE` | Output già presente (modalità solo compressione) | Attiva `Sovrascrivi` per rifarlo |
| `MANCA OUTPUT` | In verifica: nessun output corrispondente | Comprimi prima il file |
| `VMAF non letto` / `SSIM non letto` | La misura non ha restituito un numero | Vedi [sezione 10](#10-risoluzione-dei-problemi) |
| `VERIFICA DISATTIVATA` | Foto: verifica spenta in `J` | Riattivala |
| `ERRORE ...` | ffmpeg/magick falliti o file non leggibile | Controlla il file con `[2]` |

Nelle modalità `[4]` e `[7]`, un output **già presente** non viene ricodificato ma viene **verificato**; il retry parte solo per i file codificati in quella esecuzione.

La conversione audio `[10]` non ha verifica di qualità: gli stati sono `OK`, `ESISTENTE` (file già in `opus`, salvo `Sovrascrivi`), `SALTATO: output piu grande` (Opus più grande della sorgente, es. FLAC molto comprimibile) e `ERRORE ffmpeg`.

---

## 9. Documentazione tecnica

> 📘 Per una trattazione approfondita sull'architettura interna, la matematica del CRC-32 Ogg, la scala di fallback degli encoder e la preservazione del campionamento croma, consulta la **[Guida Tecnica Approfondita (TECHNICAL.md)](TECHNICAL.md)** (o in inglese: **[TECHNICAL_EN.md](TECHNICAL_EN.md)**).

### 9.1 Struttura del codice

Un solo file `.ps1` (o `.py` su Linux), organizzato in sezioni:

| Sezione | Funzioni principali |
|---|---|
| Configurazione | `Import-Config`, `Save-Config` (JSON accanto allo script) |
| Utilità e TUI | `Write-BoxTop`, `Write-BoxLine`, `Write-BoxBadgedLine`, `Write-CenteredProgress`, `Read-BoxPrompt`, `Read-Default`, `Read-IntRange`, `Get-OutDir` |
| Controllo strumenti | `Test-Tools`, `Resolve-Encoder` (cascata NVENC -> QSV -> x265) |
| Analisi | `Get-VideoInfo`, `Get-ColorArgs`, `Test-AudioToAac`, `Get-MediaFiles`, `Copy-Sidecars` |
| Video | `Invoke-Encode`, `Measure-Vmaf`, `Invoke-VideoJob` |
| Foto | `Get-PhotoInfo`, `Invoke-PhotoEncode`, `Measure-Ssim`, `Test-PhotoMetadata`, `Invoke-PhotoJob` |
| Audio | `Get-FlacComments`, `Get-RiffInfoComments`, `Get-OpusComments`, `Set-OpusTags`, `Set-AudioCover`, `Invoke-AudioJob` |
| Lotti e Menu | `Start-Batch`, `Show-Scan`, `Show-VideoTest`, `Show-PhotoTest`, `Select-Folder`, `Show-SettingsMenu`, `Show-MainMenu` |

### 9.2 Rilevamento degli strumenti (`Test-Tools`)

1. Cerca `ffmpeg` e `ffprobe` nel PATH.
2. Cerca `magick` nel PATH; se manca prova `C:\Program Files\ImageMagick*\magick.exe`.
3. Se non trova **nessuno** dei due gruppi, esce con errore.
4. Legge gli encoder (`hevc_nvenc`, `hevc_qsv`, `libx265`) e i filtri (`libvmaf`, `libopus`) di ffmpeg.
5. **Prova reale di NVENC**: codifica 0,2 secondi di un colore fisso in formato 10-bit con `hevc_nvenc -profile:v main10`. Se il comando fallisce (es. driver NVIDIA non presente o GPU non compatibile), disattiva NVENC.
6. **Prova reale di QSV**: codifica 0,2 secondi con `hevc_qsv`. Conta il risultato reale dell'esecuzione, non solo la presenza nel PATH.
7. Controlla se ImageMagick elenca la metrica `SSIM` e se esiste `exiftool`.

### 9.3 Pipeline video (`Invoke-VideoJob`)

1. `ffprobe` legge codec, formato pixel, risoluzione, fps, tag colore, codec e canali audio.
2. Scelta della qualità di partenza (NVENC CQ, QSV o CRF).
3. Se l'output esiste e `Sovrascrivi` è spento: niente ricodifica.
4. Codifica in `<file>.part`, poi `Move-Item` sul nome finale solo se ffmpeg termina con codice 0.
5. In modalità verifica: VMAF contro l'originale; se sotto soglia e il retry è attivo, ricodifica con qualità più alta:
   - **NVENC**: -3 CQ per tentativo, minimo 14.
   - **QSV**: -3 per tentativo, minimo 15.
   - **x265**: -2 CRF per tentativo, minimo 12.
6. Se l'output pesa quanto o più dell'originale, viene eliminato.
7. Copia di date file e file affiancati.

**Comando ffmpeg equivalente (NVIDIA NVENC, sorgente 10 bit, preset HQ):**

```powershell
ffmpeg -hide_banner -loglevel error -stats -y `
  -hwaccel cuda -hwaccel_output_format cuda -i INPUT.MP4 `
  -map 0:V:0 -map 0:a? -dn -map_metadata 0 `
  -c:v hevc_nvenc -profile:v main10 -preset p7 -tune hq -multipass fullres `
  -rc vbr -cq 24 -b:v 0 -rc-lookahead 32 -spatial-aq 1 -temporal-aq 1 `
  -movflags use_metadata_tags+faststart -tag:v hvc1 `
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv `
  -c:a copy -f mp4 INPUT_OUT.MP4.part
```

**Comando ffmpeg equivalente (QSV, sorgente 10 bit):**

```powershell
ffmpeg -hide_banner -loglevel error -stats -y `
  -hwaccel qsv -hwaccel_output_format qsv -i INPUT.MP4 `
  -map 0:V:0 -map 0:a? -dn -map_metadata 0 `
  -c:v hevc_qsv -profile:v main10 -preset veryslow -global_quality 24 -look_ahead 1 `
  -movflags use_metadata_tags+faststart -tag:v hvc1 `
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv `
  -c:a copy -f mp4 INPUT_OUT.MP4.part
```

**Opzioni importanti:**

| Opzione | Perché c'è |
|---|---|
| `-map 0:V:0` | Prende solo il video vero (la `V` maiuscola esclude la copertina JPEG, che sarebbe ricodificata come video) |
| `-map 0:a?` | Tutte le tracce audio; il `?` evita l'errore sui clip senza audio |
| `-dn` | Esclude le tracce dati proprietarie, che il muxer MP4 rifiuta (errore "codec none") |
| `-map_metadata 0` + `use_metadata_tags` | Conserva i tag globali |
| `-tag:v hvc1` | Compatibilità con Apple e molti player |
| `faststart` | Sposta l'indice all'inizio: partenza più rapida in streaming |
| tag colore | Letti da `ffprobe` e copiati, **non** forzati: D-Log e HLG restano corretti |

**Percorsi di codifica NVENC (fallback a 3 livelli):**

1. Livello 1: decodifica CUDA completa in GPU (`-hwaccel cuda -hwaccel_output_format cuda`) con opzioni avanzate HQ (`-multipass fullres`, `-spatial-aq 1`, `-temporal-aq 1`, `-rc-lookahead 32`). Se il clip è 4:2:2/4:4:4, questo livello viene saltato.
2. Livello 2: decodifica software su CPU + `-vf format=p010le` (o `format=nv12`) e codifica NVENC HQ su GPU.
3. Livello 3: decodifica software e codifica NVENC senza filtri AQ avanzati (safe mode per build o schede con limitazioni).

**Percorsi di codifica QSV (fallback automatico):**

1. Decodifica e codifica interamente su GPU (`-hwaccel qsv -hwaccel_output_format qsv`).
2. Se fallisce: decodifica software + `-vf format=p010le` (10 bit) o `format=nv12` (8 bit) e codifica QSV.
3. Se la sorgente è **4:2:2 o 4:4:4** (es. Sony XAVC HS): il passo 1 viene saltato e il file viene convertito a 4:2:0.

**x265:** `-c:v libx265 -preset <preset> -crf <N> -pix_fmt <formato> -x265-params log-level=error`. Il formato pixel segue la sorgente (4:2:2/4:4:4 → 4:2:0).

**Audio (`Test-AudioToAac`):** in modalità `auto` converte in AAC solo se il codec inizia per `pcm` e i canali sono 1, 2 o 6; altrimenti copia. Con `aac` converte sempre (stessa limitazione sui canali); con `copy` non converte mai. Comando usato: `-c:a aac -b:a <N>k`.

**Contenitore:** `.mov` → `-f mov`, tutto il resto `-f mp4`.

### 9.4 Misura VMAF (`Measure-Vmaf`)

```powershell
ffmpeg -hide_banner -nostats -hwaccel cuda -i COMPRESSO -hwaccel cuda -i ORIGINALE `
  -lavfi "[0:v:0][1:v:0]libvmaf=n_threads=<core>:n_subsample=<N>" -an -sn -dn -f null -
```

- Primo input = compresso (*distorted*), secondo = originale (*reference*).
- Supporta accelerazione decodifica a cascata: se l'encoder è NVENC prova prima `-hwaccel cuda`; se l'encoder è QSV o CUDA non risponde prova `-hwaccel qsv`; infine ricorre alla decodifica software su CPU.
- Il numero viene letto dalla riga `VMAF score: ...`.
- `n_subsample=5` analizza un frame ogni cinque: molto più veloce e sufficiente per individuare i file problematici.
- Supporta un parametro opzionale di durata (usato da `[11]` per test rapidi su spezzoni).

### 9.5 Pipeline foto (`Invoke-PhotoJob`)

1. `magick identify -format "%w|%h|%Q|%[jpeg:sampling-factor]"` ricava dimensioni, **qualità stimata** e sottocampionamento.
2. Se la qualità stimata è ≤ al target, la foto è saltata (`GIA COMPRESSA`).
3. Codifica:

```powershell
magick INPUT.JPG -quality 90 -sampling-factor 2x1 -interlace JPEG `
  -define jpeg:optimize-coding=true JPEG:OUTPUT.JPG.part
```

   - `-sampling-factor` esplicito: senza, ImageMagick passerebbe a 4:4:4 per qualità ≥ 90 e i file crescerebbero.
   - Nessun `-strip` e nessun `-auto-orient`: EXIF e orientamento restano come nell'originale.
   - `JPEG:` forza il formato anche sul file `.part`.
4. **SSIM**: `magick compare -metric SSIM COMPRESSA ORIGINALE null:`.
5. Se SSIM è sotto soglia e il retry è attivo: nuova codifica con Q+3 (massimo 98), fino a `MaxRetries`.
6. **Metadati** (`Test-PhotoMetadata`):
   - con `exiftool`: elenco di tutti i tag (`-a -u -G1 -s`) escludendo i gruppi `System`, `File`, `ExifTool`, `Composite`, `JFIF`, `MPF*`; conta quelli dell'originale che mancano nell'output;
   - senza `exiftool`: confronta le righe `%[EXIF:*]` lette da ImageMagick (tag EXIF standard, **non** il MakerNote).
7. Dimensione, date e file affiancati come per i video.

**Nota sull'output di SSIM:** le versioni recenti di ImageMagick 7 stampano `<valore> (<distanza>)`, dove la distanza è `(1 - SSIM) / 2` (0 = identico). Lo script la converte con `SSIM = 1 - 2 × distanza`. Se la tua versione stampa un solo numero, lo usa direttamente come SSIM.

### 9.6 Pipeline audio (`Invoke-AudioJob`)

1. **Lettura dei tag** dal file sorgente, senza passare dal dizionario di ffmpeg:
   - **FLAC**: parsing del blocco `VORBIS_COMMENT` (vendor + elenco commenti), che conserva ordine e duplicati;
   - **WAV**: parsing dei chunk `RIFF`, in particolare `LIST`→`INFO`, con mappatura delle chiavi 4 caratteri su quelle Vorbis (`IART`→`ARTIST`, `INAM`→`TITLE`, ...);
   - fallback: se il parsing nativo non trova nulla, si usano i tag letti da `ffprobe`.
2. **Normalizzazione artisti** (`Get-OpusComments`): scarta i tag copertina e divide un singolo `ARTIST` che contiene `;` in più tag `ARTIST` separati.
3. **Codifica**:

```powershell
ffmpeg -hide_banner -loglevel error -stats -y -i INPUT.FLAC `
  -map 0:a:0 -vn -map_metadata -1 `
  -c:a libopus -b:a 160k -vbr on -application audio -f opus OUTPUT.OPUS.part
```

   - `-vn` esclude eventuali copertine incorporate; `-map_metadata -1` scrive l'Opus **senza** tag (li mettiamo noi al passo successivo).
4. **Scrittura dei tag** (`Set-OpusTags`): si legge il pacchetto `OpusTags` generato da ffmpeg (riusandone l'id venditore), si costruisce il nuovo pacchetto Vorbis comment con i nostri tag e si **sostituisce la pagina Ogg** corrispondente, ricalcolando lacing, numeri di sequenza e **CRC-32** delle pagine (polinomio `0x04C11DB7`, come da specifica Ogg). Se il pacchetto cresce oltre una pagina, le pagine successive vengono rinumerate.

   Questo è ciò che permette i tag `ARTIST` multipli, cosa che ffmpeg da solo non fa.
5. **Copertina** (`Set-AudioCover`): copia il file affiancato (`cover`/`folder`/`front`/`album`) oppure estrae la picture incorporata con:

```powershell
ffmpeg -hide_banner -loglevel error -y -i INPUT.FLAC -map 0:v:0 -c copy cover.jpg
```

6. **Dimensioni e date**: se l'Opus risulta più grande della sorgente viene scartato; con *Conserva date* le date del file vengono copiate.

### 9.7 Sicurezza dei dati

- **Mai scritture sugli originali.** L'unica cosa che lo script cancella è un proprio output scartato o un `.part` interrotto.
- **File parziali:** scrittura su `.part` + `finally` che lo rimuove in caso di errore o Ctrl+C. Nessun file a metà viene scambiato per completo.
- **Output più grande dell'originale:** eliminato.
- **Prima sovrascrittura:** solo se l'opzione `Sovrascrivi` è attiva.

### 9.8 Note sull'implementazione

- `$ErrorActionPreference = 'Continue'`: con `Stop`, PowerShell 5.1 trasforma l'output su stderr dei programmi nativi in errori bloccanti.
- Tutte le tabelle usano `Out-String -Width 220`: senza, in alcuni terminali risultavano vuote.
- I numeri vengono letti con `CultureInfo.InvariantCulture`, per evitare problemi con la virgola decimale dei sistemi italiani.
- Gli argomenti dei comandi esterni sono passati come array (splatting), così i percorsi con spazi non richiedono escaping manuale.
- Il tag `[0]` in `magick identify "file[0]"` limita la lettura al primo frame.

---

## 10. Risoluzione dei problemi

| Sintomo | Causa probabile | Soluzione |
|---|---|---|
| `ERRORE: né ffmpeg né ImageMagick trovati` | PATH non aggiornato | Chiudi e riapri il terminale; verifica con `ffmpeg -version` e `magick -version` |
| Lo script non parte / "esecuzione di script disabilitata" | Execution Policy | Avvia con `powershell -ExecutionPolicy Bypass -File ...` e usa `Unblock-File` |
| Gli accenti compaiono rovinati | Script salvato senza BOM | Salvalo come UTF-8 con BOM |
| Encoder: *x265 (CPU)* invece di QSV | QSV non disponibile | Aggiorna i driver Intel Graphics; verifica `hevc_qsv` con il Passo 2 di [2.2](#22-installazione-windows) |
| Video molto lenti (circa 2-3 fps) | Si sta usando x265 su CPU | Come sopra, oppure alza il preset a `fast`/`veryfast` |
| `VMAF: NON disponibile` | Build ffmpeg senza `libvmaf` | Installa una build *full* (gyan.dev o `Gyan.FFmpeg`) |
| `VMAF non letto` | Misura fallita (formati diversi, file corrotto) | Prova `ffmpeg -i out.mp4 -i orig.mp4 -lavfi libvmaf -f null -` a mano e guarda l'errore |
| `ERRORE ffmpeg` su DJI con errore "codec none" | Tracce dati DJI nel mux | Già gestito da `-dn`: se lo vedi, stai usando un comando manuale senza `-dn` |
| Foto: *ImageMagick NON trovato* | `magick` non nel PATH | Reinstalla con l'opzione PATH oppure installa in `C:\Program Files\ImageMagick*` |
| Foto: `SSIM non letto` | ImageMagick senza metrica SSIM o errore di lettura | `magick -list metric` deve mostrare `SSIM`; aggiorna a ImageMagick 7 recente |
| Foto: `GIA COMPRESSA` per tutte | Qualità stimata ≤ target | Abbassa la qualità in `G` (es. 85) o usa `[9]` per valutare |
| Foto: `CONTROLLA METADATI` / `MANCANO n/N` | Tag non presenti nell'output | Tieni l'originale; con `exiftool` installato vedi quali tag mancano |
| Foto: `SOTTO SOGLIA` anche dopo i retry | Foto molto dettagliata/rumorosa o soglia troppo alta | Alza `G`, abbassa `H`, o tieni l'originale |
| `SALTATO: output piu grande` | File già molto compresso | Normale: tieni l'originale |
| Tabelle vuote o storte | Terminale senza larghezza | Allarga la finestra; lo script usa già una larghezza fissa |
| Errore con file dal nome strano | Caratteri speciali nel nome | Rinominalo; `[ ]` finali nel nome file confondono ImageMagick |
| Output già presente non viene rifatto | Comportamento previsto | Attiva `Sovrascrivi` (`9`) oppure cancella l'output |
| Audio: `libopus NON disponibile` | Build ffmpeg senza `libopus` | Installa una build *full* (gyan.dev o `Gyan.FFmpeg`) |
| Audio: `SALTATO: output piu grande` | FLAC molto comprimibile (es. toni/rumore) | Normale: tieni il FLAC, oppure abbassa il bitrate in `K` |
| Audio: gli artisti restano uniti | Il tag non usa `;` né più commenti `ARTIST` | La divisione avviene solo su `;`: sistema i tag alla fonte |
| Audio: copertina assente nell'`opus` | Nessun file affiancato né picture nel FLAC | Aggiungi `cover.jpg` nella cartella sorgente, oppure attiva `L` |
| Audio: `Tags: non scritti` | Scrittura dei commenti Ogg fallita | Il file resta valido ma senza tag: controlla la build di ffmpeg |

---

## 11. Limiti noti e stato dei test

### 11.1 Limiti

- **Tracce dati DJI e `rtmd` Sony non conservabili** con ffmpeg (vedi [7.1](#71-video)).
- **MPF Sony** perso nelle foto.
- **Solo JPEG** per le foto: RAW (`.ARW`) e HEIF non vengono toccati.
- **Output video sempre HEVC.** È ben supportato (WhatsApp e Instagram su telefoni recenti, Apple, Android), ma non posso garantire ogni app e versione. Non c'è una modalità H.264.
- **La compressione JPEG→JPEG è sempre con perdita.** Qui è controllata, ma non è lossless.
- **Un processo alla volta.** Non c'è parallelismo tra file (la GPU lavora, poi la CPU calcola VMAF/SSIM).
- **Le metriche non sono onniscienti** (vedi [6.4](#64-limiti-delle-metriche)).
- **Audio: la conversione è con perdita.** Da WAV/FLAC a Opus il contenuto cambia (a 128+ kb/s è di norma trasparente, ma non è lossless).
- **Audio: solo WAV e FLAC in ingresso.** Non vengono toccati MP3, M4A, OGG, Opus, ecc.
- **WAV: metadati limitati.** Si leggono solo i chunk `RIFF/INFO` (con fallback `ffprobe`); eventuali tag ID3v2 dentro il WAV non sono gestiti e il WAV non ha un concetto di artisti multipli.
- **La copertina non viene incorporata nell'Opus** (di proposito): resta un file immagine nella cartella `opus`.
- **La divisione degli artisti avviene solo sul `;`** o da più commenti `ARTIST`; non vengono interpretati altri separatori (`&`, `,`, `feat.`).
- **Audio senza verifica di qualità:** non esiste una metrica equivalente a VMAF/SSIM, quindi non c'è retry automatico.

### 11.2 Cosa è stato verificato

| Parte | Verifica |
|---|---|
| Pipeline video DJI e Sony con QSV e VMAF | Eseguita sulla macchina dell'utente (Windows, Intel Core Ultra 7 255H / Arc 140T, ffmpeg 9.0.1): risultati e log reali |
| Conversione audio PCM → AAC, 4:2:2 → 4:2:0, copia XML | Provati su clip sintetici (Linux, x265) |
| Pipeline foto (encode, sottocampionamento, progressivo, retry, metadati, SSIM, test `[9]`) | Provata su una foto **sintetica** con ImageMagick 7.1.2 su Linux |
| Parte foto su **Windows PowerShell 5.1** e su foto **reali Sony** | **Non ancora verificata** |
| Soglie foto di default (Q90, SSIM 0.990) | **Non calibrate** su foto reali |
| Decodifica GPU nella misura VMAF | Non provata (nel mio ambiente non c'è QSV); è presente un fallback in software |
| Conversione audio WAV/FLAC → Opus (tag, artisti multipli, copertina, CRC Ogg) | Provata su file sintetici con ffmpeg 9.0.1 (Windows) e Python: tag multipli separati, copertina copiata/estratta, file decodificabile, CRC delle pagine valido |
| Conversione audio su **album reali** (vari tagger/formati) | **Non ancora verificata**: riporta eventuali tag mancanti o copertine non trovate |

Se qualcosa non va, riporta il messaggio mostrato a schermo (o la riga del log CSV): è il modo più rapido per correggere.

---

## 12. FAQ

**Posso cancellare gli originali dopo la compressione?**
Solo dopo aver controllato a occhio qualche file (soprattutto i più scuri/difficili) e il riepilogo *DA CONTROLLARE*. Per i video da stabilizzare con Gyroflow tieni gli originali.

**Quanto spazio risparmio?**
Dipende dalla sorgente e dalla scena. Sorgenti H.264 ad alto bitrate (Sony) arrivano facilmente al -75/-85%; sorgenti HEVC già efficienti (DJI) al -50/-70%.

**Perché la GPU e non la CPU?**
Su GPU Intel un clip passa da circa 2,4 fps (x265 `slow`) a oltre 100 fps. A parità di qualità percepita x265 può dare file leggermente più piccoli, ma impiega ore invece di minuti. Per un archivio da lasciare in elaborazione di notte, x265 resta un'opzione valida.

**Il file "sembra uguale", perché la qualità conta?**
Perché ricodificare accumula perdita: una compressione moderata è invisibile, ma più passaggi successivi no. Comprimi **dall'originale**, mai da un file già compresso.

**Posso comprimere due volte lo stesso file?**
Sconsigliato. Lo script salta le foto già a bassa qualità, ma per i video non c'è un controllo equivalente: parti sempre dagli originali.

**Funziona con altre fotocamere (GoPro, iPhone...)?**
Per i video probabilmente sì, se il contenitore è MP4/MOV; le tracce dati proprietarie vengono comunque escluse. Per le foto, qualunque JPEG. Non è stato testato su altri modelli.

**Come ripristino i valori di default?**
Elimina `squeeze.config.json` accanto allo script.

**Posso lanciarlo su una cartella di rete o su un disco esterno?**
Sì, ma la velocità dipende dal disco. Meglio lavorare su un SSD locale e spostare i risultati dopo.

---

## 13. Personalizzare lo script

| Cosa | Dove |
|---|---|
| Aggiungere estensioni video/foto/audio/file affiancati | `Extensions`, `PhotoExtensions`, `OpusExtensions`, `SidecarExts` in `squeeze.config.json` |
| Cambiare i nomi/estensioni cercati per la copertina audio | `OpusCoverNames`, `OpusCoverExts` in `squeeze.config.json` |
| Cambiare il separatore degli artisti | Ramo `ARTIST` in `Get-OpusComments` (PowerShell) / `get_opus_comments` (Python) |
| Cambiare i parametri dell'encoder QSV | Funzione `Invoke-Encode`, variabile `$venc` nel ramo `qsv` |
| Cambiare l'incremento dei retry | Variabili `$qStep` / `$qMin` in `Invoke-VideoJob`, `$newQ = $q + 3` in `Invoke-PhotoJob` |
| Usare un altro formato audio | Variabile `$audio` in `Invoke-Encode` |
| Aggiungere un preset | Blocco `'P'` in `Show-SettingsMenu` |
| Più o meno precisione del confronto metadati | `Get-ExifToolKeys` (gruppi esclusi nella regex) |

Se modifichi lo script, salvalo come UTF-8 con BOM e ricontrolla la sintassi con:

```powershell
$e = $null; $t = $null
[void][System.Management.Automation.Language.Parser]::ParseFile("squeeze.ps1", [ref]$t, [ref]$e)
if ($e) { $e | ForEach-Object { $_.Message } } else { "PARSE OK" }
```

---

## 14. Glossario

| Termine | Significato |
|---|---|
| **HEVC / H.265** | Codec video moderno, circa il doppio di efficienza rispetto a H.264 |
| **AVC / H.264** | Codec video diffuso (usato dalla Sony nel tuo caso) |
| **NVENC** | Encoder video hardware su GPU NVIDIA (GeForce RTX / Quadro) |
| **QSV (Quick Sync Video)** | Encoder/decoder hardware nelle GPU Intel |
| **x265** | Encoder HEVC software (CPU): lento ma molto efficiente |
| **CQ** | *Constant Quality*: parametro di qualità costante per NVENC (più basso = migliore qualità) |
| **CRF** | *Constant Rate Factor*: qualità costante di x265 (più basso = migliore) |
| **global_quality** | Equivalente del CRF per QSV (modalità ICQ) |
| **Bitrate** | Dati al secondo di video (Mbps); più alto = file più grande |
| **VMAF** | Metrica di qualità video (0-100) sviluppata da Netflix; ~95+ = differenza impercettibile |
| **SSIM** | Metrica di somiglianza tra immagini (0-1); 1 = identiche |
| **Sottocampionamento croma (4:2:0 / 4:2:2 / 4:4:4)** | Quanta risoluzione ha il colore rispetto alla luminosità |
| **10 bit / 8 bit** | Profondità di colore; il 10 bit ha gradazioni più morbide |
| **Metadati** | Dati accessori: data, modello, ISO, obiettivo, GPS, ecc. |
| **EXIF / XMP / IPTC / ICC** | Tipi di metadati/profili incorporati nelle foto |
| **MakerNote** | Area EXIF proprietaria del produttore (Sony, Canon...) |
| **MPF** | *Multi-Picture Format*: seconda immagine incorporata nel JPEG (anteprima) |
| **Traccia dati (`djmd`, `dbgi`, `rtmd`)** | Telemetria proprietaria DJI/Sony dentro il file video |
| **Timecode** | Codice orario del fotogramma |
| **Progressive JPEG** | JPEG che si carica per gradi di nitidezza; di solito un po' più piccolo |
| **Opus** | Codec audio con perdita moderno ed efficiente; qui dentro un contenitore Ogg |
| **Ogg** | Contenitore che ospita i file Opus; i tag sono **commenti Vorbis** |
| **Commento Vorbis** | Tag nel formato `CHIAVE=valore`; la stessa chiave può ripetersi (è ciò che permette gli artisti multipli) |
| **FLAC** | Codec audio **lossless** (senza perdita) |
| **WAV** | Audio PCM non compresso; metadati nei chunk `RIFF`/`INFO` |
| **VBR** | *Variable Bit Rate*: il bitrate varia con la complessità dell'audio |
| **Copertina** | Immagine dell'album; qui salvata come file (`cover.jpg`/...) nella cartella `opus`, non incorporata |
| **Sidecar** | File accessorio affiancato al media (XML, SRT, XMP) |
| **`.part`** | File temporaneo in scrittura, rinominato a fine lavoro |

---

## 15. Licenza

Questo software è distribuito con licenza open source **MIT**. Consulta il file [LICENSE](LICENSE) per il testo completo e le condizioni legali.
