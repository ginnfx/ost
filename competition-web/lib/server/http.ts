import "server-only";
import { randomUUID } from "node:crypto";

export function sameOriginRequest(request: Request): boolean {
  const origin = request.headers.get("origin");
  const expected = [
    process.env.NEXT_PUBLIC_SITE_URL,
    ...(process.env.NEXT_PUBLIC_SITE_ORIGINS ?? "").split(","),
  ].filter((value): value is string => Boolean(value));
  if (!origin || !expected.length) return false;
  try {
    return expected.some(
      (value) => new URL(origin).origin === new URL(value).origin,
    );
  } catch {
    return false;
  }
}

export function privateJson(data: unknown, status = 200): Response {
  return Response.json(data, {
    status,
    headers: {
      "Cache-Control": "private, no-store, max-age=0",
      Pragma: "no-cache",
      Vary: "Cookie",
    },
  });
}

export function unavailable(): Response {
  return privateJson({ error: "This item is not available." }, 404);
}

export function failedRequest(): Response {
  const reference = randomUUID();
  console.error(JSON.stringify({ event: "request_failed", reference }));
  return privateJson(
    { error: "The request could not be completed.", reference },
    500,
  );
}
