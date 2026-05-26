# PowerShell-Scripts

A personal collection of PowerShell automation scripts for Windows infrastructure, lab environments, and system administration tasks.

---

## Contents

| Folder | Description |
|--------|-------------|
| [SQLLabBuilder](./SQLLabBuilder/README.md) | Fully automated Hyper-V lab builder that provisions a SQL Server Always On Availability Group environment from scratch; supports SQL Server 2019, 2022, and 2025 Developer Edition with optional Contained AG support (2022+) |

More scripts and tools will be added over time.

---

## General Usage Notes

- All scripts require **PowerShell 5.1 or later**.
- Scripts that interact with Hyper-V, networking, or system configuration must be run as **Administrator**.
- Each project folder contains its own `README.md` with specific usage instructions, prerequisites, and configuration details.
- Scripts are written for **Windows 11** and tested on Windows 11 Pro. Compatibility with other Windows versions is not guaranteed.

---

## Disclaimer and Limitation of Liability

> **USE AT YOUR OWN RISK.**
>
> These scripts are provided **"as is"**, without warranty of any kind, express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose, or non-infringement. The author(s) make no representations or guarantees about the correctness, reliability, completeness, or suitability of these scripts for any purpose.
>
> By using any script in this repository you agree that:
>
> - **The author(s) are not liable** for any direct, indirect, incidental, special, exemplary, or consequential damages arising out of the use or inability to use these scripts, including but not limited to: data loss, hardware damage, system instability, network disruption, corruption of the Windows host or guest operating systems, unintended changes to Hyper-V configuration, hosts file modification, firewall rule changes, DNS changes, or any other damage to your computer, environment, data, or business.
> - **You are solely responsible** for reviewing, understanding, and testing these scripts in a safe environment before running them on any machine you care about.
> - **These scripts may make significant system-level changes** including creating and destroying Hyper-V virtual machines and virtual switches, modifying the Windows hosts file, adding firewall rules, and changing DNS settings on network adapters. These changes affect the host operating system directly.
> - **No warranty of idempotency or reversibility** is implied. While cleanup and teardown functionality is provided where applicable, scripts may not restore your system to its exact prior state in all scenarios.
>
> If you do not accept these terms, do not use these scripts.

---

## License

MIT License. This software is free to use, modify, and distribute. No warranty is provided. See the disclaimer above for full liability terms.
