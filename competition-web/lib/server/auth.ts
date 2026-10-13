import "server-only";
import { cookies } from "next/headers";
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
  if (userError || !user || !session || session.user.id !== user.id)
    return null;
  return { user, accessToken: session.access_token };
}

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Server configuration is missing: ${name}`);
  return value;
}
