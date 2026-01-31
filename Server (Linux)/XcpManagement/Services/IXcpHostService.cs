using XcpManagement.Data;

namespace XcpManagement.Services;

public interface IXcpHostService
{
    Task<List<XcpHost>> GetAllHostsAsync();
    Task<XcpHost?> GetHostByIdAsync(string hostId);
    Task<XcpHost> AddHostAsync(string hostName, string hostUrl, string username, string password);
    Task<bool> UpdateHostAsync(XcpHost host);
    Task<bool> DeleteHostAsync(string hostId);
    Task<bool> TestConnectionAsync(string hostUrl, string username, string password);
}
