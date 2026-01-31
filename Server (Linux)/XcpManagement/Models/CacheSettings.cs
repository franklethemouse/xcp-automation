namespace XcpManagement.Models;

public class CacheSettings
{
    public string SettingsId { get; set; } = Guid.NewGuid().ToString();
    public int RefreshIntervalSeconds { get; set; } = 60;
    public bool AutoRefreshEnabled { get; set; } = true;
    public DateTime LastRefresh { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;
}
