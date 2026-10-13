import type { Metadata, Viewport } from "next";
import { headers } from "next/headers";
import "./tokens.generated.css";
import "./globals.css";

export const metadata: Metadata = {
  title: "OST Competition",
  description: "Private anime soundtrack competition.",
  robots: { index: false, follow: false, noarchive: true },
  manifest: "/manifest.webmanifest",
  icons: { icon: "/icons/icon-192.png", apple: "/icons/icon-192.png" },
  openGraph: {
    title: "OST Competition",
    description: "Private soundtrack competition.",
    type: "website",
  },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  themeColor: "#17191A",
};

export default async function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  // Reading the per-request header enables strict CSP nonce handling in Next's SSR.
  await headers();
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
