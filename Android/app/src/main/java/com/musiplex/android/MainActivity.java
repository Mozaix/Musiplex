package com.musiplex.android;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import android.util.Base64;
import org.json.JSONArray;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Musiplex for Android: the player UI is a web page bundled in the app (assets/index.html)
 * that speaks the same protocol as the iPhone app. This class hosts it and gives it what a
 * page can't do on its own: finding servers on the Wi-Fi, fetching the song list, and
 * keeping playback alive in the background.
 *
 * Nothing about anyone is built in: the server address, pairing key and device ID are made
 * or entered on this phone and kept only on it.
 */
public class MainActivity extends Activity {
    private WebView web;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newFixedThreadPool(3);
    private NsdManager nsd;
    private NsdManager.DiscoveryListener discovery;
    private WifiManager.MulticastLock multicast;

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        getWindow().setStatusBarColor(Color.parseColor("#111114"));
        getWindow().setNavigationBarColor(Color.parseColor("#111114"));
        web = new WebView(this);
        web.setBackgroundColor(Color.parseColor("#111114"));
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        s.setAllowFileAccess(true);   // downloaded songs play from the app's own storage
        web.setWebViewClient(new WebViewClient());
        web.setWebChromeClient(new WebChromeClient());
        web.addJavascriptInterface(new Bridge(), "Android");
        setContentView(web);
        web.loadUrl("file:///android_asset/index.html");

        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1);
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
        stopService(new Intent(this, PlaybackService.class));
        web.destroy();
        io.shutdownNow();
        super.onDestroy();
    }

    private void js(String code) {
        main.post(() -> web.evaluateJavascript(code, null));
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

    // ---- what the page can call

    private class Bridge {
        /** Plain GET (used for the song list), answered with window.onFetched(id, status, text). */
        @JavascriptInterface
        public void get(final String id, final String url) {
            io.execute(() -> {
                int status = 0;
                String text = "";
                try {
                    HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
                    c.setConnectTimeout(5000);
                    c.setReadTimeout(30000);
                    status = c.getResponseCode();
                    if (status == 200) {
                        try (InputStream in = c.getInputStream()) {
                            ByteArrayOutputStream out = new ByteArrayOutputStream();
                            byte[] buf = new byte[65536];
                            int n;
                            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                            text = out.toString("UTF-8");
                        }
                    }
                    c.disconnect();
                } catch (Exception e) {
                    status = 0;
                }
                js("window.onFetched(" + JSONObject.quote(id) + "," + status + "," + JSONObject.quote(text) + ")");
            });
        }

        /** Artwork as a data: URL (so the page can read its colours), answered via window.onFetched. */
        @JavascriptInterface
        public void getDataURL(final String id, final String url) {
            io.execute(() -> {
                String out = "";
                try {
                    HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
                    c.setConnectTimeout(5000);
                    c.setReadTimeout(15000);
                    if (c.getResponseCode() == 200) {
                        try (InputStream in = c.getInputStream()) {
                            ByteArrayOutputStream b = new ByteArrayOutputStream();
                            byte[] buf = new byte[65536];
                            int n;
                            while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
                            out = "data:image/jpeg;base64," + Base64.encodeToString(b.toByteArray(), Base64.NO_WRAP);
                        }
                    }
                    c.disconnect();
                } catch (Exception ignored) {
                }
                js("window.onFetched(" + JSONObject.quote(id) + "," + (out.isEmpty() ? 0 : 200) + "," + JSONObject.quote(out) + ")");
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
                File done = new File(songs(), id + "." + ext);
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

        /** Keeps playback going with the screen off (a notification shows while it plays). */
        @JavascriptInterface
        public void playing(boolean on, String title, String artist) {
            Intent i = new Intent(MainActivity.this, PlaybackService.class);
            if (on) {
                i.putExtra("title", title);
                i.putExtra("artist", artist);
                if (Build.VERSION.SDK_INT >= 26) startForegroundService(i); else startService(i);
            } else {
                stopService(i);
            }
        }
    }
}
