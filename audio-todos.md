# Audio Unit – Fahrplan

## Übersicht

Das Ziel ist eine **Audio Unit für Lyx**, die Audio-Dateien abspielen kann (WAV, MP3). Die Unit soll:
- Audio-Dateien laden (WAV, MP3)
- Audio via ALSA oder PipeWire ausgeben
- Eine einfache API bieten

## Teilaufgaben

### WP1: API Design

| Aufgabe | Beschreibung |
|---------|--------------|
| **audio.lyx Schnittstelle** | API-Funktionen definieren (AudioOpen, AudioPlay, AudioClose, AudioPause, AudioStop) |
| **Rückgabewerte** | Error-Codes (AudioOk, AudioError, AudioEof) |
| **Konfiguration** | Sample-Rate, Channels, Bits-Per-Sample als Parameter |

### WP2: WAV Parser

| Aufgabe | Beschreibung |
|---------|--------------|
| **RIFF-WAVE Format** | `RIFF` Header erkennen, `WAVE` Chunk validieren |
| **fmt Chunk** | Audio-Format (PCM, Sample-Rate, Channels, Bits-Per-Sample) parsen |
| **data Chunk** | Offset und Größe der Audio-Daten ermitteln |
| **Validation** | Unterstützte Formate prüfen (PCM 8/16-bit, mono/stereo) |

### WP3: WAV Decoder

| Aufgabe | Beschreibung |
|---------|--------------|
| **PCM 8-bit** | Dekodierung unsigned PCM (0-255 → -128 bis +127) |
| **PCM 16-bit** | Dekodierung signed little-endian PCM |
| **Mono/Stereo** | Stereo zu Mono Mixdown falls nötig |
| **Sample-Rate Konvertierung** | Optional: Resampling falls nötig |

### WP4: MP3 Parser

| Aufgabe | Beschreibung |
|---------|--------------|
| **ID3v1 Tag** | Song-Titel, Artist, Album aus ID3v1 parsen |
| **ID3v2 Tag** | ID3v2.x Header parsen, Frames extrahieren |
| **MPEG Audio Header** | Frame-Sync, Layer, Bitrate, Sample-Rate, Channel-Mode |
| **Frame-Offset** | Start-Byte der ersten MP3-Frame finden |

### WP5: MP3 Decoder

| Aufgabe | Beschreibung |
|---------|--------------|
| **libmpg123 FFI** | Binding zu libmpg123 (FFI-Wrapper) |
| **ODecode** | mpg123_decode → PCM-Daten |
| **Fallback** | Stub wenn keine externe Library verfügbar |
| **Hinweis** | MP3-Dekodierung in reinem Lyx ist sehr komplex → FFI bevorzugt |

### WP6: ALSA Syscalls

| Aufgabe | Beschreibung |
|---------|--------------|
| **snd_pcm_open** | Audio-Device öffnen ("default" oder "hw:0") |
| **snd_pcm_set_params** | Format, Channels, Sample-Rate konfigurieren |
| **snd_pcm_write** | PCM-Daten zum Device schreiben |
| **snd_pcm_close** | Device schließen |

### WP7: PipeWire Support

| Aufgabe | Beschreibung |
|---------|--------------|
| **pw_init** | PipeWire initialisieren |
| **pw_stream_new** | Stream erstellen |
| **pw_stream_connect** | Stream mit Device verbinden |
| **pw_stream_write** | Daten zum Stream schreiben |
| **Fallback** | Automatic Fallback zu ALSA wenn PipeWire nicht verfügbar |

### WP8: Test-Programm

| Aufgabe | Beschreibung |
|---------|--------------|
| **music_test.wav** | Einfache WAV-Datei zum Testen erstellen |
| **test_audio.lyx** | Test-Programm das music_test.mp3 abspielt |
| **Manual Test** | music_test.mp3 via Audio Unit abspielen |

## API-Entwurf (vorläufig)

```
unit audio;

type AudioFormat enum (
    AF_PCM8,
    AF_PCM16,
    AF_MP3
);

type AudioError enum (
    AudioOk = 0,
    AudioError = -1,
    AudioEof = -2,
    AudioNotSupported = -3
);

fn AudioOpen(path: pchar, format: AudioFormat): AudioError;
fn AudioPlay(buffer: pchar, frames: int64): AudioError;
fn AudioClose(): AudioError;
fn AudioPause(): AudioError;
fn AudioStop(): AudioError;
```

## Abhängigkeiten

| Komponente | Quelle |
|-------------|--------|
| libmpg123 | Debian: `libmpg123-dev` |
| ALSA | Linux: `libasound2-dev` |
| PipeWire | Linux: `libpipewire-0.3-dev` |

## Priorisierung

| Reihenfolge | Priorität | Grund |
|-------------|-----------|-------|
| 1 | **Hoch** | WP1 (API) – Grundlage für alles |
| 2 | **Hoch** | WP2 (WAV Parser) – Einfachstes Format |
| 3 | **Hoch** | WP3 (WAV Decoder) | 
| 4 | **Mittel** | WP4 (MP3 Parser) |
| 5 | **Mittel** | WP5 (MP3 Decoder) – FFI zu libmpg123 |
| 6 | **Niedrig** | WP6 (ALSA) – Playback |
| 7 | **Niedrig** | WP7 (PipeWire) – Modern |
| 8 | **Niedrig** | WP8 (Test) |

## Status

| WP | Status |
|----|-------|
| WP1 | ⏳ Offen |
| WP2 | ⏳ Offen |
| WP3 | ⏳ Offen |
| WP4 | ⏳ Offen |
| WP5 | ⏳ Offen |
| WP6 | ⏳ Offen |
| WP7 | ⏳ Offen |
| WP8 | ⏳ Offen |