using XcpManagement.Models;

namespace XcpManagement.Services;

public interface IXenApiService
{
    Task<bool> TestConnection(string hostUrl, string username, string password);
    Task<List<VirtualMachine>> GetVirtualMachinesAsync(string hostId);
    Task<VirtualMachine?> GetVirtualMachineAsync(string hostId, string vmUuid);
    Task<bool> StartVmAsync(string hostId, string vmUuid);
    Task<bool> StopVmAsync(string hostId, string vmUuid);
    Task<bool> RebootVmAsync(string hostId, string vmUuid);
    Task<bool> SuspendVmAsync(string hostId, string vmUuid);
    Task<bool> ResumeVmAsync(string hostId, string vmUuid);
}
