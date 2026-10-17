package cn.apt.rootaudio;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Locale;

/** Identical namespace and root-piece identity to the existing App upload queue. */
final class RootUploadIdentity {
    static String uuid(String value) {
        if (value == null || !value.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))
            throw new IllegalArgumentException("upload identity");
        return value;
    }
    static String piece(String capture, int index) throws Exception {
        uuid(capture);
        if (index < 0 || index > 8640) throw new IllegalArgumentException("upload piece");
        StringBuilder hash = new StringBuilder();
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(("root:" + capture + ":" + index).getBytes(StandardCharsets.UTF_8));
        for (byte b : digest) hash.append(String.format(Locale.ROOT, "%02x", b & 255));
        String h = hash.toString();
        return h.substring(0,8) + "-" + h.substring(8,12) + "-" + h.substring(12,16) + "-" + h.substring(16,20) + "-" + h.substring(20,32);
    }
    static String key(String client, String matter, String capture, int index, String sha) throws Exception {
        return key(client, matter, capture, index, sha, "wav");
    }
    static String key(String client, String matter, String capture, int index, String sha, String format) throws Exception {
        if (sha == null || !sha.matches("[0-9a-f]{64}")) throw new IllegalArgumentException("upload hash");
        if (!"wav".equals(format) && !"m4a".equals(format)) throw new IllegalArgumentException("upload format");
        return "stepx/" + uuid(client) + "/" + uuid(matter) + "/" + piece(capture, index) + "-" + sha + "." + format;
    }
}
