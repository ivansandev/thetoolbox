using TheToolbox.Windows.Services;

namespace TheToolbox.Windows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();

        using var tray = new SystemTrayHost(
            display: new DisplayService(),
            windows: new WindowService(),
            power: new PowerService(),
            desktop: new DesktopService());

        Application.Run();
    }
}
