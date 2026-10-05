# DJI Compress - Documentazione

Script di ricompressione video (HEVC/H.265) e foto (JPEG) con controllo
automatico della qualita' tramite VMAF (video) e SSIM (foto).

- **File script:** `dji-compress.ps1`
- **File di configurazione:** `dji-compress.config.json` (creato in automatico
  accanto allo script)
- **Output:** cartella `out` dentro la cartella sorgente (o una cartella a
  scelta), con log CSV per ogni sessione.

> Gli originali **non vengono mai modificati ne' cancellati**. La compressione
> lavora sempre su una copia nella cartella di output.

---

## 1. Guida rapida (per chi non e' tecnico)

### 1.1 A cosa serve

Lo script prende i video e le foto di una cartella e li ricomprime per
**occupare meno spazio**, controllando automaticamente che la qualita' resti
alta. Se un file scende sotto la soglia di qualita' scelta, lo script lo
ricodifica da solo a qualita' piu' alta finche' non va bene (fino a un numero
massimo di tentativi).

### 1.2 Cosa fare, passo per passo

1. Apri un terminale **PowerShell** nella cartella dove si trova
   `dji-compress.ps1` (nella barra degli indirizzi di Esplora File digita
   `powershell` e premi Invio, oppure tasto destro > *Apri in Terminale*).
2. Lancia lo script con il comando:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\dji-compress.ps1
   ```
3. Attendi il messaggio `Controllo ffmpeg / QSV / VMAF ...`. Se compare un
   errore sugli strumenti mancanti, vedi la sezione **Dipendenze**.
4. Nel menu principale:
   - premi **`1`** e trascina nella finestra la cartella che contiene i video
     (o incolla il percorso), poi premi Invio;
   - premi **`4`** per comprimere i video con verifica e ricodifica automatica
     (modalita' **consigliata**);
   - premi **`7`** per comprimere le foto JPEG.
5. Alla domanda `Procedo? (s/n)` premi **`s`** e Invio.
6. Attendi la fine: alla conclusione viene mostrato un riepilogo e il percorso
   del file **CSV** con i risultati. Nella cartella `out` troverai i file
   compressi.

### 1.3 Cosa significano le voci del menu

| Voce | Significato |
|------|-------------|
| `[1]` | Sceglie la cartella con video e foto (viene ricordata nelle sessioni successive). |
| `[2]` | Analizza la cartella e mostra un elenco dei file trovati, con codec, risoluzione, ecc. |
| `[3]` | Comprime i video **senza** verifica (piu' veloce). |
| `[4]` | Comprime i video **con** verifica VMAF e ricodifica automatica. **Consigliato.** |
| `[5]` | Verifica soltanto dei video gia' compressi gia' presenti in `out`. |
| `[6]` | Impostazioni (qualita', soglie, audio, foto, ecc.). |
| `[7]` | Comprime le foto JPEG con verifica SSIM + metadati + retry. |
| `[8]` | Verifica soltanto delle foto gia' compresse. |
| `[9]` | Test di qualita' su **una** foto: prova piu' livelli e mostra dimensione, SSIM e metadati. |
| `[0]` | Esce (salva la configurazione). |

### 1.4 Consigli di base

- Le impostazioni vengono **salvate automaticamente**: la cartella e le opzioni
  restano memorizzate per la prossima volta.
- Se non sai cosa scegliere, in `[6]` > `[P]` > `2` trovi il preset
  **Archivio** (equilibrato e consigliato).
- La prima esecuzione puo' richiedere piu' tempo: VMAF e' un'analisi pesante.

---

## 2. Requisiti e dipendenze

### 2.1 Sistema

- **Windows** (lo script usa percorsi e comandi tipici di Windows).
- **PowerShell 5.1 o superiore** (incluso in Windows 10/11).
- **ffmpeg** e **ffprobe** nel `PATH`.
- **ImageMagick 7** (comando `magick`) per le foto.
- **exiftool** opzionale (rendimento migliore nel confronto metadati foto).

### 2.2 ffmpeg (obbligatorio per i video)

Serve una build **"full"** che includa:

- encoder **`libx265`** (x265 software) e, se disponibile, **`hevc_qsv`**
  (Intel Quick Sync, accelerazione hardware);
- filtro **`libvmaf`** (necessario per la verifica qualita').

Verifica con:

```powershell
ffmpeg -hide_banner -encoders | findstr /I "libx265 hevc_qsv"
ffmpeg -hide_banner -filters  | findstr /I libvmaf
```

- Se manca `libvmaf`, le funzioni di **verifica** non sono disponibili
  (restano possibili la compressione semplice `[3]` e quella foto).
- Lo script esegue un test reale di QSV: se la build ha `hevc_qsv` ma la GPU
  non lo supporta, ricade automaticamente su x265 (con encoder `auto`).

### 2.3 ImageMagick 7 (obbligatorio per le foto)

- Deve essere disponibile il comando `magick` nel `PATH`.
- Per la verifica serve la metrica **SSIM** (presente nelle build standard).
- Se non trovi `magick` nel `PATH`, lo script cerca anche in
  `%ProgramFiles%\ImageMagick*\magick.exe`.

Verifica con:

```powershell
magick -version
magick -list metric | findstr /I SSIM
```

### 2.4 exiftool (opzionale)

Se presente nel `PATH`, il confronto dei metadati delle foto diventa piu'
preciso (include MakerNote Sony). Senza di esso, lo script usa comunque i tag
EXIF letti da ImageMagick.

### 2.5 Intel Quick Sync (opzionale)

Per usare l'accelerazione GPU Intel serve una CPU Intel con iGPU recente e i
driver grafici aggiornati. Se non disponibile, lo script usa x265 su CPU.

---

## 3. Installazione delle dipendenze (Windows)

### 3.1 ffmpeg

1. Scarica una build **full** (es. da `https://www.gyan.dev/ffmpeg/builds/`
   oppure `https://www.videohelp.com/software/ffmpeg`).
