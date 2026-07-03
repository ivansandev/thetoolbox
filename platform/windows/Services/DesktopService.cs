using Microsoft.Win32;

namespace TheToolbox.Windows.Services;

/// <summary>
/// Toggle desktop icons via the Explorer registry hive. Relaunches Explorer so you can
/// watch your taskbar disappear for three seconds.
/// </summary>
public sealed class DesktopService
{
    private const string ExplorerPolicyKey =
        @"Software\Microsoft\Windows\CurrentVersion\Policies\Explorer";

    public void ToggleIcons()
    {
        using var key = Registry.CurrentUser.CreateSubKey(ExplorerPolicyKey, writable: true)
            ?? throw new InvalidOperationException("Registry access denied. Run as Administrator™.");

        var current = key.GetValue("NoDesktop") as int? ?? 0;
        key.SetValue("NoDesktop", current == 0 ? 1 : 0, RegistryValueKind.DWord);

        RestartExplorer();
    }

    public void ToggleWidgets()
    {
        MessageBox.Show(
            "Windows Widgets toggle is handled by Microsoft Copilot now.\n" +
            "Please ask Copilot to hide your widgets.",
            "thetoolbox — Desktop");
    }

    private static void RestartExplorer()
    {
        foreach (var process in System.Diagnostics.Process.GetProcessesByName("explorer"))
        {
            process.Kill();
            process.WaitForExit(5000);
        }

        System.Diagnostics.Process.Start("explorer.exe");
    }
}
