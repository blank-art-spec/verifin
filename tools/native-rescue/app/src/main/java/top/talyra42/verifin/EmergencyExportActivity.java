package top.talyra42.verifin;

import android.app.Activity;
import android.content.Intent;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import android.util.TypedValue;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;
import java.util.Date;
import java.util.Locale;
import java.util.UUID;

/**
 * 完全使用 Android 原生界面的应急导出入口。
 * 安装时沿用正式包的应用 ID 和签名，从而读取同一应用私有目录；此类不启动 Flutter，
 * 也不打开应用原有的数据库迁移器。
 */
public final class EmergencyExportActivity extends Activity {
    private static final String LOG_TAG = "VeriFinRescue";
    private static final String DATABASE_NAME = "verifin.db";
    private static final int CREATE_DOCUMENT_REQUEST = 1;
    private Button exportButton;
    private TextView statusView;

    /**
     * 创建应急页面和唯一的导出按钮。
     *
     * @param savedInstanceState Android 保存的页面状态；导出不依赖此状态，避免误将旧任务恢复为成功。
     */
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        ScrollView scroll = new ScrollView(this);
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        int padding = dp(24);
        content.setPadding(padding, padding, padding, padding);
        scroll.addView(content);

        TextView title = new TextView(this);
        title.setText(R.string.title);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 26);
        title.setPadding(0, 0, 0, dp(20));
        content.addView(title);

        TextView description = new TextView(this);
        description.setText(R.string.description);
        description.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17);
        description.setPadding(0, 0, 0, dp(24));
        content.addView(description);

        exportButton = new Button(this);
        exportButton.setText(R.string.export_button);
        exportButton.setOnClickListener(view -> chooseExportLocation());
        content.addView(exportButton);

        statusView = new TextView(this);
        statusView.setText(R.string.status_ready);
        statusView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17);
        statusView.setPadding(0, dp(24), 0, 0);
        content.addView(statusView);

        setContentView(scroll);
    }

    /**
     * 把设计尺寸转换为当前屏幕的像素，保证不同密度手机有相近的可点击面积。
     *
     * @param value 以 dp 表示的设计尺寸。
     * @return 按当前屏幕密度换算后的整数像素。
     */
    private int dp(int value) {
        return Math.round(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics()));
    }

    /**
     * 调用 Android 系统文件选择器，让用户指定导出文件的位置。
     * 此操作不会读取或修改账本；取消选择也不会留下空文件。
     */
    private void chooseExportLocation() {
        File database = getDatabasePath(DATABASE_NAME);
        if (!database.isFile()) {
            statusView.setText(R.string.status_missing);
            return;
        }

        Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("application/octet-stream");
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        String date = new java.text.SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(new Date());
        intent.putExtra(Intent.EXTRA_TITLE, "verifin-raw-ledger-" + date + ".db");
        statusView.setText(R.string.status_selecting);
        startActivityForResult(intent, CREATE_DOCUMENT_REQUEST);
    }

    /**
     * 接收系统文件选择器返回的目标地址，仅在用户确实选定文件时启动后台导出。
     *
     * @param requestCode 发起选择器时传入的请求编号，用于排除其他 Activity 的结果。
     * @param resultCode 系统返回的完成状态；取消时不触碰账本。
     * @param data 包含用户选择的 content URI，不把真实存储路径写入日志。
     */
    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != CREATE_DOCUMENT_REQUEST) {
            return;
        }
        if (resultCode != RESULT_OK || data == null || data.getData() == null) {
            statusView.setText(R.string.status_cancelled);
            return;
        }
        exportLedger(data.getData());
    }

    /**
     * 在后台线程创建一致的 SQLite 快照、写入所选文件并重新读取核对摘要。
     * 成功前不会向用户显示“已备份”，且所有临时快照最终都会删除。
     *
     * @param destination 用户通过系统文件选择器授予写入权限的 content URI。
     */
    private void exportLedger(Uri destination) {
        exportButton.setEnabled(false);
        statusView.setText(R.string.status_working);

        new Thread(() -> {
            File snapshot = new File(getCacheDir(), "verifin-rescue-" + UUID.randomUUID() + ".db");
            String phase = "制作账本快照";
            try {
                File source = getDatabasePath(DATABASE_NAME);
                if (!source.isFile()) {
                    runOnUiThread(() -> statusView.setText(R.string.status_missing));
                    return;
                }

                makeConsistentSnapshot(source, snapshot);
                phase = "检查账本快照";
                int databaseVersion = checkSnapshot(snapshot);
                phase = "写入所选文件";
                FileDigest written = copySnapshot(snapshot, destination);
                phase = "重新读取并核对文件";
                FileDigest verified = digestExport(destination);
                if (written.size != verified.size || !Arrays.equals(written.sha256, verified.sha256)) {
                    throw new IOException(getString(R.string.error_mismatch));
                }

                String sizeText = android.text.format.Formatter.formatFileSize(this, written.size);
                runOnUiThread(() -> statusView.setText(
                        getString(R.string.status_success, sizeText, databaseVersion)));
                Log.i(LOG_TAG, "应急导出已完成并核验；数据库版本=" + databaseVersion
                        + "；字节数=" + written.size);
            } catch (Exception error) {
                // 不记录 URI、数据库内容或异常正文，避免系统日志泄露账目和保存路径。
                Log.e(LOG_TAG, "应急导出失败；阶段=" + phase
                        + "；异常类型=" + error.getClass().getSimpleName());
                String safePhase = phase;
                runOnUiThread(() -> statusView.setText(
                        getString(R.string.status_failure, safePhase)));
            } finally {
                if (snapshot.exists() && !snapshot.delete()) {
                    Log.e(LOG_TAG, "应急导出临时快照删除失败");
                }
                runOnUiThread(() -> exportButton.setEnabled(true));
            }
        }, "verifin-emergency-export").start();
    }

    /**
     * 让 SQLite 自己读取主库及可能尚未合并的 WAL，并生成事务一致的新数据库。
     * VACUUM INTO 不升级源库结构，目标文件必须事先不存在。
     *
     * @param source 应用私有目录中的原始 verifin.db。
     * @param snapshot 应用缓存目录中的全新临时文件路径。
     */
    private void makeConsistentSnapshot(File source, File snapshot) {
        if (snapshot.exists()) {
            throw new IllegalStateException("临时快照路径已被占用");
        }
        try (SQLiteDatabase database = SQLiteDatabase.openDatabase(
                source.getAbsolutePath(), null,
                SQLiteDatabase.OPEN_READWRITE | SQLiteDatabase.NO_LOCALIZED_COLLATORS)) {
            String escapedPath = snapshot.getAbsolutePath().replace("'", "''");
            database.execSQL("VACUUM INTO '" + escapedPath + "'");
        }
    }

    /**
     * 对即将导出的快照运行 SQLite 自身的完整性检查，并读取其真实 schema 版本。
     * 这里以只读方式打开快照，不调用 Flutter 或项目数据库迁移代码。
     *
     * @param snapshot VACUUM INTO 生成的临时数据库文件。
     * @return PRAGMA user_version 给出的原始数据库版本。
     * @throws IOException 快照为空或完整性检查未返回 ok 时抛出。
     */
    private int checkSnapshot(File snapshot) throws IOException {
        if (!snapshot.isFile() || snapshot.length() == 0) {
            throw new IOException(getString(R.string.error_empty));
        }
        try (SQLiteDatabase database = SQLiteDatabase.openDatabase(
                snapshot.getAbsolutePath(), null,
                SQLiteDatabase.OPEN_READONLY | SQLiteDatabase.NO_LOCALIZED_COLLATORS);
             Cursor integrity = database.rawQuery("PRAGMA integrity_check", null)) {
            if (!integrity.moveToFirst() || !"ok".equalsIgnoreCase(integrity.getString(0))) {
                throw new IOException(getString(R.string.error_integrity));
            }
            try (Cursor version = database.rawQuery("PRAGMA user_version", null)) {
                if (!version.moveToFirst()) {
                    throw new IOException(getString(R.string.error_integrity));
                }
                return version.getInt(0);
            }
        }
    }

    /**
     * 把已检查的快照分块写入系统文件选择器返回的目标，同时计算写出内容的 SHA-256。
     *
     * @param snapshot 只位于本应用缓存中的一致数据库快照。
     * @param destination 用户授权的目标文件 content URI。
     * @return 实际写出字节数和摘要，供重新读取后逐项比较。
     * @throws IOException 读源或写目标失败时抛出，绝不把部分文件称为成功。
     */
    private FileDigest copySnapshot(File snapshot, Uri destination) throws IOException {
        MessageDigest digest = newSha256();
        long size = 0;
        try (InputStream input = new FileInputStream(snapshot);
             OutputStream output = getContentResolver().openOutputStream(destination, "w")) {
            if (output == null) {
                throw new IOException(getString(R.string.error_open_output));
            }
            byte[] buffer = new byte[64 * 1024];
            int count;
            while ((count = input.read(buffer)) != -1) {
                output.write(buffer, 0, count);
                digest.update(buffer, 0, count);
                size += count;
            }
            output.flush();
        }
        if (size == 0) {
            throw new IOException(getString(R.string.error_empty));
        }
        return new FileDigest(size, digest.digest());
    }

    /**
     * 从系统文件提供者重新打开已导出的文件，确认实际持久化内容与写入内容一致。
     *
     * @param destination 用户选定的目标文件 content URI。
     * @return 从目标文件重新计算出的字节数和 SHA-256。
     * @throws IOException 文件无法读回或读取失败时抛出。
     */
    private FileDigest digestExport(Uri destination) throws IOException {
        MessageDigest digest = newSha256();
        long size = 0;
        try (InputStream input = getContentResolver().openInputStream(destination)) {
            if (input == null) {
                throw new IOException(getString(R.string.error_open_input));
            }
            byte[] buffer = new byte[64 * 1024];
            int count;
            while ((count = input.read(buffer)) != -1) {
                digest.update(buffer, 0, count);
                size += count;
            }
        }
        return new FileDigest(size, digest.digest());
    }

    /**
     * 创建新的 SHA-256 计算器，避免重复使用已经结束计算的摘要对象。
     *
     * @return 尚未输入任何字节的 SHA-256 实例。
     */
    private MessageDigest newSha256() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException error) {
            // SHA-256 是 Android 平台必备算法，缺失时按导出失败处理。
            throw new IllegalStateException("SHA-256 不可用", error);
        }
    }

    /** 保存一次文件读取或写入的实际结果，确保长度与摘要一起传递。 */
    private static final class FileDigest {
        final long size;
        final byte[] sha256;

        /**
         * 记录一个文件的核验结果。
         *
         * @param size 实际处理的字节数。
         * @param sha256 对这些字节计算出的 SHA-256 摘要。
         */
        FileDigest(long size, byte[] sha256) {
            this.size = size;
            this.sha256 = sha256;
        }
    }
}
