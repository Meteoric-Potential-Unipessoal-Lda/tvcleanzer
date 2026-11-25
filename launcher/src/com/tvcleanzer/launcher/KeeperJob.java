package com.tvcleanzer.launcher;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;

/**
 * The second way back for the Home-key service (0.71): a job every 15 minutes, kept over
 * reboots by the system's job scheduler, that does what BootReceiver does. TCL Smart TV Pro
 * 55C745 (Android 11): after a reboot the service was listed but never started, and
 * BOOT_COMPLETED never reached us (no «boot:» line at all).
 */
public class KeeperJob extends JobService {
    private static final int ID = 7101;

    static void schedule(Context c) {
        try {
            JobScheduler js = (JobScheduler) c.getSystemService(Context.JOB_SCHEDULER_SERVICE);
            if (js == null) return;
            for (JobInfo j : js.getAllPendingJobs()) if (j.getId() == ID) return;
            JobInfo job = new JobInfo.Builder(ID, new ComponentName(c, KeeperJob.class))
                    .setPeriodic(15 * 60 * 1000L)
                    .setPersisted(true)
                    .build();
            js.schedule(job);
            HomeKeyService.log("keeper job scheduled");
        } catch (Throwable t) {
            HomeKeyService.log("keeper job: " + t);
        }
    }

    @Override
    public boolean onStartJob(final JobParameters p) {
        HomeKeyService.log("keeper job: service " + (HomeKeyService.running != null ? "running" : "not running"));
        TclInput.ensure(this); // 1.43
        LanRemote.ensure(this); // 1.40
        HomeWatch.ensure(this); // 1.39: the watch, where the box drops the service
        if (HomeKeyService.running != null) return false;
        new Thread(() -> {
            try {
                BootReceiver.keep(getApplicationContext());
            } catch (Throwable t) {
                HomeKeyService.log("keeper job: " + t);
            } finally {
                jobFinished(p, false);
            }
        }).start();
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters p) { return false; }
}
