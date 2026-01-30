using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace XcpManagement.Models;

[Table("XcpHosts")]
public class XcpHost
{
    [Key]
    [MaxLength(36)]
    public string HostId { get; set; } = Guid.NewGuid().ToString();

    [Required]
    [MaxLength(255)]
    public string HostName { get; set; } = string.Empty;

    [Required]
    [MaxLength(255)]
    public string HostUrl { get; set; } = string.Empty;

    [Required]
    [MaxLength(255)]
    public string Username { get; set; } = string.Empty;

    [Required]
    [MaxLength(255)]
    public string PasswordHash { get; set; } = string.Empty;

    public bool Active { get; set; } = true;

    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;

    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;

    public DateTime? LastConnected { get; set; }
}