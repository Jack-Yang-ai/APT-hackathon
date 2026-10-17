package cn.apt.rootaudio;

import android.system.Os;
import android.system.OsConstants;
import java.nio.charset.StandardCharsets;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import org.json.JSONObject;

/** A persisted nonce identifies both timeout and VM, even across controller death before a handshake. */
final class RootUploadProcess {
    static final class Unconfirmed extends Exception { Unconfirmed() { super("upload stop unconfirmed"); } }
    private static final class Identity {
        final int pid; final String ticks;
        Identity(int pid, String ticks) { this.pid = pid; this.ticks = ticks; }
    }
    private static String signature(JSONObject request) throws Exception {
        String capture = RootMailbox.uuid(request, "captureId"), nonce = RootMailbox.uuid(request, "attempt");
        int piece = request.getInt("piece"), parent = request.getInt("parentPid"); String ticks = request.getString("parentTicks");
        if (piece < 0 || piece > 8640 || parent <= 1 || !ticks.matches("[0-9]{1,24}")) throw new SecurityException("upload process identity");
        String mode=request.optString("mode","");
        if(!mode.isEmpty()&&!mode.equals("pipeline")&&!mode.equals("revoke")&&!mode.equals("prepare"))throw new SecurityException("upload process mode");
        return "cn.apt.rootaudio.RootUploadWorker\0" + capture + "\0" + piece + "\0" + parent + "\0" + ticks + "\0" + nonce + "\0"+(mode.isEmpty()?"":mode+"\0");
    }
    static String ticks(int pid) throws Exception {
        if (pid <= 1 || Os.lstat("/proc/" + pid).st_uid != 0) throw new SecurityException("upload process uid");
        String stat = new String(Files.readAllBytes(Paths.get("/proc/" + pid + "/stat")), StandardCharsets.US_ASCII);
        return stat.substring(stat.lastIndexOf(')') + 2).split(" ")[19];
    }
    private static boolean matches(int pid, String signature) throws Exception {
        try {
            if (pid <= 1 || Os.lstat("/proc/" + pid).st_uid != 0) return false;
            byte[] command = Files.readAllBytes(Paths.get("/proc/" + pid + "/cmdline"));
            return command.length < 8192 && new String(command,StandardCharsets.US_ASCII).contains(signature);
        } catch (android.system.ErrnoException error) {
            if (error.errno == OsConstants.ENOENT || error.errno == OsConstants.ESRCH) return false;
            throw error;
        } catch (java.nio.file.NoSuchFileException gone) { return false; }
    }
    private static ArrayList<Identity> find(String signature) throws Exception {
        ArrayList<Identity> result = new ArrayList<>();
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(Paths.get("/proc"))) {
            for (Path path : entries) {
                String value = path.getFileName().toString(); if (!value.matches("[0-9]{1,10}")) continue;
                int pid;
                try { pid = Integer.parseInt(value); } catch (NumberFormatException ignored) { continue; }
                if (matches(pid,signature)) try { result.add(new Identity(pid,ticks(pid))); }
                catch (Exception uncertain) { if (matches(pid,signature)) throw uncertain; }
            }
        }
        return result;
    }
    static void stop(JSONObject request) throws Unconfirmed {
        try {
            String signature = signature(request);
            for (int attempt = 0; attempt < 20; attempt++) {
                ArrayList<Identity> processes = find(signature);
                if (processes.isEmpty()) return;
                for (Identity process : processes) {
                    if (matches(process.pid,signature) && process.ticks.equals(ticks(process.pid))) Os.kill(process.pid,OsConstants.SIGKILL);
                }
                Thread.sleep(50);
            }
        } catch (Exception uncertain) { throw new Unconfirmed(); }
        throw new Unconfirmed();
    }
}
