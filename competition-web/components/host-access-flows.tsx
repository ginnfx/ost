"use client";

import { startRegistration } from "@simplewebauthn/browser";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";

async function registerPasskey(
  optionsPath: string,
  verifyPath: string,
  payload: Record<string, string>,
) {
  const { nickname, ...optionsPayload } = payload;
  const optionsResponse = await fetch(optionsPath, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(optionsPayload),
    cache: "no-store",
  });
  const options = await optionsResponse.json();
  if (!optionsResponse.ok)
    throw new Error(options.error || "Passkey setup is unavailable.");
  const response = await startRegistration({ optionsJSON: options });
  const verifyResponse = await fetch(verifyPath, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ nickname, response }),
    cache: "no-store",
  });
  const result = await verifyResponse.json();
  if (!verifyResponse.ok)
    throw new Error(result.error || "Passkey setup could not be completed.");
  return (result.destination as string | undefined) ?? location.pathname;
}

export function HostBootstrap() {
  const router = useRouter();
  const [token, setToken] = useState("");
  const [nickname, setNickname] = useState("Primary passkey");
  const [message, setMessage] = useState(
    "The setup link expires after 10 minutes and works once.",
  );
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    const value = location.hash.slice(1);
    if (value) {
      setToken(value);
      history.replaceState(null, "", location.pathname);
    }
  }, []);
  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!token || busy) return;
    setBusy(true);
    try {
      const destination = await registerPasskey(
        "/api/host/bootstrap/options",
        "/api/host/bootstrap/verify",
        { token, nickname },
      );
      router.replace(destination);
    } catch (error) {
      setMessage(
        error instanceof Error ? error.message : "Setup did not finish.",
      );
      setBusy(false);
    }
  }
  return (
    <form className="invite-form" onSubmit={(event) => void submit(event)}>
      <label htmlFor="host-passkey-name">Passkey name</label>
      <input
        id="host-passkey-name"
        value={nickname}
        maxLength={60}
        onChange={(event) => setNickname(event.target.value)}
        required
      />
      <button className="button primary" disabled={busy || !token}>
        {busy ? "Waiting for passkey…" : "Create host passkey"}
      </button>
      <p role="status" aria-live="polite">
        {message}
      </p>
    </form>
  );
}

export function HostRecovery() {
  const router = useRouter();
  const [code, setCode] = useState("");
  const [nickname, setNickname] = useState("Recovered passkey");
  const [message, setMessage] = useState(
    "Use one unused recovery code, then register a new passkey.",
  );
  const [busy, setBusy] = useState(false);
  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (busy) return;
    setBusy(true);
    try {
      const destination = await registerPasskey(
        "/api/host/recovery/options",
        "/api/host/recovery/verify",
        { code: code.trim(), nickname },
      );
      router.replace(destination);
    } catch (error) {
      setMessage(
        error instanceof Error ? error.message : "Recovery did not finish.",
      );
      setBusy(false);
    }
  }
  return (
    <form className="invite-form" onSubmit={(event) => void submit(event)}>
      <label htmlFor="recovery-code">Recovery code</label>
      <input
        id="recovery-code"
        autoComplete="off"
        value={code}
        onChange={(event) => setCode(event.target.value)}
        required
      />
      <label htmlFor="recovery-passkey-name">New passkey name</label>
      <input
        id="recovery-passkey-name"
        value={nickname}
        maxLength={60}
        onChange={(event) => setNickname(event.target.value)}
        required
      />
      <button className="button primary" disabled={busy}>
        {busy ? "Waiting for passkey…" : "Recover host access"}
      </button>
      <p role="status" aria-live="polite">
        {message}
      </p>
    </form>
  );
}

type Credential = {
  credential_id: string;
  nickname: string;
  device_type: string;
  backed_up: boolean;
  created_at: string;
  last_used_at: string | null;
};

