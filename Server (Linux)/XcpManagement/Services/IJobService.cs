using XcpManagement.DTOs;

namespace XcpManagement.Services;

public interface IJobService
{
    Task<string> CreateJobAsync(CreateJobRequest request);
    Task<bool> UpdateJobStatusAsync(JobStatusUpdateRequest request);
    Task<bool> UpdateJobResultAsync(JobResultRequest request);
    Task<List<JobDetailDto>> GetJobsByAgentAsync(string agentId);
    Task<JobDetailDto?> GetJobAsync(string jobId);
    Task<List<JobDetailDto>> GetAllJobsAsync(string? status = null);
}