namespace XcpManagement.DTOs;

public class AgentRegisterRequest
{
    public string VmUuid { get; set; } = string.Empty;
    public string? VmName { get; set; }
    public string? Hostname { get; set; }
    public string OsType { get; set; } = string.Empty;
    public string? OsVersion { get; set; }
    public string AgentVersion { get; set; } = string.Empty;
    public Dictionary<string, string>? Tags { get; set; }
}

public class AgentRegisterResponse
{
    public string AgentId { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string Message { get; set; } = string.Empty;
}

public class AgentCheckInRequest
{
    public string AgentId { get; set; } = string.Empty;
    public string Status { get; set; } = "Active";
}

public class AgentCheckInResponse
{
    public List<JobDto> PendingJobs { get; set; } = new();
    public int CheckInInterval { get; set; } = 30;
}

public class AgentDto
{
    public string AgentId { get; set; } = string.Empty;
    public string VmUuid { get; set; } = string.Empty;
    public string? VmName { get; set; }
    public string? Hostname { get; set; }
    public string? OsType { get; set; }
    public string? OsVersion { get; set; }
    public string? AgentVersion { get; set; }
    public string Status { get; set; } = string.Empty;
    public DateTime? LastCheckIn { get; set; }
    public DateTime CreatedAt { get; set; }
}