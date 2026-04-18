import { canonicalizeSbol, type SerializationFormat } from "@seqora/canonicalize";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_BYTES = 8 * 1024 * 1024;

function detectFormat(name: string | undefined, contentType: string | undefined): SerializationFormat {
  const lower = (name ?? "").toLowerCase();
  if (lower.endsWith(".ttl") || (contentType ?? "").includes("turtle")) return "text/turtle";
  return "application/rdf+xml";
}

export async function POST(request: Request): Promise<Response> {
  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return Response.json({ error: "expected multipart/form-data" }, { status: 400 });
  }

  const file = form.get("sbol");
  if (!(file instanceof File)) {
    return Response.json({ error: "missing 'sbol' file field" }, { status: 400 });
  }
  if (file.size === 0) {
    return Response.json({ error: "file is empty" }, { status: 400 });
  }
  if (file.size > MAX_BYTES) {
    return Response.json({ error: `file exceeds ${MAX_BYTES} byte cap` }, { status: 413 });
  }

  const text = await file.text();
  const format = detectFormat(file.name, file.type);

  try {
    const { canonicalHash, tokenId, tripleCount } = await canonicalizeSbol(text, format);
    return Response.json({
      canonicalHash,
      tokenId: tokenId.toString(),
      tripleCount,
      format,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "canonicalization failed";
    return Response.json({ error: message }, { status: 422 });
  }
}
