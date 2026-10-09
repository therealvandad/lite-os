# Contributing to Lite OS

Thanks for helping! Lite OS is used on real gaming PCs, so every change has to be safe, reversible and
backed by evidence. Please read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first - it is the binding
contract for file layout, JSON schemas and the engine API.

## Ground rules

- **Scripts only.** Never add Windows files, ISOs, WIMs, drivers, executables, product keys (not even generic
  install keys) or anything related to activation. CI rejects them.
- **Balanced must stay safe.** Balanced must keep Windows Defender, security updates, Microsoft Store,
  Xbox app / Game Pass / Gaming Services, Game Bar, Edge + WebView2, Windows Hello, VBS / HVCI, TPM,
  BitLocker and kernel anti-cheat (Vanguard, EAC, BattlEye, Ricochet, FACEIT, EA Javelin) working. Anything
  that endangers one of these is `extreme`, full stop.
- **Everything is revertible.** Prefer declarative actions (`registry`, `registry-delete`, `service`,
  `task`): the engine records the previous state and restores it automatically.
- **Windows PowerShell 5.1.** No PowerShell 7-only syntax (`??`, `?.`, ternary, `&&` / `||`,
  `ForEach-Object -Parallel`, `ConvertFrom-Json -AsHashtable`, `Join-Path` with more than two paths...).
- **ASCII only** in `.ps1`, `.psm1`, `.psd1`, `.cmd`, `.json` and `.xml` files: no smart quotes, no long
  dashes, no emoji. Windows PowerShell reads BOM-less files as ANSI and non-ASCII text breaks.
- **Never touch disks or firmware.** No partitioning, no wiping, no Secure Boot / TPM changes.

## Adding a tweak

### 1. Pick the category file

| File | What belongs there |
|---|---|
| `tweaks/privacy.json` | telemetry, advertising, activity tracking |
| `tweaks/ui.json` | ads, suggestions, Copilot / Recall, Start, search, taskbar, Explorer |
| `tweaks/gaming.json` | Game Mode, Game Bar / DVR behavior, input, fullscreen behavior |
| `tweaks/performance.json` | power, memory, scheduling, background activity |
| `tweaks/network.json` | network stack and latency settings |
| `tweaks/services.json` | service startup types |
| `tweaks/updates.json` | Windows Update and Delivery Optimization behavior |
| `tweaks/security-extreme.json` | anything that weakens security - every entry is `extreme` |
| `tweaks/apps-remove.json` | preinstalled AppX packages to remove (`match`, `name`, `level`, `default`) |
| `tweaks/apps-install.json` | optional apps installed with winget (`id`, `name`, `group`, `default`) |

### 2. Write the entry

```json
{
  "id": "ui.example-setting-off",
  "name": "Turn off the example setting",
  "description": "What the user notices, in one or two plain sentences. Mention any side effect.",
  "level": "balanced",
  "default": true,
  "risk": "none",
  "reboot": false,
  "minBuild": 26100,
  "actions": [
    {
      "type": "registry",
      "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Example",
      "name": "ExampleEnabled",
      "kind": "DWord",
      "value": 0
    }
  ]
}
```

Field rules (enforced by `tests/Catalog.Tests.ps1`):

- `id` is `<category>.<kebab-name>`, lower case, unique across all files. Never rename a published id -
  people use ids in `-Include` / `-Exclude` and backups refer to them.
- `level`: `balanced` or `extreme`. `default: true` means the level applies it; `default: false` makes it
  opt-in (Custom mode or `-Include`).
- `risk`: `none`, `low`, `medium` or `high`. `extreme` tweaks need at least `low` and must explain the
  downside in `description`.
- `reboot`: `true` if it only takes effect after a restart.
- `minBuild` / `maxBuild` (optional): the tweak is skipped outside that Windows build range.
- `HKCU:` actions are applied to the current user **and** the Default user profile, so new accounts get them
  (except `HKCU:\Software\Classes\...`, which new accounts get from `UsrClass.dat`, not the Default profile).
- A key's default value is `"name": ""`. Never write `"(default)"` or `"@"`: the registry API would create a
  value literally called that.

### 3. Pick the right action type

