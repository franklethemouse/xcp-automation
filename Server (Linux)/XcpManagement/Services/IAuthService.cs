using XcpManagement.Models;

namespace XcpManagement.Services;

public interface IAuthService
{
    Task<string?> AuthenticateAsync(string username, string password);
    Task<User?> GetUserByUsernameAsync(string username);
    string GenerateJwtToken(User user);
}