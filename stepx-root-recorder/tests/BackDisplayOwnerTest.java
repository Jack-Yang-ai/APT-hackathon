package cn.apt.rootaudio;

public final class BackDisplayOwnerTest {
    private static int checks;
    private static void check(boolean value) { if (!value) throw new AssertionError("check " + checks); checks++; }
    public static void main(String[] args) {
        for (String pending : new String[] { "", " settingsPending" }) {
            BackDisplayOwner off = BackDisplayOwner.parse("Manager\n  appUsesCustomFrame=false appFrameOwner=none" + pending + " appliedCustomFrame=false\n");
            check(!off.custom && off.uid == -1 && !off.applied);
            for (String applied : new String[] { "true", "false" }) {
                BackDisplayOwner on = BackDisplayOwner.parse("  appUsesCustomFrame=true appFrameOwner=uid=0" + pending + " appliedCustomFrame=" + applied);
                check(on.custom && on.uid == 0 && on.applied == applied.equals("true"));
            }
        }
        BackDisplayOwner other = BackDisplayOwner.parse("  appUsesCustomFrame=true appFrameOwner=uid=10132 appliedCustomFrame=true");
        check(other.uid == 10132);
        for (String invalid : new String[] { "", "appUsesCustomFrame=true appFrameOwner=none appliedCustomFrame=true",
                "appUsesCustomFrame=false appFrameOwner=uid=0 appliedCustomFrame=false", "appUsesCustomFrame=true appFrameOwner=unknown appliedCustomFrame=true",
                "appUsesCustomFrame=true appFrameOwner=uid=-1 appliedCustomFrame=true", "appUsesCustomFrame=TRUE appFrameOwner=uid=0 appliedCustomFrame=true",
                "appUsesCustomFrame=false appFrameOwner=none appliedCustomFrame=false\nappUsesCustomFrame=true appFrameOwner=uid=0 appliedCustomFrame=true",
                "appUsesCustomFrame=false appFrameOwner=none appliedCustomFrame=false\nappUsesCustomFrame=true appFrameOwner=unknown appliedCustomFrame=true",
                "appUsesCustomFrame=false appFrameOwner=none appliedCustomFrame=false\nappUsesCustomFrame=false appFrameOwner=none newFlag=true appliedCustomFrame=false" }) {
            try { BackDisplayOwner.parse(invalid); throw new AssertionError("unverified owner accepted"); }
            catch (IllegalStateException expected) { checks++; }
        }
        System.out.println("BackDisplayOwnerTest checks=" + checks);
    }
}
