using System.Collections.Concurrent;
using XcpManagement.Models;

namespace XcpManagement.Services;

public class VmCacheService : IVmCacheService
{
    private readonly ConcurrentDictionary<string, VirtualMachine> _cache = new();
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<VmCacheService> _logger;
    private DateTime _lastRefresh = DateTime.MinValue;
    private int _refreshIntervalSeconds = 60;

    public VmCacheService(IServiceScopeFactory scopeFactory, ILogger<VmCacheService> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    public List<VirtualMachine> GetAllVirtualMachines()
    {
        return _cache.Values.ToList();
    }

    public List<VirtualMachine> GetVirtualMachinesByHost(string hostId)
    {
        return _cache.Values.Where(vm => vm.HostId == hostId).ToList();
    }

    public VirtualMachine? GetVirtualMachine(string vmUuid)
    {
        _cache.TryGetValue(vmUuid, out var vm);
        return vm;
    }

    public async Task RefreshCacheAsync()
    {
        using var scope = _scopeFactory.CreateScope();
        var xenApiService = scope.ServiceProvider.GetRequiredService<IXenApiService>();
        var hostService = scope.ServiceProvider.GetRequiredService<IXcpHostService>();

        var hosts = await hostService.GetAllHostsAsync();
        var allVms = new List<VirtualMachine>();

        foreach (var host in hosts.Where(h => h.Active))
        {
            try
            {
                var vms = await xenApiService.GetVirtualMachinesAsync(host.HostId);
                allVms.AddRange(vms);
                _logger.LogInformation("Refreshed {Count} VMs from host {HostName}", vms.Count, host.HostName);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Failed to refresh VMs from host {HostName}", host.HostName);
            }
        }

        // Update cache
        _cache.Clear();
        foreach (var vm in allVms)
        {
            _cache[vm.Uuid] = vm;
        }

        _lastRefresh = DateTime.UtcNow;
        _logger.LogInformation("Cache refreshed: {TotalVms} VMs from {HostCount} hosts", allVms.Count, hosts.Count);
    }

    public async Task RefreshHostAsync(string hostId)
    {
        using var scope = _scopeFactory.CreateScope();
        var xenApiService = scope.ServiceProvider.GetRequiredService<IXenApiService>();

        try
        {
            var vms = await xenApiService.GetVirtualMachinesAsync(hostId);
            
            // Remove old VMs from this host
            var oldVms = _cache.Values.Where(vm => vm.HostId == hostId).Select(vm => vm.Uuid).ToList();
            foreach (var uuid in oldVms)
            {
                _cache.TryRemove(uuid, out _);
            }

            // Add new VMs
            foreach (var vm in vms)
            {
                _cache[vm.Uuid] = vm;
            }

            _logger.LogInformation("Refreshed {Count} VMs for host {HostId}", vms.Count, hostId);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to refresh host {HostId}", hostId);
        }
    }

    public DateTime GetLastRefreshTime()
    {
        return _lastRefresh;
    }

    public int GetRefreshIntervalSeconds()
    {
        return _refreshIntervalSeconds;
    }

    public Task SetRefreshIntervalAsync(int seconds)
    {
        _refreshIntervalSeconds = Math.Max(30, Math.Min(600, seconds)); // Between 30s and 10min
        _logger.LogInformation("Refresh interval updated to {Seconds} seconds", _refreshIntervalSeconds);
        return Task.CompletedTask;
    }
}
