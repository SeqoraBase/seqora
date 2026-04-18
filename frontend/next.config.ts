import path from "node:path";
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  turbopack: {
    root: path.join(__dirname, ".."),
    resolveAlias: {
      accounts: "./empty-module.js",
    },
  },
  serverExternalPackages: [
    "@seqora/canonicalize",
    "rdf-canonize",
    "rdfxml-streaming-parser",
    "n3",
  ],
};

export default nextConfig;
