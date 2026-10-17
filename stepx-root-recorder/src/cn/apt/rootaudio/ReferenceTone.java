package cn.apt.rootaudio;

import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.os.SystemClock;
import java.util.concurrent.atomic.AtomicBoolean;

/** Optional acoustic evidence for research, with bounded playback and explicit release. */
public final class ReferenceTone implements AutoCloseable {
    private final AtomicBoolean stop = new AtomicBoolean();
    private final Thread thread;
    private volatile AudioTrack track;
    private volatile boolean failed;

    public ReferenceTone(long started, int totalSeconds, int chunkSeconds) {
        thread = new Thread(() -> {
            try {
                for (int at = 5, number = 0; at < totalSeconds; at += chunkSeconds, number++) {
                    while (!stop.get() && SystemClock.elapsedRealtime() - started < at * 1000L)
                        SystemClock.sleep(50);
                    if (stop.get()) return;
                    play(new int[] { 997, 1499, 1999 }[number % 3]);
                }
            } catch (Exception error) {
                if (!stop.get()) {
                    failed = true;
                    System.out.println("REFERENCE_ERROR type=" + error.getClass().getSimpleName());
                    System.out.flush();
                }
            }
        }, "apt-root-reference");
        thread.setDaemon(true);
        thread.start();
    }
    public boolean failed() { return failed; }
    private void play(int hz) throws Exception {
        int rate = WavChunk.RATE;
        int minimum = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT);
        if (minimum <= 0) throw new IllegalStateException("reference format");
        AudioTrack current = new AudioTrack(AudioManager.STREAM_MUSIC, rate,
                AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
                Math.max(minimum, rate * 2), AudioTrack.MODE_STREAM);
        track = current;
        try {
            if (current.getState() != AudioTrack.STATE_INITIALIZED)
                throw new IllegalStateException("reference initialization");
            int total = rate * 4;
            short[] samples = new short[1024];
            current.play();
            for (int offset = 0; offset < total && !stop.get();) {
                int count = Math.min(samples.length, total - offset);
                for (int i = 0; i < count; i++) {
                    double t = (offset + i) / (double) rate;
                    double edge = Math.min(1, Math.max(0, Math.min(t - 1.5, 2.25 - t)) * 100);
                    samples[i] = t < 1.5 || t >= 2.25 ? 0
                            : (short) (8192 * edge * Math.sin(2 * Math.PI * hz * t));
                }
                int sent = 0;
                while (sent < count && !stop.get()) {
                    int n = current.write(samples, sent, count - sent);
                    if (n <= 0) throw new IllegalStateException("reference write");
                    sent += n;
                }
                offset += count;
            }
            long drain = SystemClock.elapsedRealtime();
            while (!stop.get() && current.getPlaybackHeadPosition() < total
                    && SystemClock.elapsedRealtime() - drain < 4000) SystemClock.sleep(25);
            if (!stop.get() && current.getPlaybackHeadPosition() < total)
                throw new IllegalStateException("reference drain");
            if (!stop.get()) {
                System.out.println("REFERENCE hz=" + hz + " playedFrames=" + current.getPlaybackHeadPosition()
                        + " elapsedRealtimeMs=" + SystemClock.elapsedRealtime());
                System.out.flush();
            }
        } finally {
            try { if (current.getPlayState() == AudioTrack.PLAYSTATE_PLAYING) current.stop(); }
            finally { current.release(); track = null; }
        }
    }
    @Override public void close() throws Exception {
        stop.set(true);
        AudioTrack current = track;
        if (current != null) {
            try { current.pause(); } catch (IllegalStateException ignored) {}
        }
        thread.join(5000);
        if (thread.isAlive()) throw new IllegalStateException("reference did not stop");
    }
}
