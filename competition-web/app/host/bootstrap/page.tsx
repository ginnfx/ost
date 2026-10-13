import Link from "next/link";
import { HostBootstrap } from "@/components/host-access-flows";

export const metadata = {
  title: "Set up host passkey · OST Competition",
  robots: { index: false, follow: false },
};
export const dynamic = "force-dynamic";

export default function HostBootstrapPage() {
  return (
    <main className="page-shell">
      <header className="topbar">
        <Link className="wordmark" href="/">
          OST TRACKER <span>COMPETITION</span>
        </Link>
      </header>
      <section className="welcome invite-page">
        <p className="eyebrow">ONE TIME HOST SETUP</p>
        <h1>Set up host access</h1>
        <p className="intro">
          Register your first passkey on the permanent competition domain. Then
          add a backup key and generate recovery codes.
        </p>
        <HostBootstrap />
      </section>
    </main>
  );
}
