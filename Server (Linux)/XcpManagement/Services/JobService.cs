using Microsoft.EntityFrameworkCore;
using System.Text.Json;
using XcpManagement.Data;
using XcpManagement.DTOs;
using XcpManagement.Models;

namespace XcpManagement.Services;

public class JobService : IJobService
{
    private readonly XcpDbContext _context;
    private readonly ILogger<JobService> _logger;

    public JobService(XcpDbContext context, ILogger<JobService> logger)
    {
        _context = context;
        _logger = logger;
    }

    public async Task<string> CreateJobAsync(CreateJobRequest request)
    {
        try
        {
            var agent = await _context.Agents.FindAsync(request.AgentId);
            if (agent == null)
            {
                throw new Exception($"Agent not found: {request.AgentId}");
            }

            var job = new AgentJob
            {
                JobId = Guid.NewGuid().ToString(),
                AgentId = request.AgentId,
                JobType = request.JobType,
                Parameters = JsonSerializer.Serialize(request.Parameters),
                Priority = request.Priority,
                Status = "Pending"
            };

            _context.AgentJobs.Add(job);
            await _context.SaveChangesAsync();

            _logger.LogInformation("Job created: {JobId} for agent {AgentId}", job.JobId, request.AgentId);

            return job.JobId;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error creating job");
            throw;
        }
    }

    public async Task<bool> UpdateJobStatusAsync(JobStatusUpdateRequest request)
    {
        try
        {
            var job = await _context.AgentJobs.FindAsync(request.JobId);
            if (job == null) return false;

            job.Status = request.Status;
            job.ErrorMessage = request.ErrorMessage;
            job.UpdatedAt = DateTime.UtcNow;

            if (request.Status == "InProgress" && job.StartedAt == null)
            {
                job.StartedAt = DateTime.UtcNow;
            }

            if (request.Status == "Completed" || request.Status == "Failed")
            {
                job.CompletedAt = DateTime.UtcNow;
            }

            await _context.SaveChangesAsync();

            _logger.LogInformation("Job status updated: {JobId} -> {Status}", request.JobId, request.Status);

            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error updating job status");
            throw;
        }
    }

    public async Task<bool> UpdateJobResultAsync(JobResultRequest request)
    {
        try
        {
            var job = await _context.AgentJobs.FindAsync(request.JobId);
            if (job == null) return false;

            job.Status = request.Success ? "Completed" : "Failed";
            job.Result = request.Result != null ? JsonSerializer.Serialize(request.Result) : null;
            job.ErrorMessage = request.ErrorMessage;
            job.CompletedAt = DateTime.UtcNow;
            job.UpdatedAt = DateTime.UtcNow;

            await _context.SaveChangesAsync();

            _logger.LogInformation("Job result updated: {JobId} -> {Status}", request.JobId, job.Status);

            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error updating job result");
            throw;
        }
    }

    public async Task<List<JobDetailDto>> GetJobsByAgentAsync(string agentId)
    {
        var jobs = await _context.AgentJobs
            .Where(j => j.AgentId == agentId)
            .OrderByDescending(j => j.CreatedAt)
            .ToListAsync();

        return jobs.Select(MapToDto).ToList();
    }

    public async Task<JobDetailDto?> GetJobAsync(string jobId)
    {
        var job = await _context.AgentJobs.FindAsync(jobId);
        return job == null ? null : MapToDto(job);
    }

    public async Task<List<JobDetailDto>> GetAllJobsAsync(string? status = null)
    {
        var query = _context.AgentJobs.AsQueryable();

        if (!string.IsNullOrEmpty(status))
        {
            query = query.Where(j => j.Status == status);
        }

        var jobs = await query
            .OrderByDescending(j => j.CreatedAt)
            .ToListAsync();

        return jobs.Select(MapToDto).ToList();
    }

    private JobDetailDto MapToDto(AgentJob job)
    {
        return new JobDetailDto
        {
            JobId = job.JobId,
            AgentId = job.AgentId,
            JobType = job.JobType,
            Status = job.Status,
            Priority = job.Priority,
            CreatedAt = job.CreatedAt,
            StartedAt = job.StartedAt,
            CompletedAt = job.CompletedAt,
            Parameters = string.IsNullOrEmpty(job.Parameters)
                ? null
                : JsonSerializer.Deserialize<Dictionary<string, object>>(job.Parameters),
            Result = string.IsNullOrEmpty(job.Result)
                ? null
                : JsonSerializer.Deserialize<Dictionary<string, object>>(job.Result),
            ErrorMessage = job.ErrorMessage
        };
    }
}