namespace XcpManagement.Models;

public class VirtualMachine
{
    public string Uuid { get; set; } = string.Empty;
    public string NameLabel { get; set; } = string.Empty;
    public string NameDescription { get; set; } = string.Empty;
    public string HostId { get; set; } = string.Empty;
    public string HostName { get; set; } = string.Empty;
    public VmPowerState PowerState { get; set; }
    public int VcpusAtStartup { get; set; }
    public long MemoryDynamic { get; set; }
    public long MemoryStatic { get; set; }
    public List<VmDisk> Disks { get; set; } = new();
    public List<VmNetwork> Networks { get; set; } = new();
    public Dictionary<string, string> Tags { get; set; } = new();
    public DateTime LastUpdated { get; set; }
    public string? IpAddress { get; set; }
    public string? OsVersion { get; set; }
    public bool IsTemplate { get; set; }
    public bool IsControlDomain { get; set; }
}

public enum VmPowerState
{
    Halted,
    Running,
    Suspended,
    Paused,
    Unknown
}

public class VmDisk
{
    public string Uuid { get; set; } = string.Empty;
    public string DeviceName { get; set; } = string.Empty;
    public long SizeBytes { get; set; }
    public string StorageRepository { get; set; } = string.Empty;
    public bool Bootable { get; set; }
}

public class VmNetwork
{
    public string Uuid { get; set; } = string.Empty;
    public string Device { get; set; } = string.Empty;
    public string MacAddress { get; set; } = string.Empty;
    public string NetworkName { get; set; } = string.Empty;
    public bool Connected { get; set; }
}
