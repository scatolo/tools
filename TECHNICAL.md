# Squeeze: Documentazione Tecnica e Architettura Interna

[ 🇮🇹 Italiano ](TECHNICAL.md) · [ 🇬🇧 English ](TECHNICAL_EN.md) · [ ⬅️ Torna al README ](README.md)

Questo documento descrive nel dettaglio l'architettura interna, le scelte ingegneristiche, i meccanismi a basso livello e le pipeline di elaborazione di **Squeeze** (`squeeze.ps1` e `squeeze.py`).

È rivolto a sviluppatori, sistemisti, appassionati di video/audio encoding e chiunque desideri comprendere cosa accade "sotto il cofano".

---

## Indice

1. [Filosofia di progettazione e requisiti di sistema](#1-filosofia-di-progettazione-e-requisiti-di-sistema)
2. [Doppia implementazione: PowerShell 5.1 vs Python 3](#2-doppia-implementazione-powershell-51-vs-python-3)
3. [Rilevamento e collaudo dell'ambiente (`Test-Tools`)](#3-rilevamento-e-collaudo-dellambiente-test-tools)
4. [Pipeline Video: Architettura a cascata e HEVC](#4-pipeline-video-architettura-a-cascata-e-hevc)
   - 4.1 Selezione dei flussi e sanificazione (`-map`, `-dn`)
   - 4.2 Preservazione della colorimetria e normalizzazione xvYCC
   - 4.3 Scala di fallback NVENC (NVIDIA)
   - 4.4 Scala di fallback QSV (Intel)
   - 4.5 Fallback CPU x265
   - 4.6 Scrittura atomica (`.part`), guardie sulle dimensioni e pulizia
5. [Misurazione qualitativa: VMAF e SSIM](#5-misurazione-qualitativa-vmaf-e-ssim)
   - 5.1 Calcolo VMAF con accelerazione hardware multi-livello
   - 5.2 ImageMagick 7 e parsing normalizzato SSIM
   - 5.3 Algoritmo di auto-retry qualitativo
6. [Pipeline Foto: Preservazione campionamento e metadati](#6-pipeline-foto-preservazione-campionamento-e-metadati)
   - 6.1 Problema del sottocampionamento croma in ImageMagick
   - 6.2 Pre-filtro euristico sulla qualità stimata
   - 6.3 Diff profondo dei metadati con ExifTool
7. [Pipeline Audio: Riscrittura binaria dell'header Ogg](#7-pipeline-audio-riscrittura-binaria-dellheader-ogg)
   - 7.1 Il problema degli artisti multipli in ffmpeg
   - 7.2 Parser binario FLAC Vorbis Comments
   - 7.3 Parser binario RIFF INFO per WAV
   - 7.4 Motore di riscrittura pacchetti Ogg e calcolo CRC-32
   - 7.5 Strategia di gestione delle copertine
8. [Configurazione, migrazione di schema e compatibilità](#8-configurazione-migrazione-di-schema-e-compatibilità)

---

## 1. Filosofia di progettazione e requisiti di sistema

Squeeze è progettato attorno a principi cardine:

1. **Zero dipendenze esterne di runtime di terze parti**:
   - Su Windows: uno script `.ps1` eseguibile nativamente su **PowerShell 5.1 standard** (Windows 10 e 11) senza necessità di installare moduli PowerShell da PSGallery.
   - Su Linux: uno script `.py` eseguibile con la libreria standard di **Python 3.9+** (senza pacchetti `pip` / virtualenv).
   - Dipendenze binarie limitate a standard de facto comprovati: `ffmpeg`/`ffprobe`, `ImageMagick 7` e opzionalmente `exiftool`.
2. **Integrità assoluta dei dati sorgente**:
   - Nessun file originale viene mai modificato, sovrascritto o rimosso.
   - Tutte le elaborazioni creano file temporanei `.part` nella cartella di destinazione (`out/` o `opus/`), rinominati con operazione atomica solo all'uscita con codice `0` del processo esterno.
   - Qualsiasi interruzione imprevista (Ctrl+C, crash di processo, errore di muxer) attiva handler di pulizia (`finally` in PowerShell / Python e trap di segnali `SIGINT`/`SIGTERM`) che eliminano il `.part` incompleto.
3. **Scarto attivo dell'output controproducente (No-Bloat Policy)**:
   - Se un file elaborato risulta di dimensioni pari o superiori alla sorgente (tipico di video o audio già pesantemente compressi), l'output viene immediatamente rimosso e il file sorgente viene catalogato come `SALTATO: output piu grande`.
4. **Verifica oggettiva della trasparenza percettiva**:
   - Nessun presupposto a priori: ogni compressione video/foto può essere vincolata a soglie quantitative (VMAF per il video, SSIM per le foto) con meccanismo di ripensamento a feedback ad anello chiuso (retry automatico a qualità più alta).

---

## 2. Doppia implementazione: PowerShell 5.1 vs Python 3

Sebbene entrambi i file offrano la medesima TUI interattiva centrata e gestiscano le identiche configurazioni JSON, ciascun linguaggio richiede specifiche accortezze architetturali:

### PowerShell 5.1 (`squeeze.ps1`)
- **Compatibilità UTF-8**: PowerShell 5.1 interpreta di default i file di script come ANSI/Windows-1252. Il file `squeeze.ps1` è rigorosamente codificato in **UTF-8 con BOM** (`0xEF, 0xBB, 0xBF`), permettendo al motore di parsing di visualizzare correttamente box drawing ANSI e lettere accentate. All'avvio, imposta programmaticamente `[Console]::OutputEncoding` e `$OutputEncoding` su `[System.Text.Encoding]::UTF8`.
- **Comportamento di `$ErrorActionPreference = 'Continue'`**: in PowerShell 5.1, impostare `Stop` provoca l'interruzione immediata dello script non appena un comando nativo (come `ffmpeg` o `identify`) scrive messaggi informativi su `stderr`. Per questo motivo lo script mantiene `'Continue'` e gestisce esplicitamente il codice di uscita tramite `$LASTEXITCODE`.
- **Parsing numerico e internazionalizzazione**: sui sistemi Windows italiani la virgola `,` è il separatore decimale. Tutti i parsing a virgola mobile usano `$script:Inv = [Globalization.CultureInfo]::InvariantCulture` (`[double]::Parse($val, $script:Inv)`) per evitare crash nell'interpretazione dei log di ffmpeg o ImageMagick.
- **Splatting per chiamate esterne**: i comandi ffmpeg e ImageMagick non vengono concatenati in stringhe arbitrarie (soggette a problemi di escaping su percorsi contenenti spazi o parentesi quadre), bensì passati come array di argomenti (`& ffmpeg @args`).
- **Selettore cartelle**: usa `System.Windows.Forms.FolderBrowserDialog` nativo Windows, richiamato se l'utente preme Invio a vuoto sulla selezione cartella.

### Python 3 (`squeeze.py`)
- **Zero moduli PIP**: sfrutta esclusivamente `csv`, `json`, `math`, `os`, `re`, `shutil`, `struct`, `subprocess`, `sys`, `tempfile`, `time` e `pathlib.Path`.
- **Riconfigurazione stdout/stderr**: richiama `sys.stdout.reconfigure(encoding='utf-8', errors='replace')` per garantire compatibilità con terminali POSIX eterogenei.
- **Selettore cartelle multipiattaforma**: supporta in cascata `tkinter.filedialog`, `zenity --file-selection --directory` e `kdialog --getexistingdirectory`.
- **Gestione segnali**: `signal.signal(signal.SIGINT, handler)` per catturare interruzioni da tastiera e pulire i file temporanei `.part` prima dell'uscita.

---

## 3. Rilevamento e collaudo dell'ambiente (`Test-Tools`)

La semplice presenza di un binario nel `PATH` non garantisce che l'accelerazione hardware funzioni o che la GPU supporti il profilo richiesto.

All'avvio, `Test-Tools` esegue test reali sintetici:

```
[Verifica PATH] ---> ffmpeg, ffprobe, magick, exiftool
                         │
                         ▼
[Ispezione codec] --> ffprobe -encoders, -decoders, -filters
                         │
                         ▼
[Test HW NVENC] ----> ffmpeg -f lavfi -i color=c=black:s=64x64:d=0.2
                      -c:v hevc_nvenc -profile:v main10 -f null -
                         │
                         ▼
[Test HW QSV] ------> ffmpeg -f lavfi -i color=c=black:s=64x64:d=0.2
                      -c:v hevc_qsv -f null -
                         │
                         ▼
[Test Filtri] ------> Verifica presenza libvmaf, libopus
                         │
                         ▼
[Test Metriche] ----> magick -list metric (ricerca stringa "SSIM")
```

1. **Rilevamento NVENC**:
   Viene eseguita una codifica reale di 0,2 secondi di un flusso video 10-bit sintetico (`color=c=black:s=64x64:d=0.2`) verso `-f null -`. Se il driver NVIDIA non è presente, o se la scheda non supporta `hevc_nvenc` con profilo `main10` (10-bit), il test fallisce e NVENC viene disabilitato per la sessione, prevenendo errori a metà batch.
2. **Rilevamento QSV**:
   Viene eseguita una codifica sintetica con `hevc_qsv`. Su Windows sfrutta Direct3D 11 (`-hwaccel d3d11va`), su Linux si interfaccia con `/dev/dri/renderD128` (VA-API / Intel iHD).
3. **Cascata automatica (`Resolve-Encoder`)**:
   ```text
   NVENC (se hardware OK) ──> QSV (se hardware OK) ──> x265 (CPU, fallback universale)
   ```

---

## 4. Pipeline Video: Architettura a cascata e HEVC

La funzione `Invoke-VideoJob` (PowerShell) / `invoke_video_job` (Python) implementa la pipeline principale di ricodifica video.

### 4.1 Selezione dei flussi e sanificazione (`-map`, `-dn`)

Le videocamere moderne (DJI Osmo Action 3/4/5, Pocket, droni DJI e mirrorless Sony Alpha) inseriscono nei file MP4/MOV flussi ausiliari complessi. Una chiamata standard a `ffmpeg -i input.mp4 output.mp4` fallisce frequentemente per i seguenti motivi:

1. **Copertine e flussi mjpeg**: DJI e Sony possono includere un'immagine JPEG statica registrata come flusso video ausiliario. Specificando `-map 0:V:0` (con `V` maiuscola), ffmpeg seleziona esclusivamente il primo flusso **video vero**, ignorando flussi cover-art/poster-frame che altrimenti verrebbero convertiti per errore in un secondo flusso HEVC o causerebbero conflitti di muxer.
2. **Tracce dati proprietarie (`-dn`)**:
   - I file DJI contengono flussi `djmd` (telemetria, giroscopio, accelerometro) e `dbgi`.
   - I file Sony contengono flussi `rtmd` (Real-Time Metadata: ISO, apertura diaframma, autofocus, shutter speed fotogramma per fotogramma).
   Il muxer MP4 di ffmpeg non supporta tali tracciati e abortisce con errore `Could not find tag for codec none in stream #...`. L'opzione esplicita `-dn` (*drop data*) esclude questi flussi non standard, consentendo la corretta creazione dell'MP4/MOV.
3. **Flussi audio opzionali (`-map 0:a?`)**:
   Il modificatore `?` rende l'assegnazione opzionale. Se una clip è priva di tracce audio (es. video time-lapse DJI o riprese ad alta velocità a 120/240 fps senza traccia sonora), ffmpeg non fallisce per mancanza del flusso.
4. **Metadati e compatibilità Apple**:
   - `-map_metadata 0 -movflags use_metadata_tags+faststart`: conserva la data di creazione, coordinate GPS e note di scatto registrate a livello di contenitore; `faststart` sposta l'indice atom `moov` all'inizio del file per la riproduzione streaming istantanea senza attendere il caricamento completo.
   - `-tag:v hvc1`: forza il FourCC `hvc1` anziché `hev1`. Questo è fondamentale per la riproduzione su macOS (QuickTime), iOS/iPadOS, Safari e per il caricamento diretto su piattaforme social che rifiutano il FourCC `hev1`.

### 4.2 Preservazione della colorimetria e normalizzazione xvYCC

Uno dei problemi più critici nella ricodifica di video DJI (D-Log M, HLG) o Sony (S-Log3, HLG, Cine) è il "color shift" o lo sbiadimento dei neri derivante dalla perdita o dall'errata interpretazione dei tag VUI (*Video Usability Information*).

Prima dell'elaborazione, `Get-VideoInfo` estrae tramite `ffprobe` quattro proprietà fondamentali:
- `color_primaries` (es. `bt709`, `bt2020`)
- `color_transfer` / `color_trc` (es. `bt709`, `arib-std-b67`, `smpte2084`, `iec61966-2-4`)
- `color_space` / `colorspace` (es. `bt709`, `bt2020nc`)
- `color_range` (es. `tv` / limited o `pc` / full)

I parametri vengono passati integralmente all'encoder (`-color_primaries`, `-color_trc`, `-colorspace`, `-color_range`). In questo modo:
- I profili HLG (BT.2020 / ARIB STD-B67) rimangono HDR riconosciuti correttamente dalle Smart TV e dai player.
- I profili D-Log M e flat conservano la curva logaritmica nativa.

#### La correzione Sony xvYCC (`NormalizeXvYCC`)
Molte fotocamere Sony Alpha registrano video SDR in gamut standard ma impostano la curva di trasferimento su `iec61966-2-4` (xvYCC). Questo valore storico causa spesso problemi: software di montaggio, browser web e player moderni interpretano erroneamente xvYCC come Rec.601, provocando colori slavati o clipping sui neri.
Se l'opzione `NormalizeXvYCC` è attiva (default: `SI`), Squeeze intercetta `color_trc == 'iec61966-2-4'` e imposta `-color_trc bt709`.
**Nota tecnica cruciale**: l'operazione modifica solo il metadato VUI di etichetta nel bitstream HEVC; non viene applicato alcun filtro video (`-vf`) distruttivo di ricalcolo o remapping dello spazio colore. I valori dei pixel restano matematicamente intatti.

### 4.3 Scala di fallback NVENC (NVIDIA)

L'encoder NVIDIA NVENC supporta configurazioni avanzate per raggiungere qualità d'archivio. La codifica tenta 3 livelli successivi:

```
Livello 1: Full GPU Pipeline (Decodifica CUDA + Codifica NVENC HQ)
  ├── -hwaccel cuda -hwaccel_output_format cuda
  ├── -preset p7 -tune hq -multipass fullres
  ├── -rc vbr -cq <N> -b:v 0 -rc-lookahead 32 -spatial-aq 1 -temporal-aq 1
  └── (Se input è 4:2:2/4:4:4, salta direttamente al Livello 2)
         │
         ▼ Fallimento / Errore CUDA
Livello 2: Decodifica Software + Codifica NVENC HQ
  ├── Decodifica CPU (software)
  ├── -vf "format=p010le" (10-bit) oppure "format=nv12" (8-bit)
  └── -c:v hevc_nvenc (con opzioni HQ del Livello 1)
         │
         ▼ Fallimento / Build ffmpeg priva di AQ o GPU con risorse ridotte
Livello 3: Modalità Sicura NVENC
  └── -c:v hevc_nvenc -preset p7 -rc vbr -cq <N> (senza spatial-aq/temporal-aq/lookahead)
```

- **Preset p7**: il preset di massima complessità algoritmica di NVENC (7 b-frame evaluation pass).
- **Multipass fullres**: analisi di bitrate a risoluzione intera a doppio passaggio hardware.
- **Spatial AQ & Temporal AQ**: allocazione dinamica dei quantizzatori basata sulla varianza spaziale (texture complesse vs superfici uniformi) e temporale (movimento tra frame adiacenti). Previene il banding nei cieli e il macroblocking su superfici sfumate.

### 4.4 Scala di fallback QSV (Intel)

Intel Quick Sync Video (iGPU Iris Xe, Arc, Arrow Lake / Core Ultra) offre un'efficienza notevole con `hevc_qsv`.

1. **Livello 1 (Full HW)**:
   ```bash
   -hwaccel qsv -hwaccel_output_format qsv -i INPUT \
   -c:v hevc_qsv -preset veryslow -global_quality <N> -look_ahead 1
   ```
2. **Livello 2 (SW decode + HW encode)**:
   Se il demuxer QSV fallisce o la sorgente ha un formato di campionamento non supportato dal decoder hardware (es. video Sony a 10-bit 4:2:2 registrati in XAVC HS):
   - Decodifica software tramite CPU.
   - Filtro di normalizzazione: `-vf "format=p010le"` (se 10-bit) o `-vf "format=nv12"` (se 8-bit).
   - Codifica hardware `hevc_qsv`.

### 4.5 Fallback CPU x265

Se non è presente alcuna GPU supportata o l'utente seleziona esplicitamente x265:
```bash
-c:v libx265 -preset medium -crf <N> -pix_fmt yuv420p10le -x265-params log-level=error
```
x265 garantisce il massimo rapporto di compressione possibile, pur con una velocità di elaborazione sensibilmente inferiore rispetto all'hardware dedicato.

### 4.6 Scrittura atomica (`.part`), guardie sulle dimensioni e pulizia

La gestione dei file sul disco segue un rigido schema di sicurezza:
1. Il file di output viene creato con suffisso temporaneo: `destinazione/file.mp4.part`.
2. Se il processo ffmpeg termina con errore, il blocco di gestione delle eccezioni cancella immediatamente il `.part`.
3. A processo ultimato con successo:
   - Se `Dimensione(part) >= Dimensione(sorgente)`: il file viene eliminato (`Remove-Item` / `os.unlink`) e loggato come `SALTATO: output piu grande`.
   - Se `Dimensione(part) < Dimensione(sorgente)`: il file viene rinominato atomicamente al nome finale (`file.mp4`).
4. **Preservazione dei timestamp**: se `PreserveDates` è attivo, le date di creazione (`CreationTime`) e ultima modifica (`LastWriteTime`) del file originale vengono copiate sul nuovo file tramite API .NET (`[System.IO.File]::SetCreationTime`) o chiamate POSIX `os.utime`.

---

## 5. Misurazione qualitativa: VMAF e SSIM

### 5.1 Calcolo VMAF con accelerazione hardware multi-livello

Il **VMAF** (*Video Multi-Method Assessment Fusion*) sviluppato da Netflix combina metriche di dettaglio visivo (VIF), fedeltà alle alte frequenze (DLM) e perdita di movimento temporale per predire la valutazione soggettiva umana (MOS).

Il comando eseguito da `Measure-Vmaf`:
```bash
ffmpeg -hide_banner -nostats \
  <hwaccel_args> -i COMPRESSO \
  <hwaccel_args> -i ORIGINALE \
  -lavfi "[0:v:0][1:v:0]libvmaf=n_threads=<core>:n_subsample=<N>" \
  -an -sn -dn -f null -
```

#### Ottimizzazione del sottocampionamento (`n_subsample`)
Calcolare il VMAF fotogramma per fotogramma (`n_subsample=1`) richiede una potenza di calcolo enorme, spesso impiegando più tempo dell'intera fase di codifica.
Squeeze impiega di default `n_subsample=5`, che calcola la metrica su **un fotogramma ogni cinque**.
- *Validità statistica*: su un clip a 50 o 60 fps, un frame ogni cinque corrisponde a 10-12 campionamenti al secondo, ampiamente sufficienti per intercettare cali di qualità nei cambi scena o nei passaggi ad alto movimento.
- *Beneficio prestazionale*: accelerazione fino a **4x-5x** del tempo di analisi.

#### Accelerazione decodifica a cascata
Per non saturare la CPU durante il calcolo VMAF, Squeeze tenta la decodifica hardware dei due flussi contemporanei:
1. Se l'encoder scelto è NVENC, prova `-hwaccel cuda` su entrambi gli input.
2. Se l'encoder è QSV o CUDA non risponde, prova `-hwaccel qsv`.
3. In caso di errore o discrepanza nei formati colore, ricade in decodifica software pura.

### 5.2 ImageMagick 7 e parsing normalizzato SSIM

Per le immagini JPEG, Squeeze misura la somiglianza strutturale (SSIM, valore teorico tra 0 e 1, dove 1 indica identità perfetta).

Il comando di confronto:
```bash
magick compare -metric SSIM COMPRESSO.JPG ORIGINALE.JPG null:
```

#### La formula di normalizzazione ImageMagick 7
Nelle versioni recenti di ImageMagick 7, il comando non restituisce un singolo valore, bensì una tupla nel formato `valore (distanza)`, ad esempio: `0.993421 (0.003289)`.

In ImageMagick, la distanza riportata tra parentesi quadre/tonde è definita come:
$$\text{distanza} = \frac{1 - \text{SSIM}}{2} \iff \text{SSIM} = 1 - (2 \times \text{distanza})$$
*(equivalente a: `distanza = (1 - SSIM) / 2` ⟺ `SSIM = 1 - (2 * distanza)`)*

Squeeze rileva tramite espressione regolare la presenza delle parentesi con la distanza; se presente, ricalcola il punteggio esatto di SSIM con la formula inversa, evitando errate interpretazioni dovute a formati di output eterogenei tra diverse distribuzioni di ImageMagick.

### 5.3 Algoritmo di auto-retry qualitativo

Quando la verifica qualitativa è attiva (`AutoRetry = $true`), il processo opera ad anello chiuso:

```
                  ┌────────────────────────┐
                  │ Codifica Video / Foto  │
                  └───────────┬────────────┘
                              │
                              ▼
                  ┌────────────────────────┐
                  │  Misura VMAF / SSIM    │
                  └───────────┬────────────┘
                              │
                    Score >= Soglia?
                    ├── SI ──> [Stato: OK] Salva e prosegui
                    └── NO ──> Tentativi rimanenti?
                                ├── SI: Decrementa CQ/CRF (o Aumenta Q foto)
                                │       Riesegui codifica
                                └── NO: [Stato: SOTTO SOGLIA] Mantieni miglior risultato
```

- **Passo di incremento video**:
  - NVENC: `-3 CQ` per tentativo (limite minimo di sicurezza `CQ = 14`).
  - QSV: `-3 global_quality` per tentativo (limite minimo `15`).
  - x265: `-2 CRF` per tentativo (limite minimo `12`).
- **Passo di incremento foto**:
  - `+3 Q` (qualità JPEG ImageMagick) per tentativo (limite massimo `98`).

---

## 6. Pipeline Foto: Preservazione campionamento e metadati

### 6.1 Problema del sottocampionamento croma in ImageMagick

Un comportamento poco noto ma critico di ImageMagick 7 è il seguente: quando si salva un file JPEG con `-quality 90` (o superiore) senza specificare il campionamento, ImageMagick passa automaticamente dal sottocampionamento comune `4:2:0` (o `2x1` / `4:2:2`) a `4:4:4` (nessun sottocampionamento croma).
Di conseguenza, un'immagine compressa a Q90 può risultare **più pesante dell'originale** a causa del raddoppio dei dati di crominanza!

Per prevenire questo difetto, Squeeze:
1. Ispeziona preventivamente la foto originale con:
   ```bash
   magick identify -format "%w|%h|%Q|%[jpeg:sampling-factor]" "INPUT.JPG[0]"
   ```
2. Recupera l'esatto fattore di campionamento sorgente (es. `2x2,1x1,1x1` per 4:2:0, o `2x1,1x1,1x1` per 4:2:2).
3. Impone esplicitamente lo stesso fattore nella codifica:
   ```bash
   magick INPUT.JPG -quality 90 -sampling-factor <fattore_originale> \
     -interlace JPEG -define jpeg:optimize-coding=true JPEG:OUTPUT.JPG.part
   ```
   - `-interlace JPEG`: genera JPEG progressivo (se abilitato), riducendo la dimensione del bitstream del 2-4%.
   - `-define jpeg:optimize-coding=true`: ottimizza le tabelle di Huffman.
   - Nessun parametro `-strip` o `-auto-orient`: orientamento EXIF e metadati integrati rimangono inalterati.

### 6.2 Pre-filtro euristico sulla qualità stimata

La ricompressione JPEG è per definizione a perdita (lossy). Ricodificare un'immagine già salvata a qualità 80 con un target a 90 non fa che incrementare gli artefatti di quantizzazione e la dimensione del file.

Squeeze legge `%Q` (stima della tabella di quantizzazione originale):
- Se `Q_stimata <= PhotoQuality`: la foto viene saltata con stato `GIA COMPRESSA (Q~N)`.

### 6.3 Diff profondo dei metadati con ExifTool

Quando `exiftool` è disponibile nel sistema, `Test-PhotoMetadata` effettua una comparazione approfondita tra l'originale e l'output ricodificato:
```bash
exiftool -a -u -G1 -s "FILE.JPG"
```
I tag vengono estratti e confrontati scartando le differenze fisiologiche dovute alla riscrittura del contenitore:
- Gruppi ignorati via regex: `System`, `File`, `ExifTool`, `Composite`, `JFIF`, `MPF*`.
- La traccia MPF (*Multi-Picture Format*, contenente la preview incorporata 1080p generata da Sony) viene scartata da ImageMagick: il diff lo rileva e segnala se mancano tag fotografici reali rispetto all'originale.

---

## 7. Pipeline Audio: Riscrittura binaria dell'header Ogg

La conversione da file non compressi o lossless (**WAV**, **FLAC**) al formato compresso ad alta efficienza **Opus** (`libopus`, contenitore Ogg) presenta sfide complesse nella gestione dei metadati musicali.

### 7.1 Il problema degli artisti multipli in ffmpeg

Nello standard dei commenti Vorbis (`VorbisComment`, utilizzato da Ogg, FLAC e Opus), la specifica prevede esplicitamente che **i campi possano essere ripetuti**. Se una traccia include due artisti (es. *Artist A* e *Artist B*), la struttura corretta è formata da due tag distinti:
```
ARTIST=Artist A
ARTIST=Artist B
```
I riproduttori musicali moderni (MusicBee, Foobar2000, Navidrome, Plex, Apple Music) indicizzano correttamente entrambi gli artisti solo se memorizzati come tag separati.

Tuttavia, quando ffmpeg codifica un file audio:
- Converte il dizionario dei metadati unendo le voci duplicate in un'unica stringa separata da punto e virgola: `ARTIST=Artist A; Artist B`.
- Non offre alcuna opzione da riga di comando per emettere tag duplicati identici nel bitstream Ogg/Opus finale.

Per risolvere questo limite, Squeeze adotta un approccio avanzato a due stadi:
1. Codifica il flusso audio con ffmpeg **azzerando completamente i metadati**:
   ```bash
   ffmpeg -i INPUT.FLAC -map 0:a:0 -vn -map_metadata -1 \
     -c:a libopus -b:a 160k -vbr on -application audio -f opus OUTPUT.OPUS.part
   ```
2. **Inietta i tag a basso livello**, manipolando direttamente i byte dell'header Ogg del file `.opus.part`.

### 7.2 Parser binario FLAC Vorbis Comments

Squeeze implementa un lettore binario nativo del formato FLAC senza dipendenze esterne:
1. Verifica i primi 4 byte `fLaC`.
2. Scorre i blocchi di metadati (`METADATA_BLOCK_HEADER` di 4 byte):
   - Bit 0: flag ultimo blocco (`is_last`).
   - Bit 1-7: tipo di blocco (`block_type`). Il blocco tipo `4` è `VORBIS_COMMENT`.
   - Byte 1-3: lunghezza del blocco in big-endian (24 bit).
3. Entrato nel blocco `VORBIS_COMMENT`:
   - Legge la lunghezza (32-bit little-endian) e la stringa del *Vendor*.
   - Legge il numero di commenti dell'utente (`user_comment_list_length`, 32-bit little-endian).
   - Per ciascun commento, legge lunghezza e stringa `CHIAVE=valore` decodificata in UTF-8.
   Tutti i duplicati e l'ordine originario vengono preservati fedelmente.

### 7.3 Parser binario RIFF INFO per WAV

Per i file WAV:
1. Verifica il chunk master `RIFF....WAVE`.
2. Naviga tra i chunk cercando la lista `LIST` di tipo `INFO`.
3. Mappa le quattro lettere dei codici RIFF standard nei rispettivi campi Vorbis:
   - `INAM` → `TITLE`
   - `IART` → `ARTIST`
   - `IPRD` → `ALBUM`
   - `ICMT` → `COMMENT`
   - `IGNR` → `GENRE`
   - `ICRD` / `YEAR` → `DATE`
   - `ITRK` → `TRACKNUMBER`

Se il parser nativo non individua blocchi RIFF INFO, Squeeze interroga `ffprobe` come meccanismo di ripiego.

### 7.4 Motore di riscrittura pacchetti Ogg e calcolo CRC-32

Un flusso Ogg è suddiviso in pagine logiche. Ciascuna pagina inizia con i 4 byte `OggS`:

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
| page_segments | segment_table (1..255 byte)...                |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| payload dati...                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

Nei file Opus:
- La **Pagina 0** contiene il pacchetto `OpusHead` (parametri codec, frequenza, canali).
- La **Pagina 1** contiene il pacchetto `OpusTags` (metadati Vorbis comment).
- Le **Pagine successive** contengono i pacchetti audio compressi.

#### Algoritmo di riscrittura (`Set-OpusTags` / `set_opus_tags`)
1. Legge la pagina 1 originaria generata da ffmpeg e ne estrae la stringa del venditore (es. `Lavf61.1.100`).
2. Costruisce in memoria il nuovo payload `OpusTags`:
   - 8 byte magic: `OpusTags`.
   - Stringa venditore (lunghezza 32-bit LE + stringa UTF-8).
   - Conteggio commenti (32-bit LE).
   - Sequenza dei singoli tag (lunghezza 32-bit LE + `CHIAVE=valore` in UTF-8).
3. **Calcolo della tabella di segmentazione (lacing values)**:
   In Ogg, i dati sono frammentati in segmenti di massimo 255 byte. Un pacchetto di lunghezza $L$ viene suddiviso in $n$ segmenti da 255 byte seguiti da un segmento finale di $L \pmod{255}$ byte.
4. Se il nuovo header supera la dimensione massima di una pagina (255 segmenti $\times$ 255 byte $\approx 64$ KB), viene suddiviso su più pagine consecutive con flag `header_type` appropriati.
5. **Calcolo del CRC-32 Ogg**:
   Il checksum è posizionato all'offset 22 della pagina. Per calcolarlo:
   - Si azzerano temporaneamente i 4 byte del checksum (`0x00, 0x00, 0x00, 0x00`).
   - Si esegue il calcolo CRC-32 su tutti i byte dell'header e del payload della pagina utilizzando il polinomio standard Ogg:
     $$P(x) = x^{32} + x^{26} + x^{23} + x^{22} + x^{16} + x^{12} + x^{11} + x^{10} + x^8 + x^7 + x^5 + x^4 + x^2 + x + 1$$
     corrispondente al valore esadecimale generatore `0x04C11DB7`.
   - Il CRC a 32 bit risultante viene scritto in little-endian all'offset 22.
6. Le pagine audio successive vengono riallineate nei numeri di sequenza progressivi (`page_sequence_number`) e i loro CRC ricalcolati se il nuovo header ha introdotto pagine addizionali.

### 7.5 Strategia di gestione delle copertine

Sebbene la specifica consenta di inserire copertine all'interno di un blocco `METADATA_BLOCK_PICTURE` dentro il pacchetto `OpusTags`, questa pratica è sconsigliata:
- Aumenta a dismisura le dimensioni dell'header Ogg iniziale, ritardando l'avvio dello streaming audio.
- Molti decoder embedded o player per auto crashano se la prima pagina di metadati supera dimensioni standard.

Squeeze adotta una politica pulita:
1. Rimuove qualsiasi flusso o tag cover dal file `.opus`.
2. Ispeziona la cartella sorgente alla ricerca di file di copertina dedicati (`cover.jpg`, `folder.jpg`, `front.png`, ecc.) e li copia nella cartella di destinazione `opus/`.
3. Se non esistono file immagine esterni, estrae l'eventuale copertina incorporata nel FLAC tramite ffmpeg (`-map 0:v:0 -c copy cover.jpg`) salvandola come immagine affiancata.

---

## 8. Configurazione, migrazione di schema e compatibilità

La configurazione risiede in `squeeze.config.json` nella cartella dello script.

### Meccanismo di sicurezza nell'importazione (`Import-Config`)
Per prevenire injection impreviste o incompatibilità di tipo:
1. Lo script definisce un dizionario/hashtable predefinito con tutti i campi attesi e i relativi valori di fallback.
2. Durante `Import-Config`, il JSON caricato dal disco viene iterato: **solo le chiavi già registrate nel dizionario interno predefinito vengono assegnate**. Chiavi sconosciute o deprecate vengono ignorate.

### Retrocompatibilità automatica
Se `squeeze.config.json` non esiste ma nella directory è presente `dji-compress.config.json` (il nome storico del progetto):
1. I valori vengono letti automaticamente da `dji-compress.config.json`.
2. Viene scritto immediatamente il nuovo file `squeeze.config.json`.
3. L'utente non sperimenta alcuna perdita di preferenze durante l'aggiornamento.

---

[ ⬅️ Torna al README ](README.md)
