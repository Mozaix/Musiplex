package com.musiplex.android;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.Base64;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Musiplex for Android. The player is the shared Musiplex page (Client/musiplex.html, bundled
 * as assets/index.html), the same one the Windows and Linux app windows use. This class hosts
 * it and adds what a page can't do: finding servers on the Wi-Fi, downloads for offline, the
 * lock-screen player and widgets (PlaybackService, Widgets), and shortcuts.
 *
 * Nothing about anyone is built in: the server address, its key and this phone's ID are made
 * or entered here and kept only on this phone.
 */
public class MainActivity extends Activity {
    static MainActivity current;
    private WebView web;
    private boolean ready = false;
    private final List<String> waiting = new ArrayList<>();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newFixedThreadPool(4);
    private NsdManager nsd;
    private NsdManager.DiscoveryListener discovery;
    private WifiManager.MulticastLock multicast;

    /** A button outside the app (lock screen, notification, widget, shortcut) was pressed. */
    static void remote(Context ctx, String action, String value) {
        String call = "window.remote && window.remote(" + JSONObject.quote(action) + "," + (value == null ? "null" : JSONObject.quote(value)) + ")";
        if (current != null) {
            current.js(call);
        } else {
            Intent i = new Intent(ctx, MainActivity.class).putExtra("action", action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            try { ctx.startActivity(i); } catch (Exception ignored) {}
        }
    }

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        current = this;
        getWindow().setStatusBarColor(Color.parseColor("#07070b"));
        getWindow().setNavigationBarColor(Color.parseColor("#07070b"));
        web = new WebView(this);
        web.setBackgroundColor(Color.parseColor("#07070b"));
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        s.setAllowFileAccess(true);   // downloaded songs play from the app's own storage
        web.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                ready = true;
                for (String c : waiting) web.evaluateJavascript(c, null);
                waiting.clear();
            }
        });
        web.setWebChromeClient(new WebChromeClient());
        web.addJavascriptInterface(new Bridge(), "Android");
        setContentView(web);
        web.loadUrl("file:///android_asset/index.html");
        handle(getIntent());

        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1);
        }
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        handle(intent);
    }

    /** Widgets and long-press shortcuts open the app with an action (surprise, continue, …). */
    private void handle(Intent intent) {
        String action = intent == null ? null : intent.getStringExtra("action");
        if (action != null && !action.equals("open")) {
            js("window.remote && window.remote(" + JSONObject.quote(action) + ",null)");
            intent.removeExtra("action");
        }
    }

    @Override
    public void onBackPressed() {
        web.evaluateJavascript("window.goBack && window.goBack()", value -> {
            if (!"true".equals(value)) moveTaskToBack(true);  // keep playing in the background
        });
    }

    @Override
    protected void onDestroy() {
        stopDiscovery();
        current = null;
        PlaybackService.update(this, new JSONObject());
        web.destroy();
        io.shutdownNow();
        super.onDestroy();
    }

    void js(String code) {
        main.post(() -> {
            if (ready) web.evaluateJavascript(code, null); else waiting.add(code);
        });
    }

    // ---- finding servers on the Wi-Fi (Bonjour / mDNS: _musiplex._tcp)

    private void startDiscovery() {
        stopDiscovery();
        nsd = (NsdManager) getSystemService(Context.NSD_SERVICE);
        WifiManager wifi = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        if (wifi != null) {
            multicast = wifi.createMulticastLock("musiplex");
            multicast.setReferenceCounted(false);
            multicast.acquire();
        }
        discovery = new NsdManager.DiscoveryListener() {
            @Override public void onDiscoveryStarted(String type) {}
            @Override public void onDiscoveryStopped(String type) {}
            @Override public void onStartDiscoveryFailed(String type, int code) {}
            @Override public void onStopDiscoveryFailed(String type, int code) {}
            @Override public void onServiceLost(NsdServiceInfo info) {}
            @Override public void onServiceFound(NsdServiceInfo info) {
                nsd.resolveService(info, new NsdManager.ResolveListener() {
                    @Override public void onResolveFailed(NsdServiceInfo i, int code) {}
                    @Override public void onServiceResolved(NsdServiceInfo i) {
                        String host = null;
                        Map<String, byte[]> attrs = i.getAttributes();
                        if (attrs != null && attrs.get("ip") != null) host = new String(attrs.get("ip"), StandardCharsets.UTF_8);
                        InetAddress addr = i.getHost();
                        if ((host == null || host.isEmpty()) && addr != null) host = addr.getHostAddress();
                        if (host == null || host.contains(":")) return;
                        js("window.onFound && window.onFound(" + JSONObject.quote(i.getServiceName()) + "," + JSONObject.quote(host) + ")");
                    }
                });
            }
        };
        try {
            nsd.discoverServices("_musiplex._tcp", NsdManager.PROTOCOL_DNS_SD, discovery);
        } catch (Exception ignored) {
        }
    }

    private void stopDiscovery() {
        if (nsd != null && discovery != null) {
            try { nsd.stopServiceDiscovery(discovery); } catch (Exception ignored) {}
        }
        discovery = null;
        if (multicast != null && multicast.isHeld()) multicast.release();
    }

    private static byte[] read(String url, int timeout) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(5000);
        c.setReadTimeout(timeout);
        try {
            if (c.getResponseCode() != 200) return null;
            try (InputStream in = c.getInputStream()) {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[65536];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                return out.toByteArray();
            }
        } finally {
            c.disconnect();
        }
    }

    // ---- what the page can call

    private class Bridge {
        /** Plain GET (the song list), answered with window.onFetched(id, status, text). */
        @JavascriptInterface
        public void get(final String id, final String url) {
            io.execute(() -> {
                byte[] b = null;
                try { b = read(url, 30000); } catch (Exception ignored) {}
                js("window.onFetched(" + JSONObject.quote(id) + "," + (b == null ? 0 : 200) + "," + JSONObject.quote(b == null ? "" : new String(b, StandardCharsets.UTF_8)) + ")");
            });
        }

        /** Artwork as a data: URL (so the page can read its colours). */
        @JavascriptInterface
        public void getDataURL(final String id, final String url) {
            io.execute(() -> {
                byte[] b = null;
                try { b = read(url, 15000); } catch (Exception ignored) {}
                String out = b == null ? "" : "data:image/jpeg;base64," + Base64.encodeToString(b, Base64.NO_WRAP);
                js("window.onFetched(" + JSONObject.quote(id) + "," + (b == null ? 0 : 200) + "," + JSONObject.quote(out) + ")");
            });
        }

        @JavascriptInterface
        public void discover(boolean on) {
            main.post(() -> { if (on) startDiscovery(); else stopDiscovery(); });
        }

        /** Shown as this phone's name on your other devices. */
        @JavascriptInterface
        public String deviceName() {
            String n = null;
            try { n = Settings.Global.getString(getContentResolver(), "device_name"); } catch (Exception ignored) {}
            if (n == null || n.isEmpty()) n = Build.MODEL;
            return n;
        }

        /** What's playing (here or on another device): lock screen, notification, widgets. */
        @JavascriptInterface
        public void nowPlaying(String json) {
            main.post(() -> {
                try { PlaybackService.update(MainActivity.this, new JSONObject(json)); } catch (Exception ignored) {}
            });
        }

        @JavascriptInterface
        public void openUrl(String url) {
            main.post(() -> {
                try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url))); } catch (Exception ignored) {}
            });
        }

        // ---- downloads (songs kept on this phone, for offline)

        private File songs() {
            File d = new File(getFilesDir(), "songs");
            d.mkdirs();
            return d;
        }

        /** Downloads one song; progress via window.onDownload(id, fraction), -1 on failure. */
        @JavascriptInterface
        public void download(final String id, final String ext, final String url) {
            io.execute(() -> {
                File part = new File(songs(), id + ".part");
                File done = new File(songs(), id + "." + ext.replaceAll("[^a-zA-Z0-9]", ""));
                try {
                    HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
                    c.setConnectTimeout(8000);
                    c.setReadTimeout(30000);
                    long total = c.getContentLengthLong();
                    long got = 0, shown = 0;
                    try (InputStream in = c.getInputStream(); FileOutputStream out = new FileOutputStream(part)) {
                        byte[] buf = new byte[131072];
                        int n;
                        while ((n = in.read(buf)) > 0) {
                            out.write(buf, 0, n);
                            got += n;
                            if (total > 0 && got - shown > total / 20) {
                                shown = got;
                                js("window.onDownload && window.onDownload(" + JSONObject.quote(id) + "," + ((double) got / total) + ")");
                            }
                        }
                    }
                    c.disconnect();
                    if (!part.renameTo(done)) throw new Exception("rename");
                    js("window.onDownload && window.onDownload(" + JSONObject.quote(id) + ",1)");
                } catch (Exception e) {
                    part.delete();
                    js("window.onDownload && window.onDownload(" + JSONObject.quote(id) + ",-1)");
                }
            });
        }

        /** Downloaded songs: [{id, url, size}] (url plays straight from this phone). */
        @JavascriptInterface
        public String downloads() {
            JSONArray out = new JSONArray();
            File[] files = songs().listFiles();
            if (files != null) for (File f : files) {
                String name = f.getName();
                int dot = name.lastIndexOf('.');
                if (dot <= 0 || name.endsWith(".part")) continue;
                try {
                    out.put(new JSONObject().put("id", name.substring(0, dot)).put("url", "file://" + f.getAbsolutePath()).put("size", f.length()));
                } catch (Exception ignored) {
                }
            }
            return out.toString();
        }

        @JavascriptInterface
        public void removeDownload(String id) {
            File[] files = songs().listFiles();
            if (files != null) for (File f : files) if (f.getName().startsWith(id + ".")) f.delete();
        }
    }
}
