package cn.apt.rootaudio;

/** Only the synthetic Android upload fixture uses this identity; production always compiles src/RootApp. */
final class RootApp {
    static final String PACKAGE = "com.stepx.aiapp.publicapt";
    final android.content.Context context = null;
    final int uid = 0;
    final String data;
    RootApp(android.content.Context unused) { throw new SecurityException("fixture only"); }
    RootApp(String path) {
        if (!path.matches("/data/local/tmp/apt-upload-check\\.[0-9a-f]{32}")) throw new SecurityException("fixture identity");
        data = path;
    }
    void check(boolean unused) { }
    static String hash(byte[] bytes) throws Exception {
        StringBuilder result = new StringBuilder();
        for (byte b : java.security.MessageDigest.getInstance("SHA-256").digest(bytes))
            result.append(String.format(java.util.Locale.ROOT,"%02x",b & 255));
        return result.toString();
    }
}
