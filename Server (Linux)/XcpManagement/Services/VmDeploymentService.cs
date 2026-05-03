using XcpManagement.Models;
using XcpManagement.Data;
using Microsoft.EntityFrameworkCore;
using System.Text;
using System.Xml.Linq;

namespace XcpManagement.Services;

public class VmDeploymentService : IVmDeploymentService
{
    private readonly XcpDbContext _context;
    private readonly ILogger<VmDeploymentService> _logger;
    private readonly IHttpClientFactory _httpClientFactory;

    public VmDeploymentService(
        XcpDbContext context,
        ILogger<VmDeploymentService> logger,
        IHttpClientFactory httpClientFactory)
    {
        _context = context;
        _logger = logger;
        _httpClientFactory = httpClientFactory;
    }

    public async Task<List<VmTemplate>> GetTemplatesAsync(string hostId)
    {
        var host = await _context.XcpHosts.FindAsync(hostId);
        if (host == null)
            throw new Exception($"Host {hostId} not found");

        var sessionId = await LoginAsync(host.HostUrl, host.Username, host.PasswordHash);
        
        try
        {
            // Get all VM records
            var vmRefs = await CallXenApiAsync(host.HostUrl, sessionId, "VM.get_all");
            var vmRefsDoc = XDocument.Parse(vmRefs);
            var vmRefsList = vmRefsDoc.Descendants("value")
                .Where(v => v.Descendants("string").Any())
                .Select(v => v.Descendants("string").First().Value)
                .ToList();

            var templates = new List<VmTemplate>();

            foreach (var vmRef in vmRefsList)
            {
                // Get VM record
                var vmRecord = await CallXenApiAsync(host.HostUrl, sessionId, "VM.get_record", vmRef);
                var vmDoc = XDocument.Parse(vmRecord);

                var isTemplate = vmDoc.Descendants("member")
                    .FirstOrDefault(m => m.Element("name")?.Value == "is_a_template")
                    ?.Element("value")?.Element("boolean")?.Value == "1";

                var isControlDomain = vmDoc.Descendants("member")
                    .FirstOrDefault(m => m.Element("name")?.Value == "is_control_domain")
                    ?.Element("value")?.Element("boolean")?.Value == "1";

                var isSnapshot = vmDoc.Descendants("member")
                    .FirstOrDefault(m => m.Element("name")?.Value == "is_a_snapshot")
                    ?.Element("value")?.Element("boolean")?.Value == "1";

                // Only include actual templates (not control domains or snapshots)
                if (isTemplate == true && isControlDomain == false && isSnapshot == false)
                {
                    var nameLabel = vmDoc.Descendants("member")
                        .FirstOrDefault(m => m.Element("name")?.Value == "name_label")
                        ?.Element("value")?.Element("string")?.Value ?? "Unknown";

                    var nameDescription = vmDoc.Descendants("member")
                        .FirstOrDefault(m => m.Element("name")?.Value == "name_description")
                        ?.Element("value")?.Element("string")?.Value ?? "";

                    var memoryStaticMax = vmDoc.Descendants("member")
                        .FirstOrDefault(m => m.Element("name")?.Value == "memory_static_max")
                        ?.Element("value")?.Element("string")?.Value ?? "0";

                    var vcpusMax = vmDoc.Descendants("member")
                        .FirstOrDefault(m => m.Element("name")?.Value == "VCPUs_max")
                        ?.Element("value")?.Element("string")?.Value ?? "1";

                    templates.Add(new VmTemplate
                    {
                        Uuid = vmRef,
                        NameLabel = nameLabel,
                        NameDescription = nameDescription,
                        IsTemplate = true,
                        MemoryStaticMax = long.TryParse(memoryStaticMax, out var mem) ? mem : 0,
                        VcpusMax = int.TryParse(vcpusMax, out var vcpu) ? vcpu : 1
                    });
                }
            }

            return templates.OrderBy(t => t.NameLabel).ToList();
        }
        finally
        {
            await LogoutAsync(host.HostUrl, sessionId);
        }
    }

