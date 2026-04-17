"use client";

import { motion } from "framer-motion";

export default function CallToAction() {
  return (
    <section className="py-24 px-6 relative overflow-hidden">
      {/* Background gradient */}
      <div
        className="absolute inset-0"
        style={{
          background:
            "radial-gradient(ellipse 70% 60% at 50% 50%, rgba(0, 212, 170, 0.06) 0%, rgba(123, 97, 255, 0.04) 50%, transparent 80%)",
        }}
      />

      <div className="relative z-10 mx-auto max-w-[1280px] text-center">
        <motion.h2
          className="text-3xl sm:text-4xl font-bold text-text-primary mb-4"
          initial={{ opacity: 0, y: 20 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.5 }}
        >
          Ready to Register Your First Design?
        </motion.h2>

        <motion.p
          className="text-lg text-text-secondary mb-10 max-w-xl mx-auto"
          initial={{ opacity: 0, y: 20 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.5, delay: 0.1 }}
        >
          Join the future of open, composable synthetic biology.
        </motion.p>

        <motion.div
          className="flex flex-col sm:flex-row items-center justify-center gap-4"
          initial={{ opacity: 0, y: 20 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.5, delay: 0.2 }}
        >
          <a
            href="/register"
            className="inline-flex items-center justify-center rounded-full bg-primary px-8 py-3 text-base font-semibold transition-all duration-300 hover:bg-primary-hover hover:shadow-lg hover:shadow-primary-glow hover:-translate-y-0.5"
            style={{ color: "#0A0B0F" }}
          >
            Register a Design
          </a>
          <a
            href="#"
            className="inline-flex items-center justify-center rounded-full border border-border px-8 py-3 text-base font-semibold text-text-primary transition-all duration-300 hover:border-border-bright hover:-translate-y-0.5"
          >
            Join Discord
          </a>
        </motion.div>
      </div>
    </section>
  );
}
