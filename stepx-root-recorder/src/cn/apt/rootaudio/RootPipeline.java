package cn.apt.rootaudio;

import android.os.PowerManager;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Locale;
import javax.net.ssl.HttpsURLConnection;
import org.json.JSONObject;

/** Only authenticated metadata delivery. The durable server owns ASR and model scheduling. */
final class RootPipeline {
    private RootPipeline() {}
    private static String pieceReceipt(int index) { return String.format(Locale.ROOT,"pipeline-%04d.receipt.json",index); }
    static boolean enabled(JSONObject source) { return source.has("background")&&!source.optBoolean("validation",true)&&source.has("uploadClient"); }
    static JSONObject authorization(JSONObject given,String matter) throws Exception {
        JSONObject auth=new JSONObject().put("namespace",RootMailbox.uuid(given,"namespace"))
                .put("generation",RootMailbox.uuid(given,"generation")).put("handoffId",RootMailbox.uuid(given,"handoffId"));
        if(given.has("claim")) {
            JSONObject claim=given.getJSONObject("claim"),snapshot=claim.getJSONObject("snapshot"),owner=snapshot.getJSONObject("matter");
            if(!auth.getString("namespace").equals(RootMailbox.uuid(claim,"device_id"))
                    ||!auth.getString("generation").equals(RootMailbox.uuid(claim,"generation"))
                    ||!auth.getString("handoffId").equals(RootMailbox.uuid(claim,"handoff_id"))
                    ||!matter.equals(RootMailbox.uuid(claim,"recording_id"))||!matter.equals(RootMailbox.uuid(owner,"id"))
                    ||snapshot.getJSONArray("segments").length()!=0||snapshot.getJSONArray("jobs").length()!=0||snapshot.getJSONArray("memory").length()!=0
                    ||owner.getLong("startedAt")<1||owner.getLong("startedAt")>System.currentTimeMillis()+5000
                    ||!owner.isNull("endedAt")||owner.optBoolean("recordingTimeUnverified",false))throw new SecurityException("background initial claim");
            if(claim.toString().getBytes(StandardCharsets.UTF_8).length>8192)throw new SecurityException("background claim size");
            auth.put("claim",new JSONObject(claim.toString()).put("transport",true));
        }
        return auth;
    }
    private static JSONObject envelope(JSONObject source) throws Exception {
        JSONObject auth=source.getJSONObject("background");
        return new JSONObject().put("device_id",RootMailbox.uuid(auth,"namespace"))
                .put("generation",RootMailbox.uuid(auth,"generation")).put("recording_id",RootMailbox.uuid(source,"matterId"));
    }
    static JSONObject capture(PrivateDirectory dir,JSONObject source) throws Exception {
        JSONObject progress=dir.json("progress.json");long started=progress.getLong("startedAt");
        JSONObject value=new JSONObject().put("capture_id",source.getString("captureId")).put("index_base",source.getInt("indexBase"))
                .put("started_at",started).put("chunk_frames",source.getInt("chunkSeconds")*16000L).put("frames",0).put("closed",false).put("finish",false);
        if(Files.exists(dir.file("result.json"))) {
            JSONObject result=dir.json("result.json");
            if(!"stopped".equals(result.optString("state")))return value;
            value.put("frames",result.getLong("frames")).put("closed",true);
            if(Files.exists(dir.file("stop-intent.json"))) {
                JSONObject stop=dir.json("stop-intent.json");
                if(stop.getBoolean("finish"))value.put("finish",true).put("ended_at",stop.getLong("endedAt"));
            }
        }
        return value;
    }
    private static boolean equal(JSONObject a,JSONObject b,String[] fields) throws Exception {
        for(String key:fields)if(!String.valueOf(a.get(key)).equals(String.valueOf(b.get(key))))return false;return true;
    }
    static boolean captureConfirmed(PrivateDirectory dir,JSONObject source) throws Exception {
        if(!enabled(source))return true;
        if(!Files.exists(dir.file("progress.json")))return false;
        JSONObject expected=capture(dir,source);
        if(!Files.exists(dir.file("pipeline-capture.receipt.json")))return false;
        JSONObject receipt=dir.json("pipeline-capture.receipt.json");
        return source.getJSONObject("background").getString("generation").equals(receipt.optString("generation"))
                &&equal(receipt.getJSONObject("capture"),expected,new String[]{"capture_id","index_base","started_at","chunk_frames","frames","closed","finish"})
                &&(!expected.getBoolean("finish")||receipt.getJSONObject("capture").getLong("ended_at")==expected.getLong("ended_at"));
    }
    static boolean confirmed(PrivateDirectory dir,JSONObject source,int index) throws Exception {
        if(!enabled(source))return true;
        if(!Files.exists(dir.file(pieceReceipt(index))))return false;
        JSONObject piece=dir.json(String.format(Locale.ROOT,"chunk-%04d.json",index)),receipt=dir.json(pieceReceipt(index));
        return source.getJSONObject("background").getString("generation").equals(receipt.optString("generation"))
                &&equal(receipt,piece,new String[]{"sha256","frames"})&&receipt.getInt("piece")==index
                &&receipt.getString("capture_id").equals(source.getString("captureId"))
                &&receipt.getString("recording_id").equals(source.getString("matterId"))
                &&receipt.getString("device_id").equals(source.getJSONObject("background").getString("namespace"))
                &&receipt.getString("key").equals(RootUploader.base(source,piece).getString("key"));
    }
    private static JSONObject post(RootApp app,PrivateDirectory dir,int index,String credential,int pid,String ticks,String nonce,String route,JSONObject body) throws Exception {
        RootUploadWorker.allowed(app,dir,index,credential,pid,ticks,nonce);
        byte[] payload=body.toString().getBytes(StandardCharsets.UTF_8);if(payload.length>16384)throw new SecurityException("pipeline request size");
        HttpsURLConnection connection=(HttpsURLConnection)new URL("https://apt-backend.example/stepx/background/"+route).openConnection();
        connection.setInstanceFollowRedirects(false);connection.setConnectTimeout(10000);connection.setReadTimeout(15000);
        connection.setRequestMethod("POST");connection.setDoOutput(true);connection.setFixedLengthStreamingMode(payload.length);
        connection.setRequestProperty("Content-Type","application/json");connection.setRequestProperty("X-Growth-Token",credential);
        try {
            try(OutputStream output=connection.getOutputStream()){RootUploadWorker.allowed(app,dir,index,credential,pid,ticks,nonce);output.write(payload);}
            if(connection.getResponseCode()!=200)throw new IllegalStateException("pipeline response");
            ByteArrayOutputStream bytes=new ByteArrayOutputStream();byte[] buffer=new byte[4096];
            try(InputStream input=connection.getInputStream()) {for(int n;(n=input.read(buffer))!=-1;){if(bytes.size()+n>16384)throw new SecurityException("pipeline response size");bytes.write(buffer,0,n);}}
            RootUploadWorker.allowed(app,dir,index,credential,pid,ticks,nonce);
            return new JSONObject(new String(bytes.toByteArray(),StandardCharsets.UTF_8));
        }finally{connection.disconnect();}
    }
    static boolean revocationConfirmed(PrivateDirectory dir,JSONObject source) throws Exception {
        if(!Files.exists(dir.file("pipeline-revoked.receipt.json")))return false;
        JSONObject receipt=dir.json("pipeline-revoked.receipt.json"),auth=source.getJSONObject("background");
        return "revoked".equals(receipt.optString("phase"))&&auth.getString("generation").equals(receipt.optString("generation"))
                &&source.getString("matterId").equals(receipt.optString("recording_id"))&&auth.getString("namespace").equals(receipt.optString("device_id"));
    }
    static void deliver(RootApp app,String capture,int index,int pid,String ticks,String nonce,boolean revoke) throws Exception {
        try(PrivateDirectory dir=new PrivateDirectory(app.data+"/files/apt-root-recorder/capture-"+capture,0,true)) {
            JSONObject source=dir.json("source.json");if(!enabled(source))throw new SecurityException("pipeline not authorized");
            if(!(revoke?"revoke":"pipeline").equals(dir.json(RootUploader.name(index,"request")).optString("mode")))throw new SecurityException("pipeline request mode");
            String credential=RootUploadCredential.read(app);if(credential==null)throw new SecurityException("pipeline disconnected");
            RootUploadWorker.allowed(app,dir,index,credential,pid,ticks,nonce);
            PowerManager.WakeLock wake=((PowerManager)app.context.getSystemService(android.content.Context.POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"APT:RootPipeline");
            wake.acquire(100000);
            try {
                JSONObject auth=source.getJSONObject("background");
                if(auth.has("claim")) {
                    JSONObject receipt=post(app,dir,index,credential,pid,ticks,nonce,"claim",auth.getJSONObject("claim"));
                    if(!auth.getString("generation").equals(receipt.getString("generation"))
                            ||!("active".equals(receipt.getString("phase"))||revoke&&"revoked".equals(receipt.getString("phase"))))throw new SecurityException("pipeline claim receipt");
                }
                if(revoke) {
                    if(!Files.exists(dir.file("pipeline-revocation.json")))dir.write("pipeline-revocation.json",new JSONObject().put("id",java.util.UUID.randomUUID().toString()),true,false);
                    JSONObject receipt=post(app,dir,index,credential,pid,ticks,nonce,"revoke",envelope(source)
                            .put("mutation_id",RootMailbox.uuid(dir.json("pipeline-revocation.json"),"id")));
                    if(!"revoked".equals(receipt.optString("phase"))||!auth.getString("generation").equals(receipt.optString("generation"))
                            ||!source.getString("matterId").equals(receipt.optString("recording_id"))||!auth.getString("namespace").equals(receipt.optString("device_id")))throw new SecurityException("pipeline revocation receipt");
                    dir.write("pipeline-revoked.receipt.json",receipt,false,false);return;
                }
                if(!captureConfirmed(dir,source)) {
                    JSONObject facts=capture(dir,source),body=envelope(source).put("capture",facts);
                    JSONObject receipt=post(app,dir,index,credential,pid,ticks,nonce,"capture",body);
                    if(!equal(receipt,facts,new String[]{"capture_id","frames","closed","finish"}))throw new SecurityException("pipeline capture receipt");
                    dir.write("pipeline-capture.receipt.json",new JSONObject().put("generation",auth.getString("generation")).put("capture",facts),false,false);
                }
                String pieceName=String.format(Locale.ROOT,"chunk-%04d.json",index);
                if(Files.exists(dir.file(pieceName))&&!confirmed(dir,source,index)) {
                    JSONObject piece=dir.json(pieceName),uploaded=RootUploader.base(source,piece);
                    if(!RootUploader.confirmed(dir,index,uploaded))throw new SecurityException("pipeline upload receipt missing");
                    JSONObject value=new JSONObject().put("capture_id",capture).put("piece",index).put("index_base",source.getInt("indexBase"))
                            .put("frames",piece.getLong("frames")).put("frame_offset",piece.getLong("frameOffset")).put("captured_at",piece.getLong("capturedAt"))
                            .put("sha256",piece.getString("sha256")).put("key",uploaded.getString("key")).put("upload_client",source.getString("uploadClient"));
                    JSONObject receipt=post(app,dir,index,credential,pid,ticks,nonce,"piece",envelope(source).put("piece",value));
                    if(!equal(receipt,value,new String[]{"capture_id","piece","frames","sha256","key"})
                            ||!auth.getString("generation").equals(receipt.getString("generation"))
                            ||!source.getString("matterId").equals(receipt.getString("recording_id"))
                            ||!auth.getString("namespace").equals(receipt.getString("device_id")))throw new SecurityException("pipeline piece receipt");
                    dir.write(pieceReceipt(index),receipt,false,false);
                }
            }finally{if(wake.isHeld())wake.release();}
        }
    }
}
