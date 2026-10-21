package top.talyra42.verifin

import android.app.Application

/** 系统合法重建任何应用进程时，恢复本机已授权的提醒；不主动拉活或要求采集权限。 */
class VeriFinApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AccountEntryReminderReceiver.restore(this)
    }
}
