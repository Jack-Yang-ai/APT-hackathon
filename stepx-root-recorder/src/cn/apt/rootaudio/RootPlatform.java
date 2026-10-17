package cn.apt.rootaudio;

import android.content.Context;
import android.os.Looper;
import android.os.Process;

/** Only the provisioned UID0 runtime may obtain a system context. */
final class RootPlatform {
    static Context context() throws Exception {
        if (Process.myUid() != 0) throw new SecurityException("root required");
        if (Looper.myLooper() == null) Looper.prepareMainLooper();
        Object thread = Class.forName("android.app.ActivityThread").getMethod("systemMain").invoke(null);
        return (Context) thread.getClass().getMethod("getSystemContext").invoke(thread);
    }
}
