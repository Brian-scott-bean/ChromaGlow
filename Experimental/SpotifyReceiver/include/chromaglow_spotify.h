// chromaglow_spotify.h — C ABI of the LOCAL-ONLY Spotify Connect receiver
// experiment (Experimental/SpotifyReceiver, Rust over a pinned librespot).
//
// Only ever imported under CHROMAGLOW_EXPERIMENTAL_SPOTIFY. Keep CGSpotifyStatus
// in lockstep with src/state.rs.

#ifndef CHROMAGLOW_SPOTIFY_H
#define CHROMAGLOW_SPOTIFY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Receiver lifecycle (CGSpotifyStatus.state).
enum {
    CGSpotifyStateStopped = 0,
    CGSpotifyStateStarting = 1,
    CGSpotifyStateWaiting = 2,     // advertised over Bonjour, waiting for a Spotify app
    CGSpotifyStateConnecting = 3,  // credentials handed over, logging in
    CGSpotifyStateConnected = 4,
    CGSpotifyStateFailed = 5,
};

/// Player state (CGSpotifyStatus.playback).
enum {
    CGSpotifyPlaybackIdle = 0,
    CGSpotifyPlaybackLoading = 1,
    CGSpotifyPlaybackPlaying = 2,
    CGSpotifyPlaybackPaused = 3,
};

/// Connect hand-off (CGSpotifyStatus.handoff).
enum {
    CGSpotifyHandoffNone = 0,       // not picked in this session
    CGSpotifyHandoffActive = 1,     // Spotify plays on this device
    CGSpotifyHandoffMovedAway = 2,  // was active; Spotify moved playback elsewhere
};

/// cg_spotify_command codes.
enum {
    CGSpotifyCommandPlay = 1,
    CGSpotifyCommandPause = 2,
    CGSpotifyCommandPlayPause = 3,
    CGSpotifyCommandNext = 4,
    CGSpotifyCommandPrevious = 5,
    CGSpotifyCommandBringHere = 6,  // transfer playback back to this device
};

typedef struct CGSpotifyStatus {
    uint64_t generation;
    uint32_t state;
    uint32_t playback;
    uint32_t sample_rate;
    uint32_t channels;
    uint32_t zeroconf_port;
    uint32_t volume;              // Spotify's 0…65535 device volume
    uint32_t track_serial;        // bumps on every track change
    uint32_t playback_queued_frames;
    uint32_t first_pcm_ms;        // play request → first PCM chunk (ms; 0 = n/a)
    uint32_t handoff;             // CGSpotifyHandoff*
    uint32_t position_ms;         // track position when last reported…
    uint32_t position_age_ms;     // …and how long ago (add while playing)
    uint32_t duration_ms;
    uint64_t frames_delivered;    // frames handed to the PCM callback
    uint64_t chunks_delivered;
    uint64_t underruns;           // playback pulls that came up short
    float last_peak;              // peak |sample| of the latest chunk
    char title[256];
    char artist[256];
    char remote_client[128];      // the Spotify app driving this device
    char message[256];            // latest progress / error note (no secrets)
} CGSpotifyStatus;

/// PCM callback: interleaved float samples on librespot's player thread,
/// paced to real time. Must be real-time-cheap; never retain `samples`.
/// `queued_frames` = frames already queued for playback ahead of this chunk.
typedef void (*CGSpotifyPCMCallback)(uint64_t generation,
                                     const float *samples,
                                     uint32_t frames,
                                     uint32_t channels,
                                     uint32_t sample_rate,
                                     uint32_t queued_frames);

/// Start advertising `device_name` as a Spotify Connect device. Stops any
/// previous receiver first. Returns the new generation (> 0) or 0 on bad args.
uint64_t cg_spotify_start(const char *device_name,
                          const char *temp_dir,
                          CGSpotifyPCMCallback pcm_callback);

/// Stop and join (may block a few seconds — call off the main thread). The PCM
/// gate closes before it blocks.
void cg_spotify_stop(void);

/// Copy the current/last receiver status. False before the first start.
bool cg_spotify_status(CGSpotifyStatus *out);

/// Phase 2: enable pull-mode playback with a target queue depth in frames.
void cg_spotify_set_playback(bool enabled, uint32_t target_frames);

/// Phase 2, render thread: pull up to `frames` interleaved stereo frames into
/// `out` (zero-fills the remainder). Real-time safe. Returns frames read.
uint32_t cg_spotify_read_playback(float *out, uint32_t frames);

/// Phase 2 diagnostics: playback is enabled and the render thread is pulling.
bool cg_spotify_playback_live(void);

/// Identity for the NEXT start: true = librespot's desktop-Linux speaker
/// (default), false = the build target's own identity (iPhone on iOS).
void cg_spotify_set_persona(bool desktop_linux);

/// Copy the recent sanitised receiver log (newest lines kept when truncated).
/// NUL-terminated; returns bytes copied excluding the NUL. No account names,
/// credential blobs or tokens ever reach it.
size_t cg_spotify_copy_log(char *out, size_t capacity);

/// Send a CGSpotifyCommand*. Non-blocking. False without a Connect session or
/// for an unknown code. Play/Pause/Next/Previous act only while this device is
/// active; BringHere transfers playback back to it when it isn't.
bool cg_spotify_command(uint32_t command);

/// Static string naming the pinned librespot revision.
const char *cg_spotify_librespot_revision(void);

#ifdef __cplusplus
}
#endif

#endif // CHROMAGLOW_SPOTIFY_H
