package cn.apt.rootaudio;

import java.io.IOException;
import java.util.concurrent.atomic.AtomicLong;

/** Deterministic interleaving: the writer advances during the heartbeat read. */
public final class ControllerHeartbeatTest {
    private static int checks;
    private static void check(boolean ok) {
        if (!ok) throw new AssertionError("heartbeat check " + checks);
        checks++;
    }
    private static void rejects(ControllerHeartbeat.Reader reader, long now) throws Exception {
        boolean failed = false;
        try { ControllerHeartbeat.check(reader, () -> now); }
        catch (IllegalStateException expected) { failed = "controller-lost".equals(expected.getMessage()); }
        check(failed);
    }
    public static void main(String[] args) throws Exception {
        AtomicLong clock = new AtomicLong(10000);
        // Mirrors the actual race: Binder/file work permits a newer parent write.
        ControllerHeartbeat.check(() -> clock.addAndGet(125), clock::get);
        check(clock.get() == 10125);
        ControllerHeartbeat.check(() -> 10000, () -> 16000); check(true);
        rejects(() -> 10000, 16001);
        rejects(() -> 10001, 10000);
        rejects(() -> 12000, 0);
        ControllerHeartbeat.check(() -> 0, () -> 0); check(true);
        AtomicLong reads = new AtomicLong();
        try {
            ControllerHeartbeat.check(() -> { throw new IOException("unreadable"); }, () -> { reads.incrementAndGet(); return 0; });
            throw new AssertionError("read failure accepted");
        } catch (IOException expected) { check(reads.get() == 0); }
        System.out.println("HEARTBEAT_OK checks=" + checks);
    }
}
