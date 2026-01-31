using XcpManagement.Data;

namespace XcpManagement.Services;

public interface IAgentService
{
    Task<List<Agent>> GetAllAgentsAsync();
}
