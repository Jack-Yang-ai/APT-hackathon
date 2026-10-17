package cn.apt.rootaudio;

import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;
import android.media.AudioFormat;
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.os.SystemClock;
import java.io.FileDescriptor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.Locale;
import org.json.JSONObject;

/** Runs only in the bounded transport child, after the PCM file has closed. */
final class RootPcmCompression {
    static String name(int index, String suffix) { return String.format(Locale.ROOT, "%s-%04d.json", suffix, index); }
    static String hash(Path path) throws Exception {
        FileDescriptor input = Os.open(path.toString(), OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW, 0);
        try {
            StructStat stat = Os.fstat(input);
            if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_uid != 0 || stat.st_gid != 0 || (stat.st_mode & 002) != 0
                    || stat.st_size < 46 || stat.st_size > 19200044) throw new SecurityException("audio recovery identity");
            MessageDigest digest = MessageDigest.getInstance("SHA-256"); byte[] buffer = new byte[65536]; long read = 0;
            while (read < stat.st_size) {
                int n = Os.read(input, buffer, 0, (int)Math.min(buffer.length, stat.st_size - read));
                if (n <= 0) throw new SecurityException("audio recovery truncated"); digest.update(buffer, 0, n); read += n;
            }
            StringBuilder sha = new StringBuilder(); for (byte b : digest.digest()) sha.append(String.format(Locale.ROOT, "%02x", b & 255));
            return sha.toString();
        } finally { Os.close(input); }
    }
    static void prepare(PrivateDirectory dir, JSONObject source, int index) throws Exception {
        if (!"m4a".equals(source.optString("audioFormat")) || index < 0 || index > 8640) throw new SecurityException("compression source");
        if (Files.exists(dir.file(name(index, "chunk")))) return; // Format identity is immutable after first publication.
        JSONObject pcm = dir.json(name(index, "pcm"));
        long frames = pcm.getLong("frames");
        if (!RootMailbox.uuid(source,"captureId").equals(RootMailbox.uuid(pcm,"captureId"))
                || !RootMailbox.uuid(source,"matterId").equals(RootMailbox.uuid(pcm,"matterId")) || pcm.getInt("piece") != index
                || pcm.getInt("index") != source.getInt("indexBase") + index
                || pcm.getLong("frameOffset") != index * source.getInt("chunkSeconds") * 16000L
                || frames < 1 || frames > source.getInt("chunkSeconds") * 16000L || pcm.getLong("size") != 44 + frames * 2)
            throw new SecurityException("compression piece");
        Path path = dir.file(String.format(Locale.ROOT,"chunk-%04d.wav",index));
        if (!pcm.getString("sha256").equals(hash(path))) throw new SecurityException("compression PCM hash");
        JSONObject published = new JSONObject(pcm.toString());
        AacChunk encoder = null;
        FileDescriptor input = Os.open(path.toString(), OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW, 0);
        try {
            StructStat stat = Os.fstat(input);
            if (stat.st_size != pcm.getLong("size")) throw new SecurityException("compression PCM size");
            byte[] header = new byte[44];
            if (Os.read(input, header, 0, 44) != 44) throw new SecurityException("compression PCM header");
            ByteBuffer view = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN);
            if (view.getInt(0) != 0x46464952 || view.getInt(8) != 0x45564157 || view.getInt(12) != 0x20746d66
                    || view.getInt(36) != 0x61746164 || view.getInt(4) != stat.st_size - 8 || view.getInt(16) != 16
                    || view.getInt(24) != 16000 || view.getShort(20) != 1 || view.getShort(22) != 1 || view.getShort(34) != 16
                    || view.getInt(28) != 32000 || view.getShort(32) != 2 || view.getInt(40) != frames * 2)
                throw new SecurityException("compression PCM format");
            try {
                encoder = new AacChunk(dir.path, index);
                byte[] bytes = new byte[8192]; short[] samples = new short[4096]; long remaining = frames * 2;
                boolean signal = false;
                while (remaining > 0) {
                    int n = Os.read(input, bytes, 0, (int)Math.min(bytes.length, remaining));
                    if (n <= 0 || n % 2 != 0) throw new SecurityException("compression PCM read");
                    for (int i = 0; i < n / 2; i++) { samples[i] = (short)((bytes[i * 2] & 255) | (bytes[i * 2 + 1] << 8)); signal |= samples[i] != 0; }
                    encoder.append(samples, 0, n / 2); remaining -= n;
                }
                encoder.commit(frames);
                verifyAac(encoder.completedPath(),frames,signal);
                published.put("audioFormat","m4a").put("decodedVerified",true).put("pcmSha256",pcm.getString("sha256"))
                        .put("sha256",hash(encoder.completedPath())).put("size",Files.size(encoder.completedPath()));
            } catch (Exception unavailable) {
                // A failed or previously interrupted encoder can only publish the original PCM.
                published = new JSONObject(pcm.toString()).put("audioFormat","wav").put("compressionFallback",true);
            }
        } finally { if (encoder != null) encoder.close(); Os.close(input); }
        dir.write(name(index,"chunk"), published, true, false);
    }
    private static void verifyAac(Path path,long frames,boolean sourceSignal) throws Exception {
        FileDescriptor descriptor = Os.open(path.toString(),OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW,0);
        MediaExtractor extractor = new MediaExtractor(); MediaCodec decoder = null;
        try {
            StructStat stat = Os.fstat(descriptor);
            if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_uid != 0 || stat.st_size > 19200044) throw new SecurityException("AAC decode identity");
            extractor.setDataSource(descriptor,0,stat.st_size);
            if (extractor.getTrackCount() != 1) throw new SecurityException("AAC decode tracks");
            MediaFormat format = extractor.getTrackFormat(0);
            if (!MediaFormat.MIMETYPE_AUDIO_AAC.equals(format.getString(MediaFormat.KEY_MIME))
                    || format.getInteger(MediaFormat.KEY_SAMPLE_RATE) != 16000 || format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) != 1)
                throw new SecurityException("AAC decode format");
            extractor.selectTrack(0); decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC);
            decoder.configure(format,null,null,0); decoder.start();
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo(); long decoded = 0, until = SystemClock.elapsedRealtime() + 20000;
            boolean inputDone = false, outputDone = false, signal = false;
            while (!outputDone) {
                if (SystemClock.elapsedRealtime() > until) throw new IllegalStateException("AAC decode deadline");
                if (!inputDone) {
                    int input = decoder.dequeueInputBuffer(0);
                    if (input >= 0) {
                        ByteBuffer bytes = decoder.getInputBuffer(input); bytes.clear(); int n = extractor.readSampleData(bytes,0);
                        if (n < 0) { decoder.queueInputBuffer(input,0,0,0,MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true; }
                        else { decoder.queueInputBuffer(input,0,n,Math.max(0,extractor.getSampleTime()),0); extractor.advance(); }
                    }
                }
                int output = decoder.dequeueOutputBuffer(info,1000);
                if (output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat decodedFormat = decoder.getOutputFormat();
                    if (decodedFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE) != 16000 || decodedFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT) != 1
                            || decodedFormat.containsKey(MediaFormat.KEY_PCM_ENCODING) && decodedFormat.getInteger(MediaFormat.KEY_PCM_ENCODING) != AudioFormat.ENCODING_PCM_16BIT)
                        throw new SecurityException("AAC decoded PCM format");
                } else if (output >= 0) {
                    try {
                        if (info.size % 2 != 0) throw new SecurityException("AAC decoded frame size");
                        if (info.size > 0) {
                            ByteBuffer bytes = decoder.getOutputBuffer(output).order(ByteOrder.LITTLE_ENDIAN);
                            for (int i = info.offset; i < info.offset + info.size; i += 2) signal |= bytes.getShort(i) != 0;
                        }
                        decoded += info.size / 2;
                        if (decoded > frames + 4096) throw new SecurityException("AAC decoded extra frames");
                        outputDone = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
                    } finally { decoder.releaseOutputBuffer(output,false); }
                }
            }
            if (decoded < frames || sourceSignal && !signal) throw new SecurityException("AAC decoded missing audio");
        } finally {
            if (decoder != null) { try { decoder.stop(); } catch (Exception ignored) {} try { decoder.release(); } catch (Exception ignored) {} }
            extractor.release(); Os.close(descriptor);
        }
    }
    static void releaseRecovery(PrivateDirectory dir, JSONObject source, JSONObject piece, JSONObject expected) throws Exception {
        int index = piece.getInt("piece");
        if (!"m4a".equals(source.optString("audioFormat")) || !"m4a".equals(piece.optString("audioFormat"))
                || !piece.optBoolean("decodedVerified",false)
                || !piece.optString("pcmSha256").matches("[0-9a-f]{64}") || !RootUploader.confirmed(dir,index,expected)) return;
        if (RootPipeline.enabled(source) && !RootPipeline.confirmed(dir,source,index)) return;
        Path backup = dir.file(String.format(Locale.ROOT,"chunk-%04d.wav",index));
        if (!Files.exists(backup)) return;
        // Keep the compressed native original as well as the App's durable copy.
        if (!piece.getString("sha256").equals(hash(dir.file(String.format(Locale.ROOT,"chunk-%04d.m4a",index))))
                || !piece.getString("pcmSha256").equals(hash(backup))) throw new SecurityException("recovery release identity");
        dir.check(); Files.delete(backup);
        dir.write(String.format(Locale.ROOT,"pcm-%04d.released.json",index),new JSONObject().put("sha256",piece.getString("pcmSha256")),true,false);
    }
}
