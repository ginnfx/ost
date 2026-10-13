import { supabaseForRequest } from "@/lib/server/auth";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  const supabase = await supabaseForRequest();
  await supabase.auth.signOut({ scope: "local" });
  return privateJson({ success: true });
}
