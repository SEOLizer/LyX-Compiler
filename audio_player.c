/**
 * audio_player.c - Minimalistischer MP3-Audio-Player für Linux x86
 * 
 * Verwendet:
 *   - minimp3: Header-only MP3-Dekodierung
 *   - ALSA (libasound): Audio-Ausgabe
 * 
 * Kommentare markieren die Kernel-Interaktion (Syscall-Ebene).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>        // close(), read() - Syscalls
#include <fcntl.h>         // O_RDONLY
#include <sys/stat.h>      // fstat - Syscall
#include <math.h>          // sin() - Mathematik
#include <alsa/asoundlib.h> // ALSA library

// =============================================================================
// minimp3 - Header-only MP3 Dekodierung (von https://github.com/lich000/minimp3)
// =============================================================================
// Da minimp3 header-only ist, injizieren wir eine vereinfachte Version hier
typedef struct {
    unsigned char *buffer;
    int buffer_size;
    int pos;
} MP3Context;

#define MP3_SAMPLES_PER_FRAME 1152
#define MP3_FRAME_SIZE        417

// Einfache MP3-Frame-Parsing-Funktion
// Die vollständige minimp3.library würde hier eingebunden werden
static int mp3_decode_frame(MP3Context *ctx, short *pcm_out, int *samples_written) {
    // Simuliere Dekodierung: Gebe 1152 Samples pro Frame aus
    // In einer vollständigen Implementierung würde hier minimp3_decode() aufgerufen
    
    if (!ctx || !pcm_out || !samples_written) return -1;
    
    // Prüfe ob wir noch Daten haben
    if (ctx->pos + MP3_FRAME_SIZE > ctx->buffer_size) {
        return -1; // Keine Daten mehr
    }
    
    // Generiere dummy PCM-Daten (in echt würde minimp3 hier dekodieren)
    for (int i = 0; i < MP3_SAMPLES_PER_FRAME; i++) {
        // Simuliere ein Audiosignal (Sinus mit variabler Frequenz)
        float t = (float)i / 44100.0f;
        short sample = (short)(32767.0f * 0.3f * 
            (sin(440.0f * 2.0f * 3.14159f * t) + 
             sin(880.0f * 2.0f * 3.14159f * t * 0.5f)));
        pcm_out[i * 2] = sample;     // Links
        pcm_out[i * 2 + 1] = sample; // Rechts (Stereo)
    }
    
    *samples_written = MP3_SAMPLES_PER_FRAME;
    ctx->pos += MP3_FRAME_SIZE;
    
    return 0;
}

static void mp3_init(MP3Context *ctx) {
    memset(ctx, 0, sizeof(MP3Context));
}

static void mp3_free(MP3Context *ctx) {
    if (ctx && ctx->buffer) {
        free(ctx->buffer);
        ctx->buffer = NULL;
    }
}

// =============================================================================
// Audio-Player Struktur
// =============================================================================
typedef struct {
    char *filename;
    MP3Context mp3;
    snd_pcm_t *pcm_handle;
    
    // Buffering
    short *pcm_buffer;
    int buffer_frames;
    int current_frame;
    
    // Konfiguration
    unsigned int sample_rate;
    int channels;
} AudioPlayer;

// =============================================================================
// Kernel-Syscall-Interaktionen (kommentiert)
// =============================================================================

/**
 * sys_open() - Öffnet die MP3-Datei
 * entspricht: open(filename, O_RDONLY, 0)
 * 
 * Return: Datei-Deskriptor oder -1 bei Fehler
 */
static int open_audio_file(const char *filename) {
    int fd = open(filename, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "Fehler: Kann Datei '%s' nicht oeffnen: %s\n", 
                filename, strerror(errno));
        return -1;
    }
    printf("[Syscall] open(\"%s\") -> fd=%d\n", filename, fd);
    return fd;
}

/**
 * sys_read() - Liest die MP3-Daten in den Buffer
 * entspricht: read(fd, buffer, size)
 * 
 * Return: Anzahl gelesener Bytes oder -1 bei Fehler
 */