    public async Task<List<XcpNetwork>> GetNetworksAsync(string hostId)
    {
        var host = await _context.XcpHosts.FindAsync(hostId);
        if (host == null)
            throw new Exception($"Host {hostId} not found");

        var sessionId = await LoginAsync(host.HostUrl, host.Username, host.PasswordHash);
        
        try
        {
            var networkRefs = await CallXenApiAsync(host.HostUrl, sessionId, "network.get_all");
            var networkRefsDoc = XDocument.Parse(networkRefs);
            var networkRefsList = networkRefsDoc.Descendants("value")
                .Where(v => v.Descendants("string").Any())
                .Select(v => v.Descendants("string").First().Value)
                .ToList();

            var networks = new List<XcpNetwork>();

            foreach (var netRef in networkRefsList)
            {
                var netRecord = await CallXenApiAsync(host.HostUrl, sessionId, "network.get_record", netRef);
                var netDoc = XDocument.Parse(netRecord);

                var nameLabel = netDoc.Descendants("member")
                    .FirstOrDefault(m => m.Element("name")?.Value == "name_label")
                    ?.Element("value")?.Element("string")?.Value ?? "Unknown";

                var nameDescription = netDoc.Descendants("member")
                    .FirstOrDefault(m => m.Element("name")?.Value == "name_description")
                    ?.Element("value")?.Element("string")?.Value ?? "";

                var bridge = netDoc.Descendants("member")
                    .FirstOrDefault(m => m.Element("name")?.Value == "bridge")
                    ?.Element("value")?.Element("string")?.Value ?? "";

                networks.Add(new XcpNetwork
                {
                    Uuid = netRef,
                    NameLabel = nameLabel,
                    NameDescription = nameDescription,
                    Bridge = bridge
                });
            }

            return networks.OrderBy(n => n.NameLabel).ToList();
        }
        finally
        {
            await LogoutAsync(host.HostUrl, sessionId);
        }
    }

