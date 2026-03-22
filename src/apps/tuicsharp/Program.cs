using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Spectre.Console;
using Spectre.Console.Cli;
using System.ComponentModel;

namespace MyCli;

public class DefaultCommand : AsyncCommand<DefaultCommand.Settings>
{
    private const string HttpHost = "127.0.0.1";
    private const int HttpPort = 8080;

    public class Settings : CommandSettings
    {
        [CommandOption("-c|--config")]
        [Description("Configuration path or value")]
        public string? Config { get; init; }

        [CommandOption("-q|--query")]
        [Description("Query string to send to LLM")]
        public string? Query { get; init; }

        [CommandOption("-h|--help")]
        [Description("Show help information")]
        public bool Help { get; init; }
    }

    public override async Task<int> ExecuteAsync(CommandContext context, Settings settings, CancellationToken cancellationToken)
    {
        if (settings.Help || string.IsNullOrEmpty(settings.Query))
        {
            ShowHelp();
            return 0;
        }

        if (!string.IsNullOrEmpty(settings.Config))
        {
            AnsiConsole.MarkupLine($"[green]Config:[/] {settings.Config}");
        }

        var isBackendRunning = await CheckBackendAsync();
        if (!isBackendRunning)
        {
            AnsiConsole.MarkupLine("[yellow]Backend not running. Please start the nalar server first.[/]");
            return 1;
        }

        AnsiConsole.MarkupLine("[dim]Sending query to LLM...[/]");
        
        // Run synchronous streaming in a task
        await Task.Run(() => StreamLlmResponse(settings.Query), cancellationToken);

        return 0;
    }

    private static async Task<bool> CheckBackendAsync()
    {
        try
        {
            using var client = new HttpClient();
            client.Timeout = TimeSpan.FromSeconds(2);
            var response = await client.GetAsync($"http://{HttpHost}:{HttpPort}/api/session");
            return response.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }

    private static void StreamLlmResponse(string query)
    {
        string sessionId = $"session_{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}";
        Socket? sseSocket = null;
        Socket? postSocket = null;
        
        try
        {
            // Create SSE socket
            sseSocket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            sseSocket.NoDelay = true;
            sseSocket.Connect(HttpHost, HttpPort);
            
            // Send SSE subscription
            var sseRequest = $"GET /api/stream/{sessionId} HTTP/1.1\r\nHost: {HttpHost}:{HttpPort}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n";
            sseSocket.Send(Encoding.UTF8.GetBytes(sseRequest));
            
            // Wait for connected
            if (!WaitForConnected(sseSocket, 5000))
            {
                AnsiConsole.MarkupLine("[red]Failed to connect[/]");
                return;
            }
            
            // Send message via POST
            var jsonPayload = JsonSerializer.Serialize(new
            {
                app_type = "cli",
                command_type = "run_llm",
                session_id = sessionId,
                content = EscapeJsonString(query),
                cwd_session = Environment.CurrentDirectory
            });
            
            postSocket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            postSocket.Connect(HttpHost, HttpPort);
            
            var postRequest = $"POST /api/command HTTP/1.1\r\nHost: {HttpHost}:{HttpPort}\r\nContent-Type: application/json\r\nContent-Length: {jsonPayload.Length}\r\n\r\n{jsonPayload}";
            postSocket.Send(Encoding.UTF8.GetBytes(postRequest));
            postSocket.Close();
            postSocket = null;
            
            // Stream response
            AnsiConsole.Markup("[bold cyan]Response:[/] ");
            StreamResponse(sseSocket);
            AnsiConsole.WriteLine();
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"\n[red]Error: {ex.Message}[/]");
        }
        finally
        {
            sseSocket?.Close();
            postSocket?.Close();
        }
    }