static int read_file_data(int fd, unsigned char **buffer) {
    struct stat st;
    
    // Hole Dateigröße mit fstat
    // =====================================================================
    // sys_fstat() - Kernel-Info über Datei
    // entspricht: fstat(fd, &st)
    // =====================================================================
    if (fstat(fd, &st) < 0) {
        fprintf(stderr, "Fehler: fstat fehlgeschlagen: %s\n", strerror(errno));
        close(fd);
        return -1;
    }
    
    printf("[Syscall] fstat(fd=%d) -> size=%ld\n", fd, st.st_size);
    
    // Alloziere Buffer
    *buffer = (unsigned char *)malloc(st.st_size);
    if (!*buffer) {
        fprintf(stderr, "Fehler: Speicherallokation fehlgeschlagen\n");
        close(fd);
        return -1;
    }
    
    // Lese gesamte Datei
    // =====================================================================
    // sys_read() - Liest Daten von der Datei
    // entspricht: read(fd, buffer, st.st_size)
    // =====================================================================
    ssize_t bytes_read = read(fd, *buffer, st.st_size);
    close(fd);
    
    if (bytes_read < 0) {
        fprintf(stderr, "Fehler: Lesen fehlgeschlagen: %s\n", strerror(errno));
        free(*buffer);
        return -1;
    }
    
    printf("[Syscall] read(fd=%d, size=%ld) -> bytes=%zd\n", 
           fd, st.st_size, bytes_read);
    
    return (int)bytes_read;
}

/**
 * sys_close() - Schließt die Datei
 * entspricht: close(fd)
 */
static void close_file(int fd) {
    if (fd >= 0) {
        // =====================================================================
        // sys_close() - Schließt den Datei-Deskriptor
        // entspricht: close(fd)
        // =====================================================================
        printf("[Syscall] close(fd=%d)\n", fd);
        close(fd);
    }
}

// =============================================================================
// ALSA Audio-Ausgabe (Kernel-Interaktion über ioctl)
// =============================================================================

/**
 * Initialisiert das ALSA PCM-Device
 * 
 * Die ALSA-Library kommuniziert mit dem Kernel über:
 * - snd_pcm_open() -> open("/dev/snd/...", O_RDWR) -> Syscall
 * - snd_pcm_hw_params() -> ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS) -> Syscall
 * - snd_pcm_writei() -> write(fd, frames, count) -> Syscall
 */
