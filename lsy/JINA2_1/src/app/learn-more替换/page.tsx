// app/learn-more/page.tsx
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
    title: "创新点",
    description: "带您简略了解针对当今研究难点，我们做出的创新",
    icon: <Search className="h-5 w-5" />,
    href: "/deepsearch"
  },
  {
    title: "数据集一览",
    description: "从丰富度、准确性等方面，了解我们采用的数据集",
    icon: <Globe className="h-5 w-5" />,
    href: "/reader"
  },
  {
    title: "模型性能展示",
    description: "了解我们模型的工作速度、精度等数据",
    icon: <LineChart className="h-5 w-5" />,
    href: "/embeddings"
  },
  {
    title: "更多",
    description: "查看更多有关我们模型的介绍",
    icon: <BarChartBig className="h-5 w-5" />,
    href: "/reranker"
  }
];

export default function LearnMorePage() {
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
    <section className={`py-24 px-4 ${isDark ? 'bg-black' : 'bg-zinc-50'}`}>
      <div className="container mx-auto">
        <h2 className={`text-3xl md:text-4xl font-bold ${isDark ? 'text-white' : 'text-zinc-900'} mb-2 text-center`}>
          Learn More
        </h2>
        <p className={`${isDark ? 'text-zinc-400' : 'text-zinc-600'} text-center mb-16 max-w-3xl mx-auto`}>
          从多个方面更加细致地向您展示我们模型的优越性.
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

      </div>
    </section>
  );
}