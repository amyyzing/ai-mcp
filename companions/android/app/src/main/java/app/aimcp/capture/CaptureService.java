package app.aimcp.capture;

import android.app.*;
import android.content.*;
import android.content.pm.ServiceInfo;
import android.content.res.Configuration;
import android.graphics.*;
import android.hardware.display.*;
import android.media.*;
import android.media.projection.*;
import android.os.*;
import android.util.Base64;
import android.util.DisplayMetrics;
import android.widget.Toast;
import java.io.*;
import java.net.*;
import java.nio.ByteBuffer;
import java.util.UUID;
import org.json.JSONObject;

public final class CaptureService extends Service {
    private MediaProjection projection;
    private VirtualDisplay display;
    private ImageReader reader;
    private HandlerThread thread;
    private Handler worker;
    private final Handler main = new Handler(Looper.getMainLooper());
    private volatile boolean stopped;
    private volatile HttpURLConnection connection;
    private String endpoint, token;
    private long sequence, firstTimestamp = -1, lastSent, expires;
    private int failures;
    static String validateEndpoint(String input) throws Exception {
        URI uri = new URI(input);
        if (!"https".equals(uri.getScheme()) || uri.getHost() == null || uri.getUserInfo() != null || uri.getQuery() != null || uri.getFragment() != null) throw new Exception("HTTPS required");
        return input.replaceAll("/+$", "");
    }
    @Override public IBinder onBind(Intent intent) { return null; }
    private Notification notification(String status) {
        PendingIntent stop = PendingIntent.getService(this, 1, new Intent(this, CaptureService.class).setAction("STOP"), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, "capture").setSmallIcon(android.R.drawable.presence_video_online)
            .setContentTitle("AI-MCP screen capture").setContentText(status).setOngoing(true)
            .addAction(new Notification.Action.Builder(null, "Stop capture", stop).build()).build();
    }
    @Override public int onStartCommand(Intent intent, int flags, int id) {
        if (intent == null || "STOP".equals(intent.getAction())) { stopSelf(); return START_NOT_STICKY; }
        if (thread != null) return START_NOT_STICKY;
        getSystemService(NotificationManager.class).createNotificationChannel(new NotificationChannel("capture", "Screen capture", NotificationManager.IMPORTANCE_LOW));
        if (Build.VERSION.SDK_INT >= 29) startForeground(19, notification("Pairing; screen sharing requested"), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
        else startForeground(19, notification("Pairing; screen sharing requested"));
        thread = new HandlerThread("mcp-capture"); thread.start(); worker = new Handler(thread.getLooper());
        worker.post(() -> {
            try {
                endpoint = validateEndpoint(intent.getStringExtra("endpoint"));
                JSONObject request = new JSONObject().put("pairingCode", intent.getStringExtra("code")).put("label", "Android " + Build.MODEL)
                    .put("bootId", UUID.randomUUID().toString()).put("deviceUnixMs", System.currentTimeMillis());
                JSONObject pair = post("/companion/claim", request, null);
                if (!"capture".equals(pair.getJSONObject("scope").getString("kind"))) throw new Exception("Wrong pairing type");
                token = pair.getString("uploadToken"); expires = Math.min(pair.getLong("expiresAt"), System.currentTimeMillis() + 600000);
                if (stopped) return;
                projection = getSystemService(MediaProjectionManager.class).getMediaProjection(intent.getIntExtra("result", 0), intent.getParcelableExtra("projection"));
                projection.registerCallback(new MediaProjection.Callback() {
                    @Override public void onStop() { stopSelf(); }
                    @Override public void onCapturedContentResize(int width, int height) { if (!stopped && display != null) resize(width, height); }
                }, worker);
                DisplayMetrics metrics = getResources().getDisplayMetrics();
                reader = makeReader(metrics.widthPixels, metrics.heightPixels);
                display = projection.createVirtualDisplay("AI-MCP", reader.getWidth(), reader.getHeight(), metrics.densityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, reader.getSurface(), null, worker);
                main.post(() -> Toast.makeText(this, "AI-MCP connected: screen capture active", Toast.LENGTH_LONG).show());
                getSystemService(NotificationManager.class).notify(19, notification("Connected; uploading visible screen frames"));
                main.postDelayed(this::stopSelf, 600000);
            } catch (Exception error) { fail("Pairing/capture failed. Check the code, HTTPS endpoint and sharing permission."); }
            finally { intent.removeExtra("code"); intent.removeExtra("projection"); }
        });
        return START_NOT_STICKY;
    }
    private ImageReader makeReader(int width, int height) {
        double scale = Math.min(1.0, 1280.0 / Math.max(width, height));
        ImageReader next = ImageReader.newInstance(Math.max(2, (int)(width * scale)), Math.max(2, (int)(height * scale)), PixelFormat.RGBA_8888, 2);
        next.setOnImageAvailableListener(this::frame, worker); return next;
    }
    private void resize(int width, int height) {
        if (width < 1 || height < 1) return;
        ImageReader previous = reader; reader = makeReader(width, height);
        display.resize(reader.getWidth(), reader.getHeight(), getResources().getDisplayMetrics().densityDpi);
        display.setSurface(reader.getSurface()); previous.close();
    }
    @Override public void onConfigurationChanged(Configuration configuration) {
        super.onConfigurationChanged(configuration);
        // Older Android releases do not have onCapturedContentResize.
        if (Build.VERSION.SDK_INT < 34 && worker != null) worker.post(() -> {
            if (!stopped && display != null) {
                DisplayMetrics metrics = getResources().getDisplayMetrics(); resize(metrics.widthPixels, metrics.heightPixels);
            }
        });
    }
    private void frame(ImageReader source) {
        if (stopped) return;
        try (Image image = source.acquireLatestImage()) {
            if (image == null || SystemClock.elapsedRealtime() - lastSent < 200) return;
            if (System.currentTimeMillis() >= expires) { stopSelf(); return; }
            long timestamp = image.getTimestamp(); if (firstTimestamp < 0) firstTimestamp = timestamp;
            lastSent = SystemClock.elapsedRealtime();
            Image.Plane plane = image.getPlanes()[0]; ByteBuffer buffer = plane.getBuffer();
            int paddedWidth = image.getWidth() + (plane.getRowStride() - plane.getPixelStride() * image.getWidth()) / plane.getPixelStride();
            Bitmap padded = Bitmap.createBitmap(paddedWidth, image.getHeight(), Bitmap.Config.ARGB_8888); padded.copyPixelsFromBuffer(buffer);
            Bitmap cropped = Bitmap.createBitmap(padded, 0, 0, image.getWidth(), image.getHeight());
            ByteArrayOutputStream bytes = new ByteArrayOutputStream(); cropped.compress(Bitmap.CompressFormat.JPEG, 75, bytes);
            if (cropped != padded) cropped.recycle(); padded.recycle();
            if (bytes.size() > 1500000) return;
            JSONObject data = new JSONObject().put("sequence", ++sequence).put("ptsMs", (timestamp - firstTimestamp) / 1000000.0)
                .put("capturedAtUnixMs", System.currentTimeMillis()).put("backend", "android-mediaprojection")
                // Android permits either app or full-display sharing; never infer Roblox input coordinates.
                .put("coordinateSpace", "display")
                .put("imageBase64", Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP));
            post("/companion/frame", data, token); failures = 0;
        } catch (Exception error) { if (++failures >= 5) fail("Upload disconnected. Capture stopped; pair again to reconnect."); }
    }
    private JSONObject post(String route, JSONObject data, String credential) throws Exception {
        HttpURLConnection conn = (HttpURLConnection)new URL(endpoint + route).openConnection(); connection = conn;
        try {
            conn.setInstanceFollowRedirects(false); conn.setConnectTimeout(7000); conn.setReadTimeout(7000); conn.setRequestMethod("POST"); conn.setDoOutput(true);
            conn.setRequestProperty("Content-Type", "application/json"); if (credential != null) conn.setRequestProperty("Authorization", "Bearer " + credential);
            byte[] payload = data.toString().getBytes("UTF-8"); conn.setFixedLengthStreamingMode(payload.length);
            try (OutputStream out = conn.getOutputStream()) { out.write(payload); }
            if (conn.getResponseCode() != 200) throw new IOException("HTTP rejected upload");
            ByteArrayOutputStream result = new ByteArrayOutputStream();
            try (InputStream in = conn.getInputStream()) { byte[] buffer = new byte[2048]; int count; while ((count = in.read(buffer)) != -1) { if (result.size() + count > 16000) throw new IOException("Oversized response"); result.write(buffer, 0, count); } }
            return new JSONObject(result.toString("UTF-8"));
        } finally { connection = null; conn.disconnect(); }
    }
    private void fail(String message) { main.post(() -> { Toast.makeText(this, message, Toast.LENGTH_LONG).show(); stopSelf(); }); }
    @Override public void onDestroy() {
        stopped = true; main.removeCallbacksAndMessages(null); HttpURLConnection conn = connection; if (conn != null) conn.disconnect();
        if (worker != null) worker.post(() -> {
            if (display != null) display.release(); if (reader != null) reader.close(); if (projection != null) projection.stop();
            token = null; thread.quitSafely();
        });
        stopForeground(true); super.onDestroy();
    }
}