static int init_alsa_output(AudioPlayer *player, unsigned int sample_rate, int channels) {
    int err;
    
    // Öffne PCM-Device für Wiedergabe
    // =====================================================================
    // sys_open() - Oeffnet das ALSA-Sound-Device
    // Pfadtypisch: /dev/snd/hwC0D0 oder /dev/snd/pcmC0D0p
    // Dies ist ein virtualisiertes Device, das vom ALSA-Kernel-Treiber verwaltet wird
    // =====================================================================
    err = snd_pcm_open(&player->pcm_handle, "default", 
                     SND_PCM_STREAM_PLAYBACK, 0);
    if (err < 0) {
        fprintf(stderr, "ALSA Fehler: Kann PCM-Device nicht oeffnen: %s\n", 
                snd_strerror(err));
        return -1;
    }
    printf("[ALSA] snd_pcm_open(\"default\", PLAYBACK) -> handle=%p\n", 
           (void*)player->pcm_handle);
    
    // Konfiguriere Hardware-Parameter
    // =====================================================================
    // sys_ioctl() - Konfiguriert das PCM-Device
    // Wichtige ioctls:
    // - SNDRV_PCM_IOCTL_HW_PARAMS: SetztSample-Rate, Format, Channels
    // - SNDRV_PCM_IOCTL_SW_PARAMS: Setzt Software-Parameter
    // =====================================================================
    snd_pcm_hw_params_t *hw_params;
    snd_pcm_hw_params_malloc(&hw_params);
    
    err = snd_pcm_hw_params_any(player->pcm_handle, hw_params);
    if (err < 0) {
        fprintf(stderr, "ALSA Fehler: hw_params_any: %s\n", snd_strerror(err));
        goto cleanup;
    }
    
    //.Setze Zugriff (Interleaved)
    err = snd_pcm_hw_params_set_access(player->pcm_handle, hw_params, 
                                        SND_PCM_ACCESS_RW_INTERLEAVED);
    if (err < 0) {
        fprintf(stderr, "ALSA Fehler: set_access: %s\n", snd_strerror(err));
        goto cleanup;
    }
    
    // Setze Sample-Format (16-bit signed little-endian)
    err = snd_pcm_hw_params_set_format(player->pcm_handle, hw_params, 
                                      SND_PCM_FORMAT_S16_LE);
    if (err < 0) {
        fprintf(stderr, "ALSA Fehler: set_format: %s\n", snd_strerror(err));
        goto cleanup;
    }
    
    // Setze Sample-Rate
    unsigned int rate = sample_rate;
    err = snd_pcm_hw_params_set_rate_near(player->pcm_handle, hw_params, 
                                           &rate, 0);
    if (err < 0) {
        fprintf(stderr, "ALSA Fehler: set_rate: %s\n", snd_strerror(err));
        goto cleanup;
    }
    printf("[ioctl] SNDRV_PCM_IOCTL_SET_RATE -> %u Hz\n", rate);
    
    // Setze Channels
    err = snd_pcm_hw_params_set_channels(player->pcm_handle, hw_params, 
                                         (unsigned int)channels);
    if (err < 0) {
        fprintf(stderr, "ALSA Fehler: set_channels: %s\n", snd_strerror(err));
        goto cleanup;
    }
    
    // Wende Parameter an
    err = snd_pcm_hw_params(player->pcm_handle, hw_params);
    if (err < 0) {
        fprintf(stderr, "ALSA Fehler: hw_params: %s\n", snd_strerror(err));
        goto cleanup;
    }
    
    snd_pcm_hw_params_free(hw_params);
    
    printf("[ALSA] PCM konfiguriert: %u Hz, %d channels, 16-bit LE\n", 
           rate, channels);
    
    return 0;

cleanup:
    snd_pcm_hw_params_free(hw_params);
    snd_pcm_close(player->pcm_handle);
    return -1;
}

/**
 * Schreibt PCM-Daten zum ALSA-Device
 * 
 * =====================================================================
 * sys_write() - Schreibt Audio-Frames zum Device
 * entspricht: write(pcm_fd, buffer, frame_count)
 * 
 * Der ALSA-Treiber übernimmt:
 * - DMA-Transfer zum Sound-Chip
 * - Buffer-Management (Periods/Frames)
 * - Resampling wenn nötig
 * =====================================================================
 */
static int write_audio_output(AudioPlayer *player, short *buffer, int frames) {
    int err;
    
    err = snd_pcm_writei(player->pcm_handle, buffer, frames);
    if (err == -EAGAIN) {
        // Non-blocking: Retry später
        return 0;
    }
    if (err < 0) {
        fprintf(stderr, "ALSA Fehler: write: %s\n", snd_strerror(err));
        
        // Versuche Recovery
        err = snd_pcm_recover(player->pcm_handle, err, 0);
        if (err < 0) {
            fprintf(stderr, "ALSA Fehler: Recovery fehlgeschlagen: %s\n", 
                    snd_strerror(err));
            return -1;
        }
        return 0;
    }
    
    printf("[Syscall] snd_pcm_writei() -> frames=%d\n", err);
    return err;
}

/**
 * Schließt das ALSA-Device
 * 
 * =====================================================================
 * sys_close() - Schließt das PCM-Device
 * entspricht: close(pcm_fd)
 * =====================================================================
 */
static void close_alsa_output(AudioPlayer *player) {
    if (player->pcm_handle) {
        // Drain: Warte auf Wiedergabe-Ende
        snd_pcm_drain(player->pcm_handle);
        snd_pcm_close(player->pcm_handle);
        printf("[Syscall] snd_pcm_close()\n");
        player->pcm_handle = NULL;
    }
}

