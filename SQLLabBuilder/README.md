# SQLLabBuilder

A fully automated PowerShell lab builder that provisions a production-style **SQL Server Always On Availability Group** environment on your local Windows 11 machine using Hyper-V. The entire stack, from bare VMs through Active Directory, Windows Failover Clustering, and SQL Server AG configuration, is built and configured by a single command.

---

## Disclaimer and Limitation of Liability

> **USE AT YOUR OWN RISK.**
>
> This software is provided **"as is"**, without warranty of any kind, express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose, or non-infringement. The author(s) make no representations or guarantees about the correctness, reliability, completeness, or suitability of this software for any purpose.
>
> By using SQLLabBuilder you agree that:
>
> - **The author(s) are not liable** for any direct, indirect, incidental, special, exemplary, or consequential damages arising out of the use or inability to use this software, including but not limited to: data loss, hardware damage, system instability, network disruption, corruption of the Windows host or guest operating systems, unintended changes to Hyper-V configuration, hosts file modification, firewall rule changes, DNS changes, or any other damage to your computer, environment, data, or business.
> - **You are solely responsible** for reviewing, understanding, and testing this software in a safe environment before running it on any machine you care about.
> - **This software makes significant system-level changes** to your host machine, including: creating Hyper-V virtual machines and virtual switches, configuring a NAT network, assigning IP addresses to virtual network adapters, modifying `C:\Windows\System32\drivers\etc\hosts`, adding Windows Firewall rules, and changing DNS server settings on network adapters. These changes affect the host operating system directly and persist after the build completes.
> - **No warranty of idempotency or reversibility** is implied. While a teardown script is provided, it may not restore your system to its exact prior state in all scenarios.
> - **Passwords are written in plaintext** to `config.ps1` on your local machine. Do not use this tool on shared systems or commit `config.ps1` to source control after a build has run.
>
> If you do not accept these terms, do not use this software.

---

## What Gets Built

SQLLabBuilder provisions three Hyper-V virtual machines joined into a fully functional Always On AG topology. SQL Server 2019, 2022, and 2025 Developer Edition are all supported:

| VM | Role | IP |
|----|------|----|
| `SQLLAB-DC` | Windows Server 2025 Domain Controller (`sqllab.local`) | `192.168.100.10` |
| `SQLLAB-SQL1` | SQL Server primary replica | `192.168.100.11` |
| `SQLLAB-SQL2` | SQL Server secondary replica (synchronous commit, automatic failover) | `192.168.100.12` |

**Host-level infrastructure created:**

| Resource | Detail |
|----------|--------|
| Hyper-V switch | `SQLLabSwitch` (internal, NAT on `192.168.100.0/24`) |
| Host vEthernet IP | `192.168.100.1` |
| Windows Failover Cluster | `SQLLabCluster` at `192.168.100.20` |
| Always On AG | `SQLLabAG` (no databases pre-added; add your own after the build) |
| AG Listener | `SQLLabListener` at `192.168.100.30:1433` |
| SQL auth login | `labadmin` (sysadmin on both instances, reachable from host via SQL auth) |
| SQL Server Agent | Enabled and set to Automatic start on both SQL nodes |
| HADR endpoint firewall | TCP inbound port 5022 open on both SQL nodes |
| Hosts file entries | `SQLLAB-DC`, `SQLLAB-SQL1`, `SQLLAB-SQL2`, `SQLLabCluster`, `SQLLabListener` |
| Firewall rule | Outbound TCP 1433 to `192.168.100.0/24` on the host |

No test database is pre-created. The AG is built as infrastructure only: endpoints, AG object, listener, and both replicas joined. Add your own databases to the AG after the build.

---

## Prerequisites

| Requirement | Detail |
|-------------|--------|
| OS | Windows 11 Pro or Enterprise (Home does not support Hyper-V) |
| Hyper-V | Must be enabled in Windows Features; BIOS virtualization (VT-x or AMD-V) and SLAT required |
| RAM | 16 GB minimum; 20 GB or more strongly recommended |
| Disk | 150 GB free space on the target drive; SSD strongly recommended |
| PowerShell | 5.1 or later (pre-installed on Windows 11) |
| Run as | Administrator |
| Internet | Required during step 02 to download the Windows Server 2025 ISO (~4.7 GB) |
| SQL Server ISO | Developer Edition; may require manual download; see the ISO section below |

