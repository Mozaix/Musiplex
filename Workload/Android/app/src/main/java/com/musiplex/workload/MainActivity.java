package com.musiplex.workload;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Context;
import android.content.res.Configuration;
import android.graphics.Color;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

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
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Workload for Android: the same app as on iPhone and Mac. The screens are the shared
 * Workload page (Web/workload.html, bundled as assets/index.html). This class hosts it and
 * adds what a page can't do on its own: HTTP to the Musiplex server, saving the tasks,
 * finding Musiplex on the Wi-Fi (Bonjour), and syncing when the network changes.
 *
 * Nothing about anyone is built in: the server, its key and the tasks are kept only on
 * this phone (files/state.json).
 */
public class MainActivity extends Activity {
    private WebView web;
    private boolean ready = false;
    private final List<String> waiting = new ArrayList<>();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newFixedThreadPool(3);

    private NsdManager nsd;
    private NsdManager.DiscoveryListener discovery;
    private WifiManager.MulticastLock multicast;
    private final Map<String, JSONObject> servers = new LinkedHashMap<>();
    private final ArrayDeque<NsdServiceInfo> toResolve = new ArrayDeque<>();
    private boolean resolving = false;
    private ConnectivityManager.NetworkCallback netCallback;

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        boolean dark = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        int bg = Color.parseColor(dark ? "#191919" : "#FFFFFF");
        getWindow().setStatusBarColor(bg);
        getWindow().setNavigationBarColor(bg);
        if (!dark) {
            getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        }
        web = new WebView(this);
        web.setBackgroundColor(bg);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
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

