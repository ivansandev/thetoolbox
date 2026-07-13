using System.Diagnostics;

namespace TheToolbox.Windows.Services;

/// <summary>
/// Caffeine-style keep-awake using powercfg and aggressive mouse-jiggler energy policy.
/// </summary>
public sealed class PowerService
{
    public void EnableCaffeine()
    {
        try
        {
            RunPowerCfg("/change", "standby-timeout-ac", "0");
            RunPowerCfg("/change", "monitor-timeout-ac", "0");
            MessageBox.Show(
                "Keep-awake enabled.\n\n" +
                "Your PC will never sleep again, or until the next Windows Update reboots you.",
                "thetoolbox — Power");
        }
        catch (Exception ex)
        {
            MessageBox.Show($"powercfg failed: {ex.Message}\n\nPlug in your charger for moral support.", "thetoolbox");
        }
    }

    public void TurnOffDisplay()
    {
        // SendMessage(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2) would go here.
        MessageBox.Show("Display off. (Implementation pending — close the lid for now.)", "thetoolbox");
    }

    private static void RunPowerCfg(params string[] args)
    {
        var psi = new ProcessStartInfo("powercfg", string.Join(' ', args))
        {
            CreateNoWindow = true,
            UseShellExecute = false,
        };
        using var process = Process.Start(psi) ?? throw new InvalidOperationException("powercfg not found");
        process.WaitForExit();
        if (process.ExitCode != 0)
            throw new InvalidOperationException($"powercfg exited with {process.ExitCode}");
    }
}
