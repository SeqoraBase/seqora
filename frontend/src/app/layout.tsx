import type { Metadata } from "next";
import { Fraunces, Geist, Geist_Mono } from "next/font/google";
import { Providers } from "./providers";
import "./globals.css";

const fraunces = Fraunces({
  variable: "--font-fraunces",
  subsets: ["latin"],
  axes: ["opsz", "SOFT"],
  display: "swap",
});

const geist = Geist({
  variable: "--font-geist",
  subsets: ["latin"],
  display: "swap",
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
  display: "swap",
});

export const metadata: Metadata = {
  metadataBase: new URL("https://seqora.xyz"),
  title: {
    default: "Seqora — On-chain registry for engineered DNA",
    template: "%s · Seqora",
  },
  description:
    "An SBOL-native, royalty-enforcing on-chain registry for engineered DNA designs. Content-addressed. Fork-aware. Built on Base.",
  openGraph: {
    title: "Seqora",
    description:
      "An SBOL-native, royalty-enforcing on-chain registry for engineered DNA designs.",
    url: "https://seqora.xyz",
    siteName: "Seqora",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "Seqora",
    description:
      "An SBOL-native, royalty-enforcing on-chain registry for engineered DNA designs.",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${fraunces.variable} ${geist.variable} ${geistMono.variable}`}
    >
      <body className="min-h-dvh flex flex-col">
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
