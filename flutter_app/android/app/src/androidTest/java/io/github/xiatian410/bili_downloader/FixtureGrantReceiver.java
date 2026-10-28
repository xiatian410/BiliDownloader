package io.github.xiatian410.bili_downloader;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.ResultReceiver;
import android.provider.DocumentsContract;
import android.util.Log;

/** Runs in the standalone test APK, whose class loader cannot use the app's Kotlin runtime. */
public final class FixtureGrantReceiver extends BroadcastReceiver {
    @Override
    @SuppressWarnings("deprecation")
    public void onReceive(Context context, Intent intent) {
        ResultReceiver result = intent.getParcelableExtra("grantResult");
        try {
            Uri tree = DocumentsContract.buildTreeDocumentUri(
                    "io.github.xiatian410.bili_downloader.test.documents", "root");
            int flags = Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION;
            // Only this fixture's synthetic tree and these two fixed recipients.
            context.grantUriPermission("io.github.xiatian410.bili_downloader", tree, flags);
            context.grantUriPermission("com.android.shell", tree, flags);
            Log.i("BiliExportFixture", "Synthetic tree grant issued");
            if (result != null) result.send(Activity.RESULT_OK, null);
        } catch (Exception error) {
            Log.e("BiliExportFixture", "Synthetic tree grant failed", error);
            if (result != null) result.send(Activity.RESULT_CANCELED, null);
        }
    }
}
