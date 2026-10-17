package cn.apt.rootaudio;

import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.file.Files;
import java.nio.file.Path;

/** A pending file is never advertised as complete; publication cannot replace another file. */
public final class WavChunk implements AutoCloseable {
    public static final int RATE = 16000;
    private final Path pending, complete;
    private final RandomAccessFile file;
    private long frames;
    private boolean closed;

    public WavChunk(Path dir, int sequence) throws IOException {
        if (sequence < 0 || sequence > 9999) throw new IllegalArgumentException("sequence");
        String stem = String.format(java.util.Locale.ROOT, "chunk-%04d", sequence);
        pending = dir.resolve(stem + ".pending.wav");
        complete = dir.resolve(stem + ".wav");
        if (Files.exists(complete)) throw new IOException("complete chunk exists");
        Files.createFile(pending, java.nio.file.attribute.PosixFilePermissions.asFileAttribute(
                java.nio.file.attribute.PosixFilePermissions.fromString("rw-------")));
        RandomAccessFile opened = null;
        try {
            opened = new RandomAccessFile(pending.toFile(), "rw");
            header(opened, 0);
            file = opened;
        } catch (IOException error) {
            if (opened != null) opened.close();
            throw error;
        }
    }
    public long frames() { return frames; }
    public boolean isClosed() { return closed; }
    public Path completedPath() { return complete; }
    public void append(short[] samples, int from, int count) throws IOException {
        if (closed || from < 0 || count < 0 || from + count > samples.length)
            throw new IllegalArgumentException("append range/state");
        byte[] bytes = new byte[count * 2];
        for (int i = 0; i < count; i++) {
            bytes[i * 2] = (byte) samples[from + i];
            bytes[i * 2 + 1] = (byte) (samples[from + i] >> 8);
        }
        file.write(bytes);
        frames += count;
    }
    public void sync() throws IOException { file.getFD().sync(); }
    public void commit() throws IOException {
        if (closed || frames == 0) throw new IOException("empty or closed chunk");
        try {
            header(file, frames * 2);
            if (file.length() != 44 + frames * 2) throw new IOException("chunk length mismatch");
            file.getFD().sync();
        } finally { closed = true; file.close(); }
        // link() is atomic and fails if complete already exists. Keep pending on
        // publication failure; no replace-existing rename or destructive retry.
        Files.createLink(complete, pending);
        Files.delete(pending);
    }
    @Override public void close() throws IOException {
        if (!closed) { closed = true; file.close(); }
    }
    private static void header(RandomAccessFile f, long bytes) throws IOException {
        if (bytes < 0 || bytes > 0xffffffffL - 36) throw new IOException("wav size");
        f.seek(0); f.writeBytes("RIFF"); le32(f, bytes + 36); f.writeBytes("WAVEfmt ");
        le32(f, 16); le16(f, 1); le16(f, 1); le32(f, RATE);
        le32(f, RATE * 2); le16(f, 2); le16(f, 16); f.writeBytes("data"); le32(f, bytes);
        f.seek(44 + bytes);
    }
    private static void le16(RandomAccessFile f, int n) throws IOException {
        f.write(n & 255); f.write((n >>> 8) & 255);
    }
    private static void le32(RandomAccessFile f, long n) throws IOException {
        for (int i = 0; i < 4; i++) f.write((int) (n >>> (8 * i)) & 255);
    }
}
