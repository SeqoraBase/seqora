"use client";

import { motion } from "framer-motion";
import { Microscope, Building2, Users } from "lucide-react";

const audiences = [
  {
    icon: Microscope,
    title: "For Scientists",
    description:
      "Publish designs, retain IP, earn royalties. No intermediaries.",
    bullets: [
      "Upload SBOL3 designs and mint tokens in minutes",
      "Set licensing terms with one-click templates",
      "Track usage and royalty income on-chain",
    ],
  },
  {
    icon: Building2,
    title: "For Labs",
    description:
      "Discover vetted, licensable designs. Provenance you can trust.",
    bullets: [
      "Browse a registry of biosafety-screened designs",
      "License designs with transparent, enforceable terms",
      "Full provenance chain from design to wet-lab validation",
    ],
  },
  {
    icon: Users,
    title: "For DAOs",
    description:
      "Govern biosafety. Stake, review, and earn from the screening process.",
    bullets: [
      "Stake tokens to become a biosafety reviewer",
      "Earn rewards for accurate screening attestations",
      "Participate in dispute resolution and governance votes",
    ],
  },
];

export default function Audience() {
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
          For Every Stakeholder
        </motion.h2>

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          {audiences.map((audience, i) => (
            <motion.div
              key={audience.title}
              className="glass rounded-lg overflow-hidden transition-all duration-300 hover:-translate-y-0.5 hover:shadow-lg hover:shadow-primary/10"
              initial={{ opacity: 0, y: 20 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ duration: 0.5, delay: i * 0.15 }}
            >
              {/* Gradient top border */}
              <div
                className="h-0.5"
                style={{
                  background: "linear-gradient(to right, #00D4AA, #7B61FF)",
                }}
              />

              <div className="p-6">
                <audience.icon className="w-8 h-8 text-primary mb-4" />
                <h3 className="text-xl font-bold text-text-primary mb-2">
                  {audience.title}
                </h3>
                <p className="text-base text-text-secondary mb-4">
                  {audience.description}
                </p>
                <ul className="space-y-2">
                  {audience.bullets.map((bullet) => (
                    <li
                      key={bullet}
                      className="flex items-start gap-2 text-sm text-text-secondary"
                    >
                      <span className="mt-1.5 w-1.5 h-1.5 rounded-full bg-primary shrink-0" />
                      {bullet}
                    </li>
                  ))}
                </ul>
              </div>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
