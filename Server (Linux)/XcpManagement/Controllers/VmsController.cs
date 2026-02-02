using Microsoft.AspNetCore.Mvc;
using XcpManagement.Services;

namespace XcpManagement.Controllers;

[ApiController]
[Route("api/[controller]")]
public class VmsController : ControllerBase
{
    private readonly IVmCacheService _vmCache;
    private readonly IXenApiService _xenApi;
    private readonly ILogger<VmsController> _logger;

    public VmsController(IVmCacheService vmCache, IXenApiService xenApi, ILogger<VmsController> logger)
    {
        _vmCache = vmCache;
        _xenApi = xenApi;
        _logger = logger;
    }

    [HttpGet]
    public IActionResult GetAllVms()
    {
        try
        {
            var vms = _vmCache.GetAllVirtualMachines();
            return Ok(vms);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to get VMs");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("{uuid}")]
    public IActionResult GetVm(string uuid)
    {
        try
        {
            var vm = _vmCache.GetVirtualMachine(uuid);
            if (vm == null)
                return NotFound();
            return Ok(vm);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to get VM {VmUuid}", uuid);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("{uuid}/start")]
    public async Task<IActionResult> StartVm(string uuid)
    {
        try
        {
            var vm = _vmCache.GetVirtualMachine(uuid);
            if (vm == null)
                return NotFound();

            var result = await _xenApi.StartVmAsync(vm.HostId, uuid);
            if (!result)
                return StatusCode(500, new { error = "Failed to start VM" });

            return Ok(new { success = true });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to start VM {VmUuid}", uuid);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("{uuid}/stop")]
    public async Task<IActionResult> StopVm(string uuid)
    {
        try
        {
            var vm = _vmCache.GetVirtualMachine(uuid);
            if (vm == null)
                return NotFound();

            var result = await _xenApi.StopVmAsync(vm.HostId, uuid);
            if (!result)
                return StatusCode(500, new { error = "Failed to stop VM" });

            return Ok(new { success = true });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to stop VM {VmUuid}", uuid);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("{uuid}/reboot")]
    public async Task<IActionResult> RebootVm(string uuid)
    {
        try
        {
            var vm = _vmCache.GetVirtualMachine(uuid);
            if (vm == null)
                return NotFound();

            var result = await _xenApi.RebootVmAsync(vm.HostId, uuid);
            if (!result)
                return StatusCode(500, new { error = "Failed to reboot VM" });

            return Ok(new { success = true });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to reboot VM {VmUuid}", uuid);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("{uuid}/suspend")]
    public async Task<IActionResult> SuspendVm(string uuid)
    {
        try
        {
            var vm = _vmCache.GetVirtualMachine(uuid);
            if (vm == null)
                return NotFound();

            var result = await _xenApi.SuspendVmAsync(vm.HostId, uuid);
            if (!result)
                return StatusCode(500, new { error = "Failed to suspend VM" });

            return Ok(new { success = true });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to suspend VM {VmUuid}", uuid);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("{uuid}/resume")]
    public async Task<IActionResult> ResumeVm(string uuid)
    {
        try
        {
            var vm = _vmCache.GetVirtualMachine(uuid);
            if (vm == null)
                return NotFound();

            var result = await _xenApi.ResumeVmAsync(vm.HostId, uuid);
            if (!result)
                return StatusCode(500, new { error = "Failed to resume VM" });

            return Ok(new { success = true });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to resume VM {VmUuid}", uuid);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("refresh")]
    public async Task<IActionResult> RefreshCache()
    {
        try
        {
            await _vmCache.RefreshCacheAsync();
            return Ok(new { success = true });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to refresh cache");
            return StatusCode(500, new { error = ex.Message });
        }
    }
}
