using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace XcpManagement.Models;

[Table("RegisteredAgents")]
public class Agent
{
    [Key]
    [MaxLength(36)]
    public string AgentId { get; set; } = Guid.NewGuid().ToString();

    [Required]
    [MaxLength(255)]
    public string VmUuid { get; set; } = string.Empty;

    [MaxLength(255)]
    public string? VmName { get; set; }

    [MaxLength(255)]
    public string? Hostname { get; set; }

    [MaxLength(50)]
    public string? OsType { get; set; }

    [MaxLength(255)]
    public string? OsVersion { get; set; }

    [MaxLength(50)]
    public string? AgentVersion { get; set; }

    public string? Tags { get; set; }

    public DateTime? LastCheckIn { get; set; }

    [MaxLength(20)]
    public string Status { get; set; } = "Active";

    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;

    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;

    // Navigation property
    public virtual ICollection<AgentJob> Jobs { get; set; } = new List<AgentJob>();
}