2. Estrai in una cartella, ad esempio `C:\ffmpeg`.
3. Aggiungi `C:\ffmpeg\bin` alla variabile d'ambiente **PATH**:
   *Pannello di controllo > Sistema > Impostazioni avanzate > Variabili
   d'ambiente > Path > Modifica > Nuovo*.
4. Apri **un nuovo** terminale e verifica con `ffmpeg -version`.

### 3.2 ImageMagick 7

1. Scarica l'installer da `https://imagemagick.org/script/download.php`
   (versione Windows).
2. Durante l'installazione seleziona l'opzione per aggiungere `magick` al
   **PATH** e per installare gli strumenti da riga di comando.
3. Apri un nuovo terminale e verifica con `magick -version`.

### 3.3 exiftool (opzionale)

1. Scarica da `https://exiftool.org/`.
2. Rinomina `exiftool(-k).exe` in `exiftool.exe`.
3. Metti la cartella nel `PATH` e verifica con `exiftool -ver`.

### 3.4 Verifica completa

Nel terminale, tutti questi comandi devono rispondere correttamente:

```powershell
ffmpeg -version
ffprobe -version
magick -version
exiftool -ver   # opzionale
```

---

## 4. Esecuzione

### 4.1 Comando standard

```powershell
powershell -ExecutionPolicy Bypass -File .\dji-compress.ps1
```

- `-ExecutionPolicy Bypass` consente l'esecuzione dello script senza modificare
  in modo permanente la policy di sistema (utile se gli script non firmati sono
  bloccati).
- Deve essere lanciato dalla cartella dello script, oppure indica il percorso
  completo al file `.ps1`.

