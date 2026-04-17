declare module "rdf-canonize" {
  export interface CanonizeOptions {
    algorithm: "URDNA2015" | "URGNA2012";
    format?: "application/n-quads";
    inputFormat?: "application/n-quads";
  }
  export function canonize(input: unknown, options: CanonizeOptions): Promise<string>;
}
