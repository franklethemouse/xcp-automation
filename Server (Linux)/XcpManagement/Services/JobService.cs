using Microsoft.EntityFrameworkCore;
using XcpManagement.Data;

namespace XcpManagement.Services;

public class JobService : IJobService
{
    private readonly XcpDbContext _context;

    public JobService(XcpDbContext context)
    {
        _context = context;
    }

    public async Task<List<Job>> GetAllJobsAsync()
    {
        return await _context.Jobs.Include(j => j.Agent).ToListAsync();
    }
}
