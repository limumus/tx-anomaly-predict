"use client";

import Link from 'next/link';
import { useTheme } from 'next-themes';
import { useState, useEffect } from 'react';
import {
  Search,
  Globe,
  LineChart,
  BarChartBig
} from 'lucide-react';

const products = [
  {
    title: "DeepSearch",
    description: "Search, read and reason until best answer found.",
    icon: <Search className="h-5 w-5" />,
    href: "/deepsearch"
  },
  {
    title: "Reader",
    description: "Convert a URL to LLM-friendly input for better processing.",
    icon: <Globe className="h-5 w-5" />,
    href: "/reader"
  },
  {
    title: "Embeddings",
    description: "World-class multimodal multilingual embeddings.",
    icon: <LineChart className="h-5 w-5" />,
    href: "/embeddings"
  },
  {
    title: "Reranker",
    description: "Neural retriever for maximizing search relevancy.",
    icon: <BarChartBig className="h-5 w-5" />,
    href: "/reranker"
  }
];

export function ProductsSection() {
  const { theme } = useTheme();
  const [mounted, setMounted] = useState(false);

  // After mounting, we can safely show the UI
  useEffect(() => {
    setMounted(true);
  }, []);

  if (!mounted) {
    return null;
  }

  const isDark = theme === "dark";

  return (
    <section className={`py-24 px-4 ${isDark ? 'bg-black' : 'bg-zinc-50'}`}>
      <div className="container mx-auto">
        <h2 className={`text-3xl md:text-4xl font-bold ${isDark ? 'text-white' : 'text-zinc-900'} mb-2 text-center`}>
          Our Search Tools
        </h2>
        <p className={`${isDark ? 'text-zinc-400' : 'text-zinc-600'} text-center mb-16 max-w-3xl mx-auto`}>
          Advanced tools for search and retrieval, designed to enhance your search experience with cutting-edge AI.
        </p>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
          {products.map((product) => (
            <Link
              key={product.title}
              href={product.href}
              className={`p-6 rounded-lg border transition-all group
                ${isDark ?
                  'border-zinc-800 hover:border-zinc-700 bg-zinc-900/50 hover:bg-zinc-900' :
                  'border-zinc-200 hover:border-zinc-300 bg-white hover:bg-zinc-50 shadow-sm'
                }`}
            >
              <div className="flex flex-col gap-4">
                <div className="flex items-center gap-3">
                  <div className={`p-2 rounded-md transition-colors
                    ${isDark ?
                      'bg-zinc-800 group-hover:bg-zinc-700' :
                      'bg-blue-100 group-hover:bg-blue-200'
                    }`}
                  >
                    {product.icon}
                  </div>
                  <h3 className={`text-xl font-semibold ${isDark ? 'text-white' : 'text-zinc-900'}`}>
                    {product.title}
                  </h3>
                </div>
                <p className={`pl-10 ${isDark ? 'text-zinc-400' : 'text-zinc-600'}`}>
                  {product.description}
                </p>
              </div>
            </Link>
          ))}
        </div>

        <div className="mt-12 text-center">
          <div className={`inline-block px-6 py-3 rounded-full ${
            isDark ?
              'bg-zinc-900 border border-zinc-800 text-zinc-300' :
              'bg-white border border-zinc-200 text-zinc-600 shadow-sm'
          }`}>
            Try our search feature below - no registration needed!
          </div>
        </div>
      </div>
    </section>
  );
}
