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

> **Editing these files:** save them as **UTF-8 with a BOM** (`.editorconfig` enforces it).
> They contain em dashes and curly quotes, and Windows PowerShell 5.1 assumes ANSI for a
> BOM-less file — which mangles those characters and, where one sits inside a string, stops
> the script parsing at all. PowerShell 7 assumes UTF-8 and never notices, so a file saved
> without the BOM breaks 5.1 *silently* until someone runs it there.

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
| Where the data and log files land | Manual seeding only; see below |

Everything after the plan confirmation is unattended.

### Where the restored files land

Manual seeding restores a backup taken on the global primary onto replicas that may not have
the same drives. Automatic seeding places the files itself, so the question is asked only for
manual seeding — once, in the interview:

| Option | What it does |
|---|---|
| **Reuse the layout** | Each file keeps the directory it has on the global primary. Directories that do not exist on a target are **created** there. |
| **Target defaults** | Every data file goes to the target's `InstanceDefaultDataPath`, every log file to its `InstanceDefaultLogPath`. |
| **Choose where they land** | You pick the directories, at whichever precision the job needs — see below. |

Before it asks, it shows you both sides: the source databases grouped by database with every
file and its size, and then, per replica being restored onto, every directory that replica
could take them — the directories its databases already use, its instance defaults, folders
that already exist on its volumes, and the volume roots — each with free space.

#### Choosing where they land

Consolidating a sprawling source layout onto a tidier target is the usual reason to touch this
at all, so **Choose** has two independent axes.

**How precisely** you want to place them:

| Precision | What you answer |
|---|---|
| **All databases together** | One data directory and one log directory for every file. Two questions. |
| **Per database** | Each database's data files go to one directory and its log files to another, spread across as many directories as you name. Answered on the placement board (below). |
| **Per file** | The same board with one row per file, so one database's data files can be split across several locations. |

**Whether the replicas differ.** Asked only when more than one replica is being restored onto,
and defaulting to "the same on every replica", which is almost always what a forwarder AG with
matching drive letters wants. Answer "different per replica" and each one is asked separately.

So a target AG with `E:\Data`, `F:\Data` and `G:\Data` for data and `L:\Log` and `M:\Log` for
logs can send `Database1` to `E:\Data` + `L:\Log` and `Database2` to `G:\Data` + `M:\Log`
(per database), or spread `Database1`'s three data files across all three data locations
(per file).

At **all databases together**, each directory is picked from a **numbered menu** of what that
replica actually has, annotated with how many database files are already there and how much room
is left on the volume. The last entry always lets you type a path that does not exist yet:
preflight creates it.

#### The placement board (per database and per file)

Thirty databases used to be sixty separate menus, with the free space of every drive kept in
your head. Instead:

1. **Pick the pools.** Once for data and once for log files, choose by number *every* directory
   those files may go to: `2,3,4` for three data drives, `5,6` for two log drives. Each candidate
   shows its free space. When one set of answers is used on several replicas, the figure is the
   **smallest** any of them reports, and a drive that one of them does not have is flagged
   `NOT on <replica>` right there.
2. **Automatic first draft.** Every database is spread across its pool largest first, each onto
   whichever destination's **volume** keeps the most room. Unequal drives are filled in
   proportion, so a 6 TB volume takes work before a 500 GB one does.
3. **Adjust on one screen.** The board lists every database with its sizes and destination, then
   a running ledger: what each destination holds, and per volume the free space now, what is
   assigned and what is left after, with a fill bar. Directories that share a volume share its
   free space, and data and log on the same disk are counted together. A volume that would
   overflow is marked `<< OVER`.

```
   #  Database              Data -> to            Log -> to
   1  App01            107.00 MB -> D3       22.00 MB -> L1
   2  App02            280.00 MB -> D2       10.00 MB -> L1
  ...
  23  Sales01          163.00 MB -> D3*      32.00 MB -> L1
  * placed by you - "auto" leaves these alone

  Destinations
    D1   E:\Data       data    9 db(s)     1.82 GB
    D2   F:\Data       data    9 db(s)     1.83 GB
    D3   G:\Data       data   10 db(s)     1.85 GB
    L1   H:\Log        log    14 db(s)   332.00 MB
    L2   I:\Log        log    14 db(s)   332.00 MB

  Volumes  (directories on one volume share its space - free is the smallest of SQLLAB-SQL7, SQLLAB-SQL8)
                                    free now     assigned   left after
    E:   [#############.......]      2.96 GB      1.82 GB      1.15 GB   D1
    F:   [#############.......]      2.96 GB      1.83 GB      1.13 GB   D2
    G:   [#############.......]      2.96 GB      1.85 GB      1.12 GB   D3
    H:   [##############......]    479.00 MB    332.00 MB    147.00 MB   L1
    I:   [##############......]    479.00 MB    332.00 MB    147.00 MB   L2
Board:
```

