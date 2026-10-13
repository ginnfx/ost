import Link from "next/link";
import { HostRecovery } from "@/components/host-access-flows";

export const metadata = {
  title: "Recover host access · OST Competition",
  robots: { index: false, follow: false },
};
export const dynamic = "force-dynamic";

export default function HostRecoveryPage() {
  return (
    <main className="page-shell">
      <header className="topbar">
        <Link className="wordmark" href="/">
          OST TRACKER <span>COMPETITION</span>
        </Link>
      </header>
      <section className="welcome invite-page">
        <p className="eyebrow">HOST RECOVERY</p>
        <h1>Recover access</h1>
        <p className="intro">
          A recovery code can be used once. You will register a new passkey,
          which replaces the host’s existing passkeys and ends all prior
          sessions and consumes the remaining recovery codes. Generate a new set
          after signing in.
        </p>
        <HostRecovery />
      </section>
    </main>
  );
}
