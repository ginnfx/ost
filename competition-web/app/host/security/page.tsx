import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { SignOutButton } from "@/components/signout-button";
import { HostSecurityControls } from "@/components/host-access-flows";
import { SignInRequired, withHost } from "@/lib/server/database";

export const metadata = {
  title: "Host security · OST Competition",
  robots: { index: false, follow: false },
};
export const dynamic = "force-dynamic";

export default async function HostSecurityPage() {
  try {
    await withHost(async () => undefined);
  } catch (error) {
    if (error instanceof SignInRequired) redirect("/login");
    notFound();
  }
  return (
    <main className="page-shell">
      <header className="topbar">
        <Link className="wordmark" href="/">
          OST TRACKER <span>COMPETITION</span>
        </Link>
        <SignOutButton />
      </header>
      <section className="participant-home">
        <p className="eyebrow">HOST CONTROLS</p>
        <h1>Security</h1>
        <p className="intro">
          Manage the passkeys, recovery codes and active sessions for the single
          platform host.
        </p>
        <HostSecurityControls />
      </section>
    </main>
  );
}
