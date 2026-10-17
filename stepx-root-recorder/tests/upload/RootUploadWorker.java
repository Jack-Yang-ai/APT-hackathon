package cn.apt.rootaudio;

/** Only compiled into the isolated Android check JAR. No network or App access. */
public final class RootUploadWorker {
    public static void main(String[] args) throws Exception {
        if (args.length != 5 && args.length != 6) throw new IllegalArgumentException("fixture arguments");
        String fixture = System.getenv("APT_UPLOAD_FIXTURE");
        if (fixture == null || !fixture.matches("/data/local/tmp/apt-upload-check\\.[0-9a-f]{32}")) throw new SecurityException("fixture directory");
        try (PrivateDirectory root = new PrivateDirectory(fixture,0,true)) {
            root.write("worker-" + RootUploadIdentity.uuid(args[4]) + ".json",new org.json.JSONObject()
                    .put("pid",android.os.Process.myPid()).put("ticks",RootUploadProcess.ticks(android.os.Process.myPid())),true,false);
        }
        Thread.sleep(40000);
        System.exit(0);
    }
    static void allowed(RootApp app,PrivateDirectory dir,int index,String credential,int pid,String ticks,String nonce) {
        throw new SecurityException("isolated fixture cannot open a network connection");
    }
}
