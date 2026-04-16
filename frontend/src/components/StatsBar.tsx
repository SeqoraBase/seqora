"use client";

import { motion } from "framer-motion";

const stats = [
  { value: "1,200+", label: "Designs Registered" },
  { value: "340+", label: "Labs Connected" },
  { value: "$2.4M", label: "Royalties Distributed" },
  { value: "99.9%", label: "Uptime" },
];

export default function StatsBar() {
  return (
    <section className="relative z-10 -mt-16 px-6">
      <motion.div
        className="mx-auto max-w-[1280px] glass rounded-xl"
        initial={{ opacity: 0, y: 20 }}
        whileInView={{ opacity: 1, y: 0 }}
        viewport={{ once: true }}
        transition={{ duration: 0.5 }}
      >
        <div className="grid grid-cols-2 md:grid-cols-4">
          {stats.map((stat, i) => (
            <div
              key={stat.label}
              className={`flex flex-col items-center justify-center py-8 px-4 ${
                i < stats.length - 1 ? "md:border-r md:border-border" : ""
              } ${i < 2 ? "border-b md:border-b-0 border-border" : ""}`}
            >
              <span className="text-3xl sm:text-4xl font-bold text-text-primary">
                {stat.value}
              </span>
              <span className="mt-1 text-sm text-text-secondary">
                {stat.label}
              </span>
            </div>
          ))}
        </div>
      </motion.div>
    </section>
  );
}
