package cn.apt.rootaudio;

import android.system.Os;
import java.io.File;
import java.nio.file.Files;
import org.json.JSONObject;

/** Run only on Android, in a new root-owned fixture; never opens the App or microphone. */
public final class PrivateDirectoryAndroidTest {
    private static int checks;
    private interface Attempt { void run() throws Exception; }
    private static void require(boolean value, String label) {
        checks++; if (!value) throw new AssertionError(label);
    }
    private static void refused(Attempt attempt) throws Exception {
        try { attempt.run(); } catch (SecurityException expected) { checks++; return; }
        throw new AssertionError("unsafe file accepted");
    }
    private static int descriptors() {
        String[] entries = new File("/proc/self/fd").list();
        if (entries == null) throw new AssertionError("FD inventory unavailable");
        return entries.length;
    }
    private static java.util.Map<String, String> targets() throws Exception {
        java.util.Map<String, String> result = new java.util.TreeMap<>();
        for (String name : new File("/proc/self/fd").list()) {
            try { result.put(name, Os.readlink("/proc/self/fd/" + name)); }
            catch (android.system.ErrnoException inventoryClosed) { }
        }
        return result;
    }
    public static void main(String[] args) throws Exception {
        try { run(args); System.out.flush(); System.exit(0); }
        catch (Throwable failure) { failure.printStackTrace(System.err); System.err.flush(); System.exit(1); }
    }
    private static void run(String[] args) throws Exception {
        if (args.length != 1 || !args[0].matches("/data/local/tmp/apt-fd-check\\.[0-9a-f]{32}") || Os.getuid() != 0)
            throw new SecurityException("isolated root fixture required");
        final String path = args[0];
        System.out.println("ANDROID_FILES_STARTED"); System.out.flush();
        try (PrivateDirectory root = new PrivateDirectory(path, 0, true)) {
            root.write("probe.json", new JSONObject().put("counter", -1), false, false);
            require(root.json("probe.json").getInt("counter") == -1, "warm read");
            try (BackScreenLock ignored = new BackScreenLock(root)) { }
            refused(() -> root.read("probe.json", 1, 0));
            refused(() -> { try (PrivateDirectory wrong = new PrivateDirectory(path, 10000, true)) { } });
            // ART lazily opens its collector's userfaultfd on the first collection.
            System.gc(); System.runFinalization();
            int before = descriptors();
            java.util.Map<String, String> beforeTargets = targets();
            for (int i = 0; i < 1200; i++) {
                root.write("probe.json", new JSONObject().put("counter", i), false, i % 2 == 0);
                require(root.json("probe.json").getInt("counter") == i, "atomic read/write");
                refused(() -> root.read("probe.json", 1, 0));
                refused(() -> root.read("probe.json", 1024, 10000));
                refused(() -> { try (PrivateDirectory wrong = new PrivateDirectory(path, 10000, true)) { } });
                try (PrivateDirectory child = root.child("child")) { child.check(); }
                try (BackScreenLock ignored = new BackScreenLock(root)) { }
                if (i % 200 == 199) { System.out.println("ANDROID_FILES_PROGRESS iterations=" + (i + 1)); System.out.flush(); }
            }
            int after = descriptors();
            if (after != before) for (java.util.Map.Entry<String, String> entry : targets().entrySet())
                if (!beforeTargets.containsKey(entry.getKey())) System.out.println("ANDROID_FILES_NEW_FD " + entry);
            require(after == before, "repeated IO and rejection leaked descriptors: " + before + " -> " + after);
            try (BackScreenLock held = new BackScreenLock(root)) {
                before = descriptors();
                for (int i = 0; i < 300; i++) {
                    try (BackScreenLock unexpected = new BackScreenLock(root)) {
                        throw new AssertionError("overlapping lock accepted");
                    } catch (java.nio.channels.OverlappingFileLockException expected) { checks++; }
                }
                require(descriptors() == before, "failed lock acquisition leaked descriptors");
            }
            Os.chmod(root.file("frame.lock").toString(), 0644);
            before = descriptors();
            for (int i = 0; i < 300; i++) refused(() -> { try (BackScreenLock wrong = new BackScreenLock(root)) { } });
            require(descriptors() == before, "rejected lock file leaked descriptors");
            Os.chmod(root.file("frame.lock").toString(), 0600);
            Files.createSymbolicLink(root.file("linked.json"), root.file("probe.json"));
            before = descriptors();
            for (int i = 0; i < 300; i++) {
                try { root.read("linked.json", 1024, 0); throw new AssertionError("symlink accepted"); }
                catch (android.system.ErrnoException expected) { checks++; }
            }
            require(descriptors() == before, "symlink rejection leaked descriptors");
            System.out.println("ANDROID_FILES_OK checks=" + checks + " descriptors=" + after + " delta=0 iterations=1200");
        }
    }
}
