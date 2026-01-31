using XenAPI;
using XcpManagement.Models;
using XcpManagement.Data;
using Microsoft.EntityFrameworkCore;

namespace XcpManagement.Services;

public class XenApiService : IXenApiService
{
    private readonly XcpDbContext _context;
    private readonly ILogger<XenApiService> _logger;
    private readonly Dictionary<string, Session> _sessions = new();

    public XenApiService(XcpDbContext context, ILogger<XenApiService> logger)
    {
        _context = context;
        _logger = logger;
    }

    public async Task<bool> TestConnection(string hostUrl, string username, string password)
    {
        try
        {
            var session = new Session(hostUrl);
            session.login_with_password(username, password, "1.0", "XcpManagement");
            session.logout();
            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to connect to XCP-ng host: {HostUrl}", hostUrl);
            return false;
        }
    }

    private async Task<Session?> GetSessionAsync(string hostId)
    {
        var host = await _context.XcpHosts.FirstOrDefaultAsync(h => h.HostId == hostId && h.Active);
        if (host == null) return null;

        if (_sessions.TryGetValue(hostId, out var existingSession))
        {
            try
            {
                var _ = existingSession.opaque_ref;
                return existingSession;
            }
            catch
            {
                _sessions.Remove(hostId);
            }
        }

        try
        {
            var session = new Session(host.HostUrl);
            var decryptedPassword = DecryptPassword(host.PasswordHash);
            session.login_with_password(host.Username, decryptedPassword, "1.0", "XcpManagement");
            _sessions[hostId] = session;
            
            await _context.XcpHosts.Where(h => h.HostId == hostId)
                .ExecuteUpdateAsync(h => h.SetProperty(x => x.LastConnected, DateTime.UtcNow));

            return session;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to create session for host {HostId}", hostId);
            return null;
        }
    }

    public async Task<List<VirtualMachine>> GetVirtualMachinesAsync(string hostId)
    {
        var session = await GetSessionAsync(hostId);
        if (session == null) return new List<VirtualMachine>();

        try
        {
            var host = await _context.XcpHosts.FindAsync(hostId);
            if (host == null) return new List<VirtualMachine>();

            var vms = VM.get_all_records(session);
            var result = new List<VirtualMachine>();

            foreach (var vmRecord in vms)
            {
                var vm = vmRecord.Value;
                if (vm.is_a_template || vm.is_control_domain) continue;

                var virtualMachine = new VirtualMachine
                {
                    Uuid = vm.uuid,
                    NameLabel = vm.name_label,
                    NameDescription = vm.name_description,
                    HostId = hostId,
                    HostName = host.HostName,
                    PowerState = MapPowerState(vm.power_state),
                    VcpusAtStartup = (int)vm.VCPUs_at_startup,
                    MemoryDynamic = vm.memory_dynamic_max,
                    MemoryStatic = vm.memory_static_max,
                    IsTemplate = vm.is_a_template,
                    IsControlDomain = vm.is_control_domain,
                    LastUpdated = DateTime.UtcNow
                };

                if (vm.guest_metrics != null && vm.guest_metrics.opaque_ref != "OpaqueRef:NULL")
                {
                    try
                    {
                        var metrics = VM_guest_metrics.get_record(session, vm.guest_metrics);
                        if (metrics.networks.ContainsKey("0/ip"))
                            virtualMachine.IpAddress = metrics.networks["0/ip"];
                        virtualMachine.OsVersion = metrics.os_version.ContainsKey("name") ? metrics.os_version["name"] : null;
                    }
                    catch { }
                }

                result.Add(virtualMachine);
            }

            return result;
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
        var session = await GetSessionAsync(hostId);
        if (session == null) return false;

        try
        {
            var vmRef = VM.get_by_uuid(session, vmUuid);
            VM.start(session, vmRef, false, false);
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
        var session = await GetSessionAsync(hostId);
        if (session == null) return false;

        try
        {
            var vmRef = VM.get_by_uuid(session, vmUuid);
            VM.clean_shutdown(session, vmRef);
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
        var session = await GetSessionAsync(hostId);
        if (session == null) return false;

        try
        {
            var vmRef = VM.get_by_uuid(session, vmUuid);
            VM.clean_reboot(session, vmRef);
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
        var session = await GetSessionAsync(hostId);
        if (session == null) return false;

        try
        {
            var vmRef = VM.get_by_uuid(session, vmUuid);
            VM.suspend(session, vmRef);
            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to suspend VM {VmUuid}", vmUuid);
            return false;
        }
    }

    private VmPowerState MapPowerState(vm_power_state state)
    {
        return state switch
        {
            vm_power_state.Running => VmPowerState.Running,
            vm_power_state.Halted => VmPowerState.Halted,
            vm_power_state.Suspended => VmPowerState.Suspended,
            vm_power_state.Paused => VmPowerState.Paused,
            _ => VmPowerState.Unknown
        };
    }

    private string DecryptPassword(string encryptedPassword)
    {
        // TODO: Implement proper decryption
        return System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(encryptedPassword));
    }
}
