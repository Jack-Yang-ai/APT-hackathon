package cn.apt.rootaudio;

import android.os.SystemClock;
import android.system.Os;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import org.json.JSONObject;

/** A separate process removes our override if the controller stalls or disappears. */
public final class BackScreenGuard {
    static String ticks(int pid) throws Exception {
        String stat = new String(Files.readAllBytes(Paths.get("/proc/" + pid + "/stat")), StandardCharsets.UTF_8);
        return stat.substring(stat.lastIndexOf(')') + 2).split(" ")[19];
    }
    static boolean alive(int pid, String start, String type) {
        try {
            if (pid < 2 || Os.lstat("/proc/" + pid).st_uid != 0 || !ticks(pid).equals(start)) return false;
            String command = new String(Files.readAllBytes(Paths.get("/proc/" + pid + "/cmdline")), StandardCharsets.UTF_8);
            String arguments = type.equals("BackScreenController") ? "(?: --validation)?" : " [0-9a-f-]{36}";
            return command.replace('\0', ' ').trim().matches("(?:app_process(?:32|64)? /system/bin )?cn\\.apt\\.rootaudio\\." + type + arguments);
        } catch (Exception gone) { return false; }
    }
    static void recover(NeoBackScreen screen, PrivateDirectory root, String expectedId, String expectedEpoch) throws Exception {
        try (BackScreenLock ignored = new BackScreenLock(root)) { recoverLocked(screen, root, expectedId, expectedEpoch); }
    }
    private static void recoverLocked(NeoBackScreen screen, PrivateDirectory root, String expectedId, String expectedEpoch) throws Exception {
        if (!Files.exists(root.file("override.json"))) return;
        JSONObject journal = root.json("override.json");
        if (expectedId != null && !expectedId.equals(journal.optString("id"))) return;
        if (expectedEpoch != null && !expectedEpoch.equals(journal.optString("epoch"))) return;
        if (journal.optBoolean("released", true)) return;
        BackDisplayOwner current = screen.ownership(root);
        // We take over only an empty custom slot. A changed owner is left alone.
        if (!current.custom || current.uid == 0) {
            String stored = screen.storedFrame(root);
            boolean ours = stored.isEmpty() || stored.equals(journal.getString("last"));
            org.json.JSONArray hashes = journal.optJSONArray("frames");
            if (!ours && hashes != null) {
                String hash = RootApp.hash(android.util.Base64.decode(stored, android.util.Base64.NO_WRAP));
                for (int i = 0; i < hashes.length(); i++) if (hash.equals(hashes.getString(i))) ours = true;
            }
            if (ours) screen.frame(null);
            else journal.put("externalChange", true);
        }
        journal.put("released", true); root.write("override.json", journal, false, false);
    }
    public static void main(String[] args) {
        try {
            if (args.length != 1 || !args[0].matches("[0-9a-f-]{36}")) throw new IllegalArgumentException("guard arguments");
            RootApp app = new RootApp(RootPlatform.context());
            try (PrivateDirectory root = new PrivateDirectory(app.data + "/files/apt-root-backscreen", 0, true)) {
                NeoBackScreen screen = new NeoBackScreen(app.context);
                JSONObject owner = root.json("owner.json");
                String epoch = args[0];
                if (!epoch.equals(owner.getString("epoch"))) throw new SecurityException("guard owner");
                int parent = owner.getInt("pid"); String start = owner.getString("ticks");
                for (;;) {
                    long now = SystemClock.elapsedRealtime();
                    boolean live = alive(parent, start, "BackScreenController");
                    JSONObject heartbeat = root.json("parent.json");
                    boolean fresh = epoch.equals(heartbeat.getString("epoch")) && now - heartbeat.getLong("elapsed") < 6500;
                    boolean expired = false; String overrideId = null;
                    if (Files.exists(root.file("override.json"))) {
                        JSONObject journal = root.json("override.json");
                        if (!journal.optBoolean("released", true) && epoch.equals(journal.optString("epoch"))) {
                            expired = now >= journal.getLong("until");
                            overrideId = journal.getString("id");
                        }
                    }
                    if (!live || !fresh) {
                        root.write("revoked-" + epoch + ".json", new JSONObject().put("epoch", epoch), false, false);
                        if (alive(parent, start, "BackScreenController")) {
                            Os.kill(parent, android.system.OsConstants.SIGKILL);
                            long deadline = SystemClock.elapsedRealtime() + 2000;
                            while (alive(parent, start, "BackScreenController")) {
                                if (SystemClock.elapsedRealtime() > deadline) throw new IllegalStateException("display-controller-still-alive");
                                Thread.sleep(25);
                            }
                        }
                        // Parent is gone: release its newest override, even if it changed
                        // after the expired-frame snapshot. Keep retrying on vendor failure.
                        try { recover(screen, root, null, epoch); break; }
                        catch (Exception retry) { Thread.sleep(500); continue; }
                    }
                    if (expired) {
                        try { recover(screen, root, overrideId, epoch); }
                        catch (Exception retry) { /* A busy lock must not disable the later stale-parent cleanup. */ }
                    }
                    root.write("guard.json", new JSONObject().put("epoch", epoch).put("elapsed", now)
                            .put("pid", android.os.Process.myPid()).put("ticks", ticks(android.os.Process.myPid())), false, false);
                    Thread.sleep(500);
                }
            }
            System.exit(0);
        } catch (Exception failure) { System.out.println("BACKSCREEN_GUARD_FAILED type=" + failure.getClass().getSimpleName()); }
        System.exit(1);
    }
}