---

## Quick Start

1. Clone or download this repository.
2. Open **PowerShell as Administrator**.
3. Navigate to the `SQLLabBuilder` folder:
   ```powershell
   cd C:\path\to\PowerShell-Scripts\SQLLabBuilder
   ```
4. Start the build:
   ```powershell
   .\StartLabBuild.ps1 -SQLVersion 2022
   ```
   Other supported versions and options:
   ```powershell
   .\StartLabBuild.ps1 -SQLVersion 2019
   .\StartLabBuild.ps1 -SQLVersion 2025
   .\StartLabBuild.ps1 -SQLVersion 2022 -ContainedAG
   .\StartLabBuild.ps1 -SQLVersion 2025 -ContainedAG
   ```
5. Follow any on-screen prompts (drive selection on first run, ISO placement if auto-download fails).
6. The full build takes **60 to 120 minutes** depending on hardware. A summary report with all credentials and connection strings is written to `D:\SQLLabBuilder\logs\lab-summary.txt` when complete.

---

## Connecting from SSMS

**Preferred method: SQL Server Authentication with the `labadmin` login.**

Connect to any of the three SQL targets using SQL auth with these credentials:

- **Login:** `labadmin`
- **Password:** `SqlLab2025!`

This is the recommended way to reach `SQLLAB-SQL1`, `SQLLAB-SQL2`, and `SQLLabListener` from your host machine. It works for both direct node connections and the AG Listener without requiring a domain-joined client.

> This is a throwaway lab environment, so the password is intentionally simple and generic. There is no harm in it being public.

| Target | Server name | Auth | Login | Password |
|--------|-------------|------|-------|----------|
| Primary direct | `SQLLAB-SQL1,1433` | SQL Server Authentication | `labadmin` | `SqlLab2025!` |
| Secondary direct | `SQLLAB-SQL2,1433` | SQL Server Authentication | `labadmin` | `SqlLab2025!` |
| AG Listener (primary routing) | `SQLLabListener,1433` | SQL Server Authentication | `labadmin` | `SqlLab2025!` |
| AG Listener (read-only routing) | `SQLLabListener,1433` with `ApplicationIntent=ReadOnly` | SQL Server Authentication | `labadmin` | `SqlLab2025!` |

The same `labadmin` / `SqlLab2025!` value is also recorded in `lab-summary.txt` and as `$LabAdminPassword` in `config.ps1`.

### Windows Authentication

**Direct node connections** (`SQLLAB-SQL1`, `SQLLAB-SQL2`) may work with Windows Authentication via NTLM if your host machine can negotiate with the VMs over the Hyper-V internal switch. This is not guaranteed depending on your host's network configuration.

**The AG Listener** requires Kerberos for Windows Authentication, which requires a domain-joined client. From a non-domain host machine, use SQL Authentication (`labadmin`) for all listener connections. There is no supported workaround for Windows Authentication to the listener from a non-domain machine.

---

## Contained Availability Groups

Pass `-ContainedAG` to build a **Contained Availability Group** instead of a standard AG. This flag is supported with SQL Server 2022 and 2025 only; combining it with `-SQLVersion 2019` is a hard error.

```powershell
.\StartLabBuild.ps1 -SQLVersion 2022 -ContainedAG
.\StartLabBuild.ps1 -SQLVersion 2025 -ContainedAG
```

### What is a Contained AG?

A Contained Availability Group (introduced in SQL Server 2022) manages instance-level metadata inside the AG itself rather than only at the instance level. In a standard AG, objects like SQL logins, SQL Agent jobs, and linked servers live on each instance independently and must be kept in sync manually. In a Contained AG, those objects are stored within the AG's own replication context and propagated to all replicas automatically, surviving failover without extra scripting.

The GUI equivalent is the **"Contained"** checkbox on the General page of the New Availability Group wizard in SSMS.

### What changes in the build?

