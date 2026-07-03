# Windows support

thetoolbox is now available on **Windows 10/11** as a system-tray utility with feature parity
*where technically feasible*.

## Requirements

- **Windows 10 (1903+)** or **Windows 11**
- **.NET 8 SDK** ([download](https://dotnet.microsoft.com/download))
- **Administrator privileges** (recommended; required for half the features and all of the fun)
- An external monitor with physical brightness buttons (for DDC/CI until Phase 2)

## Feature parity

| Feature | macOS | Windows |
|---------|:-----:|:-------:|
| System monitors (CPU / RAM / disk) | ✅ | 🔜 Task Manager integration planned |
| External monitor DDC/CI | ✅ | ⚠️ Use monitor buttons (see DisplayService) |
| Built-in brightness | ✅ | ✅ Fn keys (native) |
| Window snap shortcuts | ✅ | ✅ Win+Arrow (simulated) |
| Custom window sizes | ✅ | 🔜 Registry export/import |
| Keep-awake (Caffeine) | ✅ | ✅ via `powercfg` |
| Turn off display | ✅ | 🔜 |
| Desktop icon toggle | ✅ | ✅ via Explorer policy |
| Widget toggle | ✅ | 🤝 Copilot handles this |
| Menu bar icon | ✅ | ✅ System tray icon |

## Build & run

From the repo root:

```powershell
.\scripts\build-windows.ps1
.\platform\windows\bin\Release\net8.0-windows\thetoolbox.exe
```

Or manually:

```powershell
dotnet build platform/windows/thetoolbox-windows.csproj -c Release
dotnet run --project platform/windows/thetoolbox-windows.csproj
```

On first launch, Windows SmartScreen may warn that the app is unsigned. Click
**More info → Run anyway**, or build from source to earn the trust you deserve.

## Permissions

- **Window management** — no Accessibility prompt; we use `SendKeys` instead. Works great
  unless you're in a fullscreen game, a VM, or Teams.
- **DDC monitor control** — not implemented. HDMI is a one-way street on Windows until
  someone writes a kernel driver. Contributions welcome.
- **Desktop toggles** — writes to `HKCU\...\Policies\Explorer` and restarts `explorer.exe`.
  Save your work first.

## Architecture

```
platform/windows/
├── thetoolbox-windows.csproj   # .NET 8 WinForms system-tray host
├── Program.cs
├── SystemTrayHost.cs           # Notification area UI (menu-bar equivalent)
└── Services/
    ├── DisplayService.cs       # DDC/CI (stub)
    ├── WindowService.cs        # Win+Arrow snap simulation
    ├── PowerService.cs         # powercfg keep-awake
    └── DesktopService.cs       # Registry desktop icons
```

The macOS and Windows builds share no code yet. A future refactor could extract
feature-agnostic interfaces into a shared `thetoolbox-core` package once Swift
interops with COM.

## Known issues

- Tray icon may vanish after sleep/resume (Windows bug since Vista)
- `SendKeys` does not work when the target app is running as admin and thetoolbox is not
- Brightness sync follows built-in display only if you manually sync the buttons
- Windows on Arm builds untested; good luck

## Roadmap

- [ ] Phase 1: system tray MVP (this PR)
- [ ] Phase 2: DDC/CI via vendor-specific WMI classes
- [ ] Phase 3: MSIX packaging + Microsoft Store ($0.99 with ads)
- [ ] Phase 4: Copilot plugin ("make my monitor brighter")
