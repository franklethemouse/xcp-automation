using Microsoft.AspNetCore.Mvc;
using XcpManagement.Services;

namespace XcpManagement.Controllers;

[ApiController]
[Route("api/[controller]")]
public class HostsController : ControllerBase
{
    private readonly IXcpHostService _hostService;
    private readonly ILogger<HostsController> _logger;

    public HostsController(IXcpHostService hostService, ILogger<HostsController> logger)
    {
        _hostService = hostService;
        _logger = logger;
    }

    [HttpGet]
    public async Task<IActionResult> GetAllHosts()
    {
        try
        {
            var hosts = await _hostService.GetAllHostsAsync();
            return Ok(hosts);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to get hosts");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("{id}")]
    public async Task<IActionResult> GetHost(string id)
    {
        try
        {
            var host = await _hostService.GetHostByIdAsync(id);
            if (host == null)
                return NotFound();
            return Ok(host);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to get host {HostId}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost]
    public async Task<IActionResult> AddHost([FromBody] AddHostRequest request)
    {
        try
        {
            var host = await _hostService.AddHostAsync(
                request.HostName,
                request.HostUrl,
                request.Username,
                request.Password
            );
            return Ok(host);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to add host");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpDelete("{id}")]
    public async Task<IActionResult> DeleteHost(string id)
    {
        try
        {
            var result = await _hostService.DeleteHostAsync(id);
            if (!result)
                return NotFound();
            return Ok();
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to delete host {HostId}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("{id}/test")]
    public async Task<IActionResult> TestConnection(string id)
    {
        try
        {
            var host = await _hostService.GetHostByIdAsync(id);
            if (host == null)
                return NotFound();

            var result = await _hostService.TestConnectionAsync(host.HostUrl, host.Username, host.PasswordHash);
            return Ok(new { success = result });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to test connection for host {HostId}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }
}

public class AddHostRequest
{
    public string HostName { get; set; } = "";
    public string HostUrl { get; set; } = "";
    public string Username { get; set; } = "";
    public string Password { get; set; } = "";
}
