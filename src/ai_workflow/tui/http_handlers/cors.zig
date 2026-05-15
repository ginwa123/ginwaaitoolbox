const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;

const httpz = http_server.httpz;

/// Handle OPTIONS preflight requests for CORS
pub fn corsPreflightHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    _ = req;
    res.status_code = 204;
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    res.header("Access-Control-Allow-Headers", "Content-Type, Authorization, Accept, Origin");
    res.header("Access-Control-Max-Age", "86400");
}