Commands. Separate row numbers with commas or spaces; case does not matter.

| Command | Effect |
|---|---|
| `3 D2` / `1-5,9 L1` | Send those rows' data (a `D` destination) or log (an `L` destination) files there |
| `4 D3 L2` | Data and log in one go |
| `Sales* D1` | Every row whose database (or, per file, logical file) name matches the wildcard |
| `D1 D3` | Everything currently on D1 moves to D3: drain a drive |
| `all D2` | Every data file to D2. A `D` destination never takes log files, and an `L` destination never takes data files |
| `auto` | Rebalance everything you have **not** placed yourself, around what you have |
| `auto 10-28` / `auto all` | Re-plan exactly those rows, or every row, including ones you placed |
| `add data` / `add log` | Add another directory to a pool from the replica's menu |
| `remove D2` | Take a destination out; what was on it is rebalanced across the rest of its pool |
| `keep 3` | Leave those files in the directory they have today |
| `undo` | Take back the last change, any number of times |
| `?` | List the commands |
| ENTER | Finished |

Anything you place yourself (with a move or `keep`) is marked `*` in the table and **pinned**:
a bare `auto` balances everything else around it, so `Sales* D3` followed by `auto` keeps the
Sales databases on D3 and spreads the rest over what is left.

Finishing is refused while two files would land on the same path. Finishing with a volume over
capacity asks first, because a thin-provisioned or soon-to-be-extended volume is a legitimate
reason to go ahead.

With **different directories per replica**, the second replica's board can start from the
first one's assignments, so only the differences need changing.

The replica-level fallback recorded in the plan (see *How a destination is decided*) is the
destination in each pool with the most room left.

Nothing is committed from the answers alone. The destination of **every file on every replica**
is resolved and printed back, with the total being written to each volume against its free
space, and you either accept it or answer the question again:

```
Where the files will land — directories CHOSEN for this run
  SQLLAB-SQL7, SQLLAB-SQL8
      MigrationDB1
          MigrationDB1               data       -> D:\Data\MigrationDB1.mdf
          MigrationDB1_dat2          data       -> D:\Data2\MigrationDB1_dat2.ndf
          MigrationDB1_dat3          data       -> D:\Data3\MigrationDB1_dat3.ndf
          MigrationDB1_log           log        -> D:\Log\MigrationDB1_log.ldf
      MigrationDB2               data -> D:\Data3    log -> D:\Log2
      D:    288.00 MB of database files -> 19.90 GB free
```

A database whose files all land in one data directory and one log directory is summarised as
that single line; one whose files are split is listed file by file. Replicas whose files resolve
to exactly the same paths are listed once, with the volume totals still shown for each.

#### How a destination is decided

At restore time the file list comes from the backup media, not from the layout captured when the
plan was built, and each file walks four levels — most specific first, every level allowed to be
absent:

1. a destination recorded for **this exact file** (matched by logical name)
2. the directories recorded for **its database**
3. the directories recorded for **its replica**
4. the replica's **instance defaults**

Level 3 is always populated, whatever precision you chose. That is what catches a file added to
the database after the plan was built: it has no destination of its own, so it lands in that
replica's chosen data or log directory rather than failing the restore.

#### What preflight proves

Before any data moves, every directory the restores will need is probed on every target and
created if missing. A path no target can satisfy — `E:\SQLData` on a server with no `E:` drive —
fails there, in seconds, naming the alternatives, rather than hours into a restore.

It also catches **two files resolving to the same path** on one replica, which the flattening
precisions make easy to do by accident: two databases whose files live in different source
directories can share a file *name*. SQL Server would restore the first and refuse the second,
after the full backup had already been taken and shipped. Preflight names both files and tells
you to give one of them a destination of its own.

Finally it reports how much each volume is being asked to hold against what it has free. That is
a **warning, never a failure** — a volume that cannot hold today's file sizes is worth saying out
loud, and is also routinely thin-provisioned or about to be extended, so it stays the operator's
call.

### Other switches

