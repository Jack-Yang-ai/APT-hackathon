package cn.apt.rootaudio;

import android.content.Context;
import android.net.LocalServerSocket;
import android.os.SystemClock;
import android.system.Os;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.DirectoryStream;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.UUID;
import org.json.JSONArray;
import org.json.JSONObject;

/** Explicitly provisioned idle controller. No TCP, shell commands, boot recording or prefs writes. */
public final class RootController {
    private final RootApp app;
    private final PrivateDirectory root, media;
    private final RootMailbox mailbox;
    private final RootUploader uploader;
    private final String epoch = UUID.randomUUID().toString();
    private final boolean validation;
    private final int testLimit, testChunk;
    private PrivateDirectory active;
    private java.lang.Process worker;
    private JSONObject last = new JSONObject(), current;
    private long stoppingAt, workerStarted;
    private String observed = "", stopReason;
    private int wrapperPid;
    private String wrapperTicks;
    private RootController(Context context, String[] args) throws Exception {
        validation = args.length == 3 && "--validation".equals(args[0]);
        if (args.length != 0 && !validation) throw new IllegalArgumentException("controller arguments");
        testLimit = validation ? Integer.parseInt(args[1]) : 43200;
        testChunk = validation ? Integer.parseInt(args[2]) : 300;
        if (testLimit < 12 || testLimit > 43200 || testChunk < 5 || testChunk > 600) throw new IllegalArgumentException("validation bound");
        app = new RootApp(context);
        try (PrivateDirectory files = new PrivateDirectory(app.data + "/files", app.uid, false)) { root = files.child("apt-root-recorder"); }
        media = new PrivateDirectory(app.data + "/files/media", app.uid, false); mailbox = new RootMailbox(app);
        settlePrevious();
        uploader = new RootUploader(app, root.canonical); uploader.settlePrevious(); if (!validation) uploader.start();
    }
    public static void main(String[] args) {
        try (LocalServerSocket lease = new LocalServerSocket("cn.apt.rootaudio.controller.v1")) {
            RootController controller = new RootController(RootPlatform.context(), args);
            System.out.println("CONTROLLER_READY version=1.3.0 uid=0 epoch=" + controller.epoch); System.out.flush();
            controller.loop();
        } catch (Exception error) {
            String reason = error.getMessage();
            System.out.println("CONTROLLER_FAILED type=" + error.getClass().getSimpleName()
                    + " reason=" + (reason != null && reason.matches("[a-zA-Z /-]{1,80}") ? reason : "initialization"));
        }
        System.exit(1);
    }
    private void loop() throws Exception {
        long published = 0;
        try {
            for (;;) {
                long now = SystemClock.elapsedRealtime(); app.check(worker != null);
                if (worker != null && current != null) {
                    boolean deleted = false;
                    try { deleted = RootUploadCredential.deleted(app,current.getString("matterId")); }
                    catch (Exception transientPrefs) { /* Uploads fail closed independently; a partial prefs write cannot stop the microphone. */ }
                    if (deleted) forget(current.getString("matterId"));
                }
                if (active != null && worker != null) {
                    active.write("parent.json", new JSONObject().put("elapsed", now).put("epoch", epoch), false, false);
                    JSONObject progress = null;
                    if (Files.exists(active.file("progress.json"))) progress = active.json("progress.json");
                    if (progress != null && now - progress.getLong("updatedElapsed") > 6000) stop("capture-stalled");
                    if (progress == null && now - workerStarted > 8000) stop("capture-start-timeout");
                    if (stoppingAt > 0 && now - stoppingAt > 7000) killVerified();
                    if (!worker.isAlive()) {
                        if (!Files.exists(active.file("result.json"))) active.write("result.json", new JSONObject()
                                .put("captureId", current.getString("captureId")).put("matterId", current.getString("matterId"))
                                .put("state", "failed").put("reason", stopReason == null ? "process-lost-tail-pending" : stopReason)
                                .put("frames", savedFrames(active,current)), true, false);
                        repairFailedFrames(active,current);
                        worker = null; stoppingAt = 0; new RootNotice(app.context, RootApp.PACKAGE).clear();
                    }
                }
                JSONObject command = null;
                try { command = mailbox.read(); } catch (Exception invalid) { /* Never copy arbitrary prefs into logs/status. */ }
                if (command != null && !command.optString("commandId").equals(observed)) {
                    observed = command.optString("commandId");
                    try { apply(command); last = new JSONObject().put("id", observed).put("ok", true); }
                    catch (Exception refused) { last = new JSONObject().put("id", observed.matches("[0-9a-f-]{36}") ? observed : "invalid")
                            .put("ok", false).put("error", "command-refused"); }
                    published = 0;
                }
                if (now - published >= 1000) { publish(); published = now; }
                Thread.sleep(250);
            }
        } finally {
            if (worker != null) {
                try { stop("controller-exit"); } catch (Exception ignored) { }
                long deadline = SystemClock.elapsedRealtime() + 7000;
                while (worker.isAlive() && SystemClock.elapsedRealtime() < deadline) Thread.sleep(100);
                if (worker.isAlive()) killVerified();
            }
            try { new RootNotice(app.context, RootApp.PACKAGE).clear(); } catch (Exception ignored) { }
        }
    }
    private void apply(JSONObject command) throws Exception {
        String id = RootMailbox.uuid(command, "commandId");
        long age = System.currentTimeMillis() - command.getLong("createdAt");
        if (command.getInt("version") != 1 || !epoch.equals(command.getString("epoch")) || age < -5000 || age > 30000)
            throw new SecurityException("epoch/age");
        Path seen = root.file("command-" + id + ".json");
        if (Files.exists(seen)) throw new SecurityException("replay");
        String action = command.getString("action");
        if (!action.equals("start") && !action.equals("stop") && !action.equals("ack") && !action.equals("ping") && !action.equals("forget")) throw new SecurityException("action");
        // Claim before acting: a crash can lose a receipt, but can never replay START.
        root.write(seen.getFileName().toString(), new JSONObject().put("id", id).put("action", action).put("epoch", epoch), true, false);
        if (action.equals("start")) start(command);
        if (action.equals("forget")) {
            String matter = RootMailbox.uuid(command,"matterId");
            forget(matter);
        }
        if (action.equals("stop")) {
            String capture = RootMailbox.uuid(command, "captureId");
            if(command.has("finishMatter"))try(PrivateDirectory dir=new PrivateDirectory(root.canonical+"/capture-"+capture,0,true)) {
                JSONObject intent=new JSONObject().put("finish",command.getBoolean("finishMatter")).put("endedAt",command.getLong("createdAt"));
                if(!Files.exists(dir.file("stop-intent.json"))||!dir.json("stop-intent.json").getBoolean("finish"))dir.write("stop-intent.json",intent,false,false);
            }
            String cancelled = "cancel-" + capture + ".json";
            if (!Files.exists(root.file(cancelled))) root.write(cancelled, new JSONObject().put("captureId", capture), true, false);
            if (current != null && current.getString("captureId").equals(capture)) stop("requested");
        }
        if (action.equals("ack")) {
            String capture = RootMailbox.uuid(command, "captureId"); int piece = command.getInt("piece");
            if (piece < 0 || piece > 8640) throw new SecurityException("piece");
            try (PrivateDirectory dir = new PrivateDirectory(root.canonical + "/capture-" + capture, 0, true)) {
                JSONObject receipt = dir.json(String.format(Locale.ROOT, "chunk-%04d.json", piece));
                if (!receipt.getString("sha256").equals(command.getString("sha256"))
                        || !receipt.getString("matterId").equals(RootMailbox.uuid(command, "matterId"))) throw new SecurityException("ack identity");
                String name = String.format(Locale.ROOT, "chunk-%04d.ack.json", piece);
                String disposition = command.optString("disposition", "legacy");
                if (!disposition.equals("saved") && !disposition.equals("deleted") && !disposition.equals("legacy")) throw new SecurityException("ack disposition");
                if (!Files.exists(dir.file(name))) dir.write(name, new JSONObject().put("sha256", receipt.getString("sha256"))
                        .put("disposition", disposition), true, false);
            }
        }
    }
    private void forget(String matter) throws Exception {
        String tombstone = "forget-" + RootUploadIdentity.uuid(matter) + ".json";
        if (!Files.exists(root.file(tombstone))) root.write(tombstone,new JSONObject().put("matterId",matter),true,false);
        uploader.revoke(matter);
        if (worker != null && current != null && matter.equals(current.getString("matterId"))) stop("source-deleted");
    }
    private void start(JSONObject command) throws Exception {
        if (worker != null) throw new IllegalStateException("already capturing");
        app.check(true);
        String capture = RootMailbox.uuid(command, "captureId"), matter = RootMailbox.uuid(command, "matterId");
        int base = command.getInt("indexBase"), seconds = command.getInt("chunkSeconds");
        if (base < 0 || base > 10000 || seconds != 300 && seconds != 600) throw new SecurityException("start bounds");
        String audioFormat = command.optString("audioFormat", "wav");
        if (!audioFormat.equals("wav") && !audioFormat.equals("m4a") || validation && !audioFormat.equals("wav")) throw new SecurityException("audio format");
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(root.path, "capture-*")) {
            for (Path entry : entries) {
                String previous = entry.getFileName().toString();
                if (!previous.matches("capture-[0-9a-f-]{36}")) continue;
                try (PrivateDirectory dir = new PrivateDirectory(root.canonical + "/" + previous, 0, true)) {
                    JSONObject source;
                    try { source = dir.json("source.json"); } catch (Exception isolated) { continue; }
                    if (matter.equals(source.optString("matterId")) && base < nextIndex(dir,source))
                        throw new SecurityException("overlapping capture indices");
                }
            }
        }
        if (root.path.toFile().getUsableSpace() < 256L * 1024 * 1024) throw new IllegalStateException("storage-low");
        String name = "capture-" + capture;
        if (Files.exists(root.file("cancel-" + capture + ".json"))) throw new SecurityException("cancelled capture");
        if (Files.exists(root.file("forget-" + matter + ".json")) || RootUploadCredential.deleted(app,matter)) throw new SecurityException("deleted upload owner");
        if (Files.exists(root.file(name))) throw new SecurityException("used capture");
        if (active != null) { active.close(); active = null; }
        active = root.child(name);
        current = new JSONObject().put("captureId", capture).put("matterId", matter).put("indexBase", base)
                .put("chunkSeconds", validation ? testChunk : seconds).put("limitSeconds", testLimit)
                .put("requestedAt", command.getLong("createdAt")).put("validation", validation);
        if (command.has("uploadClient")) current.put("uploadClient", RootMailbox.uuid(command, "uploadClient"));
        current.put("audioFormat", audioFormat);
        if(command.has("background")) {
            if(validation||!current.has("uploadClient"))throw new SecurityException("background upload authorization");
            current.put("background",RootPipeline.authorization(command.getJSONObject("background"),matter));
        }
        active.write("source.json", current, true, false);
        active.write("parent.json", new JSONObject().put("elapsed", SystemClock.elapsedRealtime()).put("epoch", epoch), false, false);
        stopReason = null; stoppingAt = 0;
        ProcessBuilder process = new ProcessBuilder("/system/bin/timeout", "-k", "5", Integer.toString(testLimit + 15),
                "/system/bin/app_process", "/system/bin", "cn.apt.rootaudio.ProductionCapture", capture);
        process.redirectErrorStream(true); process.redirectOutput(active.file("capture.log").toFile());
        workerStarted = SystemClock.elapsedRealtime(); worker = process.start();
        Class<?> type = worker.getClass(); java.lang.reflect.Field field = null;
        while (type != null && field == null) {
            try { field = type.getDeclaredField("pid"); } catch (NoSuchFieldException ignored) { type = type.getSuperclass(); }
        }
        if (field == null) throw new IllegalStateException("process identity unavailable");
        field.setAccessible(true); wrapperPid = field.getInt(worker);
        wrapperTicks = procTicks(wrapperPid);
        active.write("worker.json", new JSONObject().put("pid", wrapperPid).put("startTicks", wrapperTicks), true, false);
        supervise(active.canonical, capture, worker, wrapperPid, wrapperTicks);
    }
    private void stop(String reason) throws Exception {
        if (worker == null || active == null) return;
        stopReason = reason;
        if (!Files.exists(active.file("stop"))) active.write("stop", new JSONObject().put("reason", reason)
                .put("elapsed", SystemClock.elapsedRealtime()), true, false);
        if (stoppingAt == 0) stoppingAt = SystemClock.elapsedRealtime();
    }
    private void killVerified() throws Exception {
        if (active == null) return;
        if (Files.exists(active.file("identity.json"))) {
            JSONObject identity = active.json("identity.json");
            kill(identity.getInt("pid"), identity.getString("startTicks"), current.getString("captureId")); return;
        }
        // Even a VM stopped before main's handshake belongs to this exact timeout
        // process. Verify its kernel identity and only its direct capture child.
        if (worker != null && worker.isAlive() && wrapperTicks != null && wrapperTicks.equals(procTicks(wrapperPid))) {
            Path proc = java.nio.file.Paths.get("/proc/" + wrapperPid);
            String command = new String(Files.readAllBytes(proc.resolve("cmdline")), StandardCharsets.US_ASCII);
            if (!command.contains("cn.apt.rootaudio.ProductionCapture") || !command.contains(current.getString("captureId")))
                throw new SecurityException("wrapper identity");
            String children = new String(Files.readAllBytes(proc.resolve("task/" + wrapperPid + "/children")), StandardCharsets.US_ASCII).trim();
            if (children.length() > 64) throw new SecurityException("wrapper children");
            if (!children.isEmpty()) for (String child : children.split(" +")) {
                int pid = Integer.parseInt(child);
                String stat = new String(Files.readAllBytes(java.nio.file.Paths.get("/proc/" + pid + "/stat")), StandardCharsets.US_ASCII);
                if (Integer.parseInt(stat.substring(stat.lastIndexOf(')') + 2).split(" ")[1]) != wrapperPid) throw new SecurityException("child parent");
                kill(pid, procTicks(pid), current.getString("captureId"));
            }
            worker.destroyForcibly();
        }
    }
    private static String procTicks(int pid) throws Exception {
        if (pid <= 1 || Os.lstat("/proc/" + pid).st_uid != 0) throw new SecurityException("process uid");
        String stat = new String(Files.readAllBytes(java.nio.file.Paths.get("/proc/" + pid + "/stat")), StandardCharsets.US_ASCII);
        return stat.substring(stat.lastIndexOf(')') + 2).split(" ")[19];
    }
    private static void kill(int pid, String ticks, String captureId) throws Exception {
        String command = new String(Files.readAllBytes(java.nio.file.Paths.get("/proc/" + pid + "/cmdline")), StandardCharsets.US_ASCII);
        if (!ticks.equals(procTicks(pid)) || !command.contains("cn.apt.rootaudio.ProductionCapture")
                || !command.contains(captureId)) throw new SecurityException("capture process identity");
        android.os.Process.sendSignal(pid, 9);
    }
    private static boolean live(JSONObject identity, String capture) throws Exception {
        int pid = identity.getInt("pid");
        if (!Files.exists(java.nio.file.Paths.get("/proc/" + pid))) return false;
        if (!identity.getString("startTicks").equals(procTicks(pid))) return false;
        String command = new String(Files.readAllBytes(java.nio.file.Paths.get("/proc/" + pid + "/cmdline")), StandardCharsets.US_ASCII);
        return command.contains("cn.apt.rootaudio.ProductionCapture") && command.contains(capture);
    }
    /** File-only supervisor: neither PM nor audio/notification Binder can block it. */
    private static void supervise(String directory, String capture, java.lang.Process worker, int wrapper, String ticks) {
        Thread guard = new Thread(() -> {
            long started = SystemClock.elapsedRealtime(), stopped = 0, lastFrames = -1, lastAdvance = started;
            try (PrivateDirectory dir = new PrivateDirectory(directory, 0, true)) {
                while (worker.isAlive()) {
                    long now = SystemClock.elapsedRealtime(); boolean expired = false;
                    if (Files.exists(dir.file("progress.json"))) {
                        JSONObject progress = dir.json("progress.json");
                        long frames = progress.getLong("frames");
                        if (frames > lastFrames) { lastFrames = frames; lastAdvance = now; }
                        expired = now - progress.getLong("updatedElapsed") > 6000 || now - lastAdvance > 6000;
                    }
                    else expired = now - started > 8000;
                    expired |= now - dir.json("parent.json").getLong("elapsed") > 6000;
                    if (expired && !Files.exists(dir.file("stop"))) dir.write("stop", new JSONObject()
                            .put("reason", "supervisor-timeout").put("elapsed", now), true, false);
                    if (Files.exists(dir.file("stop")) && stopped == 0) stopped = now;
                    if (stopped > 0 && now - stopped >= 7000) {
                        if (Files.exists(dir.file("identity.json"))) {
                            JSONObject identity = dir.json("identity.json");
                            if (live(identity, capture)) kill(identity.getInt("pid"), identity.getString("startTicks"), capture);
                        } else if (ticks.equals(procTicks(wrapper))) {
                            String children = new String(Files.readAllBytes(java.nio.file.Paths.get("/proc/" + wrapper + "/task/" + wrapper + "/children")), StandardCharsets.US_ASCII).trim();
                            if (children.length() > 64) throw new SecurityException("children");
                            if (!children.isEmpty()) for (String child : children.split(" +")) kill(Integer.parseInt(child), procTicks(Integer.parseInt(child)), capture);
                            worker.destroyForcibly();
                        }
                    }
                    Thread.sleep(250);
                }
            } catch (Exception error) {
                // Directory removal must not bypass the already held process identity.
                try {
                    if (worker.isAlive() && ticks.equals(procTicks(wrapper))) {
                        String children = new String(Files.readAllBytes(java.nio.file.Paths.get("/proc/" + wrapper + "/task/" + wrapper + "/children")), StandardCharsets.US_ASCII).trim();
                        if (children.length() <= 64 && !children.isEmpty()) for (String child : children.split(" +")) kill(Integer.parseInt(child), procTicks(Integer.parseInt(child)), capture);
                        worker.destroyForcibly();
                    }
                } catch (Exception unavailable) { System.out.println("SUPERVISOR_UNCONFIRMED"); }
            }
        }, "apt-capture-supervisor");
        guard.setDaemon(true); guard.start();
    }
    private void settlePrevious() throws Exception {
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(root.path, "capture-*")) {
            for (Path entry : entries) {
                String name = entry.getFileName().toString();
                if (!name.matches("capture-[0-9a-f-]{36}")) continue;
                try (PrivateDirectory dir = new PrivateDirectory(root.canonical + "/" + name, 0, true)) {
                    String capture = name.substring("capture-".length());
                    if (Files.exists(dir.file("identity.json"))) {
                        JSONObject identity = dir.json("identity.json");
                        if (live(identity, capture)) {
                            kill(identity.getInt("pid"), identity.getString("startTicks"), capture);
                            long deadline = SystemClock.elapsedRealtime() + 3000;
                            while (live(identity, capture) && SystemClock.elapsedRealtime() < deadline) Thread.sleep(50);
                            if (live(identity, capture)) throw new IllegalStateException("previous capture unconfirmed");
                        }
                    }
                    if (Files.exists(dir.file("worker.json"))) terminateWrapper(dir.json("worker.json"), capture);
                    if (!Files.exists(dir.file("source.json"))) continue;
                    JSONObject source;
                    try { source = dir.json("source.json"); RootMailbox.uuid(source, "matterId"); }
                    catch (Exception incomplete) { continue; }
                    if (Files.exists(dir.file("result.json"))) { repairFailedFrames(dir,source); continue; }
                    dir.write("result.json", new JSONObject().put("captureId", capture).put("matterId", source.getString("matterId"))
                            .put("state", "failed").put("reason", "controller-restarted-tail-pending")
                            .put("frames", savedFrames(dir, source)), true, false);
                }
            }
        }
    }
    private static void terminateWrapper(JSONObject identity, String capture) throws Exception {
        if (!live(identity, capture)) return;
        int pid = identity.getInt("pid");
        String children = new String(Files.readAllBytes(java.nio.file.Paths.get("/proc/" + pid + "/task/" + pid + "/children")), StandardCharsets.US_ASCII).trim();
        if (children.length() > 64) throw new SecurityException("previous children");
        if (!children.isEmpty()) for (String text : children.split(" +")) {
            int child = Integer.parseInt(text);
            if (Files.exists(java.nio.file.Paths.get("/proc/" + child))) {
                JSONObject candidate = new JSONObject().put("pid", child).put("startTicks", procTicks(child));
                if (live(candidate, capture)) kill(child, candidate.getString("startTicks"), capture);
            }
        }
        if (live(identity, capture)) android.os.Process.sendSignal(pid, 9);
        long deadline = SystemClock.elapsedRealtime() + 3000;
        while (live(identity, capture) && SystemClock.elapsedRealtime() < deadline) Thread.sleep(50);
        if (live(identity, capture)) throw new IllegalStateException("previous wrapper unconfirmed");
    }
    static void repairFailedFrames(PrivateDirectory dir, JSONObject source) throws Exception {
        JSONObject result = dir.json("result.json");
        if (!"failed".equals(result.optString("state"))) return;
        long frames = savedFrames(dir,source);
        if (frames > result.getLong("frames")) dir.write("result.json",result.put("frames",frames),false,false);
    }
    static int nextIndex(PrivateDirectory dir, JSONObject source) throws Exception {
        long frames = savedFrames(dir,source);
        try { frames = Math.max(frames,dir.json("result.json").getLong("frames")); }
        catch (Exception missing) { }
        if (frames < 0 || frames > source.getLong("limitSeconds") * 16000) throw new SecurityException("capture frames");
        return source.getInt("indexBase") + (int)((frames + source.getInt("chunkSeconds") * 16000L - 1) / (source.getInt("chunkSeconds") * 16000L));
    }
    static long savedFrames(PrivateDirectory dir, JSONObject source) throws Exception {
        long frames = 0, maximum = source.getLong("limitSeconds") * 16000;
        try {
            long progress = dir.json("progress.json").getLong("frames");
            if (progress >= 0 && progress <= maximum) frames = progress;
        } catch (Exception missing) { }
        try (DirectoryStream<Path> receipts = Files.newDirectoryStream(dir.path, "*.json")) {
            for (Path receipt : receipts) {
                String name = receipt.getFileName().toString(); if (!name.matches("(chunk|pcm)-[0-9]{4}\\.json")) continue;
                try {
                    JSONObject piece = dir.json(name); int index = piece.getInt("piece");
                    long count = piece.getLong("frames"), offset = piece.getLong("frameOffset"), end = offset + count;
                    String format = name.startsWith("pcm-") ? "wav" : piece.optString("audioFormat","wav");
                    if (piece.getString("captureId").equals(source.getString("captureId"))
                            && piece.getString("matterId").equals(source.getString("matterId"))
                            && index >= 0 && index <= 8640 && piece.getInt("index") == source.getInt("indexBase") + index
                            && count > 0 && count <= source.getInt("chunkSeconds") * 16000L
                            && offset == index * source.getInt("chunkSeconds") * 16000L && end <= maximum
                            && (format.equals("wav") || format.equals("m4a"))
                            && piece.getString("sha256").equals(RootPcmCompression.hash(dir.file(String.format(Locale.ROOT,"chunk-%04d.%s",index,format)))))
                        frames = Math.max(frames, end);
                } catch (Exception damaged) { }
            }
        }
        return frames;
    }
    private void publish() throws Exception {
        JSONArray sessions = new JSONArray(), pieces = new JSONArray(), uploads = new JSONArray();
        int isolated = 0;
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(root.path, "capture-*")) {
            for (Path entry : entries) {
                String name = entry.getFileName().toString();
                if (!name.matches("capture-[0-9a-f-]{36}")) continue;
                try (PrivateDirectory dir = new PrivateDirectory(root.canonical + "/" + name, 0, true)) {
                    JSONObject source = dir.json("source.json");
                    JSONObject session = new JSONObject(source.toString()).put("state", "failed").put("reason", "controller-restarted-tail-pending");
                    if (source.has("uploadClient")) session.put("uploadRevoked",Files.exists(root.file("forget-" + RootMailbox.uuid(source,"matterId") + ".json")));
                    if (Files.exists(dir.file("progress.json"))) {
                        JSONObject progress = dir.json("progress.json");
                        session.put("frames", progress.getLong("frames")).put("startedAt", progress.getLong("startedAt"));
                    }
                    if (Files.exists(dir.file("result.json"))) {
                        JSONObject result = dir.json("result.json");
                        session.put("state", result.getString("state")).put("reason", result.getString("reason"))
                                .put("frames", result.getLong("frames"));
                    } else if (worker != null && source.getString("captureId").equals(current.getString("captureId")))
                        session.put("state", stoppingAt > 0 ? "stopping" : session.optLong("frames", 0) > 0 ? "recording" : "starting").put("reason", JSONObject.NULL);
                    JSONArray sessionPieces = new JSONArray(), sessionUploads = new JSONArray();
                    try (DirectoryStream<Path> receipts = Files.newDirectoryStream(dir.path, "chunk-*.json")) {
                        for (Path receipt : receipts) {
                            String receiptName = receipt.getFileName().toString();
                            if (!receiptName.matches("chunk-[0-9]{4}\\.json")) continue;
                            JSONObject piece = dir.json(receiptName); int index = piece.getInt("piece");
                            if (Files.exists(dir.file(String.format(Locale.ROOT, "chunk-%04d.ack.json", index)))) continue;
                            if (source.has("uploadClient") && !source.optBoolean("validation", true)) {
                                sessionUploads.put(RootUploader.status(dir,source,piece));
                            }
                            String format = piece.optString("audioFormat", "wav");
                            if (!format.equals("wav") && !format.equals("m4a")) throw new SecurityException("audio format");
                            String file = "apt-root-" + source.getString("captureId") + "-" + String.format(Locale.ROOT, "%04d", index) + "." + format;
                            Path audio = dir.file(String.format(Locale.ROOT, "chunk-%04d.%s", index, format));
                            if (!Files.exists(media.file(file))) { Os.chmod(audio.toString(), 0644); Files.createLink(media.file(file), audio); }
                            JSONObject delivered = new JSONObject(piece.toString()).put("file", file);
                            if (source.has("uploadClient") && !source.optBoolean("validation", true)) delivered.put("uploadClient", source.getString("uploadClient"));
                            sessionPieces.put(delivered);
                        }
                    }
                    sessions.put(session);
                    for (int i = 0; i < sessionPieces.length(); i++) pieces.put(sessionPieces.get(i));
                    for (int i = 0; i < sessionUploads.length(); i++) uploads.put(sessionUploads.get(i));
                } catch (Exception damaged) {
                    isolated++;
                    if (active != null && worker != null && name.equals("capture-" + current.getString("captureId"))) {
                        stop("metadata-unavailable");
                        sessions.put(new JSONObject(current.toString()).put("state", "stopping").put("reason", JSONObject.NULL));
                    }
                }
            }
        }
        if (pieces.length() > 2000 || sessions.length() > 1000) throw new IllegalStateException("delivery backlog");
        JSONArray formats = new JSONArray().put("wav"); if (!validation) formats.put("m4a");
        media.write("apt-root-status-v1.json", new JSONObject().put("version", 1).put("runtime", "1.3.0")
                .put("audioFormats", formats).put("backgroundVersion",1)
                .put("epoch", epoch).put("updatedAt", System.currentTimeMillis()).put("validation", validation)
                .put("isolatedItems", isolated)
                .put("lastCommand", last).put("sessions", sessions).put("pieces", pieces).put("uploads", uploads), false, true);
    }
}
