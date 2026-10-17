package cn.apt.rootaudio;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.graphics.drawable.Icon;
import android.service.notification.StatusBarNotification;
import java.lang.reflect.Method;
import java.util.Collections;

/** System-owned visible notice; clicking returns to Apt's explicit stop controls. */
final class RootNotice {
    private static final String PACKAGE = "com.android.shell", CHANNEL = "apt_root_recording_v1";
    private static final String TAG = "apt-root-recording";
    private static final int ID = 18462;
    private final Object service;
    private final Context context;
    private final String app;

    RootNotice(Context system, String app) throws Exception {
        this.app = app;
        context = system.createPackageContext(PACKAGE, Context.CONTEXT_IGNORE_SECURITY);
        service = NotificationManager.class.getMethod("getService").invoke(null);
        NotificationChannel channel = new NotificationChannel(CHANNEL, "Apt 持续录音", NotificationManager.IMPORTANCE_LOW);
        channel.setSound(null, null); channel.enableVibration(false);
        Class<?> sliceClass = Class.forName("android.content.pm.ParceledListSlice");
        Object slice = sliceClass.getConstructor(java.util.List.class).newInstance(Collections.singletonList(channel));
        invoke("createNotificationChannelsForPackage", PACKAGE, 2000, slice);
    }
    private Object invoke(String name, Object... args) throws Exception {
        for (Method method : Class.forName("android.app.INotificationManager").getMethods())
            if (method.getName().equals(name) && method.getParameterTypes().length == args.length)
                return method.invoke(service, args);
        throw new IllegalStateException("notification API unavailable");
    }
    void show(long seconds) throws Exception {
        show(seconds, false);
    }
    private void show(long seconds, boolean probe) throws Exception {
        Intent launch = context.getPackageManager().getLaunchIntentForPackage(app);
        if (launch == null) throw new IllegalStateException("Apt unavailable");
        PendingIntent open = PendingIntent.getActivity(context, ID, launch,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification notice = new Notification.Builder(context, CHANNEL)
                .setSmallIcon(Icon.createWithResource("android", android.R.drawable.ic_btn_speak_now))
                .setContentTitle(probe ? "Apt 录音通知验证" : "Apt 正在录音")
                .setContentText(probe ? "仅核通知，没有打开麦克风" : "已录 " + seconds / 60 + " 分钟 · 锁屏可继续 · 点此打开 Apt 暂停或结束")
                .setCategory(Notification.CATEGORY_SERVICE).setContentIntent(open)
                .setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false).build();
        notice.flags |= Notification.FLAG_NO_CLEAR;
        invoke("enqueueNotificationWithTag", PACKAGE, "android", TAG, ID, notice, 0);
    }
    boolean visible() throws Exception {
        if (!(Boolean) invoke("areNotificationsEnabledForPackage", PACKAGE, 2000)) return false;
        NotificationChannel channel = (NotificationChannel) invoke("getNotificationChannelForPackage", PACKAGE, 2000, CHANNEL, null, false);
        if (channel == null || channel.getImportance() == NotificationManager.IMPORTANCE_NONE) return false;
        StatusBarNotification[] posted = (StatusBarNotification[]) invoke("getActiveNotifications", "android");
        for (StatusBarNotification notification : posted) {
            if (PACKAGE.equals(notification.getPackageName()) && notification.getUserId() == 0
                    && TAG.equals(notification.getTag()) && notification.getId() == ID
                    && CHANNEL.equals(notification.getNotification().getChannelId())
                    && (notification.getNotification().flags & Notification.FLAG_ONGOING_EVENT) != 0) return true;
        }
        return false;
    }
    void clear() throws Exception { invoke("cancelNotificationWithTag", PACKAGE, "android", TAG, ID, 0); }
    public static void main(String[] args) {
        int exit = 1;
        String stage = "context";
        RootNotice notice = null;
        try {
            Context context = RootPlatform.context(); stage = "channel";
            notice = new RootNotice(context, "com.stepx.aiapp.publicapt"); stage = "post";
            notice.show(0, true); Thread.sleep(300);
            stage = "visible";
            if (!notice.visible()) throw new IllegalStateException("notice not visible");
            System.out.println("NOTICE_VISIBLE uid=0"); exit = 0;
        } catch (Exception error) {
            Throwable cause = error;
            while (cause instanceof java.lang.reflect.InvocationTargetException && cause.getCause() != null) cause = cause.getCause();
            System.out.println("NOTICE_FAILED stage=" + stage + " type=" + cause.getClass().getSimpleName()
                    + " message=" + cause.getMessage());
        }
        finally {
            if (notice != null) try { notice.clear(); } catch (Exception error) { exit = 1; }
        }
        System.exit(exit);
    }
}
