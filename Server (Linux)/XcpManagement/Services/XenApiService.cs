using XcpManagement.Models;
using XcpManagement.Data;
using Microsoft.EntityFrameworkCore;
using System.Text;
using System.Xml.Linq;
using System.Net.Http;

namespace XcpManagement.Services;

public class XenApiService : IXenApiService
{
    private readonly XcpDbContext _context;
    private readonly ILogger<XenApiService> _logger;
    private readonly IHttpClientFactory _httpClientFactory;

    public XenApiService(XcpDbContext context, ILogger<XenApiService> logger, IHttpClientFactory httpClientFactory)
    {
        _context = context;
        _logger = logger;
        _httpClientFactory = httpClientFactory;
    }

    private async Task<string> CallXenApiAsync(string hostUrl, string method, params object[] parameters)
    {
        var xml = BuildXmlRpcRequest(method, parameters);

        var httpClient = _httpClientFactory.CreateClient("XenAPI");
        httpClient.Timeout = TimeSpan.FromSeconds(30);

        var content = new StringContent(xml, Encoding.UTF8, "text/xml");
        var response = await httpClient.PostAsync(hostUrl, content);

        return await response.Content.ReadAsStringAsync();
    }

    private string BuildXmlRpcRequest(string method, params object[] parameters)
    {
        var xml = new StringBuilder();
        xml.AppendLine("<?xml version=\"1.0\"?>");
        xml.AppendLine("<methodCall>");
        xml.AppendLine($"  <methodName>{method}</methodName>");
        xml.AppendLine("  <params>");

        foreach (var param in parameters)
        {
            xml.AppendLine("    <param>");
            xml.AppendLine($"      <value><string>{param}</string></value>");
            xml.AppendLine("    </param>");
        }

        xml.AppendLine("  </params>");
        xml.AppendLine("</methodCall>");

        return xml.ToString();
    }

    // Extracts a single string value from the top-level "Value" member
    private string ExtractStringValue(string xmlResponse)
    {
        try
        {
            var doc = XDocument.Parse(xmlResponse);
            var valueElement = doc.Descendants("member")
                .FirstOrDefault(m => m.Element("name")?.Value == "Value")
                ?.Element("value");

            if (valueElement == null) return string.Empty;

            var stringValue = valueElement.Element("string")?.Value;
            if (!string.IsNullOrEmpty(stringValue)) return stringValue;

            var bareValue = valueElement.Nodes().OfType<XText>().FirstOrDefault()?.Value;
            return bareValue ?? string.Empty;
        }
        catch
        {
            return string.Empty;
        }
    }

    // Extracts a flat key/value dictionary from a single struct XElement
    private Dictionary<string, string> ParseStruct(XElement structElement)
    {
        var result = new Dictionary<string, string>();
        foreach (var member in structElement.Elements("member"))
        {
            var name = member.Element("name")?.Value;
            if (name == null) continue;

            var valueElement = member.Element("value");
            if (valueElement == null) continue;

            var typedValue = valueElement.Elements().FirstOrDefault()?.Value;
            if (typedValue != null)
            {
                result[name] = typedValue;
                continue;
            }

            var bareValue = valueElement.Nodes().OfType<XText>().FirstOrDefault()?.Value;
            if (bareValue != null)
                result[name] = bareValue;
        }
        return result;
    }

