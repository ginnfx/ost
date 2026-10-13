"use client";

import { startAuthentication } from "@simplewebauthn/browser";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";

export function PasskeyLogin() {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState(
    "Use a passkey already registered for an invite.",
  );
  const [instagram, setInstagram] = useState(false);
  useEffect(() => setInstagram(/Instagram/i.test(navigator.userAgent)), []);
  async function login() {
    if (busy) return;
    setBusy(true);
    setMessage("Waiting for your passkey…");
    try {
      const optionsResponse = await fetch("/api/auth/passkey/options", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
        cache: "no-store",
      });
      if (!optionsResponse.ok)
        throw new Error("Sign-in is unavailable right now.");
      const optionsJSON = await optionsResponse.json();
      const response = await startAuthentication({ optionsJSON });
      const verify = await fetch("/api/auth/passkey/verify", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ response }),
        cache: "no-store",
      });
      if (!verify.ok)
        throw new Error(
          "This passkey could not sign you in. Try again or ask the host for help.",
        );
      if (new URLSearchParams(window.location.search).get("native") === "1") {
        const authorization = await fetch("/api/auth/native/authorize", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: "{}",
          cache: "no-store",
        });
        if (!authorization.ok)
          throw new Error("Mac sign-in could not be completed. Try again.");
        const { callbackUrl } = await authorization.json();
        const callback = new URL(callbackUrl);
        if (
          callback.protocol !== "osttracker:" ||
          callback.hostname !== "competition" ||
          !callback.searchParams.has("code")
        )
          throw new Error("The Mac sign-in response was invalid.");
        window.location.assign(callback.href);
        return;
      }
      router.replace("/app");
    } catch (error) {
      setMessage(
        error instanceof Error
          ? error.message
          : "Sign-in did not finish. Try again.",
      );
      setBusy(false);
    }
  }
  return (
    <div className="passkey-login">
      {instagram && (
        <aside className="browser-notice" role="status">
          Passkeys may not work inside Instagram. Open this page in Safari, then
          try again.
        </aside>
      )}
      <button
        className="button primary"
        onClick={() => void login()}
        disabled={busy}
      >
        {busy ? "Checking passkey…" : "Sign in with passkey"}
      </button>
      <p role="status" aria-live="polite">
        {message}
      </p>
    </div>
  );
}
