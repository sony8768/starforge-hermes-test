using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Mvc.Testing;

namespace StarForge.HermesTest.Tests;

public class HealthEndpointTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly HttpClient _client;

    public HealthEndpointTests(WebApplicationFactory<Program> factory)
    {
        _client = factory.CreateClient();
    }

    [Fact]
    public async Task Get_Health_Returns200AndJson()
    {
        var response = await _client.GetAsync("/health");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("application/json", response.Content.Headers.ContentType?.MediaType);
    }

    [Fact]
    public async Task Get_Health_BodyContainsStatusOk()
    {
        var body = await _client.GetFromJsonAsync<HealthResponse>("/health");
        Assert.NotNull(body);
        Assert.Equal("ok", body!.Status);
    }

    private record HealthResponse(string Status);
}