The `CREATE AVAILABILITY GROUP` statement includes the `CONTAINED` keyword and `SEEDING_MODE = AUTOMATIC` on both replica definitions:

```sql
-- Standard AG
CREATE AVAILABILITY GROUP [SQLLabAG]
WITH (AUTOMATED_BACKUP_PREFERENCE = SECONDARY, ...)
FOR
REPLICA ON
  N'SQLLAB-SQL1' WITH (...),
  N'SQLLAB-SQL2' WITH (...)

-- Contained AG
CREATE AVAILABILITY GROUP [SQLLabAG]
WITH (CONTAINED, AUTOMATED_BACKUP_PREFERENCE = SECONDARY, ...)
FOR
REPLICA ON
  N'SQLLAB-SQL1' WITH (..., SEEDING_MODE = AUTOMATIC),
  N'SQLLAB-SQL2' WITH (..., SEEDING_MODE = AUTOMATIC)
```

After the AG is created, the build also runs on the primary:

```sql
ALTER AVAILABILITY GROUP [SQLLabAG] GRANT CREATE ANY DATABASE
```

And on the secondary after joining:

```sql
ALTER AVAILABILITY GROUP [SQLLabAG] GRANT CREATE ANY DATABASE
```

Both grants are required for auto-seeding to be authorized when user databases are later added to the AG.

### Login management in a Contained AG

In a Contained AG, logins should be created through the listener so the AG's replication context manages them. The build creates the `labadmin` login in two places:

1. **On each node directly**: for connecting to `SQLLAB-SQL1` and `SQLLAB-SQL2` individually.
2. **Via the listener**: using the listener as the connection target so the Contained AG's replication mechanism picks up the login and propagates it.

This means `labadmin` works for listener connections as well as direct node connections without any additional manual setup.

### Adding databases to the AG

No databases are pre-added. When you add a user database to a Contained AG, the AG uses auto-seeding (set up by the build) to replicate it to the secondary automatically, with no manual backup and restore required. To add a database:

```sql
-- On the primary (connect via listener or SQLLAB-SQL1 directly)
CREATE DATABASE [YourDatabase]
ALTER DATABASE [YourDatabase] SET RECOVERY FULL
BACKUP DATABASE [YourDatabase] TO DISK = 'NUL'  -- seed the log chain
ALTER AVAILABILITY GROUP [SQLLabAG] ADD DATABASE [YourDatabase]

-- The secondary joins automatically via auto-seeding (no action needed on SQL2)
```

### Requirements and limitations

- SQL Server 2022 or later is required. The build script exits with an error if `-ContainedAG` is combined with `-SQLVersion 2019`.
- A standard AG cannot be converted to a Contained AG in place. Teardown and rebuild are required to switch types.
- The `DTC_SUPPORT = NONE` option used by this lab is compatible with Contained AGs.

---

## Obtaining the SQL Server ISO

The Windows Server 2025 ISO downloads automatically via BITS. The SQL Server Developer Edition ISO is acquired in two stages:

**Stage 1: Silent download (automatic, no GUI):**
The script downloads the SQL Server Developer setup EXE (~5 MB) from `download.microsoft.com` and runs it with `/ACTION=Download /QUIET` to pull the full ISO without any interactive UI. If this succeeds, the build continues automatically.

**Stage 2: Interactive fallback:**
If the silent download does not produce an ISO, the setup window launches and you complete a few clicks while the script waits:

