package app.aimcp.capture;

import android.app.Activity;
import android.content.Intent;
import android.media.projection.MediaProjectionManager;
import android.os.Bundle;
import android.os.Build;
import android.Manifest;
import android.content.pm.PackageManager;
import android.text.InputType;
import android.widget.*;

public final class MainActivity extends Activity {
    private EditText endpoint, code;
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL); layout.setPadding(32, 48, 32, 24);
        TextView title = new TextView(this); title.setText("AI-MCP device capture"); title.setTextSize(24); layout.addView(title);
        TextView instructions = new TextView(this);
        instructions.setText("Create a capture pairing with companion-pair, then enter its HTTPS server URL and one-use code.\n\nSelect Roblox in Android's sharing dialog when available. Older Android versions share the entire display. Capture includes visible pixels only, no audio. Stop from the notification or this screen.\n\nFrames are uploaded at up to 5 fps for a maximum of 10 minutes. The code and upload credential are never saved.");
        layout.addView(instructions);
        endpoint = new EditText(this); endpoint.setHint("https://your-mcp-host"); endpoint.setSingleLine(true); endpoint.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI); layout.addView(endpoint);
        code = new EditText(this); code.setHint("One-use pairing code"); code.setSingleLine(true); code.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD); layout.addView(code);
        Button start = new Button(this); start.setText("Pair and share Roblox"); layout.addView(start);
        start.setOnClickListener(view -> {
            try { CaptureService.validateEndpoint(endpoint.getText().toString().trim()); }
            catch (Exception error) { Toast.makeText(this, "Enter a valid HTTPS server URL", Toast.LENGTH_LONG).show(); return; }
            if (code.getText().length() < 20) { Toast.makeText(this, "Enter the pairing code from companion-pair", Toast.LENGTH_LONG).show(); return; }
            MediaProjectionManager manager = getSystemService(MediaProjectionManager.class);
            startActivityForResult(manager.createScreenCaptureIntent(), 7);
        });
        Button stop = new Button(this); stop.setText("Stop capture"); layout.addView(stop);
        stop.setOnClickListener(view -> stopService(new Intent(this, CaptureService.class)));
        setContentView(layout);
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(new String[] { Manifest.permission.POST_NOTIFICATIONS }, 8);
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == 7 && result == RESULT_OK && data != null) {
            Intent service = new Intent(this, CaptureService.class).putExtra("result", result).putExtra("projection", data)
                .putExtra("endpoint", endpoint.getText().toString().trim()).putExtra("code", code.getText().toString());
            startForegroundService(service); code.setText("");
        }
    }
}
