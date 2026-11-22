package com.musiplex.android;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.drawable.Icon;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemClock;

import org.json.JSONObject;

import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;

/**
 * The lock-screen / notification player (like the iPhone's Live Activity and lock screen):
 * artwork, title, play/pause, previous, next and a seek bar, through Android's MediaSession,
 * so headphone and Bluetooth buttons work too. Shown whenever something is playing on any
 * of your devices; it also keeps the app and Wi-Fi awake while this phone is the speaker.
 */
public class PlaybackService extends Service {
    static final String CHANNEL = "playback";
    static final String ACTION = "com.musiplex.android.ACTION";
    static PlaybackService instance;

    /** The latest "now playing" from the page (also read by the widgets). */
    static JSONObject now = new JSONObject();
    static Bitmap art;
    private static String artUrl = "";

    private MediaSession session;
    private PowerManager.WakeLock wake;
    private WifiManager.WifiLock wifi;
    private final Handler main = new Handler(Looper.getMainLooper());

    /** Called by the page (via MainActivity) whenever the song or play state changes. */
    static void update(Context ctx, JSONObject np) {
        now = np;
        boolean on = np.optBoolean("on");
        String url = np.optString("art");
        if (on && !url.equals(artUrl)) {
            artUrl = url;
            art = null;
            if (!url.isEmpty()) new Thread(() -> {
                Bitmap b = fetch(url);
                new Handler(Looper.getMainLooper()).post(() -> {
                    if (url.equals(artUrl)) { art = b; refresh(ctx); }
                });
            }).start();
        }
        if (on) {
            Intent i = new Intent(ctx, PlaybackService.class);
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i); else ctx.startService(i);
        } else if (instance != null) {
            instance.stopSelf();
        }
        refresh(ctx);
    }

    static void refresh(Context ctx) {
        if (instance != null) instance.show();
        Widgets.updateAll(ctx);
    }

    private static Bitmap fetch(String url) {
        try {
            HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
            c.setConnectTimeout(5000);
            c.setReadTimeout(10000);
            if (c.getResponseCode() != 200) return null;
            try (InputStream in = c.getInputStream()) {
                Bitmap b = BitmapFactory.decodeStream(in);
                if (b == null) return null;
                int max = 512;
                if (b.getWidth() > max) b = Bitmap.createScaledBitmap(b, max, max * b.getHeight() / b.getWidth(), true);
                return b;
            }
        } catch (Exception e) {
            return null;
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        session = new MediaSession(this, "Musiplex");
        session.setCallback(new MediaSession.Callback() {
            @Override public void onPlay() { MainActivity.remote(PlaybackService.this, "toggle", null); }
            @Override public void onPause() { MainActivity.remote(PlaybackService.this, "toggle", null); }
            @Override public void onSkipToNext() { MainActivity.remote(PlaybackService.this, "next", null); }
            @Override public void onSkipToPrevious() { MainActivity.remote(PlaybackService.this, "prev", null); }
            @Override public void onSeekTo(long pos) { MainActivity.remote(PlaybackService.this, "seek", String.valueOf(pos / 1000.0)); }
            @Override public void onStop() { MainActivity.remote(PlaybackService.this, "pause", null); }
        });
        session.setSessionActivity(PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
        session.setActive(true);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent != null ? intent.getStringExtra("action") : null;
        if (action != null) MainActivity.remote(this, action, null);
        show();
        return START_NOT_STICKY;
    }

    private PendingIntent button(String action, int code) {
        Intent i = new Intent(this, PlaybackService.class).putExtra("action", action).setAction(ACTION + "." + action);
        return PendingIntent.getService(this, code, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    void show() {
        JSONObject np = now;
        boolean playing = np.optBoolean("playing");
        boolean local = np.optBoolean("local");
        String title = np.optString("title", "Musiplex");
        String artist = np.optString("artist");
        String where = np.optString("where");
        long duration = (long) (np.optDouble("duration", 0) * 1000);
        long position = (long) (np.optDouble("position", 0) * 1000);

        MediaMetadata.Builder meta = new MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
                .putString(MediaMetadata.METADATA_KEY_ALBUM, np.optString("album"))
                .putLong(MediaMetadata.METADATA_KEY_DURATION, duration);
        if (art != null) meta.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, art);
        session.setMetadata(meta.build());
        session.setPlaybackState(new PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE | PlaybackState.ACTION_PLAY_PAUSE
                        | PlaybackState.ACTION_SKIP_TO_NEXT | PlaybackState.ACTION_SKIP_TO_PREVIOUS | PlaybackState.ACTION_SEEK_TO
                        | PlaybackState.ACTION_STOP)
                .setState(playing ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED, position,
                        playing ? 1f : 0f, SystemClock.elapsedRealtime())
                .build());

        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm.getNotificationChannel(CHANNEL) == null) {
            NotificationChannel ch = new NotificationChannel(CHANNEL, "Now playing", NotificationManager.IMPORTANCE_LOW);
            ch.setShowBadge(false);
            ch.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
            nm.createNotificationChannel(ch);
        }
        Notification.Builder b = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat)
                .setContentTitle(title)
                .setContentText(artist)
                .setSubText(local ? null : where.isEmpty() ? null : "Playing on " + where)
                .setLargeIcon(art)
                .setContentIntent(session.getController().getSessionActivity())
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setOngoing(playing)
                .setShowWhen(false)
                .addAction(new Notification.Action.Builder(Icon.createWithResource(this, R.drawable.ic_prev), "Previous", button("prev", 1)).build())
                .addAction(new Notification.Action.Builder(Icon.createWithResource(this, playing ? R.drawable.ic_pause : R.drawable.ic_play),
                        playing ? "Pause" : "Play", button("toggle", 2)).build())
                .addAction(new Notification.Action.Builder(Icon.createWithResource(this, R.drawable.ic_next), "Next", button("next", 3)).build())
                .setStyle(new Notification.MediaStyle().setMediaSession(session.getSessionToken()).setShowActionsInCompactView(0, 1, 2));
        Notification n = b.build();
        if (Build.VERSION.SDK_INT >= 29) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
        else startForeground(1, n);
        if (!playing) stopForeground(STOP_FOREGROUND_DETACH);   // paused: can be swiped away
        keepAwake(local && playing);
    }

    private void keepAwake(boolean on) {
        if (on) {
            if (wake == null) {
                wake = ((PowerManager) getSystemService(Context.POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "musiplex:play");
                wake.setReferenceCounted(false);
            }
            if (!wake.isHeld()) wake.acquire(6 * 60 * 60 * 1000L);
            if (wifi == null) {
                WifiManager wm = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
                if (wm != null) {
                    wifi = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "musiplex:stream");
                    wifi.setReferenceCounted(false);
                }
            }
            if (wifi != null && !wifi.isHeld()) wifi.acquire();
        } else {
            if (wake != null && wake.isHeld()) wake.release();
            if (wifi != null && wifi.isHeld()) wifi.release();
        }
    }

    @Override
    public void onDestroy() {
        keepAwake(false);
        session.setActive(false);
        session.release();
        instance = null;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
