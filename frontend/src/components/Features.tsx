"use client";

import { motion } from "framer-motion";
import {
  Database,
  ShieldCheck,
  ScrollText,
  ArrowLeftRight,
  Fingerprint,
  Gavel,
} from "lucide-react";

const features = [
  {
    icon: Database,
    title: "Design Registry",
    description:
      "Every design gets a unique ERC-1155 token. Immutable, content-addressed, fork-tracked.",
  },
  {
    icon: ShieldCheck,
    title: "Screening Gate",
    description:
      "On-chain attestations verify biosafety screening before registration. No unvetted sequences.",
  },
  {
    icon: ScrollText,
    title: "License Engine",
    description:
      "Story Protocol-compatible licensing. Commercial, derivative, attribution — governed by templates.",
  },
  {
    icon: ArrowLeftRight,
    title: "Royalty Router",
    description:
      "Uniswap v4 hooks enforce royalty cuts at swap time. Splits flow to creators automatically.",
  },
  {
    icon: Fingerprint,
    title: "Provenance Ledger",
    description:
      "EIP-712 signed model cards and wet-lab attestations. Full chain of custody, on-chain.",
  },
  {
    icon: Gavel,
    title: "Biosafety Court",
    description:
      "Dispute resolution with staked reviewer bonds. 48h Safety Council freeze, 30-day DAO ratification.",
  },
];

export default function Features() {
  return (
    <section className="py-24 px-6">
      <div className="mx-auto max-w-[1280px]">
        <motion.h2
          className="text-3xl sm:text-4xl font-bold text-center text-text-primary mb-16"
          initial={{ opacity: 0, y: 20 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.5 }}
        >
          Built for Biosecurity
        </motion.h2>

        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6">
          {features.map((feature, i) => (
            <motion.div
              key={feature.title}
              className="glass rounded-lg p-6 transition-all duration-300 hover:-translate-y-0.5 hover:shadow-lg hover:shadow-primary/10 hover:border-border-bright"
              initial={{ opacity: 0, y: 20 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ duration: 0.5, delay: i * 0.1 }}
            >
              <feature.icon className="w-8 h-8 text-primary mb-4" />
              <h3 className="text-lg font-bold text-text-primary mb-2">
                {feature.title}
              </h3>
              <p className="text-sm text-text-secondary leading-relaxed">
                {feature.description}
              </p>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
