package cn.apt.rootaudio;

import android.content.Context;
import android.os.Bundle;
import android.util.Base64;
import java.util.concurrent.TimeUnit;
import java.nio.file.Files;
import org.json.JSONObject;

/** Neo's actual vendor manager, separate from normal Android secondary displays. */
final class NeoBackScreen {
    private final Object manager;
    NeoBackScreen(Context context) throws Exception {
        manager = context.getSystemService("display_ext");
        if (manager == null || !manager.getClass().getName().equals("android.hardware.display.StepOSDisplayManager"))
            throw new IllegalStateException("backscreen-unavailable");
    }
    String storedFrame(PrivateDirectory directory) throws Exception {
        // app_process has no ActivityManager app registration. Its system Context
        // cannot acquire a provider as package android/UID0. Use the native read-only
        // Settings client, with one fixed key and no caller-selected arguments.
        String value = output(directory, "settings-frame", 2048, new String[] { "/system/bin/settings", "get", "system", "stepos_back_screen_basic_frame" }).trim();
        if (value.equals("null") || value.isEmpty()) return "";
        if (value.length() > 1024 || Base64.decode(value, Base64.DEFAULT).length != 391) throw new IllegalStateException("existing-frame-unverified");
        return Base64.encodeToString(Base64.decode(value, Base64.DEFAULT), Base64.NO_WRAP);
    }
    void frame(int[] pixels) throws Exception {
        if (pixels != null) {
            if (pixels.length != 391) throw new IllegalArgumentException("frame size");
            for (int pixel : pixels) if (pixel < 0 || pixel > 255) throw new IllegalArgumentException("frame value");
        }
        invoke("setBackScreenFrame", new Class<?>[] { int[].class, Bundle.class }, pixels, null);
    }
    void wake() throws Exception { invoke("wakeUpBackScreen", new Class<?>[0]); }
    /** Read only the manufacturer's ownership flags. Never export its text or frame. */
    BackDisplayOwner ownership(PrivateDirectory directory) throws Exception {
        String value = output(directory, "display-diagnostic", 65536,
                new String[] { "/system/bin/dumpsys", "-t", "2", "display_ext", "back_screen", "state" });
        return BackDisplayOwner.parse(value);
    }
    private String output(PrivateDirectory directory, String prefix, int max, String[] arguments) throws Exception {
        String name = prefix + "-" + android.os.Process.myPid() + ".txt";
        java.nio.file.Path file = directory.file(name);
        Files.deleteIfExists(file);
        java.lang.Process process = new ProcessBuilder(arguments)
                .redirectErrorStream(true).redirectOutput(file.toFile()).start();
        try {
            if (!process.waitFor(3, TimeUnit.SECONDS)) { process.destroyForcibly(); throw new IllegalStateException("display-read-timeout"); }
            android.system.Os.chmod(file.toString(), 0600);
            if (process.exitValue() != 0) throw new IllegalStateException("display-read-failed");
            return directory.read(name, max, 0);
        } finally { process.destroy(); Files.deleteIfExists(file); }
    }
    Object invoke(String name, Class<?>[] types, Object... values) throws Exception {
        return manager.getClass().getMethod(name, types).invoke(manager, values);
    }
    JSONObject info() throws Exception {
        Object display = invoke("getBackScreenDisplayInfo", new Class<?>[0]);
        if (display == null) throw new IllegalStateException("backscreen-info-unavailable");
        JSONObject result = new JSONObject().put("supported", true);
        for (String field : new String[] {"LogicalWidth", "LogicalHeight", "State", "Brightness", "Rotation"})
            result.put(Character.toLowerCase(field.charAt(0)) + field.substring(1), display.getClass().getMethod("get" + field).invoke(display));
        result.put("enabled", invoke("isBackScreenEnabled", new Class<?>[0]));
        return result;
    }
    public static void main(String[] args) {
        try {
            if (args.length != 0) throw new IllegalArgumentException("read-only probe");
            Context context = RootPlatform.context(); new RootApp(context);
            System.out.println(new NeoBackScreen(context).info()); System.exit(0);
        } catch (Exception error) {
            Throwable cause = error; while (cause instanceof java.lang.reflect.InvocationTargetException && cause.getCause() != null) cause = cause.getCause();
            System.out.println("BACKSCREEN_PROBE_FAILED type=" + cause.getClass().getSimpleName()); System.exit(1);
        }
    }
}
