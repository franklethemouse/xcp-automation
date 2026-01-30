using Microsoft.EntityFrameworkCore;
using XcpManagement.Models;

namespace XcpManagement.Data;

public class XcpDbContext : DbContext
{
    public XcpDbContext(DbContextOptions<XcpDbContext> options) : base(options)
    {
    }

    public DbSet<Agent> Agents { get; set; }
    public DbSet<AgentJob> AgentJobs { get; set; }
    public DbSet<HypervisorJob> HypervisorJobs { get; set; }
    public DbSet<JobSchedule> JobSchedules { get; set; }
    public DbSet<User> Users { get; set; }
    public DbSet<XcpHost> XcpHosts { get; set; }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);

        // Agent configuration
        modelBuilder.Entity<Agent>(entity =>
        {
            entity.HasKey(e => e.AgentId);
            entity.HasIndex(e => e.VmUuid).IsUnique();
            entity.HasIndex(e => e.Status);
            entity.HasIndex(e => e.LastCheckIn);
            entity.HasIndex(e => e.OsType);

            entity.Property(e => e.CreatedAt).HasDefaultValueSql("CURRENT_TIMESTAMP");
            entity.Property(e => e.UpdatedAt).HasDefaultValueSql("CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP");
        });

        // AgentJob configuration
        modelBuilder.Entity<AgentJob>(entity =>
        {
            entity.HasKey(e => e.JobId);
            entity.HasIndex(e => new { e.AgentId, e.Status });
            entity.HasIndex(e => new { e.Status, e.Priority });
            entity.HasIndex(e => e.CreatedAt);

            entity.Property(e => e.CreatedAt).HasDefaultValueSql("CURRENT_TIMESTAMP");
            entity.Property(e => e.UpdatedAt).HasDefaultValueSql("CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP");

            entity.HasOne(e => e.Agent)
                .WithMany(a => a.Jobs)
                .HasForeignKey(e => e.AgentId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        // HypervisorJob configuration
        modelBuilder.Entity<HypervisorJob>(entity =>
        {
            entity.HasKey(e => e.JobId);
            entity.HasIndex(e => e.Status);
            entity.HasIndex(e => e.VmUuid);
            entity.HasIndex(e => e.CreatedAt);

            entity.Property(e => e.CreatedAt).HasDefaultValueSql("CURRENT_TIMESTAMP");
            entity.Property(e => e.UpdatedAt).HasDefaultValueSql("CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP");
        });

        // JobSchedule configuration
        modelBuilder.Entity<JobSchedule>(entity =>
        {
            entity.HasKey(e => e.ScheduleId);
            entity.HasIndex(e => new { e.Active, e.NextRunTime });
            entity.HasIndex(e => new { e.TargetType, e.TargetId });

            entity.Property(e => e.CreatedAt).HasDefaultValueSql("CURRENT_TIMESTAMP");
            entity.Property(e => e.UpdatedAt).HasDefaultValueSql("CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP");
        });

        // User configuration
        modelBuilder.Entity<User>(entity =>
        {
            entity.HasKey(e => e.UserId);
            entity.HasIndex(e => e.Username).IsUnique();
            entity.HasIndex(e => e.Email).IsUnique();

            entity.Property(e => e.CreatedAt).HasDefaultValueSql("CURRENT_TIMESTAMP");
            entity.Property(e => e.UpdatedAt).HasDefaultValueSql("CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP");
        });

        // XcpHost configuration
        modelBuilder.Entity<XcpHost>(entity =>
        {
            entity.HasKey(e => e.HostId);
            entity.HasIndex(e => e.Active);

            entity.Property(e => e.CreatedAt).HasDefaultValueSql("CURRENT_TIMESTAMP");
            entity.Property(e => e.UpdatedAt).HasDefaultValueSql("CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP");
        });
    }
}