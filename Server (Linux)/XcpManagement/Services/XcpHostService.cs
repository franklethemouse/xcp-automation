using Microsoft.EntityFrameworkCore;
using XcpManagement.Data;

namespace XcpManagement.Services;

public class XcpHostService : IXcpHostService
{
    private readonly XcpDbContext _context;
    private readonly IXenApiService _xenApiService;
    private readonly ILogger<XcpHostService> _logger;

    public XcpHostService(XcpDbContext context, IXenApiService xenApiService, ILogger<XcpHostService> logger)
    {
        _context = context;
        _xenApiService = xenApiService;
        _logger = logger;
    }

    public async Task<List<XcpHost>> GetAllHostsAsync()
    {
        return await _context.XcpHosts.ToListAsync();
    }

    public async Task<XcpHost?> GetHostByIdAsync(string hostId)
    {
        return await _context.XcpHosts.FindAsync(hostId);
    }

    public async Task<XcpHost> AddHostAsync(string hostName, string hostUrl, string username, string password)
    {
        // Test connection first
        var canConnect = await _xenApiService.TestConnection(hostUrl, username, password);
        if (!canConnect)
        {
            throw new Exception("Cannot connect to XCP-ng host");
        }

        var host = new XcpHost
        {
            HostId = Guid.NewGuid().ToString(),
            HostName = hostName,
            HostUrl = hostUrl,
            Username = username,
            PasswordHash = EncryptPassword(password), // TODO: Implement proper encryption
            Active = true,
            CreatedAt = DateTime.UtcNow,
            LastConnected = DateTime.UtcNow
        };

        _context.XcpHosts.Add(host);
        await _context.SaveChangesAsync();

        _logger.LogInformation("Added XCP-ng host: {HostName} ({HostId})", hostName, host.HostId);
        return host;
    }

    public async Task<bool> UpdateHostAsync(XcpHost host)
    {
        host.UpdatedAt = DateTime.UtcNow;
        _context.XcpHosts.Update(host);
        await _context.SaveChangesAsync();
        return true;
    }

    public async Task<bool> DeleteHostAsync(string hostId)
    {
        var host = await _context.XcpHosts.FindAsync(hostId);
        if (host == null)
            return false;

        _context.XcpHosts.Remove(host);
        await _context.SaveChangesAsync();
        return true;
    }

    public async Task<bool> TestConnectionAsync(string hostUrl, string username, string password)
    {
        return await _xenApiService.TestConnection(hostUrl, username, password);
    }

    private string EncryptPassword(string password)
    {
        // TODO: Implement proper encryption (AES or similar)
        // For now, return as-is (NOT SECURE)
        return Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(password));
    }
}
