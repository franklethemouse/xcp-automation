namespace XcpManagement.Services;

public interface IAuthService
{
    Task<string?> AuthenticateAsync(string username, string password);
}
