package cn.apt.rootaudio;

import android.media.MediaExtractor;
import android.media.MediaFormat;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.io.RandomAccessFile;
import org.json.JSONObject;

/** Isolated closed-file encoder: no microphone, App data, network or service deployment. */
public final class AacChunkAndroidTest {
    private static void check(boolean value, String label) { if (!value) throw new AssertionError(label); }
    private static JSONObject source() throws Exception {
        return new JSONObject().put("captureId","00000000-0000-4000-8000-000000000001")
                .put("matterId","00000000-0000-4000-8000-000000000002").put("indexBase",0)
                .put("uploadClient","00000000-0000-4000-8000-000000000003")
                .put("audioFormat","m4a").put("chunkSeconds",600).put("limitSeconds",43200).put("validation",false);
    }
    private static void receipt(PrivateDirectory dir, int index, long frames) throws Exception {
        JSONObject source = source();
        dir.write(RootPcmCompression.name(index,"pcm"),new JSONObject().put("captureId",source.getString("captureId"))
                .put("matterId",source.getString("matterId")).put("index",index).put("piece",index)
                .put("frames",frames).put("frameOffset",index * 600 * 16000L).put("capturedAt",1)
                .put("cloudEligible",true).put("size",44 + frames * 2)
                .put("sha256",RootPcmCompression.hash(dir.file(String.format("chunk-%04d.wav",index)))),true,false);
    }
    public static void main(String[] args) throws Exception {
        try { run(args); } catch (Throwable failure) { failure.printStackTrace(System.out); System.exit(1); }
    }
    private static void run(String[] args) throws Exception {
        Path directory = Paths.get(args[0]); long encodeMs, frames;
        try (PrivateDirectory dir = new PrivateDirectory(directory.toString(),0,true)) {
            try (RandomAccessFile input = new RandomAccessFile(directory.resolve("input.wav").toFile(),"r");
                 WavChunk pcm = new WavChunk(dir.path,0)) {
                frames = (input.length() - 44) / 2; input.seek(44);
                byte[] raw = new byte[2048]; short[] samples = new short[1024];
                for (int n; (n = input.read(raw)) > 0;) {
                    for (int i = 0; i < n / 2; i++) samples[i] = (short)((raw[i * 2] & 255) | (raw[i * 2 + 1] << 8));
                    pcm.append(samples,0,n / 2);
                }
                pcm.commit(); receipt(dir,0,frames);
            }
            check(RootController.savedFrames(dir,source()) == frames,"restart counts complete PCM before preparation");
            check(RootController.nextIndex(dir,source()) == 1,"unpublished PCM reserves its index");
            dir.write("result.json",new JSONObject().put("state","failed").put("frames",0),true,false);
            check(RootController.nextIndex(dir,source()) == 1,"stale failed result cannot reuse durable PCM index");
            RootController.repairFailedFrames(dir,source());
            check(dir.json("result.json").getLong("frames") == frames,"failed result publishes all completed PCM frames");
            RootPcmCompression.prepare(dir,source(),0);
            JSONObject speech = dir.json("chunk-0000.json");
            check("m4a".equals(speech.getString("audioFormat")),"actual speech AAC");
            check(Files.exists(directory.resolve("chunk-0000.wav")),"PCM preserved before ACK and upload");
            String immutable = speech.toString(); RootPcmCompression.prepare(dir,source(),0);
            check(immutable.equals(dir.json("chunk-0000.json").toString()),"format identity immutable on replay");
            MediaExtractor media = new MediaExtractor();
            try {
                media.setDataSource(directory.resolve("chunk-0000.m4a").toString());
                check(media.getTrackCount() == 1,"single track"); MediaFormat format = media.getTrackFormat(0);
                check("audio/mp4a-latm".equals(format.getString(MediaFormat.KEY_MIME)),"AAC codec");
                check(format.getInteger(MediaFormat.KEY_SAMPLE_RATE) == 16000 && format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) == 1,"16k mono");
            } finally { media.release(); }
            try (WavChunk pcm = new WavChunk(dir.path,1)) {
                short[] samples = new short[1024]; long frame = 0, target = 600 * 16000L;
                while (frame < target) {
                    int n = (int)Math.min(samples.length,target - frame);
                    for (int i = 0; i < n; i++) samples[i] = (short)(9000 * Math.sin((frame + i) * 2 * Math.PI * 317 / 16000));
                    pcm.append(samples,0,n); frame += n;
                }
                pcm.commit(); receipt(dir,1,target);
            }
            long at = android.os.SystemClock.elapsedRealtime(); RootPcmCompression.prepare(dir,source(),1);
            encodeMs = android.os.SystemClock.elapsedRealtime() - at;
            check("m4a".equals(dir.json("chunk-0001.json").getString("audioFormat")),"600 seconds AAC");
            // A previously interrupted encoder cannot overwrite a completed format or lose PCM.
            Files.createFile(directory.resolve("chunk-0002.pending.m4a"));
            try (WavChunk pcm = new WavChunk(dir.path,2)) { pcm.append(new short[16000],0,16000); pcm.commit(); receipt(dir,2,16000); }
            RootPcmCompression.prepare(dir,source(),2);
            check("wav".equals(dir.json("chunk-0002.json").getString("audioFormat")),"failed codec fallback");
            try (WavChunk pcm = new WavChunk(dir.path,3)) { pcm.append(new short[]{123},0,1); pcm.commit(); receipt(dir,3,1); }
            RootPcmCompression.prepare(dir,source(),3);
            check("wav".equals(dir.json("chunk-0003.json").getString("audioFormat")),"one-frame tail safe fallback");
            // The native AAC original remains available while the WebView is asleep.
            JSONObject expected = RootUploader.base(source(),speech);
            RootPcmCompression.releaseRecovery(dir,source(),speech,expected);
            check(Files.exists(directory.resolve("chunk-0000.wav")),"no receipt no release");
            dir.write(RootUploader.name(0,"receipt"),new JSONObject(expected.toString()).put("state","uploaded").put("uploadedAt",System.currentTimeMillis()),true,false);
            RootPcmCompression.releaseRecovery(dir,source(),new JSONObject(speech.toString()).put("decodedVerified",false),expected);
            check(Files.exists(directory.resolve("chunk-0000.wav")),"no complete decode no release");
            JSONObject background = new JSONObject().put("namespace","00000000-0000-4000-8000-000000000004")
                    .put("generation","00000000-0000-4000-8000-000000000005");
            JSONObject backgroundSource = source().put("background",background);
            RootPcmCompression.releaseRecovery(dir,backgroundSource,speech,expected);
            check(Files.exists(directory.resolve("chunk-0000.wav")),"no background handoff no release");
            for (String key : new String[]{"sha256","pcmSha256"}) {
                boolean refused = false;
                try { RootPcmCompression.releaseRecovery(dir,source(),new JSONObject(speech.toString()).put(key,new String(new char[64]).replace('\0','f')),expected); }
                catch (SecurityException changed) { refused = true; }
                check(refused && Files.exists(directory.resolve("chunk-0000.wav")),"changed recovery identity retains PCM");
            }
            dir.write("pipeline-0000.receipt.json",new JSONObject().put("generation",background.getString("generation"))
                    .put("device_id",background.getString("namespace")).put("recording_id",source().getString("matterId"))
                    .put("capture_id",source().getString("captureId")).put("piece",0).put("frames",speech.getLong("frames"))
                    .put("sha256",speech.getString("sha256")).put("key",expected.getString("key")),true,false);
            RootPcmCompression.releaseRecovery(dir,backgroundSource,speech,expected);
            check(!Files.exists(directory.resolve("chunk-0000.wav")) && Files.exists(directory.resolve("chunk-0000.m4a")),"release only temporary PCM; retain verified native AAC before App ACK");
            dir.write("chunk-0000.ack.json",new JSONObject().put("disposition","saved").put("sha256",speech.getString("sha256")),true,false);
            RootPcmCompression.releaseRecovery(dir,source(),speech,expected);
            check(Files.exists(directory.resolve("chunk-0000.m4a")),"saved ACK retains native AAC original");
            check(Files.exists(directory.resolve("chunk-0002.wav")),"fallback PCM retained");
            System.out.println("AAC_TEST_OK " + new JSONObject().put("speechBytes",Files.size(directory.resolve("chunk-0000.m4a")))
                    .put("wavBytes",Files.size(directory.resolve("input.wav"))).put("tenMinuteBytes",Files.size(directory.resolve("chunk-0001.m4a")))
                    .put("tenMinuteEncodeMs",encodeMs).put("microphoneOpened",false).put("appDataRead",false).put("networkRequests",0));
        }
    }
}