```powershell
.\Initialize-DAG.ps1 -HealthOnly            # health rollup for a configured DAG
.\Initialize-DAG.ps1 -RemoveLogBackupJob    # remove the log backup job created for manual seeding
.\Initialize-DAG.ps1 -SeedTimeoutHours 48   # how long to wait for one database to seed (default 24)
.\Initialize-DAG.ps1 -Credential $cred      # supply a SQL login for unattended runs
```

`-RemoveLogBackupJob` picks the job from a saved plan, so run it **before** clearing that plan out
with `Manage-Plans.ps1` — or let `Manage-Plans.ps1` remove the job itself, which it does for every
plan you select.

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
   putting the data and log files where you said they should go.
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

## Clearing out old plans

Both entry points offer **every** file in `DAG\state`, and neither checks that the distributed AG
still exists — so a DAG you tore down keeps turning up in the menu, pointing at servers and
databases that may be long gone. `Manage-Plans.ps1` probes each saved plan against the live
servers and clears the dead ones out by number:

```powershell
.\Manage-Plans.ps1                 # probe, then pick: 1,3,4 or 1-3 or all
.\Manage-Plans.ps1 -ListOnly       # just show what is saved and what state it is in
.\Manage-Plans.ps1 -Delete         # delete the plan files instead of archiving them
.\Manage-Plans.ps1 -RemoveBackups  # also delete each plan's <share>\<DagName> backup folder
```

```
  [1] AG-DISTLAB                  GONE       SQLLabAG -> SQLLabAG2, 3 database(s)
      replicas 4/4 reachable  ·  member AG(s) still present: SQLLabAG, SQLLabAG2  ·  saved 2026-08-21
  [2] TEST-DAG                    LIVE       SQLLabAG -> SQLLabAG2, 3 database(s)
      replicas 4/4 reachable  ·  DAG live on SQLLAB-SQL1, SQLLAB-SQL2, ...  ·  saved 2026-09-06
  [3] VANISHED-DAG                ORPHAN     log backup job with no saved plan
```

`GONE` means no reachable replica has that distributed AG — safe to clear. `UNKNOWN` means none of
its replicas answered, so nothing could be checked; it is never reported as gone. `LIVE` means the
DAG still exists and needs a second confirmation, since forgetting its plan is legal but rarely
what you meant. `ORPHAN` is a `DAG-TLogBackup-*` job on a probed server that no saved plan accounts
for — what a hand-deleted plan file leaves behind, still taking log backups on a schedule and still
breaking the log chain of whatever else backs those databases up.

For each item you select it removes what would still reference it: the plan file (archived to
`state\archive`, which neither script enumerates, or deleted with `-Delete`) and the
`DAG-TLogBackup-<DagName>` job on every replica that still has it. **It changes nothing else in SQL
Server** — no distributed AG, availability group or database is dropped. To tear a lab DAG down,
use `lab\Reset-DagLab.ps1`.

---

## Failing over, when you are ready

Use `Failover-DAG.ps1`. It is prompt-driven like `Initialize-DAG.ps1`, and it does the whole
sequence: synchronous commit, a synchronization and LSN rollup, a GO / NO-GO recommendation, the
failover itself, then back to asynchronous commit and a health rollup.

```powershell
.\Failover-DAG.ps1                # interview, readiness rollup, then ask before failing over
.\Failover-DAG.ps1 -ReadinessOnly # dry run: rollup only, changes nothing
.\Failover-DAG.ps1 -SettleTimeoutSeconds 300   # allow longer for the new shape to reconnect
```

Stop application traffic against the global primary first. Everything else it handles.

**The final rollup waits before it judges.** A failover is not finished the moment the role moves:
the link between the two clusters drops and re-establishes, the new primary's own secondaries
reconnect to a replica that has just changed role, and the per-database rows in
`sys.dm_hadr_database_replica_states` are rebuilt — reading `NOT SYNCHRONIZING` with a hardened LSN
of `0` until they are. Read a second after the failover, all of that looks like a wall of failures
that is gone by the time you look again. Step 6 therefore polls until the new shape has actually
settled (`-SettleTimeoutSeconds`, default 180) and only then decides what to call a problem. If the
window expires, what is still outstanding is reported as **not finished reconnecting**, not as a
fault — while states that never clear on their own, such as suspended data movement or a database
that is not online, are always reported as problems, with the statement that fixes them.

**Which side is primary is always read from the servers**, never from the saved plan — a failover
is precisely the thing that changes it, so a tool that trusted the file would fail the DAG over in
the direction it has already gone.

### Why the forced failover is not lossy