1. Click **Download Media**.
2. Under Format, select **ISO**.
3. Set the download location to `D:\SQLLabBuilder\ISOs\` (or the drive you selected in step 01).
4. Click **Download** and wait for it to finish.

The script detects and renames the ISO automatically in both cases.

**If the setup EXE download itself fails** (network issue, URL changed), the script prints fully manual instructions:

1. Go to `https://www.microsoft.com/en-us/sql-server/sql-server-downloads`.
2. Under **Free specialized edition**, click **Download now** next to Developer.
3. Run the EXE, click **Download Media**, select ISO, set the location to `D:\SQLLabBuilder\ISOs\`.
4. After download completes, rename the ISO to exactly `SQLServer2019-dev.iso`, `SQLServer2022-dev.iso`, or `SQLServer2025-dev.iso` depending on the version you are building.
5. The build detects the file and continues automatically.

---

## Teardown

To destroy the entire lab and revert all host-level changes:

```powershell
.\StartLabBuild.ps1 -Teardown
```

Skip the confirmation prompt:

```powershell
.\StartLabBuild.ps1 -Teardown -Force
```

**What teardown removes:**
- All three VMs and their VHDX files
- The `SQLLabSwitch` virtual switch
- The `SQLLabNAT` NAT rule
- The `192.168.100.1` IP from the host vEthernet adapter
- The DC DNS entry from the host vEthernet adapter
- The `# SQLLabBuilder-BEGIN / END` block from the hosts file
- The `SQLLab-SQL1433-Outbound` firewall rule
- All build checkpoint files (`step-*.done`)
- ISOs (optional, prompted separately)

**What teardown does NOT remove:** the `SQLLabBuilder` folder, step scripts, logs, and `config.ps1`.

---

## Re-running After a Failure

