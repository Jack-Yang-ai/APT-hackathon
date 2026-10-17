package cn.apt.rootaudio;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;

/** Real file tests; no Android services, microphone or repository fixtures. */
public final class WavChunkTest {
    private static int checks;
    private static void check(boolean ok) {
        if (!ok) throw new AssertionError("check " + checks);
        checks++;
    }
    private static void rejects(Io action) throws Exception {
        boolean rejected = false;
        try { action.run(); } catch (IOException expected) { rejected = true; }
        check(rejected);
    }
    private interface Io { void run() throws Exception; }
    public static void main(String[] args) throws Exception {
        Path dir = Files.createTempDirectory("apt-wav-test-");
        try {
            // Multiple reads append exact signed little-endian frames and header.
            WavChunk chunk = new WavChunk(dir, 0);
            short[] samples = { 0, Short.MIN_VALUE, -1, 1, Short.MAX_VALUE };
            chunk.append(samples, 0, 2); chunk.sync(); chunk.append(samples, 2, 3);
            check(!Files.exists(dir.resolve("chunk-0000.wav")));
            chunk.commit(); chunk.close();
            byte[] raw = Files.readAllBytes(chunk.completedPath());
            ByteBuffer bytes = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
            check(raw.length == 54 && bytes.getInt(4) == 46 && bytes.getInt(40) == 10);
            check(bytes.getShort(20) == 1 && bytes.getShort(22) == 1 && bytes.getInt(24) == 16000);
            for (int i = 0; i < samples.length; i++) check(bytes.getShort(44 + i * 2) == samples[i]);
            check(!Files.exists(dir.resolve("chunk-0000.pending.wav")));
            rejects(() -> new WavChunk(dir, 0));
            rejects(chunk::commit);

            // A crash/close preserves pending bytes without advertising completion.
            WavChunk partial = new WavChunk(dir, 1);
            partial.append(samples, 0, samples.length); partial.close();
            check(Files.size(dir.resolve("chunk-0001.pending.wav")) == 54);
            check(!Files.exists(partial.completedPath()));
            rejects(() -> new WavChunk(dir, 1));

            // A complete name created during capture cannot be overwritten.
            WavChunk collision = new WavChunk(dir, 2);
            collision.append(samples, 0, samples.length);
            byte[] existing = { 9, 8, 7 };
            Files.write(collision.completedPath(), existing);
            rejects(collision::commit);
            check(Arrays.equals(existing, Files.readAllBytes(collision.completedPath())));
            check(Files.exists(dir.resolve("chunk-0002.pending.wav")));

            WavChunk empty = new WavChunk(dir, 3);
            rejects(empty::commit); empty.close();
            check(!Files.exists(empty.completedPath()));

            // Unexpected extra bytes are not blessed by merely rewriting a header.
            WavChunk damaged = new WavChunk(dir, 4);
            damaged.append(samples, 0, samples.length);
            try (java.io.RandomAccessFile f = new java.io.RandomAccessFile(
                    dir.resolve("chunk-0004.pending.wav").toFile(), "rw")) { f.setLength(60); }
            rejects(damaged::commit);
            check(!Files.exists(damaged.completedPath()));
            check(damaged.isClosed());

            // A dangling destination symlink is still an occupied name.
            WavChunk linked = new WavChunk(dir, 5);
            linked.append(samples, 0, samples.length);
            Files.createSymbolicLink(linked.completedPath(), dir.resolve("not-present"));
            rejects(linked::commit);
            check(!Files.exists(dir.resolve("not-present")));
            check(Files.exists(dir.resolve("chunk-0005.pending.wav")));
            System.out.println("WavChunkTest passed checks=" + checks);
        } finally {
            try (java.util.stream.Stream<Path> paths = Files.walk(dir)) {
                for (Path path : (Iterable<Path>) paths.sorted(java.util.Comparator.reverseOrder())::iterator)
                    Files.delete(path);
            }
        }
    }
}