    public async Task<DeploymentProgress> DeployVmAsync(VmDeploymentRequest request, IProgress<DeploymentProgress>? progress = null)
    {
        var host = await _context.XcpHosts.FindAsync(request.HostId);
        if (host == null)
            throw new Exception($"Host {request.HostId} not found");

        var sessionId = await LoginAsync(host.HostUrl, host.Username, host.PasswordHash);
        
        try
        {
            // Stage 1: Clone template
            progress?.Report(new DeploymentProgress
            {
                Stage = "Cloning template",
                PercentComplete = 10,
                Message = $"Creating VM '{request.VmName}' from template..."
            });

            var cloneResult = await CallXenApiAsync(host.HostUrl, sessionId, "VM.clone", request.TemplateUuid, request.VmName);
            var cloneDoc = XDocument.Parse(cloneResult);
            var newVmRef = cloneDoc.Descendants("value").FirstOrDefault()?.Descendants("string").FirstOrDefault()?.Value;
            
            if (string.IsNullOrEmpty(newVmRef))
                throw new Exception("Failed to clone template - no VM reference returned");

            // Stage 2: Mark as not a template
            progress?.Report(new DeploymentProgress
            {
                Stage = "Configuring VM",
                PercentComplete = 30,
                Message = "Converting from template to VM..."
            });

            await CallXenApiAsync(host.HostUrl, sessionId, "VM.set_is_a_template", newVmRef, "false");

            // Stage 3: Configure CPUs
            progress?.Report(new DeploymentProgress
            {
                Stage = "Configuring CPUs",
                PercentComplete = 40,
                Message = $"Setting {request.CpuCount} CPUs with {request.CoresPerSocket} cores per socket..."
            });

            var totalVcpus = request.CpuCount * request.CoresPerSocket;
            await CallXenApiAsync(host.HostUrl, sessionId, "VM.set_VCPUs_max", newVmRef, totalVcpus.ToString());
            await CallXenApiAsync(host.HostUrl, sessionId, "VM.set_VCPUs_at_startup", newVmRef, totalVcpus.ToString());
            
            // Set platform:cores-per-socket
            await CallXenApiAsync(host.HostUrl, sessionId, "VM.add_to_platform", newVmRef, "cores-per-socket", request.CoresPerSocket.ToString());

            // Stage 4: Configure Memory
            progress?.Report(new DeploymentProgress
            {
                Stage = "Configuring Memory",
                PercentComplete = 50,
                Message = $"Setting memory to {request.MemoryMB} MB..."
            });

            var memoryBytes = request.MemoryMB * 1024 * 1024;
            await CallXenApiAsync(host.HostUrl, sessionId, "VM.set_memory_limits", newVmRef, 
                memoryBytes.ToString(), memoryBytes.ToString(), memoryBytes.ToString(), memoryBytes.ToString());

            // Stage 5: Configure Storage (if disk size specified and different from template)
            progress?.Report(new DeploymentProgress
            {
                Stage = "Configuring Storage",
                PercentComplete = 60,
                Message = "Setting up virtual disks..."
            });

            // Get VBDs (Virtual Block Devices)
            var vbdsResult = await CallXenApiAsync(host.HostUrl, sessionId, "VM.get_VBDs", newVmRef);
            var vbdsDoc = XDocument.Parse(vbdsResult);
            var vbdRefs = vbdsDoc.Descendants("value")
                .Where(v => v.Descendants("string").Any())
                .Select(v => v.Descendants("string").First().Value)
                .ToList();

            foreach (var vbdRef in vbdRefs)
            {
                // Get VBD type
                var vbdRecord = await CallXenApiAsync(host.HostUrl, sessionId, "VBD.get_record", vbdRef);
                var vbdDoc = XDocument.Parse(vbdRecord);
                
                var vbdType = vbdDoc.Descendants("member")
                    .FirstOrDefault(m => m.Element("name")?.Value == "type")
                    ?.Element("value")?.Element("string")?.Value;

                // Only resize Disk type VBDs (not CD drives)
                if (vbdType == "Disk")
                {
                    var vdiRef = vbdDoc.Descendants("member")
                        .FirstOrDefault(m => m.Element("name")?.Value == "VDI")
                        ?.Element("value")?.Element("string")?.Value;

                    if (!string.IsNullOrEmpty(vdiRef))
                    {
                        var newSizeBytes = request.DiskSizeGB * 1024L * 1024L * 1024L;
                        await CallXenApiAsync(host.HostUrl, sessionId, "VDI.resize", vdiRef, newSizeBytes.ToString());
                    }
                }
            }

            // Stage 6: Configure Network
            if (!string.IsNullOrEmpty(request.NetworkUuid))
            {
                progress?.Report(new DeploymentProgress
                {
                    Stage = "Configuring Network",
                    PercentComplete = 70,
                    Message = "Attaching to network..."
                });

                // Get VIFs (Virtual Interfaces) and update network
                var vifsResult = await CallXenApiAsync(host.HostUrl, sessionId, "VM.get_VIFs", newVmRef);
                var vifsDoc = XDocument.Parse(vifsResult);
                var vifRefs = vifsDoc.Descendants("value")
                    .Where(v => v.Descendants("string").Any())
                    .Select(v => v.Descendants("string").First().Value)
                    .ToList();

                // Destroy existing VIFs
                foreach (var vifRef in vifRefs)
                {
                    await CallXenApiAsync(host.HostUrl, sessionId, "VIF.destroy", vifRef);
                }

                // Create new VIF with selected network
                var vifParams = new Dictionary<string, string>
                {
                    { "device", "0" },
                    { "network", request.NetworkUuid },
                    { "VM", newVmRef },
                    { "MAC", "" },
                    { "MTU", "1500" },
                    { "other_config", "" },
                    { "qos_algorithm_type", "" },
                    { "qos_algorithm_params", "" }
                };

                await CallXenApiAsync(host.HostUrl, sessionId, "VIF.create", SerializeStruct(vifParams));
            }

            // Stage 7: Provision VM (makes it ready to boot)
            progress?.Report(new DeploymentProgress
            {
                Stage = "Provisioning",
                PercentComplete = 80,
                Message = "Provisioning VM for first boot..."
            });

            await CallXenApiAsync(host.HostUrl, sessionId, "VM.provision", newVmRef);

            // Stage 8: Start VM if requested
            if (request.StartAfterCreation)
            {
                progress?.Report(new DeploymentProgress
                {
                    Stage = "Starting VM",
                    PercentComplete = 90,
                    Message = "Starting VM..."
                });

                await CallXenApiAsync(host.HostUrl, sessionId, "VM.start", newVmRef, "false", "false");
            }

            // Complete
            var result = new DeploymentProgress
            {
                Stage = "Complete",
                PercentComplete = 100,
                Message = $"VM '{request.VmName}' deployed successfully!",
                IsComplete = true,
                NewVmUuid = newVmRef
            };

            progress?.Report(result);
            return result;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "VM deployment failed for {VmName}", request.VmName);
            
            var errorResult = new DeploymentProgress
            {
                Stage = "Failed",
                PercentComplete = 0,
                Message = "Deployment failed",
                HasError = true,
                ErrorMessage = ex.Message,
                IsComplete = true
            };

            progress?.Report(errorResult);
            return errorResult;
        }
        finally
        {
            await LogoutAsync(host.HostUrl, sessionId);
        }
    }

    public async Task<bool> ValidateDeploymentRequestAsync(VmDeploymentRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.VmName))
            throw new Exception("VM name is required");

        if (string.IsNullOrWhiteSpace(request.TemplateUuid))
            throw new Exception("Template must be selected");

        if (string.IsNullOrWhiteSpace(request.HostId))
            throw new Exception("Host must be selected");

        if (request.CpuCount < 1 || request.CpuCount > 64)
            throw new Exception("CPU count must be between 1 and 64");

        if (request.CoresPerSocket < 1 || request.CoresPerSocket > 16)
            throw new Exception("Cores per socket must be between 1 and 16");

        if (request.MemoryMB < 512)
            throw new Exception("Memory must be at least 512 MB");

        if (request.DiskSizeGB < 1)
            throw new Exception("Disk size must be at least 1 GB");

        return true;
    }

    // Helper methods
    private async Task<string> LoginAsync(string hostUrl, string username, string password)
    {
        var loginResult = await CallXenApiAsync(hostUrl, null, "session.login_with_password", username, password);
        var doc = XDocument.Parse(loginResult);
        var sessionId = doc.Descendants("value").FirstOrDefault()?.Descendants("string").FirstOrDefault()?.Value;
        
        if (string.IsNullOrEmpty(sessionId))
            throw new Exception("Failed to login to XCP-ng host");

        return sessionId;
    }

    private async Task LogoutAsync(string hostUrl, string sessionId)
    {
        try
        {
            await CallXenApiAsync(hostUrl, sessionId, "session.logout");
        }
        catch
        {
            // Ignore logout errors
        }
    }

    private async Task<string> CallXenApiAsync(string hostUrl, string? sessionId, string method, params string[] parameters)
    {
        var xml = BuildXmlRpcRequest(method, sessionId, parameters);
        
        var httpClient = _httpClientFactory.CreateClient("XenAPI");
        var content = new StringContent(xml, Encoding.UTF8, "text/xml");
        
        var response = await httpClient.PostAsync(hostUrl, content);
        var responseXml = await response.Content.ReadAsStringAsync();

        // Check for XMLRPC fault
        if (responseXml.Contains("<name>faultCode</name>"))
        {
            var doc = XDocument.Parse(responseXml);
            var faultString = doc.Descendants("member")
                .FirstOrDefault(m => m.Element("name")?.Value == "faultString")
                ?.Element("value")?.Element("string")?.Value;
            
            throw new Exception($"XenAPI error: {faultString ?? "Unknown error"}");
        }

        return responseXml;
    }

    private string BuildXmlRpcRequest(string method, string? sessionId, params string[] parameters)
    {
        var sb = new StringBuilder();
        sb.AppendLine("<?xml version=\"1.0\"?>");
        sb.AppendLine("<methodCall>");
        sb.AppendLine($"  <methodName>{method}</methodName>");
        sb.AppendLine("  <params>");
        
        if (!string.IsNullOrEmpty(sessionId))
        {
            sb.AppendLine("    <param><value><string>" + sessionId + "</string></value></param>");
        }

        foreach (var param in parameters)
        {
            if (param.StartsWith("{") && param.Contains(":"))
            {
                // It's a struct/dictionary
                sb.AppendLine("    <param><value>" + param + "</value></param>");
            }
            else
            {
                sb.AppendLine("    <param><value><string>" + param + "</string></value></param>");
            }
        }

        sb.AppendLine("  </params>");
        sb.AppendLine("</methodCall>");
        
        return sb.ToString();
    }

    private string SerializeStruct(Dictionary<string, string> dict)
    {
        var sb = new StringBuilder();
        sb.AppendLine("<struct>");
        
        foreach (var kvp in dict)
        {
            sb.AppendLine("  <member>");
            sb.AppendLine($"    <name>{kvp.Key}</name>");
            sb.AppendLine($"    <value><string>{kvp.Value}</string></value>");
            sb.AppendLine("  </member>");
        }
        
        sb.AppendLine("</struct>");
        return sb.ToString();
    }
}