`FORCE_FAILOVER_ALLOW_DATA_LOSS` is the only failover a distributed AG accepts — there is no
planned-failover form of the statement. Whether it loses data is a property of the **state you run
it in**, not of the statement:

* against a `SYNCHRONIZED` DAG whose global primary has already been demoted and is accepting no
  writes, there is nothing left to lose;
* against an asynchronous or lagging DAG, it does exactly what it says, silently.

The script exists to guarantee the first case, and to stop if it cannot. If you do it by hand:

1. Set **both** member AGs to `SYNCHRONOUS_COMMIT` (run on the global primary *and* the forwarder
   primary) and wait for the forwarder to report `SYNCHRONIZED`.
2. On the global primary: `ALTER AVAILABILITY GROUP [<dag>] SET (ROLE = SECONDARY);`
3. On the forwarder primary: `ALTER AVAILABILITY GROUP [<dag>] FORCE_FAILOVER_ALLOW_DATA_LOSS;`

Both statements name the **distributed** group, not the member AG. Which side each one acts on is
decided by which replica you run it against — naming the member AG in step 2 fails with `Msg 19512`.

### Two things to know

**A cross-version failover is one way.** Bringing the databases online on the higher version
upgrades their files, and from that moment the older side can no longer apply their log. The old
primary becomes a dead end you decommission, not a standby you can return to. The script warns you
before it happens, and refuses outright to fail over to an *older* version.

**Between the demotion and the failover, the DAG has no primary** and the databases are offline on
both sides. The window is short, but if a run dies inside it, re-run the script: it recognises the
state and asks which member should take the primary role — finishing the failover, or putting it
back where it was. Both are safe there, because nothing has been upgraded yet.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Forwarder never reaches `CONNECTED` | `LISTENER_URL` must use the **endpoint** port (usually 5022), not the listener's TDS port (1433). Also check endpoint `CONNECT` grants and firewalls. |
| `Log chain gap ... error 4305` | Another job is taking log backups of these databases elsewhere. Find the missing log, or restart the seed with a fresh full backup. |
| Forwarder secondaries stay empty | Expected on a cross-version DAG with automatic seeding. Use manual seeding, or wait for failover. |
| Seeding never starts on the forwarder | `ALTER AVAILABILITY GROUP [<forwarder>] GRANT CREATE ANY DATABASE` — preflight does this for you. |
| `sys.dm_hadr_automatic_seeding` shows `FAILED` | Transient failures are normal and are retried. The script only fails a database that has no successful attempt at all. |

Logs are written to `DAG\logs\Initialize-DAG_<timestamp>.log` and
`DAG\logs\Failover-DAG_<timestamp>.log`.

---

## Layout

```
DAG\
  Initialize-DAG.ps1          entry point: interview, plan, orchestrate
  Failover-DAG.ps1            entry point: readiness rollup, go / no-go, fail over
  Manage-Plans.ps1            entry point: probe saved plans, clear the dead ones out
  steps\
    00Preflight.ps1           validate + repair prerequisites
    01BuildPlan.ps1           all user interaction lives here
    02EnsureAGDatabases.ps1   seeding modes; add databases to the global primary AG
    03CreateDAG.ps1           create the DAG, join the forwarder
    04SeedAutomatic.ps1       automatic seeding + progress
    05SeedManual.ps1          backup / restore / log replay / join
    06Finalize.ps1            converge on asynchronous commit
    07HealthRollup.ps1        health summary and next steps
    failover\
      01Context.ps1           which DAG, and which way round (read from the servers)
      02Preflight.ps1         the failovers that must not be attempted at all
      03Synchronize.ps1       synchronous commit, and wait for it to take effect
      04Readiness.ps1         synchronization + LSN rollup; the GO / NO-GO call
      05Failover.ps1          demote, force the failover, confirm the role moved
      06Settle.ps1            back to asynchronous commit; settle wait; post-failover health
    _shared\
      DagCommon.ps1           logging, T-SQL quoting, retry, waits
      DagSql.ps1              connections; long ops with percent-complete
      DagPrompt.ps1           numbered menus
      DagDiscovery.ps1        topology, versions, database eligibility
      DagFileOps.ps1          server-side file operations on the share
      DagFileLayout.ps1       where restored data and log files land; the MOVE clauses
      DagBackupRestore.ps1    striped backups, LSN-aware log chain
      DagAgentJob.ps1         the log backup job
      DagHealth.ps1           health rollup and seeding progress
      DagFailover.ps1         live role discovery, sync state, the failover statements
      DagState.ps1            durable plan + per-database progress
```
