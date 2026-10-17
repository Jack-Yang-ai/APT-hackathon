package cn.apt.rootaudio;

import android.system.Os;
import android.system.OsConstants;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.DirectoryStream;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import org.json.JSONObject;

/** Synthetic root-only fixture: real ART, FD operations and suspended process cleanup. Never records/uploads. */
public final class RootUploadAndroidTest {
    private static int checks;
    private static void check(boolean value, String reason) { checks++; if (!value) throw new AssertionError(reason); }
    private static int fds() throws Exception {
        int count = 0; try (DirectoryStream<Path> paths = Files.newDirectoryStream(java.nio.file.Paths.get("/proc/self/fd"))) { for (Path ignored : paths) count++; }
        return count;
    }
    private static boolean alive(int pid) {
        try {
            String stat = new String(Files.readAllBytes(java.nio.file.Paths.get("/proc/" + pid + "/stat")),StandardCharsets.US_ASCII);
            String state = stat.substring(stat.lastIndexOf(')')+2).split(" ")[0]; return !state.equals("Z") && !state.equals("X");
        } catch (Exception gone) { return false; }
    }
    private static int pid(java.lang.Process process) throws Exception {
        Class<?> type = process.getClass(); java.lang.reflect.Field field = null;
        while (type != null && field == null) { try { field = type.getDeclaredField("pid"); } catch (NoSuchFieldException missing) { type = type.getSuperclass(); } }
        if (field == null) throw new IllegalStateException("fixture pid"); field.setAccessible(true); return field.getInt(process);
    }
    private static final class Pair {
        final JSONObject request; final java.lang.Process wrapper; final int wrapperPid, workerPid;
        Pair(PrivateDirectory fixture, String capture) throws Exception {
            this(fixture,capture,"");
        }
        Pair(PrivateDirectory fixture, String capture,String mode) throws Exception {
            String nonce = UUID.randomUUID().toString(); int parent = android.os.Process.myPid(); String ticks = RootUploadProcess.ticks(parent);
            request = new JSONObject().put("captureId",capture).put("piece",0).put("parentPid",parent).put("parentTicks",ticks).put("attempt",nonce);
            if(!mode.isEmpty())request.put("mode",mode);
            fixture.write("test-request-" + nonce + ".json",request,true,false);
            java.util.ArrayList<String> arguments=new java.util.ArrayList<>(java.util.Arrays.asList("/system/bin/timeout","-k","5","45","/system/bin/app_process","/system/bin",
                    "cn.apt.rootaudio.RootUploadWorker",capture,"0",Integer.toString(parent),ticks,nonce));
            if(!mode.isEmpty())arguments.add(mode);
            ProcessBuilder process = new ProcessBuilder(arguments);
            process.environment().put("APT_UPLOAD_FIXTURE",fixture.canonical);
            process.redirectErrorStream(true); process.redirectOutput(fixture.file("fixture-" + nonce + ".log").toFile());
            wrapper = process.start(); wrapperPid = pid(wrapper);
            String name = "worker-" + nonce + ".json"; long until = System.currentTimeMillis()+7000;
            while (!Files.exists(fixture.file(name)) && System.currentTimeMillis()<until) Thread.sleep(20);
            workerPid = fixture.json(name).getInt("pid"); check(alive(wrapperPid) && alive(workerPid),"fixture tree starts");
        }
        void close() throws Exception { RootUploadProcess.stop(request); wrapper.waitFor(2,TimeUnit.SECONDS); }
    }
    private static void cleanup(PrivateDirectory fixture) throws Exception {
        try (DirectoryStream<Path> files = Files.newDirectoryStream(fixture.path,"test-request-*.json")) {
            for (Path path : files) RootUploadProcess.stop(fixture.json(path.getFileName().toString()));
        }
    }
    public static void main(String[] args) {
        try { run(args); System.out.flush(); System.exit(0); }
        catch (Throwable failure) { failure.printStackTrace(System.err); System.err.flush(); System.exit(1); }
    }
    private static void run(String[] args) throws Exception {
        if (args.length < 1 || !args[0].matches("/data/local/tmp/apt-upload-check\\.[0-9a-f]{32}")) throw new SecurityException("fixture path");
        try (PrivateDirectory fixture = new PrivateDirectory(args[0],0,true)) {
            if (args.length==2 && args[1].equals("cleanup")) { cleanup(fixture); System.out.println("ANDROID_UPLOAD_CLEAN"); return; }
            String capture = UUID.randomUUID().toString(), matter = UUID.randomUUID().toString(), client = UUID.randomUUID().toString();
            System.out.println("ANDROID_UPLOAD_STAGE receipts"); System.out.flush();
            try (PrivateDirectory dir = fixture.child("capture-" + capture)) {
                JSONObject source = new JSONObject().put("captureId",capture).put("matterId",matter).put("uploadClient",client)
                        .put("validation",false).put("chunkSeconds",600).put("indexBase",0);
                JSONObject piece = new JSONObject().put("captureId",capture).put("matterId",matter).put("piece",0).put("index",0)
                        .put("frames",512512).put("frameOffset",0).put("size",1025068).put("sha256",new String(new char[64]).replace('\0','a')).put("cloudEligible",true);
                dir.write("source.json",source,true,false); dir.write("chunk-0000.json",piece,true,false);
                JSONObject expected = RootUploader.base(source,piece);
                check(expected.getDouble("durationSec")==32.032,"exact tail duration");
                for (String key : new String[]{"piece","frames"}) { JSONObject bad = new JSONObject(expected.toString()).put(key,expected.getDouble(key)+0.5); check(!RootUploader.same(bad,expected),"fractional identity"); }
                check(!RootUploader.same(new JSONObject(expected.toString()).put("durationSec","NaN"),expected),"NaN receipt");
                JSONObject uploaded = new JSONObject(expected.toString()).put("state","uploaded").put("uploadedAt",System.currentTimeMillis());
                for (double badAt : new double[]{1e100,9007199254740992.0}) {
                    dir.write(RootUploader.name(0,"receipt"),new JSONObject(uploaded.toString()).put("uploadedAt",badAt),true,false);
                    check(!RootUploader.confirmed(dir,0,expected),"unsafe uploadedAt isolated");
                }
                dir.write(RootUploader.name(0,"state"),uploaded,false,false);
                check(!RootUploader.status(dir,source,piece).getString("state").equals("uploaded"),"state cannot forge success");
                dir.write(RootUploader.name(0,"receipt"),new JSONObject(uploaded.toString()).put("matterId",UUID.randomUUID().toString()),true,false);
                check(!RootUploader.confirmed(dir,0,expected),"foreign receipt retained then retried");
                check(!Files.exists(dir.file(RootUploader.name(0,"receipt"))),"invalid receipt isolated");
                dir.write(RootUploader.name(0,"receipt"),uploaded,true,false); check(RootUploader.confirmed(dir,0,expected),"exact server receipt");
                check(RootUploader.status(dir,source,piece).getString("state").equals("uploaded"),"valid receipt projected");
                JSONObject extra = new JSONObject(uploaded.toString()).put("extra",new String(new char[10000]).replace('\0','x'));
                Files.delete(dir.file(RootUploader.name(0,"receipt"))); dir.write(RootUploader.name(0,"receipt"),extra,true,false);
                check(!RootUploader.status(dir,source,piece).has("extra"),"receipt projection bounded");
                dir.write("chunk-0000.ack.json",new JSONObject().put("disposition","saved"),true,false);
                check(!RootUploader.cancelled(dir,0),"saved ACK remains eligible");
                fixture.write("forget-"+matter+".json",new JSONObject().put("matterId",matter),true,false);
                check(RootUploader.cancelled(dir,0),"later durable deletion revokes saved ACK");
                check(RootUploader.status(dir,source,piece).getString("state").equals("cancelled"),"deletion wins over uploaded state");
                Files.delete(fixture.file("forget-"+matter+".json"));
                RootUploader.status(dir,source,piece); System.gc(); System.runFinalization(); int before=fds();
                for(int i=0;i<300;i++)check(RootUploader.status(dir,source,piece).getString("state").equals("uploaded"),"receipt stable");
                int after=fds();check(before==after,"FD leak");
                System.out.println("ANDROID_UPLOAD_STAGE process-trees"); System.out.flush();
                Pair stopped=null,control=null;
                try {
                    stopped=new Pair(fixture,capture);control=new Pair(fixture,capture);
                    Os.kill(stopped.wrapperPid,OsConstants.SIGSTOP);Os.kill(stopped.workerPid,OsConstants.SIGSTOP);
                    stopped.close();check(!alive(stopped.wrapperPid) && !alive(stopped.workerPid),"both suspended timeout and worker killed");
                    check(alive(control.wrapperPid) && alive(control.workerPid),"unrelated nonce survives");
                    RootUploadProcess.stop(new JSONObject(control.request.toString()).put("attempt",UUID.randomUUID().toString()));
                    check(alive(control.workerPid),"wrong request cannot kill worker");
                    control.close();check(!alive(control.wrapperPid) && !alive(control.workerPid),"control tree cleanup");
                } finally { if(stopped!=null)stopped.close();if(control!=null)control.close();cleanup(fixture); }
                for(String mode:new String[]{"prepare","pipeline","revoke"}) {
                    Pair pipeline=new Pair(fixture,capture,mode);
                    try {
                        RootUploadProcess.stop(new JSONObject(pipeline.request.toString()).put("mode",mode.equals("pipeline")?"revoke":"pipeline"));
                        check(alive(pipeline.workerPid),"wrong mode cannot kill worker");
                        Os.kill(pipeline.wrapperPid,OsConstants.SIGSTOP);Os.kill(pipeline.workerPid,OsConstants.SIGSTOP);
                        pipeline.close();check(!alive(pipeline.wrapperPid)&&!alive(pipeline.workerPid),"metadata process tree bounded cleanup");
                    }finally{pipeline.close();}
                }
                JSONObject owner=new JSONObject().put("id",matter).put("startedAt",System.currentTimeMillis()-60000)
                        .put("endedAt",JSONObject.NULL).put("origin","record").put("title",JSONObject.NULL).put("progress",JSONObject.NULL)
                        .put("personalActionsEnabled",true).put("captureComplete",false);
                JSONObject snapshot=new JSONObject().put("matter",owner).put("segments",new org.json.JSONArray()).put("jobs",new org.json.JSONArray()).put("memory",new org.json.JSONArray());
                String namespace=UUID.randomUUID().toString(),generation=UUID.randomUUID().toString(),handoff=UUID.randomUUID().toString();
                JSONObject auth=new JSONObject().put("namespace",namespace).put("generation",generation).put("handoffId",handoff)
                        .put("claim",new JSONObject().put("device_id",namespace).put("recording_id",matter).put("generation",generation).put("handoff_id",handoff).put("snapshot",snapshot));
                JSONObject authorized=RootPipeline.authorization(auth,matter);check(authorized.getJSONObject("claim").getBoolean("transport"),"native only requests bounded ownership receipt");
                for(String key:new String[]{"namespace","generation","handoffId"}) {
                    try{RootPipeline.authorization(new JSONObject(auth.toString()).put(key,UUID.randomUUID().toString()),matter);throw new AssertionError("foreign background identity");}
                    catch(SecurityException refused){checks++;}
                }
                JSONObject backgroundSource=new JSONObject(source.toString()).put("background",authorized);
                dir.write("progress.json",new JSONObject().put("startedAt",owner.getLong("startedAt")).put("frames",512512),true,false);
                check(!RootPipeline.capture(dir,backgroundSource).getBoolean("closed"),"progress is not a closed capture");
                dir.write("result.json",new JSONObject().put("state","stopped").put("frames",512512),true,false);
                JSONObject closed=RootPipeline.capture(dir,backgroundSource);check(closed.getBoolean("closed")&&!closed.getBoolean("finish"),"pause preserves incomplete recording boundary");
                dir.write("stop-intent.json",new JSONObject().put("finish",true).put("endedAt",System.currentTimeMillis()),true,false);
                JSONObject finished=RootPipeline.capture(dir,backgroundSource);check(finished.getBoolean("finish")&&finished.getLong("frames")==512512,"final tail facts independent of App receipt");
                dir.write("pipeline-capture.receipt.json",new JSONObject().put("generation",generation).put("capture",finished),true,false);
                check(RootPipeline.captureConfirmed(dir,backgroundSource),"capture receipt matches all close facts");
                check(!RootPipeline.captureConfirmed(dir,new JSONObject(backgroundSource.toString()).put("background",new JSONObject(authorized.toString()).put("generation",UUID.randomUUID().toString()))),"old generation capture receipt rejected");
                // The synthetic App has no connection credentials; the real scanner may only mark waiting.
                RootApp app = new RootApp(args[0]);
                try (PrivateDirectory prefs = fixture.child("shared_prefs"); PrivateDirectory files = fixture.child("files");
                     PrivateDirectory media = files.child("media")) {
                    String pref = "aiapp_store_" + RootApp.PACKAGE + ".xml";
                    String key = "growth.root.capture.deleted." + matter;
                    Path xml = prefs.file(pref);
                    Files.write(xml,("<map><string name=\"growth.stepx.gate\">&quot;test-gate-123456789&quot;</string><string name=\""+key+"\">deleted</string></map>").getBytes(StandardCharsets.UTF_8));
                    Os.chmod(xml.toString(),0600);
                    check(RootUploadCredential.read(app).equals("test-gate-123456789"),"existing wrapped gate decoded");
                    check(RootUploadCredential.deleted(app,matter),"UUID revocation read");
                    check(!RootUploadCredential.deleted(app,UUID.randomUUID().toString()),"unrelated revocation denied");
                    Files.write(xml,"<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///does-not-exist'>]><map/>".getBytes(StandardCharsets.UTF_8));
                    try { RootUploadCredential.read(app); throw new AssertionError("DTD accepted"); } catch (SecurityException refused) { checks++; }
                    Files.write(xml,"<map/>".getBytes(StandardCharsets.UTF_8));
                    RootUploader uploader = new RootUploader(app,fixture.canonical);
                    try (PrivateDirectory broken = fixture.child("capture-00000000-0000-4000-8000-000000000000");
                         PrivateDirectory healthy = fixture.child("capture-ffffffff-ffff-4fff-8fff-ffffffffffff")) {
                        JSONObject nextSource = new JSONObject(source.toString()).put("captureId","ffffffff-ffff-4fff-8fff-ffffffffffff");
                        JSONObject nextPiece = new JSONObject(piece.toString()).put("captureId",nextSource.getString("captureId"));
                        healthy.write("source.json",nextSource,true,false);
                        Files.write(healthy.file("chunk-0000.json"),"{broken".getBytes(StandardCharsets.UTF_8));
                        nextPiece.put("piece",1).put("index",1).put("frameOffset",9600000);
                        healthy.write("chunk-0001.json",nextPiece,true,false);
                        java.lang.reflect.Method scan = RootUploader.class.getDeclaredMethod("scan"); scan.setAccessible(true); scan.invoke(uploader);
                        check(healthy.json(RootUploader.name(1,"state")).getString("state").equals("waiting-connection"),"broken capture/piece cannot starve healthy piece");
                    }
                }
                System.out.println("ANDROID_UPLOAD_OK checks="+checks+" before="+before+" after="+after+" delta="+(after-before)+" processTrees=5 microphoneOpened=false networkRequests=0");
            }
        }
    }
}
