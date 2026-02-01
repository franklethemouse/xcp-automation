using Microsoft.EntityFrameworkCore;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.IdentityModel.Tokens;
using System.Text;
using XcpManagement.Data;
using XcpManagement.Services;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container
builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

// HTTP Client
builder.Services.AddHttpClient();

// Add Blazor services
builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents();

// Add Ant Design
builder.Services.AddAntDesign();

// Database
var dbPassword = Environment.GetEnvironmentVariable("DB_PASSWORD");
var connectionString = builder.Configuration.GetConnectionString("DefaultConnection");
if (!string.IsNullOrEmpty(dbPassword))
{
    connectionString = connectionString?.Replace("${DB_PASSWORD}", dbPassword);
}

builder.Services.AddDbContext<XcpDbContext>(options =>
    options.UseMySql(connectionString, ServerVersion.AutoDetect(connectionString)));

// Data Protection - persist keys for antiforgery tokens
builder.Services.AddDataProtection()
    .PersistKeysToFileSystem(new DirectoryInfo("/opt/xcp-management/data-protection-keys"))
    .SetApplicationName("XcpManagement");

// JWT Authentication
var jwtSecret = builder.Configuration["Security:JwtSecret"] ?? throw new InvalidOperationException("JWT Secret not configured");
var key = Encoding.ASCII.GetBytes(jwtSecret);

builder.Services.AddAuthentication(options =>
{
    options.DefaultAuthenticateScheme = JwtBearerDefaults.AuthenticationScheme;
    options.DefaultChallengeScheme = JwtBearerDefaults.AuthenticationScheme;
})
.AddJwtBearer(options =>
{
    options.RequireHttpsMetadata = false;
    options.SaveToken = true;
    options.TokenValidationParameters = new TokenValidationParameters
    {
        ValidateIssuerSigningKey = true,
        IssuerSigningKey = new SymmetricSecurityKey(key),
        ValidateIssuer = true,
        ValidIssuer = builder.Configuration["Security:JwtIssuer"],
        ValidateAudience = true,
        ValidAudience = builder.Configuration["Security:JwtAudience"],
        ClockSkew = TimeSpan.Zero
    };
});

builder.Services.AddAuthorization();

// Application Services
builder.Services.AddScoped<IAuthService, AuthService>();
builder.Services.AddScoped<IAgentService, AgentService>();
builder.Services.AddScoped<IJobService, JobService>();
builder.Services.AddScoped<IXenApiService, XenApiService>();
builder.Services.AddScoped<IXcpHostService, XcpHostService>();
builder.Services.AddSingleton<IVmCacheService, VmCacheService>();

// Background Services
builder.Services.AddHostedService<BackgroundRefreshService>();

// CORS
builder.Services.AddCors(options =>
{
    options.AddPolicy("AllowAll",
        builder => builder
            .AllowAnyOrigin()
            .AllowAnyMethod()
            .AllowAnyHeader());
});

var app = builder.Build();

// Configure the HTTP request pipeline
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseStaticFiles();
app.UseAntiforgery();

app.UseCors("AllowAll");
app.UseAuthentication();
app.UseAuthorization();

// Health check endpoint
app.MapGet("/health", () => Results.Ok(new { status = "healthy", timestamp = DateTime.UtcNow }));

// API Controllers
app.MapControllers();

// Blazor
app.MapRazorComponents<XcpManagement.Components.App>()
    .AddInteractiveServerRenderMode();

app.Run();
