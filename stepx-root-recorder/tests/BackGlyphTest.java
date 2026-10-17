package cn.apt.rootaudio;
import java.util.Arrays;

/** Entire valid minute range, pixel bounds and a few legible reference positions. */
public final class BackGlyphTest {
    private static int checks;
    private static void check(boolean value) { if (!value) throw new AssertionError("check " + checks); checks++; }
    public static void main(String[] args) {
        for (String kind : new String[] { "mic" }) for (int minutes = 0; minutes <= 720; minutes++) {
            int[] frame = BackGlyph.pattern(kind, minutes); check(frame.length == 17 * 23);
            int count = 0;
            for (int pixel : frame) { if (pixel != 0 && pixel != 255) throw new AssertionError("not monochrome"); if (pixel > 0) count++; }
            check(count > 0 && count < 150);
            for (int x = 0; x < 17; x++) check(frame[x] == 0 && frame[22 * 17 + x] == 0);
        }
        check(BackGlyph.pattern("mic", 0)[2 * 17 + 7] == 255);
        check(!Arrays.equals(BackGlyph.pattern("mic", 0), BackGlyph.pattern("mic", 1)));
        check(!Arrays.equals(BackGlyph.pattern("mic", 9), BackGlyph.pattern("mic", 10)));
        // 2026-10-15: the user explicitly removed every non-recording pattern.
        for (String kind : new String[] { null, "apt", "done", "path", "../frame" }) {
            try { BackGlyph.pattern(kind, 0); throw new AssertionError("invalid glyph accepted"); } catch (IllegalArgumentException expected) { checks++; }
        }
        for (long minutes : new long[] { -1, 721, Long.MAX_VALUE }) {
            try { BackGlyph.pattern("mic", minutes); throw new AssertionError("invalid minutes accepted"); } catch (IllegalArgumentException expected) { checks++; }
        }
        System.out.println("BackGlyphTest checks=" + checks);
    }
}
