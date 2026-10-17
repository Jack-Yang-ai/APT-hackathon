package cn.apt.rootaudio;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.os.SystemClock;
import android.system.Os;
import android.system.OsConstants;
import java.io.FileDescriptor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;

/** Optional AAC sidecar. The continuous recorder always keeps its PCM recovery file. */
final class AacChunk implements AutoCloseable {
    static final int BIT_RATE = 32000;
    private final Path pending, complete;
    private MediaCodec codec;
    private MediaMuxer muxer;
    private FileDescriptor descriptor;
    private int track = -1;
    private long frames;
    private boolean started, closed, eos;

    AacChunk(Path directory, int index) throws Exception {
        if (index < 0 || index > 9999) throw new IllegalArgumentException("AAC index");
        String stem = String.format(java.util.Locale.ROOT, "chunk-%04d", index);
        pending = directory.resolve(stem + ".pending.m4a"); complete = directory.resolve(stem + ".m4a");
        if (Files.exists(complete)) throw new IllegalStateException("AAC already complete");
        try {
            descriptor = Os.open(pending.toString(), OsConstants.O_WRONLY | OsConstants.O_CREAT
                    | OsConstants.O_EXCL | OsConstants.O_NOFOLLOW, 0600);
            muxer = new MediaMuxer(descriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
            MediaFormat format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, 16000, 1);
            format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);
            format.setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE);
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8192);
            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC);
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); codec.start();
        } catch (Exception error) { close(); throw error; }
    }
    Path completedPath() { return complete; }
    void append(short[] samples, int offset, int count) throws Exception {
        if (closed || count < 0 || offset < 0 || offset + count > samples.length) throw new IllegalArgumentException("AAC samples");
        long until = SystemClock.elapsedRealtime() + 200;
        while (count > 0) {
            drain(false);
            int input = codec.dequeueInputBuffer(0);
            if (input < 0) {
                if (SystemClock.elapsedRealtime() > until) throw new IllegalStateException("AAC input deadline");
                Thread.sleep(1); continue;
            }
            ByteBuffer bytes = codec.getInputBuffer(input); bytes.clear(); bytes.order(ByteOrder.LITTLE_ENDIAN);
            int n = Math.min(count, bytes.remaining() / 2);
            if (n == 0) throw new IllegalStateException("AAC input size");
            for (int i = 0; i < n; i++) bytes.putShort(samples[offset + i]);
            codec.queueInputBuffer(input, 0, n * 2, frames * 1000000L / 16000, 0);
            frames += n; offset += n; count -= n;
        }
        drain(false);
    }
    private void drain(boolean finishing) throws Exception {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        for (;;) {
            int output = codec.dequeueOutputBuffer(info, finishing ? 1000 : 0);
            if (output == MediaCodec.INFO_TRY_AGAIN_LATER) return;
            if (output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                if (started) throw new IllegalStateException("AAC changed format");
                MediaFormat format = codec.getOutputFormat();
                if (format.getInteger(MediaFormat.KEY_SAMPLE_RATE) != 16000 || format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) != 1)
                    throw new IllegalStateException("AAC output format");
                track = muxer.addTrack(format); muxer.start(); started = true;
            } else if (output >= 0) {
                try {
                    if (info.size > 0 && (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                        if (!started) throw new IllegalStateException("AAC muxer not started");
                        ByteBuffer bytes = codec.getOutputBuffer(output);
                        bytes.position(info.offset); bytes.limit(info.offset + info.size);
                        muxer.writeSampleData(track, bytes, info);
                    }
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) eos = true;
                } finally { codec.releaseOutputBuffer(output, false); }
            }
        }
    }
    void commit(long expectedFrames) throws Exception {
        if (closed || frames != expectedFrames || frames <= 0) throw new IllegalStateException("AAC incomplete input");
        long until = SystemClock.elapsedRealtime() + 250;
        boolean sent = false;
        while (!eos) {
            if (SystemClock.elapsedRealtime() > until) throw new IllegalStateException("AAC finish deadline");
            if (!sent) {
                int input = codec.dequeueInputBuffer(0);
                if (input >= 0) { codec.queueInputBuffer(input, 0, 0, frames * 1000000L / 16000, MediaCodec.BUFFER_FLAG_END_OF_STREAM); sent = true; }
            }
            drain(true);
        }
        if (!started) throw new IllegalStateException("AAC empty output");
        muxer.stop(); started = false; muxer.release(); muxer = null;
        Os.fsync(descriptor);
        close();
        if (Files.size(pending) <= 32 || Files.size(pending) > 44 + frames * 2) throw new IllegalStateException("AAC output size");
        Files.createLink(complete, pending); Files.delete(pending);
    }
    @Override public void close() {
        if (closed) return; closed = true;
        if (codec != null) { try { codec.stop(); } catch (Exception ignored) {} try { codec.release(); } catch (Exception ignored) {} codec = null; }
        if (muxer != null) { try { if (started) muxer.stop(); } catch (Exception ignored) {} try { muxer.release(); } catch (Exception ignored) {} muxer = null; }
        if (descriptor != null) { try { Os.close(descriptor); } catch (Exception ignored) {} descriptor = null; }
    }
}