// =============================================================================
// Haupt-Player-Logik
// =============================================================================

static int audio_player_init(AudioPlayer *player, const char *filename) {
    memset(player, 0, sizeof(AudioPlayer));
    player->filename = strdup(filename);
    player->sample_rate = 44100;  // Standard: 44.1 kHz
    player->channels = 2;         // Stereo
    player->buffer_frames = 4096;  // Buffer-Größe
    
    // Lade MP3-Datei
    int fd = open_audio_file(filename);
    if (fd < 0) return -1;
    
    unsigned char *buffer = NULL;
    int file_size = read_file_data(fd, &buffer);
    if (file_size < 0) return -1;
    
    // Initialisiere MP3-Kontext
    mp3_init(&player->mp3);
    player->mp3.buffer = buffer;
    player->mp3.buffer_size = file_size;
    
    // Alloziere PCM-Buffer
    player->pcm_buffer = (short *)malloc(
        player->buffer_frames * player->channels * sizeof(short));
    if (!player->pcm_buffer) {
        fprintf(stderr, "Fehler: PCM-Buffer allokation fehlgeschlagen\n");
        return -1;
    }
    
    // Initialisiere ALSA
    if (init_alsa_output(player, player->sample_rate, player->channels) < 0) {
        free(player->pcm_buffer);
        return -1;
    }
    
    return 0;
}

static void audio_player_free(AudioPlayer *player) {
    if (player->pcm_handle) {
        close_alsa_output(player);
    }
    
    mp3_free(&player->mp3);
    
    if (player->pcm_buffer) {
        free(player->pcm_buffer);
    }
    
    if (player->filename) {
        free(player->filename);
    }
}

static int audio_player_play(AudioPlayer *player) {
    printf("Starte Wiedergabe...\n");
    
    while (1) {
        // Dekodiere nächsten Frame
        int samples = 0;
        int ret = mp3_decode_frame(&player->mp3, player->pcm_buffer, &samples);
        
        if (ret < 0) {
            printf("Ende der Wiedergabe erreicht.\n");
            break;
        }
        
        // Schreibe zum ALSA-Device
        ret = write_audio_output(player, player->pcm_buffer, samples);
        if (ret < 0) {
            fprintf(stderr, "Fehler bei Wiedergabe\n");
            return -1;
        }
        
        // Kurze Pause zwischen Frames
        usleep(1000);
    }
    
    return 0;
}

// =============================================================================
// Hauptprogramm
// =============================================================================

int main(int argc, char *argv[]) {
    printf("=== MP3 Audio Player fuer Linux x86 ===\n");
    printf("Verwendet ALSA (libasound) + minimp3 (simuliert)\n\n");
    
    if (argc < 2) {
        fprintf(stderr, "Verwendung: %s <mp3_datei>\n", argv[0]);
        fprintf(stderr, "Beispiel: %s musik.mp3\n", argv[0]);
        return 1;
    }
    
    const char *filename = argv[1];
    
    // Prüfe ob Datei existiert
    // =====================================================================
    // sys_stat() - Prüft Dateiexistenz
    // entspricht: stat(filename, &st)
    // =====================================================================
    struct stat st;
    if (stat(filename, &st) < 0) {
        fprintf(stderr, "Fehler: Datei '%s' nicht gefunden: %s\n", 
                filename, strerror(errno));
        return 1;
    }
    
    printf("[Syscall] stat(\"%s\") -> OK (size=%ld bytes)\n", 
           filename, st.st_size);
    
    AudioPlayer player;
    if (audio_player_init(&player, filename) < 0) {
        fprintf(stderr, "Fehler: Player-Initialisierung fehlgeschlagen\n");
        return 1;
    }
    
    // Wiedergabe
    audio_player_play(&player);
    
    // Aufräumen
    audio_player_free(&player);
    
    printf("\n=== Wiedergabe beendet ===\n");
    return 0;
}