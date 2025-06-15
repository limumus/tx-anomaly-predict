"use client";

import { useTheme } from "next-themes";
import { useState, useEffect } from "react";
import Image from "next/image";
import { ChevronLeft, ChevronRight } from "lucide-react";

const imageList = [
  "/images/3/1.png",
  "/images/3/2.png",
  "/images/3/3.png",
];

export default function ReaderPage() {
  const { theme } = useTheme();
  const [mounted, setMounted] = useState(false);
  const [currentIndex, setCurrentIndex] = useState(0);

  useEffect(() => {
    setMounted(true);
  }, []);

  if (!mounted) return null;

  const isDark = theme === "dark";

  const prevIndex = (currentIndex - 1 + imageList.length) % imageList.length;
  const nextIndex = (currentIndex + 1) % imageList.length;

  const prevImage = () => {
    setCurrentIndex(prevIndex);
  };

  const nextImage = () => {
    setCurrentIndex(nextIndex);
  };

  return (
    <main
      className={`min-h-screen py-24 px-4 flex flex-col items-center justify-center ${
        isDark ? "bg-black text-white" : "bg-zinc-50 text-zinc-900"
      }`}
    >
      <h1 className="text-4xl font-bold mb-8 text-center">模型运行结果一览</h1>

      <div className="relative w-full max-w-4xl flex items-center justify-center gap-6">
        {/* 左侧小图 + 左箭头 */}
        <div
          className="relative cursor-pointer"
          onClick={prevImage}
          aria-label="Previous Image"
          title="上一张"
        >
          <Image
            src={imageList[prevIndex]}
            alt={`Previous Image ${prevIndex}`}
            width={150}
            height={100}
            className="rounded-lg opacity-40 hover:opacity-70 transition"
            unoptimized
          />
          <button className="absolute left-1 top-1/2 -translate-y-1/2 p-1 bg-white/20 backdrop-blur rounded-full hover:bg-white/40 transition">
            <ChevronLeft className="w-5 h-5 text-white" />
          </button>
        </div>

        {/* 主图 */}
        <div className="relative">
          <Image
            src={imageList[currentIndex]}
            alt={`Current Image ${currentIndex}`}
            width={600}
            height={400}
            className="rounded-xl shadow-lg max-w-full max-h-[80vh] object-contain"
            unoptimized
          />
        </div>

        {/* 右侧小图 + 右箭头 */}
        <div
          className="relative cursor-pointer"
          onClick={nextImage}
          aria-label="Next Image"
          title="下一张"
        >
          <Image
            src={imageList[nextIndex]}
            alt={`Next Image ${nextIndex}`}
            width={150}
            height={100}
            className="rounded-lg opacity-40 hover:opacity-70 transition"
            unoptimized
          />
          <button className="absolute right-1 top-1/2 -translate-y-1/2 p-1 bg-white/20 backdrop-blur rounded-full hover:bg-white/40 transition">
            <ChevronRight className="w-5 h-5 text-white" />
          </button>
        </div>
      </div>
    </main>
  );
}
