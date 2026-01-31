using Microsoft.EntityFrameworkCore;

namespace XcpManagement.Data;

public class XcpDbContext : DbContext
{
    public XcpDbContext(DbContextOptions<XcpDbContext> options) : base(options) { }

    public DbSet<User> Users { get; set; }
    public DbSet<XcpHost> XcpHosts { get; set; }
    public DbSet<Agent> Agents { get; set; }
    public DbSet<Job> Jobs { get; set; }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);

        modelBuilder.Entity<User>(entity =>
        {
            entity.HasKey(e => e.UserId);
            entity.HasIndex(e => e.Username).IsUnique();
        });

        modelBuilder.Entity<XcpHost>(entity =>
        {
            entity.HasKey(e => e.HostId);
        });

        modelBuilder.Entity<Agent>(entity =>
        {
            entity.HasKey(e => e.AgentId);
            entity.HasOne(e => e.Host)
                .WithMany()
                .HasForeignKey(e => e.HostId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<Job>(entity =>
        {
            entity.HasKey(e => e.JobId);
            entity.HasOne(e => e.Agent)
                .WithMany()
                .HasForeignKey(e => e.AgentId)
                .OnDelete(DeleteBehavior.SetNull);
        });
    }
}

public class User
{
    public string UserId { get; set; } = Guid.NewGuid().ToString();
    public string Username { get; set; } = string.Empty;
    public string PasswordHash { get; set; } = string.Empty;
    public string Email { get; set; } = string.Empty;
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime? LastLogin { get; set; }
}

public class XcpHost
{
    public string HostId { get; set; } = Guid.NewGuid().ToString();
    public string HostName { get; set; } = string.Empty;
    public string HostUrl { get; set; } = string.Empty;
    public string Username { get; set; } = string.Empty;
    public string PasswordHash { get; set; } = string.Empty;
    public bool Active { get; set; } = true;
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime? UpdatedAt { get; set; }
    public DateTime? LastConnected { get; set; }
}

public class Agent
{
    public string AgentId { get; set; } = Guid.NewGuid().ToString();
    public string HostId { get; set; } = string.Empty;
    public string AgentName { get; set; } = string.Empty;
    public string IpAddress { get; set; } = string.Empty;
    public string Status { get; set; } = "offline";
    public DateTime RegisteredAt { get; set; } = DateTime.UtcNow;
    public DateTime? LastSeen { get; set; }
    public XcpHost? Host { get; set; }
}

public class Job
{
    public string JobId { get; set; } = Guid.NewGuid().ToString();
    public string? AgentId { get; set; }
    public string JobType { get; set; } = string.Empty;
    public string Status { get; set; } = "pending";
    public string? Payload { get; set; }
    public string? Result { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime? StartedAt { get; set; }
    public DateTime? CompletedAt { get; set; }
    public Agent? Agent { get; set; }
}
