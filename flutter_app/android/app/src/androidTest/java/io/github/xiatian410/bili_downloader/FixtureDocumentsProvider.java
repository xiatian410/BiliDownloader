package io.github.xiatian410.bili_downloader;

import android.content.SharedPreferences;
import android.database.MatrixCursor;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.DocumentsProvider;
import android.util.Log;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Separate test APK/process: Android/JDK dependencies only, real Binder and file descriptors. */
public final class FixtureDocumentsProvider extends DocumentsProvider {
    private final CountDownLatch held = new CountDownLatch(1);
    @Override public boolean onCreate() { return true; }
    private File root() {
        File root = new File(getContext().getFilesDir(), "documents");
        if (!root.isDirectory() && !root.mkdirs()) throw new IllegalStateException("Fixture directory unavailable");
        return root;
    }
    private SharedPreferences preferences() { return getContext().getSharedPreferences("fixture", 0); }
    private File file(String id) {
        File root = root();
        if (id.equals("root")) return root;
        if (!id.startsWith("root/")) throw new IllegalArgumentException("Invalid fixture ID");
        try {
            File file = new File(root, id.substring(5)).getCanonicalFile();
            if (!file.getPath().startsWith(root.getCanonicalPath() + File.separator))
                throw new IllegalArgumentException("Invalid fixture path");
            return file;
        } catch (IOException error) { throw new IllegalStateException(error); }
    }
    private String id(File file) {
        File root = root();
        return file.equals(root) ? "root" : "root/" + file.getPath().substring(root.getPath().length() + 1);
    }
    @Override public MatrixCursor queryRoots(String[] projection) {
        String[] columns = projection == null ? new String[] {
                DocumentsContract.Root.COLUMN_ROOT_ID, DocumentsContract.Root.COLUMN_DOCUMENT_ID,
                DocumentsContract.Root.COLUMN_TITLE, DocumentsContract.Root.COLUMN_FLAGS } : projection;
        MatrixCursor cursor = new MatrixCursor(columns);
        Object[] values = new Object[columns.length];
        for (int i = 0; i < columns.length; i++) {
            switch (columns[i]) {
                case DocumentsContract.Root.COLUMN_ROOT_ID:
                case DocumentsContract.Root.COLUMN_DOCUMENT_ID: values[i] = "root"; break;
                case DocumentsContract.Root.COLUMN_TITLE: values[i] = "BiliDownloader test files"; break;
                case DocumentsContract.Root.COLUMN_FLAGS: values[i] = DocumentsContract.Root.FLAG_SUPPORTS_CREATE; break;
            }
        }
        cursor.addRow(values);
        return cursor;
    }
    private MatrixCursor cursor(String[] projection) {
        return new MatrixCursor(projection == null ? new String[] {
                DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_FLAGS } : projection);
    }
    private void add(MatrixCursor cursor, File file) {
        String[] columns = cursor.getColumnNames();
        Object[] values = new Object[columns.length];
        for (int i = 0; i < columns.length; i++) {
            switch (columns[i]) {
                case DocumentsContract.Document.COLUMN_DOCUMENT_ID: values[i] = id(file); break;
                case DocumentsContract.Document.COLUMN_DISPLAY_NAME: values[i] = file.getName(); break;
                case DocumentsContract.Document.COLUMN_MIME_TYPE:
                    values[i] = file.isDirectory() ? DocumentsContract.Document.MIME_TYPE_DIR : "application/octet-stream"; break;
                case DocumentsContract.Document.COLUMN_SIZE: values[i] = file.length(); break;
                case DocumentsContract.Document.COLUMN_FLAGS:
                    values[i] = file.isDirectory() ? DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE : DocumentsContract.Document.FLAG_SUPPORTS_WRITE; break;
                case "fixture_writes": values[i] = preferences().getInt("writes", 0); break;
                case "fixture_held": values[i] = preferences().getBoolean("held", false) ? 1 : 0; break;
            }
        }
        cursor.addRow(values);
    }
    @Override public MatrixCursor queryDocument(String documentId, String[] projection) {
        MatrixCursor cursor = cursor(projection);
        File file = file(documentId);
        if (file.exists()) add(cursor, file);
        return cursor;
    }
    @Override public MatrixCursor queryChildDocuments(String parentId, String[] projection, String sortOrder) {
        MatrixCursor cursor = cursor(projection);
        File[] children = file(parentId).listFiles();
        if (children != null) for (File child : children) add(cursor, child);
        return cursor;
    }
    @Override public boolean isChildDocument(String parentId, String documentId) {
        return file(documentId).getPath().startsWith(file(parentId).getPath() + File.separator);
    }
    @Override public String createDocument(String parentId, String mimeType, String displayName) throws FileNotFoundException {
        if (displayName.contains("/") || displayName.equals(".") || displayName.equals(".."))
            throw new IllegalArgumentException("Invalid fixture filename");
        File target = new File(file(parentId), displayName);
        try {
            boolean created = mimeType.equals(DocumentsContract.Document.MIME_TYPE_DIR) ? target.mkdir() : target.createNewFile();
            if (!created) throw new IOException("Fixture name already exists");
            return id(target);
        } catch (IOException error) { throw new FileNotFoundException(error.toString()); }
    }
    @Override public void deleteDocument(String documentId) throws FileNotFoundException {
        if (documentId.equals("root") || !file(documentId).delete()) throw new FileNotFoundException("Fixture delete rejected");
    }
    @Override public ParcelFileDescriptor openDocument(String documentId, String mode, CancellationSignal signal) throws FileNotFoundException {
        File target = file(documentId);
        if (mode.contains("w")) {
            if (target.getName().startsWith("denied-")) throw new SecurityException("Fixture revoked access");
            SharedPreferences preferences = preferences();
            preferences.edit().putInt("writes", preferences.getInt("writes", 0) + 1).commit();
            boolean interrupt = target.getName().startsWith("interrupt-") || target.getName().equals("process-death.bin");
            if (interrupt && !preferences.getBoolean("failed:" + documentId, false)) {
                preferences.edit().putBoolean("failed:" + documentId, true).commit();
                final ParcelFileDescriptor[] pipe;
                try { pipe = ParcelFileDescriptor.createReliablePipe(); }
                catch (IOException error) { throw new FileNotFoundException(error.toString()); }
                Thread reader = new Thread(() -> {
                    try (ParcelFileDescriptor.AutoCloseInputStream input = new ParcelFileDescriptor.AutoCloseInputStream(pipe[0]);
                         FileOutputStream output = new FileOutputStream(target)) {
                        byte[] prefix = new byte[4096];
                        int count = 0;
                        while (count < prefix.length) {
                            int size = input.read(prefix, count, prefix.length - count);
                            if (size <= 0) throw new IOException("Fixture input ended early");
                            count += size;
                        }
                        output.write(prefix);
                        output.getFD().sync();
                        if (target.getName().equals("process-death.bin")) {
                            preferences.edit().putBoolean("held", true).commit();
                            held.await(60, TimeUnit.SECONDS); // Bounded synthetic interruption only.
                        }
                        pipe[0].closeWithError("Fixture copy interrupted");
                    } catch (Exception error) {
                        Log.i("BiliExportFixture", "Synthetic pipe ended", error);
                        try { pipe[0].close(); } catch (IOException ignored) { }
                    }
                }, "bili-fixture-pipe");
                reader.setDaemon(true);
                reader.start();
                return pipe[1];
            }
            if (target.getName().equals("process-death.bin")) held.countDown();
        }
        return ParcelFileDescriptor.open(target, ParcelFileDescriptor.parseMode(mode));
    }
}
