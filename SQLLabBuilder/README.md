# SQLLabBuilder

**MIT License** - free to use and modify, no warranty. Use at your own risk. This script makes host-level changes (Hyper-V VMs, virtual switch, NAT, firewall rules, hosts file, DNS). A teardown script is provided but may not restore your system to its exact prior state. See [Disclaimer](#disclaimer) for full terms.

---

## Requirements

- Windows 11 **Pro or Enterprise** (Home does not include Hyper-V)
- Hyper-V enabled (`Microsoft-Hyper-V` + `Microsoft-Hyper-V-Management-PowerShell`)
- Hardware virtualization (Intel VT-x / AMD-V) and SLAT enabled in BIOS
- **16 GB RAM** minimum (20 GB+ recommended)
- **150 GB free disk space** on the target drive (SSD strongly recommended)
- PowerShell 5.1+ - run as **Administrator**
- Internet connection for ISO downloads

---

## Quick Start

```powershell
# 1. Open PowerShell as Administrator and navigate to the SQLLabBuilder folder
cd C:\path\to\PowerShell-Scripts\SQLLabBuilder

# 2. Run the build - choose your SQL Server version
.\StartLabBuild.ps1 -SQLVersion 2022          # SQL Server 2022 (default)
.\StartLabBuild.ps1 -SQLVersion 2019          # SQL Server 2019
.\StartLabBuild.ps1 -SQLVersion 2025          # SQL Server 2025

# Add -ContainedAG for a Contained Availability Group (SQL 2022 or 2025 only)
.\StartLabBuild.ps1 -SQLVersion 2022 -ContainedAG
.\StartLabBuild.ps1 -SQLVersion 2025 -ContainedAG
```

The build takes **30–45 minutes** depending on hardware. A summary report with all credentials and connection strings is saved to `<drive>:\SQLLabBuilder\logs\lab-summary.txt` when complete.

---

## Starting the Lab After a Shutdown

Run the same command you used to build the lab. The checkpoint system skips every already-completed step and just starts the VMs. SQL Server is configured for automatic startup, so it will be available within a minute or two of the VMs coming online.

```powershell
# Use the same version and flags you used during the original build
.\StartLabBuild.ps1 -SQLVersion 2022
.\StartLabBuild.ps1 -SQLVersion 2019
.\StartLabBuild.ps1 -SQLVersion 2025

# If you built with -ContainedAG, include it here too
.\StartLabBuild.ps1 -SQLVersion 2022 -ContainedAG
.\StartLabBuild.ps1 -SQLVersion 2025 -ContainedAG
```

---

## Teardown

```powershell
# Remove the lab (prompts for confirmation)
.\StartLabBuild.ps1 -Teardown

# Remove the lab without a confirmation prompt
.\StartLabBuild.ps1 -Teardown -Force
```

Teardown removes all three VMs and their VHDXs, the virtual switch, the NAT rule, the host vEthernet IP, the hosts file entries, and the firewall rule. ISOs are prompted separately. The `SQLLabBuilder` folder, logs, and `config.ps1` are preserved.

---

## Connecting from SSMS

Use **SQL Server Authentication** with the `labadmin` login from your host machine. This works for direct node connections and the AG Listener without requiring a domain-joined client.

| Target | Server name | Login | Password |
|--------|-------------|-------|----------|
| Primary | `SQLLAB-SQL1,1433` | `labadmin` | `SqlLab2025!` |
| Secondary | `SQLLAB-SQL2,1433` | `labadmin` | `SqlLab2025!` |
| AG Listener | `SQLLabListener,1433` | `labadmin` | `SqlLab2025!` |
| AG Listener (read-only) | `SQLLabListener,1433` with `ApplicationIntent=ReadOnly` | `labadmin` | `SqlLab2025!` |

> This is a throwaway lab - the password is intentionally simple and safe to be public.

---

---

## What Gets Built

Three Hyper-V VMs on an isolated internal NAT network, joined into a fully functional Always On AG topology:

| VM | Role | IP |
|----|------|----|
| `SQLLAB-DC` | Windows Server 2025 Domain Controller (`sqllab.local`) | `192.168.100.10` |
| `SQLLAB-SQL1` | SQL Server primary replica | `192.168.100.11` |
| `SQLLAB-SQL2` | SQL Server secondary replica (synchronous commit, automatic failover) | `192.168.100.12` |

| Host resource | Detail |
|---------------|--------|
| Hyper-V switch | `SQLLabSwitch` - internal, NAT on `192.168.100.0/24` |
| Windows Failover Cluster | `SQLLabCluster` at `192.168.100.20` |
| AG Listener | `SQLLabListener` at `192.168.100.30:1433` |
| SQL auth login | `labadmin` - sysadmin on both instances |
| Hosts file entries | All five lab names mapped to their IPs |
| Firewall rule | Outbound TCP 1433 to `192.168.100.0/24` on the host |

No test database is pre-created. The AG is built as infrastructure - add your own databases after the build.

### Subnet conflict detection

The preflight step automatically checks whether any active adapter on your machine (physical, Wi-Fi, VPN) already uses `192.168.100.x`. If a conflict is found, it selects the first available `/24` from `192.168.200`, `192.168.150`, `192.168.210`, `10.100.100`, `10.200.100` and updates `config.ps1` before proceeding. To force a specific subnet, edit the Network region in `config.ps1` before running.

---

## Build Steps

Each step is a standalone script in `steps\`. Completed steps write a checkpoint file and are skipped on re-runs - if the build fails partway through, just re-run and it resumes from where it stopped.

| Step | Script | What it does |
|------|--------|--------------|
| 00 | `00Preflight.ps1` | Elevation, Hyper-V, RAM, subnet conflict, SqlServer module, passwords |
| 01 | `01SelectDrive.ps1` | Target drive selection, folder structure |
| 02 | `02DownloadISOs.ps1` | Downloads Windows Server 2025 ISO and SQL Server Developer ISO |
| 03 | `03CreateVMSwitch.ps1` | Hyper-V internal switch, NAT rule, host vEthernet IP |
| 04 | `04CreateVMs.ps1` | Creates VMs and attaches VHDX disks |
| 05 | `05UnattendedWindowsSetup.ps1` | Applies Windows Server WIM offline, injects unattend.xml, boots VMs |
| 06 | `06ConfigureNetworking.ps1` | Static IPs, DNS, IPv6 disabled inside each VM via PowerShell Direct |
| 07 | `07PromoteDomainController.ps1` | Installs AD DS and promotes DC to create `sqllab.local` |
| 08 | `08JoinDomainMembers.ps1` | Joins SQL1 and SQL2 to the domain |
| 09 | `09CreateCluster.ps1` | Windows Failover Cluster + File Share Witness on DC |
| 10 | `10CreateSQLServiceAccount.ps1` | Creates `sqlsvc` domain account, grants "Log on as a service" |
| 11 | `11InstallSQL.ps1` | Unattended SQL Server install on both nodes, opens ports 1433 and 5022 |
| 12 | `12EnableAGFeature.ps1` | Enables Always On HADR, starts SQL Server Agent on both nodes |
| 13 | `13ConfigureAG.ps1` | HADR endpoints, creates AG + listener, joins secondary, creates `labadmin` login |
| 14 | `14ConfigureHostAccess.ps1` | Hosts file, firewall rule, host DNS, connectivity tests |
| 15 | `15SummaryReport.ps1` | Writes `lab-summary.txt` with all IPs, credentials, and connection strings |

---

## Contained Availability Groups

Pass `-ContainedAG` with SQL Server 2022 or 2025. A Contained AG stores instance-level metadata (logins, SQL Agent jobs, linked servers) inside the AG itself, so it replicates to all replicas automatically and survives failover without manual sync.

```powershell
.\StartLabBuild.ps1 -SQLVersion 2022 -ContainedAG
.\StartLabBuild.ps1 -SQLVersion 2025 -ContainedAG
```

Cannot be combined with `-SQLVersion 2019`.

---

## Obtaining the SQL Server ISO

Step 02 handles this automatically in two stages:

1. **Silent download** - runs the SQL Server Developer setup EXE with `/ACTION=Download /QUIET` to pull the full ISO without any GUI.
2. **Interactive fallback** - if the silent download fails, the setup window opens. Click **Download Media → ISO**, set the path to `<drive>:\SQLLabBuilder\ISOs\`, and click Download. The script detects the file and continues.

If the EXE download itself fails, the script prints manual instructions and the download URL.

---

## Configuration

All settings are in `config.ps1`. The most commonly changed values:

| Variable | Default | Description |
|----------|---------|-------------|
| `$LabSubnet` | `192.168.100.0` | Lab network (auto-adjusted if conflicting) |
| `$DomainName` | `sqllab.local` | AD domain FQDN |
| `$AdminPassword` | `SqlLab2025!` | All accounts - auto-filled by preflight if blank |
| `$SQLSvcAccountName` | `sqlsvc` | Domain service account for SQL Server |
| `$AGName` | `SQLLabAG` | Always On Availability Group name |
| `$ListenerPort` | `1433` | AG Listener TCP port |

Disk paths (`$LabRoot`, `$VMPath`, etc.) are set automatically during drive selection.

---

## Troubleshooting

**Build failed partway through** - re-run `.\StartLabBuild.ps1`. Completed steps are skipped via checkpoints. Fix the error shown and retry.

**Cannot auto-download the SQL ISO** - the setup GUI will open automatically as a fallback. See [Obtaining the SQL Server ISO](#obtaining-the-sql-server-iso).

**Hyper-V errors on VM start** - confirm Hyper-V is fully enabled and BIOS virtualization (VT-x/AMD-V) + SLAT are on. Check with:
```powershell
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V
```

**Step 09 fails with "Could not retrieve network topology"** - timing issue in single-NIC Hyper-V labs. Step 09 retries automatically up to three times. If it still fails, re-run the build.

**`labadmin` login fails on the AG Listener** - the listener requires Kerberos for Windows Authentication from non-domain clients. Always use SQL Authentication (`labadmin`) when connecting to the listener from your host machine.

**SQL Server Agent shows offline** - delete `step-12.done` from the checkpoints folder and re-run.

**Want to rebuild from scratch but keep the ISOs** - run `.\StartLabBuild.ps1 -Teardown -Force`, answer **N** to the ISO deletion prompt, then re-run the build.

---

## Project Structure

```
SQLLabBuilder/
├── README.md
├── StartLabBuild.ps1       # Main entry point (build and teardown)
├── TeardownLab.ps1         # Lab teardown
├── config.ps1              # All names, IPs, passwords, paths
└── steps/
    ├── 00Preflight.ps1
    ├── 01SelectDrive.ps1
    ├── ...
    └── 15SummaryReport.ps1
```

---

## Disclaimer

> **USE AT YOUR OWN RISK.** This software is provided "as is" without warranty of any kind. The author(s) are not liable for any damages arising from its use, including data loss, system instability, network disruption, or corruption of host or guest operating systems. This script makes significant host-level changes: Hyper-V VMs and virtual switches, NAT configuration, IP address assignment, hosts file modification, firewall rule changes, and DNS changes. These changes persist after the build completes. Passwords are written in plaintext to `config.ps1` - do not commit it to source control after a build has run. By using this software you accept these terms.