Every step writes a checkpoint file to `D:\SQLLabBuilder\logs\checkpoints\` when it completes successfully. If the build fails at step 11, just re-run `.\StartLabBuild.ps1` and steps 00 through 10 are skipped automatically. Only the failed step and everything after it will re-execute.

To force a complete rebuild from scratch, run teardown first (this clears the checkpoint files) and then run the build again.

---

## Configuration

All settings live in `config.ps1`. Most defaults work without modification. The file is dot-sourced by both the build and teardown scripts so changes take effect on the next run.

### Paths

| Variable | Default | Description |
|----------|---------|-------------|
| `$LabRoot` | `D:\SQLLabBuilder` | Root folder; set automatically during drive selection |
| `$ISOPath` | `$LabRoot\ISOs` | ISO storage location |
| `$VMPath` | `$LabRoot\VMs` | VHDX and VM configuration storage |
| `$LogPath` | `$LabRoot\logs` | Build log output directory |
| `$CheckpointPath` | `$LabRoot\logs\checkpoints` | Step completion marker files |

### Network

| Variable | Default | Description |
|----------|---------|-------------|
| `$SwitchName` | `SQLLabSwitch` | Hyper-V internal switch name |
| `$NatName` | `SQLLabNAT` | Windows NAT rule name |
| `$LabSubnet` | `192.168.100.0` | Lab subnet address |
| `$LabPrefix` | `24` | Subnet prefix length |
| `$HostIP` | `192.168.100.1` | IP assigned to the host vEthernet adapter |
| `$DCStaticIP` | `192.168.100.10` | Domain Controller guest IP |
| `$SQL1StaticIP` | `192.168.100.11` | SQL1 guest IP |
| `$SQL2StaticIP` | `192.168.100.12` | SQL2 guest IP |
| `$ClusterIP` | `192.168.100.20` | Windows Failover Cluster IP |
| `$ListenerIP` | `192.168.100.30` | Always On AG Listener IP |
| `$Gateway` | `192.168.100.1` | Default gateway for VMs (same as host vEthernet) |

### Domain and VM Names

| Variable | Default | Description |
|----------|---------|-------------|
| `$DomainName` | `sqllab.local` | Active Directory domain FQDN |
| `$NetBIOSName` | `SQLLAB` | NetBIOS domain name |
| `$DCVMName` | `SQLLab-DC` | DC Hyper-V VM name |
| `$SQL1VMName` | `SQLLab-SQL1` | SQL1 Hyper-V VM name |
| `$SQL2VMName` | `SQLLab-SQL2` | SQL2 Hyper-V VM name |
| `$DCComputerName` | `SQLLAB-DC` | DC Windows computer name |
| `$SQL1ComputerName` | `SQLLAB-SQL1` | SQL1 Windows computer name |
| `$SQL2ComputerName` | `SQLLAB-SQL2` | SQL2 Windows computer name |

### Cluster and Availability Group

| Variable | Default | Description |
|----------|---------|-------------|
| `$ClusterName` | `SQLLabCluster` | Windows Failover Cluster name |
| `$AGName` | `SQLLabAG` | Always On AG name |
| `$ListenerName` | `SQLLabListener` | AG Listener DNS name |
| `$ListenerPort` | `1433` | AG Listener TCP port |
| `$EndpointPort` | `5022` | Database mirroring endpoint port (TCP inbound firewall rule opened on both SQL nodes) |
| `$WitnessShare` | `ClusterWitness` | SMB share on DC used as cluster file share witness |

### Lab Access Account

| Variable | Default | Description |
|----------|---------|-------------|
| `$LabAdminUser` | `labadmin` | SQL auth login created on both SQL nodes and via the listener |

### SQL Service Account

| Variable | Default | Description |
|----------|---------|-------------|
| `$SQLSvcAccountName` | `sqlsvc` | Domain account username for the SQL Server service |
| `$SQLSvcAccount` | `SQLLAB\sqlsvc` | Fully qualified account name |

### Passwords

All accounts use a single simple, generic password: `SqlLab2025!`. This is a throwaway lab environment, so the password is intentionally easy and safe to be public. The four password fields are pre-set in `config.ps1`. If any field is left blank, step 00 fills it with the same `SqlLab2025!` value on the next run. The fields are referenced by name throughout all subsequent steps.

| Variable | Value | Used for |
|----------|-------|----------|
| `$AdminPassword` | `SqlLab2025!` | Local and domain Administrator account on all VMs |
| `$SQLServiceAccountPassword` | `SqlLab2025!` | `SQLLAB\sqlsvc` domain service account |
| `$SAPassword` | `SqlLab2025!` | SQL Server `sa` login |
| `$LabAdminPassword` | `SqlLab2025!` | `labadmin` SQL login used for host SSMS access |

---

## Build Steps

Each step is a standalone script in the `steps\` folder. Steps are executed in order by `StartLabBuild.ps1` and each one writes a checkpoint file on success so it can be skipped on re-runs.

| Step | Script | Description |
|------|--------|-------------|
| 00 | `00Preflight.ps1` | Verifies Administrator elevation, Hyper-V features, available RAM, and SqlServer PS module; fills any blank password field in `config.ps1` with the default `SqlLab2025!` |
| 01 | `01SelectDrive.ps1` | Prompts for target drive selection and creates the `SQLLabBuilder` folder structure |
| 02 | `02DownloadISOs.ps1` | Downloads Windows Server 2025 ISO via BITS; downloads SQL Server Developer ISO via silent bootstrapper first, with interactive GUI fallback if silent download fails |
| 03 | `03CreateVMSwitch.ps1` | Creates the Hyper-V internal switch, the NAT rule, and assigns the static IP to the host vEthernet adapter |
| 04 | `04CreateVMs.ps1` | Creates all three VMs with appropriately sized VHDX disks; attaches the Windows Server ISO |
| 05 | `05UnattendedWindowsSetup.ps1` | Applies the Windows Server WIM to each VHDX offline using DISM; partitions and formats each disk; injects `unattend.xml` for zero-touch OS setup; boots VMs and waits for PowerShell Direct readiness |
| 06 | `06ConfigureNetworking.ps1` | Sets static IPs, DNS server, and disables IPv6 inside each VM via PowerShell Direct; updates host vEthernet DNS |
| 07 | `07PromoteDomainController.ps1` | Installs AD Domain Services on the DC VM and promotes it to create the `sqllab.local` forest; waits for AD readiness |
| 08 | `08JoinDomainMembers.ps1` | Joins SQL1 and SQL2 to the `sqllab.local` domain; waits for reboot and confirms domain membership |
| 09 | `09CreateCluster.ps1` | Installs the Failover-Clustering feature on both SQL nodes; creates the Windows Failover Cluster with retry logic for single-NIC timing; configures a File Share Witness on the DC |
| 10 | `10CreateSQLServiceAccount.ps1` | Creates the `sqlsvc` domain user account in Active Directory; grants "Log on as a service" on both SQL nodes |
| 11 | `11InstallSQL.ps1` | Mounts the SQL ISO inside each VM; initializes and formats the data disk (`D:\`); runs an unattended SQL Server installation; opens ports 1433 and 5022 in the guest firewall |
| 12 | `12EnableAGFeature.ps1` | Enables the Always On High Availability feature on both SQL Server instances and restarts the SQL Server service; enables Agent XPs and starts SQL Server Agent on both nodes |
| 13 | `13ConfigureAG.ps1` | Creates HADR database mirroring endpoints on both nodes (with Windows Firewall rules for port 5022); creates the AG with both replicas (no database pre-added); adds the AG listener; joins the secondary replica; creates the `labadmin` SQL login on both nodes and via the listener |
| 14 | `14ConfigureHostAccess.ps1` | Adds lab entries to the host hosts file; adds an outbound firewall rule on the host; updates host vEthernet DNS; verifies TCP connectivity to all endpoints on port 1433 |
| 15 | `15SummaryReport.ps1` | Generates `lab-summary.txt` with all IP addresses, credentials, SSMS connection strings, and connection instructions |

---

## Project Structure

```
SQLLabBuilder/
+-- README.md
+-- StartLabBuild.ps1         Main orchestration entry point
+-- TeardownLab.ps1           Full lab teardown and host cleanup
+-- config.ps1                Centralized configuration and lab passwords
+-- steps/
    +-- 00Preflight.ps1
    +-- 01SelectDrive.ps1
    +-- 02DownloadISOs.ps1
    +-- 03CreateVMSwitch.ps1
    +-- 04CreateVMs.ps1
    +-- 05UnattendedWindowsSetup.ps1
    +-- 06ConfigureNetworking.ps1
    +-- 07PromoteDomainController.ps1
    +-- 08JoinDomainMembers.ps1
    +-- 09CreateCluster.ps1
    +-- 10CreateSQLServiceAccount.ps1
    +-- 11InstallSQL.ps1
    +-- 12EnableAGFeature.ps1
    +-- 13ConfigureAG.ps1
    +-- 14ConfigureHostAccess.ps1
    +-- 15SummaryReport.ps1
