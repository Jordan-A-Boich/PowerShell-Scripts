# SQLLabBuilder — LLM Prompt
> Paste everything below this line into your LLM of choice.

---

You are an expert PowerShell and Windows infrastructure engineer. Your task is to generate a complete, production-quality set of PowerShell scripts that automate the end-to-end creation of a local Hyper-V SQL Server Always On Availability Group lab environment. All scripts must live in a folder called `SQLLabBuilder` and be designed to run on a Windows host machine with Hyper-V enabled — without causing any harm to the host system.

---

## Project Structure

Generate the following files inside `SQLLabBuilder\`:

```
SQLLabBuilder\
├── Start-LabBuild.ps1         # Main runner / orchestrator
├── Teardown-Lab.ps1           # Full teardown script
├── config.ps1                 # Centralized config (names, IPs, passwords, paths)
├── steps\
│   ├── 00-Preflight.ps1
│   ├── 01-SelectDrive.ps1
│   ├── 02-DownloadISOs.ps1
│   ├── 03-CreateVMSwitch.ps1
│   ├── 04-CreateVMs.ps1
│   ├── 05-UnattendedWindowsSetup.ps1
│   ├── 06-ConfigureNetworking.ps1
│   ├── 07-PromoteDomainController.ps1
│   ├── 08-JoinDomainMembers.ps1
│   ├── 09-CreateCluster.ps1
│   ├── 10-CreateSQLServiceAccount.ps1
│   ├── 11-InstallSQL.ps1
│   ├── 12-EnableAGFeature.ps1
│   ├── 13-ConfigureAG.ps1
│   ├── 14-ConfigureHostAccess.ps1
│   └── 15-SummaryReport.ps1
└── logs\
    └── (auto-generated per run)