    // Extracts a dictionary of VM ref -> VM record struct from VM.get_all_records response
    private Dictionary<string, Dictionary<string, string>> ExtractAllRecords(string xmlResponse)
    {
        var result = new Dictionary<string, Dictionary<string, string>>();
        try
        {
            var doc = XDocument.Parse(xmlResponse);

            // Find the top-level Value struct which contains one member per VM ref
            var topStruct = doc.Descendants("member")
                .FirstOrDefault(m => m.Element("name")?.Value == "Value")
                ?.Element("value")
                ?.Element("struct");

            if (topStruct == null) return result;

            foreach (var member in topStruct.Elements("member"))
            {
                var vmRef = member.Element("name")?.Value;
                if (vmRef == null) continue;

                var vmStruct = member.Element("value")?.Element("struct");
                if (vmStruct == null) continue;

                result[vmRef] = ParseStruct(vmStruct);
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to parse VM.get_all_records response");
        }
        return result;
    }

    private Dictionary<string, string> ExtractStructValue(string xmlResponse)
    {
        try
        {
            var doc = XDocument.Parse(xmlResponse);
            var structElement = doc.Descendants("member")
                .FirstOrDefault(m => m.Element("name")?.Value == "Value")
                ?.Element("value")
                ?.Element("struct");

            if (structElement == null) return new Dictionary<string, string>();
            return ParseStruct(structElement);
        }
        catch
        {
            return new Dictionary<string, string>();
        }
    }

    public async Task<bool> TestConnection(string hostUrl, string username, string password)
    {
        try
        {
            _logger.LogInformation("Testing connection to {HostUrl}", hostUrl);

            var response = await CallXenApiAsync(hostUrl, "session.login_with_password", username, password, "1.0", "XCP-Management");
            var sessionRef = ExtractStringValue(response);

            if (string.IsNullOrEmpty(sessionRef))
                return false;

            await CallXenApiAsync(hostUrl, "session.logout", sessionRef);
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

            var password = Encoding.UTF8.GetString(Convert.FromBase64String(host.PasswordHash));

            var loginResponse = await CallXenApiAsync(host.HostUrl, "session.login_with_password", host.Username, password, "1.0", "XCP-Management");
            var sessionRef = ExtractStringValue(loginResponse);

            if (string.IsNullOrEmpty(sessionRef))
            {
                _logger.LogError("Failed to login to {HostUrl}", host.HostUrl);
                return new List<VirtualMachine>();
            }

            // Single call to get all VM records at once
            var allRecordsResponse = await CallXenApiAsync(host.HostUrl, "VM.get_all_records", sessionRef);
            var allRecords = ExtractAllRecords(allRecordsResponse);

            var vms = new List<VirtualMachine>();

            foreach (var (vmRef, vm) in allRecords)
            {
                // Filter out control domain, templates, and snapshots
                if (vm.GetValueOrDefault("is_control_domain", "false") == "true" ||
                    vm.GetValueOrDefault("is_a_template", "false") == "true" ||
                    vm.GetValueOrDefault("is_a_snapshot", "false") == "true")
                    continue;

                var powerStateStr = vm.GetValueOrDefault("power_state", "Unknown").ToLower();
                var powerState = powerStateStr switch
                {
                    "running" => VmPowerState.Running,
                    "halted" => VmPowerState.Halted,
                    "suspended" => VmPowerState.Suspended,
                    "paused" => VmPowerState.Paused,
                    _ => VmPowerState.Unknown
                };

                vms.Add(new VirtualMachine
                {
                    Uuid = vm.GetValueOrDefault("uuid", ""),
                    NameLabel = vm.GetValueOrDefault("name_label", ""),
                    NameDescription = vm.GetValueOrDefault("name_description", ""),
                    HostId = hostId,
                    HostName = host.HostName,
                    PowerState = powerState,
                    VcpusAtStartup = int.TryParse(vm.GetValueOrDefault("VCPUs_at_startup", "0"), out var vcpus) ? vcpus : 0,
                    MemoryDynamic = long.TryParse(vm.GetValueOrDefault("memory_dynamic_max", "0"), out var memDyn) ? memDyn : 0,
                    MemoryStatic = long.TryParse(vm.GetValueOrDefault("memory_static_max", "0"), out var memStat) ? memStat : 0,
                    LastUpdated = DateTime.UtcNow
                });
            }

            await CallXenApiAsync(host.HostUrl, "session.logout", sessionRef);

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

    private async Task<bool> ExecuteVmOperationAsync(string hostId, string vmUuid, string operation, params object[] additionalParams)
    {
        try
        {
            var host = await _context.XcpHosts.FindAsync(hostId);
            if (host == null) return false;

            var password = Encoding.UTF8.GetString(Convert.FromBase64String(host.PasswordHash));

            var loginResponse = await CallXenApiAsync(host.HostUrl, "session.login_with_password", host.Username, password, "1.0", "XCP-Management");
            var sessionRef = ExtractStringValue(loginResponse);

            if (string.IsNullOrEmpty(sessionRef)) return false;

            var vmRefResponse = await CallXenApiAsync(host.HostUrl, "VM.get_by_uuid", sessionRef, vmUuid);
            var vmRef = ExtractStringValue(vmRefResponse);

            if (string.IsNullOrEmpty(vmRef))
            {
                await CallXenApiAsync(host.HostUrl, "session.logout", sessionRef);
                return false;
            }

            var parameters = new List<object> { sessionRef, vmRef };
            parameters.AddRange(additionalParams);

            await CallXenApiAsync(host.HostUrl, operation, parameters.ToArray());
            await CallXenApiAsync(host.HostUrl, "session.logout", sessionRef);

            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to execute {Operation} on VM {VmUuid}", operation, vmUuid);
            return false;
        }
    }

    public async Task<bool> StartVmAsync(string hostId, string vmUuid)
    {
        _logger.LogInformation("Starting VM {VmUuid} on host {HostId}", vmUuid, hostId);
        return await ExecuteVmOperationAsync(hostId, vmUuid, "VM.start", "false", "false");
    }

    public async Task<bool> StopVmAsync(string hostId, string vmUuid)
    {
        _logger.LogInformation("Stopping VM {VmUuid} on host {HostId}", vmUuid, hostId);
        return await ExecuteVmOperationAsync(hostId, vmUuid, "VM.clean_shutdown");
    }

    public async Task<bool> RebootVmAsync(string hostId, string vmUuid)
    {
        _logger.LogInformation("Rebooting VM {VmUuid} on host {HostId}", vmUuid, hostId);
        return await ExecuteVmOperationAsync(hostId, vmUuid, "VM.clean_reboot");
    }

    public async Task<bool> SuspendVmAsync(string hostId, string vmUuid)
    {
        _logger.LogInformation("Suspending VM {VmUuid} on host {HostId}", vmUuid, hostId);
        return await ExecuteVmOperationAsync(hostId, vmUuid, "VM.suspend");
    }

    public async Task<bool> ResumeVmAsync(string hostId, string vmUuid)
    {
        _logger.LogInformation("Resuming VM {VmUuid} on host {HostId}", vmUuid, hostId);
        return await ExecuteVmOperationAsync(hostId, vmUuid, "VM.resume", "false", "false");
    }
}