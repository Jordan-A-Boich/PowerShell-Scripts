# AG

End-to-end creation and day-two management of SQL Server **Always On availability groups** on
an existing Windows Server Failover Cluster.

| Script | What it does |
|---|---|
| `Initialize-AG.ps1` | Creates a new AG from scratch: endpoints, the AG, the secondaries joining it, the listener, read-only routing, and seeding of the databases you pick. |
| `Add-AGDatabase.ps1` | Adds databases to an existing AG with the same checks, repairs and seeding engine. |
| `Remove-AGDatabase.ps1` | Takes databases out of an AG, or out of chosen secondaries only, and decides what happens to the secondary copies. |

You type one thing — an instance name. Everything else is discovered from the servers and
offered as a numbered menu with a default on ENTER, and you can still type your own value
wherever one makes sense. Answer the interview, confirm the plan, and the rest is unattended.

The seeding, backup/restore and file-placement engine is the one from `..\DAG`, carried over
function for function: the same throttled automatic seeding, the same striped manual seeding
with log-chain catch-up, the same file layout chooser and placement board.

---

## Requirements

* Windows PowerShell 5.1 or PowerShell 7+
* The [`SqlServer`](https://www.powershellgallery.com/packages/SqlServer) module
  (`Install-Module SqlServer -Scope CurrentUser`)
* `sysadmin` on every replica
* A working WSFC with every replica's node in it, and Always On enabled on each instance
  (`Enable-SqlAlwaysOn -ServerInstance <name> -Force` — restarts SQL Server)
* For manual seeding: a share the SQL Server **service account** on every replica can read and
  write. All file work is done by SQL Server itself, so the machine running the script never
  needs to see the share.

> Save these files as **UTF-8 with a BOM** (`..\.editorconfig` enforces it). They contain em
> dashes, and Windows PowerShell 5.1 misreads a BOM-less UTF-8 file.

---

## Initialize-AG.ps1

```powershell
.\Initialize-AG.ps1                 # interview, plan, run
.\Initialize-AG.ps1 -HealthOnly     # health rollup of any existing AG
.\Initialize-AG.ps1 -Credential $c  # SQL login, no auth prompt
```

### The interview

| Question | How it is answered |
|---|---|
| Authentication | Windows integrated or a SQL login |
| The primary | **The one thing you type**: the instance that holds the databases today |
| Secondary replicas | Every other cluster node is probed (reachable? sysadmin? Always On? version?) and offered by number. Unusable ones are listed with the reason and the fix. A differently-named instance can be added by name. |
| AG name | Default `AG<n>`, the first name not already used anywhere in the cluster |
| Kind | STANDARD, or CONTAINED when every replica is SQL Server 2022+. Standard Edition is detected and the AG is made BASIC automatically (two replicas, one database). |
| Failover roles | "Which replicas are synchronous with automatic failover?" then "which of the rest are synchronous with manual failover?"; the remainder are asynchronous. Version limits are enforced (3 synchronous / 3 automatic before 2019, 5 / 5 from 2019), and the primary is added to the automatic set when you forget it. |
| Readable secondaries | No / read-intent only / all connections |
| Backup preference | Prefer secondary / secondary only / primary / any |
| Everything else | Shown with the recommended values — failure condition 3, health check 30 s, DB_FAILOVER ON, DTC none, required synchronized secondaries 0, session timeout 10 s, FQDN endpoint URLs. ENTER takes them all, or step through each as a menu. |
| Listener | Now or later. Name defaults to `<AG>-LSN` and is checked against NetBIOS rules, the cluster's own names, and DNS. Port defaults to the instances' own. **One IP per subnet**: subnets come from the cluster, and a multi-subnet cluster is called out with what that means for clients. Each address is checked to be inside its subnet and pinged to make sure nothing already answers on it. DHCP is offered for a single subnet only. |
| Read-only routing | Offered when a listener is created and secondaries are readable |
| Databases | Every database on the primary, with size and what it still needs. Ones that cannot join are listed with the reason. `none` creates the AG empty. |
| Seeding | AUTOMATIC or MANUAL (see below) |
| Repairs | Asked only for what the chosen databases need — see *Prerequisites* |
| Contained AG logins | For a contained AG: the logins the databases' users map to, offered for copying into the AG |

Nothing is changed until the plan has been printed and you have said yes.

### What a run does

1. **Preflight**: every replica reachable, sysadmin, Always On on, one cluster, versions in the right
   direction; the AG name free in the cluster; endpoints usable; each database still eligible;
   for automatic seeding, every directory the seed will write to on each secondary (created when
   missing) and the free space; for manual seeding, the share writable from **every** replica, Agent
   running, every destination directory created, and a warning if another job is taking log backups
   of these databases elsewhere. Warnings are shown together and you decide.
2. **Prepare** the databases: the repairs you agreed to.
3. **Endpoints**: a missing mirroring endpoint is created (`Hadr_endpoint`, NEGOTIATE, AES, owned by
   `sa`, on the port the other replicas use); a stopped one is started. Each replica's service
   account gets `CONNECT` on every peer's endpoint (virtual accounts resolve to `DOMAIN\MACHINE$`).
   `AlwaysOn_health` is started everywhere and set to start with the instance.
4. **Create** the AG empty on the primary, **join** each secondary, `GRANT CREATE ANY DATABASE` where
   automatic seeding needs it, and wait for every secondary to be `CONNECTED`.
5. **Listener**. If it cannot be created — almost always the cluster name object lacking rights in
   Active Directory — the run says exactly what to fix, prints the statement, and **carries on**:
   the AG does not need its listener to seed.
6. **Seed** the databases.
7. **Finalize**: read-only routing, contained logins, the seeding log backup job's future, a
   **health rollup**, and what to do next (connection strings, `MultiSubnetFailover=True`, backup
   advice, `HostRecordTTL` for multi-subnet).

---

## Prerequisites the tools check — and fix

| Finding | Kind | What happens |
|---|---|---|
| SIMPLE / BULK_LOGGED recovery | fixable | Offered: switch to FULL |
| No log chain — never had a full backup (or the recovery model is changing) | fixable | Automatic seeding: offered a full backup now, to a location you pick from the instance's default backup directory, the directories it has recently backed up to, or one you type. Manual seeding: nothing extra — its own full backup starts the chain. |
| `AUTO_CLOSE ON` | fixable | Offered: turn it off |
| A leftover RESTORING copy on a secondary | fixable | Offered: drop it (automatic seeding cannot seed over it) |
| OFFLINE, READ_ONLY | blocker | Not offered, reason shown |
| Already in an AG | blocker | Not offered |
| A different database of the same name ONLINE on a secondary | blocker | Not offered — seeding would overwrite somebody's data |
| TDE certificate missing on a secondary | blocker | Not offered, certificate named |
| FILESTREAM not enabled on a secondary | blocker | Not offered |
| A dropped contained AG's `<AG>_master` / `<AG>_msdb` | blocker | Not offered; recreating that contained AG offers to reuse them |

The log chain is read from the database itself (`sys.database_recovery_status.last_log_backup_lsn`),
never from `msdb` history: history is purged by maintenance, and a COPY_ONLY full — which does not
start a chain — looks like a backup there.

A database you decline to fix is simply left out of the run.

---

## Seeding

**AUTOMATIC** — SQL Server streams each database. The AG is created empty and databases are
added through a **sliding window** (default 3 at a time): the moment one is synchronizing on
every secondary, the next is admitted. A seed that fails or stalls is restarted by re-issuing
`SEEDING_MODE = AUTOMATIC` for that secondary. Trace flag 9567 compresses the stream if you say so,
and is switched back off afterwards if it was off before. Automatic seeding puts each file at the
primary's path — or in the secondary's default directory when the primary's file is in the
primary's default — so preflight makes sure those directories exist.

**MANUAL** — per database: a compressed, checksummed full backup striped across N files (or one
file per share across several file-server nodes), restored `WITH NORECOVERY` on each secondary
where **you** chose, every log backup since applied in LSN order, the log backup job quiesced,
a final log backup taken and applied, then `ADD DATABASE` on the primary and
`SET HADR AVAILABILITY GROUP` on each secondary. A completed full backup is reused on a resume.
It is Initialize-DAG's engine: see `..\DAG\README.md` for the full story of the log-chain
handling, restore receipts and the file placement board.

During manual seeding a log backup job, `AG-TLogBackup-<AG>`, runs on every replica (each copy
only acts while its replica is primary). At the end it is **kept** — it carries on backing those
databases' logs up to the share — or **removed**, your choice. Its database list is additive: a
later Add-AGDatabase run merges into it, and Remove-AGDatabase takes databases back out of it.

### Where the files land (manual seeding)

The same chooser as Initialize-DAG: **reuse** the source layout (missing directories are
created), the targets' **defaults**, or **choose** — all databases together, per database, or per
file, the same on every secondary or different per secondary, on the placement board with a
running total of free space per volume. The destination of every file is printed for approval.

---

## Contained availability groups

* Offered when every replica is SQL Server 2022 or later.
* A contained AG's own `master` and `msdb` can only be seeded automatically, so the AG is
  always created with `SEEDING_MODE = AUTOMATIC`, the run waits for `<AG>_master` and `<AG>_msdb`
  to reach every secondary, and only then switches the replicas to MANUAL if that is what you
  chose for your databases.
* If `<AG>_master` and `<AG>_msdb` survive from a contained AG of the same name that was dropped,
  you are offered `REUSE_SYSTEM_DATABASES`, which keeps that AG's logins and jobs. Stale copies on
  secondaries are dropped so the reused ones can seed.
* Only sysadmin logins are copied into a new contained master. The interview lists the logins the
  chosen databases' users map to and offers to create them inside the AG with the same SID and
  password hash, so applications connecting through the listener keep working.
* A listener is strongly recommended — it is how anything connects *inside* the contained AG.

---

## Add-AGDatabase.ps1

```powershell
.\Add-AGDatabase.ps1
.\Add-AGDatabase.ps1 -Instance SQLLAB-SQL4 -AgName AG1
```

Connect to **any** replica, even a secondary: the AG is picked by number and every primary-side
step runs on the AG's current primary. The secondaries must be CONNECTED. The AG's own seeding
mode is the default, and each replica's original seeding mode is put back afterwards. A Basic AG
that already holds its one database is refused, and an AG that is a distributed AG's member is
pointed out (a database added there also seeds across the DAG).

## Remove-AGDatabase.ps1

```powershell
.\Remove-AGDatabase.ps1
.\Remove-AGDatabase.ps1 -Instance SQLLAB-SQL3 -AgName AG1 -Database Sales01,Sales02 -SecondaryCopies DROP -WhatIf
.\Remove-AGDatabase.ps1 -Instance SQLLAB-SQL3 -AgName AG1 -Database Sales01 -SecondaryReplica SQLLAB-SQL4 -Force
```

| Choice | Options |
|---|---|
| Scope | The whole AG (`REMOVE DATABASE` on the primary), or only chosen secondaries (`SET HADR OFF` there; the database stays in the AG elsewhere) |
| Secondary copies | **LEAVE** in RESTORING — it can rejoin with `ALTER DATABASE … SET HADR AVAILABILITY GROUP` while the primary still has the log it needs; **DROP**; **RECOVER** as an independent read-write copy |

The primary copy is never dropped. The exact statements are printed before anything runs;
`-WhatIf` stops there and `-Force` skips the confirmation. It warns when the AG is a distributed
AG member (removal flows on to the forwarder) or contained (listener connections lose the
contained logins), and takes the databases out of the toolkit's log backup job.

---

## Resume and state

Every step re-reads live server state before it acts, so a re-run never repeats work: an AG
that exists is not re-created, a joined secondary is not re-joined, a database already
synchronizing is skipped, a completed full backup is reused.

An interrupted Initialize-AG or Add-AGDatabase run is offered for **resume** next time — the plan
in `state\<CREATE|ADD>-<AG>.json` saves you the interview. It is a hint, never the source of
truth. A finished plan moves to `state\archive` and is never offered again. Logs are in `logs\`.
Neither folder is committed.

---

## Health rollup

At the end of every run, and on demand with `-HealthOnly`. Replicas (role, modes, connection,
health), every database on every replica (state, health, send and redo queues, suspended), and
the listener's addresses. It **waits for the AG to settle** first (up to 3 minutes) so a replica
still reconnecting, or a database still catching up, is not reported as a fault — while a
suspended database is always a problem, with the statement that resumes it.

---

## Lab

`lab\Reset-AgLab.ps1` tears down every AG named `AGT*` (and the contained system databases and
log backup jobs they leave behind) on the SQLLabBuilder cluster-2 pair, then builds one test
database per scenario: ready, SIMPLE recovery, never backed up, AUTO_CLOSE, a leftover
RESTORING copy on the secondary, a same-name clash, a multi-file database, and one with a SQL
login user for the contained AG. `-TeardownOnly` stops after the teardown.

---

## Layout

```
AG\
  Initialize-AG.ps1          entry point: create an AG end to end
  Add-AGDatabase.ps1         entry point: add databases to an AG
  Remove-AGDatabase.ps1      entry point: remove databases from an AG
  steps\
    01Interview.ps1          every question, for both Initialize-AG and Add-AGDatabase
    02Preflight.ps1          validate, create the directories the seed will need
    03PrepareDatabases.ps1   the agreed repairs
    04CreateAG.ps1           endpoints, CONNECT grants, CREATE / JOIN, contained system databases
    05Listener.ps1           listener, read-only routing
    06SeedAutomatic.ps1      throttled, self-healing automatic seeding
    07SeedManual.ps1         backup / restore / log chain / join
    08Finalize.ps1           contained logins, job, seeding modes, health, next steps
    09RemoveDatabase.ps1     removal
    _shared\
      AgCommon.ps1           logging, quoting, retry, waits          (from DAG)
      AgSql.ps1              connections, long operations             (from DAG)
      AgPrompt.ps1           numbered menus                           (from DAG, + include-selection)
      AgDiscovery.ps1        instance, endpoint, AG topology
      AgCluster.ps1          WSFC, subnets, IP checks, endpoints, service accounts
      AgDatabase.ps1         eligibility, repairs, leftover copies, contained logins
      AgFileOps.ps1          server-side file operations              (from DAG)
      AgFileLayout.ps1       where restored files land                (from DAG)
      AgPlacementBoard.ps1   the placement board                      (from DAG)
      AgBackupRestore.ps1    striped backups, LSN-aware log chain     (from DAG)
      AgAgentJob.ps1         the log backup job, additive scope
      AgHealth.ps1           health rollup with settle wait
      AgState.ps1            plans, resume, archive
  lab\
    Reset-AgLab.ps1          tear down and rebuild the test scenario
```
