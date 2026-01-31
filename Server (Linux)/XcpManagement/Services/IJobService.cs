using XcpManagement.Data;

namespace XcpManagement.Services;

public interface IJobService
{
    Task<List<Job>> GetAllJobsAsync();
}