### 4.2 Avvio alternativo (dentro PowerShell)

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\dji-compress.ps1
```

`-Scope Process` applica la deroga solo alla sessione corrente.

### 4.3 Cosa succede all'avvio

1. Viene caricata la configurazione (`dji-compress.config.json`) se esiste.
2. Vengono controllati ffmpeg, ffprobe, QSV, libvmaf, ImageMagick, SSIM ed
   exiftool.
3. Se ne' ffmpeg ne' ImageMagick sono presenti, lo script termina con errore.
4. Si apre il menu principale.

---

## 5. Impostazioni (menu `[6]`)

Le impostazioni sono salvate in `dji-compress.config.json` accanto allo script.

### 5.1 Video

| Voce | Nome | Descrizione |
|------|------|-------------|
| `[1]` | Encoder | `auto` (QSV se funziona, altrimenti x265), `qsv`, `x265`. |
| `[2]` | Qualita' QSV | `-global_quality`; **piu' basso = qualita' piu' alta**. 24 = archivio, 21 = piu' sicuro, 27 = compatto. |
| `[3]` | Qualita' x265 (CRF) | `-crf`; **piu' basso = qualita' piu' alta**. 20 = archivio, 18 = piu' sicuro, 22 = compatto. |
| `[4]` | Preset x265 | Da `ultrafast` a `slower`. Piu' lento = file piu' piccoli/migliori (default `medium`). |
| `[5]` | Soglia VMAF | Sotto questo punteggio il file e' "da rifare" (default 96). |
| `[6]` | Precisione VMAF | Analizza 1 frame ogni N (1 = tutti, lento; 5 = default). |
| `[7]` | Retry automatico | Ricodifica se sotto soglia; numero massimo di tentativi. |
| `[8]` | Includi sottocartelle | Cerca i file anche nelle sottocartelle. |
| `[9]` | Sovrascrivi output | Sovrascrive file gia' presenti in `out`. |
| `[A]` | Conserva date file | Copia data di creazione/modifica sull'output. |
| `[B]` | Cartella output | Vuoto = `<sorgente>\out`. |
| `[C]` | Audio | `auto` (PCM -> AAC, altri formati copiati), `copy`, `aac`. |
| `[D]` | Bitrate AAC | Bitrate in kb/s usato quando l'audio diventa AAC (default 320). |
| `[E]` | xvYCC -> bt709 (Sony) | Corregge solo l'etichetta colore; i pixel non cambiano. |
| `[F]` | Copia XML/SRT/XMP | Copia i file affiancati (sidecar) nella cartella di output. |

### 5.2 Foto

| Voce | Nome | Descrizione |
|------|------|-------------|
| `[G]` | Qualita' foto (JPEG) | Qualita' di partenza ImageMagick (default 90). |
| `[H]` | Soglia SSIM foto | Sotto la soglia la foto viene rifatta a qualita' piu' alta (default 0.990). |
| `[I]` | JPEG progressivo | JPEG progressivo (file un po' piu' piccoli). |
| `[J]` | Verifica foto | Esegue confronto SSIM + metadati dopo la compressione. |

### 5.3 Preset rapidi (`[P]`)

| Preset | QSV | x265 CRF | Soglia VMAF | Foto Q | SSIM |
|--------|-----|----------|-------------|--------|------|
| 1 - Sicuro | 21 | 18 | 97 | 93 | 0.993 |
| 2 - Archivio | 24 | 20 | 96 | 90 | 0.990 |
| 3 - Compatto | 27 | 22 | 95 | 85 | 0.985 |

---

## 6. Come funziona (parte tecnica)

### 6.1 Flusso video (modalita' `[4]` - full)

1. Lettura dei metadati con `ffprobe` (codec, pixel format, risoluzione, fps,
   durata, tag colore, audio).
2. Encoding HEVC:
   - **QSV**: `hevc_qsv` con `-preset veryslow`; tentativo 1 con decodifica ed
     encoding su GPU, tentativo 2 con decodifica software;
   - **x265**: `libx265` con `-preset` e `-crf` scelti.
3. L'output viene scritto come `<nome>.part` e rinominato solo a fine encode
   (nessun file parziale lasciato in giro, anche in caso di `Ctrl+C`).
4. Viene eseguita la verifica **VMAF** del file compresso contro l'originale.
5. Se il punteggio e' sotto la soglia e il retry automatico e' attivo, il file
   viene ricodificato con qualita' piu' alta (QSV: -3, x265: -2) per un numero
   massimo di tentativi.
6. Se l'output risulta **piu' grande** dell'originale, viene eliminato e il
   file viene marcato `SALTATO: output piu grande`.
7. Se attivo, vengono copiate le date e i file affiancati (sidecar).

### 6.2 Metadati e colori

- I tag colore dell'originale (`color_primaries`, `color_trc`, `colorspace`,
  `color_range`) vengono **replicati** sull'output, cosi' i profili D-Log, HLG e
  Normal restano corretti.
- Per i file Sony con trasferimento `iec61966-2-4` (xvYCC), se l'opzione `[E]`
  e' attiva, l'etichetta viene normalizzata a `bt709` (i pixel non cambiano).
- L'audio in **PCM** (tipico Sony) viene convertito in **AAC** per
  compatibilita' con social e browser; gli altri formati vengono copiati.
- I formati con croma **4:2:2 / 4:4:4** (es. Sony XAVC HS) vengono convertiti a
  **4:2:0** per compatibilita' con tutti i player.
- Viene aggiunto il tag `hvc1` (compatibilita' Apple) e `faststart` (streaming).

### 6.3 VMAF

VMAF (Video Multi-Method Assessment Fusion) confronta il video compresso con
l'originale e restituisce un punteggio da 0 a 100 (piu' alto = migliore).

- Default: 1 frame ogni 5 (`VmafSubsample = 5`) per bilanciare velocita' e
  accuratezza.
- Se QSV e' disponibile, la decodifica per l'analisi usa la GPU, lasciando la
  CPU libera per VMAF.

### 6.4 Flusso foto (JPEG)

1. Lettura con `magick identify` (dimensioni, qualita' stimata, croma).
2. Se la foto e' gia' compressa almeno quanto il target, viene saltata.
3. Ricodifica con `magick` mantenendo risoluzione e sottocampionamento croma
   originali, senza rimuovere i metadati; opzionalmente JPEG progressivo e
   coding ottimizzato.
4. Verifica **SSIM** (1.0 = identico) e confronto metadati (exiftool o EXIF).
5. Se SSIM sotto soglia, retry a qualita' piu' alta (+3, fino a 98).
6. Se l'output e' piu' grande dell'originale, viene eliminato.

### 6.5 Cosa contiene il CSV

Per i **video**: `File, InMB, OutMB, Saved, Quality, VMAF, Audio, Status`.
Per le **foto**: `File, InMB, OutMB, Saved, Quality, SSIM, Meta, Status`.

Gli stati possibili includono: `OK`, `COMPRESSO (non verificato)`,
`ESISTENTE`, `GIA COMPRESSA`, `SALTATO: output piu grande`, `SOTTO SOGLIA`,
`MANCA OUTPUT`, `CONTROLLA METADATI`, `ERRORE ffmpeg`, `ERRORE magick`,
`VMAF non letto`, `SSIM non letto`, `VERIFICA DISATTIVATA`.

---

## 7. Config file `dji-compress.config.json`

Creato automaticamente accanto allo script. Contiene tutti i valori visti nella
sezione 5. Puo' essere modificato manualmente (a script chiuso) o tramite menu.

Valori di default principali:

```json
{
  "Encoder": "auto",
  "QsvQuality": 24,
  "X265Crf": 20,
  "X265Preset": "medium",
  "VmafThreshold": 96,
  "VmafSubsample": 5,
  "AutoRetry": true,
  "MaxRetries": 2,
  "AudioMode": "auto",
  "AacBitrate": 320,
  "PhotoQuality": 90,
  "PhotoSsim": 0.99,
  "PhotoVerify": true,
  "Extensions": [".mp4", ".mov"],
  "PhotoExtensions": [".jpg", ".jpeg"]
}
```

---

## 8. Risoluzione dei problemi

| Sintomo | Causa probabile | Soluzione |
|---------|-----------------|-----------|
| *"ne' ffmpeg/ffprobe ne' ImageMagick trovati"* | Strumenti non nel `PATH`. | Installa e aggiungi al `PATH`, poi **riapri** il terminale. |
| *"Il tuo ffmpeg non include libvmaf"* | Build senza libvmaf. | Usa una build **full** di ffmpeg. |
| *"Nessun encoder disponibile"* | Encoder scelto non disponibile. | In `[6]`> `[1]` scegli `auto` o `x265`; aggiorna i driver Intel per QSV. |
| QSV selezionato ma molto lento | QSV non supportato dalla GPU. | Lo script ricade su x265; per forzarlo usa `x265`. |
| *"Questa build di ImageMagick non ha la metrica SSIM"* | Build ImageMagick ridotta. | Reinstalla ImageMagick 7 completo. |
| Molti file `SOTTO SOGLIA` | Soglia troppo alta per il contenuto. | Abbassa la qualita' numerica (es. QSV 21 / x265 CRF 18) o abbassa la soglia VMAF. |
| Compressione troppo lenta | VMAF su tutti i frame o preset x265 lento. | Aumenta `VmafSubsample` (es. 10) o usa `hevc_qsv`. |
| Foto `SOTTO SOGLIA` | SSIM sotto soglia. | Alza la qualita' foto (es. 93) o tieni l'originale. |

---

## 9. Note sulla sicurezza dei dati

- **Gli originali non vengono toccati**: nessuna operazione di scrittura o
  cancellazione sui file sorgente.
- Eventuali file temporanei (`.part`) vengono rimossi anche in caso di
  interruzione.
- Se l'output risulta piu' grande dell'originale, viene cancellato e il file
  originale resta l'unica versione valida.
- Lo script non invia dati in rete.
