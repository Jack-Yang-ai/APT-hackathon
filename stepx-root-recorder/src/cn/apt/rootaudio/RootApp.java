package cn.apt.rootaudio;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.system.Os;
import java.security.MessageDigest;
import java.util.Locale;

/** One user, one package, one installed signer. No caller-supplied package or paths. */
final class RootApp {
    static final String PACKAGE = "com.stepx.aiapp.publicapt";
    static final String SIGNER = "CONFIGURE_YOUR_SIGNER_SHA256";
    final Context context;
    final int uid;
    final String data;
    private final long inode;
    RootApp(Context context) throws Exception {
        this.context = context;
        PackageInfo info = context.getPackageManager().getPackageInfo(PACKAGE, PackageManager.GET_SIGNING_CERTIFICATES);
        ApplicationInfo app = info.applicationInfo;
        uid = app.uid; data = new java.io.File(app.dataDir).getCanonicalPath();
        if (uid < 10000 || uid >= 100000 || info.signingInfo == null || info.signingInfo.hasMultipleSigners())
            throw new SecurityException("install identity");
        Signature[] signers = info.signingInfo.getApkContentsSigners();
        if (signers.length != 1 || !SIGNER.equals(hash(signers[0].toByteArray()))) throw new SecurityException("signer");
        String[] packages = context.getPackageManager().getPackagesForUid(uid);
        if (packages == null || packages.length != 1 || !PACKAGE.equals(packages[0])) throw new SecurityException("shared uid");
        inode = Os.lstat(data).st_ino;
        check(false);
    }
    void check(boolean capturing) throws Exception {
        ApplicationInfo app = context.getPackageManager().getApplicationInfo(PACKAGE, 0);
        if (app.uid != uid || !app.enabled || !new java.io.File(app.dataDir).getCanonicalPath().equals(data)
                || Os.lstat(data).st_ino != inode || Os.lstat(data).st_uid != uid)
            throw new SecurityException("app changed");
        if (capturing && ((app.flags & ApplicationInfo.FLAG_STOPPED) != 0
                || context.getPackageManager().checkPermission("android.permission.RECORD_AUDIO", PACKAGE)
                    != PackageManager.PERMISSION_GRANTED)) throw new SecurityException("app stopped or permission revoked");
        PackageInfo info = context.getPackageManager().getPackageInfo(PACKAGE, PackageManager.GET_SIGNING_CERTIFICATES);
        Signature[] signers = info.signingInfo.getApkContentsSigners();
        if (signers.length != 1 || !SIGNER.equals(hash(signers[0].toByteArray()))) throw new SecurityException("signer changed");
    }
    static String hash(byte[] bytes) throws Exception {
        StringBuilder result = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(bytes)) result.append(String.format(Locale.ROOT, "%02x", b & 255));
        return result.toString();
    }
}
