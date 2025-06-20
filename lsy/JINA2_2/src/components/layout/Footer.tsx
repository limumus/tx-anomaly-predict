"use client";

import Link from "next/link";
import { Github, Mail } from "lucide-react";
import { useTheme } from "next-themes";

const socialLinks = [
  { icon: <Github className="h-4 w-4" />, href: "https://github.com" },
  { icon: <Mail className="h-4 w-4" />, href: "mailto:example@example.com" },
];

export function Footer() {
  const { theme } = useTheme();
  const isDark = theme === "dark";

  return (
    <footer
      className={`relative w-full ${
        isDark ? "bg-black text-zinc-400" : "bg-white text-zinc-600"
      }`}
    >
      <div className="container mx-auto px-4">
        {/* 页脚内容部分 */}
        <div className="flex flex-col md:flex-row justify-between items-center min-h-[100px] py-8">
          {/* 社交链接部分 */}
          <div className="flex space-x-6">
            {socialLinks.map((link, i) => (
              <Link
                key={`social-${i}`}
                href={link.href}
                className={`${
                  isDark
                    ? "text-zinc-500 hover:text-white"
                    : "text-zinc-400 hover:text-zinc-900"
                } transition-colors`}
                target="_blank"
                rel="noopener noreferrer"
              >
                {link.icon}
              </Link>
            ))}
          </div>
          {/* 版权信息部分 */}
          <div className={isDark ? "text-zinc-500" : "text-zinc-400"}>
            © 2025 Blockchain Attack Detection Demo. All rights reserved.
          </div>
        </div>
      </div>
    </footer>
  );
}