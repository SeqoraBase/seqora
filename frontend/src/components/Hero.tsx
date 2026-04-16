"use client";

import { motion } from "framer-motion";

function FloatingDot({
  delay,
  x,
  y,
  size,
}: {
  delay: number;
  x: string;
  y: string;
  size: number;
}) {
  return (
    <motion.div
      className="absolute rounded-full bg-primary/20"
      style={{ left: x, top: y, width: size, height: size }}
      animate={{
        y: [0, -20, 0],
        opacity: [0.2, 0.5, 0.2],
      }}
      transition={{
        duration: 6,
        delay,
        repeat: Infinity,
        ease: "easeInOut",
      }}
    />
  );
}

export default function Hero() {
  return (
    <section className="relative min-h-screen flex items-center justify-center overflow-hidden">
      {/* Background gradient */}
      <div
        className="absolute inset-0"
        style={{
          background:
            "radial-gradient(ellipse 60% 50% at 50% 40%, rgba(0, 212, 170, 0.12) 0%, rgba(123, 97, 255, 0.04) 50%, transparent 80%)",
        }}
      />

      {/* Grid pattern overlay */}
      <div className="absolute inset-0 bg-grid-pattern opacity-60" />

      {/* Floating molecular dots */}
      <FloatingDot delay={0} x="15%" y="25%" size={6} />
      <FloatingDot delay={1.2} x="80%" y="20%" size={4} />
      <FloatingDot delay={0.6} x="70%" y="60%" size={8} />
      <FloatingDot delay={1.8} x="25%" y="70%" size={5} />
      <FloatingDot delay={2.4} x="50%" y="15%" size={4} />
      <FloatingDot delay={0.3} x="90%" y="45%" size={6} />
      <FloatingDot delay={1.5} x="10%" y="50%" size={7} />
      <FloatingDot delay={2.0} x="60%" y="80%" size={5} />
      <FloatingDot delay={0.9} x="35%" y="35%" size={3} />
      <FloatingDot delay={2.7} x="85%" y="75%" size={6} />

      {/* Content */}
      <div className="relative z-10 mx-auto max-w-[1280px] px-6 text-center">
        <motion.h1
          className="text-4xl sm:text-5xl lg:text-[56px] font-bold leading-tight tracking-tight text-text-primary"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6, ease: "easeOut" }}
        >
          The On-Chain Registry
          <br />
          for Engineered DNA
        </motion.h1>

        <motion.p
          className="mt-6 text-lg sm:text-xl text-text-secondary max-w-2xl mx-auto leading-relaxed"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6, delay: 0.15, ease: "easeOut" }}
        >
          Register, license, and earn royalties on synthetic biology designs.
          SBOL-native. Royalty-enforcing. Built on Base.
        </motion.p>

        <motion.div
          className="mt-10 flex flex-col sm:flex-row items-center justify-center gap-4"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6, delay: 0.3, ease: "easeOut" }}
        >
          <a
            href="#"
            className="inline-flex items-center justify-center rounded-full bg-primary px-8 py-3 text-base font-semibold transition-all duration-300 hover:bg-primary-hover hover:shadow-lg hover:shadow-primary-glow hover:-translate-y-0.5"
            style={{ color: "#0A0B0F" }}
          >
            Explore Registry
          </a>
          <a
            href="#"
            className="inline-flex items-center justify-center rounded-full border border-border px-8 py-3 text-base font-semibold text-text-primary transition-all duration-300 hover:border-border-bright hover:-translate-y-0.5"
          >
            Read Docs
          </a>
        </motion.div>
      </div>
    </section>
  );
}
