package cn.apt.rootaudio;

import android.content.Context;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioRecordingConfiguration;
import android.media.MediaRecorder;
import android.net.LocalServerSocket;
import android.os.Looper;
import android.os.PowerManager;
import android.os.Process;
import android.os.SystemClock;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;
import java.io.FileDescriptor;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.util.UUID;

/** Research-only root capture. Explicit upper bound; no networking or app material writes. */
public final class RootRecordingSession {
    private static final int RATE = WavChunk.RATE;
    private static final String VERSION = "0.1.0-research";
    private static final class GuardStop extends Exception {
        GuardStop(String reason) { super(reason); }
    }

    public static void main(String[] args) {
        int exit = 1;
        try { exit = run(args); }
        catch (Exception error) {
            System.out.println("FAILED type=" + error.getClass().getSimpleName());
            System.out.flush();
        }
        // Media framework threads can outlive a command's main(). Resource cleanup
        // is completed by run() first; an outer OS watchdog is required as well.
        System.exit(exit);
    }

    private static int run(String[] args) throws Exception {
        if (Process.myUid() != 0) throw new IllegalStateException("root required");
        // An abstract socket is an OS-owned lease: no stale lock after a crash,
        // no root pathname under the shell-writable /data/local/tmp directory.
        // It accepts no commands or connections and is held through cleanup.
        try (LocalServerSocket lease = new LocalServerSocket("cn.apt.rootaudio.research.v1")) {
            return capture(args);
        }
    }

