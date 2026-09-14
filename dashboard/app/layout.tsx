import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("http://172.25.50.14:8090"),
  title: "GPUmates — Cluster Observatory",
  description: "Private LAN telemetry for a distributed llama.cpp GPU cluster.",
  openGraph: {
    title: "GPUmates — Cluster Observatory",
    description: "Private LAN telemetry for a distributed llama.cpp GPU cluster.",
    images: [{ url: "/og.png", width: 1748, height: 908, alt: "GPUmates Cluster Observatory" }],
  },
  twitter: {
    card: "summary_large_image",
    title: "GPUmates — Cluster Observatory",
    description: "Private LAN telemetry for a distributed llama.cpp GPU cluster.",
    images: ["/og.png"],
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
