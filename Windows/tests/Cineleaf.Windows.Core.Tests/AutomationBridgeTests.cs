using Cineleaf.Core;
using Cineleaf.Media;

namespace Cineleaf.Windows.Core.Tests;

public sealed class AutomationBridgeTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "CineleafAutomationTests", Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task ValidatesAndSummarizesAProjectPackage()
    {
        Directory.CreateDirectory(_root);
        var package = Path.Combine(_root, "AI.cineleaf");
        using var store = new ProjectPackageStore(Path.Combine(_root, "Recovery"));
        await store.SaveAsync(ProjectFixtures.SimpleProject(DateTimeOffset.UtcNow), package);
        var result = await AutomationBridgeService.ValidateProjectAsync(package);

        Assert.True(result.Valid);
        Assert.Equal(1, result.AssetCount);
        Assert.Equal(1, result.ClipCount);
        Assert.Equal(10, result.DurationSeconds);
    }

    [Fact]
    public void ReportsStableMachineReadableCapabilities()
    {
        var result = AutomationBridgeService.Capabilities();

        Assert.Equal(1, result.ProtocolVersion);
        Assert.Contains("render-project", result.Commands);
        Assert.Equal(4, result.MaxBatchConcurrency);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }
}
