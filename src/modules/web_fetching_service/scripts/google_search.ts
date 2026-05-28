/**
 * Simulate browsing: Open Google and search "why indonesia currency weak"
 */

const BASE_URL = "http://localhost:3000";

async function jsonFetch(url: string, options?: RequestInit) {
  const res = await fetch(url, options);
  return res.json();
}

async function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

async function main() {
  console.log("🚀 Starting browser simulation...\n");

  // Step 1: Launch browser
  console.log("📌 Step 1: Launch browser");
  const launchRes = await jsonFetch(`${BASE_URL}/launch`, { method: "POST" });
  console.log(launchRes);
  const { browser_id } = launchRes;
  console.log(`   Got browser_id: ${browser_id}\n`);
  await sleep(1000);

  // Step 2: Open Google
  console.log("📌 Step 2: Open Google");
  const pageRes = await jsonFetch(`${BASE_URL}/page`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ browser_id, url: "https://www.google.com" }),
  });
  console.log(pageRes);
  const { page_id } = pageRes;
  console.log(`   Got page_id: ${page_id}\n`);
  await sleep(1500);

  // Step 3: Take snapshot to see the page
  console.log("📌 Step 3: Take snapshot to find search box");
  const snapshotRes = await jsonFetch(`${BASE_URL}/snapshot`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ page_id }),
  });
  console.log("   Title:", snapshotRes.title);
  console.log("   URL:", snapshotRes.url);
  console.log("   Tree elements:");
  snapshotRes.tree?.slice(0, 15).forEach((el: any) => {
    console.log(`     ${el.ref}: "${el.text}"${el.href ? ` (${el.href})` : ""}`);
  });
  console.log();
  await sleep(500);

  // Step 4: Fill the search box (typically e1 or e2 on Google)
  console.log("📌 Step 4: Fill search box with query");
  // Google search box will be auto-detected by name="q" attribute
  const fillRes = await jsonFetch(`${BASE_URL}/fill`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      page_id,
      ref: "e1", // fallback ref, but will try name="q" selector first
      text: "why indonesia currency weak",
    }),
  });
  console.log(fillRes);
  console.log();
  await sleep(500);

  // Step 5: Press Enter to search
  console.log("📌 Step 5: Press Enter to search");
  const pressRes = await jsonFetch(`${BASE_URL}/press`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ page_id, key: "Enter" }),
  });
  console.log(pressRes);
  console.log(`   New URL: ${pressRes.url}\n`);
  await sleep(3000); // Wait for search results to load

  // Step 6: Take snapshot of search results
  console.log("📌 Step 6: Take snapshot of search results");
  const resultsRes = await jsonFetch(`${BASE_URL}/snapshot`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ page_id }),
  });
  console.log("   Title:", resultsRes.title);
  console.log("   URL:", resultsRes.url);
  console.log("   Top results:");
  resultsRes.tree?.slice(0, 10).forEach((el: any) => {
    const displayText = el.text?.slice(0, 60) || "";
    console.log(`     ${el.ref}: "${displayText}"${el.href ? ` -> ${el.href.slice(0, 50)}...` : ""}`);
  });
  console.log();

  // Cleanup
  console.log("📌 Cleanup: Closing page and browser");
  await jsonFetch(`${BASE_URL}/page/close/${page_id}`, { method: "POST" });
  await jsonFetch(`${BASE_URL}/close/${browser_id}`, { method: "POST" });
  console.log("   Done!");
}

main().catch(console.error);