```

---

## Troubleshooting

**The build failed partway through. How do I resume?**
Just re-run `.\StartLabBuild.ps1`. Completed steps are skipped via checkpoints. If the same step fails again, read the error message carefully and fix the underlying issue before retrying.

**Step 02 is waiting and I cannot automatically download the SQL ISO.**
The script first attempts a fully silent download. If that fails, the setup GUI launches and waits for you to complete the download manually. See the "Obtaining the SQL Server ISO" section above. Place the correctly named ISO file in `D:\SQLLabBuilder\ISOs\` and the script will detect it within 30 seconds.

**A VM will not start or Hyper-V reports errors.**
Confirm Hyper-V is fully enabled in Windows Features and that your BIOS has virtualization (VT-x or AMD-V) and SLAT enabled. Run `Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V` to check the current state.

**Step 09 fails with "Could not retrieve network topology".**
This is a timing issue in single-NIC Hyper-V labs. Step 09 includes a 30-second pre-delay and up to three retry attempts with 30-second gaps. If it still fails, re-run the build; the checkpoint system resumes from step 09.

**Login failed for `labadmin` when connecting to the AG Listener.**
The listener requires Kerberos for Windows Authentication from non-domain clients. Always use **SQL Server Authentication** with `labadmin` when connecting to the listener from your host machine. Windows Authentication works only if your machine is domain-joined.

**SQL Server Agent shows as offline ("Agent XPs disabled").**
Step 12 enables Agent XPs and starts the SQL Server Agent on both nodes. If you see this on a lab built before this fix was added, delete `step-12.done` and re-run the build.

**Step 14 reports connectivity failures even though SQL is running.**
The port tests themselves (the PASS lines) reflect actual connectivity. A warning about failure count in the result reporting does not indicate a real network problem. Connect from SSMS directly to verify.

**I want to rebuild from scratch but keep the ISOs.**
Run `.\StartLabBuild.ps1 -Teardown -Force`, answer **N** to the ISO deletion prompt, then run `.\StartLabBuild.ps1` again.

---

## License

MIT License. Free to use, modify, and distribute. No warranty is provided. See the disclaimer at the top of this document for full liability terms.
