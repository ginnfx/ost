import { randomBytes } from "node:crypto";
import { NextRequest, NextResponse } from "next/server";

export function proxy(request: NextRequest) {
  const nonce = randomBytes(18).toString("base64");
  const isDev = process.env.NODE_ENV === "development";
  const configuredSupabase =
    process.env.NEXT_PUBLIC_SUPABASE_URL ?? "http://127.0.0.1:54321";
  let supabaseOrigin = "http://127.0.0.1:54321";
  try {
    supabaseOrigin = new URL(configuredSupabase).origin;
  } catch {
    /* Invalid config fails closed to local origin. */
  }
  const csp = [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'${isDev ? " 'unsafe-eval'" : ""}`,
    `style-src 'self' 'nonce-${nonce}'`,
    "img-src 'self' data: blob:",
    "font-src 'self'",
    `media-src 'self' blob: data: ${supabaseOrigin}`,
    `connect-src 'self' ${supabaseOrigin} ${supabaseOrigin.replace(/^http/, "ws")}`,
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "worker-src 'self' blob:",
  ].join("; ");

  const requestHeaders = new Headers(request.headers);
  if (
    request.nextUrl.pathname === "/demo" ||
    request.nextUrl.pathname.startsWith("/demo/")
  )
    requestHeaders.delete("cookie");
  requestHeaders.set("x-nonce", nonce);
  requestHeaders.set("Content-Security-Policy", csp);
  const response = NextResponse.next({ request: { headers: requestHeaders } });
  response.headers.set("Content-Security-Policy", csp);
  response.headers.set("X-Content-Type-Options", "nosniff");
  response.headers.set("Referrer-Policy", "no-referrer");
  response.headers.set("X-Frame-Options", "DENY");
  response.headers.set(
    "Permissions-Policy",
    "camera=(), microphone=(), geolocation=()",
  );
  response.headers.set("X-Robots-Tag", "noindex, nofollow, noarchive");
  response.headers.set("Cross-Origin-Opener-Policy", "same-origin");
  if (process.env.NODE_ENV === "production")
    response.headers.set(
      "Strict-Transport-Security",
      "max-age=63072000; includeSubDomains; preload",
    );
  const isPublicPage =
    request.nextUrl.pathname === "/" ||
    request.nextUrl.pathname === "/demo" ||
    request.nextUrl.pathname === "/how-it-works";
  if (!isPublicPage || request.nextUrl.pathname.startsWith("/api/")) {
    response.headers.set("Cache-Control", "private, no-store, max-age=0");
    response.headers.set("Pragma", "no-cache");
  }
  return response;
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|manifest.webmanifest|robots.txt).*)",
  ],
};
