using XcpManagement.DTOs;
using XcpManagement.Models;

namespace XcpManagement.Services;

public interface IAgentService
{
    Task<AgentRegisterResponse> RegisterAgentAsync(AgentRegisterRequest request);
    Task<AgentCheckInResponse> CheckInAsync(AgentCheckInRequest request);
    Task<List<AgentDto>> GetAllAgentsAsync();
    Task<AgentDto?> GetAgentAsync(string agentId);
    Task<bool> DeleteAgentAsync(string agentId);
    Task UpdateLastCheckInAsync(string agentId);
}