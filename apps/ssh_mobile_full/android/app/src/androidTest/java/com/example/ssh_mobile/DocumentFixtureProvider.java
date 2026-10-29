package com.example.ssh_mobile;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;

/** Standalone test APK provider: fixed public bytes and framework classes only. */
public final class DocumentFixtureProvider extends ContentProvider {
    @Override public boolean onCreate() { return true; }

    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        if ("query-denied".equals(uri.getLastPathSegment())) throw new SecurityException("fixture denied");
        try {
            File file = fixture(uri);
            MatrixCursor cursor = new MatrixCursor(new String[] {OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
            cursor.addRow(new Object[] {"fixture.bin", file.length()});
            return cursor;
        } catch (IOException error) { throw new IllegalStateException(error); }
    }

    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if ("missing".equals(uri.getLastPathSegment())) throw new FileNotFoundException();
        try {
            boolean reading = "slow-input".equals(uri.getLastPathSegment());
            if (reading || "slow-output".equals(uri.getLastPathSegment())) {
                ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
                new Thread(() -> {
                    try {
                        Thread.sleep(200);
                        if (reading) {
                            try (ParcelFileDescriptor.AutoCloseOutputStream out = new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])) {
                                out.write(new byte[24 * 1024]);
                            }
                        } else {
                            try (ParcelFileDescriptor.AutoCloseInputStream in = new ParcelFileDescriptor.AutoCloseInputStream(pipe[0])) {
                                byte[] bytes = new byte[8192];
                                while (in.read(bytes) >= 0) Thread.sleep(10);
                            }
                        }
                    } catch (Exception ignored) { }
                }).start();
                return reading ? pipe[0] : pipe[1];
            }
            return ParcelFileDescriptor.open(fixture(uri), ParcelFileDescriptor.parseMode(mode));
        } catch (IOException error) { throw new FileNotFoundException("fixture unavailable"); }
    }

    private File fixture(Uri uri) throws IOException {
        String name;
        switch (uri.getLastPathSegment()) {
            case "input": case "slow-input": name = "public-saf-input.bin"; break;
            case "output": case "slow-output": name = "public-saf-output.bin"; break;
            default: throw new FileNotFoundException();
        }
        File file = new File(getContext().getCacheDir(), name);
        if (!file.exists()) {
            byte[] bytes = new byte[24 * 1024 + 7];
            for (int i = 0; i < bytes.length; i++) bytes[i] = (byte)(i % 251);
            try (FileOutputStream output = new FileOutputStream(file)) { output.write(bytes); }
        }
        return file;
    }

    @Override public String getType(Uri uri) { return "application/octet-stream"; }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) { return 0; }
    @Override public int delete(Uri uri, String selection, String[] selectionArgs) { return 0; }
}