    private static bool WaitForConnected(Socket socket, int timeoutMs)
    {
        var buffer = new byte[4096];
        var sb = new StringBuilder();
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        
        while (DateTime.UtcNow < deadline)
        {
            if (socket.Poll(100000, SelectMode.SelectRead))
            {
                int n = socket.Receive(buffer);
                if (n > 0)
                {
                    sb.Append(Encoding.UTF8.GetString(buffer, 0, n));
                    if (sb.ToString().Contains("event: connected")) return true;
                }
                else return false;
            }
        }
        return false;
    }

    private static void StreamResponse(Socket socket)
    {
        var buffer = new byte[16384];
        var rawBuffer = new StringBuilder();
        bool foundResponse = false;
        int loopCount = 0;
        
        while (true)
        {
            if (socket.Poll(100000, SelectMode.SelectRead))
            {
                int n = socket.Receive(buffer);
                if (n == 0) break;
                
                rawBuffer.Append(Encoding.UTF8.GetString(buffer, 0, n));
                
                // Process all complete SSE events in the buffer
                foundResponse = ProcessSseBuffer(rawBuffer, foundResponse);
                
                // Check for finish
                if (rawBuffer.ToString().Contains("</finish_reason>")) 
                {
                    break;
                }
            }
            loopCount++;
            if (loopCount > 1000) {
                break;
            }
        }
        
        if (!foundResponse) AnsiConsole.Markup("[dim](no response)[/]");
    }

    /// Process the raw buffer to extract and display SSE events
    private static bool ProcessSseBuffer(StringBuilder rawBuffer, bool foundResponse)
    {
        var raw = rawBuffer.ToString();
        
        // Skip HTTP headers to get body
        var headerEnd = raw.IndexOf("\r\n\r\n");
        var body = (headerEnd >= 0) ? raw.Substring(headerEnd + 4) : raw;
        
        if (string.IsNullOrEmpty(body)) return foundResponse;
        
        // Decode chunked transfer encoding if present
        var decodedBody = TryDecodeChunked(body);
        
        if (string.IsNullOrEmpty(decodedBody)) return foundResponse;
        
        // Parse SSE format: "event: type\ndata: content\ndata: more\n\n"
        // The double newline separates events
        
        // Split by double newline to get event chunks
        var eventChunks = decodedBody.Split(new string[] {"\n\n"}, StringSplitOptions.None);
        
        foreach (var chunk in eventChunks)
        {
            if (string.IsNullOrEmpty(chunk)) continue;
            
            // Parse this event chunk - extract event type and data
            var eventType = "";
            var eventData = new StringBuilder();
            
            // Split by single newline to process each line
            var lines = chunk.Split('\n');
            foreach (var line in lines)
            {
                var trimmed = line.TrimEnd('\r');
                
                // Skip empty lines
                if (string.IsNullOrEmpty(trimmed)) continue;
                
                // Skip comment lines (keepalive)
                if (trimmed.StartsWith(":")) continue;
                
                // Event type
                if (trimmed.StartsWith("event:"))
                {
                    eventType = trimmed.Substring(6).Trim();
                    continue;
                }
                
                // Data line
                if (trimmed.StartsWith("data:"))
                {
                    eventData.Append(trimmed.Substring(5));
                    continue;
                }
                
                // Continuation of data
                eventData.Append(trimmed);
            }
            
            // Process this event's data
            var dataStr = eventData.ToString();
            if (!string.IsNullOrEmpty(dataStr))
            {
                foundResponse = ParseAndDisplayXml(dataStr, foundResponse);
            }
        }
        
        return foundResponse;
    }

