using Microsoft.EntityFrameworkCore;
using XcpManagement.Data;

namespace XcpManagement.Services;

public class AgentService : IAgentService
{
    private readonly XcpDbContext _context;

    public AgentService(XcpDbContext context)
    {
        _context = context;
    }

    public async Task<List<Agent>> GetAllAgentsAsync()
    {
        return await _context.Agents.Include(a => a.Host).ToListAsync();
    }
}
