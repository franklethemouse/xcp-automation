# Complete Missing Files Setup
# Run from: Server (Linux)/XcpManagement

$ErrorActionPreference = "Stop"

Write-Host "Creating missing project structure..." -ForegroundColor Cyan

# Create directories
New-Item -ItemType Directory -Path "Data" -Force | Out-Null
New-Item -ItemType Directory -Path "Controllers" -Force | Out-Null  
New-Item -ItemType Directory -Path "DTOs" -Force | Out-Null

Write-Host "✓ Directories created" -ForegroundColor Green

# You need to:
# 1. Download XcpDbContext.cs → place in Data/
# 2. Download XcpManagement-FIXED.csproj → rename to XcpManagement.csproj
# 3. Download XenApiService-FIXED.cs → replace Services/XenApiService.cs

Write-Host ""
Write-Host "Next: Create stub service files..." -ForegroundColor Yellow

# Create IAuthService.cs
@'
namespace XcpManagement.Services;

public interface IAuthService
{
    Task<string?> AuthenticateAsync(string username, string password);
}
'@ | Out-File -FilePath "Services\IAuthService.cs" -Encoding UTF8

# Create AuthService.cs
@'
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using XcpManagement.Data;

namespace XcpManagement.Services;

public class AuthService : IAuthService
{
    private readonly XcpDbContext _context;
    private readonly IConfiguration _configuration;

    public AuthService(XcpDbContext context, IConfiguration configuration)
    {
        _context = context;
        _configuration = configuration;
    }

    public async Task<string?> AuthenticateAsync(string username, string password)
    {
        var user = await _context.Users.FirstOrDefaultAsync(u => u.Username == username);
        if (user == null || !BCrypt.Net.BCrypt.Verify(password, user.PasswordHash))
            return null;

        var tokenHandler = new JwtSecurityTokenHandler();
        var key = Encoding.ASCII.GetBytes(_configuration["Security:JwtSecret"] ?? "");
        var tokenDescriptor = new SecurityTokenDescriptor
        {
            Subject = new ClaimsIdentity(new[] { new Claim("id", user.UserId) }),
            Expires = DateTime.UtcNow.AddHours(24),
            Issuer = _configuration["Security:JwtIssuer"],
            Audience = _configuration["Security:JwtAudience"],
            SigningCredentials = new SigningCredentials(new SymmetricSecurityKey(key), SecurityAlgorithms.HmacSha256Signature)
        };
        var token = tokenHandler.CreateToken(tokenDescriptor);
        return tokenHandler.WriteToken(token);
    }
}
'@ | Out-File -FilePath "Services\AuthService.cs" -Encoding UTF8

# Create IAgentService.cs
@'
using XcpManagement.Data;

namespace XcpManagement.Services;

public interface IAgentService
{
    Task<List<Agent>> GetAllAgentsAsync();
}
'@ | Out-File -FilePath "Services\IAgentService.cs" -Encoding UTF8

# Create AgentService.cs  
@'
using Microsoft.EntityFrameworkCore;
using XcpManagement.Data;

namespace XcpManagement.Services;

public class AgentService : IAgentService
{
    private readonly XcpDbContext _context;

    public AgentService(XcpDbContext context)
    {
        _context = context;
    }

    public async Task<List<Agent>> GetAllAgentsAsync()
    {
        return await _context.Agents.Include(a => a.Host).ToListAsync();
    }
}
'@ | Out-File -FilePath "Services\AgentService.cs" -Encoding UTF8

# Create IJobService.cs
@'
using XcpManagement.Data;

namespace XcpManagement.Services;

public interface IJobService
{
    Task<List<Job>> GetAllJobsAsync();
}
'@ | Out-File -FilePath "Services\IJobService.cs" -Encoding UTF8

# Create JobService.cs
@'
using Microsoft.EntityFrameworkCore;
using XcpManagement.Data;

namespace XcpManagement.Services;

public class JobService : IJobService
{
    private readonly XcpDbContext _context;

    public JobService(XcpDbContext context)
    {
        _context = context;
    }

    public async Task<List<Job>> GetAllJobsAsync()
    {
        return await _context.Jobs.Include(j => j.Agent).ToListAsync();
    }
}
'@ | Out-File -FilePath "Services\JobService.cs" -Encoding UTF8

Write-Host "✓ Service files created" -ForegroundColor Green
Write-Host ""
Write-Host "Status:" -ForegroundColor Cyan
Write-Host "  ✓ Directories created" -ForegroundColor Green
Write-Host "  ✓ Stub services created" -ForegroundColor Green
Write-Host "  ⏳ Waiting for downloaded files" -ForegroundColor Yellow
Write-Host ""
Write-Host "Complete the setup by copying the 3 downloaded files as instructed above" -ForegroundColor Yellow
