import { supabaseForRequest } from "@/lib/server/auth";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
import { cookies } from "next/headers";

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  const supabase = await supabaseForRequest();
  await supabase.auth.signOut({ scope: "local" });
  (await cookies()).set("ost_host_recent", "", {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "strict",
    path: "/",
    maxAge: 0,
  });
  return privateJson({ success: true });
}
