using XcpManagement.Models;

namespace XcpManagement.Services;

public interface IVmCacheService
{
    List<VirtualMachine> GetAllVirtualMachines();
    List<VirtualMachine> GetVirtualMachinesByHost(string hostId);
    VirtualMachine? GetVirtualMachine(string vmUuid);
    Task RefreshCacheAsync();
    Task RefreshHostAsync(string hostId);
    DateTime GetLastRefreshTime();
    int GetRefreshIntervalSeconds();
    Task SetRefreshIntervalAsync(int seconds);
}
