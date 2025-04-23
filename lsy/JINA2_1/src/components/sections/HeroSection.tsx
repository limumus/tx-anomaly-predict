"use client";

import Image from 'next/image';
import Link from 'next/link';
import { Button } from '@/components/ui/button';
import { useTheme } from "next-themes";
import { useState, useEffect } from "react";

export function HeroSection() {
  const { theme } = useTheme();
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  if (!mounted) {
    return null;
  }

  const isDark = theme === "dark";

  return (
    <section className={`relative pt-16 overflow-hidden ${isDark ? 'bg-black' : 'bg-white'}`}>
      <div className="absolute inset-0 z-0">
        {isDark ? (
          <>
            <Image
              src="/images/hero-image.webp"
              alt="Blue glowing orb"
              fill
              priority
              className="object-cover opacity-80"
            />
            <div className="absolute inset-0 bg-gradient-to-b from-black/20 via-black/50 to-black"></div>
          </>
        ) : (
          <div className="absolute inset-0 bg-[radial-gradient(ellipse_at_center,_var(--tw-gradient-stops))] from-blue-100 via-white to-blue-50"></div>
        )}
      </div>

      <div className="container relative z-10 pt-20 pb-24 md:pt-32 md:pb-32 text-center">
        <h1 className={`text-3xl md:text-5xl font-semibold ${isDark ? 'text-white' : 'text-zinc-900'} mb-2`}>
          Blockchain Attack Detection
        </h1>
        <h2 className={`text-4xl md:text-6xl font-bold ${isDark ? 'text-white' : 'text-zinc-900'} mb-12`}>
          Secure Your Transactions
        </h2>

        <p className={`max-w-2xl mx-auto ${isDark ? 'text-zinc-300' : 'text-zinc-700'} mb-12 text-lg`}>
          Analyze and evaluate blockchain transactions to detect potential attacks with our cutting-edge AI technology.
        </p>

        <div className="flex flex-col sm:flex-row gap-4 justify-center mb-16">
          <Link href="/search">
            <Button className={isDark ?
              "bg-zinc-800 hover:bg-zinc-700 text-white border border-zinc-700 min-w-[120px]" :
              "bg-blue-600 hover:bg-blue-700 text-white min-w-[120px]"
            }>
              Try Now
            </Button>
          </Link>
          <Link href="/learn-more">
            <Button variant="outline" className={isDark ?
              "bg-transparent hover:bg-zinc-800 text-white border border-zinc-700 min-w-[120px]" :
              "bg-white hover:bg-zinc-100 text-zinc-900 border border-zinc-200 min-w-[120px]"
            }>
              Learn More
            </Button>
          </Link>
        </div>
      </div>
    </section>
  );
}