        startDiscovery();
        watchNetwork();
    }

    @Override
    protected void onResume() {
        super.onResume();
        js("window.workloadResume && window.workloadResume()");
    }

    @Override
    public void onBackPressed() {
        js("document.getElementById('layer') && (document.getElementById('layer').innerHTML='')");
        moveTaskToBack(true);
    }

    @Override
    protected void onDestroy() {
        try { if (discovery != null) nsd.stopServiceDiscovery(discovery); } catch (Exception ignored) {}
        try { if (multicast != null && multicast.isHeld()) multicast.release(); } catch (Exception ignored) {}
        try {
            if (netCallback != null) ((ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE)).unregisterNetworkCallback(netCallback);
        } catch (Exception ignored) {}
        io.shutdownNow();
        super.onDestroy();
    }

    private void js(String code) {
        main.post(() -> {
            if (ready) web.evaluateJavascript(code, null);
            else waiting.add(code);
        });
    }

    // ------------------------------------------------------------------ the page's bridge

    private class Bridge {
        /** HTTP for the page (the server sends no CORS headers). Answers via window.__hostReply. */
        @JavascriptInterface
        public void request(int id, String method, String url, String body) {
            io.execute(() -> {
                int status;
                String text;
                HttpURLConnection c = null;
                try {
                    c = (HttpURLConnection) new URL(url).openConnection();
                    c.setConnectTimeout(5000);
                    c.setReadTimeout(8000);
                    c.setRequestMethod(method);
                    if (body != null && !body.isEmpty()) {
                        c.setDoOutput(true);
                        c.setRequestProperty("Content-Type", "application/json");
                        try (OutputStream o = c.getOutputStream()) { o.write(body.getBytes(StandardCharsets.UTF_8)); }
                    }
                    status = c.getResponseCode();
                    InputStream in = status >= 400 ? c.getErrorStream() : c.getInputStream();
                    text = in == null ? "" : read(in);
                } catch (Exception e) {
                    status = -1;
                    text = String.valueOf(e.getMessage());
                } finally {
                    if (c != null) c.disconnect();
                }
                js("window.__hostReply(" + id + "," + status + "," + JSONObject.quote(text) + ")");
            });
        }

        @JavascriptInterface
        public String load() {
            File f = new File(getFilesDir(), "state.json");
            if (!f.exists()) return null;
            try (FileInputStream in = new FileInputStream(f)) { return read(in); } catch (Exception e) { return null; }
        }

        @JavascriptInterface
        public void save(String text) {
            io.execute(() -> {
                File tmp = new File(getFilesDir(), "state.tmp");
                try (FileOutputStream o = new FileOutputStream(tmp)) {
                    o.write(text.getBytes(StandardCharsets.UTF_8));
                } catch (Exception e) {
                    return;
                }
                //noinspection ResultOfMethodCallIgnored
                tmp.renameTo(new File(getFilesDir(), "state.json"));
            });
        }

        @JavascriptInterface
        public String servers() {
            synchronized (servers) {
                JSONArray a = new JSONArray();
                for (JSONObject o : servers.values()) a.put(o);
                return a.toString();
            }
        }
    }

    private static String read(InputStream in) throws Exception {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        byte[] buf = new byte[16384];
        int n;
        while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
        return b.toString("UTF-8");
    }

    // ------------------------------------------------------------------ Musiplex on the Wi-Fi

    private void startDiscovery() {
        try {
            WifiManager wifi = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            multicast = wifi.createMulticastLock("workload");
            multicast.setReferenceCounted(false);
            multicast.acquire();
        } catch (Exception ignored) {}
        nsd = (NsdManager) getSystemService(Context.NSD_SERVICE);
        discovery = new NsdManager.DiscoveryListener() {
            @Override public void onDiscoveryStarted(String type) {}
            @Override public void onDiscoveryStopped(String type) {}
            @Override public void onStartDiscoveryFailed(String type, int code) {}
            @Override public void onStopDiscoveryFailed(String type, int code) {}

            @Override
            public void onServiceFound(NsdServiceInfo info) {
                main.post(() -> { toResolve.add(info); resolveNext(); });
            }

            @Override
            public void onServiceLost(NsdServiceInfo info) {
                synchronized (servers) { servers.remove(info.getServiceName()); }
            }
        };
        try {
            nsd.discoverServices("_musiplex._tcp", NsdManager.PROTOCOL_DNS_SD, discovery);
        } catch (Exception ignored) {}
    }

    /** Android resolves one service at a time. */
    private void resolveNext() {
        if (resolving || toResolve.isEmpty()) return;
        resolving = true;
        NsdServiceInfo info = toResolve.poll();
        nsd.resolveService(info, new NsdManager.ResolveListener() {
            @Override
            public void onResolveFailed(NsdServiceInfo i, int code) {
                main.post(() -> { resolving = false; resolveNext(); });
            }

            @Override
            public void onServiceResolved(NsdServiceInfo i) {
                try {
                    Map<String, byte[]> attrs = i.getAttributes();
                    String ip = attr(attrs, "ip");
                    if (ip.isEmpty() && i.getHost() != null) ip = i.getHost().getHostAddress();
                    String http = attr(attrs, "http"), ws = attr(attrs, "ws");
                    JSONObject o = new JSONObject();
                    o.put("name", i.getServiceName());
                    o.put("ip", ip);
                    o.put("http", http.isEmpty() ? 7860 : Integer.parseInt(http));
                    o.put("ws", ws.isEmpty() ? 7861 : Integer.parseInt(ws));
                    synchronized (servers) { servers.put(i.getServiceName(), o); }
                } catch (Exception ignored) {}
                main.post(() -> { resolving = false; resolveNext(); });
            }
        });
    }

    private static String attr(Map<String, byte[]> attrs, String key) {
        byte[] v = attrs == null ? null : attrs.get(key);
        return v == null ? "" : new String(v, StandardCharsets.UTF_8);
    }

    /** Getting home (joining the Wi-Fi) syncs right away. */
    private void watchNetwork() {
        ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
        netCallback = new ConnectivityManager.NetworkCallback() {
            @Override
            public void onAvailable(Network network) {
                js("window.workloadNetwork && window.workloadNetwork()");
            }
        };
        try { cm.registerDefaultNetworkCallback(netCallback); } catch (Exception ignored) {}
    }
}