    private static int capture(String[] args) throws Exception {
        if (args.length < 3 || args.length > 4 || args.length == 4 && !args[3].equals("reference"))
            throw new IllegalArgumentException("directory totalSeconds chunkSeconds [reference]");
        int seconds = Integer.parseInt(args[1]), chunkSeconds = Integer.parseInt(args[2]);
        if (seconds < 12 || seconds > 900 || chunkSeconds < 5 || chunkSeconds > 300)
            throw new IllegalArgumentException("bounded duration required");
        Path dir = Paths.get(args[0]).toAbsolutePath();
        if (!dir.toString().startsWith("/data/local/tmp/apt-root-audio.")
                || !dir.toString().equals(dir.toFile().getCanonicalPath()))
            throw new IllegalArgumentException("isolated directory required");
        StructStat stat = Os.lstat(dir.toString());
        if (!OsConstants.S_ISDIR(stat.st_mode) || stat.st_uid != 0 || (stat.st_mode & 077) != 0)
            throw new IllegalArgumentException("root-private directory required");
        if (dir.toFile().getUsableSpace() < seconds * (long) RATE * 2 + 16 * 1024 * 1024)
            throw new IllegalStateException("insufficient free space");
        // A used directory is never reused, even after failure. This is an atomic
        // start claim, not a check-then-open convention.
        Files.createFile(dir.resolve(".session.claim"));
        String identity = UUID.randomUUID().toString();
        Files.write(dir.resolve("pid"), Integer.toString(Process.myPid()).getBytes(StandardCharsets.US_ASCII));
        syncDirectory(dir);
        if (Looper.myLooper() == null) Looper.prepareMainLooper();
        Object app = Class.forName("android.app.ActivityThread").getMethod("systemMain").invoke(null);
        Context context = (Context) app.getClass().getMethod("getSystemContext").invoke(app);
        AudioManager audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (audio == null || audio.getMode() != AudioManager.MODE_NORMAL
                || !audio.getActiveRecordingConfigurations().isEmpty())
            throw new GuardStop("microphone-busy-before-start");
        PowerManager power = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        if (power == null) throw new IllegalStateException("power service unavailable");
        PowerManager.WakeLock awake = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "APT:RootRecordingResearch");
        AudioRecord record = null;
        ReferenceTone reference = null;
        WavChunk chunk = null;
        long frames = 0, wall = 0, started = 0, peakLag = 0;
        int sequence = 0;
        String reason = "limit";
        boolean failed = false;
        try {
            awake.acquire((seconds + 20L) * 1000);
            int minimum = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT);
            if (minimum <= 0) throw new IllegalStateException("unsupported format");
            record = new AudioRecord(MediaRecorder.AudioSource.MIC, RATE,
                    AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                    Math.max(minimum, RATE * 2 * 4));
            if (record.getState() != AudioRecord.STATE_INITIALIZED)
                throw new IllegalStateException("record initialization");
            record.startRecording();
            if (record.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING)
                throw new IllegalStateException("record start");
            started = SystemClock.elapsedRealtime(); wall = System.currentTimeMillis();
            int session = record.getAudioSessionId();
            System.out.println("START version=" + VERSION + " uid=" + Process.myUid()
                    + " pid=" + Process.myPid() + " session=" + session + " identity=" + identity
                    + " seconds=" + seconds + " chunkSeconds=" + chunkSeconds);
            System.out.flush();
            immutableJson(dir.resolve("session.json"), "{\"version\":1,\"id\":\"" + identity
                    + "\",\"uid\":0,\"pid\":" + Process.myPid() + ",\"startedAt\":" + wall
                    + ",\"elapsedRealtimeStart\":" + started + ",\"sampleRate\":16000,\"channels\":1,\"totalSeconds\":"
                    + seconds + ",\"chunkSeconds\":" + chunkSeconds + "}");
            chunk = new WavChunk(dir, sequence);
            if (args.length == 4) reference = new ReferenceTone(started, seconds, chunkSeconds);
            short[] buffer = new short[1024];
            long totalFrames = seconds * (long) RATE, chunkFrames = chunkSeconds * (long) RATE;
            long lastTick = started, lastSync = started;
            while (frames < totalFrames) {
                if (Files.exists(dir.resolve("stop"))) { reason = "requested"; break; }
                long now = SystemClock.elapsedRealtime();
                if (now - started > (seconds + 5L) * 1000) throw new GuardStop("frame-deadline");
                guard(audio, record, now - started);
                int count = record.read(buffer, 0, buffer.length);
                if (count <= 0) throw new GuardStop("audio-read-code-" + count);
                // Do not persist a buffer read while a call, competing capture or
                // privacy mute started. Root's concurrent-policy privilege is not
                // used to intentionally record through those changes.
                guard(audio, record, SystemClock.elapsedRealtime() - started);
                if (Files.exists(dir.resolve("stop"))) { reason = "requested"; break; }
                if (reference != null && reference.failed()) throw new GuardStop("reference-failed");
                int offset = 0;
                while (offset < count && frames < totalFrames) {
                    int write = (int) Math.min(count - offset,
                            Math.min(chunkFrames - chunk.frames(), totalFrames - frames));
                    chunk.append(buffer, offset, write); frames += write; offset += write;
                    if (chunk.frames() == chunkFrames) {
                        publish(dir, chunk, identity, sequence, frames - chunk.frames(), wall);
                        sequence++;
                        chunk = frames < totalFrames ? new WavChunk(dir, sequence) : null;
                    }
                }
                now = SystemClock.elapsedRealtime();
                long lag = now - started - frames * 1000 / RATE;
                peakLag = Math.max(peakLag, lag);
                if (now - started > 3000 && lag > 1000) throw new GuardStop("frame-clock-gap");
                if (chunk != null && now - lastSync > 5000) { chunk.sync(); lastSync = now; }
                if (now - lastTick >= 10000) {
                    System.out.println("TICK elapsedMs=" + (now - started) + " frames=" + frames
                            + " chunks=" + sequence + " frameLagMs=" + lag);
                    System.out.flush(); lastTick = now;
                }
            }
        } catch (GuardStop stop) { reason = stop.getMessage(); failed = !reason.equals("requested"); }
        catch (Exception error) { reason = "failure-" + error.getClass().getSimpleName(); failed = true; }
        finally {
            if (record != null) {
                try { if (record.getRecordingState() == AudioRecord.RECORDSTATE_RECORDING) record.stop(); }
                catch (Exception error) { failed = true; reason = "record-stop-failed"; }
                try { record.release(); }
                catch (Exception error) { failed = true; reason = "record-release-failed"; }
            }
            if (reference != null) {
                try { reference.close(); }
                catch (Exception error) { failed = true; reason = "reference-close-failed"; }
            }
            try { if (awake.isHeld()) awake.release(); }
            catch (Exception error) { failed = true; reason = "wake-release-failed"; }
        }
        if (chunk != null) {
            try {
                if (!chunk.isClosed() && chunk.frames() > 0) {
                    publish(dir, chunk, identity, sequence, frames - chunk.frames(), wall);
                    sequence++;
                }
            } catch (Exception error) { failed = true; reason = "chunk-commit-failed"; }
            finally {
                try { chunk.close(); }
                catch (Exception error) { failed = true; reason = "chunk-close-failed"; }
            }
        }
        immutableJson(dir.resolve("result.json"), "{\"version\":1,\"sessionId\":\"" + identity
                + "\",\"state\":\"" + (failed ? "failed" : "stopped") + "\",\"reason\":\"" + reason
                + "\",\"frames\":" + frames + ",\"chunks\":" + sequence
                + ",\"peakFrameLagMs\":" + peakLag + ",\"referenceRequested\":" + (args.length == 4) + "}");
        System.out.println("DONE state=" + (failed ? "failed" : "stopped") + " reason=" + reason
                + " frames=" + frames + " chunks=" + sequence + " peakFrameLagMs=" + peakLag);
        System.out.flush();
        return failed ? 1 : 0;
    }

    private static void guard(AudioManager audio, AudioRecord record, long elapsed) throws Exception {
        if (audio.getMode() != AudioManager.MODE_NORMAL) throw new GuardStop("call-mode");
        AudioRecordingConfiguration own = record.getActiveRecordingConfiguration();
        if (own == null) {
            if (elapsed > 2000) throw new GuardStop("identity-unconfirmed");
        } else {
            int uid = (Integer) own.getClass().getMethod("getClientUid").invoke(own);
            if (uid != 0 || own.getClientAudioSessionId() != record.getAudioSessionId())
                throw new GuardStop("identity-mismatch");
            if (own.isClientSilenced()) throw new GuardStop("microphone-muted");
        }
        for (AudioRecordingConfiguration config : audio.getActiveRecordingConfigurations())
            if (config.getClientAudioSessionId() != record.getAudioSessionId())
                throw new GuardStop("other-capture");
    }
    private static void publish(Path dir, WavChunk chunk, String id, int index, long offset, long wall)
            throws Exception {
        chunk.commit(); syncDirectory(dir);
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream file = Files.newInputStream(chunk.completedPath())) {
            byte[] buffer = new byte[65536];
            for (int count; (count = file.read(buffer)) != -1;) digest.update(buffer, 0, count);
        }
        StringBuilder hash = new StringBuilder();
        for (byte b : digest.digest()) hash.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
        immutableJson(dir.resolve(String.format(java.util.Locale.ROOT, "chunk-%04d.json", index)),
                "{\"version\":1,\"sessionId\":\"" + id + "\",\"index\":" + index
                + ",\"frameOffset\":" + offset + ",\"frames\":" + chunk.frames()
                + ",\"capturedAt\":" + (wall + offset * 1000 / RATE)
                + ",\"sampleRate\":16000,\"channels\":1,\"size\":" + Files.size(chunk.completedPath())
                + ",\"sha256\":\"" + hash + "\",\"cloudEligible\":false}");
        System.out.println("COMMIT index=" + index + " frameOffset=" + offset + " frames=" + chunk.frames());
        System.out.flush();
    }
    private static void immutableJson(Path path, String json) throws Exception {
        Path pending = path.resolveSibling(path.getFileName().toString() + ".pending");
        Files.createFile(pending);
        try (java.io.FileOutputStream out = new java.io.FileOutputStream(pending.toFile())) {
            out.write((json + "\n").getBytes(StandardCharsets.UTF_8)); out.getFD().sync();
        }
        Files.createLink(path, pending); Files.delete(pending); syncDirectory(path.getParent());
    }
    private static void syncDirectory(Path dir) throws Exception {
        FileDescriptor fd = Os.open(dir.toString(), OsConstants.O_RDONLY, 0);
        try {
            if (!OsConstants.S_ISDIR(Os.fstat(fd).st_mode)) throw new IllegalArgumentException("directory changed");
            Os.fsync(fd);
        } finally { Os.close(fd); }
    }
}
