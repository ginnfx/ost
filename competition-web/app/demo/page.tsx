import type { Metadata } from "next";
import { DemoApp } from "@/components/demo-app";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import "./demo.css";

export const metadata: Metadata = {
  title: "OST Competition demo",
  description: "A browser-only preview of a soundtrack rating game.",
  robots: { index: false, follow: false, noarchive: true },
  openGraph: {
    title: "OST Competition demo",
    description: "A browser-only preview of a soundtrack rating game.",
    type: "website",
  },
};

export default async function DemoPage() {
  const isolatedOrigin = process.env.NEXT_PUBLIC_DEMO_ORIGIN;
  if (isolatedOrigin) {
    const incoming = (await headers()).get("host");
    const target = new URL(isolatedOrigin);
    if (incoming && incoming !== target.host)
      redirect(new URL("/demo", target).toString());
  }
  return <DemoApp />;
}
