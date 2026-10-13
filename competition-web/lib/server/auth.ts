import "server-only";
import { createClient } from "@supabase/supabase-js";
import { cookies, headers } from "next/headers";
import { createServerClient } from "@supabase/ssr";

export async function supabaseForRequest() {
  const cookieStore = await cookies();
  return createServerClient(
    requiredEnv("NEXT_PUBLIC_SUPABASE_URL"),
    requiredEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY"),
    {
      cookieOptions: {
        httpOnly: true,
        secure: process.env.NODE_ENV === "production",
        sameSite: "lax",
        path: "/",
      },
      auth: {
        autoRefreshToken: false,
        persistSession: false,
        detectSessionInUrl: false,
      },
      cookies: {
        getAll: () => cookieStore.getAll(),
        setAll: (values) => {
          try {
            for (const { name, value, options } of values)
              cookieStore.set(name, value, options);
          } catch {
            /* Server Components are read-only; route handlers persist refreshes. */
          }
        },
      },
    },
  );
}

export async function verifiedCurrentUser() {
  const authorization = (await headers()).get("authorization");
  const bearer = authorization?.match(/^Bearer\s+(.+)$/i)?.[1];
  if (bearer) {
    const supabase = createClient(
      requiredEnv("NEXT_PUBLIC_SUPABASE_URL"),
      requiredEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY"),
      { auth: { persistSession: false, autoRefreshToken: false } },
    );
    const {
      data: { user },
      error,
    } = await supabase.auth.getUser(bearer);
    return error || !user ? null : { user, accessToken: bearer };
  }
  const supabase = await supabaseForRequest();
  const [
    {
      data: { user },
      error: userError,
    },
    {
      data: { session },
    },
  ] = await Promise.all([supabase.auth.getUser(), supabase.auth.getSession()]);
  if (userError || !user || !session?.access_token) return null;
  return { user, accessToken: session.access_token };
}

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Server configuration is missing: ${name}`);
  return value;
}
