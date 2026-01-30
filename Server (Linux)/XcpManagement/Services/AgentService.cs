using Microsoft.EntityFrameworkCore;
using System.Text.Json;
using XcpManagement.Data;
using XcpManagement.DTOs;
using XcpManagement.Models;

namespace XcpManagement.Services;

public class AgentService : IAgentService
{
    private readonly XcpDbContext _context;
    private readonly ILogger<AgentService> _logger;

    public AgentService(XcpDbContext context, ILogger<AgentService> logger)
    {
        _context = context;
        _logger = logger;
    }

    public async Task<AgentRegisterResponse> RegisterAgentAsync(AgentRegisterRequest request)
    {
        try
        {
            // Check if agent already exists
            var existingAgent = await _context.Agents
                .FirstOrDefaultAsync(a => a.VmUuid == request.VmUuid);

            if (existingAgent != null)
            {
                // Update existing agent
                existingAgent.VmName = request.VmName;
                existingAgent.Hostname = request.Hostname;
                existingAgent.OsType = request.OsType;
                existingAgent.OsVersion = request.OsVersion;
                existingAgent.AgentVersion = request.AgentVersion;
                existingAgent.Tags = request.Tags != null ? JsonSerializer.Serialize(request.Tags) : null;
                existingAgent.LastCheckIn = DateTime.UtcNow;
                existingAgent.Status = "Active";
                existingAgent.UpdatedAt = DateTime.UtcNow;

                await _context.SaveChangesAsync();

                _logger.LogInformation("Agent re-registered: {AgentId}", existingAgent.AgentId);

                return new AgentRegisterResponse
                {
                    AgentId = existingAgent.AgentId,
                    Status = "Updated",
                    Message = "Agent re-registered successfully"
                };
            }

            // Create new agent
            var agent = new Agent
            {
                AgentId = Guid.NewGuid().ToString(),
                VmUuid = request.VmUuid,
                VmName = request.VmName,
                Hostname = request.Hostname,
                OsType = request.OsType,
                OsVersion = request.OsVersion,
                AgentVersion = request.AgentVersion,
                Tags = request.Tags != null ? JsonSerializer.Serialize(request.Tags) : null,
                LastCheckIn = DateTime.UtcNow,
                Status = "Active"
            };

            _context.Agents.Add(agent);
            await _context.SaveChangesAsync();

            _logger.LogInformation("New agent registered: {AgentId}", agent.AgentId);

            return new AgentRegisterResponse
            {
                AgentId = agent.AgentId,
                Status = "Registered",
                Message = "Agent registered successfully"
            };
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error registering agent");
            throw;
        }
    }

    public async Task<AgentCheckInResponse> CheckInAsync(AgentCheckInRequest request)
    {
        try
        {
            var agent = await _context.Agents.FindAsync(request.AgentId);
            if (agent == null)
            {
                throw new Exception($"Agent not found: {request.AgentId}");
            }

            // Update last check-in
            agent.LastCheckIn = DateTime.UtcNow;
            agent.Status = request.Status;
            agent.UpdatedAt = DateTime.UtcNow;

            // Get pending jobs for this agent
            var pendingJobs = await _context.AgentJobs
                .Where(j => j.AgentId == request.AgentId && j.Status == "Pending")
                .OrderByDescending(j => j.Priority)
                .ThenBy(j => j.CreatedAt)
                .Take(10)
                .ToListAsync();

            // Mark jobs as InProgress
            foreach (var job in pendingJobs)
            {
                job.Status = "InProgress";
                job.StartedAt = DateTime.UtcNow;
                job.UpdatedAt = DateTime.UtcNow;
            }

            await _context.SaveChangesAsync();

            var jobDtos = pendingJobs.Select(j => new JobDto
            {
                JobId = j.JobId,
                JobType = j.JobType,
                Parameters = string.IsNullOrEmpty(j.Parameters)
                    ? null
                    : JsonSerializer.Deserialize<Dictionary<string, object>>(j.Parameters)
            }).ToList();

            return new AgentCheckInResponse
            {
                PendingJobs = jobDtos,
                CheckInInterval = 30
            };
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error during agent check-in");
            throw;
        }
    }

    public async Task<List<AgentDto>> GetAllAgentsAsync()
    {
        var agents = await _context.Agents
            .OrderByDescending(a => a.LastCheckIn)
            .ToListAsync();

        return agents.Select(a => new AgentDto
        {
            AgentId = a.AgentId,
            VmUuid = a.VmUuid,
            VmName = a.VmName,
            Hostname = a.Hostname,
            OsType = a.OsType,
            OsVersion = a.OsVersion,
            AgentVersion = a.AgentVersion,
            Status = a.Status,
            LastCheckIn = a.LastCheckIn,
            CreatedAt = a.CreatedAt
        }).ToList();
    }

    public async Task<AgentDto?> GetAgentAsync(string agentId)
    {
        var agent = await _context.Agents.FindAsync(agentId);
        if (agent == null) return null;

        return new AgentDto
        {
            AgentId = agent.AgentId,
            VmUuid = agent.VmUuid,
            VmName = agent.VmName,
            Hostname = agent.Hostname,
            OsType = agent.OsType,
            OsVersion = agent.OsVersion,
            AgentVersion = agent.AgentVersion,
            Status = agent.Status,
            LastCheckIn = agent.LastCheckIn,
            CreatedAt = agent.CreatedAt
        };
    }

    public async Task<bool> DeleteAgentAsync(string agentId)
    {
        var agent = await _context.Agents.FindAsync(agentId);
        if (agent == null) return false;

        _context.Agents.Remove(agent);
        await _context.SaveChangesAsync();

        _logger.LogInformation("Agent deleted: {AgentId}", agentId);
        return true;
    }

    public async Task UpdateLastCheckInAsync(string agentId)
    {
        var agent = await _context.Agents.FindAsync(agentId);
        if (agent != null)
        {
            agent.LastCheckIn = DateTime.UtcNow;
            agent.UpdatedAt = DateTime.UtcNow;
            await _context.SaveChangesAsync();
        }
    }
}