import { Code2, Globe, MessageCircle } from "lucide-react";

const columns = [
  {
    title: "Protocol",
    links: ["Registry", "Licensing", "Royalties", "Biosafety"],
  },
  {
    title: "Developers",
    links: ["Docs", "GitHub", "Contracts", "API"],
  },
  {
    title: "Community",
    links: ["Discord", "Twitter", "Farcaster", "Forum"],
  },
  {
    title: "Company",
    links: ["About", "Blog", "Careers", "Press"],
  },
];

const socialLinks = [
  { icon: Code2, href: "#", label: "GitHub" },
  { icon: Globe, href: "#", label: "Twitter" },
  { icon: MessageCircle, href: "#", label: "Discord" },
];

export default function Footer() {
  return (
    <footer className="py-16 px-6 border-t border-border">
      <div className="mx-auto max-w-[1280px]">
        {/* Link columns */}
        <div className="grid grid-cols-2 md:grid-cols-4 gap-8 mb-12">
          {columns.map((col) => (
            <div key={col.title}>
              <h4 className="text-sm font-semibold text-text-primary mb-4">
                {col.title}
              </h4>
              <ul className="space-y-3">
                {col.links.map((link) => (
                  <li key={link}>
                    <a
                      href="#"
                      className="text-sm text-text-secondary hover:text-text-primary transition-colors duration-300"
                    >
                      {link}
                    </a>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>

        {/* Divider */}
        <div className="border-t border-border pt-8 flex flex-col sm:flex-row items-center justify-between gap-4">
          <p className="text-sm text-text-tertiary">
            2026 Seqora. All rights reserved.
          </p>
          <div className="flex items-center gap-4">
            {socialLinks.map((social) => (
              <a
                key={social.label}
                href={social.href}
                aria-label={social.label}
                className="text-text-tertiary hover:text-text-primary transition-colors duration-300"
              >
                <social.icon size={18} />
              </a>
            ))}
          </div>
        </div>
      </div>
    </footer>
  );
}
