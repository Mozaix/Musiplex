package com.musiplex.android;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.view.View;
import android.widget.RemoteViews;

import org.json.JSONObject;

/**
 * Home-screen widgets (like the iPhone's):
 * - Now Playing: artwork, song, where it's playing, and previous / play-pause / next.
 *   With nothing playing it offers Play Something.
 * - Play Music: Play Something (songs picked for you) and Continue (what you were playing).
 */
public final class Widgets {
    private Widgets() {}

    public static class NowPlaying extends AppWidgetProvider {
        @Override
        public void onUpdate(Context ctx, AppWidgetManager m, int[] ids) {
            for (int id : ids) m.updateAppWidget(id, nowViews(ctx));
        }
    }

    public static class Play extends AppWidgetProvider {
        @Override
        public void onUpdate(Context ctx, AppWidgetManager m, int[] ids) {
            for (int id : ids) m.updateAppWidget(id, playViews(ctx));
        }
    }

    static void updateAll(Context ctx) {
        AppWidgetManager m = AppWidgetManager.getInstance(ctx);
        int[] now = m.getAppWidgetIds(new ComponentName(ctx, NowPlaying.class));
        if (now.length > 0) m.updateAppWidget(now, nowViews(ctx));
    }

    /** Opens the app and does this (Play Something / Continue start the music). */
    static PendingIntent open(Context ctx, String action, int code) {
        Intent i = new Intent(ctx, MainActivity.class).putExtra("action", action)
                .setAction("com.musiplex.android.OPEN." + action)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        return PendingIntent.getActivity(ctx, code, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    /** Controls the music without opening the app. */
    static PendingIntent control(Context ctx, String action, int code) {
        Intent i = new Intent(ctx, PlaybackService.class).putExtra("action", action).setAction(PlaybackService.ACTION + ".w." + action);
        return PendingIntent.getForegroundService(ctx, code, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    static RemoteViews nowViews(Context ctx) {
        RemoteViews v = new RemoteViews(ctx.getPackageName(), R.layout.widget_now);
        JSONObject np = PlaybackService.now;
        boolean on = np.optBoolean("on") && MainActivity.current != null;
        v.setOnClickPendingIntent(R.id.w_root, open(ctx, "open", 10));
        if (!on) {
            v.setTextViewText(R.id.w_title, "Musiplex");
            v.setTextViewText(R.id.w_sub, "Nothing playing");
            v.setImageViewResource(R.id.w_art, R.mipmap.ic_launcher);
            v.setViewVisibility(R.id.w_controls, View.GONE);
            v.setViewVisibility(R.id.w_start, View.VISIBLE);
            v.setOnClickPendingIntent(R.id.w_start, open(ctx, "surprise", 11));
            return v;
        }
        boolean playing = np.optBoolean("playing");
        String where = np.optString("where");
        v.setTextViewText(R.id.w_title, np.optString("title"));
        v.setTextViewText(R.id.w_sub, np.optString("artist") + (where.isEmpty() || np.optBoolean("local") ? "" : "  ·  " + where));
        if (PlaybackService.art != null) v.setImageViewBitmap(R.id.w_art, PlaybackService.art);
        else v.setImageViewResource(R.id.w_art, R.mipmap.ic_launcher);
        v.setViewVisibility(R.id.w_controls, View.VISIBLE);
        v.setViewVisibility(R.id.w_start, View.GONE);
        v.setImageViewResource(R.id.w_toggle, playing ? R.drawable.ic_pause : R.drawable.ic_play);
        v.setOnClickPendingIntent(R.id.w_prev, control(ctx, "prev", 12));
        v.setOnClickPendingIntent(R.id.w_toggle, control(ctx, "toggle", 13));
        v.setOnClickPendingIntent(R.id.w_next, control(ctx, "next", 14));
        return v;
    }

    static RemoteViews playViews(Context ctx) {
        RemoteViews v = new RemoteViews(ctx.getPackageName(), R.layout.widget_play);
        v.setOnClickPendingIntent(R.id.w_surprise, open(ctx, "surprise", 20));
        v.setOnClickPendingIntent(R.id.w_continue, open(ctx, "continue", 21));
        return v;
    }
}
