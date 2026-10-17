package cn.apt.rootaudio;

import android.content.Context;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioRecordingConfiguration;
import android.media.MediaRecorder;
import android.net.LocalServerSocket;
import android.os.PowerManager;
import android.os.Process;
import android.os.SystemClock;
import java.nio.file.Files;
import java.nio.file.Path;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.Locale;
import org.json.JSONObject;

/** One continuous PCM stream; controller loss, privacy changes and deadlines stop it. */
public final class ProductionCapture {
    public static void main(String[] args) {
        int exit = 1;
        try (LocalServerSocket lease = new LocalServerSocket("cn.apt.rootaudio.capture.v1")) {
            if (args.length != 1 || !args[0].matches("[0-9a-f-]{36}")) throw new SecurityException("capture identity");
            // Publish a kernel process identity before any potentially blocking Binder call.
            try (PrivateDirectory dir = new PrivateDirectory("/data/data/" + RootApp.PACKAGE + "/files/apt-root-recorder/capture-" + args[0], 0, true)) {
                if (!args[0].equals(RootMailbox.uuid(dir.json("source.json"), "captureId"))) throw new SecurityException("source identity");
                dir.write("identity.json", identity(args[0]), true, false);
                Context context = RootPlatform.context(); RootApp app = new RootApp(context);
                exit = capture(context, app, dir);
            }
        } catch (Exception error) { System.out.println("CAPTURE_FAILED type=" + error.getClass().getSimpleName()); }
        System.exit(exit);
    }
    private static int capture(Context context, RootApp app, PrivateDirectory dir) throws Exception {
        JSONObject source = dir.json("source.json");
        String id = RootMailbox.uuid(source, "captureId"), matter = RootMailbox.uuid(source, "matterId");
        int limit = source.getInt("limitSeconds"), chunkSeconds = source.getInt("chunkSeconds"), base = source.getInt("indexBase");
        if (limit < 12 || limit > 43200 || chunkSeconds < 5 || chunkSeconds > 600 || base < 0 || base > 10000)
            throw new SecurityException("capture bounds");
        app.check(true); RootNotice notice = new RootNotice(context, RootApp.PACKAGE);
        AudioManager audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        PowerManager.WakeLock wake = ((PowerManager) context.getSystemService(Context.POWER_SERVICE))
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "APT:RootRecording");
        AudioRecord record = null; WavChunk chunk = null; ReferenceTone reference = null;
        long frames = 0, started = 0, wall = 0, peakLag = 0, tick = 0, lastSync = 0, lastNotice = 0; int index = 0;
        String reason = "limit"; boolean failed = false;
        try {
            if (audio.getMode() != AudioManager.MODE_NORMAL || audio.isMicrophoneMute()
                    || !audio.getActiveRecordingConfigurations().isEmpty()) throw new IllegalStateException("microphone-busy");
            notice.show(0);
            for (int i = 0; i < 20 && !notice.visible(); i++) Thread.sleep(100);
            if (!notice.visible()) throw new IllegalStateException("notification-unavailable");
            beforeStart(dir, id);
            int minimum = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
            if (minimum <= 0) throw new IllegalStateException("audio-format");
            wake.acquire((limit + 20L) * 1000);
            record = new AudioRecord(MediaRecorder.AudioSource.MIC, 16000, AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT, Math.max(minimum, 16000 * 8));
            if (record.getState() != AudioRecord.STATE_INITIALIZED) throw new IllegalStateException("audio-initialize");
            beforeStart(dir, id);
            record.startRecording();
            if (record.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) throw new IllegalStateException("audio-start");
            started = SystemClock.elapsedRealtime(); wall = System.currentTimeMillis();
            chunk = new WavChunk(dir.path, index);
            if (source.optBoolean("reference", false)) reference = new ReferenceTone(started, limit, chunkSeconds);
            short[] buffer = new short[1024]; long target = limit * 16000L, perChunk = chunkSeconds * 16000L;
            while (frames < target) {
                long now = SystemClock.elapsedRealtime();
                if (Files.exists(dir.file("result.json"))) throw new IllegalStateException("controller-restarted");
                if (Files.exists(dir.file("stop"))) { reason = "requested"; break; }
                if (now - started > (limit + 5L) * 1000) throw new IllegalStateException("frame-deadline");
                if (now - tick >= 1000) {
                    app.check(true); dir.check(); guard(audio, record, now - started);
                    if (!notice.visible()) throw new IllegalStateException("notification-removed");
                    if (now - lastNotice > 60000) { notice.show(frames / 16000); lastNotice = now; }
                    ControllerHeartbeat.check(() -> dir.json("parent.json").getLong("elapsed"), SystemClock::elapsedRealtime);
                    if (dir.path.toFile().getUsableSpace() < 192L * 1024 * 1024) throw new IllegalStateException("storage-low");
                    progress(dir, id, frames, index, started, wall, record.getAudioSessionId()); tick = now;
                }
                int count = record.read(buffer, 0, buffer.length, AudioRecord.READ_NON_BLOCKING);
                if (count < 0) throw new IllegalStateException("audio-read");
                if (SystemClock.elapsedRealtime() - started > 3000
                        && SystemClock.elapsedRealtime() - started - frames * 1000 / 16000 > 1000)
                    throw new IllegalStateException("frame-clock-gap");
                if (count == 0) { Thread.sleep(10); continue; }
                guard(audio, record, SystemClock.elapsedRealtime() - started);
                int offset = 0;
                while (offset < count && frames < target) {
                    int n = (int) Math.min(count - offset, Math.min(perChunk - chunk.frames(), target - frames));
                    chunk.append(buffer, offset, n); frames += n; offset += n;
                    if (chunk.frames() == perChunk) {
                        publish(dir, chunk, source, index, frames - chunk.frames(), wall); index++;
                        chunk = frames < target ? new WavChunk(dir.path, index) : null;
                    }
                }
                long lag = SystemClock.elapsedRealtime() - started - frames * 1000 / 16000;
                peakLag = Math.max(peakLag, lag);
                if (SystemClock.elapsedRealtime() - started > 3000 && lag > 1000) throw new IllegalStateException("frame-clock-gap");
                if (chunk != null && now - lastSync >= 5000) { chunk.sync(); lastSync = now; }
                if (reference != null && reference.failed()) throw new IllegalStateException("reference-failed");
            }
        } catch (Exception error) { failed = true; reason = safeReason(error); }
        finally {
            if (record != null) {
                try { if (record.getRecordingState() == AudioRecord.RECORDSTATE_RECORDING) record.stop(); }
                catch (Exception error) { failed = true; reason = "stop-failed"; }
                try { record.release(); } catch (Exception error) { failed = true; reason = "release-failed"; }
            }
            if (reference != null) try { reference.close(); } catch (Exception error) { failed = true; reason = "reference-close"; }
            if (wake.isHeld()) wake.release();
            try { notice.clear(); } catch (Exception error) { failed = true; reason = "notice-clear"; }
        }
        if (chunk != null) {
            try { if (!chunk.isClosed() && chunk.frames() > 0) { publish(dir, chunk, source, index, frames - chunk.frames(), wall); index++; } }
            catch (Exception error) { failed = true; reason = "tail-pending"; }
            finally { chunk.close(); }
        }
        dir.write("result.json", new JSONObject().put("captureId", id).put("matterId", matter)
                .put("state", failed ? "failed" : "stopped").put("reason", reason).put("frames", frames)
                .put("chunks", index).put("startedAt", wall).put("peakLagMs", peakLag), true, false);
        return failed ? 1 : 0;
    }
    private static void guard(AudioManager audio, AudioRecord record, long elapsed) throws Exception {
        if (audio.getMode() != AudioManager.MODE_NORMAL || audio.isMicrophoneMute()) throw new IllegalStateException("privacy-or-call");
        AudioRecordingConfiguration own = record.getActiveRecordingConfiguration();
        if (own == null) { if (elapsed > 2000) throw new IllegalStateException("identity-unconfirmed"); }
        else if ((Integer) own.getClass().getMethod("getClientUid").invoke(own) != 0
                || own.getClientAudioSessionId() != record.getAudioSessionId() || own.isClientSilenced())
            throw new IllegalStateException("silenced-or-identity");
        for (AudioRecordingConfiguration config : audio.getActiveRecordingConfigurations())
            if (config.getClientAudioSessionId() != record.getAudioSessionId()) throw new IllegalStateException("other-capture");
    }
    private static void beforeStart(PrivateDirectory dir, String id) throws Exception {
        if (Files.exists(dir.file("result.json")) || Files.exists(dir.file("stop"))) throw new IllegalStateException("cancelled-before-start");
        try (PrivateDirectory parent = new PrivateDirectory(dir.canonical.substring(0, dir.canonical.lastIndexOf('/')), 0, true)) {
            if (Files.exists(parent.file("cancel-" + id + ".json"))) throw new IllegalStateException("cancelled-before-start");
        }
        ControllerHeartbeat.check(() -> dir.json("parent.json").getLong("elapsed"), SystemClock::elapsedRealtime);
    }
    private static String safeReason(Exception error) {
        String text = error.getMessage(); return text != null && text.matches("[a-z-]{1,40}") ? text : "capture-guard";
    }
    private static void progress(PrivateDirectory dir, String id, long frames, int chunks, long start, long wall, int session) throws Exception {
        dir.write("progress.json", identity(id)
                .put("frames", frames).put("chunks", chunks).put("startedAt", wall).put("startedElapsed", start)
                .put("updatedElapsed", SystemClock.elapsedRealtime()).put("audioSession", session), false, false);
    }
    private static JSONObject identity(String id) throws Exception {
        String stat = new String(Files.readAllBytes(java.nio.file.Paths.get("/proc/self/stat")), java.nio.charset.StandardCharsets.US_ASCII);
        String ticks = stat.substring(stat.lastIndexOf(')') + 2).split(" ")[19];
        return new JSONObject().put("captureId", id).put("pid", Process.myPid()).put("startTicks", ticks);
    }
    private static void publish(PrivateDirectory dir, WavChunk chunk, JSONObject source, int index, long offset, long wall) throws Exception {
        dir.check(); chunk.commit();
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream in = Files.newInputStream(chunk.completedPath())) { byte[] buffer = new byte[65536]; for (int n; (n = in.read(buffer)) > 0;) digest.update(buffer, 0, n); }
        StringBuilder hash = new StringBuilder(); for (byte b : digest.digest()) hash.append(String.format(Locale.ROOT, "%02x", b & 255));
        // Compact captures publish completed PCM to the independent encoder first.
        // No MediaCodec/Binder operation runs on this continuous AudioRecord thread.
        dir.write(String.format(Locale.ROOT, "m4a".equals(source.optString("audioFormat")) ? "pcm-%04d.json" : "chunk-%04d.json", index), new JSONObject().put("captureId", source.getString("captureId"))
                .put("matterId", source.getString("matterId")).put("index", source.getInt("indexBase") + index)
                .put("piece", index).put("frames", chunk.frames()).put("frameOffset", offset).put("capturedAt", wall + offset * 1000 / 16000)
                .put("size", Files.size(chunk.completedPath())).put("sha256", hash.toString())
                .put("cloudEligible", !source.optBoolean("validation", false)), true, false);
    }
}
