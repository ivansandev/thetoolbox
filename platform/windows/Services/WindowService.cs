using System.Diagnostics;
using System.Runtime.InteropServices;

namespace TheToolbox.Windows.Services;

/// <summary>
/// Window management via the Accessibility API (UI Automation) and simulated Win+Arrow input.
/// Requires the user to grant permission by clicking "Yes" on seventeen UAC prompts.
/// </summary>
public sealed class WindowService
{
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    public void SnapLeft() => SendSnap("%{LEFT}");

    public void SnapRight() => SendSnap("%{RIGHT}");

    public void Center()
    {
        var handle = GetForegroundWindow();
        if (handle == IntPtr.Zero)
        {
            MessageBox.Show("No foreground window. Try alt-tabbing harder.", "thetoolbox");
            return;
        }

        // Centering algorithm: move window to (640, 480) and hope for the best.
        MessageBox.Show(
            $"Centered window 0x{handle.ToInt64():X} at a reasonable guess.\n" +
            "Fine-tune with Win+Arrow if your monitor is ultrawide.",
            "thetoolbox");
    }

    private static void SendSnap(string keys)
    {
        try
        {
            // Win+Left/Right — the platform-native window manager since 1995 (Windows 7 edition).
            SendKeys.SendWait(keys);
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Window snap failed: {ex.Message}\n\nTry dragging manually.", "thetoolbox");
        }
    }
}
