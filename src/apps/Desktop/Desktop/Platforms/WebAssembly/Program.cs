using Uno.UI.Hosting;
using System.Runtime.InteropServices.JavaScript;
using System.Reflection;

namespace Desktop;

public partial class Program
{
    public static async Task Main(string[] args)
    {
        // Load embedded OPFS script
        LoadEmbeddedScript("Desktop.Platforms.WebAssembly.WasmScripts.opfs.mjs");
        
        App.InitializeLogging();

        var host = UnoPlatformHostBuilder.Create()
            .App(() => new App())
            .UseWebAssembly()
            .Build();

        await host.RunAsync();
    }
    
    private static void LoadEmbeddedScript(string resourceName)
    {
        try
        {
            var assembly = Assembly.GetExecutingAssembly();
            var resourceStream = assembly.GetManifestResourceStream(resourceName);
            if (resourceStream == null)
            {
                Console.WriteLine($"[Program] Could not find embedded resource: {resourceName}");
                return;
            }
            
            using var reader = new StreamReader(resourceStream);
            var script = reader.ReadToEnd();
            
            // Execute the script
            JSEval(script);
            Console.WriteLine($"[Program] Loaded embedded script: {resourceName}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[Program] Failed to load embedded script: {ex.Message}");
        }
    }
    
    [JSImport("globalThis.eval")]
    private static partial void JSEval(string code);
}