```

---

## Strict Requirements

### General / Cross-Cutting

- **Fully idempotent**: Every step must check whether its work is already done before doing it. Re-running the full script from scratch on an already-built environment must be safe and produce no errors, duplicates, or unintended changes.
- **Modular step files**: `Start-LabBuild.ps1` is the only entry point the user runs. It dot-sources `config.ps1` and then calls each step script in order, passing context through shared variables defined in config.
- **Logging**: Every step must write structured, timestamped output to the console using a `Write-Log` function (e.g. `[2025-05-10 14:32:01] [INFO] Creating VM switch...`). Use color coding — green for success, yellow for warnings/skips, red for errors. All console output must also be written to a log file at `$LabRoot\logs\lab-build-<timestamp>.log`.
- **Error handling**: Wrap all critical operations in `try/catch`. On failure, log the error with full detail and halt the run cleanly. Never silently swallow errors.
- **No host harm**: Do not modify host DNS, host domain membership, host firewall rules (beyond what is needed for SSMS access from the host), host network adapters (beyond adding a NAT/internal switch), host registry, or any host system files.
- **Elevation check**: At startup, verify the script is running as Administrator and exit with a clear message if not.
- **Hyper-V check**: Verify Hyper-V is installed and the `Hyper-V` and `Hyper-V PowerShell` Windows features are enabled. If not, prompt the user with instructions and exit gracefully.

---

### Parameters for `Start-LabBuild.ps1`

```powershell
param(
    [ValidateSet("2022","2025")]
    [string]$SQLVersion = "2022",

    [switch]$Teardown,

    [switch]$Force   # Used with -Teardown to skip confirmation
)
```

- If `-Teardown` is passed, hand off to `Teardown-Lab.ps1` immediately (described below).
- Otherwise, proceed with the full build.

---

### Step 01 — Drive Selection

- Use `Get-PSDrive` or `Get-Volume` to enumerate all **fixed, NTFS-formatted drives** available on the host.
- Display a numbered list to the user, showing drive letter, label, total size, and free space.
- Prompt the user: *"Enter the number of the drive you want to use for the lab:"*
- Validate the input. If invalid, re-prompt.
- Set `$LabRoot = "<SelectedDrive>:\SQLLabBuilder"` and create the folder if it doesn't exist.
- Store `$LabRoot` in `config.ps1` (or a shared session variable) so all subsequent steps use it as the base path.
- Also store sub-paths: `$ISOPath`, `$VMPath`, `$LogPath` derived from `$LabRoot`.

---

### Step 02 — ISO Download

Download ISOs only if they are not already present (idempotent). Use `Start-BitsTransfer` with progress display.

- **Windows Server 2025 Evaluation ISO**: Download from Microsoft's official evaluation center URL. If the direct URL is subject to change, generate a comment in the script noting that the user may need to update the URL, and provide instructions for where to obtain it (`https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025`). Use the most current known direct download URL.
- **SQL Server ISO**:
  - If `$SQLVersion -eq "2022"`: Download SQL Server 2022 Evaluation ISO from Microsoft's evaluation center.
  - If `$SQLVersion -eq "2025"`: Download SQL Server 2025 Evaluation ISO from Microsoft's evaluation center.
  - Include a comment noting the URL may need refreshing and where to find it.
- Verify file size / hash after download where possible. Log download completion with file size.

---

### Step 03 — VM Switch

- Create an **Internal** Hyper-V switch named `SQLLabSwitch` if it does not already exist.
- Create a **NAT network** (`New-NetNat`) named `SQLLabNAT` on subnet `192.168.100.0/24` if it does not already exist.
- Assign the host vEthernet adapter for `SQLLabSwitch` a static IP of `192.168.100.1` / prefix length 24 if not already set.
- This subnet is fully isolated to the lab — it must not interfere with the host's primary network adapters or existing NAT configurations.

---

### Step 04 — VM Creation

Create three VMs with the following specs. Check if each VM already exists before creating.

| VM   | Name           | vCPUs | RAM (Max) | Disk                              | Role              |
|------|----------------|-------|-----------|-----------------------------------|-------------------|
| DC   | `SQLLab-DC`    | 2     | 2 GB      | 60 GB (dynamic)                   | Domain Controller |
| SQL1 | `SQLLab-SQL1`  | 2     | 4 GB      | 80 GB OS + 40 GB data (dynamic)   | SQL Replica 1     |
| SQL2 | `SQLLab-SQL2`  | 2     | 4 GB      | 80 GB OS + 40 GB data (dynamic)   | SQL Replica 2     |

- Use **Generation 2** VMs.
- Enable **Dynamic Memory** with the above values as maximum. Set minimum RAM to 512 MB for DC, 1 GB for SQL nodes.
- Use **Secure Boot** (template: `MicrosoftWindows`).
- Attach the Windows Server 2025 ISO to each VM's DVD drive.
- Connect all VMs to `SQLLabSwitch`.
- Store VHDX files under `$VMPath\<VMName>\`.
- For SQL VMs, create a second VHDX (`SQLData.vhdx`, 40 GB dynamic) for SQL data files and attach it.

---

### Step 05 — Unattended Windows Setup

- Generate an `unattend.xml` (Windows answer file) for each VM that performs a fully unattended install of **Windows Server 2025 Standard (Desktop Experience)**, sets the Administrator password, sets the computer name, sets the locale/timezone, and auto-logs in once to complete setup.
- Inject the answer file into each VM's VHDX using `Mount-VHD`, copying `unattend.xml` to the correct path, then unmounting. Do this before first boot.
- All three VMs should use the **same Administrator password**, stored in `config.ps1` as `$AdminPassword`. Generate a strong default password and note it clearly.
- Computer names: `SQLLAB-DC`, `SQLLAB-SQL1`, `SQLLAB-SQL2`.

---

### Step 06 — Static IP Configuration

After first boot (use a wait-and-poll loop via `Invoke-Command` over VMBus / `Get-VMIntegrationService` readiness check, not arbitrary `Start-Sleep`), configure static IPs inside each VM via PowerShell Direct:

| VM          | IP               | Gateway         | DNS              |
|-------------|------------------|-----------------|------------------|
| SQLLAB-DC   | 192.168.100.10   | 192.168.100.1   | 127.0.0.1        |
| SQLLAB-SQL1 | 192.168.100.11   | 192.168.100.1   | 192.168.100.10   |
| SQLLAB-SQL2 | 192.168.100.12   | 192.168.100.1   | 192.168.100.10   |

- Disable IPv6 on all VM adapters.
- Set the host `vEthernet (SQLLabSwitch)` adapter's DNS to `192.168.100.10` so that the host can resolve the lab domain for SSMS connectivity. Do this carefully — only add it, do not replace the host's existing DNS servers.

---

### Step 07 — Domain Controller Promotion

Via PowerShell Direct on `SQLLAB-DC`:

- Install `AD-Domain-Services` role.
- Run `Install-ADDSForest` with domain name `sqllab.local`, NetBIOS name `SQLLAB`, safe mode password same as `$AdminPassword`.
- Wait for DC promotion to complete and VM to reboot.
- Poll until AD web services are responding before proceeding.

---

### Step 08 — Domain Join

Via PowerShell Direct, join `SQLLAB-SQL1` and `SQLLAB-SQL2` to `sqllab.local`. Reboot each after joining. Poll until each VM is back online and domain-joined before proceeding.

---

### Step 09 — Windows Failover Cluster

Via PowerShell Direct on `SQLLAB-SQL1` (as a domain admin):

- Install `Failover-Clustering` and `RSAT-Clustering` features on both SQL VMs.
- Run `Test-Cluster` (skipping storage and network tests that aren't relevant) and log results.
- Create the cluster: `New-Cluster -Name SQLLabCluster -Node SQLLAB-SQL1,SQLLAB-SQL2 -StaticAddress 192.168.100.20 -NoStorage`.
- Configure the cluster quorum to use a **File Share Witness** hosted on the DC at `\\SQLLAB-DC\ClusterWitness`. Create the share on the DC first and grant the cluster computer account full control.

---

### Step 10 — SQL Service Account

Via PowerShell Direct on `SQLLAB-DC`:

- Create a domain user `sqllab\sqlsvc` with a strong password (stored in `config.ps1` as `$SQLServiceAccountPassword`).
- Set the account to **password never expires**.
- Grant `sqlsvc` the `Log on as a service` right on both SQL VMs using `secedit` or a GPO approach via PowerShell.

---

### Step 11 — SQL Server Installation

On both `SQLLAB-SQL1` and `SQLLAB-SQL2` via PowerShell Direct:

- Mount the SQL ISO, run `setup.exe` with a fully silent `ini`-style config or command-line flags:
  - Features: `SQLENGINE,REPLICATION,FULLTEXT`
  - Instance: `MSSQLSERVER` (default)
  - Service accounts: use `sqllab\sqlsvc` for both SQL Engine and SQL Agent
  - Data/log/backup directories: point to the second VHDX (initialize and format it as `D:\` first inside the VM if not already formatted)
  - Auth mode: Mixed (SQL + Windows), SA password stored in `config.ps1` as `$SAPassword`
  - Add `SQLLAB\Domain Admins` as a sysadmin
  - Collation: `SQL_Latin1_General_CP1_CI_AS`
- Wait for setup to complete. Parse the setup log to confirm success.
- Enable TCP/IP protocol on port 1433 via the `SqlServer` WMI provider or registry.
- Open Windows Firewall on port 1433 and port 5022 (for the AG endpoint) on both SQL VMs.
- Restart SQL Server service after configuration.

---

### Step 12 — Enable Always On AG Feature

On both SQL VMs:

- Enable the Always On Availability Groups feature via `Enable-SqlAlwaysOn` (using the `SqlServer` PowerShell module, which should be installed as part of setup or installed separately if needed) or via WMI/registry.
- Restart the SQL Server service.

---

### Step 13 — Configure the Availability Group

On `SQLLAB-SQL1` (primary):

- Create a test database `AGTestDB`, set recovery model to FULL, take a full backup to a shared UNC path on the DC (`\\SQLLAB-DC\AGShare` — create and permission this share).
- Create the AG endpoint on both nodes (port 5022).
- Create the Availability Group `SQLLabAG` with:
  - Primary: `SQLLAB-SQL1`
  - Secondary: `SQLLAB-SQL2`
  - Listener: `SQLLabListener` on IP `192.168.100.30`, port `1433`
  - Availability mode: `SynchronousCommit`
  - Failover mode: `Automatic`
- Add `AGTestDB` to the AG.
- Restore the backup on `SQLLAB-SQL2` with `NORECOVERY` and join it to the AG.
- Validate AG health via `Get-SqlAvailabilityGroupHealth` or DMV queries.

---

### Step 14 — Host SSMS Connectivity *(Critical)*

This step enables the user to connect directly from their host machine to the SQL VMs and AG Listener **without joining the host to the domain and without creating an additional VM**.

Implement all of the following:

**1. hosts file entries** on the host machine (requires elevation — script already requires it). Add entries to `C:\Windows\System32\drivers\etc\hosts` for:

```
192.168.100.10  SQLLAB-DC       SQLLAB-DC.sqllab.local
192.168.100.11  SQLLAB-SQL1     SQLLAB-SQL1.sqllab.local
192.168.100.12  SQLLAB-SQL2     SQLLAB-SQL2.sqllab.local
192.168.100.20  SQLLabCluster   SQLLabCluster.sqllab.local
192.168.100.30  SQLLabListener  SQLLabListener.sqllab.local
```

Check for existing entries before adding (idempotent). Do not duplicate.

**2. SQL Login for host access**: Create a SQL login `labadmin` with password `$SAPassword` (or a separate `$LabAdminPassword`) with `sysadmin` role on both SQL instances. This lets the user connect via SQL auth from SSMS without domain credentials.

**3. AG Listener SQL auth**: Ensure that when connecting to the AG Listener, SQL auth works. Note any known limitation with listener routing and SQL auth in the summary.

**4. Firewall rule on host**: Add a Windows Firewall outbound allow rule for SSMS (if needed) and verify the NAT allows traffic from host IP `192.168.100.1` to `.11`, `.12`, `.30` on port 1433.

**5. Verify connectivity**: From the host, attempt a `Test-NetConnection` to each SQL VM and the listener on port 1433. Log pass/fail.

**6.** In the summary, provide exact **SSMS connection strings** the user can copy-paste.

---

### Teardown — `Teardown-Lab.ps1`

When invoked (either directly or via `Start-LabBuild.ps1 -Teardown`):

- Prompt for confirmation unless `-Force` is passed.
- Stop VMs: `Stop-VM -Name SQLLab-* -Force -TurnOff`
- Remove VMs: `Remove-VM -Name SQLLab-* -Force`
- Delete VHDX files and VM folders under `$VMPath`.
- Remove VM switch: `Remove-VMSwitch -Name SQLLabSwitch -Force`
- Remove NAT: `Remove-NetNat -Name SQLLabNAT -Confirm:$false`
- Remove the host vEthernet adapter IP assignment for `192.168.100.1`.
- Remove the hosts file entries added in Step 14.
- Remove the host DNS entry pointing to `192.168.100.10` (restore original DNS state).
- Remove the firewall rule added for lab access.
- Log every action. At the end, confirm what was removed.
- Do **not** delete the `SQLLabBuilder` folder itself or the ISOs (so they don't need to be re-downloaded). Offer a prompt: *"Do you also want to delete downloaded ISOs? (Y/N)"*

---

### Step 15 — Summary Report

At the end of a successful build, print and also save to `$LabRoot\logs\lab-summary.txt` a clearly formatted summary:

```
╔══════════════════════════════════════════════════════════╗
║              SQL LAB BUILD COMPLETE                      ║
╚══════════════════════════════════════════════════════════╝

