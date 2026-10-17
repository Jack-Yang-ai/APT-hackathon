package cn.apt.rootaudio;

/** Recording microphone and elapsed minutes only, per the user's display contract. */
public final class BackGlyph {
    private static final String[] MIC = {"0011100","0111110","0111110","0111110","0111110","0011100","1000001","0100010","0011100","0001000","0011100"};
    public static int[] pattern(String kind, long minutes) {
        int[] pixels = new int[391];
        if (!"mic".equals(kind) || minutes < 0 || minutes > 720) throw new IllegalArgumentException("glyph");
        String[] shape = MIC;
        int x = (17 - shape[0].length()) / 2, y = 2;
        for (int row = 0; row < shape.length; row++) for (int column = 0; column < shape[row].length(); column++)
            if (shape[row].charAt(column) == '1') pixels[(row + y) * 17 + column + x] = 255;
        digits(pixels, Long.toString(minutes));
        return pixels;
    }
    private static void digits(int[] pixels, String text) {
        String[] numbers = {"111101101101111","010110010010111","111001111100111","111001111001111","101101111001001",
                "111100111001111","111100111101111","111001001001001","111101111101111","111101111001111"};
        int left = (17 - (text.length() * 4 - 1)) / 2;
        for (int digit = 0; digit < text.length(); digit++) for (int row = 0; row < 5; row++) for (int col = 0; col < 3; col++)
            if (numbers[text.charAt(digit) - '0'].charAt(row * 3 + col) == '1') pixels[(17 + row) * 17 + left + digit * 4 + col] = 255;
    }
}
