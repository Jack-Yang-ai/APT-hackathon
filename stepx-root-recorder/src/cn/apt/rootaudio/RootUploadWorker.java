package cn.apt.rootaudio;

import android.os.PowerManager;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;
import java.io.ByteArrayOutputStream;
import java.io.FileDescriptor;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.util.Locale;
import javax.net.ssl.HttpsURLConnection;
import org.json.JSONObject;

/** Upload-only transport. No ASR/model calls, IDB edits, arbitrary URLs or credential arguments. */
public final class RootUploadWorker {
    private RootUploadWorker() {}
    public static void main(String[] args) {
        Thread deadline = new Thread(() -> {
            try { Thread.sleep(90000); } catch (InterruptedException ignored) { return; }
            android.os.Process.killProcess(android.os.Process.myPid());
        }, "apt-upload-deadline");
        deadline.setDaemon(true); deadline.start();
        try {
            if ((args.length != 5 && args.length != 6) || !args[1].matches("[0-9]{1,4}") || !args[2].matches("[0-9]{1,10}") || !args[3].matches("[0-9]{1,24}")
                    || args.length == 6 && !java.util.Arrays.asList("prepare","pipeline","revoke").contains(args[5]))
                throw new SecurityException("upload arguments");
            RootApp app = new RootApp(RootPlatform.context());
            if (args.length == 6 && args[5].equals("prepare"))
                prepare(app,RootUploadIdentity.uuid(args[0]),Integer.parseInt(args[1]),Integer.parseInt(args[2]),args[3],RootUploadIdentity.uuid(args[4]));
            else if (args.length == 6)
                RootPipeline.deliver(app,RootUploadIdentity.uuid(args[0]),Integer.parseInt(args[1]),Integer.parseInt(args[2]),args[3],RootUploadIdentity.uuid(args[4]),args[5].equals("revoke"));
            else upload(app,RootUploadIdentity.uuid(args[0]),Integer.parseInt(args[1]),Integer.parseInt(args[2]),args[3],RootUploadIdentity.uuid(args[4]));
            System.out.println("UPLOAD_CONFIRMED"); System.exit(0);
        } catch (Exception refused) { System.out.println("UPLOAD_NOT_CONFIRMED"); System.exit(1); }
    }
    private static void prepare(RootApp app, String capture, int index, int pid, String ticks, String nonce) throws Exception {
        parent(pid,ticks); app.check(true);
        try (PrivateDirectory dir = new PrivateDirectory(app.data + "/files/apt-root-recorder/capture-" + capture,0,true)) {
            JSONObject request = dir.json(RootUploader.name(index,"request")), source = dir.json("source.json");
            if (!capture.equals(RootMailbox.uuid(source,"captureId")) || !nonce.equals(request.getString("attempt"))
                    || !capture.equals(request.getString("captureId")) || index != request.getInt("piece")
                    || !"prepare".equals(request.optString("mode"))
                    || pid != request.getInt("parentPid") || !ticks.equals(request.getString("parentTicks"))
                    || RootUploader.cancelled(app,dir,index)) throw new SecurityException("compression revoked");
            PowerManager.WakeLock wake = ((PowerManager) app.context.getSystemService(android.content.Context.POWER_SERVICE))
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"APT:AudioCompression");
            wake.acquire(100000);
            try { RootPcmCompression.prepare(dir,source,index); }
            finally { if (wake.isHeld()) wake.release(); }
        }
    }
    private static void parent(int pid, String ticks) throws Exception {
        if (pid <= 1 || Os.lstat("/proc/" + pid).st_uid != 0) throw new SecurityException("upload parent");
        String stat = new String(Files.readAllBytes(Paths.get("/proc/" + pid + "/stat")), StandardCharsets.US_ASCII);
        String command = new String(Files.readAllBytes(Paths.get("/proc/" + pid + "/cmdline")), StandardCharsets.US_ASCII);
        if (!ticks.equals(stat.substring(stat.lastIndexOf(')') + 2).split(" ")[19]) || !command.contains("cn.apt.rootaudio.RootController\0"))
            throw new SecurityException("upload parent changed");
    }
    static void allowed(RootApp app, PrivateDirectory dir, int index, String credential, int pid, String ticks, String nonce) throws Exception {
        parent(pid, ticks); app.check(true); dir.check();
        JSONObject request = dir.json(RootUploader.name(index,"request"));
        if (!nonce.equals(request.getString("attempt")) || pid != request.getInt("parentPid") || !ticks.equals(request.getString("parentTicks")))
            throw new SecurityException("upload attempt revoked");
        if ((RootUploader.cancelled(app,dir, index)&&!"revoke".equals(request.optString("mode"))) || !credential.equals(RootUploadCredential.read(app))) throw new SecurityException("upload revoked");
    }
    private static void upload(RootApp app, String capture, int index, int pid, String ticks, String nonce) throws Exception {
        if (index < 0 || index > 8640) throw new SecurityException("upload index");
        try (PrivateDirectory dir = new PrivateDirectory(app.data + "/files/apt-root-recorder/capture-" + capture, 0, true)) {
            JSONObject source = dir.json("source.json"), piece = dir.json(String.format(Locale.ROOT, "chunk-%04d.json", index));
            JSONObject expected = RootUploader.base(source, piece);
            String format = piece.optString("audioFormat", "wav");
            if (!capture.equals(expected.getString("captureId")) || index != expected.getInt("piece")) throw new SecurityException("upload capture");
            JSONObject request = dir.json(RootUploader.name(index,"request"));
            if(!request.optString("mode","").isEmpty())throw new SecurityException("upload request mode");
            if (!capture.equals(request.getString("captureId")) || index != request.getInt("piece") || !nonce.equals(request.getString("attempt"))
                    || pid != request.getInt("parentPid") || !ticks.equals(request.getString("parentTicks"))) throw new SecurityException("upload claim");
            if (RootUploader.confirmed(dir,index,expected)) return;
            String credential = RootUploadCredential.read(app);
            if (credential == null) throw new SecurityException("upload disconnected");
            allowed(app, dir, index, credential, pid, ticks, nonce);
            PowerManager.WakeLock wake = ((PowerManager) app.context.getSystemService(android.content.Context.POWER_SERVICE))
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "APT:RootUpload");
            wake.acquire(100000);
            try {
                FileDescriptor audio = Os.open(dir.file(String.format(Locale.ROOT, "chunk-%04d.%s", index, format)).toString(), OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW, 0);
                try {
                    StructStat stat = Os.fstat(audio);
                    if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_uid != 0 || stat.st_gid != 0 || (stat.st_mode & 002) != 0
                            || stat.st_size != piece.getLong("size") || stat.st_size < 46 || stat.st_size > 19200044) throw new SecurityException("upload audio identity");
                    byte[] header = new byte[44]; int offset = 0;
                    while (offset < header.length) { int n = Os.read(audio, header, offset, header.length - offset); if (n < 1) throw new SecurityException("upload header"); offset += n; }
                    ByteBuffer h = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN);
                    if (format.equals("wav") && (!"RIFF".equals(new String(header,0,4,StandardCharsets.US_ASCII)) || !"WAVEfmt ".equals(new String(header,8,8,StandardCharsets.US_ASCII))
                            || !"data".equals(new String(header,36,4,StandardCharsets.US_ASCII)) || h.getInt(4) != stat.st_size - 8 || h.getInt(16) != 16
                            || h.getShort(20) != 1 || h.getShort(22) != 1 || h.getInt(24) != 16000 || h.getInt(28) != 32000
                            || h.getShort(32) != 2 || h.getShort(34) != 16 || h.getInt(40) != stat.st_size - 44)) throw new SecurityException("upload WAV format");
                    if (format.equals("m4a") && !"ftyp".equals(new String(header,4,4,StandardCharsets.US_ASCII))) throw new SecurityException("upload AAC format");
                    MessageDigest hash = MessageDigest.getInstance("SHA-256"); hash.update(header); byte[] buffer = new byte[65536]; long read = 44;
                    while (read < stat.st_size) { int n = Os.read(audio, buffer, 0, (int)Math.min(buffer.length, stat.st_size - read)); if (n < 1) throw new SecurityException("upload short audio"); hash.update(buffer,0,n); read += n; }
                    StringBuilder sha = new StringBuilder(); for (byte b : hash.digest()) sha.append(String.format(Locale.ROOT,"%02x",b & 255));
                    if (!sha.toString().equals(piece.getString("sha256"))) throw new SecurityException("upload fingerprint");
                    allowed(app, dir, index, credential, pid, ticks, nonce); Os.lseek(audio, 0, OsConstants.SEEK_SET);
                    HttpsURLConnection connection = (HttpsURLConnection) new URL("https://apt-backend.example/stepx/upload?key="
                            + URLEncoder.encode(expected.getString("key"), "UTF-8")
                            + (format.equals("m4a") ? "&frames=" + piece.getLong("frames") : "")).openConnection();
                    connection.setInstanceFollowRedirects(false); connection.setConnectTimeout(10000); connection.setReadTimeout(15000);
                    connection.setRequestMethod("POST"); connection.setDoOutput(true); connection.setFixedLengthStreamingMode(stat.st_size);
                    connection.setRequestProperty("Content-Type",format.equals("m4a") ? "audio/mp4" : "audio/wav"); connection.setRequestProperty("X-Growth-Token",credential);
                    try {
                        try (OutputStream output = connection.getOutputStream()) {
                            long sent = 0;
                            while (sent < stat.st_size) {
                                // Check again after connect/handshake, before the first and every later body block.
                                allowed(app, dir, index, credential, pid, ticks, nonce);
                                int n = Os.read(audio, buffer, 0, (int)Math.min(buffer.length,stat.st_size - sent));
                                if (n < 1) throw new SecurityException("upload short stream"); output.write(buffer,0,n); sent += n;
                            }
                        }
                        if (connection.getResponseCode() != 200) throw new IllegalStateException("upload response");
                        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                        try (InputStream input = connection.getInputStream()) {
                            for (int n; (n = input.read(buffer)) != -1;) { if (bytes.size() + n > 8192) throw new SecurityException("upload response size"); bytes.write(buffer,0,n); }
                        }
                        JSONObject receipt = new JSONObject(new String(bytes.toByteArray(),StandardCharsets.UTF_8));
                        Object seconds = receipt.get("durationSec");
                        if (!expected.getString("key").equals(receipt.getString("key")) || !(seconds instanceof Number)
                                || !Double.isFinite(((Number)seconds).doubleValue())
                                || Math.abs(expected.getDouble("durationSec") - ((Number)seconds).doubleValue()) > 0.001) throw new SecurityException("upload response identity");
                        allowed(app, dir, index, credential, pid, ticks, nonce);
                        dir.write(RootUploader.name(index,"receipt"), expected.put("state","uploaded").put("uploadedAt",System.currentTimeMillis()), true, false);
                        RootUploader.publish(app,dir,index,expected);
                    } finally { connection.disconnect(); }
                } finally { Os.close(audio); }
            } finally { if (wake.isHeld()) wake.release(); }
        }
    }
}
