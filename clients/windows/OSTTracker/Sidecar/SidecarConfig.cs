namespace OstTracker.Sidecar;

/// <summary>
/// Where the Python sidecar lives: embedded python-build-standalone runtime
/// next to the exe when packaged, otherwise the repo checkout (dev build).
/// Mirror of the macOS SidecarConfiguration.resolve().
/// </summary>
public static class SidecarConfig
{
    public sealed record Resolved(string PythonPath, string ScriptPath, string WorkingDirectory, Dictionary<string, string> ExtraEnvironment);

    public static Resolved Resolve() => Packaged() ?? Development();

    /// <summary>python-runtime\python.exe + backend\api.py shipped next to the exe.</summary>
    private static Resolved? Packaged()
    {
        string baseDir = AppContext.BaseDirectory;
        string python = Path.Combine(baseDir, "python-runtime", "python.exe");
        if (!File.Exists(python)) return null;

        string script = Path.Combine(baseDir, "backend", "api.py");
        string dataHome = DataHome.Dir;
        return new Resolved(python, script, baseDir, new Dictionary<string, string>
        {
            ["OST_TRACKER_HOME"] = dataHome,
        });
    }

    /// <summary>Dev: the repo checkout, driven by env vars like the Swift dev path.</summary>
    private static Resolved Development()
    {
        string repo = Environment.GetEnvironmentVariable("OST_SIDECAR_REPO") ?? LocateRepo();
        string python = Environment.GetEnvironmentVariable("OST_SIDECAR_PYTHON")
            ?? Path.Combine(repo, ".venv", "Scripts", "python.exe");
        string script = Environment.GetEnvironmentVariable("OST_SIDECAR_SCRIPT")
            ?? Path.Combine(repo, "backend", "api.py");
        return new Resolved(python, script, repo, new Dictionary<string, string>());
    }

    /// <summary>Walk up from the exe looking for the repo marker (dev builds).</summary>
    private static string LocateRepo()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "dev.sh")) && Directory.Exists(Path.Combine(dir.FullName, "backend")))
                return dir.FullName;
            dir = dir.Parent;
        }
        throw new DirectoryNotFoundException("repo checkout not found; set OST_SIDECAR_REPO");
    }
}

/// <summary>Per-OS data dir: %APPDATA%\ost-tracker (config.py mirrors this).</summary>
public static class DataHome
{
    public static string Dir
    {
        get
        {
            string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            string dir = Path.Combine(appData, "ost-tracker");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }
}
