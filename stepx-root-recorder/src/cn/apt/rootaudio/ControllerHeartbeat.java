package cn.apt.rootaudio;

import java.util.function.LongSupplier;

/** Read and validate one independent controller heartbeat against the monotonic clock. */
final class ControllerHeartbeat {
    interface Reader { long read() throws Exception; }

    static void check(Reader reader, LongSupplier clock) throws Exception {
        long beat = reader.read();
        // The writer may advance while the read is in progress. Sample only after
        // reading; an earlier loop timestamp can falsely make a fresh beat "future".
        long now = clock.getAsLong();
        if (now < beat || now - beat > 6000) throw new IllegalStateException("controller-lost");
    }
}
