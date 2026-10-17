package cn.apt.rootaudio;

import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;
import java.io.File;
import java.io.FileDescriptor;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.util.UUID;
import org.json.JSONObject;

/** All writes are relative to a verified, held directory FD, never an app-selected path. */
final class PrivateDirectory implements AutoCloseable {
    final String canonical;
    final Path path;
    private final FileDescriptor fd;
    private final long inode, device;
    PrivateDirectory(String directory, int uid, boolean rootPrivate) throws Exception {
        this(openAbsolute(directory), directory, uid, rootPrivate);
    }
    private PrivateDirectory(FileDescriptor opened, String expected, int uid, boolean rootPrivate) throws Exception {
        canonical = expected;
        fd = opened;
        try {
            StructStat stat = Os.fstat(fd);
            if (!OsConstants.S_ISDIR(stat.st_mode) || stat.st_uid != uid || stat.st_gid != uid
                    || (stat.st_mode & (rootPrivate ? 077 : 006)) != 0) throw new SecurityException("directory owner/mode");
            path = descriptor(fd); inode = stat.st_ino; device = stat.st_dev;
            check();
        } catch (Exception failure) {
            try { Os.close(fd); } catch (Exception closing) { failure.addSuppressed(closing); }
            throw failure;
        }
    }
    private static Path descriptor(FileDescriptor fd) throws Exception {
        return Paths.get("/proc/self/fd/" + (Integer) FileDescriptor.class.getMethod("getInt$").invoke(fd));
    }
    private static FileDescriptor openAbsolute(String directory) throws Exception {
        if (!directory.startsWith("/") || !Paths.get(directory).normalize().toString().equals(directory))
            throw new SecurityException("directory spelling");
        FileDescriptor parent = Os.open("/", OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW, 0);
        try {
            for (String component : directory.substring(1).split("/")) {
                if (!component.matches("[a-zA-Z0-9_.-]+")) throw new SecurityException("directory component");
                FileDescriptor child = Os.open(descriptor(parent).resolve(component).toString(), OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW, 0);
                FileDescriptor previous = parent; parent = child; Os.close(previous);
                if (!OsConstants.S_ISDIR(Os.fstat(parent).st_mode)) throw new SecurityException("directory component type");
            }
            FileDescriptor result = parent; parent = null; return result;
        } finally { if (parent != null) Os.close(parent); }
    }
    void check() throws Exception {
        StructStat named = Os.lstat(canonical), held = Os.fstat(fd);
        if (!OsConstants.S_ISDIR(named.st_mode) || named.st_ino != inode || named.st_dev != device
                || held.st_ino != inode || !canonical.equals(Os.readlink(path.toString())))
            throw new SecurityException("directory changed");
    }
    Path file(String name) throws Exception {
        if (!name.matches("[a-zA-Z0-9_.-]{1,100}")) throw new SecurityException("file name");
        check(); return path.resolve(name);
    }
    PrivateDirectory child(String name) throws Exception {
        Path at = file(name);
        try { Os.mkdir(at.toString(), 0700); } catch (android.system.ErrnoException error) {
            if (error.errno != OsConstants.EEXIST) throw error;
        }
        StructStat stat = Os.lstat(at.toString());
        if (!OsConstants.S_ISDIR(stat.st_mode) || stat.st_uid != 0 || (stat.st_mode & 077) != 0)
            throw new SecurityException("private child changed");
        FileDescriptor opened = Os.open(at.toString(), OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW, 0);
        try {
            StructStat held = Os.fstat(opened);
            if (held.st_ino != stat.st_ino || held.st_dev != stat.st_dev) throw new SecurityException("child changed");
            FileDescriptor owned = opened; opened = null;
            return new PrivateDirectory(owned, canonical + "/" + name, 0, true);
        } finally { if (opened != null) Os.close(opened); }
    }
    String read(String name, int max, int owner) throws Exception {
        FileDescriptor input = Os.open(file(name).toString(), OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW, 0);
        try {
            StructStat stat = Os.fstat(input);
            if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_uid != owner || stat.st_size > max
                    || (stat.st_mode & 002) != 0) throw new SecurityException("private input");
            byte[] bytes = new byte[(int) stat.st_size]; int offset = 0;
            while (offset < bytes.length) { int count = Os.read(input, bytes, offset, bytes.length - offset); if (count < 1) throw new IllegalStateException("short input"); offset += count; }
            return new String(bytes, StandardCharsets.UTF_8);
        } finally { Os.close(input); }
    }
    JSONObject json(String name) throws Exception { return new JSONObject(read(name, 1024 * 1024, 0)); }
    void write(String name, JSONObject value, boolean immutable, boolean publicRead) throws Exception {
        Path target = file(name), temporary = file("tmp-" + UUID.randomUUID() + ".json");
        FileDescriptor output = Os.open(temporary.toString(), OsConstants.O_WRONLY | OsConstants.O_CREAT
                | OsConstants.O_EXCL | OsConstants.O_NOFOLLOW, publicRead ? 0644 : 0600);
        try {
            Os.fchmod(output, publicRead ? 0644 : 0600);
            byte[] bytes = (value.toString() + "\n").getBytes(StandardCharsets.UTF_8); int offset = 0;
            while (offset < bytes.length) { int count = Os.write(output, bytes, offset, bytes.length - offset); if (count < 1) throw new IllegalStateException("short output"); offset += count; }
            Os.fsync(output);
        } finally { Os.close(output); }
        check();
        if (immutable) { Files.createLink(target, temporary); Files.delete(temporary); }
        else Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        Os.fsync(fd);
    }
    @Override public void close() throws Exception { Os.close(fd); }
}
