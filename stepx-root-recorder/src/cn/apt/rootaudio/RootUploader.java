package cn.apt.rootaudio;

import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Locale;
import java.util.concurrent.TimeUnit;
import org.json.JSONObject;

/** One bounded network child at a time. Never runs on the capture/control loop. */
final class RootUploader {
    private final RootApp app;
    private final String rootPath;
    private volatile JSONObject activeRequest;
    private volatile String activeMatter;
    RootUploader(RootApp app, String rootPath) { this.app = app; this.rootPath = rootPath; }
    void revoke(String matter) {
        JSONObject request = activeRequest;
        if (request == null || !matter.equals(activeMatter)) return;
        Thread cancel = new Thread(() -> {
            try { RootUploadProcess.stop(request); } catch (Exception uncertain) { /* Main runner must confirm cleanup before another attempt. */ }
        },"apt-upload-revoke");
        cancel.setDaemon(true); cancel.start();
    }
    void start() {
        Thread thread = new Thread(() -> {
            for (;;) {
                try { scan(); } catch (Exception ignored) { /* Preserve originals and retry; never log credentials. */ }
                try { Thread.sleep(5000); } catch (InterruptedException stopped) { return; }
            }
        }, "apt-root-upload");
        thread.setDaemon(true); thread.start();
    }
    static String name(int piece, String suffix) { return String.format(Locale.ROOT, "upload-%04d.%s.json", piece, suffix); }
    static boolean cancelled(PrivateDirectory dir, int piece) throws Exception {
        String matter = RootMailbox.uuid(dir.json("source.json"), "matterId");
        try (PrivateDirectory root = new PrivateDirectory(java.nio.file.Paths.get(dir.canonical).getParent().toString(),0,true)) {
            String tombstone = "forget-" + matter + ".json";
            if (Files.exists(root.file(tombstone))) {
                if (!matter.equals(RootMailbox.uuid(root.json(tombstone),"matterId"))) throw new SecurityException("upload tombstone");
                return true;
            }
        }
        String ack = String.format(Locale.ROOT, "chunk-%04d.ack.json", piece);
        return Files.exists(dir.file(ack)) && !"saved".equals(dir.json(ack).optString("disposition"));
    }
    static boolean cancelled(RootApp app, PrivateDirectory dir, int piece) throws Exception {
        return cancelled(dir,piece) || RootUploadCredential.deleted(app,RootMailbox.uuid(dir.json("source.json"),"matterId"));
    }
    static boolean same(JSONObject value, JSONObject expected) throws Exception {
        for (String key : new String[]{"captureId","matterId","sha256","key"}) if (!expected.getString(key).equals(value.getString(key))) return false;
        for (String key : new String[]{"piece","frames"}) {
            Object n = value.get(key);
            if (!(n instanceof Number) || !Double.isFinite(((Number)n).doubleValue())
                    || expected.getLong(key) != ((Number)n).doubleValue()) return false;
        }
        Object seconds = value.get("durationSec");
        return seconds instanceof Number && Double.isFinite(((Number)seconds).doubleValue())
                && expected.getDouble("durationSec") == ((Number)seconds).doubleValue();
    }
    static boolean confirmed(PrivateDirectory dir, int index, JSONObject expected) throws Exception {
        String name = name(index,"receipt");
        if (!Files.exists(dir.file(name))) return false;
        try {
            JSONObject receipt = dir.json(name);
            if (validReceipt(receipt,expected)) return true;
        } catch (Exception invalid) { /* Preserve the invalid receipt before retrying the same content-addressed object. */ }
        dir.check();
        Files.move(dir.file(name),dir.file("invalid-upload-" + java.util.UUID.randomUUID() + ".json"),java.nio.file.StandardCopyOption.ATOMIC_MOVE);
        return false;
    }
    private static boolean validReceipt(JSONObject receipt, JSONObject expected) throws Exception {
        Object at = receipt.get("uploadedAt");
        return same(receipt,expected) && "uploaded".equals(receipt.getString("state")) && at instanceof Number
                && Double.isFinite(((Number)at).doubleValue()) && ((Number)at).doubleValue() > 0
                && ((Number)at).doubleValue() <= 9007199254740991L
                && ((Number)at).doubleValue() == Math.rint(((Number)at).doubleValue());
    }
    private static JSONObject projection(JSONObject receipt, JSONObject expected) throws Exception {
        return new JSONObject(expected.toString()).put("state","uploaded").put("uploadedAt",receipt.getLong("uploadedAt"));
    }
    static void publish(RootApp app, PrivateDirectory dir, int index, JSONObject expected) throws Exception {
        JSONObject receipt = dir.json(name(index,"receipt"));
        if (!validReceipt(receipt,expected)) throw new SecurityException("upload publish receipt");
        String file = "apt-root-upload-" + expected.getString("captureId") + "-" + String.format(Locale.ROOT,"%04d",index) + ".json";
        try (PrivateDirectory media = new PrivateDirectory(app.data + "/files/media",app.uid,false)) {
            try {
                JSONObject current = new JSONObject(media.read(file,8192,0));
                if (validReceipt(current,expected) && current.getLong("uploadedAt") == receipt.getLong("uploadedAt")) return;
            } catch (Exception missingOrChanged) { /* Only this reserved metadata name is repaired; audio is never replaced. */ }
            media.write(file,projection(receipt,expected),false,true);
        }
    }
    static JSONObject status(PrivateDirectory dir, JSONObject source, JSONObject piece) throws Exception {
        JSONObject result = base(source,piece); int index = piece.getInt("piece");
        try {
            if (cancelled(dir,index)) return result.put("state","cancelled");
            String receipt = name(index,"receipt"), state = name(index,"state");
            if (Files.exists(dir.file(receipt))) { JSONObject value = dir.json(receipt); if (validReceipt(value,result)) return projection(value,result); }
            if (Files.exists(dir.file(state))) {
                JSONObject value = dir.json(state);
                if (same(value,result) && java.util.Arrays.asList("pending","uploading","waiting-connection").contains(value.optString("state")))
                    return result.put("state",value.getString("state"));
            }
        } catch (Exception unavailable) { /* Upload metadata never invalidates capture/audio metadata. */ }
        return result.put("state","pending").put("error","upload-receipt-unavailable");
    }
    private void settle(PrivateDirectory root) throws Exception {
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(root.path,"capture-*")) {
            for (Path entry : entries) {
                String capture = entry.getFileName().toString(); if (!capture.matches("capture-[0-9a-f-]{36}")) continue;
                try (PrivateDirectory dir = new PrivateDirectory(root.canonical + "/" + capture,0,true);
                     DirectoryStream<Path> requests = Files.newDirectoryStream(dir.path,"upload-*.request.json")) {
                    for (Path path : requests) {
                        String name = path.getFileName().toString(); if (!name.matches("upload-[0-9]{4}\\.request\\.json")) continue;
                        RootUploadProcess.stop(dir.json(name)); Files.delete(dir.file(name));
                    }
                }
            }
        }
    }
    void settlePrevious() throws Exception {
        try (PrivateDirectory root = new PrivateDirectory(rootPath,0,true)) { settle(root); }
    }
    static JSONObject base(JSONObject source, JSONObject piece) throws Exception {
        String client = RootMailbox.uuid(source, "uploadClient"), capture = RootMailbox.uuid(source, "captureId");
        String matter = RootMailbox.uuid(source, "matterId"); int index = piece.getInt("piece");
        long frames = piece.getLong("frames");
        String format = piece.optString("audioFormat", "wav");
        if (!format.equals("wav") && !format.equals("m4a")) throw new SecurityException("upload audio format");
        if (source.optBoolean("validation", true) || !piece.getBoolean("cloudEligible")
                || !capture.equals(piece.getString("captureId")) || !matter.equals(piece.getString("matterId"))
                || index < 0 || index > 8640 || frames < 1 || frames > source.getInt("chunkSeconds") * 16000L
                || piece.getLong("frameOffset") != index * source.getInt("chunkSeconds") * 16000L
                || piece.getInt("index") != source.getInt("indexBase") + index
                || (format.equals("wav") ? piece.getLong("size") != 44 + frames * 2
                    : !"m4a".equals(source.optString("audioFormat")) || piece.getLong("size") < 46
                        || piece.getLong("size") > 44 + frames * 2)) throw new SecurityException("upload receipt identity");
        return new JSONObject().put("captureId", capture).put("matterId", matter).put("piece", index)
                .put("frames", frames).put("sha256", piece.getString("sha256"))
                .put("key", RootUploadIdentity.key(client, matter, capture, index, piece.getString("sha256"), format))
                .put("durationSec", frames / 16000.0);
    }
    private void scan() throws Exception {
        app.check(true);
        try (PrivateDirectory root = new PrivateDirectory(rootPath, 0, true);
             DirectoryStream<Path> entries = Files.newDirectoryStream(root.path, "capture-*")) {
            settle(root);
            ArrayList<String> captures = new ArrayList<>();
            for (Path entry : entries) if (entry.getFileName().toString().matches("capture-[0-9a-f-]{36}")) captures.add(entry.getFileName().toString());
            Collections.sort(captures);
            for (String capture : captures) {
                try (PrivateDirectory dir = new PrivateDirectory(root.canonical + "/" + capture, 0, true)) {
                    JSONObject source = dir.json("source.json");
                    if ("m4a".equals(source.optString("audioFormat"))) prepare(dir,source);
                    if (!source.has("uploadClient") || source.optBoolean("validation", true)) continue;
                    if(RootPipeline.enabled(source)&&cancelled(app,dir,0)) {
                        if(!RootPipeline.revocationConfirmed(dir,source))attempt(dir,source,0,new JSONObject(),"revoke");
                        continue;
                    }
                    ArrayList<String> receipts = new ArrayList<>();
                    try (DirectoryStream<Path> chunks = Files.newDirectoryStream(dir.path, "chunk-*.json")) {
                        for (Path chunk : chunks) if (chunk.getFileName().toString().matches("chunk-[0-9]{4}\\.json")) receipts.add(chunk.getFileName().toString());
                    }
                    Collections.sort(receipts);
                    for (String receipt : receipts) {
                        try {
                        JSONObject piece = dir.json(receipt), state = base(source, piece); int index = piece.getInt("piece");
                        if (cancelled(app,dir,index)) continue;
                        boolean uploaded=confirmed(dir,index,state);
                        if(uploaded){publish(app,dir,index,state);RootPcmCompression.releaseRecovery(dir,source,piece,state);if(RootPipeline.confirmed(dir,source,index))continue;}
                        attempt(dir,source,index,state,uploaded?"pipeline":"");
                        } catch (RootUploadProcess.Unconfirmed uncertain) { throw uncertain; }
                        catch (Exception invalidPiece) { /* One damaged piece cannot starve later completed audio. */ }
                    }
                    if(RootPipeline.enabled(source)&&Files.exists(dir.file("progress.json"))&&!RootPipeline.captureConfirmed(dir,source))
                        attempt(dir,source,0,new JSONObject(),"pipeline");
                } catch (RootUploadProcess.Unconfirmed stopUnconfirmed) { throw stopUnconfirmed; }
                catch (Exception isolated) { /* A damaged capture cannot starve healthy captures; uncertain children remain a global barrier. */ }
            }
        }
    }
    private void attempt(PrivateDirectory dir,JSONObject source,int index,JSONObject state,String mode) throws Exception {
        String stateName=mode.isEmpty()?name(index,"state"):String.format(Locale.ROOT,"pipeline-%s-%04d.state.json",mode,index);
        JSONObject prior=Files.exists(dir.file(stateName))?dir.json(stateName):new JSONObject();
        if(prior.optLong("nextAt",0)>System.currentTimeMillis())return;
        if(RootUploadCredential.read(app)==null){dir.write(stateName,state.put("state","waiting-connection").put("attempts",prior.optInt("attempts",0)),false,false);return;}
        int attempts=Math.min(prior.optInt("attempts",0)+1,1000000);
        dir.write(stateName,state.put("state","uploading").put("attempts",attempts),false,false);
        String pid=Integer.toString(android.os.Process.myPid()),ticks=RootUploadProcess.ticks(Integer.parseInt(pid)),nonce=java.util.UUID.randomUUID().toString();
        JSONObject request=new JSONObject().put("captureId",source.getString("captureId")).put("piece",index)
                .put("parentPid",Integer.parseInt(pid)).put("parentTicks",ticks).put("attempt",nonce);
        if(!mode.isEmpty())request.put("mode",mode);
        String requestName=name(index,"request");dir.write(requestName,request,true,false);activeMatter=source.getString("matterId");activeRequest=request;
        ArrayList<String> args=new ArrayList<>(java.util.Arrays.asList("/system/bin/timeout","-k","5","95","/system/bin/app_process","/system/bin",
                "cn.apt.rootaudio.RootUploadWorker",source.getString("captureId"),Integer.toString(index),pid,ticks,nonce));
        if(!mode.isEmpty())args.add(mode);
        ProcessBuilder command=new ProcessBuilder(args);command.redirectErrorStream(true);command.redirectOutput(dir.file(String.format(Locale.ROOT,"upload-%04d.log",index)).toFile());
        try{java.lang.Process worker=command.start();worker.waitFor(110,TimeUnit.SECONDS);}
        finally{RootUploadProcess.stop(request);Files.delete(dir.file(requestName));activeRequest=null;activeMatter=null;}
        boolean complete;
        if(mode.equals("revoke"))complete=RootPipeline.revocationConfirmed(dir,source);
        else if(mode.equals("pipeline"))complete=RootPipeline.captureConfirmed(dir,source)
                &&(!Files.exists(dir.file(String.format(Locale.ROOT,"chunk-%04d.json",index)))||RootPipeline.confirmed(dir,source,index));
        else {complete=confirmed(dir,index,state);if(complete)publish(app,dir,index,state);}
        if(!complete)dir.write(stateName,state.put("state","pending").put("error","network-or-server")
                .put("nextAt",System.currentTimeMillis()+Math.min(300000L,5000L<<Math.min(attempts-1,6))),false,false);
    }
    private void prepare(PrivateDirectory dir, JSONObject source) throws Exception {
        ArrayList<Integer> pending = new ArrayList<>();
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(dir.path,"pcm-*.json")) {
            for (Path path : entries) {
                String file = path.getFileName().toString();
                if (file.matches("pcm-[0-9]{4}\\.json")) pending.add(Integer.parseInt(file.substring(4,8)));
            }
        }
        Collections.sort(pending);
        for (int index : pending) {
            if (Files.exists(dir.file(RootPcmCompression.name(index,"chunk"))) || cancelled(app,dir,index)) continue;
            app.check(true);
            int pid = android.os.Process.myPid(); String ticks = RootUploadProcess.ticks(pid), nonce = java.util.UUID.randomUUID().toString();
            JSONObject request = new JSONObject().put("captureId",source.getString("captureId")).put("piece",index)
                    .put("parentPid",pid).put("parentTicks",ticks).put("attempt",nonce).put("mode","prepare");
            String requestName = name(index,"request"); dir.write(requestName,request,true,false);
            activeMatter = source.getString("matterId"); activeRequest = request;
            ProcessBuilder command = new ProcessBuilder("/system/bin/timeout","-k","5","95","/system/bin/app_process","/system/bin",
                    "cn.apt.rootaudio.RootUploadWorker",source.getString("captureId"),Integer.toString(index),Integer.toString(pid),ticks,nonce,"prepare");
            command.redirectErrorStream(true); command.redirectOutput(dir.file(String.format(Locale.ROOT,"compress-%04d.log",index)).toFile());
            try { java.lang.Process worker = command.start(); worker.waitFor(110,TimeUnit.SECONDS); }
            finally { RootUploadProcess.stop(request); Files.delete(dir.file(requestName)); activeRequest = null; activeMatter = null; }
        }
    }
}
