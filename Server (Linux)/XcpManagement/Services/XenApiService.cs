using XcpManagement.Models;
using XcpManagement.Data;
using Microsoft.EntityFrameworkCore;
using XenAPI;

namespace XcpManagement.Services;

public class XenApiService : IXenApiService
{
    private readonly XcpDbContext _context;
    private readonly ILogger<XenApiService> _logger;

    public XenApiService(XcpDbContext context, ILogger<XenApiService> logger)
    {
        _context = context;
        _logger = logger;
    }

    private Session CreateSession(string hostUrl, string username, string passwordHash)
    {
        // Decode base64 password (current implementation stores as base64)
        var password = System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(passwordHash));
        
        var session = new Session(hostUrl);
        session.login_with_password(username, password, "1.0", "XCP-Management");
        return session;
    }

    public async Task<bool> TestConnection(string hostUrl, string username, string password)
    {
        try
        {
            _logger.LogInformation("Testing connection to {HostUrl}", hostUrl);
            
            await Task.Run(() =>
            {
                using var session = CreateSession(hostUrl, username, password);
                session.logout();
            });
            
            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Connection test failed for {HostUrl}", hostUrl);
            return false;
        }
    }

    public async Task<List<VirtualMachine>> GetVirtualMachinesAsync(string hostId)
    {
        try
        {
            _logger.LogInformation("Getting VMs for host {HostId}", hostId);
            
            var host = await _context.XcpHosts.FindAsync(hostId);
            if (host == null)
            {
                _logger.LogWarning("Host {HostId} not found", hostId);
                return new List<VirtualMachine>();
            }

            var vms = new List<VirtualMachine>();

            await Task.Run(() =>
            {
                using var session = CreateSession(host.HostUrl, host.Username, host.PasswordHash);
                
                var vmRefs = XenAPI.VM.get_all(session);
                
                foreach (var vmRef in vmRefs)
                {
                    var vm = XenAPI.VM.get_record(session, vmRef);
                    
                    // Skip control domain and templates
                    if (vm.is_control_domain || vm.is_a_template || vm.is_a_snapshot)
                        continue;

                    var powerState = vm.power_state switch
                    {
                        vm_power_state.Running => VmPowerState.Running,
                        vm_power_state.Halted => VmPowerState.Halted,
                        vm_power_state.Suspended => VmPowerState.Suspended,
                        vm_power_state.Paused => VmPowerState.Paused,
                        _ => VmPowerState.Unknown
                    };

                    vms.Add(new VirtualMachine
                    {
                        Uuid = vm.uuid,
                        NameLabel = vm.name_label,
                        NameDescription = vm.name_description,
                        HostId = hostId,
                        HostName = host.HostName,
                        PowerState = powerState,
                        VcpusAtStartup = (int)vm.VCPUs_at_startup,
                        MemoryDynamic = vm.memory_dynamic_max,
                        MemoryStatic = vm.memory_static_max,
                        LastUpdated = DateTime.UtcNow
                    });
                }

                session.logout();
            });

            _logger.LogInformation("Retrieved {Count} VMs for host {HostId}", vms.Count, hostId);
            return vms;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to get VMs for host {HostId}", hostId);
            return new List<VirtualMachine>();
        }
    }

    public async Task<VirtualMachine?> GetVirtualMachineAsync(string hostId, string vmUuid)
    {
        var vms = await GetVirtualMachinesAsync(hostId);
        return vms.FirstOrDefault(vm => vm.Uuid == vmUuid);
    }

    public async Task<bool> StartVmAsync(string hostId, string vmUuid)
    {
        try
        {
            _logger.LogInformation("Starting VM {VmUuid} on host {HostId}", vmUuid, hostId);
            
            var host = await _context.XcpHosts.FindAsync(hostId);
            if (host == null) return false;

            await Task.Run(() =>
            {
                using var session = CreateSession(host.HostUrl, host.Username, host.PasswordHash);
                
                var vmRef = XenAPI.VM.get_by_uuid(session, vmUuid);
                XenAPI.VM.start(session, vmRef, false, false);
                
                session.logout();
            });

            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to start VM {VmUuid}", vmUuid);
            return false;
        }
    }

    public async Task<bool> StopVmAsync(string hostId, string vmUuid)
    {
        try
        {
            _logger.LogInformation("Stopping VM {VmUuid} on host {HostId}", vmUuid, hostId);
            
            var host = await _context.XcpHosts.FindAsync(hostId);
            if (host == null) return false;

            await Task.Run(() =>
            {
                using var session = CreateSession(host.HostUrl, host.Username, host.PasswordHash);
                
                var vmRef = XenAPI.VM.get_by_uuid(session, vmUuid);
                XenAPI.VM.clean_shutdown(session, vmRef);
                
                session.logout();
            });

            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to stop VM {VmUuid}", vmUuid);
            return false;
        }
    }

    public async Task<bool> RebootVmAsync(string hostId, string vmUuid)
    {
        try
        {
            _logger.LogInformation("Rebooting VM {VmUuid} on host {HostId}", vmUuid, hostId);
            
            var host = await _context.XcpHosts.FindAsync(hostId);
            if (host == null) return false;

            await Task.Run(() =>
            {
                using var session = CreateSession(host.HostUrl, host.Username, host.PasswordHash);
                
                var vmRef = XenAPI.VM.get_by_uuid(session, vmUuid);
                XenAPI.VM.clean_reboot(session, vmRef);
                
                session.logout();
            });

            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to reboot VM {VmUuid}", vmUuid);
            return false;
        }
    }

    public async Task<bool> SuspendVmAsync(string hostId, string vmUuid)
    {
        try
        {
            _logger.LogInformation("Suspending VM {VmUuid} on host {HostId}", vmUuid, hostId);
            
            var host = await _context.XcpHosts.FindAsync(hostId);
            if (host == null) return false;

            await Task.Run(() =>
            {
                using var session = CreateSession(host.HostUrl, host.Username, host.PasswordHash);
                
                var vmRef = XenAPI.VM.get_by_uuid(session, vmUuid);
                XenAPI.VM.suspend(session, vmRef);
                
                session.logout();
            });

            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to suspend VM {VmUuid}", vmUuid);
            return false;
        }
    }

    public async Task<bool> ResumeVmAsync(string hostId, string vmUuid)
    {
        try
        {
            _logger.LogInformation("Resuming VM {VmUuid} on host {HostId}", vmUuid, hostId);
            
            var host = await _context.XcpHosts.FindAsync(hostId);
            if (host == null) return false;

            await Task.Run(() =>
            {
                using var session = CreateSession(host.HostUrl, host.Username, host.PasswordHash);
                
                var vmRef = XenAPI.VM.get_by_uuid(session, vmUuid);
                XenAPI.VM.resume(session, vmRef, false, false);
                
                session.logout();
            });

            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to resume VM {VmUuid}", vmUuid);
            return false;
        }
    }
}
