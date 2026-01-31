namespace XcpManagement.Services;

public class BackgroundRefreshService : BackgroundService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<BackgroundRefreshService> _logger;

    public BackgroundRefreshService(IServiceScopeFactory scopeFactory, ILogger<BackgroundRefreshService> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("Background refresh service starting");

        while (!stoppingToken.IsCancellationRequested)
        {
            using var scope = _scopeFactory.CreateScope();
            var cacheService = scope.ServiceProvider.GetRequiredService<IVmCacheService>();

            try
            {
                await cacheService.RefreshCacheAsync();
                var interval = cacheService.GetRefreshIntervalSeconds();
                await Task.Delay(TimeSpan.FromSeconds(interval), stoppingToken);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error in background refresh");
                await Task.Delay(TimeSpan.FromSeconds(60), stoppingToken);
            }
        }

        _logger.LogInformation("Background refresh service stopping");
    }
}
