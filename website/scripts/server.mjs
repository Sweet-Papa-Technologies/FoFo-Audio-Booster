import http from "node:http";
import { readFile, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
const root = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../dist",
);
const types = {
  ".html": "text/html",
  ".css": "text/css",
  ".js": "text/javascript",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".txt": "text/plain",
  ".md": "text/markdown",
  ".json": "application/json",
  ".xml": "application/xml",
  ".webmanifest": "application/manifest+json",
};
export async function serve() {
  const server = http.createServer(async (req, res) => {
    try {
      const pathname = decodeURIComponent(
        new URL(req.url, "http://localhost").pathname,
      );
      let file = path.resolve(root, "." + pathname);
      if (!file.startsWith(root + "/") && file !== root)
        throw Error("Invalid path");
      if ((await stat(file)).isDirectory())
        file = path.join(file, "index.html");
      res.writeHead(200, {
        "Content-Type": types[path.extname(file)] || "application/octet-stream",
      });
      res.end(await readFile(file));
    } catch {
      res.writeHead(404, { "Content-Type": "text/html" });
      res.end(await readFile(path.join(root, "404.html")));
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}
