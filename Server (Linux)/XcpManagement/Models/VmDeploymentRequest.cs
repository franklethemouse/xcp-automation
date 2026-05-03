namespace XcpManagement.Models;

public class VmDeploymentRequest
{
    public string VmName { get; set; } = string.Empty;
    public string TemplateUuid { get; set; } = string.Empty;
    public string TemplateName { get; set; } = string.Empty;
    public string HostId { get; set; } = string.Empty;
    public int CpuCount { get; set; } = 2;
    public int CoresPerSocket { get; set; } = 1;
    public long MemoryMB { get; set; } = 2048;
    public long DiskSizeGB { get; set; } = 50;
    public string NetworkUuid { get; set; } = string.Empty;
    public string NetworkName { get; set; } = string.Empty;
    public bool StartAfterCreation { get; set; } = true;
    public DateTime? ScheduledFor { get; set; }
    public string RequestedBy { get; set; } = "admin";
}

public class VmTemplate
{
    public string Uuid { get; set; } = string.Empty;
    public string NameLabel { get; set; } = string.Empty;
    public string NameDescription { get; set; } = string.Empty;
    public string OsVersion { get; set; } = string.Empty;
    public bool IsTemplate { get; set; }
    public long MemoryStaticMax { get; set; }
    public int VcpusMax { get; set; }
}

public class XcpNetwork
{
    public string Uuid { get; set; } = string.Empty;
    public string NameLabel { get; set; } = string.Empty;
    public string NameDescription { get; set; } = string.Empty;
    public string Bridge { get; set; } = string.Empty;
}

public class DeploymentProgress
{
    public string Stage { get; set; } = string.Empty;
    public int PercentComplete { get; set; }
    public string Message { get; set; } = string.Empty;
    public bool IsComplete { get; set; }
    public bool HasError { get; set; }
    public string? ErrorMessage { get; set; }
    public string? NewVmUuid { get; set; }
}