    /// Try to decode chunked transfer encoding, return original if not chunked
    private static string TryDecodeChunked(string body)
    {
        // Check if body starts with hex number (chunked encoding)
        var firstLineEnd = body.IndexOf('\n');
        if (firstLineEnd <= 0) return body;
        
        var firstLine = body.Substring(0, firstLineEnd).Trim();
        if (!int.TryParse(firstLine, System.Globalization.NumberStyles.HexNumber, null, out int chunkSize) || chunkSize <= 0)
        {
            return body;
        }
        
        // It's chunked encoding - decode it
        var result = new StringBuilder();
        var pos = firstLineEnd + 1;
        
        while (pos < body.Length)
        {
            // Find next chunk size line
            var lineEnd = body.IndexOf('\n', pos);
            if (lineEnd == -1) break;
            
            var sizeLine = body.Substring(pos, lineEnd - pos).Trim();
            pos = lineEnd + 1;
            
            if (string.IsNullOrEmpty(sizeLine)) continue;
            
            // Parse hex chunk size
            if (!int.TryParse(sizeLine, System.Globalization.NumberStyles.HexNumber, null, out int size))
            {
                break;
            }
            
            if (size == 0) break; // End of chunks
            
            // Extract chunk data
            if (pos + size <= body.Length)
            {
                result.Append(body.Substring(pos, size));
                pos += size;
                
                // Skip trailing \r\n
                if (pos < body.Length && body[pos] == '\r') pos++;
                if (pos < body.Length && body[pos] == '\n') pos++;
            }
            else
            {
                break;
            }
        }
        
        return result.ToString();
    }

    /// Parse XML content and display response/tool_result tags
    private static bool ParseAndDisplayXml(string xmlContent, bool foundResponse)
    {
        if (string.IsNullOrEmpty(xmlContent)) return foundResponse;
        
        // Unescape XML entities
        xmlContent = xmlContent.Replace("&lt;", "<")
                            .Replace("&gt;", ">")
                            .Replace("&amp;", "&")
                            .Replace("&quot;", "\"")
                            .Replace("&apos;", "'");
        
        // Find <response> tags
        var idx = 0;
        while ((idx = xmlContent.IndexOf("<response>", idx)) != -1)
        {
            var endIdx = xmlContent.IndexOf("</response>", idx);
            if (endIdx == -1) break;
            
            var responseContent = xmlContent.Substring(idx + 10, endIdx - idx - 10);
            idx = endIdx + 11;
            
            if (!string.IsNullOrEmpty(responseContent))
            {
                // Extract content from nested <content> tag
                var contentIdx = responseContent.IndexOf("<content>");
                if (contentIdx >= 0)
                {
                    var contentEndIdx = responseContent.IndexOf("</content>", contentIdx);
                    if (contentEndIdx > contentIdx)
                    {
                        var content = responseContent.Substring(contentIdx + 9, contentEndIdx - contentIdx - 9);
                        if (!string.IsNullOrEmpty(content))
                        {
                            AnsiConsole.Markup(content);
                            foundResponse = true;
                        }
                    }
                }
                else
                {
                    // No <content> tag, just print the whole thing
                    AnsiConsole.Markup(responseContent);
                    foundResponse = true;
                }
            }
        }
        
        // Also handle <tool_result> tags
        idx = 0;
        while ((idx = xmlContent.IndexOf("<tool_result>", idx)) != -1)
        {
            var endIdx = xmlContent.IndexOf("</tool_result>", idx);
            if (endIdx == -1) break;
            
            var content = xmlContent.Substring(idx + 13, endIdx - idx - 13);
            idx = endIdx + 14;
            
            if (!string.IsNullOrEmpty(content))
            {
                AnsiConsole.Markup(content);
                foundResponse = true;
            }
        }
        
        return foundResponse;
    }

    private static string EscapeJsonString(string input)
    {
        return input.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "\\r");
    }

    private static void ShowHelp()
    {
        var table = new Table()
            .Title("[bold cyan]MyCli - Command Line Tool[/]")
            .AddColumn(new TableColumn("[yellow]Option[/]"))
            .AddColumn(new TableColumn("[yellow]Description[/]"))
            .AddRow("-c, --config <value>", "Set configuration path")
            .AddRow("-q, --query <value>", "Send query to LLM")
            .AddRow("-h, --help", "Show help");
        AnsiConsole.Write(table);
        AnsiConsole.WriteLine();
        AnsiConsole.MarkupLine("[dim]Example:[/] [green]mycli -q \"Hello\"[/]");
    }
}

public class Program
{
    public static int Main(string[] args)
    {
        return new CommandApp<DefaultCommand>().Run(args);
    }
}