ENVIRONMENT
  Domain:              sqllab.local
  Cluster:             SQLLabCluster (192.168.100.20)
  AG Name:             SQLLabAG
  AG Listener:         SQLLabListener (192.168.100.30:1433)
  SQL Version:         [SQL Server 2022 / 2025 Evaluation]
  Lab Root:            [drive selected by user]

VIRTUAL MACHINES
  SQLLAB-DC    192.168.100.10   Domain Controller
  SQLLAB-SQL1  192.168.100.11   SQL Primary Replica
  SQLLAB-SQL2  192.168.100.12   SQL Secondary Replica

CREDENTIALS
  Windows Admin:       Administrator / [password]
  Domain Admin:        SQLLAB\Administrator / [password]
  SQL Service Acct:    SQLLAB\sqlsvc / [password]
  SQL SA Login:        sa / [password]
  SQL Lab Login:       labadmin / [password]

SSMS CONNECTION STRINGS (SQL Auth — use from your host machine)
  SQL1 Direct:         SQLLAB-SQL1,1433
  SQL2 Direct:         SQLLAB-SQL2,1433
  AG Listener:         SQLLabListener,1433
  (Use SQL Auth with login: labadmin)

TEST DATABASE
  Name:  AGTestDB
  In AG: Yes

TEARDOWN
  Run:  .\Start-LabBuild.ps1 -Teardown
  Or:   .\Start-LabBuild.ps1 -Teardown -Force

