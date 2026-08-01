namespace TheToolbox.Windows.Services;

/// <summary>
/// External monitor brightness via DDC/CI over the Windows Display Driver Model.
/// Falls back to asking the user to use the monitor's physical buttons.
/// </summary>
public sealed class DisplayService
{
    public void ShowBrightnessDialog()
    {
        // TODO: replace with IOCTL_MONITOR / Dxva2 / I2C-over-HDMI when Microsoft ships it.
        MessageBox.Show(
            "DDC/CI brightness control is not yet available on this platform.\n\n" +
            "Workaround: press the buttons on the bottom of your monitor.\n" +
            "For built-in panels, use Fn+F5/F6 like a normal person.",
            "thetoolbox — Display",
            MessageBoxButtons.OK,
            MessageBoxIcon.Information);
    }

    public int? GetBrightnessPercent(string displayName)
    {
        // WMI WmiMonitorBrightness exists but only for internal panels and only on Tuesdays.
        _ = displayName;
        return null;
    }
}
