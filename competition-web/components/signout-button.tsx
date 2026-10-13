"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

export function SignOutButton() {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function signOut() {
    setBusy(true);
    setError("");
    try {
      const response = await fetch("/api/auth/signout", {
        method: "POST",
        cache: "no-store",
      });
      if (!response.ok) throw new Error();
      router.replace("/");
      router.refresh();
    } catch {
      setError("Sign out failed. Try again.");
      setBusy(false);
    }
  }
  return (
    <div className="signout-control">
      <button
        className="quiet-button"
        onClick={() => void signOut()}
        disabled={busy}
      >
        {busy ? "Signing out…" : "Sign out"}
      </button>
      {error && <span role="alert">{error}</span>}
    </div>
  );
}
