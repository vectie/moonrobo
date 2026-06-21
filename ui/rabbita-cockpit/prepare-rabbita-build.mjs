import fs from "node:fs";
import path from "node:path";

const mode = process.argv[2] || "release";
const root = process.cwd();
const buildRoot = path.join(root, "_build");
const source = path.join(buildRoot, "js", mode, "build", "all_pkgs.json");
const target = path.join(buildRoot, "packages.json");

if (!fs.existsSync(source)) {
  throw new Error(`Missing Rabbita package metadata: ${source}`);
}

fs.copyFileSync(source, target);
