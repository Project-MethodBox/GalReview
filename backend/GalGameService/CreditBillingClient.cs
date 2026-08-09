using System.Net.Http.Json;
using System.Text.Json;

public sealed class CreditBillingException(int statusCode,string code,string message,object details):Exception(message)
{
    public int StatusCode{get;}=statusCode;public string Code{get;}=code;public object Details{get;}=details;
}
public interface IGameCreditBilling
{
    Task ReserveAsync(Guid userId,Guid operationId,long estimated,CancellationToken ct);
    Task SettleAsync(Guid operationId,long actual,CancellationToken ct);
    Task ReleaseAsync(Guid operationId,CancellationToken ct);
}
public sealed class CreditBillingClient(IHttpClientFactory clients,IConfiguration configuration,ILogger<CreditBillingClient> logger) : IGameCreditBilling
{
    private string ServiceKey=>configuration["Gateway:ServiceKey"]??throw new InvalidOperationException("Gateway:ServiceKey must be configured.");
    public Task ReserveAsync(Guid userId,Guid operationId,long estimated,CancellationToken ct)=>SendAsync(HttpMethod.Post,"/internal/v1/credits/reservations",new{userId,operationId,operationType="GAME_GENERATION",estimatedTokenUnits=estimated},ct);
    public Task SettleAsync(Guid operationId,long actual,CancellationToken ct)=>SendAsync(HttpMethod.Post,$"/internal/v1/credits/reservations/{operationId:D}/settlement",new{actualTokenUnits=actual},ct);
    public Task ReleaseAsync(Guid operationId,CancellationToken ct)=>SendAsync(HttpMethod.Post,$"/internal/v1/credits/reservations/{operationId:D}/release",null,ct);
    private async Task SendAsync(HttpMethod method,string path,object? body,CancellationToken ct)
    {
        using var request=new HttpRequestMessage(method,path);if(body is not null)request.Content=JsonContent.Create(body);request.Headers.TryAddWithoutValidation("X-Service-Name","GalGameService");request.Headers.TryAddWithoutValidation("X-Service-Key",ServiceKey);
        using var response=await clients.CreateClient("gateway").SendAsync(request,HttpCompletionOption.ResponseHeadersRead,ct);
        var text=await ReadBoundedAsync(response.Content,64*1024,ct);
        if(response.IsSuccessStatusCode)return;
        logger.LogWarning("CreditService call failed: {Status} {Body}",(int)response.StatusCode,text.Length>2000?text[..2000]:text);
        try{using var doc=JsonDocument.Parse(text);var error=doc.RootElement.GetProperty("error");throw new CreditBillingException((int)response.StatusCode,error.GetProperty("code").GetString()??"UPSTREAM_ERROR",error.GetProperty("message").GetString()??"credits 服务调用失败。",error.TryGetProperty("details",out var details)?details.Clone():new{});}catch(CreditBillingException){throw;}catch{throw new CreditBillingException((int)response.StatusCode,"UPSTREAM_ERROR","credits 服务调用失败。",new{});}
    }
    private static async Task<string> ReadBoundedAsync(HttpContent content,int maxBytes,CancellationToken ct)
    {
        var stream=await content.ReadAsStreamAsync(ct);
        var buffer=new byte[maxBytes];
        var totalRead=0;
        while(totalRead<maxBytes)
        {
            var read=await stream.ReadAsync(buffer.AsMemory(totalRead,maxBytes-totalRead),ct);
            if(read==0)break;
            totalRead+=read;
        }
        return System.Text.Encoding.UTF8.GetString(buffer,0,totalRead);
    }
}
