"use client";

import { motion } from "framer-motion";
import { FlaskConical, ScrollText, TrendingUp } from "lucide-react";

const steps = [
  {
    number: 1,
    icon: FlaskConical,
    title: "Register",
    description:
      "Upload your SBOL3 design. Get a unique on-chain token backed by immutable storage.",
  },
  {
    number: 2,
    icon: ScrollText,
    title: "License",
    description:
      "Set terms with Story Protocol-compatible licenses. Commercial, derivative, attribution — your rules.",
  },
  {
    number: 3,
    icon: TrendingUp,
    title: "Earn",
    description:
      "Royalties auto-distribute on every swap and sublicense via Uniswap v4 hooks.",
  },
];

export default function HowItWorks() {
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
          How It Works
        </motion.h2>

        <div className="relative grid grid-cols-1 md:grid-cols-3 gap-12 md:gap-8">
          {/* Connecting dashed line (desktop only) */}
          <div className="hidden md:block absolute top-12 left-[20%] right-[20%] border-t-2 border-dashed border-border" />

          {steps.map((step, i) => (
            <motion.div
              key={step.title}
              className="relative flex flex-col items-center text-center"
              initial={{ opacity: 0, y: 20 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ duration: 0.5, delay: i * 0.15 }}
            >
              {/* Number badge */}
              <div className="relative z-10 flex items-center justify-center w-10 h-10 rounded-full bg-primary text-sm font-bold mb-6" style={{ color: "#0A0B0F" }}>
                {step.number}
              </div>

              {/* Icon */}
              <step.icon className="w-8 h-8 text-primary mb-4" />

              {/* Title */}
              <h3 className="text-xl font-bold text-text-primary mb-3">
                {step.title}
              </h3>

              {/* Description */}
              <p className="text-base text-text-secondary max-w-xs leading-relaxed">
                {step.description}
              </p>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
