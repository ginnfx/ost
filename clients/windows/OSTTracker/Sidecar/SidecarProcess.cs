using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace OstTracker.Sidecar;

/// <summary>
/// Spawns the Python FastAPI sidecar and owns its lifetime. The child is put
/// into a Job Object with KILL_ON_JOB_CLOSE, so the whole sidecar tree dies
/// whenever this process exits — the Windows counterpart of the macOS
/// kill(-pgid, SIGTERM) teardown. The sidecar's own watchdog is a second layer.
/// </summary>
public sealed class SidecarProcess : IDisposable
{
    public static SidecarProcess Instance { get; } = new();

    public int Port { get; private set; }
    private string _token = "";

    private Process? _process;
    private IntPtr _job = IntPtr.Zero;
    private readonly object _gate = new();

    // --- Job Object plumbing -------------------------------------------------

    private const int JobObjectExtendedLimitInfoClass = 9;
    private const uint JobObjectLimitKillOnJobClose = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string? lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr hJob, int jobObjectInformationClass,
        IntPtr lpJobObjectInformation, uint cbJobObjectInformationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr hObject);

    // --- lifecycle ------------------------------------------------------------

    /// <summary>Spawn the sidecar and block until its handshake line appears.</summary>
    public async Task<(int Port, string Token)> LaunchAsync(CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_process is { HasExited: false })
                return (Port, _token);
        }

        var config = SidecarConfig.Resolve();

        _job = CreateJobObject(IntPtr.Zero, null);
        if (_job == IntPtr.Zero)
            throw new InvalidOperationException("CreateJobObject failed");

        var info = new JobObjectExtendedLimitInformation
        {
            BasicLimitInformation = new JobObjectBasicLimitInformation
            {
                LimitFlags = JobObjectLimitKillOnJobClose,
            },
        };
        IntPtr infoBuffer = Marshal.AllocHGlobal(Marshal.SizeOf<JobObjectExtendedLimitInformation>());
        try
        {
            Marshal.StructureToPtr(info, infoBuffer, false);
            if (!SetInformationJobObject(_job, JobObjectExtendedLimitInfoClass, infoBuffer,
                    (uint)Marshal.SizeOf<JobObjectExtendedLimitInformation>()))
                throw new InvalidOperationException("SetInformationJobObject failed");
        }
        finally
        {
            Marshal.FreeHGlobal(infoBuffer);
        }

        var psi = new ProcessStartInfo
        {
            FileName = config.PythonPath,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = config.WorkingDirectory,
        };
        psi.ArgumentList.Add(config.ScriptPath);
        foreach (var (k, v) in config.ExtraEnvironment)
            psi.Environment[k] = v;

        _process = Process.Start(psi) ?? throw new InvalidOperationException("failed to start sidecar");
        if (!AssignProcessToJobObject(_job, _process.Handle))
            throw new InvalidOperationException("AssignProcessToJobObject failed");

        // Drain stderr so a full pipe can't wedge the sidecar.
        _ = Task.Run(() => _process.StandardError.ReadToEndAsync(ct));

        // Read stdout until the handshake line.
        var buffer = new StringBuilder();
        var deadline = DateTime.UtcNow.AddSeconds(20);
        while (DateTime.UtcNow < deadline)
        {
            ct.ThrowIfCancellationRequested();
            int n = await _process.StandardOutput.BaseStream.ReadAsync(bufferBytes.AsMemory(0, 4096), ct);
            if (n == 0)
            {
                if (_process.HasExited)
                    throw new InvalidOperationException($"sidecar exited before handshake (code {_process.ExitCode})");
                continue;
            }
            buffer.Append(Encoding.UTF8.GetString(bufferBytes, 0, n));
            int newline = buffer.ToString().IndexOf('\n');
            if (newline >= 0)
            {
                string line = buffer.ToString(0, newline).Trim();
                buffer.Remove(0, newline + 1);
                if (line.StartsWith("OSTTRACKER_READY"))
                {
                    var shake = ParseHandshake(line);
                    Port = shake.Port;
                    _token = shake.Token;
                    _ = Task.Run(() => DrainStdoutAsync());
                    return shake;
                }
            }
        }
        throw new TimeoutException("sidecar handshake timed out");
    }

    private readonly byte[] bufferBytes = new byte[4096];

    private async Task DrainStdoutAsync()
    {
        try
        {
            var rest = new byte[4096];
            while (_process is { HasExited: false })
            {
                int n = await _process.StandardOutput.BaseStream.ReadAsync(rest.AsMemory(0, rest.Length));
                if (n == 0) break;
            }
        }
        catch (Exception)
        {
            // pipe closed with the process — expected on teardown
        }
    }

    public static (int Port, string Token) ParseHandshake(string line)
    {
        int port = 0;
        string token = "";
        foreach (var field in line.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (field.StartsWith("port=", StringComparison.Ordinal)) int.TryParse(field["port=".Length..], out port);
            else if (field.StartsWith("token=", StringComparison.Ordinal)) token = field["token=".Length..];
        }
        if (port == 0 || token.Length == 0)
            throw new FormatException($"malformed handshake: {line}");
        return (port, token);
    }

    /// <summary>Kill the whole sidecar tree (Job Object) and release handles.</summary>
    public void Shutdown()
    {
        lock (_gate)
        {
            if (_job != IntPtr.Zero)
            {
                TerminateJobObject(_job, 0);
                CloseHandle(_job);
                _job = IntPtr.Zero;
            }
            if (_process != null)
            {
                try { if (!_process.HasExited) _process.Kill(); } catch { /* already gone */ }
                _process.Dispose();
                _process = null;
            }
        }
    }

    public void Dispose() => Shutdown();
}
