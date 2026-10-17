package cn.apt.rootaudio;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.net.LocalServerSocket;
import android.os.SystemClock;
import android.os.PowerManager;
import android.util.Base64;
import java.nio.file.Files;
import java.util.UUID;
import org.json.JSONArray;
import org.json.JSONObject;

/** Dedicated rear-display service: a slow vendor Binder never blocks microphone stop. */
public final class BackScreenController {
    private final RootApp app;
    private final NeoBackScreen screen;
    private final PrivateDirectory root, media;
    private final RootMailbox mailbox;
    private final String epoch = UUID.randomUUID().toString();
    private String mode = "off", observed = "", error = null;
    private JSONObject last = new JSONObject();
    private long testUntil = 0, enabledUntil = 0;
    private long stopIssuedAt = 0;
    private String glyph = "mic";
    private long minutes = 0;
    private String original = null, lastFrame = null, overrideId = null;
    private JSONArray frames = new JSONArray();
    private final PowerManager.WakeLock wake;
    private java.lang.Process guard;
    private final boolean validation;
    private BackScreenController(Context context, boolean validation) throws Exception {
        this.validation = validation;
        app = new RootApp(context); screen = new NeoBackScreen(context);
        JSONObject info = screen.info();
        if (info.getInt("logicalWidth") != 17 || info.getInt("logicalHeight") != 23) throw new IllegalStateException("unsupported-backscreen-size");
        try (PrivateDirectory files = new PrivateDirectory(app.data + "/files", app.uid, false)) { root = files.child("apt-root-backscreen"); }
        media = new PrivateDirectory(app.data + "/files/media", app.uid, false);
        mailbox = new RootMailbox(app, "growth.neo.back.command.v1");
        wake = ((PowerManager) context.getSystemService(Context.POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "APT:BackScreen");
        // Let the previous guard finish before any new override can start.
        if (Files.exists(root.file("guard.json"))) {
            JSONObject previous = root.json("guard.json"); long deadline = SystemClock.elapsedRealtime() + 10000;
            while (BackScreenGuard.alive(previous.getInt("pid"), previous.getString("ticks"), "BackScreenGuard")) {
                if (SystemClock.elapsedRealtime() > deadline) throw new IllegalStateException("previous-display-guard-active");
                Thread.sleep(100);
            }
        }
        BackScreenGuard.recover(screen, root, null, null);
        int pid = android.os.Process.myPid();
        root.write("owner.json", new JSONObject().put("epoch", epoch).put("pid", pid).put("ticks", BackScreenGuard.ticks(pid)), false, false);
        heartbeat();
        guard = new ProcessBuilder("/system/bin/app_process", "/system/bin", "cn.apt.rootaudio.BackScreenGuard", epoch)
                .redirectErrorStream(true).redirectOutput(root.file("guard-" + epoch + ".log").toFile()).start();
        long deadline = SystemClock.elapsedRealtime() + 6000;
        while (true) {
            if (!guard.isAlive() || SystemClock.elapsedRealtime() > deadline) throw new IllegalStateException("display-guard-unavailable");
            try { guardReady(); break; } catch (Exception pending) { Thread.sleep(100); }
        }
    }
    public static void main(String[] args) {
        try (LocalServerSocket lease = new LocalServerSocket("cn.apt.backscreen.controller.v1")) {
            boolean validation = args.length == 1 && "--validation".equals(args[0]);
            if (args.length != 0 && !validation) throw new IllegalArgumentException("arguments");
            BackScreenController controller = new BackScreenController(RootPlatform.context(), validation);
            System.out.println("BACKSCREEN_READY version=1.0.2 uid=0"); System.out.flush(); controller.loop();
        } catch (Exception error) { System.out.println("BACKSCREEN_FAILED type=" + error.getClass().getSimpleName()); }
        System.exit(1);
    }
    private void loop() throws Exception {
        try {
            while (true) {
                heartbeat(); guardReady();
                app.check(false);
                if (!mode.equals("off") && (app.context.getPackageManager().getApplicationInfo(RootApp.PACKAGE, 0).flags & ApplicationInfo.FLAG_STOPPED) != 0)
                    stop();
                JSONObject command = null;
                try { command = validation ? root.json("validation-command.json") : mailbox.read(); } catch (Exception invalid) { }
                if (command != null && !command.optString("commandId").equals(observed)) {
                    observed = command.optString("commandId");
                    try { apply(command); last = new JSONObject().put("id", observed).put("ok", true); error = null; }
                    catch (Exception invalid) {
                        StackTraceElement at = invalid.getStackTrace().length == 0 ? null : invalid.getStackTrace()[0];
                        System.out.println("BACKSCREEN_COMMAND_FAILED type=" + invalid.getClass().getSimpleName()
                                + " at=" + (at == null ? "unknown" : at.getClassName() + ":" + at.getLineNumber()));
                        for (int i = 0; validation && i < Math.min(8, invalid.getStackTrace().length); i++) {
                            StackTraceElement item = invalid.getStackTrace()[i];
                            System.out.println("BACKSCREEN_COMMAND_AT " + item.getClassName() + "." + item.getMethodName() + ":" + item.getLineNumber());
                        }
                        System.out.flush();
                        try { stop(); } catch (Exception cleanup) { }
                        last = new JSONObject().put("id", observed.matches("[0-9a-f-]{36}") ? observed : "invalid").put("ok", false);
                        error = "display-custom-slot-in-use".equals(invalid.getMessage()) ? "系统或其他应用正在显示自定义图案，请先结束该显示" : "背屏操作未完成，请重试";
                    }
                }
                if (original != null && root.json("override.json").optBoolean("released", false)) {
                    original = null; lastFrame = null; overrideId = null; mode = "off";
                    if (wake.isHeld()) wake.release();
                }
                long now = SystemClock.elapsedRealtime();
                if (!mode.equals("off") && now > enabledUntil) stop();
                if (mode.equals("test") && now >= testUntil) stop();
                if (mode.equals("recording")) {
                    try { follow(); } catch (Exception failure) { stop(); error = "背屏联动已停止，请刷新后重试"; }
                }
                media.write(validation ? "apt-neo-back-validation-status-v1.json" : "apt-neo-back-status-v1.json", new JSONObject().put("version", 1).put("runtime", "1.0.2").put("validation", validation)
                        .put("epoch", epoch).put("updatedAt", System.currentTimeMillis()).put("hardware", screen.info())
                        .put("mode", mode).put("overrideActive", original != null).put("lastCommand", last)
                        .put("glyph", glyph).put("minutes", minutes)
                        .put("error", error == null ? JSONObject.NULL : error), false, true);
                Thread.sleep(1000);
            }
        } finally { stop(); }
    }
    private void apply(JSONObject command) throws Exception {
        String id = RootMailbox.uuid(command, "commandId"); long age = System.currentTimeMillis() - command.getLong("createdAt");
        if (command.getInt("version") != 1 || !epoch.equals(command.getString("epoch")) || age < -5000 || age > 30000) throw new SecurityException("command epoch");
        String claim = "command-" + id + ".json";
        if (Files.exists(root.file(claim))) throw new SecurityException("command replay");
        String action = command.getString("action");
        if (!action.equals("test") && !action.equals("recording") && !action.equals("stop") && !action.equals("ping")) throw new SecurityException("command action");
        if (action.equals("test") && !validation) throw new SecurityException("recording display only");
        root.write(claim, new JSONObject().put("id", id).put("action", action), true, false);
        if (action.equals("stop")) { stopIssuedAt = Math.max(stopIssuedAt, command.getLong("createdAt")); stop(); return; }
        if (action.equals("ping")) return;
        if (command.getLong("createdAt") <= stopIssuedAt
                || (app.context.getPackageManager().getApplicationInfo(RootApp.PACKAGE, 0).flags & ApplicationInfo.FLAG_STOPPED) != 0)
            throw new SecurityException("cancelled mode");
        if (!screen.info().getBoolean("enabled")) throw new IllegalStateException("system-backscreen-disabled");
        String nextGlyph = action.equals("test") ? command.getString("glyph") : "mic";
        if (!nextGlyph.equals("mic")) throw new SecurityException("test glyph");
        int testSeconds = validation ? command.optInt("testSeconds", 3) : 3;
        if (testSeconds != 3 && testSeconds != 8) throw new SecurityException("validation test duration");
        stop(); mode = action; enabledUntil = SystemClock.elapsedRealtime() + (action.equals("test") ? testSeconds * 1000L : 43200000);
        if (action.equals("test")) {
            glyph = nextGlyph;
            testUntil = enabledUntil; show(BackGlyph.pattern(glyph, 0)); screen.wake();
        }
    }
    private void follow() throws Exception {
        JSONObject status;
        try { status = media.json("apt-root-status-v1.json"); }
        catch (Exception unavailable) { release(); error = "录音服务未连接，背屏联动已暂停"; return; }
        long age = System.currentTimeMillis() - status.getLong("updatedAt");
        if (age < -5000 || age > 8000) { release(); error = "录音服务离线，背屏联动已暂停"; return; }
        JSONArray sessions = status.getJSONArray("sessions"); JSONObject active = null;
        for (int i = 0; i < sessions.length(); i++) {
            JSONObject session = sessions.getJSONObject(i);
            if (session.optString("state").equals("recording") && session.optLong("frames") > 0) {
                if (active != null) { release(); error = "录音状态冲突，背屏联动已暂停"; return; }
                active = session;
            }
        }
        if (active == null) { release(); error = null; return; }
        glyph = "mic"; minutes = Math.min(720, active.getLong("frames") / 16000 / 60);
        show(BackGlyph.pattern(glyph, minutes)); error = null;
    }
    private void show(int[] pixels) throws Exception {
        try (BackScreenLock ignored = new BackScreenLock(root)) { showLocked(pixels); }
    }
    private void showLocked(int[] pixels) throws Exception {
        guardReady();
        if (SystemClock.elapsedRealtime() >= enabledUntil) throw new IllegalStateException("display-mode-expired");
        if (original != null && root.json("override.json").optBoolean("released", false)) throw new IllegalStateException("display-override-ended");
        byte[] bytes = new byte[pixels.length]; for (int i = 0; i < pixels.length; i++) bytes[i] = (byte) pixels[i];
        String nextFrame = Base64.encodeToString(bytes, Base64.NO_WRAP);
        if (nextFrame.equals(lastFrame)) return;
        BackDisplayOwner owner = screen.ownership(root);
        boolean starting = original == null;
        if (original == null) {
            if (owner.custom || !screen.storedFrame(root).isEmpty()) throw new IllegalStateException("display-custom-slot-in-use");
            original = ""; frames = new JSONArray();
        } else if (!owner.custom || owner.uid != 0) {
            original = null; lastFrame = null; overrideId = null; mode = "off";
            if (wake.isHeld()) wake.release();
            throw new IllegalStateException("display-owner-changed");
        }
        frames.put(RootApp.hash(bytes));
        lastFrame = nextFrame; overrideId = UUID.randomUUID().toString();
        root.write("override.json", new JSONObject().put("id", overrideId).put("epoch", epoch).put("until", enabledUntil)
                .put("last", lastFrame).put("frames", frames).put("released", false), false, false);
        if (!wake.isHeld()) wake.acquire(Math.max(1000, enabledUntil - SystemClock.elapsedRealtime() + 5000));
        screen.frame(pixels);
        if (starting) screen.wake();
    }
    private void release() throws Exception {
        if (original != null) {
            BackScreenGuard.recover(screen, root, overrideId, epoch);
            original = null; lastFrame = null; overrideId = null;
        }
        if (wake.isHeld()) wake.release();
    }
    private void stop() throws Exception { mode = "off"; release(); }
    private void heartbeat() throws Exception {
        root.write("parent.json", new JSONObject().put("epoch", epoch).put("elapsed", SystemClock.elapsedRealtime()), false, false);
    }
    private void guardReady() throws Exception {
        if (!guard.isAlive() || Files.exists(root.file("revoked-" + epoch + ".json"))) throw new IllegalStateException("display-guard-lost");
        JSONObject state = root.json("guard.json");
        if (!epoch.equals(state.getString("epoch")) || SystemClock.elapsedRealtime() - state.getLong("elapsed") > 5000)
            throw new IllegalStateException("display-guard-stale");
    }
}
