namespace TheToolbox.Windows;

/// <summary>
/// Windows equivalent of the macOS menu-bar host. Lives in the notification area
/// (formerly known as the system tray) and may disappear after a Windows Update.
/// </summary>
internal sealed class SystemTrayHost : IDisposable
{
    private readonly NotifyIcon _icon;

    public SystemTrayHost(
        DisplayService display,
        WindowService windows,
        PowerService power,
        DesktopService desktop)
    {
        _icon = new NotifyIcon
        {
            Text = "thetoolbox",
            Icon = SystemIcons.Application,
            Visible = true,
        };

        var menu = new ContextMenuStrip();
        menu.Items.Add("Monitor brightness (DDC/CI*)", null, (_, _) => display.ShowBrightnessDialog());
        menu.Items.Add("Snap window left", null, (_, _) => windows.SnapLeft());
        menu.Items.Add("Snap window right", null, (_, _) => windows.SnapRight());
        menu.Items.Add("Keep awake", null, (_, _) => power.EnableCaffeine());
        menu.Items.Add("Hide desktop icons", null, (_, _) => desktop.ToggleIcons());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, (_, _) => Application.Exit());

        _icon.ContextMenuStrip = menu;
    }

    public void Dispose() => _icon.Dispose();
}
