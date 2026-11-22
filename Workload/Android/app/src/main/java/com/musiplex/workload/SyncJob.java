package com.musiplex.workload;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Syncs with the hub about every 15 minutes while on Wi-Fi (unmetered), even when the app is
 * closed. Android decides the exact time; 15 minutes is its shortest period.
 *
 * Same rules as the page: send all tasks to POST /tasks, take the hub's copy of each task
 * when it's newer (newest write wins), save. If the app is open, it reloads the file.
 */
public class SyncJob extends JobService {
    static final int ID = 2401;

    static void schedule(Context ctx) {
        JobScheduler js = (JobScheduler) ctx.getSystemService(Context.JOB_SCHEDULER_SERVICE);
        if (js == null) return;
        for (JobInfo j : js.getAllPendingJobs()) if (j.getId() == ID) return;
        JobInfo job = new JobInfo.Builder(ID, new ComponentName(ctx, SyncJob.class))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_UNMETERED)
                .setPeriodic(15 * 60 * 1000L)
                .setPersisted(true)
                .build();
        js.schedule(job);
    }

    @Override
    public boolean onStartJob(JobParameters params) {
        new Thread(() -> {
            try { syncOnce(getApplicationContext()); } catch (Exception ignored) {}
            jobFinished(params, false);
        }).start();
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters params) {
        return true;   // try again later
    }

    static synchronized void syncOnce(Context ctx) throws Exception {
        File file = new File(ctx.getFilesDir(), "state.json");
        if (!file.exists()) return;
        JSONObject state;
        try (FileInputStream in = new FileInputStream(file)) { state = new JSONObject(read(in)); }
        JSONObject prefs = state.optJSONObject("prefs");
        if (prefs == null || prefs.optString("token").isEmpty()) return;
        JSONArray mine = state.optJSONArray("tasks");
        if (mine == null) mine = new JSONArray();
        String token = prefs.optString("token");
        int port = prefs.optInt("serverPort", 7860);
        String body = new JSONObject().put("tasks", mine).toString();

        for (String host : new String[]{prefs.optString("serverHost"), prefs.optString("awayHost")}) {
            if (host == null || host.isEmpty()) continue;
            String h = host.contains(":") ? "[" + host + "]" : host;
            HttpURLConnection c = null;
            try {
                c = (HttpURLConnection) new URL("http://" + h + ":" + port + "/tasks?t=" + token).openConnection();
                c.setConnectTimeout(5000);
                c.setReadTimeout(10000);
                c.setRequestMethod("POST");
                c.setDoOutput(true);
                c.setRequestProperty("Content-Type", "application/json");
                try (OutputStream o = c.getOutputStream()) { o.write(body.getBytes(StandardCharsets.UTF_8)); }
                if (c.getResponseCode() != 200) continue;
                JSONArray theirs;
                try (InputStream in = c.getInputStream()) { theirs = new JSONObject(read(in)).optJSONArray("tasks"); }
                if (theirs == null) return;
                state.put("tasks", merge(mine, theirs));
                File tmp = new File(ctx.getFilesDir(), "state.tmp");
                try (FileOutputStream o = new FileOutputStream(tmp)) { o.write(state.toString().getBytes(StandardCharsets.UTF_8)); }
                //noinspection ResultOfMethodCallIgnored
                tmp.renameTo(file);
                MainActivity.reloadIfOpen();
                return;
            } catch (Exception ignored) {
                // try the next address
            } finally {
                if (c != null) c.disconnect();
            }
        }
    }

    /** Newest write wins, per task; keeps this phone's order, new ones at the end. */
    static JSONArray merge(JSONArray mine, JSONArray theirs) throws Exception {
        Map<String, JSONObject> byId = new LinkedHashMap<>();
        for (int i = 0; i < mine.length(); i++) {
            JSONObject t = mine.optJSONObject(i);
            if (t != null) byId.put(t.optString("id"), t);
        }
        for (int i = 0; i < theirs.length(); i++) {
            JSONObject t = theirs.optJSONObject(i);
            if (t == null) continue;
            JSONObject m = byId.get(t.optString("id"));
            if (m == null || m.optDouble("updated", 0) < t.optDouble("updated", 0)) byId.put(t.optString("id"), t);
        }
        JSONArray out = new JSONArray();
        for (JSONObject t : byId.values()) out.put(t);
        return out;
    }

    private static String read(InputStream in) throws Exception {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        byte[] buf = new byte[16384];
        int n;
        while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
        return b.toString("UTF-8");
    }
}
