package cn.apt.rootaudio;

import android.os.SystemClock;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.nio.channels.FileLock;

/** Cross-process serialization of the vendor frame and its recovery journal. */
final class BackScreenLock implements AutoCloseable {
    private final FileDescriptor fd;
    private final FileOutputStream stream;
    private final FileLock lock;
    BackScreenLock(PrivateDirectory root) throws Exception {
        fd = Os.open(root.file("frame.lock").toString(), OsConstants.O_WRONLY | OsConstants.O_CREAT | OsConstants.O_NOFOLLOW, 0600);
        FileOutputStream output = null; FileLock acquired = null;
        try {
            StructStat stat = Os.fstat(fd);
            if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_uid != 0 || (stat.st_mode & 077) != 0) throw new SecurityException("display lock");
            output = new FileOutputStream(fd);
            long until = SystemClock.elapsedRealtime() + 1500;
            while ((acquired = output.getChannel().tryLock()) == null) {
                if (SystemClock.elapsedRealtime() > until) throw new IllegalStateException("display-lock-timeout");
                Thread.sleep(25);
            }
        } catch (Exception failure) {
            try { closeOwned(output, fd); } catch (Exception closing) { failure.addSuppressed(closing); }
            throw failure;
        }
        stream = output; lock = acquired;
    }
    private static void closeOwned(FileOutputStream stream, FileDescriptor fd) throws Exception {
        // Android streams constructed from an existing descriptor only borrow it.
        try { if (stream != null) stream.close(); } finally { if (fd.valid()) Os.close(fd); }
    }
    public void close() throws Exception { try { lock.release(); } finally { closeOwned(stream, fd); } }
}