export function HostSecurityControls() {
  const router = useRouter();
  const [credentials, setCredentials] = useState<Credential[]>([]);
  const [recoveryCodes, setRecoveryCodes] = useState<string[]>([]);
  const [nickname, setNickname] = useState("Backup passkey");
  const [message, setMessage] = useState("Loading credentials…");
  const [busy, setBusy] = useState(false);
  async function load() {
    const response = await fetch("/api/host/security", { cache: "no-store" });
    if (!response.ok) {
      setMessage(
        "Credentials are unavailable. Sign in again with a passkey and return here.",
      );
      return;
    }
    const result = await response.json();
    setCredentials(result.credentials);
    setMessage(
      result.credentials.length
        ? "Host access is active."
        : "No passkeys are registered.",
    );
  }
  useEffect(() => {
    void load();
  }, []);
  async function addCredential() {
    if (busy) return;
    setBusy(true);
    try {
      const destination = await registerPasskey(
        "/api/host/security/credentials/options",
        "/api/host/security/credentials/verify",
        { nickname },
      );
      setMessage(
        "Passkey added. Sign in again before the five-minute confirmation expires.",
      );
      await load();
      if (destination !== location.pathname) router.replace(destination);
    } catch (error) {
      setMessage(
        error instanceof Error ? error.message : "Passkey was not added.",
      );
    } finally {
      setBusy(false);
    }
  }
  async function rotateCodes() {
    setBusy(true);
    try {
      const response = await fetch("/api/host/security/recovery-codes", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
        cache: "no-store",
      });
      const result = await response.json();
      if (!response.ok)
        throw new Error(result.error || "Recovery codes could not be rotated.");
      setRecoveryCodes(result.codes);
      setMessage(
        "Copy these codes and store them somewhere offline. They will not be shown again.",
      );
    } catch (error) {
      setMessage(
        error instanceof Error
          ? error.message
          : "Recovery codes could not be rotated.",
      );
    } finally {
      setBusy(false);
    }
  }
  async function removeCredential(credentialId: string) {
    if (!confirm("Remove this passkey? All host sessions will be signed out."))
      return;
    const response = await fetch("/api/host/security", {
      method: "DELETE",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ credentialId }),
    });
    if (!response.ok) {
      setMessage(
        "Passkey could not be removed. Sign in with a passkey again first.",
      );
      return;
    }
    router.replace("/login");
  }
  async function revokeSessions() {
    const response = await fetch("/api/host/security/sessions", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    if (!response.ok) {
      setMessage(
        "Sessions could not be ended. Sign in with a passkey again first.",
      );
      return;
    }
    router.replace("/login");
  }
  return (
    <div className="host-security-controls">
      <p role="status" aria-live="polite">
        {message}
      </p>
      <section>
        <h2>Passkeys</h2>
        {credentials.map((credential) => (
          <div className="round-row" key={credential.credential_id}>
            <div>
              <strong>{credential.nickname}</strong>
              <p>
                {credential.device_type} ·{" "}
                {credential.backed_up ? "synced" : "device bound"}
              </p>
            </div>
            <button
              className="button secondary"
              disabled={credentials.length < 2}
              onClick={() => void removeCredential(credential.credential_id)}
            >
              Remove
            </button>
          </div>
        ))}
        <label htmlFor="new-passkey-name">New passkey name</label>
        <input
          id="new-passkey-name"
          value={nickname}
          onChange={(event) => setNickname(event.target.value)}
        />
        <button
          className="button primary"
          disabled={busy}
          onClick={() => void addCredential()}
        >
          {busy ? "Working…" : "Add backup passkey"}
        </button>
        {credentials.length < 2 && (
          <p className="muted-small">Add a backup before removing a passkey.</p>
        )}
      </section>
      <section>
        <h2>Recovery codes</h2>
        <p>
          Generate ten single-use codes. Rotating them disables every unused
          code shown earlier.
        </p>
        <button
          className="button secondary"
          disabled={busy}
          onClick={() => void rotateCodes()}
        >
          {busy ? "Working…" : "Generate new recovery codes"}
        </button>
        {recoveryCodes.length > 0 && (
          <ol className="recovery-code-list">
            {recoveryCodes.map((code) => (
              <li key={code}>
                <code>{code}</code>
              </li>
            ))}
          </ol>
        )}
      </section>
      <section>
        <h2>Sessions</h2>
        <p>End every signed-in session, including this one.</p>
        <button
          className="button secondary"
          onClick={() => void revokeSessions()}
        >
          Sign out all sessions
        </button>
      </section>
      <p>
        <a className="text-link" href="/host/recover">
          Use a recovery code
        </a>
      </p>
    </div>
  );
}
