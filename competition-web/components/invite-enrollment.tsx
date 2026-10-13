"use client";

import { startRegistration } from "@simplewebauthn/browser";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";

type Status = "ready" | "working" | "error";
export function InviteEnrollment() {
  const router = useRouter();
  const [token, setToken] = useState("");
  const [nickname, setNickname] = useState("");
  const [status, setStatus] = useState<Status>("ready");
  const [message, setMessage] = useState("");
  const [instagramBrowser, setInstagramBrowser] = useState(false);
  useEffect(() => {
    setInstagramBrowser(/Instagram/i.test(navigator.userAgent));
    const fragment = window.location.hash.slice(1);
    const value = new URLSearchParams(fragment).get("token") ?? fragment;
    window.history.replaceState(
      null,
      "",
      window.location.pathname + window.location.search,
    );
    if (/^[A-Za-z0-9_-]{43}$/.test(value)) setToken(value);
    else {
      setStatus("error");
      setMessage(
        "This invite link is missing or invalid. Ask the host for a new one.",
      );
    }
  }, []);
  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!token || status === "working") return;
    setStatus("working");
    setMessage("Checking your invite…");
    try {
      const optionsResponse = await fetch("/api/auth/invite/options", {
        method: "POST",
        headers: { "content-type": "application/json" },
        cache: "no-store",
        body: JSON.stringify({ token }),
      });
      if (!optionsResponse.ok)
        throw new Error(
          "This invite has expired, was used, or is unavailable. Ask the host for a new link.",
        );
      const optionsJSON = await optionsResponse.json();
      setMessage("Follow your device prompt to create a passkey…");
      const response = await startRegistration({ optionsJSON });
      const verifyResponse = await fetch("/api/auth/invite/verify", {
        method: "POST",
        headers: { "content-type": "application/json" },
        cache: "no-store",
        body: JSON.stringify({ nickname, response }),
      });
      if (!verifyResponse.ok)
        throw new Error(
          "Passkey setup could not be completed. Try again or request a new invite.",
        );
      setToken("");
      setMessage("Passkey ready. Opening your round…");
      router.replace("/app");
    } catch (error) {
      setStatus("error");
      setMessage(
        error instanceof Error
          ? error.message
          : "Passkey setup did not finish. Try again.",
      );
    }
  }
  return (
    <>
      {instagramBrowser && (
        <p className="browser-prompt" role="note">
          For passkey setup, open this invite in Safari. In Instagram, use the
          menu and choose “Open in Safari.”
        </p>
      )}
      <form
        className="invite-form"
        onSubmit={submit}
        aria-busy={status === "working"}
      >
        <label htmlFor="invite-nickname">Nickname</label>
        <input
          id="invite-nickname"
          value={nickname}
          onChange={(event) => setNickname(event.target.value)}
          minLength={1}
          maxLength={40}
          autoComplete="nickname"
          required
          disabled={status === "working"}
        />
        <button
          className="button primary"
          disabled={
            !token || nickname.trim().length === 0 || status === "working"
          }
        >
          {status === "working" ? "Setting up…" : "Create passkey and join"}
        </button>
        <p role={status === "error" ? "alert" : "status"} aria-live="polite">
          {message ||
            "The invite token is removed from the address bar and used only to verify this link."}
        </p>
      </form>
    </>
  );
}
