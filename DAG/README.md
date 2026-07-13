# Initialize-DAG

End-to-end setup and database initialization for a SQL Server **distributed availability group**.

Answer a short interview, confirm the plan, and walk away. The script discovers both
availability groups, validates and repairs the prerequisites, creates the distributed AG,
seeds the databases (automatically or by backup/restore), settles the DAG into asynchronous
commit, and prints a health rollup.

It is safe to run again at any time. Every action re-checks live server state first, so an
interrupted run resumes where it stopped rather than starting over.

---

## Requirements

* Windows PowerShell 5.1 or PowerShell 7+
* The [`SqlServer`](https://www.powershellgallery.com/packages/SqlServer) module
  (`Install-Module SqlServer -Scope CurrentUser`)
* `sysadmin` on every replica of both availability groups

## Assumptions

1. Both availability groups already exist, **each with a listener**.
2. Both are in the same domain.
3. The database mirroring endpoints use Windows authentication (`NEGOTIATE`), not certificates.
4. For manual seeding, a network share is reachable by the SQL Server service accounts on
   **both** sides, with read/write (full control is simplest).
5. The forwarder availability group is **empty** — a forwarder receives its databases from
   the distributed AG and cannot already contain databases of its own.

Preflight checks every one of these and refuses to start if something is wrong.

---

## Quick start

```powershell
.\Initialize-DAG.ps1
```

You will be asked, once, up front:

| Prompt | Notes |
|---|---|
| Authentication | Windows integrated, or a SQL login |
| A replica of the **global primary** AG | The side your databases live on today |
| Which availability group | Numbered list, auto-selected when there is only one |
| A replica of the **forwarder** AG | The destination side |
| Which availability group | Numbered list |
| DNS domain | Discovered from the endpoint URLs; pick a number |
| Distributed AG name | Defaults to `DistAG_<global>_<forwarder>` |
| Seeding mode | `AUTOMATIC` or `MANUAL` |
| Backup share, stripe count, log interval | Manual seeding only |
| Databases to exclude | Numbered list; press ENTER to include everything |

Everything after the plan confirmation is unattended.

### Other switches

```powershell
.\Initialize-DAG.ps1 -HealthOnly            # health rollup for a configured DAG
.\Initialize-DAG.ps1 -RemoveLogBackupJob    # remove the log backup job created for manual seeding
.\Initialize-DAG.ps1 -SeedTimeoutHours 48   # how long to wait for one database to seed (default 24)
.\Initialize-DAG.ps1 -Credential $cred      # supply a SQL login for unattended runs
```

---

## Choosing a seeding mode

**AUTOMATIC** — SQL Server streams each database over the endpoints. No share needed, nothing
to clean up. This is the right default.

**MANUAL** — a compressed, checksummed, striped full backup goes to a share; the script restores
it onto every forwarder replica, replays the log chain, then joins each database to the forwarder
AG. Choose it when:

* the databases are very large or the link between sites is slow, **or**
* the forwarder's **secondary** replicas must hold the databases *before* failover.

That last point matters more than it sounds. See below.

---

## Cross-version distributed AGs

A distributed AG moves databases from the global primary to the forwarder. A database can never
be restored or seeded onto an **older** major version, so the forwarder must be the same version
or newer. The script hard-blocks the wrong direction and tells you to swap the two sides.

When the forwarder is **newer** (the upgrade/migration case), expect this until you fail over:

* Forwarder databases sit in **`RECOVERING` / `SYNCHRONIZING`** and are not readable, because
  they have not been upgraded yet. This is normal.
* The distributed AG may report as less than fully healthy for the same reason.
* With **AUTOMATIC** seeding, the forwarder's own **secondary** replicas stay empty: the
  forwarder primary cannot seed a database it cannot bring online, and seeding fails with
  *Async Task Failure*. They populate themselves after failover.
* With **MANUAL** seeding, the forwarder secondaries are restored directly from backup, so they
  hold the databases immediately.

Data flows the whole time. Failing over upgrades the databases to the newer version, after which
failing back is not possible.

The health rollup labels all of the above as **expected**, not as faults.

---

## What manual seeding actually does

Per database, in order:

1. Install a log backup job (default: every 15 minutes) on **every replica of the global primary
   AG** — not just the current primary. SQL Agent jobs do not replicate, so a job that existed
   only on the old primary would silently stop after a failover. Each copy guards itself and exits
   quietly unless its local replica holds the PRIMARY role.
2. Take a non-copy-only, compressed, checksummed **FULL backup striped across N files**.
3. Restore it `WITH NORECOVERY` onto the forwarder primary and every forwarder secondary,
   relocating data and log files onto each target's own drive layout.
4. Restore every log backup taken since, `WITH NORECOVERY`.
5. **Disable the log backup job and wait for any in-flight backup to finish.** Disabling a job does
   not stop the run already in progress; a log backup that fired during the final catch-up would
   take log records the forwarder could then never obtain.
6. Take the final log backup and restore it.
7. `ALTER DATABASE ... SET HADR AVAILABILITY GROUP` on the forwarder primary, then each secondary.
8. Re-enable the job and move to the next database.

Directory layout on the share:

```
<share>\<DagName>\<Database>\FULL\<Database>_FULL_<utc>_01of04.bak
<share>\<DagName>\<Database>\LOG\<Database>_LOG_<utc>.trn
```

Directories are created by the SQL Server engine (`xp_create_subdir`), not by the machine running
the script — the orchestrating workstation usually cannot see the share at all.

### Log chain handling

Log backups are ordered by the **FirstLSN read from the media**, never by file name, and are matched
to the full backup's **FamilyGUID** so that log backups left behind by a previous database of the
same name are ignored rather than blowing up the restore with error 3154.

Which logs to apply is ultimately decided by SQL Server itself:

* **4326** — *"the log terminates too early"* → already applied, skip it.
* **4305** — *"the log begins too recently"* → a genuine gap. The run stops and tells you a log
  backup is missing from the share, almost always because another job is backing up these
  databases' logs somewhere else. Preflight warns about exactly this before any data moves.

Because of that, the tool does not depend on its own bookkeeping being correct. Delete the state
file, clear `msdb` history — it still converges.

---

## Idempotency and resume

* The distributed AG is created only if it does not exist; the forwarder joins only if it has not.
* A database already joined to the forwarder AG is skipped.
* A **completed full backup is reused** rather than retaken — the single biggest win when a
  multi-terabyte seed is interrupted. It is only reused when every stripe is still present, the
  media reads back, and it belongs to the current recovery fork of the source database.
* A full backup already applied to a target (restored LSN ≥ the backup's LastLSN) is not re-restored.
* The script refuses to overwrite a database that is ONLINE on a forwarder replica.

`DAG\state\<DagName>.json` records the plan so a resume does not re-interview you. It is a **hint,
never the source of truth**: delete it and the next run re-reads everything from the servers.

---

## Failing over, when you are ready

1. Stop application traffic against the global primary.
2. Set **both** member AGs to `SYNCHRONOUS_COMMIT` (run on the global primary *and* the forwarder
   primary) and wait for the forwarder to report `SYNCHRONIZED`.
3. On the global primary: `ALTER AVAILABILITY GROUP [<dag>] SET (ROLE = SECONDARY);`
4. On the forwarder primary: `ALTER AVAILABILITY GROUP [<dag>] FORCE_FAILOVER_ALLOW_DATA_LOSS;`

`FORCE_FAILOVER_ALLOW_DATA_LOSS` is the only supported failover for a distributed AG. With both
sides synchronized and traffic stopped, there is nothing to lose. Step 7 of the script prints these
commands filled in with your names.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Forwarder never reaches `CONNECTED` | `LISTENER_URL` must use the **endpoint** port (usually 5022), not the listener's TDS port (1433). Also check endpoint `CONNECT` grants and firewalls. |
| `Log chain gap ... error 4305` | Another job is taking log backups of these databases elsewhere. Find the missing log, or restart the seed with a fresh full backup. |
| Forwarder secondaries stay empty | Expected on a cross-version DAG with automatic seeding. Use manual seeding, or wait for failover. |
| Seeding never starts on the forwarder | `ALTER AVAILABILITY GROUP [<forwarder>] GRANT CREATE ANY DATABASE` — preflight does this for you. |
| `sys.dm_hadr_automatic_seeding` shows `FAILED` | Transient failures are normal and are retried. The script only fails a database that has no successful attempt at all. |

Logs are written to `DAG\logs\Initialize-DAG_<timestamp>.log`.

---

## Layout

```
DAG\
  Initialize-DAG.ps1          entry point: interview, plan, orchestrate
  steps\
    00Preflight.ps1           validate + repair prerequisites
    01BuildPlan.ps1           all user interaction lives here
    02EnsureAGDatabases.ps1   seeding modes; add databases to the global primary AG
    03CreateDAG.ps1           create the DAG, join the forwarder
    04SeedAutomatic.ps1       automatic seeding + progress
    05SeedManual.ps1          backup / restore / log replay / join
    06Finalize.ps1            converge on asynchronous commit
    07HealthRollup.ps1        health summary and next steps
    _shared\
      DagCommon.ps1           logging, T-SQL quoting, retry, waits
      DagSql.ps1              connections; long ops with percent-complete
      DagPrompt.ps1           numbered menus
      DagDiscovery.ps1        topology, versions, database eligibility
      DagFileOps.ps1          server-side file operations on the share
      DagBackupRestore.ps1    striped backups, MOVE, LSN-aware log chain
      DagAgentJob.ps1         the log backup job
      DagHealth.ps1           health rollup and seeding progress
      DagState.ps1            durable plan + per-database progress
```
