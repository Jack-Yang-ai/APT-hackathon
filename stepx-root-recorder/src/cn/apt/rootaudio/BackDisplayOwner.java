package cn.apt.rootaudio;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Parses only vendor ownership flags, including its five-second settings debounce. */
final class BackDisplayOwner {
    final boolean custom, applied; final int uid;
    private BackDisplayOwner(boolean custom, int uid, boolean applied) { this.custom = custom; this.uid = uid; this.applied = applied; }
    static BackDisplayOwner parse(String text) {
        String candidate = null;
        for (String line : text.split("\\n")) if (line.trim().startsWith("appUsesCustomFrame=")) {
            if (candidate != null) throw new IllegalStateException("display-owner-ambiguous");
            candidate = line.trim();
        }
        if (candidate == null) throw new IllegalStateException("display-owner-unavailable");
        Matcher match = Pattern.compile("appUsesCustomFrame=(true|false) appFrameOwner=(none|uid=([0-9]+))(?: settingsPending)? appliedCustomFrame=(true|false)").matcher(candidate);
        if (!match.matches()) throw new IllegalStateException("display-owner-unverified");
        boolean custom = Boolean.parseBoolean(match.group(1)), applied = Boolean.parseBoolean(match.group(4));
        int uid = match.group(3) == null ? -1 : Integer.parseInt(match.group(3));
        if (custom != (uid >= 0)) throw new IllegalStateException("display-owner-unverified");
        return new BackDisplayOwner(custom, uid, applied);
    }
}
