using XcpManagement.Models;

namespace XcpManagement.Services;

public interface IVmDeploymentService
{
    Task<List<VmTemplate>> GetTemplatesAsync(string hostId);
    Task<List<XcpNetwork>> GetNetworksAsync(string hostId);
    Task<DeploymentProgress> DeployVmAsync(VmDeploymentRequest request, IProgress<DeploymentProgress>? progress = null);
    Task<bool> ValidateDeploymentRequestAsync(VmDeploymentRequest request);
}
