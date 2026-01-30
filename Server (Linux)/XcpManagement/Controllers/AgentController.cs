using Microsoft.AspNetCore.Mvc;
using XcpManagement.DTOs;
using XcpManagement.Services;

namespace XcpManagement.Controllers;

[ApiController]
[Route("api/[controller]")]
public class AgentController : ControllerBase
{
    private readonly IAgentService _agentService;
    private readonly ILogger<AgentController> _logger;

    public AgentController(IAgentService agentService, ILogger<AgentController> logger)
    {
        _agentService = agentService;
        _logger = logger;
    }

    [HttpPost("register")]
    public async Task<ActionResult<AgentRegisterResponse>> Register([FromBody] AgentRegisterRequest request)
    {
        try
        {
            var response = await _agentService.RegisterAgentAsync(request);
            return Ok(response);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error registering agent");
            return StatusCode(500, new { error = "Failed to register agent" });
        }
    }

    [HttpPost("checkin")]
    public async Task<ActionResult<AgentCheckInResponse>> CheckIn([FromBody] AgentCheckInRequest request)
    {
        try
        {
            var response = await _agentService.CheckInAsync(request);
            return Ok(response);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error during check-in");
            return StatusCode(500, new { error = "Check-in failed" });
        }
    }

    [HttpGet]
    public async Task<ActionResult<List<AgentDto>>> GetAllAgents()
    {
        try
        {
            var agents = await _agentService.GetAllAgentsAsync();
            return Ok(agents);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error retrieving agents");
            return StatusCode(500, new { error = "Failed to retrieve agents" });
        }
    }

    [HttpGet("{agentId}")]
    public async Task<ActionResult<AgentDto>> GetAgent(string agentId)
    {
        try
        {
            var agent = await _agentService.GetAgentAsync(agentId);
            if (agent == null)
            {
                return NotFound(new { error = "Agent not found" });
            }
            return Ok(agent);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error retrieving agent");
            return StatusCode(500, new { error = "Failed to retrieve agent" });
        }
    }

    [HttpDelete("{agentId}")]
    public async Task<ActionResult> DeleteAgent(string agentId)
    {
        try
        {
            var result = await _agentService.DeleteAgentAsync(agentId);
            if (!result)
            {
                return NotFound(new { error = "Agent not found" });
            }
            return Ok(new { message = "Agent deleted successfully" });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error deleting agent");
            return StatusCode(500, new { error = "Failed to delete agent" });
        }
    }
}