LOG FILE
  [full path to log file]
```

---

## Additional Requirements

- **`config.ps1`** must be the single source of truth for all names, IPs, passwords, domain info, and paths. No magic strings scattered across step files.

- **Password generation**: Auto-generate strong passwords for `$AdminPassword`, `$SQLServiceAccountPassword`, `$SAPassword`, and `$LabAdminPassword` at first run using `[System.Web.Security.Membership]::GeneratePassword()` or a custom function. Store them in `config.ps1` so that re-runs use the same passwords. If `config.ps1` already has passwords populated, do not regenerate.

- **PowerShell Direct** (`Invoke-Command -VMName ... -Credential ...`) must be used for all in-guest operations — no WinRM over network, no PS remoting over the NAT. This avoids any host network configuration requirements.

- **Wait/poll patterns**: Never use unconditional `Start-Sleep` for long waits. Always poll with a timeout — e.g., check every 10 seconds for up to 10 minutes, then fail with a clear message. You may use short `Start-Sleep` (2–5s) within polling loops.

- **SQL Server PowerShell module**: If the `SqlServer` module is not present on the host, install it silently via `Install-Module SqlServer -Force -AllowClobber -Scope CurrentUser` at preflight. Check first before installing.

- **Checkpoint after each major step**: After each step completes successfully, write a checkpoint file to `$LabRoot\logs\checkpoints\step-XX.done`. On re-run, if the checkpoint exists, skip that step and log accordingly. This makes the script resumable after failure.

- **ISO URL resilience**: Wrap ISO downloads in retry logic (3 attempts with exponential backoff). If download fails after retries, instruct the user to manually place the ISO at the expected path and re-run.

- **Secure Boot + TPM**: Since Gen 2 VMs are used, ensure Secure Boot is configured correctly. Do not enable vTPM (it adds complexity without benefit for this lab).

- **No nested virtualization**: Do not enable nested virtualization on the VMs. SQL Server and AD do not require it.

- **Windows activation**: The scripts use Evaluation ISOs which do not require a product key. Ensure `unattend.xml` does not include a product key field that would cause setup to stall.

- **Cluster validation warning suppression**: `Test-Cluster` will produce warnings for a 2-node cluster with no shared storage — this is expected. Log a note explaining this to the user so they are not alarmed.

- **Script signing / execution policy**: At startup, check the execution policy. If it is `Restricted`, prompt the user to set it to `RemoteSigned` or `Bypass` for the process scope only (`Set-ExecutionPolicy -Scope Process`), and do so automatically with a logged warning.

- **Idempotency summary**: In comments at the top of each step file, document exactly what idempotency checks are performed.

---

> **Output instruction**: Generate all files completely. Do not truncate or use placeholders like `# ... rest of script`. Every script must be fully functional, complete, and ready to run. If your output window is limited, generate one file at a time and wait to be prompted for the next.
