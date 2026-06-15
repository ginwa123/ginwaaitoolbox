import { jsonResponse } from "./helpers";

export function healthGet(): Response {
  return jsonResponse({
    status: "ok",
    service: "web-scraping-api",
    version: "1.0.0",
    timestamp: new Date().toISOString(),
  });
}