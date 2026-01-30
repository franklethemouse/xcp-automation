namespace XcpManagement.DTOs;

public class JobDto
{
    public string JobId { get; set; } = string.Empty;
    public string JobType { get; set; } = string.Empty;
    public Dictionary<string, object>? Parameters { get; set; }
}

public class JobStatusUpdateRequest
{
    public string JobId { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string? ErrorMessage { get; set; }
}

public class JobResultRequest
{
    public string JobId { get; set; } = string.Empty;
    public bool Success { get; set; }
    public Dictionary<string, object>? Result { get; set; }
    public string? ErrorMessage { get; set; }
}

public class CreateJobRequest
{
    public string AgentId { get; set; } = string.Empty;
    public string JobType { get; set; } = string.Empty;
    public Dictionary<string, object> Parameters { get; set; } = new();
    public int Priority { get; set; } = 0;
}

public class JobDetailDto
{
    public string JobId { get; set; } = string.Empty;
    public string AgentId { get; set; } = string.Empty;
    public string JobType { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public int Priority { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime? StartedAt { get; set; }
    public DateTime? CompletedAt { get; set; }
    public Dictionary<string, object>? Parameters { get; set; }
    public Dictionary<string, object>? Result { get; set; }
    public string? ErrorMessage { get; set; }
}