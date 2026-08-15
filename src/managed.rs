use pgrx::bgworkers::{BackgroundWorker, BackgroundWorkerBuilder, SignalWakeFlags};
use pgrx::guc::{GucContext, GucFlags, GucRegistry, GucSetting};
use pgrx::prelude::*;
use std::collections::BTreeSet;
use std::ffi::CString;
use std::time::Duration;

static DATABASES: GucSetting<Option<CString>> = GucSetting::<Option<CString>>::new(None);
static WORKER_ROLE: GucSetting<Option<CString>> =
    GucSetting::<Option<CString>>::new(Some(c"postgres"));
static POLL_INTERVAL_MS: GucSetting<i32> = GucSetting::<i32>::new(1_000);
static BATCH_SIZE: GucSetting<i32> = GucSetting::<i32>::new(32);
static MAX_PENDING_JOBS: GucSetting<i32> = GucSetting::<i32>::new(10_000);

#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    GucRegistry::define_string_guc(
        c"pg_react.databases",
        c"Databases served by PostgreSQL-managed pg-react workers.",
        c"Comma-separated database names; changing this setting requires a PostgreSQL restart.",
        &DATABASES,
        GucContext::Postmaster,
        GucFlags::default(),
    );
    GucRegistry::define_string_guc(
        c"pg_react.worker_role",
        c"Database role used by PostgreSQL-managed pg-react workers.",
        c"The role must be able to connect to every configured pg_react.databases entry.",
        &WORKER_ROLE,
        GucContext::Postmaster,
        GucFlags::default(),
    );
    GucRegistry::define_int_guc(
        c"pg_react.poll_interval_ms",
        c"Managed worker polling interval.",
        c"Milliseconds between managed coordination and execution cycles.",
        &POLL_INTERVAL_MS,
        10,
        60_000,
        GucContext::Sighup,
        GucFlags::UNIT_MS,
    );
    GucRegistry::define_int_guc(
        c"pg_react.batch_size",
        c"Maximum managed maintenance batch size.",
        c"Window maintenance uses this bound; managed job claims retain the public 100-item maximum.",
        &BATCH_SIZE,
        1,
        1_000,
        GucContext::Sighup,
        GucFlags::default(),
    );
    GucRegistry::define_int_guc(
        c"pg_react.max_pending_jobs",
        c"Pending-job backpressure threshold.",
        c"Managed workers drain existing work but pause coordination at this threshold.",
        &MAX_PENDING_JOBS,
        1,
        i32::MAX,
        GucContext::Sighup,
        GucFlags::default(),
    );

    if !unsafe { pg_sys::process_shared_preload_libraries_in_progress } {
        return;
    }
    let Some(databases) = DATABASES.get() else {
        return;
    };
    for database in databases
        .to_string_lossy()
        .split(',')
        .map(str::trim)
        .filter(|database| !database.is_empty())
        .collect::<BTreeSet<_>>()
    {
        BackgroundWorkerBuilder::new(&format!("pg-react managed: {database}"))
            .set_library("pg_react")
            .set_function("pg_react_managed_main")
            .set_extra(database)
            .enable_spi_access()
            .set_restart_time(Some(Duration::from_secs(1)))
            .load();
    }
}

#[pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn pg_react_managed_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);
    let database = BackgroundWorker::get_extra();
    let role = WORKER_ROLE.get().expect("pg_react.worker_role");
    BackgroundWorker::connect_worker_to_spi(Some(database), Some(&role.to_string_lossy()));

    loop {
        if BackgroundWorker::sighup_received() {
            unsafe { pg_sys::ProcessConfigFile(pg_sys::GucContext::PGC_SIGHUP) };
        }
        BackgroundWorker::transaction(|| {
            let ready = Spi::get_one::<bool>(
                "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_react' AND extversion = '0.22.0')",
            )
            .expect("check pg_react version")
            .unwrap_or(false);
            if ready {
                Spi::run("SELECT pgreact_api.managed_cycle()").expect("run pg-react managed cycle");
            }
        });
        if !BackgroundWorker::wait_latch(Some(Duration::from_millis(POLL_INTERVAL_MS.get() as u64)))
        {
            break;
        }
    }
}
