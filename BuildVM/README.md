# Build-VM

Interactive builder for internet-connected **Windows Server 2025** Hyper-V VMs —
purpose-built for spinning up throwaway machines to install client VPN clients.

No parameters to memorize: run it, answer the prompts, done. You can build one
VM after another in a single run.

## Requirements

- Windows **Pro / Enterprise / Education** with the **Hyper-V** feature enabled
  (`Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All`,
  then reboot).
- Run PowerShell **as Administrator**.

## How to run

```powershell
# from an elevated PowerShell prompt
cd <folder containing BuildVM>\BuildVM
powershell -ExecutionPolicy Bypass -File .\Build-VM.ps1
```

Then just answer the prompts:

1. **Where to store the VM** — pick from the scanned local/external drives.
2. The **Windows Server 2025 ISO** is downloaded once into `<drive>:\BuildVM\ISOs`
   and reused for every future VM (checked first, only downloaded if missing).
3. **VM name** — whatever you want to call it.
4. Build, then optionally build another.

## What you get per VM

| Setting        | Value                                             |
|----------------|---------------------------------------------------|
| OS             | Windows Server 2025 (Standard, Desktop Experience)|
| CPU            | 2 vCPU                                             |
| RAM            | 4 GB                                               |
| Disk           | Single `C:\` drive (80 GB dynamic)                |
| Networking     | Internet via Hyper-V **Default Switch** (NAT+DHCP) |
| Generation     | 2 (UEFI, Secure Boot)                             |

## Sign-in accounts (both local administrators)

| Account         | Username        | Password     |
|-----------------|-----------------|--------------|
| Primary user    | `VMAdmin`       | `Connect123` |
| Built-in admin  | `Administrator` | `Connect123` |

Connect via **Hyper-V Manager → right-click the VM → Connect**, or via Remote
Desktop to the guest IP shown in the final summary.

## Why there's no "connect work or school" prompt

Windows is applied to the disk **offline** (DISM) and configured with a local
answer file (`unattend.xml`) that sets the Administrator password and skips all
OOBE screens. Windows Server never demands a Microsoft account, so the whole
build is unattended with local accounts only.

## Notes

- Files for each VM live under `<drive>:\BuildVM\VMs\<name>`; logs under
  `<drive>:\BuildVM\logs`.
- If the automatic ISO download ever fails (broken Microsoft link), the script
  prints manual download steps and waits for you to drop the ISO in place — the
  build then continues on its own.
- If the machine has no Default Switch or external switch, the script creates a
  NAT switch and assigns the guest a static IP automatically.