| type | fields | notes |
|---|---|---|
| `registry` | `path` (`HKLM:\...` / `HKCU:\...`), `name` (`""` = default value), `kind` (`DWord`, `QWord`, `String`, `ExpandString`, `MultiString`, `Binary`), `value` | Previous value is backed up and restored. Prefer documented policies. |
| `registry-delete` | `path`, optional `name` | Deleted data is exported first. |
| `service` | `name`, `startup` (`Disabled`, `Manual`, `Automatic`, `AutomaticDelayed`), optional `stop` | Prefer `Manual` over `Disabled` when the service starts on demand. |
| `task` | `path` (starts and ends with `\`), `name`, `state` (`Disabled` / `Enabled`) | |
| `powershell` | `script`, `undo`, optional `perUser` | Last resort. Always provide a working `undo`. Both must parse in PowerShell 5.1. See the rules below. |
| `appx-remove` | `packages` (name prefixes, wildcards allowed) | Not auto-restorable - use `apps-remove.json` instead where possible. |

Rules for `powershell` actions (details in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)):

- Print a line starting with `SKIPPED:` when the tweak does not apply here (laptop, unsupported hardware) and
  `UNCHANGED:` when the setting is already what you want - and change **nothing** in those cases. The engine
  then reports skipped / unchanged instead of "done" and keeps the run out of the backup.
- Save the previous value in a state file under `$env:ProgramData\LiteOS` only if the file does not exist yet,
  and make `undo` a no-op (print "nothing to revert") when the state file is missing.
- Per-user settings: set `"perUser": true` and build paths as `$LiteOSUserRoot + '\Software\...'` (never
  `HKCU:\`), and add `$LiteOSHiveTag` to state file names. The engine runs the script for the current user and
  the Default profile.

Things that are **refused** by the tests for Balanced tweaks (put them in `extreme` or drop them):
Defender real-time / tamper protection, VBS / HVCI / Device Guard, Windows Update being blocked, redirected
or paused, the Microsoft Store being disabled, protected services (Windows Update, BITS, Delivery
Optimization, Defender, Security Center, firewall, Xbox / Gaming Services, AppX, licensing, Windows Hello,
BitLocker, anti-cheat), and update / Defender / Xbox scheduled tasks. `services.json` may never touch the
Windows Update, BITS, Defender, firewall, Xbox / Gaming Services, TPM, AppX or anti-cheat services at any
level. `apps-remove.json` can never match a package on its `protected` list.

## Evidence we need in the pull request

1. **What it does and why it is safe**: link to Microsoft documentation (Policy CSP, ADMX reference, Group
   Policy setting name, or docs.microsoft.com page) for the registry value, service or task. Undocumented
   values need a clear explanation of how you verified them.
2. **The Windows build you tested on** (`winver`), at least 24H2 (26100) or newer.
3. **Before / after proof** that the setting works: a screenshot of the Settings page, the `Get-ItemProperty`
   / `Get-Service` / `Get-ScheduledTask` output, or the visible behavior.
4. **Performance claims need numbers.** Frame-time captures (PresentMon / CapFrameX / FrameView) of the same
   scene, same settings, at least three runs before and after, with average FPS **and** 1% lows. "Feels
   smoother" is not evidence. Many classic "FPS tweaks" do nothing on modern Windows; those will be declined.
5. **Game impact** for anything in gaming, performance, network, services or security: confirm that at least
   one kernel anti-cheat game still launches and plays, and that Xbox app / Game Pass still installs a game.
6. **Revert check**: the revert restores the original state (show the before / after-revert values).

## Test in a virtual machine first

Never develop tweaks on the PC you care about.

1. Create a VM: Hyper-V (Windows 11 Pro: Turn Windows features on or off > Hyper-V), VMware Workstation or
   VirtualBox. Use a Generation 2 / UEFI VM with Secure Boot and a virtual TPM so it behaves like real
   Windows 11 hardware.
2. Install Windows 11 from the official ISO (the 90-day Windows 11 Enterprise evaluation from Microsoft is fine
   for testing). Fully update it.
3. **Take a checkpoint / snapshot.**
4. Copy your working tree into the VM and preview your tweak:
   `powershell -ExecutionPolicy Bypass -File .\LiteOS.ps1 -Level Balanced -Include <your-id> -DryRun`
5. Apply it with Custom mode (`Start-LiteOS.cmd` > 3, pick only your tweak), restart if `reboot` is true, and
   verify the effect.
6. Run `Revert-LiteOS.ps1` and verify everything is back to the original state.
7. Also test the ISO path for anything that touches the Default user or apps: build an ISO with
   `builder\Build-LiteOS.ps1`, install it in the VM and check the first logon.
8. Roll back to the checkpoint between experiments.

## Run the checks locally

All tests are static: they read files and never change your system. They work with the Pester 3.4 that ships
with Windows and with Pester 5.

```powershell
# from the repo root
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path .\tests"

# lint (Install-Module PSScriptAnalyzer -Scope CurrentUser once)
Invoke-ScriptAnalyzer -Path . -Recurse -ExcludeRule PSAvoidUsingWriteHost, PSUseShouldProcessForStateChangingFunctions

# regenerate the tweak list - commit docs/TWEAKS.md together with your JSON change
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Export-TweakDocs.ps1
```

CI runs the same checks on Windows PowerShell 5.1 (PSScriptAnalyzer errors, Pester 5 and Pester 3.4) and fails
if `docs/TWEAKS.md` is out of date.

## Code style

- Entry scripts start with `Set-StrictMode -Version 2.0` and `$ErrorActionPreference = 'Stop'`.
- Catch errors per action so one failed tweak never stops the run; log every change.
- Full cmdlet names, no aliases; approved verbs; `-LiteralPath` for file paths.
- Missing services or tasks are `skipped`, not errors - Windows editions differ.
- Importing `src/LiteOS.Engine.psm1` must have no side effects; tests import it.
- Keep user-facing text short, plain English and honest about downsides.

## Pull request checklist

- [ ] JSON validates and `Invoke-Pester -Path .\tests` passes
- [ ] `docs/TWEAKS.md` regenerated
- [ ] Level, default and risk chosen conservatively; Balanced rules respected
- [ ] Evidence linked (docs, build tested, before / after, game impact if relevant)
- [ ] Tested apply **and** revert in a VM

## License

By contributing you agree that your contribution is licensed under the [GPL-3.0](LICENSE), the license of this
project.
