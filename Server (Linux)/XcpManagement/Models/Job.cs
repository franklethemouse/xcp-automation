using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace XcpManagement.Models;

[Table("AgentJobs")]
public class AgentJob
{
    [Key]
    [MaxLength(36)]
    public string JobId { get; set; } = Guid.NewGuid().ToString();

    [Required]
    [MaxLength(36)]
    public string AgentId { get; set; } = string.Empty;

    [Required]
    [MaxLength(50)]
    public string JobType { get; set; } = string.Empty;

    public string? Parameters { get; set; }

    [MaxLength(20)]
    public string Status { get; set; } = "Pending";

    public int Priority { get; set; } = 0;

    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;

    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;

    public DateTime? StartedAt { get; set; }

    public DateTime? CompletedAt { get; set; }

    public string? Result { get; set; }

    public string? ErrorMessage { get; set; }

    // Navigation property
    [ForeignKey("AgentId")]
    public virtual Agent? Agent { get; set; }
}

[Table("HypervisorJobs")]
public class HypervisorJob
{
    [Key]
    [MaxLength(36)]
    public string JobId { get; set; } = Guid.NewGuid().ToString();

    [Required]
    [MaxLength(50)]
    public string JobType { get; set; } = string.Empty;

    [MaxLength(255)]
    public string? VmUuid { get; set; }

    [MaxLength(36)]
    public string? HostId { get; set; }

    public string? Parameters { get; set; }

    [MaxLength(20)]
    public string Status { get; set; } = "Pending";

    [MaxLength(36)]
    public string? LinkedAgentJobId { get; set; }

    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;

    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;

    public DateTime? CompletedAt { get; set; }

    public string? Result { get; set; }

    public string? ErrorMessage { get; set; }
}

[Table("JobSchedules")]
public class JobSchedule
{
    [Key]
    [MaxLength(36)]
    public string ScheduleId { get; set; } = Guid.NewGuid().ToString();

    [Required]
    [MaxLength(50)]
    public string JobType { get; set; } = string.Empty;

    [Required]
    [MaxLength(20)]
    public string TargetType { get; set; } = string.Empty;

    [Required]
    [MaxLength(255)]
    public string TargetId { get; set; } = string.Empty;

    public string? Parameters { get; set; }

    [Required]
    [MaxLength(20)]
    public string ScheduleType { get; set; } = string.Empty;

    [MaxLength(255)]
    public string? ScheduleExpression { get; set; }

    public DateTime? NextRunTime { get; set; }

    public DateTime? LastRunTime { get; set; }

    public bool Active { get; set; } = true;

    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;

    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